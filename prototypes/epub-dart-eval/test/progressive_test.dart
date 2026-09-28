/// Progressive layout evidence: visible-location-first installs, bounded
/// batches, cancellation, reuse and the indivisible huge-paragraph case.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/painting.dart' show InlineSpan, TextSpan;
import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_epub_eval/reader/controller.dart';
import 'package:shosai_epub_eval/reader/effects.dart';
import 'package:shosai_epub_eval/reader/geometry.dart';
import 'package:shosai_epub_eval/reader/layout/cache.dart';
import 'package:shosai_epub_eval/reader/layout/flow.dart';
import 'package:shosai_epub_eval/reader/message.dart';
import 'package:shosai_epub_eval/reader/model.dart';

class _FixtureSource implements EpubDocumentSource {
  _FixtureSource(this.path);

  final String path;

  @override
  Future<Uint8List> read(String documentPath) async =>
      Uint8List.fromList(File(path).readAsBytesSync());
}

/// Reads whatever document the controller asks for (the fixture helper above
/// always returns the file it was constructed with, which is fine for one book
/// but not for opening a second document on the same controller).
class _PathSource implements EpubDocumentSource {
  const _PathSource();

  @override
  Future<Uint8List> read(String documentPath) async =>
      Uint8List.fromList(File(documentPath).readAsBytesSync());
}

String _fixturePath(String name) {
  final local = File('fixtures/$name');
  return local.existsSync()
      ? local.path
      : '../../crates/shosai-core/tests/fixtures/epub-conformance/$name';
}

