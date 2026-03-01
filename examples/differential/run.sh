#!/usr/bin/env bash
# Differential test runner:
# Compares interpreter mode (POPCORN_VM=0) and VM mode (POPCORN_VM=1)
# for all example programs. A test passes only if exit code and combined
# stdout/stderr are identical.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
POPCORN="$ROOT/zig-out/bin/popcorn"

if [ ! -x "$POPCORN" ]; then
    echo "Missing executable: $POPCORN"
    echo "Run 'zig build' first."
    exit 1
fi

PASS=0
FAIL=0

run_mode() {
    local mode="$1"
    local file="$2"
    local out_var="$3"
    local status_var="$4"

    local output
    local status

    set +e
    output=$(POPCORN_VM="$mode" "$POPCORN" "$file" 2>&1)
    status=$?
    set -e

    printf -v "$out_var" "%s" "$output"
    printf -v "$status_var" "%s" "$status"
}

while IFS= read -r -d '' file; do
    name="${file#"$ROOT/"}"

    interp_out=""
    interp_status=0
    vm_out=""
    vm_status=0

    run_mode 0 "$file" interp_out interp_status
    run_mode 1 "$file" vm_out vm_status

    if [ "$interp_status" -eq "$vm_status" ] && [ "$interp_out" = "$vm_out" ]; then
        printf "  PASS  %s\n" "$name"
        PASS=$((PASS + 1))
        continue
    fi

    printf "  FAIL  %s\n" "$name"
    printf "        interpreter exit: %s\n" "$interp_status"
    printf "        vm exit:          %s\n" "$vm_status"

    interp_tmp="$(mktemp)"
    vm_tmp="$(mktemp)"
    printf "%s\n" "$interp_out" > "$interp_tmp"
    printf "%s\n" "$vm_out" > "$vm_tmp"
    echo "        output diff:"
    set +e
    diff -u "$interp_tmp" "$vm_tmp"
    set -e
    rm -f "$interp_tmp" "$vm_tmp"

    FAIL=$((FAIL + 1))
done < <(find "$ROOT/examples" -type f -name '*.pop' -print0 | sort -z)

echo ""
echo "$((PASS + FAIL)) tests, $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
