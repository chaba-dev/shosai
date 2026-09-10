#!/usr/bin/env bash
set -euo pipefail

version=8046b
archive_sha256=3c5dc228d3b1fff89911fea4de91171a63b39b07680c4f441e5cd7be29b825ee
notice_archive_sha256=37686e64fa005484d619550a78805500de4c5a6f4df7aa06d8576145bfbee98f
build_license_sha256=f76cf515028a29998219ef69368c12c29ac0507df55475408e590e32f7627a5d
repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
destination="${SHOSAI_IOS_PDFIUM_ROOT:-$repository_root/target/ios-pdfium/$version}"
archive="$destination/ios.tgz"
release="$destination/release"
notices="$destination/notices"
packaged_notices="$repository_root/flutter/rust_builder/ios/generated/PDFiumLicenses"

if [[ -f "$release/pdfium.xcframework/Info.plist" && -f "$notices/PDFIUM-LICENSE" &&
  -f "$notices/PDFIUM-BUILD-LICENSE" && -d "$notices/third-party" ]]; then
  rm -rf "$packaged_notices"
  mkdir -p "$(dirname "$packaged_notices")"
  cp -R "$notices" "$packaged_notices"
  printf '%s\n' "$release"
  exit 0
fi

mkdir -p "$destination"
if [[ ! -f "$archive" ]] ||
  [[ "$(shasum -a 256 "$archive" | awk '{print $1}')" != "$archive_sha256" ]]; then
  temporary_archive="$archive.tmp"
  rm -f "$temporary_archive"
  curl --fail --location --retry 3 \
    "https://github.com/paulocoutinhox/pdfium-lib/releases/download/$version/ios.tgz" \
    --output "$temporary_archive"
  actual_sha256="$(shasum -a 256 "$temporary_archive" | awk '{print $1}')"
  if [[ "$actual_sha256" != "$archive_sha256" ]]; then
    rm -f "$temporary_archive"
    echo "error: PDFium checksum mismatch: expected $archive_sha256, got $actual_sha256" >&2
    exit 1
  fi
  mv "$temporary_archive" "$archive"
fi

temporary_release="$destination/release.tmp"
rm -rf "$temporary_release"
mkdir -p "$temporary_release"
tar -xzf "$archive" -C "$temporary_release" --strip-components=1
rm -rf "$release"
mv "$temporary_release" "$release"

notice_archive="$destination/pdfium-notices-chromium-8044.tgz"
if [[ ! -f "$notice_archive" ]] ||
  [[ "$(shasum -a 256 "$notice_archive" | awk '{print $1}')" != "$notice_archive_sha256" ]]; then
  temporary_notice_archive="$notice_archive.tmp"
  rm -f "$temporary_notice_archive"
  curl --fail --location --retry 3 \
    "https://github.com/bblanchon/pdfium-binaries/releases/download/chromium%2F8044/pdfium-android-arm64.tgz" \
    --output "$temporary_notice_archive"
  actual_sha256="$(shasum -a 256 "$temporary_notice_archive" | awk '{print $1}')"
  if [[ "$actual_sha256" != "$notice_archive_sha256" ]]; then
    rm -f "$temporary_notice_archive"
    echo "error: PDFium notice checksum mismatch: expected $notice_archive_sha256, got $actual_sha256" >&2
    exit 1
  fi
  mv "$temporary_notice_archive" "$notice_archive"
fi

build_license="$destination/pdfium-lib-LICENSE.md"
if [[ ! -f "$build_license" ]] ||
  [[ "$(shasum -a 256 "$build_license" | awk '{print $1}')" != "$build_license_sha256" ]]; then
  temporary_build_license="$build_license.tmp"
  rm -f "$temporary_build_license"
  curl --fail --location --retry 3 \
    "https://raw.githubusercontent.com/paulocoutinhox/pdfium-lib/365177682dca07b919bea78319bc546f2d255532/LICENSE.md" \
    --output "$temporary_build_license"
  actual_sha256="$(shasum -a 256 "$temporary_build_license" | awk '{print $1}')"
  if [[ "$actual_sha256" != "$build_license_sha256" ]]; then
    rm -f "$temporary_build_license"
    echo "error: PDFium build-license checksum mismatch: expected $build_license_sha256, got $actual_sha256" >&2
    exit 1
  fi
  mv "$temporary_build_license" "$build_license"
fi

temporary_notices="$destination/notices.tmp"
rm -rf "$temporary_notices" "$notices"
mkdir -p "$temporary_notices"
tar -xzf "$notice_archive" -C "$temporary_notices" LICENSE licenses
mv "$temporary_notices/LICENSE" "$temporary_notices/NOTICE-BUNDLE-DISTRIBUTOR-LICENSE"
cp "$temporary_notices/licenses/pdfium.txt" "$temporary_notices/PDFIUM-LICENSE"
mv "$temporary_notices/licenses" "$temporary_notices/third-party"
cp "$build_license" "$temporary_notices/PDFIUM-BUILD-LICENSE"
cat > "$temporary_notices/SOURCE" <<'EOF'
PDFium iOS artifact: paulocoutinhox/pdfium-lib 8046b, PDFium chromium/8046.
PDFium and third-party license texts: bblanchon/pdfium-binaries chromium/8044.
The artifact distributor does not publish generated notices; the nearest
generated PDFium license bundle is packaged as a conservative notice set.
EOF
mv "$temporary_notices" "$notices"
rm -rf "$packaged_notices"
mkdir -p "$(dirname "$packaged_notices")"
cp -R "$notices" "$packaged_notices"
printf '%s\n' "$release"
