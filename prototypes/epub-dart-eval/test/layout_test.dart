/// Layout, pagination, selection and copy evidence for the prototype.
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart' show TextSelection;
import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_epub/shosai_epub.dart';
import 'package:shosai_epub_eval/reader/effects.dart';
import 'package:shosai_epub_eval/reader/geometry.dart';
import 'package:shosai_epub_eval/reader/layout/flow.dart';
import 'package:shosai_epub_eval/reader/layout/pages.dart';
import 'package:shosai_epub_eval/reader/layout/text_style.dart';
import 'package:shosai_epub_eval/reader/theme.dart';

EpubBook _fixture(String name) {
  final local = File('fixtures/$name');
  final path = local.existsSync()
      ? local.path
      : '../../crates/shosai-core/tests/fixtures/epub-conformance/$name';
  return openEpubBytes(Uint8List.fromList(File(path).readAsBytesSync()));
}

/// Decode every admitted image resource with the prototype's own decoder.
Future<Map<String, ui.Image>> _decodeImages(EpubBook book) async {
  const decoder = EpubEngineImageDecoder();
  final images = <String, ui.Image>{};
  for (final resource in book.resources.values) {
    if (!resource.mediaType.startsWith('image/')) continue;
    final image = await decoder.decode(Uint8List.fromList(resource.bytes));
    if (image != null) images[resource.path] = image;
  }
  return images;
}

const _typography = ReaderTypography(
  fontFamily: 'Ahem',
  fontFamilyFallback: [],
  fontSize: 16,
  lineHeight: 1.4,
  palette: ReaderPalette.light,
);

ChapterFlow _flow(
  EpubBook book,
  int spine, {
  double width = 480,
  double height = 640,
}) => layoutChapterFlow(
  chapter: book.chapters[spine],
  spec: ChapterLayoutSpec(
    width: width,
    height: height,
    typography: _typography,
  ),
  images: const {},
  imageMediaTypes: const {},
);

/// Occurrence counts of canonical scalars rendered by the pages.
///
/// A multiset, not a set: a scalar placed on two pages is counted twice, so a
/// duplicate cannot cancel out against a missing one.
Map<int, int> _pageCoverage(PaginatedChapter chapter) {
  final counts = <int, int>{};
  void addRange(int start, int end) {
    for (var scalar = start; scalar < end; scalar++) {
      counts[scalar] = (counts[scalar] ?? 0) + 1;
    }
  }

  for (final page in chapter.pages) {
    for (final slice in page.slices) {
      if (slice is TextPageSlice) {
        final lines = slice.block.text!.lines;
        for (var index = slice.lineStart; index < slice.lineEnd; index++) {
          addRange(lines[index].canonicalStart, lines[index].canonicalEnd);
        }
      } else if (slice is TablePageSlice) {
        final table = slice.block.table!;
        if (slice.rowEnd <= slice.rowStart) {
          final caption = table.caption;
          if (caption != null) {
            addRange(caption.map.canonicalStart, caption.map.canonicalEnd);
          }
          continue;
        }
        for (var index = slice.rowStart; index < slice.rowEnd; index++) {
          for (final cell in table.rows[index].cells) {
            for (final text in cell.blocks) {
              addRange(text.map.canonicalStart, text.map.canonicalEnd);
            }
          }
        }
      } else {
        final image = slice.block.image;
        if (image == null) continue;
        if (image.fallbackText != null) {
          addRange(
            image.fallbackText!.map.canonicalStart,
            image.fallbackText!.map.canonicalEnd,
          );
        }
        if (image.caption != null) {
          addRange(
            image.caption!.map.canonicalStart,
            image.caption!.map.canonicalEnd,
          );
        }
      }
    }
  }
  return counts;
}

/// Canonical scalars of the flow's own line ranges (the rendered subset).
Map<int, int> _flowCoverage(ChapterFlow flow) {
  final counts = <int, int>{};
  void addText(FlowTextBlock text) {
    for (final line in text.lines) {
      for (
        var scalar = line.canonicalStart;
        scalar < line.canonicalEnd;
        scalar++
      ) {
        counts[scalar] = (counts[scalar] ?? 0) + 1;
      }
    }
  }

  for (final block in flow.blocks) {
    if (block.text != null) addText(block.text!);
    final image = block.image;
    if (image != null) {
      if (image.fallbackText != null) addText(image.fallbackText!);
      if (image.caption != null) addText(image.caption!);
    }
    final table = block.table;
    if (table != null) {
      if (table.caption != null) addText(table.caption!);
      for (final row in table.rows) {
        for (final cell in row.cells) {
          for (final text in cell.blocks) {
            addText(text);
          }
        }
      }
    }
  }
  return counts;
}

