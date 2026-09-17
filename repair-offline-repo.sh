#!/usr/bin/env bash
set -uo pipefail

# ============================================================
# Ryoku Offline Repository Package Repair Tool
# ============================================================

REPO="/usr/share/ryoku/offline/repo"
CACHE="/mnt/var/cache/pacman/pkg"
OFFLINE="/usr/share/ryoku/offline"

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
WORK="$OFFLINE/repair-$TIMESTAMP"
BACKUP="$WORK/backup"
LOG="$WORK/repair.log"

mkdir -p "$BACKUP"

exec > >(tee -a "$LOG") 2>&1

GOOD=0
BAD=0
RECOVERED=0
FAILED=0
SKIPPED=0

declare -a BAD_FILES=()

echo "============================================================"
echo " Ryoku Offline Repository Repair"
echo "============================================================"
echo "Repo   : $REPO"
echo "Cache  : $CACHE"
echo "Backup : $BACKUP"
echo "Log    : $LOG"
echo

# ------------------------------------------------------------
# Root check
# ------------------------------------------------------------

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Run this script as root."
    exit 1
fi

if [[ ! -d "$REPO" ]]; then
    echo "ERROR: Repository does not exist:"
    echo "$REPO"
    exit 1
fi

# ------------------------------------------------------------
# Dependencies
# ------------------------------------------------------------

for cmd in pacman bsdtar zstd repo-add awk sed grep find sha256sum stat; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: Required command not found: $cmd"
        exit 1
    fi
done

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------

package_filename_to_name_version() {
    local file
    file="$(basename "$1")"

    # Remove architecture and extension
    file="${file%.pkg.tar.zst}"

    case "$file" in
        *.any)
            file="${file%.any}"
            ;;
        *_x86_64)
            file="${file%_x86_64}"
            ;;
    esac

    # Arch package format:
    # name-version-release
    #
    # Package names can contain '-' so find the version by
    # looking for the first segment beginning with a digit.

    local namever="$file"
    local version=""
    local name=""

    if [[ "$namever" =~ ^(.+)-([0-9][^-]*)-(.+)$ ]]; then
        name="${BASH_REMATCH[1]}"
        version="${BASH_REMATCH[2]}-${BASH_REMATCH[3]}"
    else
        # More robust fallback:
        # find "-<digit>" and split there
        if [[ "$namever" =~ ^(.+)-([0-9].*)$ ]]; then
            name="${BASH_REMATCH[1]}"
            version="${BASH_REMATCH[2]}"
        fi
    fi

    if [[ -n "$name" && -n "$version" ]]; then
        printf '%s\n%s\n' "$name" "$version"
        return 0
    fi

    return 1
}

verify_package() {
    local file="$1"

    [[ -f "$file" ]] || return 1

    # zstd integrity
    if ! zstd -t "$file" >/dev/null 2>&1; then
        return 1
    fi

    # libalpm metadata/content check
    if ! bsdtar -tf "$file" >/dev/null 2>&1; then
        return 1
    fi

    # Package metadata must be readable
    if ! bsdtar -xOf "$file" .PKGINFO >/dev/null 2>&1; then
        return 1
    fi

    return 0
}

backup_file() {
    local file="$1"

    if [[ -f "$file" ]]; then
        cp -a -- "$file" "$BACKUP/"
    fi
}

find_local_copy() {
    local name="$1"
    local version="$2"
    local original="$3"

    local candidate
    local expected

    expected="${name}-${version}"

    echo "Searching local copies of: $expected"

    # Search cache first
    while IFS= read -r -d '' candidate; do
        if verify_package "$candidate"; then
            echo "  FOUND healthy cache copy:"
            echo "  $candidate"
            printf '%s\n' "$candidate"
            return 0
        fi
    done < <(
        find "$CACHE" "$OFFLINE" \
            -type f \
            -name "${expected}-*.pkg.tar.zst" \
            -print0 2>/dev/null
    )

    # Exact filename search
    while IFS= read -r -d '' candidate; do
        if [[ "$candidate" != "$original" ]] && verify_package "$candidate"; then
            echo "  FOUND healthy copy:"
            echo "  $candidate"
            printf '%s\n' "$candidate"
            return 0
        fi
    done < <(
        find /mnt /usr/share/ryoku \
            -type f \
            -name "${expected}-*.pkg.tar.zst" \
            -print0 2>/dev/null
    )

    return 1
}

