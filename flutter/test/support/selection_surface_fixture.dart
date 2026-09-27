import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_flutter/reader/view.dart';
import 'package:shosai_flutter/src/rust/api.dart';

/// Package 4D's deterministic selectable-surface fixture.
///
/// Selection is live in production (RFD 6 authority; plan decision 8): the
/// bridge resolves the document's own endpoints, grapheme/word boundaries and
/// visual lines, and the controller's state machine is unchanged. A widget test
/// cannot lay out a real EPUB chapter with controlled text geometry, so these
/// helpers reproduce the *shape* the bridge returns — a three-line text box in
/// the surface's own coordinate space — while the surface under test keeps its
/// own width, height, raster, handle and copy eligibility.
///
/// Every geometry value below is a fixture value, not a design value: nothing
/// here is compared with an Iced reference (RD-12 has none), and the real
/// geometry is exercised by the matched-state parity capture, which opens the
/// committed 1C fixtures through the real bridge.
const int selectionFixtureColumns = 18;
const int selectionFixtureRows = 3;

/// 54 scalars laid out as three visual lines of [selectionFixtureColumns].
const String selectionFixtureText =
    'The river runs to the sea. And the tide turns at dawn.';

/// Word starts and ends of [selectionFixtureText], in logical order.
const List<int> selectionFixtureWordBoundaries = [
  0,
  3,
  4,
  9,
  10,
  14,
  15,
  17,
  18,
  21,
  22,
  26,
  27,
  30,
  31,
  34,
  35,
  39,
  40,
  45,
  46,
  48,
  49,
  54,
];

/// The fixture's text-box layout inside a surface of a given size.
///
/// The box is centred in the surface so a capture of any viewport shows the
/// same composition; the character metrics are derived from the surface's own
/// width so the fixture is valid for every reported layout width.
final class SelectionFixtureGeometry {
  SelectionFixtureGeometry({required this.width, required this.height});

  final double width;
  final double height;

  static const double _marginX = 60;
  static const double _lineHeight = 44;
  static const double _glyphHeight = 28;

  double get charWidth => (width - 2 * _marginX) / selectionFixtureColumns;

  double get lineHeight => _lineHeight;

  double get glyphHeight => _glyphHeight;

  double get _top => height / 2 - _lineHeight * selectionFixtureRows / 2;

  int rowOf(int offset) => offset ~/ selectionFixtureColumns;

  Offset positionOfCell(int row, int column) =>
      Offset(_marginX + column * charWidth, _top + row * _lineHeight);

  Offset positionOf(int offset) =>
      positionOfCell(rowOf(offset), offset % selectionFixtureColumns);

  FlutterSelectionRect rectOf(int offset) {
    final position = positionOf(offset);
    return FlutterSelectionRect(
      left: position.dx,
      top: position.dy,
      right: position.dx + charWidth,
      bottom: position.dy + _glyphHeight,
    );
  }
}

/// The fixture geometry applied to [base]'s own surface identity.
///
/// The handle, size, raster and copy eligibility come from the surface the
/// bridge under test returned, so a non-copy-eligible or non-EPUB surface keeps
/// its own properties; only the text, endpoints and boundaries are fixture
/// data.
FlutterSelectionSurface selectionFixtureSurface(
  FlutterSelectionSurface base, {
  String text = selectionFixtureText,
  bool? copyEligible,
}) {
  final geometry = SelectionFixtureGeometry(
    width: base.width,
    height: base.height,
  );
  final scalars = text.runes.length;
  final graphemes = Uint32List(scalars + 1);
  for (var index = 0; index <= scalars; index += 1) {
    graphemes[index] = index;
  }
  return FlutterSelectionSurface(
    handle: base.handle,
    width: base.width,
    height: base.height,
    text: text,
    copyEligible: copyEligible ?? base.copyEligible,
    resourcePath: base.resourcePath,
    raster: base.raster,
    endpoints: [
      for (var index = 0; index < scalars; index += 1)
        FlutterSelectionEndpoint(
          offset: BigInt.from(index),
          rangeStart: BigInt.from(index),
          rangeEnd: BigInt.from(index + 1),
          rect: geometry.rectOf(index),
        ),
    ],
    graphemeBoundaries: graphemes,
    wordBoundaries: Uint32List.fromList(selectionFixtureWordBoundaries),
    visualLines: [
      for (var row = 0; row < selectionFixtureRows; row += 1)
        FlutterSelectionVisualLine(
          carets: [
            for (var column = 0; column <= selectionFixtureColumns; column += 1)
              FlutterSelectionCaret(
                offset: BigInt.from(row * selectionFixtureColumns + column),
                x: geometry.positionOfCell(row, column).dx,
                alongLine: column * geometry.charWidth,
                vertical: false,
                top: geometry.positionOfCell(row, 0).dy,
                bottom:
                    geometry.positionOfCell(row, 0).dy + geometry.glyphHeight,
              ),
          ],
        ),
    ],
  );
}

