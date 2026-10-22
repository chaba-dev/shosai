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
mixin BridgeRecords implements RecordsHost {
  @override
  late final ShosaiRecords records = BridgeForwardingRecords(
    this as FlutterBridge,
  );
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
    String? note,
  }) => bridge.toggleBookmark(
    bookId: bookId,
    unit: unit,
    offset: offset,
    title: title,
    note: note,
  );

  @override
  Future<void> updateBookmarkNote({required int id, String? note}) =>
      bridge.updateBookmarkNote(id: id, note: note);

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
