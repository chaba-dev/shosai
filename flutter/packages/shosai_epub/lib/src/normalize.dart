/// XHTML → normalized content model, ported from the production Rust
/// `epub::render` parser with bounded, documented simplifications.
///
/// Known deviations from the Rust implementation are listed in
/// `prototypes/epub-dart-eval/README.md`; they remain open parity work rather
/// than accepted permanent differences. They are repeated here where they
/// affect behaviour:
/// - nested lists flatten into their parent item (the Rust parser does the
///   same, but the whitespace-collapse unit differs slightly);
/// - `@media`/`@import`/attribute/pseudo selectors are not applied.
///
/// Display-block MathML inside a paragraph is promoted into sibling nodes with
/// the production parser's generated separators, so the canonical stream and
/// its anchor offsets match the retained Rust stream for that case.
library;

import 'package:xml/xml.dart';

import 'canonical.dart';
import 'css.dart';
import 'limits.dart';
import 'model.dart';
import 'paths.dart';

/// Maximum element nesting depth the normalizer will walk.
const int _maxDepth = 64;

class NormalizedChapter {
  const NormalizedChapter({
    required this.nodes,
    required this.anchors,
    required this.warnings,
  });

  final List<EpubContentNode> nodes;

  /// Element id/name to canonical scalar offset, resolved after the canonical
  /// walk assigns offsets.
  final Map<String, int> anchors;
  final List<String> warnings;
}

/// Normalize one chapter document.
///
/// [xhtml] is the decoded content document, [chapterPath] its canonical
/// archive path, and [stylesheets] the admitted author stylesheets.
NormalizedChapter normalizeChapter({
  required String xhtml,
  required String chapterPath,
  required List<CssStylesheet> stylesheets,
  required EpubLimits limits,
}) {
  final warnings = <String>[];
  final resolved = resolveNamedEntities(xhtml, warnings);
  final XmlDocument document;
  try {
    document = XmlDocument.parse(resolved);
  } on XmlException catch (error) {
    throw EpubFormatError(
      'failed to parse EPUB chapter XHTML at '
      '$chapterPath: ${error.message}',
    );
  }
  final computed = computeDocumentStyles(document, stylesheets, limits);
  final body = document.descendants.whereType<XmlElement>().firstWhere(
    (element) => element.name.local == 'body',
    orElse: () => document.rootElement,
  );
  if (computed[body]?.display == EpubDisplay.none) {
    return NormalizedChapter(
      nodes: const [],
      anchors: const {},
      warnings: warnings,
    );
  }
  final context = _NormalizeContext(
    basePath: _directoryOf(chapterPath),
    styles: computed,
    limits: limits,
    warnings: warnings,
  );
  context.noteAnchor(body);
  final nodes = context.parseBlocks(body, 0);
  context.flushPendingAnchors();
  final builder = CanonicalTextBuilder(maxScalars: limits.maxCanonicalScalars);
  final canonical = builder.build(nodes);
  for (final name in context.unresolvedAnchors) {
    builder.anchors.putIfAbsent(name, () => canonical.scalarCount);
  }
  return NormalizedChapter(
    nodes: nodes,
    anchors: builder.anchors,
    warnings: warnings,
  );
}

String _directoryOf(String path) {
  final slash = path.lastIndexOf('/');
  return slash < 0 ? '' : path.substring(0, slash);
}

// ---------------------------------------------------------------------------
// Named entity resolution
// ---------------------------------------------------------------------------

/// Bounded HTML5 named entity table. XML's own five entities are left to the
/// parser. Unknown named entities are left as-is so the XML parser reports the
/// malformed document rather than silently dropping text.
const Map<String, String> _namedEntities = {
  'nbsp': '\u00a0',
  'iexcl': '¡',
  'cent': '¢',
  'pound': '£',
  'curren': '¤',
  'yen': '¥',
  'sect': '§',
  'copy': '©',
  'laquo': '«',
  'reg': '®',
  'deg': '°',
  'plusmn': '±',
  'middot': '·',
  'raquo': '»',
  'frac14': '¼',
  'frac12': '½',
  'frac34': '¾',
  'iquest': '¿',
  'times': '×',
  'divide': '÷',
  'szlig': 'ß',
  'agrave': 'à',
  'aacute': 'á',
  'auml': 'ä',
  'aring': 'å',
  'aelig': 'æ',
  'ccedil': 'ç',
  'egrave': 'è',
  'eacute': 'é',
  'ouml': 'ö',
  'ugrave': 'ù',
  'uuml': 'ü',
  'ntilde': 'ñ',
  'oelig': 'œ',
  'shy': '\u00ad',
  'ensp': '\u2002',
  'emsp': '\u2003',
  'thinsp': '\u2009',
  'zwnj': '\u200c',
  'zwj': '\u200d',
  'ndash': '–',
  'mdash': '—',
  'lsquo': '‘',
  'rsquo': '’',
  'sbquo': '‚',
  'ldquo': '“',
  'rdquo': '”',
  'bdquo': '„',
  'dagger': '†',
  'Dagger': '‡',
  'bull': '•',
  'hellip': '…',
  'permil': '‰',
  'prime': '′',
  'Prime': '″',
  'lsaquo': '‹',
  'rsaquo': '›',
  'oline': '‾',
  'frasl': '⁄',
  'euro': '€',
  'trade': '™',
  'larr': '←',
  'uarr': '↑',
  'rarr': '→',
  'darr': '↓',
  'harr': '↔',
  'minus': '−',
  'lowast': '∗',
  'radic': '√',
  'infin': '∞',
  'ne': '≠',
  'le': '≤',
  'ge': '≥',
  'alpha': 'α',
  'beta': 'β',
  'gamma': 'γ',
  'delta': 'δ',
  'epsilon': 'ε',
  'lambda': 'λ',
  'mu': 'μ',
  'pi': 'π',
  'sigma': 'σ',
  'tau': 'τ',
  'phi': 'φ',
  'omega': 'ω',
  'Alpha': 'Α',
  'Beta': 'Β',
  'Gamma': 'Γ',
  'Delta': 'Δ',
  'Omega': 'Ω',
};

/// Resolve the bounded named-entity table outside CDATA/comments/PIs and
/// outside the DOCTYPE declaration.
String resolveNamedEntities(String xhtml, List<String> warnings) {
  if (!xhtml.contains('&')) return xhtml;
  final out = StringBuffer();
  var index = 0;
  while (index < xhtml.length) {
    final remaining = xhtml.substring(index);
    if (remaining.startsWith('<!--')) {
      final end = xhtml.indexOf('-->', index);
      final stop = end < 0 ? xhtml.length : end + 3;
      out.write(xhtml.substring(index, stop));
      index = stop;
      continue;
    }
    if (remaining.startsWith('<![CDATA[')) {
      final end = xhtml.indexOf(']]>', index);
      final stop = end < 0 ? xhtml.length : end + 3;
      out.write(xhtml.substring(index, stop));
      index = stop;
      continue;
    }
    if (remaining.startsWith('<!DOCTYPE')) {
      final end = _doctypeEnd(xhtml, index);
      final stop = end < 0 ? xhtml.length : end;
      // Custom entity declarations are not expanded: an unknown entity then
      // surfaces as a parse error instead of silently losing text.
      out.write(xhtml.substring(index, stop));
      index = stop;
      continue;
    }
    if (remaining.startsWith('&')) {
      final end = xhtml.indexOf(';', index);
      if (end < 0) {
        out.write(remaining);
        break;
      }
      final name = xhtml.substring(index + 1, end);
      final replacement = name.startsWith('#') ? null : _namedEntities[name];
      if (replacement != null) {
        out.write(replacement);
      } else {
        out.write(xhtml.substring(index, end + 1));
      }
      index = end + 1;
      continue;
    }
    out.write(xhtml[index]);
    index++;
  }
  return out.toString();
}

