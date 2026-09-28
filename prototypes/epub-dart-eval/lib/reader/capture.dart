/// Content-aware capture analysis.
///
/// The PDF evaluation's false positive was a blank white placeholder accepted
/// as "first content". This detector therefore requires ink, not a frame: a
/// capture only has content when enough pixels differ from the reader
/// background and those pixels form text-like rows. Tests feed it a blank
/// placeholder to prove it fails.
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

class CaptureAnalysis {
  const CaptureAnalysis({
    required this.width,
    required this.height,
    required this.nonBackgroundPixels,
    required this.inkRows,
    required this.inkRowIndices,
  });

  final int width;
  final int height;
  final int nonBackgroundPixels;
  final int inkRows;

  /// Row indices (top to bottom) that contain at least two ink pixels.
  final List<int> inkRowIndices;

  double get inkRatio =>
      width * height == 0 ? 0 : nonBackgroundPixels / (width * height);

  bool get hasContent => inkRows >= 5 && inkRatio >= 0.002;

  /// Whether any ink falls inside a horizontal band.
  bool hasInkInBand(int top, int bottom) {
    for (final row in inkRowIndices) {
      if (row >= top && row <= bottom) return true;
    }
    return false;
  }

  @override
  String toString() =>
      'CaptureAnalysis(${width}x$height, ink=$nonBackgroundPixels, '
      'ratio=${inkRatio.toStringAsFixed(4)}, rows=$inkRows, '
      'content=$hasContent)';
}

/// Analyze a decoded frame against a background colour.
Future<CaptureAnalysis> analyzeCapture(
  ui.Image image,
  ui.Color background, {
  int channelThreshold = 8,
  int minInkPixelsPerRow = 2,
}) async {
  final byteData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (byteData == null) {
    return CaptureAnalysis(
      width: image.width,
      height: image.height,
      nonBackgroundPixels: 0,
      inkRows: 0,
      inkRowIndices: const [],
    );
  }
  return analyzeRgbaBytes(
    byteData.buffer.asUint8List(),
    image.width,
    image.height,
    background,
    channelThreshold: channelThreshold,
    minInkPixelsPerRow: minInkPixelsPerRow,
  );
}

/// Analyze raw RGBA bytes (exposed for tests and the measurement harness).
CaptureAnalysis analyzeRgbaBytes(
  Uint8List rgba,
  int width,
  int height,
  ui.Color background, {
  int channelThreshold = 8,
  int minInkPixelsPerRow = 2,
}) {
  final backgroundR = (background.r * 255).round();
  final backgroundG = (background.g * 255).round();
  final backgroundB = (background.b * 255).round();
  var ink = 0;
  final inkRows = <int>[];
  for (var y = 0; y < height; y++) {
    var rowInk = 0;
    for (var x = 0; x < width; x++) {
      final index = (y * width + x) * 4;
      if (index + 3 >= rgba.length) break;
      final r = rgba[index];
      final g = rgba[index + 1];
      final b = rgba[index + 2];
      final differs =
          (r - backgroundR).abs() > channelThreshold ||
          (g - backgroundG).abs() > channelThreshold ||
          (b - backgroundB).abs() > channelThreshold;
      if (differs) {
        ink++;
        rowInk++;
      }
    }
    if (rowInk >= minInkPixelsPerRow) inkRows.add(y);
  }
  return CaptureAnalysis(
    width: width,
    height: height,
    nonBackgroundPixels: ink,
    inkRows: inkRows.length,
    inkRowIndices: inkRows,
  );
}
