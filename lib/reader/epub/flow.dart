/// Chapter flow layout: normalized blocks measured with Flutter's text engine
/// into line-level fragments that carry canonical ranges.
///
/// Pixels, hit testing and selection geometry all come from the [TextPainter]s
/// created here; pagination only groups and clips those painters.
///
/// This is the reader's production port of the retired evaluation layout.
/// The measured
/// shape, the windowed [ChapterLayoutSession] and the per-line canonical
/// mapping are the prototype's; the reader supplies its own typography and
/// palette, and the prototype's evidence-only helpers are dropped.
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:characters/characters.dart';
import 'package:flutter/painting.dart';
import 'package:shosai_epub/shosai_epub.dart';

import 'text_style.dart';

/// Default block spacing in ems. These are layout calibrations, not a port of
/// the retained renderer's constants.
const double _paragraphSpacingEm = 0.35;
const double _headingSpacingBeforeEm = 0.8;
const double _headingSpacingAfterEm = 0.4;
const double _listItemSpacingEm = 0.12;
const double _codeSpacingEm = 0.5;
const double _figureSpacingEm = 0.6;
const double _tableSpacingEm = 0.6;
const double _ruleSpacingEm = 0.8;
const double _tableCellPadding = 6.0;

/// One laid-out line of a text block.
class FlowLine {
  const FlowLine({
    required this.codeUnitStart,
    required this.codeUnitEnd,
    required this.canonicalStart,
    required this.canonicalEnd,
    required this.top,
    required this.height,
  });

  final int codeUnitStart;
  final int codeUnitEnd;
  final int canonicalStart;
  final int canonicalEnd;

  /// Line top relative to the block's own top.
  final double top;
  final double height;
}

/// A measured text block. The painter is the single source of pixels, hit
/// testing and selection geometry for this block.
class FlowTextBlock {
  FlowTextBlock({
    required this.painter,
    required this.map,
    required this.lines,
    required this.links,
    required this.selectable,
    required this.textAlign,
    required this.textDirection,
    this.redrawn = const [],
    this.rubies = const [],
    this.emphasis = const [],
  });

  final TextPainter painter;
  final BlockTextMap map;
  final List<FlowLine> lines;

  /// Link href per code-unit range, for internal navigation hit testing.
  final List<({int start, int end, String href})> links;
  final bool selectable;
  final TextAlign textAlign;
  final ui.TextDirection textDirection;

  /// The characters [paint] draws itself over their transparent boxes: a
  /// vertical block's upright characters and tate-chū-yoko, and ruby bases
  /// spaced out under a longer annotation.
  final List<RedrawnRun> redrawn;

  /// The ruby annotations [paint] sets beside their bases.
  final List<RubyRun> rubies;

  /// The emphasis marks [paint] sets beside their characters.
  final List<EmphasisRun> emphasis;

  /// The redrawn glyphs of each line, measured when the line is first painted.
  final Map<int, List<_RedrawnGlyph>> _redrawnLines = {};

  /// One painter per redrawn grapheme (or tate-chū-yoko run), style and use
  /// of vertical forms, shared by the block's lines.
  final Map<(String, TextStyle, bool), TextPainter> _glyphPainters = {};

  /// Each ruby annotation, laid out and placed when it is first painted.
  final Map<int, ({Offset origin, FlowTextBlock text})?> _placedRubies = {};

  /// Where each emphasis run's marks stand, the centres of their half-em
  /// squares, and a string mark laid out, when the run is first painted.
  final Map<
    int,
    ({FlowTextBlock? string, List<({int start, Offset center})> at})
  >
  _placedEmphasis = {};

  double get width => painter.width;
  double get height => painter.height;

  int canonicalAtLocal(Offset local) {
    final position = painter.getPositionForOffset(local);
    return map.canonicalAt(position.offset);
  }

  /// Selection rectangles for a canonical range, in block-local coordinates.
  List<Rect> boxesForCanonical(int start, int end) {
    if (map.isEmpty || end <= start) return const [];
    final codeUnitStart = map.codeUnitAt(start);
    final codeUnitEnd = map.codeUnitAt(end);
    if (codeUnitEnd <= codeUnitStart) return const [];
    return [
      for (final box in painter.getBoxesForSelection(
        TextSelection(baseOffset: codeUnitStart, extentOffset: codeUnitEnd),
      ))
        box.toRect(),
    ];
  }

  String? linkAtLocal(Offset local) {
    final offset = painter.getPositionForOffset(local).offset;
    for (final link in links) {
      if (offset >= link.start && offset < link.end) return link.href;
    }
    return null;
  }

  /// Paints the block with its top-left corner at the canvas origin.
  ///
  /// A vertical block's canvas is turned a quarter turn clockwise, so each
  /// upright character of the lines [lineStart] to [lineEnd] is drawn turned
  /// back over its own transparent box, in its font's vertical forms. The
  /// lines' ruby is painted too unless [ruby] is false; a caller that clips
  /// the block to its lines paints it with [paintRuby] outside that clip,
  /// since an annotation stands above its line's top.
  void paint(
    Canvas canvas, {
    int lineStart = 0,
    int? lineEnd,
    bool ruby = true,
  }) {
    painter.paint(canvas, Offset.zero);
    final end = math.min(lineEnd ?? lines.length, lines.length);
    if (redrawn.isNotEmpty) {
      for (var line = lineStart; line < end; line++) {
        for (final glyph in _redrawnLines[line] ??= _measureRedrawn(line)) {
          final glyphPainter = glyph.painter;
          canvas.save();
          canvas.translate(glyph.center.dx, glyph.center.dy);
          if (glyph.upright) canvas.rotate(-math.pi / 2);
          if (glyph.squeeze != 1) canvas.scale(glyph.squeeze, 1);
          glyphPainter.paint(
            canvas,
            Offset(-glyphPainter.width / 2, -glyphPainter.height / 2),
          );
          canvas.restore();
        }
      }
    }
    if (ruby) paintRuby(canvas, lineStart: lineStart, lineEnd: end);
  }

  /// Paints the ruby of the lines [lineStart] to [lineEnd], each annotation
  /// centred over its base's box, above the line (to its right on a vertical
  /// page), or below it (to its left) for a second level. A base broken
  /// across lines takes its ruby on its first line.
  ///
  /// The emphasis marks of those lines are painted with it, beside each
  /// character, outside a ruby annotation on the same side.
  void paintRuby(Canvas canvas, {int lineStart = 0, int? lineEnd}) {
    if (rubies.isEmpty && emphasis.isEmpty) return;
    final end = math.min(lineEnd ?? lines.length, lines.length);
    if (lineStart >= end) return;
    final from = lines[lineStart].codeUnitStart;
    final to = lines[end - 1].codeUnitEnd;
    for (var index = 0; index < emphasis.length; index++) {
      final run = emphasis[index];
      if (run.characters.last.start < from) continue;
      if (run.characters.first.start >= to) break;
      final placed = _placedEmphasis[index] ??= _placeEmphasis(run);
      for (final character in placed.at) {
        if (character.start < from || character.start >= to) continue;
        final string = placed.string;
        if (string != null) {
          canvas.save();
          canvas.translate(
            character.center.dx - string.width / 2,
            character.center.dy - string.height / 2,
          );
          string.paint(canvas);
          canvas.restore();
        } else {
          _paintEmphasisShape(canvas, character.center, run);
        }
      }
    }
    for (var index = 0; index < rubies.length; index++) {
      final ruby = rubies[index];
      if (ruby.start < from) continue;
      if (ruby.start >= to) break;
      final placed = _placedRubies.containsKey(index)
          ? _placedRubies[index]
          : _placedRubies[index] = _placeRuby(ruby);
      if (placed == null) continue;
      canvas.save();
      canvas.translate(placed.origin.dx, placed.origin.dy);
      placed.text.paint(canvas);
      canvas.restore();
    }
  }

  /// Test-only: where each ruby annotation's top-left corner stands, as
  /// [paintRuby] places it, or null for one with no base box.
  List<Offset?> debugRubyOrigins() => [
    for (var index = 0; index < rubies.length; index++)
      (_placedRubies.containsKey(index)
              ? _placedRubies[index]
              : _placedRubies[index] = _placeRuby(rubies[index]))
          ?.origin,
  ];

  /// Test-only: where the marks of the emphasis run [index] stand, the
  /// centres [paintRuby] draws them on.
  List<Offset> debugEmphasisCentres(int index) => [
    for (final character in (_placedEmphasis[index] ??= _placeEmphasis(
      emphasis[index],
    )).at)
      character.center,
  ];

  ({FlowTextBlock? string, List<({int start, Offset center})> at})
  _placeEmphasis(EmphasisRun run) {
    final half = run.baseSize * rubyScale / 2;
    final at = <({int start, Offset center})>[];
    for (final character in run.characters) {
      final boxes = painter.getBoxesForSelection(
        TextSelection(baseOffset: character.start, extentOffset: character.end),
      );
      if (boxes.isEmpty) continue;
      final box = boxes.first.toRect();
      // A tate-chū-yoko run's later characters take no room of their own:
      // the run is one character, with one mark.
      if (box.width < 0.01) continue;
      // A mark on the side of a ruby annotation stands outside it.
      var clear = 0.0;
      for (var index = 0; index < rubies.length; index++) {
        final ruby = rubies[index];
        if (ruby.start > character.start) break;
        if (character.start >= ruby.end || ruby.under != run.under) continue;
        final annotation = _placedRubies.containsKey(index)
            ? _placedRubies[index]
            : _placedRubies[index] = _placeRuby(ruby);
        clear = annotation?.text.height ?? 0;
        break;
      }
      at.add((
        start: character.start,
        center: Offset(
          box.center.dx,
          run.under
              ? box.center.dy + run.baseSize / 2 + clear + half
              : box.center.dy - run.baseSize / 2 - clear - half,
        ),
      ));
    }
    final string = run.string;
    return (string: string == null ? null : _annotationBlock(string), at: at);
  }

