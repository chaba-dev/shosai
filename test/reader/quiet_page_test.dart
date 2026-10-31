import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_flutter/core/bridge.dart';
import 'package:shosai_flutter/reader/controller.dart' show ReaderDisplayChange;
import 'package:shosai_flutter/reader/pdf/engine.dart';
import 'package:shosai_flutter/reader/view.dart';

import '../support/production_shell_harness.dart';

class _Book extends HarnessBridge {
  _Book({this.rtl = false, this.links = const []}) : super(unitCount: 5);
  final bool rtl;
  final List<PdfPageLink> links;
  @override
  bool get pdfEngineRightToLeft => rtl;
  @override
  Future<List<PdfPageLink>> pdfEngineLinks(int page) async => links;
}

const _settings = FlutterReaderSettings(
  continuous: false,
  theme: 'light',
  epubFontSize: 18,
  epubLineSpacing: 1.6,
  pdfZoom: 0,
  twoPages: false,
  zonesHintDismissed: true,
);

final _stage = find.byKey(const ValueKey('reader-stage'));
final _toolbar = find.byKey(const ValueKey('reader-header-contents'));
final _folio = find.byKey(const ValueKey('reader-folio'));

Future<void> _open(
  WidgetTester tester,
  Size size, {
  bool rtl = false,
  List<PdfPageLink> links = const [],
  FlutterReaderSettings settings = _settings,
  void Function(ReaderDisplayChange)? save,
  String path = '/books/atlas.pdf',
  bool pushRoute = false,
  double ratio = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = ratio;
  addTearDown(tester.view.reset);
  final reader = ReaderScreen(
    key: UniqueKey(),
    bridge: _Book(rtl: rtl, links: links),
    initialPath: path,
    initialSettings: settings,
    onDisplayChanged: save,
    decoder: (pixels, {required width, required height}) async {
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder).drawRect(
        const Rect.fromLTWH(0, 0, 420, 560),
        ui.Paint()..color = const Color(0xFFFFFDF8),
      );
      final picture = recorder.endRecording();
      final image = await picture.toImage(420, 560);
      picture.dispose();
      return image;
    },
  );
  await tester.pumpWidget(
    productionShell(
      home: pushRoute
          ? Builder(
              builder: (context) => TextButton(
                onPressed: () => Navigator.of(
                  context,
                ).push(MaterialPageRoute<void>(builder: (_) => reader)),
                child: const Text('Open reader'),
              ),
            )
          : reader,
    ),
  );
  if (pushRoute) {
    await tester.tap(find.text('Open reader'));
  }
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 32));
  }
}

Future<void> _tap(WidgetTester tester, double fraction) async {
  final rect = tester.getRect(_stage);
  await tester.tapAt(Offset(rect.left + rect.width * fraction, rect.center.dy));
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pumpAndSettle();
}

String _place(WidgetTester tester) => tester.widget<Text>(_folio).data!;

String? _status(WidgetTester tester) => tester
    .widget<Semantics>(find.byKey(const ValueKey('reader-progress')))
    .properties
    .label;

