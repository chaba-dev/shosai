/// Reversible shelf membership, independent of content and annotation identity.
library;

import 'dart:convert';

import '../annotations/quote.dart';
import '../annotations/records.dart' show newUuid, checkAnnotationSnapshot;
import '../errors.dart';
import '../search/case_fold.dart';
import '../store/store.dart';
import 'book.dart';
import 'location.dart';
import 'records.dart' show bookColumns, bookFromRow;

/// Publication facts, never inferred from a folder or an arbitrary UUID.
final class PublicationMetadata {
  const PublicationMetadata({
    this.title,
    this.contributors = const [],
    this.identifiers = const [],
    this.language,
    this.edition,
    this.volume,
  });

  final String? title;
  final List<String> contributors;
  final List<String> identifiers;
  final String? language;
  final String? edition;
  final String? volume;

  String encode() {
    final encoded = jsonEncode({
      'title': title,
      'contributors': contributors,
      'identifiers': identifiers,
      'language': language,
      'edition': edition,
      'volume': volume,
    });
    if (utf8.encode(encoded).length > 16384) {
      throw const CoreException.limitExceeded(
        'Publication metadata is too large.',
      );
    }
    return encoded;
  }

  static PublicationMetadata decode(String? encoded) {
    if (encoded == null) return const PublicationMetadata();
    final value = jsonDecode(encoded) as Map<String, dynamic>;
    return PublicationMetadata(
      title: value['title'] as String?,
      contributors: (value['contributors'] as List).cast<String>(),
      identifiers: (value['identifiers'] as List).cast<String>(),
      language: value['language'] as String?,
      edition: value['edition'] as String?,
      volume: value['volume'] as String?,
    );
  }
}

/// Canonical publication ISBN-13, including checked ISBN-10 equivalents.
/// An arbitrary numeric identifier is not an ISBN unless its checksum agrees.
String? publicationIsbn(String value) {
  var digits = value
      .replaceFirst(RegExp(r'^(urn:isbn:|isbn[: ]*)', caseSensitive: false), '')
      .replaceAll(RegExp(r'[-\s]'), '')
      .toUpperCase();
  if (RegExp(r'^\d{9}[\dX]$').hasMatch(digits)) {
    var sum = 0;
    for (var i = 0; i < 10; i++) {
      sum += (10 - i) * (digits[i] == 'X' ? 10 : int.parse(digits[i]));
    }
    if (sum % 11 != 0) return null;
    digits = '978${digits.substring(0, 9)}';
    var check = 0;
    for (var i = 0; i < 12; i++) {
      check += int.parse(digits[i]) * (i.isEven ? 1 : 3);
    }
    return '$digits${(10 - check % 10) % 10}';
  }
  if (!RegExp(r'^97[89]\d{10}$').hasMatch(digits)) return null;
  var sum = 0;
  for (var i = 0; i < 13; i++) {
    sum += int.parse(digits[i]) * (i.isEven ? 1 : 3);
  }
  return sum % 10 == 0 ? digits : null;
}

String _normalized(String value) => caseFold(normalizeQuoteV1(value))
    .replaceAll(RegExp('[’‘]'), "'")
    .replaceAll(RegExp('[“”]'), '"')
    .replaceAll(RegExp('[‐‑–—]'), '-');

String sourceEditionKey(BookLocator locator, int? size, String? revision) =>
    'source:${jsonEncode([locator.locationId, locator.key, size, revision])}';
String contentEditionKey(String hash) => 'hash:$hash';

/// One distinct file. Equal verified hashes have one member and many locations.
final class EditionFile {
  const EditionFile({
    required this.key,
    required this.title,
    required this.author,
    required this.format,
    required this.name,
    required this.source,
    required this.size,
    required this.hasCover,
    required this.publication,
    this.book,
    this.locator,
    this.unavailable = false,
    this.locations = const [],
    this.folderName,
  });

