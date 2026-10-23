import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_epub/shosai_epub.dart';
import 'package:shosai_flutter/reader/controller.dart';
import 'package:shosai_flutter/reader/epub/content.dart';
import 'package:shosai_flutter/reader/epub/surface.dart';
import 'package:shosai_flutter/reader/view.dart';
import 'package:shosai_flutter/core/bridge.dart';
import 'package:shosai_flutter/theme_tokens.dart';

import '../support/epub_navigation_fixture.dart';
import '../support/production_shell_harness.dart';
import '../support/selection_surface_fixture.dart';

/// Slice 4 navigation tests: the retained Contents panel serves the book's real
/// table of contents, and links painted on a Dart-rendered page navigate
/// through the guarded layout path.
///
/// The fixture archive is parsed by the real engine; the bridge is the
/// deterministic harness, so the *navigation decision* (target chapter, durable
/// offset, fallback and refusal) is what these tests isolate. The native bridge
/// parity suite covers the same resolution against the real Rust bridge.
///
/// Alternates frame pumps with real-event-loop windows so native completions
/// (open, engine parse, layout, annotation reads) can arrive and settle.
Future<void> settleNative(WidgetTester tester, {int rounds = 4}) async {
  for (var round = 0; round < rounds; round += 1) {
    await pumpHarnessFrames(tester, frames: 4);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 120)),
    );
  }
  await pumpHarnessFrames(tester, frames: 4);
}

/// The harness bridge with a controllable durable position and recorded
/// cancellation ownership.
class _NavigationBridge extends HarnessBridge {
  _NavigationBridge({
    required super.books,
    required super.unitCount,
    this.readingState,
  });

  /// The durable position every `loadReadingState` returns.
  final FlutterReadingState? readingState;

  /// Cancellation tokens the controller created, cancelled and released, in
  /// order. A test asserts a scoped operation releases what it created.
  final List<BigInt> createdCancellations = [];
  final List<BigInt> cancelledCancellations = [];
  final List<BigInt> releasedCancellations = [];

  /// The tokens the Contents load created, which the reader starts on its own
  /// once a document opens.
  final List<BigInt> contentsCancellations = [];

  /// How many Contents loads have their `createCancellation` refused.
  int contentsCancellationFailures = 0;

  @override
  BigInt createCancellation() {
    // The load runs right after the open, between the open's own scoped
    // operations, so its call is told apart by its caller rather than by
    // its position.
    final contents = StackTrace.current.toString().contains(
      '_contentsRequested',
    );
    if (contents && contentsCancellationFailures > 0) {
      contentsCancellationFailures -= 1;
      throw const FlutterBridgeError(
        kind: FlutterBridgeErrorKind.invalidRequest,
        message: 'the harness refuses a cancellation',
      );
    }
    final id = super.createCancellation();
    createdCancellations.add(id);
    if (contents) contentsCancellations.add(id);
    return id;
  }

  @override
  bool cancel({required BigInt id}) {
    cancelledCancellations.add(id);
    return super.cancel(id: id);
  }

  @override
  bool releaseCancellation({required BigInt id}) {
    releasedCancellations.add(id);
    return super.releaseCancellation(id: id);
  }

  /// When set, opening a book waits for it, so a test can act while the
  /// book opens.
  Completer<void>? openGate;

  @override
  Future<FlutterReadingState?> loadReadingState({
    required int bookId,
    required BigInt cancellationId,
  }) async {
    await openGate?.future;
    return readingState;
  }
}