int _doctypeEnd(String source, int start) {
  var quote = '';
  var subsetDepth = 0;
  for (var index = start; index < source.length; index++) {
    final char = source[index];
    if (quote.isNotEmpty) {
      if (char == quote) quote = '';
      continue;
    }
    if (char == '"' || char == "'") {
      quote = char;
      continue;
    }
    if (char == '[') subsetDepth++;
    if (char == ']') subsetDepth--;
    if (char == '>' && subsetDepth <= 0) return index + 1;
  }
  return -1;
}

// ---------------------------------------------------------------------------
// Cascade
// ---------------------------------------------------------------------------

/// Compute a fully resolved style for every element in document order.
Map<XmlElement, EpubComputedStyle> computeDocumentStyles(
  XmlDocument document,
  List<CssStylesheet> stylesheets,
  EpubLimits limits,
) {
  final rules = <(CssStyleRule, int)>[];
  var order = 0;
  for (final sheet in stylesheets) {
    for (final rule in sheet.rules) {
      rules.add((rule, order++));
    }
  }
  final computed = <XmlElement, EpubComputedStyle>{};
  void visit(XmlElement element, EpubComputedStyle parent, int depth) {
    if (depth > _maxDepth) return;
    final style = _computeElementStyle(element, parent, rules);
    computed[element] = style;
    for (final child in element.children.whereType<XmlElement>()) {
      visit(child, style, depth + 1);
    }
  }

  visit(document.rootElement, _initialStyle(), 0);
  return computed;
}

EpubComputedStyle _initialStyle() => const EpubComputedStyle(
  display: EpubDisplay.inline,
  bold: false,
  italic: false,
  monospace: false,
  preserveWhitespace: false,
  fontFamilies: [],
  fontSizePx: 16.0,
  textAlign: EpubTextAlign.start,
  direction: EpubDirection.ltr,
  marginLeftPx: 0,
  marginTopPx: 0,
  marginBottomPx: 0,
  textIndentPx: 0,
  width: null,
  height: null,
  maxWidth: null,
);

EpubComputedStyle _computeElementStyle(
  XmlElement element,
  EpubComputedStyle parent,
  List<(CssStyleRule, int)> rules,
) {
  var style = parent;
  final tag = element.name.local.toLowerCase();
  style = _applyUaDefaults(style, tag);
  if (element.getAttribute('dir')?.toLowerCase() == 'rtl') {
    style = _copyWith(style, direction: EpubDirection.rtl);
  } else if (element.getAttribute('dir')?.toLowerCase() == 'ltr') {
    style = _copyWith(style, direction: EpubDirection.ltr);
  }

  final classes = (element.getAttribute('class') ?? '')
      .split(RegExp(r'\s+'))
      .where((value) => value.isNotEmpty)
      .toSet();
  final id = element.getAttribute('id');

  final matching = <(int, int, int, CssDeclaration)>[];
  for (final (rule, order) in rules) {
    for (final selector in rule.selectors) {
      if (_selectorMatches(selector, element, tag, id, classes)) {
        for (final declaration in rule.declarations) {
          matching.add((
            declaration.important ? 1 : 0,
            selector.specificity,
            order,
            declaration,
          ));
        }
        break;
      }
    }
  }
  final inlineStyle = element.getAttribute('style');
  if (inlineStyle != null && inlineStyle.isNotEmpty) {
    for (final declaration in parseInlineDeclarations(inlineStyle)) {
      matching.add((
        declaration.important ? 1 : 0,
        0x1000,
        1 << 30,
        declaration,
      ));
    }
  }
  matching.sort((a, b) {
    if (a.$1 != b.$1) return a.$1.compareTo(b.$1);
    if (a.$2 != b.$2) return a.$2.compareTo(b.$2);
    return a.$3.compareTo(b.$3);
  });
  for (final entry in matching) {
    style = _applyDeclaration(style, entry.$4, parent);
  }
  return style;
}

List<CssDeclaration> parseInlineDeclarations(String source) {
  final declarations = <CssDeclaration>[];
  for (final raw in source.split(';')) {
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
    declarations.add(CssDeclaration(property, value, important: important));
  }
  return declarations;
}

bool _selectorMatches(
  CssSelector selector,
  XmlElement element,
  String tag,
  String? id,
  Set<String> classes,
) {
  var current = element;
  for (var index = selector.parts.length - 1; index >= 0; index--) {
    final part = selector.parts[index];
    if (index == selector.parts.length - 1) {
      if (!part.compound.matches(tag, id, classes)) return false;
      continue;
    }
    // Walk to the next matching ancestor.
    final parent = current.parentElement;
    if (parent == null) return false;
    if (part.childCombinator) {
      final parentTag = parent.name.local.toLowerCase();
      final parentClasses = (parent.getAttribute('class') ?? '')
          .split(RegExp(r'\s+'))
          .where((value) => value.isNotEmpty)
          .toSet();
      if (!part.compound.matches(
        parentTag,
        parent.getAttribute('id'),
        parentClasses,
      )) {
        return false;
      }
      current = parent;
    } else {
      XmlElement? ancestor = parent;
      var matched = false;
      while (ancestor != null) {
        final ancestorTag = ancestor.name.local.toLowerCase();
        final ancestorClasses = (ancestor.getAttribute('class') ?? '')
            .split(RegExp(r'\s+'))
            .where((value) => value.isNotEmpty)
            .toSet();
        if (part.compound.matches(
          ancestorTag,
          ancestor.getAttribute('id'),
          ancestorClasses,
        )) {
          current = ancestor;
          matched = true;
          break;
        }
        ancestor = ancestor.parentElement;
      }
      if (!matched) return false;
    }
  }
  return true;
}

EpubComputedStyle _applyUaDefaults(EpubComputedStyle style, String tag) {
  var display = style.display;
  switch (tag) {
    case 'html':
    case 'body':
    case 'article':
    case 'aside':
    case 'blockquote':
    case 'div':
    case 'figure':
    case 'figcaption':
    case 'footer':
    case 'h1':
    case 'h2':
    case 'h3':
    case 'h4':
    case 'h5':
    case 'h6':
    case 'header':
    case 'main':
    case 'nav':
    case 'ol':
    case 'p':
    case 'pre':
    case 'section':
    case 'ul':
      display = EpubDisplay.block;
    case 'table':
      display = EpubDisplay.block;
    case 'thead':
    case 'tbody':
    case 'tfoot':
    case 'tr':
    case 'td':
    case 'th':
    case 'caption':
      display = EpubDisplay.block;
    case 'li':
      display = EpubDisplay.block;
  }
  var bold = style.bold;
  var italic = style.italic;
  var monospace = style.monospace;
  var preserve = style.preserveWhitespace;
  var fontSize = style.fontSizePx;
  switch (tag) {
    case 'h1':
      bold = true;
      fontSize *= 2.0;
    case 'h2':
      bold = true;
      fontSize *= 1.6;
    case 'h3':
      bold = true;
      fontSize *= 1.3;
    case 'h4':
      bold = true;
      fontSize *= 1.1;
    case 'h5':
    case 'h6':
    case 'strong':
    case 'b':
    case 'th':
      bold = true;
    case 'em':
    case 'i':
    case 'cite':
      italic = true;
    case 'code':
    case 'kbd':
    case 'pre':
    case 'samp':
    case 'tt':
      monospace = true;
      preserve = tag == 'pre';
  }
  return _copyWith(
    style,
    display: display,
    bold: bold,
    italic: italic,
    monospace: monospace,
    preserveWhitespace: preserve,
    fontSizePx: fontSize,
  );
}

