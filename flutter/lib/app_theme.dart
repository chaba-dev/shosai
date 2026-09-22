import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shosai_flutter/theme_tokens.dart';

// The mapped design tokens and the Shad/Material themes built from them.
//
// [ShosaiTokens] is generated from `assets/theme/tokens.json`, the single
// tracked design-token source shared with the Iced application (plan
// decision 2). Every color, radius, type size and layout metric in this file
// comes from those tokens; no theme value is written as a literal here, and
// `flutter/test/app_theme_test.dart` rejects new literal theme colors in
// `lib/`.
//
// The mapping itself:
//
// | Flutter theme | Source tokens |
// | --- | --- |
// | `shosaiShadTheme(Brightness.light)` | `app.*` (the pinned Iced application palette) |
// | `shosaiShadTheme(Brightness.dark)` | `app.dark.*` (retained Flutter: Iced defines no dark application palette) |
// | `shosaiReaderShadTheme('light')` | `app.*` (the Iced reader chrome) |
// | `shosaiReaderShadTheme('dark')` | `app.dark.*` (retained Flutter chrome) |
// | `shosaiReaderShadTheme('sepia')` | `reader.sepia.*` surfaces with the `app.*` structural roles and accent |
// | reader page colors (`pageColors`) | `reader.<theme>.*` (the pinned Iced document palettes) |
// | radii | `radius.small` / `radius.medium` |
// | type | `type.family.*` and `type.size.*` |
//
// Interface fonts are separate from document fonts: `type.family.ui.*` is used
// for chrome and metadata only. EPUB book text keeps the document font or the
// reader preference, which this file never overrides.

const shosaiInterfaceFontFamily = ShosaiTokens.typeFamilyUiLatinFlutter;
const shosaiJapaneseInterfaceFontFamily =
    ShosaiTokens.typeFamilyUiJapaneseFlutter;
const shosaiInterfaceFontFallback = [shosaiJapaneseInterfaceFontFamily];

/// The bundled interface family that covers [text].
///
/// Mirrors `font_for_text` in `crates/shosai-app/src/typography.rs` so both
/// products select the same bundled face for the same string. User metadata
/// that contains Japanese is rendered with Noto Sans JP as the primary family
/// instead of through the fallback chain, which is what `docs/typography.md`
/// requires; it also keeps the paragraph's glyphs inside their box, because a
/// fallback run is positioned against the primary font's metrics.
String shosaiInterfaceFontForText(String text) =>
    text.runes.any(_isJapaneseCodePoint)
    ? shosaiJapaneseInterfaceFontFamily
    : shosaiInterfaceFontFamily;

/// [style] with the bundled face that covers [text] selected.
///
/// Japanese text gets the Japanese face as its primary family, and the Latin
/// face stays as the explicit fallback so bundled coverage does not narrow: a
/// mixed string such as `日本語 — Україна` resolves its Cyrillic glyphs from
/// Inter, which Noto Sans JP does not cover. Other scripts keep the style's own
/// family.
TextStyle shosaiInterfaceStyleForText(TextStyle style, String text) =>
    shosaiInterfaceFontForText(text) == shosaiJapaneseInterfaceFontFamily
    ? style.copyWith(
        fontFamily: shosaiJapaneseInterfaceFontFamily,
        fontFamilyFallback: const [shosaiInterfaceFontFamily],
      )
    : style;

bool _isJapaneseCodePoint(int rune) =>
    (rune >= 0x3000 && rune <= 0x30ff) ||
    (rune >= 0x31f0 && rune <= 0x31ff) ||
    (rune >= 0x3400 && rune <= 0x9fff) ||
    (rune >= 0xf900 && rune <= 0xfaff) ||
    (rune >= 0xff66 && rune <= 0xff9f) ||
    (rune >= 0x20000 && rune <= 0x2fa1f);

