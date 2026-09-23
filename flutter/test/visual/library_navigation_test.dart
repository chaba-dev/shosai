import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shosai_flutter/app_theme.dart';
import 'package:shosai_flutter/library/view.dart';
import 'package:shosai_flutter/src/rust/api.dart';
import 'package:shosai_flutter/theme_tokens.dart';

import '../support/production_shell_harness.dart';

/// Package 3A rendered states (`3A-RENDER`).
///
/// Each state renders the production shell with the deterministic harness
/// bridge, runs the geometry detectors, asserts the composition's mapped
/// metrics and captures an artifact for inspection next to its metadata. The
/// package ships no new golden baseline: the committed library goldens still
/// record the pre-3A composition until the owner approves replacements, so the
/// renders here are candidates for that review rather than a pixel gate.
void main() {
  setUpAll(loadHarnessFonts);

  /// Captures the current frame with its metadata and runs the detectors.
  ///
  /// Every captured state goes through this, including the ones captured after
  /// an interaction, so the artifact a reviewer inspects is the state that was
  /// asserted and its defect list belongs to the same frame.
  Future<void> captureState(
    WidgetTester tester,
    String name,
    HarnessView view,
    Map<String, Object?> metadata,
  ) async {
    final defects = await findRenderDefects(tester);
    await captureHarnessArtifact(
      tester,
      name,
      metadata: <String, Object?>{
        ...view.toMetadata(),
        ...metadata,
        'defects': defects.map((defect) => defect.toMetadata()).toList(),
      },
    );
    expectOnlyKnownDefects(defects, const <KnownRenderDefect>[]);
    expect(tester.takeException(), isNull);
  }

  Future<HarnessBridge> render(
    WidgetTester tester,
    String name,
    HarnessView view, {
    required bool Function() ready,
    List<FlutterLibraryBook>? books,
    Map<String, Object?> metadata = const {},
  }) async {
    final bridge = HarnessBridge(
      books: books ?? harnessLibraryBooks(),
      covers: harnessCovers(),
    );
    view.apply(tester);
    await renderHarnessState(
      tester,
      productionShell(
        home: ProductShell(
          bridgeFactory: () => bridge,
          readerBuilder: (_, _, _, _, _, _) => const SizedBox(),
        ),
      ),
      ready: ready,
    );
    await captureState(tester, name, view, metadata);
    return bridge;
  }

  Finder entry(String label) => find.widgetWithText(ShadButton, label);

  /// The painted color at [point] in the captured frame.
  Future<Color> paintedColorAt(WidgetTester tester, Offset point) async {
    final rgba = await captureHarnessRgba(tester);
    final width =
        tester.view.physicalSize.width ~/ tester.view.devicePixelRatio;
    final offset =
        ((point.dy * tester.view.devicePixelRatio).round() * width +
            (point.dx * tester.view.devicePixelRatio).round()) *
        4;
    return Color.fromARGB(
      rgba[offset + 3],
      rgba[offset],
      rgba[offset + 1],
      rgba[offset + 2],
    );
  }

  group('wide composition', () {
    testWidgets('W1280 English', (tester) async {
      await render(
        tester,
        '3a-library-wide-1280-en',
        const HarnessView(size: Size(1280, 800)),
        ready: () => harnessImagesReady(tester),
        metadata: const <String, Object?>{'locale': 'en', 'state': 'wide'},
      );

      expect(find.byType(LibrarySidebar), findsOneWidget);
      expect(
        tester.getSize(find.byType(LibrarySidebar)).width,
        ShosaiTokens.layoutLibrarySidebarWidth,
      );
      expect(
        tester.getSize(find.byType(ShadInput)).width,
        ShosaiTokens.layoutLibraryHeaderSearchMaxWidth,
      );
      expect(entry('All books'), findsOneWidget);
      expect(entry('Settings'), findsOneWidget);
    });

    testWidgets('W1280 Japanese metadata', (tester) async {
      await render(
        tester,
        '3a-library-wide-1280-ja',
        const HarnessView(size: Size(1280, 800)),
        books: harnessLibraryBooks()
            .where((book) => const {2, 4, 6}.contains(book.bookId))
            .toList(),
        ready: () => harnessImagesReady(tester),
        metadata: const <String, Object?>{
          'locale': 'ja',
          'state': 'wide-japanese-metadata',
        },
      );

      expect(find.text('海辺の図書館 — 失われた書架をめぐる長い旅路'), findsOneWidget);
      expect(
        find.text('Mixed Script Atlas: 東京・Wien・São Paulo'),
        findsOneWidget,
      );
      expect(entry('Settings'), findsOneWidget);
    });

    testWidgets('W1280 with the PDF filter selected', (tester) async {
      const view = HarnessView(size: Size(1280, 800));
      final bridge = HarnessBridge(
        books: harnessLibraryBooks(),
        covers: harnessCovers(),
      );
      view.apply(tester);
      await renderHarnessState(
        tester,
        productionShell(
          home: ProductShell(
            bridgeFactory: () => bridge,
            readerBuilder: (_, _, _, _, _, _) => const SizedBox(),
          ),
        ),
        ready: () => harnessImagesReady(tester),
      );

      await tester.tap(entry('PDF'));
      await tester.pumpAndSettle();

      // The captured frame is the asserted state: the PDF entry is selected
      // and the collection shows the PDF book.
      expect(
        tester.widget<ShadButton>(entry('PDF')).backgroundColor,
        ShosaiTokens.appAccentSoft,
      );
      expect(
        tester.widget<ShadButton>(entry('All books')).backgroundColor,
        isNull,
      );
      expect(
        find.text(
          'Donaudampfschifffahrtsgesellschaftskapitaenskajuettenfenster',
        ),
        findsOneWidget,
      );
      await captureState(tester, '3a-library-filter-pdf-1280', view, const {
        'locale': 'en',
        'state': 'selected-filter',
        'filter': 'pdf',
      });
    });

    testWidgets('W1280 under the mapped dark theme', (tester) async {
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      await render(
        tester,
        '3a-library-wide-1280-dark',
        const HarnessView(size: Size(1280, 800)),
        ready: () => harnessImagesReady(tester),
        metadata: const <String, Object?>{
          'locale': 'en',
          'palette': 'application-dark',
          'state': 'wide-dark',
        },
      );

      final scheme = shosaiShadTheme(Brightness.dark).colorScheme;
      final header = tester.getRect(find.byType(LibraryHeader));
      expect(
        (await paintedColorAt(
          tester,
          Offset(header.right - 8, header.top + 8),
        )).toARGB32(),
        scheme.card.toARGB32(),
      );
      final sidebar = tester.getRect(find.byType(LibrarySidebar));
      expect(
        (await paintedColorAt(
          tester,
          Offset(sidebar.left + 8, sidebar.bottom - 8),
        )).toARGB32(),
        scheme.secondary.toARGB32(),
      );
      expect(
        tester.widget<ShadButton>(entry('All books')).backgroundColor,
        scheme.selection,
      );
    });

    testWidgets('W1280 with a keyboard-focused entry', (tester) async {
      const view = HarnessView(size: Size(1280, 800));
      final bridge = HarnessBridge(
        books: harnessLibraryBooks(),
        covers: harnessCovers(),
      );
      view.apply(tester);
      await renderHarnessState(
        tester,
        productionShell(
          home: ProductShell(
            bridgeFactory: () => bridge,
            readerBuilder: (_, _, _, _, _, _) => const SizedBox(),
          ),
        ),
        ready: () => harnessImagesReady(tester),
      );

      // Tab until the EPUB entry owns focus, so the captured frame shows the
      // focus ring on a known control.
      for (var step = 0; step < 8; step += 1) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        if (tester
                .getSemantics(find.text('EPUB'))
                .getSemanticsData()
                .flagsCollection
                .isFocused ==
            ui.Tristate.isTrue) {
          break;
        }
      }
      expect(
        tester
            .getSemantics(find.text('EPUB'))
            .getSemanticsData()
            .flagsCollection
            .isFocused,
        ui.Tristate.isTrue,
        reason: 'the captured frame shows the EPUB entry focused',
      );
      await captureState(tester, '3a-library-focus-1280', view, const {
        'locale': 'en',
        'state': 'focus',
        'focused': 'EPUB',
      });
    });

    testWidgets('W900 Japanese metadata at 200% text', (tester) async {
      await render(
        tester,
        '3a-library-wide-900-ja-t200',
        const HarnessView(size: Size(900, 700), textScale: 2),
        ready: () => harnessImagesReady(tester),
        metadata: const <String, Object?>{
          'locale': 'ja',
          'config': 'W900 T200',
          'state': 'wide-large-text',
        },
      );

      // The 2B deferred defect state: the header action must not cover the
      // collection at this configuration.
      final header = tester.getRect(find.byType(LibraryHeader));
      final grid = tester.getRect(find.byType(GridView));
      expect(header.bottom, lessThanOrEqualTo(grid.top));
    });
  });

  group('compact composition', () {
    testWidgets('C390 English', (tester) async {
      await render(
        tester,
        '3a-library-compact-390-en',
        const HarnessView(size: Size(390, 780)),
        ready: () => harnessImagesReady(tester),
        metadata: const <String, Object?>{'locale': 'en', 'state': 'compact'},
      );

      expect(find.byType(LibraryFilterRow), findsOneWidget);
      expect(find.byType(LibrarySidebar), findsNothing);
      for (final label in ['All', 'EPUB', 'PDF', 'CBZ', 'Settings']) {
        expect(entry(label), findsOneWidget);
      }
    });

    testWidgets('C390 Japanese metadata at 200% text', (tester) async {
      await render(
        tester,
        '3a-library-compact-390-ja-t200',
        const HarnessView(size: Size(390, 780), textScale: 2),
        books: harnessLibraryBooks()
            .where((book) => const {2, 6}.contains(book.bookId))
            .toList(),
        ready: () => harnessImagesReady(tester),
        metadata: const <String, Object?>{
          'locale': 'ja',
          'config': 'C390 T200',
          'state': 'compact-large-text',
        },
      );

      expect(find.text('海辺の図書館 — 失われた書架をめぐる長い旅路'), findsOneWidget);
      expect(entry('Settings'), findsOneWidget);
      expect(tester.widget<ShadButton>(entry('Settings')).enabled, isTrue);
    });
  });

  group('breakpoint', () {
    for (final width in const [759.0, 760.0, 761.0]) {
      testWidgets('B760± at ${width}px', (tester) async {
        await render(
          tester,
          '3a-library-breakpoint-${width.toInt()}-en',
          HarnessView(size: Size(width, 700)),
          ready: () => harnessImagesReady(tester),
          metadata: <String, Object?>{
            'locale': 'en',
            'config': 'B760±',
            'state': 'breakpoint',
            'clientWidth': width,
          },
        );

        final wide = width >= ShosaiTokens.layoutLibraryCompactBreakpoint;
        expect(
          find.byType(LibrarySidebar),
          wide ? findsOneWidget : findsNothing,
        );
        expect(
          find.byType(LibraryFilterRow),
          wide ? findsNothing : findsOneWidget,
        );
      });
    }
  });

  testWidgets('a short window scrolls the sidebar to Settings', (tester) async {
    const view = HarnessView(size: Size(900, 400), textScale: 2);
    final bridge = HarnessBridge(
      books: harnessLibraryBooks(),
      covers: harnessCovers(),
    );
    view.apply(tester);
    await renderHarnessState(
      tester,
      productionShell(
        home: ProductShell(
          bridgeFactory: () => bridge,
          readerBuilder: (_, _, _, _, _, _) => const SizedBox(),
        ),
      ),
      ready: () => harnessImagesReady(tester),
    );

    expect(find.byType(LibrarySidebar), findsOneWidget);
    await tester.scrollUntilVisible(
      entry('Settings'),
      80,
      scrollable: find.descendant(
        of: find.byType(LibrarySidebar),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getRect(entry('Settings')).top,
      lessThan(tester.getRect(find.byType(LibrarySidebar)).bottom),
      reason: 'Settings is reachable by scrolling the sidebar',
    );
    await captureState(tester, '3a-library-short-900x400-t200', view, const {
      'locale': 'en',
      'config': 'W900x400 T200',
      'state': 'short-window',
    });
  });

  testWidgets('empty library keeps the navigation', (tester) async {
    await render(
      tester,
      '3a-library-empty-1280',
      const HarnessView(size: Size(1280, 800)),
      books: const [],
      ready: () =>
          find.textContaining('library is empty').evaluate().isNotEmpty,
      metadata: const <String, Object?>{'state': 'empty'},
    );

    expect(find.byType(LibrarySidebar), findsOneWidget);
    expect(entry('Settings'), findsOneWidget);
    expect(entry('Add books'), findsOneWidget);
  });
}
