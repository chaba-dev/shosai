import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shosai_flutter/app_theme.dart';
import 'package:shosai_flutter/main.dart';
import 'package:shosai_flutter/reader/view.dart';
import 'package:shosai_flutter/shared/shad_widgets.dart';
import 'package:shosai_flutter/theme_tokens.dart';

import 'support/production_shell_harness.dart';

/// Package 2C: the shared design tokens and the themes mapped from them.
///
/// The expectations in this file are transcribed from the pinned Iced reference
/// (`docs/flutter-ui-reference-spec.md` §3) rather than read back from
/// `lib/theme_tokens.dart`, so a wrong mapping cannot agree with itself. The
/// generated token file is separately checked against
/// `assets/theme/tokens.json` by `scripts/generate-theme-tokens.py --check` and
/// by the source comparison below.
void main() {
  setUpAll(loadHarnessFonts);

  // The pinned Iced application palette (specification §3.1, §3.2).
  const appBackground = Color(0xFFF4F2ED);
  const appSurface = Color(0xFFFFFEFB);
  const appSurfaceMuted = Color(0xFFECE9E1);
  const appText = Color(0xFF282724);
  const appTextMuted = Color(0xFF726F67);
  const appBorder = Color(0xFFD9D5CB);
  const appAccent = Color(0xFF4D5E86);
  const appAccentHovered = Color(0xFF3F4F76);
  const appAccentSoft = Color(0xFFE2E6F0);
  const appDanger = Color(0xFFA54343);
  const appTextOnAccent = Color(0xFFFFFFFF);
  const appShadowBase = Color(0xFF21201E);
  final appBackdrop = Color.fromRGBO(0x21, 0x20, 0x1E, 0.42);

  // The retained Flutter dark palette (Iced defines no dark application
  // palette; the values are the ones this application already rendered with).
  const appDarkBackground = Color(0xFF0C0A09);
  const appDarkForeground = Color(0xFFFAFAF9);
  const appDarkPrimary = Color(0xFFFAFAF9);
  const appDarkPrimaryForeground = Color(0xFF1C1917);
  const appDarkSecondary = Color(0xFF292524);
  const appDarkMutedForeground = Color(0xFFA8A29E);
  const appDarkDestructive = Color(0xFFEF4444);
  const appDarkBorder = Color(0xFF292524);
  const appDarkRing = Color(0xFFD6D3D1);
  const appDarkSelection = Color(0xFF355172);

  // The pinned Iced reader palettes (specification §3.3).
  const readerLightBackground = Color(0xFFFFFFFF);
  final readerLightText = const Color.from(
    alpha: 1,
    red: 0.1,
    green: 0.1,
    blue: 0.1,
  );
  final readerDarkBackground = const Color.from(
    alpha: 1,
    red: 0.12,
    green: 0.12,
    blue: 0.14,
  );
  final readerDarkText = const Color.from(
    alpha: 1,
    red: 0.85,
    green: 0.85,
    blue: 0.85,
  );
  final readerSepiaBackground = const Color.from(
    alpha: 1,
    red: 0.96,
    green: 0.92,
    blue: 0.84,
  );
  final readerSepiaText = const Color.from(
    alpha: 1,
    red: 0.3,
    green: 0.2,
    blue: 0.1,
  );
  const readerSepiaTableHeader = Color(0xFFE5D6BA);

  group('application palette mapping', () {
    test('the light Shad scheme is the pinned Iced palette', () {
      expect(
        shosaiShadTheme(Brightness.light).colorScheme,
        const ShadColorScheme(
          background: appBackground,
          foreground: appText,
          card: appSurface,
          cardForeground: appText,
          popover: appSurface,
          popoverForeground: appText,
          primary: appAccent,
          primaryForeground: appTextOnAccent,
          secondary: appSurface,
          secondaryForeground: appText,
          muted: appSurfaceMuted,
          mutedForeground: appTextMuted,
          accent: appAccentSoft,
          accentForeground: appAccent,
          destructive: appDanger,
          destructiveForeground: appTextOnAccent,
          border: appBorder,
          input: appBorder,
          ring: appAccent,
          selection: appAccentSoft,
        ),
      );
    });

    test('the dark Shad scheme is the retained dark palette', () {
      expect(
        shosaiShadTheme(Brightness.dark).colorScheme,
        const ShadColorScheme(
          background: appDarkBackground,
          foreground: appDarkForeground,
          card: appDarkBackground,
          cardForeground: appDarkForeground,
          popover: appDarkBackground,
          popoverForeground: appDarkForeground,
          primary: appDarkPrimary,
          primaryForeground: appDarkPrimaryForeground,
          secondary: appDarkSecondary,
          secondaryForeground: appDarkForeground,
          muted: appDarkSecondary,
          mutedForeground: appDarkMutedForeground,
          accent: appDarkSecondary,
          accentForeground: appDarkForeground,
          destructive: appDarkDestructive,
          destructiveForeground: appDarkForeground,
          border: appDarkBorder,
          input: appDarkBorder,
          ring: appDarkRing,
          selection: appDarkSelection,
        ),
      );
    });

    test('the accent is the Iced value and not the historical brown', () {
      for (final brightness in Brightness.values) {
        final scheme = shosaiShadTheme(brightness).colorScheme;
        expect(scheme.ring, isNot(const Color(0xFF8A6338)));
        expect(scheme.primary, isNot(const Color(0xFF8A6338)));
      }
      expect(shosaiShadTheme(Brightness.light).colorScheme.primary, appAccent);
      expect(shosaiShadTheme(Brightness.light).colorScheme.ring, appAccent);
      expect(
        shosaiAppColorScheme(Brightness.light).accentForeground,
        appAccent,
      );
      // The token the accent is mapped from keeps the same value.
      expect(ShosaiTokens.appAccent, appAccent);
      expect(ShosaiTokens.appAccentHovered, appAccentHovered);
    });

    test('the radius is the Iced small radius', () {
      expect(
        shosaiShadTheme(Brightness.light).radius,
        BorderRadius.circular(6),
      );
      expect(ShosaiTokens.radiusSmall, 6.0);
      expect(ShosaiTokens.radiusMedium, 10.0);
    });

    test('the Shad type scale is the Iced UI scale', () {
      final text = shosaiShadTheme(Brightness.light).textTheme;
      expect(text.h1.fontSize, 32);
      expect(text.h2.fontSize, 26);
      expect(text.h3.fontSize, 24);
      expect(text.h4.fontSize, 20);
      expect(text.p.fontSize, 16);
      expect(text.blockquote.fontSize, 16);
      expect(text.table.fontSize, 16);
      expect(text.list.fontSize, 16);
      expect(text.lead.fontSize, 20);
      expect(text.large.fontSize, 18);
      expect(text.small.fontSize, 14);
      expect(text.muted.fontSize, 14);
      expect(text.family, shosaiInterfaceFontFamily);
    });
  });

  group('reader palette mapping', () {
    test('the light reader chrome is the application palette', () {
      expect(
        shosaiReaderShadTheme('light').colorScheme,
        shosaiAppColorScheme(Brightness.light),
      );
      expect(
        shosaiReaderShadTheme(null).colorScheme,
        shosaiAppColorScheme(Brightness.light),
      );
    });

    test('the dark reader chrome is the retained dark palette', () {
      expect(
        shosaiReaderShadTheme('dark').colorScheme,
        shosaiAppColorScheme(Brightness.dark),
      );
      expect(shosaiReaderShadTheme('dark').brightness, Brightness.dark);
    });

    test('the sepia reader chrome uses the Iced sepia surfaces and accent', () {
      final scheme = shosaiReaderShadTheme('sepia').colorScheme;
      expect(scheme.background, readerSepiaBackground);
      expect(scheme.foreground, readerSepiaText);
      expect(scheme.card, readerSepiaTableHeader);
      expect(scheme.muted, readerSepiaTableHeader);
      expect(scheme.mutedForeground, readerSepiaText);
      expect(scheme.border, appBorder);
      expect(scheme.input, appBorder);
      // Plan decision 2 rejects the #109 brown accent; the sepia reader keeps
      // the Iced application accent instead.
      expect(scheme.primary, appAccent);
      expect(scheme.ring, appAccent);
      expect(scheme.primary, isNot(const Color(0xFF8A6338)));
      expect(shosaiReaderShadTheme('sepia').brightness, Brightness.light);
    });

    test('reader page colors are the pinned Iced document palettes', () {
      final expectations = <String?, ({Color background, Color foreground})>{
        null: (background: readerLightBackground, foreground: readerLightText),
        'light': (
          background: readerLightBackground,
          foreground: readerLightText,
        ),
        'dark': (background: readerDarkBackground, foreground: readerDarkText),
        'sepia': (
          background: readerSepiaBackground,
          foreground: readerSepiaText,
        ),
      };
      expectations.forEach((readerTheme, expected) {
        final scheme = shosaiReaderMaterialColorScheme(readerTheme);
        final colors = pageColors(scheme);
        expect(colors.background, expected.background, reason: '$readerTheme');
        expect(colors.foreground, expected.foreground, reason: '$readerTheme');
        expect(
          ThemeData.estimateBrightnessForColor(colors.background),
          isNot(ThemeData.estimateBrightnessForColor(colors.foreground)),
          reason: '$readerTheme keeps background and foreground distinct',
        );
      });
    });

    test('the reader interactive color holds contrast on each palette', () {
      expect(shosaiReaderMaterialColorScheme(null).primary, appAccent);
      expect(
        shosaiReaderMaterialColorScheme('dark').primary,
        ShosaiTokens.readerDarkLink,
      );
      expect(
        shosaiReaderMaterialColorScheme('sepia').primary,
        ShosaiTokens.readerSepiaLink,
      );
    });

    testWidgets('reader document palettes are not interface font sources', (
      tester,
    ) async {
      // Interface fonts are separate from document fonts: the reader chrome
      // uses the interface family and never forces a document font onto the
      // page, which the Rust raster supplies.
      final context = await pumpThemeContext(tester);
      final theme = shosaiReaderMaterialTheme(context, 'sepia');
      expect(theme.textTheme.bodyMedium?.fontFamily, shosaiInterfaceFontFamily);
      expect(
        theme.textTheme.bodyMedium?.fontFamilyFallback,
        shosaiInterfaceFontFallback,
      );
      expect(theme.scaffoldBackgroundColor, readerSepiaBackground);
      expect(theme.colorScheme.surface, readerSepiaBackground);
      expect(theme.colorScheme.onSurface, readerSepiaText);
    });
  });

  group('material mapping', () {
    test('the application color scheme is mapped from the tokens', () {
      final scheme = shosaiMaterialColorScheme(Brightness.light);
      expect(scheme.primary, appAccent);
      expect(scheme.onPrimary, appTextOnAccent);
      expect(scheme.primaryContainer, appAccentSoft);
      expect(scheme.onPrimaryContainer, appAccent);
      expect(scheme.secondary, appAccentSoft);
      expect(scheme.onSecondary, appAccent);
      expect(scheme.error, appDanger);
      expect(scheme.onError, appTextOnAccent);
      expect(scheme.surface, appBackground);
      expect(scheme.onSurface, appText);
      expect(scheme.onSurfaceVariant, appTextMuted);
      expect(scheme.outline, appBorder);
      expect(scheme.outlineVariant, appBorder);
      expect(scheme.surfaceContainerHighest, appSurfaceMuted);
      expect(scheme.surfaceContainerLow, appSurface);
      expect(scheme.shadow, appShadowBase);
      expect(scheme.scrim, appBackdrop);

      final dark = shosaiMaterialColorScheme(Brightness.dark);
      expect(dark.brightness, Brightness.dark);
      expect(dark.surface, appDarkBackground);
      expect(dark.onSurface, appDarkForeground);
      expect(dark.primary, appDarkPrimary);
      expect(dark.error, appDarkDestructive);
      expect(dark.outline, appDarkBorder);
    });

    testWidgets('the Material interop surfaces are mapped too', (tester) async {
      final theme = shosaiMaterialTheme(await pumpThemeContext(tester));
      expect(theme.dividerTheme.color, appBorder);
      expect(theme.textSelectionTheme.cursorColor, appAccent);
      expect(theme.textSelectionTheme.selectionColor, appAccentSoft);
      expect(theme.iconTheme.color, appText);
      expect(
        theme.tooltipTheme.decoration,
        BoxDecoration(
          color: appSurface,
          border: Border.all(color: appBorder),
          borderRadius: BorderRadius.circular(6),
        ),
      );
      expect(theme.tooltipTheme.textStyle?.color, appText);
      expect(theme.tooltipTheme.textStyle?.fontSize, 12);
      // The tooltip keeps the bundled interface family and its fallback; a
      // partial style would fall back to the platform font.
      expect(
        theme.tooltipTheme.textStyle?.fontFamily,
        shosaiInterfaceFontFamily,
      );
      expect(
        theme.tooltipTheme.textStyle?.fontFamilyFallback,
        shosaiInterfaceFontFallback,
      );

      final reader = shosaiReaderMaterialTheme(
        await pumpThemeContext(tester),
        'sepia',
      );
      expect(reader.dividerTheme.color, appBorder);
      expect(reader.textSelectionTheme.selectionColor, readerSepiaTableHeader);
      expect(
        reader.textSelectionTheme.cursorColor,
        ShosaiTokens.readerSepiaLink,
      );
      expect(reader.iconTheme.color, readerSepiaText);
    });

    testWidgets('every Material text role resolves to an Iced UI size', (
      tester,
    ) async {
      final theme = shosaiMaterialTheme(await pumpThemeContext(tester));
      final text = theme.textTheme;
      expect(text.displayLarge?.fontSize, 32);
      expect(text.displayMedium?.fontSize, 32);
      expect(text.displaySmall?.fontSize, 32);
      expect(text.headlineLarge?.fontSize, 32);
      expect(text.headlineMedium?.fontSize, 26);
      expect(text.headlineSmall?.fontSize, 24);
      expect(text.titleLarge?.fontSize, 20);
      expect(text.titleMedium?.fontSize, 16);
      expect(text.titleSmall?.fontSize, 14);
      expect(text.bodyLarge?.fontSize, 16);
      expect(text.bodyMedium?.fontSize, 14);
      expect(text.bodySmall?.fontSize, 12);
      expect(text.labelLarge?.fontSize, 14);
      expect(text.labelMedium?.fontSize, 12);
      expect(text.labelSmall?.fontSize, 11);
      expect(text.bodyMedium?.fontFamily, shosaiInterfaceFontFamily);
      expect(text.bodyMedium?.fontFamilyFallback, shosaiInterfaceFontFallback);
    });

    testWidgets('a rendered tooltip uses the mapped surface and text', (
      tester,
    ) async {
      const view = HarnessView(size: Size(390, 780));
      view.apply(tester);
      await tester.pumpWidget(
        productionShell(
          home: Scaffold(
            body: Center(
              child: ShadIconAction(
                tooltip: 'Search and bookmarks',
                onPressed: () {},
                icon: const Icon(Icons.search),
              ),
            ),
          ),
        ),
      );
      await tester.longPress(find.byType(Tooltip));
      await tester.pump(const Duration(milliseconds: 100));

      final message = tester.widget<Text>(
        find.text('Search and bookmarks', skipOffstage: false),
      );
      // The tooltip message is a `Text.rich` styled from the mapped tooltip
      // theme, so this asserts what the user actually sees, not only the theme
      // object it came from.
      expect(message.style?.color, appText);
      expect(message.style?.fontSize, 12);
      expect(message.style?.fontFamily, shosaiInterfaceFontFamily);
      expect(message.style?.fontFamilyFallback, shosaiInterfaceFontFallback);
      final context = tester.element(find.byType(Tooltip));
      expect(
        TooltipTheme.of(context).decoration,
        BoxDecoration(
          color: appSurface,
          border: Border.all(color: appBorder),
          borderRadius: BorderRadius.circular(6),
        ),
      );
    });

    testWidgets('the production shell installs the mapped Material theme', (
      tester,
    ) async {
      const view = HarnessView(size: Size(1280, 800));
      view.apply(tester);
      const probe = ValueKey('theme-probe');
      await tester.pumpWidget(
        productionShell(
          home: Builder(
            key: probe,
            builder: (context) => const SizedBox.expand(),
          ),
        ),
      );
      final context = tester.element(find.byKey(probe));
      final theme = Theme.of(context);
      expect(theme.colorScheme.surface, appBackground);
      expect(theme.colorScheme.primary, appAccent);
      expect(theme.scaffoldBackgroundColor, appBackground);
      expect(ShadTheme.of(context).colorScheme.primary, appAccent);
    });
  });

  group('token source', () {
    test('the generated Dart tokens match assets/theme/tokens.json', () {
      final document =
          jsonDecode(File('../assets/theme/tokens.json').readAsStringSync())
              as Map<String, dynamic>;

      Color hex(String value) {
        expect(value.startsWith('#'), isTrue, reason: value);
        return Color(int.parse(value.substring(1), radix: 16) | 0xFF000000);
      }

      Color rgb(String value) {
        final match = RegExp(
          r'^rgb\(([^,]+), ([^,]+), ([^)]+)\)$',
        ).firstMatch(value);
        expect(match, isNotNull, reason: value);
        return Color.from(
          alpha: 1,
          red: double.parse(match!.group(1)!),
          green: double.parse(match.group(2)!),
          blue: double.parse(match.group(3)!),
        );
      }

      Color rgba(String value) {
        final match = RegExp(
          r'^rgba\(#([0-9A-Fa-f]{6}), ([^)]+)\)$',
        ).firstMatch(value);
        expect(match, isNotNull, reason: value);
        return Color.fromRGBO(
          int.parse(match!.group(1)!.substring(0, 2), radix: 16),
          int.parse(match.group(1)!.substring(2, 4), radix: 16),
          int.parse(match.group(1)!.substring(4, 6), radix: 16),
          double.parse(match.group(2)!),
        );
      }

      final app = document['app'] as Map<String, dynamic>;
      final reader = document['reader'] as Map<String, dynamic>;
      final radius = document['radius'] as Map<String, dynamic>;
      final type = document['type'] as Map<String, dynamic>;
      final layout = document['layout'] as Map<String, dynamic>;

      expect(ShosaiTokens.appBackground, hex(app['background'] as String));
      expect(ShosaiTokens.appAccent, hex(app['accent'] as String));
      expect(ShosaiTokens.appSurface, hex(app['surface'] as String));
      expect(
        ShosaiTokens.appShadowCover,
        rgba((app['shadow'] as Map<String, dynamic>)['cover'] as String),
      );
      expect(ShosaiTokens.appBackdrop, rgba(app['backdrop'] as String));
      final light = reader['light'] as Map<String, dynamic>;
      final dark = reader['dark'] as Map<String, dynamic>;
      final sepia = reader['sepia'] as Map<String, dynamic>;
      expect(ShosaiTokens.readerLightText, rgb(light['text'] as String));
      expect(
        ShosaiTokens.readerDarkBackground,
        rgb(dark['background'] as String),
      );
      expect(ShosaiTokens.readerSepiaText, rgb(sepia['text'] as String));
      expect(ShosaiTokens.readerSepiaLink, hex(sepia['link'] as String));
      expect(ShosaiTokens.radiusSmall, radius['small']);
      expect(ShosaiTokens.radiusMedium, radius['medium']);
      expect(
        ShosaiTokens.typeSize26,
        (type['size'] as Map<String, dynamic>)['26'],
      );
      expect(
        ShosaiTokens.typeFamilyUiLatinFlutter,
        ((type['family'] as Map<String, dynamic>)['ui']
            as Map<String, dynamic>)['latin']['flutter'],
      );
      expect(
        ShosaiTokens.layoutLibraryCompactBreakpoint,
        (layout['library'] as Map<String, dynamic>)['compactBreakpoint'],
      );
      expect(
        ShosaiTokens.layoutReaderSpreadMinWidth,
        (layout['reader'] as Map<String, dynamic>)['spreadMinWidth'],
      );
      expect(document['meta']['reference_revision'], isNotEmpty);
    });

    test('no literal theme colors remain in lib/', () {
      final offenders = <String>[];
      final files = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart'))
          .where((file) => !file.path.endsWith('theme_tokens.dart'));
      for (final file in files) {
        for (final finding in dartColorLiterals(file.readAsStringSync())) {
          offenders.add('${file.path}:${finding.line}: ${finding.description}');
        }
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'theme colors belong in assets/theme/tokens.json, not in lib/:\n'
            '${offenders.join('\n')}',
      );
    });

    test('the literal scan finds literals and ignores dynamic conversions', () {
      const source = r"""
        // Color(0xff112233) in a comment
        /* Color.fromARGB(255, 0, 0, 0) in a block comment */
        const message = 'Color(0xff112233) in a string';
        const a = Color(0xff112233);
        const b = Color(
          0xff112233,
        );
        const c = Color.fromARGB(255, 0, 0, 0);
        const d = Color.fromRGBO(0, 0, 0, 0.5);
        const e = Color.from(alpha: 1, red: 0, green: 0, blue: 0);
        const f = Colors.red;
        const named = Color.from(red: 1, green: 0, blue: 0, alpha: 1);
        const fractional = Color.from(alpha: .5, red: 1, green: 0, blue: 0);
        const empty = '';
        const emptyRaw = r'';
        const emptyTriple = '''''';
        const separated = Color(0xFF_00_00_00);
        const exponent = Color.fromRGBO(0, 0, 0, 5e-1);
        const exponentPlus = Color.fromRGBO(255, 0, 0, 1e+0);
        Color dynamic1(int alpha) => Color(alpha);
        Color dynamic2(int a, int r, int g, int b) => Color.fromARGB(a, r, g, b);
        Color dynamic3(double a, double r, double g, double b) =>
            Color.from(alpha: a, red: r, green: g, blue: b);
        Color dynamic4(int r, int g, int b) => Color.fromARGB(255, r, g, b);
        Color dynamic5(bool useValue, int packed) =>
            Color(useValue ? packed : 0xff000000);
        /* outer /* inner */ Colors.red */
        const afterComment = Colors.red;
        const afterEmpty = Colors.blue;
      """;
      final found = dartColorLiterals(source);
      expect(
        found.map((finding) => finding.description).toList(),
        hasLength(13),
        reason: 'findings: $found',
      );
      expect(
        found
            .map((finding) => finding.description)
            .where((description) => description.contains('dynamic')),
        isEmpty,
        reason: 'dynamic conversions are not literals: $found',
      );
      expect(
        found.any((finding) => finding.description.contains('Colors')),
        isTrue,
      );
      expect(
        found
            .map((finding) => finding.description)
            .where((description) => description.contains('0xFF_00_00_00')),
        hasLength(1),
        reason: 'a separated hex literal is a literal: $found',
      );
      expect(
        found
            .map((finding) => finding.description)
            .where((description) => description.contains('5e-1')),
        hasLength(1),
        reason: 'an exponent literal is a literal: $found',
      );
      expect(
        found
            .map((finding) => finding.description)
            .where((description) => description.contains('1e+0')),
        hasLength(1),
        reason: 'a signed exponent literal is a literal: $found',
      );
      expect(
        found
            .map((finding) => finding.description)
            .where((description) => description == 'Colors.blue'),
        hasLength(1),
        reason: 'code after an empty string is still code: $found',
      );
      // A raw multiline string with double-quote delimiters has to be consumed
      // as one literal. The earlier scanner treated `r"""` as `r"` and exposed
      // the rest of the string as code.
      const multiline = r'''
        const message = r"""say "Colors.red" here""";
        const leading = r""""Colors.red" here""";
        const plainLeading = """"Colors.red" here""";
        const afterRaw = Colors.blue;
      ''';
      final rawFindings = dartColorLiterals(multiline);
      expect(
        rawFindings.map((finding) => finding.description).toList(),
        ['Colors.blue'],
        reason: 'findings: $rawFindings',
      );
      expect(
        found.any((finding) => finding.description.contains('fromRGBO')),
        isTrue,
      );
    });
  });
}

