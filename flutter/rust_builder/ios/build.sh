#!/bin/sh
set -eu

plugin_root=$(cd "$PODS_TARGET_SRCROOT/.." && pwd -P)
workspace_root=$(cd "$plugin_root/../.." && pwd -P)
pdfium_cache_root=${SHOSAI_IOS_PDFIUM_ROOT:-"$workspace_root/target/ios-pdfium/8046b"}
pdfium_root="$pdfium_cache_root/release"

case "$PLATFORM_NAME" in
  iphoneos)
    pdfium_library="$pdfium_root/pdfium.xcframework/ios-arm64/libpdfium.a"
    ;;
  iphonesimulator)
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

pdfium_cache_key=$(basename "$(dirname "$pdfium_root")")
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

built_archives="$TARGET_TEMP_DIR/shosai-static-libraries"
rm -rf "$built_archives"
mkdir -p "$built_archives" "$BUILT_PRODUCTS_DIR"
for rust_arch in $ARCHS; do
  case "$PLATFORM_NAME:$rust_arch" in
    iphoneos:arm64) rust_target=aarch64-apple-ios ;;
    iphonesimulator:arm64) rust_target=aarch64-apple-ios-sim ;;
    iphonesimulator:x86_64) rust_target=x86_64-apple-ios ;;
    *) echo "error: unsupported iOS architecture: $PLATFORM_NAME $rust_arch" >&2; exit 1 ;;
  esac

  pdfium_link_dir="$TARGET_TEMP_DIR/pdfium/$rust_target"
  mkdir -p "$pdfium_link_dir"
  /usr/bin/lipo "$pdfium_library" -thin "$rust_arch" \
    -output "$pdfium_link_dir/libpdfium.a"
  export PDFIUM_STATIC_LIB_PATH="$pdfium_link_dir"
  export CARGO_TARGET_DIR="$TARGET_TEMP_DIR/cargo-target-$pdfium_cache_key-$rust_arch"

  set -- rustc --manifest-path "$workspace_root/Cargo.toml" \
    --package shosai-flutter-bridge --target "$rust_target" \
    --lib --crate-type staticlib
  if [ -n "$profile_flag" ]; then
    set -- "$@" "$profile_flag"
  fi
  cargo "$@"
  cp "$CARGO_TARGET_DIR/$rust_target/$profile/libshosai_flutter_bridge.a" \
    "$built_archives/$rust_arch.a"
done

set -- "$built_archives"/*.a
if [ "$#" -eq 1 ]; then
  cp "$1" "$BUILT_PRODUCTS_DIR/libshosai_flutter_bridge.a"
else
  /usr/bin/lipo -create "$@" \
    -output "$BUILT_PRODUCTS_DIR/libshosai_flutter_bridge.a"
fi
