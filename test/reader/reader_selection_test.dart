import 'dart:ui' as ui;

import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shosai_flutter/reader/controller.dart' show ReaderPlace;
import 'package:shosai_flutter/reader/view.dart';
import 'package:shosai_flutter/core/bridge.dart';

import '../support/production_shell_harness.dart';
import '../support/selection_surface_fixture.dart';

/// Package 4D: selection actions and annotation menus (row RD-12).
///
/// Selection has no Iced reference (plan decision 8, contract §1 item 6): the
/// authority is RFD 16 plus the retained Flutter implementation, so these tests
/// drive the production surfaces with real pointer and keyboard input and
/// assert the retained actions, gating, focus and dismissal. The selectable
/// surface's endpoints and boundaries are the deterministic fixture in
/// `test/support/selection_surface_fixture.dart`; persistence, copy delivery
/// and the note dialog run through the controller's production paths.
class _SelectionBridge extends HarnessBridge {
  _SelectionBridge({super.unitCount, super.pageWidth, super.pageHeight});

  /// Whether the surface reports a complete Unicode mapping (RFD 16: copying is
  /// unavailable for a geometry-only highlight).
  bool copyEligible = true;

  List<FlutterAnnotation> annotations = const [];
  final List<FlutterAnnotation> created = [];
  final List<String> deleted = [];
  final List<FlutterAnnotation> updated = [];

  /// When set, the next annotation write fails with a bridge error so the
  /// guarded error path can be driven through the rendered surface.
  FlutterBridgeError? failAnnotationWrite;

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
    final base = await super.selectionSurface(
      document: document,
      unit: unit,
      scale: scale,
      width: width,
      fontSize: fontSize,
      lineSpacing: lineSpacing,
      cancellationId: cancellationId,
    );
    return selectionFixtureSurface(base, copyEligible: copyEligible);
  }

  @override
  Future<List<FlutterAnnotation>> listAnnotations({
    required FlutterDocumentHandle document,
    required double scale,
    required BigInt cancellationId,
  }) async => annotations;

  @override
  Future<FlutterAnnotation> createAnnotation({
    required FlutterDocumentHandle document,
    required BigInt unit,
    required BigInt start,
    required BigInt end,
    required double displayScale,
    required FlutterHighlightColor color,
    String? body,
    required BigInt cancellationId,
  }) async {
    if (failAnnotationWrite case final error?) throw error;
    final annotation = FlutterAnnotation(
      id: 'created-${created.length + 1}',
      unit: unit,
      resolution: FlutterAnnotationResolution.exact,
      textRange: FlutterAnnotationTextRange(start: start, end: end),
      color: color,
      body: body,
    );
    created.add(annotation);
    // A store keeps what it created: a relayout lists it again.
    annotations = [...annotations, annotation];
    return annotation;
  }

  @override
  Future<bool> updateAnnotation({
    required FlutterDocumentHandle document,
    required String id,
    required FlutterHighlightColor color,
    String? body,
  }) async {
    if (failAnnotationWrite case final error?) throw error;
    updated.add(
      FlutterAnnotation(
        id: id,
        unit: BigInt.zero,
        resolution: FlutterAnnotationResolution.exact,
        color: color,
        body: body,
      ),
    );
    return true;
  }

  @override
  Future<bool> deleteAnnotation({
    required FlutterDocumentHandle document,
    required String id,
  }) async {
    if (failAnnotationWrite case final error?) throw error;
    deleted.add(id);
    return true;
  }
}

/// PDF fit page (`0`), the reader's default zoom.
const _pdfFitPage = FlutterReaderSettings(
  continuous: false,
  theme: 'light',
  epubFontSize: 18,
  epubLineSpacing: 1.6,
  pdfZoom: 0,
);

/// PDF fit width (`-1` is the reader's fit-width sentinel; `1` would be manual
/// zoom): a fit where the rendered content box can exceed the viewport.
const _pdfFitWidth = FlutterReaderSettings(
  continuous: false,
  theme: 'light',
  epubFontSize: 18,
  epubLineSpacing: 1.6,
  pdfZoom: -1,
);

FlutterAnnotation _annotation({
  String id = 'one',
  int unit = 0,
  FlutterAnnotationResolution resolution = FlutterAnnotationResolution.exact,
  FlutterHighlightColor color = FlutterHighlightColor.yellow,
  String? body,
  int start = 4,
  int end = 9,
}) => FlutterAnnotation(
  id: id,
  unit: BigInt.from(unit),
  resolution: resolution,
  textRange: FlutterAnnotationTextRange(
    start: BigInt.from(start),
    end: BigInt.from(end),
  ),
  color: color,
  body: body,
);

int _readerKeyCounter = 0;

