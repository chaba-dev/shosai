/// The records over the Dart application core (`shosai_core`), and the
/// application bridge that serves them beside the documents it opens.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:shosai_core/shosai_core.dart';
import 'package:shosai_epub/shosai_epub.dart' show EpubBook;
import 'package:shosai_flutter/core/bridge.dart';
import 'package:shosai_flutter/core/documents.dart';
import 'package:shosai_flutter/core/reader_text.dart';
import 'package:shosai_flutter/core/records.dart';
import 'package:shosai_flutter/reader/pdf/engine.dart';

/// The application's records: one store, opened once per process and shared
/// by every bridge the shell creates. Its [CoreOwner] closes it.
final class ShosaiCore {
  ShosaiCore._(this.store, this.library, this.pdfEngine, String dataDirectory)
    : snapshots = DocumentSnapshots('$dataDirectory/snapshots'),
      readingState = ReadingState(store),
      bookmarks = Bookmarks(store),
      settings = ReaderSettingsStore(store),
      librarySettings = LibrarySettingsStore(store),
      annotations = Annotations(store);

  /// Open the store `library.sqlite3` and the managed directory `books`
  /// under [dataDirectory], reading PDF metadata through [pdfEngine], and
  /// retry deleting private copies and PDF snapshots (`snapshots`) an
  /// earlier run could not delete.
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
    final core = ShosaiCore._(store, library, pdfEngine, dataDirectory);
    try {
      await library.retryManagedFileDeletions();
    } on CoreException {
      // Deletion stays recorded and is retried on the next start.
    }
    await core.snapshots.sweep();
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
  final LibrarySettingsStore librarySettings;
  final Annotations annotations;

  /// The private copies open PDFs are read from, shared by every bridge.
  final DocumentSnapshots snapshots;

  /// Close the store and delete the snapshot directory. Call it once no
  /// bridge uses the core: [CoreOwner.close] does, after its bridges drain.
  Future<void> close() async {
    try {
      await snapshots.close();
    } finally {
      await store.close();
    }
  }
}

/// The one owner of a [ShosaiCore]: it hands out the bridges that share the
/// core and, when the application or a test is done with it, closes the
/// core after every bridge has drained. A single bridge never closes it.
final class CoreOwner {
  CoreOwner(this.core);

  final ShosaiCore core;
  final Set<ApplicationBridge> _bridges = {};
  Future<void>? _closing;

  /// Whether [close] has started.
  bool get isClosed => _closing != null;

  /// A new bridge over the core.
  ApplicationBridge bridge() {
    if (_closing != null) {
      throw StateError('The application core is closed.');
    }
    final bridge = ApplicationBridge(core);
    _bridges.add(bridge);
    // A bridge its reader disposed is forgotten once it has drained.
    unawaited(
      bridge._disposedFuture.then((_) async {
        await bridge.drain();
        _bridges.remove(bridge);
      }),
    );
    return bridge;
  }

  /// Dispose every bridge, wait until each has drained, then close the
  /// core. Idempotent: a second call waits for the first.
  Future<void> close() => _closing ??= () async {
    final bridges = List.of(_bridges);
    for (final bridge in bridges) {
      bridge.dispose();
    }
    try {
      await Future.wait([for (final bridge in bridges) bridge.drain()]);
    } finally {
      _bridges.clear();
      await core.close();
    }
  }();
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

  /// The operations running, for [drain].
  final Set<Future<void>> _running = {};
  var _closed = false;

  CancellationToken _token(BigInt id) {
    if (_closed) return CancellationToken()..cancel();
    return _tokens.putIfAbsent(id, CancellationToken.new);
  }

  /// Cancel the records operation running under [id].
  void cancel(BigInt id) => _token(id).cancel();

  void release(BigInt id) => _tokens.remove(id);

  /// Cancel every operation and admit no more cancellable work: a later
  /// cancellation id is cancelled from the start.
  void _close() {
    _closed = true;
    for (final token in _tokens.values) {
      token.cancel();
    }
    _tokens.clear();
  }

  /// Completes when no operation these records started is running.
  Future<void> drain() async {
    while (_running.isNotEmpty) {
      await Future.wait(List.of(_running));
    }
  }

  /// Run [body] as a tracked operation, reporting a core failure as the
  /// bridge error the controllers present.
  Future<T> _guard<T>(Future<T> Function() body) {
    final result = _bridgeErrors(body);
    late final Future<void> tracked;
    tracked = result.then<void>((_) {}, onError: (_) {}).whenComplete(() {
      _running.remove(tracked);
    });
    _running.add(tracked);
    return result;
  }

