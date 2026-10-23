import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_epub/shosai_epub.dart';
import 'package:shosai_flutter/reader/epub/flow.dart';
import 'package:shosai_flutter/reader/epub/text_style.dart';

import '../support/epub_navigation_fixture.dart';

/// Ruby: the annotation is laid out half the base's size and set over the
/// base (to its right in a vertical line); a base shorter than its annotation
/// is spaced out to the annotation's length.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const typography = ReaderEpubTypography(
    fontFamily: 'Literata',
    fontFamilyFallback: ['Shippori Mincho', 'Noto Sans JP'],
    fontSize: 20,
    lineHeight: 1.6,
    palette: ReaderEpubPalette(
      background: Color(0xFFFFFFFF),
      foreground: Color(0xFF1A1A1A),
      link: Color(0xFF174EA6),
      tableHeaderBackground: Color(0xFFE8EEF8),
      tableHeaderBorder: Color(0xFF596B89),
    ),
  );

  /// The laid-out box of the code units [start] to [end] of [built].
  Rect boxOf(BuiltBlockText built, int start, int end) {
    final painter = TextPainter(
      text: built.span,
      textDirection: ui.TextDirection.ltr,
    )..layout();
    addTearDown(painter.dispose);
    final boxes = painter.getBoxesForSelection(
      TextSelection(baseOffset: start, extentOffset: end),
    );
    return boxes
        .map((box) => box.toRect())
        .reduce((a, b) => a.expandToInclude(b));
  }

  double widthOf(InlineSpan span) {
    final painter = TextPainter(text: span, textDirection: ui.TextDirection.ltr)
      ..layout();
    addTearDown(painter.dispose);
    return painter.width;
  }

  for (final vertical in [false, true]) {
    final mode = vertical ? 'vertical' : 'horizontal';

    test('$mode: a base as long as its annotation keeps its spacing', () {
      final built = buildBlockText(
        [
          EpubTextSpan(text: '吾輩は'),
          EpubTextSpan(text: '猫', ruby: 'ね'),
          EpubTextSpan(text: 'である'),
        ],
        typography,
        20,
        vertical: vertical,
      );
      final ruby = built.rubies.single;
      expect((ruby.start, ruby.end), (3, 4));
      expect(ruby.baseSize, 20);
      expect(ruby.annotation.map.text, 'ね');
      expect(widthOf(ruby.annotation.span), closeTo(10, 0.01));
      expect(boxOf(built, 3, 4).width, closeTo(20, 0.01));
      // Only a vertical line's upright characters are redrawn.
      expect(
        built.redrawn.every((run) => run.upright),
        isTrue,
        reason: 'no base is spaced out',
      );
      if (!vertical) expect(built.redrawn, isEmpty);
    });

    test('$mode: a base shorter than its annotation is spaced out to its '
        'length and redrawn', () {
      final built = buildBlockText(
        [
          EpubTextSpan(text: '彼の'),
          EpubTextSpan(text: '掌', ruby: 'てのひら'),
          EpubTextSpan(text: 'に'),
        ],
        typography,
        20,
        vertical: vertical,
      );
      final annotation = widthOf(built.rubies.single.annotation.span);
      expect(annotation, closeTo(40, 0.01));
      expect(boxOf(built, 2, 3).width, closeTo(40, 0.01));
      final base = built.redrawn.singleWhere((run) => run.start == 2);
      expect(base.end, 3);
      expect(base.upright, vertical);
      expect(base.style.color, typography.palette.foreground);
    });
  }

  test('a vertical annotation stands upright', () {
    final built = buildBlockText(
      [EpubTextSpan(text: '猫', ruby: 'ねこ')],
      typography,
      20,
      vertical: true,
    );
    final annotation = built.rubies.single.annotation;
    expect(annotation.redrawn.single.upright, isTrue);
    expect(
      (annotation.redrawn.single.start, annotation.redrawn.single.end),
      (0, 2),
    );
  });

  test('ruby is painted over its base, outside a clip to the line', () async {
    final chapter = EpubChapter(
      spine: 0,
      resource: 'OPS/Text/ruby.xhtml',
      title: '',
      blocks: [
        EpubParagraph([
          EpubTextSpan(text: 'AB'),
          EpubTextSpan(text: 'C', ruby: 'xyzw'),
          EpubTextSpan(text: 'D'),
        ], const EpubNodeStyle()),
      ],
      canonicalText: 'ABCD',
      anchors: const {},
      scalarCount: 4,
    );
    final flow = layoutChapterFlow(
      chapter: chapter,
      spec: const ChapterLayoutSpec(
        width: 400,
        height: 400,
        typography: typography,
      ),
      images: const {},
    );
    addTearDown(() => disposeFlowBlocks(flow.blocks));
    final text = flow.blocks.single.text!;
    final line = text.lines.single;
    final base = text.painter
        .getBoxesForSelection(
          const TextSelection(baseOffset: 2, extentOffset: 3),
        )
        .single
        .toRect();
    // Spaced out to the annotation: four half-size letters.
    expect(base.width, closeTo(40, 0.01));

    Future<List<int>> inkRows({required bool ruby}) async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.translate(0, 40);
      canvas.save();
      canvas.clipRect(Rect.fromLTWH(0, line.top, text.width, line.height));
      text.paint(canvas, ruby: false);
      canvas.restore();
      if (ruby) text.paintRuby(canvas);
      final image = await recorder.endRecording().toImage(400, 120);
      final bytes = (await image.toByteData())!;
      image.dispose();
      final rows = <int>[];
      for (var y = 0; y < 120; y++) {
        for (var x = base.left.floor(); x < base.right.ceil(); x++) {
          if (bytes.getUint8((y * 400 + x) * 4 + 3) != 0) {
            rows.add(y);
            break;
          }
        }
      }
      return rows;
    }

    final without = await inkRows(ruby: false);
    final withRuby = await inkRows(ruby: true);
    final baseTop = 40 + base.center.dy - 10;
    final above = withRuby.where((y) => y < baseTop).toList();
    expect(without.where((y) => y < baseTop - 1), isEmpty);
    // The annotation is half the base's size, right above its em square.
    expect(above, isNotEmpty);
    expect(above.first, greaterThanOrEqualTo((baseTop - 10).floor() - 1));
    expect(above.first, lessThan(40 + line.top), reason: 'above the line');
  });

  test('a ruby base laid out again without tate-chū-yoko keeps its ruby', () {
    // A line may break between 一 and 二 but not before 。, so at two ems a
    // line the combined base is laid out again without tate-chū-yoko.
    final book = openEpubBytes(
      buildTestEpub(
        chapters: {
          'OPS/Text/chapter-1.xhtml':
              '<p>甲<ruby style="text-combine-upright: all">一二'
              '<rt>いちに</rt></ruby>。乙</p>',
        },
        nav: '<ol><li><a href="../Text/chapter-1.xhtml">一</a></li></ol>',
        pageProgression: 'rtl',
        bodyAttributes: ' style="writing-mode: vertical-rl"',
      ),
    );
    final session = ChapterLayoutSession(
      chapter: book.chapters.first,
      spec: const ChapterLayoutSpec(
        width: 40,
        height: 600,
        typography: typography,
        vertical: true,
      ),
      images: const {},
    );
    addTearDown(session.dispose);
    session.layoutWindowAt(0);
    final block = session.blocks.single.text!;
    expect(block.redrawn.where((run) => run.combined), isEmpty);
    expect(
      [
        for (final ruby in block.rubies)
          block.map.text.substring(ruby.start, ruby.end),
      ],
      ['一二'],
    );
  });
}
