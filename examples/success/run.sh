#!/usr/bin/env bash
# Runs each .pop file in examples/success/ and checks that:
# 1) output contains the expected substring from the first line comment
# 2) process exits with status 0
#
# First line format: // Expected output: <substring>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
POPCORN="$ROOT/zig-out/bin/popcorn"
PASS=0
FAIL=0

for file in "$SCRIPT_DIR"/*.pop; do
    first_line=$(head -1 "$file")
    expected="${first_line#// Expected output: }"
    if [ "$expected" = "$first_line" ]; then
        expected=""
    fi

    set +e
    output=$("$POPCORN" "$file" 2>&1)
    status=$?
    set -e

    name=$(basename "$file")
    if [ -n "$expected" ] && echo "$output" | grep -qiF "$expected" && [ "$status" -eq 0 ]; then
        printf "  PASS  %s\n" "$name"
        PASS=$((PASS + 1))
    else
        printf "  FAIL  %s\n" "$name"
        printf "        expected: %s\n" "$expected"
        printf "        exit:     %s (expected 0)\n" "$status"
        printf "        got:      %s\n" "$output"
        FAIL=$((FAIL + 1))
    fi
done

echo ""
echo "$((PASS + FAIL)) tests, $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
