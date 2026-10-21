import 'dart:async';

import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:shosai_flutter/core/bridge.dart';

part 'message.dart';
part 'model.dart';

/// The Bookshelf shell's state: the place in view and the open books.
///
/// The shell follows the same Elm boundary as the library and the reader
/// (`docs/flutter-architecture.md`): widgets render the immutable
/// [ShellModel] and dispatch [ShellMessage] values, [update] computes every
/// transition, and the controller starts the one effect the shell owns, the
/// reader's presentation, through injected adapters.
///
/// The reader is presented while [ShellModel.reading] is true. Entering it
/// calls [ShellReaderPresenter], which completes once the presentation has
/// gone for any reason (the reader's own back action, a rail place, closing
/// the last open book); leaving it from the shell calls
/// [ShellReaderDismisser]. The library's open effect waits on
/// [readerDismissed], so it keeps refreshing the collection when the reader
/// goes away, as it did when the reader was a route of its own.
class ShellController extends ChangeNotifier {
  ShellController({
    required ShellReaderPresenter presentReader,
    required ShellReaderDismisser dismissReader,
    ShellModel initial = const ShellModel(),
  }) : _presentReader = presentReader,
       _dismissReader = dismissReader,
       _model = initial;

  final ShellReaderPresenter _presentReader;
  final ShellReaderDismisser _dismissReader;
  ShellModel _model;
  Completer<void>? _presentation;
  bool _disposed = false;

  ShellModel get model => _model;

  /// Completes when the current reader presentation has gone; already
  /// complete when the reader is not presented.
  Future<void> get readerDismissed =>
      _presentation?.future ?? Future<void>.value();

  void dispatch(ShellMessage message) {
    if (_disposed) return;
    final previous = _model;
    final next = update(previous, message);
    if (identical(next, previous)) return;
    _model = next;
    if (!previous.reading && next.reading) {
      _present();
    } else if (previous.reading &&
        !next.reading &&
        message is! _ShellReaderDismissed) {
      _dismissReader();
    }
    notifyListeners();
  }

  void _present() {
    final presentation = Completer<void>();
    _presentation = presentation;
    unawaited(() async {
      try {
        await _presentReader();
      } finally {
        if (identical(_presentation, presentation)) _presentation = null;
        presentation.complete();
        dispatch(const _ShellReaderDismissed());
      }
    }());
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// The shell's transition function.
///
/// It returns [model] itself when a message changes nothing, so the controller
/// neither notifies nor starts an effect for it.
ShellModel update(ShellModel model, ShellMessage message) {
  switch (message) {
    case ShellPlaceSelected(:final place):
      if (model.place == place && !model.reading) return model;
      return model.copyWith(place: place, reading: false);
    case ShellBookOpened(:final book, :final path, :final bookId):
      // Opening a book that is already open focuses it instead of opening it
      // twice (RFD 4, outcome 4); its own place is kept.
      final index = model.indexOf(book.bookId);
      final books = [...model.openBooks];
      if (index < 0) {
        books.add(
          path == null
              ? OpenBook(book: book, path: book.pathKey, bookId: book.bookId)
              : OpenBook(book: book, path: path, bookId: bookId),
        );
      } else {
        books[index] = books[index].copyWith(book: book);
      }
      return model.copyWith(
        openBooks: books,
        currentBookId: book.bookId,
        reading: true,
      );
    case ShellBookActivated(:final id):
      if (model.indexOf(id) < 0) return model;
      if (model.currentBookId == id && model.reading) return model;
      return model.copyWith(currentBookId: id, reading: true);
    case ShellBookClosed(:final id):
      final index = model.indexOf(id);
      if (index < 0) return model;
      final books = [...model.openBooks]..removeAt(index);
      if (model.currentBookId != id) {
        return model.copyWith(openBooks: books);
      }
      // Closing the current book selects the one below it, else the one above;
      // with none left the library shows.
      if (books.isEmpty) {
        return model.copyWith(
          openBooks: books,
          clearCurrentBook: true,
          place: ShellPlace.library,
          reading: false,
        );
      }
      final next = books[index < books.length ? index : books.length - 1];
      return model.copyWith(openBooks: books, currentBookId: next.id);
    case ShellBookMoved(:final from, :final to):
      final count = model.openBooks.length;
      if (from < 0 || from >= count || to < 0 || to >= count || from == to) {
        return model;
      }
      final books = [...model.openBooks];
      books.insert(to, books.removeAt(from));
      return model.copyWith(openBooks: books);
    case ShellLocatorChanged(:final id, :final path, :final bookId):
      final index = model.indexOf(id);
      if (index < 0) return model;
      final current = model.openBooks[index];
      if (current.path == path && current.bookId == bookId) return model;
      final books = [...model.openBooks];
      books[index] = current.copyWith(path: path, bookId: () => bookId);
      return model.copyWith(openBooks: books);
    case ShellLibraryBooksChanged(:final books):
      // The library's reload carries the newest progress and titles; open
      // books it does not list (a filtered or paged-out book) keep theirs.
      final byId = {for (final book in books) book.bookId: book};
      final open = [
        for (final entry in model.openBooks)
          entry.copyWith(book: byId[entry.id]),
      ];
      final changed = [
        for (var i = 0; i < open.length; i += 1)
          open[i].book != model.openBooks[i].book,
      ].contains(true);
      return changed ? model.copyWith(openBooks: open) : model;
    case ShellRestored(:final restored):
      if (model.openBooks.isNotEmpty || model.reading) return model;
      return restored.copyWith(reading: false);
    case _ShellReaderDismissed():
      if (!model.reading) return model;
      return model.copyWith(reading: false);
  }
}
