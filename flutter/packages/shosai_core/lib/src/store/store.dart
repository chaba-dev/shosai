/// The single owner of the Shōsai SQLite database.
///
/// One worker isolate opens the database, runs the migrations and then
/// executes every query the application sends it, one at a time. No other
/// isolate or object holds a connection, so writes are serialized by
/// construction and the UI isolate never blocks on SQLite.
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:sqlite3/sqlite3.dart';

import '../errors.dart';
import 'schema.dart';

export 'package:sqlite3/sqlite3.dart' show Database, Row, ResultSet;

/// `PRAGMA application_id` of a database this core created ("Shsi").
const shosaiApplicationId = 0x53687369;

/// How long a statement waits for a lock held by another process (a second
/// application instance) before it fails.
const storeBusyTimeout = Duration(seconds: 5);

/// One ordered schema step. Each migration runs in its own immediate
/// transaction together with the `user_version` update that records it, so a
/// process killed mid-migration leaves the previous version intact.
final class Migration {
  const Migration(this.version, this.name, this.sql);

  final int version;
  final String name;
  final String sql;
}

/// A query body run on the store's worker isolate.
///
/// The body runs synchronously against the only connection. It is sent to the
/// worker, so it may capture only values that can cross an isolate boundary
/// (strings, numbers, lists, records, plain data classes), and its result must
/// be such a value too.
typedef StoreBody<T> = T Function(Database db);

/// The application's SQLite database, owned by a dedicated worker isolate.
///
/// A `Store` itself carries only an identifier and the worker's port, so it
/// can be captured by a [StoreBody] without making the body unsendable.
final class Store {
  Store._(this._id, this._worker, this.path, this.schemaVersion);

  final int _id;
  final SendPort _worker;

  /// The database file this store opened.
  final String path;

  /// The schema version after migrations ran.
  final int schemaVersion;

  static final _clients = <int, _StoreClient>{};
  static var _nextId = 0;

  /// Open (creating if needed) the database at [path] and migrate it.
  ///
  /// Fails with [CoreErrorKind.malformed] when the file is not a Shōsai
  /// database or was written by a newer schema; the file is left untouched.
  static Future<Store> open(
    String path, {
    List<Migration> migrations = schemaMigrations,
  }) async {
    final startup = ReceivePort();
    final exit = ReceivePort();
    final responses = ReceivePort();
    try {
      await Isolate.spawn(
        _workerMain,
        _Startup(startup.sendPort, responses.sendPort, path, migrations),
        onExit: exit.sendPort,
        debugName: 'shosai-store',
        errorsAreFatal: true,
      );
    } catch (error) {
      startup.close();
      exit.close();
      responses.close();
      throw CoreException.storage(
        'The database worker could not start: $error',
      );
    }
    final id = _nextId++;
    final client = _StoreClient(responses, exit, () => _clients.remove(id));
    final first = await Future.any([
      startup.first,
      client.exited.then((_) => const _Exited()),
    ]);
    startup.close();
    switch (first) {
      case _Ready(:final requests, :final schemaVersion):
        _clients[id] = client;
        return Store._(id, requests, path, schemaVersion);
      case _Failed(:final error):
        await client.exited;
        throw error;
      default:
        throw const CoreException.storage(
          'The database worker exited during startup.',
        );
    }
  }

  /// Run a read on the worker. Reads see every write sent before them.
  Future<T> read<T>(StoreBody<T> body) => _send(body, write: false);

  /// Run [body] inside `BEGIN IMMEDIATE … COMMIT` on the worker.
  ///
  /// Any exception rolls the transaction back and is rethrown here.
  Future<T> transaction<T>(StoreBody<T> body) => _send(body, write: true);

  /// Finish queued work, close the connection and stop the worker.
  ///
  /// Requests sent after [close] fail with [CoreErrorKind.storage].
  Future<void> close() {
    final client = _clients[_id];
    if (client == null) return Future.value();
    return client.close(_worker);
  }

  Future<T> _send<T>(StoreBody<T> body, {required bool write}) async {
    final client = _clients[_id];
    if (client == null) {
      throw const CoreException.storage('The database is closed.');
    }
    final result = await client.request(_worker, body, write);
    return result as T;
  }
}

