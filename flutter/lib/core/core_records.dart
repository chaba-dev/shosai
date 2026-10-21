/// The records over the Dart application core (`shosai_core`), and the
/// application bridge that serves them beside the documents it opens.
library;

import 'dart:typed_data';

import 'package:shosai_core/shosai_core.dart';
import 'package:shosai_epub/shosai_epub.dart' show EpubBook;
import 'package:shosai_flutter/core/bridge.dart';
import 'package:shosai_flutter/core/documents.dart';
import 'package:shosai_flutter/core/reader_text.dart';
import 'package:shosai_flutter/core/records.dart';
import 'package:shosai_flutter/reader/pdf/engine.dart';

/// The application's records: one store, opened once per process and shared
/// by every bridge the shell creates.
final class ShosaiCore {
  ShosaiCore._(this.store, this.library, this.pdfEngine)
    : readingState = ReadingState(store),
      bookmarks = Bookmarks(store),
      settings = ReaderSettingsStore(store),
      annotations = Annotations(store);

  /// Open the store `library.sqlite3` and the managed directory `books`
  /// under [dataDirectory], reading PDF metadata through [pdfEngine], and
  /// retry deleting private copies an earlier run could not delete.
  static Future<ShosaiCore> open(
    String dataDirectory, {
    required PdfEngine pdfEngine,
  }) async {
    final store = await Store.open('$dataDirectory/library.sqlite3');
    final library = Library(
      store,
      managedDirectory: '$dataDirectory/books',
      inspectors: {
        BookFormat.epub: const EpubInspector(),
        BookFormat.pdf: PdfEngineInspector(pdfEngine),
      },
    );
    final core = ShosaiCore._(store, library, pdfEngine);
    try {
      await library.retryManagedFileDeletions();
    } on CoreException {
      // Deletion stays recorded and is retried on the next start.
    }
    return core;
  }

  final Store store;
  final Library library;

  /// Reads PDF metadata on import, and PDF text for the bridge's
  /// handle-keyed annotation calls.
  final PdfEngine pdfEngine;
  final ReadingState readingState;
  final Bookmarks bookmarks;
  final ReaderSettingsStore settings;
  final Annotations annotations;

  Future<void> close() => store.close();
}

/// PDF title, author and first-page cover through the reader's PDF engine.
final class PdfEngineInspector implements BookInspector {
  const PdfEngineInspector(this._engine);

  final PdfEngine _engine;

  /// Every engine failure, including one from initialising PDFium, from
  /// reading metadata or from disposing, becomes a [CoreException], so a bad
  /// PDF fails only its own import item. A cover that fails to render is
  /// dropped.
  @override
  Future<BookMetadata> inspect(
    String path, {
    CancellationToken? cancellation,
  }) async {
    try {
      final document = await openPdfDocument(_engine, path);
      try {
        cancellation.throwIfCancelled();
        final info = await document.info();
        cancellation.throwIfCancelled();
        return BookMetadata(
          title: info.title,
          author: info.author,
          cover: await _cover(document),
        );
      } finally {
        try {
          await document.dispose();
        } on Exception {
          // The document is unusable either way; inspection's result stands.
        }
      }
    } on CoreException {
      rethrow;
    } on PdfEnginePasswordException {
      throw const CoreException(
        CoreErrorKind.unsupported,
        'Password-protected PDFs are not supported.',
      );
    } on PdfEngineLimitException catch (error) {
      throw CoreException.limitExceeded(error.message);
    } on PdfEngineException catch (error) {
      throw CoreException.malformed(error.message);
    } on Exception catch (error) {
      throw CoreException(
        CoreErrorKind.inaccessible,
        'The PDF engine could not read the file: $error',
      );
    }
  }

