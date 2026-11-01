import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_flutter/core/bridge.dart';
import 'package:shosai_flutter/reader/controller.dart' show ReaderDisplayChange;
import 'package:shosai_flutter/reader/pdf/engine.dart';
import 'package:shosai_flutter/reader/view.dart';
import 'package:shosai_flutter/shell/view.dart';

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
  bool reducedMotion = false,
  void Function(ReaderDisplayChange)? save,
  String path = '/books/atlas.pdf',
  bool pushRoute = false,
  bool shellFrame = false,
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
  Widget home = reader;
  if (shellFrame) {
    final book = harnessLibraryBooks().firstWhere(
      (book) => book.format == FlutterBookFormat.pdf,
    );
    home = Directionality(
      textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        body: ShellFrame(
          layout: ShellLayout.forWidth(size.width / ratio),
          model: ShellModel(
            openBooks: [OpenBook(book: book, path: path)],
            currentBookId: book.bookId,
            reading: true,
          ),
          covers: const {},
          actions: ShellActions(
            selectPlace: (_) {},
            openBook: (_) {},
            closeBook: (_) {},
            moveBook: (_, _) {},
            addBooks: null,
            loadCover: (_) => false,
          ),
          child: reader,
        ),
      ),
    );
  }
  await tester.pumpWidget(
    productionShell(
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(disableAnimations: reducedMotion),
          child: pushRoute
              ? Builder(
                  builder: (context) => TextButton(
                    onPressed: () => Navigator.of(
                      context,
                    ).push(MaterialPageRoute<void>(builder: (_) => reader)),
                    child: const Text('Open reader'),
                  ),
                )
              : home,
        ),
      ),
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

  final curl = find.byKey(const ValueKey('reader-page-curl'));
  for (final rtl in [false, true]) {
    for (final last in [false, true]) {
      testWidgets(
        'furniture curl reverses at the book edge (RTL $rtl, last $last)',
        (tester) async {
          await _open(tester, const Size(390, 844), rtl: rtl);
          if (last) {
            for (var page = 0; page < 4; page++) {
              await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
              await tester.pumpAndSettle();
            }
          }
          final place = _status(tester);
          final sign = (rtl ? 1.0 : -1.0) * (last ? -1 : 1);
          final gesture = await tester.startGesture(tester.getCenter(_folio));
          await gesture.moveBy(Offset(sign * 30, 0));
          await gesture.moveBy(Offset(sign * 90, 0));
          await tester.pump();
          expect(curl, findsOneWidget);
          await gesture.moveBy(Offset(-sign * 240, 0));
          await gesture.up();
          await tester.pumpAndSettle();
          expect(curl, findsNothing);
          expect(_status(tester), place);
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets(
      'curl follows a held drag, cancels, and commits past half (RTL $rtl)',
      (tester) async {
        await _open(tester, const Size(390, 844), rtl: rtl);
        final rect = tester.getRect(
          find.byKey(const ValueKey('reader-selection-surface')),
        );
        final start = Offset(
          rect.left + rect.width * (rtl ? .1 : .9),
          rect.center.dy,
        );
        final sign = rtl ? 1.0 : -1.0;
        final gesture = await tester.startGesture(start);
        await gesture.moveBy(
          Offset(sign * 30, 0),
          timeStamp: const Duration(milliseconds: 100),
        );
        await gesture.moveBy(
          Offset(sign * 100, 0),
          timeStamp: const Duration(milliseconds: 600),
        );
        await tester.pump();
        expect(curl, findsOneWidget, reason: 'the page lifts before release');
        expect(_status(tester), '20% · page 1 of 5');
        await gesture.up(timeStamp: const Duration(milliseconds: 1000));
        await tester.pumpAndSettle();
        expect(curl, findsNothing);
        expect(
          _status(tester),
          '20% · page 1 of 5',
          reason: 'a slow short drag never turns',
        );

        final committed = await tester.startGesture(start);
        await committed.moveBy(
          Offset(sign * 30, 0),
          timeStamp: const Duration(milliseconds: 100),
        );
        await committed.moveBy(
          Offset(sign * 200, 0),
          timeStamp: const Duration(milliseconds: 900),
        );
        await tester.pump();
        expect(curl, findsOneWidget);
        expect(_status(tester), '20% · page 1 of 5');
        await committed.up(timeStamp: const Duration(milliseconds: 1400));
        await tester.pumpAndSettle();
        expect(_status(tester), '40% · page 2 of 5');
        expect(curl, findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'PDF cover and paired leaf use their fitted midpoint (RTL $rtl)',
      (tester) async {
        await _open(
          tester,
          const Size(1280, 800),
          rtl: rtl,
          settings: _settings.copyWith(twoPages: true),
        );
        final surface = find.byKey(const ValueKey('reader-selection-surface'));
        final sign = rtl ? 1.0 : -1.0;
        for (final paired in [false, true]) {
          final origin = _status(tester);
          expect(origin, contains(paired ? 'pages 2–3' : 'page 1 of 5'));
          final painter = tester
              .widgetList<CustomPaint>(find.byType(CustomPaint))
              .map((p) => p.painter)
              .whereType<PagePainter>()
              .single;
          final image = painter.image!;
          final rect = tester.getRect(surface);
          final fitted = Alignment.center.inscribe(
            applyBoxFit(
              BoxFit.contain,
              Size(image.width.toDouble(), image.height.toDouble()),
              rect.size,
            ).destination,
            rect,
          );
          final leafWidth = fitted.width / (paired ? 2 : 1);
          for (final fraction in [.35, .6]) {
            final gesture = await tester.startGesture(
              Offset(
                rtl ? fitted.left + 20 : fitted.right - 20,
                fitted.center.dy,
              ),
            );
            await gesture.moveBy(
              Offset(sign * 30, 0),
              timeStamp: const Duration(milliseconds: 100),
            );
            await gesture.moveBy(
              Offset(sign * (leafWidth * fraction - 30), 0),
              timeStamp: const Duration(milliseconds: 1200),
            );
            await tester.pump(const Duration(milliseconds: 800));
            expect(curl, findsOneWidget);
            expect(_status(tester), origin);
            await gesture.up(timeStamp: const Duration(milliseconds: 2000));
            await tester.pumpAndSettle();
            expect(
              _status(tester),
              fraction < .5 ? origin : isNot(origin),
              reason: '$fraction of the actual fitted leaf, not the viewport',
            );
          }
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('keys curl for 350ms and both motion gates change immediately', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    for (final gate in ['on', 'setting', 'system']) {
      await _open(
        tester,
        const Size(390, 844),
        settings: _settings.copyWith(animations: gate != 'setting'),
        reducedMotion: gate == 'system',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.pump();
      await tester.pump();
      expect(_status(tester), '40% · page 2 of 5');
      expect(curl, gate == 'on' ? findsOneWidget : findsNothing);
      await tester.pump(const Duration(milliseconds: 175));
      expect(curl, gate == 'on' ? findsOneWidget : findsNothing);
      expect(
        tester
            .getSemantics(
              find.byKey(const ValueKey('reader-document-semantics')),
            )
            .label,
        contains('page 2 of 5'),
        reason: 'the covered live page stays available to screen readers',
      );
      await tester.pumpAndSettle();
      expect(curl, findsNothing);
    }
    semantics.dispose();
  });

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
    'Android ignores stale portrait insets after a newer landscape response',
    (tester) async {
      const channel = MethodChannel('dev.shosai/reader_system_bars');
      final pending = <Completer<List<int>>>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) {
        if (call.method != 'getStableInsets') return Future.value();
        final response = Completer<List<int>>();
        pending.add(response);
        return response.future;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      await _open(tester, const Size(780, 1688), ratio: 2);
      tester.view.physicalSize = const Size(1688, 780);
      await tester.pump();
      // The newest request completes first; the portrait requests stay pending.
      pending.removeLast().complete([96, 0, 48, 0]);
      await tester.pumpAndSettle();
      expect(tester.getRect(_stage).left, 48);
      expect(tester.getRect(_stage).right, 820);
      await _tap(tester, .85);
      await _tap(tester, .85);
      expect(_status(tester), '60% · page 3 of 5');
      final surface = find.byKey(const ValueKey('reader-selection-surface'));
      final before = tester.getRect(surface);
      final stage = tester.getRect(_stage);
      for (final response in pending.reversed) {
        response.complete([0, 96, 0, 48]);
        await tester.pumpAndSettle();
        expect(tester.getRect(_stage), stage);
        expect(tester.getRect(surface), before);
        expect(_status(tester), '60% · page 3 of 5');
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  for (final rtl in [false, true]) {
    testWidgets(
      'Android landscape insets compose with the real shell (RTL $rtl)',
      (tester) async {
        const channel = MethodChannel('dev.shosai/reader_system_bars');
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (call) async =>
              call.method == 'getStableInsets' ? [96, 20, 48, 40] : null,
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            null,
          ),
        );
        await _open(
          tester,
          const Size(1800, 1000),
          ratio: 2,
          rtl: rtl,
          shellFrame: true,
        );
        await tester.pumpAndSettle();
        await _tap(tester, rtl ? .15 : .85);
        await _tap(tester, rtl ? .15 : .85);
        expect(_status(tester), '60% · page 3 of 5');
        // A 56px tablet rail plus 48px left / 24px right stable admission.
        expect(tester.getRect(_stage).left, rtl ? 48 : 104);
        expect(tester.getRect(_stage).right, rtl ? 820 : 876);
        final stage = tester.getRect(_stage);
        final surface = find.byKey(const ValueKey('reader-selection-surface'));
        final before = tester.getRect(surface);
        for (var i = 0; i < 3; i++) {
          await _tap(tester, .5);
          expect(_toolbar.hitTestable(), findsOneWidget);
          tester.view.viewPadding = const FakeViewPadding(
            left: 96,
            top: 20,
            right: 48,
            bottom: 40,
          );
          tester.view.padding = tester.view.viewPadding;
          await tester.pumpAndSettle();
          expect(tester.getRect(_stage), stage);
          expect(tester.getRect(surface), before);
          expect(_status(tester), '60% · page 3 of 5');
          await _tap(tester, .5);
          expect(_toolbar.hitTestable(), findsNothing);
          tester.view.viewPadding = FakeViewPadding.zero;
          tester.view.padding = FakeViewPadding.zero;
          await tester.pumpAndSettle();
          expect(tester.getRect(_stage), stage);
          expect(tester.getRect(surface), before);
          expect(_status(tester), '60% · page 3 of 5');
        }
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
        await tester.fling(surface, Offset(rtl ? 180 : -180, 0), 1000);
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
    await tester.fling(_folio, const Offset(-160, 0), 1000);
    await tester.pumpAndSettle();
    expect(_place(tester), 'page 2 of 5');
    await tester.fling(_folio, const Offset(160, 0), 1000);
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
