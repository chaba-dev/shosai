import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shosai_flutter/library/view.dart';
import 'package:shosai_flutter/src/rust/api.dart';
import 'package:shosai_flutter/theme_tokens.dart';

import '../support/production_shell_harness.dart';

/// Package 3B: the cover-first card and the responsive grid (LB-11 … LB-15).
///
/// The expectations are transcribed from the pinned Iced reference
/// (`render_book_card`, `widgets::book_button`, `Grid::fluid` at
/// `1e54270a6bb2`) and from the frozen tokens, not read back from the widget, so
/// a wrong mapping cannot agree with itself. Behavior and geometry are checked
/// here; the package's rendered states are captured and inspected in
/// `test/visual/library_cards_test.dart`.

/// The card's own title line, not the missing cover's placeholder copy.
Finder cardTitle(String title) => find.byWidgetPredicate(
  (widget) =>
      widget is Text &&
      widget.data == title &&
      widget.style?.fontSize == ShosaiTokens.typeSize13,
);

/// The card for [title].
Finder cardFor(String title) =>
    find.ancestor(of: cardTitle(title), matching: find.byType(LibraryBookCard));

/// A harness bridge that records what the card asked of it.
class _RecordingBridge extends HarnessBridge {
  _RecordingBridge({super.books, super.covers, this.hasMore = false});

  final List<int> coverRequests = <int>[];
  final List<int> removedBookIds = <int>[];
  int libraryPageCalls = 0;

  /// Whether the bridge reports another page, so the collection shows its
  /// load-more control.
  final bool hasMore;

  @override
  Future<Uint8List?> libraryCover({
    required int bookId,
    required BigInt cancellationId,
  }) {
    coverRequests.add(bookId);
    return super.libraryCover(bookId: bookId, cancellationId: cancellationId);
  }

  @override
  Future<FlutterLibraryRemoveOutcome> removeLibraryBook({required int bookId}) {
    removedBookIds.add(bookId);
    return super.removeLibraryBook(bookId: bookId);
  }

  @override
  Future<FlutterLibraryPage> libraryPage({
    String? query,
    FlutterBookFormat? format,
    required int limit,
    required int offset,
    required BigInt cancellationId,
  }) async {
    libraryPageCalls += 1;
    final page = await super.libraryPage(
      query: query,
      format: format,
      limit: limit,
      offset: offset,
      cancellationId: cancellationId,
    );
    return FlutterLibraryPage(books: page.books, hasMore: hasMore);
  }
}

/// A recording bridge whose removal stays in flight until the test releases it.
class _HeldRemovalBridge extends _RecordingBridge {
  _HeldRemovalBridge({super.books, super.covers});

  final Completer<FlutterLibraryRemoveOutcome> removal =
      Completer<FlutterLibraryRemoveOutcome>();

  @override
  Future<FlutterLibraryRemoveOutcome> removeLibraryBook({required int bookId}) {
    removedBookIds.add(bookId);
    return removal.future;
  }
}

Future<HarnessBridge> pumpLibrary(
  WidgetTester tester, {
  Size size = const Size(1280, 800),
  double textScale = 1,
  Locale? locale,
  List<FlutterLibraryBook>? books,
  Map<int, Uint8List>? covers,
  HarnessBridge? bridge,
  void Function(FlutterLibraryBook book)? onOpen,
  bool Function()? ready,
}) async {
  final effective =
      bridge ??
      _RecordingBridge(
        books: books ?? harnessLibraryBooks(),
        covers: covers ?? harnessCovers(),
      );
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await renderHarnessState(
    tester,
    productionShell(
      locale: locale,
      home: ProductShell(
        bridgeFactory: () => effective,
        readerBuilder: (_, book, _, _, _, _) {
          onOpen?.call(book);
          return const SizedBox();
        },
      ),
    ),
    ready: ready ?? () => harnessImagesReady(tester),
  );
  return effective;
}