Widget _reader({
  required HarnessBridge bridge,
  String initialPath = '/books/slow-rivers.pdf',
  FlutterReaderSettings settings = _pdfFitPage,
  ReaderPlace? place,
  int? initialBookId,
}) => productionShell(
  locale: const Locale('en'),
  home: ReaderScreen(
    key: ValueKey('selection-reader-${_readerKeyCounter++}'),
    bridge: bridge,
    decoder: (pixels, {required width, required height}) => _testImage(),
    initialPath: initialPath,
    initialSettings: settings.copyWith(zonesHintDismissed: true),
    initialPlace: place,
    initialBookId: initialBookId,
  ),
);

Future<ui.Image> _testImage() async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    const Rect.fromLTWH(0, 0, 420, 560),
    Paint()..color = const Color(0xFFFFFFFF),
  );
  return recorder.endRecording().toImage(420, 560);
}

/// Chooses [action] from note card [id]'s menu, opened by its actions button.
Future<void> _cardAction(WidgetTester tester, String id, String action) async {
  await tester.tap(find.byKey(ValueKey('reader-annotation-$id-actions')));
  await tester.pumpAndSettle();
  await tester.tap(find.text(action).last);
}

/// Opens the Notes panel, where the saved highlights are listed.
Future<void> _openNotes(WidgetTester tester) async {
  if (find.byKey(const ValueKey('reader-panel-notes')).evaluate().isNotEmpty) {
    return;
  }
  await revealReaderChrome(tester);
  await tester.tap(find.byKey(const ValueKey('reader-header-notes')));
  await settleReaderSelection(tester);
}

Future<void> _open(WidgetTester tester, Widget widget) async {
  await tester.pumpWidget(widget);
  for (var round = 0; round < 8; round += 1) {
    await tester.pump(const Duration(milliseconds: 32));
    final painted = find
        .byKey(const ValueKey('reader-page-paint'))
        .evaluate()
        .isNotEmpty;
    final selectable = find
        .byKey(const ValueKey('reader-selection-surface'))
        .evaluate()
        .isNotEmpty;
    if (painted && selectable) break;
  }
  await tester.pump(const Duration(milliseconds: 32));
}

/// Turns past the PDF's cover, which a spread shows alone, to the spread of
/// its second and third pages.
Future<void> _turnToSpread(WidgetTester tester) async {
  await revealReaderChrome(tester);
  await tester.tap(find.byKey(const ValueKey('reader-edge-next')));
  await tester.pump();
  for (var round = 0; round < 4; round += 1) {
    await tester.pump(const Duration(milliseconds: 32));
  }
}

