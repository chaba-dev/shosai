/// The records the library and reader keep: books, reading state, settings,
/// bookmarks, annotations and book search.
///
/// The controllers reach records through [ShosaiRecords] and documents
/// through the bridge. In the application both are one object, the
/// application bridge over the Dart core (`core_records.dart`); the
/// controllers find the records on any bridge that is a [RecordsHost]. The
/// methods keep the bridge's request and result types until the Rust bridge
/// is removed (RFD 4, M3.0).
library;

import 'dart:typed_data';

import 'package:shosai_core/shosai_core.dart' show UnitTextSource;
import 'package:shosai_flutter/core/bridge.dart';

/// A bridge that also serves the records.
abstract interface class RecordsHost {
  ShosaiRecords get records;
}

/// The records of [bridge], which must be a [RecordsHost].
ShosaiRecords recordsOf(FlutterBridge bridge) => switch (bridge) {
  RecordsHost(:final records) => records,
  _ => throw ArgumentError.value(
    bridge,
    'bridge',
    'serves no records; build it as a RecordsHost',
  ),
};

/// The open book's text, as annotations and book search read it: PDF page
/// text from the PDF engine, EPUB chapter text in the canonical stream the
/// selection surfaces index.
typedef ReaderText = UnitTextSource;

abstract interface class ShosaiRecords {
  // Library.

  Future<FlutterLibraryPage> libraryPage({
    String? query,
    FlutterBookFormat? format,
    required int limit,
    required int offset,
    required BigInt cancellationId,
  });

  Future<Uint8List?> libraryCover({
    required int bookId,
    required BigInt cancellationId,
  });

  Future<FlutterImportReport> importPaths({
    required List<String> pathKeys,
    required bool managed,
    required BigInt cancellationId,
  });

  Future<FlutterImportReport> importDirectory({
    required String pathKey,
    required bool managed,
    required BigInt cancellationId,
  });

  Future<FlutterLibraryRemoveOutcome> removeLibraryBook({required int bookId});

  Future<FlutterReaderSettings> loadReaderSettings({
    required BigInt cancellationId,
  });

  Future<void> saveReaderSettings({required FlutterReaderSettings value});

  // Reading.

  /// Open library book [bookId] after checking that its file still holds
  /// the book.
  Future<FlutterDocumentSummary> openLibraryBook({
    required int bookId,
    required BigInt cancellationId,
  });

  Future<FlutterReadingState?> loadReadingState({
    required int bookId,
    required BigInt cancellationId,
  });

  Future<void> saveReadingState({
    required int bookId,
    required FlutterReadingState value,
    required BigInt unitCount,
  });

  Future<List<FlutterBookmark>> listBookmarks({
    required int bookId,
    required BigInt cancellationId,
  });

  Future<FlutterBookmark?> toggleBookmark({
    required int bookId,
    required BigInt unit,
    BigInt? offset,
    String? title,
    String? note,
  });

  Future<void> updateBookmarkNote({required int id, String? note});

  Future<void> deleteBookmark({required int id});

  Future<String> exportBookmarks({required int bookId});

  // Annotations, resolved against the open document's text.

  /// [document]'s annotations, resolved against [text]; PDF rectangles are
  /// scaled by [scale].
  Future<List<FlutterAnnotation>> listAnnotations({
    required FlutterDocumentSummary document,
    required ReaderText text,
    required double scale,
    required BigInt cancellationId,
  });

  /// Highlight [start]..[end] of [surface], the selection surface of [unit]
  /// at [displayScale].
  Future<FlutterAnnotation> createAnnotation({
    required FlutterDocumentSummary document,
    required FlutterSelectionSurface surface,
    required BigInt unit,
    required BigInt start,
    required BigInt end,
    required double displayScale,
    required FlutterHighlightColor color,
    String? body,
    required BigInt cancellationId,
  });

  Future<bool> updateAnnotation({
    required FlutterDocumentSummary document,
    required String id,
    required FlutterHighlightColor color,
    String? body,
  });

  Future<bool> deleteAnnotation({
    required FlutterDocumentSummary document,
    required String id,
  });

  Future<FlutterAnnotationAssociationSourcePage>
  listAnnotationAssociationSources({
    required FlutterDocumentSummary target,
    String? cursor,
    required BigInt limit,
    required BigInt cancellationId,
  });

  Future<FlutterAnnotationAssociationOutcome> associateAnnotationVersion({
    required String sourceVersionId,
    required FlutterDocumentSummary target,
    required BigInt cancellationId,
  });

  /// Every case-insensitive occurrence of [query] in [text].
  Future<List<FlutterSearchMatch>> searchDocument({
    required FlutterDocumentSummary document,
    required ReaderText text,
    required String query,
    required BigInt cancellationId,
  });
}
