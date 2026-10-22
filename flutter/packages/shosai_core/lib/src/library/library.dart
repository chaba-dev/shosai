/// The library: importing, listing, opening and removing books.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../cancellation.dart';
import '../errors.dart';
import '../store/store.dart';
import 'book.dart';
import 'files.dart';
import 'inspection.dart';
import 'records.dart';

/// Longest library search query, in UTF-8 bytes.
const maxLibraryQueryBytes = 4 * 1024;

/// Largest library page.
const maxLibraryPageSize = 500;

/// Longest stored title or author, in UTF-8 bytes.
const maxBookMetadataBytes = 4 * 1024;

/// Most paths one import request may select.
const maxSelectedImportPaths = 256;

/// Deletion retries handled per [Library.retryManagedFileDeletions] call.
const managedDeletionRetryBatch = 100;

/// The person's books and their private copies.
///
/// A book is identified by its content: importing bytes that are already in
/// the library returns that book (and repoints a referenced book whose file
/// went missing), so reading state and notes follow the content wherever the
/// file lives. Referenced books stay where the person keeps them; managed
/// books are copied into [managedDirectory] under their content hash.
final class Library {
  Library(
    Store store, {
    required this.managedDirectory,
    Map<BookFormat, BookInspector> inspectors = const {
      BookFormat.epub: EpubInspector(),
    },
  }) : _records = LibraryRecords(store),
       _inspectors = inspectors;

  final LibraryRecords _records;

  /// Where private copies live.
  final String managedDirectory;
  final Map<BookFormat, BookInspector> _inspectors;

  /// Run [section] while holding the managed directory's lock, which
  /// serializes publishing, claiming and deleting private copies with the
  /// database changes that own them, so a deletion never removes a copy that
  /// an import is about to claim.
  ///
  /// The lock is shared by every [Library] over the same directory in this
  /// isolate, whatever path names it (the directory is created, then keyed
  /// by its resolved path), and by other processes through an exclusive lock
  /// on `.shosai-lock` in the directory. The in-isolate lock is taken before
  /// the lock file is opened: POSIX file locks belong to the process, and
  /// closing any descriptor of the file releases them. (Use a library's
  /// directory from one isolate per process for the same reason.)
  ///
  /// [section] receives the validated root (see [_validatedRoot]), or null
  /// when the directory has been redirected and nothing in it may be
  /// published or deleted. Throws [CoreErrorKind.inaccessible] when the
  /// directory cannot be created or locked.
  Future<T> _withManagedFiles<T>(
    Future<T> Function(String? root) section,
  ) async {
    final key = await _resolveManagedDirectory();
    return _managedLocks.putIfAbsent(key, _Lock.new).run(() async {
      // Checked once the in-isolate lock is held, so a redirection while
      // waiting for it is caught: a redirected directory gets no lock file
      // either, since nothing will be published or deleted in it.
      if (await _validatedRoot(key) == null) return section(null);
      final RandomAccessFile lock;
      try {
        lock = await File(
          p.join(key, _lockFileName),
        ).open(mode: FileMode.append);
      } on FileSystemException catch (error) {
        throw _unusableDirectory(error);
      }
      try {
        await lock.lock(FileLock.blockingExclusive);
        return await section(await _validatedRoot(key));
      } finally {
        await lock.close();
      }
    });
  }

  /// Create the managed directory if needed and return its resolved path.
  Future<String> _resolveManagedDirectory() async {
    try {
      final directory = Directory(managedDirectory);
      await directory.create(recursive: true);
      return await directory.resolveSymbolicLinks();
    } on FileSystemException catch (error) {
      throw _unusableDirectory(error);
    }
  }

  /// [resolved], if the managed directory still resolves to it and it is the
  /// path recorded when this directory was first used; else null.
  ///
  /// A directory (or an ancestor) replaced by a symlink resolves somewhere
  /// else, perhaps into the person's own folder, where an import must not
  /// replace or a sweep delete what it finds.
  Future<String?> _validatedRoot(String resolved) async {
    final String current;
    try {
      current = await Directory(managedDirectory).resolveSymbolicLinks();
    } on FileSystemException {
      return null;
    }
    if (current != resolved) return null;
    final matches = await _records.claimManagedDirectory(
      p.normalize(p.absolute(managedDirectory)),
      resolved,
    );
    return matches ? resolved : null;
  }