  final String key;
  final String title;
  final String? author;
  final BookFormat format;
  final String name;
  final String source;
  final int? size;
  final bool hasCover;
  final PublicationMetadata publication;
  final Book? book;
  final BookLocator? locator;
  final bool unavailable;
  final List<({String label, String key, bool unavailable})> locations;
  final String? folderName;
}

enum EditionMatchEvidence { title, filename, folder, isbn, metadataConflict }

final class BookEdition {
  const BookEdition(
    this.id,
    this.files, {
    this.preferredKey,
    this.possibleMatches = const {},
  });
  final String id;
  final List<EditionFile> files;
  final String? preferredKey;
  final Map<String, Set<EditionMatchEvidence>> possibleMatches;

  EditionFile get displayFile =>
      files.reduce((a, b) => _quality(a) >= _quality(b) ? a : b);
  EditionFile get coverFile =>
      files.where((file) => file.hasCover).firstOrNull ?? displayFile;
  EditionFile? get preferred =>
      files.where((file) => file.key == preferredKey).firstOrNull;
  Set<BookFormat> get formats => {for (final file in files) file.format};

  /// Manual confirmation can fill missing facts, never override known conflicts.
  bool canGroupWith(BookEdition other) =>
      id != other.id &&
      !files.any((a) => other.files.any((b) => _conflicts(a, b)));

  static int _quality(EditionFile file) =>
      (file.hasCover ? 4 : 0) +
      (file.publication.title != null ? 8 : 0) +
      (_bookFilename(file) ? 2 : 0) +
      (_bookFolder(file) ? 1 : 0) +
      (file.author != null ? 1 : 0);
}

final class EditionPage {
  const EditionPage(
    this.editions, {
    required this.hasMore,
    required this.bookCount,
  });
  final List<BookEdition> editions;
  final bool hasMore;
  final int bookCount;
}

/// Queries all candidates before filtering/paging. Decisions and the selected
/// file live in normalized tables, not a bounded preferences blob. Originals,
/// content hashes, positions and annotation documents are never merged.
final class LibraryEditions {
  const LibraryEditions(this._store);
  final Store _store;

  /// The local catalog for the searchable, explicit Group with… chooser.
  Future<List<BookEdition>> all({required List<BookLocator> sources}) {
    final allowed = sources
        .map((s) => jsonEncode([s.locationId, s.key]))
        .toSet();
    return _store.transaction(
      (db) => List.unmodifiable(_snapshot(db, allowed)),
    );
  }

  Future<EditionPage> page({
    required List<BookLocator> sources,
    String query = '',
    BookFormat? format,
    LibrarySort sort = LibrarySort.recent,
    int limit = 50,
    int offset = 0,
  }) {
    if (limit < 1 || limit > 500 || offset < 0) {
      throw const CoreException.invalidRequest('Invalid edition page.');
    }
    final allowed = sources
        .map((s) => jsonEncode([s.locationId, s.key]))
        .toSet();
    return _store.transaction((db) {
      final all = _snapshot(db, allowed);
      final needle = _normalized(query);
      final found = all
          .where(
            (edition) =>
                (format == null || edition.formats.contains(format)) &&
                (needle.isEmpty ||
                    edition.files.any(
                      (file) => _normalized(
                        '${file.title}\n${file.author ?? ''}\n${file.name}',
                      ).contains(needle),
                    )),
          )
          .toList();
      found.sort((a, b) {
        final left = a.displayFile;
        final right = b.displayFile;
        if (sort == LibrarySort.recent) {
          String recent(BookEdition e) => e.files
              .map((f) => f.book?.lastRead ?? f.book?.dateAdded ?? '')
              .fold('', (a, b) => a.compareTo(b) > 0 ? a : b);
          final order = recent(b).compareTo(recent(a));
          if (order != 0) return order;
        }
        if (sort == LibrarySort.author) {
          final a = left.author ?? '';
          final b = right.author ?? '';
          if (a.isEmpty != b.isEmpty) return a.isEmpty ? 1 : -1;
          final order = _normalized(a).compareTo(_normalized(b));
          if (order != 0) return order;
        }
        final order = _normalized(
          left.title,
        ).compareTo(_normalized(right.title));
        return order == 0 ? a.id.compareTo(b.id) : order;
      });
      return EditionPage(
        List.unmodifiable(found.skip(offset).take(limit)),
        hasMore: found.length > offset + limit,
        bookCount: all.length,
      );
    });
  }

