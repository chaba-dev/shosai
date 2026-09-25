import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shosai_flutter/app_theme.dart';
import 'package:shosai_flutter/l10n/app_localizations.dart';
import 'package:shosai_flutter/main.dart';
import 'package:shosai_flutter/notices/notices.dart';

final class _Text implements NoticeText {
  const _Text(this.value);

  final String value;

  @override
  String resolve(AppLocalizations localizations) => value;
}

/// Resolves through the generated catalogs.
///
/// A locale change must change the rendered text, which is what keeps notice
/// copy in the standard ARB catalogs instead of a hand-written locale map.
final class _LibraryTitleText implements NoticeText {
  const _LibraryTitleText();

  @override
  String resolve(AppLocalizations localizations) => localizations.libraryTitle;
}

Widget _shell(NoticeCenter center, {Locale? locale}) => ShosaiShell(
  locale: locale,
  noticeCenter: center,
  home: const Scaffold(body: SizedBox.shrink()),
);

/// Counts its own lifetime so a test can prove the content subtree is not
/// recreated when notices appear and disappear.
final class _IdentityProbe extends StatefulWidget {
  const _IdentityProbe({required this.onInit, required this.onDispose});

  final VoidCallback onInit;
  final VoidCallback onDispose;

  @override
  State<_IdentityProbe> createState() => _IdentityProbeState();
}

class _IdentityProbeState extends State<_IdentityProbe> {
  @override
  void initState() {
    super.initState();
    widget.onInit();
  }

