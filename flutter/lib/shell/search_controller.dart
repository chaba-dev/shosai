import 'dart:async';

import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:shosai_flutter/core/bridge.dart';
import 'package:shosai_flutter/core/records.dart';
import 'package:shosai_flutter/theme_tokens.dart';

/// Which books a search covers.
enum ShellSearchScope { thisBook, allBooks }

/// What a search finds.
enum ShellSearchFilter { everything, text, notes }

/// The search palette: book text and notes across the library or in the book
/// being read (RFD 16, Search; `docs/design-system.md`, SearchPalette).
///
/// It follows the shell's Elm boundary (`docs/flutter-architecture.md`): the
/// palette renders the immutable [ShellSearchModel] and dispatches
/// [ShellSearchMessage] values, and the controller runs the searches. A query
/// waits for typing to pause; each search carries the revision it was started
/// for, so results of a search a newer query superseded are dropped, and the
/// superseded search is cancelled.
class ShellSearchController extends ChangeNotifier {
  ShellSearchController({
    required FlutterBridge bridge,
    this.debounce = const Duration(
      milliseconds: ShosaiTokens.layoutLibrarySearchDebounceMs,
    ),
  }) : _bridge = bridge,
       _records = recordsOf(bridge);

  final FlutterBridge _bridge;
  final ShosaiRecords _records;

  /// How long typing must pause before a query is searched.
  final Duration debounce;
  ShellSearchModel _model = const ShellSearchModel();
  final Set<BigInt> _cancellations = {};
  Timer? _timer;
  int _revision = 0;
  int _active = 0;
  bool _disposed = false;

  ShellSearchModel get model => _model;

  void dispatch(ShellSearchMessage message) {
    if (_disposed) return;
    switch (message) {
      case ShellSearchOpened(:final book):
        // The palette opens on the book being read, when there is one; the
        // query and filter carry over from the last search.
        final next = _model.copyWith(
          book: () => book,
          scope: book == null
              ? ShellSearchScope.allBooks
              : ShellSearchScope.thisBook,
        );
        _emit(next);
        _search(immediately: true);
      case ShellSearchQueryChanged(:final query):
        if (query == _model.query) return;
        _emit(_model.copyWith(query: query));
        _search();
      case ShellSearchScopeChanged(:final scope):
        if (scope == _model.scope ||
            (scope == ShellSearchScope.thisBook && _model.book == null)) {
          return;
        }
        _emit(_model.copyWith(scope: scope));
        _search(immediately: true);
      case ShellSearchFilterChanged(:final filter):
        if (filter == _model.filter) return;
        _emit(_model.copyWith(filter: filter));
        _search(immediately: true);
      case _ShellSearchDue(:final revision):
        if (revision == _revision) _start(revision);
      case _ShellSearchNotesFound(:final revision, :final books):
        if (revision != _revision) return;
        _emit(_model.copyWith(notes: books, notesBusy: false));
      case _ShellSearchTextFound(:final revision, :final book):
        if (revision != _revision) return;
        _emit(_model.copyWith(text: [..._model.text, book]));
      case _ShellSearchTextFinished(:final revision):
        if (revision != _revision) return;
        _emit(_model.copyWith(textBusy: false));
      case _ShellSearchFailed(:final revision, :final error):
        if (revision != _revision) return;
        _emit(
          _model.copyWith(
            notesBusy: false,
            textBusy: false,
            error: () => error,
          ),
        );
    }
  }

  /// Supersedes the running search and, unless [immediately], waits for
  /// typing to pause before starting the next.
  void _search({bool immediately = false}) {
    final revision = ++_revision;
    _timer?.cancel();
    for (final cancellation in _cancellations) {
      _bridge.cancel(id: cancellation);
    }
    final query = _model.query.trim();
    _emit(
      _model.copyWith(
        notes: const [],
        text: const [],
        notesBusy: query.isNotEmpty,
        textBusy: query.isNotEmpty,
        error: () => null,
      ),
    );
    if (query.isEmpty) return;
    if (immediately) {
      _start(revision);
    } else {
      _timer = Timer(debounce, () => dispatch(_ShellSearchDue(revision)));
    }
  }

  void _start(int revision) {
    final model = _model;
    final query = model.query.trim();
    final bookId = model.scope == ShellSearchScope.thisBook
        ? model.book?.bookId
        : null;
    final notes = model.filter != ShellSearchFilter.text;
    final text = model.filter != ShellSearchFilter.notes;
    if (!notes) _emit(_model.copyWith(notesBusy: false));
    if (!text) _emit(_model.copyWith(textBusy: false));
    if (notes) {
      _effect(revision, (cancellation) async {
        final books = await _records.searchLibraryNotes(
          query: query,
          bookId: bookId,
          cancellationId: cancellation,
        );
        dispatch(_ShellSearchNotesFound(revision, books));
      });
    }
    if (text) {
      _effect(revision, (cancellation) async {
        await _records.searchLibraryText(
          query: query,
          bookId: bookId,
          onBook: (book) => dispatch(_ShellSearchTextFound(revision, book)),
          cancellationId: cancellation,
        );
        dispatch(_ShellSearchTextFinished(revision));
      });
    }
  }

