#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
samples=${1:-50}
fixtures="$root/target/epub-perf-fixtures"
results="$root/target/epub-perf-results"
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
log="$results/$timestamp.log"

mkdir -p "$results"
python3 "$root/scripts/generate-epub-perf-fixtures.py" "$fixtures" >/dev/null
cargo build --release -p shosai-app

{
  printf 'perf-host timestamp=%s\n' "$timestamp"
  printf 'perf-host uname=%q\n' "$(uname -a)"
  printf 'perf-host rustc=%q\n' "$(rustc --version)"
  if command -v system_profiler >/dev/null 2>&1; then
    system_profiler SPHardwareDataType 2>/dev/null \
      | sed -nE 's/^[[:space:]]+(Model Name|Model Identifier|Chip|Memory):[[:space:]]*/perf-host \1=/p'
  fi
} | tee "$log"

run() {
  local fixture=$1
  local action=$2
  local width=$3
  printf '\nperf-run fixture=%s action=%s width=%s\n' "$(basename "$fixture")" "$action" "$width" | tee -a "$log"
  SHOSAI_PERF_FILE="$fixture" \
    SHOSAI_PERF_ACTION="$action" \
    SHOSAI_PERF_SAMPLES="$samples" \
    SHOSAI_PERF_WIDTH="$width" \
    "$root/target/release/shosai" 2>&1 | tee -a "$log"
}

# The checked-in sample is intentionally small, so it covers chapter transitions
# and relayout. Generated fixtures add stable warm-turn pairs and text/image load.
for width in 700 1000; do
  run "$root/crates/shosai-core/tests/fixtures/sample.epub" chapter "$width"
  run "$root/crates/shosai-core/tests/fixtures/sample.epub" relayout "$width"
  for fixture in "$fixtures/large-text.epub" "$fixtures/large-image.epub"; do
    run "$fixture" warm "$width"
    run "$fixture" chapter "$width"
    run "$fixture" relayout "$width"
  done
done

python3 "$root/scripts/validate_epub_perf_results.py" "$log" "$samples"
printf '\nSummaries written to %s\n' "$log"
rg '^perf-(config|summary)' "$log"
