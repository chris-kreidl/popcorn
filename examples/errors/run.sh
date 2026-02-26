#!/usr/bin/env bash
# Runs each .pop file in examples/errors/ and checks that its output
# contains the expected error string from the first line comment.
#
# First line format: // Expected error: <substring>
# The test passes if stderr+stdout contains that substring.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
POPCORN="$ROOT/zig-out/bin/popcorn"
PASS=0
FAIL=0

for file in "$SCRIPT_DIR"/*.pop; do
    # Extract expected error from first line
    expected=$(head -1 "$file" | sed 's|^// Expected error: ||')

    # Run and capture combined output (interpreter prints errors to stderr)
    output=$("$POPCORN" "$file" 2>&1 || true)

    name=$(basename "$file")
    if echo "$output" | grep -qi "$expected"; then
        printf "  PASS  %s\n" "$name"
        PASS=$((PASS + 1))
    else
        printf "  FAIL  %s\n" "$name"
        printf "        expected: %s\n" "$expected"
        printf "        got:      %s\n" "$output"
        FAIL=$((FAIL + 1))
    fi
done

echo ""
echo "$((PASS + FAIL)) tests, $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
