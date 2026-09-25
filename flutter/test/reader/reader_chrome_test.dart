import 'dart:async';

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shosai_flutter/main.dart';
import 'package:shosai_flutter/src/rust/api.dart';
import 'package:shosai_flutter/theme_tokens.dart';

import '../support/production_shell_harness.dart';

/// Package 4B reader chrome: header, tab strip, progress/status, edge
/// navigation and the panel host (rows RD-01…RD-06, RD-13, RD-14, RD-16, RD-17).
///
/// Interaction contracts are driven through the rendered surface; the tab list
/// and progress ordinals are fixture-injected presentation data because the
/// bridge has no session, tab or pagination API (contract §2.2). Real tab
/// lifecycle is 5F and real page ranges are 5G.
class _ChromeBridge extends HarnessBridge {
  _ChromeBridge({
    super.books,
    this.title,
    this.failOpen = false,
    this.hangOpen = false,
  });

  final String? title;
  final bool failOpen;
  final bool hangOpen;

  /// Font sizes reported to Rust by the reader layout path.
  final List<double> reportedFontSizes = [];

  /// Widths reported to Rust by the reader layout path.
  final List<double> reportedWidths = [];

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

  /// When set, the next selection-surface call fails with a bridge error, so a
  /// layout failure can be driven through the rendered chrome.
  bool failSelectionSurface = false;

