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
                          │ Document engine      │
                          │ Rust bridge or Dart  │
                          │ EPUB engine (format- │
                          │ scoped, see below)   │
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
6. Document ownership is format-scoped (amended 2026-09-28; see
   [Document ownership by format](#document-ownership-by-format)). Rust owns
   parsing, text shaping, paint geometry, durable anchors, persistence,
   cancellation, and memory admission for PDF and CBZ. For EPUB, Dart owns
   parsing, normalization, canonical text and durable anchors, and Flutter owns
   layout, shaping, paint geometry and selection geometry; Rust still owns
   storage, records and search. Flutter owns gestures, overlays, focus,
   navigation, dialogs, and responsive composition in every format.
7. Renderer geometry and renderer pixels are one contract **within one format's
   renderer**. Flutter must not independently reshape EPUB text whose hit zones
   were produced by Rust, and the Dart EPUB engine must not produce geometry for
   rasters it did not lay out. PDF/CBZ keep the Rust-produced raster and geometry
   pairing.
8. Dialogs, pickers, and similar platform effects are injected controller
   adapters. Widgets dispatch an intent; only the controller starts and awaits
   the adapter, and its result returns as a revision-guarded message.
9. Every Rust DTO carrying a retained handle has an explicit owner. Effects
   release unadopted handles on failure or staleness; adopted handles remain
   model-owned until replacement or disposal.

## Document ownership by format

The 2026-09-28 owner decision ([evaluation plan](dart-document-stack-evaluation-plan.md#adoption-decision-2026-09-28))
adopted Dart-owned EPUB parsing/normalization with Flutter layout. Rule 6's
single-owner sentence predates that decision; ownership is now format-scoped and
the Elm boundary above is unchanged.

| Responsibility | EPUB | PDF / CBZ |
| --- | --- | --- |
| Parsing, normalization, canonical text, durable anchors | Dart engine | Rust |
| Layout, shaping, paint geometry, selection geometry | Flutter, over the Dart layout | Rust |
| Rendered pixels | Flutter, from the same layout as the geometry | Rust raster |
| Library/import, SQLite storage, bookmarks, annotations, reading state, search | Rust | Rust |
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
- While the EPUB slice is integrated, Rust remains the only database writer. The
  Dart engine may read and project Rust-owned records (bookmarks, annotations,
  reading state) but must not open a second connection or write an incompatible
  save. Moving a write is a separate, explicit decision.
- Old database schemas and persisted anchors need no migration; no development
  data may be deleted without an explicit reset decision.

## Testing

Use completer-controlled effects to test stale completion, replacement, and
disposal ordering. Widget tests must exercise gestures or shortcuts through the
rendered surface when validating interaction contracts; dispatching offsets
directly only tests update logic. Native bridge tests cover owned DTO transfer
and create/reopen/update/delete flows for each supported format.
