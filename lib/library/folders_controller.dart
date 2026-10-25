import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shosai_core/shosai_core.dart';
import 'package:shosai_flutter/core/library_folders.dart';
import 'package:shosai_flutter/core/platform_folder_location.dart';

sealed class FoldersMessage {
  const FoldersMessage();
}

final class FoldersStarted extends FoldersMessage {
  const FoldersStarted();
}

final class FoldersAddRequested extends FoldersMessage {
  const FoldersAddRequested();
}

final class FoldersSelected extends FoldersMessage {
  const FoldersSelected(this.id);
  final String id;
}

final class FoldersEntryChosen extends FoldersMessage {
  const FoldersEntryChosen(this.entry);
  final LocationEntry entry;
}

final class FoldersBackRequested extends FoldersMessage {
  const FoldersBackRequested();
}

final class FoldersNextRequested extends FoldersMessage {
  const FoldersNextRequested();
}

final class FoldersRemoveRequested extends FoldersMessage {
  const FoldersRemoveRequested(this.id);
  final String id;
}

final class _FoldersLoaded extends FoldersMessage {
  const _FoldersLoaded(this.revision, this.grants);
  final int revision;
  final List<FolderGrant> grants;
}

final class _FoldersListed extends FoldersMessage {
  const _FoldersListed(this.revision, this.page);
  final int revision;
  final LocationPage page;
}

final class _FoldersImported extends FoldersMessage {
  const _FoldersImported(this.revision);
  final int revision;
}

final class _FoldersFailed extends FoldersMessage {
  const _FoldersFailed(this.revision, this.error);
  final int revision;
  final Object error;
}

@immutable
final class FoldersModel {
  const FoldersModel({
    this.grants = const [],
    this.selected,
    this.parents = const [],
    this.entries = const [],
    this.nextCursor,
    this.busy = false,
    this.error,
    this.added = false,
  });
  final List<FolderGrant> grants;
  final String? selected;
  final List<LocationEntry> parents;
  final List<LocationEntry> entries;
  final String? nextCursor;
  final bool busy;
  final Object? error;
  final bool added;
}

/// Dialog-local navigation state. Folder grants and imported content belong to
/// the shared application service, so closing this controller cancels work but
/// never destroys durable books or notes.
final class FoldersController extends ChangeNotifier {
  FoldersController({
    required LibraryFolders folders,
    required Future<FolderGrant?> Function(String id) pick,
    required Future<bool> Function(FolderGrant grant) confirmRemoval,
  }) : _folders = folders,
       _pick = pick,
       _confirmRemoval = confirmRemoval;
  final LibraryFolders _folders;
  final Future<FolderGrant?> Function(String id) _pick;
  final Future<bool> Function(FolderGrant grant) _confirmRemoval;
  FoldersModel _model = const FoldersModel();
  FoldersModel get model => _model;
  int _revision = 0;
  bool _closed = false;
  CancellationToken? _cancellation;
  final Set<Future<void>> _running = {};

  Future<void> drain() async {
    while (_running.isNotEmpty) {
      await Future.wait(List.of(_running));
    }
  }

  void _emit(FoldersModel value) {
    if (!_closed) {
      _model = value;
      notifyListeners();
    }
  }