  Future<Uint8List?> _cover(PdfEngineDocument document) async {
    try {
      final size = document.pageSize(0);
      if (size.width <= 0 || size.height <= 0) return null;
      final scale = [
        coverMaxWidth / size.width,
        coverMaxHeight / size.height,
      ].reduce((a, b) => a < b ? a : b);
      final page = await document.render(0, scale);
      return coverThumbnailFromRgba(page.width, page.height, page.pixels);
    } on Exception {
      return null;
    }
  }
}

/// [ShosaiRecords] over a [ShosaiCore]. Library books open into
/// [_documents].
final class CoreRecords implements ShosaiRecords {
  CoreRecords(this._core, this._documents);

  final ShosaiCore _core;
  final OpenDocuments _documents;

  /// The core cancellation behind each bridge cancellation id the records
  /// were given, until the id is released.
  final Map<BigInt, CancellationToken> _tokens = {};

  CancellationToken _token(BigInt id) =>
      _tokens.putIfAbsent(id, CancellationToken.new);

  /// Cancel the records operation running under [id].
  void cancel(BigInt id) => _token(id).cancel();

  void release(BigInt id) => _tokens.remove(id);

  @override
  Future<FlutterLibraryPage> libraryPage({
    String? query,
    FlutterBookFormat? format,
    required int limit,
    required int offset,
    required BigInt cancellationId,
  }) => _guard(() async {
    _token(cancellationId).throwIfCancelled();
    final page = await _core.library.page(
      query: query,
      format: format == null ? null : _bookFormat(format),
      limit: limit,
      offset: offset,
    );
    _token(cancellationId).throwIfCancelled();
    return FlutterLibraryPage(
      books: [for (final book in page.books) _libraryBook(book)],
      hasMore: page.hasMore,
    );
  });

  @override
  Future<Uint8List?> libraryCover({
    required int bookId,
    required BigInt cancellationId,
  }) => _guard(() async {
    _token(cancellationId).throwIfCancelled();
    return _core.library.cover(bookId);
  });

  @override
  Future<FlutterImportReport> importPaths({
    required List<String> pathKeys,
    required bool managed,
    required BigInt cancellationId,
  }) => _guard(() async {
    final report = await _core.library.importPaths(
      [for (final key in pathKeys) pdfPathFromKey(key)],
      managed: managed,
      cancellation: _token(cancellationId),
    );
    return _importReport(report, pathKeys);
  });

  @override
  Future<FlutterImportReport> importDirectory({
    required String pathKey,
    required bool managed,
    required BigInt cancellationId,
  }) => _guard(() async {
    final report = await _core.library.importDirectory(
      pdfPathFromKey(pathKey),
      managed: managed,
      cancellation: _token(cancellationId),
    );
    return _importReport(report, null);
  });

  @override
  Future<FlutterLibraryRemoveOutcome> removeLibraryBook({
    required int bookId,
  }) => _guard(() async {
    final outcome = await _core.library.remove(bookId);
    return FlutterLibraryRemoveOutcome(
      removed: outcome.removed,
      managedFileDeletionPending: outcome.managedFileDeletionPending,
    );
  });

  @override
  Future<FlutterReaderSettings> loadReaderSettings({
    required BigInt cancellationId,
  }) => _guard(() async {
    _token(cancellationId).throwIfCancelled();
    final settings = await _core.settings.load();
    return FlutterReaderSettings(
      continuous: settings.continuous,
      theme: settings.theme.name,
      epubFontSize: settings.epubFontSize,
      epubLineSpacing: settings.epubLineSpacing,
      pdfZoom: settings.pdfZoom,
    );
  });

  @override
  Future<void> saveReaderSettings({required FlutterReaderSettings value}) =>
      _guard(() async {
        final theme = ReaderTheme.values
            .where((theme) => theme.name == value.theme)
            .firstOrNull;
        if (theme == null) {
          throw CoreException.invalidRequest(
            'Unknown reader theme: ${value.theme}',
          );
        }
        await _core.settings.save(
          ReaderSettings(
            continuous: value.continuous,
            theme: theme,
            epubFontSize: value.epubFontSize,
            epubLineSpacing: value.epubLineSpacing,
            pdfZoom: value.pdfZoom,
          ),
        );
      });

