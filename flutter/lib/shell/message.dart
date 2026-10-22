part of 'controller.dart';

sealed class ShellMessage {
  const ShellMessage();
}

/// Shows a library-side place; while reading, it leaves the reader.
final class ShellPlaceSelected extends ShellMessage {
  const ShellPlaceSelected(this.place);
  final ShellPlace place;
}

/// Opens [book] in the reader, or focuses it when it is already open.
///
/// [path] and [bookId] are the locator to open at (a restored reader's); by
/// default the reader opens the library book, at its saved reading position.
final class ShellBookOpened extends ShellMessage {
  const ShellBookOpened(this.book, {this.path, this.bookId});
  final FlutterLibraryBook book;
  final String? path;
  final int? bookId;
}

/// Switches the reader to the open book with [id].
final class ShellBookActivated extends ShellMessage {
  const ShellBookActivated(this.id);
  final int id;
}

/// Closes the open book with [id].
final class ShellBookClosed extends ShellMessage {
  const ShellBookClosed(this.id);
  final int id;
}

/// Moves the open book at [from] to [to] in Reading now.
final class ShellBookMoved extends ShellMessage {
  const ShellBookMoved(this.from, this.to);
  final int from;
  final int to;
}

/// The reader reported a new locator for the open book with [id].
final class ShellLocatorChanged extends ShellMessage {
  const ShellLocatorChanged(this.id, {required this.path, this.bookId});
  final int id;
  final String path;
  final int? bookId;
}

/// The library listed [books]; open books among them take the new entries.
final class ShellLibraryBooksChanged extends ShellMessage {
  const ShellLibraryBooksChanged(this.books);
  final List<FlutterLibraryBook> books;
}

/// Restores the open books of an earlier run, without entering the reader.
final class ShellRestored extends ShellMessage {
  const ShellRestored(this.restored);
  final ShellModel restored;
}

/// The reader presentation has gone (completion of the presenter effect).
final class _ShellReaderDismissed extends ShellMessage {
  const _ShellReaderDismissed();
}