  void dispatch(FoldersMessage message) {
    if (_closed) return;
    switch (message) {
      case FoldersStarted():
        if (_model.busy) return;
        _effect(
          (revision, _) async =>
              _FoldersLoaded(revision, await _folders.list()),
        );
      case FoldersAddRequested():
        if (_model.busy) return;
        _effect((revision, cancellation) async {
          final grant = await _pick(LibraryFolders.newId());
          if (grant != null) {
            if (_closed || revision != _revision) {
              await _folders.discard(grant);
              cancellation.throwIfCancelled();
            }
            try {
              await _folders.add(grant);
            } catch (_) {
              await _folders.discard(grant);
              rethrow;
            }
          }
          return _FoldersLoaded(revision, await _folders.list());
        });
      case FoldersSelected():
        if (_model.busy) return;
        _emit(FoldersModel(grants: _model.grants, selected: message.id));
        _browse();
      case FoldersEntryChosen():
        if (_model.busy || _model.selected == null) return;
        if (message.entry.isDirectory) {
          _emit(
            FoldersModel(
              grants: _model.grants,
              selected: _model.selected,
              parents: List.unmodifiable([..._model.parents, message.entry]),
            ),
          );
          _browse();
        } else {
          final id = _model.selected!;
          _effect((revision, cancellation) async {
            await _folders.importEntry(
              id,
              message.entry,
              cancellation: cancellation,
            );
            return _FoldersImported(revision);
          });
        }
      case FoldersBackRequested():
        if (_model.busy) return;
        if (_model.parents.isEmpty) {
          _emit(FoldersModel(grants: _model.grants));
        } else {
          _emit(
            FoldersModel(
              grants: _model.grants,
              selected: _model.selected,
              parents: List.unmodifiable(
                _model.parents.take(_model.parents.length - 1),
              ),
            ),
          );
          _browse();
        }
      case FoldersNextRequested():
        if (!_model.busy && _model.nextCursor != null) {
          _browse(cursor: _model.nextCursor);
        }
      case FoldersRemoveRequested():
        if (_model.busy) return;
        final grant = _model.grants.firstWhere(
          (entry) => entry.id == message.id,
        );
        _effect((revision, cancellation) async {
          if (await _confirmRemoval(grant)) {
            cancellation.throwIfCancelled();
            await _folders.remove(grant.id);
          }
          return _FoldersLoaded(revision, await _folders.list());
        });
      case _FoldersLoaded():
        if (message.revision != _revision) return;
        _emit(FoldersModel(grants: List.unmodifiable(message.grants)));
      case _FoldersListed():
        if (message.revision != _revision) return;
        _emit(
          FoldersModel(
            grants: _model.grants,
            selected: _model.selected,
            parents: _model.parents,
            entries: message.page.entries,
            nextCursor: message.page.nextCursor,
          ),
        );
      case _FoldersImported():
        if (message.revision != _revision) return;
        _emit(
          FoldersModel(
            grants: _model.grants,
            selected: _model.selected,
            parents: _model.parents,
            entries: _model.entries,
            nextCursor: _model.nextCursor,
            added: true,
          ),
        );
      case _FoldersFailed():
        if (message.revision != _revision) return;
        _emit(
          FoldersModel(
            grants: _model.grants,
            selected: _model.selected,
            parents: _model.parents,
            entries: _model.entries,
            nextCursor: _model.nextCursor,
            error: message.error,
          ),
        );
    }
  }

  void _browse({String? cursor}) {
    final id = _model.selected!;
    final directory = _model.parents.lastOrNull?.key;
    _effect(
      (revision, cancellation) async => _FoldersListed(
        revision,
        await _folders.browse(
          id,
          directory: directory,
          cursor: cursor,
          cancellation: cancellation,
        ),
      ),
    );
  }

  void _effect(Future<FoldersMessage> Function(int, CancellationToken) run) {
    final revision = ++_revision;
    _cancellation?.cancel();
    final cancellation = _cancellation = CancellationToken();
    _emit(
      FoldersModel(
        grants: _model.grants,
        selected: _model.selected,
        parents: _model.parents,
        entries: _model.entries,
        nextCursor: _model.nextCursor,
        busy: true,
      ),
    );
    late final Future<void> pending;
    pending = () async {
      try {
        dispatch(await run(revision, cancellation));
      } catch (error) {
        dispatch(_FoldersFailed(revision, error));
      }
    }().whenComplete(() => _running.remove(pending));
    _running.add(pending);
    unawaited(pending);
  }

  @override
  void dispose() {
    _closed = true;
    _revision++;
    _cancellation?.cancel();
    super.dispose();
  }
}
