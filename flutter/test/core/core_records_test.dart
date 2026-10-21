import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_flutter/core/core_records.dart';
import 'package:shosai_flutter/core/reader_text.dart';
import 'package:shosai_flutter/reader/pdf/engine.dart';
import 'package:shosai_flutter/src/rust/api.dart';

const _epubFixture = 'packages/shosai_core/test/fixtures/sample.epub';
const _pdfFixture = 'packages/shosai_core/test/fixtures/sample.pdf';

/// The Rust bridge's document side: opens report the requested path back.
final class _Documents implements FlutterBridge {
  final opened = <String>[];
  var nextCancellation = BigInt.zero;
  final cancelled = <BigInt>{};

  @override
  BigInt createCancellation() => nextCancellation += BigInt.one;

  @override
  bool cancel({required BigInt id}) => cancelled.add(id);

  @override
  bool releaseCancellation({required BigInt id}) => true;

  @override
  Future<FlutterDocumentSummary> openDocument({
    required FlutterOpenRequest request,
    required BigInt cancellationId,
  }) async {
    opened.add(request.pathKey);
    return FlutterDocumentSummary(
      handle: FlutterDocumentHandle(
        registry: BigInt.one,
        id: BigInt.from(opened.length),
      ),
      format: request.formatHint ?? FlutterBookFormat.epub,
      title: 'Rust title',
      logicalUnitCount: BigInt.from(3),
    );
  }

  @override
  bool releaseDocument({required FlutterDocumentHandle handle}) => true;

  @override
  void dispose() {}

  @override
  bool get isDisposed => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A PDF engine whose documents have a title and a one-colour first page.
final class _PdfEngine implements PdfEngine {
  @override
  Future<PdfEngineDocument> open(String path) async => _PdfDocument();
}

final class _PdfDocument implements PdfEngineDocument {
  @override
  int get pageCount => 2;

  @override
  Future<PdfDocumentInfo> info() async =>
      const PdfDocumentInfo(title: 'Engine Title', author: 'Engine Author');

  @override
  PdfPageSize pageSize(int page) => const PdfPageSize(600, 800);

  @override
  Future<PdfRenderedPage> render(int page, double scale) async {
    final width = (600 * scale).round();
    final height = (800 * scale).round();
    return PdfRenderedPage(
      width: width,
      height: height,
      pixels: Uint8List(width * height * 4)
        ..fillRange(0, width * height * 4, 200),
    );
  }