  /// Draws [run]'s shape on the half-em square centred on [center], upright
  /// on the page: turned back on a vertical block's turned canvas.
  static void _paintEmphasisShape(
    Canvas canvas,
    Offset center,
    EmphasisRun run,
  ) {
    final paint = Paint()
      ..color = run.color
      ..style = run.filled ? PaintingStyle.fill : PaintingStyle.stroke
      ..strokeWidth = 0.16
      ..strokeJoin = StrokeJoin.round;
    canvas.save();
    canvas.translate(center.dx, center.dy);
    if (run.vertical) canvas.rotate(-math.pi / 2);
    // The shapes are drawn on a square two units across.
    final unit = run.baseSize * rubyScale / 2;
    canvas.scale(unit);
    switch (run.shape) {
      case EpubEmphasisShape.dot:
        canvas.drawCircle(Offset.zero, run.filled ? 0.28 : 0.24, paint);
      case EpubEmphasisShape.circle:
        canvas.drawCircle(Offset.zero, run.filled ? 0.62 : 0.56, paint);
      case EpubEmphasisShape.doubleCircle:
        canvas.drawCircle(
          Offset.zero,
          0.62,
          Paint()
            ..color = run.color
            ..style = PaintingStyle.stroke
            ..strokeWidth = 0.16,
        );
        canvas.drawCircle(Offset.zero, run.filled ? 0.32 : 0.26, paint);
      case EpubEmphasisShape.triangle:
        // Pointing up the page, its centroid on the centre.
        canvas.drawPath(
          Path()
            ..moveTo(0, -0.7)
            ..lineTo(0.62, 0.38)
            ..lineTo(-0.62, 0.38)
            ..close(),
          paint,
        );
      case EpubEmphasisShape.sesame:
        // The 丶 of vertical text: a stroke that swells from a fine head at
        // the top left to a round tail at the bottom right, its weight on
        // the centre.
        canvas.drawPath(
          Path()
            ..moveTo(-0.34, -0.5)
            ..cubicTo(-0.02, -0.36, 0.4, -0.1, 0.38, 0.16)
            ..cubicTo(0.36, 0.42, 0.04, 0.46, -0.06, 0.24)
            ..cubicTo(-0.12, 0.08, -0.18, -0.24, -0.34, -0.5)
            ..close(),
          paint,
        );
    }
    canvas.restore();
  }

  /// An annotation's laid-out text as a one-line block of its own, which
  /// paints its upright characters as a vertical block does.
  FlowTextBlock _annotationBlock(BuiltBlockText annotation) {
    final annotationPainter = TextPainter(
      text: annotation.span,
      textDirection: ui.TextDirection.ltr,
    )..layout();
    return FlowTextBlock(
      painter: annotationPainter,
      map: annotation.map,
      lines: [
        FlowLine(
          codeUnitStart: 0,
          codeUnitEnd: annotation.map.codeUnitLength,
          canonicalStart: 0,
          canonicalEnd: 0,
          top: 0,
          height: annotationPainter.height,
        ),
      ],
      links: const [],
      selectable: false,
      textAlign: TextAlign.left,
      textDirection: ui.TextDirection.ltr,
      redrawn: annotation.redrawn,
    );
  }

  ({Offset origin, FlowTextBlock text})? _placeRuby(RubyRun ruby) {
    final boxes = painter.getBoxesForSelection(
      TextSelection(baseOffset: ruby.start, extentOffset: ruby.end),
    );
    if (boxes.isEmpty) return null;
    final first = boxes.first.toRect();
    var base = first;
    for (final box in boxes.skip(1)) {
      final rect = box.toRect();
      if ((rect.top - first.top).abs() > first.height / 2) continue;
      base = base.expandToInclude(rect);
    }
    final text = _annotationBlock(ruby.annotation);
    // The annotation stands on the base's em square (or hangs from it),
    // centred on its box:
    // the laid-out box is the font's ascent and descent, which can reach well
    // past the em, and an upright character is drawn centred on it.
    return (
      origin: Offset(
        base.center.dx - text.width / 2,
        ruby.under
            ? base.center.dy + ruby.baseSize / 2
            : base.center.dy - ruby.baseSize / 2 - text.height,
      ),
      text: text,
    );
  }

  List<_RedrawnGlyph> _measureRedrawn(int line) {
    final from = lines[line].codeUnitStart;
    final to = lines[line].codeUnitEnd;
    final glyphs = <_RedrawnGlyph>[];
    final text = map.text;
    final markerOffset = map.codeUnitOffset;
    for (final run in redrawn) {
      if (run.end <= from) continue;
      if (run.start >= to) break;
      var unit = math.max(run.start, from);
      final runEnd = math.min(run.end, to);
      final runText = text.substring(
        unit - markerOffset,
        runEnd - markerOffset,
      );
      if (run.combined) {
        // Tate-chū-yoko is one unit that a line never breaks: it is drawn
        // whole on the line it starts on.
        if (run.start < from) continue;
        final glyph = _combinedGlyph(run);
        if (glyph != null) glyphs.add(glyph);
        continue;
      }
      for (final grapheme in runText.characters) {
        final start = unit;
        unit += grapheme.length;
        final glyph = _redrawnGlyph(
          start,
          unit,
          grapheme,
          run.style,
          verticalForms: run.upright,
        );
        if (glyph == null) continue;
        glyphs.add(
          _RedrawnGlyph(
            center: glyph.box.center,
            painter: glyph.painter,
            upright: run.upright,
          ),
        );
      }
    }
    return glyphs;
  }

  /// A tate-chū-yoko run drawn as horizontal text across its column,
  /// squeezed to the one em its laid-out text takes along the line.
  _RedrawnGlyph? _combinedGlyph(RedrawnRun run) {
    final glyph = _redrawnGlyph(
      run.start,
      run.end,
      map.text.substring(
        run.start - map.codeUnitOffset,
        run.end - map.codeUnitOffset,
      ),
      run.style,
      verticalForms: false,
    );
    if (glyph == null) return null;
    final advance = glyph.box.width;
    final width = glyph.painter.width;
    return _RedrawnGlyph(
      center: glyph.box.center,
      painter: glyph.painter,
      squeeze: width > advance && width > 0 ? advance / width : 1,
    );
  }

  /// Where each grapheme of the tate-chū-yoko runs that start in the code
  /// units [from] to [to] is drawn, in block coordinates.
  ///
  /// A run takes one em along its line, and its graphemes sit side by side
  /// across the line: on the page, the first is leftmost. Each cell spans the
  /// run's em along the line and its grapheme's share of the drawn text
  /// across it, so selection, highlights and hit testing see the characters
  /// where they are painted. [index] and [count] place a cell in its run.
  List<({int start, int end, int index, int count, Rect rect})> combinedCells(
    int from,
    int to,
  ) {
    final cells = <({int start, int end, int index, int count, Rect rect})>[];
    for (final run in redrawn) {
      if (!run.combined || run.start < from) continue;
      if (run.start >= to) break;
      final glyph = _combinedGlyph(run);
      if (glyph == null) continue;
      final runText = map.text.substring(
        run.start - map.codeUnitOffset,
        run.end - map.codeUnitOffset,
      );
      final boxes = painter.getBoxesForSelection(
        TextSelection(baseOffset: run.start, extentOffset: run.end),
      );
      var along = boxes.first.toRect();
      for (final box in boxes.skip(1)) {
        along = along.expandToInclude(box.toRect());
      }
      final half = glyph.painter.width / 2;
      final count = runText.characters.length;
      var index = 0;
      var unit = 0;
      for (final grapheme in runText.characters) {
        final start = unit;
        unit += grapheme.length;
        final drawn = glyph.painter.getBoxesForSelection(
          TextSelection(baseOffset: start, extentOffset: unit),
        );
        if (drawn.isEmpty) continue;
        var left = drawn.first.left;
        var right = drawn.first.right;
        for (final box in drawn.skip(1)) {
          left = math.min(left, box.left);
          right = math.max(right, box.right);
        }
        // The glyph is turned back a quarter turn, so its text runs towards
        // the block's top.
        cells.add((
          start: run.start + start,
          end: run.start + unit,
          index: index++,
          count: count,
          rect: Rect.fromLTRB(
            along.left,
            glyph.center.dy - glyph.squeeze * (right - half),
            along.right,
            glyph.center.dy - glyph.squeeze * (left - half),
          ),
        ));
      }
    }
    return cells;
  }

  /// The laid-out box of the code units [start] to [end], and a painter that
  /// draws [text] in [style], in the font's vertical forms when
  /// [verticalForms] is true (an upright character; tate-chū-yoko sets its
  /// text as horizontal).
  ({Rect box, TextPainter painter})? _redrawnGlyph(
    int start,
    int end,
    String text,
    TextStyle style, {
    required bool verticalForms,
  }) {
    final boxes = painter.getBoxesForSelection(
      TextSelection(baseOffset: start, extentOffset: end),
    );
    if (boxes.isEmpty) return null;
    var rect = boxes.first.toRect();
    for (final box in boxes.skip(1)) {
      rect = rect.expandToInclude(box.toRect());
    }
    final glyphPainter = _glyphPainters[(text, style, verticalForms)] ??=
        TextPainter(
          text: TextSpan(
            text: text,
            style: style.copyWith(
              fontFeatures: [
                if (verticalForms) const ui.FontFeature.enable('vert'),
              ],
              decoration: TextDecoration.none,
            ),
          ),
          textDirection: ui.TextDirection.ltr,
        )..layout();
    return (box: rect, painter: glyphPainter);
  }

  /// Releases the measured paragraph behind this block.
  void dispose() {
    painter.dispose();
    for (final glyphPainter in _glyphPainters.values) {
      glyphPainter.dispose();
    }
    _glyphPainters.clear();
    _redrawnLines.clear();
    for (final placed in _placedRubies.values) {
      placed?.text.dispose();
    }
    _placedRubies.clear();
    for (final placed in _placedEmphasis.values) {
      placed.string?.dispose();
    }
    _placedEmphasis.clear();
  }
}

