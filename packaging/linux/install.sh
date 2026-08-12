#!/bin/sh
set -eu

package_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
prefix=${SHOSAI_INSTALL_PREFIX:-"$HOME/.local"}
install_dir="$prefix/opt/shosai"

mkdir -p "$install_dir/bin" "$install_dir/lib" "$prefix/bin" "$prefix/share/applications"
install -m 755 "$package_dir/bin/shosai" "$install_dir/bin/shosai"
install -m 644 "$package_dir/lib/libpdfium.so" "$install_dir/lib/libpdfium.so"
install -m 644 "$package_dir/PDFIUM-LICENSE" "$install_dir/PDFIUM-LICENSE"
install -m 644 "$package_dir/LICENSE" "$install_dir/LICENSE"
ln -sfn "$install_dir/bin/shosai" "$prefix/bin/shosai"
sed "s|@SHOSAI_EXEC@|$install_dir/bin/shosai|" \
  "$package_dir/shosai.desktop" > "$prefix/share/applications/shosai.desktop"
chmod 644 "$prefix/share/applications/shosai.desktop"

printf 'Installed Shosai in %s\n' "$install_dir"
printf 'Ensure %s is on PATH, then run: shosai\n' "$prefix/bin"
