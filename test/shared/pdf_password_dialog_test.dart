import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shosai_flutter/core/bridge.dart';
import 'package:shosai_flutter/core/document_access.dart';
import 'package:shosai_flutter/l10n/app_localizations.dart';
import 'package:shosai_flutter/library/view.dart';
import 'package:shosai_flutter/reader/view.dart' show ReaderScreen;
import 'package:shosai_flutter/shared/pdf_password_dialog.dart';
import 'package:shosai_flutter/shared/protected_book_dialog.dart';

import '../support/production_shell_harness.dart';

void main() {
  setUpAll(loadHarnessFonts);

  for (final scenario in [
    (
      size: const Size(1280, 900),
      brightness: Brightness.light,
      platform: TargetPlatform.linux,
    ),
    (
      size: const Size(768, 1024),
      brightness: Brightness.light,
      platform: TargetPlatform.linux,
    ),
    (
      size: const Size(390, 844),
      brightness: Brightness.light,
      platform: TargetPlatform.linux,
    ),
    (
      size: const Size(1280, 900),
      brightness: Brightness.dark,
      platform: TargetPlatform.linux,
    ),
    (
      size: const Size(390, 844),
      brightness: Brightness.dark,
      platform: TargetPlatform.linux,
    ),
    (
      size: const Size(1366, 1024),
      brightness: Brightness.light,
      platform: TargetPlatform.iOS,
    ),
  ]) {
    testWidgets(
      'locked shelf unlock dialog at $scenario',
      (tester) async {
        final size = scenario.size;
        final suffix = scenario.brightness == Brightness.dark ? '-dark' : '';
        tester.platformDispatcher.platformBrightnessTestValue =
            scenario.brightness;
        addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
        tester.view.physicalSize = size * 2;
        tester.view.devicePixelRatio = 2;
        addTearDown(tester.view.reset);
        final semantics = tester.ensureSemantics();
        String? result;
        final book = FlutterLibraryBook(
          bookId: 7,
          title: 'The locked atlas',
          author: 'Fixture author',
          format: FlutterBookFormat.pdf,
          pathKey: '/synthetic/locked.pdf',
          managed: true,
          progress: 0,
          dateAdded: '2026-11-18',
          protection: FlutterBookProtection.password,
        );
        await tester.pumpWidget(
          productionShell(
            home: Scaffold(
              body: Builder(
                builder: (context) => LibraryCollection(
                  model: LibraryModel(books: [book], loaded: true),
                  openBook: (_) async {
                    result = await Navigator.of(context).push<String>(
                      ShadDialogRoute(
                        pageBuilder: (_) => const PdfPasswordDialog(
                          request: PdfPasswordRequest('The locked atlas'),
                        ),
                      ),
                    );
                  },
                  openNotes: () {},
                  removeBook: (_) {},
                  loadMore: () {},
                  retryPaging: () {},
                  loadCover: (_) => false,
                  retry: () {},
                  addFirstBooks: () {},
                  cancelImport: () {},
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Locked'), findsOneWidget);
        await captureHarnessArtifact(
          tester,
          'protected-shelf-${size.width.toInt()}$suffix',
        );
        await tester.tap(find.text('The locked atlas').last);
        await tester.pumpAndSettle();
        expect(find.text('Unlock PDF'), findsOneWidget);
        expect(
          tester.getSemantics(find.byType(EditableText)).label,
          'Password',
        );
        expect(
          tester
              .getSemantics(
                find.descendant(
                  of: find.byTooltip('Show password'),
                  matching: find.byType(ShadIconButton),
                ),
              )
              .tooltip,
          'Show password',
        );
        final field = tester.getRect(find.byType(ShadInput));
        final toggle = tester.getRect(find.byTooltip('Show password'));
        expect(field.intersect(toggle), toggle);
        final target =
            size.width >= 1200 && scenario.platform == TargetPlatform.linux
            ? 32.0
            : 44.0;
        expect(field.height, target);
        expect(toggle.size, Size.square(target));
        expect(tester.getSize(find.byTooltip('Close')), Size.square(target));
        final openButton = tester.getRect(
          find.ancestor(
            of: find.text('Open PDF'),
            matching: find.byType(ShadButton),
          ),
        );
        final cancelButton = tester.getRect(
          find.ancestor(
            of: find.text('Cancel'),
            matching: find.byType(ShadButton),
          ),
        );
        expect(openButton.height, target);
        expect(cancelButton.height, target);
        expect(cancelButton.left, field.left);
        if (size.width < 512) {
          expect(cancelButton.top, greaterThan(openButton.bottom));
          expect(cancelButton.right, field.right);
        } else {
          expect(cancelButton.center.dy, openButton.center.dy);
        }
        expect(field.right, openButton.right);
        expect(
          tester.getRect(find.byType(EditableText)).right,
          lessThanOrEqualTo(toggle.left),
        );
        expect(
          tester.widget<EditableText>(find.byType(EditableText)).obscureText,
          isTrue,
        );
        await captureHarnessArtifact(
          tester,
          'protected-unlock-${size.width.toInt()}$suffix',
        );
        await tester.enterText(find.byType(EditableText), 'synthetic-secret');
        await tester.tap(find.byTooltip('Show password'));
        await tester.pump();
        expect(
          tester.widget<EditableText>(find.byType(EditableText)).obscureText,
          isFalse,
        );
        await tester.tap(find.byTooltip('Hide password'));
        await tester.pump();
        expect(
          tester.widget<EditableText>(find.byType(EditableText)).obscureText,
          isTrue,
        );
        await tester.tap(find.text('Open PDF'));
        await tester.pumpAndSettle();
        expect(result, 'synthetic-secret');
        await tester.tap(find.text('The locked atlas').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(result, isNull);
        expect(find.text('Locked'), findsOneWidget);
        expect(tester.takeException(), isNull);
        semantics.dispose();
      },
      variant: TargetPlatformVariant.only(scenario.platform),
    );
  }

  for (final scenario in [
    (size: const Size(1280, 900), brightness: Brightness.light),
    (size: const Size(390, 844), brightness: Brightness.dark),
  ]) {
    testWidgets(
      'DRM click explains the lock without opening a reader $scenario',
      (tester) async {
        tester.platformDispatcher.platformBrightnessTestValue =
            scenario.brightness;
        addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
        tester.view.physicalSize = scenario.size * 2;
        tester.view.devicePixelRatio = 2;
        addTearDown(tester.view.reset);
        final bridge = HarnessBridge(
          books: const [
            FlutterLibraryBook(
              bookId: 8,
              title: 'Protected chapters',
              author: 'Fixture author',
              format: FlutterBookFormat.epub,
              pathKey: '/synthetic/drm.epub',
              managed: true,
              progress: 0,
              dateAdded: '2026-11-18',
              protection: FlutterBookProtection.drm,
            ),
          ],
        );
        await tester.pumpWidget(productionApp(bridgeFactory: () => bridge));
        await tester.pumpAndSettle();
        expect(find.text('Locked'), findsOneWidget);
        await tester.tap(find.text('Protected chapters').last);
        // The shelf keeps its busy indicator while the modal owns the effect.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          find.text(
            'This book is DRM-protected or encrypted. Shōsai can’t open it.',
          ),
          findsOneWidget,
        );
        await captureHarnessArtifact(
          tester,
          scenario.brightness == Brightness.light
              ? 'protected-drm-explanation'
              : 'protected-drm-explanation-phone-dark',
        );
        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();
        expect(find.byType(ReaderScreen), findsNothing);
        expect(find.text('Locked'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.linux),
    );
  }

  for (final password in [true, false]) {
    testWidgets('Japanese 200% dialog title avoids close control: $password', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(780, 1688);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        productionShell(
          locale: const Locale('ja'),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  ShadDialogRoute<void>(
                    pageBuilder: (context) => MediaQuery(
                      data: MediaQuery.of(
                        context,
                      ).copyWith(textScaler: const TextScaler.linear(2)),
                      child: Builder(
                        builder: (context) {
                          final l10n = AppLocalizations.of(context);
                          return password
                              ? const PdfPasswordDialog(
                                  request: PdfPasswordRequest('合成テストの本'),
                                )
                              : ProtectedBookDialog(
                                  title: Text(l10n.bookLockedTitle),
                                  description: Text(l10n.bookDrmProtected),
                                  actions: [
                                    ShadButton.outline(
                                      onPressed: () => Navigator.pop(context),
                                      child: Text(l10n.locationClose),
                                    ),
                                  ],
                                );
                        },
                      ),
                    ),
                  ),
                ),
                child: const Text('Open fixture'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open fixture'));
      await tester.pumpAndSettle();
      final title = tester.getRect(
        find.text(password ? 'PDF のロックを解除' : 'この本はロックされています'),
      );
      final close = tester.getRect(find.byTooltip('閉じる'));
      await captureHarnessArtifact(
        tester,
        password ? 'protected-unlock-ja-200pct' : 'protected-drm-ja-200pct',
      );
      expect(title.right, lessThanOrEqualTo(close.left - 8));
      expect(find.byTooltip('閉じる').hitTestable(), findsOneWidget);
      await tester.tap(find.byTooltip('閉じる'));
      await tester.pumpAndSettle();
      expect(find.text('Open fixture'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('unlock errors remain usable with keyboard and large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2;
    tester.view.viewInsets = const FakeViewPadding(bottom: 520);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      productionShell(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                ShadDialogRoute<void>(
                  pageBuilder: (context) => MediaQuery(
                    data: MediaQuery.of(
                      context,
                    ).copyWith(textScaler: const TextScaler.linear(1.5)),
                    child: const PdfPasswordDialog(
                      request: PdfPasswordRequest(
                        'A long password-protected synthetic PDF title',
                        error: 'That password didn’t work. Try again.',
                      ),
                    ),
                  ),
                ),
              ),
              child: const Text('Unlock'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.text('That password didn’t work. Try again.'),
    );
    await tester.pumpAndSettle();
    await captureHarnessArtifact(tester, 'protected-unlock-keyboard-error');
    expect(
      find.text('That password didn’t work. Try again.').hitTestable(),
      findsOneWidget,
    );
    expect(find.text('Cancel').hitTestable(), findsOneWidget);
    expect(find.text('Open PDF').hitTestable(), findsOneWidget);
    expect(
      tester.getCenter(find.text('Cancel')).dy,
      greaterThan(tester.getCenter(find.text('Open PDF')).dy),
    );
    expect(tester.takeException(), isNull);
  });
}
