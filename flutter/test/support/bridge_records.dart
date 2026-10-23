import 'dart:async';
import 'dart:typed_data';

import 'package:shosai_flutter/core/records.dart';
import 'package:shosai_flutter/core/bridge.dart';

/// Records for a fake bridge: every call answers through the bridge's own
/// record fakes, so a fixture bridge keeps one seam and its counters,
/// completers and canned results stay meaningful.
///
/// Mixed into a bridge fake: `class Fake with BridgePdfEngine, BridgeRecords
/// implements FlutterBridge`. The controllers use the records of a bridge
/// that is a [RecordsHost].
///
/// The mixin also keeps the bridge's page notes and book notes, so a fake
/// answers note calls without writing them itself.
mixin BridgeRecords implements RecordsHost {
  @override
  late final ShosaiRecords records = BridgeForwardingRecords(
    this as FlutterBridge,
  );

  /// The page notes and book notes [createNote] wrote, in creation order.
  final List<FlutterNote> placeNotes = [];
  int _nextNote = 0;

  /// When set, note writes wait for it, so a test can hold one in flight.
  Completer<void>? noteWriteGate;

  /// The note writes started, held or not.
  int noteWrites = 0;

  /// The library's books with notes, most recently read first, as
  /// [libraryNotes] lists them.
  List<FlutterBookNotes> libraryBookNotes = [];

  /// The library notes pages asked for.
  int libraryNotesCalls = 0;

  /// When set, listing the library's notes fails with it.
  FlutterBridgeError? libraryNotesFailure;

  Future<FlutterLibraryNotesPage> libraryNotes({
    required int limit,
    required int offset,
    List<int>? after,
    required BigInt cancellationId,
  }) async {
    libraryNotesCalls += 1;
    if (libraryNotesFailure case final failure?) throw failure;
    // The core's page limit.
    if (limit > 100) {
      throw const FlutterBridgeError(
        kind: FlutterBridgeErrorKind.invalidRequest,
        message: 'A library notes page lists 1 to 100 books.',
      );
    }
    if (after != null) {
      final before = [
        for (final book in libraryBookNotes.take(after.length))
          book.book.bookId,
      ];
      if (before.join(',') != after.join(',')) {
        return const FlutterLibraryNotesPage(
          books: [],
          hasMore: false,
          changed: true,
        );
      }
      offset = after.length;
    }
    final end = (offset + limit).clamp(0, libraryBookNotes.length);
    return FlutterLibraryNotesPage(
      books: libraryBookNotes.sublist(offset.clamp(0, end), end),
      hasMore: end < libraryBookNotes.length,
    );
  }

  /// What library searches answer, whatever the query: [libraryNoteHits]
  /// for notes and [libraryTextHits] for book text, each filtered to the
  /// searched book.
  List<FlutterBookNoteHits> libraryNoteHits = [];
  List<FlutterBookTextHits> libraryTextHits = [];

  /// The library searches asked for: the query and book of each.
  final List<(String, int?)> libraryNoteSearches = [];
  final List<(String, int?)> libraryTextSearches = [];

  /// When set, library text searches wait for it before their first book.
  Completer<void>? libraryTextGate;

  Future<List<FlutterBookNoteHits>> searchLibraryNotes({
    required String query,
    int? bookId,
    required BigInt cancellationId,
  }) async {
    libraryNoteSearches.add((query, bookId));
    return [
      for (final book in libraryNoteHits)
        if (bookId == null || book.book.bookId == bookId) book,
    ];
  }

  Future<void> searchLibraryText({
    required String query,
    int? bookId,
    required void Function(FlutterBookTextHits hits) onBook,
    required BigInt cancellationId,
  }) async {
    libraryTextSearches.add((query, bookId));
    await libraryTextGate?.future;
    for (final book in libraryTextHits) {
      if (bookId == null || book.book.bookId == bookId) onBook(book);
    }
  }

  /// Gates for the next note listings, one each in order: a listing waits
  /// for its gate, so a test can finish listings out of order.
  final List<Completer<void>> noteListGates = [];

  Future<List<FlutterNote>> listNotes({
    required FlutterDocumentHandle document,
    required BigInt cancellationId,
  }) async {
    if (noteListGates.isNotEmpty) await noteListGates.removeAt(0).future;
    return List.of(placeNotes);
  }

  Future<FlutterNote> createNote({
    required FlutterDocumentHandle document,
    BigInt? unit,
    BigInt? offset,
    required String body,
    required BigInt cancellationId,
  }) async {
    noteWrites += 1;
    await noteWriteGate?.future;
    final note = FlutterNote(
      id: 'note-${++_nextNote}',
      kind: unit == null ? FlutterNoteKind.book : FlutterNoteKind.page,
      unit: unit,
      offset: offset,
      resolution: FlutterAnnotationResolution.exact,
      body: body,
      modifiedAt: '2026-01-01T00:00:00.000Z',
    );
    placeNotes.add(note);
    return note;
  }

  Future<bool> updateNote({
    required FlutterDocumentHandle document,
    required String id,
    required String body,
  }) async {
    noteWrites += 1;
    await noteWriteGate?.future;
    final index = placeNotes.indexWhere((note) => note.id == id);
    if (index < 0) return false;
    final note = placeNotes[index];
    placeNotes[index] = FlutterNote(
      id: note.id,
      kind: note.kind,
      unit: note.unit,
      offset: note.offset,
      resolution: note.resolution,
      body: body,
      modifiedAt: note.modifiedAt,
    );
    return true;
  }
}

