import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_epub/shosai_epub.dart';
import 'package:shosai_flutter/reader/epub/content.dart';
import 'package:shosai_flutter/reader/epub/flow.dart';
import 'package:shosai_flutter/reader/epub/surface.dart';
import 'package:shosai_flutter/reader/epub/text_style.dart';

import '../support/epub_navigation_fixture.dart';

/// Vertical (`vertical-rl`) EPUB pages: the flow is laid out as horizontal
/// lines on a frame the page turns a quarter turn clockwise, so lines run down
/// the page and stack from its right edge, and the characters that stand
/// upright in vertical text are drawn turned back.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const typography = ReaderEpubTypography(
    fontFamily: 'Literata',
    fontFamilyFallback: ['Shippori Mincho', 'Noto Sans JP'],
    fontSize: 18,
    lineHeight: 1.6,
    palette: ReaderEpubPalette(
      background: Color(0xFFFFFFFF),
      foreground: Color(0xFF1A1A1A),
      link: Color(0xFF174EA6),
      tableHeaderBackground: Color(0xFFE8EEF8),
      tableHeaderBorder: Color(0xFF596B89),
    ),
  );

  ({ReaderEpubPage page, EpubChapter chapter}) verticalPage({
    Size windowSize = const Size(600, 800),
    bool spread = false,
  }) {
    final book = openEpubBytes(verticalJapaneseEpub(paragraphs: 30));
    final chapter = book.chapters.first;
    final pageSize = spread
        ? Size(epubSpreadPageWidth(windowSize.width), windowSize.height)
        : windowSize;
    final box = epubPageBoxFor(pageSize, vertical: true);
    final session = ChapterLayoutSession(
      chapter: chapter,
      spec: ChapterLayoutSpec(
        width: box.inlineExtent,
        height: box.blockExtent,
        typography: typography,
        vertical: true,
      ),
      images: const {},
    );
    addTearDown(session.dispose);
    session.layoutWindowAt(0);
    while (!session.complete) {
      if (session.layoutForward(maxNodes: 64, maxMicros: 20000) == 0) break;
    }
    return (
      page: pageWindowFor(
        session: session,
        scalar: 0,
        unit: chapter.spine,
        chapterCount: book.chapters.length,
        windowSize: windowSize,
        spread: spread,
        rightToLeft: true,
        vertical: true,
      ),
      chapter: chapter,
    );
  }

  test('kanji, kana, their punctuation, brackets and the long vowel mark '
      'are drawn upright; Latin, digits and dashes turn with the line', () {
    // The brackets, the wave dash and the long vowel mark (`Tr`) are drawn
    // upright in their vertical forms, as the small kana and the ideographic
    // comma and full stop (`Tu`) are.
    for (final upright in '吾輩はネコ。、ゃッ！？々〇１「」『』（）ー〜～：'.runes) {
      expect(
        isUprightInVertical(upright),
        isTrue,
        reason: String.fromCharCode(upright),
      );
    }
    for (final upright in '\uFE41\uFE48\uFE51\uFE59\uFE62'.runes) {
      expect(
        isUprightInVertical(upright),
        isTrue,
        reason: upright.toRadixString(16),
      );
    }
    // The overlines and low lines, the small em dash, hyphen-minus and
    // comparison signs are `R` too.
    for (final turned
        in 'Aa1 ,.…―－＜＞\uFE49\uFE4F\uFE58\uFE63\uFE64\uFE66'.runes) {
      expect(
        isUprightInVertical(turned),
        isFalse,
        reason: String.fromCharCode(turned),
      );
    }
  });

  test('a grapheme cluster keeps one orientation', () {
    final (:map, :upright, span: _) = buildBlockText(
      [EpubTextSpan(text: '葛\u{E0100}城 e\u0301 👩\u200D💻')],
      typography,
      18,
      vertical: true,
    );
    final runs = [
      for (final run in upright)
        map.text.substring(
          run.start - map.codeUnitOffset,
          run.end - map.codeUnitOffset,
        ),
    ];
    // The ideograph keeps its variation selector and the emoji its joined
    // parts; the accented Latin letter turns with the line, mark and all.
    expect(runs, ['葛\u{E0100}城', '👩\u200D💻']);
  });

  test('a page box turns the flow a quarter turn clockwise', () {
    final box = epubPageBoxFor(const Size(600, 800), vertical: true);
    expect(box.inlineExtent, box.contentHeight);
    expect(box.blockExtent, box.contentWidth);
    // The flow's origin is the content's top-right corner, its x axis runs
    // down the page and its y axis to the left.
    expect(
      box.toPage(Offset.zero),
      Offset(box.origin.dx + box.contentWidth, box.origin.dy),
    );
    expect(
      box.toPage(const Offset(10, 0)),
      Offset(box.origin.dx + box.contentWidth, box.origin.dy + 10),
    );
    expect(
      box.toPage(const Offset(0, 10)),
      Offset(box.origin.dx + box.contentWidth - 10, box.origin.dy),
    );
    const point = Offset(37, 91);
    expect(box.toFlow(box.toPage(point)), point);
    expect(
      box.rectToPage(const Rect.fromLTRB(10, 20, 30, 50)),
      Rect.fromLTRB(
        box.origin.dx + box.contentWidth - 50,
        box.origin.dy + 10,
        box.origin.dx + box.contentWidth - 20,
        box.origin.dy + 30,
      ),
    );
  });

  test('a vertical page reads down its columns, from right to left', () {
    final (:page, :chapter) = verticalPage();
    expect(chapter.writingMode, EpubWritingMode.verticalRl);
    expect(page.box.vertical, isTrue);
    final box = page.box;
    final content = Rect.fromLTWH(
      box.origin.dx,
      box.origin.dy,
      box.contentWidth,
      box.contentHeight,
    );

    final surface = page.surface;
    expect(surface.endpoints, isNotEmpty);
    for (final endpoint in surface.endpoints) {
      final rect = endpoint.rect;
      expect(
        content.inflate(0.5).contains(Offset(rect.left, rect.top)) &&
            content.inflate(0.5).contains(Offset(rect.right, rect.bottom)),
        isTrue,
        reason: 'every character is on the page',
      );
    }
    // The heading's first character is at the top of the rightmost column,
    // and the next one is below it in the same column.
    Rect charAt(int offset) {
      final halves = [
        for (final endpoint in surface.endpoints)
          if (endpoint.rangeStart.toInt() == offset)
            Rect.fromLTRB(
              endpoint.rect.left,
              endpoint.rect.top,
              endpoint.rect.right,
              endpoint.rect.bottom,
            ),
      ];
      return halves.reduce((a, b) => a.expandToInclude(b));
    }

    final first = charAt(0);
    final second = charAt(1);
    expect(first.right, closeTo(content.right, 1));
    expect(first.top, closeTo(content.top, 1));
    expect(second.top, closeTo(first.bottom, 0.5));
    expect(second.left, closeTo(first.left, 0.5));
    // The top half of a character starts it; the bottom half ends it.
    final halves = surface.endpoints
        .where((endpoint) => endpoint.rangeStart.toInt() == 0)
        .toList();
    expect(halves.first.offset.toInt(), 0);
    expect(halves.first.rect.bottom, lessThanOrEqualTo(halves.last.rect.top));
    expect(halves.last.offset.toInt(), 1);

    // Visual lines are columns: their carets are vertical and run down the
    // page, and each column is left of the one before it.
    double? previousX;
    for (final line in surface.visualLines) {
      final carets = line.carets;
      expect(carets.every((caret) => caret.vertical), isTrue);
      for (var index = 1; index < carets.length; index += 1) {
        expect(
          carets[index].alongLine,
          greaterThan(carets[index - 1].alongLine),
        );
        expect(carets[index].x, carets.first.x);
      }
      if (previousX != null) expect(carets.first.x, lessThan(previousX));
      previousX = carets.first.x;
    }
    expect(surface.visualLines.length, greaterThan(5));
  });

  test('a vertical spread puts its first page on the right', () {
    final (:page, chapter: _) = verticalPage(
      windowSize: const Size(1280, 800),
      spread: true,
    );
    expect(page.spread, isTrue);
    expect(page.facing, isNotNull);
    expect(page.box.origin.dx, greaterThan(page.facingBox!.origin.dx));
    expect(page.facingBox!.vertical, isTrue);
    final facingStart = page.facing!.canonicalStart;
    for (final endpoint in page.surface.endpoints) {
      final onFacing = endpoint.rangeStart.toInt() >= facingStart;
      final slot = onFacing ? page.facingBox! : page.box;
      expect(
        endpoint.rect.left,
        greaterThanOrEqualTo(slot.origin.dx - 0.5),
        reason: 'each page\'s text stays in its own slot',
      );
      expect(
        endpoint.rect.right,
        lessThanOrEqualTo(slot.origin.dx + slot.contentWidth + 0.5),
      );
    }
  });

  test('a vertical block lays its upright characters out transparent, to '
      'draw them upright itself', () {
    final (:page, chapter: _) = verticalPage();
    final blocks = [
      for (final slice in page.page.slices) ...placedPageText(slice),
    ].map((placed) => placed.block).toSet();
    final mixed = blocks.firstWhere(
      (block) => block.map.text.contains('Hello'),
    );
    final runs = [
      for (final run in mixed.upright)
        mixed.map.text.substring(
          run.start - mixed.map.codeUnitOffset,
          run.end - mixed.map.codeUnitOffset,
        ),
    ];
    expect(runs, ['「', '」と書生は言った。明治', '年、', '年のことである。']);
    for (final run in mixed.upright) {
      expect(run.style.color, typography.palette.foreground);
    }

    // The laid-out paragraph keeps every character, so line breaking and
    // selection see the text; the upright ones are transparent there.
    final laidOut = <String, Color?>{};
    mixed.painter.text!.visitChildren((span) {
      if (span is TextSpan && span.text != null) {
        laidOut[span.text!] = span.style?.color;
      }
      return true;
    });
    for (final run in runs) {
      expect(laidOut[run]!.a, 0, reason: run);
    }
    expect(laidOut['Hello, world'], typography.palette.foreground);
  });

  test('images in a vertical flow are measured turned', () async {
    final image = await createTestImage(width: 300, height: 100);
    final chapter = EpubChapter(
      spine: 0,
      resource: 'OPS/Text/image.xhtml',
      title: '',
      blocks: [EpubImage(src: 'OPS/Images/wide.png', alt: '')],
      canonicalText: '',
      anchors: const {},
      scalarCount: 0,
      writingMode: EpubWritingMode.verticalRl,
    );
    final flow = layoutChapterFlow(
      chapter: chapter,
      spec: const ChapterLayoutSpec(
        width: 600,
        height: 400,
        typography: typography,
        vertical: true,
      ),
      images: {'OPS/Images/wide.png': image},
    );
    final laid = flow.blocks.single.image!;
    expect(laid.quarterTurned, isTrue);
    // A wide image is short along the column (the flow's width) and wide
    // across the page (the flow's height).
    expect(laid.width / laid.height, closeTo(100 / 300, 1e-6));
    disposeFlowBlocks(flow.blocks);
  });
}