/// One redrawn character (or tate-chū-yoko run) of a line: where its box's
/// centre is, in block coordinates, and the painter that draws it.
class _RedrawnGlyph {
  const _RedrawnGlyph({
    required this.center,
    required this.painter,
    this.upright = true,
    this.squeeze = 1,
  });

  final Offset center;
  final TextPainter painter;

  /// Whether the glyph is turned back to stand upright in a vertical line.
  final bool upright;

  /// How much a tate-chū-yoko run is narrowed to fit its em square.
  final double squeeze;
}

/// A measured image block (or a visible alt-text fallback).
class FlowImageBlock {
  FlowImageBlock({
    required this.src,
    required this.alt,
    required this.image,
    required this.fallbackText,
    required this.width,
    required this.height,
    required this.imageRect,
    required this.caption,
    required this.canonicalStart,
    required this.canonicalEnd,
    this.quarterTurned = false,
  });

  final String src;
  final String alt;

  /// Whether the image is laid out in a vertical flow, which is turned a
  /// quarter turn: [width] and [height] are then the flow's extents, and the
  /// image is painted turned back so it stands upright.
  final bool quarterTurned;

  /// Canonical range of the image's alt fallback and caption.
  final int canonicalStart;
  final int canonicalEnd;

  /// Decoded image, or null when the resource is missing or undecodable.
  final ui.Image? image;

  /// Visible selectable fallback painted in place of a missing image.
  final FlowTextBlock? fallbackText;
  final double width;
  final double height;

  /// Image rectangle relative to the block top.
  final Rect imageRect;
  final FlowTextBlock? caption;
}

class FlowTableCellLayout {
  FlowTableCellLayout({
    required this.column,
    required this.span,
    required this.left,
    required this.width,
    required this.header,
    required this.blocks,
    required this.height,
  });

  final int column;
  final int span;
  final double left;
  final double width;
  final bool header;
  final List<FlowTextBlock> blocks;
  final double height;

  int get canonicalStart =>
      blocks.isEmpty ? 0 : blocks.first.map.canonicalStart;
  int get canonicalEnd => blocks.isEmpty ? 0 : blocks.last.map.canonicalEnd;
}

class FlowTableRowLayout {
  FlowTableRowLayout({
    required this.groupIndex,
    required this.rowIndex,
    required this.top,
    required this.height,
    required this.cells,
    required this.rowSpanGroup,
    this.canonicalSpan,
  });

  final int groupIndex;
  final int rowIndex;
  final double top;
  final double height;
  final List<FlowTableCellLayout> cells;

  /// Number of rows this row's span group covers (1 when no rowspans).
  final int rowSpanGroup;

  /// The row's own canonical range from the engine's canonical builder
  /// (`EpubTableRow.canonical`).
  ///
  /// A row whose cells all lack mapped text (empty cells are common in real
  /// books' layout tables) has no cell block to read an anchor from; without
  /// this range it would fall back to scalar 0 and anchor a mid-chapter page
  /// to the chapter start, misdirecting page lookup and page steps. The range
  /// covers the row's separators, so it is nonempty even for an entirely
  /// empty row, and consecutive rows partition the table's body.
  final EpubCanonicalSpan? canonicalSpan;

  int get canonicalStart => canonicalSpan?.start ?? _cellsFallbackStart;
  int get canonicalEnd => canonicalSpan?.end ?? _cellsFallbackEnd;

  int get _cellsFallbackStart => cells.isEmpty
      ? 0
      : cells.map((cell) => cell.canonicalStart).reduce(math.min);
  int get _cellsFallbackEnd => cells.isEmpty
      ? 0
      : cells.map((cell) => cell.canonicalEnd).reduce(math.max);
}

class FlowTableBlock {
  FlowTableBlock({
    required this.caption,
    required this.rows,
    required this.columnWidths,
    required this.width,
    required this.height,
    required this.headerRows,
  });

  final FlowTextBlock? caption;
  final List<FlowTableRowLayout> rows;
  final List<double> columnWidths;
  final double width;
  final double height;

  /// Row indices that belong to a `<thead>` group.
  final Set<int> headerRows;

  int get canonicalStart {
    final captionStart = caption?.map.canonicalStart;
    if (rows.isEmpty) return captionStart ?? 0;
    final rowStart = rows.first.canonicalStart;
    return captionStart == null ? rowStart : math.min(captionStart, rowStart);
  }

  int get canonicalEnd {
    final captionEnd = caption?.map.canonicalEnd;
    if (rows.isEmpty) return captionEnd ?? 0;
    final rowEnd = rows.last.canonicalEnd;
    return captionEnd == null ? rowEnd : math.max(captionEnd, rowEnd);
  }
}

class FlowRuleBlock {
  const FlowRuleBlock({
    required this.canonicalStart,
    required this.canonicalEnd,
  });

  final int canonicalStart;
  final int canonicalEnd;
}

/// A positioned block in the chapter flow.
class FlowBlock {
  FlowBlock({
    required this.nodeIndex,
    required this.top,
    required this.height,
    required this.text,
    required this.image,
    required this.table,
    required this.rule,
  });

  final int nodeIndex;
  double top;
  double height;

  /// Exactly one of these is non-null.
  final FlowTextBlock? text;
  final FlowImageBlock? image;
  final FlowTableBlock? table;
  final FlowRuleBlock? rule;

  int get canonicalStart =>
      text?.map.canonicalStart ??
      image?.canonicalStart ??
      table?.canonicalStart ??
      rule?.canonicalStart ??
      0;

  int get canonicalEnd =>
      text?.map.canonicalEnd ??
      image?.canonicalEnd ??
      table?.canonicalEnd ??
      rule?.canonicalEnd ??
      0;

  bool get isSplittable => text != null || table != null;

  /// A copy at a different flow-space top. Painters are shared: only the
  /// position changes, never the measured pixels.
  FlowBlock shifted(double delta) => FlowBlock(
    nodeIndex: nodeIndex,
    top: top + delta,
    height: height,
    text: text,
    image: image,
    table: table,
    rule: rule,
  );
}

/// The laid-out chapter flow.
///
/// A flow is [layoutComplete] when every chapter node has been measured. The
/// progressive layout installs an incomplete flow first (a window around the
/// reader's durable location) and extends it in bounded batches, so a partial
/// flow is a normal, supported state: it renders, hit tests and paginates the
/// range it covers, and its totals are reported as partial rather than
/// fabricated.
class ChapterFlow {
  ChapterFlow({
    required this.spine,
    required this.width,
    required this.height,
    required this.blocks,
    required this.canonicalScalarCount,
    required this.overflowClippedBlocks,
    required this.palette,
    this.layoutComplete = true,
    this.firstNodeIndex = 0,
    this.nodeCount = 0,
  });

  final int spine;
  final double width;
  final double height;
  final List<FlowBlock> blocks;
  final int canonicalScalarCount;

  /// Palette baked into this layout. Document pixels keep the palette they
  /// were laid out with, so a theme change cannot repaint a live background
  /// behind text that still carries the previous colors.
  final ReaderEpubPalette palette;

  /// Blocks that cannot fit one page and are painted clipped. A non-zero count
  /// is reported rather than hidden.
  final int overflowClippedBlocks;

  /// Whether every node of the chapter is measured into this flow.
  final bool layoutComplete;

  /// Node index of the first laid-out block (non-zero for a window that has
  /// not been extended back to the chapter start yet).
  final int firstNodeIndex;

  /// Total nodes in the chapter (0 when the caller did not record it).
  final int nodeCount;

  /// Canonical scalar of the first laid-out block, or null when empty.
  int? get firstCanonical =>
      blocks.isEmpty ? null : blocks.first.canonicalStart;

  /// Canonical scalar of the last laid-out block, or null when empty.
  int? get lastCanonical => blocks.isEmpty ? null : blocks.last.canonicalEnd;

  /// Whether [scalar] falls inside the laid-out range.
  bool covers(int scalar) {
    final first = firstCanonical;
    final last = lastCanonical;
    if (first == null || last == null) return false;
    return scalar >= first && scalar <= last;
  }
}

class ChapterLayoutSpec {
  const ChapterLayoutSpec({
    required this.width,
    required this.height,
    required this.typography,
    this.vertical = false,
  });

  /// Logical content width (already excludes chrome and page padding): the
  /// length of a line.
  final double width;

  /// Logical content height available to one page: the extent its lines
  /// stack along.
  final double height;
  final ReaderEpubTypography typography;

  /// Whether the chapter is vertical (`vertical-rl`). The flow is then laid
  /// out as horizontal lines that a page turns a quarter turn clockwise:
  /// [width] is the page's height and [height] its width.
  final bool vertical;

  @override
  bool operator ==(Object other) =>
      other is ChapterLayoutSpec &&
      other.width == width &&
      other.height == height &&
      other.typography == typography &&
      other.vertical == vertical;

  @override
  int get hashCode => Object.hash(width, height, typography, vertical);
}

/// The least line height a chapter with ruby or emphasis marks is laid out
/// at, in ems: the gap between two lines' em squares holds an annotation or
/// a mark (half an em) and a quarter of an em between it and the next line,
/// as the line height of 1.75 Japanese ebooks set does.
const double annotatedLineHeight = 1 + rubyScale + 0.25;