  @override
  Future<FlutterDocumentSummary> openLibraryBook({
    required int bookId,
    required BigInt cancellationId,
  }) => _guard(() async {
    final book = await _core.library.get(bookId);
    if (book == null) {
      throw const CoreException.notFound('The book is not in the library.');
    }
    final cancellation = _token(cancellationId);
    final path = await _core.library.verifiedPath(
      bookId,
      cancellation: cancellation,
    );
    final opened = await _documents.open(
      path,
      format: book.format,
      bookId: bookId,
      title: book.title,
      cancellation: cancellation,
    );
    return opened.summary;
  });

  @override
  Future<FlutterReadingState?> loadReadingState({
    required int bookId,
    required BigInt cancellationId,
  }) => _guard(() async {
    _token(cancellationId).throwIfCancelled();
    final position = await _core.readingState.load(bookId);
    return position == null
        ? null
        : FlutterReadingState(
            unit: BigInt.from(position.unit),
            offset: position.offset == null
                ? null
                : BigInt.from(position.offset!),
            zoom: position.zoom,
          );
  });

  @override
  Future<void> saveReadingState({
    required int bookId,
    required FlutterReadingState value,
    required BigInt unitCount,
  }) => _guard(
    () => _core.readingState.save(
      bookId,
      ReadingPosition(
        unit: value.unit.toInt(),
        offset: value.offset?.toInt(),
        zoom: value.zoom,
      ),
      unitCount: unitCount.toInt(),
    ),
  );

  @override
  Future<List<FlutterBookmark>> listBookmarks({
    required int bookId,
    required BigInt cancellationId,
  }) => _guard(() async {
    _token(cancellationId).throwIfCancelled();
    return [
      for (final bookmark in await _core.bookmarks.list(bookId))
        _bookmark(bookmark, bookId),
    ];
  });

  @override
  Future<FlutterBookmark?> toggleBookmark({
    required int bookId,
    required BigInt unit,
    BigInt? offset,
    String? title,
    String? note,
  }) => _guard(() async {
    final bookmark = await _core.bookmarks.toggle(
      bookId,
      unit.toInt(),
      offset: offset?.toInt(),
      title: title,
      note: note,
    );
    return bookmark == null ? null : _bookmark(bookmark, bookId);
  });

  @override
  Future<void> updateBookmarkNote({required int id, String? note}) =>
      _guard(() => _core.bookmarks.updateNote(id, note));

  @override
  Future<void> deleteBookmark({required int id}) =>
      _guard(() => _core.bookmarks.delete(id));

  @override
  Future<String> exportBookmarks({required int bookId}) =>
      _guard(() => _core.bookmarks.exportMarkdown(bookId));

