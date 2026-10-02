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
  builder.build(nodes);
  for (final name in context.unresolvedAnchors) {
    // The unresolved fallback is an anchor like any other: an empty, over-long
    // or unsafe name must not become a target, and the chapter's anchor
    // ceiling applies (the production parser never records such a name).
    builder.recordEndAnchor(name);
  }
  // A name only a suppressed (media-cell) walk saw is not published: the
  // chapter drops it instead of letting a later duplicate become a target.
  // This runs last, after the unresolved fallback, so a duplicate that emits
  // no content cannot republish it at the chapter end either.
  for (final name in context.suppressedAnchorNames) {
    builder.anchors.remove(name);
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
  for (final raw in splitCssDeclarations(stripCssComments(source))) {
    final colon = raw.indexOf(':');
    if (colon <= 0) continue;
    final property = raw.substring(0, colon).trim().toLowerCase();
    final parsed = splitCssImportant(raw.substring(colon + 1));
    if (property.isEmpty || parsed.value.isEmpty) continue;
    declarations.add(
      CssDeclaration(
        property,
        parsed.value,
        important: parsed.important,
        inline: true,
      ),
    );
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
  // The production UA stylesheet assigns a display role per tag (every tag
  // outside the block list is inline); the value is not inherited. A specified
  // rule or inline style overrides it afterwards.
  var display = EpubDisplay.inline;
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
    // `li` is deliberately absent: the production `ua_display` has no arm for
    // it, so a list item computes as inline. That only differs from the block
    // role inside table cells (the chapter list walker matches `li` by tag,
    // not by display), where the production cell collector joins the items
    // into one run.
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
      // The production `css_display` offers only the keywords it can map
      // losslessly: `none`, `inline`, `block`, the table keyword family
      // (`table`/`inline-table` are a pair with a table inside; the group and
      // row keywords arrive as their own kinds). Every other keyword —
      // `list-item`, `inline-block`, `flex`, `grid`, `contents`, `flow-root`,
      // `run-in`, `ruby` — keeps the UA role: the production cascade returns
      // no role for it, so the element's tag default stands.
      switch (lower) {
        case 'none':
          return _copyWith(style, display: EpubDisplay.none);
        case 'inline':
          return _copyWith(style, display: EpubDisplay.inline);
        case 'block':
        case 'table':
        case 'inline-table':
        case 'table-row-group':
        case 'table-header-group':
        case 'table-footer-group':
        case 'table-row':
        case 'table-cell':
        case 'table-caption':
          return _copyWith(style, display: EpubDisplay.block);
        default:
          return style;
      }
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
      final parsed = parseFontFamilies(value, inline: declaration.inline);
      // The production cascade derives the monospace role from the declared
      // families, so `font-family: monospace` (or a family whose name contains
      // "mono") turns a non-monospace element into a code block candidate.
      return _copyWith(
        style,
        fontFamilies: parsed.families,
        monospace: parsed.monospace,
      );
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
      // The production cascade preserves whitespace for `pre`, `pre-wrap` and
      // `break-spaces`, and turns preservation off for `pre-line` as well as
      // the normal keywords; an unrecognized value leaves the inherited role.
      if (lower == 'pre' || lower == 'pre-wrap' || lower == 'break-spaces') {
        return _copyWith(style, preserveWhitespace: true);
      }
      if (lower == 'normal' || lower == 'nowrap' || lower == 'pre-line') {
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

  /// Raw (pre-collapse) offset of each anchor recorded during the inline walk
  /// in progress, by name.
  ///
  /// The production boundary map resolves anchors through these positions, not
  /// through the collapsed span they are attached to; first occurrence wins,
  /// like `record_anchor_name`.
  final Map<String, int> _inlineAnchorOffsets = {};

  /// Whether an inline walk is collecting spans, and the raw offset reached.
  bool _inlineWalking = false;
  int _inlineRawOffset = 0;

  /// Whether the walk in progress records anchors at all.
  ///
  /// An inline-only table cell that mixes images or MathML with anchors cannot
  /// reproduce the retained anchor stream from its rendered content, so its
  /// descendant anchors are dropped rather than published at an unverifiable
  /// offset.
  bool _suppressAnchors = false;

  /// Whether an anchor walk's depth ceiling truncated a subtree since the
  /// flag was last cleared.
  ///
  /// The cell anchor pass reads it after its walk: a cell whose walk
  /// truncated cannot claim to have resolved every anchor name in its visible
  /// subtree, and the production walkers — which have no such ceiling —
  /// publish the first occurrence of each, so a partial map would let a later
  /// duplicate claim a wrong offset the routing gate cannot see. The walk
  /// fails admission instead (`EpubLimitError`).
  bool _walkHitDepthCeiling = false;

  /// Anchor names a suppressed walk saw.
  ///
  /// The chapter drops them from its anchor map, so a later duplicate cannot
  /// become a target the retained parser would not have chosen.
  final Set<String> suppressedAnchorNames = {};

  void _beginInlineWalk() {
    _inlineWalking = true;
    _inlineRawOffset = 0;
    _inlineAnchorOffsets.clear();
    // Names already pending when the walk begins (the owner's own anchors and
    // earlier markers) were recorded before its content; the production
    // `record_anchor_name` keeps their first occurrence, so a later duplicate
    // must not redefine their provenance.
    for (final name in _pendingAnchors) {
      _inlineAnchorOffsets.putIfAbsent(name, () => 0);
    }
  }

  void _endInlineWalk() {
    _inlineWalking = false;
    _inlineAnchorOffsets.clear();
  }

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

  /// Restores the pending anchors to [snapshot], dropping everything a walk
  /// that emitted no content recorded.
  ///
  /// A length-based rollback is not enough: the whitespace collapse re-appends
  /// a removed span's anchors *after* the anchors a later empty marker added,
  /// so the list can end up reordered.
  void _restorePending(List<String> snapshot) {
    _pendingAnchors
      ..clear()
      ..addAll(snapshot);
  }

  /// Anchors recorded after the last content of a list item resolve at the
  /// item's end, before the generated item newline: the production
  /// `parse_list_items` records them at the item's own text offset.
  void _takeTrailingPendingSpan(EpubTextSpan span) {
    if (_pendingAnchors.isEmpty) return;
    span.endAnchorIds = [...span.endAnchorIds, ..._pendingAnchors];
    _pendingAnchors.clear();
  }

  void _noteAnchor(XmlElement element) {
    final id = element.getAttribute('id');
    if (id != null) _noteAnchorName(id);
    if (element.name.local == 'a') {
      final name = element.getAttribute('name');
      if (name != null) _noteAnchorName(name);
    }
  }

  void _noteAnchorName(String name) {
    if (_suppressAnchors) {
      // The name must not become a later duplicate's target: it is reserved so
      // the chapter drops it instead of publishing an offset the engine cannot
      // verify.
      suppressedAnchorNames.add(name);
      return;
    }
    _pendingAnchors.add(name);
    if (_inlineWalking) {
      _inlineAnchorOffsets.putIfAbsent(name, () => _inlineRawOffset);
    }
  }

  /// Public entry point for the document body (and its own anchors).
  void noteAnchor(XmlElement element) => _noteAnchor(element);

  EpubComputedStyle styleOf(XmlElement element) =>
      styles[element] ?? _initialStyle();

  List<EpubContentNode> parseBlocks(XmlElement parent, int depth) {
    final nodes = <EpubContentNode>[];
    if (depth > _maxDepth) {
      _walkHitDepthCeiling = true;
      return nodes;
    }
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
    // The production block walker treats any element whose computed style is
    // monospace + preserve-whitespace as a code block, whatever its tag
    // (Calibre-generated classes), and never collects its descendants'
    // anchors; only the element's own anchors stay recorded at its start.
    if (tag != 'pre' &&
        tag != 'code' &&
        style.monospace &&
        style.preserveWhitespace &&
        !_isMathElement(element)) {
      final code = _collectVisibleText(element);
      if (code.trim().isNotEmpty) {
        final node = EpubCodeBlock(code: code.trim(), language: null);
        _takePending(node);
        return [node];
      }
    }
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
        // A heading's leading anchors were consumed by its first span; what is
        // still pending is a trailing marker, which the production parser
        // resolves at the heading's end, not its start.
        _takeTrailingPending(node);
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
        final pendingBefore = List<String>.of(_pendingAnchors);
        final children = parseBlocks(element, depth + 1);
        if (children.isEmpty) {
          // The production parser drops the content anchors of a blockquote it
          // does not emit; the blockquote's own anchors stay recorded at its
          // start (the parent already noted them).
          _restorePending(pendingBefore);
          return const [];
        }
        final node = EpubBlockQuote(
          children: children,
          nodeStyle: _nodeStyle(style),
        );
        // A marker after the last child resolves at the blockquote's end, not
        // its start.
        _takeTrailingPending(node);
        return [node];
      case 'table':
        final table = _parseTable(element, style, depth);
        return table == null ? const [] : [table];
      case 'math' when _isMathElement(element):
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
        // A marker after the last child stays pending: the production figure
        // arm keeps the child walk's offsets, and the figure's own separator
        // means the next content position is one past the node's end.
        return [EpubFigure(children: inner, nodeStyle: _nodeStyle(style))];
      case 'figcaption':
        final pendingBefore = List<String>.of(_pendingAnchors);
        final spans = _captionSpans(element, style.fontSizePx);
        if (spans.isEmpty) {
          // The production caption-run collector discards the anchors of a run
          // that emits nothing; the caption element's own anchors stay at its
          // start.
          _restorePending(pendingBefore);
          return const [];
        }
        final node = EpubParagraph(spans, _nodeStyle(style));
        // Trailing markers in a caption resolve at the caption's end.
        _takeTrailingPending(node);
        return [node];
      case 'div':
      case 'section':
      case 'article':
      case 'main':
      case 'aside':
      case 'header':
      case 'footer':
        // The production parser always walks these containers as block
        // children, even when their computed display is inline; their own
        // anchors stay pending until the first emitted content, and a trailing
        // marker flows to whatever content follows (or to the chapter end).
        //
        // `nav` is deliberately not in this list: the production parser falls
        // through to its inline collector for it, and a block walk would change
        // both the canonical stream and a trailing marker's offset.
        return parseBlocks(element, depth + 1);
      default:
        final spans = _inlineSpans(element, style.fontSizePx, null);
        if (spans.isEmpty) return const [];
        final node = EpubParagraph(spans, _nodeStyle(style));
        _takeTrailingPending(node);
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
    _beginInlineWalk();
    _collectInline(element, baseFontSize, link, spans, 0);
    _collapseWhitespace(spans);
    _mergeSpans(spans);
    _endInlineWalk();
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

  bool _isMathElement(XmlElement element) =>
      element.name.local == 'math' &&
      element.name.namespaceUri == _mathmlNamespace;

  /// A text span carrying [owner]'s computed style, the production
  /// `text_span_for_node`.
  EpubTextSpan _textSpanFor(
    XmlElement owner,
    String text,
    double baseFontSize,
    String? link,
  ) {
    final style = styleOf(owner);
    return EpubTextSpan(
      text: text,
      bold: style.bold,
      italic: style.italic,
      monospace: style.monospace,
      fontFamily: style.fontFamilies.isEmpty ? null : style.fontFamilies.first,
      fontSizeMultiplier: style.fontSizePx / baseFontSize,
      preserveWhitespace: style.preserveWhitespace,
      link: link,
    );
  }

  void _collectInline(
    XmlElement element,
    double baseFontSize,
    String? link,
    List<EpubTextSpan> spans,
    int depth,
  ) {
    if (depth > _maxDepth) {
      _walkHitDepthCeiling = true;
      return;
    }
    for (final child in element.children) {
      if (child is XmlText) {
        if (child.value.isEmpty) continue;
        final span = _textSpanFor(element, child.value, baseFontSize, link);
        _takePendingSpan(span);
        spans.add(span);
        _inlineRawOffset += child.value.runes.length;
        continue;
      }
      if (child is! XmlElement) continue;
      final childStyle = styleOf(child);
      if (childStyle.display == EpubDisplay.none) continue;
      _noteAnchor(child);
      if (_isMathElement(child)) {
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
        _inlineRawOffset += content.fallback.runes.length;
        continue;
      }
      // `<br/>` emits no content in the production collector (the retained
      // parser has no br arm anywhere, and its renderer inserts nothing for
      // one either), so it falls through to the default recursion below and
      // does not advance the raw offset either.
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
    // Raw positions are what the production boundary map resolves anchors
    // through, so remember them before the text is rewritten.
    final rawEnds = <int>[];
    var raw = 0;
    for (final span in spans) {
      raw += span.text.runes.length;
      rawEnds.add(raw);
    }
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
    int? trimRawEnd;
    for (var index = spans.length - 1; index >= 0; index--) {
      final span = spans[index];
      if (span.text.isEmpty || span.preserveWhitespace) continue;
      if (span.text.endsWith(' ')) {
        span.text = span.text.substring(0, span.text.length - 1);
        trimRawEnd = rawEnds[index];
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
    _resolveInlineAnchors(spans, trimRawEnd);
  }

  /// Re-places anchors recorded during the inline walk through the production
  /// raw-to-normalized boundary mapping.
  ///
  /// The collapse only removes an already-normalized character at the trailing
  /// space, and the production boundary table keeps the raw positions of the
  /// anchors recorded at or after it, clamped to the collapsed length: such an
  /// anchor stays one scalar to the right of its collapsed position (or at the
  /// end), even when that falls inside a surviving span.
  void _resolveInlineAnchors(List<EpubTextSpan> spans, int? trimRawEnd) {
    if (trimRawEnd == null || _inlineAnchorOffsets.isEmpty) return;
    final starts = <int>[];
    var total = 0;
    for (final span in spans) {
      starts.add(total);
      total += span.text.runes.length;
    }
    final moved = <(String, int)>[];
    for (var index = 0; index < spans.length; index++) {
      final span = spans[index];
      if (span.anchorIds.isEmpty) continue;
      final kept = <String>[];
      for (final name in span.anchorIds) {
        final raw = _inlineAnchorOffsets[name];
        if (raw == null || raw < trimRawEnd) {
          kept.add(name);
          continue;
        }
        final target = starts[index] + 1;
        moved.add((name, target < total ? target : total));
      }
      span.anchorIds = kept;
    }
    if (moved.isEmpty) return;
    final byTarget = <int, List<String>>{};
    for (final (name, target) in moved) {
      byTarget.putIfAbsent(target, () => []).add(name);
    }
    if (spans.isEmpty) return;
    final rebuilt = <EpubTextSpan>[];
    var position = 0;
    for (final span in spans) {
      final text = span.text;
      final length = text.runes.length;
      final end = position + length;
      if (length == 0) {
        rebuilt.add(span);
        continue;
      }
      final endAnchors = span.endAnchorIds;
      final splits =
          byTarget.keys
              .where((target) => target > position && target < end)
              .toList()
            ..sort();
      if (splits.isEmpty) {
        rebuilt.add(span);
        position = end;
        continue;
      }
      var pieceStart = position;
      var piece = span..endAnchorIds = const [];
      for (final target in splits) {
        piece.text = String.fromCharCodes(text.runes.take(target - position));
        rebuilt.add(piece);
        piece = span.copy()
          ..text = String.fromCharCodes(text.runes.skip(target - position))
          ..anchorIds = const [];
        pieceStart = target;
      }
      piece.text = String.fromCharCodes(text.runes.skip(pieceStart - position));
      piece.endAnchorIds = endAnchors;
      rebuilt.add(piece);
      position = end;
    }
    for (final entry in byTarget.entries) {
      final target = entry.key;
      final names = entry.value;
      if (target >= total) {
        final last = rebuilt.lastWhere(
          (span) => span.text.isNotEmpty,
          orElse: () => rebuilt.last,
        );
        last.endAnchorIds = [...last.endAnchorIds, ...names];
        continue;
      }
      var offset = 0;
      var placed = false;
      for (final span in rebuilt) {
        final length = span.text.runes.length;
        if (offset == target) {
          span.anchorIds = [...span.anchorIds, ...names];
          placed = true;
          break;
        }
        offset += length;
      }
      if (!placed) {
        // A target can only fall inside a span that was split above.
        rebuilt.last.endAnchorIds = [...rebuilt.last.endAnchorIds, ...names];
      }
    }
    spans
      ..clear()
      ..addAll(rebuilt);
  }

  void _mergeSpans(List<EpubTextSpan> spans) {
    var index = 0;
    while (index + 1 < spans.length) {
      final current = spans[index];
      final next = spans[index + 1];
      // A span that carries anchors must not merge into its predecessor: the
      // anchor points at that span's own start, not at the merged start. The
      // same holds for a span end that carries anchors, which would move to the
      // merged end.
      if (next.anchorIds.isEmpty &&
          next.endAnchorIds.isEmpty &&
          current.endAnchorIds.isEmpty &&
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
    if (depth > _maxDepth) {
      _walkHitDepthCeiling = true;
      return items;
    }
    for (final child in list.children.whereType<XmlElement>()) {
      if (child.name.local != 'li') continue;
      final style = styleOf(child);
      if (style.display == EpubDisplay.none) continue;
      // The production `parse_list_items` records an item's own and nested
      // anchors only when the item produced spans; an item that emits nothing
      // contributes no anchor at all.
      final pendingBefore = List<String>.of(_pendingAnchors);
      _noteAnchor(child);
      final spans = _inlineSpans(child, 16.0, null);
      if (spans.isEmpty) {
        _restorePending(pendingBefore);
        continue;
      }
      _takeTrailingPendingSpan(spans.last);
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
    // The image's own id and its ancestors' ids below the figure resolve at
    // the image's start, like the production collapsed-figure path; the
    // figure's own anchors are already pending from the block walk.
    for (final ancestor in image.ancestors.whereType<XmlElement>()) {
      if (ancestor == figure) break;
      _noteAnchor(ancestor);
    }
    _noteAnchor(image);
    // Everything pending now belongs to the image's start; a marker the
    // caption walk leaves pending is a trailing caption marker and resolves at
    // the caption's end (the node's end), like the production caption
    // collector.
    final leadingAnchors = List<String>.of(_pendingAnchors);
    _pendingAnchors.clear();
    // The caption element's own id resolves at the caption's start, after the
    // alt text and its separator, like `record_element_anchors(caption_node,
    // caption_offset)` in the production collapsed-figure path. An empty
    // caption leaves it pending, so it lands on the node's end (the alt end).
    if (captionElement != null) _noteAnchor(captionElement);
    // The caption element's own anchors stay pending across the walk; anchors
    // the walk adds are kept only when it emits spans.
    final captionAnchors = List<String>.of(_pendingAnchors);
    final captionSpans = captionElement == null
        ? <EpubTextSpan>[]
        : _captionSpans(captionElement, styleOf(captionElement).fontSizePx);
    if (captionElement != null && captionSpans.isEmpty) {
      // The production caption-run collector discards the anchors of a run that
      // emits nothing, so a nested marker in an empty caption is not a target;
      // the caption element's own anchor still resolves at the alt end.
      _restorePending(captionAnchors);
    }
    final node = EpubImage(
      src: resolved,
      alt: image.getAttribute('alt') ?? '',
      nodeStyle: imageStyle,
      caption: captionSpans,
      captionStyle: captionElement == null
          ? null
          : _nodeStyle(styleOf(captionElement)),
    );
    node.anchorIds = leadingAnchors;
    _takeTrailingPending(node);
    return node;
  }

  /// Collects a caption's runs the way the production `collect_caption_runs`
  /// does.
  ///
  /// Each visible block child flushes an independent run; a run that emits
  /// nothing is discarded together with the anchors it recorded (the caption
  /// element's own anchors are recorded separately by the caller), and
  /// non-empty runs are joined by a generated newline separator.
  List<EpubTextSpan> _captionSpans(XmlElement caption, double baseFontSize) {
    final output = <EpubTextSpan>[];
    var run = <EpubTextSpan>[];
    var runStarted = false;
    var runPending = <String>[];

    void ensureRun() {
      if (runStarted) return;
      runPending = List<String>.of(_pendingAnchors);
      _beginInlineWalk();
      runStarted = true;
    }

    void flushRun() {
      if (!runStarted) return;
      if (run.isNotEmpty) {
        _collapseWhitespace(run);
        _mergeSpans(run);
      }
      _endInlineWalk();
      if (run.isEmpty) {
        // The production run collector clears an empty run's anchors; the
        // anchors that were already pending stay for the next content.
        _restorePending(runPending);
      } else {
        // Anchors left pending after the run's content resolve at the run's
        // end, before any generated separator.
        _takeTrailingPendingSpan(run.last);
        if (output.isNotEmpty) {
          output.add(
            run.first.copy()
              ..text = '\n'
              ..math = null,
          );
        }
        output.addAll(run);
      }
      run = <EpubTextSpan>[];
      runStarted = false;
    }

    for (final child in caption.children) {
      if (child is XmlText) {
        if (child.value.isEmpty) continue;
        ensureRun();
        run.add(_textSpanFor(caption, child.value, baseFontSize, null));
        _takePendingSpan(run.last);
        _inlineRawOffset += child.value.runes.length;
        continue;
      }
      if (child is! XmlElement) continue;
      final childStyle = styleOf(child);
      if (childStyle.display == EpubDisplay.none) continue;
      final isBlock = childStyle.display != EpubDisplay.inline;
      if (isBlock) flushRun();
      // The snapshot is taken before the child's own anchors: an empty run
      // discards them, a non-empty run keeps them at the child's position.
      ensureRun();
      _noteAnchor(child);
      _collectInline(
        child,
        baseFontSize,
        child.name.local == 'a' ? child.getAttribute('href') : null,
        run,
        0,
      );
      if (isBlock) flushRun();
    }
    flushRun();
    return output;
  }

  EpubContentNode? _parseTable(
    XmlElement table,
    EpubComputedStyle style,
    int depth,
  ) {
    if (depth > _maxDepth) {
      _walkHitDepthCeiling = true;
      return null;
    }
    final pendingBefore = List<String>.of(_pendingAnchors);
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
    // A marker after the caption's text resolves at the caption's end, before
    // the caption's generated separator: the production `table_anchor_offsets`
    // records the caption's own inline offsets before it advances past them.
    if (caption.isNotEmpty) _takeTrailingPendingSpan(caption.last);
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
    if (caption.isEmpty && rowGroups.isEmpty) {
      // The production parser only computes table anchors for a table it
      // emits, so an unemitted table's caption anchors are dropped (the
      // table's own anchors stay pending at its start).
      _restorePending(pendingBefore);
      return null;
    }
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
    final pendingBefore = List<String>.of(_pendingAnchors);
    _noteAnchor(row);
    final cells = <EpubTableCell>[];
    for (final cell in row.children.whereType<XmlElement>()) {
      if (cell.name.local != 'td' && cell.name.local != 'th') continue;
      final parsed = _parseTableCell(cell);
      if (parsed != null) cells.add(parsed);
    }
    if (cells.isEmpty) {
      // A row with no visible cells is not emitted and its anchors are
      // dropped, like the production `visible_table_rows` filter.
      _restorePending(pendingBefore);
      return null;
    }
    return EpubTableRow(cells: cells);
  }

  EpubTableCell? _parseTableCell(XmlElement cell) {
    final style = styleOf(cell);
    if (style.display == EpubDisplay.none) return null;
    _noteAnchor(cell);
    // Anchors pending when the cell begins resolve at the cell's start: the
    // cell's own id, its row's id, and any marker an earlier empty cell left
    // behind. The production `table_anchor_offsets` records each of them at the
    // offset where it appears, not at the next emitted content.
    final startAnchors = List<String>.of(_pendingAnchors);
    _pendingAnchors.clear();
    final cellStyle = _nodeStyle(style);

    // Content pass: the production cell collectors (`collect_table_cell_blocks`
    // and `collect_table_cell_inline`), anchor-free. They are a separate walk
    // from the chapter rules: every visible block child flushes an independent
    // collapsed run, nested block elements flatten into sibling paragraphs,
    // display-block MathML becomes its own node, and images become nodes.
    final cellBlocks = _collectTableCellBlocks(
      cell,
      cellStyle,
      style.fontSizePx,
      null,
      0,
    );
    // Flatten the collected blocks the way the production `parse_table_cell`
    // does: one block start before each block after the first, and block
    // starts immediately before and after every display-math node.
    final children = <EpubContentNode>[];
    final blockStarts = <int>[];
    for (final block in cellBlocks) {
      if (children.isNotEmpty) blockStarts.add(children.length);
      for (final node in block) {
        final isMath = node is EpubMathNode;
        if (isMath && children.isNotEmpty) blockStarts.add(children.length);
        children.add(node);
        if (isMath) blockStarts.add(children.length);
      }
    }
    blockStarts.sort();
    final dedupedBlockStarts = <int>[];
    for (final start in blockStarts) {
      if (dedupedBlockStarts.isEmpty || dedupedBlockStarts.last != start) {
        dedupedBlockStarts.add(start);
      }
    }
    dedupedBlockStarts.removeWhere((start) => start >= children.length);
    final blockChildren = _hasBlockChildren(cell);

    // Anchor pass. The production `table_anchor_offsets` computes a cell's
    // descendant anchors from a separate anchor stream — a full block walk for
    // a cell with block children, the inline collector otherwise — whose
    // coordinates can deliberately misalign with the flattened content (the
    // retained parser keeps both streams as they are). Reproduce that: run the
    // walk, build its canonical coordinates with a throwaway builder, and
    // publish the offsets cell-locally.
    //
    // The shared walk state is saved and restored because the walk must not
    // leak anchors, offsets or suppression into the surrounding chapter pass.
    final savedPending = List<String>.of(_pendingAnchors);
    final savedSuppressAnchors = _suppressAnchors;
    final savedWalkHitDepthCeiling = _walkHitDepthCeiling;
    final savedInlineWalking = _inlineWalking;
    final savedInlineRawOffset = _inlineRawOffset;
    final savedInlineAnchorOffsets = Map<String, int>.of(_inlineAnchorOffsets);
    _pendingAnchors.clear();
    _inlineAnchorOffsets.clear();
    _suppressAnchors = false;
    _inlineWalking = false;
    Map<String, int> anchorOffsets = const {};
    var endAnchors = const <String>[];
    try {
      // A cell that mixes an image or MathML with an anchor keeps the
      // documented suppression: the retained anchor stream ignores image alt
      // text and treats MathML as spans, so this port reserves the names
      // chapter-wide instead of publishing an offset it cannot verify.
      final mediaCell = !blockChildren && _cellHasMedia(cell);
      final List<EpubContentNode> walkNodes;
      if (mediaCell) _suppressAnchors = true;
      // Truncation during the walk itself, not during the content pass,
      // decides whether the walk's map can be trusted as complete; the flag
      // is cleared so the anchor-free content collectors cannot trigger it.
      _walkHitDepthCeiling = false;
      try {
        walkNodes = blockChildren
            ? parseBlocks(cell, 0)
            : [
                EpubParagraph(
                  _inlineSpans(cell, style.fontSizePx, null),
                  cellStyle,
                ),
              ];
      } finally {
        _suppressAnchors = savedSuppressAnchors;
      }
      if (_walkHitDepthCeiling) {
        // The walk dropped a subtree past the port's depth ceiling, so its
        // map cannot claim to have resolved every anchor name in the cell's
        // visible subtree — and the production walkers, which have no such
        // ceiling, publish the first occurrence of each. A partial map lets
        // a later duplicate claim a wrong offset (the routing gate compares
        // text only, and a textless truncation hides the difference), so the
        // walk fails admission instead, like the canonical ceiling.
        throw const EpubLimitError('cell anchor walk depth', _maxDepth);
      }
      // A marker left pending after the walk resolves at the walk's own end:
      // the production block walk's accounting ends after its last emitted
      // block's generated newline (`extract_text_from_nodes` counts one per
      // node), and the inline collector's ends at the collapsed run with no
      // newline. These are walk coordinates, not flattened content
      // coordinates, so publishing from the walk is the retained behaviour.
      endAnchors = List.of(_pendingAnchors);
      _pendingAnchors.clear();
      final builder = CanonicalTextBuilder(
        maxScalars: limits.maxCanonicalScalars,
      );
      builder.build(walkNodes);
      anchorOffsets = builder.anchors;
      if (endAnchors.isNotEmpty) {
        // First occurrence wins, so a name the walk already published keeps
        // its walk offset and the trailing record is ignored.
        final walkEnd = blockChildren
            ? builder.scalarCount
            : builder.scalarCount - 1;
        for (final name in endAnchors) {
          anchorOffsets.putIfAbsent(name, () => walkEnd);
        }
      }
    } finally {
      _pendingAnchors
        ..clear()
        ..addAll(savedPending);
      _inlineAnchorOffsets
        ..clear()
        ..addAll(savedInlineAnchorOffsets);
      _inlineWalking = savedInlineWalking;
      _inlineRawOffset = savedInlineRawOffset;
      _walkHitDepthCeiling = savedWalkHitDepthCeiling;
    }
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
      blockStarts: dedupedBlockStarts,
      style: cellStyle,
      startAnchorIds: startAnchors,
      anchorOffsets: anchorOffsets,
    );
  }

  /// The production `collect_table_cell_blocks`: the cell's content as a list
  /// of blocks, each a list of content nodes.
  ///
  /// A child element whose computed display is neither `none` nor `inline`
  /// (the production block-role set — block, table, row group, row, cell and
  /// caption, which are the only roles the cascade offers beyond inline/none)
  /// flushes the pending run, starts a new block, and its own children are
  /// collected recursively. Everything else goes through the inline
  /// collector, which contributes spans and media nodes to the current run.
  ///
  /// This collector records no anchors: anchors come from the separate anchor
  /// walk (see `_parseTableCell`), like the production `table_anchor_offsets`.
  List<List<EpubContentNode>> _collectTableCellBlocks(
    XmlElement parent,
    EpubNodeStyle blockStyle,
    double baseFontSize,
    String? link,
    int depth,
  ) {
    // Like the chapter walkers, element nesting past [_maxDepth] contributes
    // nothing. These collectors are anchor-free, so their truncation does not
    // touch the anchor walk's completeness flag; text they drop diverges the
    // canonical stream and the routing gate handles it.
    if (depth > _maxDepth) return const [];
    final blocks = <List<EpubContentNode>>[];
    var children = <EpubContentNode>[];
    final spans = <EpubTextSpan>[];
    void flush() {
      _flushTableCellSpans(spans, children, blockStyle);
      if (children.isNotEmpty) {
        blocks.add(children);
        children = <EpubContentNode>[];
      }
    }

    for (final child in parent.children) {
      if (child is XmlText) {
        _collectTableCellText(child, parent, baseFontSize, link, spans);
        continue;
      }
      if (child is! XmlElement) continue;
      final childStyle = styleOf(child);
      if (childStyle.display == EpubDisplay.none) continue;
      if (childStyle.display == EpubDisplay.inline) {
        _collectTableCellInline(
          child,
          blockStyle,
          baseFontSize,
          link,
          spans,
          children,
          depth + 1,
        );
        continue;
      }
      flush();
      blocks.addAll(
        _collectTableCellBlocks(
          child,
          _nodeStyle(childStyle),
          childStyle.fontSizePx,
          link,
          depth + 1,
        ),
      );
    }
    flush();
    return blocks;
  }

  /// The production `collect_table_cell_inline` for one non-block child.
  ///
  /// Text nodes become spans styled by their parent element, display-block
  /// MathML flushes the run and becomes its own node, inline MathML becomes a
  /// span, and an image flushes the run and becomes an image node (or an alt
  /// span when its source is missing or unusable). Everything else —
  /// including `br`, which emits nothing — recurses.
  void _collectTableCellInline(
    XmlElement element,
    EpubNodeStyle blockStyle,
    double baseFontSize,
    String? link,
    List<EpubTextSpan> spans,
    List<EpubContentNode> children,
    int depth,
  ) {
    if (depth > _maxDepth) return;
    if (_isMathElement(element)) {
      final content = parseMath(element, limits);
      final childStyle = styleOf(element);
      if (content.display == EpubMathDisplay.block) {
        _flushTableCellSpans(spans, children, blockStyle);
        children.add(
          EpubMathNode(
            content: content,
            nodeStyle: blockStyle.copyWith(
              fontSizeMultiplier: childStyle.fontSizePx / baseFontSize,
            ),
            link: link,
          ),
        );
      } else {
        spans.add(
          EpubTextSpan(
            text: content.fallback,
            math: content,
            bold: childStyle.bold,
            italic: childStyle.italic,
            fontFamily: childStyle.fontFamilies.isEmpty
                ? null
                : childStyle.fontFamilies.first,
            fontSizeMultiplier: childStyle.fontSizePx / baseFontSize,
            link: link,
          ),
        );
      }
      return;
    }
    if (element.name.local == 'img') {
      final alt = element.getAttribute('alt') ?? '';
      final rawSrc = element.getAttribute('src');
      final resolved = rawSrc == null
          ? null
          : _resolveRelative(basePath, rawSrc);
      if (resolved == null) {
        if (alt.isNotEmpty) {
          spans.add(_textSpanFor(element, alt, baseFontSize, link));
        }
        return;
      }
      _flushTableCellSpans(spans, children, blockStyle);
      children.add(
        EpubImage(
          src: resolved,
          alt: alt,
          nodeStyle: _nodeStyle(styleOf(element)),
        ),
      );
      return;
    }
    final nestedLink = element.name.local == 'a'
        ? element.getAttribute('href')
        : link;
    for (final child in element.children) {
      if (child is XmlText) {
        _collectTableCellText(child, element, baseFontSize, nestedLink, spans);
      } else if (child is XmlElement) {
        if (styleOf(child).display == EpubDisplay.none) continue;
        _collectTableCellInline(
          child,
          blockStyle,
          baseFontSize,
          nestedLink,
          spans,
          children,
          depth + 1,
        );
      }
    }
  }

  void _collectTableCellText(
    XmlText text,
    XmlElement owner,
    double baseFontSize,
    String? link,
    List<EpubTextSpan> spans,
  ) {
    if (text.value.isEmpty) return;
    spans.add(_textSpanFor(owner, text.value, baseFontSize, link));
  }

  /// The production `flush_table_cell_spans`: collapse and merge the pending
  /// spans and, when any survive, emit them as one paragraph of [style].
  ///
  /// The spans here never carry anchors, so the collapse's anchor-carrying
  /// logic is inert and the shared walk state is untouched.
  void _flushTableCellSpans(
    List<EpubTextSpan> spans,
    List<EpubContentNode> children,
    EpubNodeStyle style,
  ) {
    if (spans.isEmpty) return;
    _collapseWhitespace(spans);
    _mergeSpans(spans);
    if (spans.isNotEmpty) {
      children.add(EpubParagraph(List.of(spans), style));
      spans.clear();
    }
  }

  /// Whether the cell contains an image or MathML element.
  ///
  /// The retained inline-cell anchor stream treats MathML as inline spans and
  /// image alt text as invisible, so a cell mixing either with anchors cannot
  /// have its anchors reproduced from the rendered content.
  bool _cellHasMedia(XmlElement cell) {
    for (final node in cell.descendants.whereType<XmlElement>()) {
      if (node.name.local == 'img' || _isMathElement(node)) return true;
    }
    return false;
  }

  /// Whether the cell has a visible child element whose display is neither
  /// none nor inline, the production `has_block_children` decision.
  bool _hasBlockChildren(XmlElement cell) {
    for (final child in cell.children.whereType<XmlElement>()) {
      final display = styleOf(child).display;
      if (display != EpubDisplay.none && display != EpubDisplay.inline) {
        return true;
      }
    }
    return false;
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
