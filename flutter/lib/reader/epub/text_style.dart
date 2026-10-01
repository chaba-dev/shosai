/// Converts normalized EPUB spans into Flutter text styles and a code-unit →
/// canonical-scalar map for one laid-out block.
///
/// This is the reader's production port of the evaluated prototype layout
/// (`prototypes/epub-dart-eval/lib/reader/layout/text_style.dart`): the block
/// text map and the monotone `canonicalAtAll` pass are the same algorithm, and
/// the palette now comes from the reader's own design tokens instead of the
/// prototype's local theme file.
library;

import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:shosai_epub/shosai_epub.dart';
import 'package:shosai_flutter/theme_tokens.dart';

/// The reader's document palette for the active reader theme.
///
/// These are the pinned `reader.*` Iced palettes
/// ([shosaiReaderDocumentColors] in `app_theme.dart`); the link and table
/// colors are the same token source, so the Dart layout paints the document
/// with the palette the retained renderer uses.
class ReaderEpubPalette {
  const ReaderEpubPalette({
    required this.background,
    required this.foreground,
    required this.link,
    required this.tableHeaderBackground,
    required this.tableHeaderBorder,
  });

  final Color background;
  final Color foreground;
  final Color link;
  final Color tableHeaderBackground;
  final Color tableHeaderBorder;

  /// The palette for a reader theme name (`light`, `dark`, `sepia`).
  factory ReaderEpubPalette.of(String? theme) => switch (theme) {
    'dark' => const ReaderEpubPalette(
      background: ShosaiTokens.readerDarkBackground,
      foreground: ShosaiTokens.readerDarkText,
      link: ShosaiTokens.readerDarkLink,
      tableHeaderBackground: ShosaiTokens.readerDarkTableHeaderBackground,
      tableHeaderBorder: ShosaiTokens.readerDarkTableHeaderBorder,
    ),
    'sepia' => const ReaderEpubPalette(
      background: ShosaiTokens.readerSepiaBackground,
      foreground: ShosaiTokens.readerSepiaText,
      link: ShosaiTokens.readerSepiaLink,
      tableHeaderBackground: ShosaiTokens.readerLightTableHeaderBackground,
      tableHeaderBorder: ShosaiTokens.readerLightTableHeaderBorder,
    ),
    _ => const ReaderEpubPalette(
      background: ShosaiTokens.readerLightBackground,
      foreground: ShosaiTokens.readerLightText,
      link: ShosaiTokens.readerLightLink,
      tableHeaderBackground: ShosaiTokens.readerLightTableHeaderBackground,
      tableHeaderBorder: ShosaiTokens.readerLightTableHeaderBorder,
    ),
  };

  @override
  bool operator ==(Object other) =>
      other is ReaderEpubPalette &&
      other.background == background &&
      other.foreground == foreground &&
      other.link == link &&
      other.tableHeaderBackground == tableHeaderBackground &&
      other.tableHeaderBorder == tableHeaderBorder;

  @override
  int get hashCode => Object.hash(
    background,
    foreground,
    link,
    tableHeaderBackground,
    tableHeaderBorder,
  );
}

/// Reader typography inputs for one EPUB layout.
///
/// The palette is part of the value: document pixels keep the palette they were
/// laid out with, so a theme change relayouts instead of repainting a live
/// background behind text that still carries the previous colors.
class ReaderEpubTypography {
  const ReaderEpubTypography({
    required this.fontFamily,
    required this.fontFamilyFallback,
    required this.fontSize,
    required this.lineHeight,
    required this.palette,
    this.embeddedFamilies = const {},
    this.monospaceFamily = 'monospace',
  });

  /// Base content family (reader preference).
  final String fontFamily;
  final List<String> fontFamilyFallback;
  final double fontSize;
  final double lineHeight;
  final ReaderEpubPalette palette;

  /// `@font-face` family name → registered Flutter family name.
  final Map<String, String> embeddedFamilies;

  /// Family used for monospace spans without an admitted embedded face.
  final String monospaceFamily;

  ReaderEpubTypography copyWith({
    String? fontFamily,
    List<String>? fontFamilyFallback,
    double? fontSize,
    double? lineHeight,
    ReaderEpubPalette? palette,
    Map<String, String>? embeddedFamilies,
    String? monospaceFamily,
  }) => ReaderEpubTypography(
    fontFamily: fontFamily ?? this.fontFamily,
    fontFamilyFallback: fontFamilyFallback ?? this.fontFamilyFallback,
    fontSize: fontSize ?? this.fontSize,
    lineHeight: lineHeight ?? this.lineHeight,
    palette: palette ?? this.palette,
    embeddedFamilies: embeddedFamilies ?? this.embeddedFamilies,
    monospaceFamily: monospaceFamily ?? this.monospaceFamily,
  );

