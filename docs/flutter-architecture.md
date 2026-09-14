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
                              ┌─────────────┐
                              │ Rust bridge │
                              └──────┬──────┘
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
6. Rust owns document parsing, text shaping, paint geometry, durable anchors,
   persistence, cancellation, and memory admission. Flutter owns gestures,
   overlays, focus, navigation, dialogs, and responsive composition.
7. Renderer geometry and renderer pixels are one contract. Flutter must not
   independently reshape EPUB text whose hit zones were produced by Rust.
8. Dialogs, pickers, and similar platform effects are injected controller
   adapters. Widgets dispatch an intent; only the controller starts and awaits
   the adapter, and its result returns as a revision-guarded message.
9. Every Rust DTO carrying a retained handle has an explicit owner. Effects
   release unadopted handles on failure or staleness; adopted handles remain
   model-owned until replacement or disposal.

## Testing

Use completer-controlled effects to test stale completion, replacement, and
disposal ordering. Widget tests must exercise gestures or shortcuts through the
rendered surface when validating interaction contracts; dispatching offsets
directly only tests update logic. Native bridge tests cover owned DTO transfer
and create/reopen/update/delete flows for each supported format.

## Shadcn / Material boundary

flutter-shadcn-ui is the component system. Material is retained only for
scaffolding with no Shadcn equivalent and for host interop:

- `Scaffold`, `AppBar`, and `CircularProgressIndicator` remain Material. There is
  no Shadcn app bar, scaffold, or spinner.
- `MaterialApp` is mounted inside `ShadApp.custom`; `ShadAppBuilder` supplies the
  Shadcn theme, toaster, and Sonner.
- `ThemeData` is derived from the Shadcn theme in `app_theme.dart`; do not add a
  separate Material palette.
- `ShadIconAction` wraps the Material `Tooltip` on purpose: `ShadTooltip` exposes
  no tooltip semantics, while Material's `Tooltip`/`RawTooltip` provides both the
  accessibility tooltip and the `find.byTooltip` test hook.

Themes (`app_theme.dart`):

- `shosaiShadTheme(brightness)` is the app theme; it maps the Shosai brand accent
  into a Shadcn `ShadColorScheme` and applies the bundled interface fonts.
- `shosaiReaderShadTheme(readerTheme)` maps the reader's light/sepia/dark
  preference onto a Shadcn theme. Reader page colors derive from
  `ShadColorScheme`; there is no parallel Material reader theme.

## Transient feedback (notices)

Elm models own transient feedback as value data:

- A controller raises a `Notice` (`lib/shared/notice.dart`); the model stores the
  current notice. `SonnerBridge` presents it once (guarded by the notice id) as a
  `ShadToast`, then dispatches a `*NoticeConsumed` message. The view never
  mutates model state.
- Use notices for transient results and failures (import summaries, selection or
  annotation failures, tool errors). Keep persistent, actionable conditions on a
  persistent surface (library banners for cleanup/deletion debt and retryable
  load errors; `model.error` for failed reader content; `persistenceError` for
  reading-state failures) so they stay visible until resolved.
- `ReaderController` raises reader transient notices centrally in `_emit` when a
  transient error field changes; do not raise per set-site.

## Rust `enum` ↔ Dart sealed class

Iced's flat `Message` enum maps to one Dart `sealed class` per page with one
`final class` per variant in a single `message.dart` part. Dart `enum` cannot
carry per-variant payloads, so it is reserved for payload-free value sets
(`ReaderSelectionPhase`, `LibraryFailure`, etc.). Exhaustive `switch` over the
sealed hierarchy is the analogue of Rust's exhaustive `match`; keep a default
arm out so adding a variant is a compile error until it is handled.