void main() {
  final bytes = navigationEpub();
  final book = openEpubBytes(bytes);

  /// The harness bridge serving the navigation fixture.
  ///
  /// A second library book exists so a replacement document can be opened as a
  /// library book: its durable writes are recorded, which is what proves a
  /// stale navigation did not move it.
  _NavigationBridge bridge({
    int unitCount = 3,
    FlutterReadingState? readingState,
  }) {
    final harness = _NavigationBridge(
      books: const [
        FlutterLibraryBook(
          bookId: 1,
          title: 'Reader Navigation',
          format: FlutterBookFormat.epub,
          pathKey: '/books/navigation.epub',
          managed: true,
          progress: 0,
          dateAdded: '2026-10-01',
        ),
        FlutterLibraryBook(
          bookId: 2,
          title: 'Replacement',
          format: FlutterBookFormat.pdf,
          pathKey: '/books/replacement.pdf',
          managed: true,
          progress: 0,
          dateAdded: '2026-10-01',
        ),
      ],
      unitCount: unitCount,
      readingState: readingState,
    );
    harness.epubBytes = bytes;
    return harness;
  }

  Future<void> openReader(
    WidgetTester tester,
    HarnessBridge harness, {
    List<String>? openedLinks,
    ReaderPickedDocument? picked,
    ReaderPlace? place,
    ReaderPlaceRequests? placeRequests,
  }) async {
    await renderHarnessState(
      tester,
      productionShell(
        home: ReaderScreen(
          bridge: harness,
          initialPath: '/books/navigation.epub',
          initialBookId: 1,
          initialPlace: place,
          placeRequests: placeRequests,
          epubImageDecoder: (bytes) async => null,
          externalLinkOpener: (url) async => openedLinks?.add(url),
          documentPicker: picked == null ? null : () async => picked,
        ),
      ),
      ready: () => harnessReaderPageReady(tester),
      maxRounds: 16,
    );
  }

  ReaderEpubPageContentPainter? dartPage(WidgetTester tester) {
    for (final paint in tester.widgetList<CustomPaint>(
      find.byType(CustomPaint),
    )) {
      final painter = paint.painter;
      if (painter is ReaderEpubPageContentPainter) return painter;
    }
    return null;
  }

  /// Pumps until the installed Dart page stops changing size.
  ///
  /// Opening a document reports its content box twice (the opening body, then
  /// the document body), so the first page is followed by a corrected layout;
  /// a test that taps chrome in between would tap a disabled control.
  Future<void> settleEpubPage(WidgetTester tester) async {
    Size? previous;
    for (var round = 0; round < 16; round += 1) {
      await settleNative(tester, rounds: 1);
      final page = dartPage(tester);
      if (page == null) return;
      final size = page.page.box.size;
      if (size == previous) return;
      previous = size;
    }
  }

  /// The Contents panel's own text: the toolbar and status line also name
  /// the current section.
  Finder inContents(String text) => find.descendant(
    of: find.byKey(const ValueKey('reader-panel-contents')),
    matching: find.text(text),
  );

  Future<void> openContents(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('reader-header-contents')));
    await tester.pump();
    await settleNative(tester);
  }

  /// The global tap point of the painted link with [href] on the current page.
  Offset? linkTapPoint(WidgetTester tester, String href) {
    final painter = dartPage(tester);
    if (painter == null) return null;
    final page = painter.page;
    final paintBox = tester.renderObject<RenderBox>(
      find.byKey(const ValueKey('reader-page-paint')),
    );
    final transform = SurfaceTransform.create(
      BoxFit.contain,
      page.box.size,
      paintBox.size,
    );
    for (final slice in page.page.slices) {
      for (final placed in placedPageText(slice)) {
        for (final link in placed.block.links) {
          if (link.href != href) continue;
          final boxes = placed.block.painter.getBoxesForSelection(
            TextSelection(baseOffset: link.start, extentOffset: link.end),
          );
          if (boxes.isEmpty) continue;
          final rect = page.box.rectToPage(
            boxes.first.toRect().shift(placed.origin),
          );
          final global =
              paintBox.localToGlobal(Offset.zero) +
              transform.toDestinationRect(rect).center;
          return global;
        }
      }
    }
    return null;
  }

  Future<void> tapLink(WidgetTester tester, String href) async {
    final point = linkTapPoint(tester, href);
    expect(point, isNotNull, reason: 'the link $href is painted on this page');
    await tester.tapAt(point!);
    await settleNative(tester);
  }

  Future<void> drainHarness(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
  }

  group('real table of contents', () {
    testWidgets('the panel shows the book TOC with authored depths', (
      tester,
    ) async {
      final harness = bridge();
      await openReader(tester, harness);
      await settleEpubPage(tester);
      await openContents(tester);

      expect(inContents('Chapter one'), findsOneWidget);
      expect(inContents('Chapter two target'), findsOneWidget);
      expect(inContents('Chapter three deep'), findsOneWidget);
      expect(inContents('Encoded path'), findsOneWidget);
      // The title-only part heading resolves to no location and is not shown;
      // its child keeps the authored depth of one.
      expect(find.text(navigationFixturePartTitle), findsNothing);
      expect(find.text(navigationFixtureMissingTitle), findsNothing);
      // The row keeps the panel's full width for its hover; its title is
      // what indents.
      Rect title(String key) => tester.getRect(
        find.descendant(
          of: find.byKey(ValueKey(key)),
          matching: find.byType(Text),
        ),
      );
      final nested = title('reader-contents-entry-0');
      final top = title('reader-contents-entry-2');
      expect(
        nested.left - top.left,
        ShosaiTokens.layoutReaderPanelEntryIndent,
        reason: 'a depth-1 entry is indented once',
      );
      // Exactly one row is the current entry, even though a real TOC can name
      // one chapter more than once.
      final selected = tester
          .widgetList<Semantics>(find.byType(Semantics))
          .where(
            (widget) =>
                widget.properties.selected == true &&
                widget.properties.label != null &&
                widget.properties.label!.startsWith('Chapter '),
          );
      expect(selected, hasLength(1));

      await tester.pumpWidget(const SizedBox());
      await drainHarness(tester);
    });

    testWidgets('an entry navigates to its durable anchor offset', (
      tester,
    ) async {
      final harness = bridge();
      await openReader(tester, harness);
      await settleEpubPage(tester);
      await openContents(tester);

      await tester.tap(find.byKey(const ValueKey('reader-contents-entry-2')));
      await settleNative(tester);

      expect(
        harness.savedReadingStates.last.unit.toInt(),
        2,
        reason: 'the entry addresses its chapter',
      );
      expect(
        harness.savedReadingStates.last.offset?.toInt(),
        book.chapters[2].anchors['three-deep'],
        reason: 'the verified anchor offset is the durable target',
      );

      await tester.pumpWidget(const SizedBox());
      await drainHarness(tester);
    });

    testWidgets('disposal cancels the source read it owns', (tester) async {
      final harness = bridge();
      // The open's layout waits on the held archive read.
      final held = Completer<Uint8List>();
      harness.epubSourceCompleters.add(held);
      await tester.pumpWidget(
        productionShell(
          home: ReaderScreen(
            bridge: harness,
            initialPath: '/books/navigation.epub',
            initialBookId: 1,
            epubImageDecoder: (bytes) async => null,
          ),
        ),
      );
      for (
        var round = 0;
        round < 16 && harness.epubSourceCancellations.isEmpty;
        round += 1
      ) {
        await settleNative(tester, rounds: 1);
      }
      expect(harness.epubSourceCancellations, hasLength(1));
      final sourceToken = harness.epubSourceCancellations.single;

      await tester.pumpWidget(const SizedBox());
      expect(
        harness.cancelledCancellations,
        contains(sourceToken),
        reason: 'disposal cancels the source read it no longer needs',
      );

      held.complete(bytes);
      await drainHarness(tester);
      expect(
        harness.releasedCancellations.where((id) => id == sourceToken),
        hasLength(1),
        reason: 'the source load releases its token exactly once',
      );
    });

    testWidgets('a non-EPUB document keeps the chapter fallback', (
      tester,
    ) async {
      final harness = HarnessBridge(unitCount: 3);
      await openReader(tester, harness);
      await settleNative(tester);
      await openContents(tester);

      expect(find.text('Chapter 1'), findsOneWidget);
      expect(find.text('Chapter 3'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await drainHarness(tester);
    });

    testWidgets('the restored position selects the matching entry', (
      tester,
    ) async {
      final harness = bridge(
        readingState: FlutterReadingState(
          unit: BigInt.from(1),
          offset: BigInt.from(21),
          zoom: 1,
        ),
      );
      await openReader(tester, harness);
      await settleEpubPage(tester);
      await openContents(tester);

      final current = tester.getSemantics(
        find.byKey(const ValueKey('reader-contents-entry-1')),
      );
      expect(
        current.getSemanticsData().flagsCollection.isSelected,
        ui.Tristate.isTrue,
        reason: 'the restored chapter entry is the current one',
      );
      expect(
        tester
            .getSemantics(find.byKey(const ValueKey('reader-contents-entry-0')))
            .getSemanticsData()
            .flagsCollection
            .isSelected,
        isNot(ui.Tristate.isTrue),
        reason: 'exactly one entry is current',
      );

      await tester.pumpWidget(const SizedBox());
      await drainHarness(tester);
    });

    testWidgets('a place to open at wins over the saved position', (
      tester,
    ) async {
      // A note opened from the library opens the book at the note, not where
      // it was left.
      final harness = bridge(
        readingState: FlutterReadingState(
          unit: BigInt.zero,
          offset: BigInt.from(200),
          zoom: 1,
        ),
      );
      await openReader(
        tester,
        harness,
        place: const ReaderPlace(1, offset: 21),
      );
      await settleEpubPage(tester);
      await openContents(tester);

      expect(
        tester
            .getSemantics(find.byKey(const ValueKey('reader-contents-entry-1')))
            .getSemanticsData()
            .flagsCollection
            .isSelected,
        ui.Tristate.isTrue,
        reason: 'the chapter of the place is the current one',
      );

      await tester.pumpWidget(const SizedBox());
      await drainHarness(tester);
    });

    testWidgets('a note opens where it resolves in this edition', (
      tester,
    ) async {
      bool current(int entry) =>
          tester
              .getSemantics(
                find.byKey(ValueKey('reader-contents-entry-$entry')),
              )
              .getSemanticsData()
              .flagsCollection
              .isSelected ==
          ui.Tristate.isTrue;
      FlutterNote note(FlutterAnnotationResolution resolution) => FlutterNote(
        id: 'note',
        kind: FlutterNoteKind.page,
        unit: BigInt.two,
        offset: BigInt.from(5),
        resolution: resolution,
        body: 'Moved',
        modifiedAt: '2026-10-01T00:00:00.000Z',
      );
      // Written in chapter 2 of another edition; here it resolves in 3.
      const place = ReaderPlace(
        1,
        offset: 21,
        annotationId: 'note',
        note: true,
      );

      final recovered = bridge()
        ..placeNotes.add(note(FlutterAnnotationResolution.recovered));
      await openReader(tester, recovered, place: place);
      await settleEpubPage(tester);
      await openContents(tester);
      expect(current(2), isTrue, reason: 'the resolved chapter');
      await tester.pumpWidget(const SizedBox());
      await drainHarness(tester);

      // A note this edition lost opens where the book was left, and says so.
      final orphaned = bridge(
        readingState: FlutterReadingState(unit: BigInt.zero, zoom: 1),
      )..placeNotes.add(note(FlutterAnnotationResolution.orphaned));
      await openReader(tester, orphaned, place: place);
      await settleEpubPage(tester);
      expect(
        find.text("This note's place isn't in this edition of the book."),
        findsOneWidget,
      );
      await openContents(tester);
      expect(current(0), isTrue, reason: 'the saved position');

      await tester.pumpWidget(const SizedBox());
      await drainHarness(tester);
    });

    testWidgets('an open reader goes to a place the shell asks for', (
      tester,
    ) async {
      final requests = ReaderPlaceRequests();
      final harness = bridge();
      await openReader(tester, harness, placeRequests: requests);
      await settleEpubPage(tester);

      requests.go(const ReaderPlace(1, offset: 21));
      await settleEpubPage(tester);
      await openContents(tester);
      expect(
        tester
            .getSemantics(find.byKey(const ValueKey('reader-contents-entry-1')))
            .getSemanticsData()
            .flagsCollection
            .isSelected,
        ui.Tristate.isTrue,
      );

      await tester.pumpWidget(const SizedBox());
      await drainHarness(tester);
    });

    group('a note place still resolving', () {
      FlutterNote note(
        String id,
        int unit, [
        FlutterAnnotationResolution resolution =
            FlutterAnnotationResolution.exact,
      ]) => FlutterNote(
        id: id,
        kind: FlutterNoteKind.page,
        unit: BigInt.from(unit),
        offset: BigInt.zero,
        resolution: resolution,
        body: id,
        modifiedAt: '2026-10-01T00:00:00.000Z',
      );
      ReaderPlace place(String id, int unit) =>
          ReaderPlace(unit, offset: 0, annotationId: id, note: true);
      bool current(WidgetTester tester, int entry) =>
          tester
              .getSemantics(
                find.byKey(ValueKey('reader-contents-entry-$entry')),
              )
              .getSemanticsData()
              .flagsCollection
              .isSelected ==
          ui.Tristate.isTrue;

      testWidgets('goes where this edition has it, or says it is lost', (
        tester,
      ) async {
        final requests = ReaderPlaceRequests();
        final harness = bridge()
          ..placeNotes.addAll([
            note('moved', 2, FlutterAnnotationResolution.recovered),
            note('lost', 1, FlutterAnnotationResolution.orphaned),
          ]);
        await openReader(tester, harness, placeRequests: requests);
        await settleEpubPage(tester);

        // Written in chapter 2 of another edition; here it is in chapter 3.
        requests.go(place('moved', 1));
        await settleNative(tester, rounds: 8);
        await settleEpubPage(tester);
        await openContents(tester);
        expect(current(tester, 2), isTrue, reason: 'where it resolves');
        await openContents(tester);

        requests.go(place('lost', 1));
        await settleNative(tester, rounds: 8);
        await settleEpubPage(tester);
        expect(
          find.text("This note's place isn't in this edition of the book."),
          findsOneWidget,
        );
        await openContents(tester);
        expect(current(tester, 2), isTrue, reason: 'the reader stays put');

        await tester.pumpWidget(const SizedBox());
        await drainHarness(tester);
      });

      Future<void> openAllBooksNote(WidgetTester tester, String id) async {
        await tester.tap(find.byKey(const ValueKey('reader-header-notes')));
        await settleNative(tester);
        await tester.tap(find.byKey(const ValueKey('reader-notes-all-books')));
        await settleNative(tester);
        await tester.tap(find.byKey(ValueKey('shell-note-$id-open')));
        await settleNative(tester, rounds: 8);
        await settleEpubPage(tester);
        await tester.tap(find.byKey(const ValueKey('reader-header-notes')));
        await settleNative(tester);
      }

      FlutterBookNotes listed(_NavigationBridge harness, String id, int unit) =>
          FlutterBookNotes(
            book: harness.books.first,
            notes: [
              FlutterNoteEntry(
                id: id,
                kind: FlutterNoteEntryKind.page,
                body: id,
                unit: unit,
                offset: 0,
                modifiedAt: '2026-10-01T00:00:00.000Z',
              ),
            ],
          );

      testWidgets('from All books goes where this edition has it', (
        tester,
      ) async {
        final harness = bridge()
          ..placeNotes.add(
            note('moved', 2, FlutterAnnotationResolution.recovered),
          );
        // Listed where it was made, in another edition's chapter 2.
        harness.libraryBookNotes = [listed(harness, 'moved', 1)];
        await openReader(tester, harness);
        await settleEpubPage(tester);

        await openAllBooksNote(tester, 'moved');
        await openContents(tester);
        expect(current(tester, 2), isTrue, reason: 'where it resolves');

        await tester.pumpWidget(const SizedBox());
        await drainHarness(tester);
      });

      testWidgets('yields to a note opened from All books', (tester) async {
        final requests = ReaderPlaceRequests();
        final harness = bridge()
          ..placeNotes.addAll([note('far', 2), note('near', 1)]);
        harness.libraryBookNotes = [listed(harness, 'near', 1)];
        await openReader(tester, harness, placeRequests: requests);
        await settleEpubPage(tester);
        final older = Completer<void>();
        harness.noteListGates.add(older);

        requests.go(place('far', 2));
        await tester.pump();
        await openAllBooksNote(tester, 'near');
        older.complete();
        await settleNative(tester, rounds: 8);
        await settleEpubPage(tester);
        await openContents(tester);
        expect(current(tester, 1), isTrue, reason: 'the note chosen last');

        await tester.pumpWidget(const SizedBox());
        await drainHarness(tester);
      });

      testWidgets('yields to a newer place', (tester) async {
        final requests = ReaderPlaceRequests();
        final harness = bridge()..placeNotes.add(note('far', 2));
        await openReader(tester, harness, placeRequests: requests);
        await settleEpubPage(tester);
        final gate = Completer<void>();
        harness.noteListGates.add(gate);

        requests.go(place('far', 2));
        await tester.pump();
        requests.go(const ReaderPlace(1, offset: 21));
        await settleEpubPage(tester);
        gate.complete();
        await settleNative(tester, rounds: 8);
        await settleEpubPage(tester);
        await openContents(tester);
        expect(current(tester, 1), isTrue, reason: 'the newer place');

        await tester.pumpWidget(const SizedBox());
        await drainHarness(tester);
      });

      testWidgets('yields to the reader going elsewhere', (tester) async {
        final requests = ReaderPlaceRequests();
        final harness = bridge()
          ..placeNotes.add(
            note('lost', 2, FlutterAnnotationResolution.orphaned),
          );
        await openReader(tester, harness, placeRequests: requests);
        await settleEpubPage(tester);
        final gate = Completer<void>();
        harness.noteListGates.add(gate);

        requests.go(place('lost', 2));
        await tester.pump();
        await openContents(tester);
        await tester.tap(inContents('Chapter two target'));
        await settleEpubPage(tester);
        gate.complete();
        await settleNative(tester, rounds: 8);
        await settleEpubPage(tester);
        expect(
          find.text("This note's place isn't in this edition of the book."),
          findsNothing,
          reason: 'a place given up for no longer reports on itself',
        );
        await openContents(tester);
        expect(current(tester, 1), isTrue, reason: 'where the reader went');

        await tester.pumpWidget(const SizedBox());
        await drainHarness(tester);
      });

      testWidgets('that finishes after a newer one is dropped', (tester) async {
        final requests = ReaderPlaceRequests();
        final harness = bridge()
          ..placeNotes.addAll([note('far', 2), note('near', 1)]);
        await openReader(tester, harness, placeRequests: requests);
        await settleEpubPage(tester);
        final older = Completer<void>();
        final newer = Completer<void>();
        harness.noteListGates.addAll([older, newer]);

        requests.go(place('far', 2));
        await tester.pump();
        requests.go(place('near', 1));
        await tester.pump();
        newer.complete();
        await settleNative(tester, rounds: 8);
        await settleEpubPage(tester);
        older.complete();
        await settleNative(tester, rounds: 8);
        await settleEpubPage(tester);
        await openContents(tester);
        expect(current(tester, 1), isTrue, reason: 'the newer note');

        await tester.pumpWidget(const SizedBox());
        await drainHarness(tester);
      });
    });

    testWidgets('the last place asked for while the book opens is kept', (
      tester,
    ) async {
      final requests = ReaderPlaceRequests();
      final gate = Completer<void>();
      final harness = bridge()..openGate = gate;
      await tester.pumpWidget(
        productionShell(
          home: ReaderScreen(
            bridge: harness,
            initialPath: '/books/navigation.epub',
            initialBookId: 1,
            placeRequests: requests,
            epubImageDecoder: (bytes) async => null,
          ),
        ),
      );
      await tester.pump();

      requests.go(const ReaderPlace(2));
      await tester.pump();
      requests.go(const ReaderPlace(1, offset: 21));
      await tester.pump();
      gate.complete();
      await settleNative(tester, rounds: 8);
      await settleEpubPage(tester);
      await openContents(tester);
      expect(
        tester
            .getSemantics(find.byKey(const ValueKey('reader-contents-entry-1')))
            .getSemanticsData()
            .flagsCollection
            .isSelected,
        ui.Tristate.isTrue,
      );

      await tester.pumpWidget(const SizedBox());
      await drainHarness(tester);
    });

    testWidgets('a jump shows Back, which returns where it left from', (
      tester,
    ) async {
      final harness = bridge();
      await openReader(tester, harness);
      await settleEpubPage(tester);
      expect(find.byKey(const ValueKey('reader-back-pill')), findsNothing);

      await openContents(tester);
      await tester.tap(find.byKey(const ValueKey('reader-contents-entry-2')));
      await settleNative(tester);
      if (find
          .byKey(const ValueKey('reader-panel-contents'))
          .evaluate()
          .isNotEmpty) {
        await tester.tap(find.byKey(const ValueKey('reader-header-contents')));
      }
      await settleEpubPage(tester);
      expect(find.byKey(const ValueKey('reader-back-pill')), findsOneWidget);
      expect(find.text('Back to Chapter one'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('reader-back')));
      await settleEpubPage(tester);
      expect(find.byKey(const ValueKey('reader-back-pill')), findsNothing);
      await openContents(tester);
      expect(
        tester
            .getSemantics(find.byKey(const ValueKey('reader-contents-entry-0')))
            .getSemanticsData()
            .flagsCollection
            .isSelected,
        ui.Tristate.isTrue,
        reason: 'Back returned to the first chapter',
      );

      await tester.pumpWidget(const SizedBox());
      await drainHarness(tester);
    });

    testWidgets('a long Back label fits a phone at a large text size', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 720);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 3;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final requests = ReaderPlaceRequests();
      final harness = bridge(
        readingState: FlutterReadingState(
          unit: BigInt.from(2),
          offset: BigInt.from(200),
          zoom: 1,
        ),
      );
      await openReader(tester, harness, placeRequests: requests);
      await settleEpubPage(tester);
      requests.go(const ReaderPlace(0, offset: 0));
      await settleEpubPage(tester);

      final pill = find.byKey(const ValueKey('reader-back-pill'));
      expect(pill, findsOneWidget);
      expect(find.textContaining('Back to'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(tester.getRect(pill).width, lessThanOrEqualTo(360));
      expect(
        find.byKey(const ValueKey('reader-back-dismiss')).hitTestable(),
        findsOneWidget,
        reason: 'the close button stays on screen',
      );

      await tester.pumpWidget(const SizedBox());
      await drainHarness(tester);
    });

    testWidgets('a turn the reader refuses does not count against Back', (
      tester,
    ) async {
      final requests = ReaderPlaceRequests();
      final harness = bridge();
      await openReader(tester, harness, placeRequests: requests);
      await settleEpubPage(tester);
      // The last chapter's one page: there is nothing after it.
      requests.go(const ReaderPlace(2, offset: 0));
      await settleEpubPage(tester);
      for (var turn = 0; turn < 3; turn += 1) {
        await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
        await settleEpubPage(tester);
      }
      expect(find.byKey(const ValueKey('reader-back-pill')), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await drainHarness(tester);
    });

    testWidgets(
      'Alt+← goes back, but moves by word in a text field',
      (tester) async {
        final harness = bridge();
        await openReader(tester, harness);
        await settleEpubPage(tester);
        Future<void> jump() async {
          await openContents(tester);
          await tester.tap(inContents('Chapter three deep'));
          await settleEpubPage(tester);
          if (find
              .byKey(const ValueKey('reader-panel-contents'))
              .evaluate()
              .isNotEmpty) {
            await tester.tap(
              find.byKey(const ValueKey('reader-header-contents')),
            );
            await settleEpubPage(tester);
          }
        }

        final mac = defaultTargetPlatform == TargetPlatform.macOS;
        Future<void> press({required bool back}) async {
          final (key, modifier) = back == mac
              ? (LogicalKeyboardKey.bracketLeft, LogicalKeyboardKey.metaLeft)
              : (LogicalKeyboardKey.arrowLeft, LogicalKeyboardKey.altLeft);
          await tester.sendKeyDownEvent(modifier);
          await tester.sendKeyEvent(key);
          await tester.sendKeyUpEvent(modifier);
          await settleEpubPage(tester);
        }

        final pill = find.byKey(const ValueKey('reader-back-pill'));
        await jump();
        expect(pill, findsOneWidget);
        // The other platform's shortcut does nothing here.
        await press(back: false);
        expect(pill, findsOneWidget);

        // In the search field the key moves the caret instead.
        await tester.tap(find.byKey(const ValueKey('reader-header-search')));
        await settleNative(tester);
        final field = find.byType(EditableText);
        expect(field, findsOneWidget);
        await tester.enterText(field, 'two words');
        await press(back: true);
        expect(pill, findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('reader-header-search')));
        await settleNative(tester);
        await press(back: true);
        expect(pill, findsNothing);

        await tester.pumpWidget(const SizedBox());
        await drainHarness(tester);
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.linux,
        TargetPlatform.macOS,
      }),
    );

    testWidgets('a book opened at a place goes back to where it was left', (
      tester,
    ) async {
      final harness = bridge(
        readingState: FlutterReadingState(
          unit: BigInt.from(2),
          offset: BigInt.from(20),
          zoom: 1,
        ),
      );
      await openReader(
        tester,
        harness,
        place: const ReaderPlace(1, offset: 21),
      );
      await settleEpubPage(tester);
      expect(find.byKey(const ValueKey('reader-back-pill')), findsOneWidget);

      // Closing it stays.
      await tester.tap(find.byKey(const ValueKey('reader-back-dismiss')));
      await settleNative(tester);
      expect(find.byKey(const ValueKey('reader-back-pill')), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await drainHarness(tester);
    });

    testWidgets('a book opened at a search match marks it on the page', (
      tester,
    ) async {
      final harness = bridge();
      await openReader(
        tester,
        harness,
        place: const ReaderPlace(1, offset: 0, length: 6),
      );
      await settleEpubPage(tester);

      final status = tester
          .getSemantics(find.byKey(const ValueKey('reader-selection-status')))
          .getSemanticsData()
          .label;
      expect(status, 'Selected text: Second');

      await tester.pumpWidget(const SizedBox());
      await drainHarness(tester);
    });

    testWidgets('three page turns away or Stay here close Back', (
      tester,
    ) async {
      final requests = ReaderPlaceRequests();
      final harness = bridge();
      await openReader(tester, harness, placeRequests: requests);
      await settleEpubPage(tester);
      requests.go(const ReaderPlace(1, offset: 0));
      await settleEpubPage(tester);
      expect(find.byKey(const ValueKey('reader-back-pill')), findsOneWidget);

      // The book has three one-page chapters: forward to the last, then back.
      for (final edge in ['next', 'previous', 'previous']) {
        expect(find.byKey(const ValueKey('reader-back-pill')), findsOneWidget);
        await tester.tap(find.byKey(ValueKey('reader-edge-$edge')));
        await settleEpubPage(tester);
      }
      expect(find.byKey(const ValueKey('reader-back-pill')), findsNothing);

      // Stay here closes Back too.
      requests.go(const ReaderPlace(2, offset: 0));
      await settleEpubPage(tester);
      await tester.tap(find.byKey(const ValueKey('reader-back-dismiss')));
      await tester.pump();
      expect(find.byKey(const ValueKey('reader-back-pill')), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await drainHarness(tester);
    });

    testWidgets('a later row of the same chapter is the current one', (
      tester,
    ) async {
      // The restored offset is past the chapter's first row and before its
      // deep row: exactly the deep row is current.
      final harness = bridge(
        readingState: FlutterReadingState(
          unit: BigInt.zero,
          offset: BigInt.from(200),
          zoom: 1,
        ),
      );
      await openReader(tester, harness);
      await settleEpubPage(tester);
      await openContents(tester);

      bool selected(String key) =>
          tester
              .getSemantics(find.byKey(ValueKey(key)))
              .getSemanticsData()
              .flagsCollection
              .isSelected ==
          ui.Tristate.isTrue;
      expect(
        selected('reader-contents-entry-0'),
        isFalse,
        reason: 'the chapter-start row is behind the reader',
      );
      expect(
        selected('reader-contents-entry-0-2'),
        isTrue,
        reason: 'the deep row at or before the offset is current',
      );

      await tester.pumpWidget(const SizedBox());
      await drainHarness(tester);
    });

    testWidgets('a duplicate-offset chapter still has one current row', (
      tester,
    ) async {
      // Chapter three carries two rows with the same offset (20); the exact
      // boundary still marks exactly one of them, and the reveal key stays
      // unique.
      final harness = bridge(
        readingState: FlutterReadingState(
          unit: BigInt.from(2),
          offset: BigInt.from(20),
          zoom: 1,
        ),
      );
      await openReader(tester, harness);
      await settleEpubPage(tester);
      await openContents(tester);

      bool selected(String key) =>
          tester
              .getSemantics(find.byKey(ValueKey(key)))
              .getSemanticsData()
              .flagsCollection
              .isSelected ==
          ui.Tristate.isTrue;
      expect(selected('reader-contents-entry-2'), isFalse);
      expect(selected('reader-contents-entry-2-2'), isTrue);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox());
      await drainHarness(tester);
    });

    testWidgets('a chapter-level row returns to the chapter start', (
      tester,
    ) async {
      // Read into the chapter, then activate the same chapter's fragment-less
      // row: the reader must land on the chapter start, not keep the page it
      // left, and the durable position must agree with what is displayed.
      final harness = bridge();
      await openReader(tester, harness);
      await settleEpubPage(tester);
      await tester.tap(find.byKey(const ValueKey('reader-edge-next')));
      await settleEpubPage(tester);
      final later = dartPage(tester)!;
      expect(
        later.page.canonicalStart,
        greaterThan(0),
        reason: 'the fixture chapter spans several pages',
      );

      await openContents(tester);
      await tester.tap(find.byKey(const ValueKey('reader-contents-entry-0')));
      await settleNative(tester);
      // The compact reader hides the document behind the open panel, so the
      // page is inspected after closing it.
      await tester.tap(find.byKey(const ValueKey('reader-header-contents')));
      await settleEpubPage(tester);

      final after = dartPage(tester);
      expect(
        after,
        isNotNull,
        reason: 'the chapter stays on the Dart renderer',
      );
      expect(
        after!.page.canonicalStart,
        0,
        reason: 'a chapter-level row returns to the chapter start',
      );
      expect(
        harness.savedReadingStates.last.offset,
        isNull,
        reason: 'the chapter-level row stores no offset it does not have',
      );
      expect(harness.savedReadingStates.last.unit.toInt(), 0);

      await tester.pumpWidget(const SizedBox());
      await drainHarness(tester);
    });

    testWidgets('a refused cancellation fails the load without leaking', (
      tester,
    ) async {
      // The open's own load and the retry opening the panel starts.
      final harness = bridge()..contentsCancellationFailures = 2;
      await openReader(tester, harness);
      await settleEpubPage(tester);
      await openContents(tester);

      expect(
        find.byKey(const ValueKey('reader-contents-error')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('reader-contents-retry')),
        findsOneWidget,
      );

      await tester.pumpWidget(const SizedBox());
      await drainHarness(tester);
    });

    testWidgets('a completed load releases its cancellation exactly once', (
      tester,
    ) async {
      final harness = bridge();
      await openReader(tester, harness);
      await settleEpubPage(tester);
      await openContents(tester);
      expect(inContents('Chapter three deep'), findsOneWidget);

      final loadTokens = harness.contentsCancellations;
      expect(loadTokens, hasLength(1));
      for (final token in loadTokens) {
        expect(
          harness.releasedCancellations.where((id) => id == token),
          hasLength(1),
          reason: 'the load releases the token it created',
        );
      }

      await tester.pumpWidget(const SizedBox());
      await drainHarness(tester);
    });
  });

  group('painted links', () {
    testWidgets('a same-chapter fragment navigates to its anchor', (
      tester,
    ) async {
      final harness = bridge();
      await openReader(tester, harness);
      await settleEpubPage(tester);
      expect(dartPage(tester), isNotNull);

      await tapLink(tester, '#one-deep');
      await settleEpubPage(tester);

      final after = dartPage(tester);
      expect(after, isNotNull);
      expect(
        harness.savedReadingStates.last.unit.toInt(),
        0,
        reason: 'the fragment stays in the chapter',
      );
      final anchor = book.chapters[0].anchors['one-deep']!;
      expect(harness.savedReadingStates.last.offset?.toInt(), anchor);
      expect(
        after!.page.canonicalStart <= anchor &&
            anchor <= after.page.canonicalEnd,
        isTrue,
        reason: 'the installed page contains the anchor',
      );

      await tester.pumpWidget(const SizedBox());
      await drainHarness(tester);
    });

    testWidgets('a cross-chapter fragment navigates to the target chapter', (
      tester,
    ) async {
      final harness = bridge();
      await openReader(tester, harness);
      await settleEpubPage(tester);

      await tapLink(tester, 'chapter-2.xhtml#two-target');
      await settleEpubPage(tester);

      expect(harness.savedReadingStates.last.unit.toInt(), 1);
      expect(
        harness.savedReadingStates.last.offset?.toInt(),
        book.chapters[1].anchors['two-target'],
      );

      await tester.pumpWidget(const SizedBox());
      await drainHarness(tester);
    });

    testWidgets('an encoded link resolves like its decoded form', (
      tester,
    ) async {
      final harness = bridge();
      await openReader(tester, harness);
      await settleEpubPage(tester);

      await tapLink(tester, 'chapter%2D2.xhtml#two%20encoded');
      await settleEpubPage(tester);

      expect(harness.savedReadingStates.last.unit.toInt(), 1);
      expect(
        harness.savedReadingStates.last.offset?.toInt(),
        book.chapters[1].anchors['two encoded'],
      );

      await tester.pumpWidget(const SizedBox());
      await drainHarness(tester);
    });

    testWidgets('a fragment-less link opens the target chapter start', (
      tester,
    ) async {
      final harness = bridge();
      await openReader(tester, harness);
      await settleEpubPage(tester);

      await tapLink(tester, 'chapter-3.xhtml');
      await settleEpubPage(tester);

      expect(harness.savedReadingStates.last.unit.toInt(), 2);
      expect(harness.savedReadingStates.last.offset?.toInt(), 0);
      expect(
        find.text('Back to Chapter one'),
        findsOneWidget,
        reason: 'a followed link is a jump Back returns from',
      );

      await tester.pumpWidget(const SizedBox());
      await drainHarness(tester);
    });

    testWidgets('an unresolvable anchor navigates nowhere', (tester) async {
      final harness = bridge();
      await openReader(tester, harness);
      await settleEpubPage(tester);
      final saved = harness.savedReadingStates.length;

      await tapLink(tester, '#nope');
      await settleNative(tester);

      expect(
        harness.savedReadingStates,
        hasLength(saved),
        reason: 'an unknown anchor never fabricates a position',
      );
      expect(dartPage(tester), isNotNull, reason: 'the page stays installed');

      await tester.pumpWidget(const SizedBox());
      await drainHarness(tester);
    });

    testWidgets('a drag over a link selects instead of navigating', (
      tester,
    ) async {
      final harness = bridge();
      await openReader(tester, harness);
      await settleEpubPage(tester);
      final saved = harness.savedReadingStates.length;
      final point = linkTapPoint(tester, 'chapter-2.xhtml#two-target');
      expect(point, isNotNull);

      // A press that travels past the tap slop is a selection gesture.
      final gesture = await tester.startGesture(
        point!,
        kind: ui.PointerDeviceKind.mouse,
      );
      await tester.pump();
      await gesture.moveTo(point + const Offset(40, 0));
      await tester.pump();
      await gesture.up();
      await settleNative(tester);

      expect(
        harness.savedReadingStates,
        hasLength(saved),
        reason: 'a drag does not activate the link',
      );
      expect(find.byKey(const ValueKey('selection-actions')), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await drainHarness(tester);
    });

    testWidgets('a press that returns to its origin does not activate', (
      tester,
    ) async {
      final harness = bridge();
      await openReader(tester, harness);
      await settleEpubPage(tester);
      final saved = harness.savedReadingStates.length;
      final point = linkTapPoint(tester, 'chapter-2.xhtml#two-target');
      expect(point, isNotNull);

      // The press travels past the tap slop and comes back: it is a drag, not
      // a tap, so the link must not activate even though it ends on the glyph.
      final gesture = await tester.startGesture(
        point!,
        kind: ui.PointerDeviceKind.mouse,
      );
      await tester.pump();
      await gesture.moveTo(point + const Offset(40, 0));
      await tester.pump();
      await gesture.moveTo(point);
      await tester.pump();
      await gesture.up();
      await settleNative(tester);

      expect(
        harness.savedReadingStates,
        hasLength(saved),
        reason: 'a returning press never activates the link',
      );

      await tester.pumpWidget(const SizedBox());
      await drainHarness(tester);
    });

    testWidgets('a primary mouse click activates a link', (tester) async {
      final harness = bridge();
      await openReader(tester, harness);
      await settleEpubPage(tester);
      final point = linkTapPoint(tester, 'chapter-2.xhtml#two-target');
      expect(point, isNotNull);

      await tester.tapAt(point!, kind: ui.PointerDeviceKind.mouse);
      await settleEpubPage(tester);

      expect(harness.savedReadingStates.last.unit.toInt(), 1);
      expect(
        harness.savedReadingStates.last.offset?.toInt(),
        book.chapters[1].anchors['two-target'],
      );

      await tester.pumpWidget(const SizedBox());
      await drainHarness(tester);
    });

    testWidgets('a touch long-press on a link selects, never navigates', (
      tester,
    ) async {
      final harness = bridge();
      await openReader(tester, harness);
      await settleEpubPage(tester);
      final saved = harness.savedReadingStates.length;
      final point = linkTapPoint(tester, 'chapter-2.xhtml#two-target');
      expect(point, isNotNull);

      final gesture = await tester.startGesture(
        point!,
        kind: ui.PointerDeviceKind.touch,
      );
      await tester.pump(const Duration(milliseconds: 700));
      await gesture.moveBy(const Offset(12, 0));
      await tester.pump();
      await gesture.up();
      await settleNative(tester);

      expect(
        harness.savedReadingStates,
        hasLength(saved),
        reason: 'a long press is a selection gesture, not a link tap',
      );
      expect(find.byKey(const ValueKey('selection-actions')), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await drainHarness(tester);
    });

    testWidgets('an opener failure is not a reader error', (tester) async {
      final harness = bridge();
      await tester.pumpWidget(
        productionShell(
          home: ReaderScreen(
            bridge: harness,
            initialPath: '/books/navigation.epub',
            initialBookId: 1,
            epubImageDecoder: (bytes) async => null,
            externalLinkOpener: (_) async => throw StateError('no handler'),
          ),
        ),
      );
      await settleEpubPage(tester);
      final saved = harness.savedReadingStates.length;

      await tapLink(tester, 'https://example.invalid/book');
      await settleNative(tester);

      expect(tester.takeException(), isNull);
      expect(harness.savedReadingStates, hasLength(saved));

      await tester.pumpWidget(const SizedBox());
      await drainHarness(tester);
    });

    testWidgets('a non-EPUB page never activates a link', (tester) async {
      final opened = <String>[];
      final harness = bridge();
      await renderHarnessState(
        tester,
        productionShell(
          home: ReaderScreen(
            bridge: harness,
            initialPath: '/books/replacement.pdf',
            externalLinkOpener: (url) async => opened.add(url),
          ),
        ),
        ready: () => harnessReaderPageReady(tester),
        maxRounds: 16,
      );
      await settleNative(tester);
      expect(harnessReaderPageReady(tester), isTrue);
      final saved = harness.savedReadingStates.length;

      await tester.tapAt(
        tester.getCenter(find.byKey(const ValueKey('reader-page-paint'))),
      );
      await settleNative(tester);

      expect(opened, isEmpty);
      expect(harness.savedReadingStates, hasLength(saved));

      await tester.pumpWidget(const SizedBox());
      await drainHarness(tester);
    });

    testWidgets('allowed external links go to the opener and never navigate', (
      tester,
    ) async {
      final opened = <String>[];
      final harness = bridge();
      await openReader(tester, harness, openedLinks: opened);
      await settleEpubPage(tester);
      final saved = harness.savedReadingStates.length;

      for (final href in [
        'https://example.invalid/book',
        'http://example.invalid/book',
        'mailto:reader@example.invalid',
      ]) {
        await tapLink(tester, href);
      }

      expect(opened, [
        'https://example.invalid/book',
        'http://example.invalid/book',
        'mailto:reader@example.invalid',
      ]);
      expect(
        harness.savedReadingStates,
        hasLength(saved),
        reason: 'an external link never moves the reader',
      );

      await tester.pumpWidget(const SizedBox());
      await drainHarness(tester);
    });

    testWidgets('refused schemes never reach the opener', (tester) async {
      final opened = <String>[];
      final harness = bridge();
      await openReader(tester, harness, openedLinks: opened);
      await settleEpubPage(tester);
      final saved = harness.savedReadingStates.length;

      for (final href in [
        'file:///etc/passwd',
        'data:text/plain,x',
        'javascript:alert(1)',
        'custom:blocked',
      ]) {
        await tapLink(tester, href);
      }

      expect(opened, isEmpty);
      expect(harness.savedReadingStates, hasLength(saved));

      await tester.pumpWidget(const SizedBox());
      await drainHarness(tester);
    });

    testWidgets('a navigation keeps the selection lifecycle working', (
      tester,
    ) async {
      final harness = bridge();
      await openReader(tester, harness);
      await settleEpubPage(tester);

      await tapLink(tester, 'chapter-2.xhtml#two-target');
      await settleEpubPage(tester);
      expect(find.byKey(const ValueKey('selection-actions')), findsNothing);

      // A drag on the newly installed page still selects through the same
      // surface the navigation replaced.
      final painter = dartPage(tester)!;
      final surface = painter.page.surface;
      expect(surface.endpoints, isNotEmpty);
      final first = surface.endpoints.first;
      final last = surface.endpoints.last;
      final paintBox = tester.renderObject<RenderBox>(
        find.byKey(const ValueKey('reader-page-paint')),
      );
      Offset global(Offset point) {
        final transform = SurfaceTransform.create(
          BoxFit.contain,
          painter.page.box.size,
          paintBox.size,
        );
        return paintBox.localToGlobal(
          transform
              .toDestinationRect(Rect.fromLTWH(point.dx, point.dy, 0, 0))
              .topLeft,
        );
      }

      await dragReaderSelectionBetween(
        tester,
        global(
          Offset(
            (first.rect.left + first.rect.right) / 2,
            (first.rect.top + first.rect.bottom) / 2,
          ),
        ),
        global(
          Offset(
            (last.rect.left + last.rect.right) / 2,
            (last.rect.top + last.rect.bottom) / 2,
          ),
        ),
      );
      await settleReaderSelection(tester);
      expect(find.byKey(const ValueKey('selection-actions')), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await drainHarness(tester);
    });
  });

  group('link classification', () {
    test(
      'a scheme-less reference is internal and allowed schemes are exact',
      () {
        expect(classifyEpubLink('#note'), EpubLinkKind.internal);
        expect(classifyEpubLink('chapter.xhtml#note'), EpubLinkKind.internal);
        expect(classifyEpubLink('Text/foo:bar.xhtml'), EpubLinkKind.internal);
        expect(classifyEpubLink('../chapter.xhtml'), EpubLinkKind.internal);
        expect(
          classifyEpubLink('https://example.invalid'),
          EpubLinkKind.external,
        );
        expect(
          classifyEpubLink('HTTP://example.invalid'),
          EpubLinkKind.external,
        );
        expect(
          classifyEpubLink('mailto:reader@example.invalid'),
          EpubLinkKind.external,
        );
        for (final href in [
          'file:///etc/passwd',
          'data:text/plain,x',
          'javascript:alert(1)',
          'ftp://example.invalid/book',
          'custom:blocked',
        ]) {
          expect(
            classifyEpubLink(href),
            EpubLinkKind.unsupported,
            reason: '$href must never be launched or fetched',
          );
        }
        // Text before the colon that is not a valid scheme is a path character
        // to the retained classifier; reference resolution then refuses it, so
        // it is never launched either.
        expect(classifyEpubLink('1abc:blocked'), EpubLinkKind.internal);
        expect(
          resolveBookLink(
            book: book,
            fromResource: 'OPS/Text/chapter-1.xhtml',
            href: '1abc:blocked',
          ),
          isNull,
        );
        // A protocol-relative reference has no scheme and is classified internal
        // like the retained classifier; resolution then refuses its foreign
        // origin, so it is never fetched either.
        expect(
          classifyEpubLink('//example.invalid/book'),
          EpubLinkKind.internal,
        );
        expect(
          resolveBookLink(
            book: book,
            fromResource: 'OPS/Text/chapter-1.xhtml',
            href: '//example.invalid/book',
          ),
          isNull,
        );
      },
    );
  });
}
