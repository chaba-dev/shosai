import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shosai_flutter/main.dart';

/// Demo only (not for merge): drives the selection capsule in the real app so
/// a device recording shows it. Imports the books in `SHOSAI_DEMO_BOOKS` (a
/// host directory, for the simulator) or downloads the `name=url` pairs in
/// `--dart-define=SHOSAI_DEMO_URLS=...`, into a throwaway library, so the
/// device's own library is never touched. Each state is held for a few
/// seconds and announced with a `DEMO_STEP <name>` line for screenshots.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'selection capsule demo',
    timeout: const Timeout(Duration(minutes: 10)),
    (tester) async {
      final books =
          Platform.environment['SHOSAI_DEMO_BOOKS'] ??
          const String.fromEnvironment('SHOSAI_DEMO_BOOKS').nonEmpty ??
          await _download();
      final data = Directory.systemTemp.createTempSync('shosai-demo-');
      final owner = await applicationCoreOwner(
        applicationSupportDirectory: () async => data,
      );
      final bridge = owner.bridge();
      final paths = [
        for (final f in Directory(books).listSync())
          if (f.path.endsWith('.epub') || f.path.endsWith('.pdf')) f.path,
      ]..sort();
      await bridge.importPaths(
        pathKeys: paths,
        managed: false,
        cancellationId: bridge.createCancellation(),
      );
      const locale = String.fromEnvironment(
        'SHOSAI_DEMO_LOCALE',
        defaultValue: 'en',
      );
      await tester.pumpWidget(
        ShosaiApp(productBridgeFactory: owner.bridge, locale: Locale(locale)),
      );
      await _hold(tester, 'library', 3);

      for (final title in const [
        'A Field Guide to Quiet Places',
        'Adventures in Wonderland',
      ]) {
        if (find.textContaining(title, findRichText: true).evaluate().isEmpty) {
          continue;
        }
        await _open(tester, title);
        await _hold(tester, 'open-${_slug(title)}', 2);
        if (title.startsWith('Adventures')) {
          // Past the cover and front matter to running text.
          for (var i = 0; i < 3; i += 1) {
            await _tapAt(tester, _page(tester), .9, .5);
            await _hold(tester, 'turn', 1);
          }
        }
        // Select a line, wait on the capsule, pick green. Front matter can
        // run longer on a phone: turn on until a line of prose selects.
        for (var tries = 0; ; tries += 1) {
          try {
            await _select(tester, .14, .30, .80, .30);
            break;
          } on StateError {
            if (tries >= 8) rethrow;
            await _tapAt(tester, _page(tester), .9, .5);
            await _hold(tester, 'turn', 1);
          }
        }
        await _hold(tester, 'capsule-${_slug(title)}', 4);
        await _tapKey(tester, 'selection-swatch-green');
        await _hold(tester, 'green-${_slug(title)}', 3);
        // A second line, then Note: the note editor opens over a yellow highlight.
        await _select(tester, .14, .42, .70, .42);
        await _hold(tester, 'capsule2-${_slug(title)}', 3);
        await _tapKey(tester, 'selection-note');
        await _hold(tester, 'note-${_slug(title)}', 4);
        final cancel = find.text(locale == 'ja' ? 'キャンセル' : 'Cancel');
        if (cancel.evaluate().isNotEmpty) {
          await tester.tap(cancel.last, warnIfMissed: false);
        }
        await _hold(tester, 'note-closed', 2);
        // A press outside dismisses the capsule (there is no Cancel).
        await _tapAt(tester, _page(tester), .5, .9);
        await _hold(tester, 'dismissed-${_slug(title)}', 2);
        await _back(tester);
      }
    },
  );
}

extension on String {
  String? get nonEmpty => this.isEmpty ? null : this;
}

String _slug(String title) => title.split(' ').first.toLowerCase();

Rect _page(WidgetTester tester) => tester.getRect(
  find.byKey(const ValueKey('reader-selection-surface')).first,
);

Future<void> _hold(WidgetTester tester, String step, int seconds) async {
  // ignore: avoid_print
  print('DEMO_STEP $step');
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _open(WidgetTester tester, String title) async {
  final finder = find.textContaining(title, findRichText: true);
  if (finder.evaluate().isEmpty) throw StateError('no "$title"');
  await tester.tap(finder.last, warnIfMissed: false);
  await _hold(tester, 'opening', 4);
  final hint = find.byKey(const ValueKey('reader-zones-hint'));
  if (hint.evaluate().isNotEmpty) {
    await tester.tap(hint, warnIfMissed: false);
    await _hold(tester, 'hint-dismissed', 1);
  }
}

Future<void> _back(WidgetTester tester) async {
  for (final key in const [
    'reader-back-to-library',
    'reader-header-back',
    'shell-rail-library',
  ]) {
    final f = find.byKey(ValueKey(key));
    if (f.evaluate().isNotEmpty) {
      await tester.tap(f.first, warnIfMissed: false);
      await _hold(tester, 'back', 2);
      return;
    }
  }
  final back = find.byTooltip('Back');
  if (back.evaluate().isNotEmpty) {
    await tester.tap(back.first, warnIfMissed: false);
    await _hold(tester, 'back', 2);
  }
}

Future<void> _tapKey(WidgetTester tester, String key) async {
  final f = find.byKey(ValueKey(key));
  if (f.evaluate().isEmpty) throw StateError('no $key');
  await tester.tap(f.first, warnIfMissed: false);
  await tester.pump();
}

Future<void> _tapAt(WidgetTester tester, Rect page, double x, double y) async {
  await tester.tapAt(
    Offset(page.left + page.width * x, page.top + page.height * y),
  );
  await tester.pump();
}

/// A touch (or mouse) selection along a line at [y], trying nearby lines
/// until one lands on text and the capsule opens.
Future<void> _select(
  WidgetTester tester,
  double x0,
  double y,
  double x1,
  double _,
) async {
  final mobile = Platform.isIOS || Platform.isAndroid;
  final capsule = find.byKey(const ValueKey('selection-actions'));
  for (final dy in const [0.0, .03, -.03, .06, -.06, .09, -.09, .12, -.12]) {
    final page = _page(tester);
    // A wide surface is a spread (a PDF cover sits alone in its middle):
    // stay inside the left half of the middle, where text is either way.
    final (from, to) = page.width < 600 ? (x0, x1) : (.34, .46);
    Offset at(double x) =>
        Offset(page.left + page.width * x, page.top + page.height * (y + dy));
    final gesture = await tester.startGesture(
      at(from),
      kind: mobile ? ui.PointerDeviceKind.touch : ui.PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 700));
    for (var i = 1; i <= 12; i += 1) {
      await gesture.moveTo(at(from + (to - from) * i / 12));
      await tester.pump(const Duration(milliseconds: 40));
    }
    await gesture.up();
    for (var i = 0; i < 10; i += 1) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    if (capsule.evaluate().isNotEmpty) return;
  }
  throw StateError('no selection opened the capsule');
}

Future<String> _download() async {
  const urls = String.fromEnvironment('SHOSAI_DEMO_URLS');
  final dir = Directory.systemTemp.createTempSync('shosai-demo-books-');
  final client = HttpClient();
  try {
    for (final pair in urls.split(',').where((p) => p.contains('='))) {
      final split = pair.indexOf('=');
      final request = await client.getUrl(Uri.parse(pair.substring(split + 1)));
      final response = await request.close();
      await response.pipe(
        File('${dir.path}/${pair.substring(0, split)}').openWrite(),
      );
    }
  } finally {
    client.close();
  }
  return dir.path;
}