  /// The book with [id], or null.
  Future<Book?> get(int id) => _records.book(id);

  /// The stored cover thumbnail (PNG) of book [id], or null.
  Future<Uint8List?> cover(int id) => _records.cover(id);

  /// A page of books in [sort] order.
  ///
  /// [query] matches title or author as a case-insensitive substring;
  /// [limit] is capped at [maxLibraryPageSize].
  Future<LibraryPage> page({
    String? query,
    BookFormat? format,
    LibrarySort sort = LibrarySort.recent,
    int limit = 100,
    int offset = 0,
  }) async {
    if (query != null && utf8.encode(query).length > maxLibraryQueryBytes) {
      throw const CoreException.invalidRequest(
        'The library query exceeds $maxLibraryQueryBytes bytes.',
      );
    }
    if (limit < 1 || offset < 0) {
      throw const CoreException.invalidRequest(
        'The page limit must be positive and the offset non-negative.',
      );
    }
    final pageSize = limit > maxLibraryPageSize ? maxLibraryPageSize : limit;
    return _records.page(query, format, sort, pageSize, offset);
  }

  /// Import each of [paths], continuing past failures.
  ///
  /// Cancellation stops before the next file; files already imported stay
  /// imported and the report says it was cancelled.
  Future<ImportReport> importPaths(
    List<String> paths, {
    required bool managed,
    CancellationToken? cancellation,
  }) async {
    if (paths.length > maxSelectedImportPaths) {
      throw const CoreException.invalidRequest(
        'At most $maxSelectedImportPaths paths may be imported at once.',
      );
    }
    for (final path in paths) {
      checkBookPath(path);
    }
    final report = _ReportBuilder();
    for (final path in paths) {
      if (cancellation?.isCancelled ?? false) {
        report.cancelled = true;
        break;
      }
      try {
        report.add(
          await importFile(path, managed: managed, cancellation: cancellation),
        );
      } on CoreException catch (error) {
        if (error.kind != CoreErrorKind.cancelled) rethrow;
        report.cancelled = true;
        break;
      }
    }
    return report.build();
  }

  /// Import every book under [directory] (see [discoverBooks]).
  ///
  /// Cancelled before anything finished, this throws
  /// [CoreErrorKind.cancelled]; cancelled later, it reports what finished.
  Future<ImportReport> importDirectory(
    String directory, {
    required bool managed,
    CancellationToken? cancellation,
  }) async {
    checkBookPath(directory);
    final root = canonicalBookPath(directory);
    final discovery = await discoverBooks(
      directory,
      cancellation: cancellation,
    );
    final report = _ReportBuilder();
    for (final failure in discovery.failures) {
      report.add(ImportItem.failed(failure.path, failure.error));
    }
    for (final book in discovery.books) {
      try {
        cancellation.throwIfCancelled();
        report.add(
          await _importFile(
            book.path,
            managed: managed,
            cancellation: cancellation,
            within: root,
          ),
        );
      } on CoreException catch (error) {
        if (error.kind != CoreErrorKind.cancelled) rethrow;
        if (report.isEmpty) rethrow;
        report.cancelled = true;
        break;
      }
    }
    return report.build();
  }

  /// Import one file. Failures are reported in the item; only cancellation
  /// before the commit throws.
  Future<ImportItem> importFile(
    String selected, {
    required bool managed,
    CancellationToken? cancellation,
  }) => _importFile(selected, managed: managed, cancellation: cancellation);

