// Evidence-only generator: composes the package 3C review sheets.
//
// It asserts nothing about the application; it is kept next to the package's
// candidate-render test so the sheets the owner reviews can be regenerated from
// the same inputs:
//
//   SHOSAI_3C_SHEETS=1 SHOSAI_HARNESS_ARTIFACTS=<dir> \
//     flutter test test/visual/library_states_sheets_test.dart
//
// Each sheet places the approved Iced 1B reference capture, the committed 3B
// baseline where one exists and the 3C candidate side by side under their
// labels.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/production_shell_harness.dart';

void main() {
  setUpAll(loadHarnessFonts);

  final artifacts = harnessArtifactDirectory();
  final reference = Directory(
    '../rfd/0004/evidence/reference-shots-1b/captures',
  );
  final baselines = Directory('test/goldens');

  Future<ui.Image> load(File file) async {
    final codec = await ui.instantiateImageCodec(file.readAsBytesSync());
    return (await codec.getNextFrame()).image;
  }

  Future<void> sheet(
    WidgetTester tester,
    String name,
    String title,
    List<(String, File)> panels,
  ) async {
    await tester.runAsync(() async {
      final loaded = <(String, ui.Image)>[];
      for (final (label, file) in panels) {
        loaded.add((label, await load(file)));
      }
      const gap = 24.0;
      const header = 56.0;
      const caption = 32.0;
      var width = 32.0;
      var tallest = 0.0;
      for (final (_, image) in loaded) {
        width += image.width + gap;
        tallest = tallest > image.height ? tallest : image.height.toDouble();
      }
      final height = header + caption + tallest + gap;
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(
        Rect.fromLTWH(0, 0, width, height),
        Paint()..color = const Color(0xFFEFEFEF),
      );
      ui.Paragraph paragraph(String text, double size, Color color) =>
          (ui.ParagraphBuilder(
                  ui.ParagraphStyle(fontFamily: 'Inter', fontSize: size),
                )
                ..pushStyle(ui.TextStyle(color: color))
                ..addText(text))
              .build()
            ..layout(ui.ParagraphConstraints(width: width - 32));

      final heading = paragraph(title, 22, const Color(0xFF282724));
      canvas.drawParagraph(heading, const Offset(16, 14));

      var x = 16.0;
      for (final (labelText, image) in loaded) {
        final captionParagraph = paragraph(
          labelText,
          15,
          const Color(0xFF4D5E86),
        );
        canvas.drawParagraph(captionParagraph, Offset(x, header));
        final rect = Rect.fromLTWH(
          x,
          header + caption,
          image.width.toDouble(),
          image.height.toDouble(),
        );
        canvas.drawRect(
          rect,
          Paint()
            ..color = const Color(0xFFBBB6AC)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1,
        );
        canvas.drawImage(
          image,
          rect.topLeft,
          Paint()..filterQuality = ui.FilterQuality.none,
        );
        x += image.width + gap;
      }
      final picture = recorder.endRecording();
      final composed = await picture.toImage(width.ceil(), height.ceil());
      final data = await composed.toByteData(format: ui.ImageByteFormat.png);
      final bytes = data!.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      final directory = Directory('${artifacts.path}/comparisons')
        ..createSync(recursive: true);
      File('${directory.path}/$name.png').writeAsBytesSync(bytes);
      // ignore: avoid_print
      print(
        'sheet $name -> ${directory.path}/$name.png (${bytes.length} bytes)',
      );
    });
  }

  // Evidence-only: the sheets read the candidate renders another test file
  // writes, so the generator is skipped unless SHOSAI_3C_SHEETS=1 asks for it
  // after those renders exist, instead of depending on suite ordering.
  final enabled = Platform.environment['SHOSAI_3C_SHEETS'] == '1';

  testWidgets('3C review sheets', skip: !enabled, (tester) async {
    final sheets = <(String, String, List<(String, File)>)>[
      (
        '3c-compare-continue-1280-en',
        'W1280 EN — continue reading above the grid (LB-16)',
        [
          (
            'reference — Iced 1B lib-wide-w1280-en',
            File('${reference.path}/lib-wide-w1280-en.png'),
          ),
          (
            'before — approved 3B baseline library-normal-1280',
            File('${baselines.path}/library-normal-1280.png'),
          ),
          (
            'after — 3C candidate 3c-library-continue-1280-en',
            File('${artifacts.path}/3c-library-continue-1280-en.png'),
          ),
        ],
      ),
      (
        '3c-compare-continue-1280-ja',
        'W1280 JA — continue reading, Japanese interface',
        [
          (
            'reference — Iced 1B lib-wide-w1280-ja',
            File('${reference.path}/lib-wide-w1280-ja.png'),
          ),
          (
            'after — 3C candidate 3c-library-continue-1280-ja',
            File('${artifacts.path}/3c-library-continue-1280-ja.png'),
          ),
        ],
      ),
      (
        '3c-compare-continue-900-en-t200',
        'W900 EN T200 — continue card at 200% text (no Iced T200 exists)',
        [
          (
            'reference — Iced 1B lib-wide-w900-en (100% text)',
            File('${reference.path}/lib-wide-w900-en.png'),
          ),
          (
            'after — 3C candidate 3c-library-continue-900-en-t200',
            File('${artifacts.path}/3c-library-continue-900-en-t200.png'),
          ),
        ],
      ),
      (
        '3c-compare-continue-390-ja-t200',
        'C390 JA T200 — compact continue card at 200% text',
        [
          (
            'reference — Iced 1B lib-compact-c390-ja',
            File('${reference.path}/lib-compact-c390-ja.png'),
          ),
          (
            'after — 3C candidate 3c-library-continue-390-ja-t200',
            File('${artifacts.path}/3c-library-continue-390-ja-t200.png'),
          ),
        ],
      ),
      (
        '3c-compare-continue-no-cover-1280',
        'W1280 EN — continued book without a cover (LB-12 in the 72x100 box)',
        [
          (
            'reference — Iced 1B lib-meta-no-cover-w1280',
            File('${reference.path}/lib-meta-no-cover-w1280.png'),
          ),
          (
            'after — 3C candidate 3c-library-continue-no-cover-1280',
            File('${artifacts.path}/3c-library-continue-no-cover-1280.png'),
          ),
        ],
      ),
      (
        '3c-compare-skeleton-1280',
        'W1280 EN — first-load skeleton grid (F3)',
        [
          (
            'reference — Iced 1B lib-state-loading-skeleton-w1280',
            File('${reference.path}/lib-state-loading-skeleton-w1280.png'),
          ),
          (
            'before — approved 3B baseline library-normal-1280 (no skeleton)',
            File('${baselines.path}/library-normal-1280.png'),
          ),
          (
            'after — 3C candidate 3c-library-skeleton-1280',
            File('${artifacts.path}/3c-library-skeleton-1280.png'),
          ),
        ],
      ),
      (
        '3c-compare-skeleton-search-1280',
        'W1280 EN — search-reload skeleton with the Search results title',
        [
          (
            'reference — Iced 1B lib-state-loading-skeleton-w1280',
            File('${reference.path}/lib-state-loading-skeleton-w1280.png'),
          ),
          (
            'after — 3C candidate 3c-library-skeleton-search-1280',
            File('${artifacts.path}/3c-library-skeleton-search-1280.png'),
          ),
        ],
      ),
      (
        '3c-compare-empty-1280',
        'W1280 EN — empty library composition (LB-18)',
        [
          (
            'reference — Iced 1B lib-state-empty-w1280',
            File('${reference.path}/lib-state-empty-w1280.png'),
          ),
          (
            'before — approved 3B baseline library-empty-1280',
            File('${baselines.path}/library-empty-1280.png'),
          ),
          (
            'after — 3C candidate 3c-library-empty-1280',
            File('${artifacts.path}/3c-library-empty-1280.png'),
          ),
        ],
      ),
      (
        '3c-compare-empty-390-ja-t200',
        'C390 JA T200 — empty library at 200% text',
        [
          (
            'reference — Iced 1B lib-state-empty-c390',
            File('${reference.path}/lib-state-empty-c390.png'),
          ),
          (
            'after — 3C candidate 3c-library-empty-390-ja-t200',
            File('${artifacts.path}/3c-library-empty-390-ja-t200.png'),
          ),
        ],
      ),
      (
        '3c-compare-no-matches-1280',
        'W1280 EN — no-matches composition (LB-19)',
        [
          (
            'reference — Iced 1B lib-state-search-no-matches-w1280',
            File('${reference.path}/lib-state-search-no-matches-w1280.png'),
          ),
          (
            'after — 3C candidate 3c-library-no-matches-1280',
            File('${artifacts.path}/3c-library-no-matches-1280.png'),
          ),
        ],
      ),
      (
        '3c-compare-load-error-1280',
        'W1280 EN — load failure alert above the grid (LB-20)',
        [
          (
            'reference — Iced 1B lib-state-load-error-w1280',
            File('${reference.path}/lib-state-load-error-w1280.png'),
          ),
          (
            'after — 3C candidate 3c-library-load-error-1280',
            File('${artifacts.path}/3c-library-load-error-1280.png'),
          ),
        ],
      ),
      (
        '3c-compare-paging-loading-1280',
        'W1280 EN — next page pending: the reference loading-more row',
        [
          (
            'reference — Iced 1B lib-state-loading-more-w1280',
            File('${reference.path}/lib-state-loading-more-w1280.png'),
          ),
          (
            'after — 3C candidate 3c-library-loading-more-1280',
            File('${artifacts.path}/3c-library-loading-more-1280.png'),
          ),
        ],
      ),
      (
        '3c-compare-paging-failure-1280',
        'W1280 EN — paging failure: the alert and Retry at the paging row',
        [
          (
            'reference — Iced 1B lib-state-load-error-w1280 (its alert above the grid; the reference has no automatic paging)',
            File('${reference.path}/lib-state-load-error-w1280.png'),
          ),
          (
            'after — 3C candidate 3c-library-paging-failure-1280',
            File('${artifacts.path}/3c-library-paging-failure-1280.png'),
          ),
        ],
      ),
      (
        '3c-compare-empty-error-1280',
        'W1280 EN — empty library with a load failure',
        [
          (
            'reference — Iced 1B lib-state-storage-error-w900',
            File('${reference.path}/lib-state-storage-error-w900.png'),
          ),
          (
            'after — 3C candidate 3c-library-empty-error-1280',
            File('${artifacts.path}/3c-library-empty-error-1280.png'),
          ),
        ],
      ),
      (
        '3c-compare-debt-1280',
        'W1280 — cleanup and deletion debt (retained Flutter surfaces)',
        [
          (
            'reference — Iced 1B lib-state-remove-pending-w1280',
            File('${reference.path}/lib-state-remove-pending-w1280.png'),
          ),
          (
            'after — 3C candidate 3c-library-debt-1280',
            File('${artifacts.path}/3c-library-debt-1280.png'),
          ),
        ],
      ),
    ];

    for (final (name, title, panels) in sheets) {
      await sheet(tester, name, title, panels);
    }
  });
}
