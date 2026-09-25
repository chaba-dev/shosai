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

  /// The locale the application actually rendered with.
  ///
  /// Read from the localization scope below `MaterialApp`, so a capture records
  /// the resolved language rather than the requested one (an unsupported
  /// request would otherwise be recorded despite falling back).
  String renderedLocale(WidgetTester tester) => Localizations.localeOf(
    tester.element(find.byType(LibraryHeader)),
  ).toLanguageTag();

  Future<HarnessBridge> render(
    WidgetTester tester,
    String name,
    HarnessView view, {
    required bool Function() ready,
    List<FlutterLibraryBook>? books,
    Locale? locale,
    Future<void> Function(WidgetTester tester)? verify,
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
        locale: locale,
        home: ProductShell(
          bridgeFactory: () => bridge,
          readerBuilder: (_, _, _, _, _, _) => const SizedBox(),
        ),
      ),
      ready: ready,
    );
    // Language assertions run before the artifact is written, so a failed
    // assertion cannot leave apparently valid evidence behind.
    if (verify != null) {
      await verify(tester);
    }
    await captureState(tester, name, view, <String, Object?>{
      ...metadata,
      'appLocale': renderedLocale(tester),
    });
    return bridge;
  }

  /// The library chrome above the collection: the header, the wide sidebar and
  /// the compact filter row.
  ///
  /// Scoped this way because a card is a button too, and its format label
  /// carries the same text as a filter entry.
  final chrome = find.byWidgetPredicate(
    (widget) =>
        widget is LibraryHeader ||
        widget is LibrarySidebar ||
        widget is LibraryFilterRow,
  );

  Finder entry(String label) => find.descendant(
    of: chrome,
    matching: find.widgetWithText(ShadButton, label),
  );

  /// A grid card's own 13 px title line.
  ///
  /// The continue-reading section paints the same book's title in its own 16 px
  /// line, so a bare text finder would match both.
  Finder cardTitle(String title) => find.byWidgetPredicate(
    (widget) =>
        widget is Text &&
        widget.data == title &&
        widget.style?.fontSize == ShosaiTokens.typeSize13,
  );

  /// The label paragraph inside the chrome control labelled [label].
  Finder chromeLabel(String label) =>
      find.descendant(of: chrome, matching: find.text(label));

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
        locale: const Locale('en'),
        ready: () => harnessImagesReady(tester),
        metadata: const <String, Object?>{'state': 'wide'},
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

    testWidgets('W1280 Japanese interface', (tester) async {
      await render(
        tester,
        '3a-library-wide-1280-ja',
        const HarnessView(size: Size(1280, 800)),
        books: harnessLibraryBooks()
            .where((book) => const {2, 4, 6}.contains(book.bookId))
            .toList(),
        locale: const Locale('ja'),
        ready: () => harnessImagesReady(tester),
        verify: (tester) async {
          // The reference's Japanese strings, taken from the Iced catalogs.
          expect(find.text('ライブラリ'), findsOneWidget);
          expect(find.text('自分だけの読書室'), findsOneWidget);
          expect(find.text('コレクション'), findsOneWidget);
          expect(entry('すべての本'), findsOneWidget);
          expect(entry('設定'), findsOneWidget);
          expect(entry('本を追加'), findsOneWidget);
          expect(find.text('タイトル・著者を検索...'), findsOneWidget);
          // Tooltips and accessibility text are translated too.
          expect(find.byTooltip('ライブラリを更新'), findsOneWidget);
          expect(find.bySemanticsLabel('本を追加'), findsOneWidget);
          expect(
            find.descendant(
              of: find.byType(LibrarySidebar),
              matching: find.bySemanticsLabel('すべての本'),
            ),
            findsOneWidget,
          );
          expect(find.bySemanticsLabel('設定'), findsOneWidget);
          // The English chrome must not survive a Japanese interface.
          expect(find.text('Library'), findsNothing);
          expect(find.text('All books'), findsNothing);
          expect(find.text('Settings'), findsNothing);
          expect(find.byTooltip('Refresh library'), findsNothing);
          // Japanese metadata still renders in the same state. The
          // continue-reading section paints the first page's Japanese title in
          // its own 16 px line, so the card's 13 px line is the one asserted.
          expect(cardTitle('海辺の図書館 — 失われた書架をめぐる長い旅路'), findsOneWidget);
          expect(
            cardTitle('Mixed Script Atlas: 東京・Wien・São Paulo'),
            findsOneWidget,
          );
        },
        metadata: const <String, Object?>{'state': 'wide-japanese-interface'},
      );
    });

    testWidgets('W1280 Japanese metadata with the English interface', (
      tester,
    ) async {
      // Metadata coverage is kept separate from interface coverage: this state
      // selects Japanese metadata but an explicitly English interface, so it
      // cannot stand in for the localized renders.
      await render(
        tester,
        '3a-library-wide-1280-ja-metadata',
        const HarnessView(size: Size(1280, 800)),
        books: harnessLibraryBooks()
            .where((book) => const {2, 4, 6}.contains(book.bookId))
            .toList(),
        locale: const Locale('en'),
        ready: () => harnessImagesReady(tester),
        metadata: const <String, Object?>{'state': 'wide-japanese-metadata'},
      );

      expect(cardTitle('海辺の図書館 — 失われた書架をめぐる長い旅路'), findsOneWidget);
      expect(find.text('Library'), findsOneWidget);
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
          locale: const Locale('en'),
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
      await captureState(tester, '3a-library-filter-pdf-1280', view, {
        'appLocale': renderedLocale(tester),
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
        locale: const Locale('en'),
        ready: () => harnessImagesReady(tester),
        metadata: const <String, Object?>{
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
          locale: const Locale('en'),
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
                .getSemantics(chromeLabel('EPUB'))
                .getSemanticsData()
                .flagsCollection
                .isFocused ==
            ui.Tristate.isTrue) {
          break;
        }
      }
      expect(
        tester
            .getSemantics(chromeLabel('EPUB'))
            .getSemanticsData()
            .flagsCollection
            .isFocused,
        ui.Tristate.isTrue,
        reason: 'the captured frame shows the EPUB entry focused',
      );
      await captureState(tester, '3a-library-focus-1280', view, {
        'appLocale': renderedLocale(tester),
        'state': 'focus',
        'focused': 'EPUB',
      });
    });

    testWidgets('W900 Japanese interface at 200% text', (tester) async {
      await render(
        tester,
        '3a-library-wide-900-ja-t200',
        const HarnessView(size: Size(900, 700), textScale: 2),
        locale: const Locale('ja'),
        ready: () => harnessImagesReady(tester),
        verify: (tester) async {
          // The 2B deferred defect state: the header action must not cover the
          // collection at this configuration.
          final header = tester.getRect(find.byType(LibraryHeader));
          final grid = tester.getRect(find.byType(LibraryCollection));
          expect(header.bottom, lessThanOrEqualTo(grid.top));
          // The scaled Japanese interface stays translated rather than falling
          // back to English at 200% text.
          expect(find.text('ライブラリ'), findsOneWidget);
          expect(entry('設定'), findsOneWidget);
          expect(find.byTooltip('ライブラリを更新'), findsOneWidget);
          expect(find.text('Library'), findsNothing);
        },
        metadata: const <String, Object?>{
          'config': 'W900 T200',
          'state': 'wide-large-text',
        },
      );
    });
  });

  group('compact composition', () {
    // The specification's C390 reference is 390x844. The 390x780 states below
    // are retained as supplemental regressions against the harness's historical
    // compact size; the 390x844 states are the matched C390 evidence.
    for (final (name, height, locale, t200)
        in <(String, double, Locale?, bool)>[
          ('3a-library-compact-390x780-en', 780, Locale('en'), false),
          ('3a-library-compact-390x780-ja-t200', 780, Locale('ja'), true),
          ('3a-library-compact-390x844-en', 844, Locale('en'), false),
          ('3a-library-compact-390x844-ja', 844, Locale('ja'), false),
          ('3a-library-compact-390x844-ja-t200', 844, Locale('ja'), true),
        ]) {
      testWidgets('C390 $name', (tester) async {
        final japanese = locale?.languageCode == 'ja';
        await render(
          tester,
          name,
          HarnessView(size: Size(390, height), textScale: t200 ? 2 : 1),
          books: japanese
              ? harnessLibraryBooks()
                    .where(
                      (book) => (t200 ? const {2, 6} : const {2, 4, 6})
                          .contains(book.bookId),
                    )
                    .toList()
              : null,
          locale: locale,
          ready: () => harnessImagesReady(tester),
          verify: (tester) async {
            expect(find.byType(LibraryFilterRow), findsOneWidget);
            expect(find.byType(LibrarySidebar), findsNothing);
            final labels = japanese
                ? const ['すべて', 'EPUB', 'PDF', 'CBZ', '設定']
                : const ['All', 'EPUB', 'PDF', 'CBZ', 'Settings'];
            for (final label in labels) {
              expect(entry(label), findsOneWidget);
              expect(tester.widget<ShadButton>(entry(label)).enabled, isTrue);
            }
            if (japanese) {
              // A Japanese interface in the compact row, not English chrome
              // with Japanese metadata.
              expect(find.text('ライブラリ'), findsOneWidget);
              expect(find.text('タイトル・著者を検索...'), findsOneWidget);
              expect(find.byTooltip('ライブラリを更新'), findsOneWidget);
              expect(find.text('All'), findsNothing);
              expect(find.text('Settings'), findsNothing);
              expect(find.byTooltip('Refresh library'), findsNothing);
            }
          },
          metadata: <String, Object?>{
            'config': 'C390${t200 ? ' T200' : ''}',
            'state': 'compact',
            'matchedSize': height == 844,
          },
        );
      });
    }
  });

  group('breakpoint', () {
    // Both locales cross the boundary identically: the probes check the layout
    // switch, and the Japanese probes additionally keep the interface
    // translated on both sides of it.
    for (final locale in const [Locale('en'), Locale('ja')]) {
      for (final width in const [759.0, 760.0, 761.0]) {
        testWidgets('B760± at ${width}px ${locale.languageCode}', (
          tester,
        ) async {
          final japanese = locale.languageCode == 'ja';
          await render(
            tester,
            '3a-library-breakpoint-${width.toInt()}-${locale.languageCode}',
            HarnessView(size: Size(width, 700)),
            locale: locale,
            ready: () => harnessImagesReady(tester),
            verify: (tester) async {
              final wide = width >= ShosaiTokens.layoutLibraryCompactBreakpoint;
              expect(
                find.byType(LibrarySidebar),
                wide ? findsOneWidget : findsNothing,
              );
              expect(
                find.byType(LibraryFilterRow),
                wide ? findsNothing : findsOneWidget,
              );
              if (japanese) {
                expect(find.text('ライブラリ'), findsOneWidget);
                expect(entry(wide ? 'すべての本' : 'すべて'), findsOneWidget);
                expect(entry('設定'), findsOneWidget);
                expect(find.text('Library'), findsNothing);
              }
            },
            metadata: <String, Object?>{
              'config': 'B760±',
              'state': 'breakpoint',
              'clientWidth': width,
            },
          );
        });
      }
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
        locale: const Locale('en'),
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
    await captureState(tester, '3a-library-short-900x400-t200', view, {
      'appLocale': renderedLocale(tester),
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
      locale: const Locale('en'),
      ready: () =>
          find.text('A quiet place for every book').evaluate().isNotEmpty,
      metadata: const <String, Object?>{'state': 'empty'},
    );

    expect(find.byType(LibrarySidebar), findsOneWidget);
    expect(entry('Settings'), findsOneWidget);
    expect(entry('Add books'), findsOneWidget);
  });
}
