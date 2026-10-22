import 'dart:async';

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shosai_flutter/main.dart';
import 'package:shosai_flutter/core/bridge.dart';
import 'package:shosai_flutter/reader/epub/content.dart' show ReaderEpubPage;
import 'package:shosai_flutter/reader/epub/pages.dart' show TextPageSlice;
import 'package:shosai_flutter/reader/view.dart'
    show ReaderEpubPageContentPainter;
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

FlutterBookmark _bookmark({int id = 1, String? note}) => FlutterBookmark(
  id: id,
  bookId: 1,
  unit: BigInt.zero,
  note: note,
  color: 'yellow',
  createdAt: '2026-09-20T00:00:00Z',
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
      final bridge = _ChromeBridge(books: harnessLibraryBooks())
        ..bookmarks = [_bookmark(id: 1)];
      await _open(tester, _reader(bridge: bridge, initialBookId: 1));
      expect(_button(tester, 'reader-header-typography').enabled, isTrue);

      // The saved-place note control opens the controller-owned modal through
      // a rendered control (contract §3.1 `modalEffect`).
      await tester.tap(find.byKey(const ValueKey('reader-header-notes')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 32));
      await tester.tap(find.byKey(const ValueKey('reader-saved-place-note-1')));
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

    testWidgets('a long saved note stays inside the notes panel', (
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

      await tester.tap(find.byKey(const ValueKey('reader-header-notes')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 32));

      // No overflow: the saved-place card keeps the note inside the panel
      // (the note paragraph ellipsizes).
      expect(tester.takeException(), isNull);
      expect(
        find.textContaining('A deliberately long saved note'),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('reader-saved-place-1')),
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
        find.byKey(const ValueKey('reader-saved-place-1')),
        findsOneWidget,
      );
      tester.platformDispatcher.clearTextScaleFactorTestValue();
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
