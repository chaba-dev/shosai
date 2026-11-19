# Apple privacy manifest audit

The iOS build now compiles the same SQLite 3.53.4 engine without `statfs` or
`fstatfs` calls, retains POSIX locking and WAL, and bundles framework-local SQLite and
PDFium privacy manifests. The unsigned release archive contains all 17 expected
manifests and no SQLite `statfs`/`fstatfs` imports. Android and desktop retain
their existing SQLite binaries. This resolves the identified declaration gap
locally; it is not Apple submission approval.

Audited on 2026-11-16 and implemented on 2026-11-17 against `origin/main` at
[`211f493f`](https://github.com/chaba-dev/shosai/commit/211f493f), Flutter 3.41.5 and
`pubspec.lock`; the release change is based on
[`68cb423d`](https://github.com/chaba-dev/shosai/commit/68cb423d). Packaging and
Simulator verification used a cloud Mac. No iPhone or iPad was installed
onto, uninstalled from, or read.

## App declarations

Both Runner targets copy the same source file through their Resources phase.
iOS places it at `Runner.app/PrivacyInfo.xcprivacy`; macOS places it at
`shosai_flutter.app/Contents/Resources/PrivacyInfo.xcprivacy`.

| Category | App declaration | Evidence and boundary |
| --- | --- | --- |
| File timestamps / metadata | `C617.1`, `3B52.1` | `packages/shosai_core/lib/src/library/files.dart` fingerprints files and detects changes; `library.dart` and `lib/core/documents.dart` sweep stale private files. `darwin/FolderLocations.swift` reads size and modification date for user-granted folders. Covers app-container files and user-selected files/folders, not arbitrary filesystem inspection. |
| UserDefaults | None in app manifest | App preferences use the SQLite store (`packages/shosai_core/lib/src/preferences.dart`), not UserDefaults. Google SDK use is declared in its own resources below. |
| Disk space | None in app manifest | No app capacity query or low-space admission check was found. Cache byte accounting is not available-disk-space inspection. The iOS SQLite build removes its `statfs`/`fstatfs` imports rather than inaccurately declaring `E174.1`. |
| System boot time | None in app manifest | Flutter's iOS framework manifest declares `35F9.1` for timers/elapsed time. No direct app-native call was found. FlutterMacOS supplies an empty required-reason declaration. |
| Active keyboards | None | No `activeInputModes` use found in app/plugin source searched. |
| Tracking | `false`; no tracking domains | No advertising SDK, ATT request, cross-app tracking or telemetry endpoint found in app code. Authentication/API domains are not tracking domains. |
| App-collected data | Empty array | No Shōsai backend or telemetry receiver exists in the audited paths. Books, reading state, notes, searches, preferences and diagnostic state are processed/stored locally. This is **not** a claim that every bundled SDK declares no collection. |

Include the manifest on macOS for the same app behavior and accurate packaging.
Apple documents its macOS location and supports the keys there. Apple's current
required-reason enforcement description lists iOS/iPadOS/tvOS/visionOS/watchOS,
not macOS; this audit does not assert an identical macOS submission mandate.

## Cloud authorization and data leaving the device

`lib/core/connection_credentials.dart` uses Keychain on Apple platforms.
Dropbox refresh tokens and Drive credential JSON are not written into the
library or preferences. Access tokens are used in HTTPS requests to the chosen
provider; refresh tokens are sent to that provider's token endpoint. “Stay on
the device” means no Shōsai server receives/stores them, **not** that a token is
never transmitted to its issuer.

Dropbox uses browser OAuth/PKCE through AppAuth on iOS and an external browser
on macOS. Drive also uses AppAuth on iOS and browser/loopback OAuth on macOS;
`GoogleSignIn` API calls in `google_drive_authorization.dart` are Android-only.
Provider requests list/read the user's chosen cloud storage. Both location
implementations expose upload methods, but no application caller of those
methods was found. There is no implemented reading-record sync or automatic
book/annotation upload in the audited app.

Google's Apple SDK is nevertheless bundled and instantiated during generated
plugin registration (`GoogleSignInPlugin.register` → `GIDSignInWrapper` →
`GIDSignIn.sharedInstance`); it cannot be treated as absent merely because
interactive Apple authorization uses AppAuth. Its manifest declares the
following linked, non-tracking data. Preserve it unchanged and account for it
in the release's aggregate privacy review:

| GoogleSignIn data type | Declared purposes |
| --- | --- |
| Name, email address, phone number, coarse location | App functionality |
| User ID, other data types | App functionality and analytics |
| Device ID, other usage data | Analytics |

These are the SDK's supplied declarations, not a runtime measurement proving
that every category is collected in every Shōsai session. Google's hosted
account/sign-in pages have their own collection practices. No blanket “Data
Not Collected” App Store answer is justified by the empty **app** array alone.

## Existing SDK manifests survive packaging

The unsigned iOS **release archive** contains 17 parseable manifests: the
app's, all 14 supplied SDK resources and the two added native-library
manifests. The macOS **debug** app previously verified for the shared app
manifest contains 15; its native libraries and packaging are unchanged by the
iOS fix. Every inspected manifest declares tracking false and an empty
tracking-domain array. Only GoogleSignIn declares collected data types.

| Resolved dependency | Bundled privacy resource(s) / relevant declarations |
| --- | --- |
| Flutter 3.41.5 | `Flutter.framework` on iOS: file metadata `0A2A.1`, `C617.1`; boot time `35F9.1`. `FlutterMacOS.framework` has no required-reason entries despite `stat`/`mach_absolute_time` imports; macOS is outside Apple's currently listed required-reason enforcement platforms. |
| file_selector_ios 0.5.3+6 / file_selector_macos 0.9.5+1 | `file_selector_*_privacy.bundle`; no collection or required-reason entries |
| flutter_appauth 12.1.0 | `flutter_appauth_privacy.bundle`; no collection or required-reason entries |
| flutter_secure_storage_darwin 0.4.3 | `flutter_secure_storage.bundle`; Keychain, no collection or required-reason entries |
| google_sign_in_ios 6.3.8 | `google_sign_in_ios_privacy.bundle`; wrapper declares no collection |
| url_launcher_ios 6.4.2 / url_launcher_macos 3.2.6 | `url_launcher_*_privacy.bundle`; no collection or required-reason entries |
| GoogleSignIn 9.2.0 | `GoogleSignIn.bundle`; data table above, UserDefaults `CA92.1` |
| GoogleUtilities 8.1.5 | `GoogleUtilities_Privacy.bundle`; file metadata `C617.1`, UserDefaults wrapper `C56D.1` |
| GTMSessionFetcher 3.5.0 | Core and Full privacy bundles; Core declares UserDefaults `CA92.1` |
| AppAuth 2.1.0, GTMAppAuth 5.0.0 | `AppAuthCore_Privacy.bundle`, `GTMAppAuth_Privacy.bundle`; no collection/required-reason entries |
| PromisesObjC / PromisesSwift 2.4.1 | `FBLPromises_Privacy.bundle`, `Promises_Privacy.bundle`; no collection/required-reason entries |

`path_provider_foundation` 2.6.0 is a Dart/FFI implementation of Foundation
directory lookup, not a CocoaPod with a missing resource. AppCheckCore 11.3.2
and RecaptchaInterop 101.0.0 have no supplied manifest; their presence does not
by itself prove network collection. AppCheckCore's defaults access uses the
GoogleUtilities wrapper. No manifest was fabricated for either dependency.

## iOS native libraries now carry matching declarations

`nm -u` on the archived iOS libraries verifies the remaining imports:

| Library | Remaining file-metadata imports | Added framework-local declaration |
| --- | --- | --- |
| SQLite 3.53.4, Dart bindings 3.5.2 | `stat`, `fstat`, `lstat`; no `statfs` or `fstatfs` | FileTimestamp `C617.1`: private database, journal and WAL files |
| PDFium chromium 7811, unchanged machine code | `stat`, `fstat` | FileTimestamp `C617.1`, `3B52.1`: private and user-granted document files |

Imports prove that the binary references an API, not that every code path was
exercised. SQLite 3.53.4's `src/os_unix.c` calls `statfs`/`fstatfs` for filesystem
type and mount/locking flags. The app does not check available disk capacity.
Apple's `E174.1` requires a user-observable sufficient-space/low-space behavior;
it is not a generic SQLite permission. The upstream maintainer confirms the
reason mismatch in [sqlite3.dart issue 410](https://github.com/simolus3/sqlite3.dart/issues/410).
Neither added manifest declares tracking, tracking domains or collected data.
The fix removes SQLite's iOS `statfs`/`fstatfs` paths instead of claiming a
capacity-related reason for them. Mac admission uses only the type-specific
Foundation key described below.

`scripts/embed-ios-privacy.sh` runs after Flutter and CocoaPods embed their
frameworks. It installs both manifests and re-signs the frameworks when
signing is enabled, before Runner's final signing. Strict signature checks
passed for both frameworks and the enclosing Simulator app. Distribution
signing has not been exercised. This works around the native-assets resource
gap tracked in [dart-lang/native issue 878](https://github.com/dart-lang/native/issues/878).

## The source exclusion retains normal POSIX locks

The 2026-11-17 investigation built three variants of SQLite 3.53.4, using the
package's default compiler defines plus the differences below. Xcode 27.2
compiled arm64 device dylibs targeting iOS 15 and arm64 Simulator executables.
The executables ran in iOS 27.2 Simulator on a cloud Mac's APFS data volume.
This is not real-device or full-app validation.

| Build | Excluded behavior | Device dylib imports | POSIX/WAL probe |
| --- | --- | --- | --- |
| Upstream source baseline | None | `statfs`, `fstatfs` | Passed |
| `SQLITE_ENABLE_LOCKING_STYLE=0` | Automatic filesystem-based locking selection, AFP, NFS-specific unlock workaround, flock and proxy locking | `fstatfs` remains; `statfs` removed | Passed |
| Same define plus an exclusion guard around `unixOpen`'s FAT/exFAT detection block | Also excludes filesystem-type lookup and activation of the FAT/exFAT empty-file inode workaround | Neither `statfs` nor `fstatfs`; `fcntl`, `fstat`, `fsync` retained | Passed |

Setting `SQLITE_ENABLE_LOCKING_STYLE=0` does **not** turn off database locking.
The default `unix` VFS uses `posixIoFinder` instead of `autolockIoFinder`.
The probe checked that both baseline and candidates selected `unixLock`,
`unixUnlock`, `unixShmMap` and `unixShmLock`. The NFS-specific unlock branch is
removed; the normal POSIX unlock path remains. `unix-none` and `unix-dotfile`
remain registered by upstream code but are not selected by Shōsai's open call.

All three relevant source sites were traced: `autolockIoFinderImpl` and
`proxyTransformUnixFile` are excluded by the define; `unixOpen` still calls
`fstatfs` under an `__APPLE__` conditional. That query enables the FAT/exFAT
workaround in `findInodeInfo`; excluding its activation block removes the
remaining import. No replacement capacity-query API was added.

## The exclusion depends on private local database storage

Shōsai's normal entry point opens `library.sqlite3` in the system-provided
Application Support directory (`lib/main.dart`, `lib/core/core_records.dart`).
No application `ATTACH` or second SQLite open path was found. Books chosen
through Files, Dropbox or Drive are not opened as SQLite databases. Apple
documents APFS on iOS since 10.3; Shōsai's minimum deployment target is iOS 15.
This supports an iPhone/iPad private-local-storage restriction, **not** removal
of filesystem compatibility for all possible SQLite paths.

The override in `third_party/sqlite3` keeps the published 3.5.2 Dart bindings,
headers and binary pins unchanged. Its hook selects the source build only for
`OS.iOS`, with upstream default defines except `SQLITE_ENABLE_LOCKING_STYLE=0`
and `SQLITE_TEMP_STORE=3`. The latter keeps temporary tables and indices in
memory, including when SQL requests file-backed temporary storage. Persistent
databases, journals and WAL files remain on disk with normal synchronization.

`hook/ios_container.m` checks each `unixOpen` path before opening or reusing a
descriptor. Canonical paths must be inside the symlink-resolved
`NSHomeDirectory`; this covers direct opens, `ATTACH` and journals. For a new
file, `realpath` resolves the existing parent; dangling leaf symlinks are
rejected. Resolving the complete nonexistent path with Foundation alone did
not reliably resolve its parent symlinks in the Mac probe. The core's public
`Store.open` cannot bypass the native check by accepting another path.
This is not a general-purpose SQLite build for external or network volumes.
No application schema or locking implementation was replaced.

## iOS-on-Mac admission checks storage rather than banning Macs

| Environment | Private database storage admission |
| --- | --- |
| iPhone/iPad, including iOS 15 | Retains the local APFS container contract; no volume-type query required |
| iOS-on-Mac with the iOS 16.4+ API | Parent directory must report `apfs` through `NSURLVolumeTypeNameKey` |
| iOS-on-Mac with an older runtime, failed query, missing type or other filesystem | Rejected |
| Native Android and desktop builds | Upstream binaries and filesystem handling unchanged |

The Foundation key returns filesystem type, not capacity, and is not on
Apple's current required-reason list. It is available from iOS 16.4 / macOS
13.3. The iOS 26.5 Simulator returned a successful query with no type despite
APFS backing storage, so the query is not imposed on ordinary iPhone/iPad
containers. Mac Catalyst remains rejected at compile time. No App Store
availability setting was changed.

The exact guard passed a native macOS Foundation harness with the Mac branch
forced and verified: private APFS accepted; mounted private HFS+ rejected;
missing/failed metadata rejected; existing/new files and journals accepted;
missing parents and symlink escapes rejected; internal symlinks accepted.
In the Mac lab, a standalone signed probe reported an actual iOS-on-Mac
runtime but stopped before any test writes: its test-only isolation check
expected the bundle ID in the container path, which instead used a UUID.
The production guard has no such naming restriction. Neither the probe's
volume query nor its database checks ran, so iOS-on-Mac storage compatibility
remains unverified.

Executed the patched hook for Android arm64, Linux x64, macOS arm64 and Windows
x64 and hashed each resulting library against the original published package's
pins. All four matched byte-for-byte. The vendored `lib/` and `assets/` trees
also match the published 3.5.2 package. This verifies binary selection, not new
Android or Windows runtime tests. macOS retains its filesystem compatibility
code and its existing absence of native-library manifests; the shared app
manifest remains included as documented above.

## Native probes and packaged-app checks

`build.sh`, `run.sh` and `verify.sh` completed successfully. Checks covered
competing connections and processes, uncommitted-write isolation, rollback,
WAL reader snapshots, checkpoint refusal with an active reader and success
after release, read-only reopen/write rejection, `STRICT` tables and integrity
checks. Baseline and restricted builds respected each other's writer locks
in separate Simulator processes in both directions. Read-only inspection also
verified each build's committed data in the other build without rewriting it.

The source archive was `sqlite-amalgamation-3530400.zip`, SHA-256
`1e71ddf93849c6a6ecf58b827c0692073d2dd7ee40196158068f7b29f422e87d`.
Reproduction sources/scripts and the one-line experimental guard are retained
under `.amp/in/orb-backup/sqlite-ios-branches/reproduce/`; build, run, verification
and import logs are attached to this thread under
`.amp/in/artifacts/privacy-audit/sqlite-ios-branches/evidence/`. The scratch
guard is an experiment flag, not a production platform/admission check.

The final integrated build passed both tests in
`integration_test/sqlite_privacy_test.dart` on iOS 26.5 with Xcode 27.2. They
covered actual core schema migration from version 1, data preservation,
competing connections, rollback, uncommitted-write isolation, WAL snapshots
and checkpoints, vacuum, integrity and reopen. External database paths,
symlink escapes, dangling external links and external `ATTACH` attempts were
rejected; internal symlinks allowed database creation and shared data. These
tests use disposable data, not an installed library. File-metadata reasons remain
necessary. No physical-device or App Store acceptance check was performed.

Keeping the upstream binary is still an alternative, but then its unmatched
disk-space category requires Apple's declaration guidance or a
[new approved reason](https://developer.apple.com/contact/request/privacy-manifest-reason/).
Adding `E174.1`, merely adding an unrelated low-space feature, or hiding the
imports in the app manifest is not an accurate resolution. A
`getattrlist`/`fgetattrlist` substitution is not preferred: Apple lists those
APIs too, and their filesystem support/error behavior differs. System SQLite
remains excluded by Darwin's instruction.

## Verification and remaining release checks

- Before the storage-guard refinement, `.agents/dev flutter test --no-pub`
  passed: 1,541 tests, 3 skipped. The final native and packaged checks below
  cover the refinement; this full suite was not repeated after rebasing.
- `.agents/dev make lint` passed app and both Dart-package analysis with no
  issues. This target first resolves the nested packages' test dependencies.
- On iOS 26.5 Simulator, `flutter test -d <simulator>
  integration_test/sqlite_privacy_test.dart` passed both database tests.
  The existing `integration_test/packaged_core_test.dart` also passed all
  9 tests with `--dart-define=SHOSAI_FIXTURES=<repository>/fixtures`, covering
  packaged EPUB/PDF import, rendering, reading progress and annotations.
- On the rebased production configuration (Xcode 27.3),
  `flutter build ipa --release --no-codesign --dart-define=SHOSAI_PRODUCTION=true`
  with `XCODE_XCCONFIG_FILE` set to `darwin/Production.xcconfig` produced
  `Runner.xcarchive` for `dev.shosai.reader`, targeting iOS 15.0. No IPA was exported.
- The production archive's app and both new framework declarations match their
  source; all 14 original SDK resources remain bundled and parseable. SQLite has no
  `statfs`, `fstatfs`, `getattrlist` or `statvfs` family imports; `fcntl`, `fstat`
  and `fsync` remain.
- `plutil -lint` passed for both Xcode projects and the app/framework manifests.
  Strict signature verification passed for the Simulator's two modified
  frameworks and enclosing app.
- The shared app manifest's earlier macOS debug bundle verification still
  applies; the iOS-only hook does not alter macOS machine code.

Final storage-guard, archive and integration evidence is retained under
`.amp/in/artifacts/privacy-audit/storage-guard/`; earlier full-suite and
platform-control logs remain under `.amp/in/artifacts/privacy-audit/final/`.
The iOS implementation remains local and unpublished; it has not received the
independent review required before its PR.

No distribution-signed archive, Apple upload validation, App Store privacy
report approval, physical iPhone/iPad check or privacy-label update was performed.
Repeat the audit for the final signed release archive and after any dependency
change. Real-device work must use the Mac lab's lease and install over existing
apps without modifying Darwin's library.

## Policy sources

- [Apple: required-reason APIs and approved reasons](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)
- [Apple: per-executable/library manifest responsibility](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)
- [Apple: manifest placement, including macOS](https://developer.apple.com/documentation/bundleresources/adding-a-privacy-manifest-to-your-app-or-third-party-sdk)
- [Apple: collection, on-device processing, and App Store privacy answers](https://developer.apple.com/app-store/app-privacy-details/)
- [Google: Apple Sign-In SDK data disclosure](https://developers.google.com/identity/sign-in/ios/app-privacy)
- [SQLite 3.53.4 filesystem/locking implementation](https://github.com/sqlite/sqlite/blob/version-3.53.4/src/os_unix.c)
- [SQLite: additional locking styles versus normal POSIX locking](https://www.sqlite.org/compile.html#enable_locking_style)
- [Apple: APFS and the iOS sandbox directories](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/FileSystemOverview/FileSystemOverview.html)
- [Apple: type-only filesystem query and availability](https://developer.apple.com/documentation/foundation/urlresourcekey/volumetypenamekey)
