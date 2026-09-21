import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shosai_flutter/app_theme.dart';
import 'package:shosai_flutter/library/view.dart';
import 'package:shosai_flutter/src/rust/api.dart';

/// The desktop import path has no adapter above the native picker, so the
/// file-selector channel is the platform boundary these tests stub.
const _pickerChannel = MethodChannel('plugins.flutter.io/file_selector');

/// The two desktop choices and the picker request each one must produce.
const _choices = [
  (title: 'Choose files', pickerCall: 'openFile'),
  (title: 'Choose a folder', pickerCall: 'getDirectoryPath'),
];

class _Bridge implements FlutterBridge {
  @override
  bool get isDisposed => false;
  @override
  void dispose() {}
  @override
  BigInt createCancellation() => BigInt.one;
  @override
  bool cancel({required BigInt id}) => true;
  @override
  bool releaseCancellation({required BigInt id}) => true;
  @override
  Future<FlutterLibraryPage> libraryPage({
    String? query,
    FlutterBookFormat? format,
    required int limit,
    required int offset,
    required BigInt cancellationId,
  }) async => const FlutterLibraryPage(books: [], hasMore: false);
  @override
  Future<FlutterReaderSettings> loadReaderSettings({
    required BigInt cancellationId,
  }) async => const FlutterReaderSettings(
    continuous: false,
    theme: 'light',
    epubFontSize: 18,
    epubLineSpacing: 1.5,
    pdfZoom: 0,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Counts route pops so a test can tell one activation from two.
class _PopCounter extends NavigatorObserver {
  int pops = 0;

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pops += 1;
    super.didPop(route, previousRoute);
  }
}

/// Records native picker requests so a duplicate activation is observable.
class _PickerStub {
  _PickerStub(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      _pickerChannel,
      (call) async {
        calls.add(call.method);
        return switch (call.method) {
          'openFile' => const <String>[],
          _ => null,
        };
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        _pickerChannel,
        null,
      ),
    );
  }

  final List<String> calls = [];
}

