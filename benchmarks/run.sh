#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
POPCORN="${POPCORN:-$ROOT/zig-out/bin/popcorn}"
NODE_BIN="${NODE_BIN:-node}"
ITERATIONS="${1:-5}"

if [ ! -x "$POPCORN" ]; then
  echo "Popcorn binary not found/executable: $POPCORN"
  echo "Build first with: zig build"
  exit 1
fi

if ! command -v "$NODE_BIN" >/dev/null 2>&1; then
  echo "Node.js not found. Set NODE_BIN or install node."
  exit 1
fi

if ! command -v /usr/bin/time >/dev/null 2>&1; then
  echo "Missing /usr/bin/time"
  exit 1
fi

run_timed() {
  local label="$1"
  local runtime="$2"
  local program="$3"
  local times=""

  for i in $(seq 1 "$ITERATIONS"); do
    local t
    t=$({ /usr/bin/time -p "$runtime" "$program" >/dev/null; } 2>&1 | awk '/^real / {print $2}')
    times="$times $t"
    printf "  %-18s run %d/%d: %ss\n" "$label" "$i" "$ITERATIONS" "$t" >&2
  done

  echo "$times" | awk '{s=0; for(i=1;i<=NF;i++) s+=$i; if(NF>0) printf "%.6f", s/NF; else print "nan"}'
}

compare_pair() {
  local name="$1"
  local pop_file="$2"
  local js_file="$3"

  echo ""
  echo "== $name =="

  local pop_out
  local js_out
  pop_out=$("$POPCORN" "$pop_file")
  js_out=$("$NODE_BIN" "$js_file")

  if [ "$pop_out" != "$js_out" ]; then
    echo "Output mismatch for $name"
    echo "  Popcorn: $pop_out"
    echo "  JS:      $js_out"
    exit 1
  fi

  local pop_avg
  local js_avg
  pop_avg=$(run_timed "Popcorn" "$POPCORN" "$pop_file")
  js_avg=$(run_timed "JavaScript" "$NODE_BIN" "$js_file")

  local ratio
  ratio=$(awk -v p="$pop_avg" -v j="$js_avg" 'BEGIN { if (j == 0) print "inf"; else printf "%.2f", p/j }')

  echo "  Output: $pop_out"
  echo "  Avg Popcorn:    ${pop_avg}s"
  echo "  Avg JavaScript: ${js_avg}s"
  echo "  Ratio (Pop/JS): ${ratio}x"
}

compare_pair "Recursive Fibonacci" "$SCRIPT_DIR/fib.pop" "$SCRIPT_DIR/fib.js"
compare_pair "Loop Sum" "$SCRIPT_DIR/loop_sum.pop" "$SCRIPT_DIR/loop_sum.js"
