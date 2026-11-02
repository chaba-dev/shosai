import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_flutter/core/bridge.dart';
import 'package:shosai_flutter/reader/controller.dart' show ReaderPlace;
import 'package:shosai_flutter/reader/epub/content.dart';
import 'package:shosai_flutter/reader/view.dart';

import '../support/epub_navigation_fixture.dart';
import '../support/production_shell_harness.dart';

/// A paginated EPUB numbers its pages from the start of the book, not the
/// start of each chapter (decided 2026-10-30): the chapters before the page
/// are counted in the background at the reader's layout.
void main() {
  String chapter(String title, int paragraphs) => [
    '<h1>$title</h1>',
    for (var index = 0; index < paragraphs; index += 1)
      '<p>Paragraph $index of $title runs on long enough to fill a few '
          'lines of the page, so the chapter takes several pages.</p>',
  ].join();

  HarnessBridge bridge(Map<String, String> chapters) {
    final harness = HarnessBridge(
      books: const [
        FlutterLibraryBook(
          bookId: 1,
          title: 'Numbered book',
          format: FlutterBookFormat.epub,
          pathKey: '/books/numbered.epub',
          managed: true,
          progress: 0,
          dateAdded: '2026-11-02',
        ),
      ],
      unitCount: chapters.length,
    );
    harness.epubBytes = buildTestEpub(
      chapters: chapters,
      nav: [
        '<ol>',
        for (final path in chapters.keys)
          '<li><a href="../Text/${path.split('/').last}">'
              '${path.split('/').last}</a></li>',
        '</ol>',
      ].join(),
    );
    return harness;
  }

  final book = {
    'OPS/Text/one.xhtml': chapter('One', 40),
    'OPS/Text/two.xhtml': chapter('Two', 40),
  };

  Future<void> settle(WidgetTester tester) async {
    for (var round = 0; round < 8; round += 1) {
      await pumpHarnessFrames(tester, frames: 4);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 120)),
      );
    }
  }

  Future<void> openReader(
    WidgetTester tester,
    HarnessBridge harness, {
    bool twoPages = false,
    ReaderPlace? place,
    Size size = const Size(1280, 800),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await renderHarnessState(
      tester,
      productionShell(
        home: ReaderScreen(
          bridge: harness,
          initialPath: '/books/numbered.epub',
          initialBookId: 1,
          initialPlace: place,
          initialSettings: harnessReaderSettings.copyWith(
            twoPages: twoPages,
            zonesHintDismissed: true,
          ),
          epubImageDecoder: (bytes) async => null,
        ),
      ),
      ready: () => harnessReaderPageReady(tester),
      maxRounds: 16,
    );
    await settle(tester);
  }

  Future<void> closeReader(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
  }

  ReaderEpubPage page(WidgetTester tester) {
    for (final paint in tester.widgetList<CustomPaint>(
      find.byType(CustomPaint),
    )) {
      if (paint.painter case final ReaderEpubPageContentPainter painter) {
        return painter.page;
      }
    }
    fail('no EPUB page was painted');
  }

  List<String> texts(WidgetTester tester, String key) => [
    for (final text in tester.widgetList<Text>(find.byKey(ValueKey(key))))
      text.data!,
  ];

  Future<void> turn(WidgetTester tester) async {
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await settle(tester);
  }

  testWidgets('page numbers run on from one chapter into the next', (
    tester,
  ) async {
    await openReader(tester, bridge(book));
    expect(texts(tester, 'reader-folio'), ['page 1']);
    expect(
      texts(tester, 'reader-running-head'),
      [''],
      reason: 'the book opens on a chapter opening',
    );

    var turns = 0;
    while (page(tester).unit == 0) {
      await turn(tester);
      turns += 1;
      expect(turns, lessThan(40), reason: 'the first chapter ends');
      if (page(tester).unit == 0) {
        expect(texts(tester, 'reader-folio'), ['page ${turns + 1}']);
        expect(texts(tester, 'reader-running-head').single, isNotEmpty);
      }
    }
    expect(turns, greaterThan(1), reason: 'the first chapter takes pages');
    expect(
      texts(tester, 'reader-folio'),
      ['page ${turns + 1}'],
      reason: 'the second chapter does not start again at page 1',
    );
    expect(
      texts(tester, 'reader-running-head'),
      [''],
      reason: 'a chapter opening still leaves the head quiet',
    );

    await turn(tester);
    expect(texts(tester, 'reader-folio'), ['page ${turns + 2}']);
    expect(texts(tester, 'reader-running-head').single, isNotEmpty);
    await closeReader(tester);
  });

  testWidgets('a cover alone is page 1 and the next spread pages 2 and 3', (
    tester,
  ) async {
    await openReader(
      tester,
      bridge({
        'OPS/Text/cover.xhtml': '<p>Cover</p>',
        'OPS/Text/one.xhtml': chapter('One', 40),
      }),
      twoPages: true,
    );
    expect(page(tester).facing, isNull, reason: 'the cover stands alone');
    expect(texts(tester, 'reader-folio'), ['page 1']);

    await turn(tester);
    expect(page(tester).unit, 1);
    expect(texts(tester, 'reader-folio'), ['page 2', 'page 3']);
    expect(
      texts(tester, 'reader-running-head'),
      ['', isNotEmpty],
      reason: 'the opening page is quiet; its facing page carries the head',
    );
    await closeReader(tester);
  });

  testWidgets('a page opened mid-book is numbered once earlier chapters are '
      'counted, and recounted at a new page size', (tester) async {
    const place = ReaderPlace(1);
    await openReader(tester, bridge(book), place: place);
    expect(page(tester).unit, 1);
    final wide = texts(tester, 'reader-folio').single;
    final wideNumber = int.parse(wide.substring('page '.length));
    expect(wideNumber, greaterThan(1));
    expect(
      find.text('page 1'),
      findsNothing,
      reason: 'never the chapter-relative number',
    );

    // Narrower pages hold less, so the first chapter takes more of them.
    tester.view.physicalSize = const Size(480, 800);
    await settle(tester);
    expect(page(tester).unit, 1);
    final narrow = texts(tester, 'reader-folio').single;
    expect(
      int.parse(narrow.substring('page '.length)),
      greaterThan(wideNumber),
    );
    await closeReader(tester);
  });
}
