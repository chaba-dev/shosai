import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shosai_flutter/main.dart';
import 'package:shosai_flutter/src/rust/api.dart';
import 'package:shosai_flutter/src/rust/frb_generated.dart';

/// Native add-books picker smoke test.
///
/// Run by `scripts/flutter-native-picker-smoke.sh` on a real desktop with a
/// disposable profile. The test drives the production application — real shell,
/// real Rust bridge, disposable database — to the platform file picker. The
/// runner script opens and dismisses the native dialog and captures the
/// screenshots, because a native dialog is outside the Flutter view and cannot
/// be driven by the widget tester.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('add-books reaches the native picker and the shell recovers', (
    tester,
  ) async {
    final directory = Directory(
      Platform.environment['SHOSAI_SMOKE_DIR'] ??
          Directory.systemTemp.createTempSync('shosai-picker-smoke-').path,
    )..createSync(recursive: true);
    final marker = File('${directory.path}/picker-requested');
    final result = File('${directory.path}/smoke-result.json');
    // Publish this process so a runner can address the application by pid
    // instead of by name, which another instance could share.
    File('${directory.path}/app-pid').writeAsStringSync('$pid');

    await RustLib.init(externalLibrary: nativeLibrary());
    final bridge = FlutterBridge.withDatabasePath(
      databasePath: '${directory.path}/smoke.sqlite3',
    );
    addTearDown(bridge.dispose);

    await tester.pumpWidget(ShosaiApp(productBridgeFactory: () => bridge));
    // The add-books action is the floating button; the dialog title reuses the
    // same words, so match the button itself.
    final addBooks = find.widgetWithText(ShadButton, 'Add books');
    final loaded = await _pumpUntil(
      tester,
      () => addBooks.evaluate().isNotEmpty,
      timeout: const Duration(seconds: 60),
    );
    expect(loaded, isTrue, reason: 'the library never finished loading');
    expect(tester.takeException(), isNull);

    // The add-books action is disabled while the first load runs, so keep
    // asking until the dialog actually opens.
    var dialogShown = false;
    final dialogDeadline = DateTime.now().add(const Duration(seconds: 60));
    while (DateTime.now().isBefore(dialogDeadline)) {
      await tester.tap(addBooks, warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 200));
      if (find.text('Choose files').evaluate().isNotEmpty) {
        dialogShown = true;
        break;
      }
    }
    expect(dialogShown, isTrue, reason: 'the add-books dialog did not open');

    // Tell the runner to watch for the native dialog, then open the picker.
    // The plugin runs the dialog in a nested GTK loop, so the application does
    // not process further frames until the runner dismisses it.
    marker.writeAsStringSync(DateTime.now().toUtc().toIso8601String());
    await tester.tap(find.text('Choose files'));
    await tester.pump();

    // The picker returns empty after the runner dismisses it; the shell must
    // accept another add-books request afterwards.
    var recovered = false;
    final deadline = DateTime.now().add(const Duration(seconds: 90));
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 100));
      if (addBooks.evaluate().isEmpty) continue;
      await tester.tap(addBooks, warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 200));
      if (find.text('Choose files').evaluate().isNotEmpty) {
        recovered = true;
        break;
      }
    }
    final exception = tester.takeException();
    result.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        'libraryLoaded': loaded,
        'dialogShown': dialogShown,
        'pickerRequested': true,
        'recovered': recovered,
        'exception': exception?.toString(),
      }),
    );

    expect(
      recovered,
      isTrue,
      reason: 'the shell did not recover from the picker',
    );
    expect(exception, isNull);
  });
}

/// Pumps frames until [condition] holds or [timeout] elapses.
Future<bool> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  required Duration timeout,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return true;
    await tester.pump(const Duration(milliseconds: 100));
  }
  return condition();
}
