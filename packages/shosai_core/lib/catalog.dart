/// Shared catalog storage and publication formats. Catalog files are
/// replaceable and never belong to the personal library store.
library;

import 'dart:convert';

const catalogDatabaseVersion = 1;
const catalogFormatVersion = 2;

/// Published tables in foreign-key insertion order, with stable row ordering
/// for partitioning. JSON shards at `<table>/<part>.json` are arrays of row
/// objects keyed by the versioned schema's column names.
const catalogTables = {
  'sources': 'id',
  'books': 'id',
  'authors': 'id',
  'subjects': 'id',
  'categories': 'id',
  'editions': 'book_id, display_order',
  'book_authors': 'book_id, position',
  'book_subjects': 'subject_id, book_id',
  'book_categories': 'category_id, book_id',
};

/// Apply to a fresh catalog database with no user data. The publisher supplies
/// work IDs and explicit edition groupings. Edition IDs are scoped to their
/// source and include the upstream format/variant where needed.
/// Within a work, display editions in ascending `display_order`; the first is
/// the default. Show `variant_label` rather than deriving it from the ID.
const catalogSchema =
    '''
PRAGMA foreign_keys = ON;
BEGIN;
CREATE TABLE sources (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  website TEXT NOT NULL,
  catalog_credit TEXT,
  support_url TEXT
) STRICT;
CREATE TABLE books (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL
) STRICT;
CREATE TABLE editions (
  source_id TEXT NOT NULL REFERENCES sources(id),
  source_edition_id TEXT NOT NULL,
  book_id TEXT NOT NULL REFERENCES books(id),
  title TEXT NOT NULL,
  variant_label TEXT NOT NULL CHECK (length(trim(variant_label)) > 0),
  display_order INTEGER NOT NULL CHECK (display_order >= 0),
  language TEXT NOT NULL,
  source_url TEXT NOT NULL,
  rights_line TEXT NOT NULL,
  acquisition_url TEXT NOT NULL,
  acquisition_format TEXT NOT NULL,
  size_bytes INTEGER CHECK (size_bytes > 0),
  cover_url TEXT,
  PRIMARY KEY (source_id, source_edition_id),
  UNIQUE (book_id, display_order)
) STRICT;
CREATE TABLE authors (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  sort_name TEXT NOT NULL,
  name_reading TEXT
) STRICT;
CREATE TABLE book_authors (
  book_id TEXT NOT NULL REFERENCES books(id),
  author_id TEXT NOT NULL REFERENCES authors(id),
  position INTEGER NOT NULL CHECK (position >= 0),
  PRIMARY KEY (book_id, position),
  UNIQUE (book_id, author_id)
) STRICT;
CREATE TABLE subjects (
  id TEXT PRIMARY KEY,
  label TEXT NOT NULL
) STRICT;
CREATE TABLE book_subjects (
  book_id TEXT NOT NULL REFERENCES books(id),
  subject_id TEXT NOT NULL REFERENCES subjects(id),
  PRIMARY KEY (subject_id, book_id)
) STRICT;
CREATE TABLE categories (
  id TEXT PRIMARY KEY,
  label TEXT NOT NULL
) STRICT;
CREATE TABLE book_categories (
  book_id TEXT NOT NULL REFERENCES books(id),
  category_id TEXT NOT NULL REFERENCES categories(id),
  PRIMARY KEY (category_id, book_id)
) STRICT;
PRAGMA user_version = $catalogDatabaseVersion;
COMMIT;
''';

/// Metadata for a published file. Size and digest describe the file bytes
/// before any HTTP transport compression.
typedef CatalogFile = ({int sizeBytes, String sha256});

final class CatalogManifest {
  CatalogManifest._(this.builtAt, this.sourceCounts, this.files);

  static const fileName = 'manifest.json';

  final DateTime builtAt;

  /// Counts downloadable editions per source, not grouped works.
  final Map<String, int> sourceCounts;
  final Map<String, CatalogFile> files;

  /// Parse and validate the manifest, not the files it describes.
  factory CatalogManifest.parse(String text) {
    final json = jsonDecode(text);
    if (json case {
      'formatVersion': int version,
      'builtAt': String date,
      'sourceCounts': Map<String, dynamic> counts,
      'files': Map<String, dynamic> entries,
    } when version == catalogFormatVersion) {
      final builtAt = DateTime.tryParse(date);
      if (builtAt == null ||
          !builtAt.isUtc ||
          builtAt.toIso8601String() != date) {
        throw const FormatException('Invalid catalog build timestamp');
      }
      final sourceCounts = <String, int>{};
      for (final entry in counts.entries) {
        final count = entry.value;
        if (entry.key.isEmpty || count is! int || count < 0) {
          throw const FormatException('Invalid catalog source count');
        }
        sourceCounts[entry.key] = count;
      }
      final files = <String, CatalogFile>{};
      for (final entry in entries.entries) {
        if (entry.value case {'sizeBytes': int size, 'sha256': String sha256}
            when size > 0 &&
                sha256.length == 64 &&
                _hex.hasMatch(sha256) &&
                entry.key.split('/').every(_fileSegment.hasMatch)) {
          files[entry.key] = (sizeBytes: size, sha256: sha256);
        } else {
          throw const FormatException('Invalid catalog file entry');
        }
      }
      for (final table in catalogTables.keys) {
        if (!files.containsKey('$table/0.json')) {
          throw FormatException('Missing catalog table: $table');
        }
      }
      return CatalogManifest._(
        builtAt,
        Map.unmodifiable(sourceCounts),
        Map.unmodifiable(files),
      );
    }
    throw const FormatException('Invalid or unsupported catalog manifest');
  }

  static final _hex = RegExp(r'^[0-9a-f]+$');
  static final _fileSegment = RegExp(r'^[a-zA-Z0-9_-][a-zA-Z0-9_.-]*$');
}
