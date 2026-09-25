/// Typed messages the notice center's update handles.
///
/// A feature controller never dispatches these directly: it calls
/// [NoticeCenter.report] or [NoticeCenter.resolve], which convert the call into
/// a message. The view layer dispatches only [NoticeDismissed] and
/// [NoticeActionInvoked]; [NoticeExpired] is the center's own guarded
/// completion.
part of 'controller.dart';

sealed class NoticeMessage {
  const NoticeMessage();
}

/// A controller reported an outcome through the [NoticeReporter] adapter.
final class NoticeReported extends NoticeMessage {
  const NoticeReported(this.request);

  final NoticeRequest request;
}

/// The brief-lifetime timer for [id] elapsed.
///
/// [revision] is the notice revision the timer was authorized with. A
/// completion that does not match the active revision is a late completion for
/// a superseded notice and is ignored.
final class NoticeExpired extends NoticeMessage {
  const NoticeExpired(this.id, this.revision);

  final int id;
  final int revision;
}

/// The user dismissed the notice [id].
final class NoticeDismissed extends NoticeMessage {
  const NoticeDismissed(this.id);

  final int id;
}

/// The user activated [actionId] on the notice [id].
final class NoticeActionInvoked extends NoticeMessage {
  const NoticeActionInvoked(this.id, this.actionId);

  final int id;
  final String actionId;
}

/// The condition [dedupeKey] identified is no longer true.
final class NoticeResolved extends NoticeMessage {
  const NoticeResolved(this.dedupeKey);

  final String dedupeKey;
}
