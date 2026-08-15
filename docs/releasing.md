# Releasing Shosai

Shosai releases are prepared from Conventional Commit titles and reviewed through a rolling release pull request.

## Release flow

1. Each pull request title must use an allowed Conventional Commit type. The repository must use squash merges with the pull request title as the resulting commit subject.
2. A push to `main` updates `release/next`. Git-cliff calculates the next semantic version, updates the workspace version and lockfile, regenerates `CHANGELOG.md`, and creates or refreshes the release pull request.
3. The exact `release/next` commit is dry-run through the full three-platform package matrix with publishing disabled. The release PR receives a `Release build dry run` commit status, so it cannot be mistaken for a releasable revision while packages are pending or failing. Ordinary feature pull requests do not run this release matrix.
4. Merging that pull request into the default branch validates that its `chore(release): vX.Y.Z` title matches the workspace version and creates the tag on the merge commit.
5. Release jobs repeat the same builds, bundle PDFium, and attach installable packages and checksums to the GitHub release. A manually pushed `vX.Y.Z` tag runs the same publisher after validating the tag against the workspace version.

The automatic flow is retry-safe: an existing tag is accepted only when it points to the expected release merge commit, and a missing GitHub release can be recreated on a rerun.

## Semantic versions and changelog groups

- `feat` produces a minor bump.
- `fix` produces a patch bump.
- A `!` or `BREAKING CHANGE:` footer produces a major bump.
- Other allowed types produce a patch bump and are included in their configured changelog group.
- `docs(plan): ...` is reserved for planning-only changes and is excluded from changelogs and version inference.
- The first release is `v0.1.0`.

Run `make next-version` to inspect the inferred version and `make changelog` to regenerate the changelog locally. Both commands use `cliff.toml`.

## Desktop packages

Each release contains three native packages:

- `shosai-<version>-x86_64-unknown-linux-gnu.tar.gz`
- `shosai-<version>-aarch64-unknown-linux-gnu.tar.gz`
- `Shosai-<version>-macos-aarch64.zip`

Linux packages contain an optimized binary, PDFium, licenses, a desktop entry, and `install.sh`. Extract the archive and run `./install.sh`; it installs under `~/.local` by default. Set `SHOSAI_INSTALL_PREFIX` to choose another user-writable prefix.

The macOS zip contains `Shosai.app`. Extract it and move the application into `/Applications` or `~/Applications`. The bundle is ad-hoc signed but is not yet Developer ID signed or notarized, so macOS may show a Gatekeeper warning for downloaded releases.

PDFium is pinned to the checksummed `chromium/7999` binaries from `bblanchon/pdfium-binaries`. Shosai resolves the bundled library relative to its executable and falls back to the system library for development builds.

## Required repository settings

The workflows rely on these GitHub settings:

- Allow only squash merges and use the pull request title as the default squash commit subject.
- Protect `main` from direct pushes and require the `Validate title` and normal CI checks.
- Require the `Release build dry run` commit status before merging `release/next`.
- Require release pull requests to be up to date before merging, or use a merge queue, so the reviewed changelog covers every commit in the tagged merge.
- Install the private `chaba2-bot` GitHub App on this repository with `Contents: write`, `Pull requests: write`, and `Commit statuses: write` repository permissions.
- Create the `RELEASE` Actions environment, store the App ID in its `RELEASE_APP_ID` variable, and store the PEM private key in its `RELEASE_APP_SECRET` secret.
- Allow `chaba2-bot` to update the `release/next` branch with force-with-lease.

Only mutation jobs enter the `RELEASE` environment and receive its credentials. Release package builds, including dry runs, remain credential-free. Mutation jobs exchange the credentials for short-lived, repository-scoped `chaba2-bot` installation tokens: release commits and branch pushes, release pull-request creation and updates, dry-run statuses, tags, and GitHub releases. The built-in `GITHUB_TOKEN` is read-only. App-authored branch and tag events are not suppressed by GitHub's recursive-workflow protection, so the normal PR checks and tag workflow can run.

The release does not publish the workspace crates to crates.io. Windows packaging, macOS Developer ID signing and notarization, Linux AppImage/Flatpak packages, and application icons remain separate distribution work.
