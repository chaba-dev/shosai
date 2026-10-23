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

import 'package:characters/characters.dart';
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

/// A run of a block's characters that the painter lays out transparent and
/// [FlowTextBlock.paint] draws again itself, each grapheme centred on its own
/// laid-out box.
///
/// A vertical block is laid out as horizontal lines on a frame turned a
/// quarter turn clockwise, so its text reads top to bottom and its lines stack
/// right to left; Latin letters and the brackets and dashes that CSS rotates
/// in vertical text come out sideways, as they should. Kanji, kana and the
/// other characters that stand upright (UAX #50's `U` and `Tu`) are laid out
/// in the same line for their advance and line breaking, and drawn [upright]:
/// turned back, in the font's vertical forms.
///
/// A [combined] run is tate-chū-yoko: its text is laid out one em long, and
/// drawn upright and side by side in that em square.
///
/// A ruby base that is shorter than its annotation is laid out with letter
/// spacing that makes it as long; its graphemes are redrawn centred in their
/// widened boxes, so the base spreads evenly under the annotation.
class RedrawnRun {
  const RedrawnRun({
    required this.start,
    required this.end,
    required this.style,
    this.upright = true,
    this.combined = false,
  });

  /// Painter code units of the run.
  final int start;
  final int end;

  /// The run's own style, with its ink: the laid-out text is transparent.
  final TextStyle style;

  /// Whether the run is turned back to stand upright in a vertical line.
  final bool upright;

  /// Whether the run is drawn as one unit, its characters side by side.
  final bool combined;
}

/// A ruby annotation: the painter code units of its base, and the annotation's
/// own laid-out text, which [FlowTextBlock.paint] sets over the base (to its
/// right in a vertical line).
class RubyRun {
  const RubyRun({
    required this.start,
    required this.end,
    required this.baseSize,
    required this.annotation,
  });

  /// Painter code units of the base.
  final int start;
  final int end;

  /// The base's font size: its em square, which the annotation stands on.
  final double baseSize;

  /// The annotation's text, half the base's size, as [buildBlockText] built
  /// it; its upright characters are redrawn as a vertical block's are.
  final BuiltBlockText annotation;
}

/// The ruby annotation's size, relative to its base.
const double rubyScale = 0.5;

/// Whether [rune] is drawn upright in vertical text.
///
/// A compact reading of UAX #50 (Vertical Text Layout) for the scripts a
/// vertical book sets. Upright (`U`) are CJK ideographs, kana, Hangul,
/// full-width forms and the symbols set in an ideographic em square; Latin,
/// digits and the dashes and ellipses (`R`) rotate with the line.
///
/// The `Tu` characters (the ideographic comma and full stop, the small kana)
/// and the `Tr` ones (the CJK brackets, the wave dash, the long vowel mark,
/// the full-width parentheses, colon and tilde) are drawn upright too: they
/// take their vertical forms from the font's `vert` feature, which turns a
/// `Tr` bracket or long vowel mark into its designed vertical glyph. Flutter's
/// text API does not tell whether a font has those forms; Shippori Mincho, the
/// fallback for Japanese, has them, as fonts made for vertical text do.
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
  if (rune >= 0x3000 && rune <= 0x9FFF) return true; // CJK, kana, ideographs
  if (rune >= 0xA960 && rune <= 0xA97F) return true;
  if (rune >= 0xAC00 && rune <= 0xD7FF) return true; // Hangul
  if (rune >= 0xF900 && rune <= 0xFAFF) return true;
  if (rune >= 0xFE10 && rune <= 0xFE1F) return true; // vertical forms
  if (rune >= 0xFE30 && rune <= 0xFE48) return true; // vertical compatibility
  if (rune >= 0xFE50 && rune <= 0xFE6F) {
    // The small em dash, hyphen-minus and comparison signs rotate (`R`).
    return !(rune == 0xFE58 || (rune >= 0xFE63 && rune <= 0xFE66));
  }
  if (rune >= 0xFF01 && rune <= 0xFF60) {
    // The full-width hyphen and comparison signs rotate (`R`).
    return !(rune == 0xFF0D || (rune >= 0xFF1C && rune <= 0xFF1E));
  }
  if (rune >= 0xFFE0 && rune <= 0xFFE6) return true;
  if (rune >= 0x1B000 && rune <= 0x1B2FF) return true; // kana supplements
  if (rune >= 0x1F000 && rune <= 0x1FAFF) return true; // emoji
  if (rune >= 0x20000 && rune <= 0x3FFFF) return true; // ideographs
  return false;
}

