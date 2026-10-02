import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_flutter/reader/epub/flow.dart';
import 'package:shosai_flutter/reader/epub/pages.dart';
import 'package:shosai_flutter/reader/epub/text_style.dart';
import 'package:shosai_epub/shosai_epub.dart';

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
/// Two cases share one fixture builder:
/// - The *control* (active): the same chapter with only text-bearing table
///   rows must satisfy the page-order invariants. It fails if the pagination
///   invariants themselves regress.
/// - The *bug case* (skipped): adding one empty-cells table row must violate
///   the invariants specifically on the page that contains it. Skipped until
///   the fix lands so the suite stays green; remove its `skip` when fixed.
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

  EpubChapter buildChapter({required bool emptyFirstRow}) {
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
          EpubTableRowGroup(
            kind: EpubTableRowGroupKind.body,
            rows: [
              if (emptyFirstRow)
                // An entirely empty first row (empty cells are common in
                // real books' layout tables): its cells have no text spans,
                // so the flow's cell block list is empty.
                EpubTableRow(
                  cells: [
                    EpubTableCell(children: []),
                    EpubTableCell(children: []),
                  ],
                ),
              EpubTableRow(
                cells: [
                  EpubTableCell(
                    children: [
                      EpubParagraph([
                        EpubTextSpan(text: 'Data value one for the table.'),
                      ], const EpubNodeStyle()),
                    ],
                  ),
                  EpubTableCell(
                    children: [
                      EpubParagraph([
                        EpubTextSpan(text: 'Data value two for the table.'),
                      ], const EpubNodeStyle()),
                    ],
                  ),
                ],
              ),
            ],
          ),
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

  test(
    'control: a chapter with a text-bearing table keeps page starts ordered',
    () => expectInvariants(buildChapter(emptyFirstRow: false)),
  );

  test(
    'bug: a table row without canonical-mapped cells anchors its page to '
    'scalar 0',
    skip:
        'repro for the real-book page-step regression (see '
        'benchmarks/epub-real-corpus/2026-10-02/README.md); enable when '
        'table cells without mapped canonical content stop anchoring pages '
        'to scalar 0',
    () => expectInvariants(buildChapter(emptyFirstRow: true)),
  );
}
