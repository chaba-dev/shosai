#!/bin/sh
set -eu

# DART_DEFINES comes from Flutter's generated xcconfig and can be stale when
# building directly in Xcode. The prefix encodes `SHOSAI_PRODUCTION=` and ends
# on a Base64 group boundary, so it also matches other values of that key.
dart_edition=dev
seen=no
IFS=,
set -f
for define in ${DART_DEFINES:-}; do
  case "$define" in
    U0hPU0FJX1BST0RVQ1RJT049*)
      if [ "$seen" = yes ]; then
        echo 'error: SHOSAI_PRODUCTION must only be defined once.' >&2
        exit 1
      fi
      seen=yes
      if [ "$define" = U0hPU0FJX1BST0RVQ1RJT049dHJ1ZQ== ]; then
        dart_edition=production
      fi
      ;;
  esac
done

case "${PRODUCT_BUNDLE_IDENTIFIER:-}:$dart_edition" in
  dev.shosai.reader:production) exit 0 ;;
  dev.shosai.reader:dev|:dev) ;;
  *:dev) exit 0 ;;  # Lab builds can override the development bundle ID.
esac

echo 'error: Shōsai bundle ID and Flutter edition disagree. Rebuild with Flutter for Dev or use the documented production target to regenerate the settings.' >&2
exit 1
