.PHONY: lint fmt check-fmt check
.PHONY: test test-app test-scripts test-epub-prototype
.PHONY: test-packaged-linux test-packaged-macos test-packaged-android
.PHONY: theme-tokens check-theme-tokens check-l10n-codegen
.PHONY: design-system design-system-css check-design-system-css
.PHONY: epub-prototype-fixtures measure-epub-prototype
.PHONY: dev linux-debug linux-release check-linux-bundle
.PHONY: android-profile android-release check-android-apk
.PHONY: macos-debug macos-smoke
.PHONY: ios-simulator-debug ios-device-profile ios-device-release
.PHONY: check-rfds changelog next-version

## Run static analysis for the app and Dart packages
## The packages' `pub get` must run before the app-root `flutter analyze`: that
## command walks into flutter/packages and needs each nested package's own
## package config to resolve its `package:test` imports on a fresh checkout.
lint:
	cd flutter/packages/shosai_epub && dart pub get
	cd flutter/packages/shosai_core && dart pub get
	cd flutter && flutter analyze
	cd flutter/packages/shosai_epub && dart analyze
	cd flutter/packages/shosai_core && dart analyze

## Format all Dart source files
fmt:
	cd flutter && dart format integration_test lib test packages/shosai_epub/lib packages/shosai_epub/test packages/shosai_core/lib packages/shosai_core/test

## Check Dart formatting without changing files
check-fmt:
	cd flutter && dart format --output=none --set-exit-if-changed integration_test lib test packages/shosai_epub/lib packages/shosai_epub/test packages/shosai_core/lib packages/shosai_core/test

## Regenerate the Flutter design-token module from assets/theme/tokens.json
theme-tokens:
	python3 scripts/generate-theme-tokens.py

## Verify the generated token module still matches the token source
check-theme-tokens:
	python3 scripts/generate-theme-tokens.py --check

DESIGN_SYSTEM_PORT ?= 8765

## Serve the design system viewer (docs/design-system.md) on localhost
## The repository root is served so the viewer can load assets/fonts and the
## app icon from their single tracked copies.
design-system:
	@echo "Shōsai design system: http://127.0.0.1:$(DESIGN_SYSTEM_PORT)/docs/design-system/"
	python3 -m http.server --bind 127.0.0.1 --directory "$(CURDIR)" $(DESIGN_SYSTEM_PORT)

## Regenerate docs/design-system/tokens.css from docs/design-system/tokens.json
design-system-css:
	python3 scripts/generate-design-system-css.py

## Verify docs/design-system/tokens.css still matches its token source
check-design-system-css:
	python3 scripts/generate-design-system-css.py --check

## Run the script, generated-source, Flutter and Dart package tests
test:
	$(MAKE) check-theme-tokens
	$(MAKE) test-scripts
	$(MAKE) check-l10n-codegen
	$(MAKE) test-app

## Run the app and Dart packages' tests (and the vendored PDFium hook's)
test-app:
	cd flutter && flutter test
	cd flutter/packages/shosai_epub && dart pub get && dart test
	cd flutter/packages/shosai_core && dart pub get && dart test
	cd flutter/third_party/pdfium_dart && dart pub get && dart test

## Run tests for repository scripts
test-scripts:
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover \
		-s benchmarks/epub-page-turn/2026-08-17/tests
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover \
		-s scripts/tests

## Run the Phase C Dart EPUB evaluation prototype's tests (isolated; see
## prototypes/epub-dart-eval/README.md). Not part of `make test`: the prototype
## is an evaluation artifact, not a shipped component.
test-epub-prototype:
	cd prototypes/epub-dart-eval && dart format --output=none --set-exit-if-changed lib test packages/shosai_epub/lib packages/shosai_epub/test
	cd prototypes/epub-dart-eval && flutter analyze
	cd prototypes/epub-dart-eval && flutter test
	cd prototypes/epub-dart-eval/packages/shosai_epub && dart analyze
	cd prototypes/epub-dart-eval/packages/shosai_epub && dart test
	python3 prototypes/epub-dart-eval/tool/generate_fixtures.py --check

## Regenerate the Phase C prototype fixtures (writes fixtures/ + SHA256SUMS)
epub-prototype-fixtures:
	python3 prototypes/epub-dart-eval/tool/generate_fixtures.py

## Build the prototype release bundle and run the measurement harness under
## Xvfb; writes prototypes/epub-dart-eval/artifacts/measurements/*.json
measure-epub-prototype:
	bash prototypes/epub-dart-eval/tool/measure.sh

## Verify generated Flutter localizations match the ARB catalogs
check-l10n-codegen:
	@./scripts/check-l10n-codegen.sh

