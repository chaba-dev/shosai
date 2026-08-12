.PHONY: dev lint fmt test changelog next-version

## Run the application in debug mode
dev:
	cargo run -p shosai-app

## Run clippy lints on the workspace
lint:
	cargo clippy --workspace --all-targets -- -D warnings

## Format all Rust source files
fmt:
	cargo fmt --all

## Run all tests
test:
	cargo test --workspace --no-fail-fast

## Regenerate CHANGELOG.md from conventional commits
changelog:
	git cliff -o CHANGELOG.md

## Print the next semantic version inferred from conventional commits
next-version:
	git cliff --bumped-version
