/// Bounded admission limits for the EPUB engine.
///
/// Byte limits apply before and during decompression. Large encoded images and
/// markup-heavy chapters have separate ceilings from metadata, fonts and CSS;
/// aggregate bytes and compression ratio still bound the whole archive.
library;

class EpubLimits {
  const EpubLimits({
    this.maxArchiveEntries = 4096,
    this.maxEntryBytes = 64 * 1024 * 1024,
    this.maxTotalUncompressedBytes = 512 * 1024 * 1024,
    this.maxCompressionRatio = 200,
    this.maxMetadataBytes = 4 * 1024 * 1024,
    this.maxChapterBytes = 32 * 1024 * 1024,
    this.maxXmlNodes = 200000,
    this.maxXmlTextBytes = 16 * 1024 * 1024,
    this.maxCanonicalScalars = 4 * 1024 * 1024,
    this.maxResources = 2048,
    this.maxImageBytes = 64 * 1024 * 1024,
    this.maxImagePixels = 16 * 1024 * 1024,
    this.maxFontBytes = 16 * 1024 * 1024,
    this.maxStyleSheetBytes = 1024 * 1024,
    this.maxCssRules = 20000,
    this.maxTableColumns = 64,
    this.maxListDepth = 16,
  });

  final int maxArchiveEntries;
  final int maxEntryBytes;
  final int maxTotalUncompressedBytes;
  final int maxCompressionRatio;
  final int maxMetadataBytes;
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
/// Most bounded traversals stop early at their depth bound instead of failing
/// (for example inline and block nesting); those bounds are not enforced by
/// this error. The table-cell anchor walk is the exception: a truncated walk
/// cannot prove its anchor map complete, so it fails admission instead of
/// publishing a partial map.
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