/// [typography] for [chapter]: a chapter with ruby or emphasis marks has the
/// line height that makes room for them ([annotatedLineHeight]) when the
/// reader's is less. The gap between two lines holds what stands over the
/// one and under the other: a ruby base with marks on its annotation's side
/// stacks them outside it, and a second ruby level (`<rtc>`) stands under
/// its base, so the gap may hold two or more half ems.
///
/// Every line of the chapter takes it, not only the ones with ruby, so the
/// lines keep an even pitch on the page, as a printed book with ruby sets
/// them. [vertical] tells which side a span's marks are on.
ReaderEpubTypography chapterTypography(
  EpubChapter chapter,
  ReaderEpubTypography typography, {
  bool vertical = false,
}) {
  // The annotations over and under one character, in half ems.
  var over = 0;
  var under = 0;
  void spans(List<EpubTextSpan> spans) {
    for (final span in spans) {
      final emphasis = span.emphasis;
      final marksUnder =
          emphasis != null && (vertical ? emphasis.left : emphasis.under);
      over = math.max(
        over,
        (span.ruby != null || span.rubyContinued ? 1 : 0) +
            (emphasis != null && !marksUnder ? 1 : 0),
      );
      under = math.max(
        under,
        (span.rubyUnder != null || span.rubyUnderContinued ? 1 : 0) +
            (marksUnder ? 1 : 0),
      );
    }
  }

  void visit(EpubContentNode node) {
    switch (node) {
      case EpubHeading(spans: final list) || EpubParagraph(spans: final list):
        spans(list);
      case EpubBlockQuote(:final children) || EpubFigure(:final children):
        children.forEach(visit);
      case EpubUnorderedList(:final items) || EpubOrderedList(:final items):
        items.forEach(spans);
      case EpubImage(:final caption):
        spans(caption);
      case EpubTable(:final caption, :final rowGroups):
        spans(caption);
        for (final group in rowGroups) {
          for (final row in group.rows) {
            for (final cell in row.cells) {
              cell.children.forEach(visit);
            }
          }
        }
      case EpubMathNode() || EpubCodeBlock() || EpubHorizontalRule():
        break;
    }
  }

  chapter.blocks.forEach(visit);
  final halves = over + under;
  if (halves == 0) return typography;
  final least = annotatedLineHeight + (halves - 1) * rubyScale;
  return typography.lineHeight >= least
      ? typography
      : typography.copyWith(lineHeight: least);
}

/// Lay out one chapter into a flow.
ChapterFlow layoutChapterFlow({
  required EpubChapter chapter,
  required ChapterLayoutSpec spec,
  required Map<String, ui.Image> images,
}) {
  final context = _FlowContext(
    spec: spec,
    typography: chapterTypography(
      chapter,
      spec.typography,
      vertical: spec.vertical,
    ),
    images: images,
    maxBlockHeight: math.max(120.0, spec.height - 8),
    canonicalText: chapter.canonicalText,
  );
  for (var index = 0; index < chapter.blocks.length; index++) {
    context.layoutNode(chapter.blocks[index], index, 0, 0);
  }
  return ChapterFlow(
    spine: chapter.spine,
    width: spec.width,
    height: context.cursor,
    blocks: List.unmodifiable(context.blocks),
    canonicalScalarCount: chapter.scalarCount,
    overflowClippedBlocks: context.overflowClippedBlocks,
    palette: spec.typography.palette,
    nodeCount: chapter.blocks.length,
  );
}

/// Reads a monotonic clock, in microseconds.
///
/// The layout time budgets are spent on this clock. Production reads the
/// system's ([systemLayoutClock]); a test that must not depend on machine
/// speed passes one that never advances, so only the node counts bound a
/// batch.
typedef LayoutClock = int Function();

final Stopwatch _systemLayoutStopwatch = Stopwatch()..start();

/// Microseconds on the system's monotonic clock.
int systemLayoutClock() => _systemLayoutStopwatch.elapsedMicroseconds;

/// Incremental, windowed layout of one chapter.
///
/// The session measures a contiguous range of chapter nodes. The first range
/// is a priority window around the reader's durable location, so the current
/// page can be installed before the rest of the chapter is measured; the
/// driver then extends the window forward and backward in bounded batches and
/// yields between them. Blocks keep their measured pixels ([TextPainter]s) and
/// only their flow-space tops change as the range grows.
///
/// The session frame is stable while it fills: extending backward prepends
/// into negative space, and [snapshot] normalizes the frame so an installed
/// flow always starts at zero. Installed snapshots are immutable copies, so
/// later extension never mutates a flow the view already renders.
class ChapterLayoutSession {
  ChapterLayoutSession({
    required this.chapter,
    required this.spec,
    required this.images,
    this.clock = systemLayoutClock,
  }) : _maxBlockHeight = math.max(120.0, spec.height - 8);

  final EpubChapter chapter;
  final ChapterLayoutSpec spec;
  final Map<String, ui.Image> images;

  /// The clock the batches' time budgets are spent on.
  final LayoutClock clock;
  final double _maxBlockHeight;

  final List<FlowBlock> _blocks = [];

  /// Frame cursor at the start of each laid-out node, then the range's end:
  /// `laidOutNodes + 1` entries once started. A released node's extent is read
  /// from here, so the frame of the nodes that stay never moves.
  final List<double> _bounds = [];
  double _rangeStart = 0;
  double _cursor = 0;
  int _firstNode = 0;
  int _nextNode = 0;
  int _overflowClipped = 0;
  bool _started = false;

  /// Total synchronous layout time spent in this session, microseconds.
  int layoutWorkMicros = 0;

  /// Work already reported to an owner (measurement bookkeeping only).
  int reportedWorkMicros = 0;

  /// Nodes measured in this session, counting a node again each time it is
  /// measured again after a release (measurement bookkeeping only).
  int measuredNodes = 0;

  bool get started => _started;
  bool get complete =>
      _started && _firstNode == 0 && _nextNode == chapter.blocks.length;
  int get firstNodeIndex => _firstNode;
  int get lastNodeIndex => _nextNode - 1;
  int get laidOutNodes => _started ? _nextNode - _firstNode : 0;
  int get totalNodes => chapter.blocks.length;

  /// Canonical scalar of the first laid-out block, or null when empty.
  int? get firstCanonical =>
      _blocks.isEmpty ? null : _blocks.first.canonicalStart;

  /// Canonical scalar of the last laid-out block, or null when empty.
  int? get lastCanonical => _blocks.isEmpty ? null : _blocks.last.canonicalEnd;

  /// Whether [scalar] is inside the laid-out range.
  bool covers(int scalar) {
    final first = firstCanonical;
    final last = lastCanonical;
    if (first == null || last == null) return false;
    return scalar >= first && scalar <= last;
  }

  /// Node index whose canonical range contains [scalar] (or the last node that
  /// starts before it, clamped to the chapter).
  int nodeIndexForScalar(int scalar) {
    var result = 0;
    for (var index = 0; index < chapter.blocks.length; index++) {
      final canonical = chapter.blocks[index].canonical;
      if (canonical == null) continue;
      if (canonical.start <= scalar) {
        result = index;
      } else {
        break;
      }
    }
    return result;
  }

  /// The typography the chapter's blocks are laid out with.
  late final ReaderEpubTypography _typography = chapterTypography(
    chapter,
    spec.typography,
    vertical: spec.vertical,
  );

  _FlowContext _newContext() => _FlowContext(
    spec: spec,
    typography: _typography,
    images: images,
    maxBlockHeight: _maxBlockHeight,
    canonicalText: chapter.canonicalText,
    onPainterCreated: _debugPainterCreated,
  );

  /// Measure the priority window around [scalar]: from the node containing it
  /// (or from [node] when given) forward until at least [viewports] viewport
  /// heights are measured, so the reader can show the durable location plus
  /// the following page.
  ///
  /// It is the first range of a session, or the first after [releaseAll].
  ///
  /// [maxNodes] and [maxMicros] bound the window the way they bound a batch
  /// (at least one node is measured); the window is then extended by batches.
  void layoutWindowAt(
    int scalar, {
    double viewports = 2.5,
    int? node,
    int? maxNodes,
    int? maxMicros,
  }) {
    assert(!_started, 'the priority window is the first range of a session');
    final context = _newContext();
    final started = clock();
    final target = math.max(
      0,
      math.min(node ?? nodeIndexForScalar(scalar), chapter.blocks.length - 1),
    );
    var index = target;
    final bounds = <double>[0];
    final targetHeight = math.max(120.0, spec.height) * viewports;
    try {
      while (index < chapter.blocks.length) {
        context.layoutNode(chapter.blocks[index], index, 0, 0);
        bounds.add(context.cursor);
        index++;
        if (context.cursor >= targetHeight) break;
        if (maxNodes != null && index - target >= maxNodes) break;
        if (maxMicros != null && clock() - started >= maxMicros) {
          break;
        }
      }
    } catch (_) {
      // A window that throws before the session adopts it would otherwise leak
      // every painter it created (including one whose construction never
      // finished): release them here and let the caller report the failure.
      context.releaseUnadoptedPainters(const []);
      rethrow;
    }
    layoutWorkMicros += clock() - started;
    measuredNodes += index - target;
    _blocks.addAll(context.blocks);
    context.transferCreatedPainters();
    _overflowClipped += context.overflowClippedBlocks;
    _bounds
      ..clear()
      ..addAll(bounds);
    _firstNode = target;
    _nextNode = index;
    _rangeStart = 0;
    _cursor = context.cursor;
    _started = true;
  }

  /// Measure up to [maxNodes] further nodes after the current range, stopping
  /// early when [maxMicros] of layout work has been spent.
  ///
  /// Each batch measures in its own context starting at the range's end, so
  /// the session retains only the blocks of its current range: a released
  /// block is referenced by nothing the session keeps.
  int layoutForward({int maxNodes = 24, int maxMicros = 8000}) {
    if (!_started || _nextNode >= chapter.blocks.length) return 0;
    final context = _newContext()..cursor = _cursor;
    final started = clock();
    final bounds = <double>[];
    var next = _nextNode;
    var laid = 0;
    try {
      while (next < chapter.blocks.length &&
          laid < maxNodes &&
          clock() - started < maxMicros) {
        if (next == debugFailNodeIndex) {
          throw StateError('debug layout failure at $next');
        }
        context.layoutNode(chapter.blocks[next], next, 0, 0);
        bounds.add(context.cursor);
        next++;
        laid++;
      }
    } catch (_) {
      // A batch that throws adopts nothing: every painter this call created
      // (including one whose construction never finished) is released here,
      // and the range is unchanged, so a retry re-measures those nodes instead
      // of leaving a hole.
      context.releaseUnadoptedPainters(const []);
      rethrow;
    }
    _blocks.addAll(context.blocks);
    context.transferCreatedPainters();
    _bounds.addAll(bounds);
    _overflowClipped += context.overflowClippedBlocks;
    _nextNode = next;
    _cursor = context.cursor;
    layoutWorkMicros += clock() - started;
    measuredNodes += laid;
    return laid;
  }

