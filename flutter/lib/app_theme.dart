import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

const shosaiInterfaceFontFamily = 'Inter';
const shosaiJapaneseInterfaceFontFamily = 'Noto Sans JP';
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

const _sepiaBackground = Color(0xfffff4d6);
const _sepiaCard = Color(0xffffeec4);
const _sepiaPrimary = Color(0xff8a6338);
const _sepiaPrimaryForeground = Color(0xfffffbf0);

ShadThemeData shosaiShadTheme(Brightness brightness) {
  final colorScheme = ShadColorScheme.fromName('stone', brightness: brightness);
  return ShadThemeData(
    brightness: brightness,
    colorScheme: colorScheme,
    textTheme: ShadTextTheme(
      family: shosaiInterfaceFontFamily,
    ).apply(fontFamilyFallback: shosaiInterfaceFontFallback),
  );
}

ShadThemeData shosaiReaderShadTheme(String? readerTheme) {
  final brightness = readerTheme == 'dark' ? Brightness.dark : Brightness.light;
  var colorScheme = ShadColorScheme.fromName('stone', brightness: brightness);
  if (readerTheme == 'sepia') {
    colorScheme = colorScheme.copyWith(
      background: _sepiaBackground,
      card: _sepiaCard,
      popover: _sepiaBackground,
      primary: _sepiaPrimary,
      primaryForeground: _sepiaPrimaryForeground,
      secondary: _sepiaCard,
    );
  }
  return ShadThemeData(
    brightness: brightness,
    colorScheme: colorScheme,
    textTheme: ShadTextTheme(
      family: shosaiInterfaceFontFamily,
    ).apply(fontFamilyFallback: shosaiInterfaceFontFallback),
  );
}

ThemeData shosaiMaterialTheme(BuildContext context) {
  final theme = Theme.of(context);
  return theme.copyWith(
    textTheme: theme.textTheme.apply(
      fontFamily: shosaiInterfaceFontFamily,
      fontFamilyFallback: shosaiInterfaceFontFallback,
    ),
  );
}
