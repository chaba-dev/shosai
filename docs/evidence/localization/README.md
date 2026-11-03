# English and Japanese interface audit

These captures show the Linux application running with the production Dart core,
not a mockup. The only book used was the repository's `fixtures/sample.epub` in a
disposable application profile. No build was installed on a physical device.

| Capture | State |
| --- | --- |
| `settings-ja.png` | Japanese Settings, with the Paper theme selected as 紙 |
| `settings-en-themes.png` | English theme choices: Paper, Sepia, Night |
| `settings-ja-themes.png` | Japanese theme choices: 紙, セピア, 夜 |
| `delete-managed-ja.png` | Translated destructive confirmation with the book title |
| `open-error-ja.png` | Missing-file recovery guidance and Retry in Japanese |
| `theme-selection-ja.mp4` | Pointer interaction: Paper → Sepia → Night → Paper |

The missing-file state was exercised by temporarily moving the imported fixture's
managed copy out of its expected location, opening its library card, and restoring
the copy afterward. The deletion confirmation was cancelled; the book remained.

## Audit and self-review

- Checked the application’s English/Japanese catalog parity and UI call sites in
  `lib/library`, `lib/reader`, `lib/shell`, and the platform-facing picker and
  authorization adapters. Added 68 messages; all 348 catalog messages have Japanese
  translations.
- Covered Settings, managed-copy deletion, highlight association and pagination,
  reader fallbacks, selection accessibility announcements, recovery/persistence
  errors, EPUB layout limits, shell search/notes errors, and browser-return copy.
- Settings and the reader use the same theme labels. Stored `light`, `sepia`, and
  `dark` values are unchanged.
- Raw engine/provider diagnostics are not presentation copy. Structured failures
  show localized guidance instead of English diagnostics or private paths.
- Retained document content, titles, paths, fingerprints, format names, and numeric
  values as data rather than translating them.
- Self-review caught and fixed a disposed-widget localization lookup in async
  completions and a missing localization scope on the root association dialog.

## Regression coverage

- `test/library/view_navigation_test.dart`: English/Japanese theme choices persist
  their original values; Japanese deletion confirmation interpolates the title and
  cancellation does not remove the book.
- `test/widget_test.dart`: Japanese asynchronous open failures hide raw diagnostics;
  Japanese highlight association requires a selected source and exposes translated
  selection semantics.
- `test/library/errors_test.dart`: Japanese failure guidance does not expose engine
  messages or paths.
- Existing recovery, persistence, semantics, paging, and shell tests continue to
  assert their observable behavior using the translated presentation messages.

## Native capture setup

Built with `.agents/dev flutter build linux --debug`. Ran the bundle in a disposable
profile under Xvfb at 1280 × 800, with `GDK_BACKEND=x11`, Mesa software rendering,
and the Nix development shell's EGL vendor. Set `LANGUAGE=ja` or `LANGUAGE=en`;
cropped the unused desktop below the 1280 × 720 application window. Captured the
pointer interaction at 15 fps with FFmpeg. Screenshots and the complete clip were
visually inspected.
