/// A transient, non-blocking message raised by a controller and presented by a
/// view-layer adapter (see `SonnerBridge`).
///
/// Notices are value data, not closures: an Elm message handler raises a
/// [Notice], and the view adapter presents it and dispatches a consumption
/// message. The monotonically increasing [id] lets the view present each notice
/// exactly once.
enum NoticeKind { info, success, destructive }

final class Notice {
  const Notice({
    required this.id,
    required this.message,
    this.kind = NoticeKind.info,
  });

  final int id;
  final String message;
  final NoticeKind kind;
}