  void _effect(int revision, Future<void> Function(BigInt) body) {
    final BigInt cancellation;
    try {
      cancellation = _bridge.createCancellation();
    } catch (error) {
      dispatch(_ShellSearchFailed(revision, _describe(error)));
      return;
    }
    _cancellations.add(cancellation);
    _active += 1;
    unawaited(() async {
      try {
        await body(cancellation);
      } on FlutterBridgeError catch (error) {
        // A superseded search is cancelled; its failure is no one's.
        if (error.kind != FlutterBridgeErrorKind.cancelled) {
          dispatch(_ShellSearchFailed(revision, error.message));
        }
      } catch (error) {
        dispatch(_ShellSearchFailed(revision, _describe(error)));
      } finally {
        _cancellations.remove(cancellation);
        _bridge.releaseCancellation(id: cancellation);
        _active -= 1;
        _disposeBridgeIfIdle();
      }
    }());
  }

  void _emit(ShellSearchModel next) {
    _model = next;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _revision += 1;
    _timer?.cancel();
    for (final cancellation in _cancellations) {
      _bridge.cancel(id: cancellation);
    }
    _disposeBridgeIfIdle();
    super.dispose();
  }

  /// The bridge outlives the controller until its last search settles.
  void _disposeBridgeIfIdle() {
    if (_disposed && _active == 0 && !_bridge.isDisposed) _bridge.dispose();
  }
}

String _describe(Object error) => switch (error) {
  FlutterBridgeError(:final message) => message,
  _ => 'The search could not be completed.',
};

final class ShellSearchModel {
  const ShellSearchModel({
    this.query = '',
    this.book,
    this.scope = ShellSearchScope.allBooks,
    this.filter = ShellSearchFilter.everything,
    this.notes = const [],
    this.text = const [],
    this.notesBusy = false,
    this.textBusy = false,
    this.error,
  });

  final String query;

  /// The book being read, which This book searches; null from the library.
  final FlutterLibraryBook? book;
  final ShellSearchScope scope;
  final ShellSearchFilter filter;

  /// Books whose notes hold the query, most recently read first.
  final List<FlutterBookNoteHits> notes;

  /// Books whose text holds the query, in the order they were searched.
  final List<FlutterBookTextHits> text;
  final bool notesBusy;
  final bool textBusy;
  final String? error;

  bool get busy => notesBusy || textBusy;

  ShellSearchModel copyWith({
    String? query,
    FlutterLibraryBook? Function()? book,
    ShellSearchScope? scope,
    ShellSearchFilter? filter,
    List<FlutterBookNoteHits>? notes,
    List<FlutterBookTextHits>? text,
    bool? notesBusy,
    bool? textBusy,
    String? Function()? error,
  }) => ShellSearchModel(
    query: query ?? this.query,
    book: book == null ? this.book : book(),
    scope: scope ?? this.scope,
    filter: filter ?? this.filter,
    notes: notes == null ? this.notes : List.unmodifiable(notes),
    text: text == null ? this.text : List.unmodifiable(text),
    notesBusy: notesBusy ?? this.notesBusy,
    textBusy: textBusy ?? this.textBusy,
    error: error == null ? this.error : error(),
  );
}

sealed class ShellSearchMessage {
  const ShellSearchMessage();
}

/// The palette opened; [book] is the book being read, if any.
final class ShellSearchOpened extends ShellSearchMessage {
  const ShellSearchOpened({this.book});
  final FlutterLibraryBook? book;
}

final class ShellSearchQueryChanged extends ShellSearchMessage {
  const ShellSearchQueryChanged(this.query);
  final String query;
}

final class ShellSearchScopeChanged extends ShellSearchMessage {
  const ShellSearchScopeChanged(this.scope);
  final ShellSearchScope scope;
}

final class ShellSearchFilterChanged extends ShellSearchMessage {
  const ShellSearchFilterChanged(this.filter);
  final ShellSearchFilter filter;
}

final class _ShellSearchDue extends ShellSearchMessage {
  const _ShellSearchDue(this.revision);
  final int revision;
}

final class _ShellSearchNotesFound extends ShellSearchMessage {
  const _ShellSearchNotesFound(this.revision, this.books);
  final int revision;
  final List<FlutterBookNoteHits> books;
}

final class _ShellSearchTextFound extends ShellSearchMessage {
  const _ShellSearchTextFound(this.revision, this.book);
  final int revision;
  final FlutterBookTextHits book;
}

final class _ShellSearchTextFinished extends ShellSearchMessage {
  const _ShellSearchTextFinished(this.revision);
  final int revision;
}

final class _ShellSearchFailed extends ShellSearchMessage {
  const _ShellSearchFailed(this.revision, this.error);
  final int revision;
  final String error;
}
