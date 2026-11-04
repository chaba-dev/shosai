import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shosai_flutter/core/bridge.dart';
import 'package:shosai_flutter/core/records.dart';
import 'package:shosai_flutter/library/view.dart';
import 'package:shosai_flutter/main.dart';
import 'package:shosai_flutter/shell/view.dart';

import '../test/support/epub_navigation_fixture.dart';
import '../test/support/production_shell_harness.dart' show revealReaderChrome;
import '../test/support/reference_documents.dart';

/// Production shell, reader, PDFium and SQLite. The filtered shelf reproduces
/// stale open-book metadata independently of the reported iPhone session.
/// SHOSAI_PROGRESS_ARTIFACTS saves review PNGs.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'reader progress reaches the Japanese library and filtered shelf',
    (tester) async {
      final directory = await Directory.systemTemp.createTemp(
        'shosai-progress-',
      );
      final owner = await applicationCoreOwner(
        applicationSupportDirectory: () async => directory,
      );
      final bridge = owner.bridge();
      final records = recordsOf(bridge);
      final pdf = File('${directory.path}/Thrift.pdf')
        ..writeAsBytesSync(referencePdf());
      final epub = File('${directory.path}/ResNet.epub')
        ..writeAsBytesSync(navigationEpub());
      await records.importPaths(
        pathKeys: [pdf.path, epub.path],
        managed: false,
        cancellationId: bridge.createCancellation(),
      );
      final books = (await records.libraryPage(
        limit: 10,
        offset: 0,
        cancellationId: bridge.createCancellation(),
      )).books;
      final book = books.singleWhere((b) => b.format == FlutterBookFormat.pdf);
      final unread = books.singleWhere(
        (b) => b.format == FlutterBookFormat.epub,
      );
      // An open tab and recorded progress are independent, including a tab
      // restored from a session with no recorded reading yet.
      await records.saveOpenBooks((
        books: [(book: unread, path: unread.pathKey, bookId: unread.bookId)],
        current: unread.bookId,
        reading: false,
      ));
      await records.saveReadingState(
        bookId: book.bookId,
        value: FlutterReadingState(unit: BigInt.zero, zoom: 1, progress: .13),
        unitCount: BigInt.from(3),
      );
      await records.saveReaderSettings(
        value: const FlutterReaderSettings(
          continuous: false,
          theme: 'light',
          epubFontSize: 18,
          epubLineSpacing: 1.6,
          pdfZoom: 0,
          twoPages: false,
          zonesHintDismissed: true,
        ),
      );
      final captureKey = GlobalKey();
      tester.view.physicalSize = const Size(430, 932);
      tester.view.devicePixelRatio = 1;
      await binding.setSurfaceSize(const Size(430, 932));
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        bridge.dispose();
        await closeApplicationCores();
        await directory.delete(recursive: true);
        await binding.setSurfaceSize(null);
        tester.view.reset();
      });
      await tester.pumpWidget(
        RepaintBoundary(
          key: captureKey,
          child: ShosaiApp(
            locale: const Locale('ja'),
            productBridgeFactory: owner.bridge,
          ),
        ),
      );

      Future<void> until(bool Function() ready) async {
        for (var i = 0; i < 400 && !ready(); i++) {
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(ready(), isTrue);
        await tester.pumpAndSettle();
      }

      Future<void> capture(String name) async {
        final artifacts = Platform.environment['SHOSAI_PROGRESS_ARTIFACTS'];
        if (artifacts == null) return;
        final boundary =
            captureKey.currentContext!.findRenderObject()
                as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 2);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        await Directory(artifacts).create(recursive: true);
        await File(
          '$artifacts/$name.png',
        ).writeAsBytes(data!.buffer.asUint8List());
      }

      bool libraryReady() {
        final collection = find.byType(LibraryCollection);
        if (collection.evaluate().isEmpty) return false;
        final model = tester.widget<LibraryCollection>(collection).model;
        return !model.loading && !model.busy;
      }

      Finder card() => find.byWidgetPredicate(
        (widget) =>
            widget is LibraryBookCard && widget.book.bookId == book.bookId,
      );
      PagePainter? page() => tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((paint) => paint.painter)
          .whereType<PagePainter>()
          .where((paint) => paint.image != null)
          .firstOrNull;
      Finder shelfStatus(String text) => find.descendant(
        of: find.byType(ShellReadingNowCards),
        matching: find.text(text),
      );

      await until(() => libraryReady() && card().evaluate().isNotEmpty);
      expect(
        find.descendant(of: card(), matching: find.text('13%')),
        findsOneWidget,
      );
      final unreadCard = find.byWidgetPredicate(
        (widget) =>
            widget is LibraryBookCard && widget.book.bookId == unread.bookId,
      );
      await until(
        () => find
            .descendant(of: unreadCard, matching: find.text('開いた本'))
            .evaluate()
            .isNotEmpty,
      );
      expect(
        find.descendant(of: unreadCard, matching: find.text('未読')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: unreadCard, matching: find.text('読書中')),
        findsNothing,
      );
      await capture('library-before');
      await tester.tap(card());
      await until(() => page() != null);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await until(() => page()?.currentUnit == 1);
      await revealReaderChrome(tester);
      await capture('reader-page-two');
      await tester.tap(find.byKey(const ValueKey('reader-header-back')));
      await until(libraryReady);
      expect(shelfStatus('67%'), findsOneWidget);
      expect(
        find.descendant(of: card(), matching: find.text('67%')),
        findsOneWidget,
      );
      await capture('library-after');

      // Keep the PDF open, but exclude it from the library's visible results.
      await tester.tap(find.text('EPUB').first);
      await until(() => libraryReady() && card().evaluate().isEmpty);
      expect(shelfStatus('67%'), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.byType(ShellReadingNowCards),
          matching: find.text('67%'),
        ),
      );
      await until(() => page() != null);
      expect(page()!.currentUnit, 1, reason: 'the saved position reopens');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await until(() => page()?.currentUnit == 2);
      await revealReaderChrome(tester);
      await tester.tap(find.byKey(const ValueKey('reader-header-back')));
      await until(libraryReady);
      final persisted = (await records.loadOpenBooks())!.books;
      expect(
        persisted
            .singleWhere((open) => open.book.bookId == book.bookId)
            .book
            .progress,
        1,
        reason: 'the reader saved the last page',
      );
      expect(
        persisted
            .singleWhere((open) => open.book.bookId == unread.bookId)
            .book
            .progress,
        0,
        reason: 'reading the PDF must not change the other tab',
      );
      expect(card(), findsNothing, reason: 'the EPUB filter is still active');
      expect(shelfStatus('読了'), findsOneWidget);
      expect(shelfStatus('67%'), findsNothing);
      await capture('filtered-library-after');
    },
  );
}