/// [ShosaiRecords] answered by [bridge]'s record methods; annotation and
/// search calls pass the document's handle and ignore the text.
final class BridgeForwardingRecords implements ShosaiRecords {
  BridgeForwardingRecords(this.bridge);

  final FlutterBridge bridge;

  @override
  Future<FlutterLibraryPage> libraryPage({
    String? query,
    FlutterBookFormat? format,
    FlutterLibrarySort sort = FlutterLibrarySort.recent,
    required int limit,
    required int offset,
    required BigInt cancellationId,
  }) => bridge.libraryPage(
    query: query,
    format: format,
    sort: sort,
    limit: limit,
    offset: offset,
    cancellationId: cancellationId,
  );

  @override
  Future<Uint8List?> libraryCover({
    required int bookId,
    required BigInt cancellationId,
  }) => bridge.libraryCover(bookId: bookId, cancellationId: cancellationId);

  @override
  Future<List<FlutterBookNoteHits>> searchLibraryNotes({
    required String query,
    int? bookId,
    required BigInt cancellationId,
  }) => bridge.searchLibraryNotes(
    query: query,
    bookId: bookId,
    cancellationId: cancellationId,
  );

  @override
  Future<void> searchLibraryText({
    required String query,
    int? bookId,
    required void Function(FlutterBookTextHits hits) onBook,
    required BigInt cancellationId,
  }) => bridge.searchLibraryText(
    query: query,
    bookId: bookId,
    onBook: onBook,
    cancellationId: cancellationId,
  );

  @override
  Future<FlutterLibraryNotesPage> libraryNotes({
    required int limit,
    required int offset,
    List<int>? after,
    required BigInt cancellationId,
  }) => bridge.libraryNotes(
    limit: limit,
    offset: offset,
    after: after,
    cancellationId: cancellationId,
  );

  @override
  Future<FlutterImportReport> importPaths({
    required List<String> pathKeys,
    required bool managed,
    required BigInt cancellationId,
  }) => bridge.importPaths(
    pathKeys: pathKeys,
    managed: managed,
    cancellationId: cancellationId,
  );

  @override
  Future<FlutterImportReport> importDirectory({
    required String pathKey,
    required bool managed,
    required BigInt cancellationId,
  }) => bridge.importDirectory(
    pathKey: pathKey,
    managed: managed,
    cancellationId: cancellationId,
  );

  @override
  Future<FlutterLibraryRemoveOutcome> removeLibraryBook({
    required int bookId,
  }) => bridge.removeLibraryBook(bookId: bookId);

  @override
  Future<FlutterReaderSettings> loadReaderSettings({
    required BigInt cancellationId,
  }) => bridge.loadReaderSettings(cancellationId: cancellationId);

  @override
  Future<void> saveReaderSettings({required FlutterReaderSettings value}) =>
      bridge.saveReaderSettings(value: value);

