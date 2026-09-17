#!/usr/bin/env bash

set -u

REPO_DIR="${1:-/usr/share/ryoku/offline}"
REPORT="${REPO_DIR}/offline-repo-report.txt"
BAD="${REPO_DIR}/bad-packages.txt"
GOOD="${REPO_DIR}/good-packages.txt"

mkdir -p "$REPO_DIR"

: > "$REPORT"
: > "$BAD"
: > "$GOOD"

echo "========================================" | tee -a "$REPORT"
echo " Ryoku Offline Repository Checker"       | tee -a "$REPORT"
echo "========================================" | tee -a "$REPORT"
echo "Repository: $REPO_DIR"                  | tee -a "$REPORT"
echo "Started:    $(date)"                    | tee -a "$REPORT"
echo | tee -a "$REPORT"

mapfile -t PACKAGES < <(
    find "$REPO_DIR" -type f -name '*.pkg.tar.zst' -print
)

TOTAL=${#PACKAGES[@]}
GOOD_COUNT=0
BAD_COUNT=0

echo "Found $TOTAL package files." | tee -a "$REPORT"
echo | tee -a "$REPORT"

for pkg in "${PACKAGES[@]}"; do
    name="$(basename "$pkg")"

    printf '[CHECK] %-80s' "$name"

    if zstd -t "$pkg" >/dev/null 2>&1; then

        # Ask pacman to validate the package archive.
        if pacman -Qp "$pkg" >/dev/null 2>&1; then
            echo " OK"
            echo "$pkg" >> "$GOOD"
            ((GOOD_COUNT++))
        else
            echo " BAD (pacman)"
            echo "$pkg" >> "$BAD"
            echo "$name : pacman rejected package" >> "$REPORT"
            ((BAD_COUNT++))
        fi

    else
        echo " BAD (zstd)"
        echo "$pkg" >> "$BAD"
        echo "$name : invalid/truncated zstd archive" >> "$REPORT"
        ((BAD_COUNT++))
    fi
done

echo | tee -a "$REPORT"
echo "========================================" | tee -a "$REPORT"
echo "Result"                                  | tee -a "$REPORT"
echo "========================================" | tee -a "$REPORT"
echo "Total : $TOTAL"                          | tee -a "$REPORT"
echo "Good  : $GOOD_COUNT"                     | tee -a "$REPORT"
echo "Bad   : $BAD_COUNT"                      | tee -a "$REPORT"
echo | tee -a "$REPORT"

echo "Good packages: $GOOD"
echo "Bad packages : $BAD"
echo "Full report  : $REPORT"