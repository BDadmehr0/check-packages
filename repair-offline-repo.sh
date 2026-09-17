#!/usr/bin/env bash
set -uo pipefail

# ============================================================
# Ryoku Offline Repository Repair Tool
# ============================================================

REPO="/usr/share/ryoku/offline/repo"
CACHE="/mnt/var/cache/pacman/pkg"
ROOT="/mnt"
BACKUP_BASE="/usr/share/ryoku/offline"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP="$BACKUP_BASE/repair-backup-$TIMESTAMP"

LOG="$BACKUP/repair.log"

mkdir -p "$BACKUP"

exec > >(tee -a "$LOG") 2>&1

echo "============================================================"
echo " Ryoku Offline Repository Repair"
echo "============================================================"
echo
echo "Repository : $REPO"
echo "Cache      : $CACHE"
echo "Backup     : $BACKUP"
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
# Check required tools
# ------------------------------------------------------------

for cmd in pacman pacman-conf repo-add bsdtar zstd sha256sum; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "WARNING: command not found: $cmd"
    fi
done

# ------------------------------------------------------------
# Lock handling
# ------------------------------------------------------------

LOCK="$REPO/ryoku.db.tar.gz.lck"

if [[ -e "$LOCK" ]]; then
    echo
    echo "Checking repository lock..."

    if pgrep -x pacman >/dev/null || \
       pgrep -x repo-add >/dev/null; then

        echo "ERROR: pacman/repo-add appears to be running."
        echo "Do NOT remove the lock."
        exit 1
    fi

    echo "No pacman/repo-add process detected."
    echo "Removing stale repository lock."

    mv "$LOCK" "$BACKUP/" 2>/dev/null || rm -f "$LOCK"
fi

# ------------------------------------------------------------
# Backup repository
# ------------------------------------------------------------

echo
echo "[1/7] Creating repository backup..."

mkdir -p "$BACKUP/repo"

cp -a "$REPO"/. "$BACKUP/repo/"

echo "Backup created."

# ------------------------------------------------------------
# Verify package using pacman -Qp
# ------------------------------------------------------------

get_pkg_name() {
    local file="$1"

    pacman -Qp "$file" 2>/dev/null |
        awk '{print $1}'
}

get_pkg_version() {
    local file="$1"

    pacman -Qp "$file" 2>/dev/null |
        awk '{print $2}'
}

# ------------------------------------------------------------
# Validate package
# ------------------------------------------------------------

is_good_package() {
    local file="$1"

    [[ -f "$file" ]] || return 1

    # First: pacman metadata test
    pacman -Qp "$file" >/dev/null 2>&1 || return 1

    # Second: archive integrity
    bsdtar -tf "$file" >/dev/null 2>&1 || return 1

    # Third: zstd integrity if available
    if command -v zstd >/dev/null 2>&1; then
        zstd -t "$file" >/dev/null 2>&1 || return 1
    fi

    return 0
}

# ------------------------------------------------------------
# Find healthy copies
# ------------------------------------------------------------

declare -A SEARCH_DIRS

SEARCH_DIRS["repo"]="$REPO"
SEARCH_DIRS["cache"]="$CACHE"
SEARCH_DIRS["pacman-cache"]="/var/cache/pacman/pkg"
SEARCH_DIRS["ryoku-cache"]="/mnt/var/cache/pacman/pkg"

# Additional useful locations
POSSIBLE_DIRS=(
    "$REPO"
    "$CACHE"
    "/var/cache/pacman/pkg"
    "/mnt/var/cache/pacman/pkg"
    "/usr/share/ryoku/offline"
    "/usr/share/ryoku/offline/packages"
)

# ------------------------------------------------------------
# Find exact package by metadata
# ------------------------------------------------------------