Future<void> _pumpShell(
  WidgetTester tester, {
  NavigatorObserver? observer,
}) async {
  await tester.pumpWidget(
    ShadApp(
      theme: shosaiShadTheme(Brightness.light),
      navigatorObservers: [?observer],
      home: ProductShell(
        bridgeFactory: () => _Bridge(),
        readerBuilder: (_, _, _, _, _, _) => const SizedBox(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openAddBooks(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(ShadButton, 'Add books'));
  // The import effect stays pending while the picker is open, so settle is
  // not available; pump the dialog entrance instead.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

/// Tabs forward until [title]'s choice owns focus.
Future<void> _tabToChoice(WidgetTester tester, String title) async {
  for (var step = 0; step < _choices.length + 2; step += 1) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    if (_isFocused(tester, title)) return;
  }
  fail('focus never reached $title');
}

bool _isFocused(WidgetTester tester, String title) =>
    tester
        .getSemantics(find.text(title))
        .getSemanticsData()
        .flagsCollection
        .isFocused ==
    ui.Tristate.isTrue;

/// The focus ring painted over [title]'s choice, or null when it is unfocused.
BoxDecoration? _ringOn(WidgetTester tester, String title) {
  final containers = find.ancestor(
    of: find.text(title),
    matching: find.byWidgetPredicate(
      (widget) => widget is Container && widget.foregroundDecoration != null,
    ),
  );
  if (containers.evaluate().isEmpty) return null;
  return tester.widget<Container>(containers.first).foregroundDecoration
      as BoxDecoration;
}

/// The ring the focused choice paints, taken from the production theme.
BoxDecoration _focusedRing() {
  final theme = shosaiShadTheme(Brightness.light);
  return BoxDecoration(
    border: Border.all(color: theme.colorScheme.ring, width: 2),
    borderRadius: theme.cardTheme.radius ?? theme.radius,
  );
}

/// Every case runs on the desktop import path; the Android and iOS branches
/// never show the two-choice dialog.
void _addBooksTest(String description, WidgetTesterCallback callback) =>
    testWidgets(
      description,
      callback,
      variant: TargetPlatformVariant.only(TargetPlatform.linux),
    );

void main() {
  _addBooksTest('add-books dialog lays out under active semantics', (
    tester,
  ) async {
    await _pumpShell(tester);
    await _openAddBooks(tester);

    expect(find.text('Choose files'), findsOneWidget);
    expect(find.text('Choose a folder'), findsOneWidget);
    expect(
      find.text('Select one or more PDF, EPUB, or CBZ files'),
      findsOneWidget,
    );
    expect(find.text('Find supported books in all subfolders'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  _addBooksTest('both choices expose button role, name and enabled state', (
    tester,
  ) async {
    await _pumpShell(tester);
    await _openAddBooks(tester);

    for (final (title, subtitle) in const [
      ('Choose files', 'Select one or more PDF, EPUB, or CBZ files'),
      ('Choose a folder', 'Find supported books in all subfolders'),
    ]) {
      final node = tester.getSemantics(find.text(title));
      expect(
        node,
        isSemantics(
          isButton: true,
          hasEnabledState: true,
          isEnabled: true,
          hasTapAction: true,
        ),
        reason: '$title is an enabled button',
      );
      final data = node.getSemanticsData();
      expect(data.label, contains(title));
      expect(data.label, contains(subtitle));
    }
  });

  _addBooksTest('focus enters the dialog, moves between choices and shows', (
    tester,
  ) async {
    await _pumpShell(tester);
    await _openAddBooks(tester);

    // The open dialog owns focus before any traversal.
    expect(
      FocusScope.of(tester.element(find.byType(ShadDialog))).hasFocus,
      isTrue,
      reason: 'focus starts inside the dialog',
    );

    final unfocused = tester.getRect(find.byType(ShadCard).first);
    expect(_ringOn(tester, 'Choose files'), isNull);
    expect(_ringOn(tester, 'Choose a folder'), isNull);

    await _tabToChoice(tester, 'Choose files');
    expect(_ringOn(tester, 'Choose files'), _focusedRing());
    expect(_ringOn(tester, 'Choose a folder'), isNull);
    expect(
      tester.getRect(find.byType(ShadCard).first),
      unfocused,
      reason: 'focus does not move or resize the choice',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(
      tester.getSemantics(find.text('Choose a folder')),
      isSemantics(isFocused: true),
      reason: 'Tab moves focus to the second choice',
    );
    expect(_ringOn(tester, 'Choose files'), isNull);
    expect(_ringOn(tester, 'Choose a folder'), _focusedRing());
  });

  for (final choice in _choices) {
    _addBooksTest('Enter activates ${choice.title} once', (tester) async {
      final picker = _PickerStub(tester);
      final pops = _PopCounter();

      await _pumpShell(tester, observer: pops);
      await _openAddBooks(tester);
      await _tabToChoice(tester, choice.title);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(picker.calls, [choice.pickerCall]);
      expect(pops.pops, 1);
      expect(find.byType(ShadDialog), findsNothing);
    });

    _addBooksTest('Space activates ${choice.title} once', (tester) async {
      final picker = _PickerStub(tester);
      final pops = _PopCounter();

      await _pumpShell(tester, observer: pops);
      await _openAddBooks(tester);
      await _tabToChoice(tester, choice.title);

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();

      expect(picker.calls, [choice.pickerCall]);
      expect(pops.pops, 1);
      expect(find.byType(ShadDialog), findsNothing);
    });

    _addBooksTest('screen-reader tap activates ${choice.title} once', (
      tester,
    ) async {
      final picker = _PickerStub(tester);
      final pops = _PopCounter();

      await _pumpShell(tester, observer: pops);
      await _openAddBooks(tester);

      final node = tester.getSemantics(find.text(choice.title));
      expect(node.getSemanticsData().hasAction(ui.SemanticsAction.tap), isTrue);
      node.owner!.performAction(node.id, ui.SemanticsAction.tap);
      await tester.pumpAndSettle();

      expect(picker.calls, [choice.pickerCall]);
      expect(pops.pops, 1);
      expect(find.byType(ShadDialog), findsNothing);
    });
  }

  _addBooksTest('pointer taps activate each choice once', (tester) async {
    final picker = _PickerStub(tester);
    final pops = _PopCounter();

    await _pumpShell(tester, observer: pops);
    await _openAddBooks(tester);

    await tester.tap(find.text('Choose files'));
    await tester.pumpAndSettle();

    expect(picker.calls, ['openFile']);
    expect(pops.pops, 1);

    await _openAddBooks(tester);
    await tester.tap(find.text('Choose a folder'));
    await tester.pumpAndSettle();

    expect(picker.calls, ['openFile', 'getDirectoryPath']);
    expect(pops.pops, 2);
  });

  _addBooksTest('dismissing the dialog activates nothing and keeps the shell', (
    tester,
  ) async {
    final picker = _PickerStub(tester);
    final pops = _PopCounter();

    await _pumpShell(tester, observer: pops);
    await _openAddBooks(tester);

    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();

    expect(picker.calls, isEmpty);
    expect(pops.pops, 1);
    expect(find.text('Choose files'), findsNothing);
    expect(find.widgetWithText(ShadButton, 'Add books'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await _openAddBooks(tester);
    expect(find.text('Choose files'), findsOneWidget);
  });

  for (final (name, size, textScale) in const [
    ('a narrow window', Size(390, 844), 1.0),
    ('200% text', Size(900, 700), 2.0),
    ('a narrow window at 200% text', Size(390, 844), 2.0),
  ]) {
    _addBooksTest('add-books dialog stays usable with $name', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = textScale;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final picker = _PickerStub(tester);

      await _pumpShell(tester);
      await _openAddBooks(tester);

      expect(find.text('Choose files'), findsOneWidget);
      expect(find.text('Choose a folder'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('Choose a folder'));
      await tester.pumpAndSettle();

      expect(picker.calls, ['getDirectoryPath']);
    });
  }
}
