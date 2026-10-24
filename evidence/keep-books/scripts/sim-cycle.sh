#!/usr/bin/env bash
# Keep-books evidence on the iOS Simulator for one build variant (before|fixed).
set -uo pipefail
variant=$1
S=0B527891-4877-4FAC-A6A2-430E92318C3E
B=dev.shosai.shosai-flutter
APP=/tmp/kb-apps/$variant-sim.app
E=/tmp/claude-501/keep-books-evidence/sim-$variant
URLS="alice.epub=https://www.gutenberg.org/ebooks/11.epub3.images,attention.pdf=https://arxiv.org/pdf/1706.03762"
mkdir -p "$E"
L=$E/log.txt
: > "$L"

container() { xcrun simctl get_app_container $S $B data 2>&1; }
books() { echo "  books dir: $(ls "$(container)/Library/Application Support/books" 2>&1 | tr '\n' ' ')" >> "$L"; }
harness() { # mode label
  echo "== flutter drive harness ($variant code, mode $1) = install over" >> "$L"
  (cd /tmp/kb-$variant/flutter && KEEP_BOOKS_OUT=$E /tmp/kb-tools/flutter drive --keep-app-running -d $S \
    --driver integration_test/keep_books_driver.dart --target integration_test/keep_books_test.dart \
    --dart-define=KEEP_BOOKS_MODE=$1 --dart-define=KEEP_BOOKS_LABEL=$2 "--dart-define=KEEP_BOOKS_URLS=$URLS" 2>&1 \
    | grep -E "^flutter: KEEP_BOOKS|All tests|Some tests|Error" | sed 's/^flutter: KEEP_BOOKS /  /' >> "$L")
  echo "  container after: $(container)" >> "$L"
  xcrun simctl terminate $S $B 2>/dev/null
}
app_install_launch() { # n
  xcrun simctl install $S "$APP"
  echo "== install-over #$1 of the real $variant app (simctl install)" >> "$L"
  echo "  container: $(container)" >> "$L"; books
  xcrun simctl launch $S $B >/dev/null
  sleep 15
  xcrun simctl io $S screenshot "$E/$2.png" >/dev/null 2>&1
  echo "  launched; screenshot $2.png" >> "$L"; books
  xcrun simctl terminate $S $B 2>/dev/null
  sleep 2
}

# Simulator only: start from an empty app so only this run's books are in the library.
xcrun simctl uninstall $S $B 2>/dev/null
xcrun simctl install $S "$APP"
echo "== fresh install of the real $variant app: $(container)" >> "$L"
harness seed s0-seed
app_install_launch 1 s1-app-after-install-over-1
harness check s1-check
app_install_launch 2 s2-app-after-install-over-2
xcrun simctl io $S recordVideo --codec=h264 --force "$E/s2-check-video.mp4" >/dev/null 2>&1 &
rec=$!
sleep 2
harness check s2-check
kill -INT $rec; wait $rec
app_install_launch 3 s3-app-after-install-over-3
cat "$L"
