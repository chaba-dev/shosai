import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_flutter/library/view.dart';
import 'package:shosai_flutter/src/rust/api.dart';
import 'package:shosai_flutter/theme_tokens.dart';

import '../support/production_shell_harness.dart';

final _book = FlutterLibraryBook(
  bookId: 7,
  title: 'A Book',
  author: 'Ada',
  format: FlutterBookFormat.pdf,
  pathKey: '/books/a.pdf',
  managed: false,
  progress: 0.42,
  dateAdded: '2026-09-10',
);

/// The collection inside the production composition, so the card's catalog
/// lookups resolve exactly as they do in the application.
Widget _app(Widget child) => productionShell(home: Scaffold(body: child));

LibraryCollection _collection(
  LibraryModel model, {
  ValueChanged<FlutterLibraryBook>? openBook,
  ValueChanged<FlutterLibraryBook>? removeBook,
  VoidCallback? loadMore,
  VoidCallback? retry,
  VoidCallback? addFirstBooks,
  VoidCallback? cancelImport,
}) => LibraryCollection(
  model: model,
  openBook: openBook ?? (_) {},
  removeBook: removeBook ?? (_) {},
  loadMore: loadMore ?? () {},
  loadCover: (_) => false,
  retry: retry ?? () {},
  addFirstBooks: addFirstBooks ?? () {},
  cancelImport: cancelImport ?? () {},
);

void main() {
  setUpAll(loadHarnessFonts);

  testWidgets('shows the reference skeleton grid while page one loads', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        _collection(
          const LibraryModel(loading: true, busy: true, loaded: true),
        ),
      ),
    );

    // The skeleton is the reference's grid of placeholder cards under the
    // section title, not a spinner: an empty library shows its eight
    // placeholders.
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('All books'), findsOneWidget);
    expect(find.byType(LibraryBookCard), findsNothing);
    expect(find.byType(LibrarySkeletonCard), findsNWidgets(8));
  });

  testWidgets('explains an empty library with its add-first-books action', (
    tester,
  ) async {
    var added = 0;
    await tester.pumpWidget(
      _app(
        _collection(
          const LibraryModel(loaded: true),
          addFirstBooks: () => added += 1,
        ),
      ),
    );

    expect(find.text('A quiet place for every book'), findsOneWidget);
    expect(
      find.text('No books in library. Import files to get started.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Add your first books'));
    expect(added, 1);
  });

  testWidgets('an empty library loading its import offers cancel', (
    tester,
  ) async {
    var cancelled = 0;
    await tester.pumpWidget(
      _app(
        _collection(
          const LibraryModel(loaded: true, importing: true, busy: true),
          cancelImport: () => cancelled += 1,
        ),
      ),
    );

    expect(find.text('Add your first books'), findsNothing);
    await tester.tap(find.text('Cancel'));
    expect(cancelled, 1);
  });

  testWidgets('distinguishes the no-matches composition from the empty one', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(_collection(const LibraryModel(query: 'missing', loaded: true))),
    );

    expect(find.text('No matching books'), findsOneWidget);
    expect(find.text('No books match your search or filter.'), findsOneWidget);
    // The no-matches composition has no action.
    expect(find.text('Add your first books'), findsNothing);

    await tester.pumpWidget(
      _app(
        _collection(
          const LibraryModel(
            query: 'missing',
            format: FlutterBookFormat.pdf,
            loaded: true,
          ),
        ),
      ),
    );
    expect(find.text('No matching books'), findsOneWidget);
  });

  testWidgets('a failure replaces the empty body and keeps recovery', (
    tester,
  ) async {
    var retries = 0;
    await tester.pumpWidget(
      _app(
        _collection(
          const LibraryModel(loadError: 'Library query failed', loaded: true),
          retry: () => retries += 1,
        ),
      ),
    );

    expect(find.text('A quiet place for every book'), findsOneWidget);
    expect(find.text('Library query failed'), findsOneWidget);
    // Adding books would misstate a library that failed to load; the failure's
    // own recovery action is the path instead.
    expect(find.text('Add your first books'), findsNothing);
  });

  testWidgets('a failure above loaded books is the collection alert', (
    tester,
  ) async {
    var retries = 0;
    await tester.pumpWidget(
      _app(
        _collection(
          LibraryModel(
            books: [_book],
            loaded: true,
            loadError: 'Library query failed',
          ),
          retry: () => retries += 1,
        ),
      ),
    );

    expect(find.text('Library query failed'), findsOneWidget);
    expect(find.byType(LibraryBookCard), findsOneWidget);
    await tester.tap(find.text('Retry'));
    expect(retries, 1);
  });

  testWidgets('renders book metadata and opens the selected book', (
    tester,
  ) async {
    FlutterLibraryBook? opened;
    await tester.pumpWidget(
      _app(
        _collection(
          LibraryModel(books: [_book], loaded: true),
          openBook: (book) => opened = book,
        ),
      ),
    );

    // The title is the card's own 13 px line; the missing cover's placeholder
    // carries a second copy of the same string.
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Text &&
            widget.data == 'A Book' &&
            widget.style?.fontSize == ShosaiTokens.typeSize13,
      ),
      findsOneWidget,
    );
    expect(find.text('Ada'), findsOneWidget);
    expect(find.text('42%'), findsOneWidget);

    await tester.tap(find.byType(LibraryBookCard));
    expect(opened?.bookId, 7);
  });

  testWidgets('loads more when the library has another page', (tester) async {
    var loadMoreCalls = 0;
    await tester.pumpWidget(
      _app(
        _collection(
          LibraryModel(books: [_book], loaded: true, hasMore: true),
          loadMore: () => loadMoreCalls += 1,
        ),
      ),
    );

    await tester.tap(find.text('Load more books'));
    expect(loadMoreCalls, 1);
  });

  testWidgets('book actions menu removes the book', (tester) async {
    FlutterLibraryBook? removed;
    await tester.pumpWidget(
      _app(
        _collection(
          LibraryModel(books: [_book], loaded: true),
          removeBook: (book) => removed = book,
        ),
      ),
    );

    await tester.tap(find.byTooltip('Book actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove from library'));
    await tester.pump();

    expect(removed?.bookId, 7);
  });

  testWidgets('banner announces a message and runs its action', (tester) async {
    var actions = 0;
    await tester.pumpWidget(
      _app(
        LibraryBanner(
          message: 'Temporary import data could not be removed yet.',
          actionLabel: 'Retry cleanup',
          onAction: () => actions += 1,
        ),
      ),
    );

    expect(
      find.text('Temporary import data could not be removed yet.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Retry cleanup'));
    expect(actions, 1);
  });

  testWidgets('destructive banner renders its action', (tester) async {
    await tester.pumpWidget(
      _app(
        LibraryBanner(
          message: 'The library could not be loaded.',
          actionLabel: 'Retry',
          destructive: true,
          onAction: () {},
        ),
      ),
    );

    expect(find.text('Retry'), findsOneWidget);
  });
}