  /// [within], for a directory import, is the chosen folder: the file is
  /// resolved again here, and one that now resolves outside it (a folder
  /// replaced by a symlink since discovery) is refused.
  Future<ImportItem> _importFile(
    String selected, {
    required bool managed,
    CancellationToken? cancellation,
    String? within,
  }) async {
    try {
      checkBookPath(selected);
      cancellation.throwIfCancelled();
      final path = canonicalBookPath(selected);
      checkBookPath(path);
      if (within != null && !p.isWithin(within, path)) {
        throw CoreException.invalidRequest(
          'The file is no longer inside the chosen folder: $selected',
        );
      }
      if (!managed && _isPrivateCopyPath(path)) {
        throw CoreException.invalidRequest(
          'The file is one of the library\'s private copies: $selected',
        );
      }
      final format = await detectBookFormat(path);
      if (format == null) {
        final extension = p.extension(path);
        throw CoreException(
          CoreErrorKind.unsupported,
          extension.isEmpty
              ? 'Unsupported format: $selected'
              : 'Unsupported format: $extension',
        );
      }
      cancellation.throwIfCancelled();
      final (book, duplicate) = managed
          ? await _importManaged(path, format, cancellation)
          : await _importReferenced(path, format, cancellation);
      return ImportItem.imported(selected, book, duplicate: duplicate);
    } on CoreException catch (error) {
      if (error.kind == CoreErrorKind.cancelled) rethrow;
      return ImportItem.failed(selected, error.message);
    } on FileSystemException catch (error) {
      return ImportItem.failed(
        selected,
        'Could not import: ${error.osError?.message ?? error.message}',
      );
    }
  }

  bool _isPrivateCopyPath(String path) {
    final directory = canonicalBookPath(managedDirectory);
    return path == directory || p.isWithin(directory, path);
  }

  Future<(Book, bool)> _importReferenced(
    String path,
    BookFormat format,
    CancellationToken? cancellation,
  ) async {
    final fingerprint = await fingerprintFile(path, cancellation: cancellation);
    BookMetadata? metadata;
    while (true) {
      final metadataToStore = metadata;
      final outcome = await _records.commitReferenced(
        path,
        format,
        fingerprint,
        metadataToStore,
      );
      if (outcome case Committed(:final book, :final duplicate)) {
        return (book, duplicate);
      }
      metadata = await _inspect(path, format, cancellation);
      if (!await fingerprint.unchangedSince(path)) {
        throw CoreException.conflict('The file changed during import: $path');
      }
    }
  }

  Future<(Book, bool)> _importManaged(
    String source,
    BookFormat format,
    CancellationToken? cancellation,
  ) async {
    // Stage and publish only under the validated root: never under a fresh
    // resolution that a symlink may have pointed somewhere else.
    final root = await _validatedRoot(await _resolveManagedDirectory());
    if (root == null) throw _redirectedDirectory();
    final stage = uniqueTemporaryPath(root, 'import');
    // The stage is only cleaned up once this import created it: a failed
    // exclusive create must not delete a file it does not own.
    var staged = false;
    try {
      final fingerprint = await copyAndFingerprint(
        source,
        stage,
        cancellation: cancellation,
      );
      staged = true;
      final existing = await _records.bookWithContent(fingerprint.hash);
      final metadata = existing == null
          ? await _inspect(stage, format, cancellation, titlePath: source)
          : null;
      final destination = p.join(root, '${fingerprint.hash}.${format.name}');
      checkBookPath(destination);
      cancellation.throwIfCancelled();
      // The commit point: from here the copy is published and recorded even
      // if cancellation arrives.
      return await _withManagedFiles((locked) async {
        // The directory may have been redirected since the stage was made.
        if (locked != root) throw _redirectedDirectory();
        // Decided under the lock: a removal may have claimed the copy since.
        final current = await _records.bookWithContent(fingerprint.hash);
        if (current != null &&
            current.managed &&
            await fileHasFingerprint(current.path, fingerprint)) {
          return (current, true);
        }
        await _records.checkDestinationOwner(destination, fingerprint.hash);
        if (!await _resolvesTo(root)) throw _redirectedDirectory();
        final destinationExisted = await File(destination).exists();
        await publishManagedFile(stage, destination, fingerprint);
        try {
          final outcome = await _records.commitManaged(
            source,
            destination,
            format,
            fingerprint,
            metadata,
          );
          switch (outcome) {
            case Committed(:final book, :final duplicate):
              return (book, duplicate);
            case NeedsMetadata():
              // The book this import was going to join was removed meanwhile.
              throw CoreException.conflict(
                'The library changed during import; import $source again.',
              );
          }
        } catch (_) {
          if (!destinationExisted && await _resolvesTo(root)) {
            await _deleteQuietly(destination);
          }
          rethrow;
        }
      });
    } finally {
      // A stage left behind in a redirected directory is swept later, if
      // the directory comes back.
      if (staged && await _resolvesTo(root)) await _deleteQuietly(stage);
    }
  }