void main() {
  setUpAll(loadHarnessFonts);

  group('grid sizing', () {
    test('the fluid column count is the pinned Iced formula', () {
      // `ceil((available + spacing) / (min_column + spacing))`, the strategy
      // `grid(...).fluid(220)` uses at the pinned reference.
      expect(libraryGridColumns(1048), 5, reason: '1280 wide: 5 columns');
      expect(libraryGridColumns(668), 3, reason: '900 wide: 3 columns');
      expect(libraryGridColumns(342), 2, reason: '390 compact: 2 columns');
      expect(libraryGridColumns(238), 2);
      expect(libraryGridColumns(220), 1);
      expect(libraryGridColumns(0), 1, reason: 'never zero columns');
      expect(libraryGridColumns(-1), 1);
    });

    testWidgets('the rendered grid divides the width equally', (tester) async {
      await pumpLibrary(tester);
      final wide = tester.getRect(find.byType(LibraryBookCard).first);
      expect(wide.width, closeTo(195.2, 0.6));
      expect(
        tester.getRect(find.byType(LibraryBookCard).at(1)).left - wide.left,
        closeTo(wide.width + ShosaiTokens.layoutLibraryGridSpacing, 0.6),
        reason: 'cards are one column plus the 18 px spacing apart',
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await pumpLibrary(tester, size: const Size(900, 700));
      expect(
        tester.getRect(find.byType(LibraryBookCard).first).width,
        closeTo(210.7, 0.6),
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await pumpLibrary(tester, size: const Size(390, 844));
      expect(
        tester.getRect(find.byType(LibraryBookCard).first).width,
        closeTo(162, 0.6),
      );
    });
  });

  group('card sizing', () {
    testWidgets('the tile keeps the reference height and its own text', (
      tester,
    ) async {
      await pumpLibrary(tester);
      final context = tester.element(find.byType(LibraryBookCard).first);
      final extent = libraryCardTileExtent(context);
      expect(
        extent,
        greaterThanOrEqualTo(ShosaiTokens.layoutLibraryCardHeight),
        reason: 'the pinned Iced card height is the floor',
      );
      expect(
        extent,
        lessThanOrEqualTo(ShosaiTokens.layoutLibraryCardHeight + 10),
        reason:
            'the tile only grows by the measured text: +6 for a Japanese '
            'two-line title box and +4 for its author box, both of which the '
            'reference clips inside its fixed 32/28 px boxes',
      );
      expect(
        tester.getRect(find.byType(LibraryBookCard).first).height,
        extent,
        reason: 'the painted card is exactly one tile',
      );
      expect(
        tester.getSize(find.byType(LibraryBookCover).first).height,
        ShosaiTokens.layoutLibraryCardCoverHeight,
        reason: 'LB-12: the cover box keeps the reference height',
      );
    });

    testWidgets('a scaled card grows its text, not its cover', (tester) async {
      await pumpLibrary(tester, size: const Size(390, 844), textScale: 2);
      final card = tester.getRect(find.byType(LibraryBookCard).first);
      final extent = libraryCardTileExtent(
        tester.element(find.byType(LibraryBookCard).first),
      );
      expect(card.height, extent);
      expect(
        card.height,
        greaterThan(ShosaiTokens.layoutLibraryCardHeight + 50),
        reason: 'the scaled text block needs the room',
      );
      expect(
        tester.getSize(find.byType(LibraryBookCover).first).height,
        ShosaiTokens.layoutLibraryCardCoverHeight,
        reason: 'the cover keeps its reference height at 200% text',
      );
    });

    testWidgets('the cover sits above the title, author, status and bar', (
      tester,
    ) async {
      await pumpLibrary(tester);
      final card = tester.getRect(find.byType(LibraryBookCard).first);
      final cover = tester.getRect(find.byType(LibraryBookCover).first);
      final title = tester.getRect(cardTitle('The Quiet Cartographer'));
      final author = tester.getRect(find.text('Ada Lovelace'));
      final status = tester.getRect(find.text('42%'));
      final progress = tester.getRect(
        find.descendant(
          of: find.byType(LibraryBookCard).first,
          matching: find.byType(ShadProgress),
        ),
      );
      expect(cover.top, card.top + ShosaiTokens.layoutButtonBookPadding);
      expect(cover.width, closeTo(card.width - 16, 0.6));
      expect(title.top, greaterThan(cover.bottom));
      expect(author.top, greaterThan(title.top));
      expect(status.top, greaterThan(author.top));
      expect(progress.top, greaterThanOrEqualTo(status.bottom));
      expect(progress.bottom, lessThanOrEqualTo(card.bottom));
      expect(
        progress.height,
        ShosaiTokens.layoutProgressGirth,
        reason: 'the reference progress bar girth',
      );
    });

    testWidgets('the reference type sizes carry the card hierarchy', (
      tester,
    ) async {
      await pumpLibrary(tester);
      for (final (text, size) in <(String, double)>[
        ('The Quiet Cartographer', ShosaiTokens.typeSize13),
        ('Ada Lovelace', ShosaiTokens.typeSize11),
        ('42%', ShosaiTokens.typeSize10),
        ('EPUB', ShosaiTokens.typeSize10),
      ]) {
        final paragraph = tester.renderObject<RenderParagraph>(
          find.descendant(
            of: find.byType(LibraryBookCard).first,
            matching: find.text(text),
          ),
        );
        expect(paragraph.text.style?.fontSize, size, reason: text);
      }
    });
  });

  group('reading status', () {
    testWidgets('zero progress reads as not started, above it as a percent', (
      tester,
    ) async {
      await pumpLibrary(
        tester,
        books: const [
          FlutterLibraryBook(
            bookId: 1,
            title: 'Started',
            author: 'A',
            format: FlutterBookFormat.epub,
            pathKey: '/books/a.epub',
            managed: true,
            progress: 0.42,
            dateAdded: '2026-09-10',
          ),
          FlutterLibraryBook(
            bookId: 2,
            title: 'Untouched',
            author: 'B',
            format: FlutterBookFormat.pdf,
            pathKey: '/books/b.pdf',
            managed: true,
            progress: 0,
            dateAdded: '2026-09-10',
          ),
        ],
      );
      expect(find.text('42%'), findsOneWidget);
      expect(find.text('Not started'), findsOneWidget);
    });

    testWidgets('the Japanese catalog supplies the status text', (
      tester,
    ) async {
      await pumpLibrary(
        tester,
        locale: const Locale('ja'),
        books: const [
          FlutterLibraryBook(
            bookId: 2,
            title: '短い',
            author: '芥川龍之介',
            format: FlutterBookFormat.epub,
            pathKey: '/books/b.epub',
            managed: true,
            progress: 0,
            dateAdded: '2026-09-10',
          ),
        ],
      );
      expect(find.text('未読'), findsOneWidget);
      expect(find.text('Not started'), findsNothing);
      expect(find.byTooltip('本の操作'), findsOneWidget);
      expect(find.byTooltip('Book actions'), findsNothing);
    });

    testWidgets('a book without an author reads as unknown', (tester) async {
      await pumpLibrary(
        tester,
        books: const [
          FlutterLibraryBook(
            bookId: 3,
            title: 'Anonymous Work',
            format: FlutterBookFormat.cbz,
            pathKey: '/books/c.cbz',
            managed: false,
            progress: 0.1,
            dateAdded: '2026-09-10',
          ),
        ],
      );
      expect(find.text('Unknown author'), findsOneWidget);
    });
  });

  group('covers', () {
    testWidgets('a missing cover shows the title placeholder in its box', (
      tester,
    ) async {
      // Longer than the reference's twenty-character cut, so restoring that
      // truncation (finding F8) fails this test.
      const title = 'A Book With No Cover At All';
      await pumpLibrary(
        tester,
        books: const [
          FlutterLibraryBook(
            bookId: 5,
            title: title,
            author: 'Anonymous',
            format: FlutterBookFormat.pdf,
            pathKey: '/books/e.pdf',
            managed: true,
            progress: 0,
            dateAdded: '2026-09-10',
          ),
        ],
        covers: const {},
        ready: () => find.byType(LibraryBookCard).evaluate().isNotEmpty,
      );
      final cover = tester.getRect(find.byType(LibraryBookCover));
      expect(cover.height, ShosaiTokens.layoutLibraryCardCoverHeight);
      expect(find.byType(Image), findsNothing);
      // The placeholder carries the whole title, not a prefix of it.
      final placeholder = find.descendant(
        of: find.byType(LibraryBookCover),
        matching: find.text(title),
      );
      expect(placeholder, findsOneWidget);
      final paragraph = tester.renderObject<RenderParagraph>(placeholder);
      expect(paragraph.didExceedMaxLines, isFalse);
      expect(paragraph.text.toPlainText(), title);
      expect(cover.contains(tester.getRect(placeholder).topLeft), isTrue);
    });

    testWidgets('a cover paints with the reference semantics label', (
      tester,
    ) async {
      await pumpLibrary(tester, covers: {1: harnessCovers()[1]!});
      expect(find.byType(Image), findsOneWidget);
      expect(
        find.bySemanticsLabel('Cover of The Quiet Cartographer'),
        findsOneWidget,
      );
    });

    testWidgets('covers load lazily and stay bounded', (tester) async {
      final books = List.generate(
        120,
        (index) => FlutterLibraryBook(
          bookId: index + 1,
          title: 'Book ${index + 1}',
          author: 'Author',
          format: FlutterBookFormat.epub,
          pathKey: '/books/$index.epub',
          managed: true,
          progress: 0.1,
          dateAdded: '2026-09-10',
        ),
      );
      final bridge =
          await pumpLibrary(
                tester,
                size: const Size(700, 500),
                books: books,
                covers: {
                  for (var index = 1; index <= 120; index += 1)
                    index: deterministicPng(width: 24, height: 32, seed: index),
                },
              )
              as _RecordingBridge;
      // Only the visible cards asked for a cover; the grid did not build the
      // 120-book list.
      expect(bridge.coverRequests, isNotEmpty);
      expect(
        bridge.coverRequests.length,
        lessThan(60),
        reason: 'the grid did not build, and did not request, 120 covers',
      );
      expect(bridge.coverRequests, contains(1));
      expect(bridge.coverRequests, isNot(contains(120)));
    });
  });

  group('long metadata', () {
    testWidgets('a long Japanese title wraps inside its two-line cap', (
      tester,
    ) async {
      await pumpLibrary(tester, size: const Size(390, 844));
      final title = cardTitle('海辺の図書館 — 失われた書架をめぐる長い旅路');
      final paragraph = tester.renderObject<RenderParagraph>(title);
      // Two lines of the taller Japanese line box, fully painted: the
      // reference's fixed 32 px box cuts this title mid-glyph (finding F8).
      expect(paragraph.didExceedMaxLines, isFalse);
      expect(
        paragraph.size.height,
        greaterThan(2 * ShosaiTokens.typeSize13),
        reason: 'the title uses both of its lines',
      );
      final card = tester.getRect(cardFor('海辺の図書館 — 失われた書架をめぐる長い旅路'));
      final rect = tester.getRect(title);
      expect(card.contains(rect.topLeft), isTrue);
      expect(rect.bottom, lessThanOrEqualTo(card.bottom));
      final defects = await findRenderDefects(tester);
      expectOnlyKnownDefects(defects, const <KnownRenderDefect>[]);
    });

    testWidgets('an unbreakable token truncates instead of overflowing', (
      tester,
    ) async {
      await pumpLibrary(tester);
      final paragraph = tester.renderObject<RenderParagraph>(
        cardTitle(
          'Donaudampfschifffahrtsgesellschaftskapitaenskajuettenfenster',
        ),
      );
      expect(paragraph.didExceedMaxLines, isTrue);
      expect(
        tester
            .getRect(
              cardFor(
                'Donaudampfschifffahrtsgesellschaftskapitaenskajuettenfenster',
              ),
            )
            .width,
        closeTo(195.2, 0.6),
        reason: 'the long token does not widen the card',
      );
    });

    testWidgets('200% text keeps the status readable in a narrow column', (
      tester,
    ) async {
      await pumpLibrary(
        tester,
        size: const Size(390, 844),
        textScale: 2,
        books: const [
          FlutterLibraryBook(
            bookId: 2,
            title: '海辺の図書館 — 失われた書架をめぐる長い旅路',
            author: '紫式部',
            format: FlutterBookFormat.epub,
            pathKey: '/books/umibe.epub',
            managed: true,
            progress: 0.07,
            dateAdded: '2026-09-11',
          ),
          FlutterLibraryBook(
            bookId: 5,
            title: 'Untouched',
            author: 'Anonymous',
            format: FlutterBookFormat.pdf,
            pathKey: '/books/no-cover.pdf',
            managed: true,
            progress: 0,
            dateAdded: '2026-09-14',
          ),
        ],
      );
      // The longest status labels stay fully painted: the row wraps into runs
      // rather than ellipsizing the reading status.
      for (final status in ['7%', 'Not started']) {
        final paragraph = tester.renderObject<RenderParagraph>(
          find.text(status),
        );
        expect(paragraph.didExceedMaxLines, isFalse, reason: status);
        final card = tester.getRect(
          find.ancestor(
            of: find.text(status),
            matching: find.byType(LibraryBookCard),
          ),
        );
        expect(
          card.contains(tester.getRect(find.text(status)).topLeft),
          isTrue,
        );
      }
      final defects = await findRenderDefects(tester);
      expectOnlyKnownDefects(defects, const <KnownRenderDefect>[]);
    });

    testWidgets('a scaled pending card keeps its chip inside the tile', (
      tester,
    ) async {
      final bridge = _HeldRemovalBridge(
        books: harnessLibraryBooks(),
        covers: harnessCovers(),
      );
      await pumpLibrary(
        tester,
        size: const Size(390, 844),
        textScale: 2,
        bridge: bridge,
      );

      // Book 1 is managed, so the removal goes through the confirmation the
      // application renders; the confirmation is what starts the pending state.
      await tester.tap(find.byTooltip('Book actions').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove and delete copy'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Remove and delete'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      const title = 'The Quiet Cartographer';
      final card = tester.getRect(cardFor(title));
      final chip = tester.getRect(find.text('Removing…'));
      final progress = tester.getRect(
        find.descendant(
          of: cardFor(title),
          matching: find.byType(ShadProgress),
        ),
      );
      // The chip is a decorated run of its own at this scale, so the tile's
      // reservation has to include its padding and border.
      expect(card.contains(chip.topLeft), isTrue);
      expect(card.contains(chip.bottomRight), isTrue);
      expect(progress.bottom, lessThanOrEqualTo(card.bottom));
      final defects = await findRenderDefects(tester);
      expectOnlyKnownDefects(defects, const <KnownRenderDefect>[]);

      bridge.removal.complete(
        const FlutterLibraryRemoveOutcome(
          removed: true,
          managedFileDeletionPending: false,
        ),
      );
      await tester.pumpAndSettle();
    });
  });

  group('actions', () {
    testWidgets('a card opens by activation and by keyboard', (tester) async {
      final opened = <FlutterLibraryBook>[];
      await pumpLibrary(tester, onOpen: opened.add);
      await tester.tap(find.byType(LibraryBookCard).first);
      await tester.pumpAndSettle();
      expect(opened.map((book) => book.bookId), [1]);

      // The card is a real button: Enter activates it too.
      await tester.pumpWidget(const SizedBox.shrink());
      opened.clear();
      await pumpLibrary(tester, onOpen: opened.add);
      final title = cardTitle('The Quiet Cartographer');
      for (var step = 0; step < 20; step += 1) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        if (tester
                .getSemantics(title)
                .getSemanticsData()
                .flagsCollection
                .isFocused ==
            ui.Tristate.isTrue) {
          break;
        }
      }
      expect(
        tester.getSemantics(title).getSemanticsData().flagsCollection.isFocused,
        ui.Tristate.isTrue,
        reason: 'the card takes keyboard focus',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(opened.map((book) => book.bookId), [1]);
    });

    testWidgets('the overflow action removes the book it belongs to', (
      tester,
    ) async {
      final bridge = await pumpLibrary(tester) as _RecordingBridge;
      await tester.tap(find.byTooltip('Book actions').at(2));
      await tester.pumpAndSettle();
      // Book 3 is unmanaged, so the reference's remove action applies directly.
      expect(find.text('Remove from library'), findsOneWidget);
      await tester.tap(find.text('Remove from library'));
      await tester.pumpAndSettle();
      expect(bridge.removedBookIds, [3]);
    });

    testWidgets('a managed book offers the delete-copy action', (tester) async {
      await pumpLibrary(tester);
      await tester.tap(find.byTooltip('Book actions').first);
      await tester.pumpAndSettle();
      expect(find.text('Remove and delete copy'), findsOneWidget);
      expect(find.text('Remove from library'), findsNothing);
    });

    testWidgets('the menu action stays readable at 200% text', (tester) async {
      await pumpLibrary(
        tester,
        size: const Size(390, 844),
        textScale: 2,
        locale: const Locale('ja'),
      );
      await tester.tap(find.byTooltip('本の操作').first);
      await tester.pumpAndSettle();

      final action = find.text('コピーも削除');
      expect(action, findsOneWidget);
      final paragraph = tester.renderObject<RenderParagraph>(action);
      expect(
        paragraph.didExceedMaxLines,
        isFalse,
        reason: 'a scaled action label is not cut',
      );
      final button = tester.getRect(
        find.ancestor(of: action, matching: find.byType(ShadButton)),
      );
      final label = tester.getRect(action);
      expect(button.contains(label.topLeft), isTrue);
      expect(button.contains(label.bottomRight), isTrue);
      final defects = await findRenderDefects(tester);
      expectOnlyKnownDefects(defects, const <KnownRenderDefect>[]);
    });

    testWidgets('a declined confirmation leaves no pending card', (
      tester,
    ) async {
      final bridge = await pumpLibrary(tester) as _RecordingBridge;
      await tester.tap(find.byTooltip('Book actions').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove and delete copy'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('Removing…'), findsNothing);
      expect(bridge.removedBookIds, isEmpty);
      expect(
        tester
            .widget<ShadButton>(
              find.ancestor(
                of: cardTitle('The Quiet Cartographer'),
                matching: find.byType(ShadButton),
              ),
            )
            .enabled,
        isTrue,
        reason: 'the card stays openable after a declined removal',
      );
    });

    testWidgets('a removal in flight shows its pending state', (tester) async {
      final bridge = _HeldRemovalBridge(
        books: harnessLibraryBooks(),
        covers: harnessCovers(),
      );
      await pumpLibrary(tester, bridge: bridge);

      await tester.tap(find.byTooltip('Book actions').at(2));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove from library'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // The reference's pending state: the status chip, no action, no opening.
      expect(find.text('Removing…'), findsOneWidget);
      expect(find.byTooltip('Book actions'), findsNWidgets(5));
      final card = tester.widget<LibraryBookCard>(
        cardFor('Donaudampfschifffahrtsgesellschaftskapitaenskajuettenfenster'),
      );
      expect(card.removing, isTrue);
      final button = tester.widget<ShadButton>(
        find.descendant(
          of: find.byType(LibraryBookCard).at(2),
          matching: find.byType(ShadButton),
        ),
      );
      expect(button.enabled, isFalse, reason: 'a pending card cannot open');

      bridge.removal.complete(
        const FlutterLibraryRemoveOutcome(
          removed: true,
          managedFileDeletionPending: false,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Removing…'), findsNothing);
    });

    testWidgets('load more stays reachable below the grid', (tester) async {
      final bridge =
          await pumpLibrary(
                tester,
                bridge: _RecordingBridge(
                  books: harnessLibraryBooks(),
                  covers: harnessCovers(),
                  hasMore: true,
                ),
              )
              as _RecordingBridge;
      // The control sits below the grid, so it is reached by scrolling.
      final scrollable = find.descendant(
        of: find.byType(LibraryCollection),
        matching: find.byType(Scrollable),
      );
      await tester.scrollUntilVisible(
        find.text('Load more books'),
        120,
        scrollable: scrollable,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Load more books'));
      await tester.pumpAndSettle();
      expect(bridge.libraryPageCalls, greaterThan(1));
    });
  });

  group('accessibility', () {
    testWidgets('the card is a button with the cover as its image', (
      tester,
    ) async {
      await pumpLibrary(tester);
      // The card is one button: its own title is inside the button's semantics
      // node, so the card is announced as a control rather than as loose text.
      // The card's button node is an ancestor of its title node.
      var isButton = false;
      SemanticsNode? node = tester.getSemantics(
        cardTitle('The Quiet Cartographer'),
      );
      while (node != null) {
        if (node.getSemanticsData().flagsCollection.isButton) {
          isButton = true;
          break;
        }
        node = node.parent;
      }
      expect(
        isButton,
        isTrue,
        reason: 'the title is inside the card button, not beside it',
      );
      expect(
        find.bySemanticsLabel('Cover of The Quiet Cartographer'),
        findsOneWidget,
      );
    });

    testWidgets('no render defects at the reference configurations', (
      tester,
    ) async {
      for (final (size, textScale, locale) in <(Size, double, Locale)>[
        (const Size(1280, 800), 1, Locale('en')),
        (const Size(1280, 800), 1, Locale('ja')),
        (const Size(390, 844), 2, Locale('ja')),
        (const Size(390, 844), 2, Locale('en')),
        (const Size(900, 700), 2, Locale('ja')),
      ]) {
        await tester.pumpWidget(const SizedBox.shrink());
        await pumpLibrary(
          tester,
          size: size,
          textScale: textScale,
          locale: locale,
        );
        final defects = await findRenderDefects(tester);
        expectOnlyKnownDefects(defects, const <KnownRenderDefect>[]);
        expect(
          tester.takeException(),
          isNull,
          reason: '$size at ${textScale}x ${locale.languageCode}',
        );
      }
    });
  });
}