void main() {
  setUpAll(loadHarnessFonts);

  for (final format in ['pdf', 'epub']) {
    testWidgets(
      'Android stable insets keep $format geometry through chrome and rotation',
      (tester) async {
        const channel = MethodChannel('dev.shosai/reader_system_bars');
        var stable = [0, 96, 0, 48];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (call) async => call.method == 'getStableInsets' ? stable : null,
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            null,
          ),
        );
        await _open(
          tester,
          const Size(780, 1688),
          path: '/books/atlas.$format',
          ratio: 2,
        );
        await tester.pumpAndSettle();
        await _tap(tester, .85);
        await _tap(tester, .85);
        final surface = find.byKey(const ValueKey('reader-selection-surface'));
        final before = tester.getRect(surface);
        final place = _status(tester);
        MediaQueryData media() => MediaQuery.of(tester.element(_stage));
        expect(media().viewPadding, const EdgeInsets.only(top: 48, bottom: 24));
        for (var i = 0; i < 3; i++) {
          await _tap(tester, .5);
          tester.view.viewPadding = const FakeViewPadding(top: 96, bottom: 48);
          tester.view.padding = const FakeViewPadding(top: 96, bottom: 48);
          await tester.pumpAndSettle();
          expect(tester.getRect(surface), before);
          expect(_status(tester), place);
          await _tap(tester, .5);
          tester.view.viewPadding = FakeViewPadding.zero;
          tester.view.padding = FakeViewPadding.zero;
          await tester.pumpAndSettle();
          expect(tester.getRect(surface), before);
          expect(_status(tester), place);
          expect(media().padding, const EdgeInsets.only(top: 48, bottom: 24));
        }
        stable = [96, 0, 48, 0];
        tester.view.physicalSize = const Size(1688, 780);
        await tester.pumpAndSettle();
        // The reader's horizontal SafeArea consumes these fixed insets.
        expect(tester.getRect(_stage).left, 48);
        expect(tester.getRect(_stage).right, 820);
        final rotated = tester.getRect(surface);
        await _tap(tester, .5);
        tester.view.viewPadding = const FakeViewPadding(left: 96, right: 48);
        tester.view.padding = const FakeViewPadding(left: 96, right: 48);
        await tester.pumpAndSettle();
        expect(tester.getRect(surface), rotated);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  }

  testWidgets(
    'system Back restores bars before the reader route is disposed',
    (tester) async {
      const channel = MethodChannel('dev.shosai/reader_system_bars');
      final calls = <bool>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'setShown') calls.add(call.arguments as bool);
        return null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      await _open(tester, const Size(390, 844), pushRoute: true);
      expect(calls.last, isFalse);
      // A pending keyboard cooldown must not hide bars on the library later.
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      tester.view.viewInsets = FakeViewPadding.zero;
      await tester.pump();
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(
        find.byType(ReaderScreen),
        findsOneWidget,
        reason: 'the outgoing route is still animating',
      );
      expect(calls.last, isTrue);
      final restored = calls.length;
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 2));
      expect(
        calls.length,
        restored,
        reason: 'neither cooldown nor disposal takes ownership again',
      );
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  for (final width in [390.0, 900.0, 1280.0]) {
    for (final rtl in [false, true]) {
      testWidgets('touch thirds and chrome never reflow ($width, RTL $rtl)', (
        tester,
      ) async {
        await _open(tester, Size(width, 844), rtl: rtl);
        expect(_toolbar.hitTestable(), findsNothing);
        expect(
          find.byKey(const ValueKey('reader-edge-next')).hitTestable(),
          findsNothing,
        );
        final surface = find.byKey(const ValueKey('reader-selection-surface'));
        final before = tester.getRect(surface);
        await _tap(tester, .5);
        expect(_toolbar.hitTestable(), findsOneWidget);
        expect(tester.getRect(surface), before);
        await tester.pump(const Duration(seconds: 8));
        expect(
          _toolbar.hitTestable(),
          findsOneWidget,
          reason: 'touch has no idle timer',
        );
        await _tap(tester, .5);
        expect(_toolbar.hitTestable(), findsNothing);
        await _tap(tester, rtl ? .15 : .85);
        expect(_status(tester), '40% · page 2 of 5');
        if (width < 600) expect(_place(tester), 'page 2 of 5');
        expect(_toolbar.hitTestable(), findsNothing);
        await _tap(tester, rtl ? .85 : .15);
        expect(_status(tester), '20% · page 1 of 5');
        if (width < 600) expect(_place(tester), 'page 1 of 5');
        await tester.drag(surface, Offset(rtl ? 180 : -180, 0));
        await tester.pumpAndSettle();
        expect(_status(tester), '40% · page 2 of 5');
        if (width < 600) expect(_place(tester), 'page 2 of 5');
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final width in [900.0, 1280.0]) {
    for (final rtl in [false, true]) {
      testWidgets('touch thirds turn whole PDF spreads ($width, RTL $rtl)', (
        tester,
      ) async {
        await _open(
          tester,
          Size(width, 600),
          rtl: rtl,
          settings: _settings.copyWith(twoPages: true),
        );
        expect(_status(tester), '20% · page 1 of 5');
        await _tap(tester, rtl ? .15 : .85);
        expect(_status(tester), '60% · pages 2–3 of 5');
        await _tap(tester, rtl ? .15 : .85);
        expect(_status(tester), '100% · pages 4–5 of 5');
        await _tap(tester, rtl ? .85 : .15);
        expect(_status(tester), '60% · pages 2–3 of 5');
        expect(_toolbar.hitTestable(), findsNothing);
      });
    }
  }

  testWidgets('a swipe on the phone PDF place turns the page', (tester) async {
    await _open(tester, const Size(390, 844));
    await tester.drag(_folio, const Offset(-160, 0));
    await tester.pumpAndSettle();
    expect(_place(tester), 'page 2 of 5');
    await tester.drag(_folio, const Offset(160, 0));
    await tester.pumpAndSettle();
    expect(_place(tester), 'page 1 of 5');
  });

  testWidgets(
    'keyboard closure restores current system bars after the cooldown',
    (tester) async {
      const channel = MethodChannel('dev.shosai/reader_system_bars');
      final calls = <bool>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'getStableInsets') return null;
        expectSync(call.method, 'setShown');
        calls.add(call.arguments as bool);
        return null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      await _open(tester, const Size(390, 844));
      expect(calls.last, isFalse);
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      tester.view.viewInsets = FakeViewPadding.zero;
      await tester.pump();
      final before = calls.length;
      await tester.pump(const Duration(seconds: 1));
      expect(calls.length, before);
      await tester.pump(const Duration(milliseconds: 100));
      expect(calls.length, before + 1);
      expect(calls.last, isFalse);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'desktop movement, idle boundary, chrome hover, panel, keys and exit',
    (tester) async {
      await _open(tester, const Size(1280, 800));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(0, 0));
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(_stage));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 180));
      expect(_toolbar.hitTestable(), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 1819));
      expect(_toolbar.hitTestable(), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 181));
      expect(_toolbar.hitTestable(), findsNothing);

      await mouse.moveBy(const Offset(12, 8));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 180));
      await mouse.moveTo(tester.getCenter(_toolbar));
      await tester.pump(const Duration(seconds: 4));
      expect(_toolbar.hitTestable(), findsOneWidget);
      await tester.tap(_toolbar);
      await tester.pumpAndSettle();
      await mouse.moveTo(tester.getCenter(_stage));
      await tester.pump(const Duration(seconds: 4));
      expect(
        _toolbar.hitTestable(),
        findsOneWidget,
        reason: 'open Contents pins chrome',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 3));
      expect(_toolbar.hitTestable(), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.pumpAndSettle();
      expect(find.text('40% · page 2 of 5'), findsOneWidget);
      expect(
        _toolbar.hitTestable(),
        findsNothing,
        reason: 'keys never reveal chrome',
      );
      await mouse.moveBy(const Offset(12, 8));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 180));
      expect(_toolbar.hitTestable(), findsOneWidget);
      await mouse.moveTo(const Offset(-1, -1));
      await tester.pump(const Duration(milliseconds: 180));
      expect(_toolbar.hitTestable(), findsNothing);
    },
  );

  testWidgets('toolbar swipe up hides both overlays', (tester) async {
    await _open(tester, const Size(390, 844));
    await _tap(tester, .5);
    await tester.timedDrag(
      find.byKey(const ValueKey('reader-header-title')),
      const Offset(0, -90),
      const Duration(seconds: 1),
    );
    await tester.pumpAndSettle();
    expect(_toolbar.hitTestable(), findsNothing);
    expect(
      find.byKey(const ValueKey('reader-phone-bar')).hitTestable(),
      findsNothing,
    );
  });

  testWidgets('a refused PDF link never becomes a page-zone tap', (
    tester,
  ) async {
    await _open(
      tester,
      const Size(390, 844),
      links: [
        PdfPageLink(
          rects: const [PdfLinkRect(0, 0, 612, 792)],
          url: Uri.parse('file:///etc/passwd'),
        ),
      ],
    );
    await _tap(tester, .85);
    expect(_status(tester), '20% · page 1 of 5');
    expect(_toolbar.hitTestable(), findsNothing);
  });

  for (final rtl in [false, true]) {
    testWidgets(
      'first touch hint dismisses without turning and saves (RTL $rtl)',
      (tester) async {
        final saved = <ReaderDisplayChange>[];
        await _open(
          tester,
          const Size(390, 844),
          rtl: rtl,
          settings: _settings.copyWith(zonesHintDismissed: false),
          save: saved.add,
        );
        final hint = find.byKey(const ValueKey('reader-zones-hint'));
        expect(hint, findsOneWidget);
        expect(
          tester.getCenter(find.text('Next page')).dx,
          rtl ? lessThan(195) : greaterThan(195),
        );
        await _tap(tester, .15);
        expect(hint, findsNothing);
        expect(_place(tester), 'page 1 of 5');
        expect(saved.single.zonesHintDismissed, isTrue);
        await _open(tester, const Size(900, 1000), settings: _settings);
        expect(
          hint,
          findsNothing,
          reason: 'saved device dismissal survives a new reader',
        );
        await _open(
          tester,
          const Size(1280, 800),
          settings: _settings.copyWith(zonesHintDismissed: false),
        );
        expect(
          hint,
          findsNothing,
          reason: 'desktop never has an instruction overlay',
        );
      },
    );
  }

  testWidgets('Progress changes only the folio and is handed to persistence', (
    tester,
  ) async {
    final saved = <ReaderDisplayChange>[];
    await _open(tester, const Size(390, 844), save: saved.add);
    expect(_place(tester), 'page 1 of 5');
    final style = tester.widget<Text>(_folio).style!;
    expect(style.fontFamily, 'Inter');
    expect(style.fontFamilyFallback, ['Noto Sans JP']);
    await _tap(tester, .5);
    await tester.tap(find.byKey(const ValueKey('reader-header-typography')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reader-progress-percent')));
    await tester.pumpAndSettle();
    expect(_place(tester), '20%');
    expect(saved.last.progress, FlutterReaderProgress.percent);
    await tester.tap(find.byKey(const ValueKey('reader-progress-off')));
    await tester.pumpAndSettle();
    expect(_place(tester), isEmpty);
    expect(saved.last.progress, FlutterReaderProgress.off);
  });
}
