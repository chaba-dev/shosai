import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Books another app opens in Shōsai. Hosts hand over temporary copies, never
/// originals: iOS uses its Inbox; Android and macOS stage granted documents.
class OpenedDocuments {
  int _revision = 0;
  final Set<String> _owned = {};

  static const MethodChannel _channel = MethodChannel(
    'dev.shosai/opened_documents',
  );

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
    for (final path in paths) {
      try {
        await File(path).delete();
      } on FileSystemException {
        // Already removed copies are harmless; iOS also clears its Inbox.
      } finally {
        _owned.remove(path);
      }
    }
  }
}
