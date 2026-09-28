/// Controller evidence: open, layout, navigation, selection, persistence.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/painting.dart' show InlineSpan, TextSpan;

import 'package:shosai_epub_eval/reader/controller.dart';
import 'package:shosai_epub_eval/reader/effects.dart';
import 'package:shosai_epub_eval/reader/layout/flow.dart';
import 'package:shosai_epub_eval/reader/message.dart';
import 'package:shosai_epub_eval/reader/model.dart';
import 'package:shosai_epub_eval/reader/theme.dart';

class _FixtureSource implements EpubDocumentSource {
  _FixtureSource(this.path);

  final String path;

  @override
  Future<Uint8List> read(String documentPath) async =>
      Uint8List.fromList(File(path).readAsBytesSync());
}

class _RecordingClipboard implements EpubClipboard {
  String? text;

  @override
  Future<void> setText(String text) async => this.text = text;
}

/// A clipboard whose writes complete only when the test says so, so a
/// completion can be delivered after a newer selection exists.
class _DelayedClipboard implements EpubClipboard {
  final List<Completer<void>> pending = [];

  @override
  Future<void> setText(String text) {
    final completer = Completer<void>();
    pending.add(completer);
    return completer.future;
  }

  void completeAll() {
    for (final completer in pending) {
      if (!completer.isCompleted) completer.complete();
    }
  }
}

