part of 'view.dart';

/// Merges per-character [rects], in reading order, into one band per line:
/// a rect joins the band before it when it sits beside that band's last rect
/// on the same line (horizontal text) or below it in the same column
/// (vertical text), with at most a line's size between them (a space or
/// justification). A band keeps the direction it first grew in, so the next
/// line or column starts a new band.
@visibleForTesting
List<Rect> selectionBands(Iterable<Rect> rects) {
  final bands = <Rect>[];
  Rect? last;
  Axis? axis;
  for (final rect in rects) {
    if (rect.width <= 0 && rect.height <= 0) continue;
    final previous = last;
    last = rect;
    if (previous == null) {
      bands.add(rect);
      axis = null;
      continue;
    }
    final grows = _continues(previous, rect, axis);
    if (grows == null) {
      bands.add(rect);
      axis = null;
    } else {
      bands.last = bands.last.expandToInclude(rect);
      axis = grows;
    }
  }
  return bands;
}

/// The axis along which [next] continues the line through [previous], or
/// null when it starts a new line. A band already growing along [axis] only
/// grows that way.
Axis? _continues(Rect previous, Rect next, Axis? axis) {
  double overlap(double a0, double a1, double b0, double b1) =>
      math.min(a1, b1) - math.max(a0, b0);
  double gap(double a0, double a1, double b0, double b1) =>
      math.max(b0 - a1, a0 - b1);
  if (axis != Axis.vertical) {
    final size = math.max(previous.height, next.height);
    final shared = overlap(
      previous.top,
      previous.bottom,
      next.top,
      next.bottom,
    );
    if (shared >= math.min(previous.height, next.height) * .5 &&
        gap(previous.left, previous.right, next.left, next.right) <= size) {
      return Axis.horizontal;
    }
  }
  if (axis != Axis.horizontal) {
    final size = math.max(previous.width, next.width);
    final shared = overlap(
      previous.left,
      previous.right,
      next.left,
      next.right,
    );
    if (shared >= math.min(previous.width, next.width) * .5 &&
        gap(previous.top, previous.bottom, next.top, next.bottom) <= size) {
      return Axis.vertical;
    }
  }
  return null;
}

class PagePainter extends CustomPainter {
  const PagePainter({
    required this.image,
    required this.surface,
    required this.backgroundColor,
    required this.foregroundColor,
    required this.recolorImage,
    this.fit = BoxFit.contain,
    required this.anchor,
    required this.focus,
    required this.savedSelections,
    required this.annotations,
    this.currentUnit = 0,
    this.spread,
    this.paintContent = true,
  });

  final ui.Image? image;
  final FlutterSelectionSurface surface;
  final Color backgroundColor;
  final Color foregroundColor;
  final bool recolorImage;
  final BoxFit fit;
  final int? anchor;
  final int? focus;
  final List<ReaderSelection> savedSelections;
  final List<FlutterAnnotation> annotations;
  final int currentUnit;

  /// The PDF spread the surface spans, whose second page's area highlights
  /// are painted too, each page's beside the other.
  final ReaderPdfSpread? spread;
  final bool paintContent;

  @override
  void paint(Canvas canvas, Size size) {
    final source = Rect.fromLTWH(0, 0, surface.width, surface.height);
    final transform = SurfaceTransform.create(fit, source.size, size);
    canvas.save();
    transform.apply(canvas);
    if (paintContent) {
      _paintPageContent(
        canvas,
        source,
        image,
        backgroundColor,
        foregroundColor,
        recolorImage,
      );
    }
    for (final saved in savedSelections) {
      _paintRange(canvas, saved.start, saved.end, _highlightColor(saved.color));
    }
    for (final annotation in annotations) {
      final unit = annotation.unit.toInt();
      if ((unit != currentUnit && unit != spread?.facingUnit) ||
          annotation.textRange != null) {
        continue;
      }
      _paintRectangles(
        canvas,
        annotation.rectangles ?? const [],
        _highlightColor(annotation.color),
        spread?.leftOf(unit, currentUnit) ?? 0,
      );
    }
    if (anchor != null && focus != null) {
      _paintRange(
        canvas,
        anchor! < focus! ? anchor! : focus!,
        anchor! < focus! ? focus! : anchor!,
        ShosaiTokens.readerSelectionDragFill,
        outline: true,
      );
    }
    canvas.restore();
  }

  void _paintRange(
    Canvas canvas,
    int start,
    int end,
    Color color, {
    bool outline = false,
  }) {
    _paintBands(canvas, outline: outline, [
      for (final endpoint in surface.endpoints)
        if (endpoint.rangeStart.toInt() < end &&
            start < endpoint.rangeEnd.toInt())
          Rect.fromLTRB(
            endpoint.rect.left,
            endpoint.rect.top,
            endpoint.rect.right,
            endpoint.rect.bottom,
          ),
    ], color);
  }

  /// Paints a page's [rectangles], moved right by [dx] to where the page
  /// lies in the surface.
  void _paintRectangles(
    Canvas canvas,
    List<FlutterSelectionRect> rectangles,
    Color color,
    double dx,
  ) {
    _paintBands(canvas, [
      for (final rect in rectangles)
        Rect.fromLTRB(rect.left + dx, rect.top, rect.right + dx, rect.bottom),
    ], color);
  }

