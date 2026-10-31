import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_epub/shosai_epub.dart';
import 'package:shosai_flutter/reader/epub/flow.dart';
import 'package:shosai_flutter/reader/epub/pages.dart';
import 'package:shosai_flutter/reader/controller.dart'
    show ReaderPlace, ReaderPlaceRequests;
import 'package:shosai_flutter/reader/view.dart';
import 'package:shosai_flutter/core/bridge.dart';

import '../support/epub_navigation_fixture.dart';
import '../support/production_shell_harness.dart';

/// Reader-level page-step contract over tables whose cells carry no mapped
/// canonical content (the 2026-10-02 real-book finding: PageDown skipped
/// pages, jumped backward and cycled on real chapters with such tables).
///
/// The fixture archive is parsed by the real engine and read by the
/// production `ReaderScreen` over the deterministic harness bridge; the page
/// steps here are the production ones (`ReaderPageStepRequested` through the
/// reader's own page-turn affordances and the PageDown/PageUp shortcuts).
/// The unit-level invariants live in `epub_table_page_anchor_repro_test.dart`;
/// this file exercises the controller itself: monotone forward walking,
/// backward walking that revisits the same pages, and durable restore of an
/// empty-row page through the production reopen path.

/// The harness bridge with a controllable durable position.
class _AnchorBridge extends HarnessBridge {
  _AnchorBridge({
    required super.books,
    required super.unitCount,
    this.readingState,
  });

  /// The durable position every `loadReadingState` returns.
  final FlutterReadingState? readingState;

  /// How many times the reader asked this bridge for the durable state.
  int loadReadingStateCalls = 0;

  /// The book ids of those asks, in call order.
  final List<int> loadReadingStateBookIds = <int>[];

  @override
  Future<FlutterReadingState?> loadReadingState({
    required int bookId,
    required BigInt cancellationId,
  }) async {
    loadReadingStateCalls += 1;
    loadReadingStateBookIds.add(bookId);
    return readingState;
  }
}