Future<void> _waitUntil(
  FutureOr<bool> Function() condition, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final stopwatch = Stopwatch()..start();
  while (!await condition()) {
    if (stopwatch.elapsed > timeout) {
      fail('condition was not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

EpubReaderController _open(
  String fixture, {
  EpubLayoutCache? cache,
  EpubMemoryPositionStore? store,
}) {
  final path = _fixturePath(fixture);
  final controller = EpubReaderController(
    source: _FixtureSource(path),
    positionStore: store ?? EpubMemoryPositionStore(),
    layoutStrategy: EpubLayoutStrategy.progressive,
    layoutCache: cache,
  );
  controller.dispatch(EpubReaderOpenRequested(path));
  controller.dispatch(const EpubReaderViewportChanged(900, 700));
  return controller;
}

/// Multiset of canonical scalars a flow renders, derived from the flow itself.
Map<int, int> _flowCoverage(ChapterFlow flow) {
  final counts = <int, int>{};
  void addRange(int start, int end) {
    for (var scalar = start; scalar < end; scalar++) {
      counts[scalar] = (counts[scalar] ?? 0) + 1;
    }
  }

  for (final block in flow.blocks) {
    final text = block.text;
    if (text != null) {
      for (final line in text.lines) {
        addRange(line.canonicalStart, line.canonicalEnd);
      }
      continue;
    }
    final table = block.table;
    if (table != null) {
      final caption = table.caption;
      if (caption != null) {
        addRange(caption.map.canonicalStart, caption.map.canonicalEnd);
      }
      for (final row in table.rows) {
        for (final cell in row.cells) {
          for (final cellBlock in cell.blocks) {
            for (final line in cellBlock.lines) {
              addRange(line.canonicalStart, line.canonicalEnd);
            }
          }
        }
      }
      continue;
    }
    final image = block.image;
    if (image != null) {
      if (image.fallbackText != null) {
        addRange(
          image.canonicalStart,
          image.canonicalStart + image.alt.runes.length,
        );
      }
      final caption = image.caption;
      if (caption != null) {
        addRange(caption.map.canonicalStart, caption.map.canonicalEnd);
      }
      continue;
    }
    addRange(block.canonicalStart, block.canonicalEnd);
  }
  return counts;
}

/// The eager baseline flow for the same chapter, geometry and typography.
ChapterFlow _eagerFlow(EpubReaderController controller) {
  final model = controller.model;
  final chapter = model.chapter!;
  return layoutChapterFlow(
    chapter: chapter,
    spec: ChapterLayoutSpec(
      width: model.geometry!.contentWidth,
      height: model.geometry!.contentHeight,
      typography: model.typography,
    ),
    images: model.images,
    imageMediaTypes: {
      for (final resource in model.book!.resources.values)
        resource.path: resource.mediaType,
    },
  );
}

void expectSameCoverage(
  Map<int, int> actual,
  Map<int, int> expected,
  String reason,
) {
  for (final entry in expected.entries) {
    expect(
      actual[entry.key] ?? 0,
      entry.value,
      reason: '$reason: scalar ${entry.key}',
    );
  }
  for (final entry in actual.entries) {
    expect(
      expected[entry.key] ?? 0,
      entry.value,
      reason: '$reason: scalar ${entry.key} unexpected',
    );
  }
}

double? _firstFontSize(InlineSpan? span) {
  if (span is! TextSpan) return null;
  final size = span.style?.fontSize;
  if (size != null) return size;
  for (final child in span.children ?? const <InlineSpan>[]) {
    final nested = _firstFontSize(child);
    if (nested != null) return nested;
  }
  return null;
}

/// The font size the first laid-out text block was measured with.
double? _firstTextLeafSize(ChapterFlow flow) {
  for (final block in flow.blocks) {
    final text = block.text;
    if (text == null) continue;
    final size = _firstFontSize(text.painter.text);
    if (size != null) return size;
  }
  return null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'the durable location is usable before the chapter is complete',
    () async {
      final controller = _open('long-chapter.epub');
      await _waitUntil(() => controller.model.book != null);
      final firstUsable = Completer<EpubReaderModel>();
      final complete = Completer<EpubReaderModel>();
      controller.addListener(() {
        final model = controller.model;
        if (model.flow != null &&
            !model.relayoutBusy &&
            !model.relayoutPending) {
          if (!firstUsable.isCompleted) firstUsable.complete(model);
          if (model.layoutComplete && !complete.isCompleted) {
            complete.complete(model);
          }
        }
      });
      controller.dispatch(
        const EpubReaderScalarJumpRequested(spine: 1, scalar: 0),
      );
      final usable = await firstUsable.future.timeout(
        const Duration(seconds: 20),
      );
      // The first install is a window: it renders the location but does not
      // claim the chapter's totals.
      expect(usable.spine, 1);
      expect(usable.layoutComplete, isFalse);
      expect(usable.flow!.blocks, isNotEmpty);
      expect(usable.flow!.nodeCount, greaterThan(usable.flow!.blocks.length));

      final settled = await complete.future.timeout(
        const Duration(seconds: 30),
      );
      expect(settled.layoutComplete, isTrue);
      expect(settled.flow!.firstNodeIndex, 0);
      expect(
        settled.flow!.blocks.length,
        greaterThan(usable.flow!.blocks.length),
      );
      controller.dispose();
    },
  );

  test(
    'a distant position installs a window and completes to the eager layout',
    () async {
      final controller = _open('long-chapter.epub');
      await _waitUntil(() => controller.model.flow != null);
      final chapter = controller.model.book!.chapters[1];
      final target = (chapter.scalarCount * 0.85).round();

      final firstUsable = Completer<EpubReaderModel>();
      controller.addListener(() {
        final model = controller.model;
        if (model.flow != null &&
            !model.relayoutBusy &&
            !model.relayoutPending) {
          if (!firstUsable.isCompleted) firstUsable.complete(model);
        }
      });
      controller.dispatch(
        EpubReaderScalarJumpRequested(spine: 1, scalar: target),
      );
      final usable = await firstUsable.future.timeout(
        const Duration(seconds: 20),
      );
      expect(usable.spine, 1);
      expect(usable.layoutComplete, isFalse);
      // The window contains the requested location, not the chapter start.
      expect(usable.flow!.firstNodeIndex, greaterThan(0));
      expect(usable.flow!.covers(target), isTrue);
      expect(usable.scalar, target);

      await _waitUntil(
        () => controller.model.layoutComplete && !controller.model.relayoutBusy,
      );
      final progressive = controller.model.flow!;
      final eager = _eagerFlow(controller);
      expect(progressive.blocks.length, eager.blocks.length);
      expect(progressive.height, closeTo(eager.height, 0.5));
      expect(progressive.firstNodeIndex, 0);
      for (var index = 0; index < eager.blocks.length; index++) {
        expect(
          progressive.blocks[index].canonicalStart,
          eager.blocks[index].canonicalStart,
          reason: 'block $index canonical start',
        );
        expect(
          progressive.blocks[index].canonicalEnd,
          eager.blocks[index].canonicalEnd,
          reason: 'block $index canonical end',
        );
      }
      expectSameCoverage(
        _flowCoverage(progressive),
        _flowCoverage(eager),
        'progressive vs eager',
      );
      // The durable position survives completion.
      expect(controller.model.scalar, target);
      controller.dispose();
    },
  );

  test(
    'continuous mode places a distant position without measuring the chapter',
    () async {
      final controller = _open('long-chapter.epub');
      await _waitUntil(() => controller.model.flow != null);
      controller.dispatch(
        const EpubReaderModeChanged(EpubReaderMode.continuous),
      );
      await _waitUntil(
        () =>
            controller.model.paginated == null &&
            !controller.model.relayoutBusy,
      );
      final chapter = controller.model.book!.chapters[1];
      final target = (chapter.scalarCount * 0.8).round();
      controller.dispatch(
        EpubReaderScalarJumpRequested(spine: 1, scalar: target),
      );
      await _waitUntil(
        () =>
            controller.model.spine == 1 &&
            controller.model.flow != null &&
            !controller.model.relayoutBusy &&
            !controller.model.relayoutPending,
      );
      final model = controller.model;
      expect(model.flow!.covers(target), isTrue);
      expect(model.scalar, target);
      // The scroll offset points at the target's line, not at the chapter start.
      expect(model.continuousOffset, greaterThan(0));
      final hit = hitTestFlow(
        flow: model.flow!,
        local: Offset(0, model.continuousOffset + 1),
      );
      expect(hit.scalar, lessThanOrEqualTo(target));
      expect(hit.scalar, greaterThanOrEqualTo(target - 2000));
      controller.dispose();
    },
  );

  test(
    'navigation extends the laid-out range in the requested direction',
    () async {
      final controller = _open('long-chapter.epub');
      await _waitUntil(() => controller.model.flow != null);
      final chapter = controller.model.book!.chapters[1];
      final target = (chapter.scalarCount * 0.6).round();
      controller.dispatch(
        EpubReaderScalarJumpRequested(spine: 1, scalar: target),
      );
      await _waitUntil(
        () =>
            controller.model.spine == 1 &&
            controller.model.flow != null &&
            !controller.model.relayoutBusy &&
            !controller.model.relayoutPending,
      );
      final startScalar = controller.model.scalar;
      final startBlocks = controller.model.flow!.blocks.length;

      // Backward: the window starts at the target, so a previous-page request
      // must measure earlier content before it can move.
      controller.dispatch(const EpubReaderUnitRequested(-1));
      await _waitUntil(
        () =>
            controller.model.scalar < startScalar ||
            controller.model.flow!.blocks.length > startBlocks,
      );
      await _waitUntil(
        () =>
            !controller.model.relayoutBusy && !controller.model.relayoutPending,
      );
      expect(
        controller.model.scalar,
        lessThan(startScalar),
        reason: 'a previous-page request must move the durable position back',
      );
      expect(
        controller.model.flow!.firstNodeIndex,
        lessThan(controller.model.flow!.nodeCount),
      );
      controller.dispose();
    },
  );

  test(
    'rapid font-size changes cancel superseded layouts and reuse cached work',
    () async {
      final cache = EpubLayoutCache(maxEntries: 2);
      final controller = _open('long-chapter.epub', cache: cache);
      await _waitUntil(() => controller.model.flow != null);
      controller.dispatch(
        const EpubReaderScalarJumpRequested(spine: 1, scalar: 0),
      );
      await _waitUntil(
        () => controller.model.spine == 1 && !controller.model.relayoutBusy,
      );
      final settle = <EpubReaderModel>[];
      controller.addListener(() => settle.add(controller.model));

      // A burst: +2, +2, -2, -2 returns to the starting typography, so the
      // original session is reusable.
      for (final delta in [2.0, 2.0, -2.0, -2.0]) {
        controller.dispatch(EpubReaderFontSizeChanged(delta));
        // Longer than the 80 ms coalescing delay, shorter than the chapter's
        // full measurement: each intent starts a layout and is then superseded.
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
      await _waitUntil(
        () =>
            controller.model.layoutComplete &&
            !controller.model.relayoutBusy &&
            !controller.model.relayoutPending,
      );
      expect(controller.model.typography.fontSize, 18);
      // No settled state may carry a layout measured for a different
      // typography: compare each settled layout's measured leaf size against
      // the final one, scaled by the typography the state reports.
      final settled = settle
          .where(
            (state) =>
                !state.relayoutBusy &&
                !state.relayoutPending &&
                state.flow != null,
          )
          .toList();
      expect(settled, isNotEmpty);
      final reference = _firstTextLeafSize(settled.last.flow!)!;
      final referenceFontSize = settled.last.typography.fontSize;
      for (final state in settled) {
        expect(
          _firstTextLeafSize(state.flow!),
          reference * state.typography.fontSize / referenceFontSize,
          reason: 'a superseded intent installed its layout',
        );
      }
      expect(
        cache.hits,
        greaterThan(0),
        reason: 'the burst must reuse measured blocks',
      );
      expect(cache.evictions, greaterThan(0));
      controller.dispose();
    },
  );

  test('a resize burst reuses a previously measured flow', () async {
    final cache = EpubLayoutCache(maxEntries: 2);
    final controller = _open('long-chapter.epub', cache: cache);
    await _waitUntil(
      () =>
          controller.model.flow != null &&
          controller.model.layoutComplete &&
          !controller.model.relayoutBusy,
    );
    controller.dispatch(
      const EpubReaderScalarJumpRequested(spine: 1, scalar: 0),
    );
    await _waitUntil(
      () =>
          controller.model.spine == 1 &&
          controller.model.layoutComplete &&
          !controller.model.relayoutBusy,
    );
    final hitsBefore = cache.hits;
    // A burst that returns to the starting width: the last request can reuse
    // the first one's measured blocks.
    controller.dispatch(const EpubReaderViewportChanged(820, 700));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    controller.dispatch(const EpubReaderViewportChanged(900, 700));
    await _waitUntil(
      () => controller.model.layoutComplete && !controller.model.relayoutBusy,
    );
    expect(
      cache.hits,
      greaterThan(hitsBefore),
      reason: 'the returned-to size must reuse its measured flow',
    );
    controller.dispose();
  });

  test('a huge paragraph is the indivisible unit of layout work', () async {
    final controller = _open('huge-paragraph.epub');
    await _waitUntil(() => controller.model.book != null);
    final firstUsable = Completer<EpubReaderModel>();
    controller.addListener(() {
      final model = controller.model;
      if (model.flow != null && !model.relayoutBusy && !model.relayoutPending) {
        if (!firstUsable.isCompleted) {
          firstUsable.complete(model);
        }
      }
    });
    final chapter = controller.model.book!.chapters[0];
    // Aim at the middle of the huge paragraph.
    final paragraph = chapter.blocks[1];
    final middle =
        paragraph.canonical!.start +
        (paragraph.canonical!.end - paragraph.canonical!.start) ~/ 2;
    controller.dispatch(
      EpubReaderScalarJumpRequested(spine: 0, scalar: middle),
    );
    final usable = await firstUsable.future.timeout(
      const Duration(seconds: 60),
    );
    // The window contains the whole paragraph as one block: a single
    // TextPainter.layout() measures it, so batching cannot bound this step.
    final huge = usable.flow!.blocks.firstWhere(
      (block) => block.canonicalEnd - block.canonicalStart > 100000,
    );
    expect(huge.canonicalStart, paragraph.canonical!.start);
    expect(huge.canonicalEnd, paragraph.canonical!.end);
    expect(usable.flow!.covers(middle), isTrue);
    // The tail node is not measured yet: the first install is still a window.
    expect(usable.layoutComplete, isFalse);
    expect(usable.flow!.blocks.length, lessThan(chapter.blocks.length));

    await _waitUntil(
      () => controller.model.layoutComplete && !controller.model.relayoutBusy,
      timeout: const Duration(seconds: 60),
    );
    expect(controller.model.flow!.blocks.length, chapter.blocks.length);
    controller.dispose();
  });

  test('the layout cache is scoped to one document', () async {
    // Two books can share internal resource paths (`OEBPS/Text/chapter-1.xhtml`
    // here) with different content. A cache keyed only by those paths would
    // install the first book's measured blocks under the second book.
    final cache = EpubLayoutCache(maxEntries: 2);
    final controller = EpubReaderController(
      source: const _PathSource(),
      positionStore: EpubMemoryPositionStore(),
      layoutStrategy: EpubLayoutStrategy.progressive,
      layoutCache: cache,
    );
    controller.dispatch(
      EpubReaderOpenRequested(_fixturePath('long-chapter.epub')),
    );
    controller.dispatch(const EpubReaderViewportChanged(900, 700));
    await _waitUntil(
      () =>
          controller.model.flow != null &&
          controller.model.layoutComplete &&
          !controller.model.relayoutBusy,
    );
    final firstScalars = controller.model.flow!.canonicalScalarCount;
    final firstChapters = controller.model.book!.chapters.length;

    controller.dispatch(
      EpubReaderOpenRequested(_fixturePath('long-chapter-stress.epub')),
    );
    await _waitUntil(
      () =>
          controller.model.book != null &&
          controller.model.book!.chapters.length != firstChapters &&
          controller.model.flow != null &&
          !controller.model.relayoutBusy &&
          !controller.model.relayoutPending,
    );
    await _waitUntil(
      () => controller.model.layoutComplete && !controller.model.relayoutBusy,
      timeout: const Duration(seconds: 60),
    );
    final chapter = controller.model.chapter!;
    expect(
      controller.model.flow!.canonicalScalarCount,
      chapter.scalarCount,
      reason: 'the second document must not reuse the first document layout',
    );
    expect(
      controller.model.flow!.canonicalScalarCount,
      greaterThan(firstScalars),
    );
    expect(controller.model.flow!.blocks.length, chapter.blocks.length);
    controller.dispose();
  });

  test('a chapter-end durable position is preserved', () async {
    final path = _fixturePath('rich-chapter.epub');
    final store = EpubMemoryPositionStore();
    final controller = _open('rich-chapter.epub', store: store);
    await _waitUntil(
      () =>
          controller.model.flow != null &&
          controller.model.layoutComplete &&
          !controller.model.relayoutBusy,
    );
    final end = controller.model.chapter!.scalarCount;
    expect(end, greaterThan(0));
    controller.dispatch(EpubReaderScalarJumpRequested(spine: 0, scalar: end));
    await _waitUntil(
      () =>
          controller.model.flow != null &&
          !controller.model.relayoutBusy &&
          !controller.model.relayoutPending &&
          controller.model.scalar == end,
    );
    expect(
      controller.model.scalar,
      end,
      reason: 'a chapter-end position is valid and must not move',
    );
    // Chapter 0 of 2 is fully read; the position is at its canonical end.
    expect(controller.model.progress, closeTo(0.5, 0.0001));
    await _waitUntil(() async => (await store.read(path))?.scalar == end);

    // A new session restores the same position.
    final reopened = EpubReaderController(
      source: _FixtureSource(path),
      positionStore: store,
      layoutStrategy: EpubLayoutStrategy.progressive,
    );
    reopened.dispatch(EpubReaderOpenRequested(path));
    reopened.dispatch(const EpubReaderViewportChanged(900, 700));
    await _waitUntil(
      () => reopened.model.flow != null && !reopened.model.relayoutBusy,
    );
    expect(reopened.model.scalar, end);
    expect(reopened.model.progress, closeTo(0.5, 0.0001));
    controller.dispose();
    reopened.dispose();
  });
}
