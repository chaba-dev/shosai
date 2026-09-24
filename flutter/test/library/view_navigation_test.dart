import 'dart:async';
import 'dart:ui' as ui;
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shosai_flutter/app_theme.dart';
import 'package:shosai_flutter/library/view.dart';
import 'package:shosai_flutter/src/rust/api.dart';
import 'package:shosai_flutter/theme_tokens.dart';

import '../support/production_shell_harness.dart';

/// Package 3A: the library's navigation composition (LB-03 … LB-10).
///
/// Every case renders the production shell with the deterministic harness
/// bridge, so the assertions are about the composition the application builds
/// rather than a lookalike wrapper. Behavior (activation, focus, selected
/// state) and geometry are checked here; the package's rendered states are
/// captured and inspected in `test/visual/library_navigation_test.dart`.

/// The desktop import path has no adapter above the native picker, so the
/// file-selector channel is the platform boundary these tests stub.
const _pickerChannel = MethodChannel('plugins.flutter.io/file_selector');

/// Records native picker requests and answers them with [paths].
class _PickerStub {
  _PickerStub(WidgetTester tester, this.paths) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      _pickerChannel,
      (call) async {
        calls.add(call.method);
        return switch (call.method) {
          'openFile' => paths,
          _ => null,
        };
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        _pickerChannel,
        null,
      ),
    );
  }

  final List<String> paths;
  final List<String> calls = [];
}

/// A library bridge whose loads and imports can be held open, so a test can
/// observe the header while an operation is genuinely in flight.
class _ControlledBridge implements FlutterBridge {
  _ControlledBridge({List<FlutterLibraryBook>? books})
    : books = books ?? harnessLibraryBooks();

  final List<FlutterLibraryBook> books;
  Completer<FlutterLibraryPage>? pageCompleter;
  Completer<FlutterImportReport>? importCompleter;
  final List<BigInt> cancelled = [];
  final List<BigInt> importCancellations = [];
  int pageCalls = 0;
  int importCalls = 0;
  bool _disposed = false;
  BigInt _next = BigInt.one;

  @override
  bool get isDisposed => _disposed;

  @override
  void dispose() => _disposed = true;

  @override
  BigInt createCancellation() {
    final value = _next;
    _next += BigInt.one;
    return value;
  }

  @override
  bool cancel({required BigInt id}) {
    cancelled.add(id);
    return true;
  }

  @override
  bool releaseCancellation({required BigInt id}) => true;

  @override
  Future<FlutterLibraryPage> libraryPage({
    String? query,
    FlutterBookFormat? format,
    required int limit,
    required int offset,
    required BigInt cancellationId,
  }) async {
    pageCalls += 1;
    final pending = pageCompleter;
    if (pending != null) return pending.future;
    return FlutterLibraryPage(books: books, hasMore: false);
  }

  @override
  Future<Uint8List?> libraryCover({
    required int bookId,
    required BigInt cancellationId,
  }) async => null;

  @override
  Future<FlutterReaderSettings> loadReaderSettings({
    required BigInt cancellationId,
  }) async => const FlutterReaderSettings(
    continuous: false,
    theme: 'light',
    epubFontSize: 18,
    epubLineSpacing: 1.6,
    pdfZoom: 0,
  );

