/// Prototype-only script fallback discovery.
///
/// The application bundles Inter and Noto Sans JP. Those faces do not cover
/// Hebrew or Arabic, so a mixed-direction chapter renders tofu even though the
/// bidi *layout* is correct. Production must bundle a covering face (or rely on
/// an EPUB-embedded font); for the evaluation the prototype asks the host's
/// fontconfig for a system face so the visual evidence can distinguish
/// "missing glyph coverage" from "broken bidi layout".
///
/// The helper is deliberately optional: when `fc-match` is unavailable it
/// returns an empty list and the reader falls back to the bundled faces.
library;

import 'dart:io';

import 'package:flutter/services.dart';

/// Registers the application's bundled content faces from the repository.
///
/// The prototype runs from the repository, so the shared font binaries are
/// reachable; production bundles them through the application's asset manifest.
Future<List<String>> loadBundledContentFonts() async {
  final families = <String>[];
  for (final family in const ['Inter', 'Noto Sans JP']) {
    final path = bundledFontPath(family);
    if (path == null) continue;
    try {
      final loader = FontLoader(family);
      loader.addFont(
        Future.value(
          ByteData.sublistView(
            Uint8List.fromList(File(path).readAsBytesSync()),
          ),
        ),
      );
      await loader.load();
      families.add(family);
    } catch (_) {
      // The fallback chain still works without the bundled face.
    }
  }
  return families;
}

/// Path of a bundled content face, or null when the repository layout differs.
String? bundledFontPath(String family) {
  final root = Directory.current.path;
  final name = family == 'Inter'
      ? 'InterVariable.ttf'
      : 'NotoSansJP-Variable.ttf';
  final candidates = [
    '$root/../../assets/fonts/$name',
    '$root/assets/fonts/$name',
    '$root/../../../assets/fonts/$name',
  ];
  for (final candidate in candidates) {
    if (File(candidate).existsSync()) return candidate;
  }
  return null;
}

const List<({String language, String family, List<String> preferredFiles})>
_scriptFaces = [
  (
    language: 'he',
    family: 'Noto Sans Hebrew',
    preferredFiles: ['NotoSansHebrew', 'NotoRashiHebrew', 'DejaVuSans'],
  ),
  (
    language: 'ar',
    family: 'Noto Kufi Arabic',
    preferredFiles: ['NotoKufiArabic', 'NotoNaskhArabic', 'NotoSansArabic'],
  ),
];

/// Registers system faces for scripts the bundled fonts do not cover.
Future<List<String>> loadScriptFallbackFamilies() async {
  final families = <String>[];
  for (final face in _scriptFaces) {
    final path = _matchFace(face.language, face.preferredFiles);
    if (path == null) continue;
    try {
      final bytes = Uint8List.fromList(File(path).readAsBytesSync());
      final loader = FontLoader(face.family);
      loader.addFont(Future.value(ByteData.sublistView(bytes)));
      await loader.load();
      families.add(face.family);
    } catch (_) {
      // A missing or unreadable system face is not fatal for the prototype.
    }
  }
  return families;
}

/// Finds a covering face: fontconfig first, then the Nix store, then a few
/// conventional system paths. The lookup exists only so this prototype can
/// render scripts the bundled fonts lack; production must bundle them.
String? _matchFace(String language, List<String> preferredFiles) {
  final fontconfigPaths = _fontconfigPaths(language);
  for (final name in preferredFiles) {
    for (final path in fontconfigPaths) {
      if (path.contains(name) && File(path).existsSync()) return path;
    }
  }
  for (final path in fontconfigPaths) {
    if (File(path).existsSync()) return path;
  }
  for (final candidate in _storeCandidates(preferredFiles)) {
    final path = _findInNixStore(candidate);
    if (path != null) return path;
  }
  for (final directory in const [
    '/usr/share/fonts',
    '/System/Library/Fonts/Supplemental',
    '/Library/Fonts',
  ]) {
    for (final name in preferredFiles) {
      final file = File('$directory/$name.ttf');
      if (file.existsSync()) return file.path;
    }
  }
  return null;
}

List<String> _fontconfigPaths(String language) {
  try {
    // fc-list itself interprets the two-character `\n` escape; a literal
    // newline argument produces no output.
    final result = Process.runSync('fc-list', [
      '-f',
      r'%{file}\n',
      ':lang=$language',
    ]);
    if (result.exitCode != 0) return const [];
    return (result.stdout as String)
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
  } catch (_) {
    return const [];
  }
}

List<String> _storeCandidates(List<String> preferredFiles) => [
  for (final name in preferredFiles) 'share/fonts/noto/$name.ttf',
  for (final name in preferredFiles) 'share/fonts/truetype/$name.ttf',
];

String? _findInNixStore(String relativePath) {
  final store = Directory('/nix/store');
  if (!store.existsSync()) return null;
  try {
    for (final entry in store.listSync()) {
      if (entry is! Directory) continue;
      final candidate = File('${entry.path}/$relativePath');
      if (candidate.existsSync()) return candidate.path;
    }
  } catch (_) {
    return null;
  }
  return null;
}
