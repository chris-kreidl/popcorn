#!/usr/bin/env bash
# Runs each .pop file in examples/errors/ and checks that:
# 1) output contains the expected error string from the first line comment
# 2) process exits with a non-zero status
#
# First line format: // Expected error: <substring>
# The test passes if stderr+stdout contains that substring and exit status != 0.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
POPCORN="$ROOT/zig-out/bin/popcorn"
PASS=0
FAIL=0

for file in "$SCRIPT_DIR"/*.pop; do
    # Extract expected error from first line (must match prefix exactly)
    first_line=$(head -1 "$file")
    expected="${first_line#// Expected error: }"
    if [ "$expected" = "$first_line" ]; then
        expected=""
    fi

    # Run and capture combined output (interpreter prints errors to stderr)
    set +e
    output=$("$POPCORN" "$file" 2>&1)
    status=$?
    set -e

    name=$(basename "$file")
    if [ -n "$expected" ] && echo "$output" | grep -qiF "$expected" && [ "$status" -ne 0 ]; then
        printf "  PASS  %s\n" "$name"
        PASS=$((PASS + 1))
    else
        printf "  FAIL  %s\n" "$name"
        printf "        expected: %s\n" "$expected"
        printf "        exit:     %s (expected non-zero)\n" "$status"
        printf "        got:      %s\n" "$output"
        FAIL=$((FAIL + 1))
    fi
done

# Also verify one known-good program exits successfully.
success_file="$ROOT/examples/hello.pop"
set +e
success_output=$("$POPCORN" "$success_file" 2>&1)
success_status=$?
set -e

if [ "$success_status" -eq 0 ]; then
    printf "  PASS  %s\n" "$(basename "$success_file")"
    PASS=$((PASS + 1))
else
    printf "  FAIL  %s\n" "$(basename "$success_file")"
    printf "        exit:     %s (expected 0)\n" "$success_status"
    printf "        got:      %s\n" "$success_output"
    FAIL=$((FAIL + 1))
fi

echo ""
echo "$((PASS + FAIL)) tests, $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
