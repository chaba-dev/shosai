/// Typed failures reported by the application core.
library;

/// What went wrong, independent of the message shown to a person.
///
/// The kinds follow the controller's error contract: every core failure maps to
/// exactly one kind, and messages never carry database rows or file contents.
enum CoreErrorKind {
  /// The caller cancelled the operation before it was accepted.
  cancelled,

  /// The record or file does not exist.
  notFound,

  /// The file exists but cannot be read or written.
  inaccessible,

  /// The format or operation is not supported.
  unsupported,

  /// The request is malformed or names a value outside its declared range.
  invalidRequest,

  /// Stored or supplied data is corrupt or not what its owner wrote.
  malformed,

  /// The request or stored data exceeds a resource or record limit.
  limitExceeded,

  /// The record already belongs to someone else.
  conflict,

  /// The database failed or is closed.
  storage,
}

/// A failure the core reports to its caller.
final class CoreException implements Exception {
  const CoreException(this.kind, this.message);

  const CoreException.cancelled([
    String message = 'The operation was cancelled.',
  ]) : this(CoreErrorKind.cancelled, message);

  const CoreException.notFound(String message)
    : this(CoreErrorKind.notFound, message);

  const CoreException.invalidRequest(String message)
    : this(CoreErrorKind.invalidRequest, message);

  const CoreException.malformed(String message)
    : this(CoreErrorKind.malformed, message);

  const CoreException.limitExceeded(String message)
    : this(CoreErrorKind.limitExceeded, message);

  const CoreException.conflict(String message)
    : this(CoreErrorKind.conflict, message);

  const CoreException.storage(String message)
    : this(CoreErrorKind.storage, message);

  final CoreErrorKind kind;
  final String message;

  @override
  bool operator ==(Object other) =>
      other is CoreException && other.kind == kind && other.message == message;

  @override
  int get hashCode => Object.hash(kind, message);

  @override
  String toString() => 'CoreException(${kind.name}): $message';
}
