import 'dart:async';
import 'dart:collection';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:shosai_flutter/core/bridge.dart';

part 'message.dart';
part 'model.dart';

/// Captures the current reader's last fully painted page for [bookId].
///
/// The adapter may wait for the frame requested by the transition that asks
/// for the image; the controller validates the typed completion before taking
/// ownership of it.
typedef ShellPageMiniatureCapture = FutureOr<ui.Image?> Function(int bookId);

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
    ShellPageMiniatureCapture? capturePageMiniature,
    ShellModel initial = const ShellModel(),
  }) : _presentReader = presentReader,
       _dismissReader = dismissReader,
       _capturePageMiniature = capturePageMiniature,
       _model = initial;

  static const int pageMiniatureBudgetBytes = 16 * 1024 * 1024;

  final ShellReaderPresenter _presentReader;
  final ShellReaderDismisser _dismissReader;
  final ShellPageMiniatureCapture? _capturePageMiniature;
  final Map<int, ui.Image> _pages = {};
  late final Map<int, ui.Image> _pageView = UnmodifiableMapView(_pages);
  final Map<int, int> _pageCaptureRevisions = {};
  int _pageBytes = 0;
  ShellModel _model;
  Completer<void>? _presentation;
  bool _disposed = false;

  ShellModel get model => _model;

  /// Last-read page miniatures admitted for the phone tab switcher.
  ///
  /// The controller owns and disposes every image. Books outside the bounded
  /// budget fall back to their covers.
  Map<int, ui.Image> get pages => _pageView;

  /// Completes when the current reader presentation has gone; already
  /// complete when the reader is not presented.
  Future<void> get readerDismissed =>
      _presentation?.future ?? Future<void>.value();

  void dispatch(ShellMessage message) {
    if (message case _ShellPageMiniatureCaptured()) {
      _pageCaptured(message);
      return;
    }
    if (_disposed) return;
    final previous = _model;
    final next = update(previous, message);
    if (identical(next, previous)) return;
    _model = next;
    _updatePages(previous, next);
    if (!previous.reading && next.reading) {
      _present();
    } else if (previous.reading &&
        !next.reading &&
        message is! _ShellReaderDismissed) {
      _dismissReader();
    }
    notifyListeners();
  }

  void _updatePages(ShellModel before, ShellModel after) {
    for (final id in {..._pages.keys, ..._pageCaptureRevisions.keys}) {
      final beforeIndex = before.indexOf(id);
      final afterIndex = after.indexOf(id);
      final beforeBook = beforeIndex < 0 ? null : before.openBooks[beforeIndex];
      final afterBook = afterIndex < 0 ? null : after.openBooks[afterIndex];
      final invalid =
          afterBook == null ||
          (beforeBook != null &&
              (beforeBook.path != afterBook.path ||
                  beforeBook.bookId != afterBook.bookId));
      if (invalid) _invalidatePage(id);
    }

    final id = before.currentBookId;
    if (!before.reading || id == null || after.indexOf(id) < 0) return;
    final covered = after.switching && !before.switching;
    final left = !after.reading || after.currentBookId != id;
    if (!covered && !left) return;
    final source = before.openBooks[before.indexOf(id)];
    _capturePage(id, source);
  }

  void _capturePage(int id, OpenBook source) {
    final capture = _capturePageMiniature;
    if (capture == null) return;
    final revision = (_pageCaptureRevisions[id] ?? 0) + 1;
    _pageCaptureRevisions[id] = revision;
    unawaited(() async {
      ui.Image? image;
      try {
        image = await capture(id);
      } on Object {
        image = null;
      }
      dispatch(
        _ShellPageMiniatureCaptured(
          id,
          path: source.path,
          bookId: source.bookId,
          revision: revision,
          image: image,
        ),
      );
    }());
  }

  void _pageCaptured(_ShellPageMiniatureCaptured message) {
    final page = message.image;
    if (page == null) return;
    final index = _model.indexOf(message.id);
    final current = index < 0 ? null : _model.openBooks[index];
    if (_disposed ||
        _pageCaptureRevisions[message.id] != message.revision ||
        current?.path != message.path ||
        current?.bookId != message.bookId) {
      page.dispose();
      return;
    }
    final id = message.id;
    _removePage(id);
    final bytes = page.width * page.height * 4;
    if (bytes > pageMiniatureBudgetBytes) {
      page.dispose();
      return;
    }
    while (_pages.isNotEmpty && _pageBytes + bytes > pageMiniatureBudgetBytes) {
      _removePage(_pages.keys.first);
    }
    _pages[id] = page;
    _pageBytes += bytes;
    notifyListeners();
  }

  void _invalidatePage(int id) {
    _pageCaptureRevisions[id] = (_pageCaptureRevisions[id] ?? 0) + 1;
    _removePage(id);
  }

  void _removePage(int id) {
    final page = _pages.remove(id);
    if (page == null) return;
    _pageBytes -= page.width * page.height * 4;
    page.dispose();
  }

  void _present() {
    final presentation = Completer<void>();
    _presentation = presentation;
    unawaited(() async {
      try {
        await _presentReader();
      } finally {
        // Each presentation settles its own future, but only the current one
        // may end the session: a presentation the shell already dismissed can
        // complete after the reader was presented again.
        final current = identical(_presentation, presentation);
        if (current) _presentation = null;
        presentation.complete();
        if (current) dispatch(const _ShellReaderDismissed());
      }
    }());
  }

  @override
  void dispose() {
    _disposed = true;
    for (final id in {..._pages.keys, ..._pageCaptureRevisions.keys}) {
      _invalidatePage(id);
    }
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
      // twice (RFD 12, outcome 4); its own place is kept.
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
      if (model.currentBookId == id && model.reading && !model.switching) {
        return model;
      }
      // Choosing a book in the switcher reads it.
      return model.copyWith(currentBookId: id, reading: true, switching: false);
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
    case ShellSwitcherOpened():
      if (!model.reading || model.switching) return model;
      return model.copyWith(switching: true);
    case ShellSwitcherClosed():
      if (!model.switching) return model;
      return model.copyWith(switching: false);
    case ShellRestored(:final restored):
      if (model.openBooks.isNotEmpty || model.reading) return model;
      return restored.copyWith(reading: false);
    case _ShellReaderDismissed():
      if (!model.reading) return model;
      return model.copyWith(reading: false);
    case _ShellPageMiniatureCaptured():
      // Resource completions are consumed by ShellController.dispatch.
      return model;
  }
}