EpubComputedStyle _applyDeclaration(
  EpubComputedStyle style,
  CssDeclaration declaration,
  EpubComputedStyle parent,
) {
  final value = declaration.value.trim();
  final lower = value.toLowerCase();
  switch (declaration.property) {
    case 'display':
      if (lower == 'none') return _copyWith(style, display: EpubDisplay.none);
      if (lower == 'inline') {
        return _copyWith(style, display: EpubDisplay.inline);
      }
      if (lower == 'block' ||
          lower == 'table' ||
          lower == 'table-row' ||
          lower == 'table-cell' ||
          lower == 'list-item') {
        return _copyWith(style, display: EpubDisplay.block);
      }
      return style;
    case 'font-size':
      final resolved = _resolveLength(
        value,
        parentFontSize: parent.fontSizePx,
        ownFontSize: style.fontSizePx,
        rootFontSize: 16.0,
      );
      if (resolved == null || resolved < 0) return style;
      return _copyWith(style, fontSizePx: resolved);
    case 'font-family':
      final families = _splitFontFamilies(value);
      return _copyWith(style, fontFamilies: families);
    case 'font-weight':
      if (lower == 'bold' || lower == 'bolder') {
        return _copyWith(style, bold: true);
      }
      if (lower == 'normal' || lower == 'lighter') {
        return _copyWith(style, bold: false);
      }
      final numeric = int.tryParse(value);
      if (numeric != null) return _copyWith(style, bold: numeric >= 600);
      return style;
    case 'font-style':
      if (lower == 'italic' || lower == 'oblique') {
        return _copyWith(style, italic: true);
      }
      if (lower == 'normal') return _copyWith(style, italic: false);
      return style;
    case 'white-space':
      if (lower == 'pre' || lower == 'pre-wrap' || lower == 'pre-line') {
        return _copyWith(style, preserveWhitespace: true);
      }
      if (lower == 'normal' || lower == 'nowrap') {
        return _copyWith(style, preserveWhitespace: false);
      }
      return style;
    case 'text-align':
      return switch (lower) {
        'left' || 'start' => _copyWith(style, textAlign: EpubTextAlign.start),
        'right' || 'end' => _copyWith(style, textAlign: EpubTextAlign.end),
        'center' => _copyWith(style, textAlign: EpubTextAlign.center),
        'justify' => _copyWith(style, textAlign: EpubTextAlign.justify),
        _ => style,
      };
    case 'direction':
      if (lower == 'rtl') return _copyWith(style, direction: EpubDirection.rtl);
      if (lower == 'ltr') return _copyWith(style, direction: EpubDirection.ltr);
      return style;
    case 'margin':
      final parts = value.split(RegExp(r'\s+'));
      final top = _resolveLength(
        parts.first,
        parentFontSize: parent.fontSizePx,
        ownFontSize: style.fontSizePx,
        rootFontSize: 16.0,
      );
      final bottom = _resolveLength(
        parts.length > 2 ? parts[2] : parts.first,
        parentFontSize: parent.fontSizePx,
        ownFontSize: style.fontSizePx,
        rootFontSize: 16.0,
      );
      var result = style;
      if (top != null) {
        result = _copyWith(result, marginTopPx: top < 0 ? 0 : top);
      }
      if (bottom != null) {
        result = _copyWith(result, marginBottomPx: bottom < 0 ? 0 : bottom);
      }
      if (parts.length > 3) {
        final left = _resolveLength(
          parts[3],
          parentFontSize: parent.fontSizePx,
          ownFontSize: style.fontSizePx,
          rootFontSize: 16.0,
        );
        if (left != null) result = _copyWith(result, marginLeftPx: left);
      }
      return result;
    case 'margin-left':
      final resolved = _resolveLength(
        value,
        parentFontSize: parent.fontSizePx,
        ownFontSize: style.fontSizePx,
        rootFontSize: 16.0,
      );
      if (resolved == null) return style;
      return _copyWith(style, marginLeftPx: resolved);
    case 'margin-top':
      final resolved = _resolveLength(
        value,
        parentFontSize: parent.fontSizePx,
        ownFontSize: style.fontSizePx,
        rootFontSize: 16.0,
      );
      if (resolved == null) return style;
      return _copyWith(style, marginTopPx: resolved < 0 ? 0 : resolved);
    case 'margin-bottom':
      final resolved = _resolveLength(
        value,
        parentFontSize: parent.fontSizePx,
        ownFontSize: style.fontSizePx,
        rootFontSize: 16.0,
      );
      if (resolved == null) return style;
      return _copyWith(style, marginBottomPx: resolved < 0 ? 0 : resolved);
    case 'text-indent':
      final resolved = _resolveLength(
        value,
        parentFontSize: parent.fontSizePx,
        ownFontSize: style.fontSizePx,
        rootFontSize: 16.0,
      );
      if (resolved == null) return style;
      return _copyWith(style, textIndentPx: resolved);
    case 'width':
      final length = _resolveCssLength(value);
      return length == null ? style : _copyWith(style, width: length);
    case 'height':
      final length = _resolveCssLength(value);
      return length == null ? style : _copyWith(style, height: length);
    case 'max-width':
      final length = _resolveCssLength(value);
      return length == null ? style : _copyWith(style, maxWidth: length);
  }
  return style;
}

/// Resolve em/rem/px/pt/% lengths. Percentages resolve only where the caller
/// supplies a base; `%` for font-size is relative to the parent font size.
double? _resolveLength(
  String value, {
  required double parentFontSize,
  required double ownFontSize,
  required double rootFontSize,
}) {
  final trimmed = value.trim().toLowerCase();
  if (trimmed.isEmpty) return null;
  if (trimmed.endsWith('%')) {
    final number = double.tryParse(trimmed.substring(0, trimmed.length - 1));
    return number == null ? null : parentFontSize * number / 100.0;
  }
  if (trimmed.endsWith('rem')) {
    final number = double.tryParse(trimmed.substring(0, trimmed.length - 3));
    return number == null ? null : number * rootFontSize;
  }
  if (trimmed.endsWith('em')) {
    final number = double.tryParse(trimmed.substring(0, trimmed.length - 2));
    return number == null ? null : number * ownFontSize;
  }
  if (trimmed.endsWith('pt')) {
    final number = double.tryParse(trimmed.substring(0, trimmed.length - 2));
    return number == null ? null : number * 96.0 / 72.0;
  }
  if (trimmed.endsWith('px')) {
    return double.tryParse(trimmed.substring(0, trimmed.length - 2));
  }
  return null;
}

EpubLength? _resolveCssLength(String value) {
  final trimmed = value.trim().toLowerCase();
  if (trimmed.endsWith('%')) {
    final number = double.tryParse(trimmed.substring(0, trimmed.length - 1));
    if (number == null || number < 0) return null;
    return EpubPercentLength(number / 100.0);
  }
  final pixels = _resolveLength(
    trimmed,
    parentFontSize: 16.0,
    ownFontSize: 16.0,
    rootFontSize: 16.0,
  );
  if (pixels == null || pixels < 0) return null;
  return EpubPixelLength(pixels);
}

List<String> _splitFontFamilies(String value) {
  final families = <String>[];
  for (final raw in value.split(',')) {
    var family = raw.trim();
    if (family.isEmpty) continue;
    family = family.replaceAll(RegExp('^["\']|["\']\$'), '');
    if (family.isEmpty) continue;
    final lower = family.toLowerCase();
    if (lower == 'serif' ||
        lower == 'sans-serif' ||
        lower == 'monospace' ||
        lower == 'cursive' ||
        lower == 'fantasy' ||
        lower == 'system-ui') {
      continue;
    }
    families.add(family);
  }
  return families;
}

