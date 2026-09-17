#!/usr/bin/env bash

set -u

DIR="${1:-.}"

echo "Checking .pkg.tar.zst files in: $DIR"
echo

total=0
ok=0
bad=0

for file in "$DIR"/*.pkg.tar.zst; do

    [[ -e "$file" ]] || continue

    ((total++))

    name="$(basename "$file")"
    printf "[CHECK] %-60s " "$name"

    if ! zstd -t "$file" >/dev/null 2>&1; then
        echo "CORRUPTED (zstd)"
        ((bad++))
        continue
    fi

    if ! tar -tf "$file" >/dev/null 2>&1; then
        echo "CORRUPTED (tar)"
        ((bad++))
        continue
    fi

    echo "OK"
    ((ok++))
done

echo
echo "========================================"
echo "Total : $total"
echo "OK    : $ok"
echo "Bad   : $bad"
echo "========================================"

if (( bad > 0 )); then
    exit 1
else
    exit 0
fi