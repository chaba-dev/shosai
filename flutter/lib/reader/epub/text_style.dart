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

  /// A [canonicalAt] for code-unit offsets asked in non-decreasing order,
  /// which reads each code unit of the block at most once in total.
  ///
  /// [canonicalAt] counts scalars from the segment's start, so asking it for
  /// every grapheme of a long span is quadratic in the span's length.
  CanonicalCursor cursor() => CanonicalCursor._(this);

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

/// [BlockTextMap.canonicalAt] answered in one pass; see
/// [BlockTextMap.cursor].
final class CanonicalCursor {
  CanonicalCursor._(this._map);

  final BlockTextMap _map;
  var _segment = 0;
  var _unit = 0;
  var _scalars = 0;
  var _last = 0;

  /// The canonical scalar at [codeUnit], as [BlockTextMap.canonicalAt]
  /// returns it. An offset before the previous one restarts the pass.
  int at(int codeUnit) {
    final segments = _map.segments;
    if (segments.isEmpty) return 0;
    if (codeUnit < _last) {
      _segment = 0;
      _unit = 0;
      _scalars = 0;
    }
    _last = codeUnit;
    if (codeUnit <= 0) return segments.first.canonicalStart;
    while (_segment < segments.length &&
        codeUnit > segments[_segment].codeUnitEnd) {
      _segment++;
      _unit = 0;
      _scalars = 0;
    }
    if (_segment == segments.length) return _map.canonicalEnd;
    final segment = segments[_segment];
    final text = segment.text;
    final local = (codeUnit - segment.codeUnitStart).clamp(
      0,
      segment.codeUnitLength,
    );
    // A prefix's scalar count, as `String.runes` gives it: every code unit
    // but the low half of a surrogate pair.
    for (; _unit < local; _unit++) {
      final unit = text.codeUnitAt(_unit);
      final secondHalf =
          unit >= 0xDC00 &&
          unit <= 0xDFFF &&
          _unit > 0 &&
          _isHighSurrogate(text.codeUnitAt(_unit - 1));
      if (!secondHalf) _scalars++;
    }
    return segment.canonicalStart + _scalars;
  }

  static bool _isHighSurrogate(int unit) => unit >= 0xD800 && unit <= 0xDBFF;
}

/// A run of a vertical block's characters that stand upright in their column.
///
/// A vertical block is laid out as horizontal lines on a frame turned a
/// quarter turn clockwise, so its text reads top to bottom and its lines stack
/// right to left; Latin letters and the brackets and dashes that CSS rotates
/// in vertical text come out sideways, as they should. Kanji, kana and the
/// other characters that stand upright (UAX #50's `U` and `Tu`) are laid out
/// in the same line for their advance and line breaking, painted transparent,
/// and drawn again upright over their own boxes (see
/// [FlowTextBlock.paint]).
class UprightRun {
  const UprightRun({
    required this.start,
    required this.end,
    required this.style,
  });

  /// Painter code units of the run.
  final int start;
  final int end;

  /// The run's own style, with its ink: the laid-out text is transparent.
  final TextStyle style;
}

