import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shosai_flutter/library/view.dart';
import 'package:shosai_flutter/core/bridge.dart';
import 'package:shosai_flutter/shell/view.dart';

import '../support/bridge_pdf_engine.dart';
import '../support/production_shell_harness.dart';

/// Package 3C: the continue-reading section (`LB-16`).
///
/// The store picks the book (the core's library tests); the composition is
/// transcribed from the pinned Iced `render_continue_card`
/// (`app.rs:8048-8093`), not read back from the widget, so a wrong mapping
/// cannot agree with itself. Opening is
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
    super.notes,
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
  Finder continueTitle(String title) => find.descendant(
    of: find.byType(LibraryContinueCard),
    matching: find.byWidgetPredicate(
      (widget) =>
          widget is Text &&
          widget.data == title &&
          widget.style?.fontSize == 34,
    ),
  );

  /// The collection's own 22 px section head, not the sidebar's entry.
  Finder sectionTitle(String label) => find.byWidgetPredicate(
    (widget) =>
        widget is Text && widget.data == label && widget.style?.fontSize == 22,
  );

  /// The shelf card's own title line, not its generated cover's.
  Finder cardTitle(String title) => find.byElementPredicate(
    (element) =>
        element.widget is Text &&
        (element.widget as Text).data == title &&
        element.findAncestorWidgetOfExactType<LibraryBookCard>() != null &&
        element.findAncestorWidgetOfExactType<ShellGeneratedCover>() == null,
  );

  group('selection', () {
    // The store picks the book (shosai_core's library tests); the model
    // shows the one the last page reported.
    test('shows the book the store reports, whatever the shelf order', () {
      final model = LibraryModel(
        books: [
          _book(id: 1, title: 'A never opened book'),
          _resumable(2, 'Resumable'),
        ],
        sort: FlutterLibrarySort.title,
        continueReading: _resumable(3, 'Not on this page'),
        loaded: true,
      );

      expect(model.continueBook?.bookId, 3);
      expect(
        model.copyWith(continueReading: null).continueBook,
        isNull,
        reason: 'no book to continue means no hero, never a guess',
      );
    });

    test('a search or a format filter hides the section', () {
      final books = [_resumable(1, 'Resumable')];
      final continueReading = books.single;
      expect(
        LibraryModel(
          books: books,
          continueReading: continueReading,
          loaded: true,
        ).continueBook,
        isNotNull,
      );
      expect(
        LibraryModel(
          books: books,
          continueReading: continueReading,
          loaded: true,
          query: 'quiet',
        ).continueBook,
        isNull,
      );
      expect(
        LibraryModel(
          books: books,
          continueReading: continueReading,
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
              readerBuilder: (_, _, _, _, _, _, _) => const SizedBox(),
            ),
          ),
          ready: () => harnessImagesReady(tester),
        );

        // The hero: its kicker, the book, its place and Continue, then the
        // collection's own section head.
        expect(find.text('CONTINUE READING'), findsOneWidget);
        expect(continueTitle('Resumable'), findsOneWidget);
        expect(find.text('42% complete'), findsOneWidget);
        expect(find.text('Continue'), findsOneWidget);
        // The finished and never-opened books are not the hero.
        expect(continueTitle('Finished'), findsNothing);
        expect(continueTitle('Never opened'), findsNothing);
        // The continued book keeps its shelf card as well.
        expect(cardTitle('Resumable'), findsOneWidget);

        final kicker = tester.getRect(find.text('CONTINUE READING'));
        final hero = tester.getRect(find.byType(LibraryContinueCard));
        final section = tester.getRect(sectionTitle('All books'));
        final gridCard = tester.getRect(find.byType(LibraryBookCard).first);
        expect(hero.contains(kicker.topLeft), isTrue);
        expect(section.top, greaterThan(hero.bottom));
        expect(gridCard.top, greaterThan(section.bottom));
        expect(
          tester.getSize(
            find.descendant(
              of: find.byType(LibraryContinueCard),
              matching: find.byType(LibraryBookCover),
            ),
          ),
          const Size(168, 252),
          reason: 'the desktop hero cover is 168 px at 2:3',
        );
        final bar = tester.getRect(
          find.descendant(
            of: find.byType(LibraryContinueCard),
            matching: find.byType(ShellProgressBar),
          ),
        );
        expect(bar.height, 4);
        expect(bar.width, lessThanOrEqualTo(LibraryContinueCard.placeMaxWidth));

        // The hero's own Notes button opens the Notes place, not the book.
        final heroNotes = find.descendant(
          of: find.byType(LibraryContinueCard),
          matching: find.text('Notes'),
        );
        expect(heroNotes, findsOneWidget);
        await tester.tap(heroNotes);
        await tester.pumpAndSettle();
        expect(find.text('No notes yet'), findsOneWidget);
        expect(bridge.openedBooks, isEmpty);
      },
    );

    testWidgets('the hero quotes the latest note and counts the notes', (
      tester,
    ) async {
      Future<void> pump(Size size, Map<int, FlutterNotesSummary> notes) async {
        await tester.pumpWidget(const SizedBox());
        final bridge = _ContinueBridge(
          books: [_resumable(1, 'Resumable')],
          covers: harnessCovers(count: 1),
          notes: notes,
        );
        HarnessView(size: size).apply(tester);
        await renderHarnessState(
          tester,
          productionShell(
            locale: const Locale('en'),
            home: ProductShell(
              bridgeFactory: () => bridge,
              readerBuilder: (_, _, _, _, _, _, _) => const SizedBox(),
            ),
          ),
          ready: () => harnessImagesReady(tester),
        );
      }

      final hero = find.byType(LibraryContinueCard);
      Finder inHero(Finder finder) =>
          find.descendant(of: hero, matching: finder);
      const notes = {1: FlutterNotesSummary(count: 12, latest: 'A sea of ink')};

      await pump(const Size(1280, 800), notes);
      expect(inHero(find.text('“A sea of ink”')), findsOneWidget);
      final count = inHero(find.byType(ShellCount));
      expect(count, findsOneWidget);
      expect(
        find.descendant(of: count, matching: find.text('12')),
        findsOneWidget,
      );
      expectOnlyKnownDefects(
        await findRenderDefects(tester),
        const <KnownRenderDefect>[],
      );

      // A narrow tablet's compact hero drops the quote and keeps the count.
      await pump(const Size(720, 900), notes);
      expect(inHero(find.textContaining('A sea of ink')), findsNothing);
      expect(inHero(find.byType(ShellCount)), findsOneWidget);

      // Nothing to quote and nothing to count: no placeholder, no zero.
      await pump(const Size(1280, 800), const {});
      expect(inHero(find.textContaining('“')), findsNothing);
      expect(inHero(find.byType(ShellCount)), findsNothing);
    });

    testWidgets('the tablet hero buttons are touch targets', (tester) async {
      // docs/design-system.md: `touch-target` (44 px) on tablet; the buttons
      // still grow with the text instead of clipping it.
      for (final (textScale, desktop) in [
        (1.0, false),
        (2.0, false),
        (1.0, true),
      ]) {
        await tester.pumpWidget(const SizedBox());
        final bridge = _ContinueBridge(
          books: [_resumable(1, 'Resumable')],
          covers: harnessCovers(count: 1),
        );
        HarnessView(
          size: desktop ? const Size(1280, 800) : const Size(1024, 768),
          textScale: textScale,
        ).apply(tester);
        await renderHarnessState(
          tester,
          productionShell(
            locale: const Locale('en'),
            home: ProductShell(
              bridgeFactory: () => bridge,
              readerBuilder: (_, _, _, _, _, _, _) => const SizedBox(),
            ),
          ),
          ready: () => harnessImagesReady(tester),
        );
        for (final label in ['Continue', 'Notes']) {
          final button = find.ancestor(
            of: find.descendant(
              of: find.byType(LibraryContinueCard),
              matching: find.text(label),
            ),
            matching: find.byWidgetPredicate((widget) => widget is ShadButton),
          );
          final height = tester.getSize(button.first).height;
          if (desktop) {
            expect(height, lessThan(44), reason: '$label keeps pointer size');
          } else {
            expect(
              height,
              greaterThanOrEqualTo(44),
              reason: '$label at ${textScale}x',
            );
          }
        }
        expectOnlyKnownDefects(
          await findRenderDefects(tester),
          const <KnownRenderDefect>[],
        );
      }
    });

    testWidgets('the compact hero keeps both actions at 200% text', (
      tester,
    ) async {
      // A narrow tablet puts the hero below its 560 px compact width.
      for (final locale in const [Locale('en'), Locale('ja')]) {
        await tester.pumpWidget(const SizedBox());
        final bridge = _ContinueBridge(
          books: [_resumable(1, 'Resumable')],
          covers: harnessCovers(count: 1),
        );
        const HarnessView(size: Size(720, 900), textScale: 2).apply(tester);
        await renderHarnessState(
          tester,
          productionShell(
            locale: locale,
            home: ProductShell(
              bridgeFactory: () => bridge,
              readerBuilder: (_, _, _, _, _, _, _) => const SizedBox(),
            ),
          ),
          ready: () => harnessImagesReady(tester),
        );
        final hero = find.byType(LibraryContinueCard);
        expect(
          tester
              .getSize(
                find.descendant(
                  of: hero,
                  matching: find.byType(LibraryBookCover),
                ),
              )
              .width,
          72,
          reason: '$locale hero is compact',
        );
        final buttons = find.descendant(
          of: hero,
          matching: find.byWidgetPredicate((widget) => widget is ShadButton),
        );
        expect(buttons, findsNWidgets(2), reason: '$locale actions');
        final heroRect = tester.getRect(hero);
        for (final button in buttons.evaluate()) {
          final rect = tester.getRect(find.byWidget(button.widget));
          expect(
            rect.left >= heroRect.left && rect.right <= heroRect.right,
            isTrue,
            reason: '$locale action $rect inside the hero $heroRect',
          );
        }
        expectOnlyKnownDefects(
          await findRenderDefects(tester),
          const <KnownRenderDefect>[],
        );
      }
    });

    testWidgets('a nearly finished hero book does not read as complete', (
      tester,
    ) async {
      final bridge = _ContinueBridge(
        books: [_resumable(1, 'Nearly done', progress: 0.999)],
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
            readerBuilder: (_, _, _, _, _, _, _) => const SizedBox(),
          ),
        ),
        ready: () => harnessImagesReady(tester),
      );
      expect(continueTitle('Nearly done'), findsOneWidget);
      expect(find.text('99% complete'), findsOneWidget);
      expect(find.text('100% complete'), findsNothing);
    });

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
            readerBuilder: (_, _, _, _, _, _, _) => const SizedBox(),
          ),
        ),
        ready: () => harnessImagesReady(tester),
      );
      expect(find.byType(LibraryContinueCard), findsOneWidget);

      await tester.enterText(find.byType(ShadInput), 'Resumable');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      expect(find.byType(LibraryContinueCard), findsNothing);
      expect(find.text('CONTINUE READING'), findsNothing);
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
            readerBuilder: (_, book, _, _, _, _, _) {
              opened.add(book);
              return const SizedBox();
            },
          ),
        ),
        ready: () => harnessImagesReady(tester),
      );

      await tester.tap(
        find.descendant(
          of: find.byType(LibraryContinueCard),
          matching: find.text('Continue'),
        ),
      );
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

      await tester.tap(
        find.descendant(
          of: find.byType(LibraryContinueCard),
          matching: find.text('Continue'),
        ),
      );
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
