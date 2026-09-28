/// Bounded CSS parsing and cascade for the EPUB engine.
///
/// Supported: type/class/id/universal/descendant/child selectors, selector
/// lists, `!important`, inline `style`, source order, and the property subset
/// the normalized model can express (display, font-size/-family/-weight/-style,
/// text-align, direction, margins, text-indent, width/height/max-width,
/// white-space). `@font-face` is collected for embedded font admission.
///
/// Deliberately unsupported and reported as a warning, never silently applied:
/// `@media` and other at-rules, attribute/pseudo-class/pseudo-element
/// selectors, sibling combinators, CSS variables, shorthand expansion beyond
/// `margin`, and colour/background properties (the reader palette owns ink).
library;

import 'limits.dart';
import 'model.dart';

class CssDeclaration {
  const CssDeclaration(this.property, this.value, {this.important = false});

  final String property;
  final String value;
  final bool important;
}

class CssSimpleSelector {
  const CssSimpleSelector({this.tag, this.id, this.className});

  final String? tag;
  final String? id;
  final String? className;

  bool matches(String tagName, String? id, Set<String> classes) {
    if (tag != null && tag != tagName) return false;
    if (this.id != null && this.id != id) return false;
    if (className != null && !classes.contains(className)) return false;
    return true;
  }
}

/// One compound selector with an optional descendant (` `) or child (`>`)
/// combinator to its left.
class CssSelectorPart {
  const CssSelectorPart(this.compound, {this.childCombinator = false});

  final CssSimpleSelector compound;
  final bool childCombinator;
}

class CssSelector {
  CssSelector(this.parts, this.specificity);

  /// Left-to-right; the last part matches the element itself.
  final List<CssSelectorPart> parts;
  final int specificity;
}

class CssStyleRule {
  const CssStyleRule({required this.selectors, required this.declarations});

  final List<CssSelector> selectors;
  final List<CssDeclaration> declarations;
}

class CssFontFace {
  const CssFontFace({
    required this.family,
    required this.sources,
    this.weight,
    this.style,
  });

  final String family;

  /// `url(...)` targets in source order, already unquoted.
  final List<String> sources;
  final String? weight;
  final String? style;
}

class CssStylesheet {
  CssStylesheet({
    required this.rules,
    required this.fontFaces,
    required this.warnings,
  });

  final List<CssStyleRule> rules;
  final List<CssFontFace> fontFaces;
  final List<String> warnings;

  static CssStylesheet parse(String source, EpubLimits limits) {
    final rules = <CssStyleRule>[];
    final fontFaces = <CssFontFace>[];
    final warnings = <String>[];
    final sanitized = _stripComments(source);
    var index = 0;
    while (index < sanitized.length) {
      final open = sanitized.indexOf('{', index);
      if (open < 0) break;
      final prelude = sanitized.substring(index, open).trim();
      final close = _findBlockEnd(sanitized, open);
      if (close < 0) break;
      final body = sanitized.substring(open + 1, close);
      index = close + 1;
      if (prelude.isEmpty) continue;
      if (prelude.startsWith('@')) {
        final atName = prelude.split(RegExp(r'[\s(]')).first.toLowerCase();
        if (atName == '@font-face') {
          final face = _parseFontFace(body);
          if (face != null) fontFaces.add(face);
        } else if (atName != '@charset' && atName != '@import') {
          warnings.add('unsupported CSS at-rule ignored: $atName');
        }
        continue;
      }
      if (rules.length >= limits.maxCssRules) {
        throw EpubLimitError('css rules', limits.maxCssRules, rules.length + 1);
      }
      final selectors = <CssSelector>[];
      for (final rawSelector in prelude.split(',')) {
        final selector = _parseSelector(rawSelector.trim(), warnings);
        if (selector != null) selectors.add(selector);
      }
      final declarations = _parseDeclarations(body, warnings);
      if (selectors.isEmpty || declarations.isEmpty) continue;
      rules.add(CssStyleRule(selectors: selectors, declarations: declarations));
    }
    return CssStylesheet(
      rules: rules,
      fontFaces: fontFaces,
      warnings: warnings,
    );
  }
}

String _stripComments(String source) {
  final out = StringBuffer();
  var index = 0;
  while (index < source.length) {
    final start = source.indexOf('/*', index);
    if (start < 0) {
      out.write(source.substring(index));
      break;
    }
    out.write(source.substring(index, start));
    final end = source.indexOf('*/', start + 2);
    if (end < 0) break;
    index = end + 2;
  }
  return out.toString();
}

int _findBlockEnd(String source, int open) {
  var depth = 0;
  for (var index = open; index < source.length; index++) {
    final char = source[index];
    if (char == '{') depth++;
    if (char == '}') {
      depth--;
      if (depth == 0) return index;
    }
  }
  return -1;
}

