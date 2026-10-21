import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shosai_flutter/core/bridge.dart';
import 'package:shosai_flutter/main.dart';
import 'package:shosai_flutter/reader/pdf/pdfrx_engine.dart';

/// Packaged-host check for the Dart core's native libraries.
///
/// Run on a desktop host (`flutter test integration_test/packaged_core_test.dart
/// -d linux`, or `-d macos`) with no `SHOSAI_PDFIUM_LIBRARY` or `PDFIUM_PATH`:
/// the application bundle supplies PDFium and SQLite, so this proves both
/// load there. The library import (cover rendering), the open and the reader's
/// own engine document all use the one PDFium in this process, the sharing
/// that crashed while the Rust core loaded a second user of the same image.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

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
    addTearDown(bridge.dispose);

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
    final document = await engine.open(pdf.path);
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