find_replacement() {
    local bad="$1"

    local pkgname
    local pkgver

    pkgname="$(get_pkg_name "$bad")"
    pkgver="$(get_pkg_version "$bad")"

    if [[ -z "$pkgname" || -z "$pkgver" ]]; then
        echo "ERROR: Cannot read metadata:"
        echo "$bad"
        return 1
    fi

    echo
    echo "Package:"
    echo "  $bad"
    echo
    echo "Metadata:"
    echo "  Name    : $pkgname"
    echo "  Version : $pkgver"

    local dir
    local candidate
    local found=""

    for dir in "${POSSIBLE_DIRS[@]}"; do

        [[ -d "$dir" ]] || continue

        while IFS= read -r -d '' candidate; do

            [[ "$candidate" == "$bad" ]] && continue

            echo "Checking candidate:"
            echo "  $candidate"

            # Metadata must match exactly
            local cn cv

            cn="$(get_pkg_name "$candidate")"
            cv="$(get_pkg_version "$candidate")"

            if [[ "$cn" != "$pkgname" ]]; then
                continue
            fi

            if [[ "$cv" != "$pkgver" ]]; then
                continue
            fi

            echo "  Metadata matches."

            if is_good_package "$candidate"; then
                echo "  HEALTHY COPY FOUND."

                found="$candidate"
                break
            else
                echo "  Candidate is also corrupted."
            fi

        done < <(
            find "$dir" \
                -maxdepth 2 \
                -type f \
                \( -name '*.pkg.tar.zst' -o -name '*.pkg.tar.xz' -o -name '*.pkg.tar' \) \
                -print0 2>/dev/null
        )

        [[ -n "$found" ]] && break
    done

    if [[ -n "$found" ]]; then
        printf '%s\n' "$found"
        return 0
    fi

    return 1
}

# ------------------------------------------------------------
# Attempt pacman download
# ------------------------------------------------------------

download_exact_package() {

    local pkgname="$1"
    local pkgver="$2"

    local tmp
    tmp="$(mktemp -d)"

    echo
    echo "Trying pacman to obtain exact package:"
    echo "  $pkgname-$pkgver"

    # Download only. Never install.
    if pacman -Sw \
        --cachedir "$tmp" \
        --noconfirm \
        "$pkgname" >/tmp/ryoku-pacman-download.log 2>&1; then

        local candidate

        while IFS= read -r -d '' candidate; do

            local cn cv

            cn="$(get_pkg_name "$candidate")"
            cv="$(get_pkg_version "$candidate")"

            if [[ "$cn" == "$pkgname" && "$cv" == "$pkgver" ]]; then

                if is_good_package "$candidate"; then
                    echo "Downloaded exact healthy package:"
                    echo "$candidate"

                    echo "$candidate"
                    return 0
                fi
            fi

        done < <(
            find "$tmp" \
                -type f \
                -name '*.pkg.tar.*' \
                -print0 2>/dev/null
        )
    fi

    echo "Pacman could not provide exact package."
    cat /tmp/ryoku-pacman-download.log 2>/dev/null || true

    rm -rf "$tmp"

    return 1
}

# ------------------------------------------------------------
# Replace package
# ------------------------------------------------------------

replace_package() {

    local bad="$1"
    local good="$2"

    local filename

    filename="$(basename "$bad")"

    echo
    echo "Replacing:"
    echo "  BAD : $bad"
    echo "  GOOD: $good"

    # Preserve corrupted package
    mkdir -p "$BACKUP/corrupt"

    mv "$bad" "$BACKUP/corrupt/$filename"

    # Copy healthy package
    cp -a "$good" "$REPO/$filename"

    # Final validation
    if is_good_package "$REPO/$filename"; then
        echo "Replacement verified successfully."
        return 0
    fi

    echo "ERROR: Replacement failed validation."

    # Restore original
    rm -f "$REPO/$filename"

    if [[ -f "$BACKUP/corrupt/$filename" ]]; then
        mv "$BACKUP/corrupt/$filename" "$bad"
    fi

    return 1
}

# ------------------------------------------------------------
# Scan repository
# ------------------------------------------------------------

echo
echo "[2/7] Scanning repository..."

GOOD=0
BAD=0

BAD_LIST="$BACKUP/bad-packages.txt"
GOOD_LIST="$BACKUP/good-packages.txt"

: > "$BAD_LIST"
: > "$GOOD_LIST"

while IFS= read -r -d '' pkg; do

    if is_good_package "$pkg"; then
        echo "GOOD: $pkg"
        echo "$pkg" >> "$GOOD_LIST"
        ((GOOD++))
    else
        echo "BAD : $pkg"
        echo "$pkg" >> "$BAD_LIST"
        ((BAD++))
    fi

done < <(
    find "$REPO" \
        -maxdepth 1 \
        -type f \
        -name '*.pkg.tar.zst' \
        -print0
)

echo
echo "Initial state:"
echo "  Good: $GOOD"
echo "  Bad : $BAD"

# ------------------------------------------------------------
# Repair
# ------------------------------------------------------------

echo
echo "[3/7] Repairing corrupted packages..."

RECOVERED=0
FAILED=0

