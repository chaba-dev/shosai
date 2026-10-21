{
  description = "Shōsai (書斎) — Ebook Reader";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      rust-overlay,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config = {
            allowUnfree = true;
            android_sdk.accept_license = true;
          };
          overlays = [ rust-overlay.overlays.default ];
        };

        rustToolchain = pkgs.rust-bin.stable."1.94.0".default.override {
          extensions = [
            "rust-src"
            "rust-analyzer"
            "clippy"
            "rustfmt"
          ];
        };

        developmentRustToolchain = rustToolchain.override {
          targets = [
            "aarch64-linux-android"
            "armv7-linux-androideabi"
            "x86_64-linux-android"
          ] ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
            "aarch64-apple-ios"
            "aarch64-apple-ios-sim"
            "x86_64-apple-ios"
          ];
        };

        androidSdk = (pkgs.androidenv.composeAndroidPackages {
          platformVersions = [ "35" "36" ];
          buildToolsVersions = [ "35.0.0" "36.0.0" ];
          includeCmake = true;
          cmakeVersions = [ "3.22.1" ];
          includeNDK = true;
          ndkVersion = "28.2.13676358";
        }).androidsdk;

        androidJdk = pkgs.jdk17;

        hostXcrun = pkgs.writeShellScriptBin "xcrun" ''
          exec /usr/bin/xcrun "$@"
        '';

        # Common dependencies across all platforms
        commonDeps = with pkgs; [
          developmentRustToolchain

          # tools
          androidJdk
          androidSdk
          cargo-expand
          cargo-ndk
          flutter
          flutter_rust_bridge_codegen
          git-cliff
          jujutsu
          hugo

          # build deps
          pkg-config
          cmake
          clang

          # runtime deps
          openssl
          pdfium-binaries

          # LSP
          rust-analyzer
          nodePackages.yaml-language-server
        ];

        # Linux-specific dependencies
        linuxDeps =
          with pkgs;
          pkgs.lib.optionals pkgs.stdenv.isLinux [
            # Flutter Linux desktop build deps
            gtk3
            ninja

            # Native windowing and GPU development files for the Flutter Linux
            # host and the tools that run under Xvfb below
            libxkbcommon
            wayland
            libx11
            libxcursor
            libxrandr
            libxi
            vulkan-loader
            vulkan-headers

            # Headless desktop E2E and screenshot verification
            xvfb
            xwininfo
            xdotool
            imagemagick
          ];

        # macOS-specific dependencies
        macosDeps =
          with pkgs;
          pkgs.lib.optionals pkgs.stdenv.isDarwin [
            # Essential macOS libraries for Rust compilation
            libiconv
            # macOS system frameworks are automatically available
          ];

        macosDevDeps =
          with pkgs;
          pkgs.lib.optionals pkgs.stdenv.isDarwin [
            cocoapods
            hostXcrun
            # Flutter 3.41 relies on GNU rsync's --chmod before in-place lipo.
            rsync
          ];

        # Windows-specific dependencies (when cross-compiling or running on Windows)
        windowsDeps =
          with pkgs;
          pkgs.lib.optionals pkgs.stdenv.hostPlatform.isWindows [
            # Windows system APIs are automatically available
            # No additional dependencies needed for native Windows builds
          ];
      in
      {
        devShells.default = pkgs.mkShell (
          {
            nativeBuildInputs = commonDeps ++ linuxDeps ++ macosDeps ++ macosDevDeps ++ windowsDeps;

            # Common environment variables
            ANDROID_HOME = "${androidSdk}/libexec/android-sdk";
            ANDROID_SDK_ROOT = "${androidSdk}/libexec/android-sdk";
            ANDROID_NDK_HOME = "${androidSdk}/libexec/android-sdk/ndk-bundle";
            ANDROID_NDK_ROOT = "${androidSdk}/libexec/android-sdk/ndk-bundle";
            JAVA_HOME = androidJdk.home;
            GRADLE_OPTS = "-Dorg.gradle.project.android.aapt2FromMavenOverride=${androidSdk}/libexec/android-sdk/build-tools/36.0.0/aapt2";
            RUST_SRC_PATH = "${developmentRustToolchain}/lib/rustlib/src/rust/library";
          }
          // (pkgs.lib.optionalAttrs pkgs.stdenv.isLinux {
            # Linux: LD_LIBRARY_PATH for shared libraries
            LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath (
              [ pkgs.pdfium-binaries ]
              ++ (with pkgs; [
                libxkbcommon
                wayland
                libx11
                libxcursor
                libxrandr
                libxi
                vulkan-loader
              ])
            );

            # The Flutter PDF engine tests load PDFium from here: `flutter test`
            # does not link pdfrx's native asset.
            SHOSAI_PDFIUM_LIBRARY = "${pkgs.pdfium-binaries}/lib/libpdfium.so";

            # Clang (in the shell's build deps) links the native Cargo targets
            # directly, matching the toolchain the Flutter host builds use.
            CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER = "clang";
            CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER = "clang";
          })
          // (pkgs.lib.optionalAttrs pkgs.stdenv.isDarwin {
            # macOS: DYLD_LIBRARY_PATH for dynamic libraries
            DYLD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [ pkgs.pdfium-binaries ];
            SHOSAI_PDFIUM_LIBRARY = "${pkgs.pdfium-binaries}/lib/libpdfium.dylib";

            # Release artifacts must use the host Apple SDK and system libraries,
            # rather than embedding dependencies from the Nix SDK or store.
            CARGO_TARGET_AARCH64_APPLE_DARWIN_LINKER = "/usr/bin/clang";
            CC_aarch64_apple_darwin = "/usr/bin/clang";
            CXX_aarch64_apple_darwin = "/usr/bin/clang++";
            shellHook = ''
              export DEVELOPER_DIR="$(env -u DEVELOPER_DIR /usr/bin/xcode-select --print-path)"
              export SDKROOT="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
              export PATH="${hostXcrun}/bin:$PATH"
              export MACOSX_DEPLOYMENT_TARGET=13.0
            '';
          })
        );
      }
    );
}