  /// The content key of a document opened outside the library: the hash of
  /// the snapshot it reads, so its annotations follow its bytes.
  AnnotatedContent _content(FlutterDocumentSummary document) {
    final opened = _documents[document.handle];
    return AnnotatedContent(
      contentHash: opened.contentHash,
      format: _bookFormat(document.format),
      title: _contentTitle(document.title, opened.path),
    );
  }

  @override
  Future<FlutterLibraryPage> libraryPage({
    String? query,
    FlutterBookFormat? format,
    FlutterLibrarySort sort = FlutterLibrarySort.recent,
    required int limit,
    required int offset,
    required BigInt cancellationId,
  }) => _guard(() async {
    _token(cancellationId).throwIfCancelled();
    final page = await _core.library.page(
      query: query,
      format: format == null ? null : _bookFormat(format),
      sort: LibrarySort.values.byName(sort.name),
      limit: limit,
      offset: offset,
    );
    final notes = switch (page.continueReading) {
      final book? => await _core.annotations.summary(book.id),
      null => null,
    };
    _token(cancellationId).throwIfCancelled();
    return FlutterLibraryPage(
      books: [for (final book in page.books) _libraryBook(book)],
      hasMore: page.hasMore,
      bookCount: page.bookCount,
      continueReading: switch (page.continueReading) {
        final book? => _libraryBook(book),
        null => null,
      },
      continueReadingNotes: switch (notes) {
        final notes? => FlutterNotesSummary(
          count: notes.count,
          latest: notes.latest,
        ),
        null => null,
      },
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
    final sort = await _core.librarySettings.loadSort();
    return FlutterReaderSettings(
      continuous: settings.continuous,
      theme: settings.theme.name,
      epubFontSize: settings.epubFontSize,
      epubLineSpacing: settings.epubLineSpacing,
      pdfZoom: settings.pdfZoom,
      twoPages: settings.twoPages,
      librarySort: FlutterLibrarySort.values.byName(sort.name),
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
            twoPages: value.twoPages,
          ),
        );
        await _core.librarySettings.saveSort(
          LibrarySort.values.byName(value.librarySort.name),
        );
      });