/// What [buildBlockText] builds: the span tree the painter lays out, its
/// canonical map, the runs [FlowTextBlock.paint] draws itself and the ruby it
/// sets over the text.
typedef BuiltBlockText = ({
  InlineSpan span,
  BlockTextMap map,
  List<RedrawnRun> redrawn,
  List<RubyRun> rubies,
});

/// Build the Flutter span tree for a list of engine spans.
///
/// Each span's canonical mapping is preserved in [segments]; the returned
/// [TextSpan] is the exact text laid out by the painter. With [vertical] the
/// upright characters are laid out transparent and returned as [RedrawnRun]s
/// for [FlowTextBlock.paint] to draw upright. A span with ruby returns a
/// [RubyRun], and its base is spaced out (and redrawn) when the annotation is
/// longer.
BuiltBlockText buildBlockText(
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
  final redrawn = <RedrawnRun>[];
  final rubies = <RubyRun>[];
  // The children of each tate-chū-yoko grapheme: its span, the index of its
  // run's first grapheme here, and the advance it must take.
  final graphemes = <({int child, int span, int run, double em})>[];
  for (var spanIndex = 0; spanIndex < spans.length; spanIndex++) {
    final span = spans[spanIndex];
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
    final hidden = style.copyWith(
      color: typography.palette.foreground.withValues(alpha: 0),
    );
    final combined = span.combine;
    final combinesAll = vertical && combined != null && combined.all;

    // A base shorter than its ruby is spaced out to the ruby's length, and
    // its graphemes are redrawn centred in their widened boxes.
    double? spacing;
    final ruby = span.ruby;
    if (ruby != null) {
      // A base can continue over the next spans (markup inside it); its
      // annotation stands over all of them.
      var baseEnd = buffer.length;
      var next = spanIndex + 1;
      while (next < spans.length && spans[next].rubyContinued) {
        baseEnd += spans[next].text.length;
        next++;
      }
      final continued = next > spanIndex + 1;
      final annotation = buildBlockText(
        [
          EpubTextSpan(
            text: ruby,
            bold: span.bold,
            italic: span.italic,
            monospace: span.monospace,
            fontFamily: span.fontFamily,
            fontSizeMultiplier: span.fontSizeMultiplier * rubyScale,
          ),
        ],
        typography.copyWith(lineHeight: 1),
        baseFontSize,
        selectableOverride: false,
        vertical: vertical,
      );
      rubies.add(
        RubyRun(
          start: start + codeUnitOffset,
          end: baseEnd + codeUnitOffset,
          baseSize: style.fontSize ?? baseFontSize,
          annotation: annotation,
        ),
      );
      // Only a base of one span whose characters stand alone (kanji, kana)
      // is spaced out and redrawn a character at a time; any other keeps its
      // shaping (joining, ligatures) and its annotation overhangs it.
      final extra = _width(annotation.span) - _width(span.text, style);
      if (extra > 0 &&
          !combinesAll &&
          !continued &&
          span.text.runes.every(isUprightInVertical)) {
        spacing = extra / span.text.characters.length;
      }
    }
    if (!vertical) {
      if (spacing == null) {
        children.add(TextSpan(text: span.text, style: style));
        continue;
      }
      children.add(
        TextSpan(
          text: span.text,
          style: hidden.copyWith(letterSpacing: spacing),
        ),
      );
      redrawn.add(
        RedrawnRun(
          start: start + codeUnitOffset,
          end: buffer.length + codeUnitOffset,
          style: style,
          upright: false,
        ),
      );
      continue;
    }
    final spaced = spacing == null
        ? hidden
        : hidden.copyWith(letterSpacing: spacing);
    var runStart = 0;
    bool? runUpright;
    void flush(int end) {
      final isUpright = runUpright;
      if (isUpright == null || end <= runStart) return;
      final text = span.text.substring(runStart, end);
      if (isUpright || spacing != null) {
        children.add(TextSpan(text: text, style: spaced));
        redrawn.add(
          RedrawnRun(
            start: start + codeUnitOffset + runStart,
            end: start + codeUnitOffset + end,
            style: style,
            upright: isUpright,
          ),
        );
      } else {
        children.add(TextSpan(text: text, style: style));
      }
      runStart = end;
    }

    void combine(int from, int to) {
      // The first grapheme advances one em and the others nothing, so the
      // run takes one character's place and keeps its text's own line
      // breaking rules and line height; a flow that breaks a line inside it
      // anyway lays it out again without it. Each grapheme alternates a value on
      // an axis no font has, which draws nothing differently but keeps the
      // paragraph from shaping it with its neighbours (ligatures, kerning).
      // Its advance, still shaped in context (joining forms), is measured in
      // the laid-out block below and cancelled by its letter spacing. The run
      // is drawn with its normal shaping.
      final first = graphemes.length;
      var index = 0;
      for (final grapheme in span.text.substring(from, to).characters) {
        graphemes.add((
          child: children.length,
          span: spanIndex,
          run: first,
          em: index == 0 ? style.fontSize! : 0,
        ));
        children.add(
          TextSpan(
            text: grapheme,
            style: hidden.copyWith(
              fontVariations: [
                ...?style.fontVariations,
                ui.FontVariation(
                  _shapingBoundaryAxis,
                  (graphemes.length % 2).toDouble(),
                ),
              ],
            ),
          ),
        );
        index++;
      }
      redrawn.add(
        RedrawnRun(
          start: start + codeUnitOffset + from,
          end: start + codeUnitOffset + to,
          style: style,
          combined: true,
        ),
      );
      runStart = to;
      runUpright = null;
    }

    if (combinesAll) {
      combine(0, span.text.length);
      continue;
    }
    // Orientation applies to whole grapheme clusters (UAX #50, 3.2.1): a
    // variation selector, a combining mark or an emoji joined by ZWJ goes
    // with its base, so the upright repaint shapes what the line shaped.
    final digits = combined == null || spacing != null
        ? const <({int start, int end})>[]
        : _digitRuns(span.text, combined.digits);
    var nextDigits = 0;
    var unit = 0;
    for (final cluster in span.text.characters) {
      if (nextDigits < digits.length && unit == digits[nextDigits].start) {
        flush(unit);
        combine(unit, digits[nextDigits].end);
        nextDigits++;
      }
      if (unit < runStart) {
        unit += cluster.length;
        continue;
      }
      final isUpright = isUprightInVertical(cluster.runes.first);
      if (runUpright != isUpright) {
        flush(unit);
        runUpright = isUpright;
      }
      unit += cluster.length;
    }
    flush(unit);
  }
  if (graphemes.isNotEmpty) {
    final unspaced = _graphemeAdvances(children, graphemes);
    for (final (index, grapheme) in graphemes.indexed) {
      final child = children[grapheme.child];
      children[grapheme.child] = TextSpan(
        text: child.text,
        style: child.style!.copyWith(
          letterSpacing: grapheme.em - unspaced[index],
        ),
      );
    }
    // A text engine may not space every script (Flutter leaves an Arabic
    // run's letter spacing out): a span whose run is not one em long is
    // built again without tate-chū-yoko, and turns with the line as other
    // horizontal script does.
    final spaced = _graphemeAdvances(children, graphemes);
    final runs = <int, double>{};
    for (final (index, grapheme) in graphemes.indexed) {
      runs[grapheme.run] = (runs[grapheme.run] ?? 0) + spaced[index];
    }
    final failed = {
      for (final MapEntry(key: run, value: advance) in runs.entries)
        if ((advance - graphemes[run].em).abs() > 0.01) graphemes[run].span,
    };
    if (failed.isNotEmpty) {
      return buildBlockText(
        [
          for (final (index, span) in spans.indexed)
            failed.contains(index) ? (span.copy()..combine = null) : span,
        ],
        typography,
        baseFontSize,
        selectableOverride: selectableOverride,
        codeUnitOffset: codeUnitOffset,
        vertical: vertical,
      );
    }
  }
  return (
    span: TextSpan(children: children),
    map: BlockTextMap(
      buffer.toString(),
      segments,
      codeUnitOffset: codeUnitOffset,
    ),
    redrawn: redrawn,
    rubies: rubies,
  );
}

