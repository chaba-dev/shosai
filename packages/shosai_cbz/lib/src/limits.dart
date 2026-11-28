/// Bounded admission limits for the CBZ engine, and its typed failures.
library;

/// Byte, entry and image ceilings applied before anything is decompressed.
///
/// The archive itself is never read whole: its central directory is read
/// once, and each page's bytes only when that page is needed.
final class CbzLimits {
  const CbzLimits({
    this.maxArchiveBytes = 512 * 1024 * 1024,
    this.maxEntries = 10000,
    this.maxDirectoryBytes = 16 * 1024 * 1024,
    this.maxEntryBytes = 128 * 1024 * 1024,
    this.maxTotalUncompressedBytes = 2 * 1024 * 1024 * 1024,
    this.maxCompressionRatio = 1000,
    this.maxComicInfoBytes = 1024 * 1024,
    this.maxImageDimension = 16384,
    this.maxImagePixels = 40000000,
  });

  final int maxArchiveBytes;
  final int maxEntries;
  final int maxDirectoryBytes;
  final int maxEntryBytes;
  final int maxTotalUncompressedBytes;
  final int maxCompressionRatio;
  final int maxComicInfoBytes;

  /// A page wider or taller than this, or with more pixels than
  /// [maxImagePixels], is measured but never decoded.
  final int maxImageDimension;
  final int maxImagePixels;
}

/// An admitted limit was exceeded.
final class CbzLimitError implements Exception {
  const CbzLimitError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The input is not a readable CBZ.
final class CbzFormatError implements Exception {
  const CbzFormatError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The archive's pages are encrypted.
final class CbzProtectedError implements Exception {
  const CbzProtectedError();

  @override
  String toString() => 'The comic archive is encrypted.';
}
