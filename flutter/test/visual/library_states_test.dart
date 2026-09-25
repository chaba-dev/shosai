import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shosai_flutter/android_document_import_adapter.dart';
import 'package:shosai_flutter/library/view.dart';
import 'package:shosai_flutter/src/rust/api.dart';
import 'package:shosai_flutter/theme_tokens.dart';

import '../support/production_shell_harness.dart';

/// Package 3C rendered states (`3C-RENDER`).
///
/// Each state renders the production shell with the deterministic harness
/// bridge, runs the geometry detectors, asserts the composition it claims and
/// captures an artifact for inspection next to its metadata. The package ships
/// **no new golden baseline**: the committed library goldens still record the
/// approved 3B composition until the owner approves replacements, so the
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

  /// The continue card's own 16 px title line.
  Finder continueTitle(String title) => find.byWidgetPredicate(
    (widget) =>
        widget is Text &&
        widget.data == title &&
        widget.style?.fontSize == ShosaiTokens.typeSize16,
  );

  /// The collection's own 18 px section title.
  Finder sectionTitle(String label) => find.byWidgetPredicate(
    (widget) =>
        widget is Text &&
        widget.data == label &&
        widget.style?.fontSize == ShosaiTokens.typeSize18,
  );

  /// A bridge whose next page can be held open or failed.
  HarnessBridge gatedBridge({
    List<FlutterLibraryBook>? books,
    Map<int, Uint8List>? covers,
  }) => _GatedLibraryBridge(
    books: books ?? harnessLibraryBooks(),
    covers: covers ?? harnessCovers(),
  );

  group('continue reading', () {
    testWidgets('W1280 English', (tester) async {
      await render(
        tester,
        '3c-library-continue-1280-en',
        const HarnessView(size: Size(1280, 800)),
        locale: const Locale('en'),
        ready: () => harnessImagesReady(tester),
        metadata: const <String, Object?>{'state': 'continue-reading'},
        verify: (tester) async {
          expect(find.text('Continue reading'), findsOneWidget);
          expect(continueTitle('The Quiet Cartographer'), findsOneWidget);
          expect(find.text('42% complete'), findsOneWidget);
          expect(find.text('Continue  ›'), findsOneWidget);
        },
      );
    });

    testWidgets('W1280 Japanese interface', (tester) async {
      await render(
        tester,
        '3c-library-continue-1280-ja',
        const HarnessView(size: Size(1280, 800)),
        locale: const Locale('ja'),
        ready: () => harnessImagesReady(tester),
        metadata: const <String, Object?>{'state': 'continue-reading'},
        verify: (tester) async {
          expect(find.text('読書を続ける'), findsOneWidget);
          expect(find.text('42% 完了'), findsOneWidget);
          expect(find.text('続きを読む  ›'), findsOneWidget);
        },
      );
    });

    testWidgets('W900 English at 200% text', (tester) async {
      await render(
        tester,
        '3c-library-continue-900-en-t200',
        const HarnessView(size: Size(900, 700), textScale: 2),
        locale: const Locale('en'),
        ready: () => harnessImagesReady(tester),
        metadata: const <String, Object?>{
          'state': 'continue-reading-large-text',
        },
        verify: (tester) async {
          expect(find.byType(LibraryContinueCard), findsOneWidget);
          // The card grew with its scaled text instead of cutting a line.
          final card = tester.getRect(find.byType(LibraryContinueCard));
          expect(
            card.height,
            greaterThan(ShosaiTokens.layoutContinueCardDetailsHeight),
          );
        },
      );
    });

    testWidgets('C390 Japanese interface at 200% text', (tester) async {
      await render(
        tester,
        '3c-library-continue-390-ja-t200',
        const HarnessView(size: Size(390, 844), textScale: 2),
        locale: const Locale('ja'),
        ready: () => harnessImagesReady(tester),
        metadata: const <String, Object?>{
          'state': 'continue-reading-compact-large-text',
        },
        verify: (tester) async {
          expect(find.byType(LibraryContinueCard), findsOneWidget);
          expect(find.text('続きを読む  ›'), findsOneWidget);
        },
      );
    });

    testWidgets('W1280 without a cover for the continued book', (tester) async {
      await render(
        tester,
        '3c-library-continue-no-cover-1280',
        const HarnessView(size: Size(1280, 800)),
        locale: const Locale('en'),
        books: [
          FlutterLibraryBook(
            bookId: 5,
            title: 'A Book With No Cover At All',
            author: 'Anonymous',
            format: FlutterBookFormat.pdf,
            pathKey: '/books/no-cover.pdf',
            managed: true,
            progress: 0.31,
            dateAdded: '2026-09-14',
            lastRead: '2026-09-19T08:12:00Z',
          ),
        ],
        covers: const {},
        ready: () => find.byType(LibraryContinueCard).evaluate().isNotEmpty,
        metadata: const <String, Object?>{'state': 'continue-reading-no-cover'},
        verify: (tester) async {
          // The placeholder keeps the reference's 72x100 continue box.
          expect(
            tester.getSize(
              find.descendant(
                of: find.byType(LibraryContinueCard),
                matching: find.byType(LibraryBookCover),
              ),
            ),
            const Size(
              ShosaiTokens.layoutContinueCardCoverWidth,
              ShosaiTokens.layoutContinueCardCoverHeight,
            ),
          );
        },
      );
    });
  });

  group('collection states', () {
    testWidgets('W1280 first-load skeleton', (tester) async {
      final bridge = gatedBridge() as _GatedLibraryBridge;
      bridge.gate = true;
      const view = HarnessView(size: Size(1280, 800));
      view.apply(tester);
      await renderHarnessState(
        tester,
        productionShell(
          home: ProductShell(
            bridgeFactory: () => bridge,
            readerBuilder: (_, _, _, _, _, _) => const SizedBox(),
          ),
        ),
        ready: () => find.byType(LibrarySkeletonCard).evaluate().isNotEmpty,
      );
      expect(find.byType(LibrarySkeletonCard), findsNWidgets(8));
      await captureState(tester, '3c-library-skeleton-1280', view, {
        'state': 'loading-skeleton',
        'appLocale': renderedLocale(tester),
      });
    });

    testWidgets('W1280 search-reload skeleton', (tester) async {
      final bridge =
          gatedBridge(
                books: harnessLibraryBooks().take(3).toList(),
                covers: harnessCovers(count: 3),
              )
              as _GatedLibraryBridge;
      const view = HarnessView(size: Size(1280, 800));
      view.apply(tester);
      await renderHarnessState(
        tester,
        productionShell(
          home: ProductShell(
            bridgeFactory: () => bridge,
            readerBuilder: (_, _, _, _, _, _) => const SizedBox(),
          ),
        ),
        ready: () => find.byType(LibraryBookCard).evaluate().isNotEmpty,
      );

      bridge.gate = true;
      await tester.enterText(find.byType(ShadInput), 'Quiet');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(find.byType(LibrarySkeletonCard), findsNWidgets(3));
      expect(sectionTitle('Search results'), findsOneWidget);
      await captureState(tester, '3c-library-skeleton-search-1280', view, {
        'state': 'loading-skeleton-search',
        'appLocale': renderedLocale(tester),
      });
    });

    testWidgets('W1280 empty library', (tester) async {
      await render(
        tester,
        '3c-library-empty-1280',
        const HarnessView(size: Size(1280, 800)),
        locale: const Locale('en'),
        books: const [],
        covers: const {},
        ready: () =>
            find.text('A quiet place for every book').evaluate().isNotEmpty,
        metadata: const <String, Object?>{'state': 'empty'},
        verify: (tester) async {
          expect(find.text('Add your first books'), findsOneWidget);
        },
      );
    });

    testWidgets('C390 Japanese interface at 200% text', (tester) async {
      await render(
        tester,
        '3c-library-empty-390-ja-t200',
        const HarnessView(size: Size(390, 844), textScale: 2),
        locale: const Locale('ja'),
        books: const [],
        covers: const {},
        ready: () => find.text('すべての本に静かな居場所を').evaluate().isNotEmpty,
        metadata: const <String, Object?>{'state': 'empty-large-text'},
      );
    });

    testWidgets('W1280 no matches', (tester) async {
      final bridge = gatedBridge() as _GatedLibraryBridge;
      const view = HarnessView(size: Size(1280, 800));
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
      await tester.enterText(find.byType(ShadInput), 'nothing matches this');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(find.text('No matching books'), findsOneWidget);
      await captureState(tester, '3c-library-no-matches-1280', view, {
        'state': 'no-matches',
        'appLocale': renderedLocale(tester),
      });
    });

    testWidgets('W1280 load failure above the grid', (tester) async {
      final bridge = gatedBridge() as _GatedLibraryBridge;
      const view = HarnessView(size: Size(1280, 800));
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
      bridge.failNextPage = true;
      await tester.tap(find.byTooltip('Refresh library'));
      await tester.pumpAndSettle();
      expect(find.text('Library query failed'), findsOneWidget);
      expect(find.byType(LibraryBookCard), findsWidgets);
      await captureState(tester, '3c-library-load-error-1280', view, {
        'state': 'load-error',
        'appLocale': renderedLocale(tester),
      });
    });

    testWidgets('W1280 empty library with a load failure', (tester) async {
      final bridge =
          gatedBridge(books: const [], covers: const {}) as _GatedLibraryBridge;
      const view = HarnessView(size: Size(1280, 800));
      view.apply(tester);
      await renderHarnessState(
        tester,
        productionShell(
          home: ProductShell(
            bridgeFactory: () => bridge,
            readerBuilder: (_, _, _, _, _, _) => const SizedBox(),
          ),
        ),
        ready: () =>
            find.text('A quiet place for every book').evaluate().isNotEmpty,
      );
      bridge.failNextPage = true;
      await tester.tap(find.byTooltip('Refresh library'));
      await tester.pumpAndSettle();
      expect(find.text('Library query failed'), findsOneWidget);
      await captureState(tester, '3c-library-empty-error-1280', view, {
        'state': 'empty-load-error',
        'appLocale': renderedLocale(tester),
      });
    });

    testWidgets('W1280 dark palette', (tester) async {
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      final bridge = gatedBridge() as _GatedLibraryBridge;
      const view = HarnessView(size: Size(1280, 800));
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
      bridge.failNextPage = true;
      await tester.tap(find.byTooltip('Refresh library'));
      await tester.pumpAndSettle();
      expect(find.text('Library query failed'), findsOneWidget);
      expect(find.byType(LibraryContinueCard), findsOneWidget);
      await captureState(tester, '3c-library-dark-1280', view, {
        'state': 'load-error-dark-palette',
        'appLocale': renderedLocale(tester),
      });
    });

    testWidgets('W1280 cleanup and deletion debt', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final bridge = gatedBridge() as _GatedLibraryBridge;
      bridge.deletionPending = true;
      const view = HarnessView(size: Size(1280, 800));
      view.apply(tester);
      await renderHarnessState(
        tester,
        productionShell(
          home: ProductShell(
            bridgeFactory: () => bridge,
            readerBuilder: (_, _, _, _, _, _) => const SizedBox(),
            androidImport: AndroidDocumentImportAdapter(
              channel: _CleanupChannel([1, 0]),
            ),
          ),
        ),
        ready: () => harnessImagesReady(tester),
      );
      expect(
        find.text('Temporary import data could not be removed yet.'),
        findsOneWidget,
      );

      await tester.tap(find.byTooltip('Book actions').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove and delete copy'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Remove and delete'));
      await tester.pumpAndSettle();
      expect(
        find.text('Book removed. Its private copy will be deleted later.'),
        findsOneWidget,
      );
      await captureState(tester, '3c-library-debt-1280', view, {
        'state': 'cleanup-and-deletion-debt',
        'appLocale': renderedLocale(tester),
      });
      debugDefaultTargetPlatformOverride = null;
    });
  });
}

