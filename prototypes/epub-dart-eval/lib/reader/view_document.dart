/// Document surfaces: painting and pointer handling.
///
/// Both modes paint from the flow's [TextPainter]s and hit test through the
/// same geometry functions, so what is painted and what is selected cannot
/// drift apart.
library;

import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'geometry.dart';
import 'layout/flow.dart';
import 'layout/pages.dart';
import 'message.dart';
import 'model.dart';
import 'theme.dart';

class EpubDocumentSurface extends StatelessWidget {
  const EpubDocumentSurface({
    super.key,
    required this.model,
    required this.dispatch,
    this.repaintKey,
  });

  final EpubReaderModel model;
  final void Function(EpubReaderMessage) dispatch;
  final Key? repaintKey;

  @override
  Widget build(BuildContext context) {
    final geometry = model.geometry;
    if (geometry == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final surface = model.mode == EpubReaderMode.paginated
        ? _PaginatedSurface(model: model, dispatch: dispatch)
        : _ContinuousSurface(model: model, dispatch: dispatch);
    if (repaintKey == null) return surface;
    return RepaintBoundary(key: repaintKey, child: surface);
  }
}

/// Pointer handling shared by both modes.
///
/// A press alone never starts a selection: a drag past a small threshold does.
/// A press without movement is a tap, which the controller resolves (link
/// activation, clearing the selection).
class _SelectionGestures extends StatefulWidget {
  const _SelectionGestures({
    required this.dispatch,
    required this.selectionActive,
    required this.child,
  });

  final void Function(EpubReaderMessage) dispatch;
  final bool selectionActive;
  final Widget child;

  @override
  State<_SelectionGestures> createState() => _SelectionGesturesState();
}

class _SelectionGesturesState extends State<_SelectionGestures> {
  Offset? _down;
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (event) {
        _down = event.localPosition;
        _dragging = false;
      },
      onPointerMove: (event) {
        final down = _down;
        if (down == null) return;
        if (!_dragging &&
            (event.localPosition - down).distance > 6 &&
            event.buttons == kPrimaryButton) {
          _dragging = true;
          widget.dispatch(EpubReaderSelectionStarted(down));
        }
        if (_dragging) {
          widget.dispatch(EpubReaderSelectionExtended(event.localPosition));
        }
      },
      onPointerUp: (event) {
        if (_dragging) {
          widget.dispatch(const EpubReaderSelectionEnded());
        } else {
          widget.dispatch(EpubReaderTapRequested(event.localPosition));
        }
        _down = null;
        _dragging = false;
      },
      onPointerCancel: (event) {
        _down = null;
        _dragging = false;
      },
      child: widget.child,
    );
  }
}

class _PaginatedSurface extends StatelessWidget {
  const _PaginatedSurface({required this.model, required this.dispatch});