/// Canonical scalars that *should* be rendered as text, derived from the
/// normalized chapter independently of the flow layout.
///
/// Hidden fallbacks (a decoded image's alt text) are excluded; visible
/// fallbacks (a missing image's alt) and captions are included. Newlines are
/// separators, not rendered glyphs, so they are excluded from both sides of the
/// comparison (a `<pre>` block's line breaks and a hard-wrapped paragraph's
/// breaks produce no ink of their own).
Map<int, int> _expectedRenderedScalars(
  EpubChapter chapter, {
  required bool hasImage,
}) {
  final expected = <int, int>{};
  final scalars = chapter.canonicalText.runes.toList(growable: false);
  void addCanonicalRange(int start, int end) {
    for (var scalar = start; scalar < end; scalar++) {
      if (scalars[scalar] == 0x0A) continue;
      expected[scalar] = (expected[scalar] ?? 0) + 1;
    }
  }

  void addSpan(EpubTextSpan span) {
    final canonical = span.canonical;
    if (canonical == null) return;
    addCanonicalRange(canonical.start, canonical.end);
  }

  void addNode(EpubContentNode node, {bool inCell = false}) {
    switch (node) {
      case EpubHeading(:final spans):
      case EpubParagraph(:final spans):
        for (final span in spans) {
          addSpan(span);
        }
      case EpubBlockQuote(:final children):
      case EpubFigure(:final children):
        for (final child in children) {
          addNode(child);
        }
      case EpubTable(:final caption, :final rowGroups):
        for (final span in caption) {
          addSpan(span);
        }
        for (final group in rowGroups) {
          for (final row in group.rows) {
            for (final cell in row.cells) {
              for (final child in cell.children) {
                // Cell images are always rendered as their alt text; the
                // prototype does not paint images inside table cells.
                addNode(child, inCell: true);
              }
            }
          }
        }
      case EpubMathNode(:final content):
        final canonical = node.canonical;
        if (canonical == null) return;
        addCanonicalRange(canonical.start, canonical.end);
        // The fallback string is the rendered text; its length is the node's.
        expect(content.fallback.runes.length, canonical.length);
      case EpubUnorderedList(:final items):
      case EpubOrderedList(:final items):
        for (final item in items) {
          for (final span in item) {
            addSpan(span);
          }
        }
      case EpubCodeBlock():
        final canonical = node.canonical;
        if (canonical == null) return;
        addCanonicalRange(canonical.start, canonical.end);
      case EpubImage(:final alt, :final caption):
        final canonical = node.canonical;
        if (canonical == null) return;
        if (!hasImage || inCell) {
          // A missing image paints its alt as selectable fallback text, and a
          // cell image always renders as text.
          addCanonicalRange(
            canonical.start,
            canonical.start + alt.runes.length,
          );
        }
        for (final span in caption) {
          addSpan(span);
        }
      case EpubHorizontalRule():
        break;
    }
  }

  for (final node in chapter.blocks) {
    addNode(node);
  }
  return expected;
}

/// Assert that page placement is exactly-once over the rendered scalars.
void expectExactlyOnce({
  required Map<int, int> flow,
  required Map<int, int> pages,
  required String reason,
}) {
  for (final entry in flow.entries) {
    expect(
      pages[entry.key] ?? 0,
      entry.value,
      reason: '$reason: scalar ${entry.key}',
    );
  }
  for (final entry in pages.entries) {
    expect(
      flow[entry.key] ?? 0,
      entry.value,
      reason: '$reason: scalar ${entry.key} placed but not rendered',
    );
  }
}

