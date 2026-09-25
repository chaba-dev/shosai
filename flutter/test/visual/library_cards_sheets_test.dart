// Evidence-only generator: composes the package 3B review sheets.
//
// It asserts nothing about the application; it is kept next to the package's
// candidate-render test so the sheets the owner reviews can be regenerated from
// the same inputs:
//
//   SHOSAI_HARNESS_ARTIFACTS=<dir> flutter test test/visual/library_cards_sheets_test.dart
//
// Each sheet places the approved Iced reference capture, the committed 3A
// baseline and the 3B candidate side by side under their labels.
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
  // writes, so the generator is skipped unless SHOSAI_3B_SHEETS=1 asks for it
  // after those renders exist, instead of depending on suite ordering.
  final enabled = Platform.environment['SHOSAI_3B_SHEETS'] == '1';

  testWidgets('3B review sheets', skip: !enabled, (tester) async {
    final sheets = <(String, String, List<(String, File)>)>[
      (
        '3b-compare-wide-1280-en',
        'W1280 EN — wide library (LB-11, LB-14)',
        [
          (
            'reference — Iced 1B lib-wide-w1280-en',
            File('${reference.path}/lib-wide-w1280-en.png'),
          ),
          (
            'before — 3A baseline library-normal-1280',
            File('${baselines.path}/library-normal-1280.png'),
          ),
          (
            'after — 3B candidate 3b-library-wide-1280-en',
            File('${artifacts.path}/3b-library-wide-1280-en.png'),
          ),
        ],
      ),
      (
        '3b-compare-compact-390-en',
        'C390 EN — compact library (LB-11)',
        [
          (
            'reference — Iced 1B lib-compact-c390-en (390x844)',
            File('${reference.path}/lib-compact-c390-en.png'),
          ),
          (
            'before — 3A baseline library-compact-390 (390x780)',
            File('${baselines.path}/library-compact-390.png'),
          ),
          (
            'after — 3B candidate 3b-library-compact-390x844-en',
            File('${artifacts.path}/3b-library-compact-390x844-en.png'),
          ),
        ],
      ),
      (
        '3b-compare-meta-long-ja-1280',
        'W1280 — long Japanese and mixed metadata (LB-13)',
        [
          (
            'reference — Iced 1B lib-meta-long-ja-w1280',
            File('${reference.path}/lib-meta-long-ja-w1280.png'),
          ),
          (
            'before — 3A baseline library-mixed-1280',
            File('${baselines.path}/library-mixed-1280.png'),
          ),
          (
            'after — 3B candidate 3b-library-meta-long-ja-1280',
            File('${artifacts.path}/3b-library-meta-long-ja-1280.png'),
          ),
        ],
      ),
      (
        '3b-compare-meta-no-cover-1280',
        'W1280 — missing covers (LB-12)',
        [
          (
            'reference — Iced 1B lib-meta-no-cover-w1280',
            File('${reference.path}/lib-meta-no-cover-w1280.png'),
          ),
          (
            'after — 3B candidate 3b-library-meta-no-cover-1280',
            File('${artifacts.path}/3b-library-meta-no-cover-1280.png'),
          ),
        ],
      ),
      (
        '3b-compare-book-menu-1280',
        'W1280 — card actions menu (LB-14)',
        [
          (
            'reference — Iced 1B lib-state-book-menu-w1280',
            File('${reference.path}/lib-state-book-menu-w1280.png'),
          ),
          (
            'after — 3B candidate 3b-library-book-menu-1280',
            File('${artifacts.path}/3b-library-book-menu-1280.png'),
          ),
        ],
      ),
      (
        '3b-compare-remove-pending-1280',
        'W1280 — removal pending (LB-14)',
        [
          (
            'reference — Iced 1B lib-state-remove-pending-w1280',
            File('${reference.path}/lib-state-remove-pending-w1280.png'),
          ),
          (
            'after — 3B candidate 3b-library-remove-pending-1280',
            File('${artifacts.path}/3b-library-remove-pending-1280.png'),
          ),
        ],
      ),
      (
        '3b-compare-compact-390-ja-t200',
        'C390 JA 200% text — no Iced reference (Iced does not scale interface text)',
        [
          (
            'before — 3A baseline library-compact-390-ja-t200',
            File('${baselines.path}/library-compact-390-ja-t200.png'),
          ),
          (
            'after — 3B candidate 3b-library-compact-390x844-ja-t200',
            File('${artifacts.path}/3b-library-compact-390x844-ja-t200.png'),
          ),
        ],
      ),
      (
        '3b-compare-wide-900-ja-t200',
        'W900 JA 200% text — no Iced reference (Iced does not scale interface text)',
        [
          (
            'before — 3A baseline library-wide-900-ja-t200',
            File('${baselines.path}/library-wide-900-ja-t200.png'),
          ),
          (
            'after — 3B candidate 3b-library-wide-900-ja-t200',
            File('${artifacts.path}/3b-library-wide-900-ja-t200.png'),
          ),
        ],
      ),
    ];
    for (final (name, title, panels) in sheets) {
      for (final (_, file) in panels) {
        expect(file.existsSync(), isTrue, reason: file.path);
      }
      await sheet(tester, name, title, panels);
    }
  });
}
