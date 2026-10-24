/// The open document's text, unit by unit, as annotations and book search
/// read it.
library;

import 'package:shosai_core/shosai_core.dart';
import 'package:shosai_flutter/core/records.dart';

import 'package:shosai_flutter/reader/pdf/engine.dart';

/// A PDF's page text from the PDF engine, one scalar per PDFium character:
/// the text the selection surfaces index.
final class PdfReaderText implements ReaderText {
  const PdfReaderText(this._document);

  final PdfEngineDocument _document;

  @override
  int get unitCount => _document.pageCount;

  @override
  Future<UnitText?> unitText(
    int unit, {
    CancellationToken? cancellation,
  }) async {
    cancellation.throwIfCancelled();
    return UnitText(await _document.pageText(unit));
  }
}

/// An EPUB's chapter text in the canonical stream every selection surface
/// indexes, with each chapter's resource path.
final class EpubReaderText implements ReaderText {
  const EpubReaderText({
    required this.unitCount,
    required Future<String> Function(int unit) text,
    required Future<String?> Function(int unit) resourcePath,
  }) : _text = text,
       _resourcePath = resourcePath;

  @override
  final int unitCount;

  final Future<String> Function(int unit) _text;

  /// Null when the chapter's resource path is unknown.
  final Future<String?> Function(int unit) _resourcePath;

  @override
  Future<UnitText?> unitText(
    int unit, {
    CancellationToken? cancellation,
  }) async {
    cancellation.throwIfCancelled();
    final text = await _text(unit);
    cancellation.throwIfCancelled();
    return UnitText(text, resourcePath: await _resourcePath(unit));
  }
}