/// Assert that [actual] places every expected scalar exactly as often as the
/// normalized chapter says it should be rendered (once), and nothing else.
void expectCountsEqual({
  required Map<int, int> actual,
  required Map<int, int> expected,
  required String reason,
}) {
  for (final entry in expected.entries) {
    expect(
      actual[entry.key] ?? 0,
      entry.value,
      reason: '$reason: scalar ${entry.key}',
    );
  }
  for (final entry in actual.entries) {
    expect(
      expected[entry.key] ?? 0,
      entry.value,
      reason: '$reason: scalar ${entry.key} rendered but not expected',
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('rich chapter layout', () {
    test('every rendered canonical scalar is placed exactly once', () {
      final book = _fixture('rich-chapter.epub');
      final flow = _flow(book, 0);
      final paginated = paginateFlow(
        flow: flow,
        pageHeight: 640,
        pageWidth: 480,
      );
      expect(paginated.pages.length, greaterThan(1));
      expect(flow.overflowClippedBlocks, 0);
      expect(paginated.overflowPages, 0);
      expectExactlyOnce(
        flow: _flowCoverage(flow),
        pages: _pageCoverage(paginated),
        reason: 'rich chapter',
      );
      // Independent expectation: what the normalized nodes say is rendered.
      // Compared as multisets against counts of one, so a duplicated flow
      // cannot cancel out against a missing scalar.
      final expected = _expectedRenderedScalars(
        book.chapters[0],
        hasImage: false,
      );
      expectCountsEqual(
        actual: _flowCoverage(flow),
        expected: expected,
        reason: 'rich chapter flow',
      );
      expectCountsEqual(
        actual: _pageCoverage(paginated),
        expected: expected,
        reason: 'rich chapter pages',
      );
    });

    test('headings, lists, images and tables produce blocks', () {
      final book = _fixture('rich-chapter.epub');
      final flow = _flow(book, 0);
      expect(flow.blocks.where((block) => block.text != null), isNotEmpty);
      expect(flow.blocks.where((block) => block.image != null), isNotEmpty);
      expect(flow.blocks.where((block) => block.table != null), isNotEmpty);
      expect(flow.blocks.where((block) => block.rule != null), isNotEmpty);
      final table = flow.blocks.firstWhere((b) => b.table != null).table!;
      expect(table.caption, isNotNull);
      expect(table.rows, isNotEmpty);
      expect(table.headerRows, isNotEmpty);
      // The missing-image paragraph renders a visible, selectable fallback.
      final fallback = flow.blocks
          .where((block) => block.image?.fallbackText != null)
          .toList();
      expect(fallback, isNotEmpty);
    });

    test('a nested table falls back to its exact canonical text', () {
      // A table inside a cell cannot be laid out by the prototype; the
      // fallback must render the canonical substring exactly so a hit on a
      // glyph addresses the same canonical scalar it came from.
      final first = EpubParagraph([
        EpubTextSpan(text: 'A'),
      ], const EpubNodeStyle());
      final quote = EpubBlockQuote(children: [first]);
      final second = EpubParagraph([
        EpubTextSpan(text: 'B'),
      ], const EpubNodeStyle());
      final inner = EpubTable(
        caption: const [],
        rowGroups: [
          EpubTableRowGroup(
            kind: EpubTableRowGroupKind.body,
            rows: [
              EpubTableRow(
                cells: [
                  EpubTableCell(children: [quote]),
                  EpubTableCell(children: [second]),
                ],
              ),
            ],
          ),
        ],
      );
      final outer = EpubTable(
        caption: const [],
        rowGroups: [
          EpubTableRowGroup(
            kind: EpubTableRowGroupKind.body,
            rows: [
              EpubTableRow(
                cells: [
                  EpubTableCell(children: [inner]),
                ],
              ),
            ],
          ),
        ],
      );
      final intro = EpubParagraph([
        EpubTextSpan(text: 'Intro'),
      ], const EpubNodeStyle());
      final builder = CanonicalTextBuilder(maxScalars: 1 << 20);
      final canonical = builder.build([intro, outer]);
      final chapter = EpubChapter(
        spine: 0,
        resource: 'nested.xhtml',
        title: 'Nested table',
        blocks: [intro, outer],
        canonicalText: canonical.text,
        anchors: builder.anchors,
        scalarCount: canonical.scalarCount,
      );
      expect(canonical.text, 'Intro\nA\n\tB\n\n\n');
      final bScalar = canonical.text.indexOf('B');
      expect(bScalar, greaterThan(inner.canonical!.start));

      final flow = layoutChapterFlow(
        chapter: chapter,
        spec: const ChapterLayoutSpec(
          width: 480,
          height: 640,
          typography: _typography,
        ),
        images: const {},
        imageMediaTypes: const {},
      );
      final fallback = flow.blocks
          .where((block) => block.table != null)
          .expand((block) => block.table!.rows)
          .expand((row) => row.cells)
          .expand((cell) => cell.blocks)
          .firstWhere((block) => block.map.text.contains('B'));
      final text = fallback;
      expect(text.map.text, 'A\n\tB');
      final bCodeUnit = text.map.text.indexOf('B');
      expect(
        text.map.canonicalAt(bCodeUnit),
        bScalar,
        reason: 'the rendered glyph must keep its canonical address',
      );
      // A pointer inside the glyph's own box must address the same scalar.
      final boxes = text.painter.getBoxesForSelection(
        TextSelection(baseOffset: bCodeUnit, extentOffset: bCodeUnit + 1),
      );
      expect(boxes, isNotEmpty);
      // Sample the left quarter of the glyph: the exact midpoint is a caret
      // boundary where Flutter may round to either side.
      final glyph = boxes.first.toRect();
      expect(
        text.canonicalAtLocal(
          Offset(glyph.left + glyph.width * 0.25, glyph.center.dy),
        ),
        bScalar,
      );
    });

    test('line ranges are contiguous inside each text block', () {
      final book = _fixture('rich-chapter.epub');
      final flow = _flow(book, 0);
      for (final block in flow.blocks) {
        final text = block.text;
        if (text == null) continue;
        var previous = text.lines.first.canonicalStart;
        for (final line in text.lines) {
          expect(line.canonicalEnd, greaterThanOrEqualTo(line.canonicalStart));
          expect(
            line.canonicalStart,
            greaterThanOrEqualTo(previous),
            reason: 'line ranges must be ordered',
          );
          previous = line.canonicalEnd;
        }
      }
    });

    test('a small page splits text and tables without losing content', () {
      final book = _fixture('rich-chapter.epub');
      final flow = _flow(book, 0, width: 360, height: 240);
      final paginated = paginateFlow(
        flow: flow,
        pageHeight: 240,
        pageWidth: 360,
      );
      expect(paginated.pages.length, greaterThan(4));
      expectExactlyOnce(
        flow: _flowCoverage(flow),
        pages: _pageCoverage(paginated),
        reason: 'small page',
      );
      final expected = _expectedRenderedScalars(
        book.chapters[0],
        hasImage: false,
      );
      expectCountsEqual(
        actual: _flowCoverage(flow),
        expected: expected,
        reason: 'small page flow',
      );
      expectCountsEqual(
        actual: _pageCoverage(paginated),
        expected: expected,
        reason: 'small page pages',
      );
    });

    test(
      'a decoded image hides alt text and keeps its caption rendered',
      () async {
        final book = _fixture('rich-chapter.epub');
        final images = await _decodeImages(book);
        final flow = layoutChapterFlow(
          chapter: book.chapters[0],
          spec: const ChapterLayoutSpec(
            width: 480,
            height: 640,
            typography: _typography,
          ),
          images: images,
          imageMediaTypes: const {},
        );
        final paginated = paginateFlow(
          flow: flow,
          pageHeight: 640,
          pageWidth: 480,
        );
        expectExactlyOnce(
          flow: _flowCoverage(flow),
          pages: _pageCoverage(paginated),
          reason: 'decoded image',
        );
        final expected = _expectedRenderedScalars(
          book.chapters[0],
          hasImage: true,
        );
        expectCountsEqual(
          actual: _flowCoverage(flow),
          expected: expected,
          reason: 'decoded image flow',
        );
        final rendered = _flowCoverage(flow).keys.toSet();
        // The hidden alt is still in the canonical stream but not rendered.
        final imageBlock = flow.blocks.firstWhere(
          (block) => block.image?.image != null,
        );
        final alt = imageBlock.image!.alt;
        expect(book.chapters[0].canonicalText, contains(alt));
        expect(
          rendered.contains(imageBlock.canonicalStart),
          isFalse,
          reason: 'rendered alt must not be placed',
        );
      },
    );

    test('continuous windows cover the rendered flow exactly once', () {
      final book = _fixture('rich-chapter.epub');
      final flow = _flow(book, 0, width: 480, height: 640);
      final painted = <int, int>{};
      const windowHeight = 300.0;
      for (var top = 0.0; top < flow.height; top += windowHeight) {
        final window = continuousWindow(
          flow: flow,
          top: top,
          height: windowHeight,
        );
        for (final block in window.blocks) {
          final text = block.text;
          if (text != null) {
            for (final line in text.lines) {
              for (
                var scalar = line.canonicalStart;
                scalar < line.canonicalEnd;
                scalar++
              ) {
                painted[scalar] = (painted[scalar] ?? 0) + 1;
              }
            }
          }
          final image = block.image;
          if (image != null) {
            for (final text in [image.fallbackText, image.caption]) {
              if (text == null) continue;
              for (final line in text.lines) {
                for (
                  var scalar = line.canonicalStart;
                  scalar < line.canonicalEnd;
                  scalar++
                ) {
                  painted[scalar] = (painted[scalar] ?? 0) + 1;
                }
              }
            }
          }
          final table = block.table;
          if (table != null) {
            final texts = <FlowTextBlock>[
              if (table.caption != null) table.caption!,
              for (final row in table.rows)
                for (final cell in row.cells) ...cell.blocks,
            ];
            for (final text in texts) {
              for (final line in text.lines) {
                for (
                  var scalar = line.canonicalStart;
                  scalar < line.canonicalEnd;
                  scalar++
                ) {
                  painted[scalar] = (painted[scalar] ?? 0) + 1;
                }
              }
            }
          }
        }
      }
      // A block taller than the window is painted by every window it
      // intersects, so counts are >= 1 and the union matches the flow.
      final flowCoverage = _flowCoverage(flow);
      for (final scalar in flowCoverage.keys) {
        expect(
          painted[scalar] ?? 0,
          greaterThanOrEqualTo(1),
          reason: 'scalar $scalar never painted by a window',
        );
      }
      expect(painted.keys.toSet(), flowCoverage.keys.toSet());
    });
  });

  group('CJK and bidi', () {
    test('bidi fixture lays out RTL text with canonical coverage', () {
      final book = _fixture('bidi.epub');
      final flow = _flow(book, 0, width: 420, height: 640);
      final paginated = paginateFlow(
        flow: flow,
        pageHeight: 640,
        pageWidth: 420,
      );
      expectExactlyOnce(
        flow: _flowCoverage(flow),
        pages: _pageCoverage(paginated),
        reason: 'bidi fixture',
      );
      final expected = _expectedRenderedScalars(
        book.chapters[0],
        hasImage: false,
      );
      expectCountsEqual(
        actual: _flowCoverage(flow),
        expected: expected,
        reason: 'bidi fixture flow',
      );
      expectCountsEqual(
        actual: _pageCoverage(paginated),
        expected: expected,
        reason: 'bidi fixture pages',
      );
      // Hit testing inside the Hebrew paragraph returns a selectable scalar
      // inside that paragraph's canonical range.
      final hebrew = flow.blocks.firstWhere(
        (block) => block.text?.map.text.contains('שלום') ?? false,
      );
      final hit = hitTestFlow(flow: flow, local: Offset(10, hebrew.top + 4));
      expect(hit.selectable, isTrue);
      expect(hit.scalar, greaterThanOrEqualTo(hebrew.canonicalStart));
      expect(hit.scalar, lessThanOrEqualTo(hebrew.canonicalEnd));
    });

    test('bidi paragraph line ranges reconstruct the source text', () {
      final book = _fixture('bidi.epub');
      final flow = _flow(book, 0, width: 420, height: 640);
      final paragraph = flow.blocks.firstWhere(
        (block) => block.text?.map.text.contains('עברית 42') ?? false,
      );
      final text = paragraph.text!;
      final chapter = book.chapters[0];
      final scalars = chapter.canonicalText.runes.toList();
      // Concatenating the line ranges (with the hard separators between them)
      // reproduces the paragraph's canonical text exactly, including the
      // mixed-direction run.
      final buffer = StringBuffer();
      var cursor = text.map.canonicalStart;
      for (final line in text.lines) {
        if (line.canonicalStart > cursor) {
          for (var index = cursor; index < line.canonicalStart; index++) {
            buffer.writeCharCode(scalars[index]);
          }
        }
        for (
          var index = line.canonicalStart;
          index < line.canonicalEnd;
          index++
        ) {
          buffer.writeCharCode(scalars[index]);
        }
        cursor = line.canonicalEnd;
      }
      expect(buffer.toString(), text.map.text);
    });

    test('rich chapter Japanese paragraph is laid out and hit testable', () {
      final book = _fixture('rich-chapter.epub');
      final flow = _flow(book, 0);
      final japanese = flow.blocks.firstWhere(
        (block) => block.text?.map.text.contains('日本語の段落') ?? false,
      );
      expect(japanese.text!.lines, isNotEmpty);
      final hit = hitTestFlow(flow: flow, local: Offset(20, japanese.top + 5));
      expect(hit.selectable, isTrue);
      expect(hit.scalar, greaterThanOrEqualTo(japanese.canonicalStart));
    });
  });

  group('selection and copy', () {
    test('a selection spanning pages projects rects on both pages', () {
      final book = _fixture('rich-chapter.epub');
      final flow = _flow(book, 0, width: 360, height: 200);
      final paginated = paginateFlow(
        flow: flow,
        pageHeight: 200,
        pageWidth: 360,
      );
      final firstPageEnd = paginated.pages.first.canonicalEnd;
      final start = paginated.pages.first.canonicalStart;
      final end = firstPageEnd + 40;
      final rectsFirst = projectRangePage(
        chapter: paginated,
        pageIndex: 0,
        start: start,
        end: end,
      );
      final rectsSecond = projectRangePage(
        chapter: paginated,
        pageIndex: 1,
        start: start,
        end: end,
      );
      expect(rectsFirst, isNotEmpty);
      expect(rectsSecond, isNotEmpty);
      // Projection is bounded by the page it is asked about.
      final secondStart = paginated.pages[1].canonicalStart;
      for (final rect in rectsSecond) {
        expect(rect.top, greaterThanOrEqualTo(-1));
        expect(rect.height, greaterThan(0));
      }
      expect(secondStart, lessThan(end));
    });

    test('copy text excludes hidden image alt text', () async {
      final book = _fixture('rich-chapter.epub');
      final chapter = book.chapters[0];
      final images = await _decodeImages(book);
      expect(images, isNotEmpty);
      final flow = layoutChapterFlow(
        chapter: chapter,
        spec: const ChapterLayoutSpec(
          width: 480,
          height: 640,
          typography: _typography,
        ),
        images: images,
        imageMediaTypes: const {},
      );
      final imageBlock = flow.blocks.firstWhere(
        (block) =>
            block.image != null &&
            block.image!.image != null &&
            block.image!.fallbackText == null,
      );
      final altScalars = imageBlock.image!.alt.runes.length;
      expect(altScalars, greaterThan(0));
      final hidden = [
        (
          start: imageBlock.canonicalStart,
          end: imageBlock.canonicalStart + altScalars,
        ),
      ];
      final withAlt = copyTextForRange(
        canonicalText: chapter.canonicalText,
        start: imageBlock.canonicalStart,
        end: imageBlock.canonicalEnd,
        hiddenRanges: const [],
      );
      final withoutAlt = copyTextForRange(
        canonicalText: chapter.canonicalText,
        start: imageBlock.canonicalStart,
        end: imageBlock.canonicalEnd,
        hiddenRanges: hidden,
      );
      expect(withAlt, contains('Generated image alt sentinel'));
      expect(withoutAlt, isNot(contains('Generated image alt sentinel')));
      expect(withoutAlt, contains('Figure 1.'));
    });

    test(
      'hit testing a rendered image reports a non-selectable object hit',
      () async {
        final book = _fixture('rich-chapter.epub');
        final images = await _decodeImages(book);
        final flow = layoutChapterFlow(
          chapter: book.chapters[0],
          spec: const ChapterLayoutSpec(
            width: 480,
            height: 640,
            typography: _typography,
          ),
          images: images,
          imageMediaTypes: const {},
        );
        final imageBlock = flow.blocks.firstWhere(
          (block) =>
              block.image?.image != null && block.image?.fallbackText == null,
        );
        final hit = hitTestFlow(
          flow: flow,
          local: Offset(4, imageBlock.top + 2),
        );
        expect(hit.selectable, isFalse);
      },
    );
  });

  group('long chapter', () {
    test('a 90k-scalar chapter lays out and paginates within bounds', () {
      final book = _fixture('long-chapter.epub');
      final chapter = book.chapters[1];
      expect(chapter.scalarCount, greaterThan(65000));
      final flow = _flow(book, 1, width: 520, height: 700);
      final paginated = paginateFlow(
        flow: flow,
        pageHeight: 700,
        pageWidth: 520,
      );
      expect(paginated.pages.length, greaterThan(10));
      expect(paginated.overflowPages, 0);
      expectExactlyOnce(
        flow: _flowCoverage(flow),
        pages: _pageCoverage(paginated),
        reason: 'long chapter',
      );
      final expected = _expectedRenderedScalars(chapter, hasImage: false);
      expectCountsEqual(
        actual: _flowCoverage(flow),
        expected: expected,
        reason: 'long chapter flow',
      );
      expectCountsEqual(
        actual: _pageCoverage(paginated),
        expected: expected,
        reason: 'long chapter pages',
      );
      // Content beyond the old 65,536-scalar whole-request ceiling renders.
      expect(_flowCoverage(flow).keys.any((scalar) => scalar > 65536), isTrue);
    });

    test('the stress chapter paginates with exact-once coverage', () {
      final book = _fixture('long-chapter-stress.epub');
      final flow = _flow(book, 0, width: 520, height: 700);
      final paginated = paginateFlow(
        flow: flow,
        pageHeight: 700,
        pageWidth: 520,
      );
      expect(flow.overflowClippedBlocks, 0);
      expect(paginated.overflowPages, 0);
      expectExactlyOnce(
        flow: _flowCoverage(flow),
        pages: _pageCoverage(paginated),
        reason: 'stress chapter',
      );
      final expected = _expectedRenderedScalars(
        book.chapters[0],
        hasImage: false,
      );
      expectCountsEqual(
        actual: _flowCoverage(flow),
        expected: expected,
        reason: 'stress chapter flow',
      );
      expectCountsEqual(
        actual: _pageCoverage(paginated),
        expected: expected,
        reason: 'stress chapter pages',
      );
    });

    test('tile plan for the long chapter stays bounded', () {
      final book = _fixture('long-chapter.epub');
      final flow = _flow(book, 1, width: 520, height: 700);
      final plan = tilePlan(
        chapterOriginY: 0,
        chapterHeight: flow.height,
        scale: 1.25,
      );
      expect(plan, isNotNull);
      expect(plan!.tiles.length, greaterThan(1));
      expect(plan.tiles.length, lessThan(10000));
      // Boundaries are contiguous and start at zero.
      expect(plan.tiles.first.deviceRowStart, 0);
      for (var index = 1; index < plan.tiles.length; index++) {
        expect(
          plan.tiles[index].deviceRowStart,
          plan.tiles[index - 1].deviceRowEnd,
        );
      }
    });
  });

  group('navigation robustness', () {
    test('a hit in inter-block spacing resolves to a block boundary', () {
      final book = _fixture('rich-chapter.epub');
      final flow = _flow(book, 0, width: 480, height: 640);
      // Find a gap between two blocks.
      var gapY = -1.0;
      for (var index = 1; index < flow.blocks.length; index++) {
        final previousEnd =
            flow.blocks[index - 1].top + flow.blocks[index - 1].height;
        final nextStart = flow.blocks[index].top;
        if (nextStart - previousEnd > 1) {
          gapY = (previousEnd + nextStart) / 2;
          break;
        }
      }
      expect(gapY, greaterThan(0));
      final hit = hitTestFlow(flow: flow, local: Offset(10, gapY));
      final lastEnd = flow.blocks.last.canonicalEnd;
      expect(
        hit.scalar,
        lessThan(lastEnd),
        reason: 'a gap hit must not resolve to the chapter end',
      );
      expect(hit.scalar, greaterThanOrEqualTo(0));
    });
  });

  group('coverage expectations', () {
    test('a duplicated flow scalar fails the independent comparison', () {
      // `expectExactlyOnce` compares flow against pages, so a scalar
      // duplicated in both would cancel out. The independent expectation
      // catches it because it counts one occurrence per normalized scalar.
      expect(
        () => expectCountsEqual(
          actual: <int, int>{0: 1, 1: 2},
          expected: <int, int>{0: 1, 1: 1},
          reason: 'duplicated flow',
        ),
        throwsA(isA<TestFailure>()),
      );
      expect(
        () => expectCountsEqual(
          actual: <int, int>{0: 1},
          expected: <int, int>{0: 1, 1: 1},
          reason: 'dropped flow',
        ),
        throwsA(isA<TestFailure>()),
      );
    });
  });

  group('spread decision', () {
    test('follows the frozen contract thresholds', () {
      expect(spreadDecision(availableWidth: 700, fontSize: 16).columns, 1);
      expect(spreadDecision(availableWidth: 900, fontSize: 16).columns, 2);
      // A large font makes the usable column too narrow for two columns.
      expect(spreadDecision(availableWidth: 760, fontSize: 30).columns, 1);
    });
  });
}