  final EpubReaderModel model;
  final void Function(EpubReaderMessage) dispatch;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => _SelectionGestures(
        dispatch: dispatch,
        selectionActive: model.selection != null,
        child: CustomPaint(
          size: Size(constraints.maxWidth, constraints.maxHeight),
          painter: EpubPagePainter(model: model),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

class _ContinuousSurface extends StatefulWidget {
  const _ContinuousSurface({required this.model, required this.dispatch});

  final EpubReaderModel model;
  final void Function(EpubReaderMessage) dispatch;

  @override
  State<_ContinuousSurface> createState() => _ContinuousSurfaceState();
}

class _ContinuousSurfaceState extends State<_ContinuousSurface> {
  final ScrollController _scroll = ScrollController();
  double _lastReported = -1;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_reportOffset);
  }

  @override
  void dispose() {
    _scroll.removeListener(_reportOffset);
    _scroll.dispose();
    super.dispose();
  }

  void _reportOffset() {
    if (!_scroll.hasClients) return;
    final offset = _scroll.offset;
    if ((offset - _lastReported).abs() < 1) return;
    _lastReported = offset;
    widget.dispatch(EpubReaderContinuousOffsetChanged(offset));
  }

  @override
  Widget build(BuildContext context) {
    final model = widget.model;
    final flow = model.flow;
    if (flow == null) return const Center(child: CircularProgressIndicator());
    return LayoutBuilder(
      builder: (context, constraints) {
        final target = model.continuousOffset;
        if (_scroll.hasClients && (target - _scroll.offset).abs() > 1) {
          _lastReported = target;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _scroll.hasClients) {
              _scroll.jumpTo(target.clamp(0.0, math.max(0.0, flow.height)));
            }
          });
        }
        // The scroll extent is a bare spacer; the document is painted by a
        // viewport-sized overlay that only draws the visible window. Sizing a
        // CustomPaint to the whole flow would allocate a layer proportional to
        // the chapter instead of the viewport.
        return Stack(
          children: [
            _SelectionGestures(
              dispatch: widget.dispatch,
              selectionActive: model.selection != null,
              child: SingleChildScrollView(
                controller: _scroll,
                child: SizedBox(
                  height: math.max(flow.height, constraints.maxHeight),
                  width: constraints.maxWidth,
                ),
              ),
            ),
            Positioned.fill(
              child: IgnorePointer(
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: EpubContinuousPainter(model: model),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Paints the visible spread pages.
class EpubPagePainter extends CustomPainter {
  EpubPagePainter({required this.model});

  final EpubReaderModel model;

  @override
  void paint(Canvas canvas, Size size) {
    final geometry = model.geometry;
    final paginated = model.paginated;
    final flow = model.flow;
    final palette = flow?.palette ?? model.typography.palette;
    canvas.drawRect(Offset.zero & size, Paint()..color = palette.background);
    if (geometry == null || paginated == null || flow == null) return;
    final columns = geometry.columns;
    final gutter = columns == 2 ? 20.0 : 0.0;
    final pages = model.visiblePages;
    for (var index = 0; index < pages.length; index++) {
      final columnX = index * (geometry.pageWidth + gutter);
      canvas.save();
      canvas.translate(columnX, 0);
      _paintPage(
        canvas,
        paginated: paginated,
        page: paginated.pages[pages[index]],
        palette: palette,
        selection: model.selection,
        highlights: model.highlights,
        spine: model.spine,
        geometry: geometry,
      );
      canvas.restore();
    }
  }

  void _paintPage(
    Canvas canvas, {
    required PaginatedChapter paginated,
    required FlowPage page,
    required ReaderPalette palette,
    required EpubSelection? selection,
    required List<EpubHighlight> highlights,
    required int spine,
    required EpubLayoutGeometry geometry,
  }) {
    canvas.save();
    canvas.clipRect(
      Rect.fromLTWH(0, 0, geometry.contentWidth, geometry.pageHeight),
    );
    // Highlights first, then selection on top.
    for (final highlight in highlights) {
      if (highlight.spine != spine) continue;
      final rects = projectRangePage(
        chapter: paginated,
        pageIndex: page.index,
        start: highlight.start,
        end: highlight.end,
      );
      final paint = Paint()..color = highlightColor(highlight.color);
      for (final rect in rects) {
        canvas.drawRect(rect, paint);
      }
    }
    if (selection != null && selection.end > selection.start) {
      final rects = projectRangePage(
        chapter: paginated,
        pageIndex: page.index,
        start: selection.start,
        end: selection.end,
      );
      final paint = Paint()..color = palette.selectionFill;
      for (final rect in rects) {
        canvas.drawRect(rect, paint);
      }
      if (rects.isNotEmpty) {
        _paintSelectionHandles(canvas, rects, palette);
      }
    }
    for (final slice in page.slices) {
      _paintSlice(canvas, slice, palette);
    }
    canvas.restore();
  }

  void _paintSelectionHandles(
    Canvas canvas,
    List<Rect> rects,
    ReaderPalette palette,
  ) {
    final paint = Paint()..color = palette.link;
    final first = rects.first;
    final last = rects.last;
    canvas.drawCircle(
      Offset(first.left, first.top + first.height / 2),
      3,
      paint,
    );
    canvas.drawCircle(
      Offset(last.right, last.bottom - last.height / 2),
      3,
      paint,
    );
  }

  void _paintSlice(Canvas canvas, PageSlice slice, ReaderPalette palette) {
    if (slice is TextPageSlice) {
      final text = slice.block.text!;
      final offsetY = slice.top - text.lines[slice.lineStart].top;
      canvas.save();
      canvas.clipRect(Rect.fromLTWH(0, slice.top, text.width, slice.height));
      canvas.translate(0, offsetY);
      text.painter.paint(canvas, Offset.zero);
      canvas.restore();
      return;
    }
    if (slice is TablePageSlice) {
      _paintTableSlice(canvas, slice, palette);
      return;
    }
    _paintBlock(canvas, slice.block, slice.top, palette);
  }

  void _paintTableSlice(
    Canvas canvas,
    TablePageSlice slice,
    ReaderPalette palette,
  ) {
    final table = slice.block.table!;
    var y = slice.top;
    if (slice.rowEnd <= slice.rowStart) {
      // Caption-only slice: the caption is placed as its own slice so it can
      // precede a page break without repeating on the row slice.
      if (table.caption != null) {
        canvas.save();
        canvas.translate(0, y);
        table.caption!.painter.paint(canvas, Offset.zero);
        canvas.restore();
      }
      return;
    }
    for (var index = slice.rowStart; index < slice.rowEnd; index++) {
      final row = table.rows[index];
      _paintTableRow(canvas, row, y, palette, table);
      y += row.height;
    }
  }

  void _paintTableRow(
    Canvas canvas,
    FlowTableRowLayout row,
    double top,
    ReaderPalette palette,
    FlowTableBlock table,
  ) {
    for (final cell in row.cells) {
      final rect = Rect.fromLTWH(cell.left, top, cell.width, row.height);
      if (cell.header) {
        canvas.drawRect(rect, Paint()..color = palette.tableHeaderBackground);
      }
      canvas.drawRect(
        rect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.6
          ..color = palette.tableHeaderBorder,
      );
      var cellY = top + 6.0;
      for (final text in cell.blocks) {
        canvas.save();
        canvas.clipRect(
          Rect.fromLTWH(cell.left + 6.0, cellY, cell.width - 12.0, text.height),
        );
        canvas.translate(cell.left + 6.0, cellY);
        text.painter.paint(canvas, Offset.zero);
        canvas.restore();
        cellY += text.height;
      }
    }
  }

  void _paintBlock(
    Canvas canvas,
    FlowBlock block,
    double top,
    ReaderPalette palette,
  ) {
    if (block.text != null) {
      canvas.save();
      canvas.translate(0, top);
      block.text!.painter.paint(canvas, Offset.zero);
      canvas.restore();
      return;
    }
    final image = block.image;
    if (image != null) {
      if (image.image != null) {
        paintDecodedImage(
          canvas,
          image.image!,
          Rect.fromLTWH(0, top, image.width, image.height),
        );
      }
      if (image.fallbackText != null) {
        canvas.save();
        canvas.translate(0, top);
        image.fallbackText!.painter.paint(canvas, Offset.zero);
        canvas.restore();
      }
      if (image.caption != null) {
        canvas.save();
        canvas.translate(0, top + image.height + 0.4 * 16);
        image.caption!.painter.paint(canvas, Offset.zero);
        canvas.restore();
      }
      return;
    }
    final table = block.table;
    if (table != null) {
      var y = top;
      if (table.caption != null) {
        canvas.save();
        canvas.translate(0, y);
        table.caption!.painter.paint(canvas, Offset.zero);
        canvas.restore();
        y += table.caption!.height;
      }
      for (final row in table.rows) {
        _paintTableRow(canvas, row, y, palette, table);
        y += row.height;
      }
      return;
    }
    if (block.rule != null) {
      canvas.drawRect(
        Rect.fromLTWH(0, top, 120, 1),
        Paint()..color = palette.foreground.withValues(alpha: 0.35),
      );
    }
  }

  @override
  bool shouldRepaint(covariant EpubPagePainter oldDelegate) => true;
}

/// Paints the visible continuous window.
class EpubContinuousPainter extends CustomPainter {
  EpubContinuousPainter({required this.model});

  final EpubReaderModel model;

  @override
  void paint(Canvas canvas, Size size) {
    final flow = model.flow;
    final palette = flow?.palette ?? model.typography.palette;
    canvas.drawRect(Offset.zero & size, Paint()..color = palette.background);
    if (flow == null) return;
    final window = continuousWindow(
      flow: flow,
      top: model.continuousOffset,
      height: size.height,
    );
    final gutter = math.max(0.0, (size.width - flow.width) / 2);
    canvas.save();
    canvas.translate(gutter, -model.continuousOffset);
    if (model.selection != null &&
        model.selection!.end > model.selection!.start) {
      final rects = projectRangeFlow(
        flow: flow,
        start: model.selection!.start,
        end: model.selection!.end,
      );
      final paint = Paint()..color = palette.selectionFill;
      for (final rect in rects) {
        canvas.drawRect(rect, paint);
      }
    }
    for (final highlight in model.highlights) {
      if (highlight.spine != model.spine) continue;
      final rects = projectRangeFlow(
        flow: flow,
        start: highlight.start,
        end: highlight.end,
      );
      final paint = Paint()..color = highlightColor(highlight.color);
      for (final rect in rects) {
        canvas.drawRect(rect, paint);
      }
    }
    for (final block in window.blocks) {
      _paintFlowBlock(canvas, block, palette);
    }
    canvas.restore();
  }

  void _paintFlowBlock(Canvas canvas, FlowBlock block, ReaderPalette palette) {
    if (block.text != null) {
      canvas.save();
      canvas.translate(0, block.top);
      block.text!.painter.paint(canvas, Offset.zero);
      canvas.restore();
      return;
    }
    final image = block.image;
    if (image != null) {
      if (image.image != null) {
        paintDecodedImage(
          canvas,
          image.image!,
          Rect.fromLTWH(0, block.top, image.width, image.height),
        );
      }
      if (image.fallbackText != null) {
        canvas.save();
        canvas.translate(0, block.top);
        image.fallbackText!.painter.paint(canvas, Offset.zero);
        canvas.restore();
      }
      if (image.caption != null) {
        canvas.save();
        canvas.translate(0, block.top + image.height + 0.4 * 16);
        image.caption!.painter.paint(canvas, Offset.zero);
        canvas.restore();
      }
      return;
    }
    final table = block.table;
    if (table != null) {
      var y = block.top;
      if (table.caption != null) {
        canvas.save();
        canvas.translate(0, y);
        table.caption!.painter.paint(canvas, Offset.zero);
        canvas.restore();
        y += table.caption!.height;
      }
      for (final row in table.rows) {
        _paintFlowTableRow(canvas, row, y, palette);
        y += row.height;
      }
      return;
    }
    if (block.rule != null) {
      canvas.drawRect(
        Rect.fromLTWH(0, block.top, 120, 1),
        Paint()..color = palette.foreground.withValues(alpha: 0.35),
      );
    }
  }

  void _paintFlowTableRow(
    Canvas canvas,
    FlowTableRowLayout row,
    double top,
    ReaderPalette palette,
  ) {
    for (final cell in row.cells) {
      final rect = Rect.fromLTWH(cell.left, top, cell.width, row.height);
      if (cell.header) {
        canvas.drawRect(rect, Paint()..color = palette.tableHeaderBackground);
      }
      canvas.drawRect(
        rect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.6
          ..color = palette.tableHeaderBorder,
      );
      var cellY = top + 6.0;
      for (final text in cell.blocks) {
        canvas.save();
        canvas.clipRect(
          Rect.fromLTWH(cell.left + 6.0, cellY, cell.width - 12.0, text.height),
        );
        canvas.translate(cell.left + 6.0, cellY);
        text.painter.paint(canvas, Offset.zero);
        canvas.restore();
        cellY += text.height;
      }
    }
  }

  @override
  bool shouldRepaint(covariant EpubContinuousPainter oldDelegate) => true;
}
