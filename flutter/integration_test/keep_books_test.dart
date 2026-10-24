import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shosai_flutter/main.dart';

/// Evidence harness: imported books survive installing the app over itself.
///
/// `--dart-define=KEEP_BOOKS_MODE=seed` downloads the `name=url` pairs in
/// `KEEP_BOOKS_URLS` and imports them as private copies (as the iOS picker
/// does) into the production application-support directory.
/// `KEEP_BOOKS_MODE=check` starts the production app over the same store,
/// records each book's file and opens every book in the library.
/// `KEEP_BOOKS_LABEL` prefixes the screenshots, which go to the report data.
const _mode = String.fromEnvironment('KEEP_BOOKS_MODE', defaultValue: 'check');
const _label = String.fromEnvironment('KEEP_BOOKS_LABEL', defaultValue: 'run');
const _boundary = ValueKey<String>('keep-books-boundary');

final _report = <String, Object?>{};
final _shots = <String, String>{};
final _log = <String>[];

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('keep books', timeout: const Timeout(Duration(minutes: 10)), (
    tester,
  ) async {
    final support = await getApplicationSupportDirectory();
    _note('mode $_mode label $_label');
    _note('application support ${support.path}');
    final owner = await applicationCoreOwner();
    final bridge = owner.bridge();

    if (_mode == 'seed') {
      final books = await _download();
      final report = await bridge.importPaths(
        pathKeys: books,
        managed: true,
        cancellationId: bridge.createCancellation(),
      );
      _note('imported ${report.imported}');
      for (final item in report.items) {
        _note('  item ${item.pathKey} error ${item.error}');
      }
    }

    final page = await bridge.libraryPage(
      limit: 50,
      offset: 0,
      cancellationId: bridge.createCancellation(),
    );
    final titles = <String>[];
    for (final book in page.books) {
      titles.add(book.title);
      final exists = File(book.pathKey).existsSync();
      _note(
        'book "${book.title}" ${book.format.name} managed ${book.managed} '
        'file exists $exists path ${book.pathKey}',
      );
    }

    await tester.pumpWidget(
      RepaintBoundary(
        key: _boundary,
        child: ShosaiApp(
          productBridgeFactory: owner.bridge,
          locale: const Locale('en'),
        ),
      ),
    );
    await _settle(tester, seconds: 4);
    await _shot(tester, 'library');

    if (_mode == 'check') {
      for (final title in titles) {
        try {
          await _open(tester, title);
        } catch (error) {
          _note('open "$title": harness error ${'$error'.split('\n').first}');
        }
        final thrown = tester.takeException();
        if (thrown != null) {
          _note('open "$title": app exception ${'$thrown'.split('\n').first}');
        }
      }
    }

    _report['log'] = _log;
    _report['shots'] = _shots;
    binding.reportData = _report;
    await tester.pumpWidget(const SizedBox());
    await closeApplicationCores();
  });
}

Future<void> _open(WidgetTester tester, String title) async {
  // The reader folds the sidebar to icons, so find Library by any label.
  for (final library in [
    find.text('Library'),
    find.byTooltip('Library'),
    find.bySemanticsLabel(RegExp('^Library')),
  ]) {
    if (library.evaluate().isNotEmpty) {
      await tester.tap(library.first, warnIfMissed: false);
      await _settle(tester, seconds: 2);
      break;
    }
  }
  final card = find.text(title);
  final scrollable = find.byType(Scrollable);
  if (card.evaluate().isEmpty && scrollable.evaluate().isNotEmpty) {
    await tester.scrollUntilVisible(
      card,
      300,
      scrollable: scrollable.first,
      maxScrolls: 20,
    );
  }
  if (card.evaluate().isEmpty) {
    _note('open "$title": not on screen');
    return;
  }
  await tester.ensureVisible(card.last);
  await _settle(tester, seconds: 1);
  await tester.tap(card.last, warnIfMissed: false);
  await _settle(tester, seconds: 5);
  final problems = <String>{
    for (final element in find.byType(RichText).evaluate())
      if ((element.widget as RichText).text.toPlainText()
          case final text
          when RegExp(
            'could not|missing|not be found|Locate',
            caseSensitive: false,
          ).hasMatch(text))
        text,
  };
  _note(
    'open "$title": ${problems.isEmpty ? 'opened, no missing-file message' : 'MISSING: ${problems.join(' | ')}'}',
  );
  await _shot(tester, 'open-${_slug(title)}');
}

Future<List<String>> _download() async {
  const urls = String.fromEnvironment('KEEP_BOOKS_URLS');
  final dir = Directory.systemTemp.createTempSync('keep-books-');
  final client = HttpClient();
  final paths = <String>[];
  try {
    for (final pair in urls.split(',').where((p) => p.contains('='))) {
      final split = pair.indexOf('=');
      final name = pair.substring(0, split);
      final request = await client.getUrl(Uri.parse(pair.substring(split + 1)));
      final response = await request.close();
      final file = File('${dir.path}/$name');
      await response.pipe(file.openWrite());
      _note('downloaded $name ${file.lengthSync()} B');
      paths.add(file.path);
    }
  } finally {
    client.close();
  }
  return paths;
}

Future<void> _settle(WidgetTester tester, {int seconds = 2}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _shot(WidgetTester tester, String name) async {
  final label = '$_label-${(_shots.length + 1).toString().padLeft(2, '0')}-$name';
  final boundary =
      tester.renderObject(find.byKey(_boundary)) as RenderRepaintBoundary;
  final image = await boundary.toImage(
    pixelRatio: tester.view.devicePixelRatio,
  );
  final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
  image.dispose();
  _shots[label] = base64Encode(bytes.buffer.asUint8List());
  _note('shot $label');
}

String _slug(String title) => title
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
    .replaceAll(RegExp(r'^-|-$'), '');

void _note(String line) {
  _log.add(line);
  // ignore: avoid_print
  print('KEEP_BOOKS $line');
}
