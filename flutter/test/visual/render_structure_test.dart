import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_flutter/src/rust/api.dart';

import '../support/production_shell_harness.dart';

/// Controls for the platform golden policy and its structural diagnostic.
///
/// The gate is a pixel comparison against the running platform's own baseline:
/// the committed reference golden on Linux, and a reviewed baseline under
/// `test/goldens/<platform>/` elsewhere, with an unresolved platform failing
/// rather than passing. The structural comparison is a diagnostic that is
/// recorded with the artifacts, so these controls also document what it cannot
/// see.
void main() {
  setUpAll(loadHarnessFonts);

  /// A synthetic frame: [background] with [ink] rectangles painted on it.
  HarnessImage frame({
    int width = 1280,
    int height = 800,
    int background = 0xffffffff,
    List<Rect> ink = const [],
    int shiftX = 0,
  }) {
    final rgba = Uint8List(width * height * 4);
    for (var pixel = 0; pixel < width * height; pixel += 1) {
      final offset = pixel * 4;
      rgba[offset] = background >> 16 & 0xff;
      rgba[offset + 1] = background >> 8 & 0xff;
      rgba[offset + 2] = background & 0xff;
      rgba[offset + 3] = 0xff;
    }
    for (final rect in ink) {
      for (var y = rect.top.toInt(); y < rect.bottom.toInt(); y += 1) {
        for (
          var x = rect.left.toInt() + shiftX;
          x < rect.right.toInt() + shiftX;
          x += 1
        ) {
          if (x < 0 || y < 0 || x >= width || y >= height) continue;
          final offset = (y * width + x) * 4;
          rgba[offset] = 0x11;
          rgba[offset + 1] = 0x11;
          rgba[offset + 2] = 0x11;
          rgba[offset + 3] = 0xff;
        }
      }
    }
    return HarnessImage(width: width, height: height, rgba: rgba);
  }

  const cards = [
    Rect.fromLTWH(40, 120, 300, 200),
    Rect.fromLTWH(360, 120, 300, 200),
    Rect.fromLTWH(680, 120, 300, 200),
  ];

  test('the golden policy is per platform', () {
    expect(
      goldenComparisonMode(harnessGoldenReferencePlatform),
      HarnessGoldenMode.reference,
      reason: 'the committed goldens record the reference platform',
    );
    expect(
      goldenComparisonMode('macos'),
      HarnessGoldenMode.platformBaseline,
      reason: 'another platform needs its own reviewed baseline',
    );
    expect(
      harnessPlatformGoldenDirectory('macos'),
      'test/goldens/macos',
      reason: 'the baseline path is explicit, not shared with the reference',
    );
    expect(
      platformGoldenFile('macos', 'library-normal-1280'),
      isNotNull,
      reason: 'the reviewed macOS baseline is committed under its own path',
    );
    expect(
      platformGoldenFile('windows', 'library-normal-1280'),
      isNull,
      reason: 'a platform without a reviewed baseline stays unresolved',
    );
  });

  test('the baseline matcher path resolves where the baseline lives', () {
    // matchesGoldenFile resolves against the test entrypoint directory
    // (flutter/test/visual), so a baseline under flutter/test/goldens/<platform>
    // must be reached with one `..`; a duplicated `test/test` segment would
    // silently compare against a different file or fail.
    expect(
      harnessGoldenMatcherPath('linux', 'library-normal-1280'),
      '../goldens/library-normal-1280.png',
    );
    expect(
      harnessGoldenMatcherPath('macos', 'library-normal-1280'),
      '../goldens/macos/library-normal-1280.png',
    );
    String resolve(String from, String path) {
      final parts = from.split('/')..addAll(path.split('/'));
      final out = <String>[];
      for (final part in parts) {
        if (part == '..') {
          if (out.isNotEmpty) out.removeLast();
          continue;
        }
        if (part == '.' || part.isEmpty) continue;
        out.add(part);
      }
      return out.join('/');
    }

    expect(
      resolve('test/visual', harnessGoldenMatcherPath('macos', 'x')),
      'test/goldens/macos/x.png',
      reason: 'the matcher path must land on the committed baseline',
    );
    expect(
      resolve('test/visual', harnessGoldenMatcherPath('linux', 'x')),
      'test/goldens/x.png',
    );
  });

  test('the structural comparison is a diagnostic, not a gate', () {
    // Two changes a reviewer must catch that this diagnostic cannot: they keep
    // every aggregate metric identical. The pixel comparison against the
    // platform baseline is the gate; these controls document the limit so the
    // diagnostic is never mistaken for one.
    final smallRemoved = compareRenderStructure(
      'removed-small-control',
      expected: frame(ink: const [Rect.fromLTWH(0, 0, 100, 30)]),
      actual: frame(),
    );
    expect(
      smallRemoved.structureOk,
      isTrue,
      reason: 'a 100x30 element is below the aggregate thresholds',
    );

    final movedInsideBlock = compareRenderStructure(
      'moved-inside-block',
      expected: frame(ink: const [Rect.fromLTWH(2, 2, 8, 8)]),
      actual: frame(ink: const [Rect.fromLTWH(28, 2, 8, 8)]),
    );
    expect(
      movedInsideBlock.structureOk,
      isTrue,
      reason: 'a move inside one block keeps every block count identical',
    );
  });

  test('an identical render passes structurally', () {
    final drift = compareRenderStructure(
      'identical',
      expected: frame(ink: cards),
      actual: frame(ink: cards),
    );
    expect(drift.structureOk, isTrue);
    expect(drift.pixelDiff, 0);
    expect(drift.inkRatioDelta, 0);
    expect(drift.changedBlocks, 0);
  });

  test('a one-pixel rasterisation shift passes structurally', () {
    final drift = compareRenderStructure(
      'shifted',
      expected: frame(ink: cards),
      actual: frame(ink: cards, shiftX: 1),
    );
    expect(
      drift.structureOk,
      isTrue,
      reason: 'host rasterisation moves glyph edges by about a pixel',
    );
    expect(drift.pixelDiff, greaterThan(0));
    expect(drift.maxChannelDelta, greaterThan(0));
    expect(drift.changedBlocks, lessThanOrEqualTo(harnessStructureBlockLimit));
  });

  test('a colour-only change passes structurally', () {
    // The structural diagnostic is insensitive to palette values: a surface
    // tint changes pixels without moving ink. The pixel comparison against the
    // platform baseline is the gate.
    final drift = compareRenderStructure(
      'tinted',
      expected: frame(ink: cards),
      actual: frame(background: 0xfff8f4, ink: cards),
    );
    expect(drift.structureOk, isTrue);
    expect(drift.pixelDiff, greaterThan(0));
  });

  test('a removed element fails structurally', () {
    final drift = compareRenderStructure(
      'removed',
      expected: frame(ink: cards),
      actual: frame(ink: cards.sublist(0, 2)),
    );
    expect(
      drift.structureOk,
      isFalse,
      reason: 'a missing card is a structural change',
    );
    expect(drift.changedBlocks, greaterThan(harnessStructureBlockLimit));
    expect(drift.notes, isNotEmpty);
  });

  test('a moved element fails structurally', () {
    final moved = [cards[0], cards[1], cards[2].translate(0, 260)];
    final drift = compareRenderStructure(
      'moved',
      expected: frame(ink: cards),
      actual: frame(ink: moved),
    );
    expect(drift.structureOk, isFalse, reason: 'a moved card is a change');
  });

  test('a size change fails structurally', () {
    final drift = compareRenderStructure(
      'resized',
      expected: frame(ink: cards),
      actual: frame(width: 900, height: 700, ink: cards),
    );
    expect(drift.structureOk, isFalse);
    expect(drift.notes.join(), contains('size changed'));
  });

  testWidgets('a real render pair is compared structurally', (tester) async {
    // Two real production-shell renders: the same state twice passes, and a
    // library with one card fewer fails, so the diagnostic is exercised on
    // rendered pixels and not only on synthetic frames.
    const view = HarnessView(size: Size(1280, 800));
    Future<HarnessImage> render(List<FlutterLibraryBook> books) async {
      final bridge = HarnessBridge(books: books, covers: harnessCovers());
      view.apply(tester);
      // Dispose the previous shell first: pumping another shell of the same
      // type would update the existing state and keep the previous library.
      await tester.pumpWidget(const SizedBox.shrink());
      await renderHarnessState(
        tester,
        productionApp(bridgeFactory: () => bridge),
        ready: () => harnessImagesReady(tester),
      );
      final bytes = await captureHarnessPng(tester);
      final image = await tester.runAsync(() => decodeHarnessImage(bytes));
      return image!;
    }

    final full = harnessLibraryBooks();
    final first = await render(full);
    final second = await render(full);
    final same = compareRenderStructure(
      'repeat',
      expected: first,
      actual: second,
    );
    expect(same.structureOk, isTrue, reason: same.describe());
    expect(same.pixelDiff, 0, reason: 'the same state renders identically');

    final fewer = await render(full.sublist(0, full.length - 1));
    final changed = compareRenderStructure(
      'fewer-books',
      expected: first,
      actual: fewer,
    );
    expect(
      changed.structureOk,
      isFalse,
      reason:
          'removing a book changes the rendered structure: '
          '${changed.describe()}',
    );
    expect(changed.notes, isNotEmpty);
  });
}