  Future<void> prefer(String editionId, String fileKey) =>
      _store.transaction((db) {
        if (db.select(
          'SELECT 1 FROM shelf_members WHERE edition_id = ? AND file_key = ?',
          [editionId, fileKey],
        ).isEmpty) {
          throw const CoreException.notFound(
            'The file is no longer in this edition.',
          );
        }
        db.execute('UPDATE shelf_editions SET preferred_key = ? WHERE id = ?', [
          fileKey,
          editionId,
        ]);
      });

  /// Explicit confirmation groups whole entries. The user's decision overrides
  /// missing metadata, but never an observed edition/language/volume conflict.
  Future<void> group(
    String from,
    String into, {
    required List<BookLocator> sources,
  }) {
    return _store.transaction((db) {
      // Visibility cannot shrink the membership this whole-entry edit moves.
      final entries = _snapshot(db, null);
      final a = entries.where((e) => e.id == from).firstOrNull;
      final b = entries.where((e) => e.id == into).firstOrNull;
      if (a == null || b == null || a.id == b.id) {
        throw const CoreException.notFound(
          'Choose two different library entries.',
        );
      }
      final known = {
        for (final file in [...a.files, ...b.files]) file.key,
      };
      if (db
          .select(
            'SELECT file_key FROM shelf_members WHERE edition_id IN (?, ?)',
            [from, into],
          )
          .any((row) => !known.contains(row.columnAt(0)))) {
        throw const CoreException.invalidRequest(
          'Restore missing files to the library before grouping these entries.',
        );
      }
      if (!a.canGroupWith(b)) {
        throw const CoreException.invalidRequest(
          'These files describe different editions, languages or volumes.',
        );
      }
      checkAnnotationSnapshot(db, [
        for (final file in [...a.files, ...b.files])
          if (file.book case final book?) book.contentHash,
      ]);
      db.execute(
        'UPDATE shelf_members SET edition_id = ?, manual = 1 WHERE edition_id IN (?, ?)',
        [into, from, into],
      );
      final preferred = b.preferredKey ?? a.preferredKey;
      db.execute('UPDATE shelf_editions SET preferred_key = ? WHERE id = ?', [
        preferred,
        into,
      ]);
    });
  }

  /// Locks both sides against automatic regrouping. Notes keep their original
  /// owners; removing this relationship immediately stops sharing them.
  Future<void> separate(
    String editionId,
    String fileKey,
  ) => _store.transaction((db) {
    final rows = db.select(
      'SELECT file_key FROM shelf_members WHERE edition_id = ?',
      [editionId],
    );
    if (rows.length < 2 || !rows.any((r) => r.columnAt(0) == fileKey)) {
      throw const CoreException.notFound(
        'The file is no longer in this group.',
      );
    }
    final id = newUuid();
    db.execute('INSERT INTO shelf_editions(id) VALUES (?)', [id]);
    db.execute('UPDATE shelf_members SET manual = 1 WHERE edition_id = ?', [
      editionId,
    ]);
    db.execute('UPDATE shelf_members SET edition_id = ? WHERE file_key = ?', [
      id,
      fileKey,
    ]);
    db.execute(
      'UPDATE shelf_editions SET preferred_key = NULL WHERE id = ? AND preferred_key = ?',
      [editionId, fileKey],
    );
  });
}

