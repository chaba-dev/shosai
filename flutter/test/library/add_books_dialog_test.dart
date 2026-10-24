import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shosai_flutter/app_theme.dart';
import 'package:shosai_flutter/l10n/app_localizations.dart';
import 'package:shosai_flutter/library/view.dart';
import 'package:shosai_flutter/core/bridge.dart';
import '../support/bridge_pdf_engine.dart';
import '../support/bridge_records.dart';

/// The desktop import path has no adapter above the native picker, so the
/// file-selector channel is the platform boundary these tests stub.
const _pickerChannel = MethodChannel('plugins.flutter.io/file_selector');

/// The two desktop choices and the picker request each one must produce.
const _choices = [
  (title: 'Choose files', pickerCall: 'openFile'),
  (title: 'Choose a folder', pickerCall: 'getDirectoryPath'),
];

class _Bridge with BridgePdfEngine, BridgeRecords implements FlutterBridge {
  _Bridge({this.failImport = false, this.cancelImport = false});

  final bool failImport;
  final bool cancelImport;

  /// The path imports the library asked for, in order.
  final imports = <({List<String> paths, bool managed})>[];

  @override
  bool get isDisposed => false;
  @override
  Future<FlutterImportReport> importPaths({
    required List<String> pathKeys,
    required bool managed,
    required BigInt cancellationId,
  }) async {
    imports.add((paths: pathKeys, managed: managed));
    return FlutterImportReport(
      imported: failImport || cancelImport
          ? BigInt.zero
          : BigInt.from(pathKeys.length),
      failed: failImport ? BigInt.one : BigInt.zero,
      cancelled: cancelImport,
      items: failImport
          ? [FlutterImportItem(pathKey: pathKeys.first, error: 'unsupported')]
          : const [],
    );
  }

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
    FlutterLibrarySort sort = FlutterLibrarySort.recent,
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
  _PickerStub(WidgetTester tester, {List<String> picked = const []}) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      _pickerChannel,
      (call) async {
        calls.add(call.method);
        arguments.add(call.arguments);
        return switch (call.method) {
          'openFile' => picked,
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
  final List<Object?> arguments = [];
}

Future<void> _pumpShell(
  WidgetTester tester, {
  NavigatorObserver? observer,
  _Bridge? bridge,
  Locale locale = const Locale('en'),
}) async {
  await tester.pumpWidget(
    ShadApp(
      locale: locale,
      theme: shosaiShadTheme(Brightness.light),
      navigatorObservers: [?observer],
      // Mirrors the production composition in `ShosaiShell`: the generated
      // application delegate plus the Shad/Material/Cupertino/Widgets
      // delegates, so the library's localized navigation resolves here too.
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalShadLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: ProductShell(
        bridgeFactory: () => bridge ?? _Bridge(),
        readerBuilder: (_, _, _, _, _, _, _, _, _, _) => const SizedBox(),
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

/// Every case below runs on the desktop import path; the Android and iOS
/// branches never show the two-choice dialog.
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
    expect(find.text('Select one or more PDF or EPUB files'), findsOneWidget);
    expect(find.text('Find supported books in all subfolders'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  _addBooksTest('both choices expose button role, name and enabled state', (
    tester,
  ) async {
    await _pumpShell(tester);
    await _openAddBooks(tester);

    for (final (title, subtitle) in const [
      ('Choose files', 'Select one or more PDF or EPUB files'),
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

  testWidgets(
    'iOS picks books in the document picker and keeps copies',
    (tester) async {
      // The picker copies each book into the app's inbox; stand-ins for those
      // copies show that the library removes them after its own copy.
      final inbox = await tester.runAsync(
        () => Directory.systemTemp.createTemp('shosai-inbox'),
      );
      addTearDown(() => inbox!.delete(recursive: true));
      final picked = [
        for (final name in ['origin.epub', 'paper.pdf'])
          (await tester.runAsync(
            () => File('${inbox!.path}/$name').writeAsString(name),
          ))!.path,
      ];
      final picker = _PickerStub(tester, picked: picked);
      final bridge = _Bridge();

      await _pumpShell(tester, bridge: bridge);
      await _openAddBooks(tester);

      // No two-choice dialog: the system picker opens at once, offering books
      // by their uniform type identifiers.
      expect(find.text('Choose files'), findsNothing);
      expect(picker.calls, ['openFile']);
      final request = picker.arguments.single! as Map<Object?, Object?>;
      expect(request['multiple'], isTrue);
      final types = (request['acceptedTypeGroups']! as List).single as Map;
      expect(types['uniformTypeIdentifiers'], [
        'com.adobe.pdf',
        'org.idpf.epub-container',
      ]);

      // The review keeps managed storage on: the inbox copies are temporary.
      expect(find.text('Review books'), findsOneWidget);
      expect(
        tester.widget<ShadSwitch>(find.byType(ShadSwitch)).onChanged,
        isNull,
      );
      await tester.tap(find.widgetWithText(ShadButton, 'Import'));
      await tester.pump();
      expect(bridge.imports.single.paths, picked);
      expect(bridge.imports.single.managed, isTrue);

      // The inbox copies are deleted on real file I/O, which the fake clock
      // does not advance; wait for it outside the test zone.
      var left = picked.length;
      for (var attempt = 0; left > 0 && attempt < 50; attempt += 1) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
        left = picked.where((path) => File(path).existsSync()).length;
      }
      expect(left, 0, reason: 'the picker copies are removed');
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  for (final outcome in ['decline', 'failure', 'cancelled']) {
    testWidgets(
      'iOS Japanese import localizes review and cleans copies on $outcome',
      (tester) async {
        final inbox = (await tester.runAsync(
          () => Directory.systemTemp.createTemp('shosai-import-ja'),
        ))!;
        addTearDown(() => inbox.delete(recursive: true));
        final file = File('${inbox.path}/book.epub');
        await tester.runAsync(() => file.writeAsString('book'));
        _PickerStub(tester, picked: [file.path]);
        final bridge = _Bridge(
          failImport: outcome == 'failure',
          cancelImport: outcome == 'cancelled',
        );
        await _pumpShell(tester, bridge: bridge, locale: const Locale('ja'));
        await tester.tap(find.widgetWithText(ShadButton, '本を追加'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('追加する本を確認'), findsOneWidget);
        expect(find.text('アプリ内にコピーを保存'), findsOneWidget);
        expect(find.text('選択した本のコピーをShōsai内に保存します。'), findsOneWidget);
        expect(find.text('Import'), findsNothing);
        await tester.tap(
          find
              .widgetWithText(ShadButton, outcome == 'decline' ? 'キャンセル' : '追加')
              .last,
        );
        for (var attempt = 0; file.existsSync() && attempt < 50; attempt++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump();
        }
        expect(file.existsSync(), isFalse);
        expect(bridge.imports, hasLength(outcome == 'decline' ? 0 : 1));
        for (var attempt = 0; attempt < 5; attempt++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 400));
        }
        if (outcome == 'failure') {
          expect(find.textContaining('1件を追加できませんでした。'), findsOneWidget);
          expect(find.textContaining('このファイル形式には対応していません。'), findsOneWidget);
        }
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  }
}
