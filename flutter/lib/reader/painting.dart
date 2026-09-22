part of 'view.dart';

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
      _paintRange(
        canvas,
        saved.start,
        saved.end,
        _highlightColor(saved.color),
        true,
      );
    }
    for (final annotation in annotations) {
      if (annotation.unit.toInt() != currentUnit ||
          annotation.textRange != null) {
        continue;
      }
      _paintRectangles(
        canvas,
        annotation.rectangles ?? const [],
        _highlightColor(annotation.color),
      );
    }
    if (anchor != null && focus != null) {
      _paintRange(
        canvas,
        anchor! < focus! ? anchor! : focus!,
        anchor! < focus! ? focus! : anchor!,
        ShosaiTokens.readerSelectionDragFill,
        false,
      );
    }
    canvas.restore();
  }

  void _paintRange(Canvas canvas, int start, int end, Color color, bool saved) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final border = Paint()
      ..color = color.withAlpha(220)
      ..style = PaintingStyle.stroke
      ..strokeWidth = saved ? 1.5 : 1;
    for (final endpoint in surface.endpoints) {
      final rangeStart = endpoint.rangeStart.toInt();
      final rangeEnd = endpoint.rangeEnd.toInt();
      if (rangeStart >= end || start >= rangeEnd) continue;
      final rect = endpoint.rect;
      final area = Rect.fromLTRB(rect.left, rect.top, rect.right, rect.bottom);
      canvas.drawRect(area, paint);
      if (saved) {
        canvas.drawLine(area.bottomLeft, area.bottomRight, border);
      } else {
        canvas.drawRect(area, border);
      }
    }
  }

  void _paintRectangles(
    Canvas canvas,
    List<FlutterSelectionRect> rectangles,
    Color color,
  ) {
    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final border = Paint()
      ..color = color.withAlpha(220)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (final rect in rectangles) {
      final area = Rect.fromLTRB(rect.left, rect.top, rect.right, rect.bottom);
      canvas.drawRect(area, fill);
      canvas.drawLine(area.bottomLeft, area.bottomRight, border);
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
            : null,
    );
  }
}

({Color background, Color foreground}) pageColors(ColorScheme scheme) =>
    (background: scheme.surface, foreground: scheme.onSurface);

Rect pageImageSource(ui.Image image) =>
    Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());

/// The paint color of one annotation highlight.
///
/// These are retained Flutter colors: RFD 6 selection/highlighting has no Iced
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