void main() {
  final bytes = pageAnchorEpub();
  final book = openEpubBytes(bytes);
  final emptyBytes = buildTestEpub(
    chapters: {
      'OPS/Text/chapter-1.xhtml': '<main></main>',
      'OPS/Text/chapter-2.xhtml': '<p>After the empty chapter.</p>',
    },
    nav:
        '<ol>'
        '<li><a href="../Text/chapter-1.xhtml">Empty chapter</a></li>'
        '<li><a href="../Text/chapter-2.xhtml">Next chapter</a></li>'
        '</ol>',
  );
  final emptyBook = openEpubBytes(emptyBytes);

  // The chapter under test must actually contain a row whose cells are all
  // empty after the real parse; otherwise this fixture would not exercise
  // the contract.
  final chapter = book.chapters.first;
  final hasEmptyRow = chapter.blocks.any(
    (block) =>
        block is EpubTable &&
        block.rowGroups.any(
          (group) => group.rows.any(
            (row) =>
                row.cells.isNotEmpty &&
                row.cells.every((cell) => cell.children.isEmpty),
          ),
        ),
  );
  if (!hasEmptyRow) {
    throw StateError('the fixture has no fully empty row after the real parse');
  }

  // The routing gate asks the reader for the bundled faces' coverage; these
  // tests answer with the shipped faces' own cmap tables, so the decision

  _AnchorBridge bridge({FlutterReadingState? readingState}) {
    final harness = _AnchorBridge(
      books: const [
        FlutterLibraryBook(
          bookId: 1,
          title: 'Reader Page Anchor',
          format: FlutterBookFormat.epub,
          pathKey: '/books/page-anchor.epub',
          managed: true,
          progress: 0,
          dateAdded: '2026-10-01',
        ),
      ],
      unitCount: 2,
      readingState: readingState,
    );
    harness.epubBytes = bytes;
    return harness;
  }

  _AnchorBridge emptyBridge() {
    final harness = _AnchorBridge(
      books: const [
        FlutterLibraryBook(
          bookId: 1,
          title: 'Empty Chapter',
          format: FlutterBookFormat.epub,
          pathKey: '/books/page-anchor.epub',
          managed: true,
          progress: 0,
          dateAdded: '2026-10-23',
        ),
      ],
      unitCount: 2,
      readingState: FlutterReadingState(
        unit: BigInt.one,
        offset: BigInt.zero,
        zoom: 1,
      ),
    );
    harness.epubBytes = emptyBytes;
    return harness;
  }

  Future<void> openReader(
    WidgetTester tester,
    _AnchorBridge harness, {
    ui.Size? size,
    void Function(ChapterLayoutSession)? sessionObserver,
  }) async {
    if (size != null) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }
    await renderHarnessState(
      tester,
      productionShell(
        home: ReaderScreen(
          bridge: harness,
          initialPath: '/books/page-anchor.epub',
          initialBookId: 1,
          initialSettings: harnessReaderSettings,
          epubImageDecoder: (bytes) async => null,
          debugEpubSessionObserver: sessionObserver,
        ),
      ),
      ready: () => harnessReaderPageReady(tester),
      maxRounds: 16,
    );
  }

  ReaderEpubPageContentPainter? dartPage(WidgetTester tester) {
    for (final paint in tester.widgetList<CustomPaint>(
      find.byType(CustomPaint),
    )) {
      final painter = paint.painter;
      if (painter is ReaderEpubPageContentPainter) return painter;
    }
    return null;
  }

  /// Alternates frame pumps with real-event-loop windows so native
  /// completions (open, engine parse, layout) can arrive and settle.
  Future<void> settleNative(WidgetTester tester, {int rounds = 4}) async {
    for (var round = 0; round < rounds; round += 1) {
      await pumpHarnessFrames(tester, frames: 4);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 120)),
      );
    }
    await pumpHarnessFrames(tester, frames: 4);
  }

  /// Pumps until the installed Dart page stops changing size.
  Future<void> settleEpubPage(WidgetTester tester) async {
    ui.Size? previous;
    for (var round = 0; round < 16; round += 1) {
      await settleNative(tester, rounds: 1);
      final page = dartPage(tester);
      if (page == null) return;
      final size = page.page.box.size;
      if (size == previous) return;
      previous = size;
    }
  }

  /// Steps forward through chapter one, recording each painted page's durable
  /// canonical start. With [maxSteps], stops after that many steps (the walk
  /// must still be inside the chapter); without it, stops when the reader
  /// leaves the chapter — but a walk that cycles forever hits the cap and
  /// fails the monotonicity assertion instead of hanging the test.
  Future<List<int>> walkForward(WidgetTester tester, {int? maxSteps}) async {
    final chapterUnit = book.chapters.first.spine;
    final starts = <int>[dartPage(tester)!.page.canonicalStart];
    final cap = maxSteps ?? 60;
    for (var step = 0; step < cap; step += 1) {
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await settleEpubPage(tester);
      final page = dartPage(tester)!;
      if (page.page.unit != chapterUnit) {
        if (maxSteps == null) break;
        fail('the fixture chapter spans fewer than $maxSteps steps');
      }
      starts.add(page.page.canonicalStart);
    }
    return starts;
  }

  Future<void> closeReader(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
  }

  testWidgets('EPUB curl cancellation never saves a speculative position', (
    tester,
  ) async {
    final harness = bridge();
    await openReader(tester, harness, size: const ui.Size(390, 844));
    await settleEpubPage(tester);
    final original = dartPage(tester)!.page.canonicalStart;
    final saves = harness.savedReadingStates.length;
    final surface = find.byKey(const ValueKey('reader-selection-surface'));
    final box = tester.getRect(surface);
    final start = ui.Offset(box.right - 30, box.center.dy);
    final gesture = await tester.startGesture(start);
    await gesture.moveBy(
      const ui.Offset(-30, 0),
      timeStamp: const Duration(milliseconds: 100),
    );
    await gesture.moveBy(
      const ui.Offset(-90, 0),
      timeStamp: const Duration(milliseconds: 600),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('reader-page-curl')), findsOneWidget);
    expect(dartPage(tester)!.page.canonicalStart, original);
    await gesture.up(timeStamp: const Duration(milliseconds: 1000));
    await tester.pumpAndSettle();
    expect(dartPage(tester)!.page.canonicalStart, original);
    expect(harness.savedReadingStates.length, saves);

    await tester.fling(surface, const ui.Offset(-100, 0), 1000);
    await tester.pumpAndSettle();
    final next = dartPage(tester)!.page.canonicalStart;
    expect(next, greaterThan(original));
    expect(harness.savedReadingStates.last.offset?.toInt(), next);
    await tester.fling(surface, const ui.Offset(100, 0), 1000);
    await tester.pumpAndSettle();
    expect(dartPage(tester)!.page.canonicalStart, original);
    await closeReader(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'page steps walk the table chapter forward without skipping or cycling',
    (tester) async {
      final harness = bridge();
      await openReader(tester, harness);
      await settleEpubPage(tester);

      final starts = await walkForward(tester);
      expect(starts.length, greaterThan(2), reason: 'the fixture spans pages');
      for (var index = 1; index < starts.length; index += 1) {
        expect(
          starts[index],
          greaterThan(starts[index - 1]),
          reason:
              'page step $index must advance the durable position '
              '(${starts[index - 1]} -> ${starts[index]})',
        );
      }
      // The walk leaves the chapter only after its last page.
      expect(
        dartPage(tester)!.page.unit,
        book.chapters[1].spine,
        reason: 'the walk reached the chapter end',
      );

      await closeReader(tester);
    },
  );

  testWidgets('phone swipes turn EPUB pages within a chapter and back', (
    tester,
  ) async {
    await openReader(tester, bridge(), size: const ui.Size(390, 800));
    await settleEpubPage(tester);
    final first = dartPage(tester)!.page;
    final surface = find.byKey(const ValueKey('reader-selection-surface'));
    final resting = tester.getTopLeft(surface).dx;
    await tester.drag(surface, const Offset(-200, 0));
    for (
      var frame = 0;
      frame < 20 && identical(dartPage(tester)!.page, first);
      frame++
    ) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(find.byKey(const ValueKey('reader-page-curl')), findsOneWidget);
    expect(tester.getTopLeft(surface).dx, resting);
    await settleEpubPage(tester);
    final next = dartPage(tester)!.page;
    expect(next.unit, first.unit);
    expect(next.canonicalStart, greaterThan(first.canonicalStart));
    expect(tester.getTopLeft(surface).dx, closeTo(resting, .01));
    await tester.drag(surface, const Offset(200, 0));
    for (
      var frame = 0;
      frame < 20 && identical(dartPage(tester)!.page, next);
      frame++
    ) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(find.byKey(const ValueKey('reader-page-curl')), findsOneWidget);
    expect(tester.getTopLeft(surface).dx, resting);
    await settleEpubPage(tester);
    expect(dartPage(tester)!.page.canonicalStart, first.canonicalStart);
    expect(tester.getTopLeft(surface).dx, closeTo(resting, .01));
    await closeReader(tester);
  });

  testWidgets('keyboard PageDown steps forward and PageUp walks back in '
      'order', (tester) async {
    final harness = bridge();
    await openReader(tester, harness);
    await settleEpubPage(tester);

    // Two keyboard PageDowns advance the position.
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await settleEpubPage(tester);
    final afterOne = dartPage(tester)!.page.canonicalStart;
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await settleEpubPage(tester);
    final afterTwo = dartPage(tester)!.page.canonicalStart;
    expect(afterOne, greaterThan(0));
    expect(afterTwo, greaterThan(afterOne));

    // PageUp returns through the same pages, in reverse order.
    await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
    await settleEpubPage(tester);
    final afterBack = dartPage(tester)!.page.canonicalStart;
    expect(
      afterBack,
      afterOne,
      reason: 'one PageUp returns to the previous page exactly',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
    await settleEpubPage(tester);
    expect(
      dartPage(tester)!.page.canonicalStart,
      0,
      reason: 'the walk returns to the chapter start',
    );

    await closeReader(tester);
  });

  testWidgets('PageUp at the first chapter start is refused', (tester) async {
    final harness = bridge();
    await openReader(tester, harness, size: const ui.Size(600, 800));
    await settleEpubPage(tester);
    final before = dartPage(tester)!.page;

    await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
    await settleEpubPage(tester);

    final after = dartPage(tester)!.page;
    expect(tester.takeException(), isNull);
    expect(after.unit, before.unit);
    expect(after.canonicalStart, before.canonicalStart);
    expect(after.spread, isFalse);
    await closeReader(tester);
  });

  testWidgets('a single page back from a chapter start lands on the previous '
      "chapter's last page and saves its start", (tester) async {
    final harness = bridge();
    await openReader(tester, harness, size: const ui.Size(600, 800));
    await settleEpubPage(tester);

    // Walk to the start of chapter two, remembering chapter one's last page.
    final starts = await walkForward(tester);
    expect(dartPage(tester)!.page.unit, book.chapters[1].spine);
    expect(dartPage(tester)!.page.canonicalStart, 0);

    await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
    await settleEpubPage(tester);
    final page = dartPage(tester)!.page;
    expect(page.unit, book.chapters.first.spine);
    expect(page.spread, isFalse);
    // The page is laid out afresh around the chapter end, so its break may
    // differ from the walk's; what matters is that it ends the chapter.
    // (The chapter's last scalar can lie past its last drawn line.)
    expect(
      page.canonicalEnd,
      greaterThanOrEqualTo(book.chapters.first.scalarCount - 1),
      reason: 'one page back shows the end of the chapter before',
    );
    expect(page.canonicalStart, greaterThan(0));
    expect(starts.length, greaterThan(2));
    await settleNative(tester, rounds: 2);
    expect(
      harness.savedReadingStates.last.offset?.toInt(),
      page.canonicalStart,
    );

    // Walking on back stays in that chapter, page by page.
    await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
    await settleEpubPage(tester);
    final before = dartPage(tester)!.page;
    expect(before.unit, book.chapters.first.spine);
    expect(before.canonicalStart, lessThan(page.canonicalStart));

    await closeReader(tester);
  });

  testWidgets('a spread back from a chapter start keeps the final pairing', (
    tester,
  ) async {
    final harness = bridge(
      readingState: FlutterReadingState(
        unit: BigInt.one,
        offset: BigInt.zero,
        zoom: 1,
      ),
    );
    await openReader(tester, harness, size: const ui.Size(1280, 800));
    await settleEpubPage(tester);
    expect(dartPage(tester)!.page.unit, book.chapters[1].spine);

    await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
    await settleEpubPage(tester);
    final last = dartPage(tester)!.page;
    expect(last.unit, book.chapters.first.spine);
    expect(last.spread, isTrue);
    expect(last.pageIndex.isEven, isTrue);
    expect(last.targetScalar, chapter.scalarCount);
    expect(last.canonicalEnd, greaterThanOrEqualTo(chapter.scalarCount - 1));
    await settleNative(tester, rounds: 2);
    expect(
      harness.savedReadingStates.last.offset?.toInt(),
      last.canonicalStart,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
    await settleEpubPage(tester);
    final previous = dartPage(tester)!.page;
    expect(previous.pageIndex, last.pageIndex - 2);
    expect(previous.canonicalEnd, lessThanOrEqualTo(last.canonicalStart));
    await closeReader(tester);
  });

  testWidgets('a resize keeps a pending chapter-end target and releases its '
      'superseded session', (tester) async {
    final sessions = <ChapterLayoutSession>[];
    final harness = bridge(
      readingState: FlutterReadingState(
        unit: BigInt.one,
        offset: BigInt.zero,
        zoom: 1,
      ),
    );
    await openReader(
      tester,
      harness,
      size: const ui.Size(1280, 800),
      sessionObserver: sessions.add,
    );
    await settleEpubPage(tester);

    final held = Completer<List<FlutterAnnotation>>();
    harness.annotationListCompleters.add(held);
    await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
    await settleNative(tester, rounds: 3);
    expect(
      harness.annotationListCompleters,
      isEmpty,
      reason: 'the end-targeted relayout is waiting for annotations',
    );
    final superseded = sessions.last;
    expect(superseded.isDisposed, isFalse);

    tester.view.physicalSize = const ui.Size(1400, 800);
    await settleNative(tester, rounds: 5);
    final installed = sessions.last;
    final last = dartPage(tester)!.page;
    expect(last.unit, book.chapters.first.spine);
    expect(last.targetScalar, chapter.scalarCount);
    expect(last.pageIndex.isEven, isTrue);
    expect(last.canonicalEnd, greaterThanOrEqualTo(chapter.scalarCount - 1));
    expect(installed, isNot(same(superseded)));
    expect(installed.isDisposed, isFalse);
    expect(superseded.isDisposed, isFalse);

    held.complete(const []);
    await settleNative(tester, rounds: 3);
    expect(superseded.isDisposed, isTrue);
    expect(installed.isDisposed, isFalse);
    await closeReader(tester);
  });

  testWidgets('a page back reaches the last page of an empty chapter', (
    tester,
  ) async {
    expect(emptyBook.chapters.first.scalarCount, 0);
    final harness = emptyBridge();
    await openReader(tester, harness, size: const ui.Size(600, 800));
    await settleEpubPage(tester);
    expect(dartPage(tester)!.page.unit, emptyBook.chapters[1].spine);

    await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
    await settleEpubPage(tester);
    final last = dartPage(tester)!.page;
    expect(last.unit, emptyBook.chapters.first.spine);
    expect(last.targetScalar, 0);
    expect(last.pageCount, 1);
    expect(last.pageIndex, last.pageCount - 1);
    expect(last.canonicalStart, 0);
    await closeReader(tester);
  });

  testWidgets('a position on an empty-row page restores to that page', (
    tester,
  ) async {
    // Walk until the reader paints a page whose canonical start a fully
    // empty table row owns — the position such a page saves is a row anchor,
    // not a text line's — then let the durable state settle on it.
    final harness = bridge();
    await openReader(tester, harness);
    await settleEpubPage(tester);
    final chapterUnit = book.chapters.first.spine;
    var current = dartPage(tester)!;
    var walked = 0;
    while (!_pageStartOwnedByEmptyRow(current.page.page)) {
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await settleEpubPage(tester);
      current = dartPage(tester)!;
      if (current.page.unit != chapterUnit || ++walked > 60) {
        fail(
          'no page owned by an empty row was painted before the chapter end',
        );
      }
    }
    final target = current.page.canonicalStart;
    expect(
      target,
      isNot(0),
      reason: 'the empty row anchors its page mid-chapter, not at scalar 0',
    );

    // Let the last accepted reading-state write drain before reading it.
    await settleNative(tester, rounds: 2);
    final unit = harness.savedReadingStates.last.unit.toInt();
    final offset = harness.savedReadingStates.last.offset?.toInt();
    expect(unit, chapterUnit);
    expect(offset, target, reason: 'the saved offset is the page start');

    // Reopen through the production relaunch path: the old reader is removed
    // first, so a fresh controller over a fresh bridge serves the saved
    // durable state — the original reader instance must not be answering
    // from its in-memory model.
    await closeReader(tester);
    final reopened = bridge(
      readingState: FlutterReadingState(
        unit: BigInt.from(unit),
        offset: BigInt.from(offset!),
        zoom: 1,
      ),
    );
    await openReader(tester, reopened);
    await settleEpubPage(tester);
    expect(
      reopened.loadReadingStateCalls,
      greaterThan(0),
      reason: 'the fresh reader asked its own bridge for the durable state',
    );
    expect(reopened.loadReadingStateBookIds, contains(1));
    final restored = dartPage(tester)!;
    expect(restored.page.unit, unit);
    expect(
      restored.page.canonicalStart,
      isNot(0),
      reason: 'the reader reopens mid-chapter, not at the chapter start',
    );
    // The restore guarantee is the window containing the saved canonical
    // position: the priority window starts at the node holding the scalar and
    // the snapshot paginates from its beginning, so the reopened page's own
    // start can sit earlier than the saved one (an accepted window-identity
    // limit of the existing windowed layout). What must hold is that the
    // saved empty row — the row whose own anchor is the saved scalar — is
    // painted on the restored page.
    expect(
      restored.page.canonicalStart,
      lessThanOrEqualTo(target),
      reason: 'the restored page starts at or before the saved position',
    );
    expect(
      restored.page.page.slices.whereType<TablePageSlice>().any(
        (slice) =>
            slice.rowEnd > slice.rowStart &&
            slice.block.table!.rows
                .sublist(slice.rowStart, slice.rowEnd)
                .any((row) => row.canonicalStart == target),
      ),
      isTrue,
      reason:
          'the restored page paints the empty row that owns the saved '
          'position',
    );

    await closeReader(tester);
  });

  group('the match a book opened at, before its chapter is measured,', () {
    /// Opens the book at the chapter's first word without letting time pass,
    /// so its first page installs while the rest of the chapter waits to be
    /// measured.
    Future<void> openAtMatch(
      WidgetTester tester, {
      ReaderPlaceRequests? requests,
    }) async {
      imageCache.clear();
      await tester.pumpWidget(
        productionShell(
          home: ReaderScreen(
            bridge: bridge(),
            initialPath: '/books/page-anchor.epub',
            initialBookId: 1,
            initialSettings: harnessReaderSettings,
            initialPlace: ReaderPlace(
              book.chapters.first.spine,
              offset: 0,
              length: 4,
            ),
            placeRequests: requests,
            epubImageDecoder: (bytes) async => null,
          ),
        ),
      );
      for (var round = 0; round < 16 && dartPage(tester) == null; round += 1) {
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 120)),
        );
      }
      expect(status(tester), isNot(startsWith('Selected text')));
    }

    testWidgets('is dropped by a page turn', (tester) async {
      await openAtMatch(tester);
      final first = dartPage(tester)!.page.canonicalStart;
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.pump();
      await settleEpubPage(tester);
      expect(dartPage(tester)!.page.canonicalStart, greaterThan(first));
      expect(status(tester), isNot(startsWith('Selected text')));

      await closeReader(tester);
    });

    testWidgets('gives way to a newer match in the same chapter', (
      tester,
    ) async {
      final requests = ReaderPlaceRequests();
      await openAtMatch(tester, requests: requests);
      requests.go(ReaderPlace(book.chapters.first.spine, offset: 5, length: 3));
      await tester.pump();
      await settleEpubPage(tester);
      expect(status(tester), startsWith('Selected text'));
      expect(status(tester), isNot('Selected text: Lead'));

      await closeReader(tester);
    });

    testWidgets('is dropped by a press outside the page', (tester) async {
      await openAtMatch(tester);
      await tester.tapAt(const Offset(2, 2));
      await tester.pump();
      await settleEpubPage(tester);
      expect(status(tester), 'No text selected');

      await closeReader(tester);
    });

    testWidgets('is dropped when the reader cancels the selection', (
      tester,
    ) async {
      await openAtMatch(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await settleEpubPage(tester);
      expect(status(tester), 'No text selected');

      await closeReader(tester);
    });
  });
}