EpubComputedStyle _copyWith(
  EpubComputedStyle style, {
  EpubDisplay? display,
  bool? bold,
  bool? italic,
  bool? monospace,
  bool? preserveWhitespace,
  List<String>? fontFamilies,
  double? fontSizePx,
  EpubTextAlign? textAlign,
  EpubDirection? direction,
  double? marginLeftPx,
  double? marginTopPx,
  double? marginBottomPx,
  double? textIndentPx,
  EpubLength? width,
  EpubLength? height,
  EpubLength? maxWidth,
}) => EpubComputedStyle(
  display: display ?? style.display,
  bold: bold ?? style.bold,
  italic: italic ?? style.italic,
  monospace: monospace ?? style.monospace,
  preserveWhitespace: preserveWhitespace ?? style.preserveWhitespace,
  fontFamilies: fontFamilies ?? style.fontFamilies,
  fontSizePx: fontSizePx ?? style.fontSizePx,
  textAlign: textAlign ?? style.textAlign,
  direction: direction ?? style.direction,
  marginLeftPx: marginLeftPx ?? style.marginLeftPx,
  marginTopPx: marginTopPx ?? style.marginTopPx,
  marginBottomPx: marginBottomPx ?? style.marginBottomPx,
  textIndentPx: textIndentPx ?? style.textIndentPx,
  width: width ?? style.width,
  height: height ?? style.height,
  maxWidth: maxWidth ?? style.maxWidth,
);

// ---------------------------------------------------------------------------
// Block parsing
// ---------------------------------------------------------------------------

class _NormalizeContext {
  _NormalizeContext({
    required this.basePath,
    required this.styles,
    required this.limits,
    required this.warnings,
  });

  final String basePath;
  final Map<XmlElement, EpubComputedStyle> styles;
  final EpubLimits limits;
  final List<String> warnings;

  /// Element ids whose anchor position has not yet been emitted. The next
  /// emitted span or node receives them, matching the production rule that an
  /// anchor points at the next canonical content position.
  final List<String> _pendingAnchors = [];

  /// Anchors that never met a following content position; they resolve to the
  /// chapter end.
  final List<String> unresolvedAnchors = [];

  void flushPendingAnchors() {
    unresolvedAnchors.addAll(_pendingAnchors);
    _pendingAnchors.clear();
  }

  void _takePending(EpubContentNode node) {
    if (_pendingAnchors.isEmpty) return;
    node.anchorIds = List.of(_pendingAnchors);
    _pendingAnchors.clear();
  }

  /// Anchors recorded after the last emitted content (for example a trailing
  /// `<a id="…"/>` marker) resolve to the block's end, not its start: the
  /// production parser keeps their source offset and shifts it past the
  /// generated separators.
  void _takeTrailingPending(EpubContentNode node) {
    if (_pendingAnchors.isEmpty) return;
    node.endAnchorIds = List.of(_pendingAnchors);
    _pendingAnchors.clear();
  }

  void _takePendingSpan(EpubTextSpan span) {
    if (_pendingAnchors.isEmpty) return;
    span.anchorIds = List.of(_pendingAnchors);
    _pendingAnchors.clear();
  }

  void _noteAnchor(XmlElement element) {
    final id = element.getAttribute('id');
    if (id != null) _pendingAnchors.add(id);
    if (element.name.local == 'a') {
      final name = element.getAttribute('name');
      if (name != null) _pendingAnchors.add(name);
    }
  }

  /// Public entry point for the document body (and its own anchors).
  void noteAnchor(XmlElement element) => _noteAnchor(element);

  EpubComputedStyle styleOf(XmlElement element) =>
      styles[element] ?? _initialStyle();

  List<EpubContentNode> parseBlocks(XmlElement parent, int depth) {
    final nodes = <EpubContentNode>[];
    if (depth > _maxDepth) return nodes;
    for (final child in parent.children) {
      if (child is XmlText) {
        final text = child.value.trim();
        if (text.isNotEmpty) {
          final node = EpubParagraph([
            EpubTextSpan(text: text),
          ], const EpubNodeStyle());
          _takePending(node);
          nodes.add(node);
        }
        continue;
      }
      if (child is! XmlElement) continue;
      final style = styleOf(child);
      if (style.display == EpubDisplay.none) continue;
      _noteAnchor(child);
      final produced = _parseElement(child, style, depth);
      nodes.addAll(produced);
    }
    return nodes;
  }

  List<EpubContentNode> _parseElement(
    XmlElement element,
    EpubComputedStyle style,
    int depth,
  ) {
    final tag = element.name.local.toLowerCase();
    switch (tag) {
      case 'h1':
      case 'h2':
      case 'h3':
      case 'h4':
      case 'h5':
      case 'h6':
        final spans = _inlineSpans(element, style.fontSizePx, null);
        if (spans.isEmpty) return const [];
        final node = EpubHeading(
          level: int.parse(tag.substring(1)),
          spans: spans,
          nodeStyle: _nodeStyle(style),
        );
        _takePending(node);
        return [node];
      case 'p':
        final spans = _inlineSpans(element, style.fontSizePx, null);
        if (spans.isEmpty) return const [];
        final promoted = _promoteBlockMath(spans, style);
        if (promoted == null) {
          final node = EpubParagraph(spans, _nodeStyle(style));
          _takeTrailingPending(node);
          return [node];
        }
        return promoted;
      case 'blockquote':
        final children = parseBlocks(element, depth + 1);
        if (children.isEmpty) return const [];
        final node = EpubBlockQuote(
          children: children,
          nodeStyle: _nodeStyle(style),
        );
        _takePending(node);
        return [node];
      case 'table':
        final table = _parseTable(element, style, depth);
        return table == null ? const [] : [table];
      case 'math':
        final content = parseMath(element, limits);
        final node = EpubMathNode(
          content: content,
          nodeStyle: _nodeStyle(style),
        );
        _takePending(node);
        return [node];
      case 'ul':
      case 'ol':
        final items = _parseListItems(element, depth);
        if (items.isEmpty) return const [];
        final node = tag == 'ul'
            ? EpubUnorderedList(items)
            : EpubOrderedList(
                items: items,
                start: int.tryParse(element.getAttribute('start') ?? '') ?? 1,
              );
        _takePending(node);
        return [node];
      case 'pre':
      case 'code':
        final code = _collectVisibleText(element);
        if (code.trim().isEmpty) return const [];
        final node = EpubCodeBlock(
          code: code.trim(),
          language: _languageHint(element),
        );
        _takePending(node);
        return [node];
      case 'img':
        final src = element.getAttribute('src');
        if (src == null) return const [];
        final alt = element.getAttribute('alt') ?? '';
        final resolved = _resolveRelative(basePath, src);
        if (resolved == null) {
          if (alt.isEmpty) return const [];
          final node = EpubParagraph([
            EpubTextSpan(text: alt),
          ], _nodeStyle(style));
          _takePending(node);
          return [node];
        }
        final node = EpubImage(
          src: resolved,
          alt: alt,
          nodeStyle: _nodeStyle(style),
        );
        _takePending(node);
        return [node];
      case 'svg':
        final images = element.descendants
            .whereType<XmlElement>()
            .where((node) => node.name.local == 'image')
            .toList();
        if (images.length == 1) {
          final href =
              images.first.getAttribute('href') ??
              images.first.getAttribute('xlink:href');
          if (href != null) {
            final resolved = _resolveRelative(basePath, href);
            if (resolved != null) {
              final node = EpubImage(
                src: resolved,
                alt: images.first.getAttribute('aria-label') ?? '',
                nodeStyle: _nodeStyle(style),
              );
              _takePending(node);
              return [node];
            }
          }
        }
        return const [];
      case 'hr':
        final node = EpubHorizontalRule();
        _takePending(node);
        return [node];
      case 'figure':
        final figure = _parseFigure(element, style, depth);
        if (figure != null) return [figure];
        final inner = parseBlocks(element, depth + 1);
        if (inner.isEmpty) return const [];
        final node = EpubFigure(children: inner, nodeStyle: _nodeStyle(style));
        _takePending(node);
        return [node];
      case 'figcaption':
        final spans = _captionSpans(element, style.fontSizePx);
        if (spans.isEmpty) return const [];
        final node = EpubParagraph(spans, _nodeStyle(style));
        _takePending(node);
        return [node];
      case 'div':
      case 'section':
      case 'article':
      case 'main':
      case 'aside':
      case 'header':
      case 'footer':
      case 'nav':
        final inner = parseBlocks(element, depth + 1);
        if (inner.isEmpty) return const [];
        if (style.display == EpubDisplay.inline) {
          final spans = _inlineSpans(element, style.fontSizePx, null);
          if (spans.isEmpty) return inner;
          final node = EpubParagraph(spans, _nodeStyle(style));
          _takePending(node);
          return [node];
        }
        return inner;
      default:
        final spans = _inlineSpans(element, style.fontSizePx, null);
        if (spans.isEmpty) return const [];
        final node = EpubParagraph(spans, _nodeStyle(style));
        _takePending(node);
        return [node];
    }
  }

