/// Loads the application's bundled fonts into the test engine.
///
/// `flutter_test` otherwise renders with the Ahem placeholder font, which
/// paints every glyph as a filled box: layout is still real, but capture
/// evidence would be unreadable. Loading the same Inter/Noto Sans JP binaries
/// the application bundles keeps the visual inspection honest.
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_epub_eval/reader/script_fonts.dart';

/// Registers the bundled faces, the platform monospace family and the
/// prototype's script fallbacks, then returns the fallback family list for the
/// controller.
///
/// `flutter_test` provides no platform fonts, so without a registered
/// monospace face every code glyph would fall back to the Ahem placeholder and
/// paint as a filled box in captures. The release app resolves the same family
/// through the platform font manager.
Future<List<String>> loadPrototypeFonts(WidgetTester tester) async {
  late List<String> scriptFallbacks;
  await tester.runAsync(() async {
    scriptFallbacks = await loadScriptFallbackFamilies();
  });
  await tester.runAsync(() async {
    for (final family in ['Inter', 'Noto Sans JP']) {
      final file = File(_pathFor(family));
      if (!file.existsSync()) continue;
      final loader = FontLoader(family);
      loader.addFont(
        Future.value(
          ByteData.sublistView(Uint8List.fromList(file.readAsBytesSync())),
        ),
      );
      await loader.load();
    }
  });
  await _loadMonospace(tester);
  return scriptFallbacks;
}

/// Register a real monospace TTF as the `monospace` family, matching what the
/// platform provides to the release app.
Future<void> _loadMonospace(WidgetTester tester) async {
  final path = _systemMonospacePath();
  if (path == null) return;
  await tester.runAsync(() async {
    final loader = FontLoader('monospace');
    loader.addFont(
      Future.value(
        ByteData.sublistView(Uint8List.fromList(File(path).readAsBytesSync())),
      ),
    );
    await loader.load();
  });
}

String? _systemMonospacePath() {
  // Font collections (.ttc) cannot be loaded as a single face.
  bool usable(String path) =>
      path.isNotEmpty && !path.endsWith('.ttc') && File(path).existsSync();
  try {
    final result = Process.runSync('fc-match', ['-f', '%{file}', 'monospace']);
    if (result.exitCode == 0) {
      final path = (result.stdout as String).trim();
      if (usable(path)) return path;
    }
  } catch (_) {
    // Fall through to the fixed candidates.
  }
  for (final candidate in const [
    '/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf',
    '/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf',
    '/usr/share/fonts/noto/NotoSansMono-Regular.ttf',
  ]) {
    if (usable(candidate)) return candidate;
  }
  return null;
}

String _pathFor(String family) {
  final root = Directory.current.path;
  final candidates = ['$root/../../assets/fonts', '$root/assets/fonts'];
  final name = family == 'Inter'
      ? 'InterVariable.ttf'
      : 'NotoSansJP-Variable.ttf';
  for (final directory in candidates) {
    final file = '$directory/$name';
    if (File(file).existsSync()) return file;
  }
  return '${candidates.first}/$name';
}
