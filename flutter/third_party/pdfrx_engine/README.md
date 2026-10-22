# pdfrx_engine 0.4.5, patched

This is [pdfrx_engine](https://pub.dev/packages/pdfrx_engine) 0.4.5 as
published (`lib/`, `pubspec.yaml`, `LICENSE`), with one change:
`lib/src/native/worker.dart` is upstream's version from
[espresso3389/pdfrx@e16a956](https://github.com/espresso3389/pdfrx/commit/e16a95688f718ae6ee38c86c0c1a296e70709cb2).
In 0.4.5 a callback that throws on the PDFium worker isolate sends no reply,
so the caller waits forever (for example an import whose PDFium library fails
to load). The patched worker replies with the value or the error, and the
caller rethrows it. `test/core/pdfium_load_failure_test.dart` covers this.

The fix is released in pdfrx_engine 0.4.7 (pdfrx 2.4.8), which needs
`meta` ^1.18.0; Flutter 3.41.5 pins `meta` 1.17.0. Remove this directory and
the `dependency_overrides` entry in `flutter/pubspec.yaml` once the app can
depend on pdfrx 2.4.8 or later. The pubspec drops upstream's
`resolution: workspace` and dev dependencies so it resolves outside the
upstream repository.
