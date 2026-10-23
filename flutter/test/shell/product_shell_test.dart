import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_flutter/library/view.dart';
import 'package:shosai_flutter/reader/controller.dart'
    show ReaderNoticeReporter;
import 'package:shosai_flutter/shell/view.dart';
import 'package:shosai_flutter/core/bridge.dart';

import '../support/production_shell_harness.dart';

/// The Bookshelf shell composed by the product shell: the library side in the
/// sidebar, the reader beside the rail, and the open books between them.

const _quiet = 'The Quiet Cartographer';
const _atlas = 'Mixed Script Atlas: 東京・Wien・São Paulo';

/// The library card for [bookId] (titles also appear in the sidebar).
Finder _card(int bookId) => find.byWidgetPredicate(
  (widget) => widget is LibraryBookCard && widget.book.bookId == bookId,
);

/// The reader stand-in, so a test sees which book and locator it opened.
Widget _reader(
  FlutterBridge _,
  FlutterLibraryBook book,
  FlutterReaderSettings? _,
  String path,
  int? bookId,
  void Function(String path, int? bookId) locatorChanged,
  ReaderNoticeReporter _,
  Widget openBooksAction,
  void Function(bool twoPages) _,
) => Scaffold(
  body: Column(
    children: [
      Text('Reading ${book.title} at $path:$bookId'),
      openBooksAction,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Back'),
        ),
      ),
      TextButton(
        onPressed: () => locatorChanged('${book.pathKey}#later', bookId),
        child: const Text('Turn page'),
      ),
    ],
  ),
);

/// A reader stand-in that counts how often it is mounted and disposed.
class _MountCounter extends StatefulWidget {
  const _MountCounter({required this.child});

  static int mounts = 0;
  static int disposals = 0;

  final Widget child;

  @override
  State<_MountCounter> createState() => _MountCounterState();
}

class _MountCounterState extends State<_MountCounter> {
  @override
  void initState() {
    super.initState();
    _MountCounter.mounts++;
  }

