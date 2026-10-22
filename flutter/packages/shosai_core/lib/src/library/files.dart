/// File-system work for the library: format detection, content fingerprints,
/// private copies and bounded discovery.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../cancellation.dart';
import '../errors.dart';
import 'book.dart';

/// Largest book file the library admits, for every format.
const maxBookInputBytes = 512 * 1024 * 1024;

/// Longest path the library stores, in UTF-8 bytes.
const maxBookPathBytes = 16 * 1024;

/// Discovery stops after visiting this many file-system entries.
const maxDiscoveryEntries = 50000;

/// Discovery admits at most this many books from one directory.
const maxDiscoveredBooks = 10000;

const _chunkBytes = 64 * 1024;

/// A file's content identity.
final class FileFingerprint {
  const FileFingerprint(this.hash, this.size, [this.modified]);

  /// Lowercase hexadecimal SHA-256.
  final String hash;
  final int size;

  /// The file's modification time when it was read. Not part of identity;
  /// [unchangedSince] uses it to detect a later edit without rehashing.
  final DateTime? modified;

  /// Whether the file at [path] still has this fingerprint's size and
  /// modification time.
  Future<bool> unchangedSince(String path) async {
    final stat = await File(path).stat();
    return stat.type == FileSystemEntityType.file &&
        stat.size == size &&
        stat.modified == modified;
  }

  @override
  bool operator ==(Object other) =>
      other is FileFingerprint && other.hash == hash && other.size == size;

  @override
  int get hashCode => Object.hash(hash, size);
}

/// The absolute, symlink-resolved form of [path] used as its library key.
String canonicalBookPath(String path) {
  try {
    return File(path).resolveSymbolicLinksSync();
  } on FileSystemException {
    return p.normalize(p.absolute(path));
  }
}

void checkBookPath(String path) {
  if (path.isEmpty || utf8.encode(path).length > maxBookPathBytes) {
    throw const CoreException.invalidRequest(
      'The path is empty or longer than $maxBookPathBytes bytes.',
    );
  }
}

/// The format of the file at [path]: by extension, else by content (a PDF
/// header, or an EPUB's leading uncompressed `mimetype` entry).
Future<BookFormat?> detectBookFormat(String path) async {
  final extension = p.extension(path);
  final byExtension = extension.isEmpty
      ? null
      : BookFormat.fromExtension(extension.substring(1));
  if (byExtension != null) return byExtension;
  // Probe only a regular file: opening a FIFO or device could block.
  await _stat(File(path), path);
  final RandomAccessFile file;
  try {
    file = await File(path).open();
  } on FileSystemException catch (error) {
    throw _inaccessible('inspect', path, error);
  }
  // A read or close failure fails this file only.
  final Uint8List header;
  try {
    try {
      header = await file.read(58);
    } finally {
      await file.close();
    }
  } on FileSystemException catch (error) {
    throw _inaccessible('inspect', path, error);
  }
  if (_startsWith(header, '%PDF-')) return BookFormat.pdf;
  if (header.length == 58 &&
      _startsWith(header, 'PK\x03\x04') &&
      latin1.decode(header.sublist(30, 38)) == 'mimetype' &&
      latin1.decode(header.sublist(38, 58)) == 'application/epub+zip') {
    return BookFormat.epub;
  }
  return null;
}

/// Read the whole book file at [path], admitting at most [maxBytes].
///
/// The size is checked before reading and the read stops one byte past the
/// limit, so a file that grows meanwhile cannot force a larger allocation.
Future<Uint8List> readBookBytes(
  String path, {
  int maxBytes = maxBookInputBytes,
  CancellationToken? cancellation,
}) async {
  final file = File(path);
  final stat = await _stat(file, path);
  if (stat.size > maxBytes) {
    throw CoreException.limitExceeded(
      'The book is larger than $maxBytes bytes.',
    );
  }
  cancellation.throwIfCancelled();
  final RandomAccessFile input;
  try {
    input = await file.open();
  } on FileSystemException catch (error) {
    throw _inaccessible('read', path, error);
  }
  final builder = BytesBuilder(copy: false);
  try {
    while (builder.length <= maxBytes) {
      cancellation.throwIfCancelled();
      final chunk = await input.read(_chunkBytes);
      if (chunk.isEmpty) break;
      builder.add(chunk);
    }
  } on FileSystemException catch (error) {
    throw _inaccessible('read', path, error);
  } finally {
    await input.close();
  }
  if (builder.length > maxBytes) {
    throw CoreException.limitExceeded(
      'The book is larger than $maxBytes bytes.',
    );
  }
  return builder.takeBytes();
}

bool _startsWith(Uint8List bytes, String prefix) =>
    bytes.length >= prefix.length &&
    latin1.decode(bytes.sublist(0, prefix.length)) == prefix;

