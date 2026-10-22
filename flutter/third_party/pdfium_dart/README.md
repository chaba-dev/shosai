# pdfium_dart 0.2.5, patched

This is [pdfium_dart](https://pub.dev/packages/pdfium_dart) 0.2.5 as
published (`lib/`, `hook/build.dart`, `hook/link.dart`, `pubspec.yaml`,
`LICENSE`), with two changes:

- `hook/build.dart` checks each PDFium archive it downloads from
  [bblanchon/pdfium-binaries](https://github.com/bblanchon/pdfium-binaries)
  against the SHA-256 pinned in `hook/pdfium_archives.dart`, and fails the
  build on a mismatch or an unpinned target. Upstream pins the release but
  verifies nothing. `hook/verified_archive.dart` keeps the verified archive
  beside the library and hashes it again on every build, downloading it
  again when it no longer matches, and always takes the library from it, so
  a cached library is never trusted for merely existing; both are written
  under a temporary name and renamed into place. They live in a directory
  named after the archive's hash, so a pin change never reuses another
  archive's files. `test/` covers it (`make test-app` runs it).
- `NOTICES` replaces `LICENSE` in the application's license notices: Flutter
  reads a package's `NOTICES` in preference to its `LICENSE`, so the bundled
  PDFium's license and the licenses of the third-party code compiled into it
  (FreeType, ICU, libjpeg-turbo, OpenJPEG, zlib and the rest, as the archives
  list them under `licenses/`) appear on the about screen and in `NOTICES.Z`
  beside this package's own.

`tool/pin_pdfium.py <release>` downloads every archive the hook can fetch for
a pdfium-binaries release and rewrites both `hook/pdfium_archives.dart` and
`NOTICES`; run it when the release changes. The hashes are those of the
chromium/7811 archives as GitHub served them on 2026-10-22.

On iOS PDFium comes from `pdfium_flutter`'s XCFramework instead, whose
podspec already pins the download's SHA-256. That XCFramework is a build of
the same chromium/7811 PDFium and ships no license files, so these notices
stand for it too.

The pubspec drops upstream's `resolution: workspace`, its dev dependencies
other than `test`, and its ffigen configuration (the generated bindings are
kept as published) so it resolves outside the upstream repository, and adds
`crypto` for the hash.
Remove this directory and the `dependency_overrides` entry in
`flutter/pubspec.yaml` if upstream verifies its downloads and ships the
notices itself.