/// The height a Shad button needs for a single-line label at the current text
/// scale, with this application's shared button geometry.
///
/// Shad buttons pin their content inside a `ConstrainedBox` of the size theme's
/// height minus its padding, so a label whose scaled line box is taller than
/// that content box is clipped at 200% text (LB-10). The theme height stays the
/// floor: for the single-line labels this is used with, 100% text returns the
/// theme's own height and the button only grows by the room its scaled label
/// actually needs.
///
/// The label's own line height is scaled with `TextScaler.scale`, so a nonlinear
/// text scale is measured the way Flutter lays the label out. Multiline content,
/// widget-level padding overrides and metrics beyond the label's line height are
/// outside this helper's contract.
///
/// The theme in this file gives every button variant the same geometry, so the
/// primary variant's theme resolves the height and label style for all of them.
double shosaiShadButtonHeight(BuildContext context, {ShadButtonSize? size}) {
  final theme = ShadTheme.of(context);
  final buttonTheme = theme.primaryButtonTheme;
  final sizeTheme = _shosaiButtonSizeTheme(
    theme,
    size ?? buttonTheme.size ?? ShadButtonSize.regular,
  );
  final height = buttonTheme.height ?? sizeTheme.height;
  final padding = sizeTheme.padding;
  final label = buttonTheme.textStyle ?? theme.textTheme.small;
  final lineHeight =
      MediaQuery.textScalerOf(context).scale(label.fontSize ?? 14) *
      (label.height ?? 1);
  return math.max(height, padding.vertical + lineHeight);
}

ShadButtonSizeTheme _shosaiButtonSizeTheme(
  ShadThemeData theme,
  ShadButtonSize size,
) => switch (size) {
  ShadButtonSize.sm => theme.buttonSizesTheme.sm!,
  ShadButtonSize.lg => theme.buttonSizesTheme.lg!,
  ShadButtonSize.regular => theme.buttonSizesTheme.regular!,
};

/// The application palette as a Shad color scheme.
///
/// The light scheme is the pinned Iced application palette (`app.*`); the dark
/// scheme is the retained Flutter dark palette (`app.dark.*`), because Iced
/// defines no dark application palette.
ShadColorScheme shosaiAppColorScheme(Brightness brightness) =>
    brightness == Brightness.dark ? _appDarkColorScheme : _appLightColorScheme;

const _appLightColorScheme = ShadColorScheme(
  background: ShosaiTokens.appBackground,
  foreground: ShosaiTokens.appText,
  card: ShosaiTokens.appSurface,
  cardForeground: ShosaiTokens.appText,
  popover: ShosaiTokens.appSurface,
  popoverForeground: ShosaiTokens.appText,
  primary: ShosaiTokens.appAccent,
  primaryForeground: ShosaiTokens.appTextOnAccent,
  secondary: ShosaiTokens.appSurface,
  secondaryForeground: ShosaiTokens.appText,
  muted: ShosaiTokens.appSurfaceMuted,
  mutedForeground: ShosaiTokens.appTextMuted,
  accent: ShosaiTokens.appAccentSoft,
  accentForeground: ShosaiTokens.appAccent,
  destructive: ShosaiTokens.appDanger,
  destructiveForeground: ShosaiTokens.appTextOnAccent,
  border: ShosaiTokens.appBorder,
  input: ShosaiTokens.appBorder,
  ring: ShosaiTokens.appAccent,
  selection: ShosaiTokens.appAccentSoft,
);

const _appDarkColorScheme = ShadColorScheme(
  background: ShosaiTokens.appDarkBackground,
  foreground: ShosaiTokens.appDarkForeground,
  card: ShosaiTokens.appDarkCard,
  cardForeground: ShosaiTokens.appDarkCardForeground,
  popover: ShosaiTokens.appDarkPopover,
  popoverForeground: ShosaiTokens.appDarkPopoverForeground,
  primary: ShosaiTokens.appDarkPrimary,
  primaryForeground: ShosaiTokens.appDarkPrimaryForeground,
  secondary: ShosaiTokens.appDarkSecondary,
  secondaryForeground: ShosaiTokens.appDarkSecondaryForeground,
  muted: ShosaiTokens.appDarkMuted,
  mutedForeground: ShosaiTokens.appDarkMutedForeground,
  accent: ShosaiTokens.appDarkAccent,
  accentForeground: ShosaiTokens.appDarkAccentForeground,
  destructive: ShosaiTokens.appDarkDestructive,
  destructiveForeground: ShosaiTokens.appDarkDestructiveForeground,
  border: ShosaiTokens.appDarkBorder,
  input: ShosaiTokens.appDarkInput,
  ring: ShosaiTokens.appDarkRing,
  selection: ShosaiTokens.appDarkSelection,
);

/// The reader chrome palette for [readerTheme].
///
/// The light reader uses the Iced application palette, which is what the
/// pinned reader chrome is built from. The dark and sepia readers are a
/// retained Flutter capability that Iced does not define: dark keeps the
/// retained dark palette, and sepia takes its surfaces and text from the pinned
/// Iced sepia document palette while the structural roles and the accent stay
/// on the application palette. The pre-2C brown accent is rejected by plan
/// decision 2 and is not part of this mapping.
ShadColorScheme shosaiReaderColorScheme(String? readerTheme) =>
    switch (readerTheme) {
      'dark' => _appDarkColorScheme,
      'sepia' => _readerSepiaColorScheme,
      _ => _appLightColorScheme,
    };

