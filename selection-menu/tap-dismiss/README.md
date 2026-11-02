# Tap on the page dismisses a touch selection

Not for merge. This re-verifies 446775b ("a tap on the page dismisses a touch selection") as built in
`claude/project-thread-v4f525-device` at `87a802b`. It ran on a physical iPhone 15 Pro Max (iOS 27.2)
in a profile build. The books were imported into a throwaway library.

The books were Quiet Places (PDF, one page) and Alice (EPUB). The PDF reached the phone inline as a
base64 `--dart-define`. Each tap has a `before-` and an `after-` screenshot. The driver,
`tap_dismiss_demo_test.dart`, checks the capsule and the `page N` labels before and after each tap.

| Tap | PDF | Alice |
| --- | --- | --- |
| 1. Select, Note, Cancel, then tap on the page | pass | pass (the selection had already cleared on Cancel) |
| 2. A second selection, then a tap on the selected text | pass | pass |
| 3. A third selection, then a tap in the right-hand page-turn zone | pass | pass, the page did not turn |

After every tap, the capsule and the selection were gone and the page number was unchanged.
The full run passed (`DEMO_RESULT failures=0`).
