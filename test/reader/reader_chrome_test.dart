import 'dart:async';
import 'dart:typed_data';

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shosai_flutter/main.dart';
import 'package:shosai_flutter/core/bridge.dart';
import 'package:shosai_flutter/reader/controller.dart'
    show
        PageDecoder,
        ReaderDisplayChange,
        ReaderDisplaySink,
        ReaderDocumentPickerAdapter,
        ReaderNoteDeleted,
        ReaderNoteEditStarted,
        ReaderPickedDocument;
import 'package:shosai_flutter/reader/epub/content.dart' show ReaderEpubPage;
import 'package:shosai_flutter/reader/epub/pages.dart' show TextPageSlice;
import 'package:shosai_flutter/reader/view.dart'
    show PagePainter, ReaderEpubPageContentPainter;
import 'package:shosai_flutter/theme_tokens.dart';

import '../support/bridge_pdf_engine.dart';
import '../support/production_shell_harness.dart';

/// Package 4B reader chrome: header, tab strip, progress/status, edge
/// navigation and the panel host (rows RD-01…RD-06, RD-13, RD-14, RD-16, RD-17).
///
/// Interaction contracts are driven through the rendered surface; the tab list
/// and progress ordinals are fixture-injected presentation data because the
/// bridge has no session, tab or pagination API (contract §2.2). Real tab
/// lifecycle is 5F and real page ranges are 5G.
/// Annotation updates wait for [gate].
class _GatedUpdateBridge extends _ChromeBridge {
  _GatedUpdateBridge(this.gate) : super(books: harnessLibraryBooks());

  final Future<void> gate;
  final List<String> updatedIds = [];

  @override
  Future<bool> updateAnnotation({
    required FlutterDocumentHandle document,
    required String id,
    required FlutterHighlightColor color,
    String? body,
  }) async {
    updatedIds.add(id);
    await gate;
    return true;
  }
}

class _ChromeBridge extends HarnessBridge {
  _ChromeBridge({
    super.books,
    super.unitCount,
    this.title,
    this.failOpen = false,
    this.hangOpen = false,
    this.rightToLeft = false,
  });

  final String? title;
  final bool failOpen;
  final bool hangOpen;
  bool rightToLeft;

  @override
  bool get pdfEngineRightToLeft => rightToLeft;

  @override
  Future<FlutterDocumentSummary> openDocument({
    required FlutterOpenRequest request,
    required BigInt cancellationId,
  }) async {
    if (hangOpen) return Completer<FlutterDocumentSummary>().future;
    if (failOpen) {
      throw const FlutterBridgeError(
        kind: FlutterBridgeErrorKind.notFound,
        message: 'Failed to open EPUB: the file could not be found.',
      );
    }
    final summary = await super.openDocument(
      request: request,
      cancellationId: cancellationId,
    );
    final override = title;
    return override == null
        ? summary
        : FlutterDocumentSummary(
            handle: summary.handle,
            bookId: summary.bookId,
            format: summary.format,
            title: override,
            logicalUnitCount: summary.logicalUnitCount,
          );
  }

  /// Annotations the strip renders (fixture-backed; annotation persistence is
  /// live in production).
  List<FlutterAnnotation> annotations = const [];

  /// Search completions the test controls, so cancellation can be driven with a
  /// real in-flight search.
  final List<Completer<List<FlutterSearchMatch>>> searchCompletions = [];

  /// When set, page renders fail with a bridge error, so a layout failure can
  /// be driven through the rendered chrome.
  bool failRender = false;

  /// Saved places the contents panel renders (fixture-backed; persistence is
  /// live in production).
  List<FlutterBookmark> bookmarks = const [];

  bool failSelection = false;

  @override
  Future<FlutterSelectionSurface> selectionSurface({
    required FlutterDocumentHandle document,
    required BigInt unit,
    required double scale,
    required double width,
    required double fontSize,
    required double lineSpacing,
    required BigInt cancellationId,
  }) {
    if (failSelection) throw StateError('selection endpoint limit exceeded');
    return super.selectionSurface(
      document: document,
      unit: unit,
      scale: scale,
      width: width,
      fontSize: fontSize,
      lineSpacing: lineSpacing,
      cancellationId: cancellationId,
    );
  }

  @override
  Future<List<FlutterBookmark>> listBookmarks({
    required int bookId,
    required BigInt cancellationId,
  }) async => bookmarks;

  @override
  Future<List<FlutterAnnotation>> listAnnotations({
    required FlutterDocumentHandle document,
    required double scale,
    required BigInt cancellationId,
  }) async => annotations;

  @override
  Future<List<FlutterSearchMatch>> searchDocument({
    required FlutterDocumentHandle document,
    required String query,
    required BigInt cancellationId,
  }) {
    final completer = Completer<List<FlutterSearchMatch>>();
    searchCompletions.add(completer);
    return completer.future;
  }

  @override
  Future<FlutterRenderedBuffer> renderPage({
    required FlutterDocumentHandle document,
    required BigInt page,
    required double scale,
    required BigInt cancellationId,
  }) {
    if (failRender) {
      throw const FlutterBridgeError(
        kind: FlutterBridgeErrorKind.invalidRequest,
        message: 'page render rejected',
      );
    }
    return super.renderPage(
      document: document,
      page: page,
      scale: scale,
      cancellationId: cancellationId,
    );
  }
}

/// A right-to-left PDF whose pages tell each other apart: page unit `n` is
/// [_sidedWidth] wide, its raster's red channel is `n`, and its surface has
/// one endpoint 10 pixels from its left edge.
class _SidedPdfBridge extends _ChromeBridge {
  _SidedPdfBridge() : super(rightToLeft: true);

  final Map<BigInt, Uint8List> _rasters = {};
  BigInt _nextRaster = BigInt.from(1000);

  @override
  Future<FlutterRenderedBuffer> renderPage({
    required FlutterDocumentHandle document,
    required BigInt page,
    required double scale,
    required BigInt cancellationId,
  }) async {
    final width = _sidedWidth(page.toInt());
    final pixels = Uint8List(width * pageHeight * 4);
    for (var index = 0; index < pixels.length; index += 4) {
      pixels[index] = page.toInt();
      pixels[index + 3] = 0xff;
    }
    final handle = FlutterBufferHandle(registry: BigInt.one, id: _nextRaster);
    _nextRaster += BigInt.one;
    _rasters[handle.id] = pixels;
    return FlutterRenderedBuffer(
      handle: handle,
      width: width,
      height: pageHeight,
      byteLen: BigInt.from(pixels.length),
    );
  }

  @override
  Uint8List takeBuffer({required FlutterBufferHandle handle}) =>
      _rasters[handle.id] ?? super.takeBuffer(handle: handle);

  @override
  bool releaseBuffer({required FlutterBufferHandle handle}) =>
      _rasters.remove(handle.id) != null || super.releaseBuffer(handle: handle);

  @override
  Future<FlutterSelectionSurface> selectionSurface({
    required FlutterDocumentHandle document,
    required BigInt unit,
    required double scale,
    required double width,
    required double fontSize,
    required double lineSpacing,
    required BigInt cancellationId,
  }) async => FlutterSelectionSurface(
    width: _sidedWidth(unit.toInt()).toDouble(),
    height: pageHeight.toDouble(),
    text: 'p',
    copyEligible: false,
    endpoints: [
      FlutterSelectionEndpoint(
        offset: BigInt.zero,
        rangeStart: BigInt.zero,
        rangeEnd: BigInt.one,
        rect: const FlutterSelectionRect(
          left: 10,
          top: 10,
          right: 20,
          bottom: 30,
        ),
      ),
    ],
    graphemeBoundaries: Uint32List.fromList([0, 1]),
    wordBoundaries: Uint32List.fromList([0, 1]),
    visualLines: const [],
  );
}

/// The width of page [unit] of a [_SidedPdfBridge]: page 2 (unit 1) is wider
/// than page 3 (unit 2), so a spread's halves differ.
int _sidedWidth(int unit) => unit == 2 ? 200 : 300;

/// An area highlight on [unit] at 10–30 × 10–30 of its page.
FlutterAnnotation _areaHighlight(int unit, FlutterHighlightColor color) =>
    FlutterAnnotation(
      id: 'area-$unit',
      unit: BigInt.from(unit),
      resolution: FlutterAnnotationResolution.exact,
      rectangles: const [
        FlutterSelectionRect(left: 10, top: 10, right: 30, bottom: 30),
      ],
      color: color,
    );

