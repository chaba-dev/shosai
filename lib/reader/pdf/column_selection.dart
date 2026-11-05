/// Selection in a strip keeps PDFium's page-local offsets and page geometry.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:shosai_flutter/core/bridge.dart';

import 'column_strip.dart';

/// Full canonical text for the visible pages, with only visible geometry.
/// Offsets are shifted once per page, never once per crop: two pieces of the
/// same page still address the same characters and annotations.
final class PdfStripSelection {
  PdfStripSelection(
    PdfStripScreen screen,
    Map<int, FlutterSelectionSurface> pages,
  ) : pages = Map.unmodifiable(pages) {
    final text = StringBuffer();
    final graphemes = <int>{};
    final words = <int>{};
    final shifts = <int, int>{};
    var shift = 0;
    for (final page in pages.keys.toList()..sort()) {
      final surface = pages[page]!;
      shifts[page] = shift;
      text.write(surface.text);
      text.write('\n');
      graphemes.addAll(surface.graphemeBoundaries.map((b) => b + shift));
      words.addAll(surface.wordBoundaries.map((b) => b + shift));
      shift += surface.text.runes.length + 1;
    }
    this.shifts = Map.unmodifiable(shifts);
    final endpoints = <FlutterSelectionEndpoint>[];
    final lines = <FlutterSelectionVisualLine>[];
    for (final piece in screen.pieces) {
      final page = pages[piece.page];
      if (page == null) continue;
      final shift = BigInt.from(shifts[piece.page]!);
      for (final endpoint in page.endpoints) {
        final rect = mapRect(piece, endpoint.rect);
        if (rect == null) continue;
        endpoints.add(
          FlutterSelectionEndpoint(
            offset: endpoint.offset + shift,
            rangeStart: endpoint.rangeStart + shift,
            rangeEnd: endpoint.rangeEnd + shift,
            rect: rect,
          ),
        );
      }
      for (final line in page.visualLines) {
        final carets = <FlutterSelectionCaret>[];
        for (final caret in line.carets) {
          final x = caret.vertical ? caret.x : caret.alongLine;
          final y = caret.vertical
              ? caret.alongLine
              : (caret.top + caret.bottom) / 2;
          if (x < piece.source.left ||
              x > piece.source.right ||
              y < piece.source.top ||
              y > piece.source.bottom) {
            continue;
          }
          final point = piece.fromPage(caret.x, caret.alongLine);
          carets.add(
            FlutterSelectionCaret(
              offset: caret.offset + shift,
              x: point.x,
              alongLine: caret.vertical
                  ? point.y
                  : piece.fromPage(caret.alongLine, 0).x,
              vertical: caret.vertical,
              top: piece.fromPage(0, caret.top).y,
              bottom: piece.fromPage(0, caret.bottom).y,
            ),
          );
        }
        if (carets.isNotEmpty) {
          lines.add(
            FlutterSelectionVisualLine(carets: List.unmodifiable(carets)),
          );
        }
      }
    }
    surface = FlutterSelectionSurface(
      width: screen.width,
      height: screen.height,
      text: text.toString(),
      copyEligible: pages.values.every((s) => s.copyEligible),
      endpoints: List.unmodifiable(endpoints),
      graphemeBoundaries: Uint32List.fromList(
        graphemes.toList()..sort(),
      ).asUnmodifiableView(),
      wordBoundaries: Uint32List.fromList(
        words.toList()..sort(),
      ).asUnmodifiableView(),
      visualLines: List.unmodifiable(lines),
    );
  }

  final Map<int, FlutterSelectionSurface> pages;
  late final Map<int, int> shifts;
  late final FlutterSelectionSurface surface;

  ({int page, int offset}) location(int offset) {
    final page = shifts.keys.lastWhere((p) => shifts[p]! <= offset);
    return (page: page, offset: offset - shifts[page]!);
  }

  /// Clips in original page space before applying the exact raster transform.
  static FlutterSelectionRect? mapRect(
    PdfStripPiece piece,
    FlutterSelectionRect rect,
  ) {
    final left = math.max(rect.left, piece.source.left);
    final top = math.max(rect.top, piece.source.top);
    final right = math.min(rect.right, piece.source.right);
    final bottom = math.min(rect.bottom, piece.source.bottom);
    if (right <= left || bottom <= top) return null;
    final a = piece.fromPage(left, top);
    final b = piece.fromPage(right, bottom);
    return FlutterSelectionRect(left: a.x, top: a.y, right: b.x, bottom: b.y);
  }
}
