import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shosai_core/shosai_core.dart' as core;
import 'package:shosai_flutter/core/core_records.dart';
import 'package:shosai_flutter/library/view.dart';
import 'package:shosai_flutter/core/bridge.dart';
import 'package:shosai_flutter/main.dart';
import 'package:shosai_flutter/reader/pdf/pdfrx_engine.dart';

import 'library_progress_test.dart' as library_progress;

/// Packaged-host check for the Dart core's native libraries.
///
/// Run on a desktop host with no `SHOSAI_PDFIUM_LIBRARY` or `PDFIUM_PATH`
/// (`make test-packaged-linux` or `make test-packaged-macos`
/// unset both; CI runs each), or on an Android device or emulator
/// (`make test-packaged-android`): the application bundle supplies
/// PDFium and SQLite, so this proves both load there. The library import (cover
/// rendering), the open and the reader's own engine document all use the one
/// PDFium in this process, the sharing that crashed while the Rust core loaded
/// a second user of the same image.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  library_progress.main();

  testWidgets(
    'grouped EPUB and PDF share one highlight through the real engines',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync('shosai-editions-');
      final data = await ShosaiCore.open(
        directory.path,
        pdfEngine: PdfrxPdfEngine(),
      );
      final bridge = ApplicationBridge(data);
      addTearDown(() async {
        bridge.dispose();
        await bridge.drain();
        await data.close();
        directory.deleteSync(recursive: true);
      });
      final epub = File('${directory.path}/hello.epub')
        ..writeAsBytesSync(_helloEpub());
      final pdf = File('${directory.path}/hello.pdf')
        ..writeAsBytesSync(_helloPdf());
      final imported = await bridge.importPaths(
        pathKeys: [epub.path, pdf.path],
        managed: false,
        cancellationId: bridge.createCancellation(),
      );
      expect(imported.imported, BigInt.two);
      final shelf = core.LibraryEditions(data.store);
      final separate = (await shelf.page(sources: [])).editions;
      expect(
        separate.length,
        2,
        reason: 'Missing publication facts require confirmation',
      );
      await shelf.group(separate[1].id, separate[0].id, sources: []);
      final edition = (await shelf.page(sources: [])).editions.single;
      expect(edition.files.length, 2);
      final epubBook = imported.items
          .singleWhere((i) => i.book?.format == FlutterBookFormat.epub)
          .book!;
      final pdfBook = imported.items
          .singleWhere((i) => i.book?.format == FlutterBookFormat.pdf)
          .book!;
      final epubDocument = await bridge.openLibraryBook(
        bookId: epubBook.bookId,
        cancellationId: bridge.createCancellation(),
      );
      final pdfDocument = await bridge.openLibraryBook(
        bookId: pdfBook.bookId,
        cancellationId: bridge.createCancellation(),
      );
      final created = await bridge.createAnnotation(
        document: epubDocument.handle,
        unit: BigInt.zero,
        start: BigInt.zero,
        end: BigInt.from(5),
        displayScale: 1,
        color: FlutterHighlightColor.yellow,
        body: 'One thought, either format',
        cancellationId: bridge.createCancellation(),
      );
      final [mapped] = await bridge.listAnnotations(
        document: pdfDocument.handle,
        scale: 1,
        cancellationId: bridge.createCancellation(),
      );
      expect(mapped.id, created.id);
      expect(mapped.resolution, FlutterAnnotationResolution.recovered);
      expect(mapped.fragments, [(unit: 0, start: 0, end: 5)]);
      final reverse = await bridge.createAnnotation(
        document: pdfDocument.handle,
        unit: BigInt.zero,
        start: BigInt.zero,
        end: BigInt.from(5),
        displayScale: 1,
        color: FlutterHighlightColor.green,
        cancellationId: bridge.createCancellation(),
      );
      final inEpub = await bridge.listAnnotations(
        document: epubDocument.handle,
        scale: 1,
        cancellationId: bridge.createCancellation(),
      );
      expect(
        inEpub.singleWhere((a) => a.id == reverse.id).resolution,
        FlutterAnnotationResolution.recovered,
      );
      expect(
        (await data.annotations.libraryNotes()).books.single.notes.length,
        2,
      );
      bridge.releaseDocument(handle: epubDocument.handle);
      bridge.releaseDocument(handle: pdfDocument.handle);
      await tester.pumpWidget(
        ShosaiApp(productBridgeFactory: () => ApplicationBridge(data)),
      );
      for (
        var attempt = 0;
        attempt < 100 &&
            tester
                    .widgetList<LibraryCollection>(
                      find.byType(LibraryCollection),
                    )
                    .firstOrNull
                    ?.model
                    .editions ==
                null;
        attempt++
      ) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(
        tester
            .widget<LibraryCollection>(find.byType(LibraryCollection))
            .model
            .editions!
            .single
            .files
            .length,
        2,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('the packaged PDFium and SQLite serve import, open and render', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync('shosai-packaged-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final pdf = File('${directory.path}/hello.pdf')
      ..writeAsBytesSync(_helloPdf());

    final bridge = await createApplicationBridge(
      applicationSupportDirectory: () async => directory,
    );
    addTearDown(closeApplicationCores);

    final report = await bridge.importPaths(
      pathKeys: [pdf.path],
      managed: false,
      cancellationId: bridge.createCancellation(),
    );
    expect(report.imported, BigInt.one, reason: '${report.items}');
    final page = await bridge.libraryPage(
      limit: 10,
      offset: 0,
      cancellationId: bridge.createCancellation(),
    );
    final book = page.books.single;
    expect(book.format, FlutterBookFormat.pdf);
    final cover = await bridge.libraryCover(
      bookId: book.bookId,
      cancellationId: bridge.createCancellation(),
    );
    expect(cover, isNotNull, reason: 'the cover is the first page rendered');

    final summary = await bridge.openLibraryBook(
      bookId: book.bookId,
      cancellationId: bridge.createCancellation(),
    );
    expect(summary.logicalUnitCount, BigInt.one);

    final engine = PdfrxPdfEngine();
    // The reader's own engine document reads the bridge's verified snapshot.
    expect(summary.contentPath, isNotNull);
    final document = await engine.open(summary.contentPath!);
    addTearDown(document.dispose);
    final rendered = await document.render(0, 1);
    expect(rendered.width, greaterThan(0));
    expect(await document.pageText(0), contains('Hello'));
    expect(
      await bridge.searchDocument(
        document: summary.handle,
        query: 'hello',
        cancellationId: bridge.createCancellation(),
      ),
      hasLength(1),
    );
    expect(bridge.releaseDocument(handle: summary.handle), isTrue);
  });

  testWidgets('the packaged SQLite serves an EPUB import and open', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync('shosai-packaged-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final epub = File('${directory.path}/hello.epub')
      ..writeAsBytesSync(_helloEpub());

    final bridge = await createApplicationBridge(
      applicationSupportDirectory: () async => directory,
    );
    addTearDown(closeApplicationCores);

    final report = await bridge.importPaths(
      pathKeys: [epub.path],
      managed: false,
      cancellationId: bridge.createCancellation(),
    );
    expect(report.imported, BigInt.one, reason: '${report.items}');
    final page = await bridge.libraryPage(
      limit: 10,
      offset: 0,
      cancellationId: bridge.createCancellation(),
    );
    final book = page.books.single;
    expect(book.format, FlutterBookFormat.epub);
    expect(book.title, 'Packaged Hello');

    final summary = await bridge.openLibraryBook(
      bookId: book.bookId,
      cancellationId: bridge.createCancellation(),
    );
    expect(summary.logicalUnitCount, BigInt.one);
    expect(
      await bridge.searchDocument(
        document: summary.handle,
        query: 'hello',
        cancellationId: bridge.createCancellation(),
      ),
      hasLength(1),
    );
    expect(bridge.releaseDocument(handle: summary.handle), isTrue);
  });

  testWidgets('a highlight on a file opened directly survives closing the '
      'core and reopening the file', (tester) async {
    final directory = Directory.systemTemp.createTempSync('shosai-packaged-');
    addTearDown(() => directory.deleteSync(recursive: true));
    addTearDown(closeApplicationCores);
    final pdf = File('${directory.path}/hello.pdf')
      ..writeAsBytesSync(_helloPdf());
    final request = FlutterOpenRequest(localId: pdf.path, pathKey: pdf.path);
    Future<FlutterBridge> open() => createApplicationBridge(
      applicationSupportDirectory: () async => directory,
    );

    final bridge = await open();
    final document = await bridge.openDocument(
      request: request,
      cancellationId: bridge.createCancellation(),
    );
    expect(document.bookId, isNull);
    final created = await bridge.createAnnotation(
      document: document.handle,
      unit: BigInt.zero,
      start: BigInt.zero,
      end: BigInt.from(5),
      displayScale: 1,
      color: FlutterHighlightColor.yellow,
      body: 'packaged slice',
      cancellationId: bridge.createCancellation(),
    );
    expect(created.quote, 'Hello');
    expect(bridge.releaseDocument(handle: document.handle), isTrue);
    bridge.dispose();
    // Drains the bridges and closes the store; the next bridge reopens it.
    await closeApplicationCores();

    final reopenedBridge = await open();
    final reopened = await reopenedBridge.openDocument(
      request: request,
      cancellationId: reopenedBridge.createCancellation(),
    );
    final annotations = await reopenedBridge.listAnnotations(
      document: reopened.handle,
      scale: 1,
      cancellationId: reopenedBridge.createCancellation(),
    );
    expect(annotations, hasLength(1));
    expect(annotations.single.id, created.id);
    expect(annotations.single.resolution, FlutterAnnotationResolution.exact);
    expect(annotations.single.body, 'packaged slice');
    expect(reopenedBridge.releaseDocument(handle: reopened.handle), isTrue);
  });
}

/// A one-page PDF that says "Hello", with a correct cross-reference table.
List<int> _helloPdf() {
  const content = 'BT /F1 24 Tf 72 720 Td (Hello) Tj ET';
  final objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] '
        '/Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
    '<< /Length ${content.length} >>\nstream\n$content\nendstream',
  ];
  final out = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[];
  for (var i = 0; i < objects.length; i += 1) {
    offsets.add(out.length);
    out.write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
  }
  final xref = out.length;
  out.write('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n');
  for (final offset in offsets) {
    out.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  out.write(
    'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\n'
    'startxref\n$xref\n%%EOF\n',
  );
  return ascii.encode(out.toString());
}

