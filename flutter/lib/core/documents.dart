/// The documents the application bridge opens: EPUB books parsed by the
/// Dart EPUB engine and PDF documents opened by the PDF engine, each behind a
/// handle until it is released.
///
/// Every document is read from one immutable snapshot of its file, verified
/// by content hash before anything is parsed: an EPUB's bytes, read once, or
/// a PDF's private copy, which the PDF engine reads for metadata, rendering
/// and text for as long as the document is open. A file replaced while it is
/// opened or read can therefore not put other content behind a library
/// book's identity or annotations.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:shosai_core/shosai_core.dart';
import 'package:shosai_epub/shosai_epub.dart';
import 'package:shosai_flutter/core/bridge.dart';
import 'package:shosai_flutter/reader/epub/content.dart' show parseEpubBytes;
import 'package:shosai_flutter/reader/pdf/engine.dart';

/// The library identity a document must match: the book it opens as and
/// the content hash its bytes must have.
typedef ExpectedBook = ({int bookId, String title, String contentHash});

/// A process's private directory of PDF snapshots under [parent] (the
/// application's data directory), created on first use, restricted to its
/// owner, and deleted when closed.
///
/// It lives beside the database rather than in the shared temporary
/// directory: the data directory is already the application's own (a
/// sandbox on mobile hosts, the person's profile on desktop ones), and each
/// process takes a fresh directory in it, which POSIX hosts set to `0700`.
final class DocumentSnapshots {
  DocumentSnapshots(String parent) : _parent = parent;

  final String _parent;
  Future<Directory>? _directory;
  var _closed = false;

  /// The directory, once a snapshot has been taken.
  Future<Directory>? get directory => _directory;

  /// A fresh path for one snapshot; the caller creates the file.
  Future<String> newPath() async {
    if (_closed) {
      throw const CoreException.invalidRequest(
        'The document snapshots are closed.',
      );
    }
    final pending = _directory ??= _create();
    try {
      return uniqueTemporaryPath((await pending).path, 'snapshot');
    } catch (_) {
      if (identical(_directory, pending)) _directory = null;
      rethrow;
    }
  }

  /// Delete the directory and every snapshot left in it.
  Future<void> close() async {
    _closed = true;
    final pending = _directory;
    if (pending == null) return;
    try {
      await (await pending).delete(recursive: true);
    } on Object {
      // Never created, or already gone; a leftover is swept on a later start.
    }
  }

  /// Delete snapshot directories an earlier process left behind (it did not
  /// close, or could not delete them). Only those untouched for [age] go,
  /// so another running process's directory stays.
  Future<void> sweep({Duration age = const Duration(days: 1)}) async {
    final parent = Directory(_parent);
    if (!await parent.exists()) return;
    final cutoff = DateTime.now().subtract(age);
    await for (final entry in parent.list(followLinks: false)) {
      if (entry is! Directory) continue;
      try {
        if ((await entry.stat()).modified.isBefore(cutoff)) {
          await entry.delete(recursive: true);
        }
      } on FileSystemException {
        // Retried on the next start.
      }
    }
  }

  Future<Directory> _create() async {
    try {
      await Directory(_parent).create(recursive: true);
      final directory = await Directory(_parent).createTemp('process-');
      if (Platform.isLinux || Platform.isMacOS) {
        final chmod = await Process.run('chmod', ['700', directory.path]);
        if (chmod.exitCode != 0 ||
            ((await directory.stat()).mode & _groupOrOther) != 0) {
          await directory.delete(recursive: true);
          throw const CoreException(
            CoreErrorKind.inaccessible,
            'The document snapshot directory could not be made private.',
          );
        }
      }
      return directory;
    } on FileSystemException catch (error) {
      throw CoreException(
        CoreErrorKind.inaccessible,
        'Could not create the document snapshot directory: '
        '${error.osError?.message ?? error.message}',
      );
    } on ProcessException catch (error) {
      throw CoreException(
        CoreErrorKind.inaccessible,
        'Could not restrict the document snapshot directory: $error',
      );
    }
  }

  static const _groupOrOther = 0x3f;
}

/// The open documents of one bridge, by handle.
final class OpenDocuments {
  OpenDocuments(this._pdfEngine, this._snapshots);

  final PdfEngine _pdfEngine;
  final DocumentSnapshots _snapshots;
  final Map<FlutterDocumentHandle, OpenDocument> _open = {};
  final Set<Future<void>> _pending = {};
  var _lastId = BigInt.zero;
  var _closed = false;

  /// Whether [close] has run: no document is admitted after it.
  bool get isClosed => _closed;

  /// How many documents are open.
  int get length => _open.length;

