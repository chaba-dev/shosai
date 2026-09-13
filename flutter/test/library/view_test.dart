import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shosai_flutter/app_theme.dart';
import 'package:shosai_flutter/library/view.dart';
import 'package:shosai_flutter/src/rust/api.dart';

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

Widget _app(Widget child) => ShadTheme(
  data: shosaiShadTheme(Brightness.light),
  child: MaterialApp(home: Scaffold(body: child)),
);

LibraryCollection _collection(
  LibraryModel model, {
  ValueChanged<FlutterLibraryBook>? openBook,
  ValueChanged<FlutterLibraryBook>? removeBook,
  VoidCallback? loadMore,
}) => LibraryCollection(
  model: model,
  openBook: openBook ?? (_) {},
  removeBook: removeBook ?? (_) {},
  loadMore: loadMore ?? () {},
  loadCover: (_) => false,
);

void main() {
  testWidgets('shows progress while the first page loads', (tester) async {
    await tester.pumpWidget(_app(_collection(const LibraryModel(busy: true))));

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('explains an unloaded library failure', (tester) async {
    await tester.pumpWidget(
      _app(_collection(const LibraryModel(loadError: 'failed'))),
    );

    expect(find.text('The library could not be loaded.'), findsOneWidget);
  });

  testWidgets('distinguishes empty and filtered libraries', (tester) async {
    await tester.pumpWidget(_app(_collection(const LibraryModel())));
    expect(
      find.text('Your library is empty. Add a PDF, EPUB, or CBZ to begin.'),
      findsOneWidget,
    );

    await tester.pumpWidget(
      _app(_collection(const LibraryModel(query: 'missing', loaded: true))),
    );
    expect(find.text('No books match these filters.'), findsOneWidget);
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

    expect(find.text('A Book'), findsOneWidget);
    expect(find.text('Ada'), findsOneWidget);
    expect(find.text('42% read'), findsOneWidget);

    await tester.tap(find.text('A Book'));
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
