import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart' show ShadDialog;
import 'package:shosai_flutter/main.dart';
import 'package:shosai_flutter/reader/pdf/pdfrx_engine.dart';

/// Release readiness tour (RFD 4 "The first release", RFD 6 notes and search).
///
/// Imports the books in `SHOSAI_TOUR_BOOKS`, or downloads the
/// `name=url` pairs in `--dart-define=SHOSAI_TOUR_URLS=...` (comma separated)
/// on a device that has no host directory, drives the production app
/// through each first-release outcome and captures a screenshot per step into
/// `SHOSAI_TOUR_OUT` and into the driver's report data (for devices).
/// `SHOSAI_TOUR_SIZE=390x844@3` forces a logical window size and ratio.
///
/// A step that fails is recorded and the tour moves on, so one run reports
/// every outcome.
const _boundary = ValueKey<String>('tour-boundary');

/// The tour finds controls by their English labels, so it runs the app in
/// English whatever the device language.
const _english = Locale('en');

final _report = <String, Object?>{'steps': <Map<String, Object?>>[]};
final _shots = <String, String>{};
String? _outDir;
int _step = 0;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('release tour', timeout: const Timeout(Duration(minutes: 20)), (
    tester,
  ) async {
    final env = Platform.environment;
    _outDir = env['SHOSAI_TOUR_OUT'];
    if (_outDir case final dir?) Directory(dir).createSync(recursive: true);
    final books = env['SHOSAI_TOUR_BOOKS'] ?? await _downloadBooks();
    final data = Directory(
      env['SHOSAI_TOUR_DATA'] ??
          Directory.systemTemp.createTempSync('shosai-tour-').path,
    )..createSync(recursive: true);
    if (env['SHOSAI_TOUR_SIZE'] case final size?) {
      final match = RegExp(r'^(\d+)x(\d+)(?:@([\d.]+))?$').firstMatch(size)!;
      final ratio = double.parse(match.group(3) ?? '1');
      tester.view.devicePixelRatio = ratio;
      tester.view.physicalSize = Size(
        double.parse(match.group(1)!) * ratio,
        double.parse(match.group(2)!) * ratio,
      );
      addTearDown(tester.view.reset);
    }
    final paths = [
      for (final f in Directory(books).listSync())
        if (f.path.endsWith('.epub') || f.path.endsWith('.pdf')) f.path,
    ]..sort();
    _note('platform', Platform.operatingSystem);
    _note(
      'window',
      '${(tester.view.physicalSize / tester.view.devicePixelRatio).width}x'
          '${(tester.view.physicalSize / tester.view.devicePixelRatio).height}'
          ' @${tester.view.devicePixelRatio}',
    );
    _note('books', paths.map((p) => p.split('/').last).toList());

    final owner = await applicationCoreOwner(
      applicationSupportDirectory: () async => data,
    );
    final bridge = owner.bridge();
    final imported = await bridge.importPaths(
      pathKeys: paths,
      managed: false,
      cancellationId: bridge.createCancellation(),
    );
    _note('imported', imported.imported.toInt());

    await tester.pumpWidget(
      RepaintBoundary(
        key: _boundary,
        child: ShosaiApp(productBridgeFactory: owner.bridge, locale: _english),
      ),
    );
    await _settle(tester);
    await _shot(tester, 'library');
    _note(
      'locale',
      '${Localizations.localeOf(tester.element(find.byType(Text).first))}'
          ' system ${tester.platformDispatcher.locale}',
    );

    // Outcome 2 and 5: an EPUB, its location line, contents and Back.
    await _try('origin', () async {
      await _openFromLibrary(tester, 'On the Origin of Species');
      await _shot(tester, 'origin-open');
      _status(tester, 'origin-status-open');
      _note('focus-after-open', '${FocusManager.instance.primaryFocus}');
      // A phone has no keyboard to check, and the test keyboard has no
      // physical keys for Android or iOS.
      if (!_mobile) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await _settle(tester, seconds: 1);
        _status(tester, 'origin-status-after-arrow-right');
        await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
        await _settle(tester, seconds: 1);
        _status(tester, 'origin-status-after-page-down-unfocused');
        final page = _pageRect(tester);
        final click = await tester.startGesture(
          page.center,
          kind: PointerDeviceKind.mouse,
          buttons: kPrimaryMouseButton,
        );
        await click.up();
        await _settle(tester, seconds: 1);
        _note('focus-after-click', '${FocusManager.instance.primaryFocus}');
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await _settle(tester, seconds: 1);
        _status(tester, 'origin-status-after-arrow-right-clicked');
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await _settle(tester, seconds: 1);
        _status(tester, 'origin-status-after-space');
      }
      for (var i = 0; i < 4; i += 1) {
        await _turn(tester);
        _status(tester, 'origin-status-after-page-down-$i');
      }
      await _shot(tester, 'origin-turned');
      _status(tester, 'origin-status-turned');
    });
    await _try('origin-contents', () async {
      await _tapKey(tester, 'reader-header-contents');
      await _settle(tester);
      await _shot(tester, 'origin-contents');
      await _tapText(tester, 'CHAPTER IV');
      await _settle(tester, seconds: 3);
      await _shot(tester, 'origin-contents-jump');
      _status(tester, 'origin-status-chapter-iv');
      _note(
        'origin-back-pill',
        find.byKey(const ValueKey('reader-back-pill')).evaluate().isNotEmpty,
      );
      await _tapKey(tester, 'reader-back');
      await _settle(tester, seconds: 3);
      _status(tester, 'origin-status-after-back');
      await _shot(tester, 'origin-back');
    });
    await _try('origin-highlight', () async {
      await _selectOnPage(tester);
      await _shot(tester, 'origin-selection');
      await _tapText(tester, 'Yellow');
      await _settle(tester);
      await _shot(tester, 'origin-highlighted');
    });
    await _try('origin-notes', () async {
      await _tapKey(tester, 'reader-header-notes');
      await _settle(tester);
      await _shot(tester, 'origin-notes-opened');
      await _tapKey(tester, 'reader-notes-add-page');
      await _settle(tester);
      await _shot(tester, 'origin-page-note-editor');
      await _settle(tester);
      // The note dialog's own field: a phone shows other text fields too.
      final fields = find.byType(EditableText);
      final inDialog = find.descendant(
        of: find.byType(ShadDialog),
        matching: find.byType(EditableText),
      );
      _note(
        'origin-note-fields',
        '${fields.evaluate().length} in all,'
            ' ${inDialog.evaluate().length} in the dialog',
      );
      final field = inDialog.evaluate().isNotEmpty
          ? inDialog.first
          : fields.last;
      await tester.tap(field, warnIfMissed: false);
      await tester.pump();
      await tester.enterText(field, 'Tour page note');
      await tester.pump();
      _note(
        'origin-note-typed',
        find.text('Tour page note').evaluate().isNotEmpty,
      );
      await _tapText(tester, 'Save');
      await _settle(tester);
      await _shot(tester, 'origin-notes-panel');
      _note(
        'origin-note-listed',
        find.textContaining('Tour page note').evaluate().isNotEmpty,
      );
      await _tapKey(tester, 'reader-notes-close');
      await _settle(tester);
    });
    await _try('origin-display', () async {
      await _tapKey(tester, 'reader-header-typography');
      await _settle(tester);
      await _shot(tester, 'origin-display-panel');
      await _tapText(tester, 'Night');
      await _tapKey(tester, 'reader-typography-font-increase');
      await _tapKey(tester, 'reader-typography-font-increase');
      await _settle(tester, seconds: 3);
      await _dismiss(tester);
      await _shot(tester, 'origin-night-larger');
      _status(tester, 'origin-status-larger');
    });

    // Outcome 2: the same reader for a PDF.
    await _try('pdf', () async {
      await _toLibrary(tester);
      await _openFromLibrary(tester, 'attention');
      await _shot(tester, 'pdf-open');
      _status(tester, 'pdf-status-open');
      await _turn(tester);
      await _settle(tester);
      await _shot(tester, 'pdf-turned');
      _status(tester, 'pdf-status-turned');
    });
    await _try('pdf-display', () async {
      await _tapKey(tester, 'reader-header-typography');
      await _settle(tester);
      await _shot(tester, 'pdf-display-panel');
      await _tapText(tester, 'Night');
      await _tapKey(tester, 'reader-typography-zoom-in');
      await _settle(tester, seconds: 3);
      await _dismiss(tester);
      await _shot(tester, 'pdf-night-zoomed');
      await _tapKey(tester, 'reader-header-typography');
      await _settle(tester);
      await _tapText(tester, 'Paper');
      await _tapKey(tester, 'reader-typography-fit-page');
      await _settle(tester, seconds: 2);
      await _dismiss(tester);
    });
    await _try('pdf-highlight', () async {
      await _settle(tester, seconds: 2);
      await _selectOnPage(tester);
      if (find.text('Green').evaluate().isEmpty) {
        _note('pdf-selection-first-drag', 'no selection actions');
        await _settle(tester, seconds: 3);
        await _selectOnPage(tester);
      }
      await _shot(tester, 'pdf-selection');
      await _tapText(tester, 'Green');
      await _settle(tester);
      await _shot(tester, 'pdf-highlighted');
    });

    // Outcome 5: a PDF link annotation (a citation or section reference).
    await _try('pdf-link', () async {
      await _tapPdfLink(tester, books);
      await _settle(tester, seconds: 3);
      await _shot(tester, 'pdf-link-tapped');
      _status(tester, 'pdf-status-after-link');
      _note(
        'pdf-link-back-pill',
        find.byKey(const ValueKey('reader-back-pill')).evaluate().isNotEmpty,
      );
    });

    // Outcome 5: an EPUB footnote.
    await _try('gibbon', () async {
      await _toLibrary(tester);
      await _openFromLibrary(tester, 'Decline and Fall');
      await _tapKey(tester, 'reader-header-contents');
      await _settle(tester);
      await _tapText(tester, 'Chapter I: The Extent', first: true);
      await _settle(tester, seconds: 3);
      await _turn(tester);
      await _settle(tester);
      await _shot(tester, 'gibbon-chapter');
      final dismiss = find.byKey(const ValueKey('reader-back-dismiss'));
      if (dismiss.evaluate().isNotEmpty) {
        await tester.tap(dismiss.first, warnIfMissed: false);
        await _settle(tester, seconds: 1);
      }
      var tapped = false;
      for (var turn = 0; turn < 4 && !tapped; turn += 1) {
        tapped = await _tapEpubLink(tester);
        if (!tapped) await _turn(tester);
      }
      _note('gibbon-link-found', tapped);
      await _settle(tester, seconds: 3);
      await _shot(tester, 'gibbon-footnote-tapped');
      _status(tester, 'gibbon-status-after-link');
      _note('gibbon-back-pill', _texts(tester, 'reader-back-pill'));
      if (tapped) {
        await _tapKey(tester, 'reader-back');
        await _settle(tester, seconds: 2);
        _status(tester, 'gibbon-status-after-back');
      }
    });

    // Vertical Japanese.
    await _try('neko', () async {
      await _toLibrary(tester);
      await _openFromLibrary(
        tester,
        find.textContaining('吾輩は猫である').evaluate().isNotEmpty ? '吾輩は猫である' : '草枕',
      );
      await _shot(tester, 'neko-open');
      await _turn(tester);
      await _turn(tester);
      await _settle(tester);
      await _shot(tester, 'neko-turned');
      _status(tester, 'neko-status');
    });

    // Outcome 3: search from the reader and the library, and Back.
    await _try('search', () async {
      // From a book, so the search offers This book and All books.
      if (find.byKey(const ValueKey('reader-header')).evaluate().isEmpty) {
        await _toLibrary(tester);
        await _openFromLibrary(tester, 'On the Origin of Species');
      }
      await _openSearch(tester);
      await tester.enterText(
        find.byKey(const ValueKey('shell-search-field')),
        'natural selection',
      );
      await _settle(tester, seconds: 3);
      await _shot(tester, 'search-text-this-book');
      await _tapText(tester, 'All books');
      await _settle(tester, seconds: 8);
      await _shot(tester, 'search-text');
      // The scope control took focus; give it back to the field first.
      final field = find.descendant(
        of: find.byKey(const ValueKey('shell-search-field')),
        matching: find.byType(EditableText),
      );
      await tester.tap(field, warnIfMissed: false);
      await tester.pump();
      await tester.enterText(field, 'Tour page note');
      await _settle(tester, seconds: 3);
      await _shot(tester, 'search-note');
      await _tapText(tester, 'Tour page note');
      await _settle(tester, seconds: 4);
      await _shot(tester, 'search-note-opened');
      _status(tester, 'search-note-status');
      _note(
        'search-back-pill',
        find.byKey(const ValueKey('reader-back-pill')).evaluate().isNotEmpty,
      );
    });

    // Outcome 3: the Notes place, all books.
    await _try('notes-place', () async {
      await _toLibrary(tester);
      await _place(tester, 'Notes');
      await _settle(tester, seconds: 2);
      await _shot(tester, 'notes-place');
      await _place(tester, 'Bookmarks');
      await _settle(tester);
      await _shot(tester, 'bookmarks-place');
      await _place(tester, 'Library');
      await _settle(tester);
      await _shot(tester, 'library-after');
    });

    // Outcome 4: open books, then a relaunch.
    await _try('open-books', () async {
      await _openFromLibrary(tester, 'On the Origin of Species');
      _status(tester, 'origin-status-reopened');
      await _shot(tester, 'origin-reopened');
      final switcher = find.byKey(const ValueKey('reader-open-books'));
      if (switcher.evaluate().isNotEmpty) {
        await tester.tap(switcher.first);
        await _settle(tester);
        await _shot(tester, 'switcher');
        await _dismiss(tester);
      }
    });
    await _try('relaunch', () async {
      await tester.pumpWidget(const SizedBox());
      await _settle(tester);
      await closeApplicationCores();
      final again = await applicationCoreOwner(
        applicationSupportDirectory: () async => data,
      );
      await tester.pumpWidget(
        RepaintBoundary(
          key: _boundary,
          child: ShosaiApp(
            productBridgeFactory: again.bridge,
            locale: _english,
          ),
        ),
      );
      await _settle(tester, seconds: 4);
      await _shot(tester, 'relaunch');
      _note(
        'relaunch-reading',
        find.byKey(const ValueKey('reader-header')).evaluate().isNotEmpty,
      );
      await _openFromLibrary(tester, 'On the Origin of Species');
      _status(tester, 'origin-status-relaunch');
      await _shot(tester, 'origin-relaunch');
    });
  });

  tearDownAll(() async {
    binding.reportData = {..._report, 'shots': _shots};
    if (_outDir case final dir?) {
      File(
        '$dir/report.json',
      ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(_report));
    }
  });
}

