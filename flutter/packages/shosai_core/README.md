# shosai_core

The Dart application core of the Shōsai reader: the SQLite store and the
records kept in it. It replaces the Rust core and the Flutter bridge in
stacked slices (RFD 12, milestone M3.0) and is independent of Flutter widgets,
so its behaviour is tested with `dart test`.

## Store

`Store.open(path)` starts one worker isolate that owns the database's only
connection. Every query is a synchronous `StoreBody` the store sends to that
worker, so queries run one at a time in the order they were sent and the UI
isolate never blocks on SQLite. `Store.transaction` wraps a body in
`BEGIN IMMEDIATE … COMMIT` and rolls back on any exception.

A body is sent across an isolate boundary: it may capture plain values (and a
`Store` or an object holding nothing else), and it must return plain values.
A closure written in a method captures that method's object, so a facade that
also holds locks, inspectors or cancellation tokens keeps its queries in a
separate records class (as `Library` does with `LibraryRecords`). A write's
result is sent before its `COMMIT`, so a result that cannot be sent rolls the
write back. A body must be synchronous: an `async` body is refused, its
transaction rolled back and the store closed before its continuation runs.

The connection runs in WAL mode with `synchronous = NORMAL`, foreign keys on
and a five-second busy timeout for a second application instance. A process
killed mid-write loses only its open transaction; SQLite's WAL recovery
discards it on the next open (covered by the killed-writer test).

### Schema

`schemaMigrations` lists the ordered migrations. Each runs in its own
immediate transaction together with the `PRAGMA user_version` that records it.
The first migration also sets `PRAGMA application_id` to `shosaiApplicationId`.
The store refuses, without writing to it:

- a file that is not SQLite,
- a database with tables but without Shōsai's application id (for example
  one written by the retired Rust core; those are not migrated),
- a database whose `user_version` is newer than this build.

Each migration rereads `user_version` while it holds the write lock, so two
application instances opening the same older database apply it once.

Append a migration for every schema change; never edit one that has merged.

### SQLite binary

`package:sqlite3` (pinned to 3.5.2) bundles SQLite through its build hook: the
hook downloads the release's prebuilt library, checks it against the hashes
published with the package and ships it with the application, so no system
SQLite is used. `dart test` and `flutter build` run the hook. Version 3.5.2
bundles SQLite 3.53.4. It is the newest release the Flutter SDK resolves:
3.6 and later need `hooks` 2.2, whose `record_use` needs a newer `meta` than
the one Flutter pins.

## Records

| Module | Owns |
| --- | --- |
| `Preferences` | bounded key/value preferences (1 KiB keys, 64 KiB values, 1,024 rows, 1 MiB total) |
| `Library` | books, import, covers, progress and private copies (below) |
| `ReadingState` | each book's last position (unit, offset, zoom) and its library progress |
| `ReaderSettingsStore` | reading mode, theme, EPUB font size and line spacing, PDF zoom, over `Preferences` |
| `Bookmarks` | point bookmarks with an optional title and note (1,024 per book, 4 MiB Markdown export) |
| `Annotations` | highlights with an optional note, anchored in text and resolved against the open book (below) |
| `searchBook` | case-insensitive in-document search over the open book's unit texts (below) |

Reading state and bookmarks are keyed by the book's content hash, not its
library row, so they survive removing and re-importing the same book. The
store runs requests in the order they were sent, so the last reading-state
save sent is the one that persists; no revision counter is needed.

### Library

A book's identity is its content (SHA-256). Importing content that is already
in the library returns that book, so reading state follows the content: a
referenced book whose file moved is repointed to the new path, and a managed
import of a referenced book adopts it as a private copy.

- **Referenced** books stay where the person keeps them; removing one never
  touches the file.
- **Managed** books are copied into the managed directory as
  `<sha256>.<format>`. The copy is hashed while it is written, inspected, then
  published and committed under one lock, so a deletion never races an import
  that claims the same copy. A damaged copy is replaced on the next import.
  Removing a managed book deletes the copy after the commit; a deletion that
  fails is recorded in `managed_file_deletion_debt` and retried by
  `retryManagedFileDeletions` (at start-up), and a deletion only ever renames
  and unlinks a direct entry of the directory recorded when the copy was
  imported, never a symlink's target or a path a book uses.
- Publishing, claiming and deleting copies hold one lock per managed
  directory: in-isolate for every `Library` over it, keyed by the directory's
  resolved path so aliases share it (and taken before the lock file is
  opened), and an exclusive file lock on `.shosai-lock` across processes. A
  POSIX file lock belongs to the process, so two isolates of one process are
  not excluded from each other: use a managed directory from one isolate per
  process. A referenced import of a path inside the managed directory is
  refused.
- The managed directory's resolved path is recorded the first time it is
  used. If it later resolves elsewhere (it or a parent was replaced by a
  symlink), managed imports fail and nothing is published, swept or deleted
  there; removals still commit and leave the copy's deletion pending. The
  directory is checked again at selected points of an operation, but only as
  a best effort: nothing guards against it being replaced while an operation
  runs (`dart:io` has no directory-handle-relative operations), so the library
  assumes nothing replaces its private directory, or a parent of it, while it
  runs.