/// [spans] with tate-chū-yoko turned off on the spans that hold [runs],
/// which [buildBlockText] built from them at [codeUnitOffset].
List<EpubTextSpan> withoutCombining(
  List<EpubTextSpan> spans,
  Iterable<RedrawnRun> runs, {
  int codeUnitOffset = 0,
}) {
  final result = <EpubTextSpan>[];
  var start = codeUnitOffset;
  for (final span in spans) {
    final end = start + span.text.length;
    final holds = runs.any((run) => run.start >= start && run.start < end);
    result.add(holds ? (span.copy()..combine = null) : span);
    start = end;
  }
  return result;
}

/// A variation axis no font defines. A tate-chū-yoko run's transparent
/// layout alternates its value from grapheme to grapheme so the paragraph
/// shapes each grapheme alone.
const String _shapingBoundaryAxis = 'ZTCY';

/// The advance each tate-chū-yoko grapheme of [combined] takes when
/// [children] are laid out in one line.
List<double> _graphemeAdvances(
  List<TextSpan> children,
  List<({int child, int span, int run, double em})> combined,
) {
  final measure = TextPainter(
    text: TextSpan(children: children),
    textDirection: ui.TextDirection.ltr,
  )..layout();
  final starts = <int>[];
  var unit = 0;
  for (final child in children) {
    starts.add(unit);
    unit += child.text!.length;
  }
  final advances = [
    for (final grapheme in combined)
      measure
          .getBoxesForSelection(
            TextSelection(
              baseOffset: starts[grapheme.child],
              extentOffset:
                  starts[grapheme.child] +
                  children[grapheme.child].text!.length,
            ),
          )
          .fold(0.0, (width, box) => width + box.right - box.left),
  ];
  measure.dispose();
  return advances;
}

