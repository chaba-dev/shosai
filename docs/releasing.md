# Releasing Shosai

Shōsai releases are prepared from Conventional Commit titles and reviewed through a rolling release pull request. The production app ID is `dev.shosai.reader` on all platforms. Once Play publishing is configured, merging the release PR starts the Android Production release. Check the release build and Play publishing queue before merging.

## Release flow

1. Each pull request title must use an allowed Conventional Commit type. The repository must use squash merges with the pull request title as the resulting commit subject.
2. A push to `main` updates `release/next`. The workflow merges the new `main` revision into the existing release branch, then appends a release commit instead of rewriting branch history. If the branch was deleted after an earlier pull request, the workflow recovers its last pull-request head before appending. Git-cliff calculates the next semantic version, sets the application version in `pubspec.yaml` (keeping its build number), regenerates `CHANGELOG.md`, and creates or refreshes the release pull request.
3. Review the required `docs/releases/X.Y.Z.md` and verify production builds from the release revision. The release-notes workflow checks for the notes; it does not package the app.
4. Merging the release PR validates that its `chore(release): vX.Y.Z` title matches the `pubspec.yaml` version and creates the tag on the merge commit. The release bot’s new tag triggers the Android Production build and Play upload. It does not publish a GitHub Release.

The tag workflow accepts an existing tag only when it points to the expected release merge commit.

## Semantic versions and changelog groups

- `feat` produces a minor bump.
- `fix` produces a patch bump.
- A `!` or `BREAKING CHANGE:` footer produces a major bump.
- Other allowed types produce a patch bump and are included in their configured changelog group.
- `docs(plan): ...` is reserved for planning-only changes and is excluded from changelogs and version inference.
- The first release is `v0.1.0`.

Run `make next-version` to inspect the inferred version and `make changelog` to regenerate the changelog locally. Both commands use `cliff.toml`.

## Build and verify the production identity

| Platform | Development ID (the default, even in release mode) | Production command |
| --- | --- | --- |
| Android | `dev.shosai.shosai` | `make android-production` (AAB; requires an upload keystore) |
| iOS | `dev.shosai.shosai` | `make ios-device-production` (unsigned device build) |
| macOS | `dev.shosai.shosai-flutter` | `make macos-production` (local bundle; see ARM64 settings below) |
| Linux | `dev.shosai.shosai_flutter` | `make linux-production` (local bundle with `shosai_flutter` executable) |

Use the pinned toolchain and the production targets on the appropriate host. The targets pass `SHOSAI_PRODUCTION=true` to Flutter; on Apple they also select `darwin/Production.xcconfig`. For a signed Apple archive, carry both settings into the archive build and supply the approved signing configuration. An iOS distributor xcconfig can include `darwin/Production.xcconfig` and add `GOOGLE_DRIVE_IOS_CALLBACK_SCHEME`; pass its absolute path as `SHOSAI_PRODUCTION_XCCONFIG` to the make target. Don't put the production flag in a shared development defines file.

If a direct Xcode build rejects a bundle ID and Flutter edition mismatch, run the corresponding Flutter build to regenerate the settings. On Xcode 27.2, the verified macOS build is ARM64: create a local xcconfig that `#include`s the absolute path to `darwin/Production.xcconfig` and adds `ARCHS = arm64`, then run `SHOSAI_PRODUCTION_XCCONFIG=/absolute/path/to/local.xcconfig .agents/dev make macos-production`. Universal macOS builds are unverified; the two-architecture `lipo -verify_arch` check failed when tested separately on Xcode 27.2.

Set the production Android signing inputs `SHOSAI_ANDROID_KEYSTORE` (absolute path), `SHOSAI_ANDROID_STORE_PASSWORD`, `SHOSAI_ANDROID_KEY_ALIAS`, and `SHOSAI_ANDROID_KEY_PASSWORD` in a private build environment. The production build does not fall back to debug signing. Verify the AAB's package and upload certificate before upload, then verify the installed Play build's **app-signing** SHA-1 for Google Drive. See [build credentials](build-credentials.md), [Google Drive](google-drive.md), and [Dropbox](dropbox.md) for the separate production registrations. If supplied, `SHOSAI_BUILD_DEFINES_FILE` points to the release build's Dart configuration.