- Removing a book never needs the managed directory: the removal commits
  first, and only the copy's deletion needs the lock, so an unusable
  directory leaves it pending. Deletion debt recorded in another directory
  than the library's stays pending.
- `retryManagedFileDeletions` also sweeps what a crash left behind: a
  published copy no book or debt owns, set-aside damaged copies, and staging
  files older than a day (a heuristic for an import that is no longer
  running). Up to 100 unowned entries go per call; owned copies do not count
  against that.
- `verifiedPath` re-hashes the file before the reader opens it and fails with
  `conflict` when the content changed.
- Directory import follows symlinks only inside the chosen folder, visits each
  folder once and skips files that are not regular or not EPUB/PDF. Walks are
  bounded at 50,000 entries and 10,000 books; one selection is at most 256
  paths, and a book file at most 512 MiB.
- EPUB title, author and cover come from `shosai_epub`. PDF metadata comes
  from a `BookInspector` the host supplies with its PDF engine; without one
  the file name is the title. Covers are stored as PNG thumbnails of at most
  300×400 pixels and 512 KiB.
- Import takes a `CancellationToken`, checked between file chunks and books;
  once a book's commit starts it finishes.

### Annotations

An annotation belongs to a document version, the content (SHA-256) it was
made on, and versions belong to a document. A book's first annotation creates
both, so annotations follow the content through removal and re-import like
reading state. `associate` brings another content's annotations (an earlier
edition, a re-exported file) to a book: into the book's document when it has
one, otherwise by adding the book's content to the source's document.
`associationSources` lists candidates of the same format whose documents have
live annotations, a page of at most 100 at a time with cursors both ways.

Each anchor keeps layered evidence: the unit (EPUB spine index and resource
path, or PDF page and rectangles), the Unicode-scalar range it covered, and a
quote normalized by the `shosai-quote-v1` profile with 32 scalars of context
on each side. `list` resolves every anchor against the book's text as the
format engine supplies it through `UnitTextSource`:

- **exact**: the stored range still holds the quote, on the content the
  annotation was made on;
- **recovered**: the quote occurs once (or once in its context) elsewhere in
  the unit;
- **ambiguous**: it occurs more than once and context cannot decide;
- **orphaned**: it no longer occurs, the spine item holds another resource,
  or the page is gone. A PDF annotation without text resolves only on its own
  content.

`shosai-quote-v1` pins Unicode 17.0.0 (RFD 16). NFC comes from `unorm_dart`
0.3.2, pinned exactly: it carries Unicode 17.0.0 data, and 0.3.3 moved to
Unicode 18. Grapheme clusters come from the package's own UAX #29 segmenter
(`lib/src/annotations/graphemes.dart`), because `characters`, which the
Flutter SDK pins at 1.4.1, implements Unicode 16; its table is generated from
the Unicode 17.0.0 Character Database by
`scripts/generate-quote-unicode-tables.py` (`--check` verifies it), and
`test/unicode_test.dart` runs the official conformance file and fails if
either part changes Unicode version. Selectors are checked where they enter
resolution and when records read them: limits in scalars, fields already
normalized, and an original quote that normalizes to the exact one.

Resolution runs in another isolate, in batches of about 4 MiB of text, and is
bounded at 64M work units and 1,024-scalar graphemes, so a hostile book fails
with `limitExceeded` instead of stalling. Cancellation is checked between
steps (each unit's text, each batch, before returning), so a cancelled
listing returns nothing; the work inside one batch is not interrupted.
PDF rectangles are stored as float32 and checked after rounding, so none is
stored infinite or empty. A document holds at most 1,024 live
annotations, 65,536 PDF rectangles and an estimated 8 MiB, and spans at most
128 versions; deletion leaves a tombstone for synchronization.

### Search

`searchBook` finds every occurrence of a query in the unit texts a
`UnitTextSource` supplies, in unit order, with offsets and lengths in Unicode
scalars and up to 40 scalars of context on each side. Matching uses Unicode
full case folding (`tool/generate_case_fold.py` regenerates the table from
Python's `str.casefold`), so "STRASSE" finds "Straße", and a match covers
whole characters only: "s" never matches half of "ß". The search is one
linear Knuth-Morris-Pratt pass per unit, run in other isolates about 1 MiB of
text at a time with cancellation checked between runs and after each unit
is read; a cancelled search fails with `cancelled` rather than returning
results. The 1 MiB is a soft target: a unit is never split, so cancellation
can wait for one whole unit, up to the 8 MiB of text a search covers. A query
is at most 4 KiB, one search covers at most 8 MiB of text and returns at most
10,000 matches and 8 MiB of results; past a limit it fails with
`limitExceeded` instead of returning a truncated list.

Errors are `CoreException`s whose `CoreErrorKind` the controllers map to
their own messages.

## Tests

```sh
dart pub get
dart test
```

The killed-writer test runs a Python 3 SQLite writer in a separate process and
kills it with `SIGKILL`; it is skipped where Python 3 or POSIX signals are
unavailable.
