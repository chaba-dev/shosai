import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_flutter/l10n/app_localizations.dart';
import 'package:shosai_flutter/shell/view.dart';
import 'package:shosai_flutter/core/bridge.dart';

import '../support/production_shell_harness.dart';

FlutterLibraryBook _book(int id, String title, {double progress = 0}) =>
    FlutterLibraryBook(
      bookId: id,
      title: title,
      format: FlutterBookFormat.epub,
      pathKey: '/books/$id.epub',
      managed: true,
      progress: progress,
      dateAdded: '2026-10-21',
    );

final _origin = _book(1, 'On the Origin of Species', progress: .04);
final _shannon = _book(2, 'A Mathematical Theory of Communication');
final _neko = _book(3, '吾輩は猫である');

ShellModel _model({bool reading = false, ShellPlace? place}) {
  var model = const ShellModel();
  for (final book in [_origin, _shannon, _neko]) {
    model = update(model, ShellBookOpened(book));
  }
  model = update(model, const ShellBookActivated(1));
  return model.copyWith(reading: reading, place: place ?? ShellPlace.library);
}

class _Recorder {
  final places = <ShellPlace>[];
  final opened = <int>[];
  final closed = <int>[];
  final moves = <(int, int)>[];
  final covers = <int>[];
  var adds = 0;

  /// Whether the library admits a cover request, as its four slots do.
  bool Function() admitCover = () => true;

  ShellActions get actions => ShellActions(
    selectPlace: places.add,
    openBook: (entry) => opened.add(entry.id),
    closeBook: (entry) => closed.add(entry.id),
    moveBook: (from, to) => moves.add((from, to)),
    addBooks: () => adds += 1,
    loadCover: (id) {
      if (!admitCover()) return false;
      covers.add(id);
      return true;
    },
  );
}

