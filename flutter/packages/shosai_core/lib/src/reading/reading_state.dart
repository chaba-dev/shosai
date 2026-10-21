/// Where the reader left each book.
library;

import '../errors.dart';
import '../library/records.dart';
import '../store/store.dart';

/// A reading position: a unit (PDF page or EPUB spine item), an optional
/// offset within it (an EPUB character offset), and the zoom.
final class ReadingPosition {
  const ReadingPosition({required this.unit, this.offset, this.zoom = 1});

  final int unit;
  final int? offset;
  final double zoom;

  @override
  bool operator ==(Object other) =>
      other is ReadingPosition &&
      other.unit == unit &&
      other.offset == offset &&
      other.zoom == zoom;

  @override
  int get hashCode => Object.hash(unit, offset, zoom);

  @override
  String toString() => 'ReadingPosition($unit, $offset, $zoom)';
}

/// Reading positions, kept per book content so they survive removing and
/// re-importing a book.
///
/// The store runs requests in the order they were sent, so the last save sent
/// is the one that persists.
final class ReadingState {
  const ReadingState(this._store);

  final Store _store;

  /// The saved position of book [bookId], or null when it was never saved.
  Future<ReadingPosition?> load(int bookId) =>
      _store.read((db) => _load(db, bookId));

  /// Save the position of book [bookId] and, from [unitCount], its library
  /// progress and reading time.
  Future<void> save(
    int bookId,
    ReadingPosition position, {
    required int unitCount,
  }) async {
    _validate(position);
    if (unitCount < 1) {
      throw const CoreException.invalidRequest(
        'The unit count must be positive.',
      );
    }
    final progress = readingProgress(position.unit, unitCount);
    return _store.transaction((db) => _save(db, bookId, position, progress));
  }
}

/// Progress through a book of [unitCount] units at [unit]: 0 at the first
/// unit, 1 at the last.
double readingProgress(int unit, int unitCount) => unitCount <= 1
    ? 1
    : (unit < unitCount - 1 ? unit : unitCount - 1) / (unitCount - 1);

void _validate(ReadingPosition position) {
  if (position.unit < 0 || (position.offset ?? 0) < 0) {
    throw const CoreException.invalidRequest(
      'The reading position must not be negative.',
    );
  }
  if (!position.zoom.isFinite || position.zoom <= 0) {
    throw const CoreException.invalidRequest(
      'The zoom must be finite and positive.',
    );
  }
}

ReadingPosition? _load(Database db, int bookId) {
  final hash = bookContentHash(db, bookId);
  final row = db
      .select(
        '''SELECT unit, location_offset, zoom FROM reading_state
       WHERE content_hash = ?''',
        [hash],
      )
      .firstOrNull;
  if (row == null) return null;
  return ReadingPosition(
    unit: row.columnAt(0) as int,
    offset: row.columnAt(1) as int?,
    zoom: row.columnAt(2) as double,
  );
}

void _save(Database db, int bookId, ReadingPosition position, double progress) {
  final hash = bookContentHash(db, bookId);
  db.execute(
    '''INSERT INTO reading_state (content_hash, unit, location_offset, zoom)
       VALUES (?, ?, ?, ?)
       ON CONFLICT(content_hash) DO UPDATE SET
         unit = excluded.unit,
         location_offset = excluded.location_offset,
         zoom = excluded.zoom,
         updated_at = excluded.updated_at''',
    [hash, position.unit, position.offset, position.zoom],
  );
  db.execute(
    '''UPDATE books SET progress = ?,
         last_read = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
       WHERE id = ?''',
    [progress, bookId],
  );
}
