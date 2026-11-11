import 'dart:async';
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
import 'package:shosai_core/shosai_core.dart'
    show
        BookFileCache,
        CancellationToken,
        Library,
        LibraryLocations,
        Preferences,
        Store;
import 'package:shosai_flutter/core/bridge.dart';
import 'package:shosai_flutter/core/library_folders.dart';
import '../support/bridge_pdf_engine.dart';
import '../support/bridge_records.dart';

/// The desktop import path has no adapter above the native picker, so the
/// file-selector channel is the platform boundary these tests stub.
const _pickerChannel = MethodChannel('plugins.flutter.io/file_selector');
const _openedChannel = MethodChannel('dev.shosai/opened_documents');
const _openedPlatforms = TargetPlatformVariant({
  TargetPlatform.iOS,
  TargetPlatform.android,
  TargetPlatform.macOS,
});

const _folderHint =
    'Books stay in the folder, and new ones appear on the shelf. Works with '
    'Dropbox, iCloud Drive and other synced folders.';

/// The add-books control: the sidebar or rail row beside a shelf, and the
/// header's "+" on a phone.
Finder _addBooksControl() {
  final row = find.text('Add books');
  return row.evaluate().isNotEmpty ? row : find.byTooltip('Add books');
}

/// The two desktop choices and the picker request each one must produce. A
/// session without storage connections copies the chosen folder in, so the
/// folder choice still asks for a directory.
const _choices = [
  (title: 'Choose files', pickerCall: 'openFile'),
  (title: 'Connect a folder', pickerCall: 'getDirectoryPath'),
];

class _Bridge with BridgePdfEngine, BridgeRecords implements FlutterBridge {
  _Bridge({
    this.failImport = false,
    this.cancelImport = false,
    this.loadGate,
    this.captureImportBytes = false,
  });

  final bool failImport;
  final bool cancelImport;
  final Completer<FlutterLibraryPage>? loadGate;
  final bool captureImportBytes;
  final importedBytes = <List<int>>[];

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
    if (captureImportBytes) {
      for (final path in pathKeys) {
        importedBytes.add(await File(path).readAsBytes());
      }
    }
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
  }) async => loadGate == null
      ? const FlutterLibraryPage(books: [], hasMore: false)
      : await loadGate!.future;
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

/// A session with storage connections, whose Add books offers them.
class _ConnectedBridge extends _Bridge implements LibraryFoldersHost {
  _ConnectedBridge(this.folders);

  @override
  final LibraryFolders folders;

  @override
  Future<FlutterLibraryBook> admitSourceFile(
    LibrarySourceFile file, {
    CancellationToken? cancellation,
  }) => throw StateError('No content reads');
}

/// Opens an empty connections service for [_ConnectedBridge].
Future<_ConnectedBridge> _connectedBridge(WidgetTester tester) async {
  final opened = await tester.runAsync(() async {
    final directory = await Directory.systemTemp.createTemp('shosai-add');
    final store = await Store.open('${directory.path}/library.sqlite3');
    final folders = LibraryFolders(
      Preferences(store),
      Library(store, managedDirectory: '${directory.path}/books'),
      LibraryLocations(store),
      () async => '${directory.path}/unused',
      BookFileCache(store, '${directory.path}/cache'),
      providers: const [],
    );
    return (directory, store, folders);
  });
  final (directory, store, folders) = opened!;
  addTearDown(() async {
    // The library's discovery runs in the test zone, so it drains while
    // frames and real time both advance.
    await tester.pumpWidget(const SizedBox());
    var closed = false;
    final closing = () async {
      await folders.close();
      await store.close();
      await directory.delete(recursive: true);
    }().whenComplete(() => closed = true);
    for (var frame = 0; frame < 500 && !closed; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
    }
    expect(closed, isTrue);
    await closing;
  });
  return _ConnectedBridge(folders);
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
  bool settle = true,
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
  if (settle) await tester.pumpAndSettle();
}

