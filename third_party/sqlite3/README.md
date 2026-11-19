# sqlite3 3.5.2, iOS-private-storage build

This is the published Dart `sqlite3` 3.5.2 package's `lib/`, `assets/`,
`LICENSE` and build hook. The Dart bindings and binary hash pins are unchanged.
Only iOS takes the additional branch in `hook/build.dart`; Android, Linux,
macOS and Windows retain upstream's binary selection, download and validation.

## iOS keeps POSIX locking, without filesystem-type probes

`hook/ios.dart` downloads SQLite's 3.53.4 amalgamation, the same engine version
as the package's prebuilt binary, and verifies the pinned archive SHA-256
before extracting it. A changed cached archive is checked again when the hook
runs. The hook applies two exact-match source edits and compiles with the
package's default defines except:

- `SQLITE_ENABLE_LOCKING_STYLE=0` selects normal POSIX locking rather than
  filesystem-based AFP/NFS/proxy/flock selection. WAL shared-memory locking
  remains enabled.
- The `unixOpen` FAT/exFAT detection block is excluded. It otherwise retains
  an `fstatfs` call even with extended locking styles disabled. The remaining
  file-metadata calls are declared in the framework's privacy manifest.
- `SQLITE_TEMP_STORE=3` keeps temporary tables and indices in memory even if
  SQL requests disk-backed temporary storage. Persistent databases, journals
  and WAL files remain on disk with normal locking and synchronization.

This avoids declaring Apple's disk-space reason `E174.1` for code which only
inspected filesystem type and locking behavior, not available capacity.

## The native boundary admits only private iOS paths

Before `unixOpen` opens or reuses a descriptor, `ios_container.m` checks that
the canonical path is under the symlink-resolved `NSHomeDirectory`. For a new
file it resolves the existing parent; dangling leaf symlinks are rejected.
This applies to databases, `ATTACH` and journals. External Files/provider paths
and escapes through symlinks are not supported as databases. User-selected
books are unaffected: they are not SQLite databases. Shōsai opens its database
in Application Support.

For iOS-on-Mac on a runtime providing the iOS 16.4+ API, the parent directory's
`NSURLVolumeTypeNameKey` must report `apfs`; a failed query, unknown type or
other filesystem is rejected. This key reports type, not capacity, and is not
on Apple's required-reason API list. iPhone/iPad runtimes retain the local
APFS container contract without this query: the key returned no value in the
iOS 26.5 Simulator despite APFS backing storage. Older iOS-on-Mac runtimes
remain rejected.
There is no longer a blanket iOS-on-Mac ban. Mac Catalyst is still rejected at
compile time, and the native macOS binary remains unchanged. Actual
iOS-on-Mac app execution still needs validation before promising support;
native macOS guard probes are not a substitute for that runtime test.

## Packaging and checks

The iOS Runner's final script phase copies the audited SQLite and PDFium
manifests into the embedded frameworks and re-signs them when signing is
enabled, before the enclosing app is signed. Flutter's native-assets hook
does not currently package those resources itself.

Run `integration_test/sqlite_privacy_test.dart` on a disposable iOS Simulator
to check migration/data preservation, competing connections, rollback, WAL
snapshots/checkpoints, vacuum/integrity, reopening and path admission. Audit
the final archive's manifests and native imports after any SQLite, PDFium or
Flutter upgrade. See `docs/apple-privacy-audit.md` for the audit and limitations.

The pubspec removes upstream's workspace resolution and generator-only dev
dependencies, and adds `archive` for the verified source download. Remove
this override when upstream provides a matching iOS build and framework
manifest support; do not replace it with system SQLite or disable locking.
