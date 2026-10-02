import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_epub/shosai_epub.dart';
import 'package:shosai_flutter/reader/epub/content.dart';
import 'package:shosai_flutter/reader/epub/flow.dart';
import 'package:shosai_flutter/reader/epub/pages.dart';
import 'package:shosai_flutter/reader/epub/text_style.dart';

/// Minimal reproduction for the real-book page-step regression observed in
/// the 2026-10-02 real-book compatibility pass (anonymized finding: page
/// steps are misdirected by pages whose canonical anchor is 0).
///
/// Observed on real books: pressing PageDown skipped pages, jumped backward,
/// and cycled without progress. Root cause (unit-level, reproduced on a real
/// chapter): a table whose cells carry no mapped canonical content produces
/// `FlowTableRowLayout.canonicalStart == 0` (`FlowTableCellLayout
/// .canonicalStart` is 0 when the cell's block list is empty); any page
/// containing such a row gets `canonicalStart == 0` even mid-chapter, so
/// `pageOfCanonical` — which assumes page starts are ordered — misresolves
/// positions, and the page-step controller then skips content or steps
/// backward.
///
/// The fix gives every table row its own canonical range in the engine's
/// canonical builder (`EpubTableRow.canonical`): a row owns the separators it
/// contributes (the tab between cells and the newline that ends it), so a row
/// whose cells are all empty still anchors at its own stream position.
///
/// All cases share one fixture builder and assert the same contract:
/// - The *control*: a chapter with only text-bearing table rows satisfies the
///   page-order invariants. It fails if the pagination invariants regress.
/// - The empty-cell/row cases: the same chapter with empty leading, interior
///   or trailing cells, fully empty rows, and a cell-less row must satisfy
///   the *same* invariants — strictly increasing page starts, forward and
///   backward stepping that visits every page, boundary scalars that resolve
///   to the page that starts at them, and durable restoration of an
///   empty-row page through the production `pageWindowFor`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const typography = ReaderEpubTypography(
    fontFamily: 'Inter',
    fontFamilyFallback: ['Noto Sans JP'],
    fontSize: 18,
    lineHeight: 1.5,
    palette: ReaderEpubPalette(
      background: ui.Color(0xFFFFFFFF),
      foreground: ui.Color(0xFF1A1A1A),
      link: ui.Color(0xFF174EA6),
      tableHeaderBackground: ui.Color(0xFFE8EEF8),
      tableHeaderBorder: ui.Color(0xFF596B89),
    ),
  );

  EpubTableCell cell(String text) => EpubTableCell(
    children: [
      EpubParagraph([EpubTextSpan(text: text)], const EpubNodeStyle()),
    ],
  );

  EpubTableCell emptyCell() => EpubTableCell(children: []);

  EpubTableRow rowOf(List<EpubTableCell> cells) => EpubTableRow(cells: cells);

  EpubChapter buildChapter({required List<EpubTableRow> tableRows}) {
    // Canonical spans are assigned by the engine's own CanonicalTextBuilder —
    // the same annotation walk the production parse uses — so every span and
    // node is mapped in stream order and the only zero anchor in the bug case
    // comes from the empty table row.
    final blocks = <EpubContentNode>[
      // Enough leading paragraphs to fill the first page.
      for (var index = 0; index < 40; index += 1)
        EpubParagraph([
          EpubTextSpan(text: 'Leading paragraph ${index * 7} of the fixture.'),
        ], const EpubNodeStyle()),
      EpubTable(
        caption: [],
        rowGroups: [
          EpubTableRowGroup(kind: EpubTableRowGroupKind.body, rows: tableRows),
        ],
      ),
      for (var index = 0; index < 40; index += 1)
        EpubParagraph([
          EpubTextSpan(
            text: 'Trailing paragraph ${index * 11} of the fixture.',
          ),
        ], const EpubNodeStyle()),
    ];
    final built = CanonicalTextBuilder(maxScalars: 100000).build(blocks);
    return EpubChapter(
      spine: 0,
      resource: 'chapter.xhtml',
      title: 'Synthetic page-anchor repro',
      blocks: blocks,
      canonicalText: built.text,
      anchors: const {},
      scalarCount: built.scalarCount,
    );
  }

  /// The control's table: rows whose cells all carry text.
  final controlRows = [
    rowOf([cell('Data value one.'), cell('Data value two.')]),
  ];

  /// The pinned bug shape: one row whose cells are all empty, mid-chapter
  /// after nonzero text.
  final bugRows = [
    rowOf([emptyCell(), emptyCell()]),
    rowOf([cell('Data value one.'), cell('Data value two.')]),
  ];

  Future<void> expectInvariants(EpubChapter chapter) async {
    final flow = layoutChapterFlow(
      chapter: chapter,
      spec: ChapterLayoutSpec(width: 640, height: 800, typography: typography),
      images: const {},
    );
    final paginated = paginateFlow(flow: flow, pageHeight: 800, pageWidth: 640);
    final pages = paginated.pages;
    expect(pages, isNotEmpty);
    for (var index = 1; index < pages.length; index += 1) {
      expect(
        pages[index].canonicalStart,
        greaterThanOrEqualTo(pages[index - 1].canonicalStart),
        reason: 'page $index starts before page ${index - 1}',
      );
    }
    for (final page in pages) {
      expect(
        paginated.pageOfCanonical(page.canonicalStart),
        page.index,
        reason:
            'page ${page.index} (start ${page.canonicalStart}) does not '
            'resolve its own start',
      );
    }
    var scalar = pages.first.canonicalStart;
    for (var step = 0; step < pages.length + 4; step += 1) {
      final index = paginated.pageOfCanonical(scalar);
      if (index + 1 >= pages.length) break;
      final next = pages[index + 1].canonicalStart;
      expect(
        next,
        greaterThan(scalar),
        reason:
            'forward page step $step moved the position backward '
            '($scalar -> $next)',
      );
      scalar = next;
    }
  }

  /// The invariants beyond the pinned repro: page starts must strictly
  /// increase (a tie breaks `pageOfCanonical`'s boundary ownership),
  /// backward steps must visit every page in reverse, and the boundary
  /// scalar a page ends on must resolve to the page that starts at it.
  Future<void> expectSteppingContract(EpubChapter chapter) async {
    final flow = layoutChapterFlow(
      chapter: chapter,
      spec: ChapterLayoutSpec(width: 640, height: 800, typography: typography),
      images: const {},
    );
    final paginated = paginateFlow(flow: flow, pageHeight: 800, pageWidth: 640);
    final pages = paginated.pages;
    expect(pages.length, greaterThan(1), reason: 'the fixture spans pages');
    for (var index = 1; index < pages.length; index += 1) {
      expect(
        pages[index].canonicalStart,
        greaterThan(pages[index - 1].canonicalStart),
        reason:
            'page $index must start strictly after page ${index - 1}: a '
            'tie breaks the boundary-scalar resolution',
      );
      // A page break's boundary scalar belongs to the page that starts at it.
      expect(
        paginated.pageOfCanonical(pages[index].canonicalStart),
        index,
        reason: 'page $index boundary start resolves to page $index',
      );
    }
    // Backward steps visit every page in reverse, exactly as the controller
    // derives them (`pages[index - 1].canonicalStart` from the resolved
    // current page).
    var scalar = pages.last.canonicalStart;
    for (var step = 0; step < pages.length + 4; step += 1) {
      final index = paginated.pageOfCanonical(scalar);
      if (index == 0) break;
      final previous = pages[index - 1].canonicalStart;
      expect(
        previous,
        lessThan(scalar),
        reason:
            'backward page step $step moved the position forward '
            '($scalar -> $previous)',
      );
      scalar = previous;
    }
    expect(scalar, pages.first.canonicalStart, reason: 'the walk reaches 0');
  }

  test(
    'control: a chapter with a text-bearing table keeps page starts ordered',
    () => expectInvariants(buildChapter(tableRows: controlRows)),
  );

  test(
    'bug: a table row without canonical-mapped cells anchors its page to '
    'scalar 0',
    () => expectInvariants(buildChapter(tableRows: bugRows)),
  );

  test('empty leading, interior and trailing cells keep the page contract', () {
    final chapter = buildChapter(
      tableRows: [
        rowOf([cell('One.'), cell('Two.')]),
        // A leading empty cell: the row's first mapped text is not its first
        // cell's text.
        rowOf([emptyCell(), cell('Leading cell is empty.')]),
        // An interior empty cell between two text cells.
        rowOf([cell('Before.'), emptyCell(), cell('After.')]),
        // A trailing empty cell.
        rowOf([cell('Text first.'), emptyCell()]),
        rowOf([cell('Three.'), cell('Four.')]),
      ],
    );
    expectInvariants(chapter);
    expectSteppingContract(chapter);
  });

  test('a fully empty row between text rows anchors its own position', () {
    final chapter = buildChapter(
      tableRows: [
        rowOf([cell('One.'), cell('Two.')]),
        rowOf([emptyCell(), emptyCell()]),
        rowOf([emptyCell(), emptyCell()]),
        rowOf([cell('Three.'), cell('Four.')]),
      ],
    );
    expectInvariants(chapter);
    expectSteppingContract(chapter);
    // The empty row must not anchor any page to scalar 0: every page of the
    // chapter sits at a real stream position.
    final flow = layoutChapterFlow(
      chapter: chapter,
      spec: ChapterLayoutSpec(width: 640, height: 800, typography: typography),
      images: const {},
    );
    final paginated = paginateFlow(flow: flow, pageHeight: 800, pageWidth: 640);
    for (var index = 1; index < paginated.pages.length; index += 1) {
      expect(
        paginated.pages[index].canonicalStart,
        isNot(0),
        reason: 'page $index is mid-chapter',
      );
    }
  });

  test('a row without cells contributes no page anchor', () {
    final chapter = buildChapter(
      tableRows: [
        rowOf([cell('One.'), cell('Two.')]),
        // A `<tr>` with no cells: the layout skips it, and the stream's own
        // separators must keep the following rows' anchors real.
        rowOf(const []),
        rowOf([cell('Three.'), cell('Four.')]),
      ],
    );
    expectInvariants(chapter);
    expectSteppingContract(chapter);
  });

  test('a page built only of empty rows stays ordered and steppable', () {
    // Enough empty rows that page breaks fall between them, mid-chapter.
    final chapter = buildChapter(
      tableRows: [
        for (var index = 0; index < 60; index += 1) rowOf([emptyCell()]),
        rowOf([cell('After the empty rows.')]),
      ],
    );
    expectInvariants(chapter);
    expectSteppingContract(chapter);
  });

  test('the empty-cell contract holds across page sizes and font sizes', () {
    // A resize or font-size change repaginates the chapter; the page-anchor
    // contract must hold at the other geometry too, including small pages
    // that force table rows to split across page boundaries.
    const geometries = [
      (width: 640.0, height: 800.0, fontSize: 18.0),
      (width: 480.0, height: 620.0, fontSize: 22.0),
      (width: 320.0, height: 300.0, fontSize: 14.0),
      (width: 900.0, height: 500.0, fontSize: 18.0),
    ];
    for (final geometry in geometries) {
      final typography = ReaderEpubTypography(
        fontFamily: 'Inter',
        fontFamilyFallback: ['Noto Sans JP'],
        fontSize: geometry.fontSize,
        lineHeight: 1.5,
        palette: const ReaderEpubPalette(
          background: ui.Color(0xFFFFFFFF),
          foreground: ui.Color(0xFF1A1A1A),
          link: ui.Color(0xFF174EA6),
          tableHeaderBackground: ui.Color(0xFFE8EEF8),
          tableHeaderBorder: ui.Color(0xFF596B89),
        ),
      );
      final flow = layoutChapterFlow(
        chapter: buildChapter(
          tableRows: [
            rowOf([cell('One.'), cell('Two.')]),
            rowOf([emptyCell(), cell('Leading empty cell.')]),
            rowOf([cell('Mid.'), emptyCell(), cell('End.')]),
            rowOf([emptyCell(), emptyCell()]),
            rowOf([cell('Last.')]),
          ],
        ),
        spec: ChapterLayoutSpec(
          width: geometry.width,
          height: geometry.height,
          typography: typography,
        ),
        images: const {},
      );
      final paginated = paginateFlow(
        flow: flow,
        pageHeight: geometry.height,
        pageWidth: geometry.width,
      );
      final pages = paginated.pages;
      expect(
        pages.length,
        greaterThan(2),
        reason: 'geometry $geometry spans pages',
      );
      for (var index = 1; index < pages.length; index += 1) {
        expect(
          pages[index].canonicalStart,
          greaterThan(pages[index - 1].canonicalStart),
          reason:
              'geometry $geometry: page $index must start strictly after '
              'page ${index - 1}',
        );
      }
      for (final page in pages) {
        expect(
          paginated.pageOfCanonical(page.canonicalStart),
          page.index,
          reason: 'geometry $geometry: page ${page.index} resolves its start',
        );
      }
    }
  });

  test(
    'an empty-row page start restores through the production window',
    () async {
      // Enough empty rows that the full pagination starts a page on them
      // mid-chapter: the durable position the reader saves there is a row
      // anchor, not a text line's.
      final chapter = buildChapter(
        tableRows: [
          rowOf([cell('One.'), cell('Two.')]),
          for (var index = 0; index < 60; index += 1)
            rowOf([emptyCell(), emptyCell()]),
          rowOf([cell('Three.'), cell('Four.')]),
        ],
      );
      final flow = layoutChapterFlow(
        chapter: chapter,
        spec: ChapterLayoutSpec(
          width: 640,
          height: 800,
          typography: typography,
        ),
        images: const {},
      );
      final paginated = paginateFlow(
        flow: flow,
        pageHeight: 800,
        pageWidth: 640,
      );
      // The page whose canonical start a fully empty row owns — not merely a
      // page containing some portion of the same table: a whole-table check
      // would qualify a text-only row slice too. Only slices restricted to
      // fully empty rows whose first row anchors the page start count.
      final emptyRowPage = paginated.pages
          .where(_pageStartOwnedByEmptyRow)
          .firstOrNull;
      expect(
        emptyRowPage,
        isNotNull,
        reason: 'a page break falls inside the empty-row run',
      );
      expect(
        emptyRowPage!.canonicalStart,
        isNot(0),
        reason: 'the empty row anchors its page mid-chapter',
      );
      final target = emptyRowPage.canonicalStart;

      // The production restore path: a session laid out around the saved
      // scalar must install a page that shows the saved row. The window
      // starts at the node holding the scalar and the snapshot paginates from
      // its beginning, so the restored page's own start can sit earlier than
      // the saved one (an accepted window-identity limit of the existing
      // windowed layout); what must hold is that the saved row is painted.
      final session = ChapterLayoutSession(
        chapter: chapter,
        spec: ChapterLayoutSpec(
          width: 640,
          height: 800,
          typography: typography,
        ),
        images: const {},
      );
      addTearDown(session.dispose);
      session.layoutWindowAt(target);
      while (!session.complete) {
        final progressed = session.lastNodeIndex + 1 < session.totalNodes
            ? session.layoutForward(maxNodes: 64, maxMicros: 20000)
            : session.layoutBackward(maxNodes: 64, maxMicros: 20000);
        if (progressed == 0) break;
      }
      expect(session.complete, isTrue);
      final window = pageWindowFor(
        session: session,
        scalar: target,
        unit: 0,
        chapterCount: 1,
        windowSize: const Size(640, 800),
      );
      expect(
        window.pageIndex,
        isNot(0),
        reason:
            'a position saved on an empty-row page restores to that page, '
            'not to the chapter start',
      );
      expect(window.canonicalStart, window.page.canonicalStart);
      expect(
        window.page.canonicalStart,
        lessThanOrEqualTo(target),
        reason: 'the restored page starts at or before the saved position',
      );
      expect(
        window.page.slices.whereType<TablePageSlice>().any(
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
    },
  );
}

/// Whether every row a table slice paints carries no mapped canonical content
/// (cells present but empty). A caption-only slice paints no rows and never
/// qualifies, and only `slice.rowStart`–`rowEnd` are consulted: a slice of a
/// table's text-bearing rows elsewhere never counts.
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
/// merely contains some empty-row portion of a table does not qualify — its
/// start belongs to the row it opens with.
bool _pageStartOwnedByEmptyRow(FlowPage page) =>
    page.slices.whereType<TablePageSlice>().any(
      (slice) =>
          _slicePaintsOnlyEmptyRows(slice) &&
          slice.block.table!.rows[slice.rowStart].canonicalStart ==
              page.canonicalStart,
    );