  /// Detaches every block of the nodes before [node] from the range.
  ///
  /// The blocks are returned, not released: a page the model still paints may
  /// reference them, so their owner disposes them ([disposeFlowBlocks]) once
  /// nothing renders them. The remaining nodes keep their frame positions.
  List<FlowBlock> releaseBefore(int node) {
    if (!_started || node <= _firstNode) return const [];
    final to = math.min(node, _nextNode);
    var count = 0;
    while (count < _blocks.length && _blocks[count].nodeIndex < to) {
      count++;
    }
    final released = _blocks.sublist(0, count);
    _blocks.removeRange(0, count);
    final nodes = to - _firstNode;
    _rangeStart = _bounds[nodes];
    _bounds.removeRange(0, nodes);
    _firstNode = to;
    return released;
  }

  /// Detaches every block of [node] and the nodes after it from the range.
  ///
  /// As with [releaseBefore], the owner disposes the returned blocks.
  List<FlowBlock> releaseFrom(int node) {
    if (!_started || node >= _nextNode) return const [];
    final from = math.max(node, _firstNode);
    var keep = _blocks.length;
    while (keep > 0 && _blocks[keep - 1].nodeIndex >= from) {
      keep--;
    }
    final released = _blocks.sublist(keep);
    _blocks.removeRange(keep, _blocks.length);
    final nodes = from - _firstNode;
    _cursor = _bounds[nodes];
    _bounds.removeRange(nodes + 1, _bounds.length);
    _nextNode = from;
    return released;
  }

  /// Detaches the whole range, so the next [layoutWindowAt] starts a new one.
  ///
  /// As with [releaseBefore], the owner disposes the returned blocks.
  List<FlowBlock> releaseAll() {
    final released = List<FlowBlock>.of(_blocks);
    _blocks.clear();
    _bounds.clear();
    _firstNode = 0;
    _nextNode = 0;
    _rangeStart = 0;
    _cursor = 0;
    _started = false;
    return released;
  }

  /// The blocks of the laid-out range in node order, in the session frame.
  List<FlowBlock> get blocks => List.unmodifiable(_blocks);

  /// Measure up to [maxNodes] earlier nodes before the current range, stopping
  /// early when [maxMicros] of layout work has been spent. Existing blocks
  /// keep their tops; the prepended nodes occupy negative frame space, which
  /// [snapshot] normalizes away.
  int layoutBackward({int maxNodes = 24, int maxMicros = 8000}) {
    if (!_started || _firstNode == 0) return 0;
    final started = clock();
    // The batch is staged aside and committed only when it completes: a throw
    // then leaves the range exactly as it was, and every painter the batch
    // created is released here rather than left to finalization. The staged
    // copies share their context's painters, so a failed batch releases the
    // contexts and drops the copies.
    final staged = <FlowBlock>[];
    final contexts = <_FlowContext>[];
    var stagedRange = _rangeStart;
    final tops = <double>[];
    var stagedOverflow = 0;
    var first = _firstNode;
    var laid = 0;
    try {
      while (first > 0 && laid < maxNodes && clock() - started < maxMicros) {
        final index = first - 1;
        final context = _newContext();
        contexts.add(context);
        if (index == debugFailNodeIndex) {
          throw StateError('debug layout failure at $index');
        }
        context.layoutNode(chapter.blocks[index], index, 0, 0);
        final height = context.cursor;
        stagedRange -= height;
        tops.add(stagedRange);
        staged.insertAll(0, [
          for (final block in context.blocks) block.shifted(stagedRange),
        ]);
        stagedOverflow += context.overflowClippedBlocks;
        first = index;
        laid++;
      }
    } catch (_) {
      for (final context in contexts) {
        context.releaseUnadoptedPainters(const []);
      }
      rethrow;
    }
    _blocks.insertAll(0, staged);
    for (final context in contexts) {
      context.transferCreatedPainters();
    }
    _bounds.insertAll(0, tops.reversed);
    _rangeStart = stagedRange;
    _overflowClipped += stagedOverflow;
    _firstNode = first;
    layoutWorkMicros += clock() - started;
    measuredNodes += laid;
    return laid;
  }

  /// A snapshot of the laid-out range, normalized so its first block starts at
  /// flow offset zero. Blocks are copies: a later extension cannot mutate a
  /// flow the model already installed.
  ChapterFlow snapshot() {
    final shift = -_rangeStart;
    return ChapterFlow(
      spine: chapter.spine,
      width: spec.width,
      height: _cursor - _rangeStart,
      blocks: List.unmodifiable([
        for (final block in _blocks) block.shifted(shift),
      ]),
      canonicalScalarCount: chapter.scalarCount,
      overflowClippedBlocks: _overflowClipped,
      palette: spec.typography.palette,
      layoutComplete: complete,
      firstNodeIndex: _firstNode,
      nodeCount: chapter.blocks.length,
    );
  }

  /// Releases every measured paragraph this session owns.
  ///
  /// A session's painters are the only native text resources the Dart layout
  /// retains, so the owner must call this when the session is retired: the
  /// chapter window, not the chapter, is what stays resident.
  bool _disposed = false;

  /// Test-only: the chapter node index whose measurement throws.
  ///
  /// A layout failure (an allocation or text-shaping failure) must not leave a
  /// half-adopted range: a test needs to reach that path deterministically, and
  /// a real failure cannot be produced from an input. Production leaves it null.
  int? debugFailNodeIndex;

  /// Test-only: throw after the Nth text painter is created (1-based).
  ///
  /// Reaches a failure *between* a painter's allocation and its adoption, which
  /// is the window a construction failure can leak in.
  int? debugFailTextBlockAt;

  /// Test-only: every text painter the session's contexts create, in order.
  ///
  /// A test asserts deterministic release by inspecting `debugDisposed` on the
  /// painters an interrupted construction created. Production leaves it empty.
  final List<TextPainter> debugCreatedPainters = [];

  /// Test-only: whether created painters are captured and failures injected.
  ///
  /// Both hooks are opt-in so production never pays for them; a test sets
  /// [debugObservePainters] (or [debugFailTextBlockAt], which needs the same
  /// hook) before it lays anything out.
  bool debugObservePainters = false;

  void _debugPainterCreated(TextPainter painter) {
    // Inert unless a test opted in: production pays one boolean test per
    // painter and retains nothing.
    if (!debugObservePainters && debugFailTextBlockAt == null) return;
    debugCreatedPainters.add(painter);
    if (debugFailTextBlockAt == debugCreatedPainters.length) {
      // Test-only: the painter exists and is registered with its context, but
      // the construction never reaches adoption.
      throw StateError(
        'debug text block failure at ${debugCreatedPainters.length}',
      );
    }
  }

  /// Whether the owner released this session's measured paragraphs.
  ///
  /// A session is released exactly once by its owner; the flag is exposed so an
  /// owner (and a test asserting ownership) can tell a released session from a
  /// live one.
  bool get isDisposed => _disposed;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    disposeFlowBlocks(_blocks);
    _blocks.clear();
    _bounds.clear();
    debugCreatedPainters.clear();
  }
}

/// Collects the text painters [blocks] own.
void collectPainters(Iterable<FlowBlock> blocks, Set<TextPainter> into) {
  for (final block in blocks) {
    void add(FlowTextBlock? text) {
      if (text != null) into.add(text.painter);
    }

    add(block.text);
    add(block.image?.fallbackText);
    add(block.image?.caption);
    final table = block.table;
    if (table != null) {
      add(table.caption);
      for (final row in table.rows) {
        for (final cell in row.cells) {
          for (final text in cell.blocks) {
            add(text);
          }
        }
      }
    }
  }
}

/// Releases every measured paragraph in [blocks].
///
/// Shared by a session's own retirement and by a window whose measurement threw
/// before the session adopted it: painters created in that window are the
/// session's native text resources too, and an owner that never adopts them
/// must not leave them to finalization.
void disposeFlowBlocks(Iterable<FlowBlock> blocks) {
  final disposed = <FlowTextBlock>{};
  void disposeText(FlowTextBlock? block) {
    if (block == null || !disposed.add(block)) return;
    block.dispose();
  }

  for (final block in blocks) {
    disposeText(block.text);
    disposeText(block.image?.fallbackText);
    disposeText(block.image?.caption);
    final table = block.table;
    if (table != null) {
      disposeText(table.caption);
      for (final row in table.rows) {
        for (final cell in row.cells) {
          for (final text in cell.blocks) {
            disposeText(text);
          }
        }
      }
    }
  }
}

/// A synthetic span (code block, math fallback, image alt) whose canonical
/// range comes from its owning node rather than from a parsed inline span.
EpubTextSpan _syntheticSpan(
  String text,
  EpubContentNode node, {
  bool monospace = false,
  bool preserveWhitespace = false,
  bool italic = false,
  EpubMath? math,
  EpubCanonicalSpan? canonicalRange,
}) {
  final span = EpubTextSpan(
    text: text,
    monospace: monospace,
    preserveWhitespace: preserveWhitespace,
    italic: italic,
    math: math,
  );
  final canonical = canonicalRange ?? node.canonical;
  if (canonical != null) {
    final end = canonicalRange == null
        ? canonical.start + text.runes.length
        : canonical.end;
    span.canonical = EpubCanonicalSpan(canonical.start, end);
  }
  return span;
}

class _FlowContext {
  _FlowContext({
    required this.spec,
    required this.typography,
    required this.images,
    required this.maxBlockHeight,
    required this.canonicalText,
    this.onPainterCreated,
  });

  /// Test-only: called for every painter this context creates.
  final void Function(TextPainter painter)? onPainterCreated;

  final List<TextPainter> _painters = [];