String _fixturePath(String name) {
  final local = File('fixtures/$name');
  return local.existsSync()
      ? local.path
      : '../../crates/shosai-core/tests/fixtures/epub-conformance/$name';
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

Future<void> _waitUntil(
  FutureOr<bool> Function() condition, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final stopwatch = Stopwatch()..start();
  while (!await condition()) {
    if (stopwatch.elapsed > timeout) {
      fail('condition was not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _RecordingClipboard clipboard;
  late EpubMemoryPositionStore store;

  EpubReaderController open(String fixture) {
    final path = _fixturePath(fixture);
    final controller = EpubReaderController(
      source: _FixtureSource(path),
      clipboard: clipboard,
      positionStore: store,
    );
    controller.dispatch(EpubReaderOpenRequested(path));
    controller.dispatch(const EpubReaderViewportChanged(900, 700));
    return controller;
  }

  setUp(() {
    clipboard = _RecordingClipboard();
    store = EpubMemoryPositionStore();
  });

  test('open lays out the first chapter and records first content', () async {
    final controller = open('rich-chapter.epub');
    await _waitUntil(
      () => controller.model.flow != null && !controller.model.relayoutBusy,
    );
    final model = controller.model;
    expect(model.status, EpubReaderStatus.ready);
    expect(model.book!.chapters.length, 2);
    expect(model.paginated, isNotNull);
    expect(model.paginated!.pages.length, greaterThan(1));
    expect(model.unitCount, greaterThan(1));
    expect(model.firstContentMicros, isNotNull);
    expect(model.lastLayoutMicros, isNotNull);
    controller.dispose();
  });

  test('warm navigation advances the durable position', () async {
    final controller = open('rich-chapter.epub');
    await _waitUntil(() => controller.model.flow != null);
    final before = controller.model.scalar;
    controller.dispatch(const EpubReaderUnitRequested(1));
    expect(controller.model.scalar, greaterThan(before));
    expect(controller.model.unit, 1);
    expect(controller.model.progress, greaterThan(0));
    controller.dispatch(const EpubReaderUnitRequested(-1));
    expect(controller.model.unit, 0);
    controller.dispose();
  });

  test('mode and font-size changes preserve the durable position', () async {
    final controller = open('rich-chapter.epub');
    await _waitUntil(() => controller.model.flow != null);
    controller.dispatch(const EpubReaderUnitRequested(2));
    final scalar = controller.model.scalar;
    expect(scalar, greaterThan(0));

    controller.dispatch(const EpubReaderModeChanged(EpubReaderMode.continuous));
    await _waitUntil(
      () =>
          controller.model.paginated == null &&
          controller.model.flow != null &&
          !controller.model.relayoutBusy,
    );
    expect(controller.model.scalar, scalar);
    expect(controller.model.continuousOffset, greaterThan(0));

    controller.dispatch(const EpubReaderFontSizeChanged(6));
    await _waitUntil(
      () =>
          !controller.model.relayoutBusy &&
          controller.model.typography.fontSize == 24,
    );
    expect(controller.model.scalar, scalar);

    controller.dispatch(const EpubReaderModeChanged(EpubReaderMode.paginated));
    await _waitUntil(
      () =>
          controller.model.paginated != null && !controller.model.relayoutBusy,
    );
    expect(controller.model.scalar, scalar);
    controller.dispose();
  });

  test('resizing relayouts without moving the position', () async {
    final controller = open('rich-chapter.epub');
    await _waitUntil(() => controller.model.flow != null);
    controller.dispatch(const EpubReaderUnitRequested(1));
    final scalar = controller.model.scalar;
    controller.dispatch(const EpubReaderViewportChanged(560, 700));
    await _waitUntil(
      () => !controller.model.relayoutBusy && !controller.model.relayoutPending,
    );
    expect(controller.model.scalar, scalar);
    controller.dispose();
  });

  test('TOC activation jumps to the target chapter and anchor', () async {
    final controller = open('rich-chapter.epub');
    await _waitUntil(() => controller.model.flow != null);
    controller.dispatch(const EpubReaderContentsToggled());
    expect(controller.model.contentsOpen, isTrue);
    controller.dispatch(
      const EpubReaderContentsEntryActivated(spine: 1, scalar: 0),
    );
    await _waitUntil(
      () => controller.model.spine == 1 && !controller.model.relayoutBusy,
    );
    expect(controller.model.contentsOpen, isFalse);
    expect(controller.model.chapter!.resource, contains('chapter-2'));
    controller.dispose();
  });

  test('internal link activation resolves a fragment anchor', () async {
    final controller = open('rich-chapter.epub');
    await _waitUntil(() => controller.model.flow != null);
    controller.dispatch(const EpubReaderLinkActivated('#tables'));
    final scalar = controller.model.scalar;
    expect(scalar, greaterThan(0));
    expect(scalar, controller.model.chapter!.anchors['tables']);
    controller.dispose();
  });

  test('selection, copy and highlight projection', () async {
    final controller = open('rich-chapter.epub');
    await _waitUntil(() => controller.model.flow != null);
    final flow = controller.model.flow!;
    final block = flow.blocks.firstWhere((entry) => entry.text != null);
    final text = block.text!;
    final geometry = controller.model.geometry!;
    // Page 0 places the first block at its slice top; a point inside the first
    // line hits the paragraph's opening scalars.
    final y = block.top + text.lines.first.top + 2;
    controller.dispatch(EpubReaderSelectionStarted(Offset(4, y)));
    expect(controller.model.selection, isNotNull);
    controller.dispatch(EpubReaderSelectionExtended(Offset(200, y)));
    controller.dispatch(const EpubReaderSelectionEnded());
    final selection = controller.model.selection!;
    expect(selection.end, greaterThan(selection.start));
    expect(selection.phase, EpubSelectionPhase.selected);

    controller.dispatch(const EpubReaderSelectionCopyRequested());
    await _waitUntil(() => clipboard.text != null);
    expect(clipboard.text, isNotEmpty);
    expect(controller.model.notice, contains('Copied'));

    // Highlight the range and confirm projection produces rectangles.
    controller.dispatch(EpubReaderSelectionStarted(Offset(4, y)));
    controller.dispatch(EpubReaderSelectionExtended(Offset(200, y)));
    controller.dispatch(const EpubReaderSelectionEnded());
    controller.dispatch(
      const EpubReaderHighlightRequested(ReaderHighlightColor.yellow),
    );
    expect(controller.model.highlights, hasLength(1));
    expect(controller.model.selection, isNull);
    expect(geometry.columns, greaterThanOrEqualTo(1));
    controller.dispose();
  });

  test('reopening restores the stored new-session position', () async {
    final path = _fixturePath('rich-chapter.epub');
    final first = EpubReaderController(
      source: _FixtureSource(path),
      clipboard: clipboard,
      positionStore: store,
    );
    // One column keeps unit == page ordinal, so the stored scalar maps to a
    // unique unit on reopen.
    first.dispatch(EpubReaderOpenRequested(path));
    first.dispatch(const EpubReaderViewportChanged(700, 700));
    await _waitUntil(() => first.model.flow != null);
    first.dispatch(const EpubReaderUnitRequested(3));
    final scalar = first.model.scalar;
    final spine = first.model.spine;
    final unit = first.model.unit;
    expect(scalar, greaterThan(0));
    await _waitUntil(() async {
      final stored = await store.read(path);
      return stored?.scalar == scalar;
    });
    first.dispose();

    final second = EpubReaderController(
      source: _FixtureSource(path),
      clipboard: clipboard,
      positionStore: store,
    );
    second.dispatch(EpubReaderOpenRequested(path));
    second.dispatch(const EpubReaderViewportChanged(700, 700));
    await _waitUntil(() => second.model.flow != null);
    // The durable position is usable immediately: the first installed layout
    // is a window around the stored scalar (the whole chapter for a short one).
    expect(second.model.spine, spine);
    expect(second.model.scalar, scalar);
    // Once the chapter is fully measured, the presentation ordinal is the
    // chapter's, not the window's.
    await _waitUntil(
      () => second.model.layoutComplete && !second.model.relayoutBusy,
    );
    expect(second.model.unit, unit);
    second.dispose();
  });

  test('a font-size intent invalidates an in-flight layout', () async {
    final controller = open('long-chapter.epub');
    // Catch the first layout while it is still in flight; the emission itself
    // guarantees the intent arrives before the layout work runs.
    final inFlight = Completer<void>();
    void watchBusy() {
      if (!inFlight.isCompleted && controller.model.relayoutBusy) {
        inFlight.complete();
      }
    }

    controller.addListener(watchBusy);
    await inFlight.future;
    controller.removeListener(watchBusy);

    final seen = <EpubReaderModel>[];
    controller.addListener(() => seen.add(controller.model));
    controller.dispatch(const EpubReaderFontSizeChanged(2));
    // Let the debounced relayout (80 ms) and any superseded layout finish, so
    // the last settled state is the layout for the requested font size.
    await Future<void>.delayed(const Duration(milliseconds: 700));
    // Compare every settled layout against the final one: the same block must
    // have been measured with the same font size, scaled by the typography the
    // state reports. A stale layout keeps the previous scale.
    expect(controller.model.typography.fontSize, 20);
    final settled = seen
        .where(
          (state) =>
              !state.relayoutBusy &&
              !state.relayoutPending &&
              state.flow != null &&
              state.typography.fontSize == 20,
        )
        .toList();
    expect(settled, isNotEmpty);
    final reference = _firstTextLeafSize(settled.last.flow!)!;
    final referenceFontSize = settled.last.typography.fontSize;
    for (final state in settled) {
      expect(
        _firstTextLeafSize(state.flow!),
        reference * state.typography.fontSize / referenceFontSize,
        reason:
            'a layout computed for the previous font size was installed '
            'after the intent',
      );
    }
    controller.dispose();
  });

  test('a delayed copy completion keeps a newer selection', () async {
    final delayed = _DelayedClipboard();
    final controller = EpubReaderController(
      source: _FixtureSource(_fixturePath('rich-chapter.epub')),
      clipboard: delayed,
      positionStore: EpubMemoryPositionStore(),
    );
    controller.dispatch(
      EpubReaderOpenRequested(_fixturePath('rich-chapter.epub')),
    );
    controller.dispatch(const EpubReaderViewportChanged(900, 700));
    await _waitUntil(
      () => controller.model.flow != null && !controller.model.relayoutBusy,
    );

    final block = controller.model.flow!.blocks.firstWhere(
      (entry) => entry.text != null,
    );
    final text = block.text!;
    final y = block.top + text.lines.first.top + 2;
    controller.dispatch(EpubReaderSelectionStarted(Offset(4, y)));
    expect(controller.model.selection, isNotNull);
    controller.dispatch(EpubReaderSelectionExtended(Offset(200, y)));
    controller.dispatch(const EpubReaderSelectionEnded());

    controller.dispatch(const EpubReaderSelectionCopyRequested());
    expect(delayed.pending, hasLength(1));

    // A newer selection starts while the clipboard write is still pending.
    controller.dispatch(EpubReaderSelectionStarted(Offset(4, y)));
    final newer = controller.model.selection;
    expect(newer, isNotNull);
    delayed.completeAll();
    await _waitUntil(() => controller.model.notice != null);
    expect(
      identical(controller.model.selection, newer),
      isTrue,
      reason: 'the delayed copy completion must not clear a newer selection',
    );
    controller.dispose();
  });

  test('continuous mode scroll offset maps back to a durable scalar', () async {
    final controller = open('rich-chapter.epub');
    await _waitUntil(() => controller.model.flow != null);
    controller.dispatch(const EpubReaderModeChanged(EpubReaderMode.continuous));
    await _waitUntil(() => controller.model.paginated == null);
    controller.dispatch(const EpubReaderContinuousOffsetChanged(600));
    await _waitUntil(() => controller.model.continuousOffset == 600);
    expect(controller.model.scalar, greaterThan(0));
    final stored = await store.read(_fixturePath('rich-chapter.epub'));
    expect(stored, isNotNull);
    expect(stored!.scalar, controller.model.scalar);
    controller.dispose();
  });
}
