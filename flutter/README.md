# Shōsai Flutter frontend

This is the Shōsai application (RFD 4): one Dart and Flutter codebase for the
document engines, the application core and the presentation. EPUB books are
parsed by the Dart engine (`packages/shosai_epub`) and laid out and painted by
Flutter; PDF documents are opened, rendered and measured by the Dart PDF
engine over PDFium (`lib/reader/pdf`, through `pdfrx`). The library, reading
state, bookmarks, annotations and search live in the Dart application core
(`packages/shosai_core`) over one SQLite connection.

Reader state follows an Elm-style model/message/update flow. Widgets render
the immutable `ReaderModel` and dispatch sealed `ReaderMessage` values;
`ReaderController` runs effects and dispatches their completion messages while
retaining ownership of native resources. See the
[Flutter architecture contract](../docs/flutter-architecture.md).

Run commands from the repository root through the pinned development
environment:

```sh
.agents/dev make check-flutter
.agents/dev make flutter-dev
.agents/dev make flutter-macos-smoke
.agents/dev make flutter-release
```

The PDFium and SQLite libraries are fetched by the Dart bindings' build hooks
and bundled as native assets. `flutter test` does not link native assets, so
the tests load PDFium from `SHOSAI_PDFIUM_LIBRARY` (set by the Nix shell) or
`PDFIUM_PATH`. Linux bundles are written below `flutter/build/linux/`, and
macOS bundles below `flutter/build/macos/`.
