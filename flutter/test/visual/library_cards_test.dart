import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shosai_flutter/library/view.dart';
import 'package:shosai_flutter/src/rust/api.dart';
import 'package:shosai_flutter/theme_tokens.dart';

import '../support/production_shell_harness.dart';

/// Package 3B rendered states (`3B-RENDER`).
///
/// Each state renders the production shell with the deterministic harness
/// bridge, runs the geometry detectors, asserts the composition it claims and
/// captures an artifact for inspection next to its metadata. The package ships
/// no new golden baseline: the committed library goldens still record the
/// approved 3A composition until the owner approves replacements, so the
/// renders here are candidates for that review rather than a pixel gate.
///
/// The sizes and locales are the approved 1B reference configurations
/// (`W1280`, `W900`, `C390` = 390x844, `EN`, `JA`, `MIX`) so a candidate can be
/// put next to its reference capture.
void main() {
  setUpAll(loadHarnessFonts);

  /// Captures the current frame with its metadata and runs the detectors.
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
  String renderedLocale(WidgetTester tester) => Localizations.localeOf(
    tester.element(find.byType(LibraryCollection)),
  ).toLanguageTag();

  Future<HarnessBridge> render(
    WidgetTester tester,
    String name,
    HarnessView view, {
    required bool Function() ready,
    List<FlutterLibraryBook>? books,
    Map<int, Uint8List>? covers,
    Locale? locale,
    Future<void> Function(WidgetTester tester)? verify,
    Map<String, Object?> metadata = const {},
  }) async {
    final bridge = HarnessBridge(
      books: books ?? harnessLibraryBooks(),
      covers: covers ?? harnessCovers(),
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
    // Assertions run before the artifact is written, so a failed assertion
    // cannot leave apparently valid evidence behind.
    if (verify != null) {
      await verify(tester);
    }
    await captureState(tester, name, view, <String, Object?>{
      ...metadata,
      'appLocale': renderedLocale(tester),
    });
    return bridge;
  }

  /// A card's own title line, not the missing cover's placeholder copy.
  Finder cardTitle(String title) => find.byWidgetPredicate(
    (widget) =>
        widget is Text &&
        widget.data == title &&
        widget.style?.fontSize == ShosaiTokens.typeSize13,
  );

  /// The harness books that exercise long Japanese and mixed-script metadata.
  List<FlutterLibraryBook> longMetadataBooks() => harnessLibraryBooks()
      .where((book) => const {2, 3, 4, 6}.contains(book.bookId))
      .toList();

  group('wide composition', () {
    testWidgets('W1280 English', (tester) async {
      await render(
        tester,
        '3b-library-wide-1280-en',
        const HarnessView(size: Size(1280, 800)),
        locale: const Locale('en'),
        ready: () => harnessImagesReady(tester),
        metadata: const <String, Object?>{'state': 'wide'},
        verify: (tester) async {
          // LB-11: the reference's 5 columns at the wide window.
          expect(
            tester.getRect(find.byType(LibraryBookCard).first).width,
            closeTo(195.2, 0.6),
          );
          expect(find.byType(LibraryBookCard), findsWidgets);
          // The longest status label is fully painted at 100% text.
          final status = tester.renderObject<RenderParagraph>(
            find.text('Not started'),
          );
          expect(status.didExceedMaxLines, isFalse);
        },
      );
    });

    testWidgets('W1280 Japanese interface', (tester) async {
      await render(
        tester,
        '3b-library-wide-1280-ja',
        const HarnessView(size: Size(1280, 800)),
        books: harnessLibraryBooks()
            .where((book) => const {1, 2, 4, 6}.contains(book.bookId))
            .toList(),
        locale: const Locale('ja'),
        ready: () => harnessImagesReady(tester),
        metadata: const <String, Object?>{'state': 'wide-japanese-interface'},
        verify: (tester) async {
          // The card's status and tooltip come from the Japanese catalog.
          expect(find.text('未読'), findsNothing);
          expect(find.text('50%'), findsOneWidget);
          expect(find.byTooltip('本の操作'), findsWidgets);
          expect(find.byTooltip('Book actions'), findsNothing);
          expect(find.text('ライブラリ'), findsOneWidget);
        },
      );
    });

    testWidgets('W900 English', (tester) async {
      await render(
        tester,
        '3b-library-wide-900-en',
        const HarnessView(size: Size(900, 700)),
        locale: const Locale('en'),
        ready: () => harnessImagesReady(tester),
        metadata: const <String, Object?>{'state': 'wide-900'},
        verify: (tester) async {
          // LB-11 at 900: 3 columns of 210.7 px.
          expect(
            tester.getRect(find.byType(LibraryBookCard).first).width,
            closeTo(210.7, 0.6),
          );
        },
      );
    });

    testWidgets('W900 Japanese interface at 200% text', (tester) async {
      await render(
        tester,
        '3b-library-wide-900-ja-t200',
        const HarnessView(size: Size(900, 700), textScale: 2),
        locale: const Locale('ja'),
        ready: () => harnessImagesReady(tester),
        metadata: const <String, Object?>{
          'config': 'W900 T200',
          'state': 'wide-large-text',
        },
        verify: (tester) async {
          // Every card's status is present and fully painted at 200% text: a
          // label that ellipsized would still be found by `find.text`, so the
          // paragraph is checked for its line cap too.
          for (final status in ['未読', '42%', '7%', '99%', '31%', '50%']) {
            final matches = find.text(status).evaluate();
            expect(matches, isNotEmpty, reason: status);
            for (final match in matches) {
              expect(
                (match.renderObject! as RenderParagraph).didExceedMaxLines,
                isFalse,
                reason: status,
              );
            }
          }
          expect(find.text('ライブラリ'), findsOneWidget);
        },
      );
    });

    testWidgets('W1280 under the mapped dark theme', (tester) async {
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      await render(
        tester,
        '3b-library-dark-1280',
        const HarnessView(size: Size(1280, 800)),
        locale: const Locale('en'),
        ready: () => harnessImagesReady(tester),
        metadata: const <String, Object?>{'state': 'dark'},
        verify: (tester) async {
          final scheme = ShadTheme.of(
            tester.element(find.byType(LibraryBookCard).first),
          ).colorScheme;
          expect(scheme.background, ShosaiTokens.appDarkBackground);
        },
      );
    });

    testWidgets('W1280 with a keyboard-focused card', (tester) async {
      await render(
        tester,
        '3b-library-focus-1280',
        const HarnessView(size: Size(1280, 800)),
        locale: const Locale('en'),
        ready: () => harnessImagesReady(tester),
        metadata: const <String, Object?>{'state': 'focus'},
        verify: (tester) async {
          // Tab until a card owns focus, so the captured frame shows the shared
          // focus ring on a card. The card's own title is the label inside its
          // button semantics node.
          final title = cardTitle('The Quiet Cartographer');
          for (var step = 0; step < 20; step += 1) {
            await tester.sendKeyEvent(LogicalKeyboardKey.tab);
            await tester.pump();
            if (tester
                    .getSemantics(title)
                    .getSemanticsData()
                    .flagsCollection
                    .isFocused ==
                ui.Tristate.isTrue) {
              break;
            }
          }
          expect(
            tester
                .getSemantics(title)
                .getSemanticsData()
                .flagsCollection
                .isFocused,
            ui.Tristate.isTrue,
            reason: 'the captured frame shows a card focused',
          );
        },
      );
    });
  });

  group('metadata states', () {
    testWidgets('W1280 with long Japanese and mixed metadata', (tester) async {
      await render(
        tester,
        '3b-library-meta-long-ja-1280',
        const HarnessView(size: Size(1280, 800)),
        books: longMetadataBooks(),
        locale: const Locale('en'),
        ready: () => harnessImagesReady(tester),
        metadata: const <String, Object?>{'state': 'long-metadata'},
        verify: (tester) async {
          // LB-13: the 2-line title cap ellipsizes the unbreakable German token
          // instead of cutting it mid-glyph.
          final token = tester.renderObject<RenderParagraph>(
            cardTitle(
              'Donaudampfschifffahrtsgesellschaftskapitaenskajuettenfenster',
            ),
          );
          expect(token.didExceedMaxLines, isTrue);
          // The Japanese title fits its two lines at this width and is fully
          // painted; its line box is taller than the 13 px type size, which is
          // what the tile's measured reservation accounts for.
          final japanese = tester.renderObject<RenderParagraph>(
            cardTitle('海辺の図書館 — 失われた書架をめぐる長い旅路'),
          );
          expect(japanese.didExceedMaxLines, isFalse);
          expect(japanese.size.height, greaterThan(ShosaiTokens.typeSize13));
        },
      );
    });

    testWidgets('W1280 with missing covers', (tester) async {
      await render(
        tester,
        '3b-library-meta-no-cover-1280',
        const HarnessView(size: Size(1280, 800)),
        books: harnessLibraryBooks()
            .where((book) => const {1, 2, 5, 6}.contains(book.bookId))
            .toList(),
        // Books 5 and 6 have no cover, so the card shows the reference's
        // title placeholder.
        covers: harnessCovers(count: 2),
        locale: const Locale('en'),
        ready: () => harnessImagesReady(tester),
        metadata: const <String, Object?>{'state': 'missing-covers'},
        verify: (tester) async {
          // LB-12: a missing cover shows the title placeholder and keeps the
          // 210 px box, while the covered books keep their image.
          expect(find.byType(Image), findsNWidgets(2));
          final noCoverCard = find.ancestor(
            of: cardTitle('A Book With No Cover At All'),
            matching: find.byType(LibraryBookCard),
          );
          expect(noCoverCard, findsOneWidget);
          final cover = find.descendant(
            of: noCoverCard,
            matching: find.byType(LibraryBookCover),
          );
          expect(
            tester.getSize(cover).height,
            ShosaiTokens.layoutLibraryCardCoverHeight,
          );
          expect(
            find.descendant(of: cover, matching: find.byType(Image)),
            findsNothing,
          );
        },
      );
    });

    testWidgets('C390 with missing covers', (tester) async {
      await render(
        tester,
        '3b-library-meta-no-cover-c390',
        const HarnessView(size: Size(390, 844)),
        books: harnessLibraryBooks()
            .where((book) => const {1, 2, 5, 6}.contains(book.bookId))
            .toList(),
        covers: harnessCovers(count: 2),
        locale: const Locale('en'),
        ready: () => harnessImagesReady(tester),
        metadata: const <String, Object?>{'state': 'missing-covers'},
      );
    });

    testWidgets('C390 with long Japanese metadata', (tester) async {
      await render(
        tester,
        '3b-library-meta-long-ja-c390',
        const HarnessView(size: Size(390, 844)),
        books: longMetadataBooks(),
        locale: const Locale('en'),
        ready: () => harnessImagesReady(tester),
        metadata: const <String, Object?>{'state': 'long-metadata'},
        verify: (tester) async {
          // LB-13 at the compact reference size: 2 columns, 162 px each.
          expect(
            tester.getRect(find.byType(LibraryBookCard).first).width,
            closeTo(162, 0.6),
          );
        },
      );
    });
  });

  group('compact composition', () {
    // The specification's C390 reference is 390x844.
    for (final (name, locale, t200) in <(String, Locale, bool)>[
      ('3b-library-compact-390x844-en', Locale('en'), false),
      ('3b-library-compact-390x844-ja', Locale('ja'), false),
      ('3b-library-compact-390x844-ja-t200', Locale('ja'), true),
    ]) {
      testWidgets('C390 $name', (tester) async {
        final japanese = locale.languageCode == 'ja';
        await render(
          tester,
          name,
          HarnessView(size: const Size(390, 844), textScale: t200 ? 2 : 1),
          books: japanese
              ? harnessLibraryBooks()
                    .where(
                      (book) => (t200 ? const {2, 6} : const {1, 2, 4, 6})
                          .contains(book.bookId),
                    )
                    .toList()
              : null,
          locale: locale,
          ready: () => harnessImagesReady(tester),
          metadata: <String, Object?>{
            'config': 'C390${t200 ? ' T200' : ''}',
            'state': 'compact',
            'matchedSize': true,
          },
          verify: (tester) async {
            expect(find.byType(LibraryFilterRow), findsOneWidget);
            expect(find.byType(LibrarySidebar), findsNothing);
            if (japanese) {
              expect(find.text('ライブラリ'), findsOneWidget);
              expect(find.text('Library'), findsNothing);
              if (t200) {
                // The scaled status is fully painted, not ellipsized.
                for (final status in ['7%', '50%']) {
                  final paragraph = tester.renderObject<RenderParagraph>(
                    find.text(status),
                  );
                  expect(paragraph.didExceedMaxLines, isFalse, reason: status);
                }
              }
            }
          },
        );
      });
    }
  });

  group('card actions', () {
    testWidgets('W1280 with the card menu open', (tester) async {
      await render(
        tester,
        '3b-library-book-menu-1280',
        const HarnessView(size: Size(1280, 800)),
        locale: const Locale('en'),
        ready: () => harnessImagesReady(tester),
        metadata: const <String, Object?>{'state': 'menu-open'},
        verify: (tester) async {
          await tester.tap(find.byTooltip('Book actions').first);
          await tester.pumpAndSettle();
          // The unmanaged book offers the reference's remove action.
          expect(find.text('Remove and delete copy'), findsOneWidget);
        },
      );
    });

    testWidgets('W1280 while a removal is in flight', (tester) async {
      final bridge = _HeldRemovalBridge();
      const view = HarnessView(size: Size(1280, 800));
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

      // The unmanaged book removes without a confirmation dialog.
      await tester.tap(find.byTooltip('Book actions').at(2));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove from library'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Removing…'), findsOneWidget);
      await captureState(tester, '3b-library-remove-pending-1280', view, {
        'appLocale': renderedLocale(tester),
        'state': 'remove-pending',
      });
      // Release the held removal so the shell can dispose.
      bridge.removal.complete(
        const FlutterLibraryRemoveOutcome(
          removed: true,
          managedFileDeletionPending: false,
        ),
      );
      await tester.pumpAndSettle();
    });
  });
}

/// A harness bridge whose removal stays in flight until the test releases it,
/// so the card's removal-pending state can be captured as the controller
/// produces it.
class _HeldRemovalBridge extends HarnessBridge {
  _HeldRemovalBridge()
    : super(books: harnessLibraryBooks(), covers: harnessCovers());

  final Completer<FlutterLibraryRemoveOutcome> removal =
      Completer<FlutterLibraryRemoveOutcome>();

  @override
  Future<FlutterLibraryRemoveOutcome> removeLibraryBook({
    required int bookId,
  }) => removal.future;
}