/// Dart source with comments and string literals blanked out.
///
/// Blanking preserves line numbers and offsets, so a finding can name its line.
/// Handles line and block comments, single- and double-quoted strings,
/// triple-quoted strings and raw strings.
String stripDartNoise(String source) {
  final out = StringBuffer();
  var index = 0;
  while (index < source.length) {
    final character = source[index];
    final next = index + 1 < source.length ? source[index + 1] : '';

    if (character == '/' && next == '/') {
      while (index < source.length && source[index] != '\n') {
        out.write(' ');
        index += 1;
      }
      continue;
    }
    if (character == '/' && next == '*') {
      // Dart block comments nest, so the scanner tracks the depth; stopping at
      // the first `*/` would expose comment text as code.
      var depth = 0;
      while (index < source.length) {
        final opens =
            source[index] == '/' &&
            index + 1 < source.length &&
            source[index + 1] == '*';
        final closes =
            source[index] == '*' &&
            index + 1 < source.length &&
            source[index + 1] == '/';
        if (opens) {
          depth += 1;
          out.write('  ');
          index += 2;
          continue;
        }
        if (closes) {
          depth -= 1;
          out.write('  ');
          index += 2;
          if (depth == 0) break;
          continue;
        }
        out.write(source[index] == '\n' ? '\n' : ' ');
        index += 1;
      }
      continue;
    }

    final isRaw =
        (character == 'r' || character == 'R') && (next == "'" || next == '"');
    if (character == "'" || character == '"' || isRaw) {
      final quote = isRaw ? next : character;
      final afterPrefix = isRaw ? index + 2 : index + 1;
      // Triple delimiters are recognised for raw strings too, so a raw
      // multiline string is consumed as one literal.
      final triple =
          afterPrefix + 1 < source.length &&
          source[afterPrefix] == quote &&
          source[afterPrefix + 1] == quote;
      final delimiter = triple ? quote * 3 : quote;
      // `afterPrefix` already points past the first quote, so the opening is
      // the raw prefix plus the whole delimiter. Consuming one character too
      // many would blank content (an empty string would swallow the code after
      // it); consuming too few would let the remaining opening quotes close the
      // literal early.
      final openingLength = (isRaw ? 1 : 0) + delimiter.length;
      out.write(' ' * openingLength);
      index += openingLength;
      while (index < source.length) {
        if (!isRaw && source[index] == r'\') {
          out.write('  ');
          index += 2;
          continue;
        }
        if (source.startsWith(delimiter, index)) {
          out.write(' ' * delimiter.length);
          index += delimiter.length;
          break;
        }
        out.write(source[index] == '\n' ? '\n' : ' ');
        index += 1;
      }
      continue;
    }

    out.write(character);
    index += 1;
  }
  return out.toString();
}

