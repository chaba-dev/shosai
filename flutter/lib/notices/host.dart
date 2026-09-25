import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shosai_flutter/app_theme.dart';
import 'package:shosai_flutter/l10n/app_localizations.dart';
import 'package:shosai_flutter/shared/shad_widgets.dart';

import 'controller.dart';
import 'notice.dart';

/// Presents the [NoticeCenter]'s notices for the application.
///
/// This is the view-layer adapter for the notice boundary: it observes the
/// immutable notice model, presents each notice exactly once, and reports user
/// acknowledgment back as typed messages. It never mutates the model.
///
/// Brief notices are presented as Sonner toasts through the host that
/// `ShadAppBuilder` already installs; there is no parallel toast stack.
/// Persistent notices are rendered as a surface above [child] with their
/// details and recovery actions, because a condition that is still true must
/// not disappear on a timer.
///
/// One host presents into one Sonner for the lifetime of both: the application
/// installs a single host in the shell, and a host that is unmounted while its
/// Sonner survives cannot see that Sonner's in-flight retirements. Mount a new
/// host only when the Sonner is replaced with it.
class NoticeHost extends StatefulWidget {
  const NoticeHost({super.key, required this.center, required this.child});

  final NoticeCenter center;
  final Widget child;

  @override
  State<NoticeHost> createState() => _NoticeHostState();
}

class _NoticeHostState extends State<NoticeHost> {
  /// Toasts occupying a slot in the Sonner, oldest first.
  ///
  /// A handle stays here until the Sonner has actually removed its toast, so a
  /// retirement in flight still counts against capacity and the host never
  /// presents into the Sonner's private overflow list. The handle keeps the
  /// owning Sonner and the toast identifier that host returned, so retirement
  /// targets the toast this host presented rather than an identifier another
  /// center could reuse.
  final List<_ToastPresentation> _presentations = [];

  /// Model ids this host has already presented.
  ///
  /// A notice whose toast was replaced to free a slot stays presented: the
  /// model still holds it, but presenting it again would replace another toast
  /// and cycle instead of showing the newer feedback.
  final Set<int> _presented = {};

  /// Model ids waiting for a free toast slot.
  final List<int> _pending = [];
  bool _presentationScheduled = false;

  /// How many toasts the installed Sonner shows at once.
  ///
  /// The host never presents more than this, because the component layer moves
  /// a surplus toast into its private overflow list, where a later removal does
  /// not retire it and it would be shown again after its notice was gone.
  int _visibleToastLimit = 3;

  @override
  void initState() {
    super.initState();
    widget.center.addListener(_changed);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // At least one toast must be presentable, or a theme that reports zero
    // visible toasts would retire a presentation for every pending notice
    // without ever showing one.
    _visibleToastLimit = math.max(
      1,
      ShadTheme.of(context).sonnerTheme.visibleToastsAmount ?? 3,
    );
    // The Sonner host is an inherited widget, so presentation waits for a
    // frame in which it can be looked up.
    _schedulePresentation();
  }