  @override
  Future<FlutterDocumentSummary> openLibraryBook({
    required int bookId,
    required BigInt cancellationId,
  }) => _guard(() async {
    if (_documents.isClosed) {
      throw const CoreException.invalidRequest('The bridge is disposed.');
    }
    final book = await _core.library.get(bookId);
    if (book == null) {
      throw const CoreException.notFound('The book is not in the library.');
    }
    // The document reads one snapshot of the file and checks it against the
    // book's content hash: what was verified is what is parsed, rendered,
    // searched and annotated.
    try {
      final opened = await _documents.open(
        book.path,
        format: book.format,
        expected: (
          bookId: bookId,
          title: book.title,
          contentHash: book.contentHash,
        ),
        cancellation: _token(cancellationId),
      );
      return opened.summary;
    } on CoreException catch (error) {
      if (error.kind == CoreErrorKind.notFound) {
        throw CoreException.notFound('The book file is missing: ${book.path}');
      }
      rethrow;
    }
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
      lastUnit: value.lastUnit?.toInt(),
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
  }) => _guard(() async {
    final bookmark = await _core.bookmarks.toggle(
      bookId,
      unit.toInt(),
      offset: offset?.toInt(),
      title: title,
    );
    return bookmark == null ? null : _bookmark(bookmark, bookId);
  });

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
    final cancellation = _token(cancellationId);
    // A library book's annotations are its document's; a file opened
    // directly keeps those of the content it read.
    final resolved = bookId == null
        ? await _core.annotations.listInContent(
            _content(document),
            text,
            cancellation: cancellation,
          )
        : await _core.annotations.list(
            bookId,
            text,
            kinds: const {AnnotationKind.highlight},
            cancellation: cancellation,
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
    final bookId = document.bookId;
    final content = bookId == null ? _content(document) : null;
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
    final created = content != null
        ? await _core.annotations.createInContent(
            content,
            selection,
            color: _highlightColor(color),
            body: body,
          )
        : await _core.annotations.create(
            bookId!,
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
    () => switch (document.bookId) {
      null => _core.annotations.updateInContent(
        _content(document),
        id,
        color: _highlightColor(color),
        body: body,
      ),
      final bookId => _core.annotations.update(
        bookId,
        id,
        color: _highlightColor(color),
        body: body,
      ),
    },
  );

  @override
  Future<bool> deleteAnnotation({
    required FlutterDocumentSummary document,
    required String id,
  }) => _guard(
    () => switch (document.bookId) {
      null => _core.annotations.deleteInContent(_content(document), id),
      final bookId => _core.annotations.delete(bookId, id),
    },
  );

  @override
  Future<List<FlutterNote>> listNotes({
    required FlutterDocumentSummary document,
    required ReaderText text,
    required BigInt cancellationId,
  }) => _guard(() async {
    const kinds = {AnnotationKind.pageNote, AnnotationKind.bookNote};
    final cancellation = _token(cancellationId);
    final resolved = switch (document.bookId) {
      null => await _core.annotations.listInContent(
        _content(document),
        text,
        kinds: kinds,
        cancellation: cancellation,
      ),
      final bookId => await _core.annotations.list(
        bookId,
        text,
        kinds: kinds,
        cancellation: cancellation,
      ),
    };
    // Book notes first, then page notes in reading order; notes at one
    // place stay in the order they were written.
    final notes = [for (final item in resolved) _note(item)];
    int place(BigInt? value) => value?.toInt() ?? -1;
    final order = [for (var i = 0; i < notes.length; i++) i]
      ..sort((i, j) {
        final (a, b) = (notes[i], notes[j]);
        return switch (place(a.unit).compareTo(place(b.unit))) {
          0 => switch (place(a.offset).compareTo(place(b.offset))) {
            0 => i.compareTo(j),
            final byOffset => byOffset,
          },
          final byUnit => byUnit,
        };
      });
    return [for (final i in order) notes[i]];
  });

  @override
  Future<FlutterNote> createNote({
    required FlutterDocumentSummary document,
    required ReaderText text,
    BigInt? unit,
    BigInt? offset,
    required String body,
    required BigInt cancellationId,
  }) => _guard(() async {
    final cancellation = _token(cancellationId);
    final NoteAnchor anchor;
    if (unit == null) {
      anchor = const BookAnchor();
    } else if (document.format == FlutterBookFormat.pdf) {
      anchor = PdfPageAnchor(unit.toInt());
    } else {
      // A page note keeps its chapter's path, so a reordered spine does not
      // move it to another chapter.
      final chapter = await text.unitText(
        unit.toInt(),
        cancellation: cancellation,
      );
      anchor = EpubPlaceAnchor(
        spineIndex: unit.toInt(),
        resourcePath: chapter?.resourcePath,
        offset: offset?.toInt() ?? 0,
      );
    }
    cancellation.throwIfCancelled();
    final created = switch (document.bookId) {
      null => await _core.annotations.createNoteInContent(
        _content(document),
        anchor,
        body,
      ),
      final bookId => await _core.annotations.createNote(bookId, anchor, body),
    };
    return _note(created);
  });

  @override
  Future<bool> updateNote({
    required FlutterDocumentSummary document,
    required String id,
    required String body,
  }) => _guard(
    () => switch (document.bookId) {
      null => _core.annotations.updateNoteInContent(
        _content(document),
        id,
        body,
      ),
      final bookId => _core.annotations.updateNote(bookId, id, body),
    },
  );

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
/// Disposing it admits no more documents, cancels its operations and
/// releases its documents; [drain] completes when that work has finished.
/// The core outlives every bridge; its [CoreOwner] closes it.
final class ApplicationBridge implements FlutterBridge, RecordsHost {
  ApplicationBridge(ShosaiCore core)
    : this._(core, OpenDocuments(core.pdfEngine, core.snapshots));

  ApplicationBridge._(ShosaiCore core, this._documents)
    : records = CoreRecords(core, _documents);

  final OpenDocuments _documents;

  @override
  final CoreRecords records;

  var _lastCancellation = BigInt.zero;
  final Set<BigInt> _cancellations = {};
  var _disposed = false;
  final Completer<void> _disposal = Completer<void>();

  Future<void> get _disposedFuture => _disposal.future;

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
    if (_disposed) return;
    _disposed = true;
    // Admission first: an open still running is rejected and released when
    // it finishes, instead of publishing a document nobody owns.
    records._close();
    _cancellations.clear();
    _documents.close();
    _disposal.complete();
  }

  @override
  bool get isDisposed => _disposed;

  /// Completes when the operations, opens and releases this bridge started
  /// have finished. Call it after [dispose] to know its resources are gone.
  Future<void> drain() async {
    await Future.wait([records.drain(), _documents.drain()]);
    // A release a finishing operation started.
    await _documents.drain();
  }

  /// How many documents this bridge holds open.
  int get openDocumentCount => _documents.length;

  // Documents.

  @override
  Future<FlutterDocumentSummary> openDocument({
    required FlutterOpenRequest request,
    required BigInt cancellationId,
  }) => records._guard(() async {
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
  }) => records._guard(() async {
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
    FlutterLibrarySort sort = FlutterLibrarySort.recent,
    FlutterBookFormat? format,
    required int limit,
    required int offset,
    required BigInt cancellationId,
  }) => records.libraryPage(
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
  }) => records.toggleBookmark(
    bookId: bookId,
    unit: unit,
    offset: offset,
    title: title,
  );

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
    null => _LazyPdfText(opened),
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
      surface = await opened.withPdf(
        (pdf) => pdf.selectionSurface(unit.toInt(), displayScale),
      );
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
  Future<List<FlutterNote>> listNotes({
    required FlutterDocumentHandle document,
    required BigInt cancellationId,
  }) {
    final opened = _document(document);
    return records.listNotes(
      document: opened.summary,
      text: _text(opened),
      cancellationId: cancellationId,
    );
  }

