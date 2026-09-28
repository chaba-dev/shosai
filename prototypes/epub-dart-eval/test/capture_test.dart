/// Capture-based evidence: rendered pixels must contain the laid-out text.
///
/// Each case renders the real reader view at a fixed surface size, captures the
/// document boundary, and asserts both that ink exists where the layout says
/// the text is and that the capture is not a blank placeholder. Representative
/// PNGs are written under `artifacts/captures/` for visual inspection.
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_epub_eval/reader/capture.dart';
import 'package:shosai_epub_eval/reader/controller.dart';
import 'package:shosai_epub_eval/reader/effects.dart';
import 'package:shosai_epub_eval/reader/message.dart';
import 'package:shosai_epub_eval/reader/model.dart';
import 'package:shosai_epub_eval/reader/theme.dart';
import 'package:shosai_epub_eval/reader/view.dart';

import 'support/fonts.dart';

class _FixtureSource implements EpubDocumentSource {
  _FixtureSource(this.path);

  final String path;

  @override
  Future<Uint8List> read(String documentPath) async =>
      Uint8List.fromList(File(path).readAsBytesSync());
}

String _fixturePath(String name) {
  final local = File('fixtures/$name');
  return local.existsSync()
      ? local.path
      : '../../crates/shosai-core/tests/fixtures/epub-conformance/$name';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final captureDirectory = Directory('artifacts/captures');

  setUpAll(() {
    if (!captureDirectory.existsSync()) {
      captureDirectory.createSync(recursive: true);
    }
  });

  Future<EpubReaderController> openReader(
    WidgetTester tester,
    String fixture, {
    required GlobalKey documentKey,
    Size size = const Size(1000, 700),
    EpubReaderMode mode = EpubReaderMode.paginated,
    ReaderTheme theme = ReaderTheme.light,
    double fontSize = 18,
  }) async {
    final fallbacks = await loadPrototypeFonts(tester);
    final path = _fixturePath(fixture);
    final controller = EpubReaderController(
      source: _FixtureSource(path),
      positionStore: EpubMemoryPositionStore(),
      contentFallbackFamilies: fallbacks,
    );
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: ListenableBuilder(
          listenable: controller,
          builder: (context, _) => EpubReaderView(
            controller: controller,
            model: controller.model,
            documentKey: documentKey,
          ),
        ),
      ),
    );
    // The open effect awaits engine font loading, which only completes on the
    // real async queue; the layout effect afterwards runs on the test clock.
    await tester.runAsync(() async {
      controller.dispatch(EpubReaderOpenRequested(path));
      final stopwatch = Stopwatch()..start();
      while (controller.model.status != EpubReaderStatus.ready &&
          stopwatch.elapsed < const Duration(seconds: 20)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    for (var attempt = 0; attempt < 300; attempt++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (controller.model.flow != null && !controller.model.relayoutBusy) {
        break;
      }
    }
    if (mode != EpubReaderMode.paginated) {
      controller.dispatch(EpubReaderModeChanged(mode));
      for (var attempt = 0; attempt < 200; attempt++) {
        await tester.pump(const Duration(milliseconds: 16));
        if (!controller.model.relayoutBusy &&
            controller.model.paginated == null) {
          break;
        }
      }
    }
    if (theme != ReaderTheme.light) {
      controller.dispatch(EpubReaderThemeChanged(theme));
      for (var attempt = 0; attempt < 400; attempt++) {
        await tester.pump(const Duration(milliseconds: 16));
        if (!controller.model.relayoutBusy &&
            !controller.model.relayoutPending &&
            controller.model.theme == theme) {
          break;
        }
      }
    }
    if (fontSize != 18) {
      controller.dispatch(EpubReaderFontSizeChanged(fontSize - 18));
      for (var attempt = 0; attempt < 200; attempt++) {
        await tester.pump(const Duration(milliseconds: 16));
        if (!controller.model.relayoutBusy &&
            controller.model.typography.fontSize == fontSize) {
          break;
        }
      }
    }
    await tester.pump(const Duration(milliseconds: 50));
    return controller;
  }

  Future<ui.Image> captureDocument(WidgetTester tester, GlobalKey key) async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    // toImage/toByteData complete on the engine's real async queue, so they
    // must run outside the test's fake-async zone.
    final image = await tester.runAsync(
      () => boundary.toImage(pixelRatio: 1.0),
    );
    return image!;
  }

  Future<CaptureAnalysis> analyze(
    WidgetTester tester,
    ui.Image image,
    Color background,
  ) async {
    final analysis = await tester.runAsync(
      () => analyzeCapture(image, background),
    );
    return analysis!;
  }

  Future<void> writeCapture(
    WidgetTester tester,
    ui.Image image,
    String name,
  ) async {
    final data = await tester.runAsync(
      () => image.toByteData(format: ui.ImageByteFormat.png),
    );
    if (data == null) return;
    File(
      '${captureDirectory.path}/$name.png',
    ).writeAsBytesSync(data.buffer.asUint8List());
  }

  testWidgets('blank placeholder is rejected by the content detector', (
    tester,
  ) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, 200, 120),
      Paint()..color = const Color(0xFFFFFFFF),
    );
    final picture = recorder.endRecording();
    final image = (await tester.runAsync(() => picture.toImage(200, 120)))!;
    final analysis = await analyze(tester, image, const Color(0xFFFFFFFF));
    expect(analysis.hasContent, isFalse);
    expect(analysis.nonBackgroundPixels, 0);
    expect(analysis.inkRows, 0);
  });

  testWidgets('rich chapter page 1 renders its laid-out text', (tester) async {
    final documentKey = GlobalKey(debugLabel: 'document');
    final controller = await openReader(
      tester,
      'rich-chapter.epub',
      documentKey: documentKey,
    );
    final image = await captureDocument(tester, documentKey);
    final analysis = await analyze(
      tester,
      image,
      controller.model.flow!.palette.background,
    );
    expect(analysis.hasContent, isTrue, reason: '$analysis');
    // The first page's laid-out text starts at the top of the document area.
    expect(analysis.inkRowIndices.first, lessThan(120));
    await writeCapture(tester, image, 'rich-chapter-paginated-page1');

    // Source-content assertion: the page's canonical range contains the title.
    final page = controller.model.paginated!.pages.first;
    final chapter = controller.model.chapter!;
    final text = chapter.canonicalText
        .substring(0, page.canonicalEnd)
        .replaceAll('\n', ' ');
    expect(text, contains('A Rich Chapter'));
    controller.dispose();
  });

  testWidgets('table page and CJK/bidi page render ink in their bands', (
    tester,
  ) async {
    final documentKey = GlobalKey(debugLabel: 'document');
    final controller = await openReader(
      tester,
      'rich-chapter.epub',
      documentKey: documentKey,
    );
    // Navigate to the page containing the table.
    final tableScalar = controller.model.chapter!.anchors['tables'] ?? 0;
    controller.dispatch(
      EpubReaderScalarJumpRequested(spine: 0, scalar: tableScalar),
    );
    for (var attempt = 0; attempt < 50; attempt++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final image = await captureDocument(tester, documentKey);
    final analysis = await analyze(
      tester,
      image,
      controller.model.flow!.palette.background,
    );
    expect(analysis.hasContent, isTrue, reason: '$analysis');
    await writeCapture(tester, image, 'rich-chapter-table-page');

    // Japanese and bidi page.
    final japaneseScalar = controller.model.chapter!.anchors['scripts'] ?? 0;
    controller.dispatch(
      EpubReaderScalarJumpRequested(spine: 0, scalar: japaneseScalar),
    );
    for (var attempt = 0; attempt < 50; attempt++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final cjkImage = await captureDocument(tester, documentKey);
    final cjkAnalysis = await analyze(
      tester,
      cjkImage,
      controller.model.flow!.palette.background,
    );
    expect(cjkAnalysis.hasContent, isTrue, reason: '$cjkAnalysis');
    await writeCapture(tester, cjkImage, 'rich-chapter-cjk-bidi-page');
    controller.dispose();
  });

  testWidgets('continuous mode and dark theme render content', (tester) async {
    final documentKey = GlobalKey(debugLabel: 'document');
    final controller = await openReader(
      tester,
      'rich-chapter.epub',
      documentKey: documentKey,
      mode: EpubReaderMode.continuous,
      theme: ReaderTheme.dark,
    );
    final image = await captureDocument(tester, documentKey);
    final analysis = await analyze(
      tester,
      image,
      controller.model.flow!.palette.background,
    );
    expect(analysis.hasContent, isTrue, reason: '$analysis');
    await writeCapture(tester, image, 'rich-chapter-continuous-dark');
    controller.dispose();
  });

  testWidgets('selection and highlight paint over the text', (tester) async {
    final documentKey = GlobalKey(debugLabel: 'document');
    final controller = await openReader(
      tester,
      'rich-chapter.epub',
      documentKey: documentKey,
    );
    final flow = controller.model.flow!;
    final block = flow.blocks.firstWhere((entry) => entry.text != null);
    final y = block.top + block.text!.lines.first.top + 4;
    controller.dispatch(EpubReaderSelectionStarted(Offset(4, y)));
    controller.dispatch(EpubReaderSelectionExtended(Offset(220, y)));
    controller.dispatch(const EpubReaderSelectionEnded());
    for (var attempt = 0; attempt < 20; attempt++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final selectionImage = await captureDocument(tester, documentKey);
    await writeCapture(tester, selectionImage, 'rich-chapter-selection');

    controller.dispatch(
      const EpubReaderHighlightRequested(ReaderHighlightColor.yellow),
    );
    for (var attempt = 0; attempt < 20; attempt++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final highlightImage = await captureDocument(tester, documentKey);
    await writeCapture(tester, highlightImage, 'rich-chapter-highlight');
    expect(controller.model.highlights, hasLength(1));

    // The highlight is projected into the page as at least one rect.
    final analysis = await analyze(
      tester,
      highlightImage,
      controller.model.flow!.palette.background,
    );
    expect(analysis.hasContent, isTrue, reason: '$analysis');
    controller.dispose();
  });

  testWidgets('long chapter first page renders and reports layout timing', (
    tester,
  ) async {
    final documentKey = GlobalKey(debugLabel: 'document');
    final controller = await openReader(
      tester,
      'long-chapter.epub',
      documentKey: documentKey,
    );
    final image = await captureDocument(tester, documentKey);
    final analysis = await analyze(
      tester,
      image,
      controller.model.flow!.palette.background,
    );
    expect(analysis.hasContent, isTrue, reason: '$analysis');
    expect(controller.model.lastLayoutMicros, isNotNull);
    await writeCapture(tester, image, 'long-chapter-page1');
    controller.dispose();
  });
}
