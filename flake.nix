{
  description = "Shōsai (書斎) — Ebook Reader";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
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
        };
        inherit (pkgs) lib stdenv;

        androidSdk = (pkgs.androidenv.composeAndroidPackages {
          platformVersions = [ "35" "36" ];
          buildToolsVersions = [ "35.0.0" "36.0.0" ];
          includeCmake = true;
          cmakeVersions = [ "3.22.1" ];
          includeNDK = true;
          ndkVersion = "28.2.13676358";
        }).androidsdk;

        androidJdk = pkgs.jdk17;

        # The Dart VM in libflutter_linux_gtk.so dlopens native assets (SQLite,
        # PDFium) by bare name, so it needs its upstream RUNPATH `$ORIGIN` to
        # find them beside it in the bundle's lib/. The pinned nixpkgs patches
        # the engine artifacts with auto-patchelf, which drops `$ORIGIN`.
        # Backport nixpkgs 90cf442 (#574475); drop this once the pin includes it.
        flutter =
          if stdenv.isLinux then
            pkgs.flutter.override (prev: {
              callPackage =
                path: args:
                let
                  package = prev.callPackage path args;
                in
                if baseNameOf path == "prepare-artifacts.nix" then
                  package.overrideAttrs { autoPatchelfFlags = [ "--preserve-origin" ]; }
                else
                  package;
            })
          else
            pkgs.flutter;

        # CI builds and tests the host desktop only. The engine artifacts for
        # Android alone are 757 MiB on Linux.
        ciFlutter = flutter.override {
          supportedTargetFlutterPlatforms = [
            "universal"
          ]
          ++ lib.optional stdenv.isLinux "linux"
          ++ lib.optional stdenv.isDarwin "macos";
        };

        hostXcrun = pkgs.writeShellScriptBin "xcrun" ''
          exec /usr/bin/xcrun "$@"
        '';

        # What building and testing the application needs: all that CI installs
        buildDeps = with pkgs; [
          # Flutter Linux host build deps
          pkg-config
          cmake
          clang

          # PDFium for `flutter test` (see SHOSAI_PDFIUM_LIBRARY below)
          pdfium-binaries
        ];

        # Android, release and editor tools for local development. CI builds no
        # Android target, and the Android SDK and NDK are unfree, so the public
        # binary cache does not carry them: every CI job would build them.
        devDeps = with pkgs; [
          androidJdk
          androidSdk
          git-cliff
          jujutsu
          hugo

          # LSP
          nodePackages.yaml-language-server
        ];

        androidEnv = {
          ANDROID_HOME = "${androidSdk}/libexec/android-sdk";
          ANDROID_SDK_ROOT = "${androidSdk}/libexec/android-sdk";
          ANDROID_NDK_HOME = "${androidSdk}/libexec/android-sdk/ndk-bundle";
          ANDROID_NDK_ROOT = "${androidSdk}/libexec/android-sdk/ndk-bundle";
          JAVA_HOME = androidJdk.home;
          GRADLE_OPTS = "-Dorg.gradle.project.android.aapt2FromMavenOverride=${androidSdk}/libexec/android-sdk/build-tools/36.0.0/aapt2";
        };

        # Linux-specific dependencies
        linuxDeps =
          with pkgs;
          lib.optionals stdenv.isLinux [
            # Flutter Linux desktop build deps
            gtk3
            ninja
            # Restores the engine library's $ORIGIN RUNPATH in release bundles
            patchelf

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
            xvfb-run
            xwininfo
            xdotool
            imagemagick
          ];

        macosDevDeps =
          with pkgs;
          lib.optionals stdenv.isDarwin [
            cocoapods
            hostXcrun
            # Flutter 3.41 relies on GNU rsync's --chmod before in-place lipo.
            rsync
          ];

        mkDevShell =
          {
            flutter,
            extraDeps ? [ ],
            env ? { },
          }:
          pkgs.mkShell (
            {
              nativeBuildInputs = [ flutter ] ++ buildDeps ++ linuxDeps ++ macosDevDeps ++ extraDeps;
            }
            // env
          // (lib.optionalAttrs stdenv.isLinux {
            # Linux: LD_LIBRARY_PATH for shared libraries
            LD_LIBRARY_PATH = lib.makeLibraryPath (with pkgs; [
              libxkbcommon
              wayland
              libx11
              libxcursor
              libxrandr
              libxi
              vulkan-loader
              # libEGL for the Flutter Linux host; it fails to start without one
              libGL
            ]);

            # Mesa as libglvnd's only EGL vendor, for headless runs under Xvfb
            # (`make test-packaged-linux`). Not set shell-wide: it would
            # hide every other vendor, such as a desktop's NVIDIA driver.
            SHOSAI_TEST_EGL_VENDOR = "${pkgs.mesa}/share/glvnd/egl_vendor.d/50_mesa.json";

            # The Flutter PDF engine tests load PDFium from here: `flutter test`
            # does not link pdfrx's native asset. Application bundles carry
            # pdfrx's own PDFium.
            SHOSAI_PDFIUM_LIBRARY = "${pkgs.pdfium-binaries}/lib/libpdfium.so";
          })
          // (lib.optionalAttrs stdenv.isDarwin {
            SHOSAI_PDFIUM_LIBRARY = "${pkgs.pdfium-binaries}/lib/libpdfium.dylib";

            # Builds use the host Apple SDK and system libraries rather than
            # embedding dependencies from the Nix SDK or store.
            shellHook = ''
              export DEVELOPER_DIR="$(env -u DEVELOPER_DIR /usr/bin/xcode-select --print-path)"
              export SDKROOT="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
              export PATH="${hostXcrun}/bin:$PATH"
              export MACOSX_DEPLOYMENT_TARGET=13.0
            '';
          })
          );
      in
      {
        devShells.default = mkDevShell {
          inherit flutter;
          extraDeps = devDeps;
          env = androidEnv;
        };

        # The shell CI uses: `nix develop .#ci`
        devShells.ci = mkDevShell { flutter = ciFlutter; };
      }
    );
}
