#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo "usage: $0 <version> <target> <binary> <pdfium-directory>" >&2
  exit 2
fi

version=${1#v}
target=$2
binary=$3
pdfium_dir=$4
package="shosai-${version}-${target}"
output_dir=${OUTPUT_DIR:-dist}

rm -rf "${output_dir:?}/$package"
mkdir -p \
  "$output_dir/$package/bin" \
  "$output_dir/$package/lib" \
  "$output_dir/$package/share/icons/hicolor/1024x1024/apps"
install -m 755 "$binary" "$output_dir/$package/bin/shosai"
install -m 644 "$pdfium_dir/lib/libpdfium.so" "$output_dir/$package/lib/libpdfium.so"
install -m 644 assets/shosai-icon.png \
  "$output_dir/$package/share/icons/hicolor/1024x1024/apps/shosai.png"
install -m 755 packaging/linux/install.sh "$output_dir/$package/install.sh"
install -m 644 packaging/linux/shosai.desktop "$output_dir/$package/shosai.desktop"
install -m 644 LICENSE "$output_dir/$package/LICENSE"
install -m 644 assets/fonts/LICENSE-Inter "$output_dir/$package/INTER-LICENSE"
install -m 644 "$pdfium_dir/LICENSE" "$output_dir/$package/PDFIUM-LICENSE"

tar -C "$output_dir" -czf "$output_dir/$package.tar.gz" "$package"
rm -rf "${output_dir:?}/$package"
