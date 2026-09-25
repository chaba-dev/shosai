import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shosai_flutter/library/view.dart';
import 'package:shosai_flutter/src/rust/api.dart';

import '../support/production_shell_harness.dart';

/// Package 3C: automatic next-page loading through the rendered collection.
///
/// The owner review (2026-09-25) replaced the ordinary "Load more books" button
/// with automatic paging: the collection asks for the next page as the scroll
/// approaches its end, and a page shorter than the viewport asks for one after
/// the frame so a short library does not need an impossible scroll. These tests
/// drive the real `ProductShell` and its real `LibraryController` through the
/// rendered controls — scrolling, the search field, the failure alert's Retry —
/// and pin the boundaries the owner named: one request per trigger, no request
/// while a page is in flight, exhaustion, explicit recovery instead of an
/// automatic retry loop, and a stale page that cannot merge into a newer
/// collection.
FlutterLibraryBook _book(int id, String title) => FlutterLibraryBook(
  bookId: id,
  title: title,
  author: 'Ada Lovelace',
  format: FlutterBookFormat.pdf,
  pathKey: '/books/$id.pdf',
  managed: false,
  progress: 0.42,
  dateAdded: '2026-09-10',
);

/// The card's own 13 px title line.
///
/// A card without a cover shows the title in its placeholder too, so a bare
/// text finder would match twice; the card's title is the 13 px line.
Finder _cardTitle(String title) => find.byWidgetPredicate(
  (widget) =>
      widget is Text && widget.data == title && widget.style?.fontSize == 13,
);

/// [count] books starting at [first], so a page's contents are identifiable by
/// title in the rendered tree.
List<FlutterLibraryBook> _books(int first, int count) => List.generate(
  count,
  (index) => _book(first + index, 'Book ${first + index}'),
);

/// A bridge whose collection pages are answered by the test.
///
/// It records every request (offset and query), can hold an appended page open
/// and can fail one appended page, so the loading, failure and stale-response
/// states are real rather than simulated model values.
class _PagingBridge extends HarnessBridge {
  _PagingBridge({required super.books, required super.covers});

  /// Answers a page request. The test owns the response.
  FlutterLibraryPage Function(String? query, int offset) serve = (_, _) =>
      const FlutterLibraryPage(books: [], hasMore: false);

  /// Holds appended pages (offset > 0) until the test releases them.
  bool holdAppends = false;

  /// Fails the next appended page once.
  bool failAppends = false;

  final List<int> offsets = <int>[];
  final List<String?> queries = <String?>[];
  final List<Completer<FlutterLibraryPage>> held =
      <Completer<FlutterLibraryPage>>[];

  @override
  Future<FlutterLibraryPage> libraryPage({
    String? query,
    FlutterBookFormat? format,
    required int limit,
    required int offset,
    required BigInt cancellationId,
  }) {
    offsets.add(offset);
    queries.add(query);
    if (offset > 0 && holdAppends) {
      final completer = Completer<FlutterLibraryPage>();
      held.add(completer);
      return completer.future;
    }
    if (offset > 0 && failAppends) {
      failAppends = false;
      return Future<FlutterLibraryPage>.error(
        const FlutterBridgeError(
          kind: FlutterBridgeErrorKind.backendUnavailable,
          message: 'Library query failed',
        ),
      );
    }
    return Future<FlutterLibraryPage>.value(serve(query, offset));
  }
}

