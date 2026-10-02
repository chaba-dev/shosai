import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shosai_epub/shosai_epub.dart';
import 'package:shosai_flutter/reader/epub/flow.dart';
import 'package:shosai_flutter/reader/epub/font_coverage.dart';
import 'package:shosai_flutter/reader/view.dart';
import 'package:shosai_flutter/src/rust/api.dart';

import '../support/epub_navigation_fixture.dart';
import '../support/production_shell_harness.dart';
import '../support/selection_surface_fixture.dart';

/// Slice 3 routing tests: the production reader serves a paginated EPUB chapter
/// from the Dart engine behind the retained UI.
///
/// The bytes are real fixture archives, parsed by the real engine; the bridge
/// is the deterministic harness, so the *routing decision* (and its fallback)
/// is what these tests isolate. The native parity suite covers the same reader
/// with the real Rust bridge.
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

void main() {
  final conformance = _fixture('epub-conformance/conformance.epub');
  final book = openEpubBytes(conformance);

  // The routing gate asks the reader for the bundled faces' coverage; these
  // tests answer with the shipped faces' own cmap tables, so the decision under
  // test is the production one.
  final coverage = EpubFontCoverage.fromFonts([
    _repoFile('assets/fonts/InterVariable.ttf'),
    _repoFile('assets/fonts/NotoSansJP-Variable.ttf'),
  ])!;

  HarnessBridge bridge({
    Uint8List? bytes,
    Map<int, String>? canonicalTexts,
    int unitCount = 8,
    List<FlutterLibraryBook>? books,
  }) {
    final harness = HarnessBridge(books: books, unitCount: unitCount);
    harness.epubBytes = bytes ?? conformance;
    harness.canonicalTexts =
        canonicalTexts ??
        {
          for (var unit = 0; unit < unitCount; unit += 1)
            unit: book.chapters[unit].canonicalText,
        };
    return harness;
  }

  Future<void> openReader(WidgetTester tester, HarnessBridge harness) async {
    await renderHarnessState(
      tester,
      productionShell(
        home: ReaderScreen(
          bridge: harness,
          initialPath: '/books/conformance.epub',
          fontCoverageLoader: () async => coverage,
          epubImageDecoder: (bytes) async => null,
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

  PagePainter? retainedPage(WidgetTester tester) {
    for (final paint in tester.widgetList<CustomPaint>(
      find.byType(CustomPaint),
    )) {
      final painter = paint.painter;
      if (painter is PagePainter && painter.image != null) return painter;
    }
    return null;
  }

  testWidgets('a routed chapter renders the Dart page window', (tester) async {
    final harness = bridge();
    await openReader(tester, harness);

    final page = dartPage(tester);
    expect(page, isNotNull, reason: 'the chapter is served by the Dart engine');
    expect(
      retainedPage(tester),
      isNull,
      reason: 'a routed chapter does not paint the retained raster',
    );
    // The surface carries the chapter's canonical stream, so copy, highlights
    // and durable offsets stay in the stream the store already uses.
    expect(page!.page.surface.text, book.chapters[0].canonicalText);
    expect(page.page.surface.copyEligible, isTrue);
    expect(page.page.unit, 0);
    expect(page.page.canGoForward, isTrue);
    expect(page.page.canGoBackward, isFalse);
    // The page is the whole window: the surface is not scaled by the fit.
    expect(page.page.box.size.width, greaterThan(0));
    expect(page.page.box.size.height, greaterThan(0));
    // The gate compared the engine stream with the retained one before routing.
    expect(harness.epubCanonicalCalls, greaterThan(0));
    expect(harness.epubSourceCalls, 1);

    await tester.pumpWidget(const SizedBox());
    await _drainHarness(tester);
  });

  testWidgets('a diverging canonical stream keeps the retained renderer', (
    tester,
  ) async {
    final harness = bridge(canonicalTexts: {0: 'a different canonical stream'});
    await openReader(tester, harness);

    expect(
      dartPage(tester),
      isNull,
      reason: 'a chapter whose stream diverges is never routed',
    );
    expect(retainedPage(tester), isNotNull);
    expect(harness.epubCanonicalCalls, greaterThan(0));

    await tester.pumpWidget(const SizedBox());
    await _drainHarness(tester);
  });

  testWidgets('an unavailable retained stream keeps the retained renderer', (
    tester,
  ) async {
    // No canonical text for the unit: the comparison cannot be made, so the
    // chapter must not be routed (the retained ceiling case).
    final harness = bridge(canonicalTexts: const {});
    await openReader(tester, harness);

    expect(dartPage(tester), isNull);
    expect(retainedPage(tester), isNotNull);

    await tester.pumpWidget(const SizedBox());
    await _drainHarness(tester);
  });

  test('the admission fixture differs only in span depth', () {
    // The routing gate compares canonical text, and the fixture's span
    // nesting carries no text, so the engine's own stream for a shallow
    // variant is a valid retained stream for the over-deep book: nesting
    // depth is the only difference between the control and the fallback.
    final shallowBytes = admissionEpub(spanNesting: 2);
    final shallowBook = openEpubBytes(shallowBytes);
    expect(
      () => openEpubBytes(admissionEpub(spanNesting: 65)),
      throwsA(isA<EpubLimitError>()),
    );
    expect(
      openEpubBytes(
        admissionEpub(spanNesting: 40),
      ).chapters.single.canonicalText,
      shallowBook.chapters.single.canonicalText,
      reason: 'span nesting does not change the canonical stream',
    );
  });

  testWidgets(
    'a chapter past the cell-walk admission ceiling keeps the retained renderer',
    (tester) async {
      // The shallow control routes; the over-deep book — identical but for
      // the span depth — is refused at admission and stays on the retained
      // renderer, whose anchor walkers have no such ceiling.
      final shallowBook = openEpubBytes(admissionEpub(spanNesting: 2));

      final control = bridge(
        bytes: admissionEpub(spanNesting: 2),
        unitCount: 1,
        canonicalTexts: {0: shallowBook.chapters.single.canonicalText},
      );
      await openReader(tester, control);
      expect(
        dartPage(tester),
        isNotNull,
        reason: 'the identical book inside the ceiling routes to the engine',
      );
      await tester.pumpWidget(const SizedBox());
      await _drainHarness(tester);

      final fallback = bridge(
        bytes: admissionEpub(spanNesting: 65),
        unitCount: 1,
        canonicalTexts: {0: shallowBook.chapters.single.canonicalText},
      );
      await openReader(tester, fallback);
      expect(
        dartPage(tester),
        isNull,
        reason: 'an over-deep cell anchor walk is refused at admission',
      );
      expect(retainedPage(tester), isNotNull);

      await tester.pumpWidget(const SizedBox());
      await _drainHarness(tester);
    },
  );

  testWidgets('a refused chapter falls back and the next one routes again', (
    tester,
  ) async {
    // Chapter 2 diverges from the retained stream and must not be routed;
    // chapter 3 matches and must come back to the Dart renderer. The retained
    // surface the fallback installed is released when the Dart page replaces
    // it, and the reader owns nothing it was not given.
    final harness = bridge(
      canonicalTexts: {
        0: book.chapters[0].canonicalText,
        1: 'a different canonical stream',
        for (var unit = 2; unit < 8; unit += 1)
          unit: book.chapters[unit].canonicalText,
      },
    );
    await openReader(tester, harness);
    await settleEpubPage(tester);
    expect(dartPage(tester), isNotNull);

    // The more panel's page input navigates by unit, and it is enabled exactly
    // when the reader is idle: the open's progressive chapter measurement keeps
    // the reader busy after the first page is installed.
    Future<void> openMorePanel() async {
      if (find.byKey(const ValueKey('reader-page-input')).evaluate().isEmpty) {
        await tester.tap(find.byKey(const ValueKey('reader-header-more')));
        await pumpHarnessFrames(tester, frames: 4);
      }
    }

    Future<void> settleReader() async {
      for (var round = 0; round < 40; round += 1) {
        await openMorePanel();
        final input = find.byKey(const ValueKey('reader-page-input'));
        if (input.evaluate().isNotEmpty &&
            tester.widget<ShadInput>(input).enabled) {
          return;
        }
        await settleNative(tester, rounds: 1);
      }
      fail('the reader never became idle');
    }

    Future<void> jumpTo(int unit) async {
      await settleReader();
      await tester.enterText(
        find.byKey(const ValueKey('reader-page-input')),
        '$unit',
      );
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await pumpHarnessFrames(tester, frames: 8);
      await settleNative(tester);
    }

    final beforeFallback = harness.surfaceCalls;
    await jumpTo(2);
    expect(
      harness.epubCanonicalCalls,
      greaterThan(1),
      reason: 'the reader asked for the diverging chapter',
    );
    expect(
      dartPage(tester),
      isNull,
      reason: 'a diverging chapter stays on the retained renderer',
    );
    expect(retainedPage(tester), isNotNull);
    final retainedSurfaces = harness.surfaceCalls;
    expect(
      retainedSurfaces,
      greaterThan(beforeFallback),
      reason: 'the fallback laid out the retained surface',
    );

    await jumpTo(3);

    expect(
      dartPage(tester),
      isNotNull,
      reason: 'a matching chapter routes again after a fallback',
    );
    expect(
      harness.surfaceCalls,
      retainedSurfaces,
      reason: 'the routed chapter did not ask for a retained surface',
    );
    expect(
      harness.releasedSelections.map((handle) => handle.id),
      contains(BigInt.one),
      reason: 'the replaced retained surface was released',
    );
    expect(
      harness.releasedBuffers.toSet(),
      harness.takenBuffers.toSet(),
      reason: 'every buffer the reader took was released',
    );

    await tester.pumpWidget(const SizedBox());
    await _drainHarness(tester);
  });

  testWidgets('a chapter with one unbounded layout unit stays retained', (
    tester,
  ) async {
    // The windowed session measures in bounded batches between top-level
    // blocks, but one paragraph/list/table/container is measured in a single
    // call. A chapter whose single unit is enormous is refused here rather than
    // measured in one unbounded call; the retained renderer serves it.
    final huge = _repoFile(
      'prototypes/epub-dart-eval/fixtures/huge-paragraph.epub',
    );
    final hugeBook = openEpubBytes(huge);
    final harness = HarnessBridge(unitCount: hugeBook.chapters.length);
    harness.epubBytes = huge;
    harness.canonicalTexts = {
      for (var unit = 0; unit < hugeBook.chapters.length; unit += 1)
        unit: hugeBook.chapters[unit].canonicalText,
    };
    await renderHarnessState(
      tester,
      productionShell(
        home: ReaderScreen(
          bridge: harness,
          initialPath: '/books/huge-paragraph.epub',
          fontCoverageLoader: () async => coverage,
          epubImageDecoder: (bytes) async => null,
        ),
      ),
      ready: () => harnessReaderPageReady(tester),
      maxRounds: 16,
    );

    expect(
      dartPage(tester),
      isNull,
      reason: 'an indivisible unit past the bounded-work ceiling is not routed',
    );
    expect(retainedPage(tester), isNotNull);

    await tester.pumpWidget(const SizedBox());
    await _drainHarness(tester);
  });

  testWidgets('a superseding relayout keeps the painted session alive', (
    tester,
  ) async {
    // The relayout that installs a page owns its session until the page is
    // accepted. A second relayout that starts while the first is still waiting
    // must not dispose the session the model is still painting, and must
    // release its own replacement when a third supersedes it.
    final sessions = <ChapterLayoutSession>[];
    final harness = bridge();
    await renderHarnessState(
      tester,
      productionShell(
        home: ReaderScreen(
          bridge: harness,
          initialPath: '/books/conformance.epub',
          fontCoverageLoader: () async => coverage,
          epubImageDecoder: (bytes) async => null,
          debugEpubSessionObserver: sessions.add,
        ),
      ),
      ready: () => harnessReaderPageReady(tester),
      maxRounds: 16,
    );
    await settleEpubPage(tester);
    final painted = dartPage(tester);
    expect(painted, isNotNull);
    expect(sessions, isNotEmpty, reason: 'the open built its session');
    final openSession = sessions.last;
    expect(
      openSession.isDisposed,
      isFalse,
      reason: 'the painted session is live',
    );

    // Hold the second relayout between its session creation and its page
    // installation, then supersede it with a third.
    final held = Completer<List<FlutterAnnotation>>();
    harness.annotationListCompleters.add(held);
    tester.view.physicalSize = const Size(1400, 2200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await pumpHarnessFrames(tester, frames: 8);
    await settleNative(tester);
    expect(
      harness.annotationListCompleters,
      isEmpty,
      reason: 'the second relayout is held',
    );
    expect(sessions.length, greaterThanOrEqualTo(2));
    final heldSession = sessions.last;

    tester.view.physicalSize = const Size(1500, 2300);
    await pumpHarnessFrames(tester, frames: 8);
    await settleNative(tester);

    // The superseded relayout is still waiting for its annotations, so its
    // session is neither adopted nor released yet, and the page the model paints
    // is still alive.
    expect(tester.takeException(), isNull);
    expect(dartPage(tester), isNotNull);
    expect(
      heldSession.isDisposed,
      isFalse,
      reason: 'a pending replacement is not released under the painted page',
    );
    expect(
      openSession.isDisposed,
      isTrue,
      reason: 'the session whose page was replaced is retired',
    );

    // Releasing the held call resumes the superseded effect, which finds its
    // operation invalidated and releases the replacement it built.
    held.complete(const []);
    await pumpHarnessFrames(tester, frames: 8);
    await settleNative(tester);
    expect(
      heldSession.isDisposed,
      isTrue,
      reason: 'the losing replacement is released by its effect',
    );

    expect(tester.takeException(), isNull);
    final settled = dartPage(tester);
    expect(settled, isNotNull, reason: 'the superseding relayout installed');
    expect(
      settled!.page.box.size.height,
      isNot(painted!.page.box.size.height),
      reason: 'the installed page follows the last reported box',
    );
    final installedSession = sessions.last;
    expect(
      identical(installedSession, heldSession),
      isFalse,
      reason: 'the superseding relayout built its own session',
    );
    expect(installedSession.isDisposed, isFalse);
    expect(
      openSession.isDisposed,
      isTrue,
      reason: 'the replaced session is retired once its page leaves the screen',
    );

    await tester.pumpWidget(const SizedBox());
    await _drainHarness(tester);
  });

  testWidgets('the routing observer reports settled attempts and their width', (
    tester,
  ) async {
    // The observer is the test surface for *final* routing decisions: an
    // attempt held mid-routing is not reported until it settles, a
    // superseded attempt's stale outcome is never reported, and each record
    // carries the attempted page width so a wait can identify its viewport.
    final attempts =
        <({int generation, int revision, double width, bool routed})>[];
    final harness = bridge();
    await renderHarnessState(
      tester,
      productionShell(
        home: ReaderScreen(
          bridge: harness,
          initialPath: '/books/conformance.epub',
          fontCoverageLoader: () async => coverage,
          epubImageDecoder: (bytes) async => null,
          debugEpubRoutingObserver: (generation, revision, width, routed) =>
              attempts.add((
                generation: generation,
                revision: revision,
                width: width,
                routed: routed,
              )),
        ),
      ),
      ready: () => harnessReaderPageReady(tester),
      maxRounds: 16,
    );
    await settleEpubPage(tester);
    expect(dartPage(tester), isNotNull);
    expect(
      attempts.where((attempt) => attempt.routed),
      isNotEmpty,
      reason: 'the routed chapter is reported as a settled decision',
    );
    final baseline = attempts.length;
    final openWidth = attempts.last.width;

    // Hold the next relayout mid-routing (its annotations are pending, after
    // its gate evaluation) and supersede it with a wider relayout.
    final held = Completer<List<FlutterAnnotation>>();
    harness.annotationListCompleters.add(held);
    tester.view.physicalSize = const Size(1400, 2200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await pumpHarnessFrames(tester, frames: 8);
    await settleNative(tester);
    expect(
      harness.annotationListCompleters,
      isEmpty,
      reason: 'the held relayout is mid-routing',
    );
    expect(
      attempts.length,
      baseline,
      reason: 'a held attempt is not reported before it settles',
    );

    tester.view.physicalSize = const Size(1500, 2300);
    await pumpHarnessFrames(tester, frames: 8);
    await settleNative(tester);
    expect(dartPage(tester), isNotNull);
    expect(
      attempts.length,
      baseline + 1,
      reason: 'the superseding relayout is reported once settled',
    );
    expect(attempts.last.routed, isTrue);
    expect(
      attempts.last.width,
      greaterThan(openWidth),
      reason: 'the record carries the attempted page width',
    );

    // Resuming the superseded attempt must not add a record: its outcome is
    // stale work, not a decision.
    held.complete(const []);
    await pumpHarnessFrames(tester, frames: 8);
    await settleNative(tester);
    expect(
      attempts.length,
      baseline + 1,
      reason: 'the superseded attempt is not reported',
    );
    expect(attempts.map((attempt) => attempt.routed), everyElement(isTrue));

    await tester.pumpWidget(const SizedBox());
    await _drainHarness(tester);
  });

  testWidgets('a refused archive is retried by the next relayout', (
    tester,
  ) async {
    // The archive cannot be read at open time (an empty source), so the
    // chapter keeps the retained renderer. A later relayout must retry the
    // load instead of awaiting the settled refusal: the archive is readable by
    // then, and the chapter routes.
    final harness = bridge(bytes: Uint8List(0));
    await openReader(tester, harness);
    await settleEpubPage(tester);
    expect(dartPage(tester), isNull);
    expect(retainedPage(tester), isNotNull);
    final refused = harness.epubSourceCalls;

    harness.epubBytes = conformance;
    tester.view.physicalSize = const Size(1400, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await pumpHarnessFrames(tester, frames: 8);
    await settleNative(tester);

    expect(harness.epubSourceCalls, greaterThan(refused));
    expect(
      dartPage(tester),
      isNotNull,
      reason: 'the retried archive load routed the chapter',
    );

    await tester.pumpWidget(const SizedBox());
    await _drainHarness(tester);
  });

  testWidgets('a second reader reuses the bundled font coverage', (
    tester,
  ) async {
    // The bundled coverage is parsed once per process and the parsed value is
    // cached, not the future that produced it: a settled future belongs to the
    // zone that awaited it, so a later reader awaiting it would never see the
    // coverage and would keep every chapter on the retained renderer. The
    // cross-test case is covered by the native parity captures (a second
    // capture in the same process); this asserts the same process-level reuse
    // at the routing level, with the shipped faces.
    for (var reader = 0; reader < 2; reader += 1) {
      final harness = HarnessBridge(unitCount: 8);
      harness.epubBytes = conformance;
      harness.canonicalTexts = {
        for (var unit = 0; unit < 8; unit += 1)
          unit: book.chapters[unit].canonicalText,
      };
      await renderHarnessState(
        tester,
        productionShell(
          home: ReaderScreen(
            bridge: harness,
            initialPath: '/books/conformance.epub',
          ),
        ),
        ready: () => harnessReaderPageReady(tester),
        maxRounds: 16,
      );

      expect(
        dartPage(tester),
        isNotNull,
        reason:
            'reader ${reader + 1} routed the chapter with the bundled faces',
      );

      await tester.pumpWidget(const SizedBox());
      await _drainHarness(tester);
    }
  });

  testWidgets('a chapter outside the bundled font coverage stays retained', (
    tester,
  ) async {
    // bidi.epub's stream carries Hebrew, Arabic and an emoji: the Dart layout
    // has no bundled face for them, so the chapter keeps the retained renderer
    // (whose host font database draws them) until the font-coverage work lands.
    final bidi = _fixture('epub-conformance/bidi.epub');
    final bidiBook = openEpubBytes(bidi);
    expect(coverage.coversText(bidiBook.chapters.first.canonicalText), isFalse);
    final harness = HarnessBridge(unitCount: bidiBook.chapters.length);
    harness.epubBytes = bidi;
    harness.canonicalTexts = {
      for (var unit = 0; unit < bidiBook.chapters.length; unit += 1)
        unit: bidiBook.chapters[unit].canonicalText,
    };
    await renderHarnessState(
      tester,
      productionShell(
        home: ReaderScreen(bridge: harness, initialPath: '/books/bidi.epub'),
      ),
      ready: () => harnessReaderPageReady(tester),
      maxRounds: 16,
    );

    expect(dartPage(tester), isNull);
    expect(retainedPage(tester), isNotNull);

    await tester.pumpWidget(const SizedBox());
    await _drainHarness(tester);
  });

  testWidgets('a superseded comparison is retried, not remembered', (
    tester,
  ) async {
    final harness = bridge();
    final superseded = Completer<String>();
    harness.epubCanonicalCompleters.add(superseded);
    await tester.pumpWidget(
      productionShell(
        home: ReaderScreen(
          bridge: harness,
          initialPath: '/books/conformance.epub',
          fontCoverageLoader: () async => coverage,
          epubImageDecoder: (bytes) async => null,
        ),
      ),
    );
    // The open's comparison is pending. Supersede that layout with a resize;
    // its own comparison answers from the harness, so only the superseded call
    // is left holding a future.
    for (
      var round = 0;
      round < 16 && harness.epubCanonicalCalls < 1;
      round += 1
    ) {
      await pumpHarnessFrames(tester, frames: 4);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
    }
    expect(harness.epubCanonicalCalls, 1);
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (
      var round = 0;
      round < 16 && harness.epubCanonicalCalls < 2;
      round += 1
    ) {
      await pumpHarnessFrames(tester, frames: 4);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
    }
    expect(harness.epubCanonicalCalls, 2, reason: 'the successor compared too');
    // The superseded call now fails: it must not be remembered as a permanent
    // mismatch, because its successor already decided the chapter.
    superseded.completeError(StateError('superseded comparison'));
    await renderHarnessState(
      tester,
      productionShell(
        home: ReaderScreen(
          bridge: harness,
          initialPath: '/books/conformance.epub',
          fontCoverageLoader: () async => coverage,
          epubImageDecoder: (bytes) async => null,
        ),
      ),
      ready: () => harnessReaderPageReady(tester),
      maxRounds: 16,
    );
    await settleNative(tester);

    expect(
      dartPage(tester),
      isNotNull,
      reason: 'the retried comparison routes the chapter',
    );

    await tester.pumpWidget(const SizedBox());
    await _drainHarness(tester);
  });

  testWidgets('a page turn invalidates the selection it replaces', (
    tester,
  ) async {
    // The page a selection addresses leaves the screen on a turn: the selection
    // phase is invalidated with it, so nothing can submit a range the page no
    // longer shows. (The visible surface and the derived description are
    // replaced with the page anyway, which is why this asserts the outcome
    // rather than only the phase.)
    final semantics = tester.ensureSemantics();
    final harness = bridge();
    await openReader(tester, harness);
    await settleEpubPage(tester);

    final page = dartPage(tester)!;
    final surface = page.page.surface;
    final painted = paintedReaderSurface(tester);
    Offset center(int index) {
      final endpoint = surface.endpoints[index];
      final rect = endpoint.rect;
      return readerSurfaceToGlobal(
        painted,
        Offset((rect.left + rect.right) / 2, (rect.top + rect.bottom) / 2),
      );
    }

    await dragReaderSelectionBetween(
      tester,
      center(0),
      center(surface.endpoints.length > 6 ? 6 : surface.endpoints.length - 1),
    );
    await settleReaderSelection(tester);
    expect(find.byKey(const ValueKey('selection-actions')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('reader-edge-next')));
    await pumpHarnessFrames(tester, frames: 8);
    await settleNative(tester);

    expect(
      find.byKey(const ValueKey('selection-actions')),
      findsNothing,
      reason: 'the selection does not outlive the page it addresses',
    );
    final status = tester
        .getSemantics(find.byKey(const ValueKey('reader-selection-status')))
        .getSemanticsData()
        .label;
    expect(
      status,
      isNot(startsWith('Selected text:')),
      reason: 'the selection phase is idle, not selected over an empty range',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await pumpHarnessFrames(tester, frames: 4);
    expect(
      harness.createdRanges,
      isEmpty,
      reason: 'Enter after the turn must not persist the replaced range',
    );

    await tester.pumpWidget(const SizedBox());
    await _drainHarness(tester);
    semantics.dispose();
  });

  testWidgets('a page turn advances the durable offset inside the chapter', (
    tester,
  ) async {
    final long = _repoFile(
      'prototypes/epub-dart-eval/fixtures/long-chapter.epub',
    );
    final longBook = openEpubBytes(long);
    final harness = HarnessBridge(
      books: harnessLibraryBooks(),
      unitCount: longBook.chapters.length,
    );
    harness.epubBytes = long;
    harness.canonicalTexts = {
      for (var unit = 0; unit < longBook.chapters.length; unit += 1)
        unit: longBook.chapters[unit].canonicalText,
    };
    await renderHarnessState(
      tester,
      productionShell(
        home: ReaderScreen(
          bridge: harness,
          initialPath: '/books/umibe.epub',
          initialBookId: 2,
          fontCoverageLoader: () async => coverage,
          epubImageDecoder: (bytes) async => null,
        ),
      ),
      ready: () => harnessReaderPageReady(tester),
      maxRounds: 16,
    );

    await settleEpubPage(tester);
    final first = dartPage(tester);
    expect(first, isNotNull);
    final start = first!.page.canonicalStart;
    expect(first.page.pageIndex, 0);
    expect(
      first.page.pageCount,
      greaterThan(1),
      reason: 'the fixture chapter spans several pages',
    );

    await tester.tap(find.byKey(const ValueKey('reader-edge-next')));
    await pumpHarnessFrames(tester, frames: 8);
    await settleNative(tester);

    final second = dartPage(tester);
    expect(second, isNotNull, reason: 'the chapter stays on the Dart renderer');
    expect(
      second!.page.canonicalStart,
      greaterThan(start),
      reason: 'the next page starts after the first',
    );
    expect(second.page.unit, 0, reason: 'the step stayed inside the chapter');
    expect(
      harness.savedReadingStates.map((state) => state.offset?.toInt()),
      contains(second.page.canonicalStart),
      reason: 'the page turn is the durable position it saved',
    );

    await tester.pumpWidget(const SizedBox());
    await _drainHarness(tester);
  });

  testWidgets('a taller viewport re-paginates and keeps the position', (
    tester,
  ) async {
    final harness = bridge();
    await openReader(tester, harness);
    await settleEpubPage(tester);
    final before = dartPage(tester);
    expect(before, isNotNull);
    final offset = before!.page.canonicalStart;

    tester.view.physicalSize = const Size(1600, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await pumpHarnessFrames(tester, frames: 8);
    await settleNative(tester);

    final after = dartPage(tester);
    expect(after, isNotNull);
    expect(
      after!.page.box.size.height,
      isNot(before.page.box.size.height),
      reason: 'the page window follows the reported document box',
    );
    expect(
      after.page.canonicalStart,
      offset,
      reason: 'a resize keeps the reader on the same durable position',
    );

    await tester.pumpWidget(const SizedBox());
    await _drainHarness(tester);
  });

  testWidgets('a font-size change re-paginates and keeps the position', (
    tester,
  ) async {
    final harness = bridge();
    await openReader(tester, harness);
    await settleEpubPage(tester);
    final before = dartPage(tester);
    expect(before, isNotNull);

    await tester.tap(find.byKey(const ValueKey('reader-header-typography')));
    await pumpHarnessFrames(tester, frames: 4);
    final increase = find.byKey(
      const ValueKey('reader-typography-font-increase'),
    );
    for (var round = 0; round < 8 && increase.evaluate().isEmpty; round += 1) {
      await settleNative(tester, rounds: 1);
    }
    await tester.tap(increase);
    await pumpHarnessFrames(tester, frames: 8);
    await settleNative(tester);

    final after = dartPage(tester);
    expect(after, isNotNull);
    expect(
      after!.page.canonicalStart,
      before!.page.canonicalStart,
      reason: 'a typography change keeps the durable position',
    );
    expect(harness.selectionLayouts, isEmpty, reason: 'no retained layout ran');

    await tester.pumpWidget(const SizedBox());
    await _drainHarness(tester);
  });

  testWidgets('selection and copy read the canonical stream of the page', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    MethodCall? clipboardCall;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') clipboardCall = call;
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final harness = bridge();
    await openReader(tester, harness);

    await settleEpubPage(tester);
    final page = dartPage(tester)!;
    final surface = page.page.surface;
    expect(surface.endpoints, isNotEmpty);
    final from = surface.endpoints.first;
    final to = surface.endpoints.last;
    final painted = paintedReaderSurface(tester);
    await dragReaderSelectionBetween(
      tester,
      readerSurfaceToGlobal(
        painted,
        Offset(
          (from.rect.left + from.rect.right) / 2,
          (from.rect.top + from.rect.bottom) / 2,
        ),
      ),
      readerSurfaceToGlobal(
        painted,
        Offset(
          (to.rect.left + to.rect.right) / 2,
          (to.rect.top + to.rect.bottom) / 2,
        ),
      ),
    );
    await settleReaderSelection(tester);

    final label = tester
        .getSemantics(find.byKey(const ValueKey('reader-selection-status')))
        .getSemanticsData()
        .label;
    expect(label, startsWith('Selected text:'));
    final selected = label.substring('Selected text:'.length).trim();
    expect(selected, isNotEmpty);
    // The selected text is a slice of the chapter's canonical stream: the
    // offsets the store will persist address that stream.
    expect(
      book.chapters[0].canonicalText,
      contains(selected),
      reason: 'the copied text is the canonical text the offsets address',
    );

    // Copy end to end: the action surface writes the same slice to the
    // platform clipboard, so a highlight's offsets and the copied text cannot
    // drift apart.
    await tester.tap(find.text('Copy'));
    await tester.pump();
    expect(clipboardCall?.arguments, {'text': selected});

    await tester.pumpWidget(const SizedBox());
    await _drainHarness(tester);
    semantics.dispose();
  });

  testWidgets('disposal releases the Dart page without a stale install', (
    tester,
  ) async {
    final harness = bridge();
    await openReader(tester, harness);
    expect(dartPage(tester), isNotNull);

    await tester.pumpWidget(const SizedBox());
    await _drainHarness(tester);

    expect(tester.takeException(), isNull);
    expect(harness.isDisposed, isTrue);
    expect(harness.surfaceCalls, 0, reason: 'no retained surface was asked');
  });
}

/// Pumps a frame after tearing the reader down, so the harness's disposal
/// completes inside a real-async window.
Future<void> _drainHarness(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
}

/// The bytes of one repository fixture under the core crate.
Uint8List _fixture(String name) =>
    _repoFile('crates/shosai-core/tests/fixtures/$name');

/// The bytes of one repository file.
Uint8List _repoFile(String path) =>
    Uint8List.fromList(File('../$path').readAsBytesSync());