  @override
  Future<String> pageText(int page) async => 'Page $page text';

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

FlutterSelectionSurface _surface(
  String text, {
  String? resourcePath,
  bool copyEligible = true,
  List<FlutterSelectionEndpoint> endpoints = const [],
}) => FlutterSelectionSurface(
  handle: FlutterSelectionHandle(registry: BigInt.one, id: BigInt.one),
  width: 680,
  height: 900,
  text: text,
  copyEligible: copyEligible,
  resourcePath: resourcePath,
  endpoints: endpoints,
  graphemeBoundaries: Uint32List(0),
  wordBoundaries: Uint32List(0),
  visualLines: const [],
);

void main() {
  late Directory directory;
  late ShosaiCore core;
  late _Documents documents;
  late ApplicationBridge bridge;

  setUp(() async {
    directory = Directory.systemTemp.createTempSync('shosai_records');
    core = await ShosaiCore.open(directory.path, pdfEngine: _PdfEngine());
    documents = _Documents();
    bridge = ApplicationBridge(core, documents);
  });

  tearDown(() async {
    await core.close();
    directory.deleteSync(recursive: true);
  });

  Future<FlutterLibraryBook> import(String fixture) async {
    final name = fixture.split('/').last;
    final path = '${directory.path}/$name';
    File(fixture).copySync(path);
    final cancellation = bridge.createCancellation();
    final report = await bridge.importPaths(
      pathKeys: [path],
      managed: false,
      cancellationId: cancellation,
    );
    expect(report.items.single.error, isNull);
    return report.items.single.book!;
  }

  test('library books import, list, open and remove', () async {
    final epub = await import(_epubFixture);
    final pdf = await import(_pdfFixture);

    expect(pdf.title, 'Engine Title');
    expect(pdf.author, 'Engine Author');
    expect(epub.managed, isFalse);
    final page = await bridge.libraryPage(
      limit: 10,
      offset: 0,
      cancellationId: bridge.createCancellation(),
    );
    expect(
      page.books.map((book) => book.bookId),
      unorderedEquals([epub.bookId, pdf.bookId]),
    );
    expect(page.hasMore, isFalse);
    expect(
      await bridge.libraryCover(
        bookId: pdf.bookId,
        cancellationId: bridge.createCancellation(),
      ),
      isNotNull,
    );

    final opened = await bridge.openLibraryBook(
      bookId: epub.bookId,
      cancellationId: bridge.createCancellation(),
    );
    expect(opened.bookId, epub.bookId);
    expect(opened.title, epub.title);
    expect(documents.opened, [epub.pathKey]);

    final removed = await bridge.removeLibraryBook(bookId: epub.bookId);
    expect(removed.removed, isTrue);
    await expectLater(
      bridge.openLibraryBook(
        bookId: epub.bookId,
        cancellationId: bridge.createCancellation(),
      ),
      throwsA(
        isA<FlutterBridgeError>().having(
          (error) => error.kind,
          'kind',
          FlutterBridgeErrorKind.notFound,
        ),
      ),
    );
  });

  test('a cancelled import reports what it finished', () async {
    final cancellation = bridge.createCancellation();
    expect(bridge.cancel(id: cancellation), isTrue);
    final path = '${directory.path}/sample.epub';
    File(_epubFixture).copySync(path);

    final report = await bridge.importPaths(
      pathKeys: [path],
      managed: false,
      cancellationId: cancellation,
    );

    expect(report.cancelled, isTrue);
    expect(report.imported, BigInt.zero);
    expect(documents.cancelled, {cancellation});
  });

  test('reading state, bookmarks and settings round trip', () async {
    final book = await import(_epubFixture);

    await bridge.saveReadingState(
      bookId: book.bookId,
      value: FlutterReadingState(
        unit: BigInt.one,
        offset: BigInt.from(7),
        zoom: 1.5,
      ),
      unitCount: BigInt.from(4),
    );
    final state = await bridge.loadReadingState(
      bookId: book.bookId,
      cancellationId: bridge.createCancellation(),
    );
    expect(
      state,
      FlutterReadingState(unit: BigInt.one, offset: BigInt.from(7), zoom: 1.5),
    );

    final bookmark = await bridge.toggleBookmark(
      bookId: book.bookId,
      unit: BigInt.two,
      title: 'Chapter 3',
    );
    expect(bookmark!.unit, BigInt.two);
    expect(bookmark.bookId, book.bookId);
    await bridge.updateBookmarkNote(id: bookmark.id, note: 'Remember');
    final [listed] = await bridge.listBookmarks(
      bookId: book.bookId,
      cancellationId: bridge.createCancellation(),
    );
    expect(listed.note, 'Remember');
    expect(
      await bridge.exportBookmarks(bookId: book.bookId),
      contains('Chapter 3'),
    );
    await bridge.deleteBookmark(id: bookmark.id);
    expect(
      await bridge.listBookmarks(
        bookId: book.bookId,
        cancellationId: bridge.createCancellation(),
      ),
      isEmpty,
    );

    const settings = FlutterReaderSettings(
      continuous: true,
      theme: 'sepia',
      epubFontSize: 20,
      epubLineSpacing: 1.8,
      pdfZoom: -1,
    );
    await bridge.saveReaderSettings(value: settings);
    expect(
      await bridge.loadReaderSettings(
        cancellationId: bridge.createCancellation(),
      ),
      settings,
    );
    await expectLater(
      bridge.saveReaderSettings(
        value: const FlutterReaderSettings(
          continuous: false,
          theme: 'neon',
          epubFontSize: 16,
          epubLineSpacing: 1.6,
          pdfZoom: 0,
        ),
      ),
      throwsA(isA<FlutterBridgeError>()),
    );
  });

  test('EPUB annotations resolve against the reader text', () async {
    final book = await import(_epubFixture);
    final document = await bridge.openLibraryBook(
      bookId: book.bookId,
      cancellationId: bridge.createCancellation(),
    );
    const chapter = 'The lead Café text tail.';
    const path = 'OEBPS/chapter.xhtml';
    final records = bridge.records;

    final created = await records.createAnnotation(
      document: document,
      surface: _surface(chapter, resourcePath: path),
      unit: BigInt.one,
      start: BigInt.from(9),
      end: BigInt.from(13),
      displayScale: 2,
      color: FlutterHighlightColor.green,
      body: 'Note',
      cancellationId: bridge.createCancellation(),
    );
    expect(created.resolution, FlutterAnnotationResolution.exact);
    expect(
      created.textRange,
      FlutterAnnotationTextRange(start: BigInt.from(9), end: BigInt.from(13)),
    );
    expect(created.quote, 'Café');
    expect(created.color, FlutterHighlightColor.green);
    expect(created.body, 'Note');

    final text = EpubReaderText(
      unitCount: 3,
      text: (unit) async => unit == 1 ? 'Inserted. $chapter' : '',
      resourcePath: (unit) async => unit == 1 ? path : 'other.xhtml',
    );
    final [listed] = await records.listAnnotations(
      document: document,
      text: text,
      scale: 1,
      cancellationId: bridge.createCancellation(),
    );
    expect(listed.resolution, FlutterAnnotationResolution.recovered);
    expect(
      listed.textRange,
      FlutterAnnotationTextRange(start: BigInt.from(19), end: BigInt.from(23)),
    );

    expect(
      await records.updateAnnotation(
        document: document,
        id: created.id,
        color: FlutterHighlightColor.pink,
      ),
      isTrue,
    );
    expect(
      await records.deleteAnnotation(document: document, id: created.id),
      isTrue,
    );
    expect(
      await records.listAnnotations(
        document: document,
        text: text,
        scale: 1,
        cancellationId: bridge.createCancellation(),
      ),
      isEmpty,
    );

    final matches = await records.searchDocument(
      document: document,
      text: text,
      query: 'CAFÉ',
      cancellationId: bridge.createCancellation(),
    );
    expect(matches.single.unit, BigInt.one);
    expect(matches.single.offset, BigInt.from(19));
  });

  test('PDF annotations keep page rectangles in page points', () async {
    final book = await import(_pdfFixture);
    final document = await bridge.openLibraryBook(
      bookId: book.bookId,
      cancellationId: bridge.createCancellation(),
    );
    FlutterSelectionEndpoint endpoint(int character, double left) =>
        FlutterSelectionEndpoint(
          offset: BigInt.from(character),
          rangeStart: BigInt.from(character),
          rangeEnd: BigInt.from(character + 1),
          rect: FlutterSelectionRect(
            left: left,
            top: 20,
            right: left + 10,
            bottom: 40,
          ),
        );
    final surface = _surface(
      'Page 0 text',
      copyEligible: false,
      endpoints: [for (var c = 0; c < 4; c++) endpoint(c, c * 10.0)],
    );

    final created = await bridge.records.createAnnotation(
      document: document,
      surface: surface,
      unit: BigInt.zero,
      start: BigInt.one,
      end: BigInt.from(3),
      displayScale: 2,
      color: FlutterHighlightColor.yellow,
      cancellationId: bridge.createCancellation(),
    );

    // Geometry only: the page text did not map to its characters.
    expect(created.textRange, isNull);
    expect(created.rectangles, const [
      FlutterSelectionRect(left: 10, top: 20, right: 20, bottom: 40),
      FlutterSelectionRect(left: 20, top: 20, right: 30, bottom: 40),
    ]);
    final [listed] = await bridge.records.listAnnotations(
      document: document,
      text: PdfReaderText(_PdfDocument()),
      scale: 4,
      cancellationId: bridge.createCancellation(),
    );
    expect(listed.resolution, FlutterAnnotationResolution.exact);
    expect(
      listed.rectangles!.first,
      const FlutterSelectionRect(left: 20, top: 40, right: 40, bottom: 80),
    );
  });

  test('documents opened from a file keep no annotations', () async {
    final document = await bridge.openDocument(
      request: const FlutterOpenRequest(localId: 'x', pathKey: '/tmp/x.epub'),
      cancellationId: bridge.createCancellation(),
    );

    expect(
      await bridge.records.listAnnotations(
        document: document,
        text: EpubReaderText(
          unitCount: 1,
          text: (_) async => '',
          resourcePath: (_) async => null,
        ),
        scale: 1,
        cancellationId: bridge.createCancellation(),
      ),
      isEmpty,
    );
    await expectLater(
      bridge.records.createAnnotation(
        document: document,
        surface: _surface('text', resourcePath: 'a.xhtml'),
        unit: BigInt.zero,
        start: BigInt.zero,
        end: BigInt.one,
        displayScale: 1,
        color: FlutterHighlightColor.yellow,
        cancellationId: bridge.createCancellation(),
      ),
      throwsA(
        isA<FlutterBridgeError>().having(
          (error) => error.kind,
          'kind',
          FlutterBridgeErrorKind.invalidRequest,
        ),
      ),
    );
  });
}