download_exact_package() {
    local name="$1"
    local version="$2"
    local target="$3"

    local tmpdir
    tmpdir="$(mktemp -d "$WORK/download.XXXXXX")"

    echo "Trying pacman to download:"
    echo "  $name = $version"

    # IMPORTANT:
    # -Sw downloads without installing.
    # --cachedir directs the package into our temporary directory.
    #
    # Try exact version first.

    if pacman -Sw \
        --noconfirm \
        --cachedir "$tmpdir" \
        "${name}=${version}"; then

        local downloaded
        downloaded="$(find "$tmpdir" -maxdepth 1 -type f -name '*.pkg.tar.zst' -print -quit)"

        if [[ -n "$downloaded" ]] && verify_package "$downloaded"; then
            echo "  Downloaded healthy package:"
            echo "  $downloaded"
            printf '%s\n' "$downloaded"
            rm -rf "$tmpdir"
            return 0
        fi
    fi

    echo "  Exact version download failed."

    rm -rf "$tmpdir"
    return 1
}

replace_package() {
    local bad="$1"
    local good="$2"

    echo "Replacing:"
    echo "  BAD : $bad"
    echo "  GOOD: $good"

    if ! verify_package "$good"; then
        echo "ERROR: Replacement failed verification."
        return 1
    fi

    backup_file "$bad"

    local tmp
    tmp="${bad}.replacement.$$"

    if ! cp -a -- "$good" "$tmp"; then
        rm -f "$tmp"
        echo "ERROR: Could not copy replacement."
        return 1
    fi

    if ! verify_package "$tmp"; then
        rm -f "$tmp"
        echo "ERROR: Copied replacement failed verification."
        return 1
    fi

    if ! mv -f -- "$tmp" "$bad"; then
        rm -f "$tmp"
        echo "ERROR: Could not replace original."
        return 1
    fi

    echo "  Replacement successful."
    return 0
}

# ------------------------------------------------------------
# Phase 1: Scan repository
# ------------------------------------------------------------

echo
echo "[1/6] Scanning repository..."
echo

mapfile -d '' ALL_PACKAGES < <(
    find "$REPO" -maxdepth 1 -type f \
        -name '*.pkg.tar.zst' \
        -print0 | sort -z
)

TOTAL=${#ALL_PACKAGES[@]}

echo "Packages found: $TOTAL"
echo

for pkg in "${ALL_PACKAGES[@]}"; do
    printf '\rChecking: %d / %d' "$((GOOD + BAD + 1))" "$TOTAL"

    if verify_package "$pkg"; then
        ((GOOD++))
    else
        ((BAD++))
        BAD_FILES+=("$pkg")
    fi
done

echo
echo
echo "Initial scan:"
echo "  Good : $GOOD"
echo "  Bad  : $BAD"
echo

if (( BAD == 0 )); then
    echo "No corrupted packages found."
    exit 0
fi

# ------------------------------------------------------------
# Phase 2: Save bad package list
# ------------------------------------------------------------

BAD_LIST="$WORK/bad-packages.txt"

printf '%s\n' "${BAD_FILES[@]}" > "$BAD_LIST"

echo "[2/6] Bad packages saved to:"
echo "$BAD_LIST"
echo

# ------------------------------------------------------------
# Phase 3: Repair
# ------------------------------------------------------------

echo "[3/6] Repairing packages..."
echo

for bad in "${BAD_FILES[@]}"; do

    echo
    echo "------------------------------------------------------------"
    echo "Package:"
    echo "$bad"
    echo "------------------------------------------------------------"

    filename_data="$(package_filename_to_name_version "$bad" 2>/dev/null || true)"

    if [[ -z "$filename_data" ]]; then
        echo "FAILED: Cannot determine package name/version."
        ((FAILED++))
        continue
    fi

    name="$(echo "$filename_data" | sed -n '1p')"
    version="$(echo "$filename_data" | sed -n '2p')"

    echo "Detected:"
    echo "  Name   : $name"
    echo "  Version: $version"

    replacement=""

    # --------------------------------------------------------
    # Search healthy local copy
    # --------------------------------------------------------

    replacement="$(
        find_local_copy "$name" "$version" "$bad" 2>/dev/null \
        | tail -n 1
    )" || replacement=""

    # --------------------------------------------------------
    # Download if local copy unavailable
    # --------------------------------------------------------

    if [[ -z "$replacement" ]]; then
        replacement="$(
            download_exact_package "$name" "$version" "$bad" 2>/dev/null \
            | tail -n 1
        )" || replacement=""
    fi

    # --------------------------------------------------------
    # Final check
    # --------------------------------------------------------

    if [[ -z "$replacement" || ! -f "$replacement" ]]; then
        echo "FAILED: No healthy replacement available."
        echo
        ((FAILED++))
        continue
    fi

    if ! verify_package "$replacement"; then
        echo "FAILED: Replacement is not healthy."
        ((FAILED++))
        continue
    fi

    # --------------------------------------------------------
    # Replace
    # --------------------------------------------------------

    if replace_package "$bad" "$replacement"; then
        ((RECOVERED++))
    else
        ((FAILED++))
    fi

