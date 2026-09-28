#!/usr/bin/env bash
# Build the prototype as a Linux release bundle and run the measurement
# harness under Xvfb.
#
# Usage (from the repository root, inside the dev shell):
#   .agents/dev bash prototypes/epub-dart-eval/tool/measure.sh
#
# Environment:
#   SHOSAI_MEASURE_TRIALS  warm navigation/relayout trials per book (default 5)
#   SHOSAI_MEASURE_BOOKS   comma-separated EPUB paths (default: the prototype's
#                          rich and long fixtures)
#   SHOSAI_MEASURE_OUT     JSON output path (default:
#                          artifacts/measurements/measure-<timestamp>.json)
#   SHOSAI_MEASURE_SKIP_BUILD  set to 1 to reuse an existing release bundle
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$here"

trials="${SHOSAI_MEASURE_TRIALS:-5}"
books="${SHOSAI_MEASURE_BOOKS:-$here/fixtures/rich-chapter.epub,$here/fixtures/long-chapter.epub}"
out="${SHOSAI_MEASURE_OUT:-$here/artifacts/measurements/measure-$(date -u +%Y%m%dT%H%M%SZ).json}"

mkdir -p "$(dirname "$out")"

if [[ "${SHOSAI_MEASURE_SKIP_BUILD:-0}" != "1" ]]; then
  flutter build linux --release -t lib/measure_main.dart
fi

bundle="build/linux/x64/release/bundle/shosai_epub_eval"
if [[ ! -x "$bundle" ]]; then
  echo "release bundle not found: $bundle" >&2
  exit 1
fi

display_number=99
while [[ -e "/tmp/.X${display_number}-lock" ]]; do
  display_number=$((display_number + 1))
done
Xvfb ":${display_number}" -screen 0 1440x900x24 -nolisten tcp &
xvfb_pid=$!
trap 'kill "$xvfb_pid" 2>/dev/null || true' EXIT
sleep 1

echo "books: $books"
echo "out:   $out"
SHOSAI_MEASURE_BOOKS="$books" \
SHOSAI_MEASURE_OUT="$out" \
SHOSAI_MEASURE_TRIALS="$trials" \
SHOSAI_MEASURE_SPINES="${SHOSAI_MEASURE_SPINES:-}" \
SHOSAI_MEASURE_LAYOUT="${SHOSAI_MEASURE_LAYOUT:-progressive}" \
SHOSAI_MEASURE_LAYOUT_CACHE="${SHOSAI_MEASURE_LAYOUT_CACHE:-2}" \
DISPLAY=":${display_number}" \
  "$bundle" >"$out.log" 2>&1

echo "wrote $out (raw log: $out.log)"