  Future<BookMetadata> _inspect(
    String path,
    BookFormat format,
    CancellationToken? cancellation, {
    String? titlePath,
  }) async {
    final inspector = _inspectors[format];
    final metadata = inspector == null
        ? const BookMetadata()
        : await inspector.inspect(path, cancellation: cancellation);
    cancellation.throwIfCancelled();
    final title =
        _metadataText(metadata.title) ??
        _metadataText(p.basenameWithoutExtension(titlePath ?? path)) ??
        'Untitled';
    final author = _metadataText(metadata.author);
    if (utf8.encode(title).length > maxBookMetadataBytes ||
        (author != null && utf8.encode(author).length > maxBookMetadataBytes)) {
      throw const CoreException.limitExceeded(
        'The book title or author exceeds $maxBookMetadataBytes bytes.',
      );
    }
    final cover = metadata.cover;
    return BookMetadata(
      title: title,
      author: author,
      cover: cover == null || cover.isEmpty || cover.length > maxCoverBytes
          ? null
          : cover,
    );
  }

  /// The path to open for book [id], after checking that the file still
  /// holds the book's content.
  Future<String> verifiedPath(int id, {CancellationToken? cancellation}) async {
    final book = await get(id);
    if (book == null) {
      throw const CoreException.notFound('The book is not in the library.');
    }
    final FileFingerprint fingerprint;
    try {
      fingerprint = await fingerprintFile(
        book.path,
        cancellation: cancellation,
      );
    } on CoreException catch (error) {
      if (error.kind == CoreErrorKind.notFound) {
        throw CoreException.notFound('The book file is missing: ${book.path}');
      }
      rethrow;
    }
    if (fingerprint.hash != book.contentHash) {
      throw CoreException.conflict(
        'The file contents no longer match the library book: ${book.path}',
      );
    }
    return book.path;
  }

  /// Record reading progress (clamped to 0…1) and the reading time.
  Future<void> updateProgress(int id, double progress) async {
    if (!progress.isFinite) {
      throw const CoreException.invalidRequest('Progress must be finite.');
    }
    final clamped = progress.clamp(0.0, 1.0).toDouble();
    final updated = await _records.updateProgress(id, clamped);
    if (updated == 0) {
      throw const CoreException.notFound('The book is not in the library.');
    }
  }

  /// Remove book [id]. A referenced file is never touched; a private copy is
  /// deleted after the removal commits, or recorded for a later retry.
  ///
  /// The removal itself never needs the managed directory: it commits first,
  /// recording a private copy as deletion debt, and the copy is deleted only
  /// under the directory's lock. When the directory cannot be locked or has
  /// been redirected, the deletion is reported pending.
  Future<RemoveOutcome> remove(int id) async {
    final removed = await _records.remove(id);
    if (removed == null) {
      return const RemoveOutcome(
        removed: false,
        managedFileDeletionPending: false,
      );
    }
    if (!removed.managed) {
      return const RemoveOutcome(
        removed: true,
        managedFileDeletionPending: false,
      );
    }
    bool deleted;
    try {
      deleted = await _withManagedFiles(
        (root) async =>
            root != null && await _deleteManagedFile(removed.path, root),
      );
    } on CoreException {
      // The removal is committed; its debt stays for a later retry.
      deleted = false;
    } on FileSystemException {
      deleted = false;
    }
    return RemoveOutcome(removed: true, managedFileDeletionPending: !deleted);
  }

