# shosai_core

The Dart application core of the Shōsai reader: the SQLite store and the
records kept in it. It replaces the Rust core and the Flutter bridge in
stacked slices (RFD 4, milestone M3.0) and is independent of Flutter widgets,
so its behaviour is tested with `dart test`.

## Store

`Store.open(path)` starts one worker isolate that owns the database's only
connection. Every query is a synchronous `StoreBody` the store sends to that
worker, so queries run one at a time in the order they were sent and the UI
isolate never blocks on SQLite. `Store.transaction` wraps a body in
`BEGIN IMMEDIATE … COMMIT` and rolls back on any exception.

A body is sent across an isolate boundary: it may capture plain values (and a
`Store` or a facade holding one), and it must return plain values. A write's
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
