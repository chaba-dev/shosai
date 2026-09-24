import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_flutter/main.dart';
import 'package:shosai_flutter/src/rust/api.dart';

import '../support/production_shell_harness.dart';

/// Production-shell renders.
///
/// Every state renders [ShosaiShell], the composition `main.dart` uses, with a
/// deterministic bridge beneath it. Each test also runs the render detectors so
/// an appearance change that introduces overflow or clipped text fails here
/// instead of only changing golden pixels.
void main() {
  setUpAll(loadHarnessFonts);

  /// Defects that exist in the current production shell and are owned by a
  /// later package. An entry is an explicit exception: anything else fails.
  const knownDefects = <KnownRenderDefect>[];

  Future<void> check(
    WidgetTester tester,
    String name,
    HarnessView view, {
    required Widget widget,
    Map<String, Object?> metadata = const {},
    required bool Function() ready,
    Future<void> Function(WidgetTester tester)? verify,
  }) async {
    final recorder = RenderErrorRecorder.install();
    addTearDown(recorder.dispose);
    view.apply(tester);
    await renderHarnessState(tester, widget, ready: ready);

    // Language assertions run before the artifact is written, so a state named
    // for a locale cannot leave an artifact it did not actually render.
    if (verify != null) {
      await verify(tester);
    }

    // Evidence before assertions: a failing render must still leave its drift,
    // its defect measurements and its screenshot behind.
    final characterized = <RenderDefect>[];
    final defects = await findRenderDefects(
      tester,
      characterized: characterized,
    );
    final drift = await collectHarnessGoldenDrift(tester, name);
    await captureHarnessArtifact(
      tester,
      name,
      metadata: <String, Object?>{
        ...view.toMetadata(),
        ...metadata,
        ...harnessPlatformMetrics(),
        'defects': defects.map((defect) => defect.toMetadata()).toList(),
        'characterized': characterized
            .map((defect) => defect.toMetadata())
            .toList(),
        'drift': drift.toMetadata(),
      },
    );
    for (final defect in characterized) {
      // ignore: avoid_print
      print('overhang evidence in $name: $defect');
    }

    expect(
      recorder.overflowErrors,
      isEmpty,
      reason: 'Flutter reported a layout overflow in $name',
    );
    expect(tester.takeException(), isNull);
    expectOnlyKnownDefects(defects, knownDefects);
    await expectHarnessGolden(tester, name);
  }

  HarnessBridge libraryBridge({List<FlutterLibraryBook>? books}) =>
      HarnessBridge(
        books: books ?? harnessLibraryBooks(),
        covers: harnessCovers(),
      );

  group('library', () {
    testWidgets('normal wide English library renders on the production shell', (
      tester,
    ) async {
      final bridge = libraryBridge();
      await check(
        tester,
        'library-normal-1280',
        const HarnessView(size: Size(1280, 800)),
        widget: productionApp(
          bridgeFactory: () => bridge,
          locale: const Locale('en'),
        ),
        metadata: const <String, Object?>{},
        ready: () => harnessImagesReady(tester),
      );
    });

    testWidgets('compact English library renders on the production shell', (
      tester,
    ) async {
      final bridge = libraryBridge();
      await check(
        tester,
        'library-compact-390',
        const HarnessView(size: Size(390, 780)),
        widget: productionApp(
          bridgeFactory: () => bridge,
          locale: const Locale('en'),
        ),
        metadata: const <String, Object?>{},
        ready: () => harnessImagesReady(tester),
      );
    });

    testWidgets('compact Japanese library at 200% text', (tester) async {
      final bridge = libraryBridge(
        books: const [
          FlutterLibraryBook(
            bookId: 2,
            title: '海辺の図書館 — 失われた書架をめぐる長い旅路',
            author: '紫式部',
            format: FlutterBookFormat.epub,
            pathKey: '/books/umibe.epub',
            managed: true,
            progress: 0.07,
            dateAdded: '2026-09-11',
            lastRead: '2026-09-18T21:40:00Z',
          ),
          FlutterLibraryBook(
            bookId: 6,
            title: '短い',
            author: '芥川龍之介',
            format: FlutterBookFormat.epub,
            pathKey: '/books/mijikai.epub',
            managed: true,
            progress: 0.5,
            dateAdded: '2026-09-15',
          ),
        ],
      );
      await check(
        tester,
        'library-compact-390-ja-t200',
        const HarnessView(size: Size(390, 780), textScale: 2),
        widget: productionApp(
          bridgeFactory: () => bridge,
          locale: const Locale('ja'),
        ),
        metadata: const <String, Object?>{'config': 'C390 T200'},
        ready: () => harnessImagesReady(tester),
        verify: (tester) async {
          // A capture named for Japanese must select that interface.
          expect(find.text('ライブラリ'), findsOneWidget);
          expect(find.text('Library'), findsNothing);
        },
      );
    });

    testWidgets('wide Japanese library at 200% text', (tester) async {
      final bridge = libraryBridge();
      await check(
        tester,
        'library-wide-900-ja-t200',
        const HarnessView(size: Size(900, 700), textScale: 2),
        widget: productionApp(
          bridgeFactory: () => bridge,
          locale: const Locale('ja'),
        ),
        metadata: const <String, Object?>{'config': 'W900 T200'},
        ready: () => harnessImagesReady(tester),
        verify: (tester) async {
          // A capture named for Japanese must select that interface.
          expect(find.text('ライブラリ'), findsOneWidget);
          expect(find.text('Library'), findsNothing);
        },
      );
    });

    testWidgets('mixed-script metadata with long tokens', (tester) async {
      final bridge = libraryBridge(
        books: harnessLibraryBooks()
            .where((book) => const {2, 3, 4}.contains(book.bookId))
            .toList(),
      );
      await check(
        tester,
        'library-mixed-1280',
        const HarnessView(size: Size(1280, 800)),
        widget: productionApp(
          bridgeFactory: () => bridge,
          locale: const Locale('en'),
        ),
        metadata: const <String, Object?>{'config': 'W1280'},
        ready: () => harnessImagesReady(tester),
      );
    });

    testWidgets('empty library state', (tester) async {
      final bridge = libraryBridge(books: const []);
      await check(
        tester,
        'library-empty-1280',
        const HarnessView(size: Size(1280, 800)),
        widget: productionApp(
          bridgeFactory: () => bridge,
          locale: const Locale('en'),
        ),
        metadata: const <String, Object?>{'state': 'empty'},
        ready: () =>
            find.textContaining('library is empty').evaluate().isNotEmpty,
      );
    });
  });

  group('reader', () {
    testWidgets('welcome panel renders on the production shell', (
      tester,
    ) async {
      final bridge = HarnessBridge();
      await check(
        tester,
        'reader-welcome-1280',
        const HarnessView(size: Size(1280, 800)),
        widget: productionShell(home: ReaderScreen(bridge: bridge)),
        metadata: const <String, Object?>{'state': 'welcome'},
        ready: () => find
            .textContaining('Enter a local document path')
            .evaluate()
            .isNotEmpty,
      );
    });

    testWidgets('PDF page raster renders on the production shell', (
      tester,
    ) async {
      final bridge = HarnessBridge(books: harnessLibraryBooks());
      await check(
        tester,
        'reader-pdf-1280',
        const HarnessView(size: Size(1280, 800)),
        widget: productionShell(
          home: ReaderScreen(
            bridge: bridge,
            initialPath: '/books/donau.pdf',
            initialBookId: 3,
          ),
        ),
        metadata: const <String, Object?>{'state': 'pdf-page', 'format': 'pdf'},
        ready: () => harnessReaderPageReady(tester),
      );
      expect(bridge.pageCalls, greaterThan(0));
    });

    testWidgets('EPUB surface raster renders on the production shell', (
      tester,
    ) async {
      final bridge = HarnessBridge(books: harnessLibraryBooks());
      await check(
        tester,
        'reader-epub-1280',
        const HarnessView(size: Size(1280, 800)),
        widget: productionShell(
          home: ReaderScreen(
            bridge: bridge,
            initialPath: '/books/umibe.epub',
            initialBookId: 2,
          ),
        ),
        metadata: const <String, Object?>{
          'state': 'epub-page',
          'format': 'epub',
        },
        ready: () => harnessReaderPageReady(tester),
      );
    });
  });

  testWidgets('an unready state fails instead of capturing a partial frame', (
    tester,
  ) async {
    const view = HarnessView(size: Size(400, 300));
    view.apply(tester);
    Object? error;
    try {
      await renderHarnessState(
        tester,
        productionShell(home: const Scaffold(body: SizedBox())),
        ready: () => false,
        maxRounds: 2,
      );
    } catch (caught) {
      error = caught;
    }
    expect(error, isA<HarnessNotReadyException>());
  });

  testWidgets('two fresh renders of one state are pixel-identical', (
    tester,
  ) async {
    const view = HarnessView(size: Size(900, 700));
    view.apply(tester);

    Future<(Uint8List, Uint8List, HarnessBridge)> renderOnce({
      required bool unmount,
    }) async {
      final bridge = libraryBridge();
      await renderHarnessState(
        tester,
        productionApp(bridgeFactory: () => bridge),
        ready: () => harnessImagesReady(tester),
      );
      final rgba = await captureHarnessRgba(tester);
      final png = await captureHarnessPng(tester);
      if (unmount) {
        // Unmount and drain so the next render starts from a fresh shell and a
        // fresh bridge instead of reusing this render's state.
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      }
      return (rgba, png, bridge);
    }

    final (first, _, firstBridge) = await renderOnce(unmount: true);
    final (second, secondPng, secondBridge) = await renderOnce(unmount: false);
    expect(firstBridge.coverCalls, greaterThan(0));
    expect(secondBridge.coverCalls, greaterThan(0));
    expect(
      second,
      equals(first),
      reason: describePixelDifference(first, second, width: 900),
    );
    writeHarnessArtifact(
      'repeat-render-900',
      secondPng,
      metadata: <String, Object?>{
        ...view.toMetadata(),
        'deterministic': 'raw RGBA identical across two fresh renders',
      },
    );
  });
}
