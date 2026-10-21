/// A book's text, unit by unit, as the format engine lays it out.
library;

import 'cancellation.dart';

/// One unit's text as the format engine lays it out now.
final class UnitText {
  const UnitText(this.text, {this.resourcePath});

  /// Canonical text, indexed in Unicode scalars like the anchors.
  final String text;

  /// EPUB: the spine item's canonical resource path.
  final String? resourcePath;
}

/// The book being read, unit by unit, as annotations and search need it.
/// Supplied by the format engine.
abstract interface class UnitTextSource {
  /// EPUB spine items or PDF pages.
  int get unitCount;

  /// The text of [unit], or null when it has none whose characters map to
  /// the page (a scanned PDF page, say).
  Future<UnitText?> unitText(int unit, {CancellationToken? cancellation});
}