List<BookEdition> _snapshot(Database db, Set<String>? allowed) {
  final files = <EditionFile>[];
  for (final row in db.select(
    'SELECT $bookColumns, publication_metadata, display_name, source_folder FROM books',
  )) {
    final book = bookFromRow(row);
    final locations = [
      for (final copy in db.select(
        '''SELECT l.label, b.locator_key, b.failure, l.removed
      FROM book_locators b JOIN library_locations l ON l.id = b.location_id
      WHERE b.content_hash = ? ORDER BY l.label, b.locator_key''',
        [book.contentHash],
      ))
        (
          label: copy.columnAt(0) as String,
          key: copy.columnAt(1) as String,
          unavailable: copy.columnAt(2) != null || copy.columnAt(3) == 1,
        ),
    ];
    files.add(
      EditionFile(
        key: contentEditionKey(book.contentHash),
        book: book,
        title: book.title,
        author: book.author,
        format: book.format,
        name:
            row.columnAt(17) as String? ??
            book.originalPath.replaceAll('\\', '/').split('/').last,
        source: locations.isEmpty ? 'On this device' : locations.first.label,
        size: book.fileSize,
        hasCover: book.hasCover,
        unavailable: book.locationFailure != null,
        locations: List.unmodifiable(locations),
        publication: row.columnAt(16) == null && book.author != null
            ? PublicationMetadata(
                title: book.title,
                contributors: [book.author!],
              )
            : PublicationMetadata.decode(row.columnAt(16) as String?),
        folderName: row.columnAt(18) as String?,
      ),
    );
  }
  for (final row in db.select(
    '''SELECT f.location_id, f.locator_key, f.name, f.size, f.revision,
      p.title, p.author, p.cover IS NOT NULL, p.publication_metadata, l.label, f.folder_name
    FROM library_source_files f JOIN library_locations l ON l.id = f.location_id
    LEFT JOIN library_source_previews p ON p.location_id = f.location_id AND p.locator_key = f.locator_key
    WHERE l.removed = 0''',
  )) {
    final locator = (
      locationId: row.columnAt(0) as String,
      key: row.columnAt(1) as String,
    );
    final name = row.columnAt(2) as String;
    final format = BookFormat.fromExtension(name.split('.').last);
    if (format == null) continue;
    final size = row.columnAt(3) as int?;
    files.add(
      EditionFile(
        key: sourceEditionKey(locator, size, row.columnAt(4) as String?),
        locator: locator,
        title:
            row.columnAt(5) as String? ??
            name.replaceFirst(RegExp(r'\.[^.]+$'), '').replaceAll('_', ' '),
        author: row.columnAt(6) as String?,
        format: format,
        name: name,
        source: row.columnAt(9) as String,
        size: size,
        hasCover: row.columnAt(7) == 1,
        publication: PublicationMetadata.decode(row.columnAt(8) as String?),
        folderName: row.columnAt(10) as String?,
      ),
    );
  }
  files.sort((a, b) => a.key.compareTo(b.key));
  final existing = {
    for (final row in db.select(
      'SELECT file_key, edition_id, manual FROM shelf_members',
    ))
      row.columnAt(0) as String: (
        id: row.columnAt(1) as String,
        manual: row.columnAt(2) == 1,
      ),
  };
  final preferred = {
    for (final row in db.select('SELECT id, preferred_key FROM shelf_editions'))
      row.columnAt(0) as String: row.columnAt(1) as String?,
  };
  final known = {for (final file in files) file.key};
  final incomplete = {
    for (final member in existing.entries)
      if (!known.contains(member.key)) member.value.id,
  };
  bool anchored(EditionFile file) =>
      (existing[file.key]?.manual ?? false) ||
      incomplete.contains(existing[file.key]?.id);
  final groups = <String, List<EditionFile>>{};
  // Keep explicit choices and incomplete groups intact. Missing originals
  // still own annotations; inference may not silently split their members.
  for (final file in files.where(anchored)) {
    (groups[existing[file.key]!.id] ??= []).add(file);
  }
  final evidence = <String, Set<String>>{};
  for (final entry in groups.entries) {
    for (final file in entry.value) {
      for (final key in _evidence(file)) {
        (evidence[key] ??= {}).add(entry.key);
      }
    }
  }
  for (final file in files.where((file) => !anchored(file))) {
    final keys = _evidence(file);
    final candidates = <String>[];
    for (final id in <String>{for (final key in keys) ...?evidence[key]}) {
      if (incomplete.contains(id) ||
          !groups[id]!.every((other) => _autoMatch(file, other))) {
        continue;
      }
      try {
        checkAnnotationSnapshot(db, [
          for (final member in [file, ...groups[id]!])
            if (member.book case final book?) book.contentHash,
        ]);
        candidates.add(id);
      } on CoreException catch (error) {
        if (error.kind != CoreErrorKind.limitExceeded) rethrow;
        // A matching edition must not make its existing notes unloadable.
      }
    }
    // More than one compatible group is ambiguous, not a transitive bridge.
    var id = candidates.length == 1 ? candidates.single : null;
    if (id == null) {
      final old = existing[file.key]?.id;
      id = old != null && !groups.containsKey(old) ? old : newUuid();
      groups[id] = [];
      db.execute('INSERT OR IGNORE INTO shelf_editions(id) VALUES (?)', [id]);
    }
    groups[id]!.add(file);
    db.execute(
      '''INSERT INTO shelf_members(file_key, edition_id) VALUES (?, ?)
      ON CONFLICT(file_key) DO UPDATE SET edition_id = excluded.edition_id''',
      [file.key, id],
    );
    for (final key in keys) {
      (evidence[key] ??= {}).add(id);
    }
  }
  final result = <BookEdition>[];
  for (final entry in groups.entries) {
    final selected =
        [
              preferred[entry.key],
              ...entry.value.map((f) => preferred[existing[f.key]?.id]),
            ]
            .whereType<String>()
            .where(
              (key) =>
                  entry.value.any((f) => f.key == key) ||
                  (!known.contains(key) && existing[key]?.id == entry.key),
            )
            .firstOrNull;
    db.execute('UPDATE shelf_editions SET preferred_key = ? WHERE id = ?', [
      selected,
      entry.key,
    ]);
    result.add(
      BookEdition(
        entry.key,
        List.unmodifiable(entry.value),
        preferredKey: selected,
      ),
    );
  }
  // Inference and durable choices use the complete catalog. A caller's source
  // set controls only which unopened files are shown, never what an edit owns.
  final visible = [
    for (final edition in result)
      BookEdition(
        edition.id,
        List<EditionFile>.unmodifiable(
          edition.files.where(
            (file) =>
                file.book != null ||
                allowed == null ||
                allowed.contains(
                  jsonEncode([file.locator!.locationId, file.locator!.key]),
                ),
          ),
        ),
        preferredKey: edition.preferredKey,
      ),
  ].where((edition) => edition.files.isNotEmpty).toList();
  // Index candidate names too: weak evidence suggests, but never joins groups.
  final byId = {for (final edition in result) edition.id: edition};
  final candidateIndex = <String, Set<String>>{};
  for (final edition in visible) {
    for (final file in edition.files) {
      for (final key in _candidateKeys(file)) {
        (candidateIndex[key] ??= {}).add(edition.id);
      }
    }
  }
  return [
    for (final edition in visible)
      BookEdition(
        edition.id,
        edition.files,
        preferredKey: edition.preferredKey,
        possibleMatches: Map.unmodifiable({
          for (final id in {
            for (final file in edition.files)
              for (final key in _candidateKeys(file)) ...?candidateIndex[key],
          })
            if (!incomplete.contains(edition.id) &&
                !incomplete.contains(id) &&
                byId[edition.id]!.canGroupWith(byId[id]!) &&
                // An explicit separation must not keep asking to regroup.
                !(edition.files.every(
                      (f) => existing[f.key]?.manual ?? false,
                    ) &&
                    byId[id]!.files.every(
                      (f) => existing[f.key]?.manual ?? false,
                    )))
              id: Set.unmodifiable({
                for (final a in edition.files)
                  for (final b in byId[id]!.files) ..._matchEvidence(a, b),
              }),
        }),
      ),
  ];
}