  /// Registers one painter so a failure between its creation and its adoption
  /// can release it deterministically.
  TextPainter _registerPainter(TextPainter painter) {
    _painters.add(painter);
    onPainterCreated?.call(painter);
    return painter;
  }

  /// Releases one scratch block this context measured and no longer needs.
  ///
  /// The painter leaves the registry first: it was released here, so a later
  /// failure must not release it a second time.
  void _releaseScratch(FlowTextBlock block) {
    _painters.remove(block.painter);
    block.dispose();
  }

  /// Releases the painters this context created that [adopted] does not own.
  ///
  /// Called when a window, batch or construction throws: nothing created after
  /// the last adoption may survive, and nothing already adopted may be released
  /// (an adopted block's painter is the session's to release on retirement).
  void releaseUnadoptedPainters(Iterable<FlowBlock> adopted) {
    final kept = <TextPainter>{};
    collectPainters(adopted, kept);
    final released = <TextPainter>{};
    for (final painter in _painters) {
      if (kept.contains(painter) || !released.add(painter)) continue;
      painter.dispose();
    }
    _painters.clear();
  }

  /// Transfers every painter this context created to its adopter.
  void transferCreatedPainters() => _painters.clear();

  final ChapterLayoutSpec spec;
  final Map<String, ui.Image> images;
  final double maxBlockHeight;

  /// The chapter's canonical stream, used to render exact fallback slices
  /// (nested tables) whose canonical addresses must not shift.
  final String canonicalText;

  final List<FlowBlock> blocks = [];
  double cursor = 0;
  int overflowClippedBlocks = 0;

  /// The spec's typography, with room for the chapter's ruby and emphasis
  /// marks ([chapterTypography]).
  final ReaderEpubTypography typography;
  double get baseFontSize => typography.fontSize;

  double _spacingEm(EpubNodeStyle? style, double defaultBefore) {
    final before = style?.blockBeforeEm ?? defaultBefore;
    return before * baseFontSize;
  }

  void _append({
    required int nodeIndex,
    required double height,
    required double spacingBefore,
    FlowTextBlock? text,
    FlowImageBlock? image,
    FlowTableBlock? table,
    FlowRuleBlock? rule,
  }) {
    cursor += spacingBefore;
    blocks.add(
      FlowBlock(
        nodeIndex: nodeIndex,
        top: cursor,
        height: height,
        text: text,
        image: image,
        table: table,
        rule: rule,
      ),
    );
    cursor += height;
  }

  void layoutNode(
    EpubContentNode node,
    int nodeIndex,
    double indent,
    double spacingScale,
  ) {
    switch (node) {
      case EpubHeading(:final spans, :final level):
        final style = node.nodeStyle ?? const EpubNodeStyle();
        final text = _textBlock(
          spans,
          maxWidth: spec.width - indent,
          baseFontSize: baseFontSize * (style.fontSizeMultiplier ?? 1.0),
          align: style.textAlign,
          direction: style.direction,
        );
        if (text == null) return;
        final before = level <= 2 ? _headingSpacingBeforeEm : 0.6;
        _append(
          nodeIndex: nodeIndex,
          height: text.height,
          spacingBefore: _spacingEm(style, before),
          text: text,
        );
        cursor += (style.blockAfterEm ?? _headingSpacingAfterEm) * baseFontSize;
      case EpubParagraph(:final spans):
        final style = node.nodeStyle;
        final text = _textBlock(
          spans,
          maxWidth: spec.width - indent,
          baseFontSize: baseFontSize,
          align: style.textAlign,
          direction: style.direction,
        );
        if (text == null) return;
        _append(
          nodeIndex: nodeIndex,
          height: text.height,
          spacingBefore: _spacingEm(style, _paragraphSpacingEm),
          text: text,
        );
        cursor += (style.blockAfterEm ?? 0) * baseFontSize;
      case EpubBlockQuote(:final children, :final nodeStyle):
        final style = nodeStyle ?? const EpubNodeStyle();
        final quoteIndent = indent + 1.2 * baseFontSize;
        cursor += _spacingEm(style, _paragraphSpacingEm);
        for (final child in children) {
          layoutNode(child, nodeIndex, quoteIndent, spacingScale);
        }
      case EpubFigure(:final children, :final nodeStyle):
        final style = nodeStyle ?? const EpubNodeStyle();
        cursor += _spacingEm(style, _figureSpacingEm);
        for (final child in children) {
          layoutNode(child, nodeIndex, indent, spacingScale);
        }
      case EpubUnorderedList(:final items):
        for (final item in items) {
          final text = _textBlock(
            item,
            maxWidth: spec.width - indent - 1.4 * baseFontSize,
            baseFontSize: baseFontSize,
            align: null,
            direction: EpubDirection.ltr,
            marker: '•',
            markerIndent: 1.4 * baseFontSize,
          );
          if (text == null) continue;
          _append(
            nodeIndex: nodeIndex,
            height: text.height,
            spacingBefore: _listItemSpacingEm * baseFontSize,
            text: text,
          );
        }
      case EpubOrderedList(:final items, :final start):
        for (var index = 0; index < items.length; index++) {
          final marker = '${start + index}.';
          final text = _textBlock(
            items[index],
            maxWidth: spec.width - indent - 1.8 * baseFontSize,
            baseFontSize: baseFontSize,
            align: null,
            direction: EpubDirection.ltr,
            marker: marker,
            markerIndent: 1.8 * baseFontSize,
          );
          if (text == null) continue;
          _append(
            nodeIndex: nodeIndex,
            height: text.height,
            spacingBefore: _listItemSpacingEm * baseFontSize,
            text: text,
          );
        }
      case EpubCodeBlock(:final code):
        final span = _syntheticSpan(
          code,
          node,
          monospace: true,
          preserveWhitespace: true,
        );
        final text = _textBlock(
          [span],
          maxWidth: spec.width - indent,
          baseFontSize: baseFontSize * 0.9,
          align: null,
          direction: EpubDirection.ltr,
        );
        if (text == null) return;
        _append(
          nodeIndex: nodeIndex,
          height: text.height,
          spacingBefore: _codeSpacingEm * baseFontSize,
          text: text,
        );
        cursor += _codeSpacingEm * baseFontSize;
      case EpubMathNode(:final content):
        final text = _textBlock(
          [
            _syntheticSpan(
              content.fallback,
              node,
              math: content,
              italic: content.display == EpubMathDisplay.block,
            ),
          ],
          maxWidth: spec.width - indent,
          baseFontSize: baseFontSize,
          align: content.display == EpubMathDisplay.block
              ? EpubTextAlign.center
              : null,
          direction: EpubDirection.ltr,
        );
        if (text == null) return;
        _append(
          nodeIndex: nodeIndex,
          height: text.height,
          spacingBefore: _paragraphSpacingEm * baseFontSize,
          text: text,
        );
      case EpubImage():
        _layoutImage(node, nodeIndex, indent);
      case EpubTable():
        _layoutTable(node, nodeIndex, indent);
      case EpubHorizontalRule():
        _append(
          nodeIndex: nodeIndex,
          height: 1,
          spacingBefore: _ruleSpacingEm * baseFontSize,
          rule: FlowRuleBlock(
            canonicalStart: node.canonical?.start ?? 0,
            canonicalEnd: node.canonical?.end ?? 0,
          ),
        );
        cursor += _ruleSpacingEm * baseFontSize;
    }
  }

  void _layoutImage(EpubImage node, int nodeIndex, double indent) {
    final style = node.nodeStyle ?? const EpubNodeStyle();
    cursor += _spacingEm(style, _figureSpacingEm);
    final available = math.max(40.0, spec.width - indent);
    final image = images[node.src];
    if (image != null && image.width > 0 && image.height > 0) {
      // A vertical flow is turned a quarter turn, so the image is measured
      // turned too: its height runs along the line.
      final turned = spec.vertical;
      final imageWidth = turned ? image.height : image.width;
      final imageHeight = turned ? image.width : image.height;
      var width = available.toDouble();
      var height = width * imageHeight / imageWidth;
      if (node.intrinsicSize != null) {
        // Respect a smaller intrinsic size (no upscaling) while still
        // constraining large images to the content box and page height.
        final intrinsic = node.intrinsicSize!;
        final intrinsicWidth = turned ? intrinsic.height : intrinsic.width;
        final intrinsicHeight = turned ? intrinsic.width : intrinsic.height;
        width = math.min(width, intrinsicWidth.toDouble());
        height = width * intrinsicHeight / intrinsicWidth;
      }
      if (height > maxBlockHeight) {
        height = maxBlockHeight;
        width = height * imageWidth / imageHeight;
      }
      if (height > maxBlockHeight) {
        overflowClippedBlocks++;
      }
      final caption = node.caption.isEmpty
          ? null
          : _textBlock(
              node.caption,
              maxWidth: available,
              baseFontSize: baseFontSize * 0.9,
              align: EpubTextAlign.center,
              direction: EpubDirection.ltr,
            );
      final captionGap = caption == null ? 0.0 : 0.4 * baseFontSize;
      final totalHeight = height + captionGap + (caption?.height ?? 0);
      _append(
        nodeIndex: nodeIndex,
        height: totalHeight,
        spacingBefore: 0,
        image: FlowImageBlock(
          src: node.src,
          alt: node.alt,
          image: image,
          fallbackText: null,
          width: width,
          height: height,
          imageRect: Rect.fromLTWH(0, 0, width, height),
          caption: caption,
          canonicalStart: node.canonical?.start ?? 0,
          canonicalEnd: node.canonical?.end ?? 0,
          quarterTurned: turned,
        ),
      );
      cursor += style.blockAfterEm != null
          ? style.blockAfterEm! * baseFontSize
          : _figureSpacingEm * baseFontSize;
      return;
    }
    // Missing or undecodable image: paint the alt text as a visible,
    // selectable fallback (the retained renderer's "missing image" fallback).
    if (node.alt.isNotEmpty || node.caption.isNotEmpty) {
      final fallback = node.alt.isEmpty
          ? null
          : _textBlock(
              [_syntheticSpan(node.alt, node, italic: true)],
              maxWidth: available,
              baseFontSize: baseFontSize,
              align: EpubTextAlign.center,
              direction: EpubDirection.ltr,
            );
      final caption = node.caption.isEmpty
          ? null
          : _textBlock(
              node.caption,
              maxWidth: available,
              baseFontSize: baseFontSize * 0.9,
              align: EpubTextAlign.center,
              direction: EpubDirection.ltr,
            );
      if (fallback != null || caption != null) {
        final fallbackHeight = fallback?.height ?? 0;
        final captionGap = caption == null ? 0.0 : 0.4 * baseFontSize;
        _append(
          nodeIndex: nodeIndex,
          height: fallbackHeight + captionGap + (caption?.height ?? 0),
          spacingBefore: 0,
          image: FlowImageBlock(
            src: node.src,
            alt: node.alt,
            image: null,
            fallbackText: fallback,
            width: available,
            height: fallbackHeight,
            imageRect: Rect.zero,
            caption: caption,
            canonicalStart: node.canonical?.start ?? 0,
            canonicalEnd: node.canonical?.end ?? 0,
          ),
        );
      }
    }
    cursor += _figureSpacingEm * baseFontSize;
  }

