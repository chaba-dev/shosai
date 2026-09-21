#!/usr/bin/env bash
#
# Flutter render harness runner (restoration package 2B).
#
# Runs the production-shell render tests, writes their artifacts (renders plus
# metadata) to an owned directory, and by default repeats the run to prove that
# render outputs are byte-identical across runs.
#
# Usage:
#   scripts/flutter-render-harness.sh [--runs N] [--output DIR] [--test PATH]
#
# Options:
#   --runs N       number of runs to compare (default 2, use 1 to skip the
#                  reproducibility comparison)
#   --output DIR   artifact root (default target/flutter-render-harness)
#   --test PATH    test path relative to flutter/ (default test/visual)
#
# Exit codes: 0 pass (and identical across runs), 1 failure or drift.

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
flutter_dir="$root/flutter"
runs=2
output="$root/target/flutter-render-harness"
test_path="test/visual"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --runs)
      [[ "${2:-}" =~ ^[0-9]+$ && "${2:-}" -gt 0 ]] || {
        echo "--runs needs a positive integer" >&2
        exit 2
      }
      runs="$2"
      shift 2
      ;;
    --output)
      [[ -n "${2:-}" ]] || { echo "--output needs a directory" >&2; exit 2; }
      output="$2"
      shift 2
      ;;
    --test)
      [[ -n "${2:-}" ]] || { echo "--test needs a path" >&2; exit 2; }
      test_path="$2"
      shift 2
      ;;
    -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

revision=""
if command -v jj >/dev/null 2>&1; then
  revision="$(jj log -r @ --no-graph -T commit_id 2>/dev/null || true)"
fi
[[ -n "$revision" ]] || revision="unknown"

# Resolve the artifact root, because the tests run from the Flutter package
# directory and a relative path would resolve differently there.
if [[ "$output" != /* ]]; then
  output="$root/$output"
fi

mkdir -p "$output"
status=0

manifest() {
  local dir="$1"
  (cd "$dir" && sha256sum ./*.png 2>/dev/null | sort)
}

for (( run = 1; run <= runs; run += 1 )); do
  dir="$output/run$run"
  rm -rf "$dir"
  mkdir -p "$dir"
  echo "== run $run: flutter test $test_path (artifacts in $dir)"
  (
    cd "$flutter_dir" || exit 1
    SHOSAI_HARNESS_ARTIFACTS="$dir" \
    SHOSAI_HARNESS_REVISION="$revision" \
      flutter test "$test_path"
  )
  run_status=$?
  if (( run_status != 0 )); then
    echo "run $run failed with status $run_status" >&2
    status=1
  fi
  manifest "$dir" > "$dir/manifest.sha256"
  echo "artifacts: $(wc -l < "$dir/manifest.sha256") renders"
done

if (( runs > 1 )); then
  for (( run = 2; run <= runs; run += 1 )); do
    if [[ ! -s "$output/run1/manifest.sha256" || ! -s "$output/run$run/manifest.sha256" ]]; then
      echo "NOT reproducible: a run captured no renders" >&2
      status=1
    elif ! diff -u "$output/run1/manifest.sha256" "$output/run$run/manifest.sha256" \
        > "$output/manifest.diff"; then
      echo "NOT reproducible: run $run differs from run 1" >&2
      cat "$output/manifest.diff" >&2
      status=1
    fi
  done
  if (( status == 0 )); then
    echo "reproducible: all $runs runs passed and produced identical hashes"
    rm -f "$output/manifest.diff"
  fi
fi

exit "$status"