Future<void> _openAddBooks(WidgetTester tester) async {
  await tester.tap(_addBooksControl());
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
    expect(find.text('Connect a folder'), findsOneWidget);
    expect(find.text('Select one or more PDF or EPUB files'), findsOneWidget);
    expect(find.text(_folderHint), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  _addBooksTest('both choices expose button role, name and enabled state', (
    tester,
  ) async {
    await _pumpShell(tester);
    await _openAddBooks(tester);

    for (final (title, subtitle) in const [
      ('Choose files', 'Select one or more PDF or EPUB files'),
      ('Connect a folder', _folderHint),
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
    expect(_ringOn(tester, 'Connect a folder'), isNull);

    await _tabToChoice(tester, 'Choose files');
    expect(_ringOn(tester, 'Choose files'), _focusedRing());
    expect(_ringOn(tester, 'Connect a folder'), isNull);
    expect(
      tester.getRect(find.byType(ShadCard).first),
      unfocused,
      reason: 'focus does not move or resize the choice',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(
      tester.getSemantics(find.text('Connect a folder')),
      isSemantics(isFocused: true),
      reason: 'Tab moves focus to the second choice',
    );
    expect(_ringOn(tester, 'Choose files'), isNull);
    expect(_ringOn(tester, 'Connect a folder'), _focusedRing());
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
    await tester.tap(find.text('Connect a folder'));
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
    expect(_addBooksControl(), findsOneWidget);
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
      expect(find.text('Connect a folder'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('Connect a folder'));
      await tester.pumpAndSettle();

      expect(picker.calls, ['getDirectoryPath']);
    });
  }

  for (final cancel in [false, true]) {
    testWidgets(
      'iOS owns picker copies through Review and cleans up (cancel: $cancel)',
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
        final support = Directory('${inbox!.path}/support');
        const provider = MethodChannel('plugins.flutter.io/path_provider');
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          provider,
          (call) async => support.path,
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            provider,
            null,
          ),
        );
        final bridge = _Bridge(captureImportBytes: true);

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
        for (
          var attempt = 0;
          find.text('Review books').evaluate().isEmpty && attempt < 100;
          attempt++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump();
        }
        expect(find.text('Review books'), findsOneWidget);
        expect(
          tester.widget<ShadSwitch>(find.byType(ShadSwitch)).onChanged,
          isNull,
        );
        // iOS may remove its Inbox copies while Review remains visible.
        await tester.runAsync(() async {
          for (final path in picked) {
            if (await File(path).exists()) await File(path).delete();
          }
        });
        await tester.pump(const Duration(seconds: 102));
        await tester.tap(
          find.widgetWithText(ShadButton, cancel ? 'Cancel' : 'Import').last,
        );

        // The inbox copies are deleted on real file I/O, which the fake clock
        // does not advance; wait for it outside the test zone.
        var left = true;
        for (var attempt = 0; left && attempt < 100; attempt += 1) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump();
          left =
              (!cancel && bridge.imports.isEmpty) ||
              (support.existsSync() &&
                  support
                      .listSync(recursive: true)
                      .whereType<File>()
                      .isNotEmpty);
        }
        expect(
          left,
          isFalse,
          reason: 'all temporary copies and locks are released',
        );
        if (cancel) {
          expect(bridge.imports, isEmpty);
        } else {
          expect(bridge.imports.single.paths, isNot(picked));
          expect(bridge.imports.single.managed, isTrue);
          expect(bridge.importedBytes, [
            'origin.epub'.codeUnits,
            'paper.pdf'.codeUnits,
          ]);
        }
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  }

  testWidgets(
    'iOS cancelling pending staging never opens Review or imports',
    (tester) async {
      final root = Directory.systemTemp.createTempSync('picker-cancel');
      addTearDown(() => root.delete(recursive: true));
      final picked = File('${root.path}/book.epub')..writeAsStringSync('book');
      _PickerStub(tester, picked: [picked.path]);
      final support = Directory('${root.path}/support');
      final gate = Completer<String>();
      const provider = MethodChannel('plugins.flutter.io/path_provider');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        provider,
        (_) => gate.future,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          provider,
          null,
        ),
      );
      final bridge = _Bridge(captureImportBytes: true);
      await _pumpShell(tester, bridge: bridge);
      await _openAddBooks(tester);
      expect(find.text('Review books'), findsNothing);
      await tester.tap(find.byTooltip('Cancel operation'));
      gate.complete(support.path);
      for (var n = 0; n < 100 && picked.existsSync(); n++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      expect(picked.existsSync(), isFalse);
      expect(support.existsSync(), isFalse);
      expect(find.text('Review books'), findsNothing);
      expect(bridge.imports, isEmpty);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'imports books another app opens in Shōsai at startup and while running',
    (tester) async {
      final inbox = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('shosai-opened'),
      ))!;
      addTearDown(() => inbox.delete(recursive: true));
      final opened = [
        for (final name in ['origin.epub', 'paper.pdf'])
          (await tester.runAsync(
            () => File('${inbox.path}/$name').writeAsString(name),
          ))!.path,
      ];
      final messenger = tester.binding.defaultBinaryMessenger;
      var pending = [opened.first];
      messenger.setMockMethodCallHandler(_openedChannel, (call) async {
        if (call.method == 'discard') {
          for (final path in (call.arguments! as List).cast<String>()) {
            await File(path).delete();
          }
          return null;
        }
        final paths = pending;
        pending = [];
        return paths;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(_openedChannel, null),
      );
      final bridge = _Bridge();
      await _pumpShell(tester, bridge: bridge, settle: false);
      for (var attempt = 0; bridge.imports.isEmpty && attempt < 50; attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      expect(find.text('Review books'), findsNothing);
      expect(bridge.imports.single.paths, [opened.first]);
      expect(bridge.imports.single.managed, isTrue);
      pending = [opened.last];
      await messenger.handlePlatformMessage(
        _openedChannel.name,
        _openedChannel.codec.encodeMethodCall(const MethodCall('opened')),
        (_) {},
      );
      for (
        var attempt = 0;
        bridge.imports.length < 2 && attempt < 50;
        attempt++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      expect(bridge.imports.last.paths, [opened.last]);
      for (
        var attempt = 0;
        opened.any((path) => File(path).existsSync()) && attempt < 50;
        attempt++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      expect(opened.where((path) => File(path).existsSync()), isEmpty);
    },
    variant: _openedPlatforms,
  );

  testWidgets(
    'bounds and deduplicates incoming batches before the library loads',
    (tester) async {
      final paths = List.generate(257, (index) => '/inbox/$index.epub');
      final messenger = tester.binding.defaultBinaryMessenger;
      var pending = [...paths, paths.first];
      messenger.setMockMethodCallHandler(_openedChannel, (call) async {
        if (call.method == 'discard') return null;
        final result = pending;
        pending = [];
        return result;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(_openedChannel, null),
      );
      final gate = Completer<FlutterLibraryPage>();
      final bridge = _Bridge(loadGate: gate);
      await _pumpShell(tester, bridge: bridge, settle: false);
      await tester.pump();
      expect(bridge.imports, isEmpty);
      gate.complete(const FlutterLibraryPage(books: [], hasMore: false));
      for (
        var attempt = 0;
        // Serial file cleanup resumes on the fake clock once per pump.
        bridge.imports.length < 2 && attempt < 500;
        attempt++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      expect(bridge.imports.map((batch) => batch.paths.length), [256, 1]);
      expect(bridge.imports.expand((batch) => batch.paths), paths);
      expect(bridge.imports.every((batch) => batch.managed), isTrue);
    },
    variant: _openedPlatforms,
  );

  testWidgets(
    'releases queued incoming copies when the shell closes before loading',
    (tester) async {
      final inbox = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('shosai-queued'),
      ))!;
      addTearDown(() => inbox.delete(recursive: true));
      final file = File('${inbox.path}/queued.epub');
      await tester.runAsync(() => file.writeAsString('book'));
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(_openedChannel, (call) async {
        if (call.method == 'discard') {
          await file.delete();
          return null;
        }
        return [file.path];
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(_openedChannel, null),
      );
      final gate = Completer<FlutterLibraryPage>();
      final bridge = _Bridge(loadGate: gate);
      await _pumpShell(tester, bridge: bridge, settle: false);
      await tester.pump();
      expect(bridge.imports, isEmpty);
      await tester.pumpWidget(const SizedBox());
      for (var attempt = 0; file.existsSync() && attempt < 50; attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      gate.complete(const FlutterLibraryPage(books: [], hasMore: false));
      await tester.pump();
      expect(file.existsSync(), isFalse);
      expect(bridge.imports, isEmpty);
    },
    variant: _openedPlatforms,
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
        final support = Directory('${inbox.path}/support');
        const provider = MethodChannel('plugins.flutter.io/path_provider');
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          provider,
          (_) async => support.path,
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            provider,
            null,
          ),
        );
        _PickerStub(tester, picked: [file.path]);
        final bridge = _Bridge(
          failImport: outcome == 'failure',
          cancelImport: outcome == 'cancelled',
        );
        await _pumpShell(tester, bridge: bridge, locale: const Locale('ja'));
        await tester.tap(find.text('本を追加'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump(const Duration(milliseconds: 400));
        for (
          var attempt = 0;
          find.text('追加する本を確認').evaluate().isEmpty && attempt < 100;
          attempt++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump();
        }
        expect(find.text('追加する本を確認'), findsOneWidget);
        expect(find.text('アプリ内にコピーを保存'), findsOneWidget);
        expect(find.text('選択した本のコピーをShōsai内に保存します。'), findsOneWidget);
        expect(find.text('Import'), findsNothing);
        await tester.tap(
          find
              .widgetWithText(ShadButton, outcome == 'decline' ? 'キャンセル' : '追加')
              .last,
        );
        for (
          var attempt = 0;
          support.listSync(recursive: true).whereType<File>().isNotEmpty &&
              attempt < 100;
          attempt++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump();
        }
        expect(file.existsSync(), isFalse);
        expect(support.listSync(recursive: true).whereType<File>(), isEmpty);
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

  testWidgets(
    'a phone offers files and storage accounts, never a folder',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final bridge = await _connectedBridge(tester);
      await _pumpShell(tester, bridge: bridge, settle: false);
      for (var frame = 0; frame < 20; frame++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
      await _openAddBooks(tester);

      expect(find.text('Choose files'), findsOneWidget);
      expect(find.text('Connect Dropbox'), findsOneWidget);
      expect(find.text('Connect Google Drive'), findsOneWidget);
      expect(find.text('Connect a folder'), findsNothing);
      expect(find.text('Copy into Shōsai instead'), findsNothing);
      expect(
        find.byType(ShadDialog),
        findsNothing,
        reason: 'a phone shows the choices as a bottom sheet',
      );
      final sheet = tester.getRect(
        find
            .ancestor(
              of: find.text('Connect Google Drive'),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(sheet.bottom, 844);
      // Nothing is imported while the choices are open, so the header keeps
      // its "+" and shows no activity behind the sheet.
      expect(find.byTooltip('Add books'), findsOneWidget);
      expect(find.byTooltip('Cancel'), findsNothing);
      expect(find.byType(ShadProgress), findsNothing);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'desktop connects a folder in place unless its copy is asked for',
    (tester) async {
      final picker = _PickerStub(tester);
      final bridge = await _connectedBridge(tester);
      await _pumpShell(tester, bridge: bridge, settle: false);
      for (var frame = 0; frame < 20; frame++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
      await _openAddBooks(tester);

      expect(find.text('Connect Dropbox'), findsNothing);
      final copy = tester.widget<ShadSwitch>(find.byType(ShadSwitch));
      expect(copy.value, isFalse, reason: 'connecting in place is the default');

      await tester.tap(find.text('Connect a folder'));
      for (var frame = 0; frame < 20; frame++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(
        picker.calls,
        isNot(contains('getDirectoryPath')),
        reason: 'a connected folder is not copied in',
      );
      expect(find.text('Connections'), findsOneWidget);
      await tester.tapAt(const Offset(8, 8));
      for (var frame = 0; frame < 20; frame++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }

      await _openAddBooks(tester);
      await tester.tap(find.text('Copy into Shōsai instead'));
      await tester.pump();
      await tester.tap(find.text('Connect a folder'));
      await tester.pumpAndSettle();
      expect(picker.calls, ['getDirectoryPath']);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );
}
