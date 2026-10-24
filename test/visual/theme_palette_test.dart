import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shosai_flutter/main.dart';
import 'package:shosai_flutter/reader/view.dart';
import 'package:shosai_flutter/core/bridge.dart';
import 'package:shosai_flutter/theme_tokens.dart';

import '../support/production_shell_harness.dart';

/// Package 2C palette renders (`2C-PALETTE`).
///
/// Every state renders the production shell, asserts that the mapped palette is
/// what the tree actually uses, and captures an artifact for inspection. The
/// application palette is checked in light and dark (`XA-05`, `LB-23`) and the
/// reader document palettes in light, dark and sepia (`XA-11`).
void main() {
  setUpAll(loadHarnessFonts);

  Future<void> render(
    WidgetTester tester,
    String name,
    HarnessView view,
    Widget widget, {
    required bool Function() ready,
    Map<String, Object?> metadata = const {},
  }) async {
    view.apply(tester);
    await renderHarnessState(tester, widget, ready: ready);
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
  }

  group('application palette renders', () {
    testWidgets('light library uses the mapped application palette', (
      tester,
    ) async {
      final bridge = HarnessBridge(
        books: harnessLibraryBooks(),
        covers: harnessCovers(),
      );
      await render(
        tester,
        '2c-library-light-1280',
        const HarnessView(size: Size(1280, 800)),
        productionApp(bridgeFactory: () => bridge),
        ready: () => harnessImagesReady(tester),
        metadata: const <String, Object?>{'palette': 'application-light'},
      );
      final context = tester.element(find.byType(Scaffold).first);
      expect(
        ShadTheme.of(context).colorScheme.background,
        ShosaiTokens.appBackground,
      );
      expect(ShadTheme.of(context).colorScheme.primary, ShosaiTokens.appAccent);
      expect(Theme.of(context).colorScheme.surface, ShosaiTokens.appBackground);
      expect(
        Theme.of(context).scaffoldBackgroundColor,
        ShosaiTokens.appBackground,
      );
    });

    testWidgets('dark library uses the mapped dark palette', (tester) async {
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      final bridge = HarnessBridge(
        books: harnessLibraryBooks(),
        covers: harnessCovers(),
      );
      await render(
        tester,
        '2c-library-dark-1280',
        const HarnessView(size: Size(1280, 800)),
        productionApp(bridgeFactory: () => bridge),
        ready: () => harnessImagesReady(tester),
        metadata: const <String, Object?>{'palette': 'application-dark'},
      );
      final context = tester.element(find.byType(Scaffold).first);
      expect(ShadTheme.of(context).brightness, Brightness.dark);
      expect(
        ShadTheme.of(context).colorScheme.background,
        ShosaiTokens.appDarkBackground,
      );
      expect(
        Theme.of(context).colorScheme.surface,
        ShosaiTokens.appDarkBackground,
      );
      expect(
        Theme.of(context).colorScheme.onSurface,
        ShosaiTokens.appDarkForeground,
      );
    });
  });

  group('reader palette renders', () {
    /// The reader palettes under test, with the document colors each maps.
    const palettes = <String, ({Color background, Color foreground})>{
      'light': (
        background: ShosaiTokens.readerLightBackground,
        foreground: ShosaiTokens.readerLightText,
      ),
      'dark': (
        background: ShosaiTokens.readerDarkBackground,
        foreground: ShosaiTokens.readerDarkText,
      ),
      'sepia': (
        background: ShosaiTokens.readerSepiaBackground,
        foreground: ShosaiTokens.readerSepiaText,
      ),
    };

    for (final (entry, format) in [
      for (final entry in palettes.entries)
        for (final format in ['epub', 'pdf']) (entry, format),
    ]) {
      testWidgets('$format reader renders under the ${entry.key} palette', (
        tester,
      ) async {
        final bridge = HarnessBridge(books: harnessLibraryBooks());
        await render(
          tester,
          '2c-reader-$format-${entry.key}-1280',
          const HarnessView(size: Size(1280, 800)),
          productionShell(
            home: ReaderScreen(
              bridge: bridge,
              initialPath: '/books/umibe.$format',
              initialBookId: format == 'epub' ? 2 : 3,
              initialSettings: FlutterReaderSettings(
                continuous: false,
                theme: entry.key,
                epubFontSize: 18,
                epubLineSpacing: 1.6,
                pdfZoom: 0,
              ),
            ),
          ),
          ready: () => harnessReaderPageReady(tester),
          metadata: <String, Object?>{'palette': 'reader-${entry.key}'},
        );

        final context = tester.element(find.byType(Scaffold).first);
        final painter =
            tester
                    .widget<CustomPaint>(
                      find.byWidgetPredicate(
                        (widget) =>
                            widget is CustomPaint &&
                            widget.painter is PagePainter,
                      ),
                    )
                    .painter!
                as PagePainter;
        // The document surface is painted from the mapped reader palette, not
        // from a Flutter default: the page background and the recolored EPUB
        // text both come from the tokens.
        expect(painter.backgroundColor, entry.value.background);
        expect(painter.foregroundColor, entry.value.foreground);
        expect(painter.recolorImage, format == 'epub');
        if (format == 'epub') {
          final paper = tester.widget<DecoratedBox>(
            find
                .descendant(
                  of: find.byKey(const ValueKey('reader-page')),
                  matching: find.byType(DecoratedBox),
                )
                .first,
          );
          expect(
            (paper.decoration as BoxDecoration).color,
            entry.value.background,
            reason: 'the page paper uses the ${entry.key} palette',
          );
        }
        final dark = entry.key == 'dark';
        expect(
          Theme.of(context).colorScheme.surface,
          dark ? ShosaiTokens.appDarkBackground : ShosaiTokens.appBackground,
        );
        expect(
          Theme.of(context).colorScheme.onSurface,
          dark ? ShosaiTokens.appDarkForeground : ShosaiTokens.appText,
        );
        expect(
          ShadTheme.of(context).brightness,
          dark ? Brightness.dark : Brightness.light,
        );
      });
    }
  });
}
