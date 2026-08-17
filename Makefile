.PHONY: dev lint fmt test test-scripts changelog next-version

## Run the application in debug mode
dev:
	SHOSAI_DEV_BUILD=1 cargo run -p shosai-app

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

## Run tests for repository scripts
test-scripts:
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover \
		-s benchmarks/epub-page-turn/2026-08-17/tests

## Regenerate CHANGELOG.md from conventional commits
changelog:
	git cliff -o CHANGELOG.md

## Print the next semantic version inferred from conventional commits
next-version:
	git cliff --bumped-version
