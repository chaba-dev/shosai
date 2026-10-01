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

/// Slice 4 navigation renders.
///
/// The Contents panel is served by the **real** table of contents of the
/// fixture book (no injected loader), and the link states are captured from the
/// Dart-rendered page. These are candidate renders for owner inspection: the
/// file deliberately does not compare them with a committed baseline, because
/// accepting a reader baseline is the owner's decision.
class _NavigationRenderBridge extends HarnessBridge {
  _NavigationRenderBridge({super.books, super.unitCount});

  @override
  Future<FlutterReadingState?> loadReadingState({
    required int bookId,
    required BigInt cancellationId,
  }) async => null;
}

void main() {
  setUpAll(loadHarnessFonts);

  final bytes = navigationEpub();
  final book = openEpubBytes(bytes);
  final coverage = EpubFontCoverage.fromFonts([
    Uint8List.fromList(
      File('../assets/fonts/InterVariable.ttf').readAsBytesSync(),
    ),
    Uint8List.fromList(
      File('../assets/fonts/NotoSansJP-Variable.ttf').readAsBytesSync(),
    ),
  ])!;

  HarnessBridge bridge() {
    final harness = _NavigationRenderBridge(
      unitCount: 3,
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
      ],
    );
    harness.epubBytes = bytes;
    harness.canonicalTexts = {
      for (var unit = 0; unit < book.chapters.length; unit += 1)
        unit: book.chapters[unit].canonicalText,
    };
    return harness;
  }

  Widget reader(HarnessBridge harness, {Locale? locale}) => productionShell(
    locale: locale,
    home: ReaderScreen(
      bridge: harness,
      initialPath: '/books/navigation.epub',
      initialBookId: 1,
      fontCoverageLoader: () async => coverage,
      epubImageDecoder: (bytes) async => null,
    ),
  );

  Future<void> render(
    WidgetTester tester,
    String name,
    HarnessView view,
    Widget widget, {
    required bool Function() ready,
    Map<String, Object?> metadata = const {},
  }) async {
    final recorder = RenderErrorRecorder.install();
    addTearDown(recorder.dispose);
    view.apply(tester);
    await renderHarnessState(tester, widget, ready: ready);
    final defects = await findRenderDefects(tester);
    await captureHarnessArtifact(
      tester,
      name,
      metadata: <String, Object?>{
        ...view.toMetadata(),
        ...metadata,
        ...harnessPlatformMetrics(),
        'defects': defects.map((defect) => defect.toMetadata()).toList(),
      },
    );
    expect(
      recorder.overflowErrors,
      isEmpty,
      reason: 'Flutter reported a layout overflow in $name',
    );
    expect(tester.takeException(), isNull);
    expectOnlyKnownDefects(defects, const <KnownRenderDefect>[]);
  }

  Future<void> openContents(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('reader-header-contents')));
    await pumpHarnessFrames(tester, frames: 4);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 120)),
    );
    await pumpHarnessFrames(tester, frames: 8);
  }

  testWidgets('real contents panel (EN, wide)', (tester) async {
    final harness = bridge();
    await render(
      tester,
      'reader-navigation-page-1280-en',
      const HarnessView(size: Size(1280, 800)),
      reader(harness, locale: const Locale('en')),
      ready: () => harnessReaderPageReady(tester),
      metadata: const <String, Object?>{
        'state': 'dart-page',
        'content': 'real TOC fixture, links painted',
      },
    );
    await openContents(tester);
    final defects = await findRenderDefects(tester);
    await captureHarnessArtifact(
      tester,
      'reader-navigation-contents-1280-en',
      metadata: <String, Object?>{
        'state': 'panel-open',
        'panel': 'contents',
        'entries': 'real TOC: nested part, fragments, encoded path',
        'defects': defects.map((defect) => defect.toMetadata()).toList(),
      },
    );
    expectOnlyKnownDefects(defects, const <KnownRenderDefect>[]);
  });

  testWidgets('real contents panel (JA chrome, compact)', (tester) async {
    final harness = bridge();
    await render(
      tester,
      'reader-navigation-page-390-ja',
      const HarnessView(size: Size(390, 844)),
      reader(harness, locale: const Locale('ja')),
      ready: () => harnessReaderPageReady(tester),
      metadata: const <String, Object?>{
        'state': 'dart-page',
        'chrome': 'compact',
        'locale': 'ja',
      },
    );
    await openContents(tester);
    final defects = await findRenderDefects(tester);
    await captureHarnessArtifact(
      tester,
      'reader-navigation-contents-390-ja',
      metadata: <String, Object?>{
        'state': 'panel-open',
        'panel': 'contents',
        'chrome': 'compact',
        'entries': 'real TOC (authored English titles), JA chrome',
        'defects': defects.map((defect) => defect.toMetadata()).toList(),
      },
    );
    expectOnlyKnownDefects(defects, const <KnownRenderDefect>[]);
  });

  testWidgets('a navigated fragment page (EN, wide)', (tester) async {
    final harness = bridge();
    await render(
      tester,
      'reader-navigation-target-1280-en',
      const HarnessView(size: Size(1280, 800)),
      reader(harness, locale: const Locale('en')),
      ready: () => harnessReaderPageReady(tester),
      metadata: const <String, Object?>{'state': 'dart-page'},
    );

    // Activate the cross-chapter link through its painted geometry and capture
    // the target chapter the reader lands on.
    final painter = _dartPage(tester)!;
    final paintBox = tester.renderObject<RenderBox>(
      find.byKey(const ValueKey('reader-page-paint')),
    );
    final transform = SurfaceTransform.create(
      BoxFit.contain,
      painter.page.box.size,
      paintBox.size,
    );
    Offset? point;
    for (final slice in painter.page.page.slices) {
      for (final placed in placedPageText(slice, painter.page.box)) {
        for (final link in placed.block.links) {
          if (link.href != 'chapter-2.xhtml#two-target') continue;
          final boxes = placed.block.painter.getBoxesForSelection(
            TextSelection(baseOffset: link.start, extentOffset: link.end),
          );
          if (boxes.isEmpty) continue;
          final rect = boxes.first.toRect().shift(placed.origin);
          point =
              paintBox.localToGlobal(Offset.zero) +
              transform.toDestinationRect(rect).center;
        }
      }
    }
    expect(point, isNotNull, reason: 'the cross-chapter link is painted');
    await tester.tapAt(point!);
    for (var round = 0; round < 8; round += 1) {
      await pumpHarnessFrames(tester, frames: 4);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 120)),
      );
    }
    // The capture is only a fragment-target render if the tap actually
    // navigated: assert the target chapter and its verified anchor offset, not
    // just the render defects.
    expect(
      harness.savedReadingStates.last.unit.toInt(),
      1,
      reason: 'the cross-chapter link moved to the second chapter',
    );
    expect(
      harness.savedReadingStates.last.offset?.toInt(),
      book.chapters[1].anchors['two-target'],
      reason: 'the durable offset is the verified anchor',
    );
    final defects = await findRenderDefects(tester);
    await captureHarnessArtifact(
      tester,
      'reader-navigation-target-1280-en',
      metadata: <String, Object?>{
        'state': 'fragment-target',
        'unit': harness.savedReadingStates.last.unit.toInt(),
        'offset': harness.savedReadingStates.last.offset?.toInt(),
        'defects': defects.map((defect) => defect.toMetadata()).toList(),
      },
    );
    expectOnlyKnownDefects(defects, const <KnownRenderDefect>[]);
  });
}

ReaderEpubPageContentPainter? _dartPage(WidgetTester tester) {
  for (final paint in tester.widgetList<CustomPaint>(
    find.byType(CustomPaint),
  )) {
    final painter = paint.painter;
    if (painter is ReaderEpubPageContentPainter) return painter;
  }
  return null;
}
