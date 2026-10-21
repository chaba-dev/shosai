# Flutter frontend architecture

The Flutter frontend uses an Elm-style model/message/update/effect boundary.
This keeps asynchronous native resources and stale completions from becoming
implicit widget state.

```diagram
┌────────┐   ReaderMessage   ┌──────────────────┐
│ Widget │──────────────────▶│ ReaderController │
└───▲────┘                   │ update/dispatch  │
    │ immutable ReaderModel  └───────┬──────────┘
    │                                │ owned effect
    └────────────────────────────────┤
                                     ▼
                          ┌──────────────────────┐
                          │ Document engines and │
                          │ application core     │
                          │ (Dart; see ownership │
                          │ by format below)     │
                          └──────────┬───────────┘
                                     │ typed completion message
                                     └──────────────────────────▶ update
```

## Rules

1. `ReaderModel` is immutable and is the only reader state rendered by widgets.
2. Widgets dispatch sealed `ReaderMessage` values. They do not mutate model or
   native-resource state.
3. Message handling owns state transitions. An asynchronous effect captures the
   document generation and operation revision that authorized it, then reports
   success or failure with a typed completion message.
4. Completion handling rejects stale generations and revisions after every
   asynchronous boundary. Older work must not clear, replace, or report errors
   into newer state.
5. The controller owns cancellation tokens, document and buffer handles, decoded
   images, and effect draining. Disposal cancels work and releases each resource
   exactly once after outstanding effects finish.
6. Document ownership is format-scoped (amended 2026-09-28 and 2026-10-21; see
   [Document ownership by format](#document-ownership-by-format)). Each
   format's Dart engine owns parsing, admission, canonical text, durable
   locations, cancellation and memory admission; the PDF engine also owns
   rasters and page-space geometry, while for EPUB Flutter owns layout,
   shaping, paint geometry and selection geometry over the engine's
   normalized chapter. The Dart application core owns storage, records,
   anchors and search for every format. Flutter owns gestures, overlays,
   focus, navigation, dialogs, and responsive composition in every format.
7. Renderer geometry and renderer pixels are one contract **within one format's
   renderer**. The EPUB engine must not produce geometry for text it did not
   lay out, and Flutter must not reshape text separately from the layout that
   painted it. PDF keeps the engine-produced raster and geometry pairing.
8. Dialogs, pickers, and similar platform effects are injected controller
   adapters. Widgets dispatch an intent; only the controller starts and awaits
   the adapter, and its result returns as a revision-guarded message.
9. Every engine value carrying a retained resource (a parsed archive, a
   decoded image, a rendered page, a measured layout) has an explicit owner.
   Effects release unadopted resources on failure or staleness; adopted
   resources remain model-owned until replacement or disposal.

## Document ownership by format

The 2026-09-28 owner decision ([evaluation plan](dart-document-stack-evaluation-plan.md#adoption-decision-2026-09-28))
adopted Dart-owned EPUB parsing/normalization with Flutter layout. The
2026-10-21 decision ([RFD 4](../rfd/0004/README.adoc), milestone M3.0)
replaces the Rust core and the Dart/Rust bridge with Dart for everything else;
until its slices land, the "Rust" column below is what still runs behind the
bridge. The Elm boundary above is unchanged by either decision.

| Responsibility | EPUB | PDF |
| --- | --- | --- |
| Parsing, normalization, canonical text, durable locations | Dart engine (`shosai_epub`) | Dart PDF engine (`flutter/lib/reader/pdf`, pdfrx over PDFium) for the reader; Rust `pdf.rs` for the store until the M3.0 records slice |
| Layout, shaping, paint geometry, selection geometry | Flutter, over the Dart layout | Dart PDF engine |
| Rendered pixels | Flutter, from the same layout as the geometry | Dart PDF engine raster |
| Library/import, SQLite storage, bookmarks, annotations, anchors, reading state, search | Dart application core; Rust until M3.0 | Dart application core; Rust until M3.0 |
| Gestures, focus, overlays, navigation, platform adapters | Flutter | Flutter |

- One format's geometry and pixels are one contract. EPUB hit zones, carets,
  visual lines and selection rects are derived from the same `TextPainter`
  layout that paints the page; they are never reshaped separately.
- Rule 9 extends to the Dart engine's retained resources (parsed archive, decoded
  images, measured layout caches). The controller owns them; an effect releases
  unadopted resources on failure or staleness, and adopted resources stay
  model-owned until replacement or disposal.
- Asynchronous work keeps rules 3–5: the Dart engine's layout and decode
  completions carry the document generation and operation revision that
  authorized them, and stale completions are rejected after every asynchronous
  boundary.
- There is one database writer. Until the M3.0 store slice lands it is the
  Rust core, and the Dart engine may read and project Rust-owned records
  (bookmarks, annotations, reading state) but must not open a second
  connection or write an incompatible save; after it, the Dart application
  core owns the single connection, and engines never touch the database.
- Old database schemas and persisted anchors need no migration; no development
  data may be deleted without an explicit reset decision.

## Testing

Use completer-controlled effects to test stale completion, replacement, and
disposal ordering. Widget tests must exercise gestures or shortcuts through the
rendered surface when validating interaction contracts; dispatching offsets
directly only tests update logic. Engine and core package tests cover owned
resource transfer and create/reopen/update/delete flows for each supported
format, independent of widgets.
