import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart' show ShadInput;
import 'package:shosai_flutter/library/view.dart';
import 'package:shosai_flutter/reader/view.dart' show ReaderScreen;
import 'package:shosai_flutter/reader/controller.dart'
    show
        ReaderDisplaySink,
        ReaderNoticeReporter,
        ReaderPlace,
        ReaderPlaceRequests;
import 'package:shosai_flutter/shell/view.dart';
import 'package:shosai_flutter/core/bridge.dart';

import '../support/bridge_records.dart';
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
  ReaderDisplaySink _,
  ReaderPlaceRequests places,
) => Scaffold(
  body: Column(
    children: [
      Text('Reading ${book.title} at $path:$bookId'),
      _PlaceLog(places),
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
      TextButton(
        onPressed: () => locatorChanged('/books/other.pdf', null),
        child: const Text('Open another file'),
      ),
      // A note in the reader's All books that sits in another book.
      TextButton(
        onPressed: () => places.openBook?.call(
          harnessLibraryBooks()[3],
          const ReaderPlace(4, offset: 12),
        ),
        child: const Text('Open the atlas note'),
      ),
      TextButton(
        onPressed: () {
          final open = places.openBook;
          if (open == null) return;
          final atlas = harnessLibraryBooks()[3];
          open(atlas, const ReaderPlace(4, offset: 12));
          open(atlas, const ReaderPlace(4, offset: 12));
        },
        child: const Text('Open the atlas note twice'),
      ),
      // Back to the first book, past a jump in this one and one in the first.
      TextButton(
        onPressed: () => places.openBook?.call(
          harnessLibraryBooks()[0],
          ReaderPlace(
            1,
            offset: 5,
            returnPoints: [
              (unit: 0, offset: 3, book: harnessLibraryBooks()[0]),
              (unit: 2, offset: null, book: null),
            ],
          ),
        ),
        child: const Text('Back to the first book'),
      ),
    ],
  ),
);

/// [_reader], whose way back is a jump from page 2 and where it reads, page 7.
Widget _readerWithWayBack(
  FlutterBridge bridge,
  FlutterLibraryBook book,
  FlutterReaderSettings? settings,
  String path,
  int? bookId,
  void Function(String path, int? bookId) locatorChanged,
  ReaderNoticeReporter notices,
  Widget openBooksAction,
  ReaderDisplaySink displayChanged,
  ReaderPlaceRequests places,
) {
  places.wayBack = () => const [
    (unit: 1, offset: null, book: null),
    (unit: 6, offset: 40, book: null),
  ];
  return _reader(
    bridge,
    book,
    settings,
    path,
    bookId,
    locatorChanged,
    notices,
    openBooksAction,
    displayChanged,
    places,
  );
}

/// Pumps the product's reader, which decodes its pages outside the fake
/// clock, until [done].
Future<void> _readerSettles(WidgetTester tester, bool Function() done) async {
  for (var round = 0; round < 20 && !done(); round += 1) {
    await pumpHarnessFrames(tester, frames: 4);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
  }
  await pumpHarnessFrames(tester, frames: 4);
  expect(done(), isTrue, reason: 'the reader never settled');
  await revealReaderChrome(tester);
}

/// The product's reader, over the harness bridge.
Widget _realReader(
  FlutterBridge bridge,
  FlutterLibraryBook book,
  FlutterReaderSettings? settings,
  String path,
  int? bookId,
  void Function(String path, int? bookId) locatorChanged,
  ReaderNoticeReporter noticeReporter,
  Widget openBooksAction,
  ReaderDisplaySink displayChanged,
  ReaderPlaceRequests placeRequests,
) => ReaderScreen(
  bridge: bridge,
  initialPath: path,
  initialBookId: bookId,
  initialSettings: (settings ?? harnessReaderSettings).copyWith(
    zonesHintDismissed: true,
  ),
  placeRequests: placeRequests,
  onLocatorChanged: locatorChanged,
  noticeReporter: noticeReporter,
  openBooksAction: openBooksAction,
  onDisplayChanged: displayChanged,
);

/// The places a reader stand-in was asked to go to: the one it opened at,
/// then each later request.
class _PlaceLog extends StatefulWidget {
  const _PlaceLog(this.places);

  final ReaderPlaceRequests places;

  @override
  State<_PlaceLog> createState() => _PlaceLogState();
}

class _PlaceLogState extends State<_PlaceLog> {
  final List<ReaderPlace> _places = [];

  @override
  void initState() {
    super.initState();
    if (widget.places.take() case final place?) _places.add(place);
    widget.places.addListener(_requested);
  }

  @override
  void dispose() {
    widget.places.removeListener(_requested);
    super.dispose();
  }