  EpubNodeStyle _nodeStyle(EpubComputedStyle style, {double? fontSizePx}) {
    final fontPx = fontSizePx ?? style.fontSizePx;
    return EpubNodeStyle(
      textAlign: style.textAlign,
      direction: style.direction,
      fontSizeMultiplier: style.fontSizePx / 16.0,
      marginLeftEm: style.marginLeftPx == 0
          ? null
          : style.marginLeftPx / fontPx,
      blockBeforeEm: style.marginTopPx == 0 ? null : style.marginTopPx / fontPx,
      blockAfterEm: style.marginBottomPx == 0
          ? null
          : style.marginBottomPx / fontPx,
      width: style.width,
      height: style.height,
      maxWidth: style.maxWidth,
    );
  }

  List<EpubTextSpan> _inlineSpans(
    XmlElement element,
    double baseFontSize,
    String? link,
  ) {
    final spans = <EpubTextSpan>[];
    _collectInline(element, baseFontSize, link, spans, 0);
    _collapseWhitespace(spans);
    _mergeSpans(spans);
    return spans;
  }

  /// Promotes display-block MathML inside a paragraph into sibling nodes.
  ///
  /// Ports the production `epub::render` paragraph loop: the paragraph is split
  /// around each block-math span, the math node carries the `<math>` element's
  /// anchors, and the canonical stream inserts its usual separator between the
  /// resulting block nodes. Returns null when the paragraph has no block math,
  /// so the caller keeps the single-paragraph path.
  List<EpubContentNode>? _promoteBlockMath(
    List<EpubTextSpan> spans,
    EpubComputedStyle style,
  ) {
    if (!spans.any((span) => span.math?.display == EpubMathDisplay.block)) {
      return null;
    }
    final nodes = <EpubContentNode>[];
    var paragraph = <EpubTextSpan>[];
    void flushParagraph() {
      if (paragraph.isEmpty) return;
      nodes.add(EpubParagraph(paragraph, _nodeStyle(style)));
      paragraph = <EpubTextSpan>[];
    }

    for (final span in spans) {
      final math = span.math;
      if (math != null && math.display == EpubMathDisplay.block) {
        flushParagraph();
        final node = EpubMathNode(
          content: math,
          nodeStyle: _nodeStyle(style),
          link: span.link,
        );
        node.anchorIds = span.anchorIds;
        nodes.add(node);
      } else {
        paragraph.add(span);
      }
    }
    flushParagraph();
    if (nodes.isNotEmpty) _takeTrailingPending(nodes.last);
    return nodes;
  }

  void _collectInline(
    XmlElement element,
    double baseFontSize,
    String? link,
    List<EpubTextSpan> spans,
    int depth,
  ) {
    if (depth > _maxDepth) return;
    final style = styleOf(element);
    for (final child in element.children) {
      if (child is XmlText) {
        if (child.value.isEmpty) continue;
        final span = EpubTextSpan(
          text: child.value,
          bold: style.bold,
          italic: style.italic,
          monospace: style.monospace,
          fontFamily: style.fontFamilies.isEmpty
              ? null
              : style.fontFamilies.first,
          fontSizeMultiplier: style.fontSizePx / baseFontSize,
          preserveWhitespace: style.preserveWhitespace,
          link: link,
        );
        _takePendingSpan(span);
        spans.add(span);
        continue;
      }
      if (child is! XmlElement) continue;
      final childStyle = styleOf(child);
      if (childStyle.display == EpubDisplay.none) continue;
      _noteAnchor(child);
      if (child.name.local == 'math' &&
          child.name.namespaceUri == _mathmlNamespace) {
        final content = parseMath(child, limits);
        final span = EpubTextSpan(
          text: content.fallback,
          math: content,
          bold: childStyle.bold,
          italic: childStyle.italic,
          fontFamily: childStyle.fontFamilies.isEmpty
              ? null
              : childStyle.fontFamilies.first,
          fontSizeMultiplier: childStyle.fontSizePx / baseFontSize,
          link: link,
        );
        _takePendingSpan(span);
        spans.add(span);
        continue;
      }
      if (child.name.local == 'br') {
        // A preserved newline is still emitted content: pending anchors
        // recorded before it belong to its start, not to the block end.
        final span = EpubTextSpan(text: '\n', preserveWhitespace: true);
        _takePendingSpan(span);
        spans.add(span);
        continue;
      }
      _collectInline(
        child,
        baseFontSize,
        child.name.local == 'a' ? (child.getAttribute('href') ?? link) : link,
        spans,
        depth + 1,
      );
    }
  }

  void _collapseWhitespace(List<EpubTextSpan> spans) {
    var atStartOrWhitespace = true;
    for (final span in spans) {
      if (span.math != null || span.preserveWhitespace) {
        atStartOrWhitespace =
            span.text.isEmpty || _isAsciiWhitespace(span.text.runes.last);
        continue;
      }
      final normalized = StringBuffer();
      for (final rune in span.text.runes) {
        if (_isAsciiWhitespace(rune)) {
          if (!atStartOrWhitespace) {
            normalized.write(' ');
            atStartOrWhitespace = true;
          }
        } else {
          normalized.writeCharCode(rune);
          atStartOrWhitespace = false;
        }
      }
      span.text = normalized.toString();
    }
    for (var index = spans.length - 1; index >= 0; index--) {
      final span = spans[index];
      if (span.text.isEmpty || span.preserveWhitespace) continue;
      if (span.text.endsWith(' ')) {
        span.text = span.text.substring(0, span.text.length - 1);
      }
      break;
    }
    // Removing an empty span must not drop its anchors: an anchor recorded
    // before the removed span belongs to the next surviving span's start, or
    // to the end of the enclosing block when nothing follows. The production
    // parser keeps these offsets independently of the emitted spans.
    final retained = <EpubTextSpan>[];
    final carried = <String>[];
    for (final span in spans) {
      if (span.text.isEmpty) {
        carried.addAll(span.anchorIds);
        continue;
      }
      if (carried.isNotEmpty) {
        span.anchorIds = [...carried, ...span.anchorIds];
        carried.clear();
      }
      retained.add(span);
    }
    if (carried.isNotEmpty) _pendingAnchors.addAll(carried);
    spans
      ..clear()
      ..addAll(retained);
  }

