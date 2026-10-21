/// Library records.
library;

import '../errors.dart';

/// Formats the library admits.
enum BookFormat {
  pdf,
  epub;

  /// The format for a file extension (without the dot), ignoring case.
  static BookFormat? fromExtension(String extension) =>
      switch (extension.toLowerCase()) {
        'pdf' => BookFormat.pdf,
        'epub' => BookFormat.epub,
        _ => null,
      };

  static BookFormat fromDatabase(String value) => switch (value) {
    'pdf' => BookFormat.pdf,
    'epub' => BookFormat.epub,
    _ => throw CoreException.malformed('Unknown stored book format "$value".'),
  };

  String get displayName => switch (this) {
    BookFormat.pdf => 'PDF',
    BookFormat.epub => 'EPUB',
  };
}

/// Where the library expects a book's bytes to live.
enum StorageKind {
  /// The person's own file, left where it was.
  referenced,

  /// A private copy in the managed library directory, named by its content.
  managed;

  static StorageKind fromDatabase(String value) => switch (value) {
    'referenced' => StorageKind.referenced,
    'managed' => StorageKind.managed,
    _ => throw CoreException.malformed('Unknown stored storage kind "$value".'),
  };
}

/// One book in the library.
///
/// A book's identity is its content: the library holds at most one book per
/// SHA-256 [contentHash], and reading state, bookmarks and annotations follow
/// that identity rather than a path.
final class Book {
  const Book({
    required this.id,
    required this.title,
    required this.author,
    required this.format,
    required this.path,
    required this.storageKind,
    required this.originalPath,
    required this.contentHash,
    required this.fileSize,
    required this.hasCover,
    required this.progress,
    required this.dateAdded,
    required this.lastRead,
  });

  final int id;
  final String title;
  final String? author;
  final BookFormat format;

  /// The file the reader opens: the person's file, or the managed copy.
  final String path;
  final StorageKind storageKind;

  /// The path the book was imported from.
  final String originalPath;

  /// Lowercase hexadecimal SHA-256 of the file's bytes.
  final String contentHash;
  final int fileSize;
  final bool hasCover;

  /// Reading progress from 0 to 1.
  final double progress;

  /// ISO 8601 UTC timestamps.
  final String dateAdded;
  final String? lastRead;

  bool get managed => storageKind == StorageKind.managed;

  @override
  bool operator ==(Object other) =>
      other is Book &&
      other.id == id &&
      other.title == title &&
      other.author == author &&
      other.format == format &&
      other.path == path &&
      other.storageKind == storageKind &&
      other.originalPath == originalPath &&
      other.contentHash == contentHash &&
      other.fileSize == fileSize &&
      other.hasCover == hasCover &&
      other.progress == progress &&
      other.dateAdded == dateAdded &&
      other.lastRead == lastRead;

  @override
  int get hashCode => Object.hash(
    id,
    title,
    author,
    format,
    path,
    storageKind,
    originalPath,
    contentHash,
    fileSize,
    hasCover,
    progress,
    dateAdded,
    lastRead,
  );

  @override
  String toString() => 'Book($id, $title, ${format.name}, ${storageKind.name})';
}

/// One bounded page of library books, most recently read first.
final class LibraryPage {
  const LibraryPage(this.books, {required this.hasMore});

  final List<Book> books;
  final bool hasMore;
}

/// The outcome of importing one selected file.
final class ImportItem {
  const ImportItem.imported(this.path, Book this.book, {this.duplicate = false})
    : error = null;

  const ImportItem.failed(this.path, String this.error)
    : book = null,
      duplicate = false;

  /// The path that was selected or discovered.
  final String path;
  final Book? book;

  /// True when the content was already in the library; [book] is that book.
  final bool duplicate;
  final String? error;
}

/// What an import did. Items are capped at [maxImportReportItems]; the
/// counts cover every file.
final class ImportReport {
  const ImportReport({
    required this.imported,
    required this.failed,
    required this.cancelled,
    required this.items,
  });

  final int imported;
  final int failed;

  /// True when cancellation stopped the import after some files finished.
  final bool cancelled;
  final List<ImportItem> items;
}

/// The outcome of removing a book.
final class RemoveOutcome {
  const RemoveOutcome({
    required this.removed,
    required this.managedFileDeletionPending,
  });

  /// False when no such book existed.
  final bool removed;

  /// True when the private copy could not be deleted yet; the deletion is
  /// recorded and retried on a later start.
  final bool managedFileDeletionPending;
}

const maxImportReportItems = 256;