const _readerSepiaColorScheme = ShadColorScheme(
  background: ShosaiTokens.readerSepiaBackground,
  foreground: ShosaiTokens.readerSepiaText,
  card: ShosaiTokens.readerSepiaTableHeaderBackground,
  cardForeground: ShosaiTokens.readerSepiaText,
  popover: ShosaiTokens.readerSepiaTableHeaderBackground,
  popoverForeground: ShosaiTokens.readerSepiaText,
  primary: ShosaiTokens.appAccent,
  primaryForeground: ShosaiTokens.appTextOnAccent,
  secondary: ShosaiTokens.readerSepiaTableHeaderBackground,
  secondaryForeground: ShosaiTokens.readerSepiaText,
  muted: ShosaiTokens.readerSepiaTableHeaderBackground,
  mutedForeground: ShosaiTokens.readerSepiaText,
  accent: ShosaiTokens.readerSepiaTableHeaderBackground,
  accentForeground: ShosaiTokens.readerSepiaText,
  destructive: ShosaiTokens.appDanger,
  destructiveForeground: ShosaiTokens.appTextOnAccent,
  border: ShosaiTokens.appBorder,
  input: ShosaiTokens.appBorder,
  ring: ShosaiTokens.appAccent,
  selection: ShosaiTokens.readerSepiaTableHeaderBackground,
);

/// The application Shad theme for [brightness].
ShadThemeData shosaiShadTheme(Brightness brightness) => ShadThemeData(
  brightness: brightness,
  colorScheme: shosaiAppColorScheme(brightness),
  radius: BorderRadius.circular(ShosaiTokens.radiusSmall),
  textTheme: _shosaiShadTextTheme(),
);

/// The reader Shad theme for [readerTheme] (`light`, `dark`, `sepia` or null).
ShadThemeData shosaiReaderShadTheme(String? readerTheme) {
  final brightness = readerTheme == 'dark' ? Brightness.dark : Brightness.light;
  return ShadThemeData(
    brightness: brightness,
    colorScheme: shosaiReaderColorScheme(readerTheme),
    radius: BorderRadius.circular(ShosaiTokens.radiusSmall),
    textTheme: _shosaiShadTextTheme(),
  );
}

/// The Shad text theme mapped to the Iced type scale.
///
/// Shad's roles are mapped to the Iced UI sizes they correspond to; a role
/// without an Iced counterpart (`h1Large`, used by no surface in this
/// application) keeps its Shad default. The roles the application actually
/// renders (`small`, `muted`, `p`, `large`) already sat on the Iced scale, and
/// they are now sourced from it instead of from the package default.
ShadTextTheme _shosaiShadTextTheme() {
  final base = ShadTextTheme(
    family: shosaiInterfaceFontFamily,
  ).apply(fontFamilyFallback: shosaiInterfaceFontFallback);
  return base.copyWith(
    h1: base.h1.copyWith(fontSize: ShosaiTokens.typeSize32),
    h2: base.h2.copyWith(fontSize: ShosaiTokens.typeSize26),
    h3: base.h3.copyWith(fontSize: ShosaiTokens.typeSize24),
    h4: base.h4.copyWith(fontSize: ShosaiTokens.typeSize20),
    p: base.p.copyWith(fontSize: ShosaiTokens.typeSize16),
    blockquote: base.blockquote.copyWith(fontSize: ShosaiTokens.typeSize16),
    table: base.table.copyWith(fontSize: ShosaiTokens.typeSize16),
    list: base.list.copyWith(fontSize: ShosaiTokens.typeSize16),
    lead: base.lead.copyWith(fontSize: ShosaiTokens.typeSize20),
    large: base.large.copyWith(fontSize: ShosaiTokens.typeSize18),
    small: base.small.copyWith(fontSize: ShosaiTokens.typeSize14),
    muted: base.muted.copyWith(fontSize: ShosaiTokens.typeSize14),
  );
}

/// The application Material theme, kept interoperable with the Shad theme.
///
/// Retained Material surfaces are mapped to the same tokens as the Shad
/// scheme, so a Material widget cannot render a Flutter default color next to a
/// mapped Shad one. The text theme is mapped to the Iced UI size scale: every
/// role resolves to an Iced size, and the roles this application renders
/// (`bodyMedium`, `titleMedium`, `bodySmall`, `labelMedium`) keep the size they
/// already had.
ThemeData shosaiMaterialTheme(BuildContext context, [Brightness? brightness]) {
  final base = Theme.of(context);
  final effectiveBrightness = brightness ?? base.brightness;
  return _materialTheme(base, shosaiMaterialColorScheme(effectiveBrightness));
}