  /// Open the book at [path] as [format], or as the format its extension or
  /// content names. A library book passes the identity it must match as
  /// [expected]; the content read must have its content hash.
  Future<OpenDocument> open(
    String path, {
    BookFormat? format,
    ExpectedBook? expected,
    CancellationToken? cancellation,
  }) {
    if (_closed) {
      return Future.error(
        const CoreException.invalidRequest('The bridge is disposed.'),
      );
    }
    final opening = _admit(path, format, expected, cancellation);
    _track(opening);
    return opening;
  }

  Future<OpenDocument> _admit(
    String path,
    BookFormat? format,
    ExpectedBook? expected,
    CancellationToken? cancellation,
  ) async {
    final kind =
        format ??
        await detectBookFormat(path) ??
        (throw const CoreException(
          CoreErrorKind.unsupported,
          'The file is neither an EPUB nor a PDF.',
        ));
    _checkAdmission(cancellation);
    final OpenDocument document = switch (kind) {
      BookFormat.epub => await _openEpub(path, expected, cancellation),
      BookFormat.pdf => await _openPdf(path, expected, cancellation),
    };
    try {
      _checkAdmission(cancellation);
    } catch (_) {
      _track(document._release());
      rethrow;
    }
    _open[document.summary.handle] = document;
    return document;
  }

  void _checkAdmission(CancellationToken? cancellation) {
    if (_closed) {
      throw const CoreException(
        CoreErrorKind.cancelled,
        'The bridge was disposed while the document opened.',
      );
    }
    cancellation.throwIfCancelled();
  }

  FlutterDocumentHandle _nextHandle() {
    _lastId += BigInt.one;
    return FlutterDocumentHandle(registry: BigInt.one, id: _lastId);
  }

  Future<OpenDocument> _openEpub(
    String path,
    ExpectedBook? expected,
    CancellationToken? cancellation,
  ) async {
    final bytes = await readBookBytes(path, cancellation: cancellation);
    final hash = await hashBookBytes(bytes, cancellation: cancellation);
    _verify(hash, expected, path);
    _checkAdmission(cancellation);
    final book = await _parseEpub(bytes);
    return OpenDocument._(
      FlutterDocumentSummary(
        handle: _nextHandle(),
        bookId: expected?.bookId,
        format: FlutterBookFormat.epub,
        title: expected?.title ?? _nonEmpty(book.title),
        logicalUnitCount: BigInt.from(book.chapters.length),
      ),
      path,
      contentHash: hash,
      epub: book,
    );
  }

  Future<OpenDocument> _openPdf(
    String path,
    ExpectedBook? expected,
    CancellationToken? cancellation,
  ) async {
    final snapshot = await _snapshots.newPath();
    final FileFingerprint fingerprint;
    try {
      fingerprint = await copyAndFingerprint(
        path,
        snapshot,
        cancellation: cancellation,
      );
    } on CoreException catch (error) {
      if (error.kind == CoreErrorKind.notFound) {
        throw CoreException.notFound('There is no file at $path.');
      }
      rethrow;
    }
    try {
      _verify(fingerprint.hash, expected, path);
      _checkAdmission(cancellation);
      final pdf = await openPdfDocument(_pdfEngine, snapshot);
      try {
        _checkAdmission(cancellation);
        final title = expected?.title ?? _nonEmpty((await pdf.info()).title);
        return OpenDocument._(
          FlutterDocumentSummary(
            handle: _nextHandle(),
            bookId: expected?.bookId,
            format: FlutterBookFormat.pdf,
            title: title,
            logicalUnitCount: BigInt.from(pdf.pageCount),
            contentPath: snapshot,
          ),
          path,
          contentHash: fingerprint.hash,
          snapshot: snapshot,
          pdfEngine: _pdfEngine,
        );
      } finally {
        await _disposeQuietly(pdf);
      }
    } catch (_) {
      await _deleteQuietly(snapshot);
      rethrow;
    }
  }

  /// The open document behind [handle].
  OpenDocument operator [](FlutterDocumentHandle handle) =>
      _open[handle] ??
      (throw const CoreException.invalidRequest(
        'unknown or released document handle',
      ));

  /// Forget [handle] and release its resources; false when it was not open.
  bool release(FlutterDocumentHandle handle) {
    final document = _open.remove(handle);
    if (document == null) return false;
    _track(document._release());
    return true;
  }

  /// Admit no more documents and release every open one. [drain] completes
  /// once the releases and the opens that were running have finished.
  void close() {
    _closed = true;
    for (final document in _open.values) {
      _track(document._release());
    }
    _open.clear();
  }

  /// Completes when no open or release this registry started is running.
  /// Their failures were reported to their callers or are ignored here.
  Future<void> drain() async {
    while (_pending.isNotEmpty) {
      await Future.wait([
        for (final pending in List.of(_pending))
          pending.then<void>((_) {}, onError: (_) {}),
      ]);
    }
  }