  @override
  void didUpdateWidget(NoticeHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.center != widget.center) {
      // The old center's notices are not the new center's: retire their toasts
      // instead of leaving them to be confused with the new ids.
      _retireAll();
      oldWidget.center.removeListener(_changed);
      widget.center.addListener(_changed);
      _schedulePresentation();
    }
  }

  @override
  void dispose() {
    widget.center.removeListener(_changed);
    _retireAll();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    _schedulePresentation();
  }

  /// Presents and retires toasts after the frame that changed the model.
  ///
  /// Presenting during build would mark the Sonner host dirty while the tree is
  /// building, so the presentation effect runs as a post-frame completion of
  /// the model change that authorized it.
  void _schedulePresentation() {
    if (_presentationScheduled) return;
    _presentationScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _presentationScheduled = false;
      if (!mounted) return;
      _syncPresentations();
    });
  }

  void _syncPresentations() {
    final sonner = ShadSonner.maybeOf(context);
    if (sonner == null) return;
    final wanted = [
      for (final notice in widget.center.model.active)
        if (notice.lifetime == NoticeLifetime.brief) notice.id,
    ];
    final wantedIds = wanted.toSet();
    for (final presentation
        in _presentations
            .where((presentation) => !presentation.retiring)
            .toList(growable: false)) {
      if (wantedIds.contains(presentation.noticeId)) continue;
      // The notice expired, was dismissed, or was resolved: retire its toast.
      _retire(presentation);
    }
    _pending.removeWhere((id) => !wantedIds.contains(id));
    _presented.removeWhere((id) => !wantedIds.contains(id));
    for (final id in wanted) {
      if (_presented.contains(id) || _pending.contains(id)) continue;
      _pending.add(id);
    }
    _drain(sonner);
  }

  void _drain(ShadSonnerState sonner) {
    while (_pending.isNotEmpty) {
      if (_presentations.length >= _visibleToastLimit) {
        if (_presentations.any((presentation) => presentation.retiring)) {
          // Capacity is released when a retirement in flight completes; the
          // next presentation waits rather than pushing the Sonner into its
          // private overflow list.
          return;
        }
        // Replace the oldest live toast. Its notice is already recorded as
        // presented, so it is not queued again.
        _retire(_presentations.first);
        return;
      }
      final notice = _activeNotice(_pending.removeAt(0));
      // A notice that expired while it waited is simply not presented.
      if (notice == null) continue;
      _present(sonner, notice);
    }
  }

  Notice? _activeNotice(int id) {
    for (final notice in widget.center.model.active) {
      if (notice.id == id) return notice;
    }
    return null;
  }

  void _present(ShadSonnerState sonner, Notice notice) {
    final localizations = AppLocalizations.of(context);
    final toastId = sonner.show(_toastFor(notice, localizations));
    _presentations.add(_ToastPresentation(notice.id, sonner, toastId));
    _presented.add(notice.id);
  }

  void _retire(_ToastPresentation presentation) {
    if (presentation.retiring) return;
    presentation.retiring = true;
    unawaited(
      presentation.sonner.hide(presentation.toastId).whenComplete(() {
        _presentations.remove(presentation);
        if (!mounted) return;
        _schedulePresentation();
      }),
    );
  }

  void _retireAll() {
    for (final presentation in _presentations.toList(growable: false)) {
      if (presentation.retiring) continue;
      presentation.retiring = true;
      final sonner = presentation.sonner;
      // The host may be tearing down with the Sonner, so retirement is deferred
      // and skips a Sonner that is no longer mounted.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!sonner.mounted) return;
        unawaited(
          sonner.hide(presentation.toastId).whenComplete(() {
            _presentations.remove(presentation);
            if (!mounted) return;
            _schedulePresentation();
          }),
        );
      });
    }
    _pending.clear();
    _presented.clear();
  }

  ShadToast _toastFor(Notice notice, AppLocalizations localizations) {
    final details = notice.details;
    return ShadToast.raw(
      variant: notice.kind == NoticeKind.failure
          ? ShadToastVariant.destructive
          : ShadToastVariant.primary,
      title: Text(notice.text.resolve(localizations)),
      description: details == null
          ? null
          : Text(details.resolve(localizations)),
      duration: widget.center.briefDuration,
    );
  }

  @override
  Widget build(BuildContext context) {
    final persistent = widget.center.model.active
        .where((notice) => notice.lifetime == NoticeLifetime.persistent)
        .toList(growable: false);
    // The content slot is always the same child of the same column, so adding
    // or dismissing a notice never recreates the subtree (and its controllers)
    // below it.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final notice in persistent)
              PersistentNoticeSurface(
                notice: notice,
                onDismiss: () =>
                    widget.center.dispatch(NoticeDismissed(notice.id)),
                onAction: (actionId) => widget.center.dispatch(
                  NoticeActionInvoked(notice.id, actionId),
                ),
              ),
          ],
        ),
        Expanded(child: widget.child),
      ],
    );
  }
}

/// One presented brief notice.
///
/// [retiring] is set once the host has started hiding the toast; the handle
/// keeps occupying a slot until the Sonner has actually removed it.
final class _ToastPresentation {
  _ToastPresentation(this.noticeId, this.sonner, this.toastId);

  final int noticeId;
  final ShadSonnerState sonner;
  final Object? toastId;
  bool retiring = false;
}

/// The persistent surface for one notice: headline, details and actions.
///
/// A persistent notice stays until the user dismisses it or the owning
/// controller resolves its condition, so it uses the component layer's alert
/// rather than a toast. Every declared action is rendered, including a declared
/// dismiss; when the notice declares none, the alert's close affordance is the
/// dismissal, so a persistent condition is never undismissable.
class PersistentNoticeSurface extends StatelessWidget {
  const PersistentNoticeSurface({
    super.key,
    required this.notice,
    required this.onDismiss,
    required this.onAction,
  });

  final Notice notice;
  final VoidCallback onDismiss;
  final ValueChanged<String> onAction;

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context);
    final details = notice.details;
    final actions = notice.actions;
    final declaresDismiss = notice.actions.any(
      (action) => action.id == NoticeAction.dismissId,
    );
    final destructive = notice.kind == NoticeKind.failure;
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (details != null)
          Semantics(
            liveRegion: true,
            child: Text(details.resolve(localizations)),
          ),
        if (actions.isNotEmpty)
          Padding(
            padding: EdgeInsets.only(top: details == null ? 0 : 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final action in actions)
                  action.primary
                      ? ShadButton(
                          height: shosaiShadButtonHeight(context),
                          onPressed: () => onAction(action.id),
                          child: Text(action.label.resolve(localizations)),
                        )
                      : ShadButton.outline(
                          height: shosaiShadButtonHeight(context),
                          onPressed: () => onAction(action.id),
                          child: Text(action.label.resolve(localizations)),
                        ),
              ],
            ),
          ),
      ],
    );
    final alert = ShadAlert.raw(
      variant: destructive
          ? ShadAlertVariant.destructive
          : ShadAlertVariant.primary,
      icon: Icon(switch (notice.kind) {
        NoticeKind.failure => LucideIcons.circleAlert,
        NoticeKind.warning => LucideIcons.triangleAlert,
        NoticeKind.info || NoticeKind.success => LucideIcons.info,
      }),
      title: Semantics(
        liveRegion: true,
        child: Text(notice.text.resolve(localizations)),
      ),
      description: content,
      trailing: declaresDismiss
          ? null
          : ShadIconAction(
              tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
              onPressed: onDismiss,
              icon: const Icon(LucideIcons.x),
            ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: alert,
    );
  }
}