/// The reader's painter of the open page or spread.
PagePainter _pagePainter(WidgetTester tester) => tester
    .widgetList<CustomPaint>(find.byType(CustomPaint))
    .map((paint) => paint.painter)
    .whereType<PagePainter>()
    .single;

/// The color at each of [points] once [painter] paints [size].
Future<List<ui.Color>> _paintedColors(
  WidgetTester tester,
  PagePainter painter,
  Size size,
  List<Offset> points,
) async {
  final colors = await tester.runAsync(() async {
    final recorder = ui.PictureRecorder();
    painter.paint(ui.Canvas(recorder), size);
    final picture = recorder.endRecording();
    final image = await picture.toImage(size.width.ceil(), size.height.ceil());
    try {
      final bytes = (await image.toByteData())!;
      ui.Color at(Offset point) {
        final index = (point.dy.toInt() * image.width + point.dx.toInt()) * 4;
        return ui.Color.fromARGB(
          bytes.getUint8(index + 3),
          bytes.getUint8(index),
          bytes.getUint8(index + 1),
          bytes.getUint8(index + 2),
        );
      }

      return [for (final point in points) at(point)];
    } finally {
      image.dispose();
      picture.dispose();
    }
  });
  return colors!;
}

const _epub = FlutterReaderSettings(
  continuous: false,
  theme: 'light',
  epubFontSize: 18,
  epubLineSpacing: 1.6,
  pdfZoom: 0,
);

const _continuous = FlutterReaderSettings(
  continuous: true,
  theme: 'light',
  epubFontSize: 18,
  epubLineSpacing: 1.6,
  pdfZoom: 0,
);

int _readerKeyCounter = 0;

Widget _reader({
  required HarnessBridge bridge,
  Locale? locale,
  String? initialPath = '/books/slow-rivers.epub',
  int? initialBookId,
  FlutterReaderSettings? settings = _epub,
  ReaderProgressSource? progressSource,
  ReaderDisplaySink? onDisplayChanged,
  PageDecoder? decoder,
  ReaderDocumentPickerAdapter? documentPicker,
  bool debugPathEntry = false,
}) => productionShell(
  locale: locale,
  home: ReaderScreen(
    key: ValueKey('reader-${_readerKeyCounter++}'),
    bridge: bridge,
    decoder:
        decoder ?? (pixels, {required width, required height}) => _testImage(),
    documentPicker: documentPicker,
    initialPath: initialPath,
    initialBookId: initialBookId,
    initialSettings: settings,
    progressSource: progressSource,
    onDisplayChanged: onDisplayChanged,
    debugPathEntry: debugPathEntry,
  ),
);

/// Pumps until the fixture document is loaded (not necessarily painted).
Future<void> _open(WidgetTester tester, Widget widget) async {
  await tester.pumpWidget(widget);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 32));
  await tester.pump(const Duration(milliseconds: 32));
}

/// The document box between the reader's edge columns.
final _documentArea = find.byKey(const ValueKey('reader-document-semantics'));

/// Pumps until the Dart EPUB page is painted, and returns it.
Future<ReaderEpubPage> _paintedEpubPage(WidgetTester tester) async {
  for (var round = 0; round < 16; round += 1) {
    for (final paint in tester.widgetList<CustomPaint>(
      find.byType(CustomPaint),
    )) {
      if (paint.painter case final ReaderEpubPageContentPainter painter) {
        return painter.page;
      }
    }
    await tester.pump(const Duration(milliseconds: 32));
  }
  fail('no EPUB page was painted');
}

void _setView(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// Whether the control at [key] (or a node inside it) exposes a semantic tap
/// action, i.e. whether a screen reader can activate it.
///
/// A plain Shad button splits its semantics across an outer `isButton` node and
/// an inner focusable node that carries the label and the tap action, so the
/// whole subtree is inspected rather than only the node the key resolves to.
bool _hasTapAction(WidgetTester tester, String key) {
  final node = tester.getSemantics(find.byKey(ValueKey(key)));
  var found = node.getSemanticsData().hasAction(SemanticsAction.tap);
  bool visit(SemanticsNode child) {
    if (child.getSemanticsData().hasAction(SemanticsAction.tap)) found = true;
    child.visitChildren(visit);
    return true;
  }

  node.visitChildren(visit);
  return found;
}

/// The semantics the chrome declares for the control at [key].
Semantics _controlSemantics(WidgetTester tester, String key) =>
    tester.widget<Semantics>(find.byKey(ValueKey(key)));

Future<ui.Image> _testImage() async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(const ui.Color(0xffffffff), ui.BlendMode.src);
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(1, 1);
  } finally {
    picture.dispose();
  }
}

/// The toolbar actions on desktop and tablet.
///
/// Bookmark is left out: it also needs a library book (see the saved-place
/// tests).
const _headerActions = [
  'reader-header-contents',
  'reader-header-search',
  'reader-header-typography',
  'reader-header-notes',
];

ShadButton _button(WidgetTester tester, String key) =>
    tester.widget<ShadButton>(
      find.descendant(
        of: find.byKey(ValueKey(key)),
        matching: find.byType(ShadButton),
      ),
    );