  @override
  Future<List<FlutterAnnotation>> listAnnotations({
    required FlutterDocumentSummary document,
    required ReaderText text,
    required double scale,
    required BigInt cancellationId,
  }) => _guard(() async {
    final bookId = document.bookId;
    // Annotations belong to library books; a document opened from a file
    // has none.
    if (bookId == null) return const [];
    final resolved = await _core.annotations.list(
      bookId,
      text,
      cancellation: _token(cancellationId),
    );
    return [for (final item in resolved) _annotation(item, scale)];
  });

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
  }) => _guard(() async {
    final bookId = _annotatedBook(document);
    if (!displayScale.isFinite || displayScale <= 0) {
      throw const CoreException.invalidRequest(
        'The annotation display scale must be finite and positive.',
      );
    }
    _token(cancellationId).throwIfCancelled();
    final selection = switch (document.format) {
      FlutterBookFormat.epub => EpubTextSelection(
        spineIndex: unit.toInt(),
        resourcePath:
            surface.resourcePath ??
            (throw const CoreException.invalidRequest(
              'The EPUB selection has no resource path.',
            )),
        text: surface.text,
        start: start.toInt(),
        end: end.toInt(),
      ),
      FlutterBookFormat.pdf => _pdfSelection(
        surface,
        unit.toInt(),
        start.toInt(),
        end.toInt(),
        displayScale,
      ),
    };
    final created = await _core.annotations.create(
      bookId,
      selection,
      color: _highlightColor(color),
      body: body,
    );
    return _annotation(created, displayScale);
  });

  @override
  Future<bool> updateAnnotation({
    required FlutterDocumentSummary document,
    required String id,
    required FlutterHighlightColor color,
    String? body,
  }) => _guard(
    () => _core.annotations.update(
      _annotatedBook(document),
      id,
      color: _highlightColor(color),
      body: body,
    ),
  );

  @override
  Future<bool> deleteAnnotation({
    required FlutterDocumentSummary document,
    required String id,
  }) => _guard(() => _core.annotations.delete(_annotatedBook(document), id));

  @override
  Future<FlutterAnnotationAssociationSourcePage>
  listAnnotationAssociationSources({
    required FlutterDocumentSummary target,
    String? cursor,
    required BigInt limit,
    required BigInt cancellationId,
  }) => _guard(() async {
    final bookId = target.bookId;
    if (bookId == null) {
      return const FlutterAnnotationAssociationSourcePage(sources: []);
    }
    final page = await _core.annotations.associationSources(
      bookId,
      cursor: cursor,
      limit: limit.toInt(),
      cancellation: _token(cancellationId),
    );
    return FlutterAnnotationAssociationSourcePage(
      sources: [
        for (final source in page.sources)
          FlutterAnnotationAssociationSource(
            versionId: source.versionId,
            format: target.format,
            // The title the book had when that content was annotated: what
            // the person recognizes, now that books are known by content.
            localPath: source.title,
            fingerprintAlgorithm: 'sha256',
            fingerprintVersion: 1,
            fingerprint: _hexBytes(source.contentHash),
            liveAnnotations: BigInt.from(source.liveAnnotations),
          ),
      ],
      nextCursor: page.nextCursor,
      previousCursor: page.previousCursor,
    );
  });

  @override
  Future<FlutterAnnotationAssociationOutcome> associateAnnotationVersion({
    required String sourceVersionId,
    required FlutterDocumentSummary target,
    required BigInt cancellationId,
  }) => _guard(() async {
    _token(cancellationId).throwIfCancelled();
    final outcome = await _core.annotations.associate(
      sourceVersionId,
      _annotatedBook(target),
    );
    return switch (outcome) {
      AssociationOutcome.associated =>
        FlutterAnnotationAssociationOutcome.associated,
      AssociationOutcome.alreadyAssociated =>
        FlutterAnnotationAssociationOutcome.alreadyAssociated,
    };
  });

  @override
  Future<List<FlutterSearchMatch>> searchDocument({
    required FlutterDocumentSummary document,
    required ReaderText text,
    required String query,
    required BigInt cancellationId,
  }) => _guard(() async {
    final matches = await searchBook(
      text,
      query,
      cancellation: _token(cancellationId),
    );
    return [
      for (final match in matches)
        FlutterSearchMatch(
          unit: BigInt.from(match.unit),
          offset: BigInt.from(match.offset),
          length: BigInt.from(match.length),
          context: match.context,
        ),
    ];
  });
}

/// The bridge the application hands its controllers: the documents it opens
/// through the Dart engines, and [records] over the Dart core.
///
/// Disposing it releases its documents; the core outlives every bridge.
final class ApplicationBridge implements FlutterBridge, RecordsHost {
  ApplicationBridge(ShosaiCore core)
    : this._(core, OpenDocuments(core.pdfEngine));

  ApplicationBridge._(ShosaiCore core, this._documents)
    : records = CoreRecords(core, _documents);

  final OpenDocuments _documents;

  @override
  final CoreRecords records;