List<String> _evidence(EditionFile file) {
  final p = file.publication;
  return [
    for (final id in p.identifiers.map(publicationIsbn).nonNulls) 'isbn:$id',
    if (p.title != null && _authorKey(p).isNotEmpty)
      'title:${jsonEncode([_titleKey(p.title!), _authorKey(p)])}',
  ];
}

const _editionPattern =
    r'\b(first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth|\d+(?:st|nd|rd|th)?)\s+(?:edition|editio|ed)\b\.?|第\s*\d+\s*版';

String? _edition(EditionFile file) {
  final value =
      file.publication.edition ??
      _qualifier('${file.title} ${file.name}', _editionPattern) ??
      _qualifier(file.folderName ?? '', _editionPattern);
  if (value == null) return null;
  final normalized = _normalized(value);
  final number = RegExp(r'\d+').firstMatch(normalized)?.group(0);
  if (number != null) return number.replaceFirst(RegExp(r'^0+(?=\d)'), '');
  const ordinals = [
    'first',
    'second',
    'third',
    'fourth',
    'fifth',
    'sixth',
    'seventh',
    'eighth',
    'ninth',
    'tenth',
  ];
  final word = normalized.split(' ').first;
  final index = ordinals.indexOf(word);
  return index < 0 ? normalized : '${index + 1}';
}