Future<void> _pumpFrame(
  WidgetTester tester, {
  required Size size,
  required ShellModel model,
  required _Recorder recorder,
  Locale? locale,
  Map<int, Uint8List> covers = const {},
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    productionShell(
      locale: locale,
      home: Scaffold(
        body: ShellFrame(
          layout: ShellLayout.forWidth(size.width),
          model: model,
          covers: covers,
          actions: recorder.actions,
          child: const SizedBox.expand(key: Key('content')),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadHarnessFonts);

  test('window classes follow the design system breakpoints', () {
    expect(ShellLayout.forWidth(390), ShellLayout.phone);
    expect(ShellLayout.forWidth(599), ShellLayout.phone);
    expect(ShellLayout.forWidth(600), ShellLayout.tablet);
    expect(ShellLayout.forWidth(1199), ShellLayout.tablet);
    expect(ShellLayout.forWidth(1200), ShellLayout.desktop);
    expect(ShellLayout.desktop.sidebarWidth, 240);
    expect(ShellLayout.tablet.sidebarWidth, 220);
    expect(ShellLayout.desktop.railWidth, 64);
    expect(ShellLayout.tablet.railWidth, 56);
  });

  test('the reading status follows the progress, not its rounding', () {
    final l10n = lookupAppLocalizations(const Locale('en'));
    expect(shellReadingStatus(l10n, 0), 'Not started');
    // A book under way never reads as not started or as complete.
    expect(shellReadingStatus(l10n, .001), '1%');
    expect(shellReadingStatus(l10n, .004), '1%');
    expect(shellReadingStatus(l10n, .21), '21%');
    expect(shellReadingStatus(l10n, .995), '99%');
    expect(shellReadingStatus(l10n, .999), '99%');
    expect(shellReadingStatus(l10n, 1), '100%');
  });

  testWidgets('a book barely started shows its bar in the sidebar', (
    tester,
  ) async {
    final model = update(
      const ShellModel(),
      ShellBookOpened(_book(4, 'Walden', progress: .001)),
    ).copyWith(reading: false);
    await _pumpFrame(
      tester,
      size: const Size(1440, 900),
      model: model,
      recorder: _Recorder(),
    );
    expect(find.text('1%'), findsOneWidget);
    expect(find.byType(ShellProgressBar), findsOneWidget);
  });

  testWidgets('the desktop library side has the full sidebar', (tester) async {
    final recorder = _Recorder();
    await _pumpFrame(
      tester,
      size: const Size(1440, 900),
      model: _model(),
      recorder: recorder,
    );
    expect(find.byType(ShellSidebar), findsOneWidget);
    expect(find.byType(ShellRail), findsNothing);
    expect(find.byType(ShellBottomNav), findsNothing);
    expect(tester.getSize(find.byType(ShellSidebar)).width, 240);
    expect(tester.getSize(find.byKey(const Key('content'))).width, 1200);

    expect(find.text('Shōsai'), findsOneWidget);
    for (final label in ['Library', 'Notes', 'Bookmarks', 'Add books']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    // The field-shaped button and the place both read Search on desktop.
    expect(find.text('Search'), findsNWidgets(2));
    expect(find.text('READING NOW'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('On the Origin of Species'), findsOneWidget);
    expect(find.text('4%'), findsOneWidget);
    expect(find.text('Not started'), findsNWidgets(2));

    await tester.tap(find.text('Notes'));
    await tester.tap(find.text('A Mathematical Theory of Communication'));
    await tester.tap(find.text('Add books'));
    await tester.tap(find.text('Search').first);
    expect(recorder.places, [ShellPlace.notes, ShellPlace.search]);
    expect(recorder.opened, [2]);
    expect(recorder.adds, 1);
  });

  testWidgets('the current place is marked for assistive technology', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pumpFrame(
      tester,
      size: const Size(1440, 900),
      model: _model(place: ShellPlace.bookmarks),
      recorder: _Recorder(),
    );
    expect(
      tester.getSemantics(find.text('Bookmarks')),
      isSemantics(isButton: true, isSelected: true),
    );
    expect(
      tester.getSemantics(find.text('Library')),
      isSemantics(isButton: true, isSelected: false),
    );
    handle.dispose();
  });

  testWidgets('labeled shell controls activate through their semantics', (
    tester,
  ) async {
    // The rail's icon places, its covers and the close buttons carry their
    // own labels; a screen reader must still be able to press them.
    final handle = tester.ensureSemantics();
    final recorder = _Recorder();
    await _pumpFrame(
      tester,
      size: const Size(1440, 900),
      model: _model(reading: true),
      recorder: recorder,
    );
    expect(find.byType(ShellRail), findsOneWidget);
    for (final label in ['Notes', 'A Mathematical Theory of Communication']) {
      expect(
        tester.getSemantics(find.bySemanticsLabel(label)),
        isSemantics(isButton: true, hasTapAction: true, isFocusable: true),
        reason: label,
      );
    }
    tester.semantics.tap(find.semantics.byLabel('Notes'));
    tester.semantics.tap(
      find.semantics.byLabel('A Mathematical Theory of Communication'),
    );
    expect(recorder.places, [ShellPlace.notes]);
    expect(recorder.opened, [2]);

    await _pumpFrame(
      tester,
      size: const Size(1440, 900),
      model: _model(),
      recorder: recorder,
    );
    tester.semantics.tap(
      find.semantics.byLabel('Close On the Origin of Species'),
    );
    expect(recorder.closed, [1]);
    handle.dispose();
  });

  testWidgets('an open book closes from the hover button on desktop', (
    tester,
  ) async {
    final recorder = _Recorder();
    await _pumpFrame(
      tester,
      size: const Size(1440, 900),
      model: _model(),
      recorder: recorder,
    );
    final close = find.byTooltip('Close 吾輩は猫である');
    expect(close, findsOneWidget);
    expect(
      tester
          .widget<Visibility>(
            find.ancestor(of: close, matching: find.byType(Visibility)).first,
          )
          .visible,
      isFalse,
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('吾輩は猫である')));
    await tester.pumpAndSettle();
    await tester.tap(close);
    expect(recorder.closed, [3]);
  });

  testWidgets('a desktop close button shows while the keyboard is on it', (
    tester,
  ) async {
    final recorder = _Recorder();
    await _pumpFrame(
      tester,
      size: const Size(1440, 900),
      model: _model(),
      recorder: recorder,
    );
    final close = find.byTooltip('Close 吾輩は猫である');
    bool visible() => tester
        .widget<Visibility>(
          find.ancestor(of: close, matching: find.byType(Visibility)).first,
        )
        .visible;
    bool onClose() {
      final focused = FocusManager.instance.primaryFocus?.context;
      return focused != null &&
          find
              .descendant(of: close, matching: find.byWidget(focused.widget))
              .evaluate()
              .isNotEmpty;
    }

    expect(visible(), isFalse);
    for (var i = 0; i < 40 && !onClose(); i += 1) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
    }
    expect(onClose(), isTrue, reason: 'Tab reaches the close button');
    expect(visible(), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(recorder.closed, [3]);
  });

  testWidgets('a control removed right after taking focus does not throw', (
    tester,
  ) async {
    final recorder = _Recorder();
    await _pumpFrame(
      tester,
      size: const Size(1440, 900),
      model: _model(),
      recorder: recorder,
    );
    // Focus a place row, then remove the sidebar before the next frame runs
    // the row's reveal callback.
    final focus = Focus.of(
      tester.element(
        find.descendant(
          of: find.ancestor(
            of: find.text('Notes'),
            matching: find.byType(InkWell),
          ),
          matching: find.byType(Text),
        ),
      ),
    );
    focus.requestFocus();
    await tester.idle();
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('the tablet sidebar is narrower and has no search button', (
    tester,
  ) async {
    await _pumpFrame(
      tester,
      size: const Size(1180, 820),
      model: _model(),
      recorder: _Recorder(),
    );
    expect(tester.getSize(find.byType(ShellSidebar)).width, 220);
    expect(find.text('Search'), findsOneWidget);
    // Touch layouts always show the close buttons.
    for (final visibility in tester.widgetList<Visibility>(
      find.byType(Visibility),
    )) {
      expect(visibility.visible, isTrue);
    }
  });

  testWidgets('reading collapses the sidebar to the rail', (tester) async {
    final recorder = _Recorder();
    await _pumpFrame(
      tester,
      size: const Size(1440, 900),
      model: _model(reading: true),
      recorder: recorder,
    );
    expect(find.byType(ShellSidebar), findsNothing);
    expect(tester.getSize(find.byType(ShellRail)).width, 64);
    expect(find.text('Library'), findsNothing);
    for (final label in [
      'Library',
      'Notes',
      'Bookmarks',
      'Search',
      'Add books',
      'On the Origin of Species',
      'A Mathematical Theory of Communication',
      '吾輩は猫である',
    ]) {
      expect(find.byTooltip(label), findsOneWidget, reason: label);
    }
    await tester.tap(find.byTooltip('Library'));
    await tester.tap(find.byTooltip('吾輩は猫である'));
    expect(recorder.places, [ShellPlace.library]);
    expect(recorder.opened, [3]);
  });

  testWidgets('the tablet rail is 56 px', (tester) async {
    await _pumpFrame(
      tester,
      size: const Size(1180, 820),
      model: _model(reading: true),
      recorder: _Recorder(),
    );
    expect(tester.getSize(find.byType(ShellRail)).width, 56);
  });

  testWidgets('a phone gets the bottom bar, and nothing while reading', (
    tester,
  ) async {
    final recorder = _Recorder();
    await _pumpFrame(
      tester,
      size: const Size(390, 844),
      model: _model(),
      recorder: recorder,
    );
    expect(find.byType(ShellSidebar), findsNothing);
    expect(find.byType(ShellBottomNav), findsOneWidget);
    expect(tester.getSize(find.byType(ShellBottomNav)).height, 64);
    await tester.tap(find.text('Bookmarks'));
    expect(recorder.places, [ShellPlace.bookmarks]);

    await _pumpFrame(
      tester,
      size: const Size(390, 844),
      model: _model(reading: true),
      recorder: recorder,
    );
    expect(find.byType(ShellBottomNav), findsNothing);
    expect(find.byType(ShellRail), findsNothing);
    expect(tester.getSize(find.byKey(const Key('content'))).width, 390);
  });

  testWidgets('phone Reading now cards open and close books', (tester) async {
    final recorder = _Recorder();
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      productionShell(
        home: Scaffold(
          body: ShellReadingNowCards(
            model: _model(),
            covers: const {},
            actions: recorder.actions,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Reading now'), findsOneWidget);
    await tester.tap(find.text('On the Origin of Species'));
    await tester.tap(find.byTooltip('Close On the Origin of Species'));
    expect(recorder.opened, [1]);
    expect(recorder.closed, [1]);
  });

  testWidgets('every shell control on touch layouts is a touch target', (
    tester,
  ) async {
    // docs/design-system.md: `touch-target` (44 px) for every control on
    // tablet and phone. The InkWell is each control's pressable bound.
    void expectTargets(Finder surface, String name) {
      final wells = find.descendant(
        of: surface,
        matching: find.byType(InkWell),
      );
      expect(wells, findsWidgets, reason: name);
      for (final well in wells.evaluate()) {
        final size = tester.getSize(find.byWidget(well.widget));
        expect(
          size.width >= 44 && size.height >= 44,
          isTrue,
          reason: '$name control is $size',
        );
      }
    }

    final recorder = _Recorder();
    for (final reading in [false, true]) {
      await _pumpFrame(
        tester,
        size: const Size(1180, 820),
        model: _model(reading: reading),
        recorder: recorder,
      );
      expectTargets(
        find.byType(reading ? ShellRail : ShellSidebar),
        reading ? 'tablet rail' : 'tablet sidebar',
      );
    }
    expect(tester.getSize(find.byType(ShellRail)).width, 56);

    await _pumpFrame(
      tester,
      size: const Size(390, 844),
      model: _model(),
      recorder: recorder,
    );
    expectTargets(find.byType(ShellBottomNav), 'phone bottom bar');
    await tester.pumpWidget(
      productionShell(
        home: Scaffold(
          body: ShellReadingNowCards(
            model: _model(),
            covers: const {},
            actions: recorder.actions,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expectTargets(find.byType(ShellReadingNowCards), 'phone Reading now');
  });

  testWidgets(
    'a short sidebar with open books scrolls instead of overflowing',
    (tester) async {
      // 900 x 400 at 200% text: the wordmark, places, Reading now and Add books
      // need more height than the window has.
      const HarnessView(size: Size(900, 400), textScale: 2).apply(tester);
      final recorder = _Recorder();
      await tester.pumpWidget(
        productionShell(
          home: Scaffold(
            body: ShellFrame(
              layout: ShellLayout.forWidth(900),
              model: _model(),
              covers: const {},
              actions: recorder.actions,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expectOnlyKnownDefects(
        await findRenderDefects(tester),
        const <KnownRenderDefect>[],
      );

      // The keyboard reaches the last open book and Add books, and each is
      // scrolled into the window when it takes focus.
      final sidebar = tester.getRect(find.byType(ShellSidebar));
      for (final label in ['吾輩は猫である', 'Add books']) {
        final target = find.text(label);
        bool focused() {
          final context = FocusManager.instance.primaryFocus?.context;
          return context != null &&
              find
                  .ancestor(of: target, matching: find.byWidget(context.widget))
                  .evaluate()
                  .isNotEmpty;
        }

        for (var i = 0; i < 40 && !focused(); i += 1) {
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pumpAndSettle();
        }
        expect(focused(), isTrue, reason: '$label takes focus');
        // The focus ring is drawn 2 px outside the control; the viewport's
        // clip must leave room for it.
        final viewport = tester.getRect(
          find.descendant(
            of: find.byType(ShellSidebar),
            matching: find.byType(Viewport),
          ),
        );
        final ring = tester
            .getRect(
              find.ancestor(of: target, matching: find.byType(InkWell)).first,
            )
            .inflate(2);
        expect(
          viewport.contains(ring.topLeft) &&
              viewport.contains(ring.bottomRight - const Offset(.01, .01)),
          isTrue,
          reason: '$label focus ring $ring inside the viewport $viewport',
        );
        final rect = tester.getRect(target);
        expect(
          rect.top >= sidebar.top && rect.bottom <= sidebar.bottom,
          isTrue,
          reason: '$label at $rect is inside the sidebar $sidebar',
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
      }
      expect(recorder.opened, [3]);
      expect(recorder.adds, 1);
    },
  );

  testWidgets('the Japanese sidebar keeps its labels unspaced', (tester) async {
    await _pumpFrame(
      tester,
      size: const Size(1440, 900),
      model: _model(),
      recorder: _Recorder(),
      locale: const Locale('ja'),
    );
    expect(find.text('読書中'), findsOneWidget);
    expect(find.text('ライブラリ'), findsOneWidget);
    expect(find.text('本を追加'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('place pages say what to do', (tester) async {
    await tester.pumpWidget(
      productionShell(
        home: const Scaffold(
          body: ShellPlacePage(
            layout: ShellLayout.desktop,
            place: ShellPlace.notes,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Notes'), findsOneWidget);
    expect(find.text('No notes yet'), findsOneWidget);
  });

  testWidgets('covers are requested once per visible book', (tester) async {
    final recorder = _Recorder();
    await _pumpFrame(
      tester,
      size: const Size(1440, 900),
      model: _model(),
      recorder: recorder,
    );
    await tester.pump();
    expect(recorder.covers..sort(), [1, 2, 3]);
  });

  testWidgets('a cover the library turns away is asked for again', (
    tester,
  ) async {
    // The library admits one cover at a time here; each delivered cover
    // frees the slot and rebuilds the shell with the new cover map.
    final recorder = _Recorder();
    var slots = 1;
    recorder.admitCover = () => slots > 0 && slots-- > 0;
    final delivered = <int, Uint8List>{};
    for (var round = 0; round < 3; round += 1) {
      await _pumpFrame(
        tester,
        size: const Size(1440, 900),
        model: _model(),
        recorder: recorder,
        covers: Map.of(delivered),
      );
      await tester.pump();
      for (final id in recorder.covers) {
        delivered[id] = Uint8List(0);
      }
      slots = 1;
    }
    expect(recorder.covers..sort(), [1, 2, 3]);
  });
}
