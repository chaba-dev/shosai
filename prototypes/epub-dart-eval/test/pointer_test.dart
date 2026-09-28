/// Pointer-level evidence: hit testing through the rendered surface.
///
/// These tests dispatch real pointer events at positions computed from the
/// painted layout (caret geometry), so they exercise the same transform chain
/// the reader uses: surface coordinates → page/flow coordinates → painter
/// coordinates → canonical scalar.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_epub_eval/reader/controller.dart';
import 'package:shosai_epub_eval/reader/effects.dart';
import 'package:shosai_epub_eval/reader/layout/pages.dart';
import 'package:shosai_epub_eval/reader/message.dart';
import 'package:shosai_epub_eval/reader/model.dart';
import 'package:shosai_epub_eval/reader/view.dart';

import 'support/fonts.dart';

class _FixtureSource implements EpubDocumentSource {
  _FixtureSource(this.path);

  final String path;

  @override
  Future<Uint8List> read(String documentPath) async =>
      Uint8List.fromList(File(path).readAsBytesSync());
}

Future<EpubReaderController> _open(
  WidgetTester tester,
  GlobalKey documentKey, {
  Size size = const Size(900, 700),
  EpubReaderMode mode = EpubReaderMode.paginated,
}) async {
  final fallbacks = await loadPrototypeFonts(tester);
  final path = File('fixtures/rich-chapter.epub').existsSync()
      ? 'fixtures/rich-chapter.epub'
      : '../../crates/shosai-core/tests/fixtures/epub-conformance/bionic.epub';
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
    for (var attempt = 0; attempt < 300; attempt++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (controller.model.paginated == null &&
          !controller.model.relayoutBusy &&
          !controller.model.relayoutPending) {
        break;
      }
    }
  }
  return controller;
}