  @override
  Future<FlutterDocumentSummary> openLibraryBook({
    required int bookId,
    required BigInt cancellationId,
  }) => bridge.openLibraryBook(bookId: bookId, cancellationId: cancellationId);

  @override
  Future<FlutterReadingState?> loadReadingState({
    required int bookId,
    required BigInt cancellationId,
  }) => bridge.loadReadingState(bookId: bookId, cancellationId: cancellationId);

  @override
  Future<void> saveReadingState({
    required int bookId,
    required FlutterReadingState value,
    required BigInt unitCount,
  }) => bridge.saveReadingState(
    bookId: bookId,
    value: value,
    unitCount: unitCount,
  );

  @override
  Future<List<FlutterBookmark>> listBookmarks({
    required int bookId,
    required BigInt cancellationId,
  }) => bridge.listBookmarks(bookId: bookId, cancellationId: cancellationId);

  @override
  Future<FlutterBookmark?> toggleBookmark({
    required int bookId,
    required BigInt unit,
    BigInt? offset,
    String? title,
  }) => bridge.toggleBookmark(
    bookId: bookId,
    unit: unit,
    offset: offset,
    title: title,
  );

  @override
  Future<void> deleteBookmark({required int id}) =>
      bridge.deleteBookmark(id: id);

  @override
  Future<String> exportBookmarks({required int bookId}) =>
      bridge.exportBookmarks(bookId: bookId);

  @override
  Future<List<FlutterAnnotation>> listAnnotations({
    required FlutterDocumentSummary document,
    required ReaderText text,
    required double scale,
    required BigInt cancellationId,
  }) => bridge.listAnnotations(
    document: document.handle,
    scale: scale,
    cancellationId: cancellationId,
  );

  @override
  Future<List<FlutterNote>> listNotes({
    required FlutterDocumentSummary document,
    required ReaderText text,
    required BigInt cancellationId,
  }) => bridge.listNotes(
    document: document.handle,
    cancellationId: cancellationId,
  );

  @override
  Future<FlutterNote> createNote({
    required FlutterDocumentSummary document,
    required ReaderText text,
    BigInt? unit,
    BigInt? offset,
    required String body,
    required BigInt cancellationId,
  }) => bridge.createNote(
    document: document.handle,
    unit: unit,
    offset: offset,
    body: body,
    cancellationId: cancellationId,
  );

  @override
  Future<bool> updateNote({
    required FlutterDocumentSummary document,
    required String id,
    required String body,
  }) => bridge.updateNote(document: document.handle, id: id, body: body);

  @override
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
  }) => bridge.createAnnotation(
    document: document.handle,
    unit: unit,
    start: start,
    end: end,
    displayScale: displayScale,
    color: color,
    body: body,
    cancellationId: cancellationId,
  );

  @override
  Future<bool> updateAnnotation({
    required FlutterDocumentSummary document,
    required String id,
    required FlutterHighlightColor color,
    String? body,
  }) => bridge.updateAnnotation(
    document: document.handle,
    id: id,
    color: color,
    body: body,
  );

  @override
  Future<bool> deleteAnnotation({
    required FlutterDocumentSummary document,
    required String id,
  }) => bridge.deleteAnnotation(document: document.handle, id: id);

  @override
  Future<FlutterAnnotationAssociationSourcePage>
  listAnnotationAssociationSources({
    required FlutterDocumentSummary target,
    String? cursor,
    required BigInt limit,
    required BigInt cancellationId,
  }) => bridge.listAnnotationAssociationSources(
    target: target.handle,
    cursor: cursor,
    limit: limit,
    cancellationId: cancellationId,
  );

  @override
  Future<FlutterAnnotationAssociationOutcome> associateAnnotationVersion({
    required String sourceVersionId,
    required FlutterDocumentSummary target,
    required BigInt cancellationId,
  }) => bridge.associateAnnotationVersion(
    sourceVersionId: sourceVersionId,
    target: target.handle,
    cancellationId: cancellationId,
  );

  @override
  Future<List<FlutterSearchMatch>> searchDocument({
    required FlutterDocumentSummary document,
    required ReaderText text,
    required String query,
    required BigInt cancellationId,
  }) => bridge.searchDocument(
    document: document.handle,
    query: query,
    cancellationId: cancellationId,
  );
}
