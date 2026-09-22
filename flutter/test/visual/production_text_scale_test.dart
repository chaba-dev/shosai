import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shosai_flutter/app_theme.dart';

import '../support/production_shell_harness.dart';

/// A synthetic nonlinear text scale, shaped like the platform nonlinear
/// scalers: the rendered size is not one ratio of the requested size, so a
/// control that assumes a single ratio sizes its label wrongly.
class _NonlinearScaler extends TextScaler {
  const _NonlinearScaler();

  @override
  double scale(double fontSize) => fontSize + 20;

  @override
  double get textScaleFactor => 21;
}

/// Text-scale regressions for the production shell.
///
/// A Shad button pins its content inside a `ConstrainedBox` of the size theme's
/// height minus its padding, so a label whose scaled line box is taller than
/// that box is clipped. The production shell must instead grow the control: the
/// theme height stays the floor at 100% text, and the label keeps its whole line
/// box at 200%. The Japanese metadata check pins the other half of the same
/// failure: a fallback run is positioned against the primary font's metrics and
/// leaves the paragraph box, so metadata must select the bundled face that
/// covers it.
void main() {
  setUpAll(loadHarnessFonts);

  Future<void> renderLibrary(WidgetTester tester, HarnessView view) async {
    final bridge = HarnessBridge(
      books: harnessLibraryBooks(),
      covers: harnessCovers(),
    );
    view.apply(tester);
    await renderHarnessState(
      tester,
      productionApp(bridgeFactory: () => bridge),
      ready: () => harnessImagesReady(tester),
    );
  }

  Finder addBooksButton() => find.ancestor(
    of: find.text('Add books'),
    matching: find.byType(ShadButton),
  );

  testWidgets('the add-books button keeps the theme height at 100% text', (
    tester,
  ) async {
    await renderLibrary(tester, const HarnessView(size: Size(390, 780)));

    final theme = ShadTheme.of(tester.element(addBooksButton()));
    expect(
      tester.getSize(addBooksButton()).height,
      theme.buttonSizesTheme.regular!.height,
      reason: 'the button must not change size at the default text scale',
    );
    final label = tester.renderObject<RenderParagraph>(find.text('Add books'));
    expect(label.size.height, greaterThanOrEqualTo(label.textSize.height));
  });

  testWidgets('the add-books label keeps its line box at 200% text', (
    tester,
  ) async {
    await renderLibrary(
      tester,
      const HarnessView(size: Size(390, 780), textScale: 2),
    );

    final label = tester.renderObject<RenderParagraph>(find.text('Add books'));
    expect(
      label.size.height,
      greaterThanOrEqualTo(label.textSize.height),
      reason:
          'the label line box must fit inside the box the button gives it, '
          'or the glyphs are clipped',
    );
    expect(
      tester.getSize(addBooksButton()).height,
      greaterThan(
        ShadTheme.of(
          tester.element(addBooksButton()),
        ).buttonSizesTheme.regular!.height,
      ),
      reason: 'the button grows only because the scaled label needs the room',
    );
  });

  testWidgets('the button height follows a nonlinear text scale', (
    tester,
  ) async {
    double? height;
    await tester.pumpWidget(
      ShadTheme(
        data: shosaiShadTheme(Brightness.light),
        child: MediaQuery(
          data: const MediaQueryData(textScaler: _NonlinearScaler()),
          child: Builder(
            builder: (context) {
              height = shosaiShadButtonHeight(context);
              return const SizedBox();
            },
          ),
        ),
      ),
    );

    // The 14px label renders at 34px under this scaler, plus the regular
    // button's 8px top and bottom padding: a single-ratio assumption would
    // compute a different height.
    expect(height, 50);
  });

  testWidgets('Japanese metadata ink stays inside its paragraph box', (
    tester,
  ) async {
    await renderLibrary(tester, const HarnessView(size: Size(1280, 800)));

    final title = tester.renderObject<RenderParagraph>(
      find.textContaining('海辺の図書館'),
    );
    final ink = await tester.runAsync(() => measureHarnessInk(title));
    expect(ink, isNotNull);
    expect(ink!.unmeasured, isFalse);
    expect(ink.visible, isNotNull);
    expect(ink.visible!.isEmpty, isFalse);
    expect(ink.body, isNotNull);
    expect(
      classifyInkOverhang(
        visibleInk: ink.visible,
        bodyInk: ink.body,
        region: Offset.zero & title.size,
      ),
      InkOverhangKind.none,
      reason:
          'Japanese metadata must be laid out by the bundled face that covers '
          'it, not by a fallback run that paints outside the paragraph box',
    );
  });
}
