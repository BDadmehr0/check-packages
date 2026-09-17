#!/usr/bin/env bash

set -uo pipefail

# ============================================================
# Ryoku Offline Repository Repair Tool
# ============================================================

BASE="/usr/share/ryoku/offline"
REPO="$BASE/repo"
BAD_LIST="$BASE/bad-packages.txt"

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"

BACKUP="$BASE/repair-backup-$TIMESTAMP"
QUARANTINE="$BASE/quarantine-$TIMESTAMP"
DOWNLOAD="$BASE/download-$TIMESTAMP"

REPORT="$BASE/repair-report-$TIMESTAMP.txt"

mkdir -p "$BACKUP" "$QUARANTINE" "$DOWNLOAD"

exec > >(tee -a "$REPORT") 2>&1

echo
echo "============================================================"
echo " Ryoku Offline Repository Repair"
echo "============================================================"
echo "Date       : $(date)"
echo "Repository : $REPO"
echo "Bad list   : $BAD_LIST"
echo "Backup     : $BACKUP"
echo "Quarantine : $QUARANTINE"
echo "Downloads  : $DOWNLOAD"
echo "============================================================"
echo

# ------------------------------------------------------------
# Checks
# ------------------------------------------------------------

if [[ ! -d "$REPO" ]]; then
    echo "ERROR: Repository does not exist:"
    echo "$REPO"
    exit 1
fi

if [[ ! -f "$BAD_LIST" ]]; then
    echo "ERROR: Bad package list does not exist:"
    echo "$BAD_LIST"
    exit 1
fi

if ! command -v pacman >/dev/null 2>&1; then
    echo "ERROR: pacman not found."
    exit 1
fi

if ! command -v repo-add >/dev/null 2>&1; then
    echo "ERROR: repo-add not found."
    echo "Install pacman-contrib if available."
    exit 1
fi

if ! command -v zstd >/dev/null 2>&1; then
    echo "ERROR: zstd not found."
    exit 1
fi

# ------------------------------------------------------------
# Root check
# ------------------------------------------------------------

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: Run this script as root:"
    echo
    echo "sudo $0"
    exit 1
fi

# ------------------------------------------------------------
# Find repo database
# ------------------------------------------------------------

echo "[1/9] Finding repository database..."

mapfile -t DBS < <(
    find "$REPO" -maxdepth 1 -type f \
        \( -name '*.db' -o -name '*.db.tar.gz' -o -name '*.db.tar.zst' \) \
        -print
)