void _setView(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// The rendered button behind a label.
ShadButton _button(WidgetTester tester, Finder label) {
  final button = find.ancestor(of: label, matching: find.byType(ShadButton));
  expect(button, findsWidgets, reason: 'the label is inside a button');
  return tester.widget<ShadButton>(button.first);
}

/// Whether the button behind [label] is gated off (no activation callback).
bool _disabled(WidgetTester tester, Finder label) =>
    _button(tester, label).onPressed == null;

void main() {
  setUpAll(loadHarnessFonts);

  group('selection actions', () {
    testWidgets('a mouse drag selects text and opens the action surface', (
      tester,
    ) async {
      _setView(tester, const Size(1280, 800));
      await _open(tester, _reader(bridge: _SelectionBridge()));

      expect(find.byKey(const ValueKey('selection-actions')), findsNothing);
      await dragFixtureSelection(tester, from: 4, to: 12);
      await settleReaderSelection(tester);

      expect(find.byKey(const ValueKey('selection-actions')), findsOneWidget);
      // Every retained action is rendered: Copy, the five RFD 16 colors,
      // Add note and Cancel.
      for (final label in const [
        'Copy',
        'Yellow',
        'Green',
        'Blue',
        'Pink',
        'Purple',
        'Add note',
        'Cancel',
      ]) {
        expect(
          find.text(label),
          findsOneWidget,
          reason: 'the selection surface renders the $label action',
        );
      }
      // The surface's accessible name is localized, not hardcoded.
      expect(
        tester
            .widget<Semantics>(find.byKey(const ValueKey('selection-actions')))
            .properties
            .label,
        'Selection actions',
      );
    });

    testWidgets('a highlight made while All books shows lists it again', (
      tester,
    ) async {
      _setView(tester, const Size(1280, 800));
      final bridge = _SelectionBridge();
      await _open(
        tester,
        _reader(
          bridge: bridge,
          initialPath: '/books/slow-rivers.pdf',
          initialBookId: 1,
        ),
      );
      await _openNotes(tester);
      await tester.tap(find.byKey(const ValueKey('reader-notes-all-books')));
      await settleReaderSelection(tester);
      expect(bridge.libraryNotesCalls, 1);

      await dragFixtureSelection(tester, from: 4, to: 12);
      await settleReaderSelection(tester);
      await tester.tap(find.text('Yellow'));
      await settleReaderSelection(tester);
      expect(bridge.created, hasLength(1));
      expect(bridge.libraryNotesCalls, 2);
    });

    testWidgets('a PDF opened at a search match selects it', (tester) async {
      _setView(tester, const Size(1280, 800));
      await _open(
        tester,
        _reader(
          bridge: _SelectionBridge(),
          place: const ReaderPlace(0, offset: 4, length: 8),
        ),
      );
      await settleReaderSelection(tester);

      final status = tester
          .getSemantics(find.byKey(const ValueKey('reader-selection-status')))
          .getSemanticsData()
          .label;
      expect(status, startsWith('Selected text:'));
      expect(find.byKey(const ValueKey('selection-actions')), findsOneWidget);
    });

    testWidgets('Copy is enabled only for a copy-eligible surface', (
      tester,
    ) async {
      _setView(tester, const Size(1280, 800));
      final bridge = _SelectionBridge()..copyEligible = false;
      await _open(tester, _reader(bridge: bridge));
      await dragFixtureSelection(tester, from: 4, to: 12);
      await settleReaderSelection(tester);

      expect(find.byKey(const ValueKey('selection-actions')), findsOneWidget);
      expect(
        _disabled(tester, find.text('Copy')),
        isTrue,
        reason: 'a geometry-only surface cannot copy (RFD 16)',
      );
      // The persistence actions stay enabled: the highlight is still available.
      expect(_disabled(tester, find.text('Yellow')), isFalse);
      expect(_disabled(tester, find.text('Add note')), isFalse);
      // A disabled Copy action is inert.
      await tester.tap(find.text('Copy'));
      await settleReaderSelection(tester);
      expect(find.byKey(const ValueKey('selection-actions')), findsOneWidget);
    });

    testWidgets('Copy delivers the selected text through the copier', (
      tester,
    ) async {
      _setView(tester, const Size(1280, 800));
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      await _open(tester, _reader(bridge: _SelectionBridge()));
      await dragFixtureSelection(tester, from: 4, to: 12);
      await settleReaderSelection(tester);
      await tester.tap(find.text('Copy'));
      await settleReaderSelection(tester);

      expect(copied, ['river ru']);
    });

    testWidgets(
      'a highlight on a spread\'s second page is saved on that page',
      (tester) async {
        _setView(tester, const Size(1280, 800));
        final bridge = _SelectionBridge(unitCount: 3);
        await _open(tester, _reader(bridge: bridge));
        await _turnToSpread(tester);
        expect(find.textContaining('pages 2–3 of 3'), findsOneWidget);

        // The second page's text follows the first page's and a line break.
        final shift = selectionFixtureText.runes.length + 1;
        await dragReaderSelectionBetween(
          tester,
          renderedEndpointCenter(tester, shift + 4),
          renderedEndpointCenter(tester, shift + 12),
        );
        await settleReaderSelection(tester);
        await tester.tap(find.text('Yellow'));
        await settleReaderSelection(tester);

        final created = bridge.created.single;
        expect(created.unit.toInt(), 2);
        expect(created.textRange!.start.toInt(), 4);
        expect(created.textRange!.end.toInt(), 12);
      },
    );

    testWidgets('a selection stays on the spread page it started on', (
      tester,
    ) async {
      _setView(tester, const Size(1280, 800));
      final bridge = _SelectionBridge(unitCount: 3);
      await _open(tester, _reader(bridge: bridge));
      await _turnToSpread(tester);

      final shift = selectionFixtureText.runes.length + 1;
      await dragReaderSelectionBetween(
        tester,
        renderedEndpointCenter(tester, 40),
        renderedEndpointCenter(tester, shift + 12),
      );
      await settleReaderSelection(tester);
      await tester.tap(find.text('Yellow'));
      await settleReaderSelection(tester);

      final created = bridge.created.single;
      expect(created.unit.toInt(), 1);
      expect(created.textRange!.start.toInt(), 40);
      expect(
        created.textRange!.end.toInt(),
        selectionFixtureText.runes.length,
        reason: "the selection ends at the first page's last character",
      );
    });

    testWidgets('each of the five colors commits the selected range', (
      tester,
    ) async {
      _setView(tester, const Size(1280, 800));
      for (final (label, color) in const [
        ('Yellow', FlutterHighlightColor.yellow),
        ('Green', FlutterHighlightColor.green),
        ('Blue', FlutterHighlightColor.blue),
        ('Pink', FlutterHighlightColor.pink),
        ('Purple', FlutterHighlightColor.purple),
      ]) {
        final bridge = _SelectionBridge();
        await _open(tester, _reader(bridge: bridge));
        await dragFixtureSelection(tester, from: 4, to: 12);
        await settleReaderSelection(tester);
        await tester.tap(find.text(label));
        await settleReaderSelection(tester);

        expect(
          bridge.created.single.color,
          color,
          reason: '$label commits its own RFD 16 color',
        );
        expect(bridge.created.single.textRange!.start.toInt(), 4);
        expect(bridge.created.single.textRange!.end.toInt(), 12);
        // The commit leaves the action surface; the notes panel lists the
        // highlight.
        expect(find.byKey(const ValueKey('selection-actions')), findsNothing);
        await _openNotes(tester);
        expect(find.text('1 note'), findsOneWidget);
      }
    });

    testWidgets('Enter commits the selection and Escape cancels it', (
      tester,
    ) async {
      _setView(tester, const Size(1280, 800));
      final bridge = _SelectionBridge();
      await _open(tester, _reader(bridge: bridge));

      await dragFixtureSelection(tester, from: 4, to: 12);
      await settleReaderSelection(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settleReaderSelection(tester);
      expect(bridge.created.single.color, FlutterHighlightColor.yellow);
      expect(bridge.created.single.textRange!.start.toInt(), 4);

      await dragFixtureSelection(tester, from: 20, to: 26);
      await settleReaderSelection(tester);
      expect(find.byKey(const ValueKey('selection-actions')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settleReaderSelection(tester);
      expect(find.byKey(const ValueKey('selection-actions')), findsNothing);
      expect(
        bridge.created,
        hasLength(1),
        reason: 'cancelling a selection creates no highlight',
      );
    });

    testWidgets('Shift+arrows extend the selection before it is committed', (
      tester,
    ) async {
      _setView(tester, const Size(1280, 800));
      final bridge = _SelectionBridge();
      await _open(tester, _reader(bridge: bridge));

      await dragFixtureSelection(tester, from: 4, to: 8);
      await settleReaderSelection(tester);
      // Shift+Right extends the focus one grapheme at a time.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await settleReaderSelection(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settleReaderSelection(tester);

      expect(bridge.created.single.textRange!.start.toInt(), 4);
      expect(
        bridge.created.single.textRange!.end.toInt(),
        10,
        reason: 'two Shift+Right presses extend the focus by two graphemes',
      );
    });

    testWidgets('Shift+arrows do not page the document', (tester) async {
      _setView(tester, const Size(1280, 800));
      final bridge = _SelectionBridge(unitCount: 4);
      await _open(tester, _reader(bridge: bridge));
      await dragFixtureSelection(tester, from: 4, to: 8);
      await settleReaderSelection(tester);

      final surfaceCalls = bridge.surfaceCalls;
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await settleReaderSelection(tester);
      expect(
        bridge.surfaceCalls,
        surfaceCalls,
        reason: 'selection extension must not request another unit layout',
      );
      expect(
        tester
            .widget<Semantics>(
              find.byKey(const ValueKey('reader-document-semantics')),
            )
            .properties
            .label,
        contains('page 1 of 4'),
      );
    });

    testWidgets('selection menu pins visible chrome and retains F10 focus', (
      tester,
    ) async {
      _setView(tester, const Size(1280, 800));
      await _open(tester, _reader(bridge: _SelectionBridge()));
      final mouse = await tester.createGesture(
        kind: ui.PointerDeviceKind.mouse,
      );
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(
        tester.getCenter(find.byKey(const ValueKey('reader-stage'))),
      );
      await tester.pump(const Duration(milliseconds: 180));
      await dragFixtureSelection(tester, from: 4, to: 12);
      await settleReaderSelection(tester);
      expect(find.byKey(const ValueKey('selection-actions')), findsOneWidget);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.f10);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await settleReaderSelection(tester);
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      await mouse.moveTo(const Offset(-1, -1));
      await tester.pump(const Duration(milliseconds: 180));
      expect(
        find.byKey(const ValueKey('reader-header-contents')).hitTestable(),
        findsOneWidget,
      );
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'selection actions',
        reason: 'Shift+F10 opens the actions and focuses the first action',
      );

      // Escape dismisses the surface from inside it and returns focus to the
      // document surface.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settleReaderSelection(tester);
      expect(find.byKey(const ValueKey('selection-actions')), findsNothing);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'reader surface');
    });

    testWidgets('keyboard selection does not reveal hidden chrome', (
      tester,
    ) async {
      _setView(tester, const Size(1280, 800));
      await _open(tester, _reader(bridge: _SelectionBridge()));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.f10);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await settleReaderSelection(tester);
      await tester.pump(const Duration(seconds: 3));
      expect(find.byKey(const ValueKey('selection-actions')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('reader-header-contents')).hitTestable(),
        findsNothing,
      );
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'selection actions',
      );
    });

    testWidgets(
      'height-constrained selection actions remain touch-scrollable',
      (tester) async {
        _setView(tester, const Size(320, 140));
        await _open(tester, _reader(bridge: _SelectionBridge()));
        await dragFixtureSelection(tester, from: 4, to: 12);
        await settleReaderSelection(tester);
        final menu = find.byKey(const ValueKey('selection-actions'));
        final scroll = tester
            .state<ScrollableState>(
              find
                  .descendant(of: menu, matching: find.byType(Scrollable))
                  .first,
            )
            .position;
        expect(scroll.maxScrollExtent, greaterThan(0));
        expect(scroll.pixels, 0);
        await tester.drag(menu, const Offset(0, -80));
        await tester.pumpAndSettle();
        expect(scroll.pixels, greaterThan(0));
        await tester.drag(menu, const Offset(0, 120));
        await tester.pumpAndSettle();
        expect(scroll.pixels, 0);
      },
    );

    testWidgets('the context-menu key opens the actions', (tester) async {
      _setView(tester, const Size(1280, 800));
      await _open(tester, _reader(bridge: _SelectionBridge()));
      await dragFixtureSelection(tester, from: 4, to: 12);
      await settleReaderSelection(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
      await settleReaderSelection(tester);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'selection actions',
      );
    });

    testWidgets('the arrows move between the actions without turning the '
        'page', (tester) async {
      _setView(tester, const Size(1280, 800));
      await _open(tester, _reader(bridge: _SelectionBridge(unitCount: 4)));
      await dragFixtureSelection(tester, from: 4, to: 12);
      await settleReaderSelection(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
      await settleReaderSelection(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await settleReaderSelection(tester);
      expect(find.byKey(const ValueKey('selection-actions')), findsOneWidget);
      expect(
        tester
            .widget<Semantics>(
              find.byKey(const ValueKey('reader-document-semantics')),
            )
            .properties
            .label,
        contains('page 1 of 4'),
      );
    });

    testWidgets('the screen-reader select action opens the actions', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      _setView(tester, const Size(1280, 800));
      await _open(tester, _reader(bridge: _SelectionBridge()));

      final node = tester.getSemantics(
        find.byKey(const ValueKey('reader-content-semantics')),
      );
      tester.binding.renderViews.first.owner!.semanticsOwner!.performAction(
        node.id,
        SemanticsAction.tap,
      );
      await settleReaderSelection(tester);

      expect(find.byKey(const ValueKey('selection-actions')), findsOneWidget);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'selection actions',
        reason: 'the controller asks for the action surface after the request',
      );
      semantics.dispose();
    });

    testWidgets('a press outside the selection dismisses the surface', (
      tester,
    ) async {
      _setView(tester, const Size(1280, 800));
      final bridge = _SelectionBridge();
      await _open(tester, _reader(bridge: bridge));
      await dragFixtureSelection(tester, from: 4, to: 12);
      await settleReaderSelection(tester);
      expect(find.byKey(const ValueKey('selection-actions')), findsOneWidget);

      // A press outside the selected range cancels the selection (retained
      // behavior); the surface is gone and no highlight was created.
      await tester.tapAt(const Offset(30, 300));
      await settleReaderSelection(tester);
      expect(find.byKey(const ValueKey('selection-actions')), findsNothing);
      expect(bridge.created, isEmpty);
    });

    testWidgets('the action surface stays inside the viewport', (tester) async {
      _setView(tester, const Size(390, 844));
      await _open(tester, _reader(bridge: _SelectionBridge()));
      // A range on the first line: the surface prefers to sit above it, and the
      // clamp keeps it fully inside the document area.
      await dragFixtureSelection(tester, from: 0, to: 6);
      await settleReaderSelection(tester);
      final rect = tester.getRect(
        find.byKey(const ValueKey('selection-actions')),
      );
      final document = tester.getRect(
        find.byKey(const ValueKey('reader-selection-surface')),
      );
      expect(rect.left, greaterThanOrEqualTo(document.left));
      expect(rect.right, lessThanOrEqualTo(document.right + 0.5));
      expect(rect.top, greaterThanOrEqualTo(document.top));
      expect(rect.bottom, lessThanOrEqualTo(document.bottom + 0.5));
    });

    testWidgets('the surface follows the range in a PDF fit-width view', (
      tester,
    ) async {
      _setView(tester, const Size(390, 844));
      await _open(
        tester,
        _reader(
          bridge: _SelectionBridge(pageWidth: 336, pageHeight: 1200),
          initialPath: '/books/atlas.pdf',
          settings: _pdfFitWidth,
        ),
      );
      await dragFixtureSelection(tester, from: 4, to: 14);
      await settleReaderSelection(tester);

      final surface = tester.getRect(
        find.byKey(const ValueKey('selection-actions')),
      );
      final range = renderedFixtureOffset(tester, 4);
      // The fixture range is well inside the page: the surface must be near the
      // range, not pinned to the top of the viewport.
      expect(
        surface.top,
        greaterThan(8),
        reason: 'the surface is not pinned to the viewport top',
      );
      expect(surface.top, lessThan(range.dy));
      expect(range.dy - surface.bottom, lessThan(60));
    });

    // The scroll fixtures size their page to the 390 px phone's document pane
    // (336 px), so the fit-width page is the one these scroll offsets were
    // measured against.
    testWidgets('the surface follows the range when the content scrolls', (
      tester,
    ) async {
      _setView(tester, const Size(390, 844));
      await _open(
        tester,
        _reader(
          bridge: _SelectionBridge(pageWidth: 336, pageHeight: 1200),
          initialPath: '/books/atlas.pdf',
          settings: _pdfFitWidth,
        ),
      );
      await dragFixtureSelection(tester, from: 4, to: 14);
      await settleReaderSelection(tester);
      final surfaceBefore = tester.getRect(
        find.byKey(const ValueKey('selection-actions')),
      );
      final rangeBefore = renderedFixtureOffset(tester, 4);

      // A pointer drag on the surface would start a new selection, so the
      // scroll input is the wheel: it changes the content transform without
      // rebuilding the document view.
      final pointer = TestPointer(1, ui.PointerDeviceKind.mouse);
      pointer.hover(
        tester.getCenter(
          find.byKey(const ValueKey('reader-selection-surface')),
        ),
      );
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, 120)));
      await settleReaderSelection(tester);

      final surfaceAfter = tester.getRect(
        find.byKey(const ValueKey('selection-actions')),
      );
      final rangeAfter = renderedFixtureOffset(tester, 4);
      final rangeMoved = rangeAfter.dy - rangeBefore.dy;
      expect(
        rangeMoved,
        lessThan(-40),
        reason: 'the wheel scrolled the content up (moved $rangeMoved)',
      );
      expect(
        surfaceAfter.top - surfaceBefore.top,
        closeTo(rangeMoved, 6),
        reason: 'the action surface followed the scrolled range',
      );
      final viewport = tester.getRect(
        find.byKey(const ValueKey('reader-document-semantics')),
      );
      expect(surfaceAfter.top, greaterThanOrEqualTo(viewport.top - 0.5));
      expect(surfaceAfter.bottom, lessThanOrEqualTo(viewport.bottom + 0.5));
    });

    testWidgets('the surface follows the range when a resize clamps the scroll', (
      tester,
    ) async {
      // A page only slightly taller than the viewport, so a selected range stays
      // visible at the scroll's end and the clamp is observable. Leave enough
      // width beside the 44px edges for the toolbar to stay on the same side
      // of the range; a narrower toolbar can legitimately flip above it.
      _setView(tester, const Size(430, 500));
      await _open(
        tester,
        _reader(
          bridge: _SelectionBridge(pageWidth: 336, pageHeight: 700),
          initialPath: '/books/atlas.pdf',
          settings: _pdfFitWidth,
        ),
      );
      final pointer = TestPointer(1, ui.PointerDeviceKind.mouse);
      pointer.hover(
        tester.getCenter(
          find.byKey(const ValueKey('reader-selection-surface')),
        ),
      );
      // Scroll to the end of the content, then select a range that stays
      // visible there.
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, 400)));
      await settleReaderSelection(tester);
      await dragFixtureSelection(tester, from: 18, to: 30);
      await settleReaderSelection(tester);
      final surfaceBefore = tester.getRect(
        find.byKey(const ValueKey('selection-actions')),
      );
      final rangeBefore = renderedFixtureOffset(tester, 18);

      // Growing the viewport height reduces the maximum scroll offset, so the
      // layout clamps it: the content (and the range) moves without a scroll
      // update notification, and the overlay must re-read the geometry.
      tester.view.physicalSize = const Size(430, 620);
      await settleReaderSelection(tester, rounds: 8);
      final surfaceAfter = tester.getRect(
        find.byKey(const ValueKey('selection-actions')),
      );
      final rangeAfter = renderedFixtureOffset(tester, 18);
      expect(
        rangeAfter.dy - rangeBefore.dy,
        greaterThan(20),
        reason: 'the resize clamped the scroll offset and moved the range',
      );
      expect(
        surfaceAfter.top - surfaceBefore.top,
        closeTo(rangeAfter.dy - rangeBefore.dy, 8),
        reason: 'the action surface followed the range across the resize',
      );
      final viewport = tester.getRect(
        find.byKey(const ValueKey('reader-document-semantics')),
      );
      expect(surfaceAfter.top, greaterThanOrEqualTo(viewport.top - 0.5));
      expect(surfaceAfter.bottom, lessThanOrEqualTo(viewport.bottom + 0.5));
    });
  });

  group('selection notes', () {
    testWidgets(
      'Add note opens the editor and commits the note with the range',
      (tester) async {
        _setView(tester, const Size(1280, 800));
        final bridge = _SelectionBridge();
        await _open(tester, _reader(bridge: bridge));
        await dragFixtureSelection(tester, from: 4, to: 12);
        await settleReaderSelection(tester);
        await tester.tap(find.text('Add note'));
        await tester.pumpAndSettle();

        expect(find.byType(ShadDialog), findsOneWidget);
        expect(find.text('Highlight note'), findsOneWidget);
        await tester.enterText(
          find.descendant(
            of: find.byType(ShadDialog),
            matching: find.byType(ShadInput),
          ),
          'the survey notes',
        );
        await tester.tap(find.widgetWithText(ShadButton, 'Save'));
        await tester.pumpAndSettle();

        expect(bridge.created.single.body, 'the survey notes');
        expect(bridge.created.single.color, FlutterHighlightColor.yellow);
        expect(bridge.created.single.textRange!.start.toInt(), 4);
        expect(bridge.created.single.textRange!.end.toInt(), 12);
      },
    );

    testWidgets('cancelling the note editor creates no highlight', (
      tester,
    ) async {
      _setView(tester, const Size(1280, 800));
      final bridge = _SelectionBridge();
      await _open(tester, _reader(bridge: bridge));
      await dragFixtureSelection(tester, from: 4, to: 12);
      await settleReaderSelection(tester);
      await tester.tap(find.text('Add note'));
      await tester.pumpAndSettle();

      await tester.tap(
        find.descendant(
          of: find.byType(ShadDialog),
          matching: find.widgetWithText(ShadButton, 'Cancel'),
        ),
      );
      await tester.pumpAndSettle();

      expect(bridge.created, isEmpty);
      // The retained behavior keeps the selection: cancelling the editor
      // returns to the action surface instead of discarding the range.
      expect(find.byKey(const ValueKey('selection-actions')), findsOneWidget);
    });

    testWidgets('a failed commit reports through the selection live region', (
      tester,
    ) async {
      _setView(tester, const Size(1280, 800));
      final bridge = _SelectionBridge()
        ..failAnnotationWrite = const FlutterBridgeError(
          kind: FlutterBridgeErrorKind.invalidRequest,
          message: 'annotation store unavailable',
        );
      await _open(tester, _reader(bridge: bridge));
      await dragFixtureSelection(tester, from: 4, to: 12);
      await settleReaderSelection(tester);
      await tester.tap(find.text('Yellow'));
      await settleReaderSelection(tester);

      expect(bridge.created, isEmpty);
      expect(
        find.textContaining(
          'Selection action failed: annotation store unavailable',
        ),
        findsOneWidget,
        reason: 'the bridge reason reaches the selection error surface',
      );
    });
  });

  group('annotation actions', () {
    testWidgets(
      'navigation, recolor, note and delete run from the notes panel',
      (tester) async {
        _setView(tester, const Size(1280, 800));
        final bridge = _SelectionBridge()
          ..annotations = [
            _annotation(
              id: 'one',
              color: FlutterHighlightColor.yellow,
              body: 'old note',
            ),
          ];
        await _open(tester, _reader(bridge: bridge));
        await _openNotes(tester);

        expect(find.byKey(const ValueKey('reader-annotation-one')), findsOne);
        expect(find.text('old note'), findsOneWidget);

        // Recolor cycles yellow -> green and keeps the note.
        await _cardAction(tester, 'one', 'Change color');
        await settleReaderSelection(tester);
        expect(bridge.updated.single.color, FlutterHighlightColor.green);
        expect(bridge.updated.single.body, 'old note');

        // Choosing the card selects the range and focuses the surface.
        await tester.tap(
          find.byKey(const ValueKey('reader-annotation-one-open')),
        );
        await settleReaderSelection(tester);
        expect(
          FocusManager.instance.primaryFocus?.debugLabel,
          'reader surface',
        );

        // Delete removes the highlight.
        await _cardAction(tester, 'one', 'Delete highlight');
        await settleReaderSelection(tester);
        expect(bridge.deleted, ['one']);
        expect(
          find.byKey(const ValueKey('reader-annotation-one')),
          findsNothing,
        );
      },
    );

    testWidgets('the note is edited in place with Save and Cancel', (
      tester,
    ) async {
      _setView(tester, const Size(1280, 800));
      final bridge = _SelectionBridge()
        ..annotations = [_annotation(id: 'one', body: 'old note')];
      await _open(tester, _reader(bridge: bridge));
      await _openNotes(tester);
      final field = find.byKey(const ValueKey('reader-note-edit-field'));

      await _cardAction(tester, 'one', 'Edit note');
      await tester.pumpAndSettle();
      expect(find.byType(ShadDialog), findsNothing);
      expect(tester.widget<ShadInput>(field).controller!.text, 'old note');
      await tester.enterText(field, 'discarded');
      await tester.tap(find.byKey(const ValueKey('reader-note-edit-cancel')));
      await tester.pumpAndSettle();
      expect(field, findsNothing);
      expect(find.text('old note'), findsOneWidget);
      expect(bridge.updated, isEmpty);

      await _cardAction(tester, 'one', 'Edit note');
      await tester.pumpAndSettle();
      await tester.enterText(field, 'revised note');
      await tester.tap(find.byKey(const ValueKey('reader-note-edit-save')));
      await settleReaderSelection(tester);
      expect(bridge.updated.single.body, 'revised note');
      expect(bridge.updated.single.color, FlutterHighlightColor.yellow);
    });

    testWidgets('a draft change made before a rebuild is kept', (tester) async {
      _setView(tester, const Size(1280, 800));
      final bridge = _SelectionBridge()
        ..annotations = [_annotation(id: 'one', body: 'old note')];
      await _open(tester, _reader(bridge: bridge));
      await _openNotes(tester);
      await _cardAction(tester, 'one', 'Edit note');
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('reader-note-edit-field'));
      await tester.enterText(field, 'A');
      await tester.pump();

      // Two changes before the card is built again: away and back.
      final draft = tester.widget<ShadInput>(field).controller!;
      draft.text = 'B';
      draft.value = const TextEditingValue(
        text: 'A',
        selection: TextSelection.collapsed(offset: 1),
        composing: TextRange(start: 0, end: 1),
      );
      await tester.pump();

      expect(draft.text, 'A');
      expect(draft.value.composing, const TextRange(start: 0, end: 1));
    });

    testWidgets('a secondary click opens the card menu', (tester) async {
      _setView(tester, const Size(1280, 800));
      final bridge = _SelectionBridge()..annotations = [_annotation(id: 'one')];
      await _open(tester, _reader(bridge: bridge));
      await _openNotes(tester);

      await tester.tapAt(
        tester.getCenter(find.byKey(const ValueKey('reader-annotation-one'))),
        buttons: kSecondaryMouseButton,
        kind: ui.PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();

      for (final label in const [
        'Add note',
        'Change color',
        'Delete highlight',
      ]) {
        expect(find.text(label), findsOneWidget);
      }

      await tester.tap(find.text('Change color'));
      await settleReaderSelection(tester);
      expect(bridge.updated.single.color, FlutterHighlightColor.green);
    });

    testWidgets('Shift+F10 opens the same menu from the keyboard', (
      tester,
    ) async {
      _setView(tester, const Size(1280, 800));
      final bridge = _SelectionBridge()..annotations = [_annotation(id: 'one')];
      await _open(tester, _reader(bridge: bridge));
      await _openNotes(tester);

      // Focus the card through the rendered tree, then use the keyboard
      // equivalent of a secondary click.
      Focus.of(
        tester.element(
          find
              .descendant(
                of: find.byKey(const ValueKey('reader-annotation-one-open')),
                matching: find.byType(Padding),
              )
              .first,
        ),
      ).requestFocus();
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus,
        isNotNull,
        reason: 'the card can take focus',
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.f10);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();

      expect(find.text('Change color'), findsOneWidget);
      await tester.tap(find.text('Delete highlight'));
      await settleReaderSelection(tester);
      expect(bridge.deleted, ['one']);
    });

    testWidgets('a card keeps its annotation when an earlier one is deleted', (
      tester,
    ) async {
      _setView(tester, const Size(1280, 800));
      final bridge = _SelectionBridge()
        ..annotations = [
          _annotation(id: 'one'),
          _annotation(id: 'two', color: FlutterHighlightColor.green),
          _annotation(id: 'three', color: FlutterHighlightColor.blue),
        ];
      await _open(tester, _reader(bridge: bridge));
      await _openNotes(tester);

      // The cards are keyed by annotation id, so after the first is deleted
      // the second card still acts on 'two' rather than on whichever
      // annotation lands in its list position.
      await _cardAction(tester, 'one', 'Delete highlight');
      await settleReaderSelection(tester);
      expect(bridge.deleted, ['one']);

      await _cardAction(tester, 'two', 'Change color');
      await settleReaderSelection(tester);
      expect(
        bridge.updated.single.id,
        'two',
        reason: 'the menu acts on the annotation it was opened for',
      );
      expect(bridge.updated.single.color, FlutterHighlightColor.blue);
    });

    testWidgets('a failed annotation write reports through the live region', (
      tester,
    ) async {
      _setView(tester, const Size(1280, 800));
      final bridge = _SelectionBridge()
        ..annotations = [_annotation(id: 'one')]
        ..failAnnotationWrite = const FlutterBridgeError(
          kind: FlutterBridgeErrorKind.invalidRequest,
          message: 'highlight write rejected',
        );
      await _open(tester, _reader(bridge: bridge));
      await _openNotes(tester);
      await _cardAction(tester, 'one', 'Delete highlight');
      await settleReaderSelection(tester);

      expect(bridge.deleted, isEmpty);
      expect(
        find.textContaining(
          'Highlight action failed: highlight write rejected',
        ),
        findsOneWidget,
      );
    });
  });
}
