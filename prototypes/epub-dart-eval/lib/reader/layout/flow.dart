/// Chapter flow layout: normalized blocks measured with Flutter's text engine
/// into line-level fragments that carry canonical ranges.
///
/// Pixels, hit testing and selection geometry all come from the [TextPainter]s
/// created here; pagination only groups and clips those painters.
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:shosai_epub/shosai_epub.dart';

import '../theme.dart';
import 'text_style.dart';

/// Default block spacing in ems. These are prototype calibrations, not a port
/// of the production pagination constants.
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

/// A measured text block. The painter is the single source of pixels,
/// hit testing and selection geometry for this block.
class FlowTextBlock {
  FlowTextBlock({
    required this.painter,
    required this.map,
    required this.lines,
    required this.links,
    required this.selectable,
    required this.textAlign,
    required this.textDirection,
  });

  final TextPainter painter;
  final BlockTextMap map;
  final List<FlowLine> lines;

  /// Link href per code-unit range, for internal navigation hit testing.
  final List<({int start, int end, String href})> links;
  final bool selectable;
  final TextAlign textAlign;
  final ui.TextDirection textDirection;

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
  });

  final String src;
  final String alt;

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
  });

  final int groupIndex;
  final int rowIndex;
  final double top;
  final double height;
  final List<FlowTableCellLayout> cells;

  /// Number of rows this row's span group covers (1 when no rowspans).
  final int rowSpanGroup;

  int get canonicalStart => cells.isEmpty
      ? 0
      : cells.map((cell) => cell.canonicalStart).reduce(math.min);
  int get canonicalEnd => cells.isEmpty
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
}

/// The complete laid-out chapter flow.
class ChapterFlow {
  ChapterFlow({
    required this.spine,
    required this.width,
    required this.height,
    required this.blocks,
    required this.canonicalScalarCount,
    required this.overflowClippedBlocks,
    required this.palette,
  });

  final int spine;
  final double width;
  final double height;
  final List<FlowBlock> blocks;
  final int canonicalScalarCount;

  /// Palette baked into this layout. Document pixels keep the palette they
  /// were laid out with, so a theme change cannot repaint a live background
  /// behind text that still carries the previous colours.
  final ReaderPalette palette;

  /// Blocks that cannot fit one page/tile and are painted clipped. A non-zero
  /// count is reported in evidence rather than hidden.
  final int overflowClippedBlocks;
}

class ChapterLayoutSpec {
  const ChapterLayoutSpec({
    required this.width,
    required this.height,
    required this.typography,
  });

  /// Logical content width (already excludes chrome and page padding).
  final double width;

  /// Logical content height available to one page (paginated) or the viewport
  /// used to bound atomic blocks (continuous).
  final double height;
  final ReaderTypography typography;

  @override
  bool operator ==(Object other) =>
      other is ChapterLayoutSpec &&
      other.width == width &&
      other.height == height &&
      other.typography == typography;

  @override
  int get hashCode => Object.hash(width, height, typography);
}

/// Lay out one chapter into a flow.
ChapterFlow layoutChapterFlow({
  required EpubChapter chapter,
  required ChapterLayoutSpec spec,
  required Map<String, ui.Image> images,
  required Map<String, String> imageMediaTypes,
}) {
  final context = _FlowContext(
    spec: spec,
    images: images,
    imageMediaTypes: imageMediaTypes,
    maxBlockHeight: math.max(120.0, spec.height - 8),
    canonicalText: chapter.canonicalText,
  );
  for (var index = 0; index < chapter.blocks.length; index++) {
    context.layoutNode(chapter.blocks[index], index, 0, 0);
  }
  context.finish();
  return ChapterFlow(
    spine: chapter.spine,
    width: spec.width,
    height: context.cursor,
    blocks: context.blocks,
    canonicalScalarCount: chapter.scalarCount,
    overflowClippedBlocks: context.overflowClippedBlocks,
    palette: spec.typography.palette,
  );
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
    required this.images,
    required this.imageMediaTypes,
    required this.maxBlockHeight,
    required this.canonicalText,
  });

  final ChapterLayoutSpec spec;
  final Map<String, ui.Image> images;
  final Map<String, String> imageMediaTypes;
  final double maxBlockHeight;

  /// The chapter's canonical stream, used to render exact fallback slices
  /// (nested tables) whose canonical addresses must not shift.
  final String canonicalText;

  final List<FlowBlock> blocks = [];
  double cursor = 0;
  int overflowClippedBlocks = 0;

  ReaderTypography get typography => spec.typography;
  double get baseFontSize => typography.fontSize;

  void finish() {
    // Nothing to finalize yet; block tops are assigned as they are appended.
  }

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
          textIndent: 0,
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
          textIndent: 0,
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
      var width = available.toDouble();
      var height = width * image.height / image.width;
      if (node.intrinsicSize != null) {
        // Respect a smaller intrinsic size (no upscaling) while still
        // constraining large images to the content box and page height.
        final intrinsic = node.intrinsicSize!;
        width = math.min(width, intrinsic.width.toDouble());
        height = width * intrinsic.height / intrinsic.width;
      }
      if (height > maxBlockHeight) {
        height = maxBlockHeight;
        width = height * image.width / image.height;
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
        ),
      );
      cursor += style.blockAfterEm != null
          ? style.blockAfterEm! * baseFontSize
          : _figureSpacingEm * baseFontSize;
      return;
    }
    // Missing or undecodable image: paint the alt text as a visible,
    // selectable fallback (the production "missing image" fallback).
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
    double textIndent = 0,
  }) {
    final markerPrefix = marker == null ? '' : '$marker\t';
    final built = buildBlockText(
      spans,
      typography,
      baseFontSize,
      codeUnitOffset: markerPrefix.length,
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
    final painter = TextPainter(
      text: TextSpan(children: children),
      textAlign: textAlign,
      textDirection: flutterTextDirection(direction),
      textWidthBasis: TextWidthBasis.parent,
    );
    final width = math.max(
      20.0,
      maxWidth - (marker != null ? markerIndent : 0),
    );
    painter.layout(maxWidth: width);
    final lines = <FlowLine>[];
    final metrics = painter.computeLineMetrics();
    final totalLength = built.map.codeUnitLength;
    var cursor = 0;
    for (final metric in metrics) {
      // Logical line boundaries come from the painter's own line boundary API.
      // Two visual-edge caret probes are not sufficient for bidi: a logical
      // endpoint can sit at an internal visual boundary.
      var range = cursor < totalLength
          ? painter.getLineBoundary(TextPosition(offset: cursor))
          : TextRange(start: cursor, end: cursor);
      var start = math.max(range.start, cursor);
      var end = math.max(range.end, cursor);
      if (end <= start) {
        // The cursor sits on a hard newline (which the boundary API excludes);
        // skip separators and re-probe so the next visual line is found.
        var probe = cursor;
        while (probe < totalLength &&
            built.map.text.codeUnitAt(probe) == 0x0A) {
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
      lines.add(
        FlowLine(
          codeUnitStart: start,
          codeUnitEnd: end,
          canonicalStart: built.map.canonicalAt(start),
          canonicalEnd: built.map.canonicalAt(end),
          top: metric.baseline - metric.ascent,
          height: metric.height,
        ),
      );
      cursor = math.max(cursor, end);
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
