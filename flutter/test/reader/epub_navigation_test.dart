import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_epub/shosai_epub.dart';
import 'package:shosai_flutter/reader/controller.dart';
import 'package:shosai_flutter/reader/epub/content.dart';
import 'package:shosai_flutter/reader/epub/font_coverage.dart';
import 'package:shosai_flutter/reader/epub/surface.dart';
import 'package:shosai_flutter/reader/view.dart';
import 'package:shosai_flutter/src/rust/api.dart';
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

  /// How many `createCancellation` calls fail before succeeding again.
  int createCancellationFailures = 0;

  @override
  BigInt createCancellation() {
    if (createCancellationFailures > 0) {
      createCancellationFailures -= 1;
      throw const FlutterBridgeError(
        kind: FlutterBridgeErrorKind.invalidRequest,
        message: 'the harness refuses a cancellation',
      );
    }
    final id = super.createCancellation();
    createdCancellations.add(id);
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

  @override
  Future<FlutterReadingState?> loadReadingState({
    required int bookId,
    required BigInt cancellationId,
  }) async => readingState;
}

void main() {
  final bytes = navigationEpub();
  final book = openEpubBytes(bytes);

  // The routing gate asks the reader for the bundled faces' coverage; these
  // tests answer with the shipped faces' own cmap tables, so the decision under
  // test is the production one.
  final coverage = EpubFontCoverage.fromFonts([
    _repoFile('assets/fonts/InterVariable.ttf'),
    _repoFile('assets/fonts/NotoSansJP-Variable.ttf'),
  ])!;

  /// The harness bridge serving the navigation fixture.
  ///
  /// A second library book exists so a replacement document can be opened as a
  /// library book: its durable writes are recorded, which is what proves a
  /// stale navigation did not move it.
  _NavigationBridge bridge({
    Map<int, String>? canonicalTexts,
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
    harness.canonicalTexts =
        canonicalTexts ??
        {
          for (var unit = 0; unit < book.chapters.length; unit += 1)
            unit: book.chapters[unit].canonicalText,
        };
    return harness;
  }

  Future<void> openReader(
    WidgetTester tester,
    HarnessBridge harness, {
    List<String>? openedLinks,
    ReaderPickedDocument? picked,
  }) async {
    await renderHarnessState(
      tester,
      productionShell(
        home: ReaderScreen(
          bridge: harness,
          initialPath: '/books/navigation.epub',
          initialBookId: 1,
          fontCoverageLoader: () async => coverage,
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
      for (final placed in placedPageText(slice, page.box)) {
        for (final link in placed.block.links) {
          if (link.href != href) continue;
          final boxes = placed.block.painter.getBoxesForSelection(
            TextSelection(baseOffset: link.start, extentOffset: link.end),
          );
          if (boxes.isEmpty) continue;
          final rect = boxes.first.toRect().shift(placed.origin);
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

      expect(find.text('Chapter one'), findsOneWidget);
      expect(find.text('Chapter two target'), findsOneWidget);
      expect(find.text('Chapter three deep'), findsOneWidget);
      expect(find.text('Encoded path'), findsOneWidget);
      // The title-only part heading resolves to no location and is not shown;
      // its child keeps the authored depth of one.
      expect(find.text(navigationFixturePartTitle), findsNothing);
      expect(find.text(navigationFixtureMissingTitle), findsNothing);
      final nested = tester.getRect(
        find.byKey(const ValueKey('reader-contents-entry-0')),
      );
      final top = tester.getRect(
        find.byKey(const ValueKey('reader-contents-entry-2')),
      );
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

    testWidgets('an unverified anchor keeps the title and the chapter target', (
      tester,
    ) async {
      // The retained stream for unit 2 differs: the chapter is not servable by
      // the engine, so its fragment offset must not be navigated.
      final harness = bridge(
        canonicalTexts: {
          for (var unit = 0; unit < book.chapters.length; unit += 1)
            unit: unit == 2
                ? '${book.chapters[unit].canonicalText} diverged'
                : book.chapters[unit].canonicalText,
        },
      );
      await openReader(tester, harness);
      await settleEpubPage(tester);
      await openContents(tester);

      expect(find.text('Chapter three deep'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('reader-contents-entry-2')));
      await settleNative(tester);

      expect(harness.savedReadingStates.last.unit.toInt(), 2);
      expect(
        harness.savedReadingStates.last.offset,
        isNull,
        reason:
            'an unverified anchor keeps the chapter target and stores no '
            'offset it cannot verify',
      );

      await tester.pumpWidget(const SizedBox());
      await drainHarness(tester);
    });

    testWidgets('a structurally shifted source falls back to chapters', (
      tester,
    ) async {
      // The bridge reports one logical unit more than the engine's chapter
      // list, so the engine's spine ordinals are not the retained units.
      final harness = bridge(unitCount: 4);
      await openReader(tester, harness);
      await settleEpubPage(tester);
      await openContents(tester);

      expect(find.text('Chapter one'), findsNothing);
      expect(find.text('Chapter three deep'), findsNothing);
      // The fallback rows are the retained units, with the localized chapter
      // number and no invented title.
      expect(find.text('Chapter 4'), findsOneWidget);
      expect(find.text('Chapter 1'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await drainHarness(tester);
    });

    testWidgets('a source the engine cannot parse falls back to chapters', (
      tester,
    ) async {
      final harness = bridge();
      harness.epubBytes = Uint8List(0);
      await openReader(tester, harness);
      await settleEpubPage(tester);
      await openContents(tester);

      expect(find.text('Chapter 1'), findsOneWidget);
      expect(find.text('Chapter one'), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await drainHarness(tester);
    });

    testWidgets('a superseded Contents request keeps the shared source load', (
      tester,
    ) async {
      final harness = bridge();
      // The first open refuses the archive, so the reader holds no source yet.
      harness.epubBytes = Uint8List(0);
      await openReader(tester, harness);
      await settleEpubPage(tester);

      // The next read is held, then the panel is closed and reopened: the
      // superseded request must not cancel the load the new one shares.
      harness.epubBytes = bytes;
      final held = Completer<Uint8List>();
      harness.epubSourceCompleters.add(held);
      await openContents(tester);
      expect(harness.epubSourceCompleters, isEmpty, reason: 'the read is held');

      await tester.tap(find.byKey(const ValueKey('reader-header-contents')));
      await tester.pump();
      await settleNative(tester);
      await openContents(tester);

      final sourceToken = harness.epubSourceCancellations.last;
      held.complete(bytes);
      await settleNative(tester, rounds: 8);

      expect(
        harness.cancelledCancellations,
        isNot(contains(sourceToken)),
        reason: 'a superseded panel request does not cancel the shared load',
      );
      expect(find.text('Chapter three deep'), findsOneWidget);
      expect(find.text('Chapter 1'), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await drainHarness(tester);
    });

    testWidgets('disposal cancels the shared source read it inherited', (
      tester,
    ) async {
      final harness = bridge();
      harness.epubBytes = Uint8List(0);
      await openReader(tester, harness);
      await settleEpubPage(tester);

      harness.epubBytes = bytes;
      final held = Completer<Uint8List>();
      harness.epubSourceCompleters.add(held);
      await openContents(tester);
      final sourceToken = harness.epubSourceCancellations.last;

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

    testWidgets('a stale load cannot publish entries for a newer document', (
      tester,
    ) async {
      final harness = bridge();
      await openReader(
        tester,
        harness,
        // The replacement is a raster document, so its Contents panel is the
        // chapter fallback and a stale EPUB TOC cannot be mistaken for it.
        picked: const ReaderPickedDocument('/books/other.pdf'),
      );
      await settleEpubPage(tester);
      // The open compared the current chapter; the panel's comparisons are
      // held from here on.
      final compared = harness.epubCanonicalCalls;
      final held = Completer<String>();
      harness.epubCanonicalCompleters.add(held);
      await openContents(tester);
      expect(
        harness.epubCanonicalCalls,
        compared + 1,
        reason: 'the first panel comparison is held',
      );

      // A new open through the rendered more panel replaces the generation
      // while the comparison is still pending.
      await tester.tap(find.byKey(const ValueKey('reader-header-more')));
      await settleNative(tester);
      await tester.tap(find.byKey(const ValueKey('reader-more-open-book')));
      await settleNative(tester);

      // The stale comparison must not publish entries for the new document.
      held.complete('other stream');
      await settleNative(tester);
      await openContents(tester);
      expect(find.text('Chapter one'), findsNothing);
      expect(find.text('Chapter 2'), findsOneWidget);

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

    testWidgets('a failed comparison keeps the title without an offset', (
      tester,
    ) async {
      final harness = bridge();
      await openReader(tester, harness);
      await settleEpubPage(tester);
      // The panel's first comparison fails: the chapter cannot be qualified.
      // The open already verified the current chapter, so the held comparison
      // is chapter two's.
      final failing = Completer<String>();
      harness.epubCanonicalCompleters.add(failing);
      await openContents(tester);
      failing.completeError(
        const FlutterBridgeError(
          kind: FlutterBridgeErrorKind.invalidRequest,
          message: 'the harness cannot compare',
        ),
      );
      await settleNative(tester);

      expect(find.text('Chapter two target'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('reader-contents-entry-1')));
      await settleNative(tester);

      expect(harness.savedReadingStates.last.unit.toInt(), 1);
      expect(
        harness.savedReadingStates.last.offset,
        isNull,
        reason: 'an uncomparable anchor stores no offset',
      );

      await tester.pumpWidget(const SizedBox());
      await drainHarness(tester);
    });

    testWidgets('a refused cancellation fails the load without leaking', (
      tester,
    ) async {
      final harness = bridge();
      await openReader(tester, harness);
      await settleEpubPage(tester);
      harness.createCancellationFailures = 1;
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
      final created = harness.createdCancellations.length;
      await openContents(tester);
      expect(find.text('Chapter three deep'), findsOneWidget);

      final loadTokens = harness.createdCancellations.sublist(created);
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

    testWidgets('an unverified chapter keeps the link at the chapter level', (
      tester,
    ) async {
      final harness = bridge(
        canonicalTexts: {
          for (var unit = 0; unit < book.chapters.length; unit += 1)
            unit: unit == 1
                ? '${book.chapters[unit].canonicalText} diverged'
                : book.chapters[unit].canonicalText,
        },
      );
      await openReader(tester, harness);
      await settleEpubPage(tester);

      await tapLink(tester, 'chapter-2.xhtml#two-target');
      await settleEpubPage(tester);

      expect(harness.savedReadingStates.last.unit.toInt(), 1);
      expect(
        harness.savedReadingStates.last.offset,
        isNull,
        reason: 'the unverified anchor stores no offset it cannot verify',
      );

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
            fontCoverageLoader: () async => coverage,
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
            fontCoverageLoader: () async => coverage,
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

    testWidgets('a newer link supersedes a pending one', (tester) async {
      final harness = bridge();
      await openReader(tester, harness);
      await settleEpubPage(tester);

      // Hold the cross-chapter target's comparison, then navigate with a
      // cached same-chapter link whose layout completes first.
      final held = Completer<String>();
      harness.epubCanonicalCompleters.add(held);
      await tapLink(tester, 'chapter-2.xhtml#two-target');
      expect(
        harness.savedReadingStates.last.unit.toInt(),
        0,
        reason: 'the held comparison has not navigated yet',
      );

      await tapLink(tester, '#one-deep');
      expect(harness.savedReadingStates.last.unit.toInt(), 0);
      expect(
        harness.savedReadingStates.last.offset?.toInt(),
        book.chapters[0].anchors['one-deep'],
        reason: 'the newer same-chapter link won',
      );
      final saved = harness.savedReadingStates.length;

      // The superseded completion must not move the reader back to chapter 2.
      held.complete(book.chapters[1].canonicalText);
      await settleNative(tester);

      expect(
        harness.savedReadingStates,
        hasLength(saved),
        reason: 'a superseded link completion never navigates',
      );
      expect(
        harness.savedReadingStates.last.offset?.toInt(),
        book.chapters[0].anchors['one-deep'],
      );

      await tester.pumpWidget(const SizedBox());
      await drainHarness(tester);
    });

    testWidgets('a completed link releases its cancellation exactly once', (
      tester,
    ) async {
      final harness = bridge();
      await openReader(tester, harness);
      await settleEpubPage(tester);
      final created = harness.createdCancellations.length;

      await tapLink(tester, 'chapter-2.xhtml#two-target');
      await settleEpubPage(tester);

      // The activation creates the link's comparison token and the relayout
      // token its navigation starts; both are released exactly once.
      final linkTokens = harness.createdCancellations.sublist(created);
      expect(linkTokens, isNotEmpty);
      for (final token in linkTokens) {
        expect(
          harness.releasedCancellations.where((id) => id == token),
          hasLength(1),
          reason: 'the link flow releases every token it created',
        );
      }

      await tester.pumpWidget(const SizedBox());
      await drainHarness(tester);
    });

    testWidgets('a suspension drops a pending link comparison', (tester) async {
      final harness = bridge();
      await openReader(tester, harness);
      await settleEpubPage(tester);
      final held = Completer<String>();
      harness.epubCanonicalCompleters.add(held);
      final created = harness.createdCancellations.length;
      await tapLink(tester, 'chapter-2.xhtml#two-target');
      final token = harness.createdCancellations.sublist(created).single;
      final saved = harness.savedReadingStates.length;

      // Suspension cancels the pending comparison; completing it afterwards
      // must not navigate.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      addTearDown(
        () => tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        ),
      );
      await settleNative(tester);
      held.complete(book.chapters[1].canonicalText);
      await settleNative(tester);

      expect(tester.takeException(), isNull);
      expect(harness.savedReadingStates, hasLength(saved));
      expect(harness.cancelledCancellations, contains(token));

      await tester.pumpWidget(const SizedBox());
      await drainHarness(tester);
    });

    testWidgets('a page turn supersedes a pending link', (tester) async {
      final harness = bridge();
      await openReader(tester, harness);
      await settleEpubPage(tester);

      final held = Completer<String>();
      harness.epubCanonicalCompleters.add(held);
      await tapLink(tester, 'chapter-2.xhtml#two-target');

      await tester.tap(find.byKey(const ValueKey('reader-edge-next')));
      await settleEpubPage(tester);
      final turned = harness.savedReadingStates.last.offset?.toInt();
      expect(turned, isNotNull, reason: 'the page turn moved the reader');
      final saved = harness.savedReadingStates.length;

      held.complete(book.chapters[1].canonicalText);
      await settleNative(tester);

      expect(
        harness.savedReadingStates,
        hasLength(saved),
        reason: 'the superseded link never navigates after a page turn',
      );

      await tester.pumpWidget(const SizedBox());
      await drainHarness(tester);
    });

    testWidgets('a stale link completion cannot navigate a newer document', (
      tester,
    ) async {
      final harness = bridge();
      await openReader(
        tester,
        harness,
        picked: const ReaderPickedDocument('/books/replacement.pdf', bookId: 2),
      );
      await settleEpubPage(tester);
      // The open compared the current chapter; the next comparison is the
      // clicked cross-chapter target's and is held here.
      final held = Completer<String>();
      harness.epubCanonicalCompleters.add(held);
      await tapLink(tester, 'chapter-2.xhtml#two-target');

      await tester.tap(find.byKey(const ValueKey('reader-header-more')));
      await settleNative(tester);
      await tester.tap(find.byKey(const ValueKey('reader-more-open-book')));
      await settleNative(tester);
      // The replacement is a library book, so its durable writes are recorded.
      final saved = harness.savedReadingStates.length;
      expect(
        harness.savedReadingStates.last.unit.toInt(),
        0,
        reason: 'the replacement opened at its own start',
      );

      held.complete(book.chapters[1].canonicalText);
      await settleNative(tester);

      expect(
        harness.savedReadingStates,
        hasLength(saved),
        reason: 'the superseded link never navigates the replacement',
      );
      expect(harness.savedReadingStates.last.unit.toInt(), 0);

      await tester.pumpWidget(const SizedBox());
      await drainHarness(tester);
    });

    testWidgets('a link completion after disposal is dropped', (tester) async {
      final harness = bridge();
      await openReader(tester, harness);
      await settleEpubPage(tester);
      final held = Completer<String>();
      harness.epubCanonicalCompleters.add(held);
      final created = harness.createdCancellations.length;
      await tapLink(tester, 'chapter-2.xhtml#two-target');
      expect(harness.epubCanonicalCalls, greaterThan(0));
      expect(
        harness.createdCancellations.length,
        created + 1,
        reason: 'the pending link owns one cancellation',
      );

      await tester.pumpWidget(const SizedBox());
      await drainHarness(tester);
      held.complete(book.chapters[1].canonicalText);
      await drainHarness(tester);

      expect(tester.takeException(), isNull);
      expect(harness.isDisposed, isTrue);
      // Disposal cancels the pending link and releases its token exactly once.
      final pending = harness.createdCancellations.sublist(created);
      expect(pending, hasLength(1));
      expect(harness.cancelledCancellations, contains(pending.single));
      expect(
        harness.releasedCancellations.where((id) => id == pending.single),
        hasLength(1),
      );
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

/// The bytes of one repository file.
Uint8List _repoFile(String path) =>
    Uint8List.fromList(File('../$path').readAsBytesSync());
