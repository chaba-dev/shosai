import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_epub/shosai_epub.dart';
import 'package:shosai_flutter/reader/epub/flow.dart';
import 'package:shosai_flutter/reader/view.dart';
import 'package:shosai_flutter/core/bridge.dart';
import 'package:shosai_flutter/theme_tokens.dart';

import '../support/epub_navigation_fixture.dart';
import '../support/production_shell_harness.dart';
import '../support/selection_surface_fixture.dart';

/// The production reader lays every EPUB chapter out with the Dart engine.
///
/// The bytes are real fixture archives, parsed by the real engine; the bridge
/// is the deterministic harness, so the page windows, their ownership and the
/// durable offsets are what these tests isolate.
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

  HarnessBridge bridge({
    Uint8List? bytes,
    int unitCount = 8,
    List<FlutterLibraryBook>? books,
  }) {
    final harness = HarnessBridge(books: books, unitCount: unitCount);
    harness.epubBytes = bytes ?? conformance;
    return harness;
  }

  Future<void> openReader(
    WidgetTester tester,
    HarnessBridge harness, {
    bool failing = false,
    FlutterReaderSettings? settings,
  }) async {
    await renderHarnessState(
      tester,
      productionShell(
        home: ReaderScreen(
          bridge: harness,
          initialPath: '/books/conformance.epub',
          initialSettings: settings,
          epubImageDecoder: (bytes) async => null,
        ),
      ),
      ready: failing
          ? () => find
                .byKey(const ValueKey('reader-content-error'))
                .evaluate()
                .isNotEmpty
          : () => harnessReaderPageReady(tester),
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

  testWidgets('a chapter renders the Dart page window', (tester) async {
    final harness = bridge();
    await openReader(tester, harness);

    final page = dartPage(tester);
    expect(page, isNotNull, reason: 'the chapter is laid out by the engine');
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
    expect(harness.epubSourceCalls, 1);

    await tester.pumpWidget(const SizedBox());
    await _drainHarness(tester);
  });

  testWidgets('a book past the cell-walk admission ceiling fails to lay out', (
    tester,
  ) async {
    // The shallow control lays out; the over-deep book, identical but for the
    // span depth, is refused at admission, and the reader reports the failure
    // instead of painting a page.
    final control = bridge(bytes: admissionEpub(spanNesting: 2), unitCount: 1);
    await openReader(tester, control);
    expect(
      dartPage(tester),
      isNotNull,
      reason: 'the identical book inside the ceiling lays out',
    );
    await tester.pumpWidget(const SizedBox());
    await _drainHarness(tester);

    expect(
      () => openEpubBytes(admissionEpub(spanNesting: 65)),
      throwsA(isA<EpubLimitError>()),
    );
    final refused = bridge(bytes: admissionEpub(spanNesting: 65), unitCount: 1);
    await openReader(tester, refused, failing: true);
    expect(dartPage(tester), isNull);
    expect(
      find.byKey(const ValueKey('reader-content-error')),
      findsOneWidget,
      reason: 'a refused archive is an open failure',
    );

    await tester.pumpWidget(const SizedBox());
    await _drainHarness(tester);
  });

  testWidgets('a chapter with one enormous paragraph still lays out', (
    tester,
  ) async {
    // The windowed session measures in bounded batches between top-level
    // blocks, but one paragraph is measured in a single call; the chapter is
    // laid out anyway, because there is no other renderer to hand it to.
    final huge = _repoFile(
      'prototypes/epub-dart-eval/fixtures/huge-paragraph.epub',
    );
    final hugeBook = openEpubBytes(huge);
    final harness = bridge(bytes: huge, unitCount: hugeBook.chapters.length);
    await openReader(tester, harness);
    await settleEpubPage(tester);

    expect(dartPage(tester), isNotNull);

    await tester.pumpWidget(const SizedBox());
    await _drainHarness(tester);
  });

  testWidgets('a chapter outside the bundled faces still lays out', (
    tester,
  ) async {
    // bidi.epub's stream carries Hebrew, Arabic and an emoji, which neither
    // bundled face carries: the host's fallback faces draw them.
    final bidi = _fixture('epub-conformance/bidi.epub');
    final bidiBook = openEpubBytes(bidi);
    final harness = bridge(bytes: bidi, unitCount: bidiBook.chapters.length);
    await openReader(tester, harness);

    expect(dartPage(tester), isNotNull);
    expect(
      dartPage(tester)!.page.surface.text,
      bidiBook.chapters.first.canonicalText,
    );

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

  testWidgets('an unreadable archive fails the open with an error', (
    tester,
  ) async {
    final harness = bridge(bytes: Uint8List(0));
    await openReader(tester, harness, failing: true);

    expect(dartPage(tester), isNull);
    expect(find.byKey(const ValueKey('reader-content-error')), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await _drainHarness(tester);
  });

  testWidgets('the dark reader keeps a failed book message legible', (
    tester,
  ) async {
    await openReader(
      tester,
      bridge(bytes: Uint8List(0)),
      failing: true,
      settings: const FlutterReaderSettings(
        continuous: false,
        theme: 'dark',
        epubFontSize: 18,
        epubLineSpacing: 1.5,
        pdfZoom: 0,
      ),
    );

    // A failed book is still document-area copy: the message follows the
    // reader palette ink over the reader paper.
    final message = tester.widget<Text>(
      find.byKey(const ValueKey('reader-content-error')),
    );
    expect(message.style?.color, ShosaiTokens.readerDarkText);

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
    await renderHarnessState(
      tester,
      productionShell(
        home: ReaderScreen(
          bridge: harness,
          initialPath: '/books/umibe.epub',
          initialBookId: 2,
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
Uint8List _fixture(String name) => _repoFile('fixtures/$name');

/// The bytes of one repository file.
Uint8List _repoFile(String path) =>
    Uint8List.fromList(File('../$path').readAsBytesSync());