/// Global position of a canonical scalar inside a paginated page.
Offset _globalPositionOfScalar(
  WidgetTester tester,
  GlobalKey documentKey,
  EpubReaderController controller,
  int scalar,
) {
  final geometry = controller.model.geometry!;
  final paginated = controller.model.paginated!;
  final pageIndex = paginated.pageOfCanonical(scalar);
  final page = paginated.pages[pageIndex];
  for (final slice in page.slices) {
    if (slice is! TextPageSlice) continue;
    if (scalar < slice.canonicalStart || scalar > slice.canonicalEnd) continue;
    final text = slice.block.text!;
    final line = text.lines.firstWhere(
      (entry) => scalar >= entry.canonicalStart && scalar <= entry.canonicalEnd,
      orElse: () => text.lines[slice.lineStart],
    );
    final codeUnit = text.map.codeUnitAt(scalar);
    final caret = text.painter.getOffsetForCaret(
      TextPosition(offset: codeUnit),
      Rect.zero,
    );
    final localY =
        slice.top +
        (caret.dy - text.lines[slice.lineStart].top) +
        line.height / 2;
    final localX = caret.dx + 2;
    final column = pageIndex % geometry.columns;
    final gutter = geometry.columns == 2 ? 20.0 : 0.0;
    final origin = tester.getTopLeft(find.byKey(documentKey));
    return origin +
        Offset(column * (geometry.pageWidth + gutter) + localX, localY);
  }
  fail('scalar $scalar is not placed on any page');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a drag over painted glyphs selects those glyphs', (
    tester,
  ) async {
    final documentKey = GlobalKey(debugLabel: 'pointer-document');
    final controller = await _open(tester, documentKey);
    final chapter = controller.model.chapter!;
    final flow = controller.model.flow!;
    final block = flow.blocks.firstWhere(
      (entry) => entry.text?.map.text.contains('paragraph mixes') ?? false,
    );
    final text = block.text!;
    final firstLine = text.lines.first;
    final startScalar = firstLine.canonicalStart + 4;
    final endScalar = firstLine.canonicalEnd - 4;
    expect(endScalar, greaterThan(startScalar));

    final start = _globalPositionOfScalar(
      tester,
      documentKey,
      controller,
      startScalar,
    );
    final end = _globalPositionOfScalar(
      tester,
      documentKey,
      controller,
      endScalar,
    );
    final gesture = await tester.startGesture(start);
    await tester.pump(const Duration(milliseconds: 20));
    await gesture.moveTo(end);
    await tester.pump(const Duration(milliseconds: 20));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 20));

    final selection = controller.model.selection;
    expect(selection, isNotNull);
    expect(selection!.start, greaterThanOrEqualTo(firstLine.canonicalStart));
    expect(selection.end, lessThanOrEqualTo(firstLine.canonicalEnd));
    expect(
      selection.start,
      lessThanOrEqualTo(startScalar),
      reason: 'the selection must start at or before the pressed glyph',
    );
    expect(
      selection.end,
      greaterThanOrEqualTo(endScalar - 1),
      reason: 'the selection must reach the released glyph',
    );
    expect(chapter.canonicalText.runes.length, greaterThan(selection.end));
    controller.dispose();
  });

  testWidgets('tapping a painted link navigates to its anchor', (tester) async {
    final documentKey = GlobalKey(debugLabel: 'pointer-document');
    final controller = await _open(tester, documentKey);
    final chapter = controller.model.chapter!;
    final flow = controller.model.flow!;
    final linkBlock = flow.blocks.firstWhere(
      (entry) => entry.text!.links.isNotEmpty,
    );
    final link = linkBlock.text!.links.first;
    // Position the tap on the link's own glyphs.
    final text = linkBlock.text!;
    final line = text.lines.firstWhere(
      (entry) =>
          link.start >= entry.codeUnitStart && link.start <= entry.codeUnitEnd,
      orElse: () => text.lines.first,
    );
    final caret = text.painter.getOffsetForCaret(
      TextPosition(offset: link.start + 1),
      Rect.zero,
    );
    final geometry = controller.model.geometry!;
    final paginated = controller.model.paginated!;
    final pageIndex = paginated.pageOfCanonical(text.map.canonicalStart);
    final page = paginated.pages[pageIndex];
    final slice = page.slices.whereType<TextPageSlice>().firstWhere(
      (entry) => entry.block == linkBlock,
    );
    final localY =
        slice.top +
        (caret.dy - text.lines[slice.lineStart].top) +
        line.height / 2;
    final column = pageIndex % geometry.columns;
    final gutter = geometry.columns == 2 ? 20.0 : 0.0;
    final origin = tester.getTopLeft(find.byKey(documentKey));
    final global =
        origin +
        Offset(column * (geometry.pageWidth + gutter) + caret.dx + 2, localY);

    final tablesAnchor = chapter.anchors['tables'];
    expect(tablesAnchor, isNotNull);
    expect(link.href, '#tables');
    await tester.tapAt(global);
    await tester.pump(const Duration(milliseconds: 20));
    expect(controller.model.scalar, tablesAnchor);
    controller.dispose();
  });

  testWidgets('continuous-mode hit testing accounts for the centred column', (
    tester,
  ) async {
    final documentKey = GlobalKey(debugLabel: 'pointer-document');
    final controller = await _open(
      tester,
      documentKey,
      size: const Size(1200, 700),
      mode: EpubReaderMode.continuous,
    );
    final flow = controller.model.flow!;
    // The column is narrower than the viewport, so a pointer in the left margin
    // must still resolve to the nearest text, and a pointer inside the column
    // must resolve to the glyph under it.
    final block = flow.blocks.firstWhere((entry) => entry.text != null);
    final text = block.text!;
    final line = text.lines.first;
    final scalar = (line.canonicalStart + line.canonicalEnd) ~/ 2;
    final codeUnit = text.map.codeUnitAt(scalar);
    final caret = text.painter.getOffsetForCaret(
      TextPosition(offset: codeUnit),
      Rect.zero,
    );
    final geometry = controller.model.geometry!;
    final gutter = (geometry.viewportWidth - flow.width) / 2;
    expect(gutter, greaterThan(0), reason: 'the column must be centred');
    final origin = tester.getTopLeft(find.byKey(documentKey));
    final global =
        origin +
        Offset(
          gutter + caret.dx + 2,
          block.top -
              controller.model.continuousOffset +
              caret.dy +
              line.height / 2,
        );
    final gesture = await tester.startGesture(global);
    await tester.pump(const Duration(milliseconds: 20));
    await gesture.moveBy(const Offset(40, 0));
    await tester.pump(const Duration(milliseconds: 20));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 20));
    final selection = controller.model.selection;
    expect(selection, isNotNull);
    expect(selection!.start, greaterThanOrEqualTo(line.canonicalStart));
    expect(selection.start, lessThanOrEqualTo(scalar + 4));
    controller.dispose();
  });

  testWidgets('a chapter-end position survives a continuous-mode relayout', (
    tester,
  ) async {
    // The scroll surface must not report its own extent correction as user
    // navigation: a chapter-end position in continuous mode maps to the last
    // screenful, and a relayout must not move it.
    final documentKey = GlobalKey(debugLabel: 'pointer-document');
    final fallbacks = await loadPrototypeFonts(tester);
    final path = File('fixtures/rich-chapter.epub').existsSync()
        ? 'fixtures/rich-chapter.epub'
        : '../../crates/shosai-core/tests/fixtures/epub-conformance/bidi.epub';
    final store = EpubMemoryPositionStore();
    final controller = EpubReaderController(
      source: _FixtureSource(path),
      positionStore: store,
      contentFallbackFamilies: fallbacks,
    );
    await tester.binding.setSurfaceSize(const Size(900, 700));
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
    controller.dispatch(const EpubReaderModeChanged(EpubReaderMode.continuous));
    for (var attempt = 0; attempt < 300; attempt++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (controller.model.paginated == null &&
          !controller.model.relayoutBusy &&
          !controller.model.relayoutPending) {
        break;
      }
    }
    final end = controller.model.chapter!.scalarCount;
    controller.dispatch(EpubReaderScalarJumpRequested(spine: 0, scalar: end));
    for (var attempt = 0; attempt < 400; attempt++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (!controller.model.relayoutBusy &&
          !controller.model.relayoutPending &&
          controller.model.scalar == end) {
        break;
      }
    }
    expect(controller.model.scalar, end);

    // A typography relayout while the scroll surface is attached.
    controller.dispatch(const EpubReaderFontSizeChanged(2));
    for (var attempt = 0; attempt < 400; attempt++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (!controller.model.relayoutBusy &&
          !controller.model.relayoutPending &&
          controller.model.typography.fontSize == 20) {
        break;
      }
    }
    // Let any ballistic scroll correction settle.
    for (var attempt = 0; attempt < 60; attempt++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(
      controller.model.scalar,
      end,
      reason: 'a layout-driven scroll correction must not move the position',
    );
    final stored = await store.read(path);
    expect(stored?.scalar, end);
    controller.dispose();
  });
}
