part of 'controller.dart';

/// Presents the reader for [ShellModel.currentBook]; completes once the
/// presentation has gone, whoever ended it.
typedef ShellReaderPresenter = Future<void> Function();

/// Ends the reader presentation the shell started.
typedef ShellReaderDismisser = void Function();

/// The places of the sidebar, the rail and the phone's bottom bar, in their
/// one order (`docs/design-system.md`, Sidebar).
enum ShellPlace { library, notes, bookmarks, search }

/// One open book: the library entry it was opened from and the reader's last
/// reported locator, so switching back reopens it where it was left.
final class OpenBook {
  const OpenBook({required this.book, required this.path, this.bookId});

  final FlutterLibraryBook book;

  /// The reader locator's document path.
  final String path;

  /// The reader locator's library book id; null for a document opened by path.
  final int? bookId;

  int get id => book.bookId;

  OpenBook copyWith({
    FlutterLibraryBook? book,
    String? path,
    int? Function()? bookId,
  }) => OpenBook(
    book: book ?? this.book,
    path: path ?? this.path,
    bookId: bookId == null ? this.bookId : bookId(),
  );

  @override
  bool operator ==(Object other) =>
      other is OpenBook &&
      other.book == book &&
      other.path == path &&
      other.bookId == bookId;

  @override
  int get hashCode => Object.hash(book, path, bookId);
}

final class ShellModel {
  const ShellModel({
    this.place = ShellPlace.library,
    this.openBooks = const [],
    this.currentBookId,
    this.reading = false,
    this.switching = false,
  });

  /// The library-side place in view, and the one the reader returns to.
  final ShellPlace place;

  /// Every open book, in the order opened (or as the reader rearranged them).
  final List<OpenBook> openBooks;

  /// The book the reader shows, and the lifted row in Reading now.
  final int? currentBookId;

  /// Whether the reader is presented over the library-side place.
  final bool reading;

  /// Whether the phone's tab switcher is open over the reader; only while
  /// [reading].
  final bool switching;

  OpenBook? get currentBook {
    final index = currentBookId == null ? -1 : indexOf(currentBookId!);
    return index < 0 ? null : openBooks[index];
  }

  int indexOf(int id) => openBooks.indexWhere((entry) => entry.id == id);

  ShellModel copyWith({
    ShellPlace? place,
    List<OpenBook>? openBooks,
    int? currentBookId,
    bool clearCurrentBook = false,
    bool? reading,
    bool? switching,
  }) => ShellModel(
    place: place ?? this.place,
    openBooks: openBooks == null
        ? this.openBooks
        : List.unmodifiable(openBooks),
    currentBookId: clearCurrentBook
        ? null
        : currentBookId ?? this.currentBookId,
    reading: reading ?? this.reading,
    // The switcher lives over the reader, so leaving the reader closes it.
    switching: (reading ?? this.reading) && (switching ?? this.switching),
  );
}