  @override
  Future<FlutterImportReport> importPaths({
    required List<String> pathKeys,
    required bool managed,
    required BigInt cancellationId,
  }) async {
    importCalls += 1;
    importCancellations.add(cancellationId);
    final pending = importCompleter;
    if (pending != null) return pending.future;
    return FlutterImportReport(
      imported: BigInt.zero,
      failed: BigInt.zero,
      cancelled: false,
      items: const [],
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _waitUntil(bool Function() predicate) async {
  while (!predicate()) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  setUpAll(loadHarnessFonts);

  /// Renders the library and returns the bridge behind it.
  Future<HarnessBridge> pumpLibrary(
    WidgetTester tester,
    Size size, {
    double textScale = 1,
    List<FlutterLibraryBook>? books,
    Locale? locale,
  }) async {
    final bridge = HarnessBridge(
      books: books ?? harnessLibraryBooks(),
      covers: harnessCovers(),
    );
    final view = HarnessView(size: size, textScale: textScale);
    view.apply(tester);
    await renderHarnessState(
      tester,
      productionShell(
        locale: locale,
        home: ProductShell(
          bridgeFactory: () => bridge,
          readerBuilder: (_, _, _, _, _, _) => const SizedBox(),
        ),
      ),
      ready: () => harnessImagesReady(tester),
    );
    return bridge;
  }

  /// Renders the library over a bridge whose operations can be held open.
  Future<_ControlledBridge> pumpControlledLibrary(
    WidgetTester tester,
    Size size, {
    double textScale = 1,
    _ControlledBridge? bridge,
    bool settle = true,
    Locale? locale,
  }) async {
    final effective = bridge ?? _ControlledBridge();
    final view = HarnessView(size: size, textScale: textScale);
    view.apply(tester);
    await tester.pumpWidget(
      productionShell(
        locale: locale,
        home: ProductShell(
          bridgeFactory: () => effective,
          readerBuilder: (_, _, _, _, _, _) => const SizedBox(),
        ),
      ),
    );
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      // The held operation keeps the activity bar animating, so settling is
      // not available; pump enough frames for the first layout instead.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }
    return effective;
  }

  Finder navigationEntry(String label) =>
      find.widgetWithText(ShadButton, label);

  ShadButton navigationButton(WidgetTester tester, String label) =>
      tester.widget<ShadButton>(navigationEntry(label));

  /// The format entries in the order the reference lists them.
  const formatLabels = ['EPUB', 'PDF', 'CBZ'];

  /// The selected entry paints the accent-soft surface and the accent text.
  void expectSelected(WidgetTester tester, String label) {
    final button = navigationButton(tester, label);
    expect(button.backgroundColor, ShosaiTokens.appAccentSoft);
    expect(button.foregroundColor, ShosaiTokens.appAccent);
  }

  void expectUnselected(WidgetTester tester, String label) {
    final button = navigationButton(tester, label);
    expect(button.backgroundColor, isNull);
    expect(button.foregroundColor, ShosaiTokens.appText);
  }

  /// True when [label]'s entry is the focused element.
  bool isFocused(WidgetTester tester, String label) =>
      tester
          .getSemantics(find.text(label))
          .getSemanticsData()
          .flagsCollection
          .isFocused ==
      ui.Tristate.isTrue;

  /// Tabs forward until [label]'s entry owns focus.
  Future<void> tabTo(WidgetTester tester, String label) async {
    for (var step = 0; step < 12; step += 1) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      if (isFocused(tester, label)) return;
    }
    fail('focus never reached $label');
  }

  /// The focus ring a focused entry paints, or null when it paints none.
  ///
  /// The decorator keeps its outward-border painter mounted while unfocused and
  /// gives it a zero-width border, so the ring is only reported when it has a
  /// visible width and colour.
  ShadOutwardBorderPainter? focusRing(WidgetTester tester, String label) {
    final paints = find.descendant(
      of: navigationEntry(label),
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is CustomPaint &&
            widget.foregroundPainter is ShadOutwardBorderPainter,
      ),
    );
    if (paints.evaluate().isEmpty) return null;
    final painter =
        tester.widget<CustomPaint>(paints.first).foregroundPainter
            as ShadOutwardBorderPainter;
    final side = painter.border.top;
    return side.width > 0 && side.color.a > 0 ? painter : null;
  }

  /// The painted color at [point] in the captured frame.
  ///
  /// The point is inside the entry's surface and clear of its label, which the
  /// navigation entry lays out at its leading edge.
  Future<Color> paintedColorAt(WidgetTester tester, Offset point) async {
    final rgba = await captureHarnessRgba(tester);
    final width =
        tester.view.physicalSize.width ~/ tester.view.devicePixelRatio;
    final x = (point.dx * tester.view.devicePixelRatio).round();
    final y = (point.dy * tester.view.devicePixelRatio).round();
    final offset = (y * width + x) * 4;
    return Color.fromARGB(
      rgba[offset + 3],
      rgba[offset],
      rgba[offset + 1],
      rgba[offset + 2],
    );
  }

  /// Hovers [finder] with a real mouse pointer and returns the painted color
  /// inside its surface, clear of the label.
  Future<Color> hoverPaintedSurface(WidgetTester tester, Finder finder) async {
    final rect = tester.getRect(finder);
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: rect.center);
    addTearDown(gesture.removePointer);
    await tester.pump();
    await gesture.moveTo(rect.center);
    await tester.pump();
    return paintedColorAt(tester, Offset(rect.right - 6, rect.center.dy));
  }

