import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_epub/shosai_epub.dart';
import 'package:shosai_flutter/reader/epub/font_coverage.dart';
import 'package:shosai_flutter/reader/epub/pages.dart';
import 'package:shosai_flutter/reader/view.dart';
import 'package:shosai_flutter/src/rust/api.dart';

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
  // under test is the production one.
  final coverage = EpubFontCoverage.fromFonts([
    _repoFile('assets/fonts/InterVariable.ttf'),
    _repoFile('assets/fonts/NotoSansJP-Variable.ttf'),
  ])!;

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
    harness.canonicalTexts = {
      for (var unit = 0; unit < book.chapters.length; unit += 1)
        unit: book.chapters[unit].canonicalText,
    };
    return harness;
  }

  Future<void> openReader(WidgetTester tester, _AnchorBridge harness) async {
    await renderHarnessState(
      tester,
      productionShell(
        home: ReaderScreen(
          bridge: harness,
          initialPath: '/books/page-anchor.epub',
          initialBookId: 1,
          fontCoverageLoader: () async => coverage,
          epubImageDecoder: (bytes) async => null,
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
      await tester.tap(find.byKey(const ValueKey('reader-edge-next')));
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
      await tester.tap(find.byKey(const ValueKey('reader-edge-next')));
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
}

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

/// The bytes of one repository file.
Uint8List _repoFile(String path) =>
    Uint8List.fromList(File('../$path').readAsBytesSync());