void main() {
  setUpAll(loadHarnessFonts);

  group('header', () {
    testWidgets('shows the live title on one ellipsized line and keeps it '
        'in semantics', (tester) async {
      _setView(tester, const Size(1280, 800));
      const long =
          'A Field Guide to the Slow Rivers of the Northern '
          'Hemisphere and Their Meanders';
      final bridge = _ChromeBridge(title: long);
      await _open(tester, _reader(bridge: bridge));

      final semantics = tester.widget<Semantics>(
        find.byKey(const ValueKey('reader-header-title')),
      );
      expect(semantics.properties.label, startsWith(long));
      Text title() => tester.widget<Text>(find.text(long));
      expect(title().maxLines, 1);
      expect(title().overflow, TextOverflow.ellipsis);

      // A phone keeps the same single line in the narrower toolbar.
      tester.view.physicalSize = const Size(390, 844);
      await tester.pump();
      await tester.pump();
      expect(title().maxLines, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'actions are disabled without a document and enabled with one',
      (tester) async {
        _setView(tester, const Size(1280, 800));
        final bridge = _ChromeBridge();
        await _open(tester, _reader(bridge: bridge, initialPath: null));

        for (final key in _headerActions) {
          expect(_button(tester, key).enabled, isFalse, reason: key);
        }
        await tester.tap(
          find.byKey(const ValueKey('reader-header-contents')),
          warnIfMissed: false,
        );
        await tester.pump();
        expect(
          find.byKey(const ValueKey('reader-panel-contents')),
          findsNothing,
        );

        await _open(tester, _reader(bridge: _ChromeBridge()));
        for (final key in _headerActions) {
          expect(_button(tester, key).enabled, isTrue, reason: key);
        }
      },
    );

    testWidgets('back on a phone leaves the reader through the injected '
        'adapter', (tester) async {
      // Desktop and tablet leave through the shell's sidebar; the phone
      // toolbar has its own back control.
      _setView(tester, const Size(390, 844));
      final bridge = _ChromeBridge();
      await tester.pumpWidget(
        productionShell(
          home: _PushHost(
            reader: _ReaderHost(bridge: bridge),
            child: const Text('library-placeholder'),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 32));
      expect(find.byKey(const ValueKey('reader-header-back')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('reader-header-back')));
      await tester.pumpAndSettle();

      expect(find.text('library-placeholder'), findsOneWidget);
      expect(find.byKey(const ValueKey('reader-header-back')), findsNothing);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    });

    testWidgets('stays reachable and activated at 200% interface text', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      final bridge = _ChromeBridge();
      await _open(tester, _reader(bridge: bridge, locale: const Locale('ja')));

      expect(find.byKey(const ValueKey('reader-header-back')), findsOneWidget);
      for (final key in [
        'reader-header-contents',
        'reader-header-typography',
        'reader-header-notes',
      ]) {
        expect(_button(tester, key).enabled, isTrue, reason: key);
      }
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('reader-header-notes')));
      await tester.pump();
      expect(find.byKey(const ValueKey('reader-panel-notes')), findsOneWidget);
    });

    testWidgets('the retired path entry stays out of the reader composition', (
      tester,
    ) async {
      _setView(tester, const Size(1280, 800));
      await _open(tester, _reader(bridge: _ChromeBridge()));
      expect(find.text('Open document'), findsNothing);
      expect(find.byKey(const ValueKey('reader-header')), findsOneWidget);
    });
  });

  group('progress and status', () {
    testWidgets('shows the no-book wording without a document', (tester) async {
      _setView(tester, const Size(1280, 800));
      await _open(tester, _reader(bridge: _ChromeBridge(), initialPath: null));
      expect(find.text('No book open'), findsOneWidget);
      expect(find.byKey(const ValueKey('reader-progress')), findsOneWidget);
    });

    testWidgets('shows the opening wording while an open is in flight', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      _setView(tester, const Size(1280, 800));
      await _open(tester, _reader(bridge: _ChromeBridge(hangOpen: true)));

      // The status surface stays mounted while the open is in flight: its
      // loading wording is the required live region (RD-05), separate from the
      // opening view's own label.
      final status = tester.getSemantics(
        find.byKey(const ValueKey('reader-progress')),
      );
      expect(status.label, contains('Opening document…'));
      expect(status.flagsCollection.isLiveRegion, isTrue);
      expect(find.byKey(const ValueKey('reader-opening')), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('renders single, range and chapter wording from fixture data', (
      tester,
    ) async {
      _setView(tester, const Size(1280, 800));
      await _open(
        tester,
        _reader(
          bridge: _ChromeBridge(),
          progressSource: (_) => const ReaderProgressPresentation(
            kind: ReaderProgressKind.single,
            hasDocument: true,
            firstOrdinal: 4,
            percentage: 42,
          ),
        ),
      );
      expect(find.text('42% · page 4'), findsOneWidget);

      await _open(
        tester,
        _reader(
          bridge: _ChromeBridge(),
          progressSource: (_) => const ReaderProgressPresentation(
            kind: ReaderProgressKind.range,
            hasDocument: true,
            firstOrdinal: 4,
            lastOrdinal: 5,
            percentage: 42,
          ),
        ),
      );
      expect(find.text('42% · pages 4–5'), findsOneWidget);

      await _open(
        tester,
        _reader(
          bridge: _ChromeBridge(),
          progressSource: (_) => const ReaderProgressPresentation(
            kind: ReaderProgressKind.single,
            hasDocument: true,
            displayUnit: ReaderDisplayUnit.chapter,
            firstOrdinal: 3,
            percentage: 33,
          ),
        ),
      );
      expect(find.text('33% · chapter 3 of 3'), findsOneWidget);
    });

    testWidgets('the bar is hidden without a document but the text is not', (
      tester,
    ) async {
      _setView(tester, const Size(1280, 800));
      await _open(tester, _reader(bridge: _ChromeBridge(), initialPath: null));
      expect(find.byKey(const ValueKey('reader-progress')), findsOneWidget);
      expect(find.byKey(const ValueKey('reader-progress-track')), findsNothing);
      expect(find.text('No book open'), findsOneWidget);
    });

    testWidgets('empty documents report zero percent', (tester) async {
      _setView(tester, const Size(1280, 800));
      await _open(
        tester,
        _reader(
          bridge: _ChromeBridge(),
          progressSource: (_) => const ReaderProgressPresentation(
            kind: ReaderProgressKind.single,
            hasDocument: true,
            firstOrdinal: 1,
            percentage: 0,
          ),
        ),
      );
      expect(find.text('0% · page 1'), findsOneWidget);
    });

    testWidgets('the default source names the retained logical unit', (
      tester,
    ) async {
      _setView(tester, const Size(1280, 800));
      await _open(tester, _reader(bridge: _ChromeBridge()));
      expect(find.text('33% · chapter 1 of 3'), findsOneWidget);
    });
  });

  group('edge navigation', () {
    for (final fitWidth in [false, true]) {
      for (final cancel in [false, true]) {
        testWidgets(
          'PDF asymmetric pinch beats scrolling (fitWidth: $fitWidth, cancel: $cancel)',
          (tester) async {
            _setView(tester, const Size(390, 500));
            await _open(
              tester,
              _reader(
                bridge: _ChromeBridge(),
                initialPath: '/books/atlas.pdf',
                settings: _epub.copyWith(pdfZoom: fitWidth ? -1 : 1),
              ),
            );
            final center = tester.getCenter(
              find.byKey(const ValueKey('reader-selection-surface')),
            );
            final axis = fitWidth ? const Offset(0, 1) : const Offset(1, 0);
            final stationary = await tester.startGesture(
              center - axis * 50,
              pointer: 1,
            );
            final moving = await tester.startGesture(
              center + axis * 50,
              pointer: 2,
            );
            // Cross child drag slop before scale slop, then continue the pinch.
            await moving.moveBy(axis * 20);
            await tester.pump(const Duration(milliseconds: 20));
            await moving.moveBy(axis * 80);
            await tester.pump();
            if (cancel) {
              await moving.cancel();
            } else {
              await moving.up();
            }
            await stationary.up();
            await tester.pumpAndSettle();
            expect(find.text('33% · page 1'), findsOneWidget);
            await tester.tap(
              find.byKey(const ValueKey('reader-header-typography')),
            );
            await tester.pumpAndSettle();
            if (cancel) {
              expect(
                find.byKey(
                  ValueKey(
                    fitWidth ? 'reader-fit-fitWidth' : 'reader-fit-none',
                  ),
                ),
                findsOneWidget,
              );
              if (!fitWidth) expect(find.text('100%'), findsOneWidget);
            } else {
              expect(find.text(fitWidth ? '144%' : '200%'), findsOneWidget);
            }
          },
        );
      }
    }

    testWidgets(
      'Night PDF pinch zooms, pans, and double tap restores fit without losing its palette',
      (tester) async {
        _setView(tester, const Size(390, 800));
        await _open(
          tester,
          _reader(
            bridge: _ChromeBridge(),
            initialPath: '/books/atlas.pdf',
            settings: _epub.copyWith(theme: 'dark'),
          ),
        );
        final surface = find.byKey(const ValueKey('reader-selection-surface'));
        final center = tester.getCenter(surface);
        final left = await tester.startGesture(
          center - const Offset(50, 0),
          pointer: 1,
        );
        final right = await tester.startGesture(
          center + const Offset(50, 0),
          pointer: 2,
        );
        for (var i = 1; i <= 5; i++) {
          await left.moveTo(center - Offset(50 + i * 10, 0));
          await right.moveTo(center + Offset(50 + i * 10, 0));
          await tester.pump(const Duration(milliseconds: 20));
        }
        await left.up();
        await tester.pump();
        await right.up();
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('reader-fit-none')), findsOneWidget);
        expect(find.text('33% · page 1'), findsOneWidget);
        await tester.tap(
          find.byKey(const ValueKey('reader-header-typography')),
        );
        await tester.pumpAndSettle();
        // A 420px PDF fitted into 302px, pinched to twice its displayed size.
        expect(find.text('144%'), findsOneWidget);
        await tester.tap(
          find.byKey(const ValueKey('reader-header-typography')),
        );
        await tester.pumpAndSettle();
        await tester.drag(surface, const Offset(-100, 0));
        await tester.pumpAndSettle();
        final horizontal = find.byWidgetPredicate(
          (w) =>
              w is SingleChildScrollView &&
              w.scrollDirection == Axis.horizontal,
        );
        final scroll = tester.state<ScrollableState>(
          find
              .descendant(of: horizontal, matching: find.byType(Scrollable))
              .first,
        );
        expect(scroll.position.pixels, greaterThan(0));
        expect(find.text('33% · page 1'), findsOneWidget);
        await tester.tap(surface);
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tap(surface);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('reader-fit-contain')),
          findsOneWidget,
        );
        expect(
          _pagePainter(tester).backgroundColor,
          ShosaiTokens.readerDarkBackground,
        );
        expect(
          _pagePainter(tester).foregroundColor,
          ShosaiTokens.readerDarkText,
        );
        expect(
          ShadTheme.of(tester.element(surface)).brightness,
          Brightness.dark,
        );
      },
    );

    for (final rtl in [false, true]) {
      testWidgets('phone PDF swipes turn in book order (RTL: $rtl)', (
        tester,
      ) async {
        _setView(tester, const Size(390, 844));
        await _open(
          tester,
          _reader(
            bridge: _ChromeBridge(rightToLeft: rtl),
            initialPath: '/books/atlas.pdf',
          ),
        );
        final surface = find.byKey(const ValueKey('reader-selection-surface'));
        final forward = Offset(rtl ? 180 : -180, 0);
        for (final key in ['reader-edge-previous', 'reader-edge-next']) {
          expect(
            tester.getSize(find.byKey(ValueKey(key))).width,
            greaterThanOrEqualTo(44),
          );
        }
        expect(find.text('33% · page 1'), findsOneWidget);
        await tester.drag(surface, -forward);
        await tester.pumpAndSettle();
        expect(find.text('33% · page 1'), findsOneWidget);
        await tester.drag(surface, forward);
        await tester.pumpAndSettle();
        expect(find.text('67% · page 2'), findsOneWidget);
        await tester.drag(surface, -forward);
        await tester.pumpAndSettle();
        expect(find.text('33% · page 1'), findsOneWidget);

        await tester.drag(surface, forward * .2);
        await tester.pumpAndSettle();
        expect(
          find.text('33% · page 1'),
          findsOneWidget,
          reason: 'small movements must not accidentally turn pages',
        );
        final gesture = await tester.startGesture(tester.getCenter(surface));
        await gesture.moveBy(forward);
        await tester.pump();
        await gesture.cancel();
        await tester.pumpAndSettle();
        expect(find.text('33% · page 1'), findsOneWidget);
      });
    }

    for (final rtl in [false, true]) {
      for (final motion in ['on', 'off', 'disabled', 'reduced']) {
        testWidgets('PDF page motion follows direction ($rtl, $motion)', (
          tester,
        ) async {
          _setView(tester, const Size(390, 844));
          tester.platformDispatcher.accessibilityFeaturesTestValue =
              FakeAccessibilityFeatures(
                disableAnimations: motion == 'disabled',
                reduceMotion: motion == 'reduced',
              );
          addTearDown(
            tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
          );
          await _open(
            tester,
            _reader(
              bridge: _ChromeBridge(rightToLeft: rtl),
              initialPath: '/books/atlas.pdf',
              settings: _epub.copyWith(animations: motion != 'off'),
            ),
          );
          await tester.pumpAndSettle();
          final surface = find.byKey(
            const ValueKey('reader-selection-surface'),
          );
          final resting = tester.getTopLeft(surface).dx;
          for (final forward in [true, false]) {
            await tester.tap(
              find.byKey(
                ValueKey(forward ? 'reader-edge-next' : 'reader-edge-previous'),
              ),
            );
            final status = forward ? '67% · page 2' : '33% · page 1';
            for (
              var frame = 0;
              frame < 20 && find.text(status).evaluate().isEmpty;
              frame++
            ) {
              await tester.pump(const Duration(milliseconds: 10));
            }
            expect(find.text(status), findsOneWidget);
            final start = tester.getTopLeft(surface).dx - resting;
            if (motion == 'on') {
              expect(start.abs(), greaterThan(1));
              expect(start.sign, (forward != rtl) ? 1 : -1);
              await tester.pump(const Duration(milliseconds: 100));
              final middle = tester.getTopLeft(surface).dx - resting;
              expect(middle.abs(), lessThan(start.abs()));
              expect(middle.sign, start.sign);
              if (forward) {
                // iOS changes reduceMotion without setting disableAnimations.
                tester.platformDispatcher.accessibilityFeaturesTestValue =
                    const FakeAccessibilityFeatures(reduceMotion: true);
                await tester.pump();
                expect(tester.getTopLeft(surface).dx, closeTo(resting, .01));
                tester.platformDispatcher.accessibilityFeaturesTestValue =
                    const FakeAccessibilityFeatures();
                await tester.pump();
              }
            } else {
              expect(start, closeTo(0, .01));
            }
            await tester.pump(const Duration(milliseconds: 250));
            expect(tester.getTopLeft(surface).dx, closeTo(resting, .01));
          }
          expect(tester.takeException(), isNull);
        });
      }
    }

    testWidgets('PDF pages still animate when selection extraction fails', (
      tester,
    ) async {
      _setView(tester, const Size(390, 844));
      await _open(
        tester,
        _reader(
          bridge: _ChromeBridge()..failSelection = true,
          initialPath: '/books/atlas.pdf',
          settings: _epub.copyWith(theme: 'dark'),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('reader-selection-surface')),
        findsNothing,
      );
      final image = find.descendant(
        of: _documentArea,
        matching: find.byType(RawImage),
      );
      final resting = tester.getTopLeft(image).dx;
      final pixels = await captureHarnessRgba(tester);
      final point =
          tester.getCenter(image) -
          tester.getTopLeft(find.byKey(harnessBoundaryKey));
      final width = tester.getSize(find.byKey(harnessBoundaryKey)).width.ceil();
      final index = (point.dy.toInt() * width + point.dx.toInt()) * 4;
      expect(
        Color.fromARGB(
          pixels[index + 3],
          pixels[index],
          pixels[index + 1],
          pixels[index + 2],
        ),
        ShosaiTokens.readerDarkBackground,
        reason:
            'the white raster becomes Night paper even without selection geometry',
      );
      await tester.tap(find.byKey(const ValueKey('reader-edge-next')));
      for (
        var frame = 0;
        frame < 20 && find.text('67% · page 2').evaluate().isEmpty;
        frame++
      ) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(find.text('67% · page 2'), findsOneWidget);
      expect(tester.getTopLeft(image).dx, greaterThan(resting + 1));
      await tester.pump(const Duration(milliseconds: 250));
      expect(tester.getTopLeft(image).dx, closeTo(resting, .01));
      expect(tester.takeException(), isNull);
    });

    testWidgets('continuous presentation never turns PDF pages on swipe', (
      tester,
    ) async {
      _setView(tester, const Size(390, 844));
      await _open(
        tester,
        _reader(
          bridge: _ChromeBridge(),
          initialPath: '/books/atlas.pdf',
          settings: _continuous,
        ),
      );
      await tester.drag(
        find.byKey(const ValueKey('reader-selection-surface')),
        const Offset(-180, 0),
      );
      await tester.pumpAndSettle();
      expect(find.text('33% · page 1'), findsOneWidget);
    });

    testWidgets('enabled and disabled states dispatch unit navigation', (
      tester,
    ) async {
      _setView(tester, const Size(1280, 800));
      final bridge = _ChromeBridge();
      await _open(tester, _reader(bridge: bridge));

      final previous = _button(tester, 'reader-edge-previous');
      final next = _button(tester, 'reader-edge-next');
      expect(previous.enabled, isFalse);
      expect(next.enabled, isTrue);
      expect(
        _controlSemantics(tester, 'reader-edge-next').properties.label,
        'Next page',
      );

      await tester.tap(find.byKey(const ValueKey('reader-edge-next')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 32));
      expect(bridge.events, isNotEmpty);
      expect(find.text('67% · chapter 2 of 3'), findsOneWidget);
      expect(_button(tester, 'reader-edge-previous').enabled, isTrue);
    });

    testWidgets('a PDF spread shows the cover alone, then turns both pages', (
      tester,
    ) async {
      _setView(tester, const Size(1280, 800));
      final bridge = _ChromeBridge();
      await _open(
        tester,
        _reader(bridge: bridge, initialPath: '/books/atlas.pdf'),
      );
      await tester.pump(const Duration(milliseconds: 32));
      expect(find.text('33% · page 1 of 3'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('reader-edge-next')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 32));
      expect(find.text('100% · pages 2–3 of 3'), findsOneWidget);
      expect(_button(tester, 'reader-edge-next').enabled, isFalse);

      await tester.tap(find.byKey(const ValueKey('reader-edge-previous')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 32));
      expect(find.text('33% · page 1 of 3'), findsOneWidget);
    });

    testWidgets('a right-to-left PDF turns leftward, first page on the right', (
      tester,
    ) async {
      _setView(tester, const Size(1280, 800));
      final bridge = _SidedPdfBridge();
      final rasters = <({Uint8List pixels, int width})>[];
      await _open(
        tester,
        _reader(
          bridge: bridge,
          initialPath: '/books/atlas.pdf',
          decoder: (pixels, {required width, required height}) {
            rasters.add((pixels: pixels, width: width));
            return _testImage();
          },
        ),
      );
      await tester.pump(const Duration(milliseconds: 32));
      expect(
        tester.getCenter(find.byKey(const ValueKey('reader-edge-next'))).dx,
        lessThan(
          tester
              .getCenter(find.byKey(const ValueKey('reader-edge-previous')))
              .dx,
        ),
        reason: 'the next page is behind the left margin',
      );

      await tester.tap(find.byKey(const ValueKey('reader-edge-next')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 32));
      await tester.pump(const Duration(milliseconds: 32));
      expect(find.text('100% · pages 2–3 of 3'), findsOneWidget);

      // Page 3 (unit 2, 200 wide) is drawn on the left and page 2 (unit 1,
      // 300 wide) on the right, in the raster and the selection surface alike.
      final raster = rasters.last;
      expect(raster.width, 500);
      int unitAt(int x) => raster.pixels[x * 4];
      expect([unitAt(5), unitAt(195), unitAt(205), unitAt(495)], [2, 2, 1, 1]);
      final painter = _pagePainter(tester);
      final surface = painter.surface;
      expect(surface.text, 'p\np', reason: 'page 2 still reads first');
      expect(
        [
          for (final endpoint in surface.endpoints)
            (endpoint.offset.toInt(), endpoint.rect.left),
        ],
        [(0, 210.0), (2, 10.0)],
      );
      expect(painter.spread!.facingUnit, 2);
    });

    testWidgets('a right-to-left spread paints each page\'s area highlights '
        'on that page', (tester) async {
      _setView(tester, const Size(1280, 800));
      final bridge = _SidedPdfBridge()
        ..annotations = [
          _areaHighlight(1, FlutterHighlightColor.yellow),
          _areaHighlight(2, FlutterHighlightColor.blue),
        ];
      await _open(
        tester,
        _reader(bridge: bridge, initialPath: '/books/atlas.pdf'),
      );
      await tester.tap(find.byKey(const ValueKey('reader-edge-next')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 32));
      await tester.pump(const Duration(milliseconds: 32));
      expect(find.text('100% · pages 2–3 of 3'), findsOneWidget);

      final painter = _pagePainter(tester);
      expect(
        [for (final annotation in painter.annotations) annotation.unit.toInt()],
        unorderedEquals([1, 2]),
        reason: 'both pages\' highlights reach the painter',
      );
      final colors = await _paintedColors(
        tester,
        painter,
        const Size(500, 560),
        const [Offset(20, 20), Offset(220, 20), Offset(120, 20)],
      );
      // Page 3's blue highlight is on the left page and page 2's yellow one
      // on the right page; nothing is painted between them.
      expect(colors[0].b, greaterThan(colors[0].r));
      expect(colors[1].r, greaterThan(colors[1].b));
      expect(colors[2].a, 0);
    });

    testWidgets('a right-to-left PDF read a page at a time steps leftward', (
      tester,
    ) async {
      _setView(tester, const Size(1280, 800));
      await _open(
        tester,
        _reader(
          bridge: _ChromeBridge(rightToLeft: true),
          initialPath: '/books/atlas.pdf',
          settings: _epub.copyWith(twoPages: false),
        ),
      );
      await tester.pump(const Duration(milliseconds: 32));
      final track = find.byKey(const ValueKey('reader-progress-track'));
      Focus.of(tester.element(track)).requestFocus();
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 32));
      expect(find.text('67% · page 2 of 3'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 32));
      expect(find.text('33% · page 1 of 3'), findsOneWidget);
    });

    testWidgets('a PDF opened after a right-to-left one turns rightward', (
      tester,
    ) async {
      _setView(tester, const Size(1280, 800));
      final bridge = _ChromeBridge(rightToLeft: true);
      await _open(
        tester,
        _reader(
          bridge: bridge,
          initialPath: '/books/atlas.pdf',
          documentPicker: () async =>
              const ReaderPickedDocument('/books/replacement.pdf'),
        ),
      );
      await tester.pump(const Duration(milliseconds: 32));
      double nextLeftOfPrevious() =>
          tester.getCenter(find.byKey(const ValueKey('reader-edge-next'))).dx -
          tester
              .getCenter(find.byKey(const ValueKey('reader-edge-previous')))
              .dx;
      expect(nextLeftOfPrevious(), lessThan(0));

      bridge.rightToLeft = false;
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyO);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      for (var frame = 0; frame < 6; frame += 1) {
        await tester.pump(const Duration(milliseconds: 32));
      }
      expect(bridge.pdfEngineOpenedPaths.last, '/books/replacement.pdf');
      expect(nextLeftOfPrevious(), greaterThan(0));
    });

    for (final rightToLeft in [false, true]) {
      testWidgets('the progress track steps a PDF a spread at a time '
          '(${rightToLeft ? 'right to left' : 'left to right'})', (
        tester,
      ) async {
        _setView(tester, const Size(1280, 800));
        await _open(
          tester,
          _reader(
            bridge: _ChromeBridge(unitCount: 5, rightToLeft: rightToLeft),
            initialPath: '/books/atlas.pdf',
          ),
        );
        await tester.pump(const Duration(milliseconds: 32));
        final track = find.byKey(const ValueKey('reader-progress-track'));
        Focus.of(tester.element(track)).requestFocus();
        await tester.pump();
        // The arrow toward the next page: left in a right-to-left book.
        final forward = rightToLeft
            ? LogicalKeyboardKey.arrowLeft
            : LogicalKeyboardKey.arrowRight;
        final backward = rightToLeft
            ? LogicalKeyboardKey.arrowRight
            : LogicalKeyboardKey.arrowLeft;
        // The track's semantics: what it shows, and what a step forward and
        // back would show.
        SemanticsProperties semantics() => tester
            .widget<Semantics>(
              find
                  .ancestor(
                    of: track,
                    matching: find.byWidgetPredicate(
                      (widget) =>
                          widget is Semantics &&
                          widget.properties.value != null,
                    ),
                  )
                  .first,
            )
            .properties;
        Future<void> step(LogicalKeyboardKey key) async {
          // A step announces beforehand the place it then shows.
          final predicted = key == forward
              ? semantics().increasedValue
              : semantics().decreasedValue;
          final shown = semantics().value;
          await tester.sendKeyEvent(key);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 32));
          await tester.pump(const Duration(milliseconds: 32));
          expect(semantics().value, predicted ?? shown);
        }

        expect(find.textContaining('page 1 of 5'), findsOneWidget);
        await step(forward);
        expect(find.textContaining('pages 2–3 of 5'), findsOneWidget);
        await step(forward);
        expect(find.textContaining('pages 4–5 of 5'), findsOneWidget);
        await step(forward);
        expect(find.textContaining('pages 4–5 of 5'), findsOneWidget);
        await step(backward);
        expect(find.textContaining('pages 2–3 of 5'), findsOneWidget);
        await step(backward);
        expect(find.textContaining('page 1 of 5'), findsOneWidget);
      });
    }

    testWidgets('one page reads a PDF a page at a time', (tester) async {
      _setView(tester, const Size(1280, 800));
      final bridge = _ChromeBridge();
      final saved = <bool?>[];
      await _open(
        tester,
        _reader(
          bridge: bridge,
          initialPath: '/books/atlas.pdf',
          onDisplayChanged: (change) => saved.add(change.twoPages),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('reader-header-typography')));
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('reader-typography-one-page')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 32));
      await tester.pump(const Duration(milliseconds: 32));
      expect(find.text('33% · page 1 of 3'), findsOneWidget);
      // The choice is handed to the shell to save, once.
      expect(saved, [false]);
      await tester.tap(
        find.byKey(const ValueKey('reader-typography-one-page')),
      );
      await tester.pump();
      expect(saved, [false]);
    });

    for (final animations in [true, false]) {
      testWidgets(
        'page animations opens $animations and toggles without layout',
        (tester) async {
          _setView(tester, const Size(1280, 800));
          final bridge = _ChromeBridge();
          final saved = <ReaderDisplayChange>[];
          await _open(
            tester,
            _reader(
              bridge: bridge,
              initialPath: '/books/atlas.pdf',
              settings: animations ? _epub : _epub.copyWith(animations: false),
              onDisplayChanged: saved.add,
            ),
          );
          await tester.tap(
            find.byKey(const ValueKey('reader-header-typography')),
          );
          await tester.pumpAndSettle();
          final toggle = find.byKey(
            const ValueKey('reader-typography-animations'),
          );
          expect(find.text('Page animations'), findsOneWidget);
          expect(tester.widget<ShadSwitch>(toggle).value, animations);
          final layouts = bridge.selectionLayouts.length;
          final pages = bridge.pageCalls;
          await tester.tap(toggle);
          await tester.pumpAndSettle();
          expect(tester.widget<ShadSwitch>(toggle).value, !animations);
          expect(saved, [
            (
              theme: null,
              fontSize: null,
              lineSpacing: null,
              twoPages: null,
              animations: !animations,
            ),
          ]);
          expect(bridge.selectionLayouts, hasLength(layouts));
          expect(bridge.pageCalls, pages);
        },
      );
    }

    testWidgets('the theme, text size and line spacing are handed over', (
      tester,
    ) async {
      _setView(tester, const Size(1280, 800));
      final bridge = _ChromeBridge();
      final saved = <ReaderDisplayChange>[];
      await _open(tester, _reader(bridge: bridge, onDisplayChanged: saved.add));
      await tester.tap(find.byKey(const ValueKey('reader-header-typography')));
      await tester.pump();
      await tester.tap(find.text('Sepia'));
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('reader-typography-font-increase')),
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('reader-typography-line-spacing-increase')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 32));

      expect(saved, hasLength(3));
      expect(saved[0], (
        theme: 'sepia',
        fontSize: null,
        lineSpacing: null,
        twoPages: null,
        animations: null,
      ));
      expect(saved[1].fontSize, greaterThan(18));
      expect((saved[1].theme, saved[1].lineSpacing), (null, null));
      expect(saved[2].lineSpacing, greaterThan(1.6));
      expect((saved[2].theme, saved[2].fontSize), (null, null));

      // The theme already chosen is not handed over again.
      await tester.tap(find.text('Sepia'));
      await tester.pump();
      expect(saved, hasLength(3));
    });

    testWidgets('a saved one-page setting opens a PDF on one page', (
      tester,
    ) async {
      _setView(tester, const Size(1280, 800));
      final bridge = _ChromeBridge();
      await _open(
        tester,
        _reader(
          bridge: bridge,
          initialPath: '/books/atlas.pdf',
          settings: _epub.copyWith(twoPages: false),
        ),
      );
      await tester.pump(const Duration(milliseconds: 32));
      await tester.tap(find.byKey(const ValueKey('reader-edge-next')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 32));
      expect(find.text('67% · page 2 of 3'), findsOneWidget);
    });

    testWidgets('a disabled edge dispatches nothing', (tester) async {
      _setView(tester, const Size(1280, 800));
      final bridge = _ChromeBridge();
      await _open(tester, _reader(bridge: bridge));
      final before = bridge.events.length;
      await tester.tap(
        find.byKey(const ValueKey('reader-edge-previous')),
        warnIfMissed: false,
      );
      await tester.pump();
      expect(bridge.events.length, before);
      expect(find.text('33% · chapter 1 of 3'), findsOneWidget);
    });

    testWidgets('reserves its columns invisibly without a document', (
      tester,
    ) async {
      _setView(tester, const Size(1280, 800));
      await _open(tester, _reader(bridge: _ChromeBridge(), initialPath: null));
      // The controls are hidden but their columns keep the width the document
      // state uses, so the content area does not change width when a document
      // arrives (and the open is laid out for the width it keeps).
      final reservedWidth = tester
          .getSize(find.byKey(const ValueKey('reader-edge-previous')))
          .width;
      expect(
        tester
            .widget<Visibility>(
              find
                  .ancestor(
                    of: find.byKey(const ValueKey('reader-edge-previous')),
                    matching: find.byType(Visibility),
                  )
                  .first,
            )
            .visible,
        isFalse,
      );

      await _open(tester, _reader(bridge: _ChromeBridge()));
      expect(
        tester
            .getSize(find.byKey(const ValueKey('reader-edge-previous')))
            .width,
        reservedWidth,
      );
    });

    testWidgets('is hidden in continuous mode', (tester) async {
      _setView(tester, const Size(1280, 800));
      await _open(
        tester,
        _reader(bridge: _ChromeBridge(), settings: _continuous),
      );
      expect(find.byKey(const ValueKey('reader-edge-previous')), findsNothing);
      expect(find.byKey(const ValueKey('reader-edge-next')), findsNothing);
    });
  });

  group('panel host', () {
    testWidgets('panels are mutually exclusive and Escape closes with focus '
        'return', (tester) async {
      _setView(tester, const Size(1280, 800));
      await _open(tester, _reader(bridge: _ChromeBridge()));

      await tester.tap(find.byKey(const ValueKey('reader-header-contents')));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('reader-panel-contents')),
        findsOneWidget,
      );
      await tester.pump();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'reader panel');

      await tester.tap(find.byKey(const ValueKey('reader-header-typography')));
      await tester.pump();
      expect(find.byKey(const ValueKey('reader-panel-contents')), findsNothing);
      expect(
        find.byKey(const ValueKey('reader-panel-typography')),
        findsOneWidget,
      );

      // The controller defers the panel focus request to the frame the panel
      // is built in; give it that frame before sending the key.
      await tester.pump();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'reader panel');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump();
      expect(
        find.byKey(const ValueKey('reader-panel-typography')),
        findsNothing,
      );
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'reader typography',
      );
    });

    testWidgets('a popover floats over the page and the docked notes panel '
        'narrows the stage', (tester) async {
      _setView(tester, const Size(1280, 800));
      final bridge = _ChromeBridge();
      await _open(tester, _reader(bridge: bridge));
      final before = tester.getRect(_documentArea);
      final stage = tester.getSize(find.byKey(const ValueKey('reader-stage')));

      await tester.tap(find.byKey(const ValueKey('reader-header-contents')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 32));
      expect(
        tester.getRect(_documentArea),
        before,
        reason: 'the Contents popover does not lay the book out again',
      );

      await tester.tap(find.byKey(const ValueKey('reader-header-notes')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 32));
      expect(
        tester.getSize(find.byKey(const ValueKey('reader-stage'))).width,
        stage.width - ShosaiTokens.sizePanelWidth,
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('reader-panel-notes'))).width,
        ShosaiTokens.sizePanelWidth,
      );
    });

    testWidgets('an open modal disables the chrome until it closes', (
      tester,
    ) async {
      _setView(tester, const Size(1280, 800));
      final bridge = _ChromeBridge(books: harnessLibraryBooks());
      await _open(tester, _reader(bridge: bridge, initialBookId: 1));
      expect(_button(tester, 'reader-header-typography').enabled, isTrue);

      // The page note action opens the controller-owned modal through
      // a rendered control (contract §3.1 `modalEffect`).
      await tester.tap(find.byKey(const ValueKey('reader-header-notes')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 32));
      await tester.tap(find.byKey(const ValueKey('reader-notes-add-page')));
      await tester.pumpAndSettle();
      expect(find.byType(ShadDialog), findsOneWidget);
      expect(
        _button(tester, 'reader-header-typography').enabled,
        isFalse,
        reason: 'the header gates on the open modal',
      );
      expect(_button(tester, 'reader-header-contents').enabled, isFalse);

      await tester.tap(find.widgetWithText(ShadButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(ShadDialog), findsNothing);
      expect(
        _button(tester, 'reader-header-typography').enabled,
        isTrue,
        reason: 'the modal slot is cleared when the dialog closes',
      );
    });

    testWidgets('the docked notes panel keeps edge navigation beside it', (
      tester,
    ) async {
      _setView(tester, const Size(1280, 800));
      final bridge = _ChromeBridge();
      await _open(tester, _reader(bridge: bridge));
      final edges = tester.getSize(
        find.byKey(const ValueKey('reader-edge-previous')),
      );
      expect(edges.width, greaterThan(0));

      await tester.tap(find.byKey(const ValueKey('reader-header-notes')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 32));
      await tester.pump(const Duration(milliseconds: 32));

      // The stage keeps its page and both page-turn margins beside the panel.
      final panel = tester.getRect(
        find.byKey(const ValueKey('reader-panel-notes')),
      );
      expect(
        find.byKey(const ValueKey('reader-edge-previous')),
        findsOneWidget,
      );
      expect(
        tester.getRect(find.byKey(const ValueKey('reader-edge-next'))).right,
        lessThanOrEqualTo(panel.left),
      );
      expect(tester.getRect(_documentArea).right, lessThan(panel.left));
    });

    testWidgets('a long page note stays inside the notes panel', (
      tester,
    ) async {
      _setView(tester, const Size(1280, 800));
      final bridge = _ChromeBridge(books: harnessLibraryBooks())
        ..placeNotes.add(
          FlutterNote(
            id: 'note-1',
            kind: FlutterNoteKind.page,
            unit: BigInt.zero,
            resolution: FlutterAnnotationResolution.exact,
            body:
                'A deliberately long saved note that cannot fit the bounded '
                'panel row without ellipsizing, repeated for good measure',
            modifiedAt: '2026-09-20T00:00:00Z',
          ),
        );
      await _open(tester, _reader(bridge: bridge, initialBookId: 1));

      await tester.tap(find.byKey(const ValueKey('reader-header-notes')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 32));

      // No overflow: the note card keeps the note inside the panel (the note
      // paragraph ellipsizes).
      expect(tester.takeException(), isNull);
      expect(
        find.textContaining('A deliberately long saved note'),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('reader-place-note-note-1')),
        findsOneWidget,
      );
      final panel = tester.getRect(
        find.byKey(const ValueKey('reader-panel-notes')),
      );
      final row = tester.getRect(
        find.textContaining('A deliberately long saved note'),
      );
      expect(row.left, greaterThanOrEqualTo(panel.left - 0.5));
      expect(row.right, lessThanOrEqualTo(panel.right + 0.5));

      // The same holds at compact width and 200 % text.
      tester.view.physicalSize = const Size(390, 844);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 32));
      expect(tester.takeException(), isNull);
      expect(
        find.textContaining('A deliberately long saved note'),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('reader-place-note-note-1')),
        findsOneWidget,
      );
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });

    testWidgets('an orphaned page note does not open its old place', (
      tester,
    ) async {
      _setView(tester, const Size(1280, 800));
      final bridge = _ChromeBridge(books: harnessLibraryBooks());
      for (final (id, resolution) in [
        ('found', FlutterAnnotationResolution.recovered),
        ('lost', FlutterAnnotationResolution.orphaned),
      ]) {
        bridge.placeNotes.add(
          FlutterNote(
            id: id,
            kind: FlutterNoteKind.page,
            unit: BigInt.zero,
            resolution: resolution,
            body: id,
            modifiedAt: '2026-09-20T00:00:00Z',
          ),
        );
      }
      await _open(tester, _reader(bridge: bridge, initialBookId: 1));

      await tester.tap(find.byKey(const ValueKey('reader-header-notes')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 32));

      // The lost note's card opens its editor instead of its old place.
      await tester.tap(
        find.byKey(const ValueKey('reader-place-note-lost-open')),
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey('reader-note-edit-field')),
        findsOneWidget,
      );
      expect(find.textContaining('Page note — '), findsNWidgets(2));
    });

    testWidgets('a resize keeps focus in the open panel', (tester) async {
      _setView(tester, const Size(1280, 800));
      final bridge = _ChromeBridge();
      await _open(tester, _reader(bridge: bridge));
      await tester.tap(find.byKey(const ValueKey('reader-header-typography')));
      await tester.pump();
      await tester.pump();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'reader panel');

      // A passive relayout invalidation must not steal focus from the panel.
      tester.view.physicalSize = const Size(1000, 800);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 32));
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'reader panel');

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump();
      expect(
        find.byKey(const ValueKey('reader-panel-typography')),
        findsNothing,
      );
    });
  });

  group('semantics', () {
    testWidgets('named chrome controls keep a gated activation action', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      _setView(tester, const Size(1280, 800));
      final bridge = _ChromeBridge();
      await _open(tester, _reader(bridge: bridge));

      for (final key in const [..._headerActions, 'reader-edge-next']) {
        expect(
          _hasTapAction(tester, key),
          isTrue,
          reason: '$key must be activatable by a screen reader',
        );
      }

      // Activating the semantic action runs the control's intent.
      final notes = tester.getSemantics(
        find.byKey(const ValueKey('reader-header-notes')),
      );
      // The semantics owner that owns the rendered tree (`RenderView.owner`),
      // the same one the semantics finders use.
      tester.binding.renderViews.first.owner!.semanticsOwner!.performAction(
        notes.id,
        SemanticsAction.tap,
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('reader-panel-notes')), findsOneWidget);

      // A rendered but disabled control has no activation action.
      expect(
        _hasTapAction(tester, 'reader-edge-previous'),
        isFalse,
        reason: 'the previous edge is disabled on the first unit',
      );

      // A disabled header action is not activatable either.
      await _open(tester, _reader(bridge: _ChromeBridge(hangOpen: true)));
      expect(
        _hasTapAction(tester, 'reader-header-contents'),
        isFalse,
        reason: 'a disabled header action must not be activatable',
      );
      semantics.dispose();
    });
  });

  group('annotation focus', () {
    testWidgets('activation leaves the surface shortcuts working', (
      tester,
    ) async {
      _setView(tester, const Size(1280, 800));
      final bridge = _ChromeBridge()
        ..annotations = [
          FlutterAnnotation(
            id: 'one',
            unit: BigInt.zero,
            resolution: FlutterAnnotationResolution.exact,
            textRange: FlutterAnnotationTextRange(
              start: BigInt.one,
              end: BigInt.from(3),
            ),
            color: FlutterHighlightColor.yellow,
          ),
        ];
      await _open(tester, _reader(bridge: bridge));
      await tester.tap(find.byKey(const ValueKey('reader-header-notes')));
      await tester.pump();

      await tester.tap(
        find.byKey(const ValueKey('reader-annotation-one-open')),
      );
      await tester.pump();
      // The controller explicitly returns focus to the surface after
      // navigation, so a surface-only shortcut reaches the selection.
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'reader surface');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byKey(const ValueKey('selection-actions')), findsNothing);
    });
  });

  group('layout failure chrome', () {
    testWidgets('a failed layout is reported as a layout failure', (
      tester,
    ) async {
      _setView(tester, const Size(1280, 800));
      final bridge = _ChromeBridge();
      await _open(
        tester,
        _reader(bridge: bridge, initialPath: '/books/atlas.pdf'),
      );

      bridge.failRender = true;
      await tester.tap(find.byKey(const ValueKey('reader-edge-next')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 32));
      bridge.failRender = false;

      // The bridge reason is visible (kind and message, not
      // "Instance of 'FlutterBridgeError'") and the entry is not labelled as a
      // selection problem.
      final error = find.byKey(const ValueKey('reader-relayout-error'));
      expect(error, findsOneWidget);
      expect(
        find.textContaining('page render rejected (invalidRequest)'),
        findsOneWidget,
      );
      expect(find.textContaining('Selection unavailable'), findsNothing);

      // The failure is transient: the committed content stays and a retry
      // clears it.
      await tester.tap(find.byKey(const ValueKey('reader-edge-next')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 32));
      expect(error, findsNothing);
    });
  });

  group('opening and failure chrome', () {
    testWidgets('an open failure shows a live-region alert with retry', (
      tester,
    ) async {
      _setView(tester, const Size(900, 700));
      final bridge = _ChromeBridge(failOpen: true);
      await _open(tester, _reader(bridge: bridge));

      expect(find.byKey(const ValueKey('reader-open-error')), findsOneWidget);
      expect(find.textContaining('could not be found'), findsOneWidget);
      expect(_button(tester, 'reader-open-error-retry').enabled, isTrue);
      await tester.tap(find.byKey(const ValueKey('reader-open-error-retry')));
      await tester.pump();
      expect(find.byKey(const ValueKey('reader-open-error')), findsOneWidget);
    });
  });

  testWidgets('T200 leaves the document font size unchanged', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    final bridge = _ChromeBridge();
    await _open(
      tester,
      _reader(
        bridge: bridge,
        settings: const FlutterReaderSettings(
          continuous: false,
          theme: 'light',
          epubFontSize: 24,
          epubLineSpacing: 1.6,
          pdfZoom: 0,
        ),
      ),
    );
    // The interface scale must never scale the document font: the book text
    // is set at the reader preference (24), never the 200% value (48).
    final page = await _paintedEpubPage(tester);
    final blocks = [
      for (final slice in page.page.slices.whereType<TextPageSlice>())
        slice.block.text!,
    ];
    expect(blocks, isNotEmpty);
    final sizes = <double?>{};
    for (final block in blocks) {
      expect(block.painter.textScaler, TextScaler.noScaling);
      block.painter.text!.visitChildren((span) {
        if (span is TextSpan && span.text != null) {
          sizes.add(span.style?.fontSize);
        }
        return true;
      });
    }
    expect(sizes, {24});
  });

  test('a highlight save the reader turns down keeps the draft', () async {
    FlutterAnnotation highlight(String id) => FlutterAnnotation(
      id: id,
      unit: BigInt.zero,
      resolution: FlutterAnnotationResolution.exact,
      textRange: FlutterAnnotationTextRange(
        start: BigInt.one,
        end: BigInt.from(3),
      ),
      color: FlutterHighlightColor.yellow,
    );
    final gate = Completer<void>();
    final bridge = _GatedUpdateBridge(gate.future)
      ..annotations = [highlight('one'), highlight('two')];
    final controller = ReaderController(
      bridge: bridge,
      decoder: (pixels, {required int width, required int height}) async =>
          _testImage(),
    );
    addTearDown(controller.dispose);
    controller.dispatch(const ReaderOpenRequested('/books/x.pdf', bookId: 3));
    await pumpEventQueue();
    controller.dispatch(
      const ReaderNoteEditStarted('reader-annotation-one', 'Draft'),
    );

    // Another highlight's write holds the reader; this save is turned down.
    controller.dispatch(
      const ReaderAnnotationUpdated('two', FlutterHighlightColor.green, null),
    );
    controller.dispatch(const ReaderAnnotationNoteSaved('one', 'Draft'));
    await pumpEventQueue();
    expect(bridge.updatedIds, ['two']);
    expect(controller.model.noteEdit?.text, 'Draft');

    gate.complete();
    await pumpEventQueue();
    controller.dispatch(const ReaderAnnotationNoteSaved('one', 'Draft'));
    await pumpEventQueue();
    expect(bridge.updatedIds, ['two', 'one']);
    expect(controller.model.noteEdit, isNull);
  });

  test('an in-place edit ends when its note is gone', () async {
    FlutterNote note(String id) => FlutterNote(
      id: id,
      kind: FlutterNoteKind.book,
      resolution: FlutterAnnotationResolution.exact,
      body: id,
      modifiedAt: '2026-09-20T00:00:00Z',
    );
    final bridge = _ChromeBridge(books: harnessLibraryBooks())
      ..placeNotes.addAll([note('a'), note('b'), note('c')]);
    final controller = ReaderController(
      bridge: bridge,
      decoder: (pixels, {required int width, required int height}) async =>
          _testImage(),
    );
    addTearDown(controller.dispose);
    controller.dispatch(const ReaderOpenRequested('/books/x.pdf', bookId: 3));
    await pumpEventQueue();
    controller.dispatch(
      const ReaderNoteEditStarted('reader-place-note-a', 'Draft'),
    );

    // Another note's delete leaves the edit alone.
    controller.dispatch(const ReaderNoteDeleted('b'));
    await pumpEventQueue();
    expect(controller.model.noteEdit?.text, 'Draft');

    // A listing without the note ends it.
    bridge.placeNotes.removeWhere((item) => item.id == 'a');
    controller.dispatch(const ReaderNoteDeleted('c'));
    await pumpEventQueue();
    expect(controller.model.notes.map((item) => item.id), isNot(contains('a')));
    expect(controller.model.noteEdit, isNull);
  });

  test('a stale editor completion cannot clear a newer editor slot', () async {
    final bridge = _ChromeBridge(books: harnessLibraryBooks())
      ..annotations = [
        FlutterAnnotation(
          id: 'one',
          unit: BigInt.zero,
          resolution: FlutterAnnotationResolution.exact,
          textRange: FlutterAnnotationTextRange(
            start: BigInt.one,
            end: BigInt.from(3),
          ),
          color: FlutterHighlightColor.yellow,
        ),
      ];
    final annotationEditors = <Completer<String?>>[];
    final placeEditors = <Completer<String?>>[];
    final controller = ReaderController(
      bridge: bridge,
      decoder: (pixels, {required int width, required int height}) async =>
          _testImage(),
      noteEditor: (_) {
        final completer = Completer<String?>();
        annotationEditors.add(completer);
        return completer.future;
      },
      placeNoteEditor: (_) {
        final completer = Completer<String?>();
        placeEditors.add(completer);
        return completer.future;
      },
      noteEditorCanceller: () {},
    );
    addTearDown(controller.dispose);
    controller.dispatch(const ReaderOpenRequested('/books/x.pdf', bookId: 3));
    await pumpEventQueue();
    expect(controller.model.document, isNotNull);
    expect(controller.model.annotations, isNotEmpty);

    // Annotation editors count with `_noteRevision`: the first is revision 1
    // (completed), the second is revision 2 and stays pending.
    controller.dispatch(const ReaderAnnotationNoteRequested('one'));
    expect(annotationEditors, hasLength(1));
    annotationEditors.first.complete('first');
    await pumpEventQueue();
    controller.dispatch(const ReaderAnnotationNoteRequested('one'));
    expect(annotationEditors, hasLength(2));

    // Suspension clears the owner and advances both counters; the next page
    // note editor counts with `_notesRevision`, which can collide with the
    // pending annotation editor's revision (`_noteRevision`).
    controller.dispatch(const ReaderSuspended());
    await pumpEventQueue();
    expect(controller.model.modalEffect, isNull);
    controller.dispatch(const ReaderResumed());
    await pumpEventQueue();

    controller.dispatch(const ReaderPageNoteRequested());
    expect(placeEditors, hasLength(1));
    expect(controller.model.modalEffect, ReaderModalEffect.placeNote);

    // The stale annotation editor finishing must not clear the newer note
    // slot: ownership is the token, not the colliding revision.
    annotationEditors.last.complete('stale');
    await pumpEventQueue();
    expect(
      controller.model.modalEffect,
      ReaderModalEffect.placeNote,
      reason: 'the replacement dialog still owns the modal slot',
    );

    // The replacement is still owned: suspending cancels it and clears it.
    controller.dispatch(const ReaderSuspended());
    await pumpEventQueue();
    expect(controller.model.modalEffect, isNull);
    for (final pending in placeEditors.where((e) => !e.isCompleted)) {
      pending.complete(null);
    }
  });

  test(
    'the modal slot is published, cleared on cancel and stale-safe',
    () async {
      final bridge = _ChromeBridge(books: harnessLibraryBooks());
      final editors = <Completer<String?>>[];
      final controller = ReaderController(
        bridge: bridge,
        decoder: (pixels, {required int width, required int height}) async =>
            _testImage(),
        placeNoteEditor: (_) {
          final completer = Completer<String?>();
          editors.add(completer);
          return completer.future;
        },
        noteEditorCanceller: () {},
      );
      addTearDown(controller.dispose);
      controller.dispatch(
        const ReaderOpenRequested('/books/x.epub', bookId: 1),
      );
      await pumpEventQueue();
      expect(controller.model.document, isNotNull);

      // Acquisition publishes the owned slot before the adapter starts.
      controller.dispatch(const ReaderPageNoteRequested());
      expect(editors, hasLength(1));
      expect(controller.model.modalEffect, ReaderModalEffect.placeNote);

      // A relayout while the dialog is open must not clear or replace it.
      controller.dispatch(
        const ReaderViewportChanged(
          ReaderLayout(scale: 1, width: 800, lineSpacing: 1.5),
        ),
      );
      expect(controller.model.modalEffect, ReaderModalEffect.placeNote);

      // Suspending cancels the dialog and clears the slot (owner-checked).
      controller.dispatch(const ReaderSuspended());
      await pumpEventQueue();
      expect(controller.model.modalEffect, isNull);

      // A stale completion cannot resurrect the slot.
      editors.single.complete('late note');
      await pumpEventQueue();
      expect(controller.model.modalEffect, isNull);
    },
  );

  test(
    'closing the search cancels an in-flight search and drops results',
    () async {
      final bridge = _ChromeBridge();
      final controller = ReaderController(
        bridge: bridge,
        decoder: (pixels, {required int width, required int height}) async =>
            _testImage(),
      );
      addTearDown(controller.dispose);
      controller.dispatch(const ReaderOpenRequested('/books/slow-rivers.epub'));
      await pumpEventQueue();
      expect(controller.model.document, isNotNull);

      controller.dispatch(const ReaderSearchToggled());
      expect(controller.model.searchOpen, isTrue);
      controller.dispatch(const ReaderSearchRequested('river'));
      expect(controller.model.searchBusy, isTrue);
      expect(bridge.searchCompletions, hasLength(1));

      // Closing the search cancels the query; the stale completion cannot
      // publish results afterwards.
      controller.dispatch(const ReaderSearchToggled());
      expect(controller.model.searchOpen, isFalse);
      expect(controller.model.searchBusy, isFalse);
      bridge.searchCompletions.single.complete([
        FlutterSearchMatch(
          unit: BigInt.zero,
          offset: BigInt.zero,
          length: BigInt.one,
          context: 'river',
        ),
      ]);
      await pumpEventQueue();
      expect(controller.model.searchResults, isEmpty);
    },
  );
}

/// Pushes [reader] onto the navigator so the reader can leave it.
class _PushHost extends StatefulWidget {
  const _PushHost({required this.child, required this.reader});

  final Widget child;
  final Widget reader;

  @override
  State<_PushHost> createState() => _PushHostState();
}

class _PushHostState extends State<_PushHost> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.of(
        context,
      ).push(MaterialPageRoute<void>(builder: (_) => widget.reader));
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// A reader host that owns a bridge for the pushed-route test.
class _ReaderHost extends StatelessWidget {
  const _ReaderHost({required this.bridge});

  final HarnessBridge bridge;

  @override
  Widget build(BuildContext context) => ReaderScreen(
    bridge: bridge,
    initialPath: '/books/slow-rivers.epub',
    initialSettings: _epub,
  );
}