  var _lastCancellation = BigInt.zero;
  final Set<BigInt> _cancellations = {};
  var _disposed = false;

  @override
  BigInt createCancellation() {
    _lastCancellation += BigInt.one;
    _cancellations.add(_lastCancellation);
    return _lastCancellation;
  }

  @override
  bool cancel({required BigInt id}) {
    if (!_cancellations.contains(id)) return false;
    records.cancel(id);
    return true;
  }

  @override
  bool releaseCancellation({required BigInt id}) {
    records.release(id);
    return _cancellations.remove(id);
  }

  @override
  void dispose() {
    _disposed = true;
    _documents.releaseAll();
  }

  @override
  bool get isDisposed => _disposed;

  // Documents.

  @override
  Future<FlutterDocumentSummary> openDocument({
    required FlutterOpenRequest request,
    required BigInt cancellationId,
  }) => _guard(() async {
    if (_disposed) {
      throw const CoreException.invalidRequest('The bridge is disposed.');
    }
    final opened = await _documents.open(
      pdfPathFromKey(request.pathKey),
      format: switch (request.formatHint) {
        null => null,
        final format => _bookFormat(format),
      },
      cancellation: records._token(cancellationId),
    );
    return opened.summary;
  });

  @override
  Future<FlutterDocumentSummary> openLibraryBook({
    required int bookId,
    required BigInt cancellationId,
  }) => records.openLibraryBook(bookId: bookId, cancellationId: cancellationId);

  @override
  Future<EpubBook> epubBook({
    required FlutterDocumentHandle document,
    required BigInt cancellationId,
  }) => _guard(() async {
    records._token(cancellationId).throwIfCancelled();
    return _documents[document].epub ??
        (throw const CoreException.invalidRequest(
          'The document is not an EPUB.',
        ));
  });

  @override
  bool releaseDocument({required FlutterDocumentHandle handle}) =>
      _documents.release(handle);

  // Records, served by the Dart core.

  @override
  Future<FlutterLibraryPage> libraryPage({
    String? query,
    FlutterBookFormat? format,
    required int limit,
    required int offset,
    required BigInt cancellationId,
  }) => records.libraryPage(
    query: query,
    format: format,
    limit: limit,
    offset: offset,
    cancellationId: cancellationId,
  );

  @override
  Future<Uint8List?> libraryCover({
    required int bookId,
    required BigInt cancellationId,
  }) => records.libraryCover(bookId: bookId, cancellationId: cancellationId);

  @override
  Future<FlutterImportReport> importPaths({
    required List<String> pathKeys,
    required bool managed,
    required BigInt cancellationId,
  }) => records.importPaths(
    pathKeys: pathKeys,
    managed: managed,
    cancellationId: cancellationId,
  );

  @override
  Future<FlutterImportReport> importDirectory({
    required String pathKey,
    required bool managed,
    required BigInt cancellationId,
  }) => records.importDirectory(
    pathKey: pathKey,
    managed: managed,
    cancellationId: cancellationId,
  );

  @override
  Future<FlutterLibraryRemoveOutcome> removeLibraryBook({
    required int bookId,
  }) => records.removeLibraryBook(bookId: bookId);

  @override
  Future<FlutterReaderSettings> loadReaderSettings({
    required BigInt cancellationId,
  }) => records.loadReaderSettings(cancellationId: cancellationId);

  @override
  Future<void> saveReaderSettings({required FlutterReaderSettings value}) =>
      records.saveReaderSettings(value: value);

  @override
  Future<FlutterReadingState?> loadReadingState({
    required int bookId,
    required BigInt cancellationId,
  }) =>
      records.loadReadingState(bookId: bookId, cancellationId: cancellationId);

  @override
  Future<void> saveReadingState({
    required int bookId,
    required FlutterReadingState value,
    required BigInt unitCount,
  }) => records.saveReadingState(
    bookId: bookId,
    value: value,
    unitCount: unitCount,
  );

