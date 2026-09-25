import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shosai_flutter/android_document_import_adapter.dart';
import 'package:shosai_flutter/app_theme.dart';
import 'package:shosai_flutter/library/view.dart';
import 'package:shosai_flutter/src/rust/api.dart';

import '../support/production_shell_harness.dart';

/// Package 3C: the collection's distinct states and their recovery actions.
///
/// Each state is the pinned Iced `library_collection` shape
/// (`crates/shosai-app/src/app.rs:7124`): the skeleton grid while page one
/// loads, the empty-library or no-matches composition when the result set is
/// empty, the failure alert above the grid, and the retained Flutter debt
/// surfaces. The assertions pin that the states stay distinguishable from one
/// another and that every recovery action still reaches its typed intent.
FlutterLibraryBook _book(int id, String title) => FlutterLibraryBook(
  bookId: id,
  title: title,
  author: 'Ada Lovelace',
  format: FlutterBookFormat.pdf,
  pathKey: '/books/$id.pdf',
  managed: true,
  progress: 0.42,
  dateAdded: '2026-09-10',
);

/// A bridge whose next page can be held open or failed, so the loading and
/// failure states are real rather than simulated model values.
class _GatedLibraryBridge extends HarnessBridge {
  _GatedLibraryBridge({required super.books, required super.covers});

  final List<Completer<FlutterLibraryPage>> pending = [];
  final List<int> offsets = [];
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
    offsets.add(offset);
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

