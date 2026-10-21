/// The records over the Dart application core (`shosai_core`), and the
/// application bridge that serves them beside the Rust bridge's documents.
library;

import 'dart:typed_data';

import 'package:shosai_core/shosai_core.dart';
import 'package:shosai_flutter/reader/epub/content.dart' show parseEpubBytes;
import 'package:shosai_flutter/core/reader_text.dart';
import 'package:shosai_flutter/core/records.dart';
import 'package:shosai_flutter/reader/pdf/engine.dart';
import 'package:shosai_flutter/src/rust/api.dart';

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

  @override
  Future<BookMetadata> inspect(
    String path, {
    CancellationToken? cancellation,
  }) async {
    final PdfEngineDocument document;
    try {
      document = await _engine.open(path);
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
      await document.dispose();
    }
  }

  Future<Uint8List?> _cover(PdfEngineDocument document) async {
    final size = document.pageSize(0);
    if (size.width <= 0 || size.height <= 0) return null;
    final scale = [
      coverMaxWidth / size.width,
      coverMaxHeight / size.height,
    ].reduce((a, b) => a < b ? a : b);
    try {
      final page = await document.render(0, scale);
      return coverThumbnailFromRgba(page.width, page.height, page.pixels);
    } on PdfEngineException {
      return null;
    }
  }
}

/// [ShosaiRecords] over a [ShosaiCore]. Library books open through
/// [_documents], the Rust bridge that still serves the documents.
final class CoreRecords implements ShosaiRecords {
  CoreRecords(this._core, this._documents);

  final ShosaiCore _core;
  final FlutterBridge _documents;

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
  }) async => (await openLibraryBookAt(
    bookId: bookId,
    cancellationId: cancellationId,
  )).$1;

  /// [openLibraryBook], with the path the book opened from.
  Future<(FlutterDocumentSummary, String)> openLibraryBookAt({
    required int bookId,
    required BigInt cancellationId,
  }) async {
    final (book, path) = await _guard(() async {
      final book = await _core.library.get(bookId);
      if (book == null) {
        throw const CoreException.notFound('The book is not in the library.');
      }
      final path = await _core.library.verifiedPath(
        bookId,
        cancellation: _token(cancellationId),
      );
      return (book, path);
    });
    final opened = await _documents.openDocument(
      request: FlutterOpenRequest(
        localId: path,
        pathKey: path,
        formatHint: _flutterFormat(book.format),
      ),
      cancellationId: cancellationId,
    );
    final summary = FlutterDocumentSummary(
      handle: opened.handle,
      bookId: bookId,
      format: opened.format,
      title: book.title,
      logicalUnitCount: opened.logicalUnitCount,
    );
    return (summary, path);
  }

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

/// The bridge the application hands its controllers: the Rust bridge for
/// documents, and [records] over the Dart core.
///
/// Disposing it disposes the Rust bridge; the core outlives every bridge.
final class ApplicationBridge implements FlutterBridge, RecordsHost {
  ApplicationBridge(ShosaiCore core, this._rust)
    : records = CoreRecords(core, _rust);

  /// The application bridge over [core] and a Rust bridge whose own
  /// database lives at [rustDatabasePath].
  factory ApplicationBridge.at(ShosaiCore core, String rustDatabasePath) =>
      ApplicationBridge(
        core,
        FlutterBridge.withDatabasePath(databasePath: rustDatabasePath),
      );

  final FlutterBridge _rust;

  @override
  final CoreRecords records;

  @override
  BigInt createCancellation() => _rust.createCancellation();

  @override
  bool cancel({required BigInt id}) {
    records.cancel(id);
    return _rust.cancel(id: id);
  }

  @override
  bool releaseCancellation({required BigInt id}) {
    records.release(id);
    return _rust.releaseCancellation(id: id);
  }

  @override
  void dispose() => _rust.dispose();

  @override
  bool get isDisposed => _rust.isDisposed;

  // Documents, served by the Rust bridge until the Dart engines replace it.

  @override
  Future<FlutterDocumentSummary> openDocument({
    required FlutterOpenRequest request,
    required BigInt cancellationId,
  }) async {
    final summary = await _rust.openDocument(
      request: request,
      cancellationId: cancellationId,
    );
    _opened[summary.handle] = _OpenedDocument(
      summary,
      pdfPathFromKey(request.pathKey),
    );
    return summary;
  }

  @override
  Future<FlutterDocumentSummary> openLibraryBook({
    required int bookId,
    required BigInt cancellationId,
  }) async {
    final (summary, path) = await records.openLibraryBookAt(
      bookId: bookId,
      cancellationId: cancellationId,
    );
    _opened[summary.handle] = _OpenedDocument(summary, path);
    return summary;
  }

  @override
  bool releaseDocument({required FlutterDocumentHandle handle}) {
    _opened.remove(handle)?.release();
    return _rust.releaseDocument(handle: handle);
  }

  @override
  Future<FlutterRenderedBuffer> renderPage({
    required FlutterDocumentHandle document,
    required BigInt page,
    required double scale,
    required BigInt cancellationId,
  }) => _rust.renderPage(
    document: document,
    page: page,
    scale: scale,
    cancellationId: cancellationId,
  );

