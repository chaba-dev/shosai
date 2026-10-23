import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_epub/shosai_epub.dart';
import 'package:shosai_flutter/reader/epub/flow.dart';
import 'package:shosai_flutter/reader/epub/pages.dart';
import 'package:shosai_flutter/reader/epub/surface.dart';
import 'package:shosai_flutter/reader/epub/text_style.dart';

/// Emphasis marks (傍点): a shape half the characters' size, set over each
/// character that is not punctuation or a space (to its right in a vertical
/// line), or under it (to its left).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const typography = ReaderEpubTypography(
    fontFamily: 'Literata',
    fontFamilyFallback: ['Shippori Mincho', 'Noto Sans JP'],
    fontSize: 20,
    lineHeight: 1.75,
    palette: ReaderEpubPalette(
      background: Color(0xFFFFFFFF),
      foreground: Color(0xFF1A1A1A),
      link: Color(0xFF174EA6),
      tableHeaderBackground: Color(0xFFE8EEF8),
      tableHeaderBorder: Color(0xFF596B89),
    ),
  );

  const sesame = EpubTextEmphasis();

  EpubChapter chapterOf(List<EpubTextSpan> spans) => EpubChapter(
    spine: 0,
    resource: 'OPS/Text/emphasis.xhtml',
    title: '',
    blocks: [EpubParagraph(spans, const EpubNodeStyle())],
    canonicalText: spans.map((span) => span.text).join(),
    anchors: const {},
    scalarCount: spans.map((span) => span.text.runes.length).fold(0, (a, b) {
      return a + b;
    }),
  );

  FlowTextBlock layOut(
    List<EpubTextSpan> spans, {
    bool vertical = false,
    ReaderEpubTypography typography = typography,
  }) {
    final flow = layoutChapterFlow(
      chapter: chapterOf(spans),
      spec: ChapterLayoutSpec(
        width: 400,
        height: 400,
        typography: typography,
        vertical: vertical,
      ),
      images: const {},
    );
    addTearDown(() => disposeFlowBlocks(flow.blocks));
    return flow.blocks.single.text!;
  }

  /// The rows (or columns) that [paint] inks inside [area].
  Future<Rect?> inkOf(
    FlowTextBlock text,
    Rect area,
    void Function(Canvas canvas) paint,
  ) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.translate(0, 60);
    paint(canvas);
    final image = await recorder.endRecording().toImage(400, 200);
    final bytes = (await image.toByteData())!;
    image.dispose();
    Rect? ink;
    for (var y = area.top.floor(); y < area.bottom.ceil(); y++) {
      for (var x = area.left.floor(); x < area.right.ceil(); x++) {
        if (bytes.getUint8((y * 400 + x) * 4 + 3) > 64) {
          final pixel = Rect.fromLTWH(x.toDouble(), y.toDouble(), 1, 1);
          ink = ink?.expandToInclude(pixel) ?? pixel;
        }
      }
    }
    return ink;
  }

  test(
    'marks follow the CSS punctuation, separator and control exceptions',
    () {
      final built = buildBlockText(
        [
          EpubTextSpan(text: '甲'),
          EpubTextSpan(
            text: '猫、#﹟％＆＠で ある。 \u0301\u0001\u200E\u0378😀',
            emphasis: sesame,
          ),
        ],
        typography,
        20,
      );
      final run = built.emphasis.single;
      expect(
        [
          for (final c in run.characters)
            built.map.text.substring(c.start, c.end),
        ],
        ['猫', '#', '﹟', '％', '＆', '＠', 'で', 'あ', 'る', ' \u0301', '😀'],
      );
      expect(run.baseSize, 20);
      expect(run.color, typography.palette.foreground);
      // A horizontal line's default shape is a circle, a vertical one's sesame.
      expect(run.shape, EpubEmphasisShape.circle);
      expect(
        buildBlockText(
          [EpubTextSpan(text: '猫', emphasis: sesame)],
          typography,
          20,
          vertical: true,
        ).emphasis.single.shape,
        EpubEmphasisShape.sesame,
      );
    },
  );

  test(
    'a string mark keeps the base font style and stays upright vertically',
    () {
      final mark = buildBlockText(
        [
          EpubTextSpan(
            text: '猫',
            bold: true,
            italic: true,
            emphasis: const EpubTextEmphasis(string: 'x'),
          ),
        ],
        typography,
        20,
        vertical: true,
      ).emphasis.single.string!;
      final glyph = mark.redrawn.single;
      expect(glyph.combined, isTrue, reason: 'the Latin mark stands upright');
      expect(glyph.style.fontWeight, FontWeight.bold);
      expect(glyph.style.fontStyle, FontStyle.italic);
    },
  );

  test('the side follows the line: under a horizontal one, left of a '
      'vertical one', () {
    for (final (vertical, emphasis, under) in [
      (false, const EpubTextEmphasis(under: true), true),
      (false, const EpubTextEmphasis(left: true), false),
      (true, const EpubTextEmphasis(left: true), true),
      (true, const EpubTextEmphasis(under: true), false),
    ]) {
      final run = buildBlockText(
        [EpubTextSpan(text: '猫', emphasis: emphasis)],
        typography,
        20,
        vertical: vertical,
      ).emphasis.single;
      expect(run.under, under, reason: '$vertical $emphasis');
      expect(run.vertical, vertical);
    }
  });

  for (final vertical in [false, true]) {
    final mode = vertical ? 'vertical' : 'horizontal';

    test('$mode: a mark stands over its character, centred on it, outside '
        'a clip to the line', () async {
      final text = layOut([
        EpubTextSpan(text: '吾'),
        EpubTextSpan(text: '猫', emphasis: sesame),
      ], vertical: vertical);
      final box = text.painter
          .getBoxesForSelection(
            const TextSelection(baseOffset: 1, extentOffset: 2),
          )
          .single
          .toRect()
          .shift(const Offset(0, 60));
      final line = text.lines.single;
      final mark = await inkOf(text, const Rect.fromLTWH(0, 0, 400, 200), (
        canvas,
      ) {
        canvas.save();
        canvas.clipRect(
          Rect.fromLTWH(0, 60 + line.top, text.width, line.height),
        );
        text.paint(canvas, ruby: false);
        canvas.restore();
        canvas.clipRect(Rect.fromLTWH(0, 0, 400, 60 + box.center.dy - 10));
        text.paintRuby(canvas);
      });
      expect(mark, isNotNull);
      // Half an em square standing on the character's em square.
      final emTop = box.center.dy - 10;
      expect(mark!.bottom, lessThanOrEqualTo(emTop + 0.5));
      expect(mark.top, greaterThanOrEqualTo(emTop - 10 - 0.5));
      expect(mark.center.dx, closeTo(box.center.dx, 1.5));
    });
  }

  test('marks under the line stand under the em square', () async {
    final text = layOut([
      EpubTextSpan(text: '猫', emphasis: const EpubTextEmphasis(under: true)),
    ]);
    final box = text.painter
        .getBoxesForSelection(
          const TextSelection(baseOffset: 0, extentOffset: 1),
        )
        .single
        .toRect()
        .shift(const Offset(0, 60));
    final emBottom = box.center.dy + 10;
    final mark = await inkOf(
      text,
      Rect.fromLTRB(0, emBottom, 400, 200),
      text.paintRuby,
    );
    expect(mark, isNotNull);
    expect(mark!.top, greaterThanOrEqualTo(emBottom - 0.5));
    expect(mark.bottom, lessThanOrEqualTo(emBottom + 10 + 0.5));
  });

  test('tate-chū-yoko takes one mark, as one character', () {
    final text = layOut([
      EpubTextSpan(text: '明治'),
      EpubTextSpan(
        text: '38',
        combine: const EpubTextCombine.all(),
        emphasis: sesame,
      ),
      EpubTextSpan(text: '年'),
    ], vertical: true);
    final run = text.emphasis.single;
    expect(run.characters, hasLength(2));
    // The second digit takes no room of its own.
    expect(text.debugEmphasisCentres(0), hasLength(1));
  });

  test('a mark on a ruby base stands outside its annotation', () {
    final text = layOut([
      EpubTextSpan(text: '猫', ruby: 'ねこ', emphasis: sesame),
      EpubTextSpan(text: '犬', emphasis: sesame),
    ]);
    final cat = text.debugEmphasisCentres(0).single;
    final dog = text.debugEmphasisCentres(1).single;
    expect(dog.dy - cat.dy, closeTo(10, 0.5), reason: 'one annotation higher');
  });

  test('a mark on the second ruby level stands outside its annotation', () {
    for (final (vertical, emphasis) in [
      (false, const EpubTextEmphasis(under: true)),
      (true, const EpubTextEmphasis(left: true)),
    ]) {
      final text = layOut([
        EpubTextSpan(text: '猫', rubyUnder: 'cat', emphasis: emphasis),
        EpubTextSpan(text: '犬', emphasis: emphasis),
      ], vertical: vertical);
      final cat = text.debugEmphasisCentres(0).single;
      final dog = text.debugEmphasisCentres(1).single;
      expect(
        cat.dy - dog.dy,
        closeTo(10, 0.5),
        reason: '$vertical: one annotation farther outside',
      );
    }
  });

  test('table cells paint emphasis outside the text painter clip', () async {
    final row = EpubTableRow(
      cells: [
        EpubTableCell(
          children: [
            EpubParagraph([
              EpubTextSpan(text: '猫', emphasis: sesame),
              EpubTextSpan(
                text: '犬',
                emphasis: const EpubTextEmphasis(under: true),
              ),
              EpubTextSpan(text: '鳥', ruby: 'とり', emphasis: sesame),
            ], const EpubNodeStyle()),
          ],
        ),
      ],
    )..canonical = const EpubCanonicalSpan(0, 3);
    final chapter = EpubChapter(
      spine: 0,
      resource: 'OPS/Text/table.xhtml',
      title: '',
      blocks: [
        EpubTable(
          caption: const [],
          rowGroups: [
            EpubTableRowGroup(kind: EpubTableRowGroupKind.body, rows: [row]),
          ],
        ),
      ],
      canonicalText: '猫犬鳥',
      anchors: const {},
      scalarCount: 3,
    );
    final flow = layoutChapterFlow(
      chapter: chapter,
      spec: const ChapterLayoutSpec(
        width: 240,
        height: 160,
        typography: typography,
      ),
      images: const {},
    );
    addTearDown(() => disposeFlowBlocks(flow.blocks));
    final page = paginateFlow(
      flow: flow,
      pageHeight: 160,
      pageWidth: 240,
    ).pages.single;
    final text =
        flow.blocks.single.table!.rows.single.cells.single.blocks.single;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    paintPageSlices(
      canvas,
      page,
      typography.palette,
      const EpubPageBox(
        size: Size(280, 200),
        origin: Offset(20, 20),
        contentWidth: 240,
        contentHeight: 160,
      ),
    );
    final image = await recorder.endRecording().toImage(280, 200);
    final bytes = (await image.toByteData())!;
    image.dispose();
    bool centreIsInk(Offset center) =>
        bytes.getUint8((center.dy.round() * 280 + center.dx.round()) * 4 + 3) >
        64;

    final over = text.debugEmphasisCentres(0).single + const Offset(26, 26);
    final under = text.debugEmphasisCentres(1).single + const Offset(26, 26);
    final stacked = text.debugEmphasisCentres(2).single + const Offset(26, 26);
    final stackedBase = text.painter
        .getBoxesForSelection(
          const TextSelection(baseOffset: 2, extentOffset: 3),
        )
        .single
        .toRect()
        .shift(const Offset(26, 26));
    expect(stacked.dy, lessThan(stackedBase.center.dy - 10));
    for (final center in [over, under, stacked]) {
      expect(
        centreIsInk(center),
        isTrue,
        reason: 'the filled mark centre at $center must survive cell clipping',
      );
    }
  });

  test('marks do not enter canonical text or change selection geometry', () {
    final plain = layOut([
      EpubTextSpan(text: '甲😀乙', canonical: const EpubCanonicalSpan(0, 3)),
    ]);
    final marked = layOut([
      EpubTextSpan(
        text: '甲😀乙',
        canonical: const EpubCanonicalSpan(0, 3),
        emphasis: const EpubTextEmphasis(string: 'x'),
      ),
    ]);
    expect(marked.map.text, plain.map.text);
    expect(marked.map.canonicalStart, plain.map.canonicalStart);
    expect(marked.map.canonicalEnd, plain.map.canonicalEnd);
    expect(
      marked.boxesForCanonical(0, 3),
      pairwiseCompare(
        plain.boxesForCanonical(0, 3),
        (Rect left, Rect right) => left == right,
        'same rectangle',
      ),
    );
  });

  group('line spacing', () {
    test('a chapter with marks makes room for them', () {
      final tight = typography.copyWith(lineHeight: 1.2);
      expect(
        chapterTypography(
          chapterOf([EpubTextSpan(text: '猫', emphasis: sesame)]),
          tight,
        ).lineHeight,
        annotatedLineHeight,
      );
      expect(
        chapterTypography(
          chapterOf([EpubTextSpan(text: '猫')]),
          tight,
        ).lineHeight,
        1.2,
      );
    });

    test('a ruby base with marks on its annotation\'s side makes room for '
        'both', () {
      final tight = typography.copyWith(lineHeight: 1.2);
      final stacked = 1 + 2 * rubyScale + 0.25;
      expect(
        chapterTypography(
          chapterOf([EpubTextSpan(text: '猫', ruby: 'ねこ', emphasis: sesame)]),
          tight,
        ).lineHeight,
        stacked,
      );
      // Marks on the other side stand in the gap the next line's ruby
      // stands in, so the gap holds both too; marks under a line in a
      // chapter without ruby need only one half em.
      for (final (vertical, emphasis) in [
        (false, const EpubTextEmphasis(under: true)),
        (true, const EpubTextEmphasis(left: true)),
      ]) {
        expect(
          chapterTypography(
            chapterOf([
              EpubTextSpan(text: '猫', ruby: 'ねこ', emphasis: emphasis),
            ]),
            tight,
            vertical: vertical,
          ).lineHeight,
          stacked,
        );
        expect(
          chapterTypography(
            chapterOf([EpubTextSpan(text: '猫', emphasis: emphasis)]),
            tight,
            vertical: vertical,
          ).lineHeight,
          annotatedLineHeight,
        );
      }
      // Ruby on one character and marks on another over their line share
      // one half em; marks under it take another. The side is the line's:
      // `under` is a horizontal line's, `left` a vertical one's.
      for (final (vertical, emphasis, least) in [
        (false, sesame, annotatedLineHeight),
        (false, const EpubTextEmphasis(under: true), stacked),
        (true, const EpubTextEmphasis(under: true), annotatedLineHeight),
        (true, const EpubTextEmphasis(left: true), stacked),
      ]) {
        expect(
          chapterTypography(
            chapterOf([
              EpubTextSpan(text: '猫', ruby: 'ねこ'),
              EpubTextSpan(text: '犬', emphasis: emphasis),
            ]),
            tight,
            vertical: vertical,
          ).lineHeight,
          least,
          reason: '$vertical $emphasis',
        );
      }
    });
  });
}
