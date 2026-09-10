#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
archive="$root/target/downloads/pdfium-android-arm64-chromium-7999.tgz"
output="$root/target/flutter-android-native/arm64-v8a"
notices="$root/target/flutter-android-assets/PDFiumLicenses"
url="https://github.com/bblanchon/pdfium-binaries/releases/download/chromium/7999/pdfium-android-arm64.tgz"
sha256="ed2aabb502a4e2748ca236eaf7bbf5bcaeb4e50a5aca97955138b5b981dfa5b5"

mkdir -p "$(dirname "$archive")" "$output"
if [[ ! -f "$archive" ]]; then
  curl --fail --location --retry 3 "$url" --output "$archive"
fi
printf '%s  %s\n' "$sha256" "$archive" | sha256sum --check --status || {
  echo "error: PDFium archive checksum mismatch: $archive" >&2
  exit 1
}

temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT
tar -xzf "$archive" -C "$temporary" lib/libpdfium.so LICENSE licenses
cp "$temporary/lib/libpdfium.so" "$output/libpdfium.so"
rm -rf "$notices"
mkdir -p "$notices"
cp "$temporary/LICENSE" "$notices/DISTRIBUTOR-LICENSE"
cp "$temporary/licenses/pdfium.txt" "$notices/PDFIUM-LICENSE"
cp -R "$temporary/licenses" "$notices/third-party"

android_target="aarch64-linux-android"
case "$(uname -s)" in
  Linux) ndk_host=linux-x86_64 ;;
  Darwin) ndk_host=darwin-x86_64 ;;
  *) echo "error: unsupported Android build host: $(uname -s)" >&2; exit 1 ;;
esac
ndk_bin="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$ndk_host/bin"
android_cc="$ndk_bin/aarch64-linux-android21-clang"
android_ar="$ndk_bin/llvm-ar"
cargo_target="$root/target/flutter-android-cargo"
if [[ ! -x "$android_cc" || ! -x "$android_ar" ]]; then
  echo "error: Android NDK toolchain is missing under $ndk_bin" >&2
  exit 1
fi

cd "$root"
CC_aarch64_linux_android="$android_cc" \
  AR_aarch64_linux_android="$android_ar" \
  CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$android_cc" \
  CARGO_TARGET_DIR="$cargo_target" \
  cargo build \
    --target "$android_target" \
    --package shosai-flutter-bridge \
    --release
cp \
  "$cargo_target/$android_target/release/libshosai_flutter_bridge.so" \
  "$output/libshosai_flutter_bridge.so"
