import 'dart:async';

import 'package:flutter/foundation.dart' show Listenable, VoidCallback;

import 'notice.dart';
import 'policy.dart';

part 'message.dart';
part 'model.dart';

/// The application-level notice center.
///
/// This is the Elm boundary for feedback. Feature controllers report a
/// [NoticeRequest] through the [reporter] adapter; this controller's message
/// handling owns which notices are active; the host presents them and
/// dispatches typed acknowledgment messages back. The center never mutates
/// another controller's state: a notice action invokes the handler its owning
/// controller registered when it reported the notice.
///
/// Guarding rules:
/// - Ids are monotonic and never reused, so a completion that names an id
///   cannot act on a notice reported afterwards.
/// - Brief expiry is a controller-owned timer whose completion carries the id
///   and the revision that authorized it; a completion for a superseded notice
///   is ignored.
/// - A report whose [NoticeRequest.dedupeKey] matches an active notice is
///   suppressed, so the same unresolved problem is not presented repeatedly.
///   Dismissal or [resolve] re-arms the key for a later, new occurrence.
class NoticeCenter implements Listenable {
  NoticeCenter({this.briefDuration = NoticePolicy.briefDuration});

  /// How long a [NoticeLifetime.brief] notice stays in the model.
  final Duration briefDuration;

  NoticeModel _model = const NoticeModel();
  final Set<VoidCallback> _listeners = {};
  final Map<int, Timer> _expiries = {};
  final Map<int, NoticeActionHandler> _handlers = {};
  final Map<int, String> _dedupeKeys = {};
  final Map<int, int> _revisions = {};
  int _nextId = 0;
  int _revision = 0;
  bool _closing = false;

  NoticeModel get model => _model;

  /// The adapter feature controllers receive at construction.
  NoticeReporter get reporter => report;

  /// Reports an outcome. The request is handled as a typed message.
  void report(NoticeRequest request) => dispatch(NoticeReported(request));

  /// Marks the unresolved condition [dedupeKey] as no longer true.
  ///
  /// An active notice for the key is retracted without user acknowledgment,
  /// and the next report for the key is presented again.
  void resolve(String dedupeKey) => dispatch(NoticeResolved(dedupeKey));

  void dispatch(NoticeMessage message) {
    if (_closing) return;
    switch (message) {
      case NoticeReported():
        _add(message.request);
      case NoticeExpired():
        _expire(message.id, message.revision);
      case NoticeDismissed():
        _remove(message.id);
      case NoticeActionInvoked():
        _invoke(message.id, message.actionId);
      case NoticeResolved():
        _resolve(message.dedupeKey);
    }
  }

  void _add(NoticeRequest request) {
    final dedupeKey = request.dedupeKey;
    if (dedupeKey != null && _dedupeKeys.containsValue(dedupeKey)) {
      // The same unresolved problem is already presented. A new occurrence
      // after dismissal or resolution reports again with a new id.
      return;
    }
    final id = ++_nextId;
    final revision = ++_revision;
    final notice = Notice(
      id: id,
      kind: request.kind,
      lifetime: request.lifetime,
      text: request.text,
      details: request.details,
      actions: List.unmodifiable(request.actions),
      dedupeKey: dedupeKey,
    );
    _revisions[id] = revision;
    if (dedupeKey != null) _dedupeKeys[id] = dedupeKey;
    if (request.onAction case final handler?) _handlers[id] = handler;
    // The timer is registered before listeners run: a listener may dismiss the
    // notice or dispose the center synchronously, and either must be able to
    // cancel the expiry it is looking at.
    if (request.lifetime == NoticeLifetime.brief) {
      _expiries[id] = Timer(
        briefDuration,
        () => dispatch(NoticeExpired(id, revision)),
      );
    }
    _emit(
      _model.copyWith(active: List.unmodifiable([..._model.active, notice])),
    );
  }

  void _expire(int id, int revision) {
    // A late completion for a superseded notice must not clear its successor.
    if (_revisions[id] != revision) return;
    _remove(id);
  }

  void _invoke(int id, String actionId) {
    final index = _model.active.indexWhere((notice) => notice.id == id);
    if (index < 0) return;
    final notice = _model.active[index];
    final action = notice.actions
        .where((action) => action.id == actionId)
        .firstOrNull;
    if (action == null) return;
    final handler = _handlers[id];
    _remove(id);
    if (actionId != NoticeAction.dismissId && handler != null) {
      handler(actionId);
    }
  }

  void _resolve(String dedupeKey) {
    final ids = _dedupeKeys.entries
        .where((entry) => entry.value == dedupeKey)
        .map((entry) => entry.key)
        .toList(growable: false);
    for (final id in ids) {
      _remove(id);
    }
  }

  void _remove(int id) {
    final index = _model.active.indexWhere((notice) => notice.id == id);
    if (index < 0) return;
    _expiries.remove(id)?.cancel();
    _handlers.remove(id);
    _dedupeKeys.remove(id);
    _revisions.remove(id);
    final active = [..._model.active]..removeAt(index);
    _emit(_model.copyWith(active: List.unmodifiable(active)));
  }

  void _emit(NoticeModel model) {
    _model = model;
    for (final listener in List<VoidCallback>.of(_listeners)) {
      listener();
    }
  }

  @override
  void addListener(VoidCallback listener) => _listeners.add(listener);

  @override
  void removeListener(VoidCallback listener) => _listeners.remove(listener);

  void dispose() {
    if (_closing) return;
    _closing = true;
    for (final expiry in _expiries.values) {
      expiry.cancel();
    }
    _expiries.clear();
    _handlers.clear();
    _dedupeKeys.clear();
    _revisions.clear();
    _listeners.clear();
  }
}