/// The top-level arguments of the call whose `(` is at [open].
List<String> callArguments(String code, int open) {
  final arguments = <String>[];
  var depth = 1;
  var index = open + 1;
  var current = StringBuffer();
  while (index < code.length) {
    final character = code[index];
    if (character == '(' || character == '[' || character == '{') {
      depth += 1;
      current.write(character);
    } else if (character == ')' || character == ']' || character == '}') {
      depth -= 1;
      if (depth == 0) break;
      current.write(character);
    } else if (character == ',' && depth == 1) {
      arguments.add(current.toString());
      current = StringBuffer();
    } else {
      current.write(character);
    }
    index += 1;
  }
  if (current.toString().trim().isNotEmpty) {
    arguments.add(current.toString());
  }
  return arguments;
}

/// True when [argument] is a bare numeric literal, named or positional.
///
/// A channel expression (`Color(alpha)`, `Color.fromARGB(a, r, g, b)`) is a
/// dynamic conversion, not a literal, so a data-derived color cannot hide
/// behind a numeric-looking argument.
bool isNumericLiteral(String argument) {
  var value = argument.trim();
  // Only an anchored `identifier:` prefix is a named argument; anything else
  // with a colon is an expression (`condition ? a : b`).
  final named = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*\s*:\s*').firstMatch(value);
  if (named != null) {
    value = value.substring(named.end).trim();
  }
  // `+` and `-` stay allowed because an exponent may carry a sign; the grammar
  // below rejects them anywhere else.
  if (value.isEmpty || RegExp(r'[\s*/?:()\[\]{}]').hasMatch(value)) {
    return false;
  }
  final unsigned = value.startsWith('-') ? value.substring(1) : value;
  if (unsigned.startsWith('0x') || unsigned.startsWith('0X')) {
    final digits = unsigned.substring(2);
    return digits.isNotEmpty && RegExp(r'^[0-9a-fA-F_]+$').hasMatch(digits);
  }
  return RegExp(
    r'^(\d[\d_]*\.?[\d_]*|\.\d[\d_]*)([eE][+-]?\d[\d_]*)?$',
  ).hasMatch(unsigned);
}