/// The laid-out width of [text]: a span tree, or a string set in [style].
double _width(Object text, [TextStyle? style]) {
  final measure = TextPainter(
    text: text is InlineSpan ? text : TextSpan(text: '$text', style: style),
    textDirection: ui.TextDirection.ltr,
  )..layout();
  final width = measure.width;
  measure.dispose();
  return width;
}

/// The runs of ASCII digits in [text] that `text-combine-upright: digits`
/// combines: those no longer than [longest].
///
/// Runs are found on grapheme boundaries, so a run never ends inside a
/// cluster. A digit that carries a mark or a keycap still counts towards its
/// run's length, but its run does not combine.
List<({int start, int end})> _digitRuns(String text, int longest) {
  bool isDigit(int unit) => unit >= 0x30 && unit <= 0x39;
  final runs = <({int start, int end})>[];
  var unit = 0;
  int? start;
  var count = 0;
  var plain = true;
  void close() {
    final runStart = start;
    if (runStart != null && plain && count <= longest) {
      runs.add((start: runStart, end: unit));
    }
    start = null;
  }

  for (final cluster in text.characters) {
    if (isDigit(cluster.codeUnitAt(0))) {
      if (start == null) {
        start = unit;
        count = 0;
        plain = true;
      }
      count++;
      plain = plain && cluster.length == 1;
    } else {
      close();
    }
    unit += cluster.length;
  }
  close();
  return runs;
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
