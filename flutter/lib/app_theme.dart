import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

const shosaiInterfaceFontFamily = 'Inter';
const shosaiInterfaceFontFallback = ['Noto Sans JP'];

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
