import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shosai_flutter/main.dart';

/// Demo only (not for merge): on touch, a tap on the page dismisses a
/// finished selection without turning the page. Imports the books in
/// `SHOSAI_DEMO_BOOKS` (a host directory, for the simulator) or downloads the
/// `name=url` pairs in `SHOSAI_DEMO_URLS` into a throwaway library, so the
/// device's own library is never touched. Each state is held for a few
/// seconds and announced with a `DEMO_STEP <name>` line for screenshots, and
/// each tap reports `DEMO_CHECK` lines with the capsule and page state.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'tap dismiss demo',
    timeout: const Timeout(Duration(minutes: 10)),
    (tester) async {
      final books =
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
      // ignore: avoid_print
      print('DEMO_BOOKS $paths');
      await bridge.importPaths(
        pathKeys: paths,
        managed: false,
        cancellationId: bridge.createCancellation(),
      );
      await tester.pumpWidget(
        ShosaiApp(productBridgeFactory: owner.bridge, locale: const Locale('en')),
      );
      await _hold(tester, 'library', 3);

      var failures = 0;
      for (final (title, slug) in const [
        ('A Field Guide to Quiet Places', 'pdf'),
        ('Adventures in Wonderland', 'alice'),
      ]) {
        if (find.textContaining(title, findRichText: true).evaluate().isEmpty) {
          // ignore: avoid_print
          print('DEMO_SKIP $slug not in library');
          continue;
        }
        await _open(tester, title);
        if (slug == 'alice') {
          // Past the cover and front matter to running text.
          for (var i = 0; i < 3; i += 1) {
            await _tapAt(tester, .9, .5);
            await _hold(tester, 'turn', 1);
          }
        }

        // 1. Select, Note, Cancel, then a tap on the page.
        await _selectTurningOn(tester, .30);
        await _hold(tester, 'selected1-$slug', 2);
        await _tapKey(tester, 'selection-note');
        await _hold(tester, 'note-$slug', 2);
        final cancel = find.text('Cancel');
        if (cancel.evaluate().isNotEmpty) {
          await tester.tap(cancel.last, warnIfMissed: false);
        }
        await _hold(tester, 'before-tap1-$slug', 4);
        final page1 = _pageLabel();
        // ignore: avoid_print
        print('DEMO_CHECK $slug tap1 before capsule=${_capsuleUp()} page=$page1');
        await _tapAt(tester, .5, .62);
        await _hold(tester, 'after-tap1-$slug', 4);
        failures += _check(slug, 'tap1', page1);
        await _dismissChrome(tester);

        // 2. A second selection, then a tap on the selected text itself.
        final on = await _selectTurningOn(tester, .42);
        await _hold(tester, 'before-tap2-$slug', 4);
        final page2 = _pageLabel();
        // ignore: avoid_print
        print('DEMO_CHECK $slug tap2 before capsule=${_capsuleUp()} page=$page2');
        await tester.tapAt(on);
        await tester.pump();
        await _hold(tester, 'after-tap2-$slug', 4);
        failures += _check(slug, 'tap2', page2);
        await _dismissChrome(tester);

        // 3. A third selection, then a tap in the right-hand page-turn zone.
        await _selectTurningOn(tester, .30);
        await _hold(tester, 'before-tap3-$slug', 4);
        final page3 = _pageLabel();
        // ignore: avoid_print
        print('DEMO_CHECK $slug tap3 before capsule=${_capsuleUp()} page=$page3');
        await _tapAt(tester, .9, .62);
        await _hold(tester, 'after-tap3-$slug', 4);
        failures += _check(slug, 'tap3', page3);
        await _dismissChrome(tester);

        await _back(tester);
      }
      // ignore: avoid_print
      print('DEMO_RESULT failures=$failures');
      expect(failures, 0);
    },
  );
}

extension on String {
  // `this.` is needed: a bare isEmpty is flutter_test's matcher.
  // ignore: unnecessary_this
  String? get nonEmpty => this.isEmpty ? null : this;
}

bool _capsuleUp() =>
    find.byKey(const ValueKey('selection-actions')).evaluate().isNotEmpty;