Future<String> _downloadBooks() async {
  const urls = String.fromEnvironment('SHOSAI_TOUR_URLS');
  final dir = Directory.systemTemp.createTempSync('shosai-tour-books-');
  final client = HttpClient();
  try {
    for (final pair in urls.split(',').where((p) => p.contains('='))) {
      final split = pair.indexOf('=');
      final name = pair.substring(0, split);
      final request = await client.getUrl(Uri.parse(pair.substring(split + 1)));
      final response = await request.close();
      final sink = File('${dir.path}/$name').openWrite();
      await response.pipe(sink);
      _note('downloaded', '$name ${File('${dir.path}/$name').lengthSync()} B');
    }
  } finally {
    client.close();
  }
  return dir.path;
}

Future<void> _try(String name, Future<void> Function() body) async {
  try {
    await body();
    _note('$name-ok', true);
  } catch (error, stack) {
    _note(
      '$name-FAILED',
      '$error\n${stack.toString().split('\n').take(6).join('\n')}',
    );
  }
}

void _note(String key, Object? value) {
  (_report['steps']! as List).add({'key': key, 'value': value});
  // ignore: avoid_print
  print('TOUR $key: $value');
}

final _mobile = Platform.isAndroid || Platform.isIOS;

List<String> _texts(WidgetTester tester, String key) => [
  for (final e
      in find
          .descendant(
            of: find.byKey(ValueKey(key)),
            matching: find.byType(Text),
          )
          .evaluate())
    (e.widget as Text).data ?? '',
];

