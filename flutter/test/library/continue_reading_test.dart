import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shosai_flutter/library/view.dart';
import 'package:shosai_flutter/src/rust/api.dart';
import 'package:shosai_flutter/theme_tokens.dart';

import '../support/production_shell_harness.dart';

/// Package 3C: the continue-reading section (`LB-16`).
///
/// The selection rule is transcribed from the pinned Iced
/// `continue_reading_book` (`crates/shosai-app/src/app.rs:7856-7866`) and the
/// composition from `render_continue_card` (`app.rs:8048-8093`), not read back
/// from the widget, so a wrong mapping cannot agree with itself. Opening is
/// asserted through the reader boundary: the durable saved position is
/// Rust-owned, so the library's contract is that the reader is asked for the
/// position of the book the card showed.
FlutterLibraryBook _book({
  required int id,
  required String title,
  double progress = 0,
  String? lastRead,
  String? author = 'Ada Lovelace',
}) => FlutterLibraryBook(
  bookId: id,
  title: title,
  author: author,
  format: FlutterBookFormat.pdf,
  pathKey: '/books/$id.pdf',
  managed: true,
  progress: progress,
  dateAdded: '2026-09-10',
  lastRead: lastRead,
);

/// A book with a reading history that is still unfinished.
FlutterLibraryBook _resumable(int id, String title, {double progress = 0.42}) =>
    _book(
      id: id,
      title: title,
      progress: progress,
      lastRead: '2026-09-19T08:12:00Z',
    );

/// The harness bridge with the reader requests recorded and the durable
/// position controllable.
class _ContinueBridge extends HarnessBridge {
  _ContinueBridge({
    required super.books,
    required super.covers,
    this.readingState,
  });

  /// The durable position every `loadReadingState` returns.
  final FlutterReadingState? readingState;

  final List<int> openedBooks = [];
  final List<int> readingStateBooks = [];
  final List<int> renderedPages = [];

  @override
  Future<FlutterDocumentSummary> openLibraryBook({
    required int bookId,
    required BigInt cancellationId,
  }) {
    openedBooks.add(bookId);
    return super.openLibraryBook(
      bookId: bookId,
      cancellationId: cancellationId,
    );
  }

  @override
  Future<FlutterReadingState?> loadReadingState({
    required int bookId,
    required BigInt cancellationId,
  }) {
    readingStateBooks.add(bookId);
    final durable = readingState;
    if (durable != null) return Future<FlutterReadingState?>.value(durable);
    return super.loadReadingState(
      bookId: bookId,
      cancellationId: cancellationId,
    );
  }

  @override
  Future<FlutterRenderedBuffer> renderPage({
    required FlutterDocumentHandle document,
    required BigInt page,
    required double scale,
    required BigInt cancellationId,
  }) {
    renderedPages.add(page.toInt());
    return super.renderPage(
      document: document,
      page: page,
      scale: scale,
      cancellationId: cancellationId,
    );
  }
}

