/// Cooperative cancellation for long core operations.
library;

import 'dart:async';

import 'errors.dart';

/// Requests that an operation stop at its next cancellation point.
///
/// Cancellation is cooperative: an operation checks the token between bounded
/// steps (a file chunk, an imported book) and stops before its next effect.
/// Once an operation has started committing a result it finishes, so a
/// cancelled operation either has no effect or reports what it completed.
final class CancellationToken {
  final _cancelled = Completer<void>();

  bool get isCancelled => _cancelled.isCompleted;

  /// Completes when [cancel] is called.
  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }
}

extension CancellationCheck on CancellationToken? {
  /// Throw [CoreErrorKind.cancelled] when this token was cancelled.
  void throwIfCancelled() {
    if (this?.isCancelled ?? false) throw const CoreException.cancelled();
  }
}