  @override
  void dispose() {
    _MountCounter.disposals++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

Future<HarnessBridge> _pump(
  WidgetTester tester,
  Size size, {
  ProductReaderBuilder readerBuilder = _reader,
}) async {
  final bridge = HarnessBridge(
    books: harnessLibraryBooks(),
    covers: harnessCovers(),
  );
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    productionShell(
      home: ProductShell(
        bridgeFactory: () => bridge,
        readerBuilder: readerBuilder,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return bridge;
}

Future<void> _open(WidgetTester tester, int bookId) async {
  await tester.ensureVisible(_card(bookId));
  await tester.pumpAndSettle();
  await tester.tap(_card(bookId));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadHarnessFonts);

  testWidgets('a book opens beside the rail and stays in Reading now', (
    tester,
  ) async {
    await _pump(tester, const Size(1440, 900));
    expect(find.byType(ShellSidebar), findsOneWidget);
    expect(find.text('READING NOW'), findsNothing);

    await _open(tester, 1);
    expect(
      find.text('Reading $_quiet at /books/quiet-cartographer.epub:1'),
      findsOneWidget,
    );
    expect(find.byType(ShellRail), findsOneWidget);
    expect(find.byTooltip(_quiet), findsOneWidget);

    await tester.tap(find.byTooltip('Library'));
    await tester.pumpAndSettle();
    expect(find.byType(ShellRail), findsNothing);
    expect(find.text('READING NOW'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(ShellSidebar),
        matching: find.text(_quiet),
      ),
      findsOneWidget,
    );
  });

  testWidgets('the rail switches books and each keeps its place', (
    tester,
  ) async {
    await _pump(tester, const Size(1440, 900));
    await _open(tester, 1);
    await tester.tap(find.text('Turn page'));
    await tester.pump();

    await tester.tap(find.byTooltip('Library'));
    await tester.pumpAndSettle();
    await _open(tester, 4);
    expect(find.textContaining('Reading $_atlas'), findsOneWidget);
    expect(find.byTooltip(_quiet), findsOneWidget);
    expect(find.byTooltip(_atlas), findsOneWidget);

    await tester.tap(find.byTooltip(_quiet));
    await tester.pumpAndSettle();
    expect(
      find.text('Reading $_quiet at /books/quiet-cartographer.epub#later:1'),
      findsOneWidget,
      reason: 'switching back reopens the book where it was left',
    );
  });

  testWidgets('a reader keeps its state when the window narrows to a phone', (
    tester,
  ) async {
    _MountCounter.mounts = 0;
    _MountCounter.disposals = 0;
    await _pump(
      tester,
      const Size(1024, 800),
      readerBuilder:
          (
            bridge,
            book,
            settings,
            path,
            bookId,
            locatorChanged,
            notices,
            openBooks,
            pagesChanged,
          ) => _MountCounter(
            child: _reader(
              bridge,
              book,
              settings,
              path,
              bookId,
              locatorChanged,
              notices,
              openBooks,
              pagesChanged,
            ),
          ),
    );
    await _open(tester, 1);
    expect(find.byType(ShellRail), findsOneWidget);

    tester.view.physicalSize = const Size(390, 844);
    await tester.pumpAndSettle();
    expect(find.byType(ShellRail), findsNothing);
    expect(find.textContaining('Reading $_quiet'), findsOneWidget);
    expect(_MountCounter.mounts, 1, reason: 'the reader moved, not remounted');
    expect(_MountCounter.disposals, 0);

    tester.view.physicalSize = const Size(1024, 800);
    await tester.pumpAndSettle();
    expect(find.byType(ShellRail), findsOneWidget);
    expect(_MountCounter.mounts, 1);
  });

  testWidgets('opening an open book focuses it instead of opening it twice', (
    tester,
  ) async {
    await _pump(tester, const Size(1440, 900));
    await _open(tester, 1);
    await tester.tap(find.byTooltip('Library'));
    await tester.pumpAndSettle();
    await _open(tester, 1);
    expect(find.byTooltip(_quiet), findsOneWidget);
    expect(find.byType(ShellRail), findsOneWidget);
  });

  testWidgets('the sidebar reopens a book and closes it', (tester) async {
    await _pump(tester, const Size(1180, 820));
    await _open(tester, 1);
    await tester.tap(find.byTooltip('Notes'));
    await tester.pumpAndSettle();
    expect(find.text('No notes yet'), findsOneWidget);

    await tester.tap(
      find.descendant(
        of: find.byType(ShellSidebar),
        matching: find.text(_quiet),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ShellRail), findsOneWidget);

    await tester.tap(find.byTooltip('Library'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Close $_quiet'));
    await tester.pumpAndSettle();
    expect(find.text('READING NOW'), findsNothing);
  });

  testWidgets('the reader’s own back returns to the library', (tester) async {
    final bridge = await _pump(tester, const Size(1440, 900));
    final loads = bridge.libraryCalls;
    await _open(tester, 1);
    await tester.tap(find.text('Back'));
    await tester.pumpAndSettle();
    expect(find.byType(ShellSidebar), findsOneWidget);
    expect(find.text('READING NOW'), findsOneWidget);
    expect(
      bridge.libraryCalls,
      greaterThan(loads),
      reason: 'the library refreshes once the reader has gone',
    );
  });

  testWidgets('a phone reads full screen and lists open books as cards', (
    tester,
  ) async {
    await _pump(tester, const Size(390, 844));
    expect(find.byType(ShellBottomNav), findsOneWidget);
    await _open(tester, 1);
    expect(find.byType(ShellBottomNav), findsNothing);
    expect(find.byType(ShellRail), findsNothing);

    await tester.tap(find.text('Back'));
    await tester.pumpAndSettle();
    expect(find.byType(ShellReadingNowCards), findsOneWidget);
    expect(find.text('Reading now'), findsOneWidget);
  });

  testWidgets('the reader’s open-book count opens the tab switcher', (
    tester,
  ) async {
    await _pump(tester, const Size(390, 844));
    await _open(tester, 1);
    await tester.tap(find.text('Back'));
    await tester.pumpAndSettle();
    await _open(tester, 4);
    expect(find.textContaining('Reading $_atlas'), findsOneWidget);

    await tester.tap(find.byTooltip('2 open books'));
    await tester.pumpAndSettle();
    expect(find.byType(ShellTabSwitcher), findsOneWidget);

    // The other book's card brings it forward and closes the switcher.
    await tester.tap(
      find.descendant(
        of: find.byType(ShellTabSwitcher),
        matching: find.text(_quiet),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ShellTabSwitcher), findsNothing);
    expect(find.textContaining('Reading $_quiet'), findsOneWidget);

    await tester.tap(find.byTooltip('2 open books'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.byType(ShellTabSwitcher), findsNothing);
    expect(find.textContaining('Reading $_quiet'), findsOneWidget);
  });

  testWidgets('open books come back after a restoration', (tester) async {
    await _pump(tester, const Size(1440, 900));
    await _open(tester, 1);
    await tester.tap(find.byTooltip('Library'));
    await tester.pumpAndSettle();
    await _open(tester, 4);
    await tester.tap(find.text('Turn page'));
    await tester.pump();

    await tester.restartAndRestore();
    await tester.pumpAndSettle();

    expect(
      find.text('Reading $_atlas at /books/atlas.pdf#later:4'),
      findsOneWidget,
    );
    expect(find.byTooltip(_quiet), findsOneWidget);
    expect(find.byTooltip(_atlas), findsOneWidget);
  });

  testWidgets('the title counts the open books and their cards say Open', (
    tester,
  ) async {
    await _pump(tester, const Size(1440, 900));
    expect(find.text('6 books'), findsOneWidget);
    expect(find.text('Open'), findsNothing);

    await _open(tester, 1);
    await tester.tap(find.byTooltip('Library'));
    await tester.pumpAndSettle();

    expect(find.text('6 books · 1 open'), findsOneWidget);
    final meta = find.descendant(
      of: _card(1),
      matching: find.textContaining('Open', findRichText: true),
    );
    expect(meta, findsOneWidget);
    expect(
      find.descendant(
        of: _card(4),
        matching: find.textContaining('Open', findRichText: true),
      ),
      findsNothing,
    );
  });

  testWidgets('the sort control reorders the shelf and keeps the hero', (
    tester,
  ) async {
    await _pump(tester, const Size(1440, 900));
    List<int> shelf() => [
      for (final card in tester.widgetList<LibraryBookCard>(
        find.byType(LibraryBookCard),
      ))
        card.book.bookId,
    ];
    expect(shelf(), [1, 2, 3, 4, 5, 6]);

    await tester.tap(find.text('Title'));
    await tester.pumpAndSettle();
    // A, D, M, T, then the Japanese titles after the Latin ones.
    expect(shelf(), [5, 3, 4, 1, 2, 6]);
    expect(find.byType(LibraryContinueCard), findsOneWidget);

    await tester.tap(find.text('Author'));
    await tester.pumpAndSettle();
    expect(shelf().first, 1, reason: 'Ada Lovelace sorts first');

    await tester.tap(find.text('Recent'));
    await tester.pumpAndSettle();
    expect(shelf(), [1, 2, 3, 4, 5, 6]);
  });

  testWidgets('each sort option is a touch target on a phone', (tester) async {
    await _pump(tester, const Size(390, 844));
    for (final option in ['Recent', 'Title', 'Author']) {
      final target = tester.getSize(
        find.ancestor(of: find.text(option), matching: find.byType(InkWell)),
      );
      expect(target.height, greaterThanOrEqualTo(44), reason: option);
      expect(target.width, greaterThanOrEqualTo(44), reason: option);
    }
  });
}