  group('wide layout', () {
    testWidgets('the collection sidebar carries the filters and Settings', (
      tester,
    ) async {
      await pumpLibrary(tester, const Size(1280, 800));

      expect(find.byType(LibrarySidebar), findsOneWidget);
      expect(find.byType(LibraryFilterRow), findsNothing);
      expect(find.byType(Drawer), findsNothing);

      final sidebar = tester.getRect(find.byType(LibrarySidebar));
      expect(sidebar.width, ShosaiTokens.layoutLibrarySidebarWidth);
      expect(find.text('COLLECTION'), findsOneWidget);

      for (final label in ['All books', ...formatLabels, 'Settings']) {
        expect(
          navigationEntry(label),
          findsOneWidget,
          reason: '$label is reachable from the sidebar',
        );
      }

      // The format group sits under the collection label and Settings is
      // pinned to the sidebar's bottom (Iced's composition).
      final all = tester.getRect(navigationEntry('All books'));
      final settings = tester.getRect(navigationEntry('Settings'));
      final label = tester.getRect(find.text('COLLECTION'));
      expect(label.bottom, lessThanOrEqualTo(all.top));
      expect(settings.top, greaterThan(all.bottom));
      expect(
        sidebar.bottom - settings.bottom,
        22,
        reason: 'Settings sits inside the sidebar padding at its bottom',
      );
    });

    testWidgets('the header carries the title, subtitle, search and action', (
      tester,
    ) async {
      await pumpLibrary(tester, const Size(1280, 800));

      final title = tester.renderObject<RenderParagraph>(find.text('Library'));
      expect(title.text.style?.fontSize, ShosaiTokens.typeSize26);
      final subtitle = tester.renderObject<RenderParagraph>(
        find.text('Your private reading room'),
      );
      expect(subtitle.text.style?.fontSize, ShosaiTokens.typeSize12);
      expect(subtitle.text.style?.color, ShosaiTokens.appTextMuted);

      final search = tester.getRect(find.byType(ShadInput));
      expect(
        search.width,
        ShosaiTokens.layoutLibraryHeaderSearchMaxWidth,
        reason: 'the wide reference reaches the 380 px search cap',
      );
      final header = tester.getRect(find.byType(LibraryHeader));
      expect(search.left, greaterThan(header.left + 100));

      // The add-books action is a header control; the floating overlay that
      // used to cover the collection is gone (2B deferred overlap defect).
      expect(
        find.ancestor(
          of: find.text('Add books'),
          matching: find.byType(LibraryHeader),
        ),
        findsOneWidget,
      );
      expect(find.byType(FloatingActionButton), findsNothing);
      final action = tester.getRect(navigationEntry('Add books'));
      expect(action.right, closeTo(header.right - 20, 1));
    });

    testWidgets('the header action never overlaps the collection', (
      tester,
    ) async {
      // The 2B deferred defect: at 900x700 with 200% Japanese text the
      // floating add-books button covered the bottom-right card metadata.
      await pumpLibrary(tester, const Size(900, 700), textScale: 2);

      final header = tester.getRect(find.byType(LibraryHeader));
      final grid = tester.getRect(find.byType(GridView));
      expect(
        header.bottom,
        lessThanOrEqualTo(grid.top),
        reason: 'the header action cannot cover the collection',
      );
      expect(find.byType(FloatingActionButton), findsNothing);
    });
  });

