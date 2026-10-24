/// Work that runs off the calling isolate and stops when it is cancelled.
library;

import 'dart:async';
import 'dart:isolate';

import 'cancellation.dart';
import 'errors.dart';

/// Run [work] on a new isolate, as [Isolate.run] does, and kill that isolate
/// if [cancellation] is cancelled first; the returned future then fails with
/// [CoreErrorKind.cancelled]. It settles only once the worker has exited, so
/// after a cancellation the caller can clean up knowing the worker is gone.
///
/// A killed worker stops between any two of its steps, so [work] must leave
/// nothing behind that the caller cannot clean up. Like [Isolate.run], [work]
/// must capture only values that can be sent to another isolate.
Future<R> runCancellable<R>(
  FutureOr<R> Function() work, {
  CancellationToken? cancellation,
}) async {
  cancellation.throwIfCancelled();
  if (cancellation == null) return Isolate.run(work);
  final result = Completer<R>();
  final port = RawReceivePort();
  Object? reply;
  var cancelled = false;
  port.handler = (Object? message) {
    // The worker's reply (never null) arrives before its exit message (null).
    if (message != null) {
      reply = message;
      return;
    }
    port.close();
    if (cancelled && reply == null) {
      result.completeError(const CoreException.cancelled());
      return;
    }
    switch (reply) {
      case (final R value,):
        result.complete(value);
      case (final Object error, final String stack):
        result.completeError(error, StackTrace.fromString(stack));
      default:
        result.completeError(
          RemoteError('The worker isolate exited without a result.', ''),
        );
    }
  };
  final Isolate isolate;
  try {
    isolate = await Isolate.spawn(
      _runWork<R>,
      (work, port.sendPort),
      onExit: port.sendPort,
      errorsAreFatal: true,
    );
  } catch (_) {
    port.close();
    rethrow;
  }
  unawaited(
    cancellation.whenCancelled.then((_) {
      if (result.isCompleted || reply != null) return;
      cancelled = true;
      isolate.kill(priority: Isolate.immediate);
    }),
  );
  return result.future;
}

Future<void> _runWork<R>((FutureOr<R> Function(), SendPort) request) async {
  final (work, reply) = request;
  Object message;
  try {
    message = (await work(),);
  } catch (error, stack) {
    message = (error, stack.toString());
  }
  Isolate.exit(reply, message);
}