  @override
  bool operator ==(Object other) =>
      other is ReaderEpubTypography &&
      other.fontFamily == fontFamily &&
      other.fontSize == fontSize &&
      other.lineHeight == lineHeight &&
      other.palette == palette &&
      other.monospaceFamily == monospaceFamily &&
      _mapEquals(other.embeddedFamilies, embeddedFamilies) &&
      _listEquals(other.fontFamilyFallback, fontFamilyFallback);

  @override
  int get hashCode => Object.hash(
    fontFamily,
    Object.hashAll(fontFamilyFallback),
    fontSize,
    lineHeight,
    palette,
    monospaceFamily,
    Object.hashAll(embeddedFamilies.entries.map((e) => '${e.key}=${e.value}')),
  );
}

bool _mapEquals(Map<String, String> a, Map<String, String> b) {
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (b[entry.key] != entry.value) return false;
  }
  return true;
}

bool _listEquals(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var index = 0; index < a.length; index++) {
    if (a[index] != b[index]) return false;
  }
  return true;
}

/// One code-unit range of a laid-out block mapped to canonical scalars.
class TextMapSegment {
  const TextMapSegment({
    required this.codeUnitStart,
    required this.codeUnitEnd,
    required this.canonicalStart,
    required this.text,
    required this.selectable,
    this.link,
  });

  final int codeUnitStart;
  final int codeUnitEnd;
  final int canonicalStart;
  final String text;
  final bool selectable;

  /// Source link href for this span, if any.
  final String? link;

  int get codeUnitLength => codeUnitEnd - codeUnitStart;
}

/// Code-unit ↔ canonical scalar mapping for one block's concatenated text.
class BlockTextMap {
  BlockTextMap(this.text, this.segments, {this.codeUnitOffset = 0});

  final String text;
  final List<TextMapSegment> segments;

  /// Code units prepended to the laid-out string outside this map (for
  /// example a generated list marker); painter offsets are shifted by it.
  final int codeUnitOffset;

  bool get isEmpty => text.isEmpty;

  /// Total code units of the laid-out string.
  int get codeUnitLength => codeUnitOffset + text.length;

  int get canonicalStart =>
      segments.isEmpty ? 0 : segments.first.canonicalStart;

  int get canonicalEnd {
    if (segments.isEmpty) return 0;
    final last = segments.last;
    return last.canonicalStart + last.text.runes.length;
  }

  /// Canonical scalar at a UTF-16 code-unit offset, clamped to the block.
  int canonicalAt(int codeUnit) {
    if (segments.isEmpty) return 0;
    if (codeUnit <= 0) return segments.first.canonicalStart;
    for (final segment in segments) {
      if (codeUnit <= segment.codeUnitEnd) {
        final local = (codeUnit - segment.codeUnitStart).clamp(
          0,
          segment.codeUnitLength,
        );
        return segment.canonicalStart + _scalarCount(segment.text, local);
      }
    }
    return canonicalEnd;
  }

  /// Code-unit offset for a canonical scalar, clamped to the block.
  int codeUnitAt(int canonical) {
    if (segments.isEmpty) return 0;
    if (canonical <= segments.first.canonicalStart) {
      return segments.first.codeUnitStart;
    }
    for (final segment in segments) {
      final end = segment.canonicalStart + segment.text.runes.length;
      if (canonical <= end) {
        final local = codeUnitAtScalar(
          segment.text,
          canonical - segment.canonicalStart,
        );
        return segment.codeUnitStart + local;
      }
    }
    return text.length + codeUnitOffset;
  }

  /// Canonical scalars for a monotonically non-decreasing list of code-unit
  /// offsets, computed in one pass over the text.
  ///
  /// The per-offset [canonicalAt] lookup counts scalars from the segment start,
  /// which is O(text) on a single huge span; a laid-out line walk calls it twice
  /// per line, so a very long paragraph made layout quadratic in its length.
  /// This monotone pass is the merged prototype optimization and is what keeps
  /// a chapter with one very long paragraph bounded.
  List<int> canonicalAtAll(List<int> codeUnits) {
    if (segments.isEmpty) {
      return List<int>.filled(codeUnits.length, 0);
    }
    final result = List<int>.filled(codeUnits.length, 0);
    var unit = 0;
    var scalar = segments.first.canonicalStart;
    for (var index = 0; index < codeUnits.length; index++) {
      final target = (codeUnits[index] - codeUnitOffset).clamp(0, text.length);
      while (unit < target) {
        final codeUnit = text.codeUnitAt(unit);
        unit +=
            codeUnit >= 0xD800 && codeUnit <= 0xDBFF && unit + 1 < text.length
            ? 2
            : 1;
        scalar++;
      }
      result[index] = scalar;
    }
    return result;
  }