String? _volume(EditionFile file) => file.publication.volume == null
    ? _qualifier(
        '${file.title} ${file.name} ${file.folderName ?? ''}',
        r'\b(?:volume|vol\.?|part)\s+[\divxlc]+\b|第\s*\d+\s*巻',
      )
    : _normalized(file.publication.volume!);
String? _qualifier(String text, String pattern) => RegExp(
  pattern,
  caseSensitive: false,
).firstMatch(_normalized(text.replaceAll('_', ' ')))?.group(0);

bool _conflicts(EditionFile a, EditionFile b) {
  bool different(String? a, String? b) =>
      a != null && b != null && _normalized(a) != _normalized(b);
  final status = r'\b(?:abridged|unabridged|draft|final|early access|meap)\b';
  return different(_edition(a), _edition(b)) ||
      different(_volume(a), _volume(b)) ||
      different(_revision(a), _revision(b)) ||
      different(a.publication.language, b.publication.language) ||
      (_qualifier('${a.title} ${a.name}', status) !=
          _qualifier('${b.title} ${b.name}', status));
}

bool _autoMatch(EditionFile a, EditionFile b) {
  if (_conflicts(a, b)) return false;
  final leftTitle = a.publication.title;
  final rightTitle = b.publication.title;
  if (leftTitle != null &&
      rightTitle != null &&
      _titleKey(leftTitle) != _titleKey(rightTitle)) {
    return false;
  }
  final leftAuthors = _authorKey(a.publication);
  final rightAuthors = _authorKey(b.publication);
  if (leftAuthors.isNotEmpty &&
      rightAuthors.isNotEmpty &&
      leftAuthors != rightAuthors) {
    return false;
  }
  // Unknown edition/volume never stands in for an explicitly named one.
  if ((_edition(a) == null) != (_edition(b) == null) ||
      (_volume(a) == null) != (_volume(b) == null) ||
      (_revision(a) == null) != (_revision(b) == null)) {
    return false;
  }
  final isbns = a.publication.identifiers.map(publicationIsbn).nonNulls.toSet();
  if (b.publication.identifiers
      .map(publicationIsbn)
      .nonNulls
      .any(isbns.contains)) {
    return true;
  }
  if (leftTitle == null ||
      rightTitle == null ||
      leftAuthors.isEmpty ||
      rightAuthors.isEmpty) {
    return false;
  }
  // Publication facts remain sufficient. Missing facts need corroboration
  // from the export, not a title-only guess that could share the wrong notes.
  return (_edition(a) != null &&
          a.publication.language != null &&
          a.publication.language == b.publication.language) ||
      (_bookFilename(a) &&
          _bookFilename(b) &&
          _filenameKey(a) == _filenameKey(b)) ||
      (_bookFolder(a) &&
          _bookFolder(b) &&
          _titleKey(a.folderName!) == _titleKey(b.folderName!));
}