## Run formatting, analysis, generated-source, script, app and package checks
check:
	$(MAKE) check-fmt lint
	$(MAKE) test

## Run the Linux host in debug mode
dev:
	cd flutter && flutter run -d linux

## Build the Linux host in debug mode
linux-debug:
	cd flutter && flutter build linux --debug

## Verify the built Linux Flutter host's bundle carries the declared fonts
## (the packaged-font regression; needs `linux-debug` first)
check-linux-bundle:
	PYTHONDONTWRITEBYTECODE=1 python3 scripts/check_flutter_bundle.py \
		flutter/build/linux/x64/debug/bundle

## Run the packaged-host integration tests on the Linux host under Xvfb, on X11
## with Mesa's EGL (from the Nix dev shell). No PDFium override is set, so the
## bundle's own PDFium and SQLite must load.
test-packaged-linux:
	cd flutter && env -u PDFIUM_PATH -u SHOSAI_PDFIUM_LIBRARY \
		GDK_BACKEND=x11 \
		__EGL_VENDOR_LIBRARY_FILENAMES="$${SHOSAI_TEST_EGL_VENDOR:?run in the Nix dev shell}" \
		xvfb-run -a -s '-screen 0 1280x1024x24' \
		flutter test -d linux integration_test/packaged_core_test.dart

## Run the packaged-host integration tests on the macOS host, likewise with no
## PDFium override
test-packaged-macos:
	env -u PDFIUM_PATH -u SHOSAI_PDFIUM_LIBRARY ./scripts/build-flutter-macos.sh \
		test -d macos integration_test/packaged_core_test.dart

## Run the packaged-host integration tests in a profile build (AOT, with the
## release build's native libraries; Flutter Driver refuses release mode) on a
## connected Android device or emulator (ANDROID_DEVICE picks one), likewise
## with no PDFium override
test-packaged-android:
	cd flutter && env -u PDFIUM_PATH -u SHOSAI_PDFIUM_LIBRARY \
		flutter drive --profile --driver=integration_test/driver.dart \
		--target=integration_test/packaged_core_test.dart \
		$(if $(ANDROID_DEVICE),-d $(ANDROID_DEVICE))

## Build the Android arm64 host in profile mode
android-profile:
	cd flutter && flutter build apk --profile --target-platform android-arm64

## Build the universal Android APK (every ABI) in release mode
android-release:
	cd flutter && flutter build apk --release

## Verify the universal release APK carries Flutter, the app, PDFium and SQLite
## for every ABI (needs `android-release` first)
check-android-apk:
	PYTHONDONTWRITEBYTECODE=1 python3 scripts/check_android_apk.py \
		flutter/build/app/outputs/flutter-apk/app-release.apk

## Build the macOS host in debug mode
macos-debug:
	@./scripts/build-flutter-macos.sh

## Build the iOS host for an Apple Silicon simulator in debug mode
ios-simulator-debug:
	@./scripts/build-flutter-ios.sh simulator debug

## Build the iOS host for physical devices in unsigned profile mode
ios-device-profile:
	@./scripts/build-flutter-ios.sh device profile

## Build the iOS host for physical devices in unsigned release mode
ios-device-release:
	@./scripts/build-flutter-ios.sh device release

## Launch the packaged macOS host and verify that it remains running
macos-smoke: macos-debug
	@set -eu; \
		app="flutter/build/macos/Build/Products/Debug/shosai_flutter.app"; \
		verify_signatures() { \
			/usr/bin/codesign --verify --deep --strict --verbose=2 "$$app"; \
		}; \
		verify_signatures; \
		$(MAKE) macos-debug; \
		verify_signatures; \
		log="$$(mktemp)"; \
		"$$app/Contents/MacOS/shosai_flutter" >"$$log" 2>&1 & pid=$$!; \
		trap 'kill "$$pid" 2>/dev/null || true; wait "$$pid" 2>/dev/null || true; rm -f "$$log"' EXIT; \
		sleep 5; \
		if ! kill -0 "$$pid" 2>/dev/null; then \
			cat "$$log"; \
			exit 1; \
		fi

## Build the Linux host in release mode
linux-release:
	cd flutter && flutter build linux --release

## Validate RFD sources and the checker regression fixtures
check-rfds:
	@./scripts/check-rfd-status.sh
	@./scripts/check-rfd-status-test.sh

## Regenerate CHANGELOG.md from conventional commits
changelog:
	git cliff -o CHANGELOG.md

## Print the next semantic version inferred from conventional commits
next-version:
	git cliff --bumped-version
