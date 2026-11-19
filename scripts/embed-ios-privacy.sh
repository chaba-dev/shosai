#!/bin/sh
set -eu

# Run after both Flutter native assets and CocoaPods frameworks are embedded.
# Adding resources changes a framework seal, so re-sign before Runner signs.
for name in sqlite3 PDFium; do
  framework="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/$name.framework"
  source="$SRCROOT/Privacy/$name.xcprivacy"
  if [ ! -d "$framework" ]; then
    echo "error: missing $framework; cannot package its privacy manifest" >&2
    exit 1
  fi
  plutil -lint "$source"
  cp "$source" "$framework/PrivacyInfo.xcprivacy"
  if [ "${CODE_SIGNING_ALLOWED:-NO}" = YES ]; then
    identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
    [ -n "$identity" ] || identity=-
    /usr/bin/codesign --force --sign "$identity" --timestamp=none \
      --preserve-metadata=identifier,entitlements,flags "$framework"
    /usr/bin/codesign --verify --strict "$framework"
  fi
done