  @override
  Future<List<FlutterBookmark>> listBookmarks({
    required int bookId,
    required BigInt cancellationId,
  }) => records.listBookmarks(bookId: bookId, cancellationId: cancellationId);

  @override
  Future<FlutterBookmark?> toggleBookmark({
    required int bookId,
    required BigInt unit,
    BigInt? offset,
    String? title,
    String? note,
  }) => records.toggleBookmark(
    bookId: bookId,
    unit: unit,
    offset: offset,
    title: title,
    note: note,
  );

  @override
  Future<void> updateBookmark({required int id, String? title, String? note}) =>
      records.updateBookmarkNote(id: id, note: note);

  @override
  Future<void> updateBookmarkNote({required int id, String? note}) =>
      records.updateBookmarkNote(id: id, note: note);

  @override
  Future<void> deleteBookmark({required int id}) =>
      records.deleteBookmark(id: id);

  @override
  Future<String> exportBookmarks({required int bookId}) =>
      records.exportBookmarks(bookId: bookId);

  // Handle-keyed annotations and search, for callers that hold only a
  // document handle (tests and measurement tools). They read the document's
  // own text: PDF pages through an engine document, EPUB chapters from the
  // parsed book. The reader passes its own text to [records] instead.

  OpenDocument _document(FlutterDocumentHandle handle) {
    try {
      return _documents[handle];
    } on CoreException catch (error) {
      throw FlutterBridgeError(
        kind: FlutterBridgeErrorKind.invalidRequest,
        message: error.message,
      );
    }
  }

  ReaderText _text(OpenDocument opened) => switch (opened.epub) {
    null => _LazyPdfText(opened, _documents.pdfEngine),
    final book => EpubReaderText(
      unitCount: book.chapters.length,
      text: (unit) async => book.chapters[unit].canonicalText,
      resourcePath: (unit) async => book.chapters[unit].resource,
    ),
  };

  @override
  Future<List<FlutterAnnotation>> listAnnotations({
    required FlutterDocumentHandle document,
    required double scale,
    required BigInt cancellationId,
  }) {
    final opened = _document(document);
    return records.listAnnotations(
      document: opened.summary,
      text: _text(opened),
      scale: scale,
      cancellationId: cancellationId,
    );
  }

  @override
  Future<FlutterAnnotation> createAnnotation({
    required FlutterDocumentHandle document,
    required BigInt unit,
    required BigInt start,
    required BigInt end,
    required double displayScale,
    required FlutterHighlightColor color,
    String? body,
    required BigInt cancellationId,
  }) async {
    final opened = _document(document);
    final FlutterSelectionSurface surface;
    if (opened.epub case final book?) {
      final chapter = unit < BigInt.from(book.chapters.length)
          ? book.chapters[unit.toInt()]
          : throw FlutterBridgeError(
              kind: FlutterBridgeErrorKind.invalidRequest,
              message: 'The EPUB has no chapter $unit.',
            );
      // The chapter's canonical stream, which every EPUB selection indexes.
      surface = FlutterSelectionSurface(
        text: chapter.canonicalText,
        resourcePath: chapter.resource,
        width: 0,
        height: 0,
        copyEligible: true,
        visualLines: const [],
        endpoints: const [],
        graphemeBoundaries: Uint32List(0),
        wordBoundaries: Uint32List(0),
      );
    } else {
      surface = await (await opened.pdf(
        _documents.pdfEngine,
      )).selectionSurface(unit.toInt(), displayScale);
    }
    return records.createAnnotation(
      document: opened.summary,
      surface: surface,
      unit: unit,
      start: start,
      end: end,
      displayScale: displayScale,
      color: color,
      body: body,
      cancellationId: cancellationId,
    );
  }

  @override
  Future<bool> updateAnnotation({
    required FlutterDocumentHandle document,
    required String id,
    required FlutterHighlightColor color,
    String? body,
  }) async => records.updateAnnotation(
    document: _document(document).summary,
    id: id,
    color: color,
    body: body,
  );

