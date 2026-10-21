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

  /// Serializes publishing and deleting private copies with the database
  /// changes that own them, so a deletion never removes a copy that an import
  /// is about to claim.
  final _managedFiles = _Lock();

  /// The book with [id], or null.
  Future<Book?> get(int id) => _records.book(id);

  /// The stored cover thumbnail (PNG) of book [id], or null.
  Future<Uint8List?> cover(int id) => _records.cover(id);

  /// A page of books, most recently read first, then most recently added.
  ///
  /// [query] matches title or author as a case-insensitive substring;
  /// [limit] is capped at [maxLibraryPageSize].
  Future<LibraryPage> page({
    String? query,
    BookFormat? format,
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
    return _records.page(query, format, pageSize, offset);
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
          await importFile(
            book.path,
            managed: managed,
            cancellation: cancellation,
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
  }) async {
    try {
      checkBookPath(selected);
      final path = canonicalBookPath(selected);
      checkBookPath(path);
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
    }
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
    await Directory(managedDirectory).create(recursive: true);
    final stage = uniqueTemporaryPath(managedDirectory, 'import');
    try {
      final fingerprint = await copyAndFingerprint(
        source,
        stage,
        cancellation: cancellation,
      );
      final existing = await _records.bookWithContent(fingerprint.hash);
      if (existing != null &&
          existing.managed &&
          await fileHasFingerprint(existing.path, fingerprint)) {
        return (existing, true);
      }
      final metadata = existing == null
          ? await _inspect(stage, format, cancellation, titlePath: source)
          : null;
      final destination = p.join(
        canonicalBookPath(managedDirectory),
        '${fingerprint.hash}.${format.name}',
      );
      checkBookPath(destination);
      cancellation.throwIfCancelled();
      // The commit point: from here the copy is published and recorded even
      // if cancellation arrives.
      return await _managedFiles.run(() async {
        await _records.checkDestinationOwner(destination, fingerprint.hash);
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
          if (!destinationExisted) await _deleteQuietly(destination);
          rethrow;
        }
      });
    } finally {
      await _deleteQuietly(stage);
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
  Future<RemoveOutcome> remove(int id) => _managedFiles.run(() async {
    final managedDirectory = canonicalBookPath(this.managedDirectory);
    final removed = await _records.remove(id, managedDirectory);
    if (removed == null) {
      return const RemoveOutcome(
        removed: false,
        managedFileDeletionPending: false,
      );
    }
    final pending = removed.managed && !await _deleteManagedFile(removed.path);
    return RemoveOutcome(removed: true, managedFileDeletionPending: pending);
  });

  /// Retry deleting private copies of removed books, least-tried first.
  Future<({int cleared, int pending})> retryManagedFileDeletions() =>
      _managedFiles.run(() async {
        final paths = await _records.claimDeletionRetries(
          managedDeletionRetryBatch,
        );
        var cleared = 0;
        for (final path in paths) {
          if (await _deleteManagedFile(path)) cleared++;
        }
        return (cleared: cleared, pending: paths.length - cleared);
      });

  /// Delete the recorded private copy at [path]. A path that a book uses
  /// again stays, and so does its debt until that book is gone (a managed
  /// import that reclaims the copy clears the debt itself). Returns true once
  /// nothing remains to do. Runs under [_managedFiles].
  Future<bool> _deleteManagedFile(String path) async {
    final debt = await _records.deletionDebt(path);
    if (debt.inUse) return false;
    final managedDirectory = debt.directory;
    if (managedDirectory == null) return true;
    // Only delete a direct child of the managed directory recorded with the
    // debt; a path that resolves anywhere else stays.
    final String parent;
    try {
      parent = await Directory(p.dirname(path)).resolveSymbolicLinks();
    } on FileSystemException {
      return false;
    }
    if (parent != canonicalBookPath(managedDirectory)) return false;
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
    final quarantine = uniqueTemporaryPath(parent, 'delete');
    final FileSystemEntity quarantined;
    try {
      quarantined = await entry.rename(quarantine);
    } on FileSystemException {
      return false;
    }
    await _records.moveDeletionDebt(path, quarantine);
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
