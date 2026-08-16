#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <version> <architecture> <archive>" >&2
  exit 2
fi

version=${1#v}
architecture=$2
archive=$3

case "$architecture" in
  x86_64) binary_architecture="x86_64" ;;
  aarch64) binary_architecture="arm64" ;;
  *)
    echo "unsupported macOS architecture: $architecture" >&2
    exit 2
    ;;
esac

if [[ ! -f "$archive" ]]; then
  echo "package archive not found: $archive" >&2
  exit 1
fi

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

while IFS= read -r entry; do
  if [[ "$entry" != "Shosai.app" && "$entry" != "Shosai.app/"* ]] ||
    [[ "$entry" == *"/../"* || "$entry" == *"/.." ]]; then
    echo "unsafe or unexpected archive entry: $entry" >&2
    exit 1
  fi
done < <(unzip -Z1 "$archive")

ditto -x -k "$archive" "$work_dir"
app="$work_dir/Shosai.app"
contents="$app/Contents"
binary="$contents/MacOS/Shosai"
pdfium="$contents/Frameworks/libpdfium.dylib"
info_plist="$contents/Info.plist"

test -x "$binary"
test -x "$pdfium"
test -s "$contents/Resources/LICENSE"
test -s "$contents/Resources/PDFIUM-LICENSE"
test -s "$contents/Resources/Shosai.icns"

test "$(lipo -archs "$binary")" = "$binary_architecture"
test "$(lipo -archs "$pdfium")" = "$binary_architecture"

plutil -lint "$info_plist"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")" = \
  "io.github.chaba2.shosai"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info_plist")" = "Shosai"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$info_plist")" = "Shosai"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")" = \
  "$version"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_plist")" = "$version"
test "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$info_plist")" = "12.0"

codesign --verify --deep --strict --verbose=2 "$app"

printf 'Validated %s\n' "$archive"
