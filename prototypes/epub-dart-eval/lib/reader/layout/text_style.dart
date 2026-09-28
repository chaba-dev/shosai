/// Converts normalized EPUB spans into Flutter text styles and a code-unit →
/// canonical-scalar map for one laid-out block.
library;

import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:shosai_epub/shosai_epub.dart';

import '../theme.dart';

/// Reader typography inputs for one layout.
class ReaderTypography {
  const ReaderTypography({
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
  final ReaderPalette palette;

  /// `@font-face` family name → registered Flutter family name.
  final Map<String, String> embeddedFamilies;

  /// Family used for monospace spans without an admitted embedded face.
  final String monospaceFamily;

  ReaderTypography copyWith({
    String? fontFamily,
    List<String>? fontFamilyFallback,
    double? fontSize,
    double? lineHeight,
    ReaderPalette? palette,
    Map<String, String>? embeddedFamilies,
    String? monospaceFamily,
  }) => ReaderTypography(
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
      other is ReaderTypography &&
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
  ReaderTypography typography,
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
    final canonical = span.canonical ?? EpubCanonicalSpan(0, 0);
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
  ReaderTypography typography,
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
    fontFamilyFallback: family == null ? typography.fontFamilyFallback : null,
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