  void _mergeSpans(List<EpubTextSpan> spans) {
    var index = 0;
    while (index + 1 < spans.length) {
      final current = spans[index];
      final next = spans[index + 1];
      // A span that carries anchors must not merge into its predecessor: the
      // anchor points at that span's own start, not at the merged start.
      if (next.anchorIds.isEmpty &&
          current.bold == next.bold &&
          current.math == null &&
          next.math == null &&
          current.fontFamily == next.fontFamily &&
          current.italic == next.italic &&
          current.monospace == next.monospace &&
          current.fontSizeMultiplier == next.fontSizeMultiplier &&
          current.preserveWhitespace == next.preserveWhitespace &&
          current.link == next.link) {
        current.text = current.text + next.text;
        spans.removeAt(index + 1);
      } else {
        index++;
      }
    }
  }

  String _collectVisibleText(XmlElement element) {
    final buffer = StringBuffer();
    for (final child in element.children) {
      if (child is XmlText) {
        buffer.write(child.value);
      } else if (child is XmlElement) {
        if (styleOf(child).display == EpubDisplay.none) continue;
        buffer.write(_collectVisibleText(child));
      }
    }
    return buffer.toString();
  }

  String? _languageHint(XmlElement element) {
    final classes = <String?>[
      element.getAttribute('class'),
      element.children
          .whereType<XmlElement>()
          .where((child) => child.name.local == 'code')
          .map((child) => child.getAttribute('class'))
          .firstOrNull,
    ];
    for (final classAttribute in classes) {
      if (classAttribute == null) continue;
      for (final value in classAttribute.split(RegExp(r'\s+'))) {
        for (final prefix in const [
          'language-',
          'lang-',
          'code-',
          'sourceCode',
        ]) {
          if (value.startsWith(prefix) && value.length > prefix.length) {
            return value.substring(prefix.length).toLowerCase();
          }
        }
      }
    }
    return null;
  }

  List<List<EpubTextSpan>> _parseListItems(XmlElement list, int depth) {
    final items = <List<EpubTextSpan>>[];
    if (depth > _maxDepth) return items;
    for (final child in list.children.whereType<XmlElement>()) {
      if (child.name.local != 'li') continue;
      final style = styleOf(child);
      if (style.display == EpubDisplay.none) continue;
      _noteAnchor(child);
      final spans = _inlineSpans(child, 16.0, null);
      if (spans.isEmpty) continue;
      items.add(spans);
    }
    return items;
  }

  EpubContentNode? _parseFigure(
    XmlElement figure,
    EpubComputedStyle figureStyle,
    int depth,
  ) {
    final images = figure.descendants
        .whereType<XmlElement>()
        .where(
          (node) =>
              node.name.local == 'img' &&
              styleOf(node).display != EpubDisplay.none,
        )
        .toList();
    if (images.length != 1) return null;
    final image = images.first;
    final src = image.getAttribute('src');
    if (src == null) return null;
    final resolved = _resolveRelative(basePath, src);
    if (resolved == null) return null;
    final captions = figure.children
        .whereType<XmlElement>()
        .where(
          (node) =>
              node.name.local == 'figcaption' &&
              styleOf(node).display != EpubDisplay.none,
        )
        .toList();
    final visibleChildren = figure.children
        .whereType<XmlElement>()
        .where((node) => styleOf(node).display != EpubDisplay.none)
        .toList();
    final captionElement =
        captions.isNotEmpty &&
            visibleChildren.isNotEmpty &&
            visibleChildren.last == captions.last
        ? captions.last
        : null;
    // A figure is collapsed only when nothing else visible is inside it.
    for (final node in figure.descendants) {
      if (node is XmlText) {
        if (node.value.trim().isNotEmpty &&
            !(captionElement?.descendants.contains(node) ?? false)) {
          return null;
        }
      } else if (node is XmlElement && node != figure) {
        final isImage = node == image;
        final isCaption =
            captionElement != null && captionElement.descendants.contains(node);
        final containsSelected =
            node.descendants.contains(image) ||
            (captionElement != null &&
                node.descendants.contains(captionElement));
        if (!isImage &&
            !isCaption &&
            !containsSelected &&
            node != captionElement &&
            styleOf(node).display != EpubDisplay.none) {
          return null;
        }
      }
    }
    final imageStyle = _nodeStyle(styleOf(image));
    final captionSpans = captionElement == null
        ? <EpubTextSpan>[]
        : _captionSpans(captionElement, styleOf(captionElement).fontSizePx);
    final node = EpubImage(
      src: resolved,
      alt: image.getAttribute('alt') ?? '',
      nodeStyle: imageStyle,
      caption: captionSpans,
      captionStyle: captionElement == null
          ? null
          : _nodeStyle(styleOf(captionElement)),
    );
    _takePending(node);
    return node;
  }

  List<EpubTextSpan> _captionSpans(XmlElement caption, double baseFontSize) {
    final spans = _inlineSpans(caption, baseFontSize, null);
    return spans;
  }

  EpubContentNode? _parseTable(
    XmlElement table,
    EpubComputedStyle style,
    int depth,
  ) {
    if (depth > _maxDepth) return null;
    final captionElement = table.children
        .whereType<XmlElement>()
        .where(
          (child) =>
              child.name.local == 'caption' &&
              styleOf(child).display != EpubDisplay.none,
        )
        .firstOrNull;
    if (captionElement != null) _noteAnchor(captionElement);
    final caption = captionElement == null
        ? <EpubTextSpan>[]
        : _inlineSpans(
            captionElement,
            styleOf(captionElement).fontSizePx,
            null,
          );
    final rowGroups = <EpubTableRowGroup>[];
    final implicitBody = <EpubTableRow>[];
    void flushImplicit() {
      if (implicitBody.isEmpty) return;
      rowGroups.add(
        EpubTableRowGroup(
          kind: EpubTableRowGroupKind.body,
          rows: List.of(implicitBody),
        ),
      );
      implicitBody.clear();
    }

    for (final child in table.children.whereType<XmlElement>()) {
      if (styleOf(child).display == EpubDisplay.none) continue;
      switch (child.name.local) {
        case 'thead':
        case 'tbody':
        case 'tfoot':
          flushImplicit();
          final kind = switch (child.name.local) {
            'thead' => EpubTableRowGroupKind.head,
            'tfoot' => EpubTableRowGroupKind.foot,
            _ => EpubTableRowGroupKind.body,
          };
          final rows = child.children
              .whereType<XmlElement>()
              .where((row) => row.name.local == 'tr')
              .map(_parseTableRow)
              .whereType<EpubTableRow>()
              .toList();
          if (rows.isNotEmpty) {
            rowGroups.add(EpubTableRowGroup(kind: kind, rows: rows));
          }
        case 'tr':
          final row = _parseTableRow(child);
          if (row != null) implicitBody.add(row);
      }
    }
    flushImplicit();
    if (caption.isEmpty && rowGroups.isEmpty) return null;
    final node = EpubTable(
      caption: caption,
      captionStyle: captionElement == null
          ? null
          : _nodeStyle(styleOf(captionElement)),
      rowGroups: rowGroups,
      nodeStyle: _nodeStyle(style),
    );
    _takePending(node);
    return node;
  }

  EpubTableRow? _parseTableRow(XmlElement row) {
    if (styleOf(row).display == EpubDisplay.none) return null;
    _noteAnchor(row);
    final cells = <EpubTableCell>[];
    for (final cell in row.children.whereType<XmlElement>()) {
      if (cell.name.local != 'td' && cell.name.local != 'th') continue;
      final parsed = _parseTableCell(cell);
      if (parsed != null) cells.add(parsed);
    }
    return cells.isEmpty ? null : EpubTableRow(cells: cells);
  }

