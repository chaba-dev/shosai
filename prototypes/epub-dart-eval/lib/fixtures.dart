/// Fixture discovery for the prototype app and measurement harness.
///
/// Paths are resolved relative to the repository root so the same list works
/// from a `flutter test`, a `flutter run`, or a built Linux bundle launched
/// from the prototype directory.
library;

import 'dart:io';

class PrototypeFixture {
  const PrototypeFixture({required this.name, required this.path});

  final String name;
  final String path;
}

/// Candidate repository roots, in priority order.
List<String> repositoryRoots() {
  final candidates = <String>[];
  final fromEnvironment = Platform.environment['SHOSAI_REPO_ROOT'];
  if (fromEnvironment != null && fromEnvironment.isNotEmpty) {
    candidates.add(fromEnvironment);
  }
  final cwd = Directory.current.path;
  // tools/epub-dart-eval/scripts runs from the prototype directory.
  candidates.addAll(['$cwd/../../..', cwd, '$cwd/..', '$cwd/../..']);
  return [
    for (final candidate in candidates)
      if (Directory(candidate).existsSync()) candidate,
  ];
}

String? _firstExisting(List<String> candidates) {
  for (final candidate in candidates) {
    if (File(candidate).existsSync()) return candidate;
  }
  return null;
}

/// The evaluation fixture set.
List<PrototypeFixture> prototypeFixtures() {
  final roots = repositoryRoots();
  final generated = <PrototypeFixture>[];
  final conformance = <PrototypeFixture>[];
  for (final root in roots) {
    final fixtureRoot = '$root/prototypes/epub-dart-eval/fixtures';
    for (final entry in [
      ('Rich chapter', '$fixtureRoot/rich-chapter.epub'),
      ('Long chapter', '$fixtureRoot/long-chapter.epub'),
    ]) {
      final path = _firstExisting([entry.$2]);
      if (path != null) {
        generated.add(PrototypeFixture(name: entry.$1, path: path));
      }
    }
    final conformanceRoot =
        '$root/crates/shosai-core/tests/fixtures/epub-conformance';
    for (final entry in [
      ('Conformance (all cases)', 'conformance.epub'),
      ('Bidirectional text', 'bidi.epub'),
      ('Tables', 'table.epub'),
      ('Embedded fonts', 'fonts.epub'),
      ('Nested images', 'nested-image.epub'),
      ('MathML', 'mathml.epub'),
      ('Links', 'links.epub'),
      ('CSS cascade', 'css-cascade.epub'),
    ]) {
      final path = _firstExisting(['$conformanceRoot/${entry.$2}']);
      if (path != null) {
        conformance.add(PrototypeFixture(name: entry.$1, path: path));
      }
    }
    if (generated.isNotEmpty || conformance.isNotEmpty) break;
  }
  return [...generated, ...conformance];
}

/// Path of one fixture by name, or null when the repository layout differs.
String? fixturePath(String name) {
  for (final fixture in prototypeFixtures()) {
    if (fixture.name == name) return fixture.path;
  }
  return null;
}