  /// Fills [rects] as one band per line (or column), `radius-xs` corners,
  /// in one pass so overlaps never paint twice. An [outline] (the live
  /// selection's cue that does not rely on colour) traces the bands' outer
  /// edge, never the seams between them.
  void _paintBands(
    Canvas canvas,
    List<Rect> rects,
    Color color, {
    bool outline = false,
  }) {
    if (rects.isEmpty) return;
    const radius = Radius.circular(ShosaiTokens.radiusXs);
    Path? shape;
    for (final band in selectionBands(rects)) {
      final next = Path()..addRRect(RRect.fromRectAndRadius(band, radius));
      shape = shape == null
          ? next
          : Path.combine(PathOperation.union, shape, next);
    }
    canvas.drawPath(shape!, Paint()..color = color);
    if (outline) {
      canvas.drawPath(
        shape,
        Paint()
          ..color = color.withAlpha(220)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }
  }

  @override
  bool shouldRepaint(PagePainter oldDelegate) =>
      oldDelegate.image != image ||
      oldDelegate.backgroundColor != backgroundColor ||
      oldDelegate.foregroundColor != foregroundColor ||
      oldDelegate.recolorImage != recolorImage ||
      oldDelegate.paintContent != paintContent ||
      oldDelegate.anchor != anchor ||
      oldDelegate.focus != focus ||
      oldDelegate.fit != fit ||
      oldDelegate.currentUnit != currentUnit ||
      oldDelegate.spread != spread ||
      oldDelegate.savedSelections != savedSelections ||
      oldDelegate.annotations != annotations;
}

class _PageContentPainter extends CustomPainter {
  const _PageContentPainter({
    required this.image,
    required this.surface,
    required this.backgroundColor,
    required this.foregroundColor,
    required this.recolorImage,
    required this.fit,
  });

  final ui.Image? image;
  final FlutterSelectionSurface surface;
  final Color backgroundColor;
  final Color foregroundColor;
  final bool recolorImage;
  final BoxFit fit;

  @override
  void paint(Canvas canvas, Size size) {
    final source = Rect.fromLTWH(0, 0, surface.width, surface.height);
    final transform = SurfaceTransform.create(fit, source.size, size);
    canvas.save();
    transform.apply(canvas);
    _paintPageContent(
      canvas,
      source,
      image,
      backgroundColor,
      foregroundColor,
      recolorImage,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PageContentPainter oldDelegate) =>
      oldDelegate.image != image ||
      oldDelegate.surface != surface ||
      oldDelegate.backgroundColor != backgroundColor ||
      oldDelegate.foregroundColor != foregroundColor ||
      oldDelegate.recolorImage != recolorImage ||
      oldDelegate.fit != fit;
}

void _paintPageContent(
  Canvas canvas,
  Rect source,
  ui.Image? image,
  Color backgroundColor,
  Color foregroundColor,
  bool recolorImage,
) {
  canvas.drawRect(source, Paint()..color = backgroundColor);
  if (image case final page?) {
    canvas.drawImageRect(
      page,
      pageImageSource(page),
      source,
      Paint()
        ..colorFilter = recolorImage
            ? ColorFilter.mode(foregroundColor, BlendMode.srcIn)
            : _pdfPageColorFilter(backgroundColor, foregroundColor),
    );
  }
}

/// PDF pixels keep their geometry and alpha. Paper is the original raster;
/// Sepia maps its RGB channels between the page ink and paper. Night reverses
/// luminance while retaining chroma (rather than turning colours into their
/// complements), then maps black/white to the shared page ink/paper. Saturated
/// colours can clip at the gamut boundary, but images retain tonal detail.
///
/// This filter belongs on the raster paint, never on the canvas or widget:
/// saved highlights, search hits and live selection must keep their own colours.
ColorFilter? _pdfPageColorFilter(Color background, Color foreground) {
  if (background == ShosaiTokens.readerLightBackground &&
      foreground == ShosaiTokens.readerLightText) {
    return null;
  }
  final night = background.computeLuminance() < foreground.computeLuminance();
  const luminance = [0.2126, 0.7152, 0.0722];
  final paper = [background.r, background.g, background.b];
  final ink = [foreground.r, foreground.g, foreground.b];
  return ColorFilter.matrix([
    for (var row = 0; row < 3; row += 1) ...[
      for (var column = 0; column < 3; column += 1)
        (paper[row] - ink[row]) *
            (night
                ? 2 * luminance[column] - (row == column ? 1 : 0)
                : (row == column ? 1 : 0)),
      0,
      ink[row] * 255,
    ],
    0,
    0,
    0,
    1,
    0,
  ]);
}

/// The document paint colors of the reader palette for [readerTheme].
///
/// The reader palette is the *document* palette (owner decision 2026-09-28):
/// the page paper and the page foreground follow the reader theme while the
/// shared chrome keeps the application palette
/// ([shosaiReaderColorScheme]/[shosaiReaderMaterialColorScheme]).
({Color background, Color foreground}) pageColors(String? readerTheme) =>
    shosaiReaderDocumentColors(readerTheme);

Rect pageImageSource(ui.Image image) =>
    Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());

/// The paint color of one annotation highlight.
///
/// These are retained Flutter colors: RFD 16 selection/highlighting has no Iced
/// reference (plan decision 8), so the values are the ones this application
/// already painted with, recorded in the shared token source instead of as
/// literals here.
Color _highlightColor(FlutterHighlightColor? color) => switch (color) {
  FlutterHighlightColor.green => ShosaiTokens.readerAnnotationGreen,
  FlutterHighlightColor.blue => ShosaiTokens.readerAnnotationBlue,
  FlutterHighlightColor.pink => ShosaiTokens.readerAnnotationPink,
  FlutterHighlightColor.purple => ShosaiTokens.readerAnnotationPurple,
  FlutterHighlightColor.yellow || null => ShosaiTokens.readerAnnotationYellow,
};