  /// Saved places the contents panel renders (fixture-backed; persistence is
  /// live in production).
  List<FlutterBookmark> bookmarks = const [];

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
  Future<FlutterSelectionSurface> selectionSurface({
    required FlutterDocumentHandle document,
    required BigInt unit,
    required double scale,
    required double width,
    required double fontSize,
    required double lineSpacing,
    required BigInt cancellationId,
  }) async {
    reportedFontSizes.add(fontSize);
    reportedWidths.add(width);
    if (failSelectionSurface) {
      throw const FlutterBridgeError(
        kind: FlutterBridgeErrorKind.invalidRequest,
        message: 'chapter layout rejected',
      );
    }
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
  List<ReaderTabPresentation> tabs = const [],
  ReaderProgressSource? progressSource,
  bool debugPathEntry = false,
}) => productionShell(
  locale: locale,
  home: ReaderScreen(
    key: ValueKey('reader-${_readerKeyCounter++}'),
    bridge: bridge,
    decoder: (pixels, {required width, required height}) => _testImage(),
    initialPath: initialPath,
    initialBookId: initialBookId,
    initialSettings: settings,
    initialTabs: tabs,
    progressSource: progressSource,
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

/// Whether the control at [key] reports itself selected.
bool _isSelected(WidgetTester tester, String key) =>
    _controlSemantics(tester, key).properties.selected == true;

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

ShadButton _button(WidgetTester tester, String key) =>
    tester.widget<ShadButton>(
      find.descendant(
        of: find.byKey(ValueKey(key)),
        matching: find.byType(ShadButton),
      ),
    );

bool _visible(WidgetTester tester, String key, String viewportKey) {
  final rect = tester.getRect(find.byKey(ValueKey(key)));
  final viewport = tester.getRect(find.byKey(ValueKey(viewportKey)));
  return rect.left >= viewport.left - 0.5 && rect.right <= viewport.right + 0.5;
}

List<ReaderTabPresentation> _manyTabs({int selected = 7}) => [
  for (var index = 0; index < 8; index += 1)
    ReaderTabPresentation(
      id: 'tab-$index',
      title: switch (index) {
        0 => '短い',
        1 => 'The Quiet Cartographer',
        2 => '海辺の図書館 — 失われた書架をめぐる長い旅路',
        _ => 'Tab $index with a deliberately long mixed 見出し label',
      },
      selected: index == selected,
    ),
];

void main() {
  setUpAll(loadHarnessFonts);

  group('header', () {
    testWidgets('shows the live title, truncates it, and keeps it in '
        'semantics', (tester) async {
      _setView(tester, const Size(1280, 800));
      const long =
          'A Field Guide to the Slow Rivers of the Northern '
          'Hemisphere and Their Meanders';
      final bridge = _ChromeBridge(title: long);
      await _open(tester, _reader(bridge: bridge));

      // Wide: 58 characters plus an ellipsis, the full title in semantics.
      final semantics = tester.widget<Semantics>(
        find.byKey(const ValueKey('reader-header-title')),
      );
      expect(semantics.properties.label, long);
      expect(
        find.text('A Field Guide to the Slow Rivers of the Northern Hemisphe…'),
        findsOneWidget,
      );

      // Compact: 24 characters.
      tester.view.physicalSize = const Size(390, 844);
      await tester.pump();
      await tester.pump();
      expect(find.text('A Field Guide to the Sl…'), findsOneWidget);
    });

    testWidgets(
      'actions are disabled without a document and enabled with one',
      (tester) async {
        _setView(tester, const Size(1280, 800));
        final bridge = _ChromeBridge();
        await _open(tester, _reader(bridge: bridge, initialPath: null));

        expect(_button(tester, 'reader-header-contents').enabled, isFalse);
        expect(_button(tester, 'reader-header-typography').enabled, isFalse);
        expect(_button(tester, 'reader-header-more').enabled, isFalse);
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
        expect(_button(tester, 'reader-header-contents').enabled, isTrue);
        expect(_button(tester, 'reader-header-typography').enabled, isTrue);
        expect(_button(tester, 'reader-header-more').enabled, isTrue);
      },
    );

    testWidgets('back leaves the reader through the injected adapter', (
      tester,
    ) async {
      _setView(tester, const Size(1280, 800));
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
        'reader-header-more',
      ]) {
        expect(_button(tester, key).enabled, isTrue, reason: key);
      }
      await tester.tap(find.byKey(const ValueKey('reader-header-more')));
      await tester.pump();
      expect(find.byKey(const ValueKey('reader-panel-more')), findsOneWidget);
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

  group('tab strip', () {
    testWidgets('is hidden without tabs and renders fixture tabs with close '
        'controls', (tester) async {
      _setView(tester, const Size(1280, 800));
      await _open(tester, _reader(bridge: _ChromeBridge()));
      expect(
        find.byKey(const ValueKey('reader-tab-strip-scroll')),
        findsNothing,
      );

      await _open(
        tester,
        _reader(bridge: _ChromeBridge(), tabs: _manyTabs(selected: 0)),
      );
      expect(
        find.byKey(const ValueKey('reader-tab-strip-scroll')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('reader-tab-tab-0')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('reader-tab-close-tab-3')),
        findsOneWidget,
      );
      // Every tab is closable and the close control names its tab.
      expect(
        _controlSemantics(tester, 'reader-tab-close-tab-3').properties.label,
        contains('Tab 3'),
      );
    });

    testWidgets('the selected tab uses the accent token and the others the '
        'muted token', (tester) async {
      _setView(tester, const Size(1280, 800));
      await _open(
        tester,
        _reader(bridge: _ChromeBridge(), tabs: _manyTabs(selected: 0)),
      );

      TextStyle? labelStyle(String key) => tester
          .widget<Text>(
            find
                .descendant(
                  of: find.byKey(ValueKey(key)),
                  matching: find.byType(Text),
                )
                .first,
          )
          .style;

      expect(labelStyle('reader-tab-tab-0')?.color, ShosaiTokens.appAccent);
      expect(labelStyle('reader-tab-tab-1')?.color, ShosaiTokens.appTextMuted);
    });

    testWidgets('activation and close run through rendered controls', (
      tester,
    ) async {
      _setView(tester, const Size(1280, 800));
      await _open(
        tester,
        _reader(bridge: _ChromeBridge(), tabs: _manyTabs(selected: 0)),
      );

      await tester.tap(find.byKey(const ValueKey('reader-tab-tab-2')));
      await tester.pump();
      // The active tab carries the selected semantics state.
      expect(_isSelected(tester, 'reader-tab-tab-2'), isTrue);

      await tester.tap(find.byKey(const ValueKey('reader-tab-close-tab-2')));
      await tester.pump();
      expect(find.byKey(const ValueKey('reader-tab-tab-2')), findsNothing);
      // The successor becomes active and takes focus.
      expect(_isSelected(tester, 'reader-tab-tab-3'), isTrue);
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'reader-tab-label-tab-3',
      );
    });

    testWidgets('Ctrl+W, Ctrl+Tab and Ctrl+1..9 activate and close tabs', (
      tester,
    ) async {
      _setView(tester, const Size(1280, 800));
      await _open(
        tester,
        _reader(bridge: _ChromeBridge(), tabs: _manyTabs(selected: 0)),
      );

      Future<void> chord(LogicalKeyboardKey key) async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(key);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();
      }

      await chord(LogicalKeyboardKey.digit3);
      expect(_isSelected(tester, 'reader-tab-tab-2'), isTrue);

      await chord(LogicalKeyboardKey.tab);
      expect(_isSelected(tester, 'reader-tab-tab-3'), isTrue);

      await chord(LogicalKeyboardKey.keyW);
      expect(find.byKey(const ValueKey('reader-tab-tab-3')), findsNothing);
    });

    testWidgets('one scrollable row with readable widths, active reveal and '
        'keyboard access to offscreen tabs', (tester) async {
      _setView(tester, const Size(1280, 800));
      await _open(
        tester,
        _reader(bridge: _ChromeBridge(), tabs: _manyTabs(selected: 7)),
      );
      await tester.pump();

      // One row: the strip holds a single horizontal scrollable, not a wrap
      // and not an overflow menu. (The reader's bounded chrome rows add
      // scroll regions of their own, so the count is scoped to the strip.)
      expect(
        find.byKey(const ValueKey('reader-tab-strip-scroll')),
        findsOneWidget,
      );
      final stripScrollable = find.descendant(
        of: find.byKey(const ValueKey('reader-tab-strip-scroll')),
        matching: find.byType(Scrollable),
      );
      expect(stripScrollable, findsOneWidget);
      expect(
        tester.widget<Scrollable>(stripScrollable).axisDirection,
        AxisDirection.right,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('reader-tab-strip-scroll')),
          matching: find.byType(Wrap),
        ),
        findsNothing,
      );
      final stripHeight = tester
          .getSize(find.byKey(const ValueKey('reader-tab-strip-scroll')))
          .height;
      expect(stripHeight, lessThan(60));

      // The initially offscreen active tab is revealed fully.
      expect(
        _visible(tester, 'reader-tab-tab-7', 'reader-tab-strip-scroll'),
        isTrue,
      );
      expect(
        _visible(tester, 'reader-tab-close-tab-7', 'reader-tab-strip-scroll'),
        isTrue,
      );

      // Readable widths: a short label keeps the provisional floor, a long one
      // is truncated at 34 characters and is wider than the floor.
      final shortWidth = tester
          .getSize(find.byKey(const ValueKey('reader-tab-tab-0')))
          .width;
      final longWidth = tester
          .getSize(find.byKey(const ValueKey('reader-tab-tab-3')))
          .width;
      expect(shortWidth, greaterThanOrEqualTo(readerTabMinLabelWidth));
      expect(longWidth, greaterThan(readerTabMinLabelWidth));

      // Keyboard activation of an initially offscreen tab reveals it.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      await tester.pump();
      expect(
        _visible(tester, 'reader-tab-tab-0', 'reader-tab-strip-scroll'),
        isTrue,
      );

      // A compact resize re-reveals the active tab.
      tester.view.physicalSize = const Size(390, 844);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 32));
      expect(
        _visible(tester, 'reader-tab-tab-0', 'reader-tab-strip-scroll'),
        isTrue,
      );
    });

    testWidgets('a long active Japanese title is fully revealed at C390 T200', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      const long = '海辺の図書館 — 失われた書架をめぐる長い旅路と、その先にある静かな読書室の記録';
      final bridge = _ChromeBridge(title: long);
      await _open(
        tester,
        _reader(
          bridge: bridge,
          tabs: [
            for (var index = 0; index < 4; index += 1)
              ReaderTabPresentation(
                id: 'tab-$index',
                title: '第$index巻 $long',
                selected: index == 3,
              ),
          ],
        ),
      );

      final strip = tester.getRect(
        find.byKey(const ValueKey('reader-tab-strip-scroll')),
      );
      final label = tester.getRect(
        find.byKey(const ValueKey('reader-tab-tab-3')),
      );
      final close = tester.getRect(
        find.byKey(const ValueKey('reader-tab-close-tab-3')),
      );

      // The complete tab (label + close control) fits the strip viewport, so
      // the active tab and its close control are both fully revealed.
      expect(
        close.right - label.left,
        lessThanOrEqualTo(strip.width + 0.5),
        reason: 'the complete tab must fit the strip viewport',
      );
      expect(
        _visible(tester, 'reader-tab-tab-3', 'reader-tab-strip-scroll'),
        isTrue,
      );
      expect(
        _visible(tester, 'reader-tab-close-tab-3', 'reader-tab-strip-scroll'),
        isTrue,
      );

      // Keyboard activation of an offscreen tab reveals it fully, including its
      // close control.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      await tester.pump();
      expect(
        _visible(tester, 'reader-tab-tab-0', 'reader-tab-strip-scroll'),
        isTrue,
      );
      expect(
        _visible(tester, 'reader-tab-close-tab-0', 'reader-tab-strip-scroll'),
        isTrue,
      );
    });

    testWidgets('every tab and close control is reachable in order', (
      tester,
    ) async {
      _setView(tester, const Size(1280, 800));
      await _open(
        tester,
        _reader(bridge: _ChromeBridge(), tabs: _manyTabs(selected: 0)),
      );

      // Every tab label and close control is focusable and reachable in the
      // strip's own order (label then close, tab by tab).
      final labels = <String>[];
      for (var step = 0; step < 14; step += 1) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        labels.add(FocusManager.instance.primaryFocus?.debugLabel ?? 'none');
      }
      expect(
        labels,
        containsAllInOrder([
          'reader-tab-label-tab-0',
          'reader-tab-close-tab-0',
          'reader-tab-label-tab-1',
          'reader-tab-close-tab-1',
        ]),
      );
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
      expect(find.text('Page 4 · 42%'), findsOneWidget);

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
      expect(find.text('Pages 4–5 · 42%'), findsOneWidget);

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
      expect(find.text('Chapter 3 · 33%'), findsOneWidget);
    });

    testWidgets('the bar is hidden without a document but the text is not', (
      tester,
    ) async {
      _setView(tester, const Size(1280, 800));
      await _open(tester, _reader(bridge: _ChromeBridge(), initialPath: null));
      expect(find.byKey(const ValueKey('reader-progress')), findsOneWidget);
      expect(find.byType(FractionallySizedBox), findsNothing);
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
      expect(find.text('Page 1 · 0%'), findsOneWidget);
    });

    testWidgets('the default source names the retained logical unit', (
      tester,
    ) async {
      _setView(tester, const Size(1280, 800));
      await _open(tester, _reader(bridge: _ChromeBridge()));
      expect(find.text('Chapter 1 · 33%'), findsOneWidget);
    });
  });

  group('edge navigation', () {
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
      expect(find.text('Chapter 2 · 67%'), findsOneWidget);
      expect(_button(tester, 'reader-edge-previous').enabled, isTrue);
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
      expect(find.text('Chapter 1 · 33%'), findsOneWidget);
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

    testWidgets('opening the contents panel reports the content width change', (
      tester,
    ) async {
      _setView(tester, const Size(1280, 800));
      final bridge = _ChromeBridge();
      await _open(tester, _reader(bridge: bridge));
      final before = bridge.reportedWidths.toList();

      await tester.tap(find.byKey(const ValueKey('reader-header-contents')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 32));
      await tester.pump(const Duration(milliseconds: 32));

      expect(bridge.reportedWidths.length, greaterThan(before.length));
      expect(
        bridge.reportedWidths.last,
        lessThan(before.last),
        reason: 'the side panel narrows the content the reporter observes',
      );
    });

    testWidgets('an open modal disables the chrome until it closes', (
      tester,
    ) async {
      _setView(tester, const Size(1280, 800));
      final bridge = _ChromeBridge(books: harnessLibraryBooks());
      await _open(tester, _reader(bridge: bridge, initialBookId: 1));
      expect(_button(tester, 'reader-header-more').enabled, isTrue);

      // The retained bookmark-note control opens the controller-owned modal
      // through a rendered control (contract §3.1 `modalEffect`).
      await tester.tap(find.byKey(const ValueKey('reader-header-more')));
      await tester.pump();
      await tester.tap(find.byTooltip('Bookmark with note'));
      await tester.pumpAndSettle();
      expect(find.byType(ShadDialog), findsOneWidget);
      expect(
        _button(tester, 'reader-header-more').enabled,
        isFalse,
        reason: 'the header gates on the open modal',
      );
      expect(_button(tester, 'reader-header-contents').enabled, isFalse);

      await tester.tap(find.widgetWithText(ShadButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(ShadDialog), findsNothing);
      expect(
        _button(tester, 'reader-header-more').enabled,
        isTrue,
        reason: 'the modal slot is cleared when the dialog closes',
      );
    });

    testWidgets('the wide contents panel keeps edge navigation and width', (
      tester,
    ) async {
      _setView(tester, const Size(1280, 800));
      final bridge = _ChromeBridge();
      await _open(tester, _reader(bridge: bridge));
      final edges = tester.getSize(
        find.byKey(const ValueKey('reader-edge-previous')),
      );
      expect(edges.width, greaterThan(0));

      await tester.tap(find.byKey(const ValueKey('reader-header-contents')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 32));
      await tester.pump(const Duration(milliseconds: 32));

      // The pinned composition keeps the reader surface (and its edges) beside
      // the wide panel; the content the reporter observes loses the panel width
      // and both edge columns, no more.
      expect(
        find.byKey(const ValueKey('reader-edge-previous')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('reader-edge-next')), findsOneWidget);
      expect(
        bridge.reportedWidths.last,
        closeTo(
          1280 - ShosaiTokens.layoutReaderBookmarksPanelWidth - 2 * edges.width,
          1,
        ),
      );
    });

    testWidgets('a long saved note stays inside the contents panel', (
      tester,
    ) async {
      _setView(tester, const Size(1280, 800));
      final bridge = _ChromeBridge(books: harnessLibraryBooks())
        ..bookmarks = [
          FlutterBookmark(
            id: 1,
            bookId: 1,
            unit: BigInt.zero,
            note:
                'A deliberately long saved note that cannot fit the bounded '
                'panel row without ellipsizing, repeated for good measure',
            color: 'yellow',
            createdAt: '2026-09-20T00:00:00Z',
          ),
        ];
      await _open(tester, _reader(bridge: bridge, initialBookId: 1));

      await tester.tap(find.byKey(const ValueKey('reader-header-contents')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 32));

      // No overflow: the retained saved-place row ellipsizes inside the panel.
      expect(tester.takeException(), isNull);
      expect(
        find.textContaining('1: A deliberately long saved note'),
        findsOneWidget,
      );
      expect(find.byTooltip('Bookmark actions'), findsOneWidget);
      final panel = tester.getRect(
        find.byKey(const ValueKey('reader-panel-contents')),
      );
      final row = tester.getRect(
        find.textContaining('1: A deliberately long saved note'),
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
        find.textContaining('1: A deliberately long saved note'),
        findsOneWidget,
      );
      expect(find.byTooltip('Bookmark actions'), findsOneWidget);
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });

    testWidgets('a resize keeps focus in the open panel', (tester) async {
      _setView(tester, const Size(1280, 800));
      final bridge = _ChromeBridge();
      await _open(tester, _reader(bridge: bridge));
      await tester.tap(find.byKey(const ValueKey('reader-header-more')));
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
      expect(find.byKey(const ValueKey('reader-panel-more')), findsNothing);
    });
  });

  group('semantics', () {
    testWidgets('named chrome controls keep a gated activation action', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      _setView(tester, const Size(1280, 800));
      final bridge = _ChromeBridge();
      await _open(
        tester,
        _reader(bridge: bridge, tabs: _manyTabs(selected: 0)),
      );

      for (final key in const [
        'reader-header-back',
        'reader-header-contents',
        'reader-header-typography',
        'reader-header-more',
        'reader-tab-tab-0',
        'reader-tab-close-tab-0',
        'reader-edge-next',
      ]) {
        expect(
          _hasTapAction(tester, key),
          isTrue,
          reason: '$key must be activatable by a screen reader',
        );
      }

      // Activating the semantic action runs the control's intent.
      final more = tester.getSemantics(
        find.byKey(const ValueKey('reader-header-more')),
      );
      // The semantics owner that owns the rendered tree (`RenderView.owner`),
      // the same one the semantics finders use.
      tester.binding.renderViews.first.owner!.semanticsOwner!.performAction(
        more.id,
        SemanticsAction.tap,
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('reader-panel-more')), findsOneWidget);

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

      await tester.tap(find.widgetWithText(ShadButton, 'Highlight 1'));
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
      await _open(tester, _reader(bridge: bridge));

      bridge.failSelectionSurface = true;
      await tester.tap(find.byKey(const ValueKey('reader-edge-next')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 32));
      bridge.failSelectionSurface = false;

      // The bridge reason is visible (kind and message, not
      // "Instance of 'FlutterBridgeError'") and the entry is not labelled as a
      // selection problem.
      final error = find.byKey(const ValueKey('reader-relayout-error'));
      expect(error, findsOneWidget);
      expect(
        find.textContaining('chapter layout rejected (invalidRequest)'),
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
    await tester.pump(const Duration(milliseconds: 32));
    expect(bridge.reportedFontSizes, isNotEmpty);
    // The interface scale must never scale the document font: the reader
    // preference (24) is reported, never the 200% value (48).
    expect(bridge.reportedFontSizes.last, 24);
    expect(bridge.reportedFontSizes, isNot(contains(48)));
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
    final bookmarkEditors = <Completer<String?>>[];
    final controller = ReaderController(
      bridge: bridge,
      decoder: (pixels, {required int width, required int height}) async =>
          _testImage(),
      noteEditor: (_) {
        final completer = Completer<String?>();
        annotationEditors.add(completer);
        return completer.future;
      },
      bookmarkNoteEditor: (_) {
        final completer = Completer<String?>();
        bookmarkEditors.add(completer);
        return completer.future;
      },
      noteEditorCanceller: () {},
    );
    addTearDown(controller.dispose);
    controller.dispatch(const ReaderOpenRequested('/books/x.epub', bookId: 1));
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

    // Suspension clears the owner and advances both counters, so the next
    // bookmark editor's revision (`_bookmarkRevision`) collides with the
    // pending annotation editor's revision (`_noteRevision`).
    controller.dispatch(const ReaderSuspended());
    await pumpEventQueue();
    expect(controller.model.modalEffect, isNull);
    controller.dispatch(const ReaderResumed());
    await pumpEventQueue();

    controller.dispatch(const ReaderBookmarkNoteRequested());
    expect(bookmarkEditors, hasLength(1));
    expect(controller.model.modalEffect, ReaderModalEffect.bookmarkNote);

    // The stale annotation editor finishing must not clear the newer bookmark
    // slot: ownership is the token, not the colliding revision.
    annotationEditors.last.complete('stale');
    await pumpEventQueue();
    expect(
      controller.model.modalEffect,
      ReaderModalEffect.bookmarkNote,
      reason: 'the replacement dialog still owns the modal slot',
    );

    // The replacement is still owned: suspending cancels it and clears it.
    controller.dispatch(const ReaderSuspended());
    await pumpEventQueue();
    expect(controller.model.modalEffect, isNull);
    for (final pending in bookmarkEditors.where((e) => !e.isCompleted)) {
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
        bookmarkNoteEditor: (_) {
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
      controller.dispatch(const ReaderBookmarkNoteRequested());
      expect(editors, hasLength(1));
      expect(controller.model.modalEffect, ReaderModalEffect.bookmarkNote);

      // A relayout while the dialog is open must not clear or replace it.
      controller.dispatch(
        const ReaderViewportChanged(
          ReaderLayout(scale: 1, width: 800, lineSpacing: 1.5),
        ),
      );
      expect(controller.model.modalEffect, ReaderModalEffect.bookmarkNote);

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

  testWidgets('macOS uses the command modifier for the tab shortcuts', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    _setView(tester, const Size(1280, 800));
    await _open(
      tester,
      _reader(bridge: _ChromeBridge(), tabs: _manyTabs(selected: 0)),
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(_isSelected(tester, 'reader-tab-tab-1'), isTrue);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyW);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(find.byKey(const ValueKey('reader-tab-tab-1')), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });
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
