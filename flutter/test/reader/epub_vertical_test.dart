import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_epub/shosai_epub.dart';
import 'package:shosai_flutter/core/bridge.dart';
import 'package:shosai_flutter/reader/epub/content.dart';
import 'package:shosai_flutter/reader/epub/flow.dart';
import 'package:shosai_flutter/reader/epub/surface.dart';
import 'package:shosai_flutter/reader/epub/text_style.dart';

import '../support/epub_navigation_fixture.dart';
import '../support/production_shell_harness.dart';

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
    Uint8List? epub,
  }) {
    final book = openEpubBytes(epub ?? verticalJapaneseEpub(paragraphs: 30));
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
    final (
      :map,
      redrawn: upright,
      span: _,
      rubies: _,
      emphasis: _,
    ) = buildBlockText(
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
      for (final run in mixed.redrawn)
        mixed.map.text.substring(
          run.start - mixed.map.codeUnitOffset,
          run.end - mixed.map.codeUnitOffset,
        ),
    ];
    expect(runs, ['「', '」と書生は言った。明治', '38', '年、', '年のことである。']);
    expect(
      [for (final run in mixed.redrawn) run.combined],
      [false, false, true, false, false],
    );
    for (final run in mixed.redrawn) {
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
    // Tate-chū-yoko is laid out a grapheme at a time.
    for (final run in runs) {
      for (final text in laidOut.containsKey(run) ? [run] : run.split('')) {
        expect(laidOut[text]!.a, 0, reason: text);
      }
    }
    expect(laidOut['Hello, world'], typography.palette.foreground);
  });

  /// The laid-out width of each upright run of [spans], and whether it is
  /// tate-chū-yoko.
  List<(String, double, bool)> uprightWidths(List<EpubTextSpan> spans) {
    final (:map, redrawn: upright, :span, rubies: _, emphasis: _) =
        buildBlockText(spans, typography, 18, vertical: true);
    final painter = TextPainter(text: span, textDirection: TextDirection.ltr)
      ..layout();
    addTearDown(painter.dispose);
    return [
      for (final run in upright)
        (
          map.text.substring(run.start, run.end),
          painter
              .getBoxesForSelection(
                TextSelection(baseOffset: run.start, extentOffset: run.end),
              )
              .fold(0.0, (width, box) => width + box.right - box.left),
          run.combined,
        ),
    ];
  }

  test('tate-chū-yoko lays its text out one em long and draws it as one '
      'upright unit', () {
    final runs = uprightWidths([
      EpubTextSpan(text: '明治'),
      EpubTextSpan(text: '38', combine: const EpubTextCombine.all()),
      EpubTextSpan(text: '年'),
      EpubTextSpan(text: '!?', combine: const EpubTextCombine.all()),
    ]);
    expect(
      [for (final run in runs) (run.$1, run.$3)],
      [('明治', false), ('38', true), ('年', false), ('!?', true)],
    );
    expect(runs[1].$2, closeTo(18, 0.01));
    expect(runs[3].$2, closeTo(18, 0.01));
  });

  test('text-combine-upright: digits combines only short digit runs', () {
    final runs = uprightWidths([
      EpubTextSpan(
        text: '令和5年12月31日、2024年',
        combine: const EpubTextCombine.digits(2),
      ),
    ]);
    expect(
      [
        for (final run in runs)
          if (run.$3) run.$1,
      ],
      ['5', '12', '31'],
    );
    for (final run in runs.where((run) => run.$3)) {
      expect(run.$2, closeTo(18, 0.01), reason: run.$1);
    }
    // The long run turns with the line, as Latin digits do.
    expect(
      [
        for (final run in runs)
          if (!run.$3) run.$1,
      ],
      ['令和', '年', '月', '日、', '年'],
    );
  });

  test('text-orientation: upright stands each Latin letter and digit up in '
      'an em of its own', () {
    final runs = uprightWidths([
      EpubTextSpan(text: '西暦'),
      EpubTextSpan(text: '1905年', orientation: EpubTextOrientation.upright),
    ]);
    expect(
      [for (final run in runs) (run.$1, run.$3)],
      [
        ('西暦', false),
        ('1', true),
        ('9', true),
        ('0', true),
        ('5', true),
        ('年', false),
      ],
    );
    for (final run in runs.where((run) => run.$3)) {
      expect(run.$2, closeTo(18, 0.01), reason: run.$1);
    }
  });

  test('text-orientation: upright leaves a preserved line break alone, and '
      'falls back where it cannot stand a letter in one em', () async {
    final arabic = FontLoader('Noto Sans Arabic')
      ..addFont(
        File(
          '../fixtures/fonts/NotoSansArabic.ttf',
        ).readAsBytes().then(ByteData.sublistView),
      );
    await arabic.load();
    final built = buildBlockText(
      [
        EpubTextSpan(
          text: 'A\nB',
          preserveWhitespace: true,
          orientation: EpubTextOrientation.upright,
        ),
        EpubTextSpan(
          text: '\u0644\u0627',
          orientation: EpubTextOrientation.upright,
        ),
      ],
      typography.copyWith(
        fontFamilyFallback: [
          ...typography.fontFamilyFallback,
          'Noto Sans Arabic',
        ],
      ),
      18,
      vertical: true,
    );
    expect(built.span.toPlainText(), built.map.text);
    expect(
      [
        for (final run in built.redrawn)
          if (run.combined) built.map.text.substring(run.start, run.end),
      ],
      ['A', 'B'],
    );
  });

  test('an upright Latin letter selects by its top and bottom halves, as '
      'other characters of its column do', () {
    final (:page, :chapter) = verticalPage(
      epub: buildTestEpub(
        chapters: {
          'OPS/Text/chapter-1.xhtml':
              '<p>西暦<span style="text-orientation: upright">AB</span>年</p>',
        },
        nav: '<ol><li><a href="../Text/chapter-1.xhtml">一</a></li></ol>',
        pageProgression: 'rtl',
        bodyAttributes: ' style="writing-mode: vertical-rl"',
      ),
    );
    final a = chapter.canonicalText.indexOf('A');
    final halves = [
      for (final endpoint in page.surface.endpoints)
        if (endpoint.rangeStart.toInt() == a) endpoint,
    ]..sort((x, y) => x.rect.top.compareTo(y.rect.top));
    expect(halves, hasLength(2));
    expect(halves.first.offset.toInt(), a);
    expect(halves.last.offset.toInt(), a + 1);
    expect(halves.first.rect.bottom, lessThanOrEqualTo(halves.last.rect.top));
    expect(halves.first.rect.left, closeTo(halves.last.rect.left, 0.5));
    expect(halves.first.rect.right, closeTo(halves.last.rect.right, 0.5));
  });

  test('text-orientation: sideways turns kanji and kana with the line', () {
    final runs = uprightWidths([
      EpubTextSpan(text: '吾輩は'),
      EpubTextSpan(text: '猫', orientation: EpubTextOrientation.sideways),
      EpubTextSpan(text: 'である'),
    ]);
    expect([for (final run in runs) run.$1], ['吾輩は', 'である']);
  });

  test('text-combine-upright: digits keeps a keycap or a marked digit whole, '
      'so the laid-out text stays the mapped text', () {
    final built = buildBlockText(
      [
        EpubTextSpan(
          text: '第1\uFE0F\u20E3話12\u0301月、5',
          combine: const EpubTextCombine.digits(2),
        ),
        EpubTextSpan(text: '7\u0301', combine: const EpubTextCombine.digits(2)),
        EpubTextSpan(text: '日'),
      ],
      typography,
      18,
      vertical: true,
    );
    final laidOut = built.span.toPlainText();
    expect(laidOut.length, built.map.text.length);
    expect(laidOut.substring(laidOut.length - 1), '日');
    expect(
      [
        for (final run in built.redrawn)
          if (run.combined) built.map.text.substring(run.start, run.end),
      ],
      ['5'],
    );
  });

  test('a line never breaks inside tate-chū-yoko, even with half an em '
      'left', () {
    final built = buildBlockText(
      [
        EpubTextSpan(text: '甲'),
        EpubTextSpan(text: '一二', combine: const EpubTextCombine.all()),
        EpubTextSpan(text: '乙'),
      ],
      typography,
      18,
      vertical: true,
    );
    final painter = TextPainter(
      text: built.span,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: 27);
    addTearDown(painter.dispose);
    final run = built.redrawn.singleWhere((run) => run.combined);
    final tops = {
      for (var unit = run.start; unit < run.end; unit++)
        for (final box in painter.getBoxesForSelection(
          TextSelection(baseOffset: unit, extentOffset: unit + 1),
        ))
          box.top,
    };
    expect(tops, hasLength(1));
    final width = painter
        .getBoxesForSelection(
          TextSelection(baseOffset: run.start, extentOffset: run.end),
        )
        .fold(0.0, (width, box) => width + box.right - box.left);
    expect(width, closeTo(18, 0.01));
  });

  test('tate-chū-yoko selects its characters where they are drawn, side by '
      'side across the column', () {
    final (:page, :chapter) = verticalPage();
    final text = chapter.canonicalText;
    final three = text.indexOf('明治38') + 2;
    final surface = page.surface;
    Rect charAt(int offset) => [
      for (final endpoint in surface.endpoints)
        if (endpoint.rangeStart.toInt() == offset)
          Rect.fromLTRB(
            endpoint.rect.left,
            endpoint.rect.top,
            endpoint.rect.right,
            endpoint.rect.bottom,
          ),
    ].reduce((a, b) => a.expandToInclude(b));
    final first = charAt(three);
    final second = charAt(three + 1);
    // 3 is drawn left of 8, in the same em of the column.
    expect(second.left, closeTo(first.right, 0.5));
    expect(second.top, closeTo(first.top, 0.5));
    expect(second.bottom, closeTo(first.bottom, 0.5));
    // Each character's left half starts it and its right half ends it.
    final halves = surface.endpoints
        .where((endpoint) => endpoint.rangeStart.toInt() == three + 1)
        .toList();
    final left = halves.reduce((a, b) => a.rect.left < b.rect.left ? a : b);
    final right = halves.reduce((a, b) => a.rect.left < b.rect.left ? b : a);
    expect(left.offset.toInt(), three + 1);
    expect(right.offset.toInt(), three + 2);
    // Carets keep reading order along the column.
    final line = surface.visualLines.firstWhere(
      (line) => line.carets.any((caret) => caret.offset.toInt() == three + 1),
    );
    final offsets = [for (final caret in line.carets) caret.offset.toInt()];
    final at = offsets.indexOf(three);
    expect(offsets.sublist(at, at + 3), [three, three + 1, three + 2]);
  });

  test('tate-chū-yoko on a later line of its block selects in its own '
      'column', () {
    const tcy = '<span style="text-combine-upright: all">38</span>';
    final (:page, :chapter) = verticalPage(
      epub: buildTestEpub(
        chapters: {
          'OPS/Text/chapter-1.xhtml': '<p>${'名前はまだ無い。明治$tcy年。' * 12}</p>',
        },
        nav: '<ol><li><a href="../Text/chapter-1.xhtml">一</a></li></ol>',
        pageProgression: 'rtl',
        bodyAttributes: ' style="writing-mode: vertical-rl"',
      ),
    );
    final surface = page.surface;
    final text = chapter.canonicalText;
    Rect area(FlutterSelectionEndpoint endpoint) => Rect.fromLTRB(
      endpoint.rect.left,
      endpoint.rect.top,
      endpoint.rect.right,
      endpoint.rect.bottom,
    );
    final columns = <double>{};
    for (
      var three = text.indexOf('38');
      three >= 0 && three < page.page.canonicalEnd;
      three = text.indexOf('38', three + 1)
    ) {
      final halves = [
        for (final endpoint in surface.endpoints)
          if (endpoint.rangeStart.toInt() == three ||
              endpoint.rangeStart.toInt() == three + 1)
            endpoint,
      ];
      expect(halves, hasLength(4), reason: '$three');
      for (final half in halves) {
        expect(area(half).width, greaterThan(0), reason: '$three');
        expect(area(half).height, greaterThan(0), reason: '$three');
      }
      final cell = halves.map(area).reduce((a, b) => a.expandToInclude(b));
      // The digits' cell is centred on their column's carets.
      final caret = surface.visualLines
          .expand((line) => line.carets)
          .firstWhere((caret) => caret.offset.toInt() == three + 1);
      expect(cell.center.dx, closeTo(caret.x, 1), reason: '$three');
      columns.add(caret.x);
    }
    expect(columns.length, greaterThan(2), reason: 'later lines are covered');
  });

  test('tate-chū-yoko stays one em with a ligature in its font', () async {
    await loadHarnessFonts();
    final built = buildBlockText(
      [
        EpubTextSpan(text: '甲'),
        EpubTextSpan(text: 'affi', combine: const EpubTextCombine.all()),
        EpubTextSpan(text: '乙'),
      ],
      typography,
      18,
      vertical: true,
    );
    final painter = TextPainter(
      text: built.span,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: 27);
    addTearDown(painter.dispose);
    final run = built.redrawn.singleWhere((run) => run.combined);
    final boxes = painter.getBoxesForSelection(
      TextSelection(baseOffset: run.start, extentOffset: run.end),
    );
    expect({for (final box in boxes) box.top}, hasLength(1));
    expect(
      boxes.fold(0.0, (width, box) => width + box.right - box.left),
      closeTo(18, 0.01),
    );
  });

  test('tate-chū-yoko the text engine cannot space turns with the line '
      'instead', () async {
    // Flutter leaves an Arabic run's letter spacing out, so lam-alef
    // cannot be made one em long.
    final arabic = FontLoader('Noto Sans Arabic')
      ..addFont(
        File(
          '../fixtures/fonts/NotoSansArabic.ttf',
        ).readAsBytes().then(ByteData.sublistView),
      );
    await arabic.load();
    final built = buildBlockText(
      [
        EpubTextSpan(text: '甲'),
        EpubTextSpan(
          text: '\u0644\u0627\u0644\u0627',
          combine: const EpubTextCombine.all(),
        ),
        EpubTextSpan(text: '38', combine: const EpubTextCombine.all()),
      ],
      typography.copyWith(
        fontFamilyFallback: [
          ...typography.fontFamilyFallback,
          'Noto Sans Arabic',
        ],
      ),
      18,
      vertical: true,
    );
    expect(built.span.toPlainText(), built.map.text);
    expect(
      [
        for (final run in built.redrawn)
          (built.map.text.substring(run.start, run.end), run.combined),
      ],
      [('甲', false), ('38', true)],
    );
    final painter = TextPainter(
      text: built.span,
      textDirection: TextDirection.ltr,
    )..layout();
    addTearDown(painter.dispose);
    final run = built.redrawn.last;
    expect(
      painter
          .getBoxesForSelection(
            TextSelection(baseOffset: run.start, extentOffset: run.end),
          )
          .fold(0.0, (width, box) => width + box.right - box.left),
      closeTo(18, 0.01),
    );
  });

  test('tate-chū-yoko keeps the line breaking rules of its text', () async {
    await loadHarnessFonts();
    // A closing full stop may not start a line: with no room for it after
    // 38, the line breaks before 38 rather than between 38 and 。.
    final built = buildBlockText(
      [
        EpubTextSpan(text: '甲'),
        EpubTextSpan(text: '38', combine: const EpubTextCombine.all()),
        EpubTextSpan(text: '。乙'),
      ],
      typography,
      18,
      vertical: true,
    );
    final painter = TextPainter(
      text: built.span,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: 36);
    addTearDown(painter.dispose);
    final stop = built.map.text.indexOf('。');
    final eight = built.map.text.indexOf('8');
    int line(int unit) =>
        painter.getLineBoundary(TextPosition(offset: unit)).start;
    expect(line(stop), line(eight));
  });

  /// A vertical chapter whose first paragraph breaks a two-em line inside
  /// its tate-chū-yoko, and whose second does not.
  EpubBook brokenCombinedBook() {
    const tcy = '<span style="text-combine-upright: all">';
    return openEpubBytes(
      buildTestEpub(
        chapters: {
          'OPS/Text/chapter-1.xhtml':
              '<p>甲$tcy一二</span>。乙</p><p>丙${tcy}38</span>。丁</p>',
        },
        nav: '<ol><li><a href="../Text/chapter-1.xhtml">一</a></li></ol>',
        pageProgression: 'rtl',
        bodyAttributes: ' style="writing-mode: vertical-rl"',
      ),
    );
  }

  test('tate-chū-yoko whose text breaks a line inside it is laid out '
      'without it', () async {
    await loadHarnessFonts();
    // A line may break between 一 and 二 but not before 。, so with two ems
    // to a line the run's empty second character would start the next one.
    final book = brokenCombinedBook();
    final session = ChapterLayoutSession(
      chapter: book.chapters.first,
      spec: const ChapterLayoutSpec(
        width: 36,
        height: 600,
        typography: typography,
        vertical: true,
      ),
      images: const {},
    );
    addTearDown(session.dispose);
    session.layoutWindowAt(0);
    final blocks = [for (final block in session.blocks) block.text!];
    for (final block in blocks) {
      for (final run in block.redrawn.where((run) => run.combined)) {
        expect(
          block.painter.getLineBoundary(TextPosition(offset: run.start)),
          block.painter.getLineBoundary(TextPosition(offset: run.end - 1)),
        );
      }
    }
    String combined(FlowTextBlock block) => [
      for (final run in block.redrawn)
        if (run.combined) block.map.text.substring(run.start, run.end),
    ].join();
    // 一二 falls back to upright characters; 38 stays combined.
    expect(blocks.map(combined), ['', '38']);
    expect(
      blocks.first.redrawn.map((run) => run.combined),
      everyElement(false),
    );
  });

  test('a block laid out again without tate-chū-yoko releases the painter '
      'it set aside, once', () async {
    await loadHarnessFonts();
    final book = brokenCombinedBook();
    ChapterLayoutSession session() => ChapterLayoutSession(
      chapter: book.chapters.first,
      spec: const ChapterLayoutSpec(
        width: 36,
        height: 600,
        typography: typography,
        vertical: true,
      ),
      images: const {},
    );

    final laidOut = session()..debugObservePainters = true;
    addTearDown(laidOut.dispose);
    laidOut.layoutWindowAt(0);
    // The first paragraph's painter is set aside and released; its second
    // attempt and the next paragraph's are kept.
    expect(
      [
        for (final painter in laidOut.debugCreatedPainters)
          painter.debugDisposed,
      ],
      [true, false, false],
    );

    // A failure in the second attempt releases what is left, and does not
    // release the set-aside painter twice.
    final failed = session()..debugFailTextBlockAt = 2;
    addTearDown(failed.dispose);
    expect(() => failed.layoutWindowAt(0), throwsA(isA<StateError>()));
    expect(
      [
        for (final painter in failed.debugCreatedPainters)
          painter.debugDisposed,
      ],
      [true, true],
    );
  });

  test('a line of tate-chū-yoko alone keeps the line height', () {
    double lineHeight(double factor) {
      final built = buildBlockText(
        [EpubTextSpan(text: '38', combine: const EpubTextCombine.all())],
        typography.copyWith(lineHeight: factor),
        18,
        vertical: true,
      );
      final painter = TextPainter(
        text: built.span,
        textDirection: TextDirection.ltr,
      )..layout();
      addTearDown(painter.dispose);
      return painter.height;
    }

    expect(lineHeight(2), closeTo(36, 1));
    expect(lineHeight(2), greaterThan(lineHeight(1.6)));
  });

  test('horizontal text ignores tate-chū-yoko', () {
    final built = buildBlockText(
      [EpubTextSpan(text: '38', combine: const EpubTextCombine.all())],
      typography,
      18,
    );
    expect(built.redrawn, isEmpty);
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
