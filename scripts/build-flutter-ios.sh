#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != Darwin ]]; then
  echo "error: the Flutter iOS host must be built on macOS" >&2
  exit 1
fi
if [[ "$(uname -m)" != arm64 ]]; then
  echo "error: the Flutter iOS host currently requires Apple Silicon" >&2
  exit 1
fi

usage() {
  echo "usage: $0 <simulator|device> <debug|profile|release>" >&2
  exit 2
}

target=${1:-}
mode=${2:-}
[[ $# -eq 2 ]] || usage
case "$target" in
  simulator) target_flag=--simulator ;;
  device) target_flag=--no-codesign ;;
  *) usage ;;
esac
case "$mode" in
  debug|profile|release) ;;
  *) usage ;;
esac
if [[ "$target" == simulator && "$mode" != debug ]]; then
  echo "error: Flutter supports debug mode only for iOS simulator builds" >&2
  exit 2
fi

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version=3.41.5
archive_sha256=90d8e7d7e6c2c27ce8634a6c99eb8a218ea63ba29781b61eb9db72c62d027546
sdk_cache="${SHOSAI_FLUTTER_IOS_SDK:-$repository_root/target/flutter-ios-sdk/$version}"
archive="$sdk_cache/flutter_macos_arm64_${version}-stable.zip"
flutter_root="$sdk_cache/flutter"
marker="$flutter_root/.shosai-archive-sha256"

if [[ ! -x "$flutter_root/bin/flutter" ]] ||
  [[ ! -f "$marker" ]] || [[ "$(cat "$marker")" != "$archive_sha256" ]]; then
  mkdir -p "$sdk_cache"
  if [[ ! -f "$archive" ]] ||
    [[ "$(shasum -a 256 "$archive" | awk '{print $1}')" != "$archive_sha256" ]]; then
    temporary_archive="$archive.tmp"
    rm -f "$temporary_archive"
    curl --fail --location --retry 3 \
      "https://storage.googleapis.com/flutter_infra_release/releases/stable/macos/flutter_macos_arm64_${version}-stable.zip" \
      --output "$temporary_archive"
    actual_sha256="$(shasum -a 256 "$temporary_archive" | awk '{print $1}')"
    if [[ "$actual_sha256" != "$archive_sha256" ]]; then
      rm -f "$temporary_archive"
      echo "error: Flutter checksum mismatch: expected $archive_sha256, got $actual_sha256" >&2
      exit 1
    fi
    mv "$temporary_archive" "$archive"
  fi

  temporary_root="$sdk_cache/flutter.tmp"
  rm -rf "$temporary_root" "$sdk_cache/flutter-extract.tmp"
  unzip -q "$archive" -d "$sdk_cache/flutter-extract.tmp"
  mv "$sdk_cache/flutter-extract.tmp/flutter" "$temporary_root"
  rm -rf "$sdk_cache/flutter-extract.tmp" "$flutter_root"
  chmod -R u+w "$temporary_root"
  printf '%s\n' "$archive_sha256" > "$temporary_root/.shosai-archive-sha256"
  mv "$temporary_root" "$flutter_root"
fi

"$repository_root/scripts/fetch-ios-pdfium.sh" >/dev/null

export FLUTTER_ROOT="$flutter_root"
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$flutter_root/bin:$PATH"

cd "$repository_root/flutter"
exec env \
  -u SDKROOT \
  -u MACOSX_DEPLOYMENT_TARGET \
  -u IPHONEOS_DEPLOYMENT_TARGET \
  -u TVOS_DEPLOYMENT_TARGET \
  -u WATCHOS_DEPLOYMENT_TARGET \
  -u XROS_DEPLOYMENT_TARGET \
  -u DRIVERKIT_DEPLOYMENT_TARGET \
  -u CC -u CXX -u CC_FOR_BUILD -u CXX_FOR_BUILD \
  -u AR -u AS -u LD -u LD_FOR_BUILD -u NM -u RANLIB -u STRIP \
  -u OBJCOPY -u OBJDUMP -u READELF \
  -u CFLAGS -u CXXFLAGS -u CPPFLAGS -u LDFLAGS \
  -u NIX_CFLAGS_COMPILE -u NIX_CFLAGS_COMPILE_FOR_BUILD \
  -u NIX_LDFLAGS -u NIX_LDFLAGS_FOR_BUILD \
  "$flutter_root/bin/flutter" build ios "$target_flag" "--$mode"
