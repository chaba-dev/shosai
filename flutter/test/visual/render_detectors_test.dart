import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/production_shell_harness.dart';

/// Negative controls for the render detectors.
///
/// Each fixture is a controlled failure of a known shape, so a detector that
/// stops working fails here instead of silently passing the production renders.
/// The clipped-label fixtures deliberately produce no `RenderFlex` overflow
/// report: the geometry detector is the only thing that can catch them.
void main() {
  setUpAll(loadHarnessFonts);

  const view = HarnessView(size: Size(900, 400));

  Future<void> pumpFixture(
    WidgetTester tester,
    Widget home, {
    HarnessView at = view,
  }) async {
    at.apply(tester);
    await tester.pumpWidget(productionShell(home: home));
    await tester.pumpAndSettle();
  }

  /// A fixed-width tab strip whose labels are wider than their boxes.
  Widget clippedTabs({TextOverflow overflow = TextOverflow.clip}) => Scaffold(
    body: Align(
      alignment: Alignment.topLeft,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final label in ['All', 'EPUB', 'PDF', 'CBZ'])
            SizedBox(
              width: 26,
              height: 22,
              child: Text(
                label,
                maxLines: 1,
                softWrap: false,
                overflow: overflow,
              ),
            ),
        ],
      ),
    ),
  );

  List<RenderDefect> clipped(List<RenderDefect> defects) => defects
      .where((defect) => defect.kind == RenderDefectKind.clippedText)
      .toList();

  testWidgets('flex overflow is reported by the framework and by geometry', (
    tester,
  ) async {
    final recorder = RenderErrorRecorder.install();
    addTearDown(recorder.dispose);
    await pumpFixture(
      tester,
      Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 100,
            height: 40,
            child: Row(
              children: const [
                SizedBox(width: 80, height: 20),
                SizedBox(width: 80, height: 20),
              ],
            ),
          ),
        ),
      ),
    );

    final defects = await findRenderDefects(tester);
    expect(
      defects.where((defect) => defect.kind == RenderDefectKind.layoutOverflow),
      isNotEmpty,
      reason: 'geometry detector must report the overflowing row',
    );
    expect(
      defects.where(
        (defect) =>
            defect.kind == RenderDefectKind.layoutOverflow &&
            defect.source == 'geometry',
      ),
      isNotEmpty,
      reason: 'the geometry source must be independent of Flutter reporting',
    );
    expect(
      recorder.overflowErrors,
      isNotEmpty,
      reason: 'Flutter must also report this fixture, which is the known shape',
    );
    // The framework report is an expected part of this fixture.
    expect(tester.takeException(), isNotNull);
  });

  testWidgets('the historical 900x700 200% tab fixture is detected', (
    tester,
  ) async {
    // Faithful reproduction of the historical library tab-strip clipping
    // (rfd/0004/evidence/parity-review-2026-09-14/07-golden-clipped-tabs-3x.png)
    // at the XA-03 configuration: 900 logical pixels wide, 200% text. The
    // production library no longer clips at this configuration, so the
    // historical failing input is preserved here as its own control.
    final recorder = RenderErrorRecorder.install();
    addTearDown(recorder.dispose);
    await pumpFixture(
      tester,
      Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 900,
            child: Row(
              children: [
                for (final label in ['All', 'EPUB', 'PDF', 'CBZ'])
                  SizedBox(
                    width: 44,
                    height: 44,
                    child: Text(
                      label,
                      maxLines: 1,
                      softWrap: false,
                      textAlign: TextAlign.center,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
      at: const HarnessView(size: Size(900, 700), textScale: 2),
    );

    final labels = clipped(
      await findClippingDefects(tester),
    ).map((defect) => defect.label).join('\n');
    expect(
      labels,
      allOf(contains('EPUB'), contains('PDF'), contains('CBZ')),
      reason: 'every label wider than its tab must be reported',
    );
    expect(
      recorder.overflowErrors,
      isEmpty,
      reason:
          'the historical shape produced no RenderFlex report, so only the '
          'clipping check can catch it',
    );
    expect(tester.takeException(), isNull);

    writeHarnessArtifact(
      'negative-historical-clipped-tabs-900-t200',
      await captureHarnessPng(tester),
      metadata: <String, Object?>{
        'fixture': 'G2 historical clipped tabs',
        'expected': 'clippedText',
      },
    );
  });

  testWidgets('clipped labels fail the clipping check without a flex report', (
    tester,
  ) async {
    final recorder = RenderErrorRecorder.install();
    addTearDown(recorder.dispose);
    await pumpFixture(tester, clippedTabs());

    final labels = clipped(
      await findClippingDefects(tester),
    ).map((defect) => defect.label).join('\n');
    expect(
      labels,
      allOf(contains('EPUB'), contains('CBZ')),
      reason: 'every label wider than its box must be reported',
    );
    expect(
      recorder.overflowErrors,
      isEmpty,
      reason:
          'this fixture is the historical clipped-label shape: Flutter '
          'reports no RenderFlex overflow, so only the clipping check '
          'can catch it',
    );
    expect(tester.takeException(), isNull);

    // Record the failing render so the detection can be inspected.
    writeHarnessArtifact(
      'negative-clipped-labels',
      await captureHarnessPng(tester),
      metadata: <String, Object?>{
        'fixture': 'clipped-tabs',
        'expected': 'clippedText',
        'defects': clipped(
          await findClippingDefects(tester),
        ).map((defect) => defect.id).toList(),
      },
    );
  });

  testWidgets('no-wrap text in a tall box is still detected', (tester) async {
    // Without wrapping the paragraph lays out at its intrinsic width, so a box
    // that is tall enough for two wrapped lines still cuts the single line.
    await pumpFixture(
      tester,
      const Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 30,
            height: 200,
            child: Text('EPUB EPUB', softWrap: false, maxLines: 1),
          ),
        ),
      ),
    );

    expect(clipped(await findClippingDefects(tester)), isNotEmpty);
  });

  testWidgets('an ellipsized label is truncation, not silent clipping', (
    tester,
  ) async {
    await pumpFixture(tester, clippedTabs(overflow: TextOverflow.ellipsis));

    expect(
      clipped(await findClippingDefects(tester)),
      isEmpty,
      reason: 'an ellipsis is visible truncation, not a hidden cut',
    );
    expect(
      await findTruncationDefects(tester),
      isNotEmpty,
      reason: 'the truncation must still be reported',
    );
  });

  testWidgets('labels that fit report no defects', (tester) async {
    final recorder = RenderErrorRecorder.install();
    addTearDown(recorder.dispose);
    await pumpFixture(
      tester,
      Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final label in ['All', 'EPUB', 'PDF', 'CBZ'])
                SizedBox(
                  width: 80,
                  height: 22,
                  child: Text(label, maxLines: 1, softWrap: false),
                ),
            ],
          ),
        ),
      ),
    );

    expect(await findRenderDefects(tester), isEmpty);
    expect(recorder.overflowErrors, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a label cut by an ancestor clip is reported', (tester) async {
    await pumpFixture(
      tester,
      Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: ClipRect(
            child: SizedBox(
              width: 40,
              height: 22,
              child: OverflowBox(
                maxWidth: 240,
                alignment: Alignment.centerLeft,
                child: const Text(
                  'EPUB label wider than its clip',
                  maxLines: 1,
                  softWrap: false,
                ),
              ),
            ),
          ),
        ),
      ),
    );

    expect(
      (await findClippingDefects(
        tester,
      )).where((defect) => defect.kind == RenderDefectKind.clippedByAncestor),
      isNotEmpty,
      reason: 'the paragraph box fits but the ancestor clip cuts the glyphs',
    );
  });

  testWidgets('a clip that removes only empty space is not reported', (
    tester,
  ) async {
    // The paragraph box is 60 tall while its ink is one short line; the clip
    // cuts only the paragraph's empty lower half.
    await pumpFixture(
      tester,
      const Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: ClipRect(
            child: SizedBox(
              width: 200,
              height: 30,
              child: OverflowBox(
                minWidth: 0,
                maxWidth: 200,
                minHeight: 0,
                maxHeight: 60,
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 200,
                  height: 60,
                  child: Text('EPUB', maxLines: 1, softWrap: false),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    expect(await findClippingDefects(tester), isEmpty);
  });

  testWidgets('a clipped label inside a scrollable is reported', (
    tester,
  ) async {
    // The viewport's own clipping is scrolling, but a clip inside it is not.
    await pumpFixture(
      tester,
      Scaffold(
        body: ListView(
          children: [
            Align(
              alignment: Alignment.topLeft,
              child: ClipRect(
                child: SizedBox(
                  width: 40,
                  height: 22,
                  child: OverflowBox(
                    minWidth: 0,
                    maxWidth: 240,
                    alignment: Alignment.centerLeft,
                    child: const Text(
                      'EPUB label wider than its clip',
                      maxLines: 1,
                      softWrap: false,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 1000),
          ],
        ),
      ),
    );

    expect(
      (await findClippingDefects(
        tester,
      )).where((defect) => defect.kind == RenderDefectKind.clippedByAncestor),
      isNotEmpty,
      reason: 'a clip below the viewport still cuts the label',
    );
  });

  testWidgets('scroll clipping is not reported as a defect', (tester) async {
    // The label straddles the bottom edge of the viewport, so its ink is cut by
    // the viewport itself: that is scrolling, not a defect.
    await pumpFixture(
      tester,
      Scaffold(
        body: ListView(
          children: const [
            SizedBox(height: 390),
            SizedBox(
              height: 40,
              child: Text('A paragraph crossing the edge', maxLines: 1),
            ),
            SizedBox(height: 400),
          ],
        ),
      ),
    );

    expect(await findClippingDefects(tester), isEmpty);
  });

  testWidgets('a clip above a viewport is reported when it crops shown ink', (
    tester,
  ) async {
    // Geometry: outer clip 80 tall, viewport 100 tall, ink at 70..86. The
    // viewport shows the ink and the outer clip removes part of it.
    await pumpFixture(
      tester,
      Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: ClipRect(
            child: SizedBox(
              width: 300,
              height: 80,
              child: OverflowBox(
                minWidth: 0,
                maxWidth: 300,
                minHeight: 0,
                maxHeight: 100,
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 300,
                  height: 100,
                  child: ListView(
                    padding: EdgeInsets.zero,
                    children: const [
                      SizedBox(height: 70),
                      SizedBox(
                        height: 40,
                        child: Text('Cropped by an outer clip', maxLines: 1),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    expect(
      (await findClippingDefects(
        tester,
      )).where((defect) => defect.kind == RenderDefectKind.clippedByAncestor),
      isNotEmpty,
    );
  });

  testWidgets('a viewport narrower than its outer clip is not reported', (
    tester,
  ) async {
    // Same ink, but the outer clip is taller than the viewport, so the viewport
    // already removes everything the outer clip would: no additional crop.
    await pumpFixture(
      tester,
      Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: ClipRect(
            child: SizedBox(
              width: 300,
              height: 200,
              child: OverflowBox(
                minWidth: 0,
                maxWidth: 300,
                minHeight: 0,
                maxHeight: 100,
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 300,
                  height: 100,
                  child: ListView(
                    padding: EdgeInsets.zero,
                    children: const [
                      SizedBox(height: 70),
                      SizedBox(
                        height: 40,
                        child: Text('Fully inside the outer clip', maxLines: 1),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    expect(await findClippingDefects(tester), isEmpty);
  });

  testWidgets('a clip between nested viewports is still reported', (
    tester,
  ) async {
    await pumpFixture(
      tester,
      Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: ClipRect(
            child: SizedBox(
              width: 300,
              height: 200,
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  ClipRect(
                    child: SizedBox(
                      width: 300,
                      height: 60,
                      child: OverflowBox(
                        minWidth: 0,
                        maxWidth: 300,
                        minHeight: 0,
                        maxHeight: 120,
                        alignment: Alignment.topLeft,
                        child: SizedBox(
                          width: 300,
                          height: 120,
                          child: ListView(
                            padding: EdgeInsets.zero,
                            children: const [
                              SizedBox(height: 100),
                              SizedBox(
                                height: 40,
                                child: Text('Inside nested viewports'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    expect(
      (await findClippingDefects(
        tester,
      )).where((defect) => defect.kind == RenderDefectKind.clippedByAncestor),
      isNotEmpty,
    );
  });

  testWidgets('an active fade is visible truncation, not a hidden cut', (
    tester,
  ) async {
    // Width-only fade: one line, no maxLines limit, faded at the right edge.
    await pumpFixture(
      tester,
      const Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 30,
            height: 40,
            child: Text(
              'EPUB',
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.fade,
            ),
          ),
        ),
      ),
    );
    expect(
      clipped(await findClippingDefects(tester)),
      isEmpty,
      reason: 'the faded edge is the visible indication',
    );
    expect(await findTruncationDefects(tester), isNotEmpty);

    // Height-only fade: wrapping text in a short box.
    await pumpFixture(
      tester,
      const Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 200,
            height: 10,
            child: Text(
              'EPUB text that needs more height than the box provides',
              overflow: TextOverflow.fade,
            ),
          ),
        ),
      ),
    );
    expect(clipped(await findClippingDefects(tester)), isEmpty);
    expect(await findTruncationDefects(tester), isNotEmpty);
  });

  testWidgets('an unmeasurable visible overflow is reported, not skipped', (
    tester,
  ) async {
    // The paragraph lays out at its intrinsic width, which is far beyond the
    // harness raster limit, so the ink cannot be measured.
    await pumpFixture(
      tester,
      Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: ClipRect(
            child: SizedBox(
              width: 100,
              height: 20,
              child: Text(
                'x' * 5000,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.visible,
              ),
            ),
          ),
        ),
      ),
    );

    final defects = clipped(await findClippingDefects(tester));
    expect(defects, isNotEmpty);
    expect(
      defects.map((defect) => defect.detail).join('\n'),
      contains('unmeasured'),
    );
  });

  testWidgets('visible overflow is reported only when a clip cuts it', (
    tester,
  ) async {
    Widget fixture({required bool clipped}) {
      final label = const SizedBox(
        width: 30,
        height: 22,
        child: Text(
          'EPUB',
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.visible,
        ),
      );
      return Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: clipped ? ClipRect(child: label) : label,
        ),
      );
    }

    await pumpFixture(tester, fixture(clipped: false));
    expect(
      await findClippingDefects(tester),
      isEmpty,
      reason: 'visible overflow paints the whole label; nothing is cut',
    );

    await pumpFixture(tester, fixture(clipped: true));
    expect(
      (await findClippingDefects(
        tester,
      )).where((defect) => defect.kind == RenderDefectKind.clippedByAncestor),
      isNotEmpty,
      reason: 'an ancestor clip cuts the visibly overflowing label',
    );
  });

  testWidgets('right-to-left labels are measured in their own direction', (
    tester,
  ) async {
    await pumpFixture(
      tester,
      const Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 30,
              height: 22,
              child: Text(
                'שלום עולם',
                maxLines: 1,
                softWrap: false,
                textDirection: TextDirection.rtl,
              ),
            ),
          ),
        ),
      ),
    );

    expect(clipped(await findClippingDefects(tester)), isNotEmpty);
  });

  testWidgets('wrapped CJK text is not reported, an unbreakable run is', (
    tester,
  ) async {
    await pumpFixture(
      tester,
      const Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 120,
            height: 120,
            child: Text('海辺の図書館をめぐる長い旅路'),
          ),
        ),
      ),
    );
    expect(
      await findClippingDefects(tester),
      isEmpty,
      reason: 'Japanese text wraps inside a wide enough box',
    );

    await pumpFixture(
      tester,
      const Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 40,
            height: 22,
            child: Text('海辺の図書館', maxLines: 1, softWrap: false),
          ),
        ),
      ),
    );
    expect(clipped(await findClippingDefects(tester)), isNotEmpty);
  });

  testWidgets('inline widgets are reported as unmeasured, not guessed', (
    tester,
  ) async {
    await pumpFixture(
      tester,
      Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 30,
            height: 22,
            child: Text.rich(
              TextSpan(
                children: [
                  const TextSpan(text: 'A'),
                  WidgetSpan(child: SizedBox(width: 40, height: 10)),
                ],
              ),
              maxLines: 1,
              softWrap: false,
            ),
          ),
        ),
      ),
    );

    final defects = clipped(await findClippingDefects(tester));
    expect(defects, isNotEmpty);
    expect(
      defects.map((defect) => defect.detail).join('\n'),
      contains('inline widgets'),
    );
  });

  testWidgets('a clip inside a viewport is not masked by the viewport', (
    tester,
  ) async {
    // The inner clip's edge coincides with the viewport edge, but the clip
    // moves with the content, so the glyph part it removes stays removed.
    await pumpFixture(
      tester,
      Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 300,
            height: 100,
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                ClipRect(
                  child: SizedBox(
                    width: 300,
                    height: 100,
                    child: OverflowBox(
                      minWidth: 0,
                      maxWidth: 300,
                      minHeight: 0,
                      maxHeight: 120,
                      alignment: Alignment.topLeft,
                      child: SizedBox(
                        width: 300,
                        height: 120,
                        child: Column(
                          children: const [
                            SizedBox(height: 90),
                            Text('Permanently cut label', maxLines: 1),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 300),
              ],
            ),
          ),
        ),
      ),
    );

    expect(
      (await findClippingDefects(
        tester,
      )).where((defect) => defect.kind == RenderDefectKind.clippedByAncestor),
      isNotEmpty,
    );
  });

  testWidgets('an outer viewport still bounds a taller inner viewport', (
    tester,
  ) async {
    // Outer clip 80 tall, viewport A 75 tall, inner viewport B 100 tall, ink
    // 70..86: A already removes everything past 75, so the outer clip adds no
    // further crop.
    await pumpFixture(
      tester,
      Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: ClipRect(
            child: SizedBox(
              width: 300,
              height: 80,
              child: OverflowBox(
                minWidth: 0,
                maxWidth: 300,
                minHeight: 0,
                maxHeight: 75,
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 300,
                  height: 75,
                  child: ListView(
                    padding: EdgeInsets.zero,
                    children: [
                      SizedBox(
                        height: 100,
                        child: ListView(
                          padding: EdgeInsets.zero,
                          children: const [
                            SizedBox(height: 70),
                            SizedBox(
                              height: 40,
                              child: Text('Nested label', maxLines: 1),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    expect(await findClippingDefects(tester), isEmpty);
  });

  testWidgets('ink entirely outside the viewport is not reported', (
    tester,
  ) async {
    // The label is scrolled far below the viewport, so no visible ink remains
    // for an outer clip to remove.
    await pumpFixture(
      tester,
      Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: ClipRect(
            child: SizedBox(
              width: 300,
              height: 80,
              child: OverflowBox(
                minWidth: 0,
                maxWidth: 300,
                minHeight: 0,
                maxHeight: 100,
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 300,
                  height: 100,
                  child: ListView(
                    padding: EdgeInsets.zero,
                    children: const [
                      SizedBox(height: 150),
                      SizedBox(
                        height: 40,
                        child: Text('Below the viewport', maxLines: 1),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    expect(await findClippingDefects(tester), isEmpty);
  });

  testWidgets('a faded label is not blamed for ink the fade already clips', (
    tester,
  ) async {
    // The ancestor clip matches the paragraph box exactly, so it removes
    // nothing the faded paragraph does not already clip.
    await pumpFixture(
      tester,
      const Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: ClipRect(
            child: SizedBox(
              width: 30,
              height: 40,
              child: Text(
                'EPUB',
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.fade,
              ),
            ),
          ),
        ),
      ),
    );
    expect(
      await findClippingDefects(tester),
      isEmpty,
      reason: 'truncation is reported separately; nothing else is cut',
    );
    expect(await findTruncationDefects(tester), isNotEmpty);

    // A genuinely smaller ancestor clip still cuts the painted label.
    await pumpFixture(
      tester,
      const Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: ClipRect(
            child: SizedBox(
              width: 20,
              height: 40,
              child: OverflowBox(
                minWidth: 0,
                maxWidth: 30,
                alignment: Alignment.centerLeft,
                child: SizedBox(
                  width: 30,
                  height: 40,
                  child: Text(
                    'EPUB',
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.fade,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    expect(
      (await findClippingDefects(
        tester,
      )).where((defect) => defect.kind == RenderDefectKind.clippedByAncestor),
      isNotEmpty,
    );
  });

  testWidgets('a rotated clip keeps a valid axis-aligned bound', (
    tester,
  ) async {
    // A 45-degree rotation of a 100x100 clip has a ~141x141 bounding box. The
    // label sits inside the rotated clip, so the bound must contain it.
    await pumpFixture(
      tester,
      Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: Transform.rotate(
            angle: math.pi / 4,
            child: ClipRect(
              child: SizedBox(
                width: 100,
                height: 100,
                child: Align(
                  alignment: Alignment.center,
                  child: SizedBox(
                    width: 60,
                    height: 20,
                    child: Text('Rotated', maxLines: 1, softWrap: false),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    expect(await findClippingDefects(tester), isEmpty);
  });

  /// A paragraph whose line metrics fit its box but whose glyph ink overhangs
  /// it. Flutter does not clip a fitting line box, so the overhang is only cut
  /// when an ancestor clip is smaller than the ink.
  Widget overhangingLabel({required double clipHeight}) => Scaffold(
    body: Align(
      alignment: Alignment.topLeft,
      child: ClipRect(
        child: SizedBox(
          width: 200,
          height: clipHeight,
          child: const Align(
            alignment: Alignment.center,
            child: SizedBox(
              width: 120,
              height: 8,
              child: Text(
                'Overhang',
                maxLines: 1,
                softWrap: false,
                style: TextStyle(fontSize: 16, height: 0.5),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  testWidgets('glyph overhang inside a generous clip is not a defect', (
    tester,
  ) async {
    // The 16px glyphs are taller than the 8px line box, so their ink paints
    // outside the paragraph box, but the enclosing clip contains all of it.
    await pumpFixture(tester, overhangingLabel(clipHeight: 40));

    expect(
      await findClippingDefects(tester),
      isEmpty,
      reason: 'a fitting line box is not clipped by Flutter itself',
    );
  });

  testWidgets('glyph overhang cut by an ancestor clip is reported', (
    tester,
  ) async {
    // The clip matches the paragraph box exactly, so the overhang above and
    // below the line box is removed even though Flutter never enabled the
    // paragraph's own clip.
    await pumpFixture(tester, overhangingLabel(clipHeight: 8));

    final defects = await findClippingDefects(tester);
    expect(
      defects.where(
        (defect) => defect.kind == RenderDefectKind.clippedByAncestor,
      ),
      isNotEmpty,
      reason: 'the ancestor clip cuts glyph ink the paragraph still paints',
    );
    expect(
      defects.where((defect) => defect.kind == RenderDefectKind.clippedText),
      isEmpty,
      reason:
          'a fitting line box must not be reported as a self-clipping paragraph',
    );
  });

  /// Two lines of text in a box tall enough for both, limited to one line: the
  /// layout drops the second line without any ink leaving the box.
  Widget droppedLine({required TextOverflow overflow}) => Scaffold(
    body: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: 240,
        height: 100,
        child: Text(
          'EPUB\nPDF',
          maxLines: 1,
          overflow: overflow,
          style: const TextStyle(fontSize: 16, height: 1),
        ),
      ),
    ),
  );

  for (final overflow in [TextOverflow.clip, TextOverflow.visible]) {
    testWidgets('a dropped line is reported for ${overflow.name}', (
      tester,
    ) async {
      await pumpFixture(tester, droppedLine(overflow: overflow));

      final defects = await findRenderDefects(tester, includeTruncation: true);
      expect(
        defects.where(
          (defect) =>
              defect.kind == RenderDefectKind.clippedText &&
              defect.detail.contains('maxLines'),
        ),
        isNotEmpty,
        reason:
            'maxLines removed the second line and ${overflow.name} shows no '
            'indication of it',
      );
    });
  }

  testWidgets(
    'a faded label with no ink inside its box is not blamed on a clip',
    (tester) async {
      // The paragraph box is one pixel tall, so its own overflow removes all of
      // its ink before any ancestor clip applies. The ancestor check must skip
      // that paragraph rather than normalize an empty intersection into a
      // phantom rect that the clip appears to cut.
      await pumpFixture(
        tester,
        const Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: ClipRect(
              child: SizedBox(
                width: 30,
                height: 1,
                child: Text(
                  'EPUB',
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.fade,
                ),
              ),
            ),
          ),
        ),
      );

      final defects = await findRenderDefects(tester, includeTruncation: true);
      expect(
        defects.where(
          (defect) => defect.kind == RenderDefectKind.truncatedText,
        ),
        isNotEmpty,
        reason: 'the fade is still reported as visible truncation',
      );
      expect(
        defects.where(
          (defect) => defect.kind == RenderDefectKind.clippedByAncestor,
        ),
        isEmpty,
        reason: 'an empty intersection is not ink an ancestor can cut',
      );
    },
  );
}