  void _layoutTable(EpubTable node, int nodeIndex, double indent) {
    final style = node.nodeStyle ?? const EpubNodeStyle();
    cursor += _spacingEm(style, _tableSpacingEm);
    final tableWidth = math.max(80.0, spec.width - indent);
    final caption = node.caption.isEmpty
        ? null
        : _textBlock(
            node.caption,
            maxWidth: tableWidth,
            baseFontSize: baseFontSize * 0.95,
            align: EpubTextAlign.center,
            direction: EpubDirection.ltr,
          );
    if (caption != null) cursor += 0.2 * baseFontSize;

    // Build the logical grid with colspan/rowspan occupancy.
    final placements = _tablePlacements(node);
    final columnCount = placements.isEmpty
        ? 0
        : placements.map((p) => p.column + p.span).reduce(math.max);
    final columnWidths = _columnWidths(
      node,
      placements,
      columnCount,
      tableWidth,
    );

    final rows = <FlowTableRowLayout>[];
    final headerRows = <int>{};
    var rowIndex = 0;
    var cursorWithinTable = caption == null
        ? 0.0
        : caption.height + 0.2 * baseFontSize;
    for (final group in node.rowGroups) {
      for (final row in group.rows) {
        final cells = <FlowTableCellLayout>[];
        var height = 0.0;
        final rowPlacements = placements
            .where((placement) => placement.row == rowIndex)
            .toList();
        for (final placement in rowPlacements) {
          final cell = row.cells[placement.cellIndex];
          final width = columnWidths
              .sublist(placement.column, placement.column + placement.span)
              .fold<double>(0, (sum, value) => sum + value);
          final contentWidth = math.max(20.0, width - 2 * _tableCellPadding);
          final cellBlocks = <FlowTextBlock>[];
          for (final child in cell.children) {
            final blocks = _cellTextBlocks(child, contentWidth);
            cellBlocks.addAll(blocks);
          }
          final cellHeight = cellBlocks.fold<double>(
            0,
            (sum, block) => sum + block.height,
          );
          height = math.max(height, cellHeight + 2 * _tableCellPadding);
          cells.add(
            FlowTableCellLayout(
              column: placement.column,
              span: placement.span,
              left: columnWidths
                  .sublist(0, placement.column)
                  .fold<double>(0, (sum, value) => sum + value),
              width: width,
              header: cell.header,
              blocks: cellBlocks,
              height: cellHeight,
            ),
          );
        }
        if (cells.isEmpty) {
          rowIndex++;
          continue;
        }
        if (group.kind == EpubTableRowGroupKind.head) headerRows.add(rowIndex);
        final rowSpanGroup = placements
            .where((placement) => placement.row == rowIndex)
            .map((placement) => placement.rowSpan)
            .fold<int>(1, math.max);
        rows.add(
          FlowTableRowLayout(
            groupIndex: 0,
            rowIndex: rowIndex,
            top: cursorWithinTable,
            height: height,
            cells: cells,
            rowSpanGroup: rowSpanGroup,
            canonicalSpan: row.canonical,
          ),
        );
        cursorWithinTable += height;
        rowIndex++;
      }
    }
    final tableHeight = cursorWithinTable;
    if (rows.isEmpty && caption == null) {
      return;
    }
    _append(
      nodeIndex: nodeIndex,
      height: tableHeight,
      spacingBefore: 0,
      table: FlowTableBlock(
        caption: caption,
        rows: rows,
        columnWidths: columnWidths,
        width: tableWidth,
        height: tableHeight,
        headerRows: headerRows,
      ),
    );
    cursor += _tableSpacingEm * baseFontSize;
  }

  List<FlowTextBlock> _cellTextBlocks(EpubContentNode node, double width) {
    switch (node) {
      case EpubParagraph(:final spans):
        final text = _textBlock(
          spans,
          maxWidth: width,
          baseFontSize: baseFontSize,
          align: node.nodeStyle.textAlign,
          direction: node.nodeStyle.direction,
        );
        return text == null ? const [] : [text];
      case EpubHeading(:final spans):
        final text = _textBlock(
          spans,
          maxWidth: width,
          baseFontSize: baseFontSize,
          align: node.nodeStyle?.textAlign,
          direction: node.nodeStyle?.direction ?? EpubDirection.ltr,
        );
        return text == null ? const [] : [text];
      case EpubUnorderedList(:final items):
        final blocks = <FlowTextBlock>[];
        for (final item in items) {
          final text = _textBlock(
            item,
            maxWidth: width - 1.2 * baseFontSize,
            baseFontSize: baseFontSize,
            align: null,
            direction: EpubDirection.ltr,
            marker: '•',
            markerIndent: 1.2 * baseFontSize,
          );
          if (text != null) blocks.add(text);
        }
        return blocks;
      case EpubOrderedList(:final items, :final start):
        final blocks = <FlowTextBlock>[];
        for (var index = 0; index < items.length; index++) {
          final text = _textBlock(
            items[index],
            maxWidth: width - 1.5 * baseFontSize,
            baseFontSize: baseFontSize,
            align: null,
            direction: EpubDirection.ltr,
            marker: '${start + index}.',
            markerIndent: 1.5 * baseFontSize,
          );
          if (text != null) blocks.add(text);
        }
        return blocks;
      case EpubCodeBlock(:final code):
        final text = _textBlock(
          [
            _syntheticSpan(
              code,
              node,
              monospace: true,
              preserveWhitespace: true,
            ),
          ],
          maxWidth: width,
          baseFontSize: baseFontSize * 0.85,
          align: null,
          direction: EpubDirection.ltr,
        );
        return text == null ? const [] : [text];
      case EpubMathNode(:final content):
        final text = _textBlock(
          [_syntheticSpan(content.fallback, node, math: content)],
          maxWidth: width,
          baseFontSize: baseFontSize,
          align: null,
          direction: EpubDirection.ltr,
        );
        return text == null ? const [] : [text];
      case EpubBlockQuote(:final children):
      case EpubFigure(:final children):
        return [for (final child in children) ..._cellTextBlocks(child, width)];
      case EpubImage(:final alt):
        final text = _textBlock(
          [_syntheticSpan(alt, node, italic: true)],
          maxWidth: width,
          baseFontSize: baseFontSize * 0.9,
          align: EpubTextAlign.center,
          direction: EpubDirection.ltr,
        );
        return text == null ? const [] : [text];
      case EpubHorizontalRule():
        return const [];
      case EpubTable():
        // Nested tables fall back to their exact canonical text so no content
        // is silently dropped and every rendered scalar keeps its canonical
        // address. Real nested-table layout is not implemented.
        final slice = _canonicalSlice(node);
        if (slice == null || slice.text.isEmpty) return const [];
        final text = _textBlock(
          [
            _syntheticSpan(
              slice.text,
              node,
              preserveWhitespace: true,
              canonicalRange: EpubCanonicalSpan(slice.start, slice.end),
            ),
          ],
          maxWidth: width,
          baseFontSize: baseFontSize,
          align: null,
          direction: EpubDirection.ltr,
        );
        return text == null ? const [] : [text];
    }
  }

  /// The exact canonical substring of a node, with generated trailing
  /// newline separators trimmed (they are not rendered glyphs, so the
  /// canonical range shrinks with them).
  ({String text, int start, int end})? _canonicalSlice(EpubContentNode node) {
    final span = node.canonical;
    if (span == null || canonicalText.isEmpty) return null;
    var end = math.min(span.end, canonicalText.runes.length);
    var endUnit = codeUnitAtScalar(canonicalText, end);
    while (end > span.start &&
        endUnit > 0 &&
        canonicalText.codeUnitAt(endUnit - 1) == 0x0A) {
      end--;
      endUnit--;
    }
    if (end <= span.start) return null;
    final startUnit = codeUnitAtScalar(canonicalText, span.start);
    return (
      text: canonicalText.substring(startUnit, endUnit),
      start: span.start,
      end: end,
    );
  }

