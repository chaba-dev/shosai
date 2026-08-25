#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo "usage: $0 <version> <architecture> <binary> <pdfium-directory>" >&2
  exit 2
fi

version=${1#v}
architecture=$2
binary=$3
pdfium_dir=$4
output_dir=${OUTPUT_DIR:-dist}
app="$output_dir/Shosai.app"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks" "$app/Contents/Resources"
install -m 755 "$binary" "$app/Contents/MacOS/Shosai"
install -m 755 "$pdfium_dir/lib/libpdfium.dylib" "$app/Contents/Frameworks/libpdfium.dylib"
install -m 644 "$pdfium_dir/LICENSE" "$app/Contents/Resources/PDFIUM-LICENSE"
install -m 644 LICENSE "$app/Contents/Resources/LICENSE"
install -m 644 assets/fonts/LICENSE-Inter "$app/Contents/Resources/INTER-LICENSE"

iconset="$output_dir/Shosai.iconset"
rm -rf "$iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  double_size=$((size * 2))
  sips -z "$size" "$size" assets/shosai-icon.png \
    --out "$iconset/icon_${size}x${size}.png" >/dev/null
  sips -z "$double_size" "$double_size" assets/shosai-icon.png \
    --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/Shosai.icns"
rm -rf "$iconset"

cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleDisplayName</key><string>Shosai</string>
  <key>CFBundleExecutable</key><string>Shosai</string>
  <key>CFBundleIdentifier</key><string>io.github.chaba2.shosai</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleIconFile</key><string>Shosai</string>
  <key>CFBundleName</key><string>Shosai</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

# Ad-hoc signing keeps the bundle internally consistent. Public releases still
# need Developer ID signing and notarization to avoid Gatekeeper warnings.
codesign --force --sign - "$app/Contents/Frameworks/libpdfium.dylib"
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"

artifact="Shosai-${version}-macos-${architecture}.zip"
rm -f "$output_dir/$artifact"
ditto -c -k --sequesterRsrc --keepParent "$app" "$output_dir/$artifact"
rm -rf "$app"