if [[ ${#DBS[@]} -eq 0 ]]; then
    echo "WARNING: No repository database found."
    echo "A new database will be created."
    DB="$REPO/ryoku.db.tar.gz"
else
    # Prefer .db.tar.gz, then .db.tar.zst, then .db
    DB=""
    for x in "${DBS[@]}"; do
        case "$x" in
            *.db.tar.gz)
                DB="$x"
                break
                ;;
        esac
    done

    if [[ -z "$DB" ]]; then
        for x in "${DBS[@]}"; do
            case "$x" in
                *.db.tar.zst)
                    DB="$x"
                    break
                    ;;
            esac
        done
    fi

    if [[ -z "$DB" ]]; then
        DB="${DBS[0]}"
    fi
fi

DB_NAME="$(basename "$DB")"

echo "Database: $DB"
echo

# ------------------------------------------------------------
# Backup
# ------------------------------------------------------------

echo "[2/9] Creating backup..."

cp -a "$REPO" "$BACKUP/repo"

echo "Backup created:"
echo "$BACKUP/repo"
echo

# ------------------------------------------------------------
# Read bad package list
# ------------------------------------------------------------

echo "[3/9] Reading bad package list..."

mapfile -t BAD_FILES < <(
    sed '/^[[:space:]]*$/d' "$BAD_LIST"
)

BAD_TOTAL=${#BAD_FILES[@]}

echo "Bad packages listed: $BAD_TOTAL"
echo

if [[ "$BAD_TOTAL" -eq 0 ]]; then
    echo "Nothing to repair."
    exit 0
fi

# ------------------------------------------------------------
# Helper functions
# ------------------------------------------------------------

package_name_from_file() {
    local file="$1"

    pacman -Qp "$file" --print-format '%n' 2>/dev/null || true
}

package_version_from_file() {
    local file="$1"

    pacman -Qp "$file" --print-format '%v' 2>/dev/null || true
}

find_same_package_elsewhere() {
    local basename="$1"

    find /mnt /usr/share/ryoku /var/cache/pacman \
        -type f \
        -name "$basename" \
        2>/dev/null \
        | while read -r candidate; do

            # Don't return the known-bad repository copy.
            if [[ "$candidate" == "$REPO/$basename" ]]; then
                continue
            fi

            if zstd -t "$candidate" >/dev/null 2>&1 &&
               pacman -Qp "$candidate" >/dev/null 2>&1; then
                echo "$candidate"
                return 0
            fi
        done

    return 1
}

find_downloaded_package() {
    local basename="$1"

    find "$DOWNLOAD" /var/cache/pacman/pkg /mnt \
        -type f \
        -name "$basename" \
        2>/dev/null \
        | while read -r candidate; do

            if zstd -t "$candidate" >/dev/null 2>&1 &&
               pacman -Qp "$candidate" >/dev/null 2>&1; then
                echo "$candidate"
                return 0
            fi
        done

    return 1
}

# ------------------------------------------------------------
# Repair
# ------------------------------------------------------------

echo "[4/9] Repairing bad packages..."
echo

REPAIRED=0
FAILED=0
SKIPPED=0

for bad in "${BAD_FILES[@]}"; do

    if [[ ! -f "$bad" ]]; then
        # bad-packages.txt may contain relative paths
        if [[ -f "$REPO/$(basename "$bad")" ]]; then
            bad="$REPO/$(basename "$bad")"
        else
            echo "[SKIP] File does not exist: $bad"
            ((SKIPPED++))
            continue
        fi
    fi

    basename_pkg="$(basename "$bad")"

    echo
    echo "------------------------------------------------------------"
    echo "Package: $basename_pkg"
    echo "------------------------------------------------------------"

    # --------------------------------------------------------
    # Get package metadata
    # --------------------------------------------------------

    pkgname="$(package_name_from_file "$bad")"
    pkgver="$(package_version_from_file "$bad")"

    if [[ -z "$pkgname" || -z "$pkgver" ]]; then
        echo "Could not read package metadata from:"
        echo "$bad"

        echo "Trying filename-based package name..."

        pkgname="${basename_pkg%%-[0-9]*}"

        if [[ -z "$pkgname" ]]; then
            echo "FAILED: Cannot determine package name."
            ((FAILED++))
            continue
        fi
    fi

    echo "Name    : $pkgname"
    echo "Version : $pkgver"

    # --------------------------------------------------------
    # Look for exact healthy copy
    # --------------------------------------------------------

    healthy=""

    healthy="$(find_same_package_elsewhere "$basename_pkg" || true)"

    if [[ -n "$healthy" ]]; then
        echo
        echo "Found healthy existing copy:"
        echo "$healthy"
    fi

    # --------------------------------------------------------
    # If no copy, download exact version
    # --------------------------------------------------------

    if [[ -z "$healthy" ]]; then

        echo
        echo "No healthy local copy found."
        echo "Trying pacman to download exact package..."

        if [[ -n "$pkgver" ]]; then

            if pacman -Sw \
                --noconfirm \
                --cachedir "$DOWNLOAD" \
                "$pkgname=$pkgver"; then

                healthy="$DOWNLOAD/$basename_pkg"

            else
                echo "Exact version download failed."
            fi

        else

            echo "Package version could not be determined."
        fi
    fi

    # --------------------------------------------------------
    # Verify replacement
    # --------------------------------------------------------

    if [[ -z "$healthy" || ! -f "$healthy" ]]; then
        echo
        echo "FAILED: No replacement available."
        echo "Original package was NOT touched."
        ((FAILED++))
        continue
    fi

    echo
    echo "Verifying replacement..."

    if ! zstd -t "$healthy" >/dev/null 2>&1; then
        echo "FAILED: zstd verification failed."
        ((FAILED++))
        continue
    fi

    if ! pacman -Qp "$healthy" >/dev/null 2>&1; then
        echo "FAILED: pacman rejected replacement."
        ((FAILED++))
        continue
    fi

    replacement_basename="$(basename "$healthy")"

    if [[ "$replacement_basename" != "$basename_pkg" ]]; then
        echo "FAILED: Replacement filename differs."
        echo "Expected: $basename_pkg"
        echo "Got     : $replacement_basename"
        echo
        echo "Refusing automatic replacement."
        ((FAILED++))
        continue
    fi

    # --------------------------------------------------------
    # Quarantine original
    # --------------------------------------------------------

    echo
    echo "Moving corrupted package to quarantine..."

    mv "$bad" "$QUARANTINE/$basename_pkg"

    # --------------------------------------------------------
    # Copy replacement
    # --------------------------------------------------------

    echo "Installing healthy replacement..."

    cp -a "$healthy" "$REPO/$basename_pkg"

    # --------------------------------------------------------
    # Verify final file
    # --------------------------------------------------------

    if ! zstd -t "$REPO/$basename_pkg" >/dev/null 2>&1; then
        echo "ERROR: Replacement verification failed."

        rm -f "$REPO/$basename_pkg"

        mv "$QUARANTINE/$basename_pkg" "$bad"

        echo "Original restored."
        ((FAILED++))
        continue
    fi

    if ! pacman -Qp "$REPO/$basename_pkg" >/dev/null 2>&1; then
        echo "ERROR: pacman rejected replacement."

        rm -f "$REPO/$basename_pkg"

        mv "$QUARANTINE/$basename_pkg" "$bad"

        echo "Original restored."
        ((FAILED++))
        continue
    fi

    echo "SUCCESS: $basename_pkg repaired."
    ((REPAIRED++))

done

echo
echo "============================================================"
echo "Repair phase complete"
echo "============================================================"
echo "Repaired : $REPAIRED"
echo "Failed   : $FAILED"
echo "Skipped  : $SKIPPED"
echo

# ------------------------------------------------------------
# Stop if failures exist
# ------------------------------------------------------------

if [[ "$FAILED" -gt 0 ]]; then
    echo "WARNING:"
    echo "Some packages could not be repaired."
    echo
    echo "The repository database will still be rebuilt using"
    echo "the packages currently present."
    echo
fi

# ------------------------------------------------------------
# Rebuild repository database
# ------------------------------------------------------------

echo "[5/9] Rebuilding repository database..."
echo

# Determine database filename.
# repo-add wants a database path without requiring it to exist.

if [[ "$DB" == *.db.tar.gz ]]; then
    DB_TARGET="$DB"
elif [[ "$DB" == *.db.tar.zst ]]; then
    DB_TARGET="$DB"
elif [[ "$DB" == *.db ]]; then
    DB_TARGET="$DB"
else
    DB_TARGET="$REPO/ryoku.db.tar.gz"
fi

echo "Database target:"
echo "$DB_TARGET"
echo

# Remove stale DB variants before rebuilding.
# Package files are NOT touched.

find "$REPO" -maxdepth 1 -type f \
    \( -name '*.db' -o -name '*.db.tar.gz' -o -name '*.db.tar.zst' \
       -o -name '*.files' -o -name '*.files.tar.gz' -o -name '*.files.tar.zst' \) \
    -print \
    -exec mv {} "$QUARANTINE/" \;

echo "Old repository database metadata moved to quarantine."

# Build package list.
mapfile -t ALL_PACKAGES < <(
    find "$REPO" -maxdepth 1 -type f -name '*.pkg.tar.zst' -print | sort
)

echo "Packages in repo: ${#ALL_PACKAGES[@]}"
echo

if [[ ${#ALL_PACKAGES[@]} -eq 0 ]]; then
    echo "ERROR: No packages remain in repository."
    exit 1
fi

if ! repo-add "$DB_TARGET" "${ALL_PACKAGES[@]}"; then
    echo
    echo "ERROR: repo-add failed."
    echo
    echo "Your original repository is backed up at:"
    echo "$BACKUP/repo"
    exit 1
fi

echo
echo "Repository database rebuilt successfully."
echo

# ------------------------------------------------------------
# Find new database
# ------------------------------------------------------------

echo "[6/9] Checking generated repository metadata..."

find "$REPO" -maxdepth 1 -type f \
    \( -name '*.db' -o -name '*.db.tar.gz' -o -name '*.db.tar.zst' \) \
    -printf '%f\n'

echo

# ------------------------------------------------------------
# Verify every package
# ------------------------------------------------------------

echo "[7/9] Verifying every package..."
echo

FINAL_BAD="$BASE/final-bad-$TIMESTAMP.txt"
FINAL_GOOD="$BASE/final-good-$TIMESTAMP.txt"

: > "$FINAL_BAD"
: > "$FINAL_GOOD"

TOTAL=0
GOOD=0
BAD=0

while IFS= read -r pkg; do

    ((TOTAL++))

    name="$(basename "$pkg")"

    printf '[%4d/%4d] %-75s ' "$TOTAL" "${#ALL_PACKAGES[@]}" "$name"

    if ! zstd -t "$pkg" >/dev/null 2>&1; then
        echo "BAD-ZSTD"
        echo "$pkg" >> "$FINAL_BAD"
        ((BAD++))
        continue
    fi

    if ! pacman -Qp "$pkg" >/dev/null 2>&1; then
        echo "BAD-PACMAN"
        echo "$pkg" >> "$FINAL_BAD"
        ((BAD++))
        continue
    fi

    echo "OK"
    echo "$pkg" >> "$FINAL_GOOD"
    ((GOOD++))

done < <(
    find "$REPO" -maxdepth 1 -type f -name '*.pkg.tar.zst' -print | sort
)

echo
echo "============================================================"
echo "Final package verification"
echo "============================================================"
echo "Total : $TOTAL"
echo "Good  : $GOOD"
echo "Bad   : $BAD"
echo

# ------------------------------------------------------------
# Database package consistency check
# ------------------------------------------------------------

echo "[8/9] Testing repository database access..."
echo

# Create temporary pacman config so we don't touch system config.
TESTROOT="$BASE/testroot-$TIMESTAMP"
mkdir -p "$TESTROOT"

cat > "$TESTROOT/pacman.conf" <<EOF
[options]
Architecture = auto
SigLevel = Never
CacheDir = $REPO

[ryoku-test]
SigLevel = Never
Server = file://$REPO
EOF

mkdir -p "$TESTROOT/var/lib/pacman"

if pacman \
    --config "$TESTROOT/pacman.conf" \
    --root "$TESTROOT" \
    -Sy \
    --dbonly \
    2>&1; then

    echo
    echo "Repository database can be read by pacman."
else
    echo
    echo "WARNING: pacman repository database test failed."
fi

rm -rf "$TESTROOT"

# ------------------------------------------------------------
# Final result
# ------------------------------------------------------------

echo
echo "[9/9] Final result"
echo
echo "============================================================"
echo " Ryoku Offline Repository Repair Result"
echo "============================================================"
echo "Repaired packages : $REPAIRED"
echo "Failed repairs    : $FAILED"
echo "Skipped           : $SKIPPED"
echo "Final good        : $GOOD"
echo "Final bad         : $BAD"
echo
echo "Backup:"
echo "$BACKUP"
echo
echo "Quarantine:"
echo "$QUARANTINE"
echo
echo "Report:"
echo "$REPORT"
echo
echo "Final bad list:"
echo "$FINAL_BAD"
echo
echo "Final good list:"
echo "$FINAL_GOOD"
echo "============================================================"
echo

if [[ "$BAD" -eq 0 ]]; then
    echo "SUCCESS: All package archives passed final verification."
    echo
    echo "The offline repository database has been rebuilt."
else
    echo "WARNING: Some package archives are still bad."
    echo
    echo "DO NOT run the Ryoku installer yet."
    echo "Repair the packages listed in:"
    echo "$FINAL_BAD"
fi