#!/bin/sh
set -eu

plugin_root=$(cd "$PODS_TARGET_SRCROOT/.." && pwd -P)
workspace_root=$(cd "$plugin_root/../.." && pwd -P)
pdfium_root=${SHOSAI_IOS_PDFIUM_ROOT:-"$workspace_root/target/ios-pdfium/8046b/release"}

case "$PLATFORM_NAME" in
  iphoneos)
    rust_target=aarch64-apple-ios
    rust_arch=arm64
    pdfium_library="$pdfium_root/pdfium.xcframework/ios-arm64/libpdfium.a"
    ;;
  iphonesimulator)
    case " $ARCHS " in
      *" arm64 "*) rust_target=aarch64-apple-ios-sim; rust_arch=arm64 ;;
      *" x86_64 "*) rust_target=x86_64-apple-ios; rust_arch=x86_64 ;;
      *) echo "error: unsupported iOS simulator architectures: $ARCHS" >&2; exit 1 ;;
    esac
    pdfium_library="$pdfium_root/pdfium.xcframework/ios-arm64_x86_64-simulator/libpdfium.a"
    ;;
  *) echo "error: unsupported Apple platform: $PLATFORM_NAME" >&2; exit 1 ;;
esac

if [ ! -f "$pdfium_library" ]; then
  echo "error: missing iOS PDFium library: $pdfium_library" >&2
  echo "run scripts/fetch-ios-pdfium.sh before building" >&2
  exit 1
fi

profile=debug
profile_flag=
case "$CONFIGURATION" in
  Debug) ;;
  Profile|Release)
    profile=release
    profile_flag=--release
    ;;
esac

pdfium_link_dir="$TARGET_TEMP_DIR/pdfium/$rust_target"
mkdir -p "$pdfium_link_dir" "$BUILT_PRODUCTS_DIR"
/usr/bin/lipo "$pdfium_library" -thin "$rust_arch" \
  -output "$pdfium_link_dir/libpdfium.a"

export PDFIUM_STATIC_LIB_PATH="$pdfium_link_dir"
pdfium_cache_key=$(basename "$(dirname "$pdfium_root")")
export CARGO_TARGET_DIR="$TARGET_TEMP_DIR/cargo-target-$pdfium_cache_key"
export CARGO_TARGET_AARCH64_APPLE_IOS_LINKER=/usr/bin/clang
export CARGO_TARGET_AARCH64_APPLE_IOS_SIM_LINKER=/usr/bin/clang
export CARGO_TARGET_X86_64_APPLE_IOS_LINKER=/usr/bin/clang
export CC_aarch64_apple_ios=/usr/bin/clang
export CXX_aarch64_apple_ios=/usr/bin/clang++
export CC_aarch64_apple_ios_sim=/usr/bin/clang
export CXX_aarch64_apple_ios_sim=/usr/bin/clang++
export CC_x86_64_apple_ios=/usr/bin/clang
export CXX_x86_64_apple_ios=/usr/bin/clang++
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
unset SDKROOT MACOSX_DEPLOYMENT_TARGET TVOS_DEPLOYMENT_TARGET
unset WATCHOS_DEPLOYMENT_TARGET XROS_DEPLOYMENT_TARGET DRIVERKIT_DEPLOYMENT_TARGET
unset CC CXX CC_FOR_BUILD CXX_FOR_BUILD AR AS LD LD_FOR_BUILD NM RANLIB STRIP
unset OBJCOPY OBJDUMP READELF CFLAGS CXXFLAGS CPPFLAGS LDFLAGS
unset NIX_CFLAGS_COMPILE NIX_CFLAGS_COMPILE_FOR_BUILD
unset NIX_LDFLAGS NIX_LDFLAGS_FOR_BUILD

set -- rustc --manifest-path "$workspace_root/Cargo.toml" \
  --package shosai-flutter-bridge --target "$rust_target" \
  --lib --crate-type staticlib
if [ -n "$profile_flag" ]; then
  set -- "$@" "$profile_flag"
fi
cargo "$@"
cp "$CARGO_TARGET_DIR/$rust_target/$profile/libshosai_flutter_bridge.a" \
  "$BUILT_PRODUCTS_DIR/libshosai_flutter_bridge.a"