done

# ------------------------------------------------------------
# Phase 4: Rescan
# ------------------------------------------------------------

echo
echo "[4/6] Rechecking repaired repository..."
echo

FINAL_GOOD=0
FINAL_BAD=0

while IFS= read -r -d '' pkg; do
    if verify_package "$pkg"; then
        ((FINAL_GOOD++))
    else
        ((FINAL_BAD++))
        echo "STILL BAD:"
        echo "$pkg"
    fi
done < <(
    find "$REPO" -maxdepth 1 -type f \
        -name '*.pkg.tar.zst' \
        -print0 | sort -z
)

echo
echo "Final package state:"
echo "  Good: $FINAL_GOOD"
echo "  Bad : $FINAL_BAD"
echo

# ------------------------------------------------------------
# Phase 5: Lock detection
# ------------------------------------------------------------

echo "[5/6] Checking repository database lock..."

DB="$REPO/ryoku.db.tar.gz"
LOCK="${DB}.lck"

if [[ -e "$LOCK" ]]; then

    echo
    echo "WARNING: Lock exists:"
    echo "$LOCK"

    # Check whether repo-add/pacman is actually running.
    if pgrep -a -f '(^|/)(repo-add|pacman)( |$)' >/dev/null 2>&1; then
        echo
        echo "A pacman/repo-add process appears to be running."
        echo "The lock will NOT be removed automatically."
        echo
        echo "Processes:"
        pgrep -a -f '(^|/)(repo-add|pacman)( |$)' || true

        echo
        echo "Repository database rebuild SKIPPED."
        ((SKIPPED++))

    else
        echo
        echo "No pacman/repo-add process appears to be running."
        echo "The lock appears stale."

        # Backup lock rather than blindly deleting it.
        mkdir -p "$BACKUP/locks"

        cp -a "$LOCK" "$BACKUP/locks/" 2>/dev/null || true
        rm -f "$LOCK"

        echo "Stale lock moved/removed."
    fi
fi

# ------------------------------------------------------------
# Phase 6: Rebuild repo database
# ------------------------------------------------------------

if (( FINAL_BAD > 0 )); then
    echo
    echo "WARNING:"
    echo "$FINAL_BAD package(s) are still corrupted."
    echo "Repository database will NOT be rebuilt."
    echo "Fix remaining packages first."
    ((SKIPPED++))
else

    echo
    echo "[6/6] Rebuilding repository database..."
    echo

    # Backup current database files.
    mkdir -p "$BACKUP/repo-db"

    for dbfile in \
        "$REPO/ryoku.db.tar.gz" \
        "$REPO/ryoku.files.tar.gz" \
        "$REPO/ryoku.db" \
        "$REPO/ryoku.files"; do

        if [[ -e "$dbfile" ]]; then
            cp -a "$dbfile" "$BACKUP/repo-db/" 2>/dev/null || true
        fi
    done

    echo "Running repo-add..."

    if repo-add --remove "$DB" "$REPO"/*.pkg.tar.zst; then
        echo
        echo "Repository database rebuilt successfully."
    else
        echo
        echo "ERROR: repo-add failed."
        echo
        echo "Repository package files were NOT deleted."
        echo "Previous database backup is available at:"
        echo "$BACKUP/repo-db"
        ((FAILED++))
    fi
fi

# ------------------------------------------------------------
# Final report
# ------------------------------------------------------------

REPORT="$WORK/REPORT.txt"

cat > "$REPORT" <<EOF
Ryoku Offline Repository Repair Report
======================================

Date:
$TIMESTAMP

Repository:
$REPO

Initial:
  Good: $GOOD
  Bad : $BAD

Repair:
  Recovered: $RECOVERED
  Failed   : $FAILED
  Skipped  : $SKIPPED

Final:
  Good: $FINAL_GOOD
  Bad : $FINAL_BAD

Backup:
$BACKUP

Bad package list:
$BAD_LIST

Log:
$LOG
EOF

echo
echo "============================================================"
echo " REPAIR COMPLETE"
echo "============================================================"
echo
echo "Initial:"
echo "  Good : $GOOD"
echo "  Bad  : $BAD"
echo
echo "Repair:"
echo "  Recovered: $RECOVERED"
echo "  Failed   : $FAILED"
echo "  Skipped  : $SKIPPED"
echo
echo "Final:"
echo "  Good : $FINAL_GOOD"
echo "  Bad  : $FINAL_BAD"
echo
echo "Backup:"
echo "$BACKUP"
echo
echo "Report:"
echo "$REPORT"
echo
echo "Log:"
echo "$LOG"
echo "============================================================"