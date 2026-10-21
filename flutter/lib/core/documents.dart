/// The documents the application bridge opens: EPUB books parsed by the
/// Dart EPUB engine and PDF documents opened by the PDF engine, each behind a
/// handle until it is released.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:shosai_core/shosai_core.dart';
import 'package:shosai_epub/shosai_epub.dart';
import 'package:shosai_flutter/core/bridge.dart';
import 'package:shosai_flutter/reader/epub/content.dart' show parseEpubBytes;
import 'package:shosai_flutter/reader/pdf/engine.dart';

/// The open documents of one bridge, by handle.
final class OpenDocuments {
  OpenDocuments(this._pdfEngine);

  final PdfEngine _pdfEngine;
  final Map<FlutterDocumentHandle, OpenDocument> _open = {};
  var _lastId = BigInt.zero;

  /// Open the book at [path] as [format], or as the format its extension or
  /// content names. A library book passes its [bookId] and [title].
  Future<OpenDocument> open(
    String path, {
    BookFormat? format,
    int? bookId,
    String? title,
    CancellationToken? cancellation,
  }) async {
    final kind =
        format ??
        await detectBookFormat(path) ??
        (throw const CoreException(
          CoreErrorKind.unsupported,
          'The file is neither an EPUB nor a PDF.',
        ));
    cancellation.throwIfCancelled();
    _lastId += BigInt.one;
    final handle = FlutterDocumentHandle(registry: BigInt.one, id: _lastId);
    final OpenDocument document;
    switch (kind) {
      case BookFormat.epub:
        final book = await _parseEpub(await _readBook(path));
        document = OpenDocument._(
          FlutterDocumentSummary(
            handle: handle,
            bookId: bookId,
            format: FlutterBookFormat.epub,
            title: title ?? _nonEmpty(book.title),
            logicalUnitCount: BigInt.from(book.chapters.length),
          ),
          path,
          epub: book,
        );
      case BookFormat.pdf:
        final pdf = await openPdfDocument(_pdfEngine, path);
        try {
          cancellation.throwIfCancelled();
          document = OpenDocument._(
            FlutterDocumentSummary(
              handle: handle,
              bookId: bookId,
              format: FlutterBookFormat.pdf,
              title: title ?? _nonEmpty((await pdf.info()).title),
              logicalUnitCount: BigInt.from(pdf.pageCount),
            ),
            path,
          );
        } finally {
          await pdf.dispose();
        }
    }
    cancellation.throwIfCancelled();
    _open[handle] = document;
    return document;
  }

  /// The open document behind [handle].
  OpenDocument operator [](FlutterDocumentHandle handle) =>
      _open[handle] ??
      (throw const CoreException.invalidRequest(
        'unknown or released document handle',
      ));

  /// Forget [handle]; false when it was not open.
  bool release(FlutterDocumentHandle handle) {
    final document = _open.remove(handle);
    document?._release();
    return document != null;
  }

  /// Release every open document.
  void releaseAll() {
    for (final document in _open.values) {
      document._release();
    }
    _open.clear();
  }

  PdfEngine get pdfEngine => _pdfEngine;
}

/// One open document: its summary, the path it opened from, the parsed book
/// of an EPUB, and a PDF engine document opened on first use.
final class OpenDocument {
  OpenDocument._(this.summary, this.path, {this.epub});

  final FlutterDocumentSummary summary;
  final String path;

  /// The parsed book; null for a PDF.
  final EpubBook? epub;

  Future<PdfEngineDocument>? _pdf;

  /// This PDF's engine document, opened once through [engine].
  Future<PdfEngineDocument> pdf(PdfEngine engine) =>
      _pdf ??= openPdfDocument(engine, path);

  void _release() {
    final pdf = _pdf;
    _pdf = null;
    pdf?.then((document) => document.dispose(), onError: (_) {});
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

Future<Uint8List> _readBook(String path) async {
  final file = File(path);
  try {
    if (await file.length() > maxBookInputBytes) {
      throw const CoreException.limitExceeded(
        'The book is larger than $maxBookInputBytes bytes.',
      );
    }
    return await file.readAsBytes();
  } on PathNotFoundException {
    throw CoreException.notFound('There is no file at $path.');
  } on FileSystemException catch (error) {
    throw CoreException(
      CoreErrorKind.inaccessible,
      'Could not read $path: ${error.osError?.message ?? error.message}',
    );
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