void _status(WidgetTester tester, String key) =>
    _note(key, _statusTexts(tester));

List<String> _statusTexts(WidgetTester tester) {
  final texts = <String>[];
  for (final k in [
    'reader-status-line',
    'reader-status-section',
    'reader-phone-bar',
  ]) {
    final finder = find.descendant(
      of: find.byKey(ValueKey(k)),
      matching: find.byType(Text),
    );
    for (final e in finder.evaluate()) {
      final widget = e.widget as Text;
      texts.add(widget.data ?? widget.textSpan?.toPlainText() ?? '');
    }
  }
  return texts;
}

Future<void> _settle(WidgetTester tester, {int seconds = 2}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _tapText(
  WidgetTester tester,
  String text, {
  bool first = false,
}) async {
  final finder = find.textContaining(text, findRichText: true);
  if (finder.evaluate().isEmpty) throw StateError('no "$text" on screen');
  await tester.tap(first ? finder.first : finder.last, warnIfMissed: false);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _tapKey(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  if (finder.evaluate().isEmpty) throw StateError('no $key on screen');
  await tester.tap(finder.first, warnIfMissed: false);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

/// Closes the open panel: Escape on desktop, a tap on the scrim on a phone.
Future<void> _dismiss(WidgetTester tester) async {
  final scrim = find.byKey(const ValueKey('reader-panel-scrim'));
  if (!_mobile) {
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
  } else if (scrim.evaluate().isNotEmpty) {
    await tester.tapAt(
      tester.getRect(scrim.first).topCenter + const Offset(0, 8),
    );
  }
  await _settle(tester, seconds: 1);
}

/// Turns forward with the stage's next-page edge, the way a pointer or a tap
/// does (the keyboard is checked separately).
Future<void> _turn(WidgetTester tester) async {
  final next = find.byKey(const ValueKey('reader-edge-next'));
  if (next.evaluate().isEmpty) throw StateError('no next-page edge');
  await tester.tap(next.first, warnIfMissed: false);
  await _settle(tester, seconds: 1);
}

Future<void> _openFromLibrary(WidgetTester tester, String title) async {
  final finder = find.textContaining(title, findRichText: true);
  // A small window builds only the first rows of the shelf.
  final scrollable = find.byType(Scrollable);
  if (finder.evaluate().isEmpty && scrollable.evaluate().isNotEmpty) {
    await tester.scrollUntilVisible(
      finder,
      300,
      scrollable: scrollable.first,
      maxScrolls: 30,
    );
  }
  if (finder.evaluate().isEmpty) throw StateError('no "$title" on screen');
  await tester.ensureVisible(finder.last);
  await _settle(tester, seconds: 1);
  await _tapText(tester, title);
  await _settle(tester, seconds: 4);
}

/// Back to the library side: the rail's Library entry, or the reader's back
/// control on a phone.
Future<void> _toLibrary(WidgetTester tester) async {
  final close = find.byKey(const ValueKey('shell-search-close'));
  if (close.evaluate().isNotEmpty) {
    await tester.tap(close.first, warnIfMissed: false);
    await _settle(tester, seconds: 1);
  }
  final back = find.byKey(const ValueKey('reader-header-back'));
  if (back.evaluate().isNotEmpty) {
    await tester.tap(back.first, warnIfMissed: false);
  } else {
    // The rail has a tooltip; the wide sidebar and the phone tab bar have
    // the word.
    var library = find.byTooltip('Library');
    if (library.evaluate().isEmpty) library = find.text('Library');
    if (library.evaluate().isEmpty) throw StateError('no way to the library');
    await tester.tap(library.first, warnIfMissed: false);
  }
  await _settle(tester, seconds: 2);
}

Future<void> _place(WidgetTester tester, String name) async {
  final finder = find.text(name);
  if (finder.evaluate().isEmpty) throw StateError('no place $name');
  await tester.tap(finder.first, warnIfMissed: false);
  await tester.pump();
}

Future<void> _openSearch(WidgetTester tester) async {
  final header = find.byKey(const ValueKey('reader-header-search'));
  if (header.evaluate().isNotEmpty) {
    await tester.tap(header.first, warnIfMissed: false);
  } else {
    await tester.tap(find.text('Search').first, warnIfMissed: false);
  }
  await _settle(tester, seconds: 2);
}

/// The reader's visible page area.
Rect _pageRect(WidgetTester tester) {
  final pdf = find.byKey(const ValueKey('reader-pdf-page-shadow'));
  if (pdf.evaluate().isNotEmpty) return tester.getRect(pdf.first);
  final paint = find.byKey(const ValueKey('reader-page-paint'));
  if (paint.evaluate().isNotEmpty) return tester.getRect(paint.first);
  final page = find.byKey(const ValueKey('reader-page'));
  if (page.evaluate().isNotEmpty) return tester.getRect(page.first);
  return tester.getRect(find.byKey(const ValueKey('reader-stage')).first);
}

/// Selects a run of text a third of the way down the first page: a mouse
/// drag on desktop, a long press and drag on touch.
Future<void> _selectOnPage(WidgetTester tester) async {
  final rect = _pageRect(tester);
  final start = Offset(
    rect.left + rect.width * .18,
    rect.top + rect.height * .35,
  );
  final end = Offset(
    rect.left + rect.width * .42,
    rect.top + rect.height * .38,
  );
  if (_mobile) {
    final gesture = await tester.startGesture(start);
    await tester.pump(const Duration(milliseconds: 700));
    await gesture.moveTo(end);
    await tester.pump(const Duration(milliseconds: 200));
    await gesture.up();
  } else {
    final gesture = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
      buttons: kPrimaryMouseButton,
    );
    await tester.pump(const Duration(milliseconds: 50));
    for (var i = 1; i <= 8; i += 1) {
      await gesture.moveTo(Offset.lerp(start, end, i / 8)!);
      await tester.pump(const Duration(milliseconds: 30));
    }
    await gesture.up();
  }
  await _settle(tester, seconds: 2);
}

/// Taps the first internal link annotation on the shown PDF page.
Future<void> _tapPdfLink(WidgetTester tester, String books) async {
  final engine = PdfrxPdfEngine();
  final document = await engine.open('$books/attention.pdf');
  try {
    // The tour turned once from the cover, so page 2 shows (alone on a phone,
    // on the left of a spread otherwise).
    const page = 1;
    final size = document.pageSize(page);
    final links = await document.links(page);
    _note('pdf-links-on-page', links.length);
    final link = links.firstWhere(
      (l) => l.page != null,
      orElse: () => links.first,
    );
    final r = link.rects.first;
    final pageRect = _pageRect(tester);
    final spread = pageRect.width > pageRect.height;
    _note('pdf-page-rect', '$pageRect spread $spread');
    final width = spread ? pageRect.width / 2 : pageRect.width;
    final scale = width / size.width;
    final offset = Offset(
      pageRect.left + (r.left + r.right) / 2 * scale,
      pageRect.top + (size.height - (r.top + r.bottom) / 2) * scale,
    );
    _note('pdf-link-target', 'page ${link.page} url ${link.url} at $offset');
    await tester.tapAt(offset);
    await tester.pump();
  } finally {
    await document.dispose();
  }
}

/// Taps across the shown EPUB page until a tap follows a link (a Back
/// point appears or the location changes), or reports that none did.
Future<bool> _tapEpubLink(WidgetTester tester) async {
  final rect = _pageRect(tester);
  String location() => _statusTexts(tester).join(' | ');
  final before = location();
  var taps = 0;
  for (var y = rect.top + 40; y < rect.bottom - 40; y += 9) {
    for (var x = rect.left + 40; x < rect.right - 40; x += 12) {
      final gesture = await tester.startGesture(
        Offset(x, y),
        kind: _mobile ? PointerDeviceKind.touch : PointerDeviceKind.mouse,
        buttons: kPrimaryMouseButton,
      );
      await gesture.up();
      taps += 1;
      if (taps % 20 == 0) await tester.pump(const Duration(milliseconds: 16));
      if (find
              .byKey(const ValueKey('reader-back-pill'))
              .evaluate()
              .isNotEmpty ||
          location() != before) {
        await tester.pump(const Duration(milliseconds: 100));
        _note('gibbon-link-tap', 'at ${Offset(x, y)} after $taps taps');
        return true;
      }
    }
  }
  _note('gibbon-link-tap', 'none after $taps taps');
  return false;
}

Future<void> _shot(WidgetTester tester, String name) async {
  final error = tester.takeException();
  if (error != null) {
    _note('EXCEPTION-before-$name', '$error'.split('\n').take(3).join(' '));
  }
  _step += 1;
  final label = '${_step.toString().padLeft(2, '0')}-$name';
  final boundary =
      tester.renderObject(find.byKey(_boundary)) as RenderRepaintBoundary;
  final image = await boundary.toImage(
    pixelRatio: tester.view.devicePixelRatio,
  );
  final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
  image.dispose();
  final png = bytes.buffer.asUint8List();
  _shots[label] = base64Encode(png);
  if (_outDir case final dir?) {
    File('$dir/$label.png').writeAsBytesSync(png);
  }
  _note('shot', label);
}
