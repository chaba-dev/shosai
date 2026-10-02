import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_epub/shosai_epub.dart';
import 'package:shosai_flutter/reader/epub/font_coverage.dart';
import 'package:shosai_flutter/reader/epub/surface.dart';
import 'package:shosai_flutter/reader/view.dart';
import 'package:shosai_flutter/src/rust/api.dart';

import '../support/epub_navigation_fixture.dart';
import '../support/production_shell_harness.dart';

/// Slice 5 canonical-parity renders.
///
/// The page and the Contents panel are served by the real engine over the
/// canonical-parity fixture, whose stream the retained Rust parser pinned (the
/// probe run recorded with slice 5). The assertions here are independent
/// content and geometry checks — the rendered block texts, the panel's row
/// source and the navigation target — not image snapshots; the captures are
/// candidate renders for owner inspection.
class _CanonicalRenderBridge extends HarnessBridge {
  _CanonicalRenderBridge({super.books, super.unitCount});

  @override
  Future<FlutterReadingState?> loadReadingState({
    required int bookId,
    required BigInt cancellationId,
  }) async => null;
}

void main() {
  setUpAll(loadHarnessFonts);

  final bytes = canonicalParityEpub();
  final book = openEpubBytes(bytes);
  final coverage = EpubFontCoverage.fromFonts([
    Uint8List.fromList(
      File('../assets/fonts/InterVariable.ttf').readAsBytesSync(),
    ),
    Uint8List.fromList(
      File('../assets/fonts/NotoSansJP-Variable.ttf').readAsBytesSync(),
    ),
  ])!;

  // The retained parser's own stream for the fixture chapter (probe run with
  // slice 5), the baseline the Dart engine must reproduce before rendering.
  const retainedCanonicalText =
      'a middle tail.\n'
      'before\n'
      'Cell link to the cell.\n'
      '\tAlpha bold tail\n'
      'before\n'
      '(a)/(b)\n'
      'after\tAnchor cell\n\n'
      'After the table.\n';
  const retainedAnchors = {
    'x': 21,
    'lead': 22,
    'empty-cell': 45,
    'cell-anchor': 83,
  };

  test('the engine reproduces the retained stream for the fixture', () {
    expect(book.chapters.single.canonicalText, retainedCanonicalText);
    for (final entry in retainedAnchors.entries) {
      expect(
        book.chapters.single.anchors[entry.key],
        entry.value,
        reason: 'anchor ${entry.key} matches the retained parser',
      );
    }
    // The NCX wins over the nav document (slice 5's TOC preference), so the
    // panel's source rows are the NCX's, not the nav's.
    expect(
      [
        for (final entry in book.toc)
          '${entry.title} -> ${entry.resource}'
              '${entry.fragment == null ? '' : '#${entry.fragment}'}',
      ],
      const [
        'NCX One -> OPS/Text/chapter-1.xhtml',
        'NCX Two -> OPS/Text/chapter-1.xhtml#cell-anchor',
      ],
    );
  });

  HarnessBridge bridge() {
    final harness = _CanonicalRenderBridge(
      unitCount: 1,
      books: const [
        FlutterLibraryBook(
          bookId: 1,
          title: 'EPUB Canonical Parity',
          format: FlutterBookFormat.epub,
          pathKey: '/books/canonical-parity.epub',
          managed: true,
          progress: 0,
          dateAdded: '2026-10-02',
        ),
      ],
    );
    harness.epubBytes = bytes;
    // The routing gate must compare against the retained parser's own
    // literal, not the engine's output: feeding the engine's text back would
    // make the gate self-confirming.
    harness.canonicalTexts = const {0: retainedCanonicalText};
    return harness;
  }

  Widget reader(HarnessBridge harness) => productionShell(
    locale: const Locale('en'),
    home: ReaderScreen(
      bridge: harness,
      initialPath: '/books/canonical-parity.epub',
      initialBookId: 1,
      fontCoverageLoader: () async => coverage,
      epubImageDecoder: (bytes) async => null,
    ),
  );

  /// The text every placed page block paints, across all EPUB page painters.
  List<String> paintedPageTexts(WidgetTester tester) => [
    for (final painter in tester.widgetList<CustomPaint>(
      find.byType(CustomPaint),
    ))
      if (painter.painter is ReaderEpubPageContentPainter)
        for (final slice
            in (painter.painter as ReaderEpubPageContentPainter)
                .page
                .page
                .slices)
          for (final placed in placedPageText(
            slice,
            (painter.painter as ReaderEpubPageContentPainter).page.box,
          ))
            placed.block.map.text,
  ];

  Future<void> openContents(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('reader-header-contents')));
    await pumpHarnessFrames(tester, frames: 4);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 120)),
    );
    await pumpHarnessFrames(tester, frames: 8);
  }

  testWidgets('the parity page paints the collapsed runs (EN, wide)', (
    tester,
  ) async {
    final harness = bridge();
    final view = const HarnessView(size: Size(1280, 800));
    view.apply(tester);
    await renderHarnessState(
      tester,
      reader(harness),
      ready: () => harnessReaderPageReady(tester),
    );
    await pumpHarnessFrames(tester, frames: 4);

    final texts = paintedPageTexts(tester);
    // `<br/>` contributes no scalar: "mid" and "dle" join into one run with no
    // line break, and the trailing marker's paragraph carries only its text.
    expect(
      texts.where((text) => text.contains('mid')),
      hasLength(1),
      reason: 'the break paragraph is painted once',
    );
    final breakParagraph = texts.singleWhere((text) => text.contains('mid'));
    expect(breakParagraph, 'a middle tail.');
    expect(breakParagraph.contains('\n'), isFalse);
    // A whitespace-only cell paints nothing; the inline-only cell is one
    // collapsed run.
    expect(
      texts.any((text) => text.trim().isEmpty && text.isNotEmpty),
      isFalse,
      reason: 'no whitespace-only block is painted',
    );
    expect(
      texts.contains('Alpha bold tail'),
      isTrue,
      reason: 'the inline-only cell is one collapsed run',
    );
    // Display math inside an inline cell splits the runs: "before", the math
    // fallback and "after" are separate blocks.
    expect(texts.contains('before'), isTrue);
    expect(texts.contains('(a)/(b)'), isTrue);
    expect(texts.contains('after'), isTrue);
    expect(texts.contains('Anchor cell'), isTrue);
    expect(texts.contains('After the table.'), isTrue);

    final defects = await findRenderDefects(tester);
    await captureHarnessArtifact(
      tester,
      'reader-epub-canonical-page-1280-en',
      metadata: <String, Object?>{
        ...view.toMetadata(),
        'state': 'dart-page',
        'content': 'br join, collapsed cells, cell display math',
        'paintedBlocks': texts,
        'defects': defects.map((defect) => defect.toMetadata()).toList(),
      },
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('the Contents panel serves the NCX, not the nav (EN, wide)', (
    tester,
  ) async {
    final harness = bridge();
    final view = const HarnessView(size: Size(1280, 800));
    view.apply(tester);
    await renderHarnessState(
      tester,
      reader(harness),
      ready: () => harnessReaderPageReady(tester),
    );
    await openContents(tester);

    expect(find.text('NCX One'), findsOneWidget);
    expect(find.text('NCX Two'), findsOneWidget);
    expect(
      find.text('Nav One'),
      findsNothing,
      reason: 'the nav document loses to the NCX',
    );

    // Activating the NCX row navigates to the verified cell anchor through the
    // guarded layout path, not to an unverified position.
    await tester.tap(find.text('NCX Two'));
    for (var round = 0; round < 6; round += 1) {
      await pumpHarnessFrames(tester, frames: 4);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 120)),
      );
    }
    expect(harness.savedReadingStates, isNotEmpty);
    expect(
      harness.savedReadingStates.last.unit.toInt(),
      0,
      reason: 'the NCX target is in the first chapter',
    );
    expect(
      harness.savedReadingStates.last.offset?.toInt(),
      retainedAnchors['cell-anchor'],
      reason:
          'the durable offset is the retained literal, not the engine output',
    );

    final defects = await findRenderDefects(tester);
    await captureHarnessArtifact(
      tester,
      'reader-epub-canonical-contents-1280-en',
      metadata: <String, Object?>{
        ...view.toMetadata(),
        'state': 'contents-open',
        'panel': 'contents',
        'entries': 'NCX wins over a disagreeing nav document',
        'defects': defects.map((defect) => defect.toMetadata()).toList(),
      },
    );
  });
}