  group('compact layout', () {
    testWidgets('the filter row carries every entry and Settings', (
      tester,
    ) async {
      await pumpLibrary(tester, const Size(390, 780));

      expect(find.byType(LibraryFilterRow), findsOneWidget);
      expect(find.byType(LibrarySidebar), findsNothing);
      expect(find.byType(Drawer), findsNothing);

      for (final label in ['All', ...formatLabels, 'Settings']) {
        expect(
          navigationEntry(label),
          findsOneWidget,
          reason: '$label is directly accessible in the filter row',
        );
      }
      expect(find.text('All books'), findsNothing);
    });

    testWidgets('every entry activates without a drawer', (tester) async {
      final bridge = await pumpLibrary(tester, const Size(390, 780));

      await tester.tap(navigationEntry('Settings'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Reader theme'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(navigationEntry('CBZ'));
      await tester.pumpAndSettle();
      expectSelected(tester, 'CBZ');
      expect(
        find.text('Mixed Script Atlas: 東京・Wien・São Paulo'),
        findsOneWidget,
        reason: 'the CBZ filter selects the CBZ book',
      );
      expect(bridge.removeCalls, 0);
    });
  });

  group('breakpoint', () {
    for (final (width, wide) in const [
      (759.0, false),
      (760.0, true),
      (761.0, true),
    ]) {
      testWidgets('width $width switches at the 760 px breakpoint', (
        tester,
      ) async {
        await pumpLibrary(tester, Size(width, 700));

        expect(
          find.byType(LibrarySidebar),
          wide ? findsOneWidget : findsNothing,
        );
        expect(
          find.byType(LibraryFilterRow),
          wide ? findsNothing : findsOneWidget,
        );
        expect(find.text(wide ? 'All books' : 'All'), findsOneWidget);
        expect(navigationEntry('Settings'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('query persistence', () {
    testWidgets('crossing the breakpoint keeps the search and its filter', (
      tester,
    ) async {
      final bridge = await pumpLibrary(tester, const Size(760, 700));

      // The book the query excludes is established as present first, so its
      // absence after the query is filtering rather than a lazy grid that has
      // not built it.
      expect(find.text('海辺の図書館 — 失われた書架をめぐる長い旅路'), findsOneWidget);
      await tester.enterText(find.byType(ShadInput), 'Quiet');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(find.text('The Quiet Cartographer'), findsOneWidget);
      expect(find.text('海辺の図書館 — 失われた書架をめぐる長い旅路'), findsNothing);
      expect(bridge, isNotNull);

      // The layout switch recreates the input; the query it filters by has to
      // survive with it, or the field would look empty over a filtered list.
      tester.view.physicalSize = const Size(759, 700);
      await tester.pumpAndSettle();
      expect(find.byType(LibraryFilterRow), findsOneWidget);
      expect(
        tester.widget<EditableText>(find.byType(EditableText)).controller.text,
        'Quiet',
        reason: 'the recreated field shows the query it filters by',
      );
      expect(find.text('The Quiet Cartographer'), findsOneWidget);
      expect(find.text('海辺の図書館 — 失われた書架をめぐる長い旅路'), findsNothing);

      tester.view.physicalSize = const Size(760, 700);
      await tester.pumpAndSettle();
      expect(find.byType(LibrarySidebar), findsOneWidget);
      expect(
        tester.widget<EditableText>(find.byType(EditableText)).controller.text,
        'Quiet',
      );
      expect(find.text('The Quiet Cartographer'), findsOneWidget);
      expect(find.text('海辺の図書館 — 失われた書架をめぐる長い旅路'), findsNothing);
    });
  });

  group('search width', () {
    for (final width in const [600.0, 759.0, 1280.0]) {
      testWidgets('the search stays capped at 380 px at $width', (
        tester,
      ) async {
        await pumpLibrary(tester, Size(width, 700));

        final search = tester.getSize(find.byType(ShadInput));
        expect(
          search.width,
          lessThanOrEqualTo(ShosaiTokens.layoutLibraryHeaderSearchMaxWidth),
          reason: 'the search is capped at the reference maximum',
        );
        if (width == 1280) {
          expect(search.width, ShosaiTokens.layoutLibraryHeaderSearchMaxWidth);
        }
      });
    }
  });

  group('dark palette', () {
    testWidgets('the header and sidebar keep the mapped dark surfaces', (
      tester,
    ) async {
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      await pumpLibrary(tester, const Size(1280, 800));

      final dark = shosaiShadTheme(Brightness.dark);
      final scheme = dark.colorScheme;
      expect(
        ShadTheme.of(tester.element(find.byType(LibraryHeader))).brightness,
        Brightness.dark,
      );
      final headerRect = tester.getRect(find.byType(LibraryHeader));
      final headerSurface = await paintedColorAt(
        tester,
        Offset(headerRect.right - 8, headerRect.top + 8),
      );
      expect(
        headerSurface.toARGB32(),
        scheme.card.toARGB32(),
        reason: 'the header paints the mapped dark surface, not the light one',
      );
      final sidebarSurface = await paintedColorAt(
        tester,
        tester.getRect(find.byType(LibrarySidebar)).bottomLeft +
            const Offset(8, -8),
      );
      expect(sidebarSurface.toARGB32(), scheme.secondary.toARGB32());

      final selected = navigationButton(tester, 'All books');
      expect(selected.backgroundColor, scheme.selection);
      expect(selected.foregroundColor, scheme.accentForeground);
      expect(
        navigationButton(tester, 'EPUB').foregroundColor,
        scheme.foreground,
      );
      expect(selected.foregroundColor, isNot(selected.backgroundColor));
    });
  });

  group('primary action interaction', () {
    testWidgets('the light theme paints the reference hovered fill', (
      tester,
    ) async {
      await pumpLibrary(tester, const Size(1280, 800));

      final hovered = await hoverPaintedSurface(
        tester,
        navigationEntry('Add books'),
      );
      expect(
        hovered.toARGB32(),
        ShosaiTokens.appAccentHovered.toARGB32(),
        reason: 'the light theme uses the pinned hovered fill',
      );
    });

    testWidgets('the dark theme keeps a legible hovered primary action', (
      tester,
    ) async {
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      await pumpLibrary(tester, const Size(1280, 800));

      final hovered = await hoverPaintedSurface(
        tester,
        navigationEntry('Add books'),
      );
      expect(
        hovered.toARGB32(),
        isNot(ShosaiTokens.appAccentHovered.toARGB32()),
        reason:
            'the light hovered fill cannot carry the dark theme\'s dark '
            'primary label',
      );
      expect(
        hovered.computeLuminance(),
        greaterThan(0.5),
        reason: 'the hovered dark action stays a light surface',
      );
    });

    testWidgets(
      'the dark cancel action keeps a legible hovered surface',
      (tester) async {
        tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
        addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
        final picker = _PickerStub(tester, const ['/books/new.epub']);
        final bridge = _ControlledBridge();
        bridge.importCompleter = Completer<FlutterImportReport>();
        await pumpControlledLibrary(
          tester,
          const Size(1280, 800),
          bridge: bridge,
        );

        await tester.tap(navigationEntry('Add books'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(find.text('Choose files'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(find.text('Import'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(picker.calls, ['openFile']);
        expect(navigationEntry('Cancel'), findsOneWidget);

        final hovered = await hoverPaintedSurface(
          tester,
          navigationEntry('Cancel'),
        );
        expect(hovered.computeLuminance(), greaterThan(0.5));

        bridge.importCompleter!.complete(
          FlutterImportReport(
            imported: BigInt.zero,
            failed: BigInt.zero,
            cancelled: true,
            items: const [],
          ),
        );
        await tester.pumpAndSettle();
      },
      variant: TargetPlatformVariant.only(TargetPlatform.linux),
    );
  });

  group('selected state', () {
    testWidgets('exactly one filter is selected and it is visually distinct', (
      tester,
    ) async {
      await pumpLibrary(tester, const Size(1280, 800));

      expectSelected(tester, 'All books');
      for (final label in [...formatLabels, 'Settings']) {
        expectUnselected(tester, label);
      }

      final selectedSurface = await paintedColorAt(
        tester,
        tester.getRect(navigationEntry('All books')).centerRight -
            const Offset(6, 0),
      );
      final unselectedSurface = await paintedColorAt(
        tester,
        tester.getRect(navigationEntry('EPUB')).centerRight -
            const Offset(6, 0),
      );
      expect(
        selectedSurface.toARGB32(),
        ShosaiTokens.appAccentSoft.toARGB32(),
        reason: 'the selected entry paints the accent-soft surface',
      );
      expect(
        unselectedSurface.toARGB32(),
        ShosaiTokens.appSidebarBackground.toARGB32(),
        reason: 'an unselected entry keeps the sidebar surface',
      );
    });

    testWidgets('selecting another format moves the selection exclusively', (
      tester,
    ) async {
      await pumpLibrary(tester, const Size(1280, 800));

      await tester.tap(navigationEntry('PDF'));
      await tester.pumpAndSettle();

      expectSelected(tester, 'PDF');
      expectUnselected(tester, 'All books');
      expectUnselected(tester, 'EPUB');
      expectUnselected(tester, 'CBZ');
      expect(
        find.text(
          'Donaudampfschifffahrtsgesellschaftskapitaenskajuettenfenster',
        ),
        findsOneWidget,
        reason: 'the PDF filter selects the PDF book',
      );
    });
  });

  group('keyboard', () {
    testWidgets('entries are reachable in order and activate with Enter', (
      tester,
    ) async {
      await pumpLibrary(tester, const Size(1280, 800));

      // The entries are reached in the reference's order. The collection's own
      // controls sit between them in the traversal (reading order interleaves
      // the sidebar with the grid), so the order is asserted over the sequence
      // the traversal produces rather than over consecutive Tabs.
      final order = ['All books', ...formatLabels, 'Settings'];
      final reached = <String>[];
      for (
        var step = 0;
        step < 26 && reached.length < order.length;
        step += 1
      ) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        for (final label in order) {
          if (!reached.contains(label) && isFocused(tester, label)) {
            reached.add(label);
            final ring = focusRing(tester, label);
            expect(
              ring,
              isNotNull,
              reason: '$label paints the shared focus ring while focused',
            );
            expect(ring!.border.top.color, ShosaiTokens.appAccent);
          }
        }
      }
      expect(
        reached,
        order,
        reason: 'every entry is reachable, in the reference order',
      );

      await tabTo(tester, 'PDF');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expectSelected(tester, 'PDF');
    });

    testWidgets('entries activate with Space', (tester) async {
      await pumpLibrary(tester, const Size(390, 780));

      await tabTo(tester, 'EPUB');
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();

      expectSelected(tester, 'EPUB');
    });

    testWidgets('focus leaves no ring on an entry it moved away from', (
      tester,
    ) async {
      await pumpLibrary(tester, const Size(1280, 800));

      await tabTo(tester, 'EPUB');
      expect(focusRing(tester, 'EPUB'), isNotNull);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();

      expect(isFocused(tester, 'PDF'), isTrue);
      expect(
        focusRing(tester, 'EPUB'),
        isNull,
        reason: 'the entry that lost focus paints no ring',
      );
      expect(focusRing(tester, 'PDF'), isNotNull);
    });
  });

  group('large text', () {
    testWidgets('compact 200% text keeps every label inside its button', (
      tester,
    ) async {
      await pumpLibrary(tester, const Size(390, 780), textScale: 2);

      for (final label in ['All', ...formatLabels, 'Settings']) {
        final entry = navigationEntry(label);
        expect(entry, findsOneWidget);
        final button = tester.widget<ShadButton>(entry);
        expect(button.enabled, isTrue, reason: '$label stays enabled');
        expect(button.onPressed, isNotNull, reason: '$label stays activatable');

        final text = tester.renderObject<RenderParagraph>(find.text(label));
        expect(
          text.size.height,
          greaterThanOrEqualTo(text.textSize.height),
          reason: '$label keeps its line box inside the button',
        );
        expect(
          text.didExceedMaxLines,
          isFalse,
          reason:
              '$label is short enough to be fully visible at 200% text; an '
              'ellipsized label would mean the row hid part of it',
        );
        // The label's line box is exactly its line height, so a glyph may
        // paint into the button's padding; what must not happen is the button
        // cutting the label, which the detectors report and this containment
        // check pins.
        final ink = await tester.runAsync(() => measureHarnessInk(text));
        expect(ink, isNotNull);
        expect(ink!.unmeasured, isFalse);
        final visible = ink.visible;
        expect(visible, isNotNull);
        final origin = tester.getTopLeft(find.text(label));
        final buttonRect = tester.getRect(entry);
        expect(
          buttonRect.contains(origin + visible!.center),
          isTrue,
          reason: '$label paints inside its button',
        );
        expect(
          buttonRect.contains(origin + visible.bottomLeft) &&
              buttonRect.contains(origin + visible.topRight),
          isTrue,
          reason: '$label is not cut by the button',
        );
      }

      // The row wraps instead of clipping or dropping an entry: Settings moves
      // to a second line and stays directly reachable.
      final all = tester.getRect(navigationEntry('All'));
      final settings = tester.getRect(navigationEntry('Settings'));
      expect(settings.top, greaterThan(all.top));
      expect(
        tester.getRect(find.byType(LibraryFilterRow)).height,
        greaterThan(all.height),
      );

      final defects = await findRenderDefects(tester);
      expectOnlyKnownDefects(defects, const <KnownRenderDefect>[]);

      await tester.tap(navigationEntry('Settings'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Reader theme'), findsOneWidget);
    });

    testWidgets('a Japanese label keeps its ink inside the button', (
      tester,
    ) async {
      // The Flutter interface is English until package 6B owns localization;
      // this pins the component behavior a Japanese label will need.
      await tester.pumpWidget(
        productionShell(
          home: Scaffold(
            body: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(2)),
              child: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 184,
                  child: LibraryNavigationButton(
                    label: '設定と書棚',
                    selected: true,
                    onPressed: () {},
                    fillWidth: true,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final text = tester.renderObject<RenderParagraph>(find.text('設定と書棚'));
      expect(
        shosaiInterfaceFontForText('設定と書棚'),
        shosaiJapaneseInterfaceFontFamily,
        reason: 'the label selects the bundled face that covers it',
      );
      expect(text.text.style?.fontFamily, shosaiJapaneseInterfaceFontFamily);
      expect(
        text.size.height,
        greaterThanOrEqualTo(text.textSize.height),
        reason: 'the label keeps its whole line box',
      );
      final ink = await tester.runAsync(() => measureHarnessInk(text));
      expect(ink, isNotNull);
      expect(ink!.unmeasured, isFalse);
      expect(
        classifyInkOverhang(
          visibleInk: ink.visible,
          bodyInk: ink.body,
          region: Offset.zero & text.size,
        ),
        isNot(InkOverhangKind.material),
        reason:
            'no glyph body may leave the label box: a fallback run positioned '
            'against the primary font metrics cuts the glyphs',
      );
      final defects = await findRenderDefects(tester);
      expectOnlyKnownDefects(defects, const <KnownRenderDefect>[]);
    });
  });

  group('operation cancellation', () {
    testWidgets(
      'the header cancels an import that is in flight',
      (tester) async {
        final picker = _PickerStub(tester, const ['/books/new.epub']);
        final bridge = _ControlledBridge();
        bridge.importCompleter = Completer<FlutterImportReport>();
        await pumpControlledLibrary(
          tester,
          const Size(1280, 800),
          bridge: bridge,
        );

        await tester.tap(navigationEntry('Add books'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(find.text('Choose files'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(find.text('Import'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        // The import is in flight with no dialog covering the header, and the
        // add-books action is the cancel action for it.
        expect(picker.calls, ['openFile']);
        expect(bridge.importCalls, 1);
        expect(navigationEntry('Cancel'), findsOneWidget);
        expect(navigationEntry('Add books'), findsNothing);
        expect(
          find.byTooltip('Cancel operation'),
          findsNothing,
          reason: 'the import owns the header cancel action',
        );

        await tester.tap(navigationEntry('Cancel'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        expect(
          bridge.cancelled,
          contains(bridge.importCancellations.single),
          reason: 'the header action cancels the import cancellation token',
        );

        bridge.importCompleter!.complete(
          FlutterImportReport(
            imported: BigInt.zero,
            failed: BigInt.zero,
            cancelled: true,
            items: const [],
          ),
        );
        await tester.pumpAndSettle();
        expect(navigationEntry('Add books'), findsOneWidget);
        expect(navigationEntry('Cancel'), findsNothing);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.linux),
    );

    testWidgets('a load keeps its own cancel action', (tester) async {
      final bridge = _ControlledBridge();
      bridge.pageCompleter = Completer<FlutterLibraryPage>();
      await pumpControlledLibrary(
        tester,
        const Size(1280, 800),
        bridge: bridge,
        settle: false,
      );

      // The initial load is in flight: the add-books action is disabled and
      // the retained cancel action is present.
      expect(find.byTooltip('Cancel operation'), findsOneWidget);
      expect(navigationButton(tester, 'Add books').enabled, isFalse);
      expect(navigationButton(tester, 'Add books').onPressed, isNull);
      await tester.tap(navigationEntry('Add books'));
      await tester.pump();
      expect(
        bridge.importCalls,
        0,
        reason: 'a disabled add-books action starts no import',
      );

      await tester.tap(find.byTooltip('Cancel operation'));
      await tester.pump();
      expect(bridge.cancelled, isNotEmpty);

      bridge.pageCompleter!.complete(
        FlutterLibraryPage(books: bridge.books, hasMore: false),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('Cancel operation'), findsNothing);
      expect(navigationButton(tester, 'Add books').enabled, isTrue);
      expect(navigationButton(tester, 'Add books').onPressed, isNotNull);
    });
  });

  group('import state', () {
    test('the flag follows the import effect and survives a load', () async {
      final bridge = _ControlledBridge();
      bridge.importCompleter = Completer<FlutterImportReport>();
      final controller = LibraryController(
        bridge: bridge,
        confirmRemoval: (_) async => true,
        pickImport: () async => const LibraryImportSelection(
          paths: ['/books/new.epub'],
          managed: true,
        ),
        openBook: (_) async {},
        drainReaderSaves: (_) async {},
        editSettings: (_) async => null,
      );
      final notifications = <({bool busy, bool importing})>[];
      controller.addListener(
        () => notifications.add((
          busy: controller.model.busy,
          importing: controller.model.importing,
        )),
      );

      controller.dispatch(const LibraryStarted());
      await _waitUntil(() => controller.model.loaded);
      notifications.clear();

      controller.dispatch(const LibraryImportRequested());
      await _waitUntil(() => bridge.importCalls == 1);

      // The notification that starts the import already carries the flag, so a
      // listener never observes a busy import that is not the import state.
      expect(notifications.first, (busy: true, importing: true));
      expect(controller.model.importing, isTrue);

      // A load that starts while the import is in flight leaves it alone.
      controller.dispatch(const LibraryQueryChanged('quiet'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await _waitUntil(() => bridge.pageCalls >= 2);
      expect(controller.model.importing, isTrue);

      // Terminal completion clears it and the library is idle again.
      bridge.importCompleter!.complete(
        FlutterImportReport(
          imported: BigInt.zero,
          failed: BigInt.zero,
          cancelled: false,
          items: const [],
        ),
      );
      await _waitUntil(() => !controller.model.importing);
      expect(controller.model.busy, isFalse);

      controller.dispose();
      await _waitUntil(() => bridge.isDisposed);
    });
  });

  group('short windows', () {
    testWidgets('keyboard focus reaches Settings and paints its ring', (
      tester,
    ) async {
      await pumpLibrary(tester, const Size(900, 400), textScale: 2);

      // Traversal scrolls the focused entry into view; the ring it paints is
      // outside the entry, so it must not be clipped by the sidebar viewport.
      for (var step = 0; step < 26; step += 1) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        if (isFocused(tester, 'Settings')) break;
      }
      expect(
        isFocused(tester, 'Settings'),
        isTrue,
        reason: 'traversal reaches Settings without scrolling the sidebar',
      );
      final sidebar = tester.getRect(find.byType(LibrarySidebar));
      final settings = tester.getRect(navigationEntry('Settings'));
      expect(
        sidebar.contains(settings.center),
        isTrue,
        reason: 'the focused entry is scrolled into view',
      );
      // The shared focus ring paints outside the entry, so the reveal has to
      // leave clearance on every side the ring paints on.
      final ring = ShosaiTokens.appAccent.toARGB32();
      expect(
        (await paintedColorAt(
          tester,
          Offset(settings.left - 3, settings.center.dy),
        )).toARGB32(),
        ring,
        reason: 'the leading ring segment is painted, not clipped',
      );
      expect(
        (await paintedColorAt(
          tester,
          Offset(settings.center.dx, settings.bottom + 3),
        )).toARGB32(),
        ring,
        reason: 'the trailing ring segment is painted, not clipped',
      );

      // The reverse direction reveals an entry above the viewport, which is
      // the other edge the ring can be clipped on.
      String? reversed;
      for (var step = 0; step < 8 && reversed == null; step += 1) {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.pump();
        for (final label in ['Settings', ...formatLabels, 'All books']) {
          if (isFocused(tester, label)) {
            reversed = label;
            break;
          }
        }
      }
      expect(reversed, isNotNull, reason: 'reverse traversal reaches an entry');
      final reversedRect = tester.getRect(navigationEntry(reversed!));
      expect(
        (await paintedColorAt(
          tester,
          Offset(reversedRect.center.dx, reversedRect.top - 3),
        )).toARGB32(),
        ring,
        reason: 'the leading ring segment of $reversed is painted',
      );
      expect(
        sidebar.contains(reversedRect.center),
        isTrue,
        reason: '$reversed is scrolled into view',
      );

      await tabTo(tester, 'Settings');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Reader theme'), findsOneWidget);
    });

    testWidgets('a short sidebar keeps Settings reachable', (tester) async {
      await pumpLibrary(tester, const Size(900, 400), textScale: 2);

      expect(find.byType(LibrarySidebar), findsOneWidget);
      expect(navigationEntry('Settings'), findsOneWidget);
      final defects = await findRenderDefects(tester);
      expectOnlyKnownDefects(defects, const <KnownRenderDefect>[]);

      await tester.scrollUntilVisible(
        navigationEntry('Settings'),
        80,
        scrollable: find.descendant(
          of: find.byType(LibrarySidebar),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(navigationEntry('Settings'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Reader theme'), findsOneWidget);
    });
  });

  group('interface localization', () {
    testWidgets(
      'a Japanese interface translates the navigation, its semantics and its tooltips',
      (tester) async {
        await pumpLibrary(
          tester,
          const Size(1280, 800),
          locale: const Locale('ja'),
        );

        // Header, sidebar, actions and the search placeholder come from the
        // generated catalogs.
        expect(find.text('ライブラリ'), findsOneWidget);
        expect(find.text('自分だけの読書室'), findsOneWidget);
        expect(find.text('タイトル・著者を検索...'), findsOneWidget);
        expect(find.text('コレクション'), findsOneWidget);
        expect(navigationEntry('すべての本'), findsOneWidget);
        expect(navigationEntry('設定'), findsOneWidget);
        expect(navigationEntry('本を追加'), findsOneWidget);
        expect(find.byTooltip('ライブラリを更新'), findsOneWidget);
        // Format entries stay Latin in both locales, as in the reference.
        for (final label in const ['EPUB', 'PDF', 'CBZ']) {
          expect(navigationEntry(label), findsOneWidget);
        }
        // The English chrome is gone rather than merely accompanied.
        for (final label in const [
          'Library',
          'Your private reading room',
          'COLLECTION',
          'All books',
          'Settings',
          'Add books',
        ]) {
          expect(
            find.text(label),
            findsNothing,
            reason: '$label is not shown in a Japanese interface',
          );
        }
        // Controls announce themselves in the selected language.
        expect(find.bySemanticsLabel('本を追加'), findsOneWidget);
        expect(find.bySemanticsLabel('すべての本'), findsOneWidget);
        expect(find.bySemanticsLabel('設定'), findsOneWidget);
      },
    );

    testWidgets('a Japanese interface translates the load cancel action', (
      tester,
    ) async {
      final bridge = _ControlledBridge();
      bridge.pageCompleter = Completer<FlutterLibraryPage>();
      await pumpControlledLibrary(
        tester,
        const Size(1280, 800),
        bridge: bridge,
        settle: false,
        locale: const Locale('ja'),
      );

      expect(find.byTooltip('操作をキャンセル'), findsOneWidget);
      expect(find.byTooltip('Cancel operation'), findsNothing);

      bridge.pageCompleter!.complete(
        FlutterLibraryPage(books: bridge.books, hasMore: false),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('操作をキャンセル'), findsNothing);
    });

    testWidgets('an unsupported system locale falls back to English', (
      tester,
    ) async {
      tester.platformDispatcher.localesTestValue = const [Locale('fr')];
      addTearDown(tester.platformDispatcher.clearLocalesTestValue);

      await pumpLibrary(tester, const Size(1280, 800));

      expect(find.text('Library'), findsOneWidget);
      expect(navigationEntry('Settings'), findsOneWidget);
      expect(find.text('ライブラリ'), findsNothing);
    });

    testWidgets('a supported system locale is used when none is injected', (
      tester,
    ) async {
      tester.platformDispatcher.localesTestValue = const [Locale('ja')];
      addTearDown(tester.platformDispatcher.clearLocalesTestValue);

      await pumpLibrary(tester, const Size(1280, 800));

      expect(find.text('ライブラリ'), findsOneWidget);
      expect(navigationEntry('設定'), findsOneWidget);
    });

    testWidgets('switching the interface language keeps the library state', (
      tester,
    ) async {
      // The query and the selected format live in the controller, so a language
      // change must not reset either of them.
      final locale = ValueNotifier<Locale?>(const Locale('en'));
      addTearDown(locale.dispose);
      final bridge = HarnessBridge(
        books: harnessLibraryBooks(),
        covers: harnessCovers(),
      );
      const view = HarnessView(size: Size(1280, 800));
      view.apply(tester);
      await renderHarnessState(
        tester,
        ValueListenableBuilder<Locale?>(
          valueListenable: locale,
          builder: (context, value, _) => productionShell(
            locale: value,
            home: ProductShell(
              bridgeFactory: () => bridge,
              readerBuilder: (_, _, _, _, _, _) => const SizedBox(),
            ),
          ),
        ),
        ready: () => harnessImagesReady(tester),
      );

      await tester.enterText(find.byType(ShadInput), 'Donaudampf');
      await tester.pumpAndSettle();
      await tester.tap(navigationEntry('PDF'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Donaudampfschifffahrtsgesellschaftskapitaenskajuettenfenster',
        ),
        findsOneWidget,
      );
      expect(find.text('The Quiet Cartographer'), findsNothing);

      locale.value = const Locale('ja');
      await tester.pumpAndSettle();

      // The interface changed, and the query and the filter survived it.
      expect(find.text('ライブラリ'), findsOneWidget);
      expect(
        find.text(
          'Donaudampfschifffahrtsgesellschaftskapitaenskajuettenfenster',
        ),
        findsOneWidget,
        reason: 'the query still filters after the language change',
      );
      expect(
        find.text('The Quiet Cartographer'),
        findsNothing,
        reason: 'the PDF filter still applies after the language change',
      );
      expect(
        tester.widget<ShadButton>(navigationEntry('PDF')).backgroundColor,
        ShosaiTokens.appAccentSoft,
        reason: 'the selected format survives the language change',
      );
      expect(
        tester.widget<ShadButton>(navigationEntry('すべての本')).backgroundColor,
        isNull,
        reason: 'the selection stays exclusive after the change',
      );
    });
  });
}
