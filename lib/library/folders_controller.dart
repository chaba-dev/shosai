import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shosai_core/shosai_core.dart';
import 'package:shosai_flutter/core/library_connection.dart';
import 'package:shosai_flutter/core/library_folders.dart';

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

final class FoldersChooseDirectoryRequested extends FoldersMessage {
  const FoldersChooseDirectoryRequested();
}

final class FoldersDirectorySaved extends FoldersMessage {
  const FoldersDirectorySaved();
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
  const _FoldersLoaded(this.revision, this.grants, {this.selected});
  final int revision;
  final List<LibraryConnection> grants;
  final String? selected;
}

final class _FoldersListed extends FoldersMessage {
  const _FoldersListed(this.revision, this.page);
  final int revision;
  final LocationPage page;
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
    this.choosingDirectory = false,
  });
  final List<LibraryConnection> grants;
  final String? selected;
  final List<LocationEntry> parents;
  final List<LocationEntry> entries;
  final String? nextCursor;
  final bool busy;
  final Object? error;
  final bool choosingDirectory;
}

/// Dialog-local navigation state. Connections and imported content belong to
/// the shared application service, so closing this controller cancels work but
/// never destroys durable books or notes.
final class FoldersController extends ChangeNotifier {
  FoldersController({
    required LibraryFolders folders,
    required Future<LibraryConnection?> Function(String id) setup,
    required Future<bool> Function(LibraryConnection connection) confirmRemoval,
  }) : _folders = folders,
       _setup = setup,
       _confirmRemoval = confirmRemoval;
  final LibraryFolders _folders;
  final Future<LibraryConnection?> Function(String id) _setup;
  final Future<bool> Function(LibraryConnection connection) _confirmRemoval;
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
          final grant = await _setup(LibraryFolders.newId());
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
      case FoldersChooseDirectoryRequested():
        if (_model.busy || _model.selected == null) return;
        _emit(
          FoldersModel(
            grants: _model.grants,
            selected: _model.selected,
            choosingDirectory: true,
          ),
        );
        _browse();
      case FoldersDirectorySaved():
        if (_model.busy || !_model.choosingDirectory) return;
        final id = _model.selected!;
        final directory = _model.parents.lastOrNull;
        final label = directory == null
            ? null
            : _model.parents.map((entry) => entry.name).join('/');
        _effect((revision, _) async {
          await _folders.configure(id, directory: directory?.key, label: label);
          return _FoldersLoaded(revision, await _folders.list(), selected: id);
        });
      case FoldersEntryChosen():
        if (_model.busy || !_model.choosingDirectory) return;
        if (message.entry.isDirectory) {
          _emit(
            FoldersModel(
              grants: _model.grants,
              selected: _model.selected,
              choosingDirectory: true,
              parents: List.unmodifiable([..._model.parents, message.entry]),
            ),
          );
          _browse();
        }
      case FoldersBackRequested():
        if (_model.busy) return;
        if (!_model.choosingDirectory) {
          _emit(FoldersModel(grants: _model.grants));
        } else if (_model.parents.isEmpty) {
          _emit(FoldersModel(grants: _model.grants, selected: _model.selected));
        } else {
          _emit(
            FoldersModel(
              grants: _model.grants,
              selected: _model.selected,
              choosingDirectory: true,
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
        _emit(
          FoldersModel(
            grants: List.unmodifiable(message.grants),
            selected: message.selected,
          ),
        );
      case _FoldersListed():
        if (message.revision != _revision) return;
        _emit(
          FoldersModel(
            grants: _model.grants,
            selected: _model.selected,
            choosingDirectory: true,
            parents: _model.parents,
            entries: message.page.entries,
            nextCursor: message.page.nextCursor,
          ),
        );
      case _FoldersFailed():
        if (message.revision != _revision) return;
        _emit(
          FoldersModel(
            grants: _model.grants,
            selected: _model.selected,
            choosingDirectory: _model.choosingDirectory,
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
        choosingDirectory: _model.choosingDirectory,
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
