import 'package:shosai_flutter/l10n/app_localizations.dart';

/// Severity of a presented [Notice].
enum NoticeKind { info, success, warning, failure }

/// How long a notice stays in the notice model.
///
/// [brief] notices are transient feedback (a completed save, a finished
/// import): the [NoticeCenter] expires them with its own guarded timer and the
/// host presents them as a Sonner toast. [persistent] notices describe a
/// condition that is still true (a failure, permission problem or cleanup
/// debt): they stay until the user dismisses them or the owning controller
/// resolves the condition, and the host renders them as a surface with details
/// and recovery actions instead of a toast.
enum NoticeLifetime { brief, persistent }

/// Localized notice copy.
///
/// Controllers have no `BuildContext`, so a notice carries a [NoticeText] and
/// the host resolves it through the generated [AppLocalizations] at render
/// time. Notice copy therefore lives in the standard ARB catalogs; there is no
/// hand-written locale map in this package.
abstract interface class NoticeText {
  String resolve(AppLocalizations localizations);
}

/// Copy that is data rather than interface copy.
///
/// A provider-supplied error string or a test fixture is already text and has
/// no ARB key. Production interface copy must use an ARB-backed [NoticeText]
/// implementation instead.
final class RawNoticeText implements NoticeText {
  const RawNoticeText(this.value);

  final String value;

  @override
  String resolve(AppLocalizations localizations) => value;
}

/// An action a persistent notice offers.
///
/// A notice is value data: it names the action, and the controller that
/// reported the notice registered what the action does (see
/// [NoticeRequest.onAction]). The host only reports the invocation back.
final class NoticeAction {
  const NoticeAction({
    required this.id,
    required this.label,
    this.primary = false,
  });

  /// Identifier the host reports through `NoticeActionInvoked`.
  ///
  /// Invoking it dismisses the notice without calling the owner's handler.
  static const String dismissId = 'dismiss';

  final String id;
  final NoticeText label;

  /// Whether this is the notice's primary recovery action.
  final bool primary;
}

/// An active notice as the host renders it.
final class Notice {
  const Notice({
    required this.id,
    required this.kind,
    required this.lifetime,
    required this.text,
    this.details,
    this.actions = const <NoticeAction>[],
    this.dedupeKey,
  });

  /// Center-assigned identity.
  ///
  /// Ids are monotonic and never reused, so a completion that names an id
  /// cannot act on a notice reported later.
  final int id;

  final NoticeKind kind;
  final NoticeLifetime lifetime;

  /// The notice's headline.
  final NoticeText text;

  /// Optional detail shown with a persistent notice.
  final NoticeText? details;

  final List<NoticeAction> actions;

  /// Identity of the unresolved condition this notice describes, or null.
  ///
  /// While a notice with the same key is active, the center suppresses another
  /// report for that key, so a repeated failure does not present the same
  /// unresolved problem again. Dismissing the notice or resolving the key
  /// re-arms it.
  final String? dedupeKey;
}

/// A notice a controller asks the center to present.
final class NoticeRequest {
  const NoticeRequest({
    required this.text,
    this.kind = NoticeKind.info,
    this.lifetime = NoticeLifetime.brief,
    this.details,
    this.actions = const <NoticeAction>[],
    this.dedupeKey,
    this.onAction,
  });

  final NoticeText text;
  final NoticeKind kind;
  final NoticeLifetime lifetime;
  final NoticeText? details;
  final List<NoticeAction> actions;
  final String? dedupeKey;

  /// Invoked when the user activates one of [actions].
  ///
  /// The reporting controller owns the recovery effect: its handler dispatches
  /// its own typed message (for example a retry), and the center clears the
  /// notice before calling it. A null handler means the notice has no actions
  /// beyond the host's dismissal.
  final NoticeActionHandler? onAction;
}

/// Receives the action id a user activated on a reported notice.
typedef NoticeActionHandler = void Function(String actionId);

/// The adapter feature controllers use to report outcomes.
///
/// The composition root injects the [NoticeCenter]'s reporter into a feature
/// controller; the controller never owns notice state and never mutates it.
typedef NoticeReporter = void Function(NoticeRequest request);

/// Default [NoticeReporter] for controllers constructed without a center.
void ignoreNotice(NoticeRequest request) {}
