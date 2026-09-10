#!/usr/bin/env bash
set -euo pipefail

version=8046b
archive_sha256=3c5dc228d3b1fff89911fea4de91171a63b39b07680c4f441e5cd7be29b825ee
repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
destination="${SHOSAI_IOS_PDFIUM_ROOT:-$repository_root/target/ios-pdfium/$version}"
archive="$destination/ios.tgz"
release="$destination/release"

if [[ -f "$release/pdfium.xcframework/Info.plist" ]]; then
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
printf '%s\n' "$release"