  EpubTableCell? _parseTableCell(XmlElement cell) {
    final style = styleOf(cell);
    if (style.display == EpubDisplay.none) return null;
    _noteAnchor(cell);
    final cellStyle = _nodeStyle(style);
    final blocks = parseBlocks(cell, 0);
    final children = <EpubContentNode>[];
    final blockStarts = <int>[];
    for (final block in blocks) {
      if (children.isNotEmpty) blockStarts.add(children.length);
      children.add(block);
    }
    blockStarts
      ..sort()
      ..toSet()
      ..removeWhere((start) => start >= children.length);
    return EpubTableCell(
      id: cell.getAttribute('id'),
      header: cell.name.local == 'th',
      scope: cell.getAttribute('scope'),
      headers: (cell.getAttribute('headers') ?? '')
          .split(RegExp(r'\s+'))
          .where((value) => value.isNotEmpty)
          .toList(),
      rowSpan: _spanValue(cell.getAttribute('rowspan'), 1),
      columnSpan: _spanValue(cell.getAttribute('colspan'), 1),
      children: children,
      blockStarts: blockStarts,
      style: cellStyle,
    );
  }

  int _spanValue(String? raw, int fallback) {
    if (raw == null) return fallback;
    final value = int.tryParse(raw.trim());
    if (value == null || value <= 0) return fallback;
    return value;
  }
}

bool _isAsciiWhitespace(int rune) =>
    rune == 0x20 ||
    rune == 0x09 ||
    rune == 0x0A ||
    rune == 0x0D ||
    rune == 0x0C;

const String _mathmlNamespace = 'http://www.w3.org/1998/Math/MathML';

/// Resolve a relative reference against a canonical archive directory.
///
/// Returns a canonical path or `null` when the reference escapes the archive,
/// has a foreign origin, or is otherwise not a legal same-book reference.
String? _resolveRelative(String basePath, String reference) {
  try {
    return resolveEpubReference(basePath, reference).path;
  } on EpubPathError {
    return null;
  }
}

// ---------------------------------------------------------------------------
// MathML
// ---------------------------------------------------------------------------

const int _mathMaxDepth = 16;
const int _mathMaxNodes = 64;
const int _mathMaxVisibleTextBytes = 1024;

/// Bounded Presentation MathML parse, ported from the production `math` module.
///
/// The parse mirrors the production rules arm for arm: a node that fails
/// preflight reports `[math expression omitted]`, and a node whose construct is
/// unsupported reports either its source-order children text or
/// `[unsupported math]`. The readable fallback is the canonical stream's math
/// text, so these rules are offset-bearing, not presentation details.
EpubMath parseMath(XmlElement root, EpubLimits limits) {
  final display = root.getAttribute('display') == 'block'
      ? EpubMathDisplay.block
      : EpubMathDisplay.inline;
  final budget = _MathBudget();
  if (!_mathPreflight(
    root,
    0,
    allowForeign: false,
    suppressText: false,
    budget: budget,
  )) {
    return EpubMath(display: display, fallback: '[math expression omitted]');
  }
  final fallback = _mathFallback(root, 0) ?? '[unsupported math]';
  final expression = _mathExpression(root, 0);
  return EpubMath(display: display, fallback: fallback, expression: expression);
}

class _MathBudget {
  int nodes = 0;
  int visibleTextBytes = 0;
}

/// Ports the production `preflight` bounds: depth, node count, namespace
/// admission, the `semantics` shape and the visible-text budget.
bool _mathPreflight(
  XmlElement node,
  int depth, {
  required bool allowForeign,
  required bool suppressText,
  required _MathBudget budget,
}) {
  if (depth > _mathMaxDepth) return false;
  budget.nodes += 1;
  final isMathml = _mathNamespaceOf(node) == _mathmlNamespace;
  if (budget.nodes > _mathMaxNodes || (!allowForeign && !isMathml)) {
    return false;
  }
  final name = node.name.local;
  if (!suppressText && isMathml && name == 'semantics') {
    final children = _mathElements(node);
    if (children.isEmpty ||
        _isMathAnnotation(children.first) ||
        children.skip(1).any((child) => !_isMathAnnotation(child)) ||
        _hasNonWhitespaceDirectText(node)) {
      return false;
    }
  }
  final suppressed = suppressText || _isMathAnnotation(node);
  if (!suppressed) {
    if (!_addVisibleBytes(_trimmedDirectTextBytes(node), budget)) return false;
    if (isMathml && name == 'mfenced') {
      // The production budget adds the fence bytes as authored; a missing
      // attribute defaults to the parenthesis the renderer would draw.
      if (!_addVisibleBytes(
        _utf8ByteLength(node.getAttribute('open') ?? '('),
        budget,
      )) {
        return false;
      }
      if (!_addVisibleBytes(
        _utf8ByteLength(node.getAttribute('close') ?? ')'),
        budget,
      )) {
        return false;
      }
    }
  }
  final allow = allowForeign || _isAnnotationXml(node);
  for (final child in _mathElements(node)) {
    if (!_mathPreflight(
      child,
      depth + 1,
      allowForeign: allow,
      suppressText: suppressed,
      budget: budget,
    )) {
      return false;
    }
  }
  return true;
}

bool _addVisibleBytes(int bytes, _MathBudget budget) {
  budget.visibleTextBytes += bytes;
  return budget.visibleTextBytes <= _mathMaxVisibleTextBytes;
}

/// Ports the production `trimmed_direct_text_bytes`: whitespace runs that never
/// preceded visible text carry no bytes.
///
/// The budget counts UTF-8 bytes of code points, not UTF-16 units, so a
/// character outside the BMP costs what the production counter charges it
/// (four bytes rather than two).
int _trimmedDirectTextBytes(XmlElement node) {
  var bytes = 0;
  var pendingWhitespace = 0;
  var visible = false;
  for (final child in node.children) {
    final text = _mathText(child);
    if (text == null) continue;
    for (final rune in text.runes) {
      final length = _utf8Length(rune);
      if (String.fromCharCode(rune).trim().isEmpty) {
        if (visible) pendingWhitespace += length;
      } else {
        bytes += pendingWhitespace + length;
        pendingWhitespace = 0;
        visible = true;
      }
    }
  }
  return bytes;
}

/// The UTF-8 byte length of one code point.
int _utf8Length(int rune) => rune < 0x80
    ? 1
    : rune < 0x800
    ? 2
    : rune < 0x10000
    ? 3
    : 4;

/// The UTF-8 byte length of [value].
int _utf8ByteLength(String value) {
  var bytes = 0;
  for (final rune in value.runes) {
    bytes += _utf8Length(rune);
  }
  return bytes;
}

