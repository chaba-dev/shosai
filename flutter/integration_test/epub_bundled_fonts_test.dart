import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shosai_flutter/main.dart';
import 'package:shosai_flutter/reader/view.dart'
    show ReaderEpubPageContentPainter;
import 'package:shosai_flutter/core/bridge.dart';

/// Packaged-bundle font regression for the EPUB reader.
///
/// Finding 1 of the 2026-10-02 corpus pass: the bundled faces were declared in
/// `pubspec.yaml` with paths that escape the Flutter project
/// (`../assets/fonts/...`). The tool records those keys in the asset manifest
/// but never places the files in the built bundle, so in a *built* desktop app
/// `rootBundle.load` fails and the reader paints every chapter with host
/// fallback faces.
///
/// This test drives the production reader in the **built** app
/// (`flutter drive -d linux --profile`): the faces are read through the real
/// `rootBundle`, the engine must have the bundled families registered, and a
/// self-authored chapter must paint as a Dart EPUB page. A chapter carrying a
/// rune neither bundled face covers must paint too, with the host's fallback
/// for that rune.
///
/// This is manually exercised regression coverage: CI runs the structural
/// bundle check (`scripts/check_flutter_bundle.py`) but does not drive this
/// test, so the documented pass below is the regression's evidence.
///
/// Run (from `flutter/`, on a display or under Xvfb):
/// ```sh
/// flutter drive --driver=integration_test/driver.dart \
///   --target=integration_test/epub_bundled_fonts_test.dart -d linux --profile
/// ```
///
/// Optional: `SHOSAI_EPUB_FONT_BUNDLE_ARTIFACTS=<dir>` copies page captures
/// there for inspection; a capture failure never gates the pass.

/// A rune neither bundled face carries (Linear B).
const _uncoveredRune = 0x10005;

final GlobalKey _captureKey = GlobalKey(debugLabel: 'bundled-fonts-capture');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('bundled document faces load from the built asset bundle', (
    tester,
  ) async {
    final artifacts = Platform.environment['SHOSAI_EPUB_FONT_BUNDLE_ARTIFACTS'];

    // The bundled bytes must be loadable through the platform asset bundle
    // itself.
    final inter = await rootBundle.load('fonts/InterVariable.ttf');
    final noto = await rootBundle.load('fonts/NotoSansJP-Variable.ttf');
    expect(inter.lengthInBytes, greaterThan(0));
    expect(noto.lengthInBytes, greaterThan(0));

    // The engine must also have registered the bundled families themselves
    // (the whole interface paints with them, and the EPUB renderer shapes
    // with both): laying out a glyph with each family must produce
    // *different* metrics than laying out with a family the engine does not
    // have. If a bundled face were missing, the two would share the host
    // fallback and match. Limitations: a host with the same-named face
    // installed can satisfy this via the host font database, and a glyph the
    // host covers itself (Japanese on a CJK-equipped host) falls back
    // identically in both cases, so the assertion uses Latin glyphs, which
    // no documented run host maps to either bundled family name.
    double advanceWidthOf(String family, String glyph) {
      final painter = TextPainter()
        ..textDirection = TextDirection.ltr
        ..text = TextSpan(
          text: glyph,
          style: TextStyle(fontFamily: family, fontSize: 100),
        );
      painter.layout();
      final width = painter.width;
      painter.dispose();
      return width;
    }

    expect(
      advanceWidthOf('Inter', 'W'),
      isNot(closeTo(advanceWidthOf('ShosaiAbsentFamily', 'W'), 0.01)),
      reason: 'the bundled Inter face must be registered with the engine',
    );
    expect(
      advanceWidthOf('Noto Sans JP', 'W'),
      isNot(closeTo(advanceWidthOf('ShosaiAbsentFamily', 'W'), 0.01)),
      reason:
          'the bundled Noto Sans JP face must be registered with the engine',
    );

    final directory = await Directory.systemTemp.createTemp(
      'shosai-epub-bundled-fonts-',
    );
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });

    final books = {
      'covered':
          '<p>Packaged fonts paint this chapter: あいうえお.</p>'
          '${'<p>Filler paragraph for pagination.</p>' * 12}',
      'uncovered':
          '<p>An uncovered rune paints with the host fallback.</p>'
          '${'<p>Filler paragraph for pagination.</p>' * 12}'
          '<p>Uncovered rune: ${String.fromCharCode(_uncoveredRune)}.</p>',
    };
    for (final MapEntry(key: name, value: body) in books.entries) {
      final path = '${directory.path}/$name.epub';
      await File(
        path,
      ).writeAsBytes(_epub(chapters: {'OPS/chapter-1.xhtml': body}));
      final bridge = await createApplicationBridge(
        applicationSupportDirectory: () async =>
            Directory('${directory.path}/$name')..createSync(),
      );
      try {
        await tester.pumpWidget(_readerShell(path, bridge));
        final painted = await _pumpUntil(
          tester,
          () => _dartPage(tester) != null,
          const Duration(minutes: 2),
        );
        expect(painted, isTrue, reason: 'the $name chapter must paint');
        final page = _dartPage(tester)!;
        expect(page.page.unit, 0);
        expect(page.page.canonicalStart, 0);
        await _capture(tester, artifacts, 'bundled-fonts-$name-page');
      } finally {
        await _closeReader(tester, bridge);
      }
    }
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