/// Literal color constructions in Dart source, with the line they appear on.
///
/// A construction is a literal only when every one of its arguments is a bare
/// number, in any named-argument order; `Colors.<name>` is always a finding,
/// because it can only be a literal.
List<({int line, String description})> dartColorLiterals(String source) {
  final code = stripDartNoise(source);
  final findings = <({int line, String description})>[];
  int lineOf(int offset) =>
      '\n'.allMatches(code.substring(0, offset)).length + 1;

  final constructors = <RegExp>[
    RegExp(r'\bColor\s*\.\s*fromARGB\s*\('),
    RegExp(r'\bColor\s*\.\s*fromRGBO\s*\('),
    RegExp(r'\bColor\s*\.\s*from\s*\('),
    RegExp(r'\bColor\s*\('),
  ];
  for (final pattern in constructors) {
    for (final match in pattern.allMatches(code)) {
      final arguments = callArguments(code, match.end - 1);
      if (arguments.isEmpty || !arguments.every(isNumericLiteral)) {
        continue;
      }
      final callee = match
          .group(0)!
          .replaceAll(RegExp(r'\s+'), '')
          .replaceAll('(', '');
      findings.add((
        line: lineOf(match.start),
        description:
            '$callee(${arguments.map((argument) => argument.trim()).join(', ')})',
      ));
    }
  }
  for (final match in RegExp(r'\bColors\s*\.\s*[A-Za-z_]+').allMatches(code)) {
    findings.add((
      line: lineOf(match.start),
      description: match.group(0)!.replaceAll(RegExp(r'\s+'), ''),
    ));
  }
  findings.sort((a, b) => a.line.compareTo(b.line));
  return findings;
}

/// Pumps a minimal Material app and returns a context inside it.
///
/// The theme builders read the ambient theme for their base text styles, so
/// these tests hand them the same default theme the production shell's
/// `appBuilder` does.
Future<BuildContext> pumpThemeContext(WidgetTester tester) async {
  late BuildContext captured;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) {
          captured = context;
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  return captured;
}