final class _StoreClient {
  _StoreClient(this._responses, this._exit, this._onDone) {
    _responses.listen((message) {
      switch (message) {
        case _Result(:final id, :final value):
          _pending.remove(id)?.complete(value);
        case _Failure(:final id, :final error, :final stackTrace):
          _pending
              .remove(id)
              ?.completeError(error, StackTrace.fromString(stackTrace));
      }
    });
    // The worker only exits after closing its connection (or by crashing),
    // and its exit message arrives after every response it sent.
    _exit.listen((_) => _finish());
  }

  final ReceivePort _responses;
  final ReceivePort _exit;
  final void Function() _onDone;
  final _pending = <int, Completer<Object?>>{};
  final _exited = Completer<void>();
  var _nextRequest = 0;
  Completer<void>? _closing;

  bool get _done => _exited.isCompleted;

  Future<void> get exited => _exited.future;

  Future<Object?> request(SendPort worker, Function body, bool write) {
    if (_closing != null || _done) {
      return Future.error(
        const CoreException.storage('The database is closed.'),
      );
    }
    final id = _nextRequest++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    try {
      worker.send(_Run(id, body, write));
    } on ArgumentError catch (error) {
      _pending.remove(id);
      return Future.error(
        CoreException.storage('A database request could not be sent: $error'),
      );
    }
    return completer.future;
  }

  Future<void> close(SendPort worker) {
    if (_closing == null) {
      _closing = Completer<void>();
      if (!_done) worker.send(const _Close());
    }
    return exited;
  }

  void _finish() {
    if (_done) return;
    _exited.complete();
    for (final completer in _pending.values) {
      completer.completeError(
        const CoreException.storage('The database worker stopped.'),
      );
    }
    _pending.clear();
    _responses.close();
    _exit.close();
    _onDone();
  }
}

// Messages between the store and its worker. Everything here is sent across
// the isolate boundary.

final class _Startup {
  const _Startup(this.startup, this.responses, this.path, this.migrations);

  final SendPort startup;
  final SendPort responses;
  final String path;
  final List<Migration> migrations;
}

final class _Ready {
  const _Ready(this.requests, this.schemaVersion);

  final SendPort requests;
  final int schemaVersion;
}

final class _Failed {
  const _Failed(this.error);

  final Object error;
}

final class _Exited {
  const _Exited();
}

final class _Run {
  const _Run(this.id, this.body, this.write);

  final int id;
  final Function body;
  final bool write;
}

final class _Close {
  const _Close();
}

final class _Result {
  const _Result(this.id, this.value);

  final int id;
  final Object? value;
}

final class _Failure {
  const _Failure(this.id, this.error, this.stackTrace);

  final int id;
  final Object error;
  final String stackTrace;
}

void _workerMain(_Startup startup) {
  final Database db;
  final int version;
  try {
    db = openStoreDatabase(startup.path);
    try {
      version = migrateStoreDatabase(db, startup.migrations);
    } catch (_) {
      db.close();
      rethrow;
    }
  } catch (error) {
    startup.startup.send(_Failed(_sendableError(error)));
    return;
  }
  final requests = ReceivePort();
  startup.startup.send(_Ready(requests.sendPort, version));
  requests.listen((message) {
    switch (message) {
      case _Run(:final id, :final body, :final write):
        try {
          final value = write
              ? _inTransaction(db, body)
              : (body as Object? Function(Database))(db);
          try {
            startup.responses.send(_Result(id, value));
          } on ArgumentError catch (error) {
            startup.responses.send(
              _Failure(
                id,
                CoreException.storage(
                  'A database result could not be sent: $error',
                ),
                StackTrace.current.toString(),
              ),
            );
          }
        } catch (error, stackTrace) {
          startup.responses.send(
            _Failure(id, _sendableError(error), stackTrace.toString()),
          );
        }
      case _Close():
        db.close();
        requests.close();
    }
  });
}