  /// Retry deleting private copies of removed books, least-tried first,
  /// then delete what a crash left in the managed directory (see
  /// [_sweepOrphans]). Run at start-up.
  ///
  /// Only copies recorded in this library's managed directory, while it
  /// still resolves to the path recorded when it was first used, are
  /// deleted; any other debt stays pending.
  Future<({int cleared, int pending})> retryManagedFileDeletions() =>
      _withManagedFiles((root) async {
        final paths = await _records.claimDeletionRetries(
          managedDeletionRetryBatch,
        );
        if (root == null) return (cleared: 0, pending: paths.length);
        var cleared = 0;
        for (final path in paths) {
          if (await _deleteManagedFile(path, root)) cleared++;
        }
        await _sweepOrphans(root);
        return (cleared: cleared, pending: paths.length - cleared);
      });

  /// Delete entries of the managed directory [root] that no book or deletion
  /// debt owns: a copy published by an import that died before its commit,
  /// and quarantined files from a publish or deletion that died midway.
  /// Staging files are written outside the lock by imports that may still be
  /// running, so only ones older than [_staleStageAge] go. Runs under the
  /// lock, where every published copy has a book or a debt, and only with a
  /// validated root (see [_validatedRoot]): a redirected directory's listing
  /// could be someone else's folder.
  ///
  /// At most [managedDeletionRetryBatch] unowned entries go per call; owned
  /// ones do not count, so a directory of many books never starves the sweep.
  Future<void> _sweepOrphans(String root) async {
    final now = DateTime.now();
    final orphans = <String>[];
    final pending = <String>[];
    Future<void> collect() async {
      orphans.addAll(await _records.unowned(pending));
      pending.clear();
    }

    if (!await _resolvesTo(root)) return;
    try {
      await for (final entry in Directory(root).list(followLinks: false)) {
        if (entry is! File) continue;
        final name = p.basename(entry.path);
        if (_publishedName.hasMatch(name) ||
            name.startsWith('.shosai-damaged-') ||
            name.startsWith('.shosai-delete-')) {
          pending.add(entry.path);
        } else if (name.startsWith('.shosai-import-') &&
            now.difference((await entry.stat()).modified) > _staleStageAge) {
          pending.add(entry.path);
        }
        if (pending.length >= _sweepOwnershipBatch) {
          await collect();
          if (orphans.length >= managedDeletionRetryBatch) break;
        }
      }
      await collect();
    } on FileSystemException {
      return;
    }
    for (final path in orphans.take(managedDeletionRetryBatch)) {
      if (await _records.isOwned(path)) continue;
      // The listing is only trusted while root still resolves to itself.
      if (!await _resolvesTo(root)) return;
      await _deleteQuietly(path);
    }
  }

  /// Delete the recorded private copy at [path]. A path that a book uses
  /// again stays, and so does its debt until that book is gone (a managed
  /// import that reclaims the copy clears the debt itself). Debt recorded in
  /// a directory other than the locked [root] stays pending: its directory's
  /// lock is not held. Returns true once nothing remains to do. Runs under
  /// [_withManagedFiles].
  Future<bool> _deleteManagedFile(String path, String root) async {
    final debt = await _records.deletionDebt(path);
    final managedDirectory = debt.directory;
    if (managedDirectory == null) return true;
    if (debt.inUse || managedDirectory != root) return false;
    // Only delete a direct child of the directory recorded with the debt
    // (the copy's own canonical directory when it was imported). The parent
    // is resolved now and compared with that stored path, never with a fresh
    // resolution of it: if the directory or an ancestor has since been
    // replaced by a symlink, they differ and nothing is deleted.
    final String parent;
    try {
      parent = await Directory(p.dirname(path)).resolveSymbolicLinks();
    } on FileSystemException {
      return false;
    }
    if (parent != managedDirectory) return false;
    // Rename the entry itself (a symlink is never followed), then delete it.
    final FileSystemEntity entry;
    switch (await FileSystemEntity.type(path, followLinks: false)) {
      case FileSystemEntityType.notFound:
        await _records.clearDeletionDebt(path);
        return true;
      case FileSystemEntityType.file:
        entry = File(path);
      case FileSystemEntityType.link:
        entry = Link(path);
      default:
        return false;
    }
    // Record the quarantine path before the rename, so a crash between the
    // two leaves a debt for wherever the file is.
    final quarantine = uniqueTemporaryPath(parent, 'delete');
    await _records.recordDeletionDebt(quarantine, managedDirectory);
    final FileSystemEntity quarantined;
    try {
      quarantined = await entry.rename(quarantine);
    } on FileSystemException {
      await _records.clearDeletionDebt(quarantine);
      return false;
    }
    await _records.clearDeletionDebt(path);
    if (!await _resolvesTo(parent)) return false;
    try {
      await quarantined.delete();
    } on PathNotFoundException {
      // Already gone.
    } on FileSystemException {
      return false;
    }
    await _records.clearDeletionDebt(quarantine);
    return true;
  }
}