void main() {
  setUpAll(loadHarnessFonts);

  /// The continue card's own 16 px title line, not a grid card's 13 px one.
  Finder continueTitle(String title) => find.byWidgetPredicate(
    (widget) =>
        widget is Text &&
        widget.data == title &&
        widget.style?.fontSize == ShosaiTokens.typeSize16,
  );

  /// The collection's own 18 px section title, not the sidebar's entry.
  Finder sectionTitle(String label) => find.byWidgetPredicate(
    (widget) =>
        widget is Text &&
        widget.data == label &&
        widget.style?.fontSize == ShosaiTokens.typeSize18,
  );

  /// The grid card's own 13 px title line.
  Finder cardTitle(String title) => find.byWidgetPredicate(
    (widget) =>
        widget is Text &&
        widget.data == title &&
        widget.style?.fontSize == ShosaiTokens.typeSize13,
  );

  group('selection', () {
    test(
      'picks the first unfinished previously-read book of the first page',
      () {
        final model = LibraryModel(
          books: [
            _book(id: 1, title: 'Never opened', progress: 0.9),
            _book(
              id: 2,
              title: 'Finished',
              progress: 1,
              lastRead: '2026-09-01',
            ),
            _resumable(3, 'Resumable'),
            _resumable(4, 'Later resumable', progress: 0.07),
          ],
          loaded: true,
        );

        expect(model.continueBook?.bookId, 3);
      },
    );

    test('skips a finished book and a book that was never opened', () {
      final finishedFirst = LibraryModel(
        books: [
          _book(id: 1, title: 'Finished', progress: 1, lastRead: '2026-09-01'),
          _book(id: 2, title: 'Never opened', progress: 0.5),
        ],
        loaded: true,
      );
      expect(finishedFirst.continueBook, isNull);

      // Progress just under completion still resumes; exactly complete does not.
      final nearlyDone = LibraryModel(
        books: [_resumable(1, 'Nearly done', progress: 0.999)],
        loaded: true,
      );
      expect(nearlyDone.continueBook?.bookId, 1);
    });

    test('a book beyond the first page never introduces the section', () {
      // 60 books: the eligible book sits past `libraryPageSize`.
      final books = List.generate(
        libraryPageSize + 10,
        (index) => index == libraryPageSize + 5
            ? _resumable(index + 1, 'Late resumable')
            : _book(id: index + 1, title: 'Book ${index + 1}'),
      );
      expect(LibraryModel(books: books, loaded: true).continueBook, isNull);

      final withinPage = [
        ...books.sublist(0, libraryPageSize - 1),
        _resumable(libraryPageSize, 'Last of the page'),
        ...books.sublist(libraryPageSize),
      ];
      expect(
        LibraryModel(books: withinPage, loaded: true).continueBook?.bookId,
        libraryPageSize,
      );
    });

    test('a search or a format filter hides the section', () {
      final books = [_resumable(1, 'Resumable')];
      expect(LibraryModel(books: books, loaded: true).continueBook, isNotNull);
      expect(
        LibraryModel(books: books, loaded: true, query: 'quiet').continueBook,
        isNull,
      );
      expect(
        LibraryModel(
          books: books,
          loaded: true,
          format: FlutterBookFormat.pdf,
        ).continueBook,
        isNull,
      );
    });
  });

  group('rendering', () {
    testWidgets(
      'shows the eligible book above the grid in the reference hierarchy',
      (tester) async {
        final bridge = _ContinueBridge(
          books: [
            _book(id: 1, title: 'Never opened', progress: 0.9),
            _book(
              id: 2,
              title: 'Finished',
              progress: 1,
              lastRead: '2026-09-01',
            ),
            _resumable(3, 'Resumable', progress: 0.42),
          ],
          covers: harnessCovers(),
        );
        const view = HarnessView(size: Size(1280, 800));
        view.apply(tester);
        await renderHarnessState(
          tester,
          productionShell(
            locale: const Locale('en'),
            home: ProductShell(
              bridgeFactory: () => bridge,
              readerBuilder: (_, _, _, _, _, _) => const SizedBox(),
            ),
          ),
          ready: () => harnessImagesReady(tester),
        );

        // The section: heading, the card, then the collection's own title.
        expect(find.text('Continue reading'), findsOneWidget);
        expect(continueTitle('Resumable'), findsOneWidget);
        expect(find.text('42% complete'), findsOneWidget);
        expect(find.text('Continue  ›'), findsOneWidget);
        // The finished and never-opened books are not the continue card.
        expect(continueTitle('Finished'), findsNothing);
        expect(continueTitle('Never opened'), findsNothing);
        // The continued book keeps its grid card as well.
        expect(cardTitle('Resumable'), findsOneWidget);

        final heading = tester.getRect(find.text('Continue reading'));
        final card = tester.getRect(find.byType(LibraryContinueCard));
        final section = tester.getRect(sectionTitle('All books'));
        final gridCard = tester.getRect(find.byType(LibraryBookCard).first);
        expect(card.top, greaterThan(heading.bottom));
        expect(section.top, greaterThan(card.bottom));
        expect(gridCard.top, greaterThan(section.bottom));
        expect(
          card.width,
          lessThanOrEqualTo(ShosaiTokens.layoutContinueCardMaxWidth),
        );
        expect(
          tester.getSize(
            find.descendant(
              of: find.byType(LibraryContinueCard),
              matching: find.byType(LibraryBookCover),
            ),
          ),
          const Size(
            ShosaiTokens.layoutContinueCardCoverWidth,
            ShosaiTokens.layoutContinueCardCoverHeight,
          ),
        );
        expect(
          tester
              .getRect(
                find.descendant(
                  of: find.byType(LibraryContinueCard),
                  matching: find.byType(ShadProgress),
                ),
              )
              .height,
          ShosaiTokens.layoutProgressGirth,
        );
      },
    );

    testWidgets('a search hides the section and titles the results', (
      tester,
    ) async {
      final bridge = _ContinueBridge(
        books: [_resumable(1, 'Resumable')],
        covers: harnessCovers(count: 1),
      );
      const view = HarnessView(size: Size(1280, 800));
      view.apply(tester);
      await renderHarnessState(
        tester,
        productionShell(
          locale: const Locale('en'),
          home: ProductShell(
            bridgeFactory: () => bridge,
            readerBuilder: (_, _, _, _, _, _) => const SizedBox(),
          ),
        ),
        ready: () => harnessImagesReady(tester),
      );
      expect(find.byType(LibraryContinueCard), findsOneWidget);

      await tester.enterText(find.byType(ShadInput), 'Resumable');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      expect(find.byType(LibraryContinueCard), findsNothing);
      expect(find.text('Continue reading'), findsNothing);
      expect(sectionTitle('Search results'), findsOneWidget);
    });
  });

  group('opening', () {
    testWidgets('the card dispatches the book it showed', (tester) async {
      final bridge = _ContinueBridge(
        books: [
          _resumable(7, 'Resumable'),
          _resumable(9, 'Second resumable', progress: 0.07),
        ],
        covers: {7: harnessCovers()[1]!},
      );
      final opened = <FlutterLibraryBook>[];
      const view = HarnessView(size: Size(1280, 800));
      view.apply(tester);
      await renderHarnessState(
        tester,
        productionShell(
          home: ProductShell(
            bridgeFactory: () => bridge,
            readerBuilder: (_, book, _, _, _, _) {
              opened.add(book);
              return const SizedBox();
            },
          ),
        ),
        ready: () => harnessImagesReady(tester),
      );

      await tester.tap(find.byType(LibraryContinueCard));
      await tester.pumpAndSettle();

      expect(opened.map((book) => book.bookId), [7]);
    });

    testWidgets("opens the reader at that book's durable saved position", (
      tester,
    ) async {
      final bridge = _ContinueBridge(
        books: [
          _book(id: 1, title: 'Finished', progress: 1, lastRead: '2026-09-01'),
          _resumable(7, 'Resumable'),
          _resumable(9, 'Second resumable', progress: 0.07),
        ],
        covers: harnessCovers(),
        // The durable position Rust would report for book 7: its third unit.
        readingState: FlutterReadingState(unit: BigInt.from(2), zoom: 1),
      );
      const view = HarnessView(size: Size(1280, 800));
      view.apply(tester);
      await renderHarnessState(
        tester,
        productionApp(bridgeFactory: () => bridge, locale: const Locale('en')),
        ready: () => harnessImagesReady(tester),
      );

      await tester.tap(find.byType(LibraryContinueCard));
      // The reader's own effects (document open, durable state, page raster)
      // complete on the real event loop, so the wait alternates real-async
      // windows with frame pumps until the page is rendered.
      for (var round = 0; round < 8; round += 1) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)),
        );
        await pumpHarnessFrames(tester, frames: 4);
        if (bridge.renderedPages.isNotEmpty) break;
      }

      // The reader was opened for the continued book — the first eligible one,
      // not the later resumable book — asked Rust for that book's durable
      // position, and rendered the page that position names.
      expect(bridge.openedBooks, [7]);
      expect(bridge.openedBooks, isNot(contains(9)));
      expect(bridge.readingStateBooks, [7]);
      expect(bridge.renderedPages, contains(2));
      expect(
        bridge.renderedPages,
        isNot(contains(0)),
        reason: "the reader did not fall back to the book's first page",
      );
    });
  });
}
