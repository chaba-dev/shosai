import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_flutter/l10n/app_localizations.dart';
import 'package:shosai_flutter/notices/notices.dart';

final class _Text implements NoticeText {
  const _Text(this.value);

  final String value;

  @override
  String resolve(AppLocalizations localizations) => value;
}

NoticeRequest _brief({
  String text = 'Saved.',
  NoticeKind kind = NoticeKind.success,
  String? dedupeKey,
}) => NoticeRequest(text: _Text(text), kind: kind, dedupeKey: dedupeKey);

NoticeRequest _persistent({
  String text = 'The operation failed.',
  String? dedupeKey,
  List<NoticeAction> actions = const [],
  NoticeActionHandler? onAction,
}) => NoticeRequest(
  text: _Text(text),
  kind: NoticeKind.failure,
  lifetime: NoticeLifetime.persistent,
  dedupeKey: dedupeKey,
  actions: actions,
  onAction: onAction,
);

void main() {
  testWidgets('a brief notice is presented once and expires on its own timer', (
    tester,
  ) async {
    final center = NoticeCenter();
    addTearDown(center.dispose);
    final activeCounts = <int>[];
    center.addListener(() => activeCounts.add(center.model.active.length));

    center.report(_brief());

    expect(center.model.active, hasLength(1));
    expect(center.model.active.single.lifetime, NoticeLifetime.brief);
    await tester.pump(
      NoticePolicy.briefDuration - const Duration(milliseconds: 1),
    );
    expect(
      center.model.active,
      hasLength(1),
      reason: 'the notice must survive until its duration elapses',
    );
    await tester.pump(const Duration(milliseconds: 1));

    expect(center.model.active, isEmpty);
    expect(activeCounts, [
      1,
      0,
    ], reason: 'one report and one expiry, not a duplicate emit');
  });

  testWidgets('a persistent notice does not expire', (tester) async {
    final center = NoticeCenter();
    addTearDown(center.dispose);

    center.report(_persistent(dedupeKey: NoticePolicy.libraryImportKey));
    await tester.pump(NoticePolicy.briefDuration * 10);

    expect(center.model.active, hasLength(1));
  });

  testWidgets('reports without a dedupe key are never suppressed', (
    tester,
  ) async {
    final center = NoticeCenter();
    addTearDown(center.dispose);

    center.report(_brief(text: 'First.'));
    center.report(_brief(text: 'Second.'));

    expect(center.model.active, hasLength(2));
    await tester.pump(NoticePolicy.briefDuration);
  });

  testWidgets(
    'an unresolved condition suppresses duplicates until the user acknowledges it',
    (tester) async {
      final center = NoticeCenter();
      addTearDown(center.dispose);

      center.report(
        _persistent(
          text: 'First failure.',
          dedupeKey: NoticePolicy.libraryImportKey,
        ),
      );
      final firstId = center.model.active.single.id;
      center.report(
        _persistent(
          text: 'Second failure.',
          dedupeKey: NoticePolicy.libraryImportKey,
        ),
      );

      expect(center.model.active, hasLength(1));
      expect(
        (center.model.active.single.text as _Text).value,
        'First failure.',
        reason: 'the presented notice describes the unresolved condition',
      );

      center.dispatch(NoticeDismissed(firstId));
      expect(center.model.active, isEmpty);

      // A new operation reporting the same condition is a new occurrence and
      // presents again with a new identity.
      center.report(
        _persistent(
          text: 'Third failure.',
          dedupeKey: NoticePolicy.libraryImportKey,
        ),
      );
      expect(center.model.active, hasLength(1));
      expect(center.model.active.single.id, greaterThan(firstId));
    },
  );

  testWidgets('resolving a condition retracts its notice and re-arms the key', (
    tester,
  ) async {
    final center = NoticeCenter();
    addTearDown(center.dispose);

    center.report(_persistent(dedupeKey: NoticePolicy.libraryRemovalKey));
    expect(center.model.active, hasLength(1));

    center.resolve(NoticePolicy.libraryRemovalKey);
    expect(center.model.active, isEmpty);

    center.report(_persistent(dedupeKey: NoticePolicy.libraryRemovalKey));
    expect(center.model.active, hasLength(1));
  });

  testWidgets('a notice action runs its owner handler once and clears it', (
    tester,
  ) async {
    final center = NoticeCenter();
    addTearDown(center.dispose);
    var retries = 0;
    center.report(
      _persistent(
        actions: const [
          NoticeAction(id: 'retry', label: _Text('Retry'), primary: true),
          NoticeAction(id: NoticeAction.dismissId, label: _Text('Dismiss')),
        ],
        onAction: (actionId) {
          if (actionId == 'retry') retries += 1;
        },
      ),
    );
    final id = center.model.active.single.id;

    center.dispatch(NoticeActionInvoked(id, 'retry'));

    expect(retries, 1);
    expect(center.model.active, isEmpty);

    center.dispatch(NoticeActionInvoked(id, 'retry'));

    expect(retries, 1, reason: 'a completion for a cleared notice is inert');
    expect(center.model.active, isEmpty);
  });

  testWidgets(
    'the dismiss action clears a notice without running the handler',
    (tester) async {
      final center = NoticeCenter();
      addTearDown(center.dispose);
      var handled = 0;
      center.report(
        _persistent(
          actions: const [
            NoticeAction(id: NoticeAction.dismissId, label: _Text('Dismiss')),
          ],
          onAction: (_) => handled += 1,
        ),
      );

      center.dispatch(
        NoticeActionInvoked(
          center.model.active.single.id,
          NoticeAction.dismissId,
        ),
      );

      expect(handled, 0);
      expect(center.model.active, isEmpty);
    },
  );

  testWidgets('an action the notice does not declare is ignored', (
    tester,
  ) async {
    final center = NoticeCenter();
    addTearDown(center.dispose);
    var handled = 0;
    center.report(
      _persistent(
        actions: const [NoticeAction(id: 'retry', label: _Text('Retry'))],
        onAction: (_) => handled += 1,
      ),
    );
    final id = center.model.active.single.id;

    center.dispatch(NoticeActionInvoked(id, 'unknown'));

    expect(handled, 0);
    expect(center.model.active, hasLength(1));
  });

  testWidgets(
    'a late completion cannot clear a successor reported for the same key',
    (tester) async {
      final center = NoticeCenter();
      addTearDown(center.dispose);

      center.report(_brief(text: 'First.', dedupeKey: 'library.open'));
      final firstId = center.model.active.single.id;
      center.dispatch(NoticeDismissed(firstId));
      center.report(_brief(text: 'Second.', dedupeKey: 'library.open'));
      final secondId = center.model.active.single.id;
      expect(secondId, isNot(firstId));

      // The retired notice's timer completes after its successor exists, with
      // the revision that authorized it.
      center.dispatch(NoticeExpired(firstId, 1));
      expect(center.model.active.single.id, secondId);

      // A stale revision for the active notice must not expire it either.
      center.dispatch(NoticeExpired(secondId, 0));
      expect(center.model.active, hasLength(1));

      await tester.pump(NoticePolicy.briefDuration);
      expect(center.model.active, isEmpty);
    },
  );

  testWidgets('disposal cancels expiry timers and makes later work inert', (
    tester,
  ) async {
    final center = NoticeCenter();
    center.report(_brief());
    final id = center.model.active.single.id;
    var changes = 0;
    center.addListener(() => changes += 1);

    center.dispose();
    center.dispatch(NoticeExpired(id, 1));
    center.report(_brief(text: 'After disposal.'));
    await tester.pump(NoticePolicy.briefDuration * 2);

    expect(changes, 0);
    expect(center.model.active, hasLength(1));
  });

  testWidgets('disposing from the first listener leaves no pending timer', (
    tester,
  ) async {
    final center = NoticeCenter();
    addTearDown(center.dispose);
    center.addListener(center.dispose);

    center.report(_brief());

    // The test ends without advancing time: a timer installed after the
    // listeners ran would still be pending and fail the binding invariant.
  });

  testWidgets('dismissing from a listener cancels the expiry it authorized', (
    tester,
  ) async {
    final center = NoticeCenter();
    addTearDown(center.dispose);
    center.addListener(() {
      for (final notice in center.model.active) {
        center.dispatch(NoticeDismissed(notice.id));
      }
    });

    center.report(_brief());

    expect(center.model.active, isEmpty);
    await tester.pump(NoticePolicy.briefDuration * 2);
    expect(center.model.active, isEmpty);
  });
}
