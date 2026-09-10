import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_flutter/product_shell.dart';
import 'package:shosai_flutter/src/rust/api.dart';

void main() {
  setUpAll(() async {
    final inter = FontLoader('Inter')
      ..addFont(rootBundle.load('../assets/fonts/InterVariable.ttf'));
    await inter.load();
  });

  testWidgets('expanded library golden', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final bridge = _LibraryBridge();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff745b3e)),
          useMaterial3: true,
          fontFamily: 'Inter',
        ),
        home: ProductShell(
          bridgeFactory: () => bridge,
          readerBuilder: (_, _) => const SizedBox(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(ProductShell),
      matchesGoldenFile('goldens/library-expanded.png'),
    );
  });

  testWidgets('library renders content, progress, filters, and opens a book', (
    tester,
  ) async {
    final bridge = _LibraryBridge();
    FlutterLibraryBook? opened;
    await tester.pumpWidget(
      MaterialApp(
        home: ProductShell(
          bridgeFactory: () => bridge,
          readerBuilder: (_, book) {
            opened = book;
            return Scaffold(body: Text('Reading ${book.title}'));
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('A Book'), findsOneWidget);
    expect(find.text('Ada'), findsOneWidget);
    expect(find.text('42% read'), findsOneWidget);
    expect(find.text('PDF'), findsOneWidget);

    await tester.tap(find.text('PDF'));
    await tester.pumpAndSettle();
    expect(bridge.lastFormat, FlutterBookFormat.pdf);

    await tester.tap(find.text('A Book'));
    await tester.pumpAndSettle();
    expect(opened?.bookId, 7);
    expect(find.text('Reading A Book'), findsOneWidget);
  });

  testWidgets('library distinguishes empty and no-result states', (
    tester,
  ) async {
    final bridge = _LibraryBridge(books: const []);
    await tester.pumpWidget(
      MaterialApp(
        home: ProductShell(
          bridgeFactory: () => bridge,
          readerBuilder: (_, _) => const SizedBox(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('library is empty'), findsOneWidget);

    await tester.enterText(find.byType(SearchBar), 'missing');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.text('No books match these filters.'), findsOneWidget);
  });
}

class _LibraryBridge implements FlutterBridge {
  _LibraryBridge({
    this.books = const [
      FlutterLibraryBook(
        bookId: 7,
        title: 'A Book',
        author: 'Ada',
        format: FlutterBookFormat.pdf,
        pathKey: '/books/a.pdf',
        managed: true,
        progress: 0.42,
        dateAdded: '2026-09-10',
      ),
    ],
  });

  final List<FlutterLibraryBook> books;
  FlutterBookFormat? lastFormat;
  bool disposed = false;

  @override
  bool get isDisposed => disposed;

  @override
  Future<FlutterLibraryPage> libraryPage({
    String? query,
    FlutterBookFormat? format,
    required int limit,
    required int offset,
  }) async {
    lastFormat = format;
    return FlutterLibraryPage(
      books: books
          .where(
            (book) =>
                (format == null || book.format == format) &&
                (query == null ||
                    query.isEmpty ||
                    book.title.toLowerCase().contains(query.toLowerCase())),
          )
          .toList(),
      hasMore: false,
    );
  }

  @override
  Future<FlutterReaderSettings> loadReaderSettings() async =>
      const FlutterReaderSettings(
        continuous: false,
        epubFontSize: 18,
        epubLineSpacing: 1.6,
        pdfZoom: 0,
      );

  @override
  void dispose() => disposed = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
