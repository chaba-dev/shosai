.PHONY: dev reset lint fmt test test-scripts check-frb check-rfds changelog next-version

DEV_DATA_HOME := $(CURDIR)/target

## Run the application in debug mode
dev:
	XDG_DATA_HOME="$(DEV_DATA_HOME)" SHOSAI_DEV_BUILD=1 cargo run -p shosai-app

## Delete development-only Shosai data and development-owned managed copies
reset:
	@XDG_DATA_HOME="$(DEV_DATA_HOME)" python3 scripts/reset-local-data.py

## Run clippy lints on the workspace
lint:
	cargo clippy --workspace --all-targets -- -D warnings

## Format all Rust source files
fmt:
	cargo fmt --all

## Run all tests
test:
	cargo test --workspace --no-fail-fast
	$(MAKE) test-scripts
	$(MAKE) check-frb

## Run tests for repository scripts
test-scripts:
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover \
		-s benchmarks/epub-page-turn/2026-08-17/tests
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover \
		-s scripts/tests

## Verify that the core bridge API is accepted by flutter_rust_bridge codegen
check-frb:
	@./scripts/check-frb-codegen.sh

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
