#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <version> <architecture> <archive>" >&2
  exit 2
fi

version=${1#v}
architecture=$2
archive=$3
plist_buddy=${PLIST_BUDDY:-/usr/libexec/PlistBuddy}

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
invalid_entries=$(find "$app" ! -type f ! -type d -print)
if [[ -n "$invalid_entries" ]]; then
  printf 'unsupported package entry type:\n%s\n' "$invalid_entries" >&2
  exit 1
fi

contents="$app/Contents"
binary="$contents/MacOS/Shosai"
pdfium="$contents/Frameworks/libpdfium.dylib"
info_plist="$contents/Info.plist"

test -x "$binary"
test -x "$pdfium"
test -s "$contents/Resources/LICENSE"
test -s "$contents/Resources/INTER-LICENSE"
test -s "$contents/Resources/PDFIUM-LICENSE"
test -s "$contents/Resources/Shosai.icns"

test "$(lipo -archs "$binary")" = "$binary_architecture"
test "$(lipo -archs "$pdfium")" = "$binary_architecture"

plutil -lint "$info_plist"
test "$("$plist_buddy" -c 'Print :CFBundleIdentifier' "$info_plist")" = \
  "io.github.chaba2.shosai"
test "$("$plist_buddy" -c 'Print :CFBundleExecutable' "$info_plist")" = "Shosai"
test "$("$plist_buddy" -c 'Print :CFBundleIconFile' "$info_plist")" = "Shosai"
test "$("$plist_buddy" -c 'Print :CFBundleShortVersionString' "$info_plist")" = \
  "$version"
test "$("$plist_buddy" -c 'Print :CFBundleVersion' "$info_plist")" = "$version"
minimum_system_version=$("$plist_buddy" -c 'Print :LSMinimumSystemVersion' "$info_plist")
test "$minimum_system_version" = "12.0"

macho_minimum_version() {
  otool -l "$1" | awk '
    $1 == "cmd" { build_version = ($2 == "LC_BUILD_VERSION"); legacy_version = ($2 == "LC_VERSION_MIN_MACOSX") }
    build_version && $1 == "minos" { print $2; exit }
    legacy_version && $1 == "version" { print $2; exit }
  '
}

version_is_greater() {
  awk -v actual="$1" -v declared="$2" 'BEGIN {
    split(actual, left, "."); split(declared, right, ".")
    for (part = 1; part <= 4; part++) {
      if ((left[part] + 0) > (right[part] + 0)) exit 0
      if ((left[part] + 0) < (right[part] + 0)) exit 1
    }
    exit 1
  }'
}

check_macho_portability() {
  local label=$1
  local macho=$2
  local minimum
  minimum=$(macho_minimum_version "$macho")
  if [[ -z "$minimum" ]]; then
    echo "cannot determine minimum macOS version for $label" >&2
    exit 1
  fi
  if version_is_greater "$minimum" "$minimum_system_version"; then
    echo "$label requires macOS $minimum but package declares $minimum_system_version" >&2
    exit 1
  fi

  while IFS= read -r dependency; do
    case "$dependency" in
      ""|/usr/lib/*|/System/Library/*|@rpath/*|@loader_path/*|@executable_path/*) ;;
      *)
        echo "non-portable Mach-O dependency in $label: $dependency" >&2
        exit 1
        ;;
    esac
  done < <(otool -L "$macho" | awk 'NR > 1 { print $1 }')
}

check_macho_portability "Shosai binary" "$binary"
check_macho_portability "PDFium library" "$pdfium"

codesign --verify --deep --strict --verbose=2 "$app"

printf 'Validated %s\n' "$archive"
