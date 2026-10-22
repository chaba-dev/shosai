.PHONY: lint lint-rust lint-flutter fmt fmt-rust fmt-flutter check-fmt-rust check-fmt-flutter test test-rust test-flutter test-scripts check-frb check-flutter-codegen check-l10n-codegen flutter-codegen check-flutter flutter-dev flutter-linux-debug flutter-android-profile flutter-macos-debug flutter-macos-smoke flutter-ios-simulator-debug flutter-ios-device-profile flutter-ios-device-release flutter-release measure-flutter-m2 check-rfds changelog next-version theme-tokens check-theme-tokens design-system design-system-css check-design-system-css test-epub-prototype epub-prototype-fixtures measure-epub-prototype flutter-bundle-check-linux

## Run clippy lints on the workspace
lint: lint-rust lint-flutter

## Run Rust lints
lint-rust:
	cargo clippy --workspace --all-targets -- -D warnings

## Run Flutter static analysis
## The packages' `pub get` must run before the app-root `flutter analyze`: that
## command walks into flutter/packages and needs each nested package's own
## package config to resolve its `package:test` imports on a fresh checkout.
lint-flutter:
	cd flutter/packages/shosai_epub && dart pub get
	cd flutter/packages/shosai_core && dart pub get
	cd flutter && flutter analyze
	cd flutter/packages/shosai_epub && dart analyze
	cd flutter/packages/shosai_core && dart analyze

## Format all Rust and Dart source files
fmt: fmt-rust fmt-flutter

## Format Rust source files
fmt-rust:
	cargo fmt --all

## Format Dart source files
fmt-flutter:
	cd flutter && dart format integration_test lib test packages/shosai_epub/lib packages/shosai_epub/test packages/shosai_core/lib packages/shosai_core/test

## Check Rust formatting without changing files
check-fmt-rust:
	cargo fmt --all -- --check

## Check Dart formatting without changing files
check-fmt-flutter:
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

## Run all Rust, script, bridge, and Flutter tests
test:
	$(MAKE) check-theme-tokens
	$(MAKE) test-rust
	$(MAKE) test-scripts
	$(MAKE) check-frb
	$(MAKE) check-flutter-codegen
	$(MAKE) check-l10n-codegen
	$(MAKE) test-flutter

## Run Rust workspace tests
test-rust:
	cargo test --workspace --no-fail-fast

## Build the bridge and run Flutter unit and native bridge tests
test-flutter:
	cargo build --package shosai-flutter-bridge
	cd flutter && flutter test
	cd flutter/packages/shosai_epub && dart pub get && dart test
	cd flutter/packages/shosai_core && dart pub get && dart test

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

## Verify that the core bridge API is accepted by flutter_rust_bridge codegen
check-frb:
	@./scripts/check-frb-codegen.sh

## Verify checked-in Flutter bindings match the bridge API
check-flutter-codegen:
	@./scripts/check-flutter-codegen.sh

## Verify generated Flutter localizations match the ARB catalogs
check-l10n-codegen:
	@./scripts/check-l10n-codegen.sh

## Generate Rust/Dart bindings
flutter-codegen:
	cd flutter && flutter_rust_bridge_codegen generate
	cargo fmt --package shosai-flutter-bridge

## Validate generated bindings and the Flutter host
check-flutter: check-flutter-codegen
	$(MAKE) check-fmt-flutter lint-flutter
	$(MAKE) test-flutter

## Run the Linux Flutter host in debug mode
flutter-dev: flutter-codegen
	cd flutter && flutter run -d linux

## Build the Linux Flutter host in debug mode
flutter-linux-debug:
	cd flutter && flutter build linux --debug

## Verify the built Linux Flutter host's bundle carries the declared fonts
## (the packaged-font regression; needs `flutter-linux-debug` first)
flutter-bundle-check-linux:
	PYTHONDONTWRITEBYTECODE=1 python3 scripts/check_flutter_bundle.py \
		flutter/build/linux/x64/debug/bundle

## Build the Android arm64 Flutter host in profile mode
flutter-android-profile:
	cd flutter && flutter build apk --profile --target-platform android-arm64

## Build the macOS Flutter host in debug mode
flutter-macos-debug:
	@./scripts/build-flutter-macos.sh

## Build the iOS host for an Apple Silicon simulator in debug mode
flutter-ios-simulator-debug:
	@./scripts/build-flutter-ios.sh simulator debug

## Build the iOS host for physical devices in unsigned profile mode
flutter-ios-device-profile:
	@./scripts/build-flutter-ios.sh device profile

## Build the iOS host for physical devices in unsigned release mode
flutter-ios-device-release:
	@./scripts/build-flutter-ios.sh device release

## Launch the packaged macOS host and verify that it remains running
flutter-macos-smoke: flutter-macos-debug
	@set -eu; \
		app="flutter/build/macos/Build/Products/Debug/shosai_flutter.app"; \
		verify_signatures() { \
			/usr/bin/codesign --verify --strict "$$app/Contents/Frameworks/libshosai_flutter_bridge.dylib"; \
			/usr/bin/codesign --verify --strict "$$app/Contents/Frameworks/libpdfium.dylib"; \
			/usr/bin/codesign --verify --deep --strict --verbose=2 "$$app"; \
		}; \
		verify_signatures; \
		$(MAKE) flutter-macos-debug; \
		verify_signatures; \
		log="$$(mktemp)"; \
		"$$app/Contents/MacOS/shosai_flutter" >"$$log" 2>&1 & pid=$$!; \
		trap 'kill "$$pid" 2>/dev/null || true; wait "$$pid" 2>/dev/null || true; rm -f "$$log"' EXIT; \
		sleep 5; \
		if ! kill -0 "$$pid" 2>/dev/null; then \
			cat "$$log"; \
			exit 1; \
		fi

## Build the Linux Flutter host in release mode
flutter-release: flutter-codegen
	cd flutter && flutter build linux --release

## Run the RFD 4 M2 profile measurements (DEVICE must be a Flutter device ID)
measure-flutter-m2:
	@test -n "$(DEVICE)" || { echo "DEVICE is required" >&2; exit 2; }
	@python3 scripts/m2-measurements.py --device "$(DEVICE)" \
		--output "$(or $(OUTPUT),target/m2-measurements/$(DEVICE).json)"

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
