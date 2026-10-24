# Keep books across install-over (PR #226): device evidence

Evidence only, not for merging. Captured 2026-10-24 on the iPad Air 11-inch (M4) Simulator (iOS 26.5) and on Darwin's iPad Air 5 (iOS 26.6.2).

Builds:

- **before**: `origin/main` at 12e37d5 (includes #222 and #223).
- **fixed**: `origin/claude/project-thread-8owd8y` (ed6616f) merged with `origin/main` 12e37d5.
  The iPad build was a profile build signed for team NALL3XDPUR. The team ID was set only in the local checkout.

Books: Alice's Adventures in Wonderland (Gutenberg EPUB 11) and "Attention Is All You Need" (arXiv PDF 1706.03762).
`flutter/integration_test/keep_books_test.dart` downloads them and imports them through the app core as private copies (`managed: true`, what the iOS picker does).

Each `simctl install` / `devicectl device install app` / `flutter drive` installs over the app and never uninstalls it. Every iPad drive ran with `--keep-app-running`; without that flag, `flutter drive` uninstalls the app.
`check` mode starts the production `ShosaiApp` (in English) over the production store, logs every book's file, opens each book from the library and captures it.

## Simulator, before (`sim-before/`)

The Simulator gives the app a new data container on every install, so it reproduces the bug.

| step | data container | result |
|---|---|---|
| seed (harness) | 90CC97C0… | 2 books imported, both files present |
| install-over #1, real app launched | 620503C2… | before launch, `books/` holds both files. **After launch, `books/` is empty.** The orphan sweep deleted them. |
| harness check (install-over) | 0D158B1A… | rows still point at 90CC97C0…, file exists = false; opening "attention" shows **"The book file is missing: …(notFound)"** (`s1-check-02-open-attention.png`) |
| install-over #2, #3 | 33C6E17E…, A44AC68C… | `books/` stays empty |

## Simulator, fixed (`sim-fixed/`)

| step | data container | result |
|---|---|---|
| seed (harness) | D1431772… | 2 books imported |
| install-over #1, real app launched | 8EF311B2… | both files kept after launch (`s1-app-after-install-over-1.png`) |
| harness check (install-over) | 57062E06… | rows re-pointed to 57062E06…; both books open (`s1-check-02/03`) |
| install-over #2, real app launched | F25A98E7… | app restores the open Alice tab and renders it (`s2-app-after-install-over-2.png`) |
| harness check (install-over), video | 5E7D07B8… | both books open (`s2-check-02/03`, `s2-check-video-540p.mp4`) |
| install-over #3, real app launched | 36E17675… | app restores the "attention" tab and renders page 1 (`s3-app-after-install-over-3.png`) |

## iPad Air 5, fixed (`ipad-fixed/`)

The app data container was backed up first on the Mac, in `/tmp/claude-501/ipad-backup-20261024-014717`.
Before the first install, the library held one book, facebook_scuba (managed). Its row pointed at old container EDA8CF56…, and its file had already been deleted by the bug.

| step | data container | result |
|---|---|---|
| before any install | CD4F345F… | `books/` empty; facebook_scuba row → EDA8CF56… |
| install-over #1, real fixed app launched | E2814157… | unchanged (facebook_scuba has no file to keep) |
| seed (harness, install-over) | 366913A7… | Alice + attention imported, files present |
| install-over #2, real fixed app launched | D6F60FB5… | both files kept |
| harness check (install-over) | 014AB481… | Alice + attention re-pointed to 014AB481… and open; facebook_scuba shows "The book file is missing" (expected, deleted before the fix) |
| install-over #3, real fixed app launched | BADBD5A4… | both files kept |
| harness check (install-over) | 6A9BC5A9… | the app starts with Alice's tab reopened; Alice + attention open; facebook_scuba still missing |
| install-over #4, real fixed app launched | AE754583… | both files kept; the real fixed app is what's installed now |

Per-step logs: `*/log.txt`. Scripts: `scripts/` (`ios-flutter.sh` runs the repo's pinned iOS Flutter SDK outside the Nix shell, as `scripts/build-flutter-ios.sh` does).