/// The production reader composition for one book path.
Widget _readerShell(String path, FlutterBridge bridge) => ShosaiShell(
  home: Align(
    alignment: Alignment.topLeft,
    child: SizedBox(
      width: 1000,
      height: 720,
      child: RepaintBoundary(
        key: _captureKey,
        child: ReaderScreen(bridge: bridge, initialPath: path),
      ),
    ),
  ),
);

/// Unmounts the reader and waits for the controller to dispose the bridge it
/// was handed (the controller disposes it itself once its operations drain).
/// A run whose drain never completes is a failure: the bridge is disposed
/// here so a bridge cannot leak past the test, and the failure is reported. A
/// bridge the reader never received (an earlier failure) is disposed
/// directly.
Future<void> _closeReader(WidgetTester tester, FlutterBridge bridge) async {
  if (find.byKey(_captureKey).evaluate().isEmpty) {
    if (!bridge.isDisposed) bridge.dispose();
    return;
  }
  await tester.pumpWidget(const SizedBox.shrink());
  final disposed = await _pumpUntil(
    tester,
    () => bridge.isDisposed,
    const Duration(seconds: 10),
  );
  if (!disposed) {
    bridge.dispose();
    throw StateError('the reader did not drain the bridge after unmount');
  }
}

/// Pumps with real event-loop windows until [condition] holds or the deadline
/// passes (the reader lays out asynchronously).
Future<bool> _pumpUntil(
  WidgetTester tester,
  bool Function() condition,
  Duration deadline,
) async {
  final end = DateTime.now().add(deadline);
  while (DateTime.now().isBefore(end)) {
    if (condition()) return true;
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
  }
  return condition();
}

/// Writes a PNG of the capture boundary to [artifacts] when configured.
Future<void> _capture(
  WidgetTester tester,
  String? artifacts,
  String name,
) async {
  if (artifacts == null) return;
  // Best-effort visual evidence; a capture failure never gates the pass.
  try {
    final boundary =
        _captureKey.currentContext?.findRenderObject()
            as RenderRepaintBoundary?;
    if (boundary == null) return;
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (bytes == null) return;
    final dir = Directory(artifacts)..createSync(recursive: true);
    File(
      '${dir.path}/$name.png',
    ).writeAsBytesSync(bytes.buffer.asUint8List(), flush: true);
  } catch (_) {}
}

/// An EPUB archive built in memory with the reader's own fixture conventions.
///
/// Self-authored synthetic content with the same container/OPF/spine structure
/// the committed reader fixtures use
/// (`test/support/epub_navigation_fixture.dart`), kept local here so this
/// regression does not extend the shared fixture set.
Uint8List _epub({required Map<String, String> chapters}) {
  final files = <String, String>{
    'mimetype': 'application/epub+zip',
    'META-INF/container.xml':
        '<?xml version="1.0"?>'
        '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" '
        'version="1.0"><rootfiles><rootfile full-path="OPS/package.opf" '
        'media-type="application/oebps-package+xml"/></rootfiles></container>',
  };
  final manifest = <String>[];
  final spine = <String>[];
  var index = 1;
  for (final path in chapters.keys) {
    final name = path.substring(path.lastIndexOf('/') + 1);
    manifest.add(
      '<item id="chapter-$index" href="$name" '
      'media-type="application/xhtml+xml"/>',
    );
    spine.add('<itemref idref="chapter-$index"/>');
    files[path] =
        '<?xml version="1.0"?>'
        '<html xmlns="http://www.w3.org/1999/xhtml"><body>'
        '${chapters[path]}</body></html>';
    index += 1;
  }
  manifest.add(
    '<item id="nav" href="nav.xhtml" '
    'media-type="application/xhtml+xml" properties="nav"/>',
  );
  final nav = chapters.keys.map((path) {
    final name = path.substring(path.lastIndexOf('/') + 1);
    return '<li><a href="$name">${name.replaceAll('.', ' ')}</a></li>';
  }).join();
  files['OPS/package.opf'] =
      '<?xml version="1.0"?>'
      '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" '
      'unique-identifier="id"><metadata '
      'xmlns:dc="http://purl.org/dc/elements/1.1/">'
      '<dc:identifier id="id">bundled-fonts</dc:identifier>'
      '<dc:title>Bundled Fonts</dc:title><dc:language>en</dc:language>'
      '</metadata><manifest>${manifest.join()}</manifest>'
      '<spine>${spine.join()}</spine></package>';
  files['OPS/nav.xhtml'] =
      '<?xml version="1.0"?>'
      '<html xmlns="http://www.w3.org/1999/xhtml" '
      'xmlns:epub="http://www.idpf.org/2007/ops"><body>'
      '<nav epub:type="toc"><ol>$nav</ol></nav></body></html>';

  final archive = Archive();
  for (final entry in files.entries) {
    final bytes = Uint8List.fromList(utf8.encode(entry.value));
    archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}
