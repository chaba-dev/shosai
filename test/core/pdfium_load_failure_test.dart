// pdfrx loads PDFium once per process, and `flutter test` runs each test file
// in its own process, so this file keeps the missing library away from every
// test that needs a working PDFium.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart' as pdfrx;
import 'package:shosai_flutter/core/core_records.dart';
import 'package:shosai_flutter/reader/pdf/pdfrx_engine.dart';

const _epubFixture = 'packages/shosai_core/test/fixtures/sample.epub';
const _pdfFixture = 'packages/shosai_core/test/fixtures/sample.pdf';

void main() {
  test(
    'a PDFium library that fails to load fails only the PDF import',
    () async {
      final directory = Directory.systemTemp.createTempSync('shosai_pdfium');
      addTearDown(() => directory.deleteSync(recursive: true));
      final missing = '${directory.path}/libpdfium-missing.so';
      // The same override PDFIUM_PATH and SHOSAI_PDFIUM_LIBRARY set; the
      // engine keeps a module path that is already set.
      pdfrx.Pdfrx.pdfiumModulePath = missing;
      final core = await ShosaiCore.open(
        directory.path,
        pdfEngine: PdfrxPdfEngine(),
      );
      addTearDown(core.close);
      final bridge = ApplicationBridge(core);
      final paths = [
        for (final (fixture, name) in [
          (_epubFixture, 'first.epub'),
          (_pdfFixture, 'sample.pdf'),
          (_epubFixture, 'second.epub'),
        ])
          File(fixture).copySync('${directory.path}/$name').path,
      ];

      final report = await bridge.importPaths(
        pathKeys: paths,
        managed: false,
        cancellationId: bridge.createCancellation(),
      );

      expect(report.imported, BigInt.two);
      expect(report.failed, BigInt.one);
      expect(report.items[0].book, isNotNull);
      expect(report.items[1].book, isNull);
      expect(report.items[1].error, contains('libpdfium-missing.so'));
      expect(report.items[2].book, isNotNull);
    },
    // pdfrx_engine 0.4.5's worker never answered a callback that threw, so
    // the import waited forever.
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