  @override
  void dispose() {
    widget.onDispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

NoticeRequest _persistentNotice(String text, String dedupeKey) => NoticeRequest(
  text: _Text(text),
  kind: NoticeKind.failure,
  lifetime: NoticeLifetime.persistent,
  dedupeKey: dedupeKey,
);

void main() {
  testWidgets('presents a brief success notice once and expires it', (
    tester,
  ) async {
    final center = NoticeCenter();
    addTearDown(center.dispose);
    await tester.pumpWidget(_shell(center));

    center.report(
      const NoticeRequest(text: _LibraryTitleText(), kind: NoticeKind.success),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Library'), findsOneWidget);

    // A rebuild must not present the same notice twice.
    await tester.pump();
    expect(find.text('Library'), findsOneWidget);

    await tester.pump(NoticePolicy.briefDuration);
    await tester.pumpAndSettle();

    expect(find.text('Library'), findsNothing);
  });

  testWidgets('resolves notice copy through the application locale', (
    tester,
  ) async {
    final center = NoticeCenter();
    addTearDown(center.dispose);
    await tester.pumpWidget(_shell(center, locale: const Locale('ja')));
    // The component layer loads its Japanese strings asynchronously; the host
    // only exists once the application tree has resolved that localization.
    await tester.pumpAndSettle();

    center.report(
      const NoticeRequest(text: _LibraryTitleText(), kind: NoticeKind.success),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('ライブラリ'), findsOneWidget);
    expect(find.text('Library'), findsNothing);
    await tester.pump(NoticePolicy.briefDuration);
    await tester.pumpAndSettle();
  });

  testWidgets('a persistent failure shows details and routes its action', (
    tester,
  ) async {
    final center = NoticeCenter();
    addTearDown(center.dispose);
    var retries = 0;
    await tester.pumpWidget(_shell(center));

    center.report(
      NoticeRequest(
        text: const _Text('Some books could not be imported.'),
        kind: NoticeKind.failure,
        lifetime: NoticeLifetime.persistent,
        dedupeKey: NoticePolicy.libraryImportKey,
        details: const _Text('2 of 5 failed: unsupported format.'),
        actions: const [
          NoticeAction(id: 'retry', label: _Text('Retry'), primary: true),
          NoticeAction(id: NoticeAction.dismissId, label: _Text('Dismiss')),
        ],
        onAction: (actionId) {
          if (actionId == 'retry') retries += 1;
        },
      ),
    );
    await tester.pump();

    expect(find.text('Some books could not be imported.'), findsOneWidget);
    expect(find.text('2 of 5 failed: unsupported format.'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Dismiss'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pump();

    expect(retries, 1);
    expect(find.text('Some books could not be imported.'), findsNothing);
  });

  testWidgets('a persistent notice does not expire while the user reads it', (
    tester,
  ) async {
    final center = NoticeCenter();
    addTearDown(center.dispose);
    await tester.pumpWidget(_shell(center));

    center.report(
      NoticeRequest(
        text: const _Text('The book could not be removed.'),
        kind: NoticeKind.failure,
        lifetime: NoticeLifetime.persistent,
        dedupeKey: NoticePolicy.libraryRemovalKey,
      ),
    );
    await tester.pump(NoticePolicy.briefDuration * 5);

    expect(find.text('The book could not be removed.'), findsOneWidget);
  });

  testWidgets('an unresolved problem is not presented twice', (tester) async {
    final center = NoticeCenter();
    addTearDown(center.dispose);
    await tester.pumpWidget(_shell(center));

    for (var attempt = 0; attempt < 2; attempt += 1) {
      center.report(
        NoticeRequest(
          text: const _Text('The import could not be completed.'),
          kind: NoticeKind.failure,
          lifetime: NoticeLifetime.persistent,
          dedupeKey: NoticePolicy.libraryImportKey,
        ),
      );
      await tester.pump();
    }

    expect(find.text('The import could not be completed.'), findsOneWidget);
  });

  testWidgets('a persistent notice without a declared dismiss can be closed', (
    tester,
  ) async {
    final center = NoticeCenter();
    addTearDown(center.dispose);
    await tester.pumpWidget(_shell(center));

    center.report(
      NoticeRequest(
        text: const _Text('The selected file could not be found.'),
        kind: NoticeKind.failure,
        lifetime: NoticeLifetime.persistent,
        dedupeKey: 'library.open',
      ),
    );
    await tester.pump();

    await tester.tap(find.byTooltip('Close'));
    await tester.pump();

    expect(find.text('The selected file could not be found.'), findsNothing);
  });

  testWidgets('persistent notices never recreate the content subtree', (
    tester,
  ) async {
    final center = NoticeCenter();
    addTearDown(center.dispose);
    var initializations = 0;
    var disposals = 0;
    await tester.pumpWidget(
      ShosaiShell(
        noticeCenter: center,
        home: _IdentityProbe(
          onInit: () => initializations += 1,
          onDispose: () => disposals += 1,
        ),
      ),
    );
    expect(initializations, 1);

    center.report(
      _persistentNotice('First failure.', NoticePolicy.libraryImportKey),
    );
    await tester.pump();
    center.report(
      _persistentNotice('Second failure.', NoticePolicy.libraryRemovalKey),
    );
    await tester.pump();
    expect(find.text('First failure.'), findsOneWidget);

    center.dispatch(NoticeDismissed(center.model.active.first.id));
    await tester.pump();
    center.resolve(NoticePolicy.libraryRemovalKey);
    await tester.pump();

    expect(find.text('First failure.'), findsNothing);
    expect(
      initializations,
      1,
      reason:
          'a notice must not recreate the content subtree and its controllers',
    );
    expect(disposals, 0);
  });

  testWidgets('replacing the center retires the previous center toasts', (
    tester,
  ) async {
    final first = NoticeCenter();
    final second = NoticeCenter();
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    await tester.pumpWidget(_shell(first));
    first.report(
      const NoticeRequest(
        text: _Text('First saved.'),
        kind: NoticeKind.success,
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('First saved.'), findsOneWidget);

    await tester.pumpWidget(_shell(second));
    await tester.pumpAndSettle();

    expect(find.text('First saved.'), findsNothing);

    second.report(
      const NoticeRequest(
        text: _Text('Second saved.'),
        kind: NoticeKind.success,
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Second saved.'), findsOneWidget);

    await tester.pump(NoticePolicy.briefDuration);
    await tester.pumpAndSettle();

    expect(find.text('Second saved.'), findsNothing);
  });

  testWidgets('a burst of brief notices never resurrects a retired toast', (
    tester,
  ) async {
    final center = NoticeCenter();
    addTearDown(center.dispose);
    await tester.pumpWidget(_shell(center));

    for (var index = 1; index <= 4; index += 1) {
      center.report(
        NoticeRequest(text: _Text('Saved $index.'), kind: NoticeKind.success),
      );
      await tester.pump();
      await tester.pump();
    }
    await tester.pumpAndSettle();

    expect(
      find.text('Saved 1.'),
      findsNothing,
      reason:
          'the oldest toast is replaced rather than moved to the overflow list',
    );
    expect(find.text('Saved 4.'), findsOneWidget);

    // Removing the remaining notices must not bring the replaced one back.
    for (final notice in [...center.model.active]) {
      center.dispatch(NoticeDismissed(notice.id));
    }
    await tester.pump();
    await tester.pumpAndSettle();

    for (var index = 1; index <= 4; index += 1) {
      expect(find.text('Saved $index.'), findsNothing);
    }
  });

  testWidgets('a debt notice renders as a persistent warning', (tester) async {
    final center = NoticeCenter();
    addTearDown(center.dispose);
    await tester.pumpWidget(_shell(center));

    center.report(
      NoticeRequest(
        text: const _Text(
          'Book removed. Its private copy will be deleted later.',
        ),
        kind: NoticeKind.warning,
        lifetime: NoticeLifetime.persistent,
        dedupeKey: 'library.deletion',
        actions: const [
          NoticeAction(id: NoticeAction.dismissId, label: _Text('Dismiss')),
        ],
      ),
    );
    await tester.pump();

    expect(
      find.text('Book removed. Its private copy will be deleted later.'),
      findsOneWidget,
    );
    expect(find.byIcon(LucideIcons.triangleAlert), findsOneWidget);

    await tester.pump(NoticePolicy.briefDuration * 3);

    expect(
      find.text('Book removed. Its private copy will be deleted later.'),
      findsOneWidget,
    );
  });

  testWidgets('a notice reported during an exit animation waits for the slot', (
    tester,
  ) async {
    final center = NoticeCenter();
    addTearDown(center.dispose);
    await tester.pumpWidget(_shell(center));

    for (var index = 1; index <= 3; index += 1) {
      center.report(
        NoticeRequest(text: _Text('Saved $index.'), kind: NoticeKind.success),
      );
      await tester.pump();
      await tester.pump();
    }
    await tester.pumpAndSettle();

    // Dismiss the oldest and report a successor while its exit animation is
    // still running: the successor must wait for the slot instead of pushing
    // the retiring toast into the Sonner's overflow list.
    center.dispatch(NoticeDismissed(center.model.active.first.id));
    center.report(
      const NoticeRequest(text: _Text('Saved 4.'), kind: NoticeKind.success),
    );
    await tester.pump();

    expect(find.text('Saved 4.'), findsNothing);

    await tester.pumpAndSettle();

    expect(find.text('Saved 1.'), findsNothing);
    expect(find.text('Saved 4.'), findsOneWidget);

    // Removing another toast must not bring the retired one back.
    center.dispatch(NoticeDismissed(center.model.active.first.id));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('Saved 1.'), findsNothing);

    for (final notice in [...center.model.active]) {
      center.dispatch(NoticeDismissed(notice.id));
    }
    await tester.pump();
    await tester.pumpAndSettle();

    for (var index = 1; index <= 4; index += 1) {
      expect(find.text('Saved $index.'), findsNothing);
    }
  });

  testWidgets(
    'replacing a full center with a pre-populated one does not overflow',
    (tester) async {
      final first = NoticeCenter();
      final second = NoticeCenter();
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      await tester.pumpWidget(_shell(first));

      for (var index = 1; index <= 3; index += 1) {
        first.report(
          NoticeRequest(text: _Text('First $index.'), kind: NoticeKind.success),
        );
        await tester.pump();
        await tester.pump();
      }
      await tester.pumpAndSettle();

      second.report(
        const NoticeRequest(
          text: _Text('Second saved.'),
          kind: NoticeKind.success,
        ),
      );
      await tester.pumpWidget(_shell(second));
      await tester.pumpAndSettle();

      for (var index = 1; index <= 3; index += 1) {
        expect(find.text('First $index.'), findsNothing);
      }
      expect(find.text('Second saved.'), findsOneWidget);

      second.dispatch(NoticeDismissed(second.model.active.single.id));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.text('Second saved.'), findsNothing);
      for (var index = 1; index <= 3; index += 1) {
        expect(find.text('First $index.'), findsNothing);
      }

      // The replaced center's notices are still active; dispose it so no expiry
      // timer outlives the test.
      first.dispose();
    },
  );

  testWidgets('renders persistent notices without a Sonner host', (
    tester,
  ) async {
    final center = NoticeCenter();
    addTearDown(center.dispose);
    await tester.pumpWidget(
      ShadTheme(
        data: shosaiShadTheme(Brightness.light),
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: NoticeHost(
            center: center,
            child: const Scaffold(body: SizedBox.shrink()),
          ),
        ),
      ),
    );

    center.report(
      NoticeRequest(
        text: const _Text('The import could not be completed.'),
        kind: NoticeKind.failure,
        lifetime: NoticeLifetime.persistent,
        dedupeKey: NoticePolicy.libraryImportKey,
      ),
    );
    await tester.pump();

    expect(find.text('The import could not be completed.'), findsOneWidget);
  });
}