  FlowTextBlock? _textBlock(
    List<EpubTextSpan> spans, {
    required double maxWidth,
    required double baseFontSize,
    required EpubTextAlign? align,
    required EpubDirection direction,
    String? marker,
    double markerIndent = 0,
  }) {
    final markerPrefix = marker == null ? '' : '$marker\t';
    final built = buildBlockText(
      spans,
      typography,
      baseFontSize,
      codeUnitOffset: markerPrefix.length,
      vertical: spec.vertical,
    );
    if (built.map.isEmpty && marker == null) return null;
    final children = <InlineSpan>[];
    if (marker != null) {
      children.add(
        TextSpan(
          text: markerPrefix,
          style: TextStyle(
            fontFamily: typography.fontFamily,
            fontFamilyFallback: typography.fontFamilyFallback,
            fontSize: baseFontSize,
            height: typography.lineHeight,
            color: typography.palette.foreground,
          ),
        ),
      );
    }
    children.add(built.span);
    final textAlign = flutterTextAlign(align ?? EpubTextAlign.start);
    final painter = _registerPainter(
      TextPainter(
        text: TextSpan(children: children),
        textAlign: textAlign,
        textDirection: flutterTextDirection(direction),
        textWidthBasis: TextWidthBasis.parent,
      ),
    );
    final width = math.max(
      20.0,
      maxWidth - (marker != null ? markerIndent : 0),
    );
    painter.layout(maxWidth: width);
    // A line may still break inside tate-chū-yoko where its text allows it
    // (between two kanji, before a full stop that may not start a line):
    // the spans of a run broken across lines are laid out again without it.
    final broken = [
      for (final run in built.redrawn)
        if (run.combined &&
            painter.getLineBoundary(TextPosition(offset: run.start)) !=
                painter.getLineBoundary(TextPosition(offset: run.end - 1)))
          run,
    ];
    if (broken.isNotEmpty) {
      _painters.remove(painter);
      painter.dispose();
      return _textBlock(
        withoutCombining(spans, broken, codeUnitOffset: markerPrefix.length),
        maxWidth: maxWidth,
        baseFontSize: baseFontSize,
        align: align,
        direction: direction,
        marker: marker,
        markerIndent: markerIndent,
      );
    }
    final lines = <FlowLine>[];
    final metrics = painter.computeLineMetrics();
    final bounds = _lineBounds(
      painter: painter,
      map: built.map,
      metrics: metrics,
      fastPath: direction == EpubDirection.ltr && !_hasBidiText(built.map.text),
    );
    // One monotone pass maps every line boundary to its canonical scalar: the
    // per-boundary lookup is O(text) on a single huge span, which dominated the
    // layout of a very long paragraph.
    final offsets = <int>[
      for (final bound in bounds) ...[bound.start, bound.end],
    ];
    final scalars = built.map.canonicalAtAll(offsets);
    for (var index = 0; index < bounds.length; index++) {
      final metric = metrics[index];
      lines.add(
        FlowLine(
          codeUnitStart: bounds[index].start,
          codeUnitEnd: bounds[index].end,
          canonicalStart: scalars[index * 2],
          canonicalEnd: scalars[index * 2 + 1],
          top: metric.baseline - metric.ascent,
          height: metric.height,
        ),
      );
    }
    final links = <({int start, int end, String href})>[
      for (final segment in built.map.segments)
        if (segment.link != null)
          (
            start: segment.codeUnitStart,
            end: segment.codeUnitEnd,
            href: segment.link!,
          ),
    ];
    return FlowTextBlock(
      painter: painter,
      map: built.map,
      lines: lines,
      links: links,
      selectable: spans.any((span) => span.selectable),
      textAlign: textAlign,
      textDirection: flutterTextDirection(direction),
      redrawn: built.redrawn,
      rubies: built.rubies,
      emphasis: built.emphasis,
    );
  }

  List<_TableCellPlacement> _tablePlacements(EpubTable table) {
    final placements = <_TableCellPlacement>[];
    var rowIndex = 0;
    final occupied = <int, Set<int>>{};
    for (final group in table.rowGroups) {
      for (final row in group.rows) {
        var column = 0;
        for (var cellIndex = 0; cellIndex < row.cells.length; cellIndex++) {
          final cell = row.cells[cellIndex];
          while ((occupied[rowIndex] ?? const <int>{}).contains(column)) {
            column++;
          }
          final span = cell.columnSpan.clamp(1, 64);
          final rowSpan = cell.rowSpan == 0 ? 1 : cell.rowSpan.clamp(1, 64);
          placements.add(
            _TableCellPlacement(
              row: rowIndex,
              column: column,
              span: span,
              rowSpan: rowSpan,
              cellIndex: cellIndex,
            ),
          );
          for (var r = rowIndex; r < rowIndex + rowSpan; r++) {
            occupied.putIfAbsent(r, () => <int>{});
            for (var c = column; c < column + span; c++) {
              occupied[r]!.add(c);
            }
          }
          column += span;
        }
        rowIndex++;
      }
    }
    return placements;
  }

  List<double> _columnWidths(
    EpubTable table,
    List<_TableCellPlacement> placements,
    int columnCount,
    double tableWidth,
  ) {
    if (columnCount == 0) return const [];
    final natural = List<double>.filled(columnCount, 0);
    for (final placement in placements) {
      if (placement.span != 1) continue;
      final cell = _cellAt(table, placement);
      if (cell == null) continue;
      var widest = 0.0;
      for (final child in cell.children) {
        for (final block in _cellTextBlocks(child, tableWidth)) {
          widest = math.max(widest, block.painter.width);
          _releaseScratch(block);
        }
      }
      natural[placement.column] = math.max(
        natural[placement.column],
        widest + 2 * _tableCellPadding,
      );
    }
    final total = natural.fold<double>(0, (sum, value) => sum + value);
    if (total <= 0) {
      return List<double>.filled(columnCount, tableWidth / columnCount);
    }
    final scale = tableWidth / total;
    var widths = [for (final value in natural) value * scale];
    // A narrow column still needs a readable minimum; rebalance the rest.
    const minimum = 48.0;
    var deficit = 0.0;
    for (var index = 0; index < widths.length; index++) {
      if (widths[index] < minimum) {
        deficit += minimum - widths[index];
        widths[index] = minimum;
      }
    }
    if (deficit > 0) {
      final flexible = widths
          .where((value) => value > minimum)
          .fold<double>(0, (sum, value) => sum + value);
      if (flexible > 0) {
        widths = [
          for (final value in widths)
            value > minimum ? value - deficit * value / flexible : value,
        ];
      }
    }
    return widths;
  }

  EpubTableCell? _cellAt(EpubTable table, _TableCellPlacement placement) {
    var rowIndex = 0;
    for (final group in table.rowGroups) {
      for (final row in group.rows) {
        if (rowIndex == placement.row) {
          if (placement.cellIndex < row.cells.length) {
            return row.cells[placement.cellIndex];
          }
          return null;
        }
        rowIndex++;
      }
    }
    return null;
  }
}

class _TableCellPlacement {
  const _TableCellPlacement({
    required this.row,
    required this.column,
    required this.span,
    required this.rowSpan,
    required this.cellIndex,
  });

  final int row;
  final int column;
  final int span;
  final int rowSpan;
  final int cellIndex;
}

/// Code-unit ranges of every laid-out line, one per line metric.
///
/// The fast path probes the caret at the left edge of each line's vertical
/// centre. That is O(log lines) per line instead of the boundary API's O(text)
/// scan, which is what made a single huge paragraph expensive. It is only
/// correct when visual order equals logical order, so any right-to-left or
/// bidi-control content (or a right-to-left block) uses the boundary API.
List<({int start, int end})> _lineBounds({
  required TextPainter painter,
  required BlockTextMap map,
  required List<ui.LineMetrics> metrics,
  required bool fastPath,
}) {
  final text = map.text;
  final markerOffset = map.codeUnitOffset;
  final totalLength = map.codeUnitLength;
  final bounds = <({int start, int end})>[];
  if (fastPath) {
    for (var index = 0; index < metrics.length; index++) {
      final metric = metrics[index];
      final y = metric.baseline - metric.ascent + metric.height / 2;
      var start = painter.getPositionForOffset(Offset(0, y)).offset;
      if (index > 0 && start < bounds[index - 1].start) {
        start = bounds[index - 1].start;
      }
      bounds.add((start: start, end: start));
    }
    for (var index = 0; index < bounds.length; index++) {
      final end = index + 1 < bounds.length
          ? bounds[index + 1].start
          : totalLength;
      // Painter offsets include any generated marker prefix; trim hard-break
      // newlines in the map's own coordinates (they belong to no line).
      final startUnit = (bounds[index].start - markerOffset).clamp(
        0,
        text.length,
      );
      var endUnit = (end - markerOffset).clamp(0, text.length);
      while (endUnit > startUnit && text.codeUnitAt(endUnit - 1) == 0x0A) {
        endUnit--;
      }
      bounds[index] = (start: bounds[index].start, end: endUnit + markerOffset);
    }
    return bounds;
  }

  var cursor = 0;
  for (var index = 0; index < metrics.length; index++) {
    var range = cursor < totalLength
        ? painter.getLineBoundary(TextPosition(offset: cursor))
        : TextRange(start: cursor, end: cursor);
    var start = math.max(range.start, cursor);
    var end = math.max(range.end, cursor);
    if (end <= start) {
      // The cursor sits on a hard newline (which the boundary API excludes);
      // skip separators and re-probe so the next visual line is found.
      var probe = cursor;
      while (probe < totalLength && text.codeUnitAt(probe) == 0x0A) {
        probe++;
      }
      if (probe < totalLength) {
        range = painter.getLineBoundary(TextPosition(offset: probe));
        start = math.max(range.start, probe);
        end = math.max(range.end, probe);
        cursor = probe;
      }
    }
    if (end <= start) {
      // An empty trailing line: keep the metric's box with no text range.
      end = start;
    }
    bounds.add((start: start, end: end));
    cursor = math.max(cursor, end);
  }
  return bounds;
}

/// Whether [text] contains right-to-left letters or bidi control characters,
/// where a visual edge probe would not give the logical line boundary.
bool _hasBidiText(String text) {
  for (final rune in text.runes) {
    if ((rune >= 0x0590 && rune <= 0x08FF) ||
        (rune >= 0xFB1D && rune <= 0xFDFF) ||
        (rune >= 0xFE70 && rune <= 0xFEFF) ||
        (rune >= 0x10800 && rune <= 0x10FFF) ||
        (rune >= 0x1E800 && rune <= 0x1EFFF) ||
        rune == 0x200E ||
        rune == 0x200F ||
        (rune >= 0x202A && rune <= 0x202E) ||
        (rune >= 0x2066 && rune <= 0x2069)) {
      return true;
    }
  }
  return false;
}