  @override
  Future<bool> deleteAnnotation({
    required FlutterDocumentHandle document,
    required String id,
  }) async =>
      records.deleteAnnotation(document: _document(document).summary, id: id);

  @override
  Future<FlutterAnnotationAssociationSourcePage>
  listAnnotationAssociationSources({
    required FlutterDocumentHandle target,
    String? cursor,
    required BigInt limit,
    required BigInt cancellationId,
  }) async => records.listAnnotationAssociationSources(
    target: _document(target).summary,
    cursor: cursor,
    limit: limit,
    cancellationId: cancellationId,
  );

  @override
  Future<FlutterAnnotationAssociationOutcome> associateAnnotationVersion({
    required String sourceVersionId,
    required FlutterDocumentHandle target,
    required BigInt cancellationId,
  }) async => records.associateAnnotationVersion(
    sourceVersionId: sourceVersionId,
    target: _document(target).summary,
    cancellationId: cancellationId,
  );

  @override
  Future<List<FlutterSearchMatch>> searchDocument({
    required FlutterDocumentHandle document,
    required String query,
    required BigInt cancellationId,
  }) async {
    final opened = _document(document);
    return records.searchDocument(
      document: opened.summary,
      text: _text(opened),
      query: query,
      cancellationId: cancellationId,
    );
  }
}

/// PDF page text from an engine document opened on first use.
final class _LazyPdfText implements ReaderText {
  const _LazyPdfText(this._opened, this._engine);

  final OpenDocument _opened;
  final PdfEngine _engine;

  @override
  int get unitCount => _opened.summary.logicalUnitCount.toInt();

  @override
  Future<UnitText?> unitText(
    int unit, {
    CancellationToken? cancellation,
  }) async => PdfReaderText(
    await _opened.pdf(_engine),
  ).unitText(unit, cancellation: cancellation);
}

/// Run [body], reporting a core failure as the bridge error the controllers
/// already present.
Future<T> _guard<T>(Future<T> Function() body) async {
  try {
    return await body();
  } on CoreException catch (error) {
    throw FlutterBridgeError(
      kind: switch (error.kind) {
        CoreErrorKind.cancelled => FlutterBridgeErrorKind.cancelled,
        CoreErrorKind.notFound => FlutterBridgeErrorKind.notFound,
        CoreErrorKind.inaccessible => FlutterBridgeErrorKind.inaccessible,
        CoreErrorKind.unsupported => FlutterBridgeErrorKind.unsupported,
        CoreErrorKind.invalidRequest ||
        CoreErrorKind.conflict => FlutterBridgeErrorKind.invalidRequest,
        CoreErrorKind.malformed => FlutterBridgeErrorKind.malformed,
        CoreErrorKind.limitExceeded => FlutterBridgeErrorKind.limitExceeded,
        CoreErrorKind.storage => FlutterBridgeErrorKind.backendUnavailable,
      },
      message: error.message,
    );
  }
}

int _annotatedBook(FlutterDocumentSummary document) =>
    document.bookId ??
    (throw const CoreException.invalidRequest(
      'Only books in the library keep highlights.',
    ));

/// A PDF selection of [start]..[end] on [surface], built at [scale]: the
/// character boxes it covers in page points and, when the page text maps to
/// its characters, the text range.
PdfSelection _pdfSelection(
  FlutterSelectionSurface surface,
  int page,
  int start,
  int end,
  double scale,
) {
  final rectangles = <PageRect>[];
  for (final endpoint in surface.endpoints) {
    final character = endpoint.rangeStart.toInt();
    if (character < start || character >= end) continue;
    final rect = endpoint.rect;
    final value = PageRect(
      rect.left / scale,
      rect.top / scale,
      rect.right / scale,
      rect.bottom / scale,
    );
    if (value.isValid && (rectangles.isEmpty || rectangles.last != value)) {
      rectangles.add(value);
    }
  }
  return surface.copyEligible
      ? PdfSelection(
          page: page,
          rectangles: rectangles,
          text: surface.text,
          start: start,
          end: end,
        )
      : PdfSelection(page: page, rectangles: rectangles);
}