Object? _inTransaction(Database db, Function body) {
  db.execute('BEGIN IMMEDIATE');
  try {
    final value = (body as Object? Function(Database))(db);
    db.execute('COMMIT');
    return value;
  } catch (_) {
    if (!db.autocommit) db.execute('ROLLBACK');
    rethrow;
  }
}

/// SQLite failures become storage errors; core errors pass through unchanged.
Object _sendableError(Object error) => switch (error) {
  CoreException() => error,
  SqliteException(:final message, :final extendedResultCode) =>
    CoreException.storage('$message (SQLite $extendedResultCode)'),
  _ =>
    error is Error || error is Exception
        ? CoreException.storage(error.toString())
        : CoreException.storage('$error'),
};

/// Open the database file with the store's connection settings.
///
/// Exposed for tests and tools that inspect a database the way the worker
/// does; application code goes through [Store.open].
Database openStoreDatabase(String path) {
  final parent = File(path).parent;
  try {
    parent.createSync(recursive: true);
  } on FileSystemException catch (error) {
    throw CoreException(
      CoreErrorKind.inaccessible,
      'The data directory could not be created: ${error.osError?.message ?? error.message}',
    );
  }
  final Database db;
  try {
    db = sqlite3.open(path);
  } on SqliteException catch (error) {
    throw CoreException(
      CoreErrorKind.inaccessible,
      'The database could not be opened: ${error.message}',
    );
  }
  try {
    db.execute('PRAGMA busy_timeout = ${storeBusyTimeout.inMilliseconds}');
    // Check ownership before anything (even the journal mode) writes to the
    // file, so a database this core did not create is left byte for byte.
    if (_pragmaInt(db, 'application_id') != shosaiApplicationId) {
      final hasObjects = db
          .select('SELECT 1 FROM sqlite_schema LIMIT 1')
          .isNotEmpty;
      if (_pragmaInt(db, 'application_id') != 0 ||
          _pragmaInt(db, 'user_version') != 0 ||
          hasObjects) {
        throw const CoreException.malformed(
          'The database was not created by this version of Shōsai.',
        );
      }
    }
    final mode = db.select('PRAGMA journal_mode = WAL').first.columnAt(0);
    if (mode != 'wal') {
      throw CoreException.storage(
        'The database refused WAL journaling ($mode).',
      );
    }
    db.execute('PRAGMA synchronous = NORMAL');
    db.execute('PRAGMA foreign_keys = ON');
    return db;
  } on SqliteException catch (error) {
    db.close();
    throw CoreException.malformed(
      'The file is not a usable database: ${error.message}',
    );
  } catch (_) {
    db.close();
    rethrow;
  }
}

/// Bring [db] to the newest of [migrations] and return its schema version.
///
/// [db] must come from [openStoreDatabase], which refuses foreign files.
int migrateStoreDatabase(Database db, List<Migration> migrations) {
  _checkMigrationOrder(migrations);
  final userVersion = _pragmaInt(db, 'user_version');
  final latest = migrations.isEmpty ? 0 : migrations.last.version;
  if (userVersion > latest) {
    throw CoreException.malformed(
      'The database schema ($userVersion) is newer than this application ($latest).',
    );
  }
  for (final migration in migrations) {
    if (migration.version <= userVersion) continue;
    db.execute('BEGIN IMMEDIATE');
    try {
      if (migration.version == 1) {
        db.execute('PRAGMA application_id = $shosaiApplicationId');
      }
      db.execute(migration.sql);
      db.execute('PRAGMA user_version = ${migration.version}');
      db.execute('COMMIT');
    } catch (error) {
      if (!db.autocommit) db.execute('ROLLBACK');
      throw CoreException.storage(
        'Migration ${migration.version} (${migration.name}) failed: $error',
      );
    }
  }
  return _pragmaInt(db, 'user_version');
}

void _checkMigrationOrder(List<Migration> migrations) {
  for (var index = 0; index < migrations.length; index++) {
    if (migrations[index].version != index + 1) {
      throw StateError('Migrations must be numbered 1, 2, 3, … in order.');
    }
  }
}

int _pragmaInt(Database db, String name) =>
    db.select('PRAGMA $name').first.columnAt(0) as int;