/// Ports the production `fallback`: the readable source-order text of a math
/// node, or null when no bounded fallback exists.
String? _mathFallback(XmlElement node, int depth) {
  if (depth > _mathMaxDepth) return null;
  final tag = node.name.local;
  switch (tag) {
    case 'mi':
    case 'mn':
    case 'mo':
    case 'mtext':
      return _mathToken(node) ?? _mathFallbackChildren(node, depth);
    case 'mfrac':
      if (!_hasSupportedMathExpression(node)) {
        return _mathFallbackChildren(node, depth);
      }
      final children = _mathElements(node);
      if (children.length != 2) return _mathFallbackChildren(node, depth);
      final numerator = _mathFallback(children[0], depth + 1);
      final denominator = _mathFallback(children[1], depth + 1);
      if (numerator == null || denominator == null) return null;
      return '($numerator)/($denominator)';
    case 'msqrt':
      if (!_hasSupportedMathExpression(node)) {
        return _mathFallbackChildren(node, depth);
      }
      final inner = _mathFallbackChildren(node, depth);
      return inner == null ? null : 'sqrt($inner)';
    case 'mroot':
      if (!_hasSupportedMathExpression(node)) {
        return _mathFallbackChildren(node, depth);
      }
      final children = _mathElements(node);
      if (children.length != 2) return _mathFallbackChildren(node, depth);
      final radicand = _mathFallback(children[0], depth + 1);
      final index = _mathFallback(children[1], depth + 1);
      if (radicand == null || index == null) return null;
      return 'root($radicand, $index)';
    case 'msub':
    case 'msup':
    case 'msubsup':
      if (!_hasSupportedMathExpression(node)) {
        return _mathFallbackChildren(node, depth);
      }
      final children = _mathElements(node);
      if (tag == 'msubsup') {
        if (children.length != 3) return _mathFallbackChildren(node, depth);
        final base = _mathFallback(children[0], depth + 1);
        final sub = _mathFallback(children[1], depth + 1);
        final sup = _mathFallback(children[2], depth + 1);
        if (base == null || sub == null || sup == null) return null;
        return '${base}_$sub^$sup';
      }
      if (children.length != 2) return _mathFallbackChildren(node, depth);
      final base = _mathFallback(children[0], depth + 1);
      final script = _mathFallback(children[1], depth + 1);
      if (base == null || script == null) return null;
      return tag == 'msub' ? '${base}_$script' : '$base^$script';
    case 'annotation':
    case 'annotation-xml':
      return '';
    case 'mfenced':
      if (!_hasSupportedMathExpression(node)) {
        return _mathFallbackChildren(node, depth);
      }
      final inner = _mathFallbackChildren(node, depth);
      if (inner == null) return null;
      return '${node.getAttribute('open') ?? '('}$inner'
          '${node.getAttribute('close') ?? ')'}';
    case 'semantics':
      final first = _mathElements(node).firstOrNull;
      return first == null ? null : _mathFallback(first, depth + 1);
    default:
      return _mathFallbackChildren(node, depth);
  }
}

/// Ports the production `fallback_children`: element children and trimmed text
/// nodes in source order, joined with one space, with empty parts removed and
/// annotations suppressed.
String? _mathFallbackChildren(XmlElement node, int depth) {
  final parts = <String>[];
  for (final child in node.children) {
    final text = _mathText(child);
    if (text != null) {
      final trimmed = text.trim();
      if (trimmed.isNotEmpty) parts.add(trimmed);
      continue;
    }
    if (child is XmlElement) {
      if (_isMathAnnotation(child)) continue;
      final part = _mathFallback(child, depth + 1);
      if (part == null) return null;
      if (part.isNotEmpty) parts.add(part);
    }
  }
  return parts.join(' ');
}

/// Ports the production `token`: direct text only, trimmed, non-empty and free
/// of line breaks.
String? _mathToken(XmlElement node) {
  final buffer = StringBuffer();
  for (final child in node.children) {
    final text = _mathText(child);
    if (text != null) {
      buffer.write(text);
      continue;
    }
    if (child is XmlComment) continue;
    return null;
  }
  final text = buffer.toString().trim();
  if (text.isEmpty || text.contains('\n') || text.contains('\r')) return null;
  return text;
}

bool _hasSupportedMathExpression(XmlElement node) =>
    _mathExpression(node, 0) != null;

bool _hasNonWhitespaceDirectText(XmlElement node) => node.children
    .map(_mathText)
    .whereType<String>()
    .any((text) => text.trim().isNotEmpty);

String? _mathNamespaceOf(XmlElement node) => node.name.namespaceUri;

bool _isMathAnnotation(XmlElement node) =>
    _mathNamespaceOf(node) == _mathmlNamespace &&
    (node.name.local == 'annotation' || node.name.local == 'annotation-xml');

bool _isAnnotationXml(XmlElement node) =>
    _mathNamespaceOf(node) == _mathmlNamespace &&
    node.name.local == 'annotation-xml';

/// The production `elements`: element children only.
List<XmlElement> _mathElements(XmlElement node) =>
    node.children.whereType<XmlElement>().toList(growable: false);

/// Text content of a child node, mirroring the production tree's text nodes.
String? _mathText(XmlNode child) => switch (child) {
  XmlText() => child.value,
  XmlCDATA() => child.value,
  _ => null,
};

EpubMathExpression? _mathExpression(XmlElement node, int depth) {
  if (depth > _mathMaxDepth) return null;
  final tag = node.name.local;
  if (!_mathTokenTags.contains(tag) && _hasNonWhitespaceDirectText(node)) {
    return null;
  }
  final children = _mathElements(node);
  switch (tag) {
    case 'math':
    case 'mrow':
    case 'mstyle':
    case 'mtd':
      return _mathRow(children, depth);
    case 'mi':
    case 'mn':
    case 'mo':
    case 'mtext':
      final token = _mathToken(node);
      return token == null ? null : EpubMathToken(token);
    case 'mfrac':
      if (children.length != 2) return null;
      final numerator = _mathExpression(children[0], depth + 1);
      final denominator = _mathExpression(children[1], depth + 1);
      if (numerator == null || denominator == null) return null;
      return EpubMathFraction(numerator, denominator);
    case 'msqrt':
      final radicand = _mathRow(children, depth);
      return radicand == null ? null : EpubMathRadical(radicand: radicand);
    case 'mroot':
      if (children.length != 2) return null;
      final radicand = _mathExpression(children[0], depth + 1);
      final index = _mathExpression(children[1], depth + 1);
      if (radicand == null || index == null) return null;
      return EpubMathRadical(radicand: radicand, index: index);
    case 'msub':
    case 'msup':
      if (children.length != 2) return null;
      final base = _mathExpression(children[0], depth + 1);
      final script = _mathExpression(children[1], depth + 1);
      if (base == null || script == null) return null;
      return EpubMathScript(
        base: base,
        sub: tag == 'msub' ? script : null,
        sup: tag == 'msup' ? script : null,
      );
    case 'msubsup':
      if (children.length != 3) return null;
      final base = _mathExpression(children[0], depth + 1);
      final sub = _mathExpression(children[1], depth + 1);
      final sup = _mathExpression(children[2], depth + 1);
      if (base == null || sub == null || sup == null) return null;
      return EpubMathScript(base: base, sub: sub, sup: sup);
    case 'mfenced':
      final content = _mathRow(children, depth);
      if (content == null) return null;
      return EpubMathFenced(
        open: node.getAttribute('open') ?? '(',
        close: node.getAttribute('close') ?? ')',
        content: content is EpubMathRow
            ? content.children
            : <EpubMathExpression>[content],
      );
    case 'mtable':
      final rows = <List<EpubMathExpression>>[];
      for (final row in children) {
        if (row.name.local != 'mtr' || _hasNonWhitespaceDirectText(row)) {
          return null;
        }
        final cells = <EpubMathExpression>[];
        for (final cell in _mathElements(row)) {
          if (cell.name.local != 'mtd') return null;
          final cellExpression = _mathExpression(cell, depth + 2);
          if (cellExpression == null) return null;
          cells.add(cellExpression);
        }
        rows.add(cells);
      }
      return EpubMathTable(rows);
    case 'semantics':
      final first = children.firstOrNull;
      return first == null ? null : _mathExpression(first, depth + 1);
    default:
      return null;
  }
}

const Set<String> _mathTokenTags = {'mi', 'mn', 'mo', 'mtext'};

/// Ports the production `row_expression`: every element child must be a
/// supported expression, or the row is unsupported.
EpubMathExpression? _mathRow(List<XmlElement> children, int depth) {
  final expressions = <EpubMathExpression>[];
  for (final child in children) {
    final expression = _mathExpression(child, depth + 1);
    if (expression == null) return null;
    expressions.add(expression);
  }
  return EpubMathRow(expressions);
}