/// Locks of the managed directories open in this isolate, by path.
final _managedLocks = <String, _Lock>{};

const _lockFileName = '.shosai-lock';

/// The name of a published private copy: `<sha256>.<format>`.
final _publishedName = RegExp(r'^[0-9a-f]{64}\.(epub|pdf)$');

/// A staging file this old is taken to belong to an import that is no longer
/// running. A heuristic: nothing records which imports are alive, and an
/// import that really ran this long would fail when its stage vanished.
const _staleStageAge = Duration(days: 1);

/// Sweep candidates checked for an owner per database read.
const _sweepOwnershipBatch = 200;

/// Whether the directory at [path] still resolves to [path] itself.
///
/// A best-effort check at selected boundaries of an operation in the managed
/// directory (before publishing, sweeping, and some clean-ups); it gives no
/// guarantee against the directory being replaced while an operation runs:
/// `dart:io` has no operations relative to an open directory handle
/// (`openat`, `renameat`, `unlinkat`), and helpers such as the staging copy
/// still change files after longer waits. The library assumes that nothing
/// replaces its private directory, or a parent of it, while it runs.
Future<bool> _resolvesTo(String path) async {
  try {
    return await Directory(path).resolveSymbolicLinks() == path;
  } on FileSystemException {
    return false;
  }
}

CoreException _unusableDirectory(FileSystemException error) => CoreException(
  CoreErrorKind.inaccessible,
  'The private copy folder is not usable: '
  '${error.osError?.message ?? error.message}',
);

CoreException _redirectedDirectory() => const CoreException(
  CoreErrorKind.conflict,
  'The private copy folder no longer resolves to where it was first used '
  '(it or a parent folder was moved or replaced by a link); private copies '
  'are not stored there.',
);

String? _metadataText(String? value) {
  final collapsed = value?.trim().replaceAll(RegExp(r'\s+'), ' ');
  return collapsed == null || collapsed.isEmpty ? null : collapsed;
}

Future<void> _deleteQuietly(String path) async {
  try {
    await File(path).delete();
  } on FileSystemException {
    // Already gone, or a later import replaces it.
  }
}

final class _ReportBuilder {
  var imported = 0;
  var failed = 0;
  var cancelled = false;
  final items = <ImportItem>[];

  bool get isEmpty => imported == 0 && failed == 0;

  void add(ImportItem item) {
    if (item.book != null) {
      imported++;
    } else {
      failed++;
    }
    if (items.length < maxImportReportItems) items.add(item);
  }

  ImportReport build() => ImportReport(
    imported: imported,
    failed: failed,
    cancelled: cancelled,
    items: List.unmodifiable(items),
  );
}

/// Runs one asynchronous section at a time, in call order.
final class _Lock {
  Future<void> _tail = Future.value();

  Future<T> run<T>(Future<T> Function() section) {
    final result = _tail.then((_) => section());
    _tail = result.then((_) {}, onError: (_) {});
    return result;
  }
}