/// The retained Material theme for [scheme].
///
/// The color scheme, scaffold, text theme and the Material interop surfaces
/// (dividers, text selection, icons) all come from the mapped tokens, so a
/// Material widget cannot keep a package-default color next to a mapped one.
/// The text styles are taken from a theme built for [scheme]'s brightness,
/// because Flutter derives the default text colors from it: a dark reader theme
/// needs light text even when the ambient theme is light.
ThemeData _materialTheme(ThemeData base, ColorScheme scheme) {
  final sized = ThemeData(
    brightness: scheme.brightness,
    colorScheme: scheme,
    useMaterial3: base.useMaterial3,
  );
  final textTheme = _shosaiMaterialTextTheme(sized.textTheme);
  return base.copyWith(
    brightness: scheme.brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    textTheme: textTheme,
    dividerTheme: DividerThemeData(color: scheme.outline, thickness: 1),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: scheme.primary,
      selectionColor: scheme.primaryContainer,
      selectionHandleColor: scheme.primary,
    ),
    iconTheme: IconThemeData(size: 16, color: scheme.onSurface),
    // Material tooltips do not derive their paint from the color scheme in this
    // Flutter version, and `ShadIconAction` renders one, so the tooltip surface
    // is mapped explicitly: the mapped raised surface, the mapped border, the
    // Iced small radius and the mapped text.
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border.all(color: scheme.outline),
        borderRadius: BorderRadius.circular(ShosaiTokens.radiusSmall),
      ),
      // Derived from the mapped body style so the tooltip keeps the bundled
      // interface family and its fallback; only the mapped color and size are
      // overridden.
      textStyle: (textTheme.bodyMedium ?? const TextStyle()).copyWith(
        color: scheme.onSurface,
        fontSize: ShosaiTokens.typeSize12,
      ),
    ),
    scrollbarTheme: base.scrollbarTheme.copyWith(
      thumbColor: WidgetStatePropertyAll<Color>(scheme.outline),
    ),
  );
}

/// The reader Material theme for [readerTheme].
///
/// The page and surface colors are the pinned Iced reader palettes (`reader.*`)
/// for the active theme, which is what [pageColors] reads. The interactive
/// color is the application accent for the light reader and the palette's own
/// link color for the dark and sepia readers: those palettes define an
/// interactive color for their surface, so document interaction keeps the
/// palette's semantics rather than the application accent. The application
/// accent still paints the reader chrome (see [shosaiReaderColorScheme]).
ThemeData shosaiReaderMaterialTheme(BuildContext context, String? readerTheme) {
  final base = Theme.of(context);
  return _materialTheme(base, shosaiReaderMaterialColorScheme(readerTheme));
}

/// The application Material color scheme for [brightness].
ColorScheme shosaiMaterialColorScheme(Brightness brightness) =>
    brightness == Brightness.dark
    ? ColorScheme.dark(
        primary: ShosaiTokens.appDarkPrimary,
        onPrimary: ShosaiTokens.appDarkPrimaryForeground,
        primaryContainer: ShosaiTokens.appDarkSelection,
        onPrimaryContainer: ShosaiTokens.appDarkForeground,
        secondary: ShosaiTokens.appDarkSecondary,
        onSecondary: ShosaiTokens.appDarkSecondaryForeground,
        error: ShosaiTokens.appDarkDestructive,
        onError: ShosaiTokens.appDarkDestructiveForeground,
        surface: ShosaiTokens.appDarkBackground,
        onSurface: ShosaiTokens.appDarkForeground,
        onSurfaceVariant: ShosaiTokens.appDarkMutedForeground,
        outline: ShosaiTokens.appDarkBorder,
        outlineVariant: ShosaiTokens.appDarkInput,
        surfaceContainerHighest: ShosaiTokens.appDarkMuted,
        surfaceContainerLow: ShosaiTokens.appDarkCard,
        shadow: ShosaiTokens.appShadowBase,
        scrim: ShosaiTokens.appShadowBase,
      )
    : ColorScheme.light(
        primary: ShosaiTokens.appAccent,
        onPrimary: ShosaiTokens.appTextOnAccent,
        primaryContainer: ShosaiTokens.appAccentSoft,
        onPrimaryContainer: ShosaiTokens.appAccent,
        secondary: ShosaiTokens.appAccentSoft,
        onSecondary: ShosaiTokens.appAccent,
        error: ShosaiTokens.appDanger,
        onError: ShosaiTokens.appTextOnAccent,
        surface: ShosaiTokens.appBackground,
        onSurface: ShosaiTokens.appText,
        onSurfaceVariant: ShosaiTokens.appTextMuted,
        outline: ShosaiTokens.appBorder,
        outlineVariant: ShosaiTokens.appBorder,
        surfaceContainerHighest: ShosaiTokens.appSurfaceMuted,
        surfaceContainerLow: ShosaiTokens.appSurface,
        shadow: ShosaiTokens.appShadowBase,
        scrim: ShosaiTokens.appBackdrop,
      );