/// The page numbers in the visible `page N` labels, which change when the
/// page turns (and not when the chrome shows or hides).
String _pageLabel() {
  final pages = <int>{};
  for (final e in find
      .textContaining(RegExp(r'page \d'), findRichText: true)
      .evaluate()) {
    final w = e.widget;
    final s = switch (w) {
      Text() => w.data ?? w.textSpan?.toPlainText(),
      RichText() => w.text.toPlainText(),
      _ => null,
    };
    for (final m in RegExp(r'page (\d+)').allMatches(s ?? '')) {
      pages.add(int.parse(m.group(1)!));
    }
  }
  return (pages.toList()..sort()).join(',');
}

int _check(String slug, String tap, String pageBefore) {
  final capsule = _capsuleUp();
  final page = _pageLabel();
  final ok = !capsule && page == pageBefore;
  // ignore: avoid_print
  print(
    'DEMO_CHECK $slug $tap after capsule=$capsule page=$page '
    '${ok ? 'PASS' : 'FAIL'}',
  );
  return ok ? 0 : 1;
}

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
  await tester.tap(finder.last, warnIfMissed: false);
  await _hold(tester, 'opening', 4);
  final hint = find.byKey(const ValueKey('reader-zones-hint'));
  if (hint.evaluate().isNotEmpty) {
    await tester.tap(hint, warnIfMissed: false);
    await _hold(tester, 'hint-dismissed', 1);
  }
}

/// A tap that showed the reader chrome is answered with another, so the
/// next selection starts from the same page view.
Future<void> _dismissChrome(WidgetTester tester) async {
  if (find.byKey(const ValueKey('reader-header-back')).evaluate().isEmpty) {
    return;
  }
  await _tapAt(tester, .5, .62);
  await _hold(tester, 'chrome-hidden', 1);
}

Future<void> _back(WidgetTester tester) async {
  var f = find.byKey(const ValueKey('reader-header-back'));
  if (f.evaluate().isEmpty) {
    await _tapAt(tester, .5, .62);
    await _hold(tester, 'chrome', 1);
    f = find.byKey(const ValueKey('reader-header-back'));
  }
  if (f.evaluate().isNotEmpty) {
    await tester.tap(f.first, warnIfMissed: false);
  }
  await _hold(tester, 'back', 2);
}

Future<void> _tapKey(WidgetTester tester, String key) async {
  final f = find.byKey(ValueKey(key));
  if (f.evaluate().isEmpty) throw StateError('no $key');
  await tester.tap(f.first, warnIfMissed: false);
  await tester.pump();
}

Future<void> _tapAt(WidgetTester tester, double x, double y) async {
  final page = _page(tester);
  await tester.tapAt(
    Offset(page.left + page.width * x, page.top + page.height * y),
  );
  await tester.pump();
}

/// Selects a line near [y], turning pages until one holds prose. Returns the
/// middle of the dragged span, which lies on the selected text.
Future<Offset> _selectTurningOn(WidgetTester tester, double y) async {
  for (var tries = 0; ; tries += 1) {
    final at = await _select(tester, y);
    if (at != null) return at;
    if (tries >= 8) throw StateError('no selection opened the capsule');
    await _tapAt(tester, .9, .5);
    await _hold(tester, 'turn', 1);
  }
}

Future<Offset?> _select(WidgetTester tester, double y) async {
  final mobile = Platform.isIOS || Platform.isAndroid;
  for (final dy in const [0.0, .03, -.03, .06, -.06, .09, -.09, .12, -.12]) {
    final page = _page(tester);
    final (from, to) = page.width < 600 ? (.14, .70) : (.30, .46);
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
    if (_capsuleUp()) return at((from + to) / 2);
  }
  return null;
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
  // A small PDF passed inline, for a device that cannot reach the host.
  const pdf = String.fromEnvironment('SHOSAI_DEMO_PDF_B64');
  if (pdf.isNotEmpty) {
    File('${dir.path}/quiet-places.pdf').writeAsBytesSync(base64Decode(pdf));
  }
  return dir.path;
}
