# pdfium_dart 0.2.5, patched

This is [pdfium_dart](https://pub.dev/packages/pdfium_dart) 0.2.5 as
published (`lib/`, `hook/build.dart`, `hook/link.dart`, `pubspec.yaml`,
`LICENSE`), with one change: `hook/build.dart` checks each PDFium archive it
downloads from
[bblanchon/pdfium-binaries](https://github.com/bblanchon/pdfium-binaries)
against the SHA-256 pinned in `hook/pdfium_archives.dart`, and fails the
build on a mismatch or an unpinned target. Upstream pins the release but
verifies nothing. The extracted library lives in a directory named after the
archive's hash, so a copy extracted by the unpatched hook is not reused.

`tool/pin_pdfium.py <release>` downloads every archive the hook can fetch for
a pdfium-binaries release and rewrites `hook/pdfium_archives.dart`; run it
when the release changes. The hashes are those of the chromium/7811 archives
as GitHub served them on 2026-10-22.

On iOS PDFium comes from `pdfium_flutter`'s XCFramework instead, whose
podspec already pins the download's SHA-256.

The pubspec drops upstream's `resolution: workspace`, dev dependencies and
ffigen configuration (the generated bindings are kept as published) so it
resolves outside the upstream repository, and adds `crypto` for the hash.
Remove this directory and the `dependency_overrides` entry in
`flutter/pubspec.yaml` if upstream verifies its downloads itself.
