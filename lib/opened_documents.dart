import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shosai_core/shosai_core.dart'
    show
        CancellationToken,
        CancellationCheck,
        CoreException,
        maxSelectedImportPaths,
        copyAndFingerprint;

import 'core/documents.dart' show DocumentSnapshots;

/// Books another app opens in Shōsai. Hosts hand over temporary copies, never
/// originals: iOS uses its Inbox; Android and macOS stage granted documents.
class OpenedDocuments {
  int _revision = 0;
  final Set<String> _owned = {};
  final _staged = <String, DocumentSnapshots>{};
  final _staging = <CancellationToken>{};

  static const MethodChannel _channel = MethodChannel(
    'dev.shosai/opened_documents',
  );

  /// Own iOS picker inputs before Review can outlive its disposable Inbox.
  /// Each original basename survives, including equal names from different
  /// folders. These are not admitted books; [discard] releases them.
  Future<List<String>> stagePickerCopies(List<String> paths) async {
    if (paths.isEmpty) return [];
    if (paths.length > maxSelectedImportPaths) {
      throw const CoreException.limitExceeded('Too many selected books.');
    }
    final cancellation = CancellationToken();
    _staging.add(cancellation);
    DocumentSnapshots? snapshots;
    final staged = <String>[];
    try {
      final support = await getApplicationSupportDirectory();
      cancellation.throwIfCancelled();
      snapshots = DocumentSnapshots('${support.path}/import-snapshots');
      await snapshots.sweep();
      for (final path in paths) {
        cancellation.throwIfCancelled();
        final directory = await Directory(await snapshots.newPath()).create();
        final destination =
            '${directory.path}/${File(path).uri.pathSegments.last}';
        await copyAndFingerprint(path, destination, cancellation: cancellation);
        staged.add(destination);
      }
      cancellation.throwIfCancelled();
      for (final path in staged) {
        _staged[path] = snapshots;
      }
      return List.unmodifiable(staged);
    } catch (_) {
      await snapshots?.close();
      rethrow;
    } finally {
      _staging.remove(cancellation);
    }
  }

  /// Delivers each batch of opened books' paths to [onOpened], starting
  /// with the books that opened the app before Dart was listening.
  Future<void> listen(void Function(List<String> paths) onOpened) async {
    final revision = ++_revision;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'opened') {
        await _takePending(revision, onOpened);
      }
    });
    await _takePending(revision, onOpened);
  }

  Future<void> _takePending(
    int revision,
    void Function(List<String>) onOpened,
  ) async {
    final List<String>? pending;
    try {
      pending = await _channel.invokeListMethod<String>('takePending');
    } on MissingPluginException {
      // A host without the channel, such as a widget test, opens no books.
      return;
    }
    if (pending == null || pending.isEmpty) return;
    // A duplicate delivery must not delete a copy an active import owns.
    final paths = pending
        .where((path) => !_owned.contains(path))
        .toSet()
        .toList();
    if (revision != _revision) {
      await discard(paths);
    } else if (paths.isNotEmpty) {
      _owned.addAll(paths);
      onOpened(List.unmodifiable(paths));
    }
  }

  /// Stops delivery; books opened later wait for the next [listen].
  /// A response already in flight is cancelled by releasing its copies.
  void cancel() {
    _revision += 1;
    _channel.setMethodCallHandler(null);
    cancelPickerStaging();
  }

  /// Cancel picker work without interrupting opened-document delivery.
  void cancelPickerStaging() {
    for (final cancellation in _staging) {
      cancellation.cancel();
    }
  }

  /// Releases only platform-owned temporary copies, after importing or cancelling.
  Future<void> discard(Iterable<String> paths) async {
    if (paths.isEmpty) return;
    if (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.macOS) {
      // Native retains cleanup ownership of staging sessions (and Android's
      // provider resources). Never fall back to deleting an external path.
      final copies = paths.toList();
      await _channel.invokeMethod<void>('discard', copies);
      _owned.removeAll(copies);
      return;
    }
    final released = <DocumentSnapshots>{};
    for (final path in paths) {
      try {
        await File(path).delete();
      } on FileSystemException {
        // Already removed copies are harmless; iOS also clears its Inbox.
      } finally {
        _owned.remove(path);
        final snapshots = _staged.remove(path);
        if (snapshots != null) released.add(snapshots);
      }
    }
    for (final snapshots in released) {
      if (!_staged.containsValue(snapshots)) await snapshots.close();
    }
  }
}
