import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_epub/shosai_epub.dart';
import 'package:shosai_flutter/reader/epub/content.dart';
import 'package:shosai_flutter/reader/epub/font_coverage.dart';
import 'package:shosai_flutter/reader/epub/flow.dart';
import 'package:shosai_flutter/reader/epub/pages.dart';
import 'package:shosai_flutter/reader/epub/text_style.dart';

/// Layout-level tests for the Dart EPUB renderer: the page window, its
/// selection surface and the windowed chapter session.
///
/// The inputs are real fixture archives and the expectations are derived from
/// the engine's own canonical stream, so these tests do not encode fixture
/// arithmetic: they assert the invariants the reader depends on (every page
/// window covers its own canonical range, the surface's geometry addresses the
/// chapter's stream, and the windowed session reaches the whole chapter).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final conformance = openEpubBytes(_fixture('conformance.epub'));

  const typography = ReaderEpubTypography(
    fontFamily: 'Inter',
    fontFamilyFallback: ['Noto Sans JP'],
    fontSize: 18,
    lineHeight: 1.5,
    palette: ReaderEpubPalette(
      background: Color(0xFFFFFFFF),
      foreground: Color(0xFF1A1A1A),
      link: Color(0xFF174EA6),
      tableHeaderBackground: Color(0xFFE8EEF8),
      tableHeaderBorder: Color(0xFF596B89),
    ),
  );

  ChapterLayoutSpec spec({double width = 640, double height = 800}) =>
      ChapterLayoutSpec(width: width, height: height, typography: typography);

  test('a laid-out chapter paginates into ordered, non-overlapping pages', () {
    final chapter = conformance.chapters[2];
    final flow = layoutChapterFlow(
      chapter: chapter,
      spec: spec(),
      images: const {},
    );
    final paginated = paginateFlow(flow: flow, pageHeight: 800, pageWidth: 640);
    expect(paginated.pages, isNotEmpty);
    expect(paginated.pages.first.index, 0);
    for (var index = 0; index < paginated.pages.length; index += 1) {
      final page = paginated.pages[index];
      expect(page.index, index);
      expect(page.slices, isNotEmpty);
      expect(page.canonicalStart, lessThanOrEqualTo(page.canonicalEnd));
      if (index == 0) continue;
      final previous = paginated.pages[index - 1];
      expect(
        page.canonicalStart,
        greaterThanOrEqualTo(previous.canonicalStart),
        reason: 'pages are ordered by their canonical start',
      );
      expect(
        page.canonicalStart,
        greaterThanOrEqualTo(previous.canonicalEnd),
        reason: 'a page does not start inside the previous page',
      );
    }
    // Every page a scalar resolves to contains that scalar's start.
    for (final page in paginated.pages) {
      expect(
        paginated.pageOfCanonical(page.canonicalStart),
        page.index,
        reason: 'a page resolves its own start',
      );
    }
    expect(
      paginated.pageOfCanonical(chapter.scalarCount),
      paginated.pages.length - 1,
      reason: 'a chapter-end position resolves to the last page',
    );
  });

  test('a page window surface addresses the chapter canonical stream', () {
    final chapter = conformance.chapters[2];
    final session = ChapterLayoutSession(
      chapter: chapter,
      spec: spec(),
      images: const {},
    );
    addTearDown(session.dispose);
    session.layoutWindowAt(0);
    while (!session.complete) {
      final progressed = session.lastNodeIndex + 1 < session.totalNodes
          ? session.layoutForward(maxNodes: 64, maxMicros: 20000)
          : session.layoutBackward(maxNodes: 64, maxMicros: 20000);
      if (progressed == 0) break;
    }
    expect(session.complete, isTrue);

    final page = pageWindowFor(
      session: session,
      scalar: 0,
      unit: chapter.spine,
      chapterCount: conformance.chapters.length,
      windowSize: const Size(680, 800),
    );
    final surface = page.surface;
    expect(surface.text, chapter.canonicalText);
    expect(surface.copyEligible, isTrue);
    expect(surface.resourcePath, chapter.resource);
    expect(surface.endpoints, isNotEmpty);
    expect(page.pageIndex, 0);
    // The fixture chapter is spine 2 of 8: a step back reaches the previous
    // chapter even though this page is the chapter's first.
    expect(page.canGoBackward, isTrue);
    expect(page.canGoForward, isTrue);
    expect(page.pageCount, greaterThan(0));

    final box = page.box;
    for (final endpoint in surface.endpoints) {
      final start = endpoint.rangeStart.toInt();
      final end = endpoint.rangeEnd.toInt();
      expect(end, greaterThan(start), reason: 'a hit zone spans a cluster');
      expect(
        endpoint.offset.toInt(),
        inInclusiveRange(start, end),
        reason: 'a caret sits on its own cluster boundary',
      );
      expect(start, greaterThanOrEqualTo(page.canonicalStart));
      expect(end, lessThanOrEqualTo(page.canonicalEnd));
      expect(endpoint.rect.left, greaterThanOrEqualTo(0));
      expect(endpoint.rect.top, greaterThanOrEqualTo(0));
      expect(
        endpoint.rect.right,
        lessThanOrEqualTo(surface.width + 0.5),
        reason: 'a hit zone stays inside the page window',
      );
      expect(
        endpoint.rect.bottom,
        lessThanOrEqualTo(surface.height + 0.5),
        reason: 'a hit zone stays inside the page window',
      );
      expect(
        endpoint.rect.left,
        greaterThanOrEqualTo(box.origin.dx - 0.5),
        reason: 'text is laid out inside the page margin',
      );
    }
    // The boundaries span the page's coverage and are chapter-relative.
    expect(surface.graphemeBoundaries.first, page.canonicalStart);
    expect(surface.graphemeBoundaries.last, page.canonicalEnd);
    expect(surface.wordBoundaries.first, page.canonicalStart);
    expect(surface.wordBoundaries.last, page.canonicalEnd);
    expect(surface.visualLines, isNotEmpty);
    for (final line in surface.visualLines) {
      expect(line.carets, isNotEmpty);
      for (final caret in line.carets) {
        expect(caret.offset.toInt(), inInclusiveRange(0, chapter.scalarCount));
      }
    }
  });

  test('the windowed session reaches the whole chapter in bounded batches', () {
    final chapter = conformance.chapters[1];
    final session = ChapterLayoutSession(
      chapter: chapter,
      spec: spec(),
      images: const {},
    );
    addTearDown(session.dispose);
    final target = chapter.scalarCount ~/ 2;
    session.layoutWindowAt(target);
    expect(session.started, isTrue);
    expect(
      session.covers(target),
      isTrue,
      reason: 'the first window contains the reader position',
    );
    expect(session.laidOutNodes, greaterThan(0));
    var batches = 0;
    while (!session.complete && batches < 10000) {
      batches += 1;
      final progressed = session.lastNodeIndex + 1 < session.totalNodes
          ? session.layoutForward(maxNodes: 4, maxMicros: 4000)
          : session.layoutBackward(maxNodes: 4, maxMicros: 4000);
      if (progressed == 0) break;
    }
    expect(session.complete, isTrue);
    final flow = session.snapshot();
    expect(flow.layoutComplete, isTrue);
    expect(flow.firstNodeIndex, 0);
    expect(flow.nodeCount, chapter.blocks.length);
    // The snapshot is normalized: the frame starts at zero and the measured
    // extent is the flow height (a block may carry its own leading spacing).
    expect(flow.blocks.first.top, greaterThanOrEqualTo(0));
    expect(flow.height, greaterThan(flow.blocks.last.top));
    for (var index = 1; index < flow.blocks.length; index += 1) {
      expect(
        flow.blocks[index].top,
        greaterThanOrEqualTo(flow.blocks[index - 1].top),
        reason: 'blocks stay in document order',
      );
    }
  });

  test('a very long paragraph keeps line mapping linear and ordered', () {
    final book = openEpubBytes(
      _repoFile('prototypes/epub-dart-eval/fixtures/huge-paragraph.epub'),
    );
    final chapter = book.chapters.first;
    final stopwatch = Stopwatch()..start();
    final flow = layoutChapterFlow(
      chapter: chapter,
      spec: spec(),
      images: const {},
    );
    stopwatch.stop();
    final textBlocks = flow.blocks
        .where((block) => block.text != null)
        .toList(growable: false);
    expect(textBlocks, isNotEmpty);
    final lines = textBlocks.expand((block) => block.text!.lines).toList();
    expect(lines.length, greaterThan(100));
    for (var index = 1; index < lines.length; index += 1) {
      expect(
        lines[index].canonicalStart,
        greaterThanOrEqualTo(lines[index - 1].canonicalStart),
        reason: 'line boundaries follow the canonical stream',
      );
      expect(
        lines[index].canonicalEnd,
        greaterThanOrEqualTo(lines[index].canonicalStart),
      );
    }
    // The per-line mapping is one monotone pass over the block text: a
    // per-boundary scan of a 64k-scalar paragraph took seconds in the
    // prototype. The bound is deliberately loose so it fails only on a
    // quadratic regression, not on a slow machine.
    expect(
      stopwatch.elapsedMilliseconds,
      lessThan(10000),
      reason: 'laying out one very long paragraph stays bounded',
    );
  });

  test('the session releases its measured paragraphs once', () {
    final chapter = conformance.chapters[2];
    final session = ChapterLayoutSession(
      chapter: chapter,
      spec: spec(),
      images: const {},
    );
    session.layoutWindowAt(0);
    expect(session.started, isTrue);
    session.dispose();
    // A second release is a no-op rather than a double free.
    session.dispose();
    expect(session.laidOutNodes, greaterThan(0));
  });

  test('the page margin bounds the laid-out content', () {
    final box = epubPageBoxFor(const Size(680, 800));
    expect(box.size, const Size(680, 800));
    expect(box.origin.dx, kEpubPageMargin);
    expect(box.origin.dy, kEpubPageMargin);
    expect(box.contentWidth, 680 - 2 * kEpubPageMargin);
    expect(box.contentHeight, 800 - 2 * kEpubPageMargin);
    // A tiny window still leaves a usable content box.
    final small = epubPageBoxFor(const Size(60, 60));
    expect(small.contentWidth, greaterThanOrEqualTo(40));
    expect(small.contentHeight, greaterThanOrEqualTo(40));
  });

  test('the bundled-face coverage admits exactly what the faces carry', () {
    // The coverage is read from the shipped fonts' own cmap tables, so these
    // expectations are about the faces the reader bundles: Inter carries Latin,
    // Greek and Cyrillic; Noto Sans JP carries kana and the Japanese
    // ideographs it covers (the JIS set, not the whole CJK block).
    final coverage = EpubFontCoverage.fromFonts([
      _repoFile('assets/fonts/InterVariable.ttf'),
      _repoFile('assets/fonts/NotoSansJP-Variable.ttf'),
    ]);
    expect(coverage, isNotNull);
    expect(coverage!.coversText('English 123 — Привет'), isTrue);
    expect(coverage.coversText('湖の記録'), isTrue);
    expect(coverage.coversText('あいうえお'), isTrue);
    // Scripts neither face carries.
    expect(coverage.coversText('שלום'), isFalse);
    expect(coverage.coversText('مرحبا'), isFalse);
    expect(coverage.coversText('😀'), isFalse);
    // A code point inside the CJK block that the bundled face does *not* carry:
    // the block-level gate this replaced admitted it and painted tofu.
    expect(coverage.covers(0x4E06), isFalse);
    expect(coverage.coversText('丆'), isFalse);
    // The engine's conformance fixtures follow the faces: the Latin chapters
    // route, the bidi chapter does not.
    expect(coverage.coversText(conformance.chapters[0].canonicalText), isTrue);
    expect(coverage.coversText(conformance.chapters[5].canonicalText), isFalse);
  });

  test('an unreadable font reports unknown coverage', () {
    expect(EpubFontCoverage.fromFonts([Uint8List(8)]), isNull);
  });

  test('chapter image sources are collected in document order', () {
    final chapter = conformance.chapters[0];
    final sources = chapterImageSources(chapter);
    expect(sources, isNotEmpty);
    expect(sources.toSet().length, sources.length, reason: 'each source once');
    for (final source in sources) {
      expect(conformance.resources.containsKey(source), isTrue);
    }
  });

  /// A synthetic chapter of [count] paragraphs, each with visible text.
  EpubChapter paragraphChapter(int count) => EpubChapter(
    spine: 0,
    resource: 'chapter.xhtml',
    title: 'Paragraphs',
    blocks: [
      for (var index = 0; index < count; index += 1)
        EpubParagraph([
            EpubTextSpan(
              text: 'Paragraph $index with enough words to measure a line.',
            ),
          ], const EpubNodeStyle())
          ..canonical = EpubCanonicalSpan(index * 48, index * 48 + 47),
    ],
    canonicalText: '',
    anchors: const {},
    scalarCount: count * 48,
  );

  /// Asserts the painters created by a failed call are released and the ones the
  /// session already adopted are not.
  void expectReleaseBoundary(
    List<TextPainter> painters, {
    required int adopted,
    required int created,
  }) {
    for (var index = 0; index < painters.length; index += 1) {
      final painter = painters[index];
      if (index < adopted) {
        expect(
          painter.debugDisposed,
          isFalse,
          reason: 'an adopted painter (${index + 1}) is not released',
        );
      } else if (index < created) {
        expect(
          painter.debugDisposed,
          isTrue,
          reason:
              'a painter the failed call created (${index + 1}) is released',
        );
      }
    }
  }

  test('a failed batch rolls its measurement back before it rethrows', () {
    // A layout failure must not leave a half-adopted range: the retry after the
    // failure has to produce the same flow a clean layout produces.
    final chapter = paragraphChapter(40);
    final clean = ChapterLayoutSession(
      chapter: chapter,
      spec: spec(),
      images: const {},
    )..layoutWindowAt(0, viewports: 0.1);
    while (!clean.complete) {
      clean.layoutForward(maxNodes: 4, maxMicros: 1000000);
    }
    final expected = clean.snapshot();

    final failing = ChapterLayoutSession(
      chapter: chapter,
      spec: spec(),
      images: const {},
    )..layoutWindowAt(0, viewports: 0.1);
    failing.layoutForward(maxNodes: 2, maxMicros: 1000000);
    failing.layoutForward(maxNodes: 2, maxMicros: 1000000);
    final before = failing.snapshot();
    // The failing batch measures one node and then throws.
    failing.debugFailNodeIndex = failing.lastNodeIndex + 2;
    expect(
      () => failing.layoutForward(maxNodes: 4, maxMicros: 1000000),
      throwsStateError,
    );
    final after = failing.snapshot();

    expect(
      after.blocks.length,
      before.blocks.length,
      reason: 'the failing batch adopted nothing',
    );
    for (var index = 0; index < before.blocks.length; index += 1) {
      expect(
        after.blocks[index].top,
        before.blocks[index].top,
        reason: 'adopted block positions are unchanged by the rollback',
      );
      expect(after.blocks[index].text?.painter.debugDisposed, isFalse);
    }

    failing.debugFailNodeIndex = null;
    while (!failing.complete) {
      failing.layoutForward(maxNodes: 4, maxMicros: 1000000);
    }
    final retried = failing.snapshot();
    expect(retried.blocks.length, expected.blocks.length);
    for (var index = 0; index < expected.blocks.length; index += 1) {
      expect(
        retried.blocks[index].top,
        expected.blocks[index].top,
        reason: 'the retry matches a clean layout',
      );
    }
    clean.dispose();
    failing.dispose();
  });

  test('a backward batch that throws after a prepend commits nothing', () {
    // The staged range is committed only when the whole batch completes: a throw
    // after an earlier node of the same batch was measured must leave the range
    // exactly as it was, release the painters the batch created, and let the
    // retry produce the layout a clean session produces.
    final chapter = paragraphChapter(40);
    final clean = ChapterLayoutSession(
      chapter: chapter,
      spec: spec(),
      images: const {},
    )..layoutWindowAt(chapter.scalarCount, viewports: 0.1);
    while (clean.firstNodeIndex > 0) {
      clean.layoutBackward(maxNodes: 3, maxMicros: 1000000);
    }
    final expected = clean.snapshot();

    final session =
        ChapterLayoutSession(chapter: chapter, spec: spec(), images: const {})
          ..debugObservePainters = true
          ..layoutWindowAt(chapter.scalarCount, viewports: 0.1);
    final before = session.snapshot();
    final adoptedPainters = session.debugCreatedPainters.length;
    // The second node of the batch throws: the first prepend is already staged.
    session.debugFailNodeIndex = session.firstNodeIndex - 2;
    expect(
      () => session.layoutBackward(maxNodes: 3, maxMicros: 1000000),
      throwsA(isA<StateError>()),
    );

    final after = session.snapshot();
    expect(
      after.blocks.length,
      before.blocks.length,
      reason: 'a failed backward batch commits nothing',
    );
    for (var index = 0; index < before.blocks.length; index += 1) {
      expect(after.blocks[index].top, before.blocks[index].top);
    }
    expect(after.firstNodeIndex, before.firstNodeIndex);
    expect(after.height, before.height);
    expectReleaseBoundary(
      session.debugCreatedPainters,
      adopted: adoptedPainters,
      created: session.debugCreatedPainters.length,
    );

    session.debugFailNodeIndex = null;
    while (session.firstNodeIndex > 0) {
      session.layoutBackward(maxNodes: 3, maxMicros: 1000000);
    }
    final retried = session.snapshot();
    expect(retried.blocks.length, expected.blocks.length);
    for (var index = 0; index < expected.blocks.length; index += 1) {
      expect(
        retried.blocks[index].top,
        expected.blocks[index].top,
        reason: 'the retry matches a clean layout',
      );
    }
    clean.dispose();
    session.dispose();
  });

  /// A chapter of paragraphs and one table, for construction-failure tests.
  EpubChapter paragraphAndTableChapter() => EpubChapter(
    spine: 0,
    resource: 'chapter.xhtml',
    title: 'Paragraphs and a table',
    blocks: [
      EpubParagraph([
        EpubTextSpan(text: 'Lead paragraph before the table.'),
      ], const EpubNodeStyle())..canonical = const EpubCanonicalSpan(0, 31),
      EpubTable(
        caption: [EpubTextSpan(text: 'Quarterly results')],
        rowGroups: [
          EpubTableRowGroup(
            kind: EpubTableRowGroupKind.body,
            rows: [
              EpubTableRow(
                cells: [
                  EpubTableCell(
                    children: [
                      EpubParagraph(
                        [EpubTextSpan(text: 'Cell paragraph.')],
                        const EpubNodeStyle(),
                      )..canonical = const EpubCanonicalSpan(32, 46),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ],
      )..canonical = const EpubCanonicalSpan(32, 60),
      for (var index = 0; index < 8; index += 1)
        EpubParagraph(
          [EpubTextSpan(text: 'Trailing paragraph $index.')],
          const EpubNodeStyle(),
        )..canonical = EpubCanonicalSpan(61 + index * 24, 84 + index * 24),
    ],
    canonicalText: '',
    anchors: const {},
    scalarCount: 61 + 8 * 24,
  );

  test('an interrupted window construction releases its painters', () {
    final chapter = paragraphChapter(12);
    final clean = ChapterLayoutSession(
      chapter: chapter,
      spec: spec(),
      images: const {},
    )..layoutWindowAt(0, viewports: 0.01);
    while (!clean.complete) {
      clean.layoutForward(maxNodes: 4, maxMicros: 1000000);
    }
    final expected = clean.snapshot();

    final session = ChapterLayoutSession(
      chapter: chapter,
      spec: spec(),
      images: const {},
    );
    session.debugFailTextBlockAt = 1;
    expect(
      () => session.layoutWindowAt(0, viewports: 0.01),
      throwsA(isA<StateError>()),
    );
    expect(session.debugCreatedPainters, hasLength(1));
    expect(
      session.debugCreatedPainters.single.debugDisposed,
      isTrue,
      reason: 'a window that never starts releases what it created',
    );
    expect(session.snapshot().blocks, isEmpty);
    expect(session.firstNodeIndex, 0);

    session.debugFailTextBlockAt = null;
    session.layoutWindowAt(0, viewports: 0.01);
    while (!session.complete) {
      session.layoutForward(maxNodes: 4, maxMicros: 1000000);
    }
    final retried = session.snapshot();
    expect(retried.layoutComplete, isTrue);
    expect(retried.blocks.length, expected.blocks.length);
    for (var index = 0; index < expected.blocks.length; index += 1) {
      expect(
        retried.blocks[index].top,
        expected.blocks[index].top,
        reason: 'the retry matches a clean layout',
      );
    }
    clean.dispose();
    session.dispose();
  });

  for (final failure in const [
    (
      offset: 1,
      table: false,
      name: 'a standalone paragraph',
      what: 'the paragraph painter',
    ),
    (
      offset: 1,
      table: true,
      name: 'a table caption',
      what: 'the caption painter',
    ),
    (
      offset: 2,
      table: true,
      name: 'a table cell width measurement',
      what: 'the scratch cell painter',
    ),
    (
      offset: 3,
      table: true,
      name: 'a table cell paragraph after its width measurement',
      what: 'the final cell painter',
    ),
    (
      offset: 4,
      table: true,
      name: 'a paragraph after a completed table',
      what: 'a later painter',
    ),
  ]) {
    test('an interrupted ${failure.name} construction releases its painters', () {
      final chapter = failure.table
          ? paragraphAndTableChapter()
          : paragraphChapter(12);
      final clean = ChapterLayoutSession(
        chapter: chapter,
        spec: spec(),
        images: const {},
      )..layoutWindowAt(0, viewports: 0.01);
      while (!clean.complete) {
        clean.layoutForward(maxNodes: 4, maxMicros: 1000000);
      }
      final expected = clean.snapshot();

      final session =
          ChapterLayoutSession(chapter: chapter, spec: spec(), images: const {})
            ..debugObservePainters = true
            ..layoutWindowAt(0, viewports: 0.01);
      final before = session.snapshot();
      final adoptedPainters = session.debugCreatedPainters.length;
      expect(
        adoptedPainters,
        greaterThan(0),
        reason: 'the window adopted painters the failure must not release',
      );
      final failingPainter = adoptedPainters + failure.offset;

      session.debugFailTextBlockAt = failingPainter;
      expect(
        () => session.layoutForward(maxNodes: 3, maxMicros: 1000000),
        throwsA(isA<StateError>()),
        reason:
            'the ${failure.what} failure propagates as the original error '
            '(a second release of an already-released painter would surface as '
            'an assertion instead)',
      );

      final after = session.snapshot();
      expect(after.blocks.length, before.blocks.length);
      expect(after.height, before.height);
      expect(after.firstNodeIndex, before.firstNodeIndex);
      expect(
        session.debugCreatedPainters.length,
        failingPainter,
        reason: 'the construction reached the painter it failed on',
      );
      expectReleaseBoundary(
        session.debugCreatedPainters,
        adopted: adoptedPainters,
        created: failingPainter,
      );

      // The session still measures cleanly once the failure is cleared, and the
      // result matches a session that never failed.
      session.debugFailTextBlockAt = null;
      while (!session.complete) {
        session.layoutForward(maxNodes: 4, maxMicros: 1000000);
      }
      final retried = session.snapshot();
      expect(retried.layoutComplete, isTrue);
      expect(retried.blocks.length, expected.blocks.length);
      for (var index = 0; index < expected.blocks.length; index += 1) {
        expect(
          retried.blocks[index].top,
          expected.blocks[index].top,
          reason: 'the retry matches a clean layout',
        );
      }
      clean.dispose();
      session.dispose();
    });
  }

  test('an embedded or monospace span keeps the bundled fallback chain', () {
    // The routing gate only promises the *bundled* faces can draw a chapter, so
    // a span that selects an admitted (or platform monospace) face must keep
    // the bundled primary and its fallbacks behind it.
    const typography = ReaderEpubTypography(
      fontFamily: 'Inter',
      fontFamilyFallback: ['Noto Sans JP'],
      fontSize: 18,
      lineHeight: 1.5,
      palette: ReaderEpubPalette(
        background: Color(0xFFFFFFFF),
        foreground: Color(0xFF1A1A1A),
        link: Color(0xFF174EA6),
        tableHeaderBackground: Color(0xFFE8EEF8),
        tableHeaderBorder: Color(0xFF596B89),
      ),
      embeddedFamilies: {'Body': 'shosai-epub-1-Body'},
    );

    final plain = spanStyle(EpubTextSpan(text: 'plain'), typography, 18);
    expect(plain.fontFamily, 'Inter');
    expect(plain.fontFamilyFallback, ['Noto Sans JP']);

    final embedded = spanStyle(
      EpubTextSpan(text: 'embedded', fontFamily: 'Body'),
      typography,
      18,
    );
    expect(embedded.fontFamily, 'shosai-epub-1-Body');
    expect(embedded.fontFamilyFallback, ['Inter', 'Noto Sans JP']);

    final monospace = spanStyle(
      EpubTextSpan(text: 'code', monospace: true),
      typography,
      18,
    );
    expect(monospace.fontFamily, 'monospace');
    expect(monospace.fontFamilyFallback, ['Inter', 'Noto Sans JP']);
  });

  test('list items and table structure count toward the indivisible bound', () {
    // The bound is about the work one layout call does: a list measures every
    // item and a table places every group/row/cell in one call, so both count
    // as work units rather than as single leaf nodes.
    EpubChapter chapter(List<EpubContentNode> blocks) => EpubChapter(
      spine: 0,
      resource: 'chapter.xhtml',
      title: 'Chapter',
      blocks: blocks,
      canonicalText: '',
      anchors: const {},
      scalarCount: 0,
    );
    EpubBook book(List<EpubContentNode> blocks) => EpubBook(
      title: 'Bound',
      author: null,
      language: null,
      spine: const ['chapter.xhtml'],
      toc: const [],
      resources: const {},
      chapters: [chapter(blocks)],
      embeddedFonts: const {},
      warnings: const [],
    );
    EpubContentSource source(List<EpubContentNode> blocks) => EpubContentSource(
      book: book(blocks),
      embeddedFamilies: const {},
      bytes: Uint8List(0),
    );

    final manyItems = source([
      EpubUnorderedList([
        for (var index = 0; index < kEpubIndivisibleNodeLimit + 1; index += 1)
          const <EpubTextSpan>[],
      ]),
    ]);
    expect(manyItems.indivisibleUnitsBounded(0), isFalse);

    final manyRows = source([
      EpubTable(
        caption: const [],
        rowGroups: [
          EpubTableRowGroup(
            kind: EpubTableRowGroupKind.body,
            rows: [
              for (
                var index = 0;
                index < kEpubIndivisibleNodeLimit + 1;
                index += 1
              )
                EpubTableRow(cells: [EpubTableCell(children: const [])]),
            ],
          ),
        ],
      ),
    ]);
    expect(manyRows.indivisibleUnitsBounded(0), isFalse);

    final bounded = source([
      EpubUnorderedList([
        for (var index = 0; index < 8; index += 1) const <EpubTextSpan>[],
      ]),
      EpubParagraph(const [], const EpubNodeStyle()),
    ]);
    expect(bounded.indivisibleUnitsBounded(0), isTrue);

    final hugeText = source([
      EpubParagraph(const [], const EpubNodeStyle())
        ..canonical = const EpubCanonicalSpan(
          0,
          kEpubIndivisibleScalarLimit + 1,
        ),
    ]);
    expect(hugeText.indivisibleUnitsBounded(0), isFalse);
  });

  test('a decode shared by concurrent callers is adopted once', () async {
    final bytes = _fixture('nested-image.epub');
    final book = openEpubBytes(bytes);
    final source = EpubContentSource(
      book: book,
      embeddedFamilies: const {},
      bytes: bytes,
    );
    final chapter = book.chapters[0];
    var calls = 0;
    final pending = Completer<ui.Image>();
    Future<ui.Image?> decode(Uint8List _) {
      calls += 1;
      return pending.future;
    }

    final first = source.ensureImages(chapter, decode);
    final second = source.ensureImages(chapter, decode);
    final image = await _testImage(64, 48);
    pending.complete(image);
    await Future.wait([first, second]);

    expect(calls, 1, reason: 'the resource was decoded once');
    expect(source.images, hasLength(1));
    expect(
      source.decodedImageBytes,
      64 * 48 * 4,
      reason: 'the raster is accounted for once, by its adopting caller',
    );

    source.dispose();
    expect(image.debugDisposed, isTrue, reason: 'the owner released it once');
  });

  test('a decoder that never settles does not hold the chapter open', () async {
    final bytes = _fixture('nested-image.epub');
    final book = openEpubBytes(bytes);
    final source = EpubContentSource(
      book: book,
      embeddedFamilies: const {},
      bytes: bytes,
      imageDecodeTimeout: const Duration(milliseconds: 20),
    );

    await source.ensureImages(
      book.chapters[0],
      (_) => Completer<ui.Image?>().future,
    );

    expect(
      source.images,
      isEmpty,
      reason:
          'a decode that misses its deadline is refused, not awaited forever',
    );
    source.dispose();
  });

  test('two waiters release an over-budget raster exactly once', () async {
    final bytes = _fixture('nested-image.epub');
    final book = openEpubBytes(bytes);
    final source = EpubContentSource(
      book: book,
      embeddedFamilies: const {},
      bytes: bytes,
      rasterBudgetBytes: 64 * 48 * 4 - 1,
    );
    final image = await _testImage(64, 48);

    await Future.wait([
      source.ensureImages(book.chapters[0], (_) async => image),
      source.ensureImages(book.chapters[0], (_) async => image),
    ]);

    expect(source.images, isEmpty);
    expect(
      image.debugDisposed,
      isTrue,
      reason: 'the shared result is released once, not once per waiter',
    );
    source.dispose();
  });

  test('a decoder that throws before returning is refused once', () async {
    final bytes = _fixture('nested-image.epub');
    final book = openEpubBytes(bytes);
    final source = EpubContentSource(
      book: book,
      embeddedFamilies: const {},
      bytes: bytes,
      imageDecodeTimeout: const Duration(milliseconds: 20),
    );
    var calls = 0;
    Future<ui.Image?> decode(Uint8List _) {
      calls += 1;
      throw StateError('decode failed');
    }

    await Future.wait([
      source.ensureImages(book.chapters[0], decode),
      source.ensureImages(book.chapters[0], decode),
    ]);
    await source.ensureImages(book.chapters[0], decode);

    expect(calls, 1, reason: 'a refused resource is not decoded again');
    expect(source.images, isEmpty);
    expect(source.decodedImageBytes, 0);
    source.dispose();
  });

  test('a timed-out decode is not retried while it is outstanding', () async {
    final bytes = _fixture('nested-image.epub');
    final book = openEpubBytes(bytes);
    final source = EpubContentSource(
      book: book,
      embeddedFamilies: const {},
      bytes: bytes,
      imageDecodeTimeout: const Duration(milliseconds: 20),
    );
    var calls = 0;
    final pending = Completer<ui.Image?>();
    Future<ui.Image?> decode(Uint8List _) {
      calls += 1;
      return pending.future;
    }

    await source.ensureImages(book.chapters[0], decode);
    await source.ensureImages(book.chapters[0], decode);

    expect(calls, 1, reason: 'a refused resource is not decoded again');
    expect(source.images, isEmpty);
    source.dispose();
  });

  test('a late decode after disposal is released', () async {
    final bytes = _fixture('nested-image.epub');
    final book = openEpubBytes(bytes);
    final source = EpubContentSource(
      book: book,
      embeddedFamilies: const {},
      bytes: bytes,
    );
    final pending = Completer<ui.Image?>();
    final admission = source.ensureImages(
      book.chapters[0],
      (_) => pending.future,
    );

    source.dispose();
    final image = await _testImage(32, 32);
    pending.complete(image);
    await admission;

    expect(source.images, isEmpty);
    expect(
      image.debugDisposed,
      isTrue,
      reason: 'a raster for a released source is released with it',
    );
  });

  test('a raster past the byte budget is released, not adopted', () async {
    final bytes = _fixture('nested-image.epub');
    final book = openEpubBytes(bytes);
    final source = EpubContentSource(
      book: book,
      embeddedFamilies: const {},
      bytes: bytes,
      rasterBudgetBytes: 64 * 48 * 4 - 1,
    );
    final image = await _testImage(64, 48);

    await source.ensureImages(book.chapters[0], (_) async => image);

    expect(source.images, isEmpty);
    expect(source.decodedImageBytes, 0);
    expect(
      image.debugDisposed,
      isTrue,
      reason: 'an over-budget raster is released rather than retained',
    );
    source.dispose();
  });
}

/// A solid test raster of the given size.
Future<ui.Image> _testImage(int width, int height) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = const Color(0xFFEEEEEE),
  );
  return recorder.endRecording().toImage(width, height);
}

Uint8List _fixture(String name) =>
    _repoFile('crates/shosai-core/tests/fixtures/epub-conformance/$name');

Uint8List _repoFile(String path) =>
    Uint8List.fromList(File('../$path').readAsBytesSync());
