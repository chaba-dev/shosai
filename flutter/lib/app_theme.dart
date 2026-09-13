import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

const shosaiInterfaceFontFamily = 'Inter';
const shosaiInterfaceFontFallback = ['Noto Sans JP'];

const _brandLightPrimary = Color(0xff745b3e);
const _brandLightPrimaryForeground = Color(0xfffffbf5);
const _brandDarkPrimary = Color(0xffc5a57c);
const _brandDarkPrimaryForeground = Color(0xff2b2117);

const _sepiaBackground = Color(0xfffff4d6);
const _sepiaCard = Color(0xffffeec4);
const _sepiaPrimary = Color(0xff8a6338);
const _sepiaPrimaryForeground = Color(0xfffffbf0);

ShadColorScheme _shosaiColorScheme(Brightness brightness) {
  final base = ShadColorScheme.fromName('stone', brightness: brightness);
  final dark = brightness == Brightness.dark;
  final primary = dark ? _brandDarkPrimary : _brandLightPrimary;
  return base.copyWith(
    primary: primary,
    primaryForeground: dark
        ? _brandDarkPrimaryForeground
        : _brandLightPrimaryForeground,
    ring: primary,
  );
}

ShadTextTheme _shosaiTextTheme() => ShadTextTheme(
  family: shosaiInterfaceFontFamily,
).apply(fontFamilyFallback: shosaiInterfaceFontFallback);

ShadThemeData shosaiShadTheme(Brightness brightness) => ShadThemeData(
  brightness: brightness,
  colorScheme: _shosaiColorScheme(brightness),
  textTheme: _shosaiTextTheme(),
);

ShadThemeData shosaiReaderShadTheme(String? readerTheme) {
  final brightness = readerTheme == 'dark' ? Brightness.dark : Brightness.light;
  var colorScheme = _shosaiColorScheme(brightness);
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
    textTheme: _shosaiTextTheme(),
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
