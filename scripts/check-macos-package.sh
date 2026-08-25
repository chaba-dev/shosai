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
test "$minimum_system_version" = "13.0"

macho_build_target() {
  awk '
    $1 == "cmd" { command = $2; platform = ""; next }
    command == "LC_BUILD_VERSION" && $1 == "platform" { platform = $2; next }
    command == "LC_BUILD_VERSION" && $1 == "minos" { print platform, $2; exit }
    command == "LC_VERSION_MIN_MACOSX" && $1 == "version" { print "MACOS", $2; exit }
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

path_has_dot_component() {
  case "/$1/" in
    */./*|*/../*) return 0 ;;
    *) return 1 ;;
  esac
}

check_macho_portability() {
  local label=$1
  local macho=$2
  local load_commands
  if ! load_commands=$(otool -l "$macho"); then
    echo "cannot inspect Mach-O load commands for $label" >&2
    exit 1
  fi

  local target
  local platform
  local minimum
  target=$(printf '%s\n' "$load_commands" | macho_build_target)
  read -r platform minimum <<< "$target"
  if [[ -z "$minimum" ]]; then
    echo "cannot determine minimum macOS version for $label" >&2
    exit 1
  fi
  case "$platform" in
    1|MACOS) ;;
    *)
      echo "$label is not a macOS Mach-O (platform $platform)" >&2
      exit 1
      ;;
  esac
  if version_is_greater "$minimum" "$minimum_system_version"; then
    echo "$label requires macOS $minimum but package declares $minimum_system_version" >&2
    exit 1
  fi

  local rpaths
  rpaths=$(printf '%s\n' "$load_commands" | awk '
    $1 == "cmd" { in_rpath = ($2 == "LC_RPATH"); next }
    in_rpath && $1 == "path" {
      line = $0
      sub(/^[[:space:]]*path[[:space:]]+/, "", line)
      sub(/[[:space:]]+\(offset [0-9]+\)$/, "", line)
      print line
      in_rpath = 0
    }
  ')
  while IFS= read -r rpath; do
    [[ -z "$rpath" ]] && continue
    if path_has_dot_component "$rpath"; then
      echo "path traversal in LC_RPATH for $label: $rpath" >&2
      exit 1
    fi
    case "$rpath" in
      /usr/lib|/usr/lib/*|/System/Library|/System/Library/*|@loader_path|@loader_path/*|@executable_path|@executable_path/*) ;;
      *)
        echo "non-portable LC_RPATH in $label: $rpath" >&2
        exit 1
        ;;
    esac
  done <<< "$rpaths"

  local dependency_output
  if ! dependency_output=$(otool -L "$macho"); then
    echo "cannot inspect Mach-O dependencies for $label" >&2
    exit 1
  fi
  local dependencies
  dependencies=$(printf '%s\n' "$dependency_output" | sed -n '2,$ {
    s/^[[:space:]]*//
    s/ (compatibility version.*$//
    p
  }')
  while IFS= read -r dependency; do
    # otool reports a dylib's install name before its actual dependencies.
    if [[ "$label" == "PDFium library" && "$dependency" == "./libpdfium.dylib" ]]; then
      continue
    fi
    if path_has_dot_component "$dependency"; then
      echo "path traversal in Mach-O dependency for $label: $dependency" >&2
      exit 1
    fi
    case "$dependency" in
      ""|/usr/lib/*|/System/Library/*|@rpath/*|@loader_path/*|@executable_path/*) ;;
      *)
        echo "non-portable Mach-O dependency in $label: $dependency" >&2
        exit 1
        ;;
    esac
  done <<< "$dependencies"
}

check_macho_portability "Shosai binary" "$binary"
check_macho_portability "PDFium library" "$pdfium"

codesign --verify --deep --strict --verbose=2 "$app"

printf 'Validated %s\n' "$archive"
