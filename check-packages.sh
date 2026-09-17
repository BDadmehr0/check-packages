#!/usr/bin/env bash

set -u

DIR="${1:-.}"
BAD_FILE="$DIR/bad.txt"

# فایل قبلی را پاک می‌کنیم
: > "$BAD_FILE"

total=0
ok=0
bad=0

echo "Checking .pkg.tar.zst files in: $DIR"
echo

for file in "$DIR"/*.pkg.tar.zst; do
    [[ -e "$file" ]] || continue

    ((total++))

    name="$(basename "$file")"
    printf "[CHECK] %-60s " "$name"

    # تست Zstandard
    if ! zstd -t "$file" >/dev/null 2>&1; then
        echo "CORRUPTED"
        echo "$file" >> "$BAD_FILE"
        ((bad++))
        continue
    fi

    # تست TAR
    if ! tar -tf "$file" >/dev/null 2>&1; then
        echo "CORRUPTED"
        echo "$file" >> "$BAD_FILE"
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
    echo
    echo "Corrupted files saved to:"
    echo "$BAD_FILE"
fi

exit $(( bad > 0 ? 1 : 0 ))