/// Shared catalog storage and publication formats. Catalog files are
/// replaceable and never belong to the personal library store.
library;

import 'dart:convert';

export 'src/catalog/catalog_client.dart';

const catalogDatabaseVersion = 2;
const catalogFormatVersion = 2;

/// Published tables in foreign-key insertion order. Each `<table>/<part>.json`
/// is an array with one row per line, ordered by `orderBy`. Editions use the
/// first hex digit of SHA-256(book_id) for stable partitions; other tables
/// occupy a single file. Partitions never depend on the number or size of rows.
const catalogTables = {
  'sources': (orderBy: 'id', parts: '0'),
  'books': (orderBy: 'id', parts: '0'),
  'authors': (orderBy: 'id', parts: '0'),
  'subjects': (orderBy: 'id', parts: '0'),
  'categories': (orderBy: 'id', parts: '0'),
  'editions': (orderBy: 'book_id, display_order', parts: '0123456789abcdef'),
  'book_authors': (orderBy: 'book_id, position', parts: '0'),
  'book_subjects': (orderBy: 'subject_id, book_id', parts: '0'),
  'book_categories': (orderBy: 'category_id, book_id', parts: '0'),
};

/// Descriptive tables added within format 2. A manifest lists all of a
/// table's partitions or none of them, so snapshots without them still load
/// and readers that predate them verify but ignore the files. Imported after
/// [catalogTables]; `book_details` partitions like editions.
const optionalCatalogTables = {
  'author_details': (orderBy: 'author_id', parts: '0'),
  'book_details': (orderBy: 'book_id', parts: '0123456789abcdef'),
  'book_series': (orderBy: 'book_id, series', parts: '0'),
};

/// Apply to a fresh catalog database with no user data. The publisher supplies
/// work IDs and explicit edition groupings. Edition IDs are scoped to their
/// source and include the upstream format/variant where needed.
/// Within a work, display editions in ascending `display_order`; the first is
/// the default. Show `variant_label` rather than deriving it from the ID.
/// A source's optional `support_url` enables its donation action; null omits it.
/// `author_details` gives a reading-order name and life years when known;
/// years before the common era are negative. `book_details` holds the source's
/// summary as published and a rounded Flesch reading-ease score, which may fall
/// outside 0–100, plus a plain-text long description (paragraphs separated by
/// blank lines), a word count and the edition's release date (`YYYY-MM-DD`).
/// `book_series` names each series a work belongs to and its position when
/// known. None of them invents a value the source does not supply.
///
/// Tables may gain nullable columns within a format version: [importCatalog]
/// loads the columns this version knows, treats a missing nullable column as
/// null and ignores the rest, so older builds keep installing newer snapshots.
/// A database installed by an earlier build may lack recently added columns.
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
CREATE TABLE author_details (
  author_id TEXT PRIMARY KEY REFERENCES authors(id),
  display_name TEXT NOT NULL CHECK (length(trim(display_name)) > 0),
  birth_year INTEGER,
  death_year INTEGER
) STRICT;
CREATE TABLE book_details (
  book_id TEXT PRIMARY KEY REFERENCES books(id),
  summary TEXT CHECK (length(trim(summary)) > 0),
  reading_ease INTEGER,
  description TEXT CHECK (length(trim(description)) > 0),
  word_count INTEGER CHECK (word_count > 0),
  released TEXT CHECK (released IS NULL OR (length(released) = 10 AND date(released) IS released))
) STRICT;
CREATE TABLE book_series (
  book_id TEXT NOT NULL REFERENCES books(id),
  series TEXT NOT NULL CHECK (length(trim(series)) > 0),
  position INTEGER CHECK (position > 0),
  PRIMARY KEY (book_id, series)
) STRICT;
PRAGMA user_version = $catalogDatabaseVersion;
COMMIT;
''';

/// Metadata for a published file. Size and digest describe the file bytes
/// before any HTTP transport compression.
typedef CatalogFile = ({int sizeBytes, String sha256});

final class CatalogManifest {
  CatalogManifest._(
    this.builtAt,
    this.sourceCounts,
    this.files,
    this.thumbnails,
  );

  static const fileName = 'manifest.json';

  final DateTime builtAt;

  /// Counts downloadable editions per source, not grouped works.
  final Map<String, int> sourceCounts;
  final Map<String, CatalogFile> files;

  /// Cover images under `thumbnails/`, which editions name by relative
  /// `cover_url`. Apps load each one when shown, never as part of an update.
  final Map<String, CatalogFile> thumbnails;

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
      final files = _inventory(entries);
      if (files.keys.any((path) => path.startsWith('thumbnails/'))) {
        throw const FormatException('Invalid catalog file entry');
      }
      final thumbnails = switch (json['thumbnails']) {
        null => const <String, CatalogFile>{},
        final Map<String, dynamic> listed => _inventory(listed),
        _ => throw const FormatException('Invalid catalog thumbnails'),
      };
      if (!thumbnails.keys.every(_thumbnail.hasMatch)) {
        throw const FormatException('Invalid catalog thumbnail entry');
      }
      for (final entry in catalogTables.entries) {
        for (final part in entry.value.parts.split('')) {
          if (!files.containsKey('${entry.key}/$part.json')) {
            throw FormatException(
              'Missing catalog partition: ${entry.key}/$part',
            );
          }
        }
      }
      for (final entry in optionalCatalogTables.entries) {
        final listed = entry.value.parts
            .split('')
            .where((part) => files.containsKey('${entry.key}/$part.json'))
            .length;
        if (listed != 0 && listed != entry.value.parts.length) {
          throw FormatException('Incomplete catalog table: ${entry.key}');
        }
      }
      return CatalogManifest._(
        builtAt,
        Map.unmodifiable(sourceCounts),
        Map.unmodifiable(files),
        Map.unmodifiable(thumbnails),
      );
    }
    throw const FormatException('Invalid or unsupported catalog manifest');
  }

  static Map<String, CatalogFile> _inventory(Map<String, dynamic> entries) {
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
    return files;
  }

  static final _hex = RegExp(r'^[0-9a-f]+$');
  static final _thumbnail = RegExp(r'^thumbnails/[0-9a-f]{40}\.jpg$');
  static final _fileSegment = RegExp(r'^[a-zA-Z0-9_-][a-zA-Z0-9_.-]*$');
}