String _words(String value) => _normalized(value)
    .replaceAll('_', ' ')
    .replaceAll(RegExp(r'(?<!\d)\.|\.(?!\d)'), ' ')
    .replaceAll(RegExp(r'[^\p{L}\p{N}.+#]+', unicode: true), ' ')
    .trim();

String _titleKey(String value) => _words(
  value
      .replaceAll('_', ' ')
      .replaceAll(RegExp(_editionPattern, caseSensitive: false), ''),
).replaceAll(' ', '');

String _authorKey(PublicationMetadata publication) {
  final names =
      publication.contributors
          .map((name) {
            final parts = name.split(',').map(_words).toList();
            // Normalize a surname-first person, not an unordered bag of name tokens:
            // "Ann Lee, Bo Tan" must not equal "Ann Tan, Bo Lee".
            if (parts.length == 2 &&
                (parts.first.split(' ').length == 1 ||
                    parts.last.split(' ').length == 1)) {
              return '${parts.last} ${parts.first}';
            }
            // Coauthor separators may be missing; name order must still agree.
            return parts.join(' ');
          })
          .where((name) => name.isNotEmpty)
          .toList()
        ..sort();
  return names.join('\u0000');
}

String _filenameKey(EditionFile file) {
  var name = file.name
      .replaceFirst(RegExp(r'\.[^.]+$'), '')
      .replaceAll('_', ' ');
  final suffix = RegExp(
    r'\s*(?:\(\d+\)|\[from [^\]]+\])\s*$',
    caseSensitive: false,
  );
  while (suffix.hasMatch(name)) {
    name = name.replaceFirst(suffix, '');
  }
  final separator = name.lastIndexOf(' - ');
  if (separator > 0 &&
      _authorKey(
            PublicationMetadata(contributors: [name.substring(separator + 3)]),
          ) ==
          _authorKey(file.publication)) {
    name = name.substring(0, separator);
  }
  return _titleKey(name);
}

bool _bookFilename(EditionFile file) {
  final title = _titleKey(file.publication.title ?? file.title);
  final name = _filenameKey(file);
  final revision = _revision(file);
  return name == title || (revision != null && name == '$title$revision');
}

bool _bookFolder(EditionFile file) =>
    file.folderName != null &&
    _titleKey(file.folderName!) ==
        _titleKey(file.publication.title ?? file.title);

String? _revision(EditionFile file) => _qualifier(
  '${file.title} ${file.name} ${file.folderName ?? ''}',
  r'\b(?:v\d+(?:\.\d+)*|p\d+\.\d+)\b',
);

List<String> _candidateKeys(EditionFile file) => [
  'name:${_titleKey(file.publication.title ?? file.title)}',
  'name:${_filenameKey(file)}',
  if (_bookFolder(file)) 'name:${_titleKey(file.folderName!)}',
  for (final id in file.publication.identifiers.map(publicationIsbn).nonNulls)
    'isbn:$id',
];

Set<EditionMatchEvidence> _matchEvidence(EditionFile a, EditionFile b) {
  final result = <EditionMatchEvidence>{};
  if (_titleKey(a.publication.title ?? a.title) ==
      _titleKey(b.publication.title ?? b.title)) {
    result.add(EditionMatchEvidence.title);
  }
  if (_filenameKey(a) == _filenameKey(b)) {
    result.add(EditionMatchEvidence.filename);
  }
  if (_bookFolder(a) &&
      _bookFolder(b) &&
      _titleKey(a.folderName!) == _titleKey(b.folderName!)) {
    result.add(EditionMatchEvidence.folder);
  }
  final isbns = a.publication.identifiers.map(publicationIsbn).nonNulls.toSet();
  if (b.publication.identifiers
      .map(publicationIsbn)
      .nonNulls
      .any(isbns.contains)) {
    result.add(EditionMatchEvidence.isbn);
  }
  if ((a.publication.title != null &&
          b.publication.title != null &&
          _titleKey(a.publication.title!) != _titleKey(b.publication.title!)) ||
      (_authorKey(a.publication).isNotEmpty &&
          _authorKey(b.publication).isNotEmpty &&
          _authorKey(a.publication) != _authorKey(b.publication))) {
    result.add(EditionMatchEvidence.metadataConflict);
  }
  return result;
}