CssFontFace? _parseFontFace(String body) {
  String? family;
  final sources = <String>[];
  String? weight;
  String? style;
  for (final declaration in _parseDeclarations(body)) {
    switch (declaration.property) {
      case 'font-family':
        family = declaration.value.replaceAll(RegExp(r'''^["']|["']$'''), '');
      case 'src':
        for (final match in RegExp(
          r'''url\(\s*(['"]?)([^'")]+)\1\s*\)''',
        ).allMatches(declaration.value)) {
          sources.add(match.group(2)!);
        }
      case 'font-weight':
        weight = declaration.value;
      case 'font-style':
        style = declaration.value;
    }
  }
  if (family == null || family.isEmpty || sources.isEmpty) return null;
  return CssFontFace(
    family: family,
    sources: sources,
    weight: weight,
    style: style,
  );
}

/// Properties the normalized model can express. Anything else is ignored and
/// reported once, never silently applied.
const Set<String> kSupportedCssProperties = {
  'display',
  'font-family',
  'font-size',
  'font-style',
  'font-weight',
  'height',
  'margin',
  'margin-bottom',
  'margin-left',
  'margin-top',
  'max-width',
  'text-align',
  'text-indent',
  'white-space',
  'width',
};

List<CssDeclaration> _parseDeclarations(String body, [List<String>? warnings]) {
  final declarations = <CssDeclaration>[];
  for (final raw in body.split(';')) {
    final colon = raw.indexOf(':');
    if (colon <= 0) continue;
    final property = raw.substring(0, colon).trim().toLowerCase();
    var value = raw.substring(colon + 1).trim();
    if (property.isEmpty || value.isEmpty) continue;
    var important = false;
    if (value.toLowerCase().endsWith('!important')) {
      important = true;
      value = value.substring(0, value.length - '!important'.length).trim();
    }
    if (warnings != null && !kSupportedCssProperties.contains(property)) {
      warnings.add('unsupported CSS property ignored: $property');
    }
    declarations.add(CssDeclaration(property, value, important: important));
  }
  return declarations;
}

CssSelector? _parseSelector(String raw, List<String> warnings) {
  if (raw.isEmpty) return null;
  if (raw.contains(':') ||
      raw.contains('[') ||
      raw.contains('+') ||
      raw.contains('~')) {
    warnings.add('unsupported CSS selector ignored: $raw');
    return null;
  }
  final parts = <CssSelectorPart>[];
  var specificity = 0;
  var index = 0;
  var childCombinator = false;
  while (index < raw.length) {
    final char = raw[index];
    if (char == ' ') {
      index++;
      childCombinator = false;
      continue;
    }
    if (char == '>') {
      index++;
      childCombinator = true;
      continue;
    }
    final start = index;
    while (index < raw.length && raw[index] != ' ' && raw[index] != '>') {
      index++;
    }
    final compound = raw.substring(start, index);
    final simple = _parseCompound(compound, warnings);
    if (simple == null) return null;
    if (simple.tag != null && simple.tag != '*') specificity += 1;
    if (simple.className != null) specificity += 0x10;
    if (simple.id != null) specificity += 0x100;
    parts.add(CssSelectorPart(simple, childCombinator: childCombinator));
  }
  if (parts.isEmpty) return null;
  return CssSelector(parts, specificity);
}

CssSimpleSelector? _parseCompound(String compound, List<String> warnings) {
  if (compound.isEmpty) return null;
  String? tag;
  String? id;
  String? className;
  var index = 0;
  if (compound[0] != '.' && compound[0] != '#') {
    final match = RegExp(r'^[A-Za-z][A-Za-z0-9-]*|\*').firstMatch(compound);
    if (match == null) {
      warnings.add('unsupported CSS selector ignored: $compound');
      return null;
    }
    tag = match.group(0);
    index = match.end;
  }
  while (index < compound.length) {
    final marker = compound[index];
    final match = RegExp(
      r'^[A-Za-z0-9_-]+',
    ).firstMatch(compound.substring(index + 1));
    if (match == null) {
      warnings.add('unsupported CSS selector ignored: $compound');
      return null;
    }
    final name = match.group(0)!;
    if (marker == '.') {
      className = name;
    } else if (marker == '#') {
      id = name;
    } else {
      warnings.add('unsupported CSS selector ignored: $compound');
      return null;
    }
    index += 1 + name.length;
  }
  return CssSimpleSelector(tag: tag, id: id, className: className);
}

/// Fully resolved presentation values for one element.
class EpubComputedStyle {
  const EpubComputedStyle({
    required this.display,
    required this.bold,
    required this.italic,
    required this.monospace,
    required this.preserveWhitespace,
    required this.fontFamilies,
    required this.fontSizePx,
    required this.textAlign,
    required this.direction,
    required this.marginLeftPx,
    required this.marginTopPx,
    required this.marginBottomPx,
    required this.textIndentPx,
    required this.width,
    required this.height,
    required this.maxWidth,
  });

  final EpubDisplay display;
  final bool bold;
  final bool italic;
  final bool monospace;
  final bool preserveWhitespace;
  final List<String> fontFamilies;
  final double fontSizePx;
  final EpubTextAlign textAlign;
  final EpubDirection direction;
  final double marginLeftPx;
  final double marginTopPx;
  final double marginBottomPx;
  final double textIndentPx;
  final EpubLength? width;
  final EpubLength? height;
  final EpubLength? maxWidth;

  bool get isBlockLike => display != EpubDisplay.inline;
}
