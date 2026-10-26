import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shosai_flutter/library/dropbox_dialog.dart';

import '../support/production_shell_harness.dart';

void main() {
  setUpAll(loadHarnessFonts);
  for (final (locale, size, connect, cancel) in [
    (const Locale('en'), const Size(900, 720), 'Connect Dropbox', 'Cancel'),
    (const Locale('ja'), const Size(390, 844), 'Dropbox を接続', 'キャンセル'),
  ]) {
    testWidgets(
      'Dropbox authorization entry and cancellation (${locale.languageCode})',
      (tester) async {
        HarnessView(size: size).apply(tester);
        String? result;
        var returned = false;
        await tester.pumpWidget(
          productionShell(
            locale: locale,
            home: Scaffold(
              body: Builder(
                builder: (context) => Center(
                  child: ShadButton(
                    onPressed: () async {
                      result = await showShadDialog<String>(
                        context: context,
                        builder: (_) => const DropboxCodeDialog(),
                      );
                      returned = true;
                    },
                    child: const Text('Open'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        final action = find.widgetWithText(ShadButton, connect);
        expect(tester.widget<ShadButton>(action).onPressed, null);
        expect(tester.widget<ShadButton>(action).enabled, false);
        await captureHarnessArtifact(
          tester,
          'dropbox-code-empty-${locale.languageCode}',
          metadata: {'width': size.width, 'height': size.height},
        );
        await tester.enterText(
          find.byType(EditableText),
          '  fixture-authorization-code  ',
        );
        await tester.pump();
        expect(
          tester.widget<EditableText>(find.byType(EditableText)).obscureText,
          true,
        );
        expect(tester.widget<ShadButton>(action).onPressed, isNotNull);
        expect(tester.widget<ShadButton>(action).enabled, true);
        await captureHarnessArtifact(
          tester,
          'dropbox-code-ready-${locale.languageCode}',
        );
        await tester.tap(action);
        await tester.pumpAndSettle();
        expect(result, 'fixture-authorization-code');
        expect(returned, true);
        returned = false;
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        await tester.tap(find.text(cancel));
        await tester.pumpAndSettle();
        expect(result, null);
        expect(returned, true);
        expect(tester.takeException(), null);
      },
    );
  }
}