// ---------------------------------------------------------------------------
// Driving the rendered surface
// ---------------------------------------------------------------------------

/// The painted selectable surface, its fit and its rendered box.
///
/// Read from the production painter, so a test maps the surface's own
/// coordinates into the rendered frame exactly as the widget does.
({FlutterSelectionSurface surface, BoxFit fit, RenderBox box})
paintedReaderSurface(WidgetTester tester) {
  for (final paint in tester.widgetList<CustomPaint>(
    find.byType(CustomPaint),
  )) {
    final candidate = paint.painter;
    if (candidate is PagePainter) {
      return (
        surface: candidate.surface,
        fit: candidate.fit,
        box: tester.renderObject<RenderBox>(
          find.byKey(const ValueKey('reader-page-paint')),
        ),
      );
    }
  }
  throw StateError('the reader paints a selectable surface');
}

/// The global position of [point], given in the surface's own coordinates.
Offset readerSurfaceToGlobal(
  ({FlutterSelectionSurface surface, BoxFit fit, RenderBox box}) painted,
  Offset point,
) {
  final transform = SurfaceTransform.create(
    painted.fit,
    Size(painted.surface.width, painted.surface.height),
    painted.box.size,
  );
  final mapped = transform
      .toDestinationRect(Rect.fromLTWH(point.dx, point.dy, 0, 0))
      .topLeft;
  return painted.box.localToGlobal(mapped);
}

/// The rendered centre of the fixture character [offset].
Offset renderedFixtureOffset(WidgetTester tester, int offset) {
  final painted = paintedReaderSurface(tester);
  final geometry = SelectionFixtureGeometry(
    width: painted.surface.width,
    height: painted.surface.height,
  );
  return readerSurfaceToGlobal(
    painted,
    geometry.positionOf(offset) +
        Offset(geometry.charWidth / 2, geometry.glyphHeight / 2),
  );
}

/// The rendered centre of the endpoint whose offset is [offset].
///
/// This is the real-surface counterpart of [renderedFixtureOffset]: it uses the
/// endpoints the bridge returned for the open document.
Offset renderedEndpointCenter(WidgetTester tester, int offset) {
  final painted = paintedReaderSurface(tester);
  final endpoint = painted.surface.endpoints.firstWhere(
    (candidate) => candidate.offset.toInt() == offset,
    orElse: () => throw StateError('no endpoint at $offset'),
  );
  final rect = endpoint.rect;
  return readerSurfaceToGlobal(
    painted,
    Offset((rect.left + rect.right) / 2, (rect.top + rect.bottom) / 2),
  );
}

/// Drags a selection between two rendered positions with the primary mouse
/// button, the way a pointer user makes one.
Future<void> dragReaderSelectionBetween(
  WidgetTester tester,
  Offset from,
  Offset to,
) async {
  final gesture = await tester.startGesture(
    from,
    kind: ui.PointerDeviceKind.mouse,
  );
  await tester.pump();
  await gesture.moveTo(to);
  await tester.pump();
  await gesture.up();
  await tester.pump();
}

/// Drags a selection between two fixture characters.
Future<void> dragFixtureSelection(
  WidgetTester tester, {
  required int from,
  required int to,
}) => dragReaderSelectionBetween(
  tester,
  renderedFixtureOffset(tester, from),
  renderedFixtureOffset(tester, to),
);

/// Pumps bounded frames until the reader's selectable surface is painted.
Future<void> settleReaderSelection(
  WidgetTester tester, {
  int rounds = 4,
}) async {
  for (var round = 0; round < rounds; round += 1) {
    await tester.pump(const Duration(milliseconds: 32));
  }
}
