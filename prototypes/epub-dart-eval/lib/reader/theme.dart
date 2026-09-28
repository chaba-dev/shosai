/// Reader document palettes for the evaluation prototype.
///
/// Values are copied from the shared design tokens
/// (`assets/theme/tokens.json`, `reader.<theme>.*`) through
/// `flutter/lib/theme_tokens.dart` so the prototype's page paper matches the
/// production reader. The prototype deliberately does not import the
/// application package: this is an isolated evaluation artifact.
library;

import 'package:flutter/painting.dart';

enum ReaderTheme { light, dark, sepia }

class ReaderPalette {
  const ReaderPalette({
    required this.background,
    required this.foreground,
    required this.link,
    required this.tableHeaderBackground,
    required this.tableHeaderBorder,
    required this.selectionFill,
    required this.highlightFill,
    required this.pageNumber,
    required this.placeholder,
  });

  final Color background;
  final Color foreground;
  final Color link;
  final Color tableHeaderBackground;
  final Color tableHeaderBorder;
  final Color selectionFill;
  final Color highlightFill;
  final Color pageNumber;
  final Color placeholder;

  static const light = ReaderPalette(
    background: Color(0xFFFFFFFF),
    foreground: Color(0xFF1A1A1A),
    link: Color(0xFF174EA6),
    tableHeaderBackground: Color(0xFFE8EEF8),
    tableHeaderBorder: Color(0xFF596B89),
    selectionFill: Color.fromRGBO(0x90, 0xCA, 0xF9, 0.4),
    highlightFill: Color.fromRGBO(0xFF, 0xF3, 0xA3, 0.5),
    pageNumber: Color.fromRGBO(0x1A, 0x1A, 0x1A, 0.55),
    placeholder: Color.fromRGBO(0x1A, 0x1A, 0x1A, 0.45),
  );

  static const dark = ReaderPalette(
    background: Color.fromRGBO(0x1F, 0x1F, 0x24, 1.0),
    foreground: Color.fromRGBO(0xD9, 0xD9, 0xD9, 1.0),
    link: Color(0xFF8AB4F8),
    tableHeaderBackground: Color(0xFF2B3445),
    tableHeaderBorder: Color(0xFF8797B2),
    selectionFill: Color.fromRGBO(0x90, 0xCA, 0xF9, 0.3),
    highlightFill: Color.fromRGBO(0x4C, 0x3B, 0x00, 0.55),
    pageNumber: Color.fromRGBO(0xD9, 0xD9, 0xD9, 0.55),
    placeholder: Color.fromRGBO(0xD9, 0xD9, 0xD9, 0.45),
  );

  static const sepia = ReaderPalette(
    background: Color.fromRGBO(0xF5, 0xEB, 0xD6, 1.0),
    foreground: Color.fromRGBO(0x4D, 0x33, 0x1A, 1.0),
    link: Color(0xFF683D00),
    tableHeaderBackground: Color(0xFFE5D6BA),
    tableHeaderBorder: Color(0xFF6B542E),
    selectionFill: Color.fromRGBO(0x90, 0xCA, 0xF9, 0.4),
    highlightFill: Color.fromRGBO(0xFF, 0xE6, 0x9A, 0.45),
    pageNumber: Color.fromRGBO(0x4D, 0x33, 0x1A, 0.55),
    placeholder: Color.fromRGBO(0x4D, 0x33, 0x1A, 0.45),
  );

  static ReaderPalette of(ReaderTheme theme) => switch (theme) {
    ReaderTheme.light => light,
    ReaderTheme.dark => dark,
    ReaderTheme.sepia => sepia,
  };
}

/// Highlight colors available to the reader (RD-12 palette order).
enum ReaderHighlightColor { yellow, green, blue, pink, purple }

Color highlightColor(ReaderHighlightColor color) => switch (color) {
  ReaderHighlightColor.yellow => const Color.fromRGBO(0xFF, 0xE0, 0x66, 0.5),
  ReaderHighlightColor.green => const Color.fromRGBO(0x9C, 0xE0, 0x9C, 0.5),
  ReaderHighlightColor.blue => const Color.fromRGBO(0x90, 0xCA, 0xF9, 0.5),
  ReaderHighlightColor.pink => const Color.fromRGBO(0xF8, 0xB8, 0xE0, 0.5),
  ReaderHighlightColor.purple => const Color.fromRGBO(0xC9, 0xB8, 0xF9, 0.5),
};
