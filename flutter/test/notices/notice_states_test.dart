import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shosai_flutter/library/view.dart';
import 'package:shosai_flutter/main.dart';
import 'package:shosai_flutter/notices/library_notice_text.dart';
import 'package:shosai_flutter/notices/notices.dart';

import '../support/production_shell_harness.dart';

/// Package 2D rendered notice states (`2D-RENDER`).
///
/// Each state renders the production shell and library with the deterministic
/// harness bridge, drives the notice center, runs the geometry detectors and
/// captures an artifact for inspection next to its metadata. The package ships
/// no new golden baseline: the notice surfaces are transient or
/// condition-driven, so these renders are evidence for review rather than a
/// pixel gate.
///
/// The success and persistent states are **synthetic** render evidence: the
/// controller → reporter → center connection is covered by
/// `library_notice_integration_test.dart`, and these renders drive the center
/// directly to prove the center → host → painted-surface composition,
/// localization and wrapping. Production library failures and debt stay on the
/// library's inline surfaces.
///
/// The configurations are the approved reference ones: `C390` = 390x844,
/// `W900` = 900x700, `EN`/`JA` application locales and 200% text.
void main() {
  setUpAll(loadHarnessFonts);

  Future<void> captureState(
    WidgetTester tester,
    String name,
    HarnessView view,
    Map<String, Object?> metadata,
  ) async {
    final defects = await findRenderDefects(tester);
    await captureHarnessArtifact(
      tester,
      name,
      metadata: <String, Object?>{
        ...view.toMetadata(),
        ...metadata,
        'defects': defects.map((defect) => defect.toMetadata()).toList(),
      },
    );
    expectOnlyKnownDefects(defects, const <KnownRenderDefect>[]);
    expect(tester.takeException(), isNull);
  }

  Future<void> renderLibrary(
    WidgetTester tester,
    NoticeCenter center,
    HarnessView view, {
    Locale? locale,
  }) async {
    final bridge = HarnessBridge(
      books: harnessLibraryBooks(),
      covers: harnessCovers(),
    );
    view.apply(tester);
    await renderHarnessState(
      tester,
      RepaintBoundary(
        key: harnessBoundaryKey,
        child: ShosaiShell(
          locale: locale,
          noticeCenter: center,
          home: ProductShell(
            bridgeFactory: () => bridge,
            noticeReporter: center.reporter,
            readerBuilder: (_, _, _, _, _, _) => const SizedBox(),
          ),
        ),
      ),
      ready: () => harnessImagesReady(tester),
    );
  }

  testWidgets('compact English import success toast', (tester) async {
    final center = NoticeCenter();
    addTearDown(center.dispose);
    const view = HarnessView(size: Size(390, 844));
    await renderLibrary(tester, center, view);

    center.report(
      const NoticeRequest(
        text: LibraryImportSucceededNotice(count: 3),
        kind: NoticeKind.success,
      ),
    );
    await pumpHarnessFrames(tester, frames: 30);

    expect(find.text('Imported 3 books.'), findsOneWidget);
    expect(find.byType(ShadToast), findsOneWidget);
    expect(find.byType(PersistentNoticeSurface), findsNothing);
    await captureState(tester, 'notice-success-compact-en.png', view, {
      'state': 'synthetic brief import success toast',
      'locale': 'en',
    });

    await tester.pump(NoticePolicy.briefDuration);
    await tester.pumpAndSettle();

    expect(find.text('Imported 3 books.'), findsNothing);
    expect(find.byType(ShadToast), findsNothing);
  });

  testWidgets('compact Japanese persistent failure', (tester) async {
    final center = NoticeCenter();
    addTearDown(center.dispose);
    const view = HarnessView(size: Size(390, 844));
    await renderLibrary(tester, center, view, locale: const Locale('ja'));

    center.report(
      NoticeRequest(
        text: const LibraryImportFailedNotice(),
        kind: NoticeKind.failure,
        lifetime: NoticeLifetime.persistent,
        dedupeKey: NoticePolicy.libraryImportKey,
        details: const RawNoticeText('2 冊が失敗しました: 未対応の形式です。'),
        actions: const [
          NoticeAction(id: 'retry', label: NoticeRetryText(), primary: true),
          NoticeAction(id: NoticeAction.dismissId, label: NoticeDismissText()),
        ],
      ),
    );
    await pumpHarnessFrames(tester, frames: 8);

    expect(find.text('取り込みを完了できませんでした。'), findsOneWidget);
    expect(find.text('再試行'), findsOneWidget);
    expect(find.text('閉じる'), findsOneWidget);
    expect(find.byType(PersistentNoticeSurface), findsOneWidget);
    expect(find.byType(ShadToast), findsNothing);
    await captureState(tester, 'notice-persistent-compact-ja.png', view, {
      'state': 'synthetic persistent import failure',
      'locale': 'ja',
    });
  });

  testWidgets('wide Japanese persistent failure at 200% text', (tester) async {
    final center = NoticeCenter();
    addTearDown(center.dispose);
    const view = HarnessView(size: Size(900, 700), textScale: 2);
    await renderLibrary(tester, center, view, locale: const Locale('ja'));

    center.report(
      NoticeRequest(
        text: const LibraryImportPartialNotice(),
        kind: NoticeKind.failure,
        lifetime: NoticeLifetime.persistent,
        dedupeKey: NoticePolicy.libraryImportKey,
        details: const RawNoticeText(
          '2 冊が失敗しました: 未対応の形式です。残りの本はライブラリに追加されています。',
        ),
        actions: const [
          NoticeAction(id: 'retry', label: NoticeRetryText(), primary: true),
          NoticeAction(id: NoticeAction.dismissId, label: NoticeDismissText()),
        ],
      ),
    );
    await pumpHarnessFrames(tester, frames: 8);

    expect(find.text('一部の本を取り込めませんでした。'), findsOneWidget);
    expect(find.byType(PersistentNoticeSurface), findsOneWidget);
    expect(find.byType(ShadToast), findsNothing);
    await captureState(tester, 'notice-persistent-wide-ja-t200.png', view, {
      'state': 'synthetic persistent partial import',
      'locale': 'ja',
    });
  });
}