  /// Releases the oldest held page with [books].
  void release(List<FlutterLibraryBook> books, {bool hasMore = false}) {
    pending
        .removeAt(0)
        .complete(FlutterLibraryPage(books: books, hasMore: hasMore));
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

void main() {
  setUpAll(loadHarnessFonts);

  /// Mounts the production shell over a gated bridge.
  Future<void> mount(
    WidgetTester tester,
    _GatedLibraryBridge bridge, {
    AndroidDocumentImportAdapter? androidImport,
    HarnessView view = const HarnessView(size: Size(1280, 800)),
    Locale locale = const Locale('en'),
  }) async {
    view.apply(tester);
    await tester.pumpWidget(
      productionShell(
        locale: locale,
        home: ProductShell(
          bridgeFactory: () => bridge,
          readerBuilder: (_, _, _, _, _, _) => const SizedBox(),
          androidImport: androidImport,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<_GatedLibraryBridge> pumpShell(
    WidgetTester tester, {
    required List<FlutterLibraryBook> books,
    HarnessView view = const HarnessView(size: Size(1280, 800)),
    Locale locale = const Locale('en'),
  }) async {
    final bridge = _GatedLibraryBridge(
      books: books,
      covers: harnessCovers(count: books.length),
    );
    await mount(tester, bridge, view: view, locale: locale);
    return bridge;
  }

  testWidgets('the first load shows the reference skeleton grid, then books', (
    tester,
  ) async {
    final bridge = _GatedLibraryBridge(
      books: [_book(1, 'A Book'), _book(2, 'Another Book')],
      covers: harnessCovers(count: 2),
    )..gate = true;
    const view = HarnessView(size: Size(1280, 800));
    view.apply(tester);
    await tester.pumpWidget(
      productionShell(
        home: ProductShell(
          bridgeFactory: () => bridge,
          readerBuilder: (_, _, _, _, _, _) => const SizedBox(),
        ),
      ),
    );
    await tester.pump();

    // Eight placeholders for an empty library, under the section title.
    expect(find.byType(LibrarySkeletonCard), findsNWidgets(8));
    expect(find.byType(LibraryBookCard), findsNothing);
    expect(find.text('All books'), findsWidgets);

    bridge.release([_book(1, 'A Book'), _book(2, 'Another Book')]);
    await tester.pumpAndSettle();

    expect(find.byType(LibrarySkeletonCard), findsNothing);
    expect(find.byType(LibraryBookCard), findsNWidgets(2));
  });

  testWidgets('a reload shows the skeleton of the page it replaces', (
    tester,
  ) async {
    final bridge = await pumpShell(
      tester,
      books: [_book(1, 'A Book'), _book(2, 'Another Book')],
    );
    expect(find.byType(LibraryBookCard), findsNWidgets(2));

    bridge.gate = true;
    await tester.enterText(find.byType(ShadInput), 'Book');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();

    // The reference replaces the grid with as many placeholders as the page
    // held, and titles the section for the active search.
    expect(find.byType(LibrarySkeletonCard), findsNWidgets(2));
    expect(find.byType(LibraryBookCard), findsNothing);
    expect(find.text('Search results'), findsWidgets);

    bridge.release([_book(1, 'A Book')]);
    await tester.pumpAndSettle();
    expect(find.byType(LibrarySkeletonCard), findsNothing);
    expect(find.byType(LibraryBookCard), findsOneWidget);
  });

  testWidgets('every empty and filtered state is distinguishable', (
    tester,
  ) async {
    // Empty library: heading, body and the add-first-books action, centred in
    // the collection area.
    await pumpShell(tester, books: const []);
    expect(find.text('A quiet place for every book'), findsOneWidget);
    expect(
      find.text('No books in library. Import files to get started.'),
      findsOneWidget,
    );
    expect(find.text('Add your first books'), findsOneWidget);
    expect(find.text('No matching books'), findsNothing);
    expect(find.byType(LibrarySkeletonCard), findsNothing);
    final collection = tester.getRect(find.byType(LibraryCollection));
    expect(
      tester.getRect(find.text('A quiet place for every book')).center.dx,
      closeTo(collection.center.dx, 1),
      reason: 'the empty composition is centred in the collection area',
    );

    // No matches: heading and body, and no action.
    await tester.pumpWidget(const SizedBox.shrink());
    await pumpShell(tester, books: [_book(1, 'A Book')]);
    await tester.enterText(find.byType(ShadInput), 'nothing matches this');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.text('No matching books'), findsOneWidget);
    expect(find.text('No books match your search or filter.'), findsOneWidget);
    expect(find.text('Add your first books'), findsNothing);
    expect(find.byType(LibraryBookCard), findsNothing);
  });

  testWidgets('the failure alert keeps its recovery above the grid', (
    tester,
  ) async {
    final bridge = await pumpShell(tester, books: [_book(1, 'A Book')]);

    // A failing reload keeps the loaded grid and reports the failure in the
    // collection's own alert, with the retained retry action.
    bridge.failNextPage = true;
    await tester.tap(find.byTooltip('Refresh library'));
    await tester.pumpAndSettle();

    expect(find.text('Library query failed'), findsOneWidget);
    expect(find.byType(LibraryBookCard), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);

    // Retry asks the controller for another load, which succeeds.
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Library query failed'), findsNothing);
    expect(find.byType(LibraryBookCard), findsOneWidget);
  });

  testWidgets('the failure alert follows the dark palette', (tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    final bridge = await pumpShell(tester, books: [_book(1, 'A Book')]);
    bridge.failNextPage = true;
    await tester.tap(find.byTooltip('Refresh library'));
    await tester.pumpAndSettle();

    final scheme = shosaiShadTheme(Brightness.dark).colorScheme;
    final alert = tester.widget<Container>(
      find
          .ancestor(
            of: find.text('Library query failed'),
            matching: find.byType(Container),
          )
          .first,
    );
    expect(
      alert.color,
      scheme.muted,
      reason:
          'the reference alert surface is a pinned light value, so the dark '
          'theme keeps its own raised surface instead',
    );
  });

  testWidgets('an empty failed library keeps a recovery action', (
    tester,
  ) async {
    final bridge = await pumpShell(tester, books: const []);
    bridge.failNextPage = true;
    await tester.tap(find.byTooltip('Refresh library'));
    await tester.pumpAndSettle();

    expect(find.text('A quiet place for every book'), findsOneWidget);
    expect(find.text('Library query failed'), findsOneWidget);
    expect(
      find.text('Add your first books'),
      findsNothing,
      reason:
          'offering to add books while the library failed to load would '
          'misstate the state',
    );

    // The failure's recovery is present in this shape too, not only in the
    // populated grid's alert.
    expect(find.text('Retry'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Library query failed'), findsNothing);
    expect(find.text('A quiet place for every book'), findsOneWidget);
  });

  testWidgets('an unresolved failure stays visible during a reload', (
    tester,
  ) async {
    final bridge = await pumpShell(tester, books: [_book(1, 'A Book')]);
    bridge.failNextPage = true;
    await tester.tap(find.byTooltip('Refresh library'));
    await tester.pumpAndSettle();
    expect(find.text('Library query failed'), findsOneWidget);

    // An unrelated search reload replaces the grid with the skeleton; the
    // unresolved failure and its retry stay visible above it.
    bridge.gate = true;
    await tester.enterText(find.byType(ShadInput), 'Book');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();

    expect(find.byType(LibrarySkeletonCard), findsWidgets);
    expect(find.text('Library query failed'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);

    bridge.release([_book(1, 'A Book')]);
    await tester.pumpAndSettle();
  });

  testWidgets('cleanup and deletion debt stay distinct from the failure', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final bridge = _GatedLibraryBridge(
      books: [_book(1, 'A Book')],
      covers: harnessCovers(count: 1),
    )..deletionPending = true;
    await mount(
      tester,
      bridge,
      androidImport: AndroidDocumentImportAdapter(
        channel: _CleanupChannel([1, 0]),
      ),
    );

    // Provider-cleanup debt: its own message and its own retry.
    expect(
      find.text('Temporary import data could not be removed yet.'),
      findsOneWidget,
    );
    expect(find.text('Retry cleanup'), findsOneWidget);
    // The failure alert is not shown, so the debt states cannot be mistaken
    // for a load failure.
    expect(find.text('Retry'), findsNothing);

    await tester.tap(find.text('Retry cleanup'));
    await tester.pumpAndSettle();
    expect(
      find.text('Temporary import data could not be removed yet.'),
      findsNothing,
    );

    // Managed-deletion debt: its own message and an acknowledgement.
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
    expect(find.text('Dismiss'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);

    await tester.tap(find.text('Dismiss'));
    await tester.pumpAndSettle();
    expect(
      find.text('Book removed. Its private copy will be deleted later.'),
      findsNothing,
    );
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('the empty action starts the import entry', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await pumpShell(tester, books: const []);

    await tester.tap(find.text('Add your first books'));
    // The picker dialog keeps the import effect in flight, so the tree never
    // settles; a bounded pump is enough to observe the transition.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // The action reached the typed import intent: the dialog is up and the
    // header's add-books action became the import's cancel action.
    expect(find.text('Add books'), findsWidgets);
    expect(find.text('Choose files'), findsOneWidget);
    expect(find.text('Cancel'), findsWidgets);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('paging stays available below the grid', (tester) async {
    final many = List.generate(
      libraryPageSize + 1,
      (index) => _book(index + 1, 'Book ${index + 1}'),
    );
    final bridge = _GatedLibraryBridge(
      books: many,
      covers: harnessCovers(count: many.length),
    );
    await mount(tester, bridge);

    // The paging control is the last item of the collection column, below a
    // full page of cards, so it is reached by scrolling.
    await tester.scrollUntilVisible(
      find.text('Load more books'),
      400,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
    expect(find.text('Load more books'), findsOneWidget);
    // The append is held open, so the pending presentation is asserted rather
    // than only its settled result.
    bridge.gate = true;
    await tester.tap(find.text('Load more books'));
    await tester.pump();
    expect(find.byType(LibrarySkeletonCard), findsNothing);
    expect(find.byType(LibraryBookCard), findsWidgets);
    bridge.release(const []);
    await tester.pumpAndSettle();

    // The append asks the bridge for the next offset and keeps the grid: a
    // later page is not the skeleton, and the paging control retires once the
    // appended page is the last one.
    expect(bridge.offsets, contains(libraryPageSize));
    expect(find.byType(LibrarySkeletonCard), findsNothing);
    expect(find.byType(LibraryBookCard), findsWidgets);
    expect(find.text('Load more books'), findsNothing);
  });
}