  void _track(Future<Object?> work) {
    late final Future<void> tracked;
    tracked = work.then<void>((_) {}, onError: (_) {}).whenComplete(() {
      _pending.remove(tracked);
    });
    _pending.add(tracked);
  }

  PdfEngine get pdfEngine => _pdfEngine;
}

/// One open document: its summary, the path it was opened from, its content
/// hash, the parsed book of an EPUB, and for a PDF the private snapshot the
/// engine reads and an engine document opened on it on first use.
final class OpenDocument {
  OpenDocument._(
    this.summary,
    this.path, {
    required this.contentHash,
    this.epub,
    String? snapshot,
    PdfEngine? pdfEngine,
  }) : _snapshot = snapshot,
       _pdfEngine = pdfEngine;

  final FlutterDocumentSummary summary;

  /// The path the document was opened from. Its content is never read
  /// again; read [snapshotPath] instead.
  final String path;

  /// Lowercase hexadecimal SHA-256 of the content this document reads.
  final String contentHash;

  /// The parsed book; null for a PDF.
  final EpubBook? epub;

  final String? _snapshot;
  final PdfEngine? _pdfEngine;
  Future<PdfEngineDocument>? _pdf;
  var _released = false;

  /// Operations reading the engine document, which its release waits for.
  var _users = 0;
  Completer<void>? _idle;

  /// The private copy a PDF is read from until it is released; null for an
  /// EPUB, whose bytes were parsed when it opened.
  String? get snapshotPath => _snapshot;

  /// Run [use] on this PDF's engine document. The document is not disposed
  /// while [use] runs, even when it is released meanwhile.
  Future<T> withPdf<T>(
    Future<T> Function(PdfEngineDocument document) use,
  ) async {
    final document = _pdfDocument();
    _users += 1;
    try {
      return await use(await document);
    } finally {
      _users -= 1;
      if (_users == 0) {
        _idle?.complete();
        _idle = null;
      }
    }
  }

  /// This PDF's engine document over its snapshot, opened once.
  Future<PdfEngineDocument> _pdfDocument() {
    final snapshot = _snapshot;
    if (_released || snapshot == null) {
      return Future.error(
        CoreException.invalidRequest(
          _released
              ? 'The document is released.'
              : 'The document is not a PDF.',
        ),
      );
    }
    return _pdf ??= openPdfDocument(_pdfEngine!, snapshot);
  }

  /// Once the operations using it have finished, dispose the engine
  /// document, then delete the snapshot. Completes when both are done; a
  /// failing disposal still deletes the snapshot.
  Future<void> _release() async {
    _released = true;
    if (_users > 0) await (_idle ??= Completer<void>()).future;
    final pdf = _pdf;
    _pdf = null;
    try {
      if (pdf != null) {
        try {
          await _disposeQuietly(await pdf);
        } on Object {
          // The engine document never opened: nothing to dispose.
        }
      }
    } finally {
      if (_snapshot case final snapshot?) await _deleteQuietly(snapshot);
    }
  }
}

/// Open the PDF at [path], reporting an engine failure as a core failure.
Future<PdfEngineDocument> openPdfDocument(PdfEngine engine, String path) async {
  try {
    return await engine.open(path);
  } on PdfEnginePasswordException {
    throw const CoreException(
      CoreErrorKind.unsupported,
      'Password-protected PDFs are not supported.',
    );
  } on PdfEngineLimitException catch (error) {
    throw CoreException.limitExceeded(error.message);
  } on PdfEngineException catch (error) {
    throw CoreException.malformed(error.message);
  }
}

void _verify(String hash, ExpectedBook? expected, String path) {
  if (expected != null && hash != expected.contentHash) {
    throw CoreException.conflict(
      'The file contents no longer match the library book: $path',
    );
  }
}

Future<void> _disposeQuietly(PdfEngineDocument document) async {
  try {
    await document.dispose();
  } on Object {
    // The engine document is unusable either way.
  }
}

Future<void> _deleteQuietly(String path) async {
  try {
    await File(path).delete();
  } on FileSystemException {
    // Already gone, or removed with the snapshot directory.
  }
}

Future<EpubBook> _parseEpub(Uint8List bytes) async {
  try {
    return await parseEpubBytes(bytes);
  } on EpubLimitError catch (error) {
    throw CoreException.limitExceeded('The EPUB exceeds a limit: $error');
  } on EpubFormatError catch (error) {
    throw CoreException.malformed('The EPUB cannot be read: ${error.message}');
  } on Exception catch (error) {
    throw CoreException.malformed('The EPUB cannot be read: $error');
  }
}

String? _nonEmpty(String? value) =>
    value == null || value.trim().isEmpty ? null : value;