/// Hash the file at [path] and check that it did not change while it was read.
Future<FileFingerprint> fingerprintFile(
  String path, {
  int maxBytes = maxBookInputBytes,
  CancellationToken? cancellation,
}) async {
  final file = File(path);
  final before = await _stat(file, path);
  if (before.size > maxBytes) {
    throw const CoreException.limitExceeded(
      'The book is larger than $maxBookInputBytes bytes.',
    );
  }
  final RandomAccessFile input;
  try {
    input = await file.open();
  } on FileSystemException catch (error) {
    throw _inaccessible('read', path, error);
  }
  final digest = _DigestSink();
  final hasher = sha256.startChunkedConversion(digest);
  var read = 0;
  try {
    while (true) {
      cancellation.throwIfCancelled();
      final chunk = await input.read(_chunkBytes);
      if (chunk.isEmpty) break;
      read += chunk.length;
      if (read > before.size) break;
      hasher.add(chunk);
    }
  } on FileSystemException catch (error) {
    throw _inaccessible('read', path, error);
  } finally {
    await input.close();
  }
  hasher.close();
  final after = await _stat(file, path);
  if (read != before.size || !_sameVersion(before, after)) {
    throw CoreException.conflict('The file changed while it was read: $path');
  }
  return FileFingerprint(digest.value.toString(), read, after.modified);
}

/// Copy [source] to a new file [destination] while hashing it.
///
/// [destination] must not exist; this creates it exclusively. It is flushed
/// to disk before this returns. On any failure, including cancellation, a
/// destination this call created is deleted again; one that already existed
/// is never touched.
Future<FileFingerprint> copyAndFingerprint(
  String source,
  String destination, {
  int maxBytes = maxBookInputBytes,
  CancellationToken? cancellation,
}) async {
  final sourceFile = File(source);
  final before = await _stat(sourceFile, source);
  if (before.size > maxBytes) {
    throw const CoreException.limitExceeded(
      'The book is larger than $maxBookInputBytes bytes.',
    );
  }
  final RandomAccessFile input;
  try {
    input = await sourceFile.open();
  } on FileSystemException catch (error) {
    throw _inaccessible('read', source, error);
  }
  final target = File(destination);
  RandomAccessFile? output;
  final digest = _DigestSink();
  final hasher = sha256.startChunkedConversion(digest);
  var copied = 0;
  var created = false;
  try {
    await target.create(exclusive: true);
    created = true;
    output = await target.open(mode: FileMode.writeOnly);
    while (true) {
      cancellation.throwIfCancelled();
      final chunk = await input.read(_chunkBytes);
      if (chunk.isEmpty) break;
      copied += chunk.length;
      if (copied > before.size) break;
      hasher.add(chunk);
      await output.writeFrom(chunk);
    }
    await output.flush();
    hasher.close();
    final after = await _stat(sourceFile, source);
    if (copied != before.size || !_sameVersion(before, after)) {
      throw CoreException.conflict(
        'The file changed while it was copied: $source',
      );
    }
    return FileFingerprint(digest.value.toString(), copied, after.modified);
  } catch (error) {
    await output?.close();
    output = null;
    if (created) await _deleteQuietly(target);
    if (error is FileSystemException) {
      throw _inaccessible('copy', source, error);
    }
    rethrow;
  } finally {
    await output?.close();
    await input.close();
  }
}

/// Move a verified private copy from [stage] to [destination].
///
/// A [destination] that already holds [expected] content is kept and the
/// stage discarded. One with other content (a damaged earlier copy) is set
/// aside, replaced and then deleted.
Future<void> publishManagedFile(
  String stage,
  String destination,
  FileFingerprint expected,
) async {
  final target = File(destination);
  if (await target.exists()) {
    final existing = await _fingerprintOrNull(destination);
    if (existing == expected) {
      await _deleteQuietly(File(stage));
      return;
    }
    final quarantine = uniqueTemporaryPath(p.dirname(destination), 'damaged');
    await target.rename(quarantine);
    try {
      await File(stage).rename(destination);
    } catch (_) {
      await File(quarantine).rename(destination);
      rethrow;
    }
    await _deleteQuietly(File(quarantine));
    return;
  }
  try {
    await File(stage).rename(destination);
  } on FileSystemException catch (error) {
    if (await _fingerprintOrNull(destination) == expected) {
      await _deleteQuietly(File(stage));
      return;
    }
    throw _inaccessible('store', destination, error);
  }
}

var _temporarySequence = 0;

/// A fresh hidden path in [directory] for staging or quarantine.
String uniqueTemporaryPath(String directory, String label) => p.join(
  directory,
  '.shosai-$label-$pid-${DateTime.now().microsecondsSinceEpoch}-'
  '${_temporarySequence++}.tmp',
);

