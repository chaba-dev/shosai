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
  const CssDeclaration(
    this.property,
    this.value, {
    this.important = false,
    this.inline = false,
  });

  final String property;
  final String value;
  final bool important;

  /// Whether the declaration came from a `style` attribute.
  ///
  /// The production inline parser terminates a quoted value at a raw newline
  /// (the stylesheet parser continues the line), which changes the derived
  /// monospace role.
  final bool inline;
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
    final sanitized = stripCssComments(source);
    var index = 0;
    while (index < sanitized.length) {
      final open = _indexOfOutsideStrings(sanitized, 0x7B, index);
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

int _findBlockEnd(String source, int open) {
  var depth = 0;
  var index = open;
  while (index < source.length) {
    final unit = source.codeUnitAt(index);
    if (unit == 0x5C && index + 1 < source.length) {
      // An escaped quote outside a string is content, not a string opener.
      index += 2;
      continue;
    }
    if (unit == 0x22 || unit == 0x27) {
      // A quoted string is one token: a brace inside it is content, not a
      // block boundary. The scan mirrors the tokenizer's escape handling, so
      // an escaped quote does not end the string.
      final quote = unit;
      index += 1;
      while (index < source.length) {
        final inner = source.codeUnitAt(index);
        if (inner == 0x5C && index + 1 < source.length) {
          index += 2;
          continue;
        }
        index += 1;
        if (inner == quote) break;
      }
      continue;
    }
    if (unit == 0x7B) {
      depth += 1;
    } else if (unit == 0x7D) {
      depth -= 1;
      if (depth == 0) return index;
    }
    index += 1;
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

/// Splits a declaration value from its `!important` flag.
///
/// The production declaration parser accepts `!`, optional whitespace and
/// comments, then the `important` identifier with escapes decoded,
/// case-insensitively.
({String value, bool important}) splitCssImportant(String raw) {
  final withoutComments = stripCssComments(raw).trimRight();
  final bang = _lastIndexOfOutsideStrings(withoutComments, 0x21);
  if (bang < 0) return (value: withoutComments.trim(), important: false);
  final suffix = decodeCssEscapes(withoutComments.substring(bang + 1)).trim();
  if (suffix.toLowerCase() != 'important') {
    return (value: withoutComments.trim(), important: false);
  }
  return (value: withoutComments.substring(0, bang).trim(), important: true);
}

/// Splits a declaration list on semicolons that are outside quoted strings.
///
/// The production parser tokenizes the list, so a `;` inside a value does not
/// end the declaration.
List<String> splitCssDeclarations(String body) {
  final declarations = <String>[];
  final current = StringBuffer();
  var index = 0;
  while (index < body.length) {
    final unit = body.codeUnitAt(index);
    if (unit == 0x5C && index + 1 < body.length) {
      // A backslash escapes the next character outside strings too, so an
      // escaped `;` stays in the declaration.
      current.writeCharCode(unit);
      current.writeCharCode(body.codeUnitAt(index + 1));
      index += 2;
      continue;
    }
    if (unit == 0x22 || unit == 0x27) {
      final quote = unit;
      current.writeCharCode(unit);
      index += 1;
      while (index < body.length) {
        final inner = body.codeUnitAt(index);
        current.writeCharCode(inner);
        index += 1;
        if (inner == 0x5C && index < body.length) {
          current.writeCharCode(body.codeUnitAt(index));
          index += 1;
          continue;
        }
        if (inner == quote) break;
      }
      continue;
    }
    if (unit == 0x3B) {
      declarations.add(current.toString());
      current.clear();
      index += 1;
      continue;
    }
    current.writeCharCode(unit);
    index += 1;
  }
  declarations.add(current.toString());
  return declarations;
}

/// The first index of [unit] in [source] at or after [start] that is outside
/// quoted strings, or -1.
int _indexOfOutsideStrings(String source, int unit, int start) {
  var index = start;
  while (index < source.length) {
    final current = source.codeUnitAt(index);
    if (current == 0x5C && index + 1 < source.length) {
      // A backslash escapes the next character outside strings too: an
      // escaped quote never opens a string.
      index += 2;
      continue;
    }
    if (current == 0x22 || current == 0x27) {
      final quote = current;
      index += 1;
      while (index < source.length) {
        final inner = source.codeUnitAt(index);
        if (inner == 0x5C && index + 1 < source.length) {
          index += 2;
          continue;
        }
        index += 1;
        if (inner == quote) break;
      }
      continue;
    }
    if (current == unit) return index;
    index += 1;
  }
  return -1;
}

/// The last index of [unit] in [source] that is outside quoted strings.
int _lastIndexOfOutsideStrings(String source, int unit) {
  var result = -1;
  var index = 0;
  while (index < source.length) {
    final current = source.codeUnitAt(index);
    if (current == 0x5C && index + 1 < source.length) {
      // An escaped character is content, so it never counts as the flag.
      index += 2;
      continue;
    }
    if (current == 0x22 || current == 0x27) {
      final quote = current;
      index += 1;
      while (index < source.length) {
        final inner = source.codeUnitAt(index);
        if (inner == 0x5C && index + 1 < source.length) {
          index += 2;
          continue;
        }
        index += 1;
        if (inner == quote) break;
      }
      continue;
    }
    if (current == unit) result = index;
    index += 1;
  }
  return result;
}

/// Removes CSS comments that are outside quoted strings.
String stripCssComments(String source) {
  final out = StringBuffer();
  var index = 0;
  while (index < source.length) {
    final unit = source.codeUnitAt(index);
    if (unit == 0x5C && index + 1 < source.length) {
      // An escaped quote is content, not a string opener, so the comment that
      // follows it is still a comment.
      out.writeCharCode(unit);
      out.writeCharCode(source.codeUnitAt(index + 1));
      index += 2;
      continue;
    }
    if (unit == 0x22 || unit == 0x27) {
      final quote = unit;
      out.writeCharCode(unit);
      index += 1;
      while (index < source.length) {
        final current = source.codeUnitAt(index);
        out.writeCharCode(current);
        index += 1;
        if (current == 0x5C && index < source.length) {
          out.writeCharCode(source.codeUnitAt(index));
          index += 1;
          continue;
        }
        if (current == quote) break;
      }
      continue;
    }
    if (unit == 0x2F &&
        index + 1 < source.length &&
        source.codeUnitAt(index + 1) == 0x2A) {
      final end = source.indexOf('*/', index + 2);
      index = end < 0 ? source.length : end + 2;
      // A comment separates tokens, so it leaves a single space behind.
      out.writeCharCode(0x20);
      continue;
    }
    out.writeCharCode(unit);
    index += 1;
  }
  return out.toString();
}

/// Decodes CSS escapes (`\XXXXXX ` hex or `\c`) in one token.
///
/// A backslash followed by a newline is a line continuation and is dropped,
/// like the production tokenizer.
String decodeCssEscapes(String source) {
  final out = StringBuffer();
  var index = 0;
  while (index < source.length) {
    final unit = source.codeUnitAt(index);
    if (unit != 0x5C) {
      out.writeCharCode(unit);
      index += 1;
      continue;
    }
    index += 1;
    if (index >= source.length) break;
    if (_isCssNewline(source.codeUnitAt(index))) {
      index += 1;
      continue;
    }
    var value = 0;
    var digits = 0;
    while (index < source.length && digits < 6) {
      final digit = _hexDigit(source.codeUnitAt(index));
      if (digit < 0) break;
      value = value * 16 + digit;
      index += 1;
      digits += 1;
    }
    if (digits == 0) {
      // A literal escaped character.
      out.writeCharCode(source.codeUnitAt(index));
      index += 1;
      continue;
    }
    if (index < source.length && _isCssWhitespace(source.codeUnitAt(index))) {
      index += 1;
    }
    if (value == 0 ||
        value > 0x10FFFF ||
        (value >= 0xD800 && value <= 0xDFFF)) {
      out.writeCharCode(0xFFFD);
    } else {
      out.writeCharCode(value);
    }
  }
  return out.toString();
}

/// The named families of a `font-family` value, with CSS escapes decoded, and
/// whether the value names a monospace family — the production
/// `named_font_families` and `has_monospace_family`.
({List<String> families, bool monospace}) parseFontFamilies(
  String value, {
  bool inline = false,
}) {
  if (inline && _hasNewlineInString(value)) {
    return (families: const <String>[], monospace: false);
  }
  final families = <String>[];
  var monospace = false;
  for (final token in _fontFamilyTokens(stripCssComments(value))) {
    final lower = token.name.toLowerCase();
    if (!token.quoted && _genericFontFamilies.contains(lower)) {
      if (lower == 'monospace' || lower == 'ui-monospace') monospace = true;
      continue;
    }
    if (lower.contains('mono')) monospace = true;
    families.add(token.name);
  }
  return (families: families, monospace: monospace);
}

const Set<String> _genericFontFamilies = {
  'serif',
  'sans-serif',
  'monospace',
  'cursive',
  'fantasy',
  'system-ui',
  'ui-serif',
  'ui-sans-serif',
  'ui-monospace',
  'ui-rounded',
  'emoji',
  'math',
  'fangsong',
};

/// One `font-family` token: its decoded name and whether it was quoted.
typedef _FontFamilyToken = ({String name, bool quoted});

/// Splits a `font-family` value into decoded family tokens.
List<_FontFamilyToken> _fontFamilyTokens(String value) {
  final tokens = <_FontFamilyToken>[];
  var index = 0;
  while (index < value.length) {
    final unit = value.codeUnitAt(index);
    if (_isCssWhitespace(unit) || unit == 0x2C) {
      index += 1;
      continue;
    }
    if (unit == 0x22 || unit == 0x27) {
      // A quoted string: escapes decode, and the quote itself ends the token.
      final quote = unit;
      final buffer = StringBuffer();
      index += 1;
      while (index < value.length) {
        final current = value.codeUnitAt(index);
        if (current == 0x5C && index + 1 < value.length) {
          // Keep the escape for the decoder; only the quote check is skipped.
          buffer.write(value[index]);
          buffer.write(value[index + 1]);
          index += 2;
          continue;
        }
        if (current == quote) {
          index += 1;
          break;
        }
        buffer.writeCharCode(current);
        index += 1;
      }
      final token = decodeCssEscapes(buffer.toString()).trim();
      if (token.isNotEmpty) tokens.add((name: token, quoted: true));
      continue;
    }
    // An unquoted identifier sequence; escapes decode and identifiers join
    // with a single space.
    final start = index;
    while (index < value.length) {
      final current = value.codeUnitAt(index);
      if (current == 0x2C) break;
      index += 1;
    }
    final raw = value.substring(start, index);
    final decoded = decodeCssEscapes(raw).trim();
    if (decoded.isEmpty) continue;
    tokens.add((name: decoded.split(RegExp(r'\s+')).join(' '), quoted: false));
  }
  return tokens;
}

/// Whether a quoted string in [value] contains a raw newline.
bool _hasNewlineInString(String value) {
  var index = 0;
  while (index < value.length) {
    final unit = value.codeUnitAt(index);
    if (unit != 0x22 && unit != 0x27) {
      index += 1;
      continue;
    }
    final quote = unit;
    index += 1;
    while (index < value.length) {
      final current = value.codeUnitAt(index);
      if (current == 0x5C && index + 1 < value.length) {
        if (_isCssNewline(value.codeUnitAt(index + 1))) return true;
        index += 2;
        continue;
      }
      if (current == quote) break;
      if (_isCssNewline(current)) return true;
      index += 1;
    }
    index += 1;
  }
  return false;
}

bool _isCssWhitespace(int unit) =>
    unit == 0x20 ||
    unit == 0x09 ||
    unit == 0x0A ||
    unit == 0x0C ||
    unit == 0x0D;

bool _isCssNewline(int unit) => unit == 0x0A || unit == 0x0D || unit == 0x0C;

int _hexDigit(int unit) {
  if (unit >= 0x30 && unit <= 0x39) return unit - 0x30;
  if (unit >= 0x41 && unit <= 0x46) return unit - 0x41 + 10;
  if (unit >= 0x61 && unit <= 0x66) return unit - 0x61 + 10;
  return -1;
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
  for (final raw in splitCssDeclarations(stripCssComments(body))) {
    final colon = raw.indexOf(':');
    if (colon <= 0) continue;
    final property = raw.substring(0, colon).trim().toLowerCase();
    final parsed = splitCssImportant(raw.substring(colon + 1));
    if (property.isEmpty || parsed.value.isEmpty) continue;
    if (warnings != null && !kSupportedCssProperties.contains(property)) {
      warnings.add('unsupported CSS property ignored: $property');
    }
    declarations.add(
      CssDeclaration(property, parsed.value, important: parsed.important),
    );
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
