#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <version> <target> <archive>" >&2
  exit 2
fi

version=${1#v}
target=$2
archive=$3
package="shosai-${version}-${target}"

case "$target" in
  x86_64-*) architecture="x86-64" ;;
  aarch64-*) architecture="ARM aarch64" ;;
  *)
    echo "unsupported Linux target: $target" >&2
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
  if [[ "$entry" != "$package" && "$entry" != "$package/"* ]] ||
    [[ "$entry" == *"/../"* || "$entry" == *"/.." ]]; then
    echo "unsafe or unexpected archive entry: $entry" >&2
    exit 1
  fi
done < <(tar -tzf "$archive")

tar -xzf "$archive" -C "$work_dir"
package_dir="$work_dir/$package"

invalid_entries=$(find "$package_dir" ! -type f ! -type d -print)
if [[ -n "$invalid_entries" ]]; then
  printf 'unsupported package entry type:\n%s\n' "$invalid_entries" >&2
  exit 1
fi

expected_files=$(cat <<EOF
INTER-LICENSE
LICENSE
PDFIUM-LICENSE
bin/shosai
install.sh
lib/libpdfium.so
share/icons/hicolor/1024x1024/apps/shosai.png
shosai.desktop
EOF
)
actual_files=$(
  find "$package_dir" -type f -print |
    sed "s|^$package_dir/||" |
    LC_ALL=C sort
)

if [[ "$actual_files" != "$expected_files" ]]; then
  echo "unexpected files in $archive" >&2
  diff -u <(printf '%s\n' "$expected_files") <(printf '%s\n' "$actual_files") >&2 || true
  exit 1
fi

test -x "$package_dir/bin/shosai"
test -x "$package_dir/install.sh"
test -s "$package_dir/lib/libpdfium.so"
test -s "$package_dir/LICENSE"
test -s "$package_dir/INTER-LICENSE"
test -s "$package_dir/PDFIUM-LICENSE"

file "$package_dir/bin/shosai" | grep -Fq "$architecture"
file "$package_dir/lib/libpdfium.so" | grep -Fq "$architecture"
file "$package_dir/share/icons/hicolor/1024x1024/apps/shosai.png" |
  grep -Fq "PNG image data, 1024 x 1024"

grep -Fxq "Exec=@SHOSAI_EXEC@" "$package_dir/shosai.desktop"
grep -Fxq "Icon=shosai" "$package_dir/shosai.desktop"

install_prefix="$work_dir/install"
SHOSAI_INSTALL_PREFIX="$install_prefix" "$package_dir/install.sh"

test -x "$install_prefix/opt/shosai/bin/shosai"
test -s "$install_prefix/opt/shosai/lib/libpdfium.so"
test -s "$install_prefix/opt/shosai/LICENSE"
test -s "$install_prefix/opt/shosai/INTER-LICENSE"
test -s "$install_prefix/opt/shosai/PDFIUM-LICENSE"
test -L "$install_prefix/bin/shosai"
test "$(readlink "$install_prefix/bin/shosai")" = "$install_prefix/opt/shosai/bin/shosai"
test -s "$install_prefix/share/icons/hicolor/1024x1024/apps/shosai.png"
grep -Fxq "Exec=$install_prefix/opt/shosai/bin/shosai" \
  "$install_prefix/share/applications/shosai.desktop"
desktop-file-validate "$install_prefix/share/applications/shosai.desktop"

printf 'Validated %s\n' "$archive"
