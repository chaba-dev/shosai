/// The books left open, kept so they come back when the application starts
/// again (RFD 4, outcome 4).
library;

import 'dart:convert';
import 'dart:io';

import '../preferences.dart';
import '../store/store.dart';
import 'book.dart';
import 'library.dart';

const _openBooksKey = 'shell.openBooks';

/// One open book: the library book and the reader's last locator in it.
typedef OpenBookRecord = ({int bookId, String path, int? openBookId});

/// The open books in their order, the one being read, and whether the reader
/// was showing it.
final class OpenBooksSession {
  const OpenBooksSession({
    required this.books,
    this.current,
    this.reading = false,
  });

  final List<OpenBookRecord> books;
  final int? current;
  final bool reading;
}

/// An open book as loaded: [book] is the library's current record.
typedef LoadedOpenBook = ({Book book, String path, int? openBookId});

/// [OpenBooksSession] as loaded, with each book's library record.
final class LoadedOpenBooks {
  const LoadedOpenBooks({
    required this.books,
    this.current,
    this.reading = false,
  });

  final List<LoadedOpenBook> books;
  final int? current;
  final bool reading;
}

/// Loads and saves the open books.
final class OpenBooksStore {
  OpenBooksStore(Store store, this._library)
    : _preferences = Preferences(store);

  final Preferences _preferences;
  final Library _library;

  /// The open books last saved, or null when none were or the saved value
  /// cannot be read.
  ///
  /// Books the library no longer holds are left out. A book whose file is
  /// gone stays open, but the reader is not shown for it, so a start does
  /// not open on a book that cannot be read.
  Future<LoadedOpenBooks?> load() async {
    final saved = _decode(await _preferences.get(_openBooksKey));
    if (saved == null) return null;
    final books = <LoadedOpenBook>[];
    for (final entry in saved.books) {
      if (books.any((open) => open.book.id == entry.bookId)) continue;
      final book = await _library.get(entry.bookId);
      if (book == null) continue;
      // A tab showing its own book opens it where the library has it now:
      // the saved path is absolute, and the file may have moved since (iOS
      // moves the app's files on every install).
      final path = entry.openBookId == entry.bookId ? book.path : entry.path;
      books.add((book: book, path: path, openBookId: entry.openBookId));
    }
    final current = books
        .where((open) => open.book.id == saved.current)
        .firstOrNull;
    return LoadedOpenBooks(
      books: books,
      current: current?.book.id,
      reading:
          saved.reading &&
          current != null &&
          await File(current.book.path).exists(),
    );
  }

  Future<void> save(OpenBooksSession session) => _preferences.set(
    _openBooksKey,
    jsonEncode({
      'books': [
        for (final book in session.books)
          {
            'id': book.bookId,
            'openPath': book.path,
            'openBookId': book.openBookId,
          },
      ],
      'current': session.current,
      'reading': session.reading,
    }),
  );
}

/// [value] read leniently: an entry without an id or a path is skipped, and
/// anything else unreadable reads as nothing saved.
OpenBooksSession? _decode(String? value) {
  if (value == null) return null;
  try {
    final decoded = jsonDecode(value);
    if (decoded is! Map<String, Object?>) return null;
    final books = decoded['books'];
    if (books is! List<Object?>) return null;
    return OpenBooksSession(
      books: [
        for (final entry in books)
          if (entry case {
            'id': final int id,
            'openPath': final String path,
          } when entry is Map<String, Object?>)
            (
              bookId: id,
              path: path,
              openBookId: switch (entry['openBookId']) {
                final int id => id,
                _ => null,
              },
            ),
      ],
      current: switch (decoded['current']) {
        final int id => id,
        _ => null,
      },
      reading: decoded['reading'] == true,
    );
  } on FormatException {
    return null;
  }
}
