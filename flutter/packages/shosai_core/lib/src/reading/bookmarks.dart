/// Point bookmarks with optional titles. A note about a place is a page
/// note, an annotation (RFD 6).
library;

import 'dart:convert';

import '../errors.dart';
import '../library/records.dart';
import '../store/store.dart';

const maxBookmarksPerBook = 1024;
const maxBookmarkTitleBytes = 4 * 1024;
const maxBookmarkExportBytes = 4 * 1024 * 1024;

/// A bookmark at a unit (PDF page or EPUB spine item) and an optional offset
/// within it.
final class Bookmark {
  const Bookmark({
    required this.id,
    required this.unit,
    required this.offset,
    required this.title,
    required this.color,
    required this.createdAt,
  });

  final int id;
  final int unit;
  final int? offset;
  final String? title;
  final String color;

  /// ISO 8601 UTC timestamp.
  final String createdAt;

  @override
  bool operator ==(Object other) =>
      other is Bookmark &&
      other.id == id &&
      other.unit == unit &&
      other.offset == offset &&
      other.title == title &&
      other.color == color &&
      other.createdAt == createdAt;

  @override
  int get hashCode => Object.hash(id, unit, offset, title, color, createdAt);

  @override
  String toString() => 'Bookmark($id, $unit, $offset)';
}

/// Bookmarks, kept per book content so they survive removing and
/// re-importing a book. A book holds at most [maxBookmarksPerBook].
final class Bookmarks {
  const Bookmarks(this._store);

  final Store _store;

  /// Book [bookId]'s bookmarks in reading order.
  Future<List<Bookmark>> list(int bookId) =>
      _store.read((db) => _list(db, bookContentHash(db, bookId)));

  /// Remove the bookmark at [unit] and [offset], or add one there with
  /// [title]. Returns the added bookmark, or null when one was removed.
  Future<Bookmark?> toggle(
    int bookId,
    int unit, {
    int? offset,
    String? title,
  }) async {
    if (unit < 0 || (offset ?? 0) < 0) {
      throw const CoreException.invalidRequest(
        'The bookmark location must not be negative.',
      );
    }
    _checkBytes(title, maxBookmarkTitleBytes, 'title');
    return _store.transaction((db) => _toggle(db, bookId, unit, offset, title));
  }

  /// Delete bookmark [id]; deleting a missing bookmark does nothing.
  Future<void> delete(int id) => _store.transaction(
    (db) => db.execute('DELETE FROM bookmarks WHERE id = ?', [id]),
  );

  /// Book [bookId]'s bookmarks as Markdown, at most [maxBookmarkExportBytes].
  Future<String> exportMarkdown(int bookId) =>
      _store.read((db) => _exportMarkdown(db, bookId));
}

void _checkBytes(String? value, int limit, String field) {
  if (value != null && utf8.encode(value).length > limit) {
    throw CoreException.invalidRequest(
      'The bookmark $field exceeds $limit bytes.',
    );
  }
}

Bookmark _bookmark(Row row) => Bookmark(
  id: row.columnAt(0) as int,
  unit: row.columnAt(1) as int,
  offset: row.columnAt(2) as int?,
  title: row.columnAt(3) as String?,
  color: row.columnAt(4) as String,
  createdAt: row.columnAt(5) as String,
);

const _columns = 'id, unit, location_offset, title, color, created_at';

List<Bookmark> _list(Database db, String hash) {
  final rows = db.select(
    '''SELECT $_columns FROM bookmarks WHERE content_hash = ?
       ORDER BY unit, coalesce(location_offset, 0), created_at, id
       LIMIT ?''',
    [hash, maxBookmarksPerBook + 1],
  );
  if (rows.length > maxBookmarksPerBook) {
    throw const CoreException.limitExceeded(
      'The book has more than $maxBookmarksPerBook bookmarks.',
    );
  }
  return rows.map(_bookmark).toList();
}

Bookmark? _toggle(
  Database db,
  int bookId,
  int unit,
  int? offset,
  String? title,
) {
  final hash = bookContentHash(db, bookId);
  final existing = db
      .select(
        '''SELECT id FROM bookmarks
       WHERE content_hash = ? AND unit = ? AND location_offset IS ?
       LIMIT 1''',
        [hash, unit, offset],
      )
      .firstOrNull;
  if (existing != null) {
    db.execute('DELETE FROM bookmarks WHERE id = ?', [existing.columnAt(0)]);
    return null;
  }
  final count =
      db
              .select('SELECT COUNT(*) FROM bookmarks WHERE content_hash = ?', [
                hash,
              ])
              .single
              .columnAt(0)
          as int;
  if (count >= maxBookmarksPerBook) {
    throw const CoreException.limitExceeded(
      'A book holds at most $maxBookmarksPerBook bookmarks.',
    );
  }
  return _bookmark(
    db
        .select(
          '''INSERT INTO bookmarks (content_hash, unit, location_offset, title)
         VALUES (?, ?, ?, ?)
         RETURNING $_columns''',
          [hash, unit, offset, title],
        )
        .single,
  );
}

String _exportMarkdown(Database db, int bookId) {
  final book = db.select('SELECT title, content_hash FROM books WHERE id = ?', [
    bookId,
  ]).firstOrNull;
  if (book == null) {
    throw const CoreException.notFound('The book is not in the library.');
  }
  final markdown = StringBuffer('# Bookmarks: ${book.columnAt(0)}\n\n');
  var bytes = utf8.encode(markdown.toString()).length;
  for (final bookmark in _list(db, book.columnAt(1) as String)) {
    final entry = StringBuffer(
      '## Page ${bookmark.unit + 1}: ${bookmark.title ?? 'Untitled'}\n\n',
    );
    entry.write('*Added: ${bookmark.createdAt}*\n\n---\n\n');
    final text = entry.toString();
    bytes += utf8.encode(text).length;
    if (bytes > maxBookmarkExportBytes) {
      throw const CoreException.limitExceeded(
        'The bookmark export exceeds $maxBookmarkExportBytes bytes.',
      );
    }
    markdown.write(text);
  }
  return markdown.toString();
}