/// A one-chapter EPUB 3 whose text says "Hello".
Uint8List _helloEpub() {
  const files = {
    'mimetype': 'application/epub+zip',
    'META-INF/container.xml':
        '<?xml version="1.0"?>'
        '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" '
        'version="1.0"><rootfiles><rootfile full-path="OPS/package.opf" '
        'media-type="application/oebps-package+xml"/></rootfiles></container>',
    'OPS/package.opf':
        '<?xml version="1.0"?>'
        '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" '
        'unique-identifier="id"><metadata '
        'xmlns:dc="http://purl.org/dc/elements/1.1/">'
        '<dc:identifier id="id">packaged-hello</dc:identifier>'
        '<dc:title>Packaged Hello</dc:title><dc:language>en</dc:language>'
        '</metadata><manifest>'
        '<item id="chapter" href="chapter.xhtml" '
        'media-type="application/xhtml+xml"/>'
        '<item id="nav" href="nav.xhtml" '
        'media-type="application/xhtml+xml" properties="nav"/>'
        '</manifest><spine><itemref idref="chapter"/></spine></package>',
    'OPS/chapter.xhtml':
        '<?xml version="1.0"?>'
        '<html xmlns="http://www.w3.org/1999/xhtml"><body>'
        '<p>Hello from the packaged host.</p></body></html>',
    'OPS/nav.xhtml':
        '<?xml version="1.0"?>'
        '<html xmlns="http://www.w3.org/1999/xhtml" '
        'xmlns:epub="http://www.idpf.org/2007/ops"><body>'
        '<nav epub:type="toc"><ol><li><a href="chapter.xhtml">Hello</a></li>'
        '</ol></nav></body></html>',
  };
  final archive = Archive();
  for (final entry in files.entries) {
    final bytes = Uint8List.fromList(utf8.encode(entry.value));
    archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}