String? status(WidgetTester tester) => tester
    .getSemantics(find.byKey(const ValueKey('reader-selection-status')))
    .getSemanticsData()
    .label;

/// Whether every row a table slice paints carries no mapped canonical content
/// (cells present but empty). A caption-only slice paints no rows and never
/// qualifies, and a slice of a table elsewhere on the page is not consulted:
/// only `slice.rowStart`–`rowEnd` are.
bool _slicePaintsOnlyEmptyRows(TablePageSlice slice) {
  final table = slice.block.table;
  if (table == null || slice.rowEnd <= slice.rowStart) return false;
  return table.rows
      .sublist(slice.rowStart, slice.rowEnd)
      .every(
        (row) =>
            row.cells.isNotEmpty &&
            row.cells.every((cell) => cell.blocks.isEmpty),
      );
}

/// Whether [page]'s canonical start is owned by a slice of fully empty rows:
/// the slice's first row anchors exactly where the page starts. A page that
/// merely contains some empty-row portion of a table elsewhere does not
/// qualify — its start belongs to the row it opens with.
bool _pageStartOwnedByEmptyRow(FlowPage page) =>
    page.slices.whereType<TablePageSlice>().any(
      (slice) =>
          _slicePaintsOnlyEmptyRows(slice) &&
          slice.block.table!.rows[slice.rowStart].canonicalStart ==
              page.canonicalStart,
    );