/// Whether [rune] stands upright in vertical text.
///
/// A compact reading of UAX #50 (Vertical Text Layout) for the scripts a
/// vertical book sets: CJK ideographs, kana, Hangul, full-width forms and the
/// symbols set in an ideographic em square are upright; Latin, digits and
/// the brackets, long vowel mark, dashes, ellipses and tildes rotate with the
/// line. The `Tu` characters (the ideographic comma and full stop, the small
/// kana) are upright and take their vertical forms from the font's `vert`
/// feature when they are drawn.
bool isUprightInVertical(int rune) {
  if (rune < 0x00A7) return false;
  if (rune == 0x00A7 || rune == 0x00A9 || rune == 0x00AE) return true;
  if (rune == 0x00B1 || rune == 0x00D7 || rune == 0x00F7) return true;
  if (rune < 0x1100) return false;
  if (rune <= 0x11FF) return true; // Hangul Jamo
  if (rune == 0x203B || rune == 0x2020 || rune == 0x2021) return true;
  if (rune >= 0x2460 && rune <= 0x24FF) return true; // enclosed numbers
  if (rune >= 0x25A0 && rune <= 0x27BF) return true; // shapes, symbols
  if (rune >= 0x2E80 && rune <= 0x2FFF) return true; // radicals
  if (rune >= 0x3000 && rune <= 0x303F) {
    // Brackets, the wave dash and the double prime quotes rotate.
    return !((rune >= 0x3008 && rune <= 0x3011) ||
        (rune >= 0x3014 && rune <= 0x301F) ||
        rune == 0x3030);
  }
  if (rune >= 0x3040 && rune <= 0x30FF) {
    // The long vowel mark and the double hyphen rotate.
    return rune != 0x30FC && rune != 0x30A0;
  }
  if (rune >= 0x3100 && rune <= 0x9FFF) return true; // ideographs and more
  if (rune >= 0xA960 && rune <= 0xA97F) return true;
  if (rune >= 0xAC00 && rune <= 0xD7FF) return true; // Hangul
  if (rune >= 0xF900 && rune <= 0xFAFF) return true;
  if (rune >= 0xFE10 && rune <= 0xFE1F) return true; // vertical forms
  if (rune >= 0xFE30 && rune <= 0xFE4F) return true;
  if (rune >= 0xFF01 && rune <= 0xFF60) {
    // Full-width brackets, hyphen, colons, comparison signs, low line, braces,
    // vertical line and tilde rotate.
    return !(rune == 0xFF08 ||
        rune == 0xFF09 ||
        rune == 0xFF0D ||
        (rune >= 0xFF1A && rune <= 0xFF1E) ||
        rune == 0xFF3B ||
        rune == 0xFF3D ||
        rune == 0xFF3F ||
        rune >= 0xFF5B);
  }
  if (rune >= 0xFFE0 && rune <= 0xFFE6) return true;
  if (rune >= 0x1F000 && rune <= 0x1FAFF) return true; // emoji
  if (rune >= 0x20000 && rune <= 0x3FFFF) return true; // ideographs
  return false;
}

/// Build the Flutter span tree for a list of engine spans.
///
/// Each span's canonical mapping is preserved in [segments]; the returned
/// [TextSpan] is the exact text laid out by the painter. With [vertical] the
/// upright characters are laid out transparent and returned as [UprightRun]s
/// for [FlowTextBlock.paint] to draw upright.
({InlineSpan span, BlockTextMap map, List<UprightRun> upright}) buildBlockText(
  List<EpubTextSpan> spans,
  ReaderEpubTypography typography,
  double baseFontSize, {
  bool selectableOverride = true,
  int codeUnitOffset = 0,
  bool vertical = false,
}) {
  final buffer = StringBuffer();
  final segments = <TextMapSegment>[];
  final children = <TextSpan>[];
  final upright = <UprightRun>[];
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
    final style = spanStyle(span, typography, baseFontSize);
    if (!vertical) {
      children.add(TextSpan(text: span.text, style: style));
      continue;
    }
    final hidden = style.copyWith(
      color: typography.palette.foreground.withValues(alpha: 0),
    );
    var runStart = 0;
    bool? runUpright;
    void flush(int end) {
      if (runUpright == null || end <= runStart) return;
      final text = span.text.substring(runStart, end);
      if (runUpright) {
        children.add(TextSpan(text: text, style: hidden));
        upright.add(
          UprightRun(
            start: start + codeUnitOffset + runStart,
            end: start + codeUnitOffset + end,
            style: style,
          ),
        );
      } else {
        children.add(TextSpan(text: text, style: style));
      }
      runStart = end;
    }

    var unit = 0;
    for (final rune in span.text.runes) {
      final isUpright = isUprightInVertical(rune);
      if (runUpright != isUpright) {
        flush(unit);
        runUpright = isUpright;
      }
      unit += rune > 0xFFFF ? 2 : 1;
    }
    flush(unit);
  }
  return (
    span: TextSpan(children: children),
    map: BlockTextMap(
      buffer.toString(),
      segments,
      codeUnitOffset: codeUnitOffset,
    ),
    upright: upright,
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