  @override
  Future<FlutterNote> createNote({
    required FlutterDocumentHandle document,
    BigInt? unit,
    BigInt? offset,
    required String body,
    required BigInt cancellationId,
  }) {
    final opened = _document(document);
    return records.createNote(
      document: opened.summary,
      text: _text(opened),
      unit: unit,
      offset: offset,
      body: body,
      cancellationId: cancellationId,
    );
  }

  @override
  Future<bool> updateNote({
    required FlutterDocumentHandle document,
    required String id,
    required String body,
  }) async => records.updateNote(
    document: _document(document).summary,
    id: id,
    body: body,
  );

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

/// PDF page text from an engine document opened on the document's snapshot
/// on first use.
final class _LazyPdfText implements ReaderText {
  const _LazyPdfText(this._opened);

  final OpenDocument _opened;

  @override
  int get unitCount => _opened.summary.logicalUnitCount.toInt();

  @override
  Future<UnitText?> unitText(int unit, {CancellationToken? cancellation}) =>
      _opened.withPdf(
        (pdf) => PdfReaderText(pdf).unitText(unit, cancellation: cancellation),
      );
}

/// Run [body], reporting a core failure as the bridge error the controllers
/// already present.
Future<T> _bridgeErrors<T>(Future<T> Function() body) async {
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

/// Association moves annotations between library books' documents.
int _annotatedBook(FlutterDocumentSummary document) =>
    document.bookId ??
    (throw const CoreException.invalidRequest(
      'Only books in the library take annotations from other contents.',
    ));

/// What a directly opened content's annotations are listed under: its
/// title, else its file name.
String _contentTitle(String? title, String path) {
  final name = title?.trim();
  if (name != null && name.isNotEmpty && name.length <= 1024) return name;
  final file = path.split(RegExp(r'[/\\]')).last;
  return file.isEmpty ? 'Untitled' : file;
}

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
    unit: BigInt.from(stored.anchor.unit!),
    resolution: _resolution(resolved.resolution),
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
    color: _flutterColor(stored.color!),
    body: stored.body,
  );
}

FlutterNote _note(ResolvedAnnotation resolved) {
  final stored = resolved.annotation;
  final unit = stored.anchor.unit;
  return FlutterNote(
    id: stored.id,
    kind: stored.kind == AnnotationKind.bookNote
        ? FlutterNoteKind.book
        : FlutterNoteKind.page,
    unit: unit == null ? null : BigInt.from(unit),
    offset: resolved.start == null ? null : BigInt.from(resolved.start!),
    resolution: _resolution(resolved.resolution),
    body: stored.body ?? '',
    modifiedAt: stored.modifiedAt,
  );
}

FlutterAnnotationResolution _resolution(AnnotationResolution resolution) =>
    switch (resolution) {
      AnnotationResolution.exact => FlutterAnnotationResolution.exact,
      AnnotationResolution.recovered => FlutterAnnotationResolution.recovered,
      AnnotationResolution.ambiguous => FlutterAnnotationResolution.ambiguous,
      AnnotationResolution.orphaned => FlutterAnnotationResolution.orphaned,
    };

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
