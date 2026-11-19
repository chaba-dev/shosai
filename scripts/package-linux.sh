#!/usr/bin/env bash
# Assemble both packages from a production Flutter build on native Ubuntu.
set -euo pipefail
cd "$(dirname "$0")/.."
export LC_ALL=C

app_id=dev.shosai.reader
version=$(sed -nE 's/^version: ([0-9]+\.[0-9]+\.[0-9]+)(\+[0-9]+)?$/\1/p' pubspec.yaml)
bundle=build/linux/x64/release/bundle
stage=target/linux-package-root
dist=target/release-dist
stem="shosai-$version-linux-x64"
if [[ -z "$version" || $(uname -m) != x86_64 ]]; then
  echo 'Expected a stable version in pubspec.yaml and a native x86-64 build' >&2
  exit 1
fi

python3 scripts/check_flutter_bundle.py "$bundle"
desktop-file-validate "linux/packaging/$app_id.desktop"
appstreamcli validate --no-net "linux/packaging/$app_id.metainfo.xml"
if ! grep -aqF "$app_id" "$bundle/shosai_flutter"; then
  echo 'Build with make linux-production before packaging' >&2
  exit 1
fi

rm -rf "$stage"
mkdir -p "$stage/opt/shosai" "$dist"
cp -a "$bundle/." "$stage/opt/shosai/"
install -Dm644 LICENSE "$stage/usr/share/doc/shosai/copyright"
install -Dm644 "linux/packaging/$app_id.desktop" "$stage/usr/share/applications/$app_id.desktop"
install -Dm644 "linux/packaging/$app_id.metainfo.xml" "$stage/usr/share/metainfo/$app_id.metainfo.xml"
icon_dir="$stage/usr/share/icons/hicolor/128x128/apps"
install -d "$icon_dir"
convert assets/shosai-icon.png -resize 128x128 "$icon_dir/$app_id.png"

payload=$stage/opt/shosai
if [[ -n $(find "$payload" -type l -print -quit) ]] ||
    [[ $(patchelf --print-interpreter "$payload/shosai_flutter") != /lib64/ld-linux-x86-64.so.2 ]]; then
  echo 'Use a native, non-Nix Flutter bundle without symlinks' >&2
  exit 1
fi
for lib in libpdfium.so libsqlite3.so libflutter_linux_gtk.so libflutter_secure_storage_linux_plugin.so; do
  test -s "$payload/lib/$lib"
done
patchelf --set-rpath "\$ORIGIN/lib" "$payload/shosai_flutter"
for lib in "$payload"/lib/*.so; do
  # The Flutter engine dlopens PDFium and SQLite by name. Plugins also need
  # their sibling engine, not an absolute RUNPATH back to the build tree.
  patchelf --set-rpath "\$ORIGIN" "$lib"
done
elfs=("$payload/shosai_flutter" "$payload"/lib/*.so)
for elf in "${elfs[@]}"; do
  deps=$(ldd "$elf")
  if [[ "$deps" == *'not found'* || "$deps" == *'/nix/store/'* ]]; then
    printf 'Nonportable dependencies in %s:\n%s\n' "$elf" "$deps" >&2
    exit 1
  fi
done

# Resolve host dependencies from the actual ELF symbol versions. Give
# dpkg-shlibdeps a source control file without adding Debian build files to
# the Flutter checkout or inside the shipped payload.
mkdir -p "$stage/debian" "$stage/DEBIAN"
cat > "$stage/debian/control" <<'EOF'
Source: shosai
Section: office
Priority: optional
Maintainer: Shōsai contributors

Package: shosai
Architecture: amd64
Description: EPUB and PDF reader
EOF
depends=$(cd "$stage" && dpkg-shlibdeps --ignore-missing-info --warnings=0 -O -lopt/shosai/lib \
  opt/shosai/shosai_flutter opt/shosai/lib/*.so)
rm -r "$stage/debian"
install -d "$stage/usr/bin"
# glibc resolves the executable's $ORIGIN relative to the launch path. Use
# exec rather than a symlink so it sees the adjacent bundled libraries.
printf '%s\n' '#!/bin/sh' 'exec /opt/shosai/shosai_flutter "$@"' > "$stage/usr/bin/shosai_flutter"
chmod 755 "$stage/usr/bin/shosai_flutter"
cat > "$stage/DEBIAN/control" <<EOF
Package: shosai
Version: $version
Architecture: amd64
Section: office
Priority: optional
Maintainer: Shōsai contributors
Depends: libegl1, libgl1, ${depends#shlibs:Depends=}
Recommends: gnome-keyring, libegl-mesa0, libgl1-mesa-dri
Installed-Size: $(du -sk "$stage" | cut -f1)
Homepage: https://shosai.pages.dev/
Description: EPUB and PDF reader
 A personal ebook library and reader for EPUB and PDF files.
EOF
dpkg-deb --root-owner-group --build "$stage" "$dist/$stem.deb"
rm -r "$stage/DEBIAN" "${stage:?}/usr/bin"

# Build only from the staged files: no Flutter SDK, secrets or network in the
# Flatpak sandbox. The runtime and SDK must already be installed from Flathub.
repo=$(mktemp -d "$PWD/target/flatpak-repo.XXXXXXXX")
trap 'rm -rf "$repo"' EXIT
flatpak-builder --force-clean --disable-download --state-dir=target/flatpak-state \
  --repo="$repo" target/flatpak-build "$app_id.yml"
flatpak build-bundle --runtime-repo=https://flathub.org/repo/flathub.flatpakrepo \
  "$repo" "$dist/$stem.flatpak" "$app_id" master
stat -c '%n: %s bytes' "$dist/$stem.deb" "$dist/$stem.flatpak"