  @override
  Future<FlutterSelectionSurface> selectionSurface({
    required FlutterDocumentHandle document,
    required BigInt unit,
    required double scale,
    required double width,
    required double fontSize,
    required double lineSpacing,
    required BigInt cancellationId,
  }) => _rust.selectionSurface(
    document: document,
    unit: unit,
    scale: scale,
    width: width,
    fontSize: fontSize,
    lineSpacing: lineSpacing,
    cancellationId: cancellationId,
  );

  @override
  bool releaseSelection({required FlutterSelectionHandle handle}) =>
      _rust.releaseSelection(handle: handle);

  @override
  Uint8List takeBuffer({required FlutterBufferHandle handle}) =>
      _rust.takeBuffer(handle: handle);

  @override
  bool releaseBuffer({required FlutterBufferHandle handle}) =>
      _rust.releaseBuffer(handle: handle);

  @override
  Future<String> epubCanonicalText({
    required FlutterDocumentHandle document,
    required BigInt unit,
    required BigInt cancellationId,
  }) => _rust.epubCanonicalText(
    document: document,
    unit: unit,
    cancellationId: cancellationId,
  );

  @override
  Future<Uint8List> epubSourceBytes({
    required FlutterDocumentHandle document,
    required BigInt cancellationId,
  }) =>
      _rust.epubSourceBytes(document: document, cancellationId: cancellationId);

  @override
  FlutterSelectionSurface roundTripVisibleScene({
    required FlutterSelectionSurface scene,
  }) => _rust.roundTripVisibleScene(scene: scene);

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
  // text on their own: PDF pages through a second engine document, EPUB
  // chapters through the Rust bridge's canonical stream. The reader passes
  // its own text to [records] instead.

  final Map<FlutterDocumentHandle, _OpenedDocument> _opened = {};

  _OpenedDocument _document(FlutterDocumentHandle handle) =>
      _opened[handle] ??
      (throw const FlutterBridgeError(
        kind: FlutterBridgeErrorKind.invalidRequest,
        message: 'unknown or released document handle',
      ));

  ReaderText _text(_OpenedDocument opened, BigInt cancellationId) =>
      switch (opened.summary.format) {
        FlutterBookFormat.pdf => _LazyPdfText(opened, _pdfEngine),
        FlutterBookFormat.epub => EpubReaderText(
          unitCount: opened.summary.logicalUnitCount.toInt(),
          text: (unit) => _rust.epubCanonicalText(
            document: opened.summary.handle,
            unit: BigInt.from(unit),
            cancellationId: cancellationId,
          ),
          resourcePath: (unit) async {
            final chapters = (await opened.epubChapters(
              () => _rust.epubSourceBytes(
                document: opened.summary.handle,
                cancellationId: cancellationId,
              ),
            ));
            return unit < chapters.length ? chapters[unit] : null;
          },
        ),
      };

  PdfEngine get _pdfEngine => records._core.pdfEngine;

  @override
  Future<List<FlutterAnnotation>> listAnnotations({
    required FlutterDocumentHandle document,
    required double scale,
    required BigInt cancellationId,
  }) {
    final opened = _document(document);
    return records.listAnnotations(
      document: opened.summary,
      text: _text(opened, cancellationId),
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
    if (opened.summary.format == FlutterBookFormat.pdf) {
      surface = await (await opened.pdf(
        _pdfEngine,
      )).selectionSurface(unit.toInt(), displayScale);
    } else {
      // The retained layout the Rust bridge annotated with.
      final retained = await _rust.selectionSurface(
        document: document,
        unit: unit,
        scale: 1,
        width: 680,
        fontSize: 18,
        lineSpacing: 1.5,
        cancellationId: cancellationId,
      );
      if (retained.raster case final raster?) {
        _rust.releaseBuffer(handle: raster.handle);
      }
      _rust.releaseSelection(handle: retained.handle);
      surface = retained;
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
      text: _text(opened, cancellationId),
      query: query,
      cancellationId: cancellationId,
    );
  }
}

/// A document this bridge opened, and what its handle-keyed calls loaded
/// for it.
final class _OpenedDocument {
  _OpenedDocument(this.summary, this.path);

  final FlutterDocumentSummary summary;
  final String path;
  Future<PdfEngineDocument>? _pdf;
  Future<List<String>>? _epubChapters;

  Future<PdfEngineDocument> pdf(PdfEngine engine) => _pdf ??= engine.open(path);

  /// The EPUB chapters' resource paths, parsed once from [bytes].
  Future<List<String>> epubChapters(Future<Uint8List> Function() bytes) =>
      _epubChapters ??= () async {
        final book = await parseEpubBytes(await bytes());
        return [for (final chapter in book.chapters) chapter.resource];
      }();

  Future<void> release() async {
    final pdf = _pdf;
    _pdf = null;
    if (pdf != null) await (await pdf).dispose();
  }
}

/// PDF page text from an engine document opened on first use.
final class _LazyPdfText implements ReaderText {
  const _LazyPdfText(this._opened, this._engine);

  final _OpenedDocument _opened;
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
