import 'dart:async';

import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:shosai_flutter/core/bridge.dart';
import 'package:shosai_flutter/core/records.dart';

/// The Notes place: every highlight and note across the library, books most
/// recently read first (RFD 6, Notes surface).
///
/// It follows the shell's Elm boundary (`docs/flutter-architecture.md`): the
/// place renders the immutable [ShellNotesModel] and dispatches
/// [ShellNotesMessage] values, and the controller runs the one effect it owns,
/// listing a page of the library's notes. A completion carries the revision
/// it was started for, so a list that a newer request superseded is dropped.
class ShellNotesController extends ChangeNotifier {
  ShellNotesController({required FlutterBridge bridge})
    : _bridge = bridge,
      _records = recordsOf(bridge);

  /// Books listed per page.
  static const pageSize = 20;

  final FlutterBridge _bridge;
  final ShosaiRecords _records;
  ShellNotesModel _model = const ShellNotesModel();
  BigInt? _cancellation;
  int _revision = 0;
  int _active = 0;
  bool _disposed = false;

  ShellNotesModel get model => _model;

  void dispatch(ShellNotesMessage message) {
    if (_disposed) return;
    switch (message) {
      case ShellNotesRequested():
        _load(append: false);
      case ShellNotesMoreRequested():
        // After a failed page this is its retry.
        if (_model.hasMore && !_model.loading) {
          _load(append: true);
        }
      case _ShellNotesLoaded(:final revision, :final page, :final append):
        if (revision != _revision) return;
        _emit(
          ShellNotesModel(
            status: ShellNotesStatus.loaded,
            books: List.unmodifiable([
              if (append) ..._model.books,
              ...page.books,
            ]),
            hasMore: page.hasMore,
          ),
        );
      case _ShellNotesFailed(:final revision, :final error, :final append):
        if (revision != _revision) return;
        // A page that fails after others keeps what was listed; its error
        // replaces the More action until a retry.
        _emit(
          _model.copyWith(
            status: append ? ShellNotesStatus.loaded : ShellNotesStatus.failed,
            books: append ? null : const [],
            hasMore: append ? null : false,
            error: () => error,
          ),
        );
    }
  }

  void _load({required bool append}) {
    final revision = ++_revision;
    if (_cancellation case final previous?) _bridge.cancel(id: previous);
    final BigInt cancellation;
    try {
      cancellation = _bridge.createCancellation();
    } catch (error) {
      dispatch(_ShellNotesFailed(revision, _describe(error), append: append));
      return;
    }
    _cancellation = cancellation;
    _emit(
      _model.copyWith(
        status: append ? null : ShellNotesStatus.loading,
        appending: append,
        error: () => null,
      ),
    );
    final offset = append ? _model.books.length : 0;
    _active += 1;
    unawaited(() async {
      try {
        final page = await _records.libraryNotes(
          limit: pageSize,
          offset: offset,
          cancellationId: cancellation,
        );
        dispatch(_ShellNotesLoaded(revision, page, append: append));
      } catch (error) {
        dispatch(_ShellNotesFailed(revision, _describe(error), append: append));
      } finally {
        if (identical(_cancellation, cancellation)) _cancellation = null;
        _bridge.releaseCancellation(id: cancellation);
        _active -= 1;
        _disposeBridgeIfIdle();
      }
    }());
  }

  void _emit(ShellNotesModel next) {
    _model = next;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _revision += 1;
    if (_cancellation case final cancellation?) {
      _bridge.cancel(id: cancellation);
    }
    _disposeBridgeIfIdle();
    super.dispose();
  }

  /// The bridge outlives the controller until its last list settles.
  void _disposeBridgeIfIdle() {
    if (_disposed && _active == 0 && !_bridge.isDisposed) _bridge.dispose();
  }
}

String _describe(Object error) => switch (error) {
  FlutterBridgeError(:final message) => message,
  _ => 'The notes could not be listed.',
};

enum ShellNotesStatus { idle, loading, loaded, failed }

final class ShellNotesModel {
  const ShellNotesModel({
    this.status = ShellNotesStatus.idle,
    this.books = const [],
    this.hasMore = false,
    this.appending = false,
    this.error,
  });

  final ShellNotesStatus status;

  /// The listed books with their notes, most recently read first.
  final List<FlutterBookNotes> books;
  final bool hasMore;

  /// Whether a further page is being listed.
  final bool appending;

  /// Why the last list failed: the whole list, or the page after [books].
  final String? error;

  bool get loading => status == ShellNotesStatus.loading || appending;

  ShellNotesModel copyWith({
    ShellNotesStatus? status,
    List<FlutterBookNotes>? books,
    bool? hasMore,
    bool? appending,
    String? Function()? error,
  }) => ShellNotesModel(
    status: status ?? this.status,
    books: books ?? this.books,
    hasMore: hasMore ?? this.hasMore,
    appending: appending ?? false,
    error: error == null ? this.error : error(),
  );
}

sealed class ShellNotesMessage {
  const ShellNotesMessage();
}

/// Lists the library's notes again from the first page.
final class ShellNotesRequested extends ShellNotesMessage {
  const ShellNotesRequested();
}

/// Lists the next page of books.
final class ShellNotesMoreRequested extends ShellNotesMessage {
  const ShellNotesMoreRequested();
}

final class _ShellNotesLoaded extends ShellNotesMessage {
  const _ShellNotesLoaded(this.revision, this.page, {required this.append});
  final int revision;
  final FlutterLibraryNotesPage page;
  final bool append;
}

final class _ShellNotesFailed extends ShellNotesMessage {
  const _ShellNotesFailed(this.revision, this.error, {required this.append});
  final int revision;
  final String error;
  final bool append;
}