/// Whether the file at [path] exists and holds [expected] content.
Future<bool> fileHasFingerprint(String path, FileFingerprint expected) async =>
    await _fingerprintOrNull(path) == expected;

Future<FileFingerprint?> _fingerprintOrNull(String path) async {
  try {
    return await fingerprintFile(path);
  } on CoreException {
    return null;
  }
}

Future<void> _deleteQuietly(File file) async {
  try {
    await file.delete();
  } on FileSystemException {
    // Already gone, or left for the next cleanup.
  }
}

Future<FileStat> _stat(File file, String path) async {
  final stat = await file.stat();
  if (stat.type == FileSystemEntityType.notFound) {
    throw CoreException.notFound('The file does not exist: $path');
  }
  if (stat.type != FileSystemEntityType.file) {
    throw CoreException.invalidRequest('Not a regular file: $path');
  }
  return stat;
}

bool _sameVersion(FileStat before, FileStat after) =>
    before.size == after.size && before.modified == after.modified;

CoreException _inaccessible(
  String action,
  String path,
  FileSystemException error,
) {
  if (error is PathNotFoundException) {
    return CoreException.notFound('The file does not exist: $path');
  }
  return CoreException(
    CoreErrorKind.inaccessible,
    'Could not $action $path: ${error.osError?.message ?? error.message}',
  );
}

final class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

/// A file found by [discoverBooks].
typedef DiscoveredBook = ({String path, BookFormat format});

/// What [discoverBooks] found under one directory.
final class Discovery {
  const Discovery(this.books, this.failures);

  /// Supported files, sorted by path.
  final List<DiscoveredBook> books;

  /// Paths that could not be inspected, with a reason, sorted by path.
  final List<({String path, String error})> failures;
}

/// Find the books under [root] without importing them.
///
/// Symlinks are followed only to targets inside [root], each directory is
/// visited once (so link cycles end), and only regular files with a
/// supported format are returned; other files are skipped silently. The walk
/// is bounded by [maxDiscoveryEntries] and [maxDiscoveredBooks].
Future<Discovery> discoverBooks(
  String root, {
  CancellationToken? cancellation,
}) async {
  final canonicalRoot = canonicalBookPath(root);
  final rootType = await FileSystemEntity.type(canonicalRoot);
  if (rootType != FileSystemEntityType.directory) {
    throw CoreException.notFound('The folder does not exist: $root');
  }
  final books = <DiscoveredBook>[];
  final failures = <({String path, String error})>[];
  final visited = <String>{};
  final seenFiles = <String>{};
  final pending = <String>[canonicalRoot];
  var entries = 0;
  var exhausted = false;
  while (pending.isNotEmpty && !exhausted) {
    cancellation.throwIfCancelled();
    final directory = pending.removeLast();
    if (!visited.add(directory)) continue;
    // Read the listing as a stream so the entry budget and cancellation
    // apply while a huge folder is being listed, not after.
    final children = <FileSystemEntity>[];
    try {
      await for (final child in Directory(directory).list(followLinks: false)) {
        cancellation.throwIfCancelled();
        if (++entries > maxDiscoveryEntries) {
          exhausted = true;
          break;
        }
        children.add(child);
      }
    } on FileSystemException catch (error) {
      failures.add((
        path: directory,
        error:
            'Could not read the folder: ${error.osError?.message ?? error.message}',
      ));
      continue;
    }
    if (exhausted) {
      failures.add((
        path: canonicalRoot,
        error: 'Discovery stopped after $maxDiscoveryEntries entries.',
      ));
    }
    children.sort((a, b) => a.path.compareTo(b.path));
    for (final child in children) {
      cancellation.throwIfCancelled();
      final resolved = canonicalBookPath(child.path);
      if (!p.isWithin(canonicalRoot, resolved)) continue;
      final type = await FileSystemEntity.type(resolved, followLinks: false);
      if (type == FileSystemEntityType.directory) {
        pending.add(resolved);
        continue;
      }
      if (type != FileSystemEntityType.file || !seenFiles.add(resolved)) {
        continue;
      }
      final BookFormat? format;
      try {
        format = await detectBookFormat(resolved);
      } on CoreException catch (error) {
        failures.add((path: resolved, error: error.message));
        continue;
      } on FileSystemException catch (error) {
        failures.add((
          path: resolved,
          error: _inaccessible('inspect', resolved, error).message,
        ));
        continue;
      }
      if (format == null) continue;
      if (books.length == maxDiscoveredBooks) {
        failures.add((
          path: canonicalRoot,
          error: 'The folder holds more than $maxDiscoveredBooks books.',
        ));
        exhausted = true;
        break;
      }
      books.add((path: resolved, format: format));
    }
  }
  books.sort((a, b) => a.path.compareTo(b.path));
  failures.sort((a, b) => a.path.compareTo(b.path));
  return Discovery(books, failures);
}