while IFS= read -r bad; do

    [[ -z "$bad" ]] && continue
    [[ -f "$bad" ]] || continue

    echo
    echo "------------------------------------------------------------"

    pkgname="$(get_pkg_name "$bad")"
    pkgver="$(get_pkg_version "$bad")"

    if [[ -z "$pkgname" || -z "$pkgver" ]]; then
        echo "Cannot read package metadata."
        echo "Trying filename fallback."

        filename="$(basename "$bad")"

        # Remove .pkg.tar.zst
        base="${filename%.pkg.tar.zst}"

        # Arch package filenames are:
        # name-version-arch
        #
        # Instead of manually splitting version,
        # search all local packages and compare filename metadata.
        pkgname=""
        pkgver=""
    else
        echo "Detected:"
        echo "  Name    : $pkgname"
        echo "  Version : $pkgver"
    fi

    replacement=""

    if [[ -n "$pkgname" && -n "$pkgver" ]]; then

        replacement="$(find_replacement "$bad" 2>/dev/null | tail -n 1)" || true

    fi

    # --------------------------------------------------------
    # If no local copy: download exact package
    # --------------------------------------------------------

    if [[ -z "$replacement" && -n "$pkgname" && -n "$pkgver" ]]; then

        replacement="$(download_exact_package "$pkgname" "$pkgver" 2>/dev/null | tail -n 1)" || true

    fi

    # --------------------------------------------------------
    # Replace
    # --------------------------------------------------------

    if [[ -n "$replacement" && -f "$replacement" ]]; then

        if replace_package "$bad" "$replacement"; then
            ((RECOVERED++))
        else
            ((FAILED++))
        fi

    else

        echo
        echo "FAILED: No healthy replacement available."
        echo "Original package was NOT touched."

        ((FAILED++))
    fi

done < "$BAD_LIST"

echo
echo "Repair phase complete."
echo "Recovered: $RECOVERED"
echo "Failed   : $FAILED"

# ------------------------------------------------------------
# Re-scan
# ------------------------------------------------------------

echo
echo "[4/7] Rechecking repository..."

FINAL_GOOD=0
FINAL_BAD=0

FINAL_BAD_LIST="$BACKUP/final-bad-packages.txt"

: > "$FINAL_BAD_LIST"

while IFS= read -r -d '' pkg; do

    if is_good_package "$pkg"; then
        ((FINAL_GOOD++))
    else
        echo "STILL BAD:"
        echo "$pkg"

        echo "$pkg" >> "$FINAL_BAD_LIST"

        ((FINAL_BAD++))
    fi

done < <(
    find "$REPO" \
        -maxdepth 1 \
        -type f \
        -name '*.pkg.tar.zst' \
        -print0
)

# ------------------------------------------------------------
# Repository database
# ------------------------------------------------------------

echo
echo "[5/7] Checking repository database lock..."

if [[ -e "$LOCK" ]]; then

    if pgrep -x pacman >/dev/null || \
       pgrep -x repo-add >/dev/null; then

        echo "ERROR: repository is currently locked."
        echo "Database will NOT be rebuilt."
        exit 1
    fi

    echo "Removing stale lock."
    mv "$LOCK" "$BACKUP/" 2>/dev/null || rm -f "$LOCK"
fi

# ------------------------------------------------------------
# Rebuild database ONLY if all packages are healthy
# ------------------------------------------------------------

if [[ "$FINAL_BAD" -eq 0 ]]; then

    echo
    echo "[6/7] Rebuilding repository database..."

    # Remove old database files
    rm -f \
        "$REPO/ryoku.db" \
        "$REPO/ryoku.db.tar.gz" \
        "$REPO/ryoku.files" \
        "$REPO/ryoku.files.tar.gz"

    repo-add \
        "$REPO/ryoku.db.tar.gz" \
        "$REPO"/*.pkg.tar.zst

    if [[ $? -eq 0 ]]; then
        echo
        echo "Repository database rebuilt successfully."
    else
        echo
        echo "ERROR: repo-add failed."
        echo "Backup:"
        echo "$BACKUP/repo"
        exit 1
    fi

else

    echo
    echo "WARNING:"
    echo "$FINAL_BAD package(s) are still corrupted."

    echo "Repository database will NOT be rebuilt."
fi

# ------------------------------------------------------------
# Final report
# ------------------------------------------------------------

echo
echo "[7/7] Final report"

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
echo
echo "Final:"
echo "  Good : $FINAL_GOOD"
echo "  Bad  : $FINAL_BAD"
echo
echo "Backup:"
echo "  $BACKUP"
echo
echo "Bad package list:"
echo "  $FINAL_BAD_LIST"
echo
echo "Log:"
echo "  $LOG"
echo