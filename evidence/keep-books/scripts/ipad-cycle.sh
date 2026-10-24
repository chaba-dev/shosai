#!/usr/bin/env bash
# Keep-books evidence on the iPad with the fixed build. Installs over the app only; never uninstalls.
set -uo pipefail
D=3CAD788D-9574-5EEE-83F1-DF624DD99973
B=dev.shosai.shosai-flutter
APP=/tmp/kb-apps/fixed-ios-profile.app
E=/tmp/claude-501/keep-books-evidence/ipad-fixed
URLS="alice.epub=https://www.gutenberg.org/ebooks/11.epub3.images,attention.pdf=https://arxiv.org/pdf/1706.03762"
mkdir -p "$E/db"
L=$E/log.txt
touch "$L"

# devicectl prints the data container path when asked to copy ".".
container() {
  xcrun devicectl device copy from --device $D --domain-type appDataContainer --domain-identifier $B \
    --source . --destination /tmp/kb-tools/none 2>&1 | grep -o '/private/var/mobile/Containers/Data/Application/[A-F0-9-]*' | head -1
}
state() { # label
  echo "  container: $(container)" >> "$L"
  echo "  books dir: $(xcrun devicectl device info files --device $D --domain-type appDataContainer --domain-identifier $B 2>/dev/null \
    | grep -oE 'Library/Application Support/books/[0-9a-f]{64}\.[a-z]+' | sed 's#.*/##' | tr '\n' ' ')" >> "$L"
}
install_launch() { # n
  echo "== install-over #$1: real fixed app (devicectl device install app)" >> "$L"
  xcrun devicectl device install app --device $D "$APP" 2>&1 | grep -E "App installed|ERROR|rror" >> "$L"
  xcrun devicectl device process launch --device $D --terminate-existing $B 2>&1 | grep -E "Launched|ERROR|rror|ocked" >> "$L"
  sleep 15
  echo "  launched the real app; state after launch:" >> "$L"
  state "install-$1"
}
harness() { # mode label
  echo "== flutter drive --profile --keep-app-running harness (fixed code, mode $1) = install over" >> "$L"
  (cd /tmp/kb-fixed/flutter && KEEP_BOOKS_OUT=$E /tmp/kb-tools/flutter drive --profile --keep-app-running --device-timeout 30 -d 00008103-001430EE0E68801E \
    --driver integration_test/keep_books_driver.dart --target integration_test/keep_books_test.dart \
    --dart-define=KEEP_BOOKS_MODE=$1 --dart-define=KEEP_BOOKS_LABEL=$2 "--dart-define=KEEP_BOOKS_URLS=$URLS" 2>&1 \
    | grep -E "^flutter: KEEP_BOOKS|All tests|Some tests|Error|rror" | sed 's/^flutter: KEEP_BOOKS /  /' >> "$L")
  state "$2"
}

step=${1:-all}
case $step in
  pre) echo "== before any install (current app on the iPad)" >> "$L"; state pre ;;
  i1) install_launch 1 ;;
  seed) harness seed h1-seed ;;
  i2) install_launch 2 ;;
  c1) harness check h2-check ;;
  i3) install_launch 3 ;;
  c2) harness check h3-check ;;
  i4) install_launch 4 ;;
esac
