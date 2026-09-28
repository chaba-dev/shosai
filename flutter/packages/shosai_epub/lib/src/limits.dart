/// Bounded admission limits for the EPUB engine.
///
/// These mirror the shape (not the exact numbers) of the Rust `EpubLimits`
/// policy: an archive, chapter or resource that exceeds a limit is rejected
/// with a typed error instead of being truncated. The engine uses smaller
/// defaults than production so fixture tests stay fast.
library;

class EpubLimits {
  const EpubLimits({
    this.maxArchiveEntries = 4096,
    this.maxEntryBytes = 8 * 1024 * 1024,
    this.maxTotalUncompressedBytes = 64 * 1024 * 1024,
    this.maxCompressionRatio = 200,
    this.maxChapterBytes = 4 * 1024 * 1024,
    this.maxXmlNodes = 200000,
    this.maxXmlTextBytes = 16 * 1024 * 1024,
    this.maxCanonicalScalars = 4 * 1024 * 1024,
    this.maxResources = 2048,
    this.maxImageBytes = 8 * 1024 * 1024,
    this.maxImagePixels = 16 * 1024 * 1024,
    this.maxFontBytes = 8 * 1024 * 1024,
    this.maxStyleSheetBytes = 1024 * 1024,
    this.maxCssRules = 20000,
    this.maxTableColumns = 64,
    this.maxListDepth = 16,
  });

  final int maxArchiveEntries;
  final int maxEntryBytes;
  final int maxTotalUncompressedBytes;
  final int maxCompressionRatio;
  final int maxChapterBytes;
  final int maxXmlNodes;
  final int maxXmlTextBytes;
  final int maxCanonicalScalars;
  final int maxResources;
  final int maxImageBytes;
  final int maxImagePixels;
  final int maxFontBytes;
  final int maxStyleSheetBytes;
  final int maxCssRules;
  final int maxTableColumns;
  final int maxListDepth;
}

/// A typed admission failure for an admitted limit that was exceeded.
/// Some bounded traversals stop early at their depth bound instead of failing
/// (for example inline and block nesting); those bounds are not enforced by
/// this error.
class EpubLimitError implements Exception {
  const EpubLimitError(this.kind, this.limit, [this.actual]);

  final String kind;
  final int limit;
  final int? actual;

  @override
  String toString() => 'EpubLimitError($kind: ${actual ?? '?'} > $limit)';
}

/// A malformed or unsupported input that cannot be read as EPUB.
class EpubFormatError implements Exception {
  const EpubFormatError(this.message);

  final String message;

  @override
  String toString() => 'EpubFormatError($message)';
}

/// The canonical scalar ceiling for a single canonical chapter stream.
const int kMaxCanonicalScalarsPerChapter = 4 * 1024 * 1024;