/// The reader Material color scheme for [readerTheme].
ColorScheme shosaiReaderMaterialColorScheme(String? readerTheme) {
  final (surface, onSurface, primary, onPrimary) = switch (readerTheme) {
    'dark' => (
      ShosaiTokens.readerDarkBackground,
      ShosaiTokens.readerDarkText,
      ShosaiTokens.readerDarkLink,
      ShosaiTokens.readerDarkBackground,
    ),
    'sepia' => (
      ShosaiTokens.readerSepiaBackground,
      ShosaiTokens.readerSepiaText,
      ShosaiTokens.readerSepiaLink,
      ShosaiTokens.readerSepiaBackground,
    ),
    _ => (
      ShosaiTokens.readerLightBackground,
      ShosaiTokens.readerLightText,
      ShosaiTokens.appAccent,
      ShosaiTokens.appTextOnAccent,
    ),
  };
  final chrome = shosaiReaderColorScheme(readerTheme);
  return ColorScheme(
    brightness: readerTheme == 'dark' ? Brightness.dark : Brightness.light,
    primary: primary,
    onPrimary: onPrimary,
    primaryContainer: chrome.selection,
    onPrimaryContainer: onPrimary,
    secondary: chrome.secondary,
    onSecondary: chrome.secondaryForeground,
    error: ShosaiTokens.appDanger,
    onError: ShosaiTokens.appTextOnAccent,
    surface: surface,
    onSurface: onSurface,
    onSurfaceVariant: chrome.mutedForeground,
    outline: chrome.border,
    outlineVariant: chrome.input,
    surfaceContainerHighest: chrome.muted,
    surfaceContainerLow: chrome.card,
    shadow: ShosaiTokens.appShadowBase,
    scrim: ShosaiTokens.appBackdrop,
  );
}

/// The Material text theme mapped to the Iced UI size scale.
///
/// Iced's scale is 10, 11, 12, 13, 14, 16, 18, 20, 24, 26 and 32 logical
/// pixels. Every Material role resolves to the nearest Iced size, which leaves
/// the roles this application renders unchanged (`bodySmall` 12, `bodyMedium`
/// 14, `titleMedium` 16, `labelMedium` 12) and removes the Flutter-default
/// sizes that have no Iced counterpart (57, 45, 36, 28, 22).
TextTheme _shosaiMaterialTextTheme(TextTheme base) {
  TextStyle sized(TextStyle? style, double size) =>
      (style ?? const TextStyle()).copyWith(fontSize: size);
  return base
      .copyWith(
        displayLarge: sized(base.displayLarge, ShosaiTokens.typeSize32),
        displayMedium: sized(base.displayMedium, ShosaiTokens.typeSize32),
        displaySmall: sized(base.displaySmall, ShosaiTokens.typeSize32),
        headlineLarge: sized(base.headlineLarge, ShosaiTokens.typeSize32),
        headlineMedium: sized(base.headlineMedium, ShosaiTokens.typeSize26),
        headlineSmall: sized(base.headlineSmall, ShosaiTokens.typeSize24),
        titleLarge: sized(base.titleLarge, ShosaiTokens.typeSize20),
        titleMedium: sized(base.titleMedium, ShosaiTokens.typeSize16),
        titleSmall: sized(base.titleSmall, ShosaiTokens.typeSize14),
        bodyLarge: sized(base.bodyLarge, ShosaiTokens.typeSize16),
        bodyMedium: sized(base.bodyMedium, ShosaiTokens.typeSize14),
        bodySmall: sized(base.bodySmall, ShosaiTokens.typeSize12),
        labelLarge: sized(base.labelLarge, ShosaiTokens.typeSize14),
        labelMedium: sized(base.labelMedium, ShosaiTokens.typeSize12),
        labelSmall: sized(base.labelSmall, ShosaiTokens.typeSize11),
      )
      .apply(
        fontFamily: shosaiInterfaceFontFamily,
        fontFamilyFallback: shosaiInterfaceFontFallback,
      );
}
