import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
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
  bool longChapter = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = ratio;
  addTearDown(tester.view.reset);
  final bridge = _Book(rtl: rtl, links: links);
  if (longChapter) {
    bridge.epubBytes = File(
      'fixtures/epub-layout/long-chapter.epub',
    ).readAsBytesSync();
  }
  final reader = ReaderScreen(
    key: UniqueKey(),
    bridge: bridge,
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

  testWidgets('a PDF tap turn changes the place line with the curl', (
    tester,
  ) async {
    await _open(tester, const Size(390, 844));
    final root = tester.getTopLeft(find.byKey(harnessBoundaryKey));
    final width = tester.getSize(find.byKey(harnessBoundaryKey)).width.ceil();
    final line = tester.getRect(_folio).shift(-root);
    int change(List<int> a, List<int> b) => [
      for (var i = 0; i < a.length; i++) (a[i] - b[i]).abs(),
    ].reduce(math.max);
    Future<List<int>> place() async {
      final pixels = await captureHarnessRgba(tester);
      return [
        for (var y = line.top.ceil(); y < line.bottom.floor(); y++)
          for (var x = line.left.ceil(); x < line.right.floor(); x++)
            ...pixels.sublist((y * width + x) * 4, (y * width + x) * 4 + 3),
      ];
    }

    expect(_place(tester), 'page 1 of 5');
    final before = await place();
    final rect = tester.getRect(_stage);
    await tester.tapAt(Offset(rect.left + rect.width * .9, rect.center.dy));
    for (var frame = 0; frame < 20 && curl.evaluate().isEmpty; frame++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 5));
    }
    expect(curl, findsOneWidget);
    expect(_place(tester), 'page 2 of 5');
    // The leaf has barely moved, and the line under it with it.
    expect(change(await place(), before), lessThan(16));
    await tester.pumpAndSettle();
    expect(curl, findsNothing);
    expect(change(await place(), before), greaterThan(64));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a PDF tap turn on a tablet keeps the page shadow as it is', (
    tester,
  ) async {
    await _open(
      tester,
      const Size(1180, 820),
      settings: _settings.copyWith(twoPages: true),
    );
    // Past the cover, onto a spread.
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.pumpAndSettle();
    final root = tester.getTopLeft(find.byKey(harnessBoundaryKey));
    final width = tester.getSize(find.byKey(harnessBoundaryKey)).width.ceil();
    final page = tester.getRect(
      find.byKey(const ValueKey('reader-pdf-page-shadow')),
    );
    // Under the page, where `shadow-page` is darkest, and past its corner.
    final points = [
      page.bottomCenter + const Offset(0, 14),
      page.bottomLeft + const Offset(-4, 10),
    ];
    Future<List<int>> shadow() async {
      final pixels = await captureHarnessRgba(tester);
      return [
        for (final point in points)
          for (final (x, y) in [
            ((point - root).dx.toInt(), (point - root).dy.toInt()),
          ])
            ...pixels.sublist((y * width + x) * 4, (y * width + x) * 4 + 3),
      ];
    }

    final before = await shadow();
    final rect = tester.getRect(_stage);
    await tester.tapAt(Offset(rect.left + rect.width * .9, rect.center.dy));
    for (var frame = 0; frame < 20 && curl.evaluate().isEmpty; frame++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 5));
    }
    expect(curl, findsOneWidget);
    for (final step in [120, 120]) {
      await tester.pump(Duration(milliseconds: step));
      expect(curl, findsOneWidget);
      final during = await shadow();
      expect([
        for (var i = 0; i < before.length; i++) (during[i] - before[i]).abs(),
      ], everyElement(lessThanOrEqualTo(2)));
    }
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

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
      final edges = <bool>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'setShown') calls.add(call.arguments as bool);
        if (call.method == 'setTurnEdges') edges.add(call.arguments as bool);
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
      // The quiet page takes the middle of the side edges from the back
      // gesture, and gives them back with the bars.
      expect(edges.last, isTrue);
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
      expect(edges.last, isFalse);
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

  for (final tablet in [false, true]) {
    testWidgets(
      'iOS status bar follows phone chrome but leaves tablet geometry fixed ($tablet)',
      (tester) async {
        final ratio = tablet ? 2.0 : 3.0;
        final size = tablet ? const Size(2360, 1640) : const Size(1290, 2796);
        var statusShown = true;
        void metrics() {
          final insets = FakeViewPadding(
            top: tablet ? (statusShown ? 64 : 0) : 177,
            bottom: tablet ? 50 : 102,
          );
          tester.view.viewPadding = insets;
          tester.view.padding = insets;
        }

        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'SystemChrome.setEnabledSystemUIOverlays') {
              statusShown = (call.arguments as List).contains(
                'SystemUiOverlay.top',
              );
              metrics();
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
        metrics();
        await _open(
          tester,
          size,
          ratio: ratio,
          path: '/books/atlas.epub',
          longChapter: true,
          shellFrame: true,
        );
        await _tap(tester, .85);
        expect(statusShown, tablet);
        final furniture = [
          _stage,
          _folio,
          find.byKey(const ValueKey('reader-running-head')),
          find.byKey(const ValueKey('reader-content-semantics')),
          if (tablet) find.byType(ShellMark),
          if (tablet) find.byTooltip('Library'),
        ];
        final before = furniture.map(tester.getRect).toList();
        final place = _status(tester);
        if (tablet) expect(before[4].top, greaterThanOrEqualTo(48));
        for (final shown in [true, false, true, false, true, false]) {
          await _tap(tester, .5);
          expect(_toolbar.hitTestable(), shown ? findsOneWidget : findsNothing);
          expect(statusShown, tablet || shown);
          expect(furniture.map(tester.getRect).toList(), before);
          expect(_status(tester), place);
          expect(tester.takeException(), isNull);
        }
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  }

  for (final (name, size, ratio, insets) in [
    (
      'iPhone 15 Pro Max',
      const Size(1290, 2796),
      3.0,
      const FakeViewPadding(top: 177, bottom: 102),
    ),
    (
      'Android gesture navigation',
      const Size(1080, 2400),
      3.0,
      const FakeViewPadding(top: 72, bottom: 72),
    ),
    (
      'Android three-button navigation',
      const Size(1080, 2340),
      3.0,
      const FakeViewPadding(top: 84, bottom: 144),
    ),
  ]) {
    for (final format in ['epub', 'pdf']) {
      testWidgets('$name $format furniture stays safe across chrome toggles', (
        tester,
      ) async {
        tester.view.viewPadding = insets;
        // Immersive edge-to-edge geometry: system bars are hidden, but the
        // physical cutout and gesture insets remain in viewPadding.
        tester.view.padding = FakeViewPadding.zero;
        await _open(
          tester,
          size,
          ratio: ratio,
          path: '/books/atlas.$format',
          longChapter: format == 'epub',
        );
        await _tap(tester, .85);
        expect(tester.widget<Text>(_folio).data, isNotEmpty);
        final head = find.byKey(const ValueKey('reader-running-head'));
        final surface = find.byKey(const ValueKey('reader-content-semantics'));
        final stageRect = tester.getRect(_stage);
        final folioRect = tester.getRect(_folio);
        final headRect = format == 'epub' ? tester.getRect(head) : null;
        final surfaceRect = tester.getRect(surface);
        expect(
          folioRect.bottom,
          lessThanOrEqualTo(size.height / ratio - insets.bottom / ratio),
        );
        if (headRect != null) {
          expect(tester.widget<Text>(head).data, isNotEmpty);
          expect(headRect.top, greaterThanOrEqualTo(insets.top / ratio));
        }
        for (final shown in [true, false, true, false]) {
          await _tap(tester, .5);
          tester.view.padding = shown ? insets : FakeViewPadding.zero;
          await tester.pumpAndSettle();
          expect(_toolbar.hitTestable(), shown ? findsOneWidget : findsNothing);
          expect(tester.getRect(_stage), stageRect);
          expect(tester.getRect(_folio), folioRect);
          if (headRect != null) expect(tester.getRect(head), headRect);
          expect(tester.getRect(surface), surfaceRect);
          expect(tester.takeException(), isNull);
        }
      });
    }
  }

  for (final width in [390.0, 900.0, 1280.0]) {
    for (final rtl in [false, true]) {
      testWidgets('touch zones and chrome never reflow ($width, RTL $rtl)', (
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
          findsNothing,
          reason: 'touch chrome leaves after three seconds',
        );
        await _tap(tester, .5);
        expect(_toolbar.hitTestable(), findsOneWidget);
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
      testWidgets('touch zones turn whole PDF spreads ($width, RTL $rtl)', (
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

  for (final width in [390.0, 600.0, 640.0, 900.0]) {
    for (final rtl in [false, true]) {
      testWidgets('quarter zones and hint match ($width, RTL $rtl)', (
        tester,
      ) async {
        await _open(
          tester,
          Size(width, 600),
          rtl: rtl,
          settings: _settings.copyWith(
            twoPages: true,
            zonesHintDismissed: false,
          ),
        );
        final area = tester.getRect(
          find.byKey(const ValueKey('reader-page-tap-area')),
        );
        final labels = [
          rtl ? 'Next page' : 'Previous page',
          'Controls',
          rtl ? 'Previous page' : 'Next page',
        ];
        for (var i = 0; i < labels.length; i++) {
          final column = tester.getRect(
            find
                .ancestor(
                  of: find.text(labels[i]),
                  matching: find.byType(CustomPaint),
                )
                .first,
          );
          expect(column.width, closeTo(area.width * (i == 1 ? .5 : .25), .01));
          expect(
            column.center.dx,
            closeTo(area.center.dx + (i - 1) * area.width * .375, .01),
          );
        }
        await _tap(tester, .5); // Dismiss onboarding, not reveal or turn.
        expect(_toolbar.hitTestable(), findsNothing);
        final left = area.left + area.width * .25;
        final right = area.left + area.width * .75;
        Future<void> tapX(double x) async {
          await tester.tapAt(Offset(x, area.center.dy));
          await tester.pump(const Duration(milliseconds: 350));
          await tester.pumpAndSettle();
        }

        await tapX(left);
        expect(_toolbar.hitTestable(), findsOneWidget);
        await tapX(right - 1);
        expect(_toolbar.hitTestable(), findsNothing);
        await tapX(rtl ? left - 1 : right);
        expect(_toolbar.hitTestable(), findsNothing);
        expect(
          _status(tester),
          width == 900 ? '60% · pages 2–3 of 5' : '40% · page 2 of 5',
        );
        await tapX(rtl ? right + 1 : left - 1);
        expect(_status(tester), '20% · page 1 of 5');
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final width in [390.0, 900.0]) {
    testWidgets('touch idle waits for all fingers and cancellation ($width)', (
      tester,
    ) async {
      await _open(tester, Size(width, 844));
      await _tap(tester, .5);
      // A non-actionable toolbar location exercises raw touch activity without
      // a page tap, page turn, or panel opening hiding/pinning the chrome.
      final title = tester.getCenter(
        find.byKey(const ValueKey('reader-header-title')),
      );
      final first = await tester.startGesture(title, pointer: 11);
      await tester.pump(const Duration(seconds: 4));
      expect(_toolbar.hitTestable(), findsOneWidget);
      final second = await tester.startGesture(title, pointer: 12);
      await first.up();
      await tester.pump(const Duration(seconds: 4));
      expect(_toolbar.hitTestable(), findsOneWidget);
      await second.cancel();
      await tester.pump(const Duration(milliseconds: 2999));
      expect(_toolbar.hitTestable(), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump(const Duration(milliseconds: 200));
      expect(_toolbar.hitTestable(), findsNothing);
    });

    for (final panel in ['contents', 'typography', 'notes']) {
      testWidgets('touch $panel pins chrome then restarts idle ($width)', (
        tester,
      ) async {
        await _open(tester, Size(width, 844));
        await _tap(tester, .5);
        await tester.tap(find.byKey(ValueKey('reader-header-$panel')));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 5));
        expect(_toolbar.hitTestable(), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 2999));
        expect(_toolbar.hitTestable(), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 201));
        expect(_toolbar.hitTestable(), findsNothing);
      });
    }

    testWidgets('reference popover pins touch chrome ($width)', (tester) async {
      final links = <PdfPageLink>[];
      await _open(tester, Size(width, 844), links: links);
      await _tap(tester, .5);
      links.add(
        const PdfPageLink(rects: [PdfLinkRect(0, 0, 612, 792)], page: 1),
      );
      await _tap(tester, .5);
      expect(
        find.byKey(const ValueKey('reader-reference-peek')),
        findsOneWidget,
      );
      final preview = tester.widget<Text>(
        find.byKey(const ValueKey('reader-reference-preview')),
      );
      expect(preview.style!.fontWeight, FontWeight.w400);
      expect(preview.style!.fontVariations, [
        const ui.FontVariation('wght', 400),
      ]);
      await tester.pump(const Duration(seconds: 5));
      // The modal barrier covers the toolbar's hit targets, but must not
      // allow its chrome to fade underneath the reference card.
      expect(
        tester
            .widget<AnimatedOpacity>(
              find
                  .ancestor(
                    of: _toolbar,
                    matching: find.byType(AnimatedOpacity),
                  )
                  .first,
            )
            .opacity,
        1,
      );
      await tester.tap(find.byKey(const ValueKey('reader-reference-close')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 2999));
      expect(_toolbar.hitTestable(), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 201));
      expect(_toolbar.hitTestable(), findsNothing);
    });
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
        if (call.method == 'setTurnEdges') return null;
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

  for (final width in [390.0, 900.0, 1199.0, 1280.0]) {
    testWidgets(
      'desktop input is independent of shell width ($width)',
      (tester) async {
        await _open(
          tester,
          Size(width, 844),
          settings: _settings.copyWith(zonesHintDismissed: false),
        );
        final hint = find.byKey(const ValueKey('reader-zones-hint'));
        expect(hint, findsNothing, reason: 'desktop has no touch instruction');
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: const Offset(0, 0));
        addTearDown(mouse.removePointer);
        await mouse.moveTo(tester.getCenter(_stage));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 180));
        expect(_toolbar.hitTestable(), findsOneWidget);
        expect(hint, findsNothing);
        await tester.pump(const Duration(seconds: 2));
        await tester.pump(const Duration(milliseconds: 180));
        expect(_toolbar.hitTestable(), findsNothing);

        // A real touchscreen still uses zones, even on a desktop platform.
        await _tap(tester, .85);
        expect(_status(tester), '40% · page 2 of 5');
        await _tap(tester, .5);
        expect(_toolbar.hitTestable(), findsOneWidget);
        expect(hint, findsNothing);
        await _tap(tester, .5);
        expect(_toolbar.hitTestable(), findsNothing);

        // The mouse click must not reuse touch mode and pin chrome forever.
        await tester.tapAt(
          tester.getCenter(_stage),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pumpAndSettle();
        expect(_toolbar.hitTestable(), findsNothing);
        expect(_status(tester), '40% · page 2 of 5');
        await mouse.moveBy(const Offset(12, 8));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 180));
        expect(_toolbar.hitTestable(), findsOneWidget);
        await tester.pump(const Duration(seconds: 2));
        await tester.pump(const Duration(milliseconds: 180));
        expect(_toolbar.hitTestable(), findsNothing);
        await mouse.moveBy(const Offset(12, 8));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 180));
        await mouse.moveTo(const Offset(-1, -1));
        await tester.pump(const Duration(milliseconds: 180));
        expect(_toolbar.hitTestable(), findsNothing);
        expect(tester.takeException(), isNull);
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.macOS,
        TargetPlatform.linux,
        TargetPlatform.windows,
      }),
    );
  }

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

  testWidgets(
    'the Aa sheet dims the page between the toolbar and the bottom bar',
    (tester) async {
      await _open(tester, const Size(390, 844));
      tester.view.viewPadding = const FakeViewPadding(top: 52, bottom: 24);
      tester.view.padding = tester.view.viewPadding;
      await tester.pumpAndSettle();
      await _tap(tester, .5);
      await tester.tap(find.byKey(const ValueKey('reader-header-typography')));
      await tester.pumpAndSettle();
      final header = tester.getRect(
        find.byKey(const ValueKey('reader-header')),
      );
      final scrim = tester.getRect(
        find.byKey(const ValueKey('reader-panel-scrim')),
      );
      // The toolbar sits under the status bar; none of it is left half dimmed.
      expect(header.top, 52);
      expect(scrim.top, header.bottom);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}