FlutterAnnotation _annotation(ResolvedAnnotation resolved, double scale) {
  final stored = resolved.annotation;
  final (start, end) = (resolved.start, resolved.end);
  return FlutterAnnotation(
    id: stored.id,
    unit: BigInt.from(stored.anchor.unit),
    resolution: switch (resolved.resolution) {
      AnnotationResolution.exact => FlutterAnnotationResolution.exact,
      AnnotationResolution.recovered => FlutterAnnotationResolution.recovered,
      AnnotationResolution.ambiguous => FlutterAnnotationResolution.ambiguous,
      AnnotationResolution.orphaned => FlutterAnnotationResolution.orphaned,
    },
    textRange: start == null || end == null
        ? null
        : FlutterAnnotationTextRange(
            start: BigInt.from(start),
            end: BigInt.from(end),
          ),
    quote: stored.quote?.original ?? stored.quote?.exact,
    rectangles: resolved.rectangles.isEmpty
        ? null
        : [
            for (final rectangle in resolved.rectangles)
              FlutterSelectionRect(
                left: rectangle.left * scale,
                top: rectangle.top * scale,
                right: rectangle.right * scale,
                bottom: rectangle.bottom * scale,
              ),
          ],
    color: _flutterColor(stored.color),
    body: stored.body,
  );
}

HighlightColor _highlightColor(FlutterHighlightColor color) =>
    HighlightColor.values.byName(color.name);

FlutterHighlightColor _flutterColor(HighlightColor color) =>
    FlutterHighlightColor.values.byName(color.name);

BookFormat _bookFormat(FlutterBookFormat format) => switch (format) {
  FlutterBookFormat.epub => BookFormat.epub,
  FlutterBookFormat.pdf => BookFormat.pdf,
};

FlutterBookFormat _flutterFormat(BookFormat format) => switch (format) {
  BookFormat.epub => FlutterBookFormat.epub,
  BookFormat.pdf => FlutterBookFormat.pdf,
};

FlutterLibraryBook _libraryBook(Book book) => FlutterLibraryBook(
  bookId: book.id,
  title: book.title,
  author: book.author,
  format: _flutterFormat(book.format),
  pathKey: book.path,
  managed: book.storageKind == StorageKind.managed,
  progress: book.progress,
  dateAdded: book.dateAdded,
  lastRead: book.lastRead,
);

FlutterBookmark _bookmark(Bookmark bookmark, int bookId) => FlutterBookmark(
  id: bookmark.id,
  bookId: bookId,
  unit: BigInt.from(bookmark.unit),
  offset: bookmark.offset == null ? null : BigInt.from(bookmark.offset!),
  title: bookmark.title,
  note: bookmark.note,
  color: bookmark.color,
  createdAt: bookmark.createdAt,
);

/// [report] for the bridge. A selected path key the core decoded is
/// reported as the key the caller sent.
FlutterImportReport _importReport(ImportReport report, List<String>? keys) {
  final items = report.items;
  return FlutterImportReport(
    imported: BigInt.from(report.imported),
    failed: BigInt.from(report.failed),
    cancelled: report.cancelled,
    items: [
      for (final (index, item) in items.indexed)
        FlutterImportItem(
          pathKey: keys != null && index < keys.length
              ? keys[index]
              : item.path,
          book: item.book == null ? null : _libraryBook(item.book!),
          error: item.error,
        ),
    ],
  );
}

Uint8List _hexBytes(String hex) => Uint8List.fromList([
  for (var index = 0; index + 1 < hex.length; index += 2)
    int.parse(hex.substring(index, index + 2), radix: 16),
]);