  void _requested() {
    if (widget.places.take() case final place?) {
      setState(() => _places.add(place));
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (final place in _places) ...[
        Text('At ${place.unit}:${place.offset}'),
        if (place.returnPoints case final points?)
          Text(
            'Back through ${[for (final point in points) '${point.book?.bookId ?? 'here'}:${point.unit}:${point.offset}'].join(' ')}',
          ),
        if (place.annotationId case final id?)
          Text('Resolving $id as ${place.note! ? 'a note' : 'a highlight'}'),
      ],
    ],
  );
}

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
  double devicePixelRatio = 1,
  HarnessBridge? bridge,
}) async {
  final activeBridge =
      bridge ??
      HarnessBridge(books: harnessLibraryBooks(), covers: harnessCovers());
  tester.view.physicalSize = size * devicePixelRatio;
  tester.view.devicePixelRatio = devicePixelRatio;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    productionShell(
      home: ProductShell(
        bridgeFactory: () => activeBridge,
        readerBuilder: readerBuilder,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return activeBridge;
}

/// The sidebar's Notes place.
final _sidebarNotes = find.descendant(
  of: find.byType(ShellSidebar),
  matching: find.text('Notes'),
);

Future<void> _open(WidgetTester tester, int bookId) async {
  await tester.ensureVisible(_card(bookId));
  await tester.pumpAndSettle();
  await tester.tap(_card(bookId));
  await tester.pumpAndSettle();
}

/// The Open tag on book [bookId]'s card.
Finder _openTag(int bookId) => find.descendant(
  of: _card(bookId),
  matching: find.textContaining('Open', findRichText: true),
);

/// A library whose settings writes fail while [failSaves] is set.
class _FailingSettingsBridge extends HarnessBridge {
  _FailingSettingsBridge()
    : super(books: harnessLibraryBooks(), covers: harnessCovers());

  bool failSaves = true;

  @override
  Future<void> saveReaderSettings({
    required FlutterReaderSettings value,
  }) async {
    if (failSaves) {
      throw const FlutterBridgeError(
        kind: FlutterBridgeErrorKind.inaccessible,
        message: 'disk full',
      );
    }
    await super.saveReaderSettings(value: value);
  }
}

class _PersistingSettingsBridge extends HarnessBridge {
  _PersistingSettingsBridge()
    : super(books: harnessLibraryBooks(), covers: harnessCovers());

  @override
  Future<FlutterReaderSettings> loadReaderSettings({
    required BigInt cancellationId,
  }) async => savedSettings ?? settings;
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

  testWidgets('a Pages setting the reader cannot save stays reported over it '
      'until a retry saves it', (tester) async {
    _MountCounter.mounts = 0;
    final bridge = _FailingSettingsBridge();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      productionShell(
        home: ProductShell(
          bridgeFactory: () => bridge,
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
                displayChanged,
                places,
              ) => _MountCounter(
                child: Scaffold(
                  body: TextButton(
                    onPressed: () => displayChanged((
                      theme: null,
                      fontSize: null,
                      lineSpacing: null,
                      twoPages: false,
                      animations: false,
                      progress: null,
                      zonesHintDismissed: null,
                    )),
                    child: const Text('One page'),
                  ),
                ),
              ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _open(tester, 1);

    await tester.tap(find.text('One page'));
    await tester.pumpAndSettle();
    const failure = 'Reader settings could not be saved.';
    expect(find.text(failure), findsOneWidget);
    expect(find.text('disk full'), findsOneWidget);
    // It is no brief notice: the setting is still unsaved.
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect(find.text(failure), findsOneWidget);
    expect(_MountCounter.mounts, 1, reason: 'the reader is not remounted');

    bridge.failSaves = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text(failure), findsNothing);
    expect(bridge.savedSettings?.twoPages, isFalse);
    expect(bridge.savedSettings?.animations, isFalse);
    expect(_MountCounter.mounts, 1);
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
            displayChanged,
            places,
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
              displayChanged,
              places,
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

  testWidgets('a reader opens another book’s note in the shell', (
    tester,
  ) async {
    await _pump(tester, const Size(1440, 900));
    await tester.tap(_card(1));
    await tester.pumpAndSettle();
    expect(find.textContaining('Reading $_quiet'), findsOneWidget);

    await tester.tap(find.text('Open the atlas note'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Reading $_atlas'), findsOneWidget);
    expect(find.text('At 4:12'), findsOneWidget);
  });

  testWidgets('a book opened from another one leads Back to it', (
    tester,
  ) async {
    await _pump(
      tester,
      const Size(1440, 900),
      readerBuilder: _readerWithWayBack,
    );
    await tester.tap(_card(1));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Open the atlas note'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Reading $_atlas'), findsOneWidget);
    expect(find.text('At 4:12'), findsOneWidget);
    // The first book's own return points name it.
    expect(find.text('Back through 1:1:null 1:6:40'), findsOneWidget);

    // Back hands over what is left of the way: this book's points name it,
    // and the first book's become its own.
    await tester.tap(find.text('Back to the first book'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Reading $_quiet'), findsOneWidget);
    expect(find.text('At 1:5'), findsOneWidget);
    expect(find.text('Back through here:0:3 4:2:null'), findsOneWidget);
  });

  testWidgets('a direct file is not mislabeled as the tab’s library book', (
    tester,
  ) async {
    await _pump(
      tester,
      const Size(1440, 900),
      readerBuilder: _readerWithWayBack,
    );
    await tester.tap(_card(1));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open another file'));
    await tester.pump();

    await tester.tap(find.text('Open the atlas note'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Reading $_atlas'), findsOneWidget);
    expect(find.text('At 4:12'), findsOneWidget);
    expect(
      find.textContaining('Back through'),
      findsNothing,
      reason: 'the direct file has no library book destination for Back',
    );
  });

  testWidgets('a duplicate open keeps the first request’s way Back', (
    tester,
  ) async {
    await _pump(
      tester,
      const Size(1440, 900),
      readerBuilder: _readerWithWayBack,
    );
    await tester.tap(_card(1));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Open the atlas note twice'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Reading $_atlas'), findsOneWidget);
    expect(find.text('At 4:12'), findsOneWidget);
    expect(find.text('Back through 1:1:null 1:6:40'), findsOneWidget);
  });

  testWidgets('the Notes place lists every book’s notes and opens one there', (
    tester,
  ) async {
    final bridge = await _pump(tester, const Size(1440, 900));
    final [quiet, _, _, atlas, ...] = harnessLibraryBooks();
    bridge.libraryBookNotes = [
      FlutterBookNotes(
        book: atlas,
        notes: const [
          FlutterNoteEntry(
            id: 'atlas-highlight',
            kind: FlutterNoteEntryKind.highlight,
            color: FlutterHighlightColor.green,
            quote: 'Every map is a promise.',
            body: 'Open with this.',
            unit: 4,
            offset: 12,
            modifiedAt: '2026-10-01T00:00:00.000Z',
          ),
        ],
      ),
      FlutterBookNotes(
        book: quiet,
        notes: const [
          FlutterNoteEntry(
            id: 'quiet-book',
            kind: FlutterNoteEntryKind.book,
            body: 'A reading group pick.',
            modifiedAt: '2026-10-01T00:00:00.000Z',
          ),
          FlutterNoteEntry(
            id: 'quiet-page',
            kind: FlutterNoteEntryKind.page,
            body: 'The lead matters.',
            unit: 2,
            offset: 30,
            modifiedAt: '2026-10-01T00:00:00.000Z',
          ),
        ],
      ),
    ];

    await tester.tap(_sidebarNotes);
    await tester.pumpAndSettle();
    expect(bridge.libraryNotesCalls, 1);
    expect(find.text('3 notes'), findsOneWidget);
    expect(find.text('$_atlas · page 5'), findsOneWidget);
    expect(find.text('Every map is a promise.'), findsOneWidget);
    expect(find.text('$_quiet · Book note'), findsOneWidget);
    expect(find.text('$_quiet · Page note'), findsOneWidget);
    // Books most recently read first, each book's notes in reading order.
    double top(String id) =>
        tester.getRect(find.byKey(ValueKey('shell-note-$id'))).top;
    expect(top('atlas-highlight'), lessThan(top('quiet-book')));
    expect(top('quiet-book'), lessThan(top('quiet-page')));

    await tester.tap(find.byKey(const ValueKey('shell-note-quiet-page-open')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Reading $_quiet'), findsOneWidget);
    expect(find.text('At 2:30'), findsOneWidget);

    // Back on the Notes place the list is read again; a book note opens
    // the book where it was left.
    await tester.tap(find.byTooltip('Notes'));
    await tester.pumpAndSettle();
    expect(bridge.libraryNotesCalls, 2);
    await tester.tap(find.byKey(const ValueKey('shell-note-quiet-book-open')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Reading $_quiet'), findsOneWidget);
    expect(find.textContaining('At '), findsNothing);
  });

  testWidgets('the Notes place pages through the library’s books', (
    tester,
  ) async {
    final bridge = await _pump(tester, const Size(1440, 900));
    final books = harnessLibraryBooks();
    bridge.libraryBookNotes = [
      for (var i = 0; i < ShellNotesController.pageSize + 1; i += 1)
        FlutterBookNotes(
          book: books[i % books.length],
          notes: [
            FlutterNoteEntry(
              id: 'note-$i',
              kind: FlutterNoteEntryKind.book,
              body: 'Note $i',
              modifiedAt: '2026-10-01T00:00:00.000Z',
            ),
          ],
        ),
    ];
    await tester.tap(_sidebarNotes);
    await tester.pumpAndSettle();
    expect(find.text('${ShellNotesController.pageSize} notes'), findsOneWidget);

    final more = find.byKey(const ValueKey('shell-notes-more'));
    await tester.scrollUntilVisible(
      more,
      300,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('shell-notes')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.ensureVisible(more);
    await tester.pumpAndSettle();
    await tester.tap(more);
    await tester.pumpAndSettle();
    expect(
      find.byKey(ValueKey('shell-note-note-${ShellNotesController.pageSize}')),
      findsOneWidget,
    );
    expect(more, findsNothing);
    expect(bridge.libraryNotesCalls, 2);
  });

  testWidgets('More pages through every book and starts again when they '
      'are reordered', (tester) async {
    final bridge = await _pump(tester, const Size(1440, 900));
    FlutterBookNotes entry(int i) => FlutterBookNotes(
      book: FlutterLibraryBook(
        bookId: 1000 + i,
        title: 'Book $i',
        format: FlutterBookFormat.epub,
        pathKey: '/books/book-$i.epub',
        managed: true,
        progress: 0,
        dateAdded: '2026-10-01',
      ),
      notes: [
        FlutterNoteEntry(
          id: 'note-$i',
          kind: FlutterNoteEntryKind.book,
          body: 'Note $i',
          modifiedAt: '2026-10-01T00:00:00.000Z',
        ),
      ],
    );
    // More books than one page of the core's lists.
    bridge.libraryBookNotes = [for (var i = 0; i < 101; i += 1) entry(i)];
    await tester.tap(_sidebarNotes);
    await tester.pumpAndSettle();
    final scrollable = find
        .descendant(
          of: find.byKey(const ValueKey('shell-notes')),
          matching: find.byType(Scrollable),
        )
        .first;
    final more = find.byKey(const ValueKey('shell-notes-more'));
    Future<void> tapMore() async {
      await tester.scrollUntilVisible(more, 600, scrollable: scrollable);
      await tester.ensureVisible(more);
      await tester.pumpAndSettle();
      await tester.tap(more);
      await tester.pumpAndSettle();
    }

    await tapMore();
    // A book read meanwhile moves to the front: More lists from the first
    // book again instead of repeating one and skipping it.
    bridge.libraryBookNotes.insert(0, bridge.libraryBookNotes.removeAt(70));
    await tapMore();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('shell-note-note-70')),
      -600,
      scrollable: scrollable,
    );
    expect(find.text('${ShellNotesController.pageSize} notes'), findsOneWidget);

    // 20 books, then four pages of 20 and the last book.
    for (var page = 0; page < 5; page += 1) {
      await tapMore();
      expect(
        find.byKey(const ValueKey('shell-notes-more-error')),
        findsNothing,
      );
    }
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('shell-note-note-100')),
      600,
      scrollable: scrollable,
    );
    expect(more, findsNothing);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('shell-note-note-0')),
      -600,
      scrollable: scrollable,
    );
    expect(find.text('101 notes'), findsOneWidget);
  });

  testWidgets('a note opens its own book in a tab that showed another file', (
    tester,
  ) async {
    final bridge = await _pump(tester, const Size(1440, 900));
    final [quiet, ...] = harnessLibraryBooks();
    await _open(tester, 1);
    await tester.tap(find.text('Open another file'));
    await tester.pumpAndSettle();

    bridge.libraryBookNotes = [
      FlutterBookNotes(
        book: quiet,
        notes: const [
          FlutterNoteEntry(
            id: 'quiet-page',
            kind: FlutterNoteEntryKind.page,
            body: 'The lead matters.',
            unit: 2,
            offset: 30,
            modifiedAt: '2026-10-01T00:00:00.000Z',
          ),
        ],
      ),
    ];
    await tester.tap(find.byTooltip('Notes'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('shell-note-quiet-page-open')));
    await tester.pumpAndSettle();
    expect(
      find.text('Reading $_quiet at /books/quiet-cartographer.epub:1'),
      findsOneWidget,
    );
    expect(find.text('At 2:30'), findsOneWidget);
  });

  testWidgets('a failed notes list says why and retries', (tester) async {
    final bridge = await _pump(tester, const Size(1440, 900));
    bridge.libraryNotesFailure = const FlutterBridgeError(
      kind: FlutterBridgeErrorKind.backendUnavailable,
      message: 'The store is unavailable.',
    );
    await tester.tap(_sidebarNotes);
    await tester.pumpAndSettle();
    expect(find.text('The store is unavailable.'), findsOneWidget);

    bridge.libraryNotesFailure = null;
    await tester.tap(find.byKey(const ValueKey('shell-notes-retry')));
    await tester.pumpAndSettle();
    expect(find.text('No notes yet'), findsOneWidget);
    expect(bridge.libraryNotesCalls, 2);
  });

  group('search palette', () {
    Future<void> commandK(WidgetTester tester) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
    }

    final palette = find.byType(ShellSearchPalette);

    HarnessBridge withHits(HarnessBridge bridge) {
      final [quiet, _, _, atlas, ...] = harnessLibraryBooks();
      return bridge
        ..libraryNoteHits = [
          FlutterBookNoteHits(
            book: quiet,
            hits: const [
              FlutterNoteHit(
                note: FlutterNoteEntry(
                  id: 'quiet-page',
                  kind: FlutterNoteEntryKind.page,
                  body: 'The lead matters.',
                  unit: 2,
                  offset: 30,
                  modifiedAt: '2026-10-01T00:00:00.000Z',
                ),
                matches: [
                  FlutterNoteMatch(
                    field: FlutterNoteField.body,
                    offset: 4,
                    length: 4,
                  ),
                ],
              ),
            ],
          ),
        ]
        ..libraryTextHits = [
          FlutterBookTextHits(
            book: atlas,
            matches: [
              FlutterSearchMatch(
                unit: BigInt.from(4),
                offset: BigInt.from(120),
                length: BigInt.from(4),
                context: 'where the lead line runs',
              ),
            ],
          ),
        ];
    }

    testWidgets('finds notes and book text and opens a hit there', (
      tester,
    ) async {
      final bridge = withHits(await _pump(tester, const Size(1440, 900)));
      await commandK(tester);
      expect(palette, findsOneWidget);
      expect(
        find.byKey(const ValueKey('shell-search-scope')),
        findsNothing,
        reason: 'from the library every book is searched',
      );

      await tester.enterText(
        find.byKey(const ValueKey('shell-search-field')),
        'lead',
      );
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      expect(bridge.libraryNoteSearches, [('lead', null)]);
      expect(bridge.libraryTextSearches, [('lead', null)]);
      expect(find.text('NOTES · 1'), findsOneWidget);
      expect(find.text('$_quiet · Page note'), findsOneWidget);
      expect(find.text(_atlas), findsWidgets);
      expect(find.text('· 1 match'), findsOneWidget);
      // Notes come first, then each book's text.
      expect(
        tester.getRect(find.byKey(const ValueKey('shell-search-notes'))).top,
        lessThan(
          tester.getRect(find.byKey(const ValueKey('shell-search-book-4'))).top,
        ),
      );

      await tester.tap(find.byKey(const ValueKey('shell-search-text-4-0')));
      await tester.pumpAndSettle();
      expect(palette, findsNothing);
      expect(find.textContaining('Reading $_atlas'), findsOneWidget);
      expect(find.text('At 4:120'), findsOneWidget);

      // While reading, the palette searches this book first, with the last
      // query; a hit in it moves the open reader.
      await commandK(tester);
      expect(find.byKey(const ValueKey('shell-search-scope')), findsOneWidget);
      expect(bridge.libraryTextSearches.last, ('lead', 4));
      await tester.tap(find.byKey(const ValueKey('shell-search-text-4-0')));
      await tester.pumpAndSettle();
      expect(find.text('At 4:120'), findsNWidgets(2));

      // All books finds the note in another book, which opens at its place.
      await commandK(tester);
      await tester.tap(find.text('All books'));
      await tester.pumpAndSettle();
      expect(bridge.libraryNoteSearches.last, ('lead', null));
      await tester.tap(
        find.byKey(const ValueKey('shell-search-note-quiet-page')),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Reading $_quiet'), findsOneWidget);
      expect(find.text('At 2:30'), findsOneWidget);
      // The reader finds the note where this edition has it.
      expect(find.text('Resolving quiet-page as a note'), findsOneWidget);

      // A note hit in the book being read moves its reader the same way.
      await commandK(tester);
      await tester.tap(
        find.byKey(const ValueKey('shell-search-note-quiet-page')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Resolving quiet-page as a note'), findsNWidgets(2));
    });

    testWidgets('the filter keeps to text or notes', (tester) async {
      final bridge = withHits(await _pump(tester, const Size(1440, 900)));
      await commandK(tester);
      await tester.tap(find.text('Notes').last);
      await tester.enterText(
        find.byKey(const ValueKey('shell-search-field')),
        'lead',
      );
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      expect(bridge.libraryNoteSearches, hasLength(1));
      expect(bridge.libraryTextSearches, isEmpty);
      expect(find.text('NOTES · 1'), findsOneWidget);
      expect(find.byKey(const ValueKey('shell-search-book-4')), findsNothing);

      await tester.tap(find.text('Text').last);
      await tester.pumpAndSettle();
      expect(bridge.libraryTextSearches, hasLength(1));
      expect(find.text('NOTES · 1'), findsNothing);
      expect(find.byKey(const ValueKey('shell-search-book-4')), findsOneWidget);
    });

    testWidgets('a query that finds nothing says so', (tester) async {
      await _pump(tester, const Size(1440, 900));
      await commandK(tester);
      await tester.enterText(
        find.byKey(const ValueKey('shell-search-field')),
        'nowhere',
      );
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      expect(find.text('No matches for “nowhere”'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(palette, findsNothing);
    });

    testWidgets('the Search place and / open it, but / types in a field', (
      tester,
    ) async {
      await _pump(tester, const Size(1440, 900));
      await tester.tap(
        find
            .descendant(
              of: find.byType(ShellSidebar),
              matching: find.text('Search'),
            )
            .last,
      );
      await tester.pumpAndSettle();
      expect(palette, findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('shell-search-close')));
      await tester.pumpAndSettle();
      expect(palette, findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.slash);
      await tester.pumpAndSettle();
      expect(palette, findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      await tester.tap(find.byType(ShadInput).first);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.slash);
      await tester.pumpAndSettle();
      expect(palette, findsNothing);
    });

    testWidgets('each text hit marks its own match', (tester) async {
      final bridge = await _pump(tester, const Size(1440, 900));
      final [_, _, _, atlas, ...] = harnessLibraryBooks();
      FlutterSearchMatch hit(int at, String context, {int length = 4}) =>
          FlutterSearchMatch(
            unit: BigInt.from(4),
            offset: BigInt.from(100 + at),
            length: BigInt.from(length),
            context: context,
            contextOffset: BigInt.from(at),
          );
      bridge.libraryTextHits = [
        FlutterBookTextHits(
          book: atlas,
          matches: [
            hit(0, 'lead one lead two'),
            hit(9, 'lead one lead two'),
            // Full case folding: STRASSE is found as Straße.
            hit(4, 'Die Straße', length: 6),
          ],
        ),
      ];
      await commandK(tester);
      await tester.enterText(
        find.byKey(const ValueKey('shell-search-field')),
        'STRASSE',
      );
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();

      List<String?> parts(int index) => [
        for (final span
            in (tester
                        .widget<Text>(
                          find.descendant(
                            of: find.byKey(
                              ValueKey('shell-search-text-4-$index'),
                            ),
                            matching: find.byWidgetPredicate(
                              (widget) =>
                                  widget is Text && widget.textSpan != null,
                            ),
                          ),
                        )
                        .textSpan
                    as TextSpan)
                .children!)
          (span as TextSpan).text,
      ];
      expect(parts(0), ['', 'lead', ' one lead two']);
      expect(parts(1), ['lead one ', 'lead', ' two']);
      expect(parts(2), ['Die ', 'Straße', '']);
    });

    testWidgets('a phone reader’s Search button opens it', (tester) async {
      await _pump(
        tester,
        const Size(390, 844),
        readerBuilder:
            (
              bridge,
              book,
              settings,
              path,
              bookId,
              locatorChanged,
              noticeReporter,
              openBooksAction,
              displayChanged,
              placeRequests,
            ) => ReaderScreen(
              bridge: bridge,
              initialPath: path,
              initialBookId: bookId,
              initialSettings: harnessReaderSettings,
              placeRequests: placeRequests,
              onLocatorChanged: locatorChanged,
              noticeReporter: noticeReporter,
              openBooksAction: openBooksAction,
              onDisplayChanged: displayChanged,
            ),
      );
      await _open(tester, 1);
      for (var frame = 0; frame < 8; frame += 1) {
        await tester.pump(const Duration(milliseconds: 32));
      }

      await revealReaderChrome(tester);
      await tester.tap(find.byKey(const ValueKey('reader-header-search')));
      for (var frame = 0; frame < 8; frame += 1) {
        await tester.pump(const Duration(milliseconds: 32));
      }
      expect(palette, findsOneWidget);
      expect(
        find.byKey(const ValueKey('shell-search-scope')),
        findsOneWidget,
        reason: 'it searches this book first',
      );
    });

    testWidgets('its last results scroll above a phone’s keyboard', (
      tester,
    ) async {
      final bridge = await _pump(tester, const Size(390, 844));
      final [_, _, _, atlas, ...] = harnessLibraryBooks();
      bridge.libraryTextHits = [
        FlutterBookTextHits(
          book: atlas,
          matches: [
            for (var i = 0; i < 30; i += 1)
              FlutterSearchMatch(
                unit: BigInt.from(i),
                offset: BigInt.zero,
                length: BigInt.from(4),
                context: 'lead line $i',
              ),
          ],
        ),
      ];
      await commandK(tester);
      await tester.enterText(
        find.byKey(const ValueKey('shell-search-field')),
        'lead',
      );
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();

      final last = find.byKey(const ValueKey('shell-search-text-4-29'));
      await tester.scrollUntilVisible(
        last,
        300,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('shell-search-results')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      expect(tester.getRect(last).bottom, lessThanOrEqualTo(844 - 300));
    });

    testWidgets('Back returns to the book a hit was opened from', (
      tester,
    ) async {
      final bridge = withHits(
        await _pump(tester, const Size(1440, 900), readerBuilder: _realReader),
      );
      const donau =
          'Donaudampfschifffahrtsgesellschaftskapitaenskajuettenfenster';
      final back = find.byKey(const ValueKey('reader-back-pill'));
      await _open(tester, 3);
      await _readerSettles(tester, () => harnessReaderPageReady(tester));
      await tester.tap(find.byKey(const ValueKey('reader-edge-next')));
      await _readerSettles(
        tester,
        () => bridge.savedReadingStates.lastOrNull?.unit == BigInt.one,
      );
      final read = bridge.savedReadingStates.last;
      expect(read.unit, BigInt.one);

      await commandK(tester);
      await tester.tap(find.text('All books'));
      await tester.enterText(
        find.byKey(const ValueKey('shell-search-field')),
        'lead',
      );
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('shell-search-text-4-0')));
      await _readerSettles(tester, () => back.evaluate().isNotEmpty);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('reader-header-title')),
          matching: find.text('atlas.pdf'),
        ),
        findsOneWidget,
      );
      expect(find.text('Back to $donau'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('reader-back')));
      final donauTitle = find.descendant(
        of: find.byKey(const ValueKey('reader-header-title')),
        matching: find.text('donau.pdf'),
      );
      await _readerSettles(tester, () => donauTitle.evaluate().isNotEmpty);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('reader-header-title')),
          matching: find.text('donau.pdf'),
        ),
        findsOneWidget,
      );
      expect(back, findsNothing, reason: 'nothing is left to go back to');
      expect(bridge.savedReadingStates.last.unit, read.unit);
      expect(bridge.savedReadingStates.last.offset, read.offset);
    });

    testWidgets('a phone shows it full screen', (tester) async {
      await _pump(tester, const Size(390, 844));
      await commandK(tester);
      expect(
        tester
            .getSize(find.byKey(const ValueKey('shell-search-results')))
            .width,
        greaterThan(350),
      );
      expect(tester.getRect(palette).height, 844);
    });
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

  testWidgets('Back closes only the topmost switcher, then the reader panel', (
    tester,
  ) async {
    await _pump(tester, const Size(390, 844), readerBuilder: _realReader);
    await _open(tester, 3);
    await _readerSettles(tester, () => harnessReaderPageReady(tester));
    final panel = find.byKey(const ValueKey('reader-panel-notes'));
    await tester.tap(find.byKey(const ValueKey('reader-header-notes')));
    await tester.pumpAndSettle();
    expect(panel, findsOneWidget);
    await tester.tap(find.byTooltip('1 open book'));
    await tester.pumpAndSettle();
    expect(find.byType(ShellTabSwitcher), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(ShellTabSwitcher), findsNothing);
    expect(panel, findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(panel, findsNothing);
    expect(find.byType(ReaderScreen), findsOneWidget);
  });

  testWidgets('the tab switcher shows each book’s page as it was left', (
    tester,
  ) async {
    await _pump(
      tester,
      const Size(390, 844),
      readerBuilder: _realReader,
      devicePixelRatio: 4,
    );
    Finder page(int bookId) => find.byKey(ValueKey('shell-tab-page-$bookId'));
    await _open(tester, 3);
    await _readerSettles(tester, () => harnessReaderPageReady(tester));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await pumpHarnessFrames(tester, frames: 4);

    await tester.tap(find.byTooltip('1 open book'));
    await tester.pumpAndSettle();
    expect(page(3), findsOneWidget);
    final miniature = tester.widget<RawImage>(page(3)).image!;
    expect(miniature.width, lessThanOrEqualTo(420));
    expect(miniature.height, lessThanOrEqualTo(252));
    expect(miniature.height, greaterThan(0));

    // The library card leaves the reader; the next book's switcher still
    // shows the first one's page, now that its reader has gone.
    await tester.tap(
      find.descendant(
        of: find.byType(ShellTabSwitcher),
        matching: find.text('Library'),
      ),
    );
    await tester.pumpAndSettle();
    await _open(tester, 4);
    await _readerSettles(tester, () => harnessReaderPageReady(tester));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await pumpHarnessFrames(tester, frames: 4);
    await tester.tap(find.byTooltip('2 open books'));
    await tester.pumpAndSettle();
    expect(page(3), findsOneWidget);
    expect(page(4), findsOneWidget);

    // A closed book's page goes with it.
    await tester.tap(
      find.byTooltip(
        'Close Donaudampfschifffahrtsgesellschaftskapitaenskajuettenfenster',
      ),
    );
    await tester.pumpAndSettle();
    expect(page(3), findsNothing);
    expect(page(4), findsOneWidget);
  });

  testWidgets('the tab switcher captures the new page after pending paint', (
    tester,
  ) async {
    late ReaderPlaceRequests requests;
    await _pump(
      tester,
      const Size(390, 844),
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
            displayChanged,
            places,
          ) {
            requests = places;
            return _realReader(
              bridge,
              book,
              settings,
              path,
              bookId,
              locatorChanged,
              notices,
              openBooks,
              displayChanged,
              places,
            );
          },
    );
    final page = find.byKey(const ValueKey('shell-tab-page-3'));
    await _open(tester, 3);
    await _readerSettles(tester, () => harnessReaderPageReady(tester));
    final capture = requests.pageMiniature!;
    final settled = capture();
    expect(settled, isNotNull);
    settled!.dispose();

    // The page-turn transition dirties the isolated stage. Open the switcher
    // before pumping that frame: capture waits for the resulting frame rather
    // than retaining the old layer's pixels under the new document state.
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    expect(capture(), isNull);
    await tester.tap(find.byTooltip('1 open book'));
    await tester.pumpAndSettle();
    expect(find.byType(ShellTabSwitcher), findsOneWidget);
    expect(page, findsOneWidget);
  });

  testWidgets('a direct cross-book jump keeps the page it left', (
    tester,
  ) async {
    late ReaderPlaceRequests requests;
    await _pump(
      tester,
      const Size(390, 844),
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
            displayChanged,
            places,
          ) {
            requests = places;
            return _realReader(
              bridge,
              book,
              settings,
              path,
              bookId,
              locatorChanged,
              notices,
              openBooks,
              displayChanged,
              places,
            );
          },
    );
    await _open(tester, 3);
    await _readerSettles(tester, () => harnessReaderPageReady(tester));

    requests.openBook!(
      harnessLibraryBooks()[3],
      const ReaderPlace(4, offset: 12),
    );
    await tester.pumpAndSettle();
    await revealReaderChrome(tester);
    await tester.tap(find.byTooltip('2 open books'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('shell-tab-page-3')), findsOneWidget);
  });

  testWidgets('a theme chosen in the reader is saved for every book', (
    tester,
  ) async {
    final persisted = _PersistingSettingsBridge();
    final bridge = await _pump(
      tester,
      const Size(1440, 900),
      readerBuilder: _realReader,
      bridge: persisted,
    );
    await _open(tester, 3);
    await _readerSettles(tester, () => harnessReaderPageReady(tester));
    await tester.tap(find.byKey(const ValueKey('reader-header-typography')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sepia'));
    await _readerSettles(tester, () => bridge.savedSettings != null);
    expect(bridge.savedSettings!.theme, 'sepia');
    expect(
      bridge.savedSettings!.copyWith(theme: bridge.settings.theme),
      bridge.settings,
      reason: 'the other settings stay as they were',
    );

    await tester.tap(find.byTooltip('Library'));
    await tester.pumpAndSettle();
    await _open(tester, 1);
    await _readerSettles(tester, () => harnessReaderPageReady(tester));
    await tester.tap(find.byKey(const ValueKey('reader-header-typography')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<ReaderScreen>(find.byType(ReaderScreen))
          .initialSettings
          ?.theme,
      'sepia',
    );
    expect(
      tester
          .getSemantics(
            find.byKey(const ValueKey('reader-typography-theme-sepia')),
          )
          .getSemanticsData()
          .flagsCollection
          .isSelected,
      ui.Tristate.isTrue,
    );
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

  testWidgets('open books come back when the application starts again', (
    tester,
  ) async {
    final bridge = await _pump(tester, const Size(1440, 900));
    await _open(tester, 1);
    await tester.tap(find.byTooltip('Library'));
    await tester.pumpAndSettle();
    await _open(tester, 4);
    await tester.tap(find.text('Turn page'));
    await tester.pump();
    await tester.pumpAndSettle();

    // A cold start has no platform restoration: only the saved session.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      productionShell(
        home: ProductShell(bridgeFactory: () => bridge, readerBuilder: _reader),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Reading $_atlas at /books/atlas.pdf#later:4'),
      findsOneWidget,
    );
    expect(find.byTooltip(_quiet), findsOneWidget);
    expect(find.byTooltip(_atlas), findsOneWidget);
  });

  testWidgets('a slow read of the saved books keeps them until it finishes', (
    tester,
  ) async {
    final bridge = HarnessBridge(
      books: harnessLibraryBooks(),
      covers: harnessCovers(),
    );
    final records = bridge.records as BridgeForwardingRecords;
    final quiet = harnessLibraryBooks().first;
    final saved = (
      books: [(book: quiet, path: '${quiet.pathKey}#later', bookId: 1)],
      current: 1,
      reading: false,
    );
    records.openBooks = saved;
    final read = Completer<void>();
    records.openBooksRead = read.future;
    await _pump(tester, const Size(1440, 900), bridge: bridge);

    // A change before the read must not replace what it will read.
    await tester.tap(_sidebarNotes);
    await tester.pumpAndSettle();
    expect(records.openBooks, same(saved));

    read.complete();
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(ShellSidebar),
        matching: find.text('Library'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('6 books · 1 open'), findsOneWidget);
    expect(_openTag(1), findsOneWidget);
    expect(find.textContaining('Reading '), findsNothing);
  });

  testWidgets('a book opened before the saved ones are read replaces them', (
    tester,
  ) async {
    final bridge = HarnessBridge(
      books: harnessLibraryBooks(),
      covers: harnessCovers(),
    );
    final records = bridge.records as BridgeForwardingRecords;
    final quiet = harnessLibraryBooks().first;
    records.openBooks = (
      books: [(book: quiet, path: quiet.pathKey, bookId: 1)],
      current: 1,
      reading: true,
    );
    final read = Completer<void>();
    records.openBooksRead = read.future;
    await _pump(tester, const Size(1440, 900), bridge: bridge);
    await _open(tester, 4);

    read.complete();
    await tester.pumpAndSettle();
    expect(find.textContaining('Reading $_atlas'), findsOneWidget);
    expect(find.byTooltip(_quiet), findsNothing);
    expect(
      [for (final open in records.openBooks!.books) open.book.bookId],
      [4],
    );

    // Leaving the reader does not open the book the saved session read.
    await tester.tap(find.byTooltip('Library'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Reading '), findsNothing);
    expect(find.text('6 books · 1 open'), findsOneWidget);
    expect(_openTag(1), findsNothing);
  });

  testWidgets('a platform restoration wins over the saved open books', (
    tester,
  ) async {
    final bridge = await _pump(tester, const Size(1440, 900));
    final records = bridge.records as BridgeForwardingRecords;
    await _open(tester, 1);
    await tester.tap(find.byTooltip('Library'));
    await tester.pumpAndSettle();
    final other = harnessLibraryBooks()[1];
    records.openBooks = (
      books: [(book: other, path: other.pathKey, bookId: other.bookId)],
      current: other.bookId,
      reading: true,
    );

    await tester.restartAndRestore();
    await tester.pumpAndSettle();

    expect(find.textContaining('Reading '), findsNothing);
    expect(find.text('6 books · 1 open'), findsOneWidget);
    expect(_openTag(1), findsOneWidget);
    expect(_openTag(other.bookId), findsNothing);
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