void main() {
  setUpAll(loadHarnessFonts);

  /// Mounts the production shell with a real library controller at W1280.
  Future<void> pumpLibrary(WidgetTester tester, _PagingBridge bridge) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      productionShell(
        home: ProductShell(
          bridgeFactory: () => bridge,
          readerBuilder: (_, _, _, _, _, _) => const SizedBox(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// The collection's own scroll view, reached through the rendered tree.
  Finder scrollable() => find.descendant(
    of: find.byType(LibraryCollection),
    matching: find.byType(Scrollable),
  );

  testWidgets('a short first page asks for the next page without a scroll', (
    tester,
  ) async {
    final bridge = _PagingBridge(books: const [], covers: const {})
      ..serve = (query, offset) => offset == 0
          ? FlutterLibraryPage(books: _books(1, 2), hasMore: true)
          : FlutterLibraryPage(books: _books(3, 1), hasMore: false);
    await pumpLibrary(tester, bridge);

    // Two cards cannot fill the viewport, so there is no end to scroll to: the
    // collection asks for the next page after the frame, and the appended page
    // is part of the same grid rather than a second skeleton.
    expect(bridge.offsets, [0, 2]);
    expect(_cardTitle('Book 3'), findsOneWidget);
    expect(find.byType(LibrarySkeletonCard), findsNothing);
    expect(find.text('Loading more…'), findsNothing);
    expect(find.text('Load more books'), findsNothing);
  });

  testWidgets('scrolling near the end requests one page and shows feedback', (
    tester,
  ) async {
    final bridge = _PagingBridge(books: const [], covers: const {})
      ..holdAppends = true
      ..serve = (query, offset) => offset == 0
          ? FlutterLibraryPage(books: _books(1, 50), hasMore: true)
          : FlutterLibraryPage(books: _books(51, 50), hasMore: false);
    await pumpLibrary(tester, bridge);

    // A full page is taller than the viewport, so nothing is requested until
    // the scroll crosses the trigger distance at the collection's end.
    expect(bridge.offsets, [0]);
    final position = tester.state<ScrollableState>(scrollable()).position;
    position.jumpTo(
      (position.maxScrollExtent - 800).clamp(0, position.maxScrollExtent),
    );
    await tester.pump();
    expect(bridge.offsets, [
      0,
    ], reason: 'the trigger distance is not crossed yet');
    position.jumpTo(
      (position.maxScrollExtent - 100).clamp(0, position.maxScrollExtent),
    );
    await tester.pump();

    expect(bridge.offsets, [
      0,
      50,
    ], reason: 'the scroll end asks for exactly one page');

    // The pending line sits at the collection's end, where the user arrives to
    // see the page they asked for.
    position.jumpTo(position.maxScrollExtent);
    await tester.pump();
    await tester.pump();
    expect(find.text('Loading more…'), findsOneWidget);
    expect(
      tester
          .getSemantics(find.text('Loading more…'))
          .getSemanticsData()
          .flagsCollection
          .isLiveRegion,
      isTrue,
      reason: 'the pending page is announced, not only painted',
    );
    expect(
      find.byType(LibrarySkeletonCard),
      findsNothing,
      reason: 'an appended page keeps the loaded grid',
    );

    // The trigger can fire again before the model it was built with is
    // replaced; the controller refuses those requests, so repeated scrolling
    // cannot fetch the same page twice.
    await tester.drag(scrollable(), const Offset(0, -200));
    await tester.pump();
    await tester.drag(scrollable(), const Offset(0, -200));
    await tester.pump();
    expect(bridge.offsets, [0, 50]);

    bridge.held.single.complete(
      FlutterLibraryPage(books: _books(51, 50), hasMore: false),
    );
    await tester.pumpAndSettle();
    expect(find.text('Loading more…'), findsNothing);

    // The appended page is the collection's, and exhaustion stops the trigger:
    // scroll to the collection's new end before asking again.
    position.jumpTo(position.maxScrollExtent);
    await tester.pump();
    await tester.pump();
    expect(_cardTitle('Book 100'), findsOneWidget);
    position.jumpTo(position.maxScrollExtent);
    await tester.pump();
    expect(bridge.offsets, [0, 50]);
  });

  testWidgets('exhaustion stops the paging trigger', (tester) async {
    final bridge = _PagingBridge(books: const [], covers: const {})
      ..serve = (query, offset) =>
          FlutterLibraryPage(books: _books(1, 3), hasMore: false);
    await pumpLibrary(tester, bridge);

    await tester.drag(scrollable(), const Offset(0, -3000));
    await tester.pump();

    expect(bridge.offsets, [0]);
    expect(find.text('Loading more…'), findsNothing);
  });

  testWidgets('a failed appended page keeps its recovery in place', (
    tester,
  ) async {
    final bridge = _PagingBridge(books: const [], covers: const {})
      ..failAppends = true
      ..serve = (query, offset) => offset == 0
          ? FlutterLibraryPage(books: _books(1, 50), hasMore: true)
          : FlutterLibraryPage(books: _books(51, 50), hasMore: false);
    await pumpLibrary(tester, bridge);

    final position = tester.state<ScrollableState>(scrollable()).position;
    position.jumpTo(position.maxScrollExtent);
    await tester.pump();
    await tester.pump();
    expect(bridge.offsets, [0, 50]);

    // The failure replaces the pending line where the trigger fired: the user
    // who asked for the page sees its alert and its Retry without scrolling
    // back to the top, and the loaded page stays below the grid.
    expect(find.text('Loading more…'), findsNothing);
    expect(find.text('Library query failed'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(
      tester
          .getSemantics(find.text('Library query failed'))
          .getSemanticsData()
          .flagsCollection
          .isLiveRegion,
      isTrue,
      reason: 'the failure is announced where it happened',
    );
    expect(
      tester
          .getSemantics(find.text('Retry'))
          .getSemanticsData()
          .hasAction(SemanticsAction.tap),
      isTrue,
      reason: 'the recovery action is exposed as a control',
    );
    expect(
      find.byType(LibraryBookCard),
      findsWidgets,
      reason: 'a failed append keeps the loaded page',
    );

    // The failure is not retried automatically: the trigger waits for the
    // explicit recovery, so a failing page cannot become a request loop.
    position.jumpTo(position.maxScrollExtent);
    await tester.pump();
    expect(bridge.offsets, [0, 50]);

    // That recovery retries the page that failed, in place: the pending line
    // takes the row while the retry is in flight, and the appended page joins
    // the collection without reloading it.
    bridge.holdAppends = true;
    await tester.tap(find.text('Retry'));
    await tester.pump();
    await tester.pump();
    expect(
      bridge.offsets,
      [0, 50, 50],
      reason: 'the paging Retry asks for the page that failed, not page one',
    );
    position.jumpTo(position.maxScrollExtent);
    await tester.pump();
    await tester.pump();
    expect(find.text('Loading more…'), findsOneWidget);
    expect(find.text('Library query failed'), findsNothing);

    bridge.held.single.complete(
      FlutterLibraryPage(books: _books(51, 50), hasMore: false),
    );
    await tester.pumpAndSettle();
    expect(find.text('Library query failed'), findsNothing);
    expect(find.byType(LibraryBookCard), findsWidgets);
    position.jumpTo(position.maxScrollExtent);
    await tester.pump();
    await tester.pump();
    expect(_cardTitle('Book 100'), findsOneWidget);
  });

  testWidgets('a stale append cannot merge into a new query result', (
    tester,
  ) async {
    final bridge = _PagingBridge(books: const [], covers: const {})
      ..holdAppends = true
      ..serve = (query, offset) {
        if (offset > 0) {
          return FlutterLibraryPage(books: _books(51, 50), hasMore: false);
        }
        if (query == null || query.isEmpty) {
          return FlutterLibraryPage(books: _books(1, 50), hasMore: true);
        }
        return FlutterLibraryPage(
          books: [_book(900, 'The Quiet Cartographer')],
          hasMore: false,
        );
      };
    await pumpLibrary(tester, bridge);

    await tester.drag(scrollable(), const Offset(0, -5000));
    await tester.pump();
    expect(bridge.offsets, [0, 50], reason: 'the append is in flight');

    await tester.enterText(find.byType(ShadInput), 'Quiet');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    await tester.pump();
    expect(_cardTitle('The Quiet Cartographer'), findsOneWidget);

    // The held page belongs to the superseded collection: its books must not
    // merge into the newer query's result.
    bridge.held.single.complete(
      FlutterLibraryPage(books: _books(51, 50), hasMore: false),
    );
    await tester.pump();
    await tester.pump();
    expect(_cardTitle('Book 51'), findsNothing);
    expect(_cardTitle('Book 1'), findsNothing);
    expect(_cardTitle('The Quiet Cartographer'), findsOneWidget);
  });
}