/// Transfer a preview membership and selection only after verified admission.
/// A changed source revision has a different key, so never inherits old notes.
/// Returns false when verified facts require keeping the content separate.
bool admitEditionFile(
  Database db,
  String sourceKey,
  String hash, {
  bool inheritPreview = true,
}) {
  if (db.select('SELECT 1 FROM shelf_members WHERE file_key = ?', [
    sourceKey,
  ]).isEmpty) {
    return true;
  }
  final entries = _snapshot(db, null);
  final key = contentEditionKey(hash);
  final source = db.select(
    'SELECT edition_id, manual FROM shelf_members WHERE file_key = ?',
    [sourceKey],
  ).single;
  final target = db.select(
    'SELECT edition_id, manual FROM shelf_members WHERE file_key = ?',
    [key],
  ).firstOrNull;
  final sourceId = source.columnAt(0) as String;
  final targetId = target?.columnAt(0) as String?;
  final destination = entries
      .where((entry) => entry.id == sourceId)
      .firstOrNull;
  final verified = entries
      .expand((entry) => entry.files)
      .singleWhere((file) => file.key == key);
  final known = {
    for (final file in destination?.files ?? <EditionFile>[]) file.key,
  };
  if (destination == null ||
      (!inheritPreview &&
          (source.columnAt(1) == 1 || destination.files.length > 1)) ||
      destination.files.any((file) => _conflicts(verified, file)) ||
      db
          .select('SELECT file_key FROM shelf_members WHERE edition_id = ?', [
            sourceId,
          ])
          .any((row) => !known.contains(row.columnAt(0)))) {
    // A preview decision cannot override newly verified publication facts.
    // Keep the admitted content's independent membership and discard only
    // the provisional file, not the other members or their annotations.
    db.execute(
      'UPDATE shelf_editions SET preferred_key = NULL WHERE preferred_key = ?',
      [sourceKey],
    );
    db.execute('DELETE FROM shelf_members WHERE file_key = ?', [sourceKey]);
    return false;
  }
  if (source.columnAt(1) == 1 &&
      target?.columnAt(1) == 1 &&
      targetId != sourceId) {
    throw const CoreException.invalidRequest(
      'This file already belongs to another confirmed group. Separate it there first.',
    );
  }
  // Verified identical bytes have one membership. An explicit preview choice
  // wins over an inferred existing membership, but never combines both groups.
  final id = source.columnAt(1) == 1 ? sourceId : targetId ?? sourceId;
  db.execute(
    'INSERT OR IGNORE INTO shelf_members(file_key, edition_id, manual) VALUES (?, ?, ?)',
    [key, id, source.columnAt(1)],
  );
  if (id == sourceId && targetId != null && targetId != id) {
    db.execute(
      'UPDATE shelf_members SET edition_id = ?, manual = 1 WHERE file_key = ?',
      [id, key],
    );
    db.execute(
      'UPDATE shelf_editions SET preferred_key = NULL WHERE id = ? AND preferred_key = ?',
      [targetId, key],
    );
  }
  db.execute(
    'UPDATE shelf_editions SET preferred_key = ? WHERE id = ? AND preferred_key = ?',
    [key, id, sourceKey],
  );
  db.execute('DELETE FROM shelf_members WHERE file_key = ?', [sourceKey]);
  checkAnnotationSnapshot(db, [hash]);
  return true;
}
