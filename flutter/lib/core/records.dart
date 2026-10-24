/// The records the library and reader keep: books, reading state, settings,
/// bookmarks, annotations and book search.
///
/// The controllers reach records through [ShosaiRecords] and documents
/// through the bridge. In the application both are one object, the
/// application bridge over the Dart core (`core_records.dart`); the
/// controllers find the records on any bridge that is a [RecordsHost]. The
/// methods keep the bridge's request and result types until the Rust bridge
/// is removed (RFD 12, M3.0).
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

/// One open book: the library book and the reader's last locator in it
/// (its document [path], and its library book id, null for a document opened
/// by path).
typedef FlutterOpenBook = ({FlutterLibraryBook book, String path, int? bookId});

/// The open books in their order, the one being read, and whether the reader
/// was showing it (RFD 4, outcome 4).
typedef FlutterOpenBooks = ({
  List<FlutterOpenBook> books,
  int? current,
  bool reading,
});

/// The open book's text, as annotations and book search read it: PDF page
/// text from the PDF engine, EPUB chapter text in the canonical stream the
/// selection surfaces index.
typedef ReaderText = UnitTextSource;

abstract interface class ShosaiRecords {
  // Library.

  Future<FlutterLibraryPage> libraryPage({
    String? query,
    FlutterBookFormat? format,
    FlutterLibrarySort sort = FlutterLibrarySort.recent,
    required int limit,
    required int offset,
    required BigInt cancellationId,
  });

  Future<Uint8List?> libraryCover({
    required int bookId,
    required BigInt cancellationId,
  });

  /// A page of the library's books that have notes, most recently read
  /// first, each with its notes in reading order.
  /// A page of the library's books with notes; [after] continues a listing
  /// and makes the page `changed` when those books are no longer the first.
  Future<FlutterLibraryNotesPage> libraryNotes({
    required int limit,
    required int offset,
    List<int>? after,
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

  /// The open books last saved, each with the library's current record, or
  /// null when none were. Books the library no longer holds are left out,
  /// and [FlutterOpenBooks.reading] is false when the current book's file is
  /// gone.
  Future<FlutterOpenBooks?> loadOpenBooks();

  Future<void> saveOpenBooks(FlutterOpenBooks value);

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
  });

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

  /// Delete highlight or note [id].
  Future<bool> deleteAnnotation({
    required FlutterDocumentSummary document,
    required String id,
  });

  /// [document]'s page notes and book notes, resolved against [text].
  Future<List<FlutterNote>> listNotes({
    required FlutterDocumentSummary document,
    required ReaderText text,
    required BigInt cancellationId,
  });

  /// Write [body] as a page note at [unit] and [offset] of [text], or as a
  /// book note when [unit] is null.
  Future<FlutterNote> createNote({
    required FlutterDocumentSummary document,
    required ReaderText text,
    BigInt? unit,
    BigInt? offset,
    required String body,
    required BigInt cancellationId,
  });

  /// Rewrite note [id]; false when [document] has no such live note.
  Future<bool> updateNote({
    required FlutterDocumentSummary document,
    required String id,
    required String body,
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

  /// The notes of every library book, or of book [bookId], whose quote or
  /// body holds [query]; books most recently read first.
  Future<List<FlutterBookNoteHits>> searchLibraryNotes({
    required String query,
    int? bookId,
    required BigInt cancellationId,
  });

  /// The text matches of [query] in every library book, or in book
  /// [bookId], reported to [onBook] one book at a time, most recently read
  /// first; books without matches are left out. Completes when every book
  /// has been searched.
  Future<void> searchLibraryText({
    required String query,
    int? bookId,
    required void Function(FlutterBookTextHits hits) onBook,
    required BigInt cancellationId,
  });
}