  /// Whether every canonical scalar in the range is selectable.
  bool rangeSelectable(int canonicalStart, int canonicalEnd) {
    for (final segment in segments) {
      final segmentEnd = segment.canonicalStart + segment.text.runes.length;
      if (segmentEnd <= canonicalStart) continue;
      if (segment.canonicalStart >= canonicalEnd) break;
      if (!segment.selectable) return false;
    }
    return true;
  }

  static int _scalarCount(String text, int codeUnitLength) {
    if (codeUnitLength <= 0) return 0;
    if (codeUnitLength >= text.length) return text.runes.length;
    return text.substring(0, codeUnitLength).runes.length;
  }
}

/// Build the Flutter span tree for a list of engine spans.
///
/// Each span's canonical mapping is preserved in [segments]; the returned
/// [TextSpan] is the exact text laid out by the painter.
({InlineSpan span, BlockTextMap map}) buildBlockText(
  List<EpubTextSpan> spans,
  ReaderEpubTypography typography,
  double baseFontSize, {
  bool selectableOverride = true,
  int codeUnitOffset = 0,
}) {
  final buffer = StringBuffer();
  final segments = <TextMapSegment>[];
  final children = <TextSpan>[];
  for (final span in spans) {
    if (span.text.isEmpty) continue;
    final start = buffer.length;
    buffer.write(span.text);
    final canonical = span.canonical ?? const EpubCanonicalSpan(0, 0);
    segments.add(
      TextMapSegment(
        codeUnitStart: start + codeUnitOffset,
        codeUnitEnd: buffer.length + codeUnitOffset,
        canonicalStart: canonical.start,
        text: span.text,
        selectable: span.selectable && selectableOverride,
        link: span.link,
      ),
    );
    children.add(
      TextSpan(
        text: span.text,
        style: spanStyle(span, typography, baseFontSize),
      ),
    );
  }
  return (
    span: TextSpan(children: children),
    map: BlockTextMap(
      buffer.toString(),
      segments,
      codeUnitOffset: codeUnitOffset,
    ),
  );
}

/// Flutter style for one engine span.
TextStyle spanStyle(
  EpubTextSpan span,
  ReaderEpubTypography typography,
  double baseFontSize,
) {
  final palette = typography.palette;
  final embedded = span.fontFamily == null
      ? null
      : typography.embeddedFamilies[span.fontFamily!];
  // A span that asks for a monospace face without an admitted embedded family
  // uses the platform monospace family.
  final family =
      embedded ?? (span.monospace ? typography.monospaceFamily : null);
  final size = baseFontSize * span.fontSizeMultiplier;
  return TextStyle(
    fontFamily: family ?? typography.fontFamily,
    // A span that selects an embedded (or monospace) face keeps the bundled
    // chain behind it, primary face first: the routing gate only promises the
    // *bundled* faces can draw the chapter, and an admitted face may be
    // Latin-only, so dropping the chain could paint missing glyphs for text the
    // gate admitted.
    fontFamilyFallback: family == null
        ? typography.fontFamilyFallback
        : [typography.fontFamily, ...typography.fontFamilyFallback],
    fontSize: size,
    height: typography.lineHeight,
    fontWeight: span.bold ? FontWeight.w700 : FontWeight.w400,
    fontStyle: span.italic ? FontStyle.italic : FontStyle.normal,
    color: palette.foreground,
    decoration: span.link != null ? TextDecoration.underline : null,
    decorationColor: palette.link,
    leadingDistribution: TextLeadingDistribution.even,
  );
}

/// Code-unit offset of canonical scalar [scalar] in [text], clamped to the
/// string length. Canonical offsets count Unicode scalars, not UTF-16 units.
int codeUnitAtScalar(String text, int scalar) {
  if (scalar <= 0) return 0;
  var count = 0;
  var index = 0;
  while (index < text.length && count < scalar) {
    final unit = text.codeUnitAt(index);
    index += unit >= 0xD800 && unit <= 0xDBFF ? 2 : 1;
    count++;
  }
  return index;
}

/// Map an engine text alignment to Flutter's.
TextAlign flutterTextAlign(EpubTextAlign align) => switch (align) {
  EpubTextAlign.start => TextAlign.start,
  EpubTextAlign.center => TextAlign.center,
  EpubTextAlign.end => TextAlign.end,
  EpubTextAlign.justify => TextAlign.justify,
};

/// Map an engine direction to Flutter's.
ui.TextDirection flutterTextDirection(EpubDirection direction) =>
    direction == EpubDirection.rtl
    ? ui.TextDirection.rtl
    : ui.TextDirection.ltr;