**Keep the development install to retain its data.** Production installs separately with an empty library and no copied credentials. Use different `.app` paths for dev and production on macOS. On the Pixel lab, `dev.shosai.shosai` is the owner's library, not a test slot: never uninstall it or target it with Flutter Driver. Use an audited disposable package for automated device tests instead. The device-lab package, signing, and install checks still apply to both editions.

## Release on Google Play from GitHub Actions

| Track | What starts the release | What GitHub builds and uploads |
| --- | --- | --- |
| Internal testing | Manually run [**Publish Shosai to Google Play**](https://github.com/chaba-dev/shosai/actions/workflows/play-release.yml) from `main` and confirm that Publishing overview is clear. | A signed bundle from the selected `main` revision. No second approval. |
| Production | Merge `release/next` into `main` through its release PR. The workflow accepts only a new release-bot tag matching that merged PR and its version. | A fresh signed bundle from the exact merge commit, submitted for full rollout subject to Play review and publishing settings. No dispatch or second approval. |

**Before dispatching Internal or merging a release PR:** Check Play Console’s **Publishing overview** for unrelated changes ready to send, and coordinate with other publishers until the job finishes. Play commits edits app-wide. The workflow refuses to cancel an existing review but cannot detect unrelated unsent Console changes.

The version name comes from `pubspec.yaml`; both tracks share one version-code sequence (`10000 +` the Play workflow run number). If the upload fails, check Play Console before retrying: a rerun uses the same code, and Play may already have accepted it. For a Production retry, rerun the original Play workflow rather than moving or recreating its tag. Verify the final state in Play Console; an accepted API commit is not proof that the release is live.

### One-time setup

1. Create Shōsai in Play Console as a **Free App**. Manually upload the first production AAB for `dev.shosai.reader` to **Internal testing**, accept Google-managed **Play App Signing**, and finish the initial internal rollout. Keep the upload key and passwords backed up privately. Confirm all previously uploaded version codes are below the automated range before enabling CI uploads.
2. Before storing the upload key in `RELEASE`, verify that `main` is protected and that active GitHub rulesets cover every tag admitted by `RELEASE` (`v*`): only the release bot can create those tags, and no one, including the bot, can move or delete them. Use separate rulesets for creation and immutability so the bot bypass applies only to creation. If the key is already stored and these protections are missing, remove the four Android signing secrets until the rules are active. A workflow actor check does not protect environment secrets from another workflow on an unprotected ref.
3. In `RELEASE`, keep the existing [release build credentials](build-credentials.md) and add `SHOSAI_ANDROID_KEYSTORE_BASE64`, `SHOSAI_ANDROID_STORE_PASSWORD`, `SHOSAI_ANDROID_KEY_ALIAS`, and `SHOSAI_ANDROID_KEY_PASSWORD` through GitHub’s secret input. Use the registered upload key; the first secret contains its base64-encoded keystore. Signed bundles are retained for seven days and are downloadable by signed-in users from this public repo’s Actions runs. Never embed confidential credentials in build defines.
4. In Google Cloud, enable the Android Publisher API. Give each track its own workload identity **pool**, GitHub OIDC provider, and service account, separate from the `RELEASE` build-secret federation. Map `attribute.repository_id=assertion.repository_id` and grant `roles/iam.workloadIdentityUser` on each service account only to `principalSet://iam.googleapis.com/projects/PROJECT_NUMBER/locations/global/workloadIdentityPools/TRACK_POOL_ID/attribute.repository_id/1194321001` for its own pool. IAM principal sets are pool-scoped, not provider-scoped.
   - Both providers must require repository ID `1194321001` and owner ID `44737549`.
   - Internal must require `PLAY_INTERNAL`, `workflow_dispatch`, `refs/heads/main`, and `workflow_ref == 'chaba-dev/shosai/.github/workflows/play-release.yml@refs/heads/main'`.
   - Production must require `PLAY_PRODUCTION`, `push`, release-bot actor ID `305388421`, a `refs/tags/vX.Y.Z` ref, and `workflow_ref == 'chaba-dev/shosai/.github/workflows/play-release.yml@' + assertion.ref`.
5. Create GitHub environments `PLAY_INTERNAL` (`main` only) and `PLAY_PRODUCTION` (`v*` tags only), without required reviewers. In each, set `SHOSAI_PLAY_PROVIDER` and `SHOSAI_PLAY_SERVICE_ACCOUNT` for that track. Before enabling Play uploads, verify that each identity can impersonate its own publisher and that cross-track impersonation is denied in both directions. No Play upload is needed for this check.
6. In **Play Console → Users and permissions**, grant the service accounts access to Shōsai only: **Release apps to testing tracks** for `shosai-play-internal@shosai-512821.iam.gserviceaccount.com`, and the app-scoped production release permission for the separate production account. Confirm the app is eligible for Production. Do not grant account admin or issue a JSON key.

## Linux distribution (x86-64)

| Option | Install or build | Runtime |
| --- | --- | --- |
| Flatpak | `flatpak install --user ./shosai-X.Y.Z-linux-x64.flatpak`; launch with `flatpak run dev.shosai.reader` | GNOME 51 from Flathub; a desktop portal and Secret Service on the host |
| Debian package | `sudo apt install ./shosai-X.Y.Z-linux-x64.deb`; launch Shōsai from the application menu | Ubuntu 24.04 or Debian 13 and compatible newer releases; APT resolves GTK and libsecret |
| Nix | `nix develop .#ci --command make linux-production`; run `build/linux/x64/release/bundle/shosai_flutter` | The pinned Nix shell/store and a desktop keyring; do not redistribute this bundle as a portable download |

The Flatpak and `.deb` both use the `dev.shosai.reader` desktop entry, icon and AppStream ID. The Flatpak uses the desktop file chooser portal for host files, keeps app data under `~/.var/app/dev.shosai.reader`, and talks directly to the host `org.freedesktop.secrets` service via libsecret. Both bundles include PDFium, SQLite, Inter and Noto Sans JP. An unlocked Secret Service provider (for example GNOME Keyring) is required to save sign-ins. Install the Flathub remote first if it is not configured. Sideloading this bundle is not a Flathub listing; submission as `dev.shosai.reader` requires project control of `shosai.dev` and Flathub review.

Build the distributable bundles in a clean **native Ubuntu 24.04** environment, not in `nix develop`. The [Linux release workflow](../.github/workflows/release-linux.yml) lists the SDK, runtime and build dependencies. Run `flutter pub get --enforce-lockfile`, `make linux-production` (with the authorized defines file for a release), then `bash scripts/package-linux.sh`. The script validates fonts, notices and ELF dependencies; it writes and measures the two assets in `target/release-dist/`. Smoke-test the installed assets in separate non-Nix desktop sessions: open the library, import and open `fixtures/sample.pdf` and `fixtures/sample.epub`, then save a test cloud sign-in and restart the app to confirm it can recover the credential from the keyring.

The draft-release workflow can call `./.github/workflows/release-linux.yml` as a job after tag validation, passing `needs.validate.outputs.commit` as `commit` and granting `contents: read` and `id-token: write`. Make the draft job depend on that job, download `release-linux-desktop` alongside the other `release-*` artifacts, and add the `.deb` and `.flatpak` names above to the draft packager's expected assets and checksum list. The Linux job only builds artifacts; it does not create a tag or a release. The Nix build remains a separate source-build option.

## Required repository settings

The workflows rely on these GitHub settings:

- Allow only squash merges and use the pull request title as the default squash commit subject.
- Protect `main` from direct pushes and require the `Validate title` and normal CI checks.
- Require the `Release notes` check before merging `release/next`.
- Require release pull requests to be up to date before merging, or use a merge queue, so the reviewed changelog covers every commit in the tagged merge.
- Install the private `chaba2-bot` GitHub App on this repository with `Contents: write` and `Pull requests: write` repository permissions.
- Create the `RELEASE` Actions environment, store the App ID in its `RELEASE_APP_ID` variable, and store the PEM private key in its `RELEASE_APP_SECRET` secret.
- Allow `chaba2-bot` to push updates to the `release/next` branch.

The release PR and tag jobs use `RELEASE` GitHub App credentials to update release branches and tags. The Android build job uses `RELEASE` for signing and build configuration; it does not request the GitHub App credentials. The built-in `GITHUB_TOKEN` is read-only.
