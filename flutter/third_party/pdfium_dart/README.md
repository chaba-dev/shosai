# pdfium_dart 0.2.5, patched

This is [pdfium_dart](https://pub.dev/packages/pdfium_dart) 0.2.5 as
published (`lib/`, `hook/build.dart`, `hook/link.dart`, `pubspec.yaml`,
`LICENSE`), vendored so the application can change how it fetches and
credits PDFium.

The pubspec drops upstream's `resolution: workspace`, dev dependencies and
ffigen configuration (the generated bindings are kept as published) so it
resolves outside the upstream repository.
