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

/// Registers the bundled faces plus the prototype's script fallbacks and
/// returns the fallback family list for the controller.
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
  return scriptFallbacks;
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