/// A bridge whose next page can be held open or failed.
class _GatedLibraryBridge extends HarnessBridge {
  _GatedLibraryBridge({required super.books, required super.covers});

  final List<Completer<FlutterLibraryPage>> pending = [];
  bool gate = false;
  bool failNextPage = false;
  bool deletionPending = false;

  @override
  Future<FlutterLibraryPage> libraryPage({
    String? query,
    FlutterBookFormat? format,
    required int limit,
    required int offset,
    required BigInt cancellationId,
  }) {
    if (failNextPage) {
      failNextPage = false;
      return Future<FlutterLibraryPage>.error(
        const FlutterBridgeError(
          kind: FlutterBridgeErrorKind.backendUnavailable,
          message: 'Library query failed',
        ),
      );
    }
    if (!gate) {
      return super.libraryPage(
        query: query,
        format: format,
        limit: limit,
        offset: offset,
        cancellationId: cancellationId,
      );
    }
    final completer = Completer<FlutterLibraryPage>();
    pending.add(completer);
    return completer.future;
  }

  @override
  Future<FlutterLibraryRemoveOutcome> removeLibraryBook({
    required int bookId,
  }) async {
    await super.removeLibraryBook(bookId: bookId);
    return FlutterLibraryRemoveOutcome(
      removed: true,
      managedFileDeletionPending: deletionPending,
    );
  }
}

/// The Android provider channel that reports deferred cleanup work.
final class _CleanupChannel implements AndroidDocumentImportChannel {
  _CleanupChannel(Iterable<int> pending) : _pending = Queue.of(pending);

  final Queue<int> _pending;

  @override
  Future<Object?> invoke(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    if (method == 'retryCleanup') {
      return <String, Object?>{'pending': _pending.removeFirst()};
    }
    return null;
  }
}
