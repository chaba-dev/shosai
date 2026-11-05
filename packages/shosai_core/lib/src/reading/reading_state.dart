/// Where the reader left each book.
library;

import '../errors.dart';
import '../library/records.dart';
import '../store/store.dart';
import 'reader_settings.dart';

/// A reading position: a unit (PDF page or EPUB spine item), an optional
/// offset within it (an EPUB character offset), and the zoom.
final class ReadingPosition {
  const ReadingPosition({
    required this.unit,
    this.offset,
    this.zoom = 1,
    this.pdfY,
    this.pdfX,
    this.pdfFit,
  });

  final int unit;
  final int? offset;
  final double zoom;

  /// Height from the rotated PDF page's top, in original points, not pixels.
  final double? pdfY;

  /// Horizontal page-space anchor, including when the visible piece has no text.
  final double? pdfX;

  /// This paper's explicit Aa choice; null inherits the Settings default.
  final PdfFit? pdfFit;

  @override
  bool operator ==(Object other) =>
      other is ReadingPosition &&
      other.unit == unit &&
      other.offset == offset &&
      other.zoom == zoom &&
      other.pdfY == pdfY &&
      other.pdfX == pdfX &&
      other.pdfFit == pdfFit;

  @override
  int get hashCode => Object.hash(unit, offset, zoom, pdfY, pdfX, pdfFit);

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
  ///
  /// [lastUnit] is the last unit in view when it is past the position's own,
  /// as on a PDF spread: the progress counts it as read, so the last spread of
  /// a book finishes it.
  /// [progress] supplies the book-wide fraction when the reader has canonical
  /// EPUB offsets or a fixed PDF page range. It is saved atomically with the
  /// position, without changing the position used for restoration.
  Future<void> save(
    int bookId,
    ReadingPosition position, {
    required int unitCount,
    int? lastUnit,
    double? progress,
  }) async {
    _validate(position);
    if (unitCount < 1) {
      throw const CoreException.invalidRequest(
        'The unit count must be positive.',
      );
    }
    if (lastUnit != null && lastUnit < position.unit) {
      throw const CoreException.invalidRequest(
        'The last unit in view must not come before the position.',
      );
    }
    if (progress != null &&
        (!progress.isFinite || progress < 0 || progress > 1)) {
      throw const CoreException.invalidRequest(
        'Progress must be between 0 and 1.',
      );
    }
    final fraction =
        progress ?? readingProgress(lastUnit ?? position.unit, unitCount);
    return _store.transaction((db) => _save(db, bookId, position, fraction));
  }
}

/// Progress through a book of [unitCount] units at [unit]: 0 at the first
/// unit, 1 at the last.
double readingProgress(int unit, int unitCount) => unitCount <= 1
    ? 1
    : (unit < unitCount - 1 ? unit : unitCount - 1) / (unitCount - 1);

void _validate(ReadingPosition position) {
  if (position.pdfY case final y? when !y.isFinite || y < 0) {
    throw const CoreException.invalidRequest(
      'The PDF height must be finite and nonnegative.',
    );
  }
  if (position.pdfX case final x? when !x.isFinite || x < 0) {
    throw const CoreException.invalidRequest(
      'The PDF horizontal anchor must be finite and nonnegative.',
    );
  }
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
        '''SELECT unit, location_offset, zoom, pdf_y, pdf_x, pdf_fit FROM reading_state
       WHERE content_hash = ?''',
        [hash],
      )
      .firstOrNull;
  if (row == null) return null;
  return ReadingPosition(
    unit: row.columnAt(0) as int,
    offset: row.columnAt(1) as int?,
    zoom: row.columnAt(2) as double,
    pdfY: row.columnAt(3) as double?,
    pdfX: row.columnAt(4) as double?,
    pdfFit: PdfFit.values.asNameMap()[row.columnAt(5)],
  );
}

void _save(Database db, int bookId, ReadingPosition position, double progress) {
  final hash = bookContentHash(db, bookId);
  db.execute(
    '''INSERT INTO reading_state (content_hash, unit, location_offset, zoom, pdf_y, pdf_x, pdf_fit)
       VALUES (?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT(content_hash) DO UPDATE SET
         unit = excluded.unit,
         location_offset = excluded.location_offset,
         zoom = excluded.zoom,
         pdf_y = excluded.pdf_y,
         pdf_x = excluded.pdf_x,
         pdf_fit = excluded.pdf_fit,
         updated_at = excluded.updated_at''',
    [
      hash,
      position.unit,
      position.offset,
      position.zoom,
      position.pdfY,
      position.pdfX,
      position.pdfFit?.name,
    ],
  );
  db.execute(
    '''UPDATE books SET progress = ?,
         last_read = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
       WHERE id = ?''',
    [progress, bookId],
  );
}
