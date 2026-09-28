/// Normalized document model for the Phase C evaluation prototype.
///
/// The block/inline shape follows the existing Rust `ContentNode`/`TextSpan`
/// model closely enough that the canonical text stream, anchors and durable
/// offsets can be compared with the production implementation. It is not a
/// wire format and is not intended to be one.
library;

enum EpubDisplay { block, inline, none }

enum EpubTextAlign { start, center, end, justify }

enum EpubDirection { ltr, rtl }

enum EpubFontStyle { normal, italic }

enum EpubFontWeight { normal, bold }

/// Authored width/height values retained for replaced elements and tables.
sealed class EpubLength {
  const EpubLength();
}

class EpubPercentLength extends EpubLength {
  const EpubPercentLength(this.fraction);

  final double fraction;

  @override
  String toString() => '${(fraction * 100).toStringAsFixed(1)}%';
}

class EpubPixelLength extends EpubLength {
  const EpubPixelLength(this.pixels);

  final double pixels;

  @override
  String toString() => '${pixels}px';
}

/// Block-level style annotations derived from the bounded CSS cascade.
class EpubNodeStyle {
  const EpubNodeStyle({
    this.textAlign,
    this.direction = EpubDirection.ltr,
    this.fontSizeMultiplier,
    this.marginLeftEm,
    this.blockBeforeEm,
    this.blockAfterEm,
    this.width,
    this.height,
    this.maxWidth,
    this.fragmentBefore = false,
    this.fragmentAfter = false,
  });

  final EpubTextAlign? textAlign;
  final EpubDirection direction;
  final double? fontSizeMultiplier;
  final double? marginLeftEm;
  final double? blockBeforeEm;
  final double? blockAfterEm;
  final EpubLength? width;
  final EpubLength? height;
  final EpubLength? maxWidth;

  /// Pagination truncated the first nested child boundary of this fragment.
  final bool fragmentBefore;

  /// Pagination truncated the last nested child boundary of this fragment.
  final bool fragmentAfter;

  EpubNodeStyle copyWith({
    EpubTextAlign? textAlign,
    EpubDirection? direction,
    double? fontSizeMultiplier,
    double? marginLeftEm,
    double? blockBeforeEm,
    double? blockAfterEm,
    EpubLength? width,
    EpubLength? height,
    EpubLength? maxWidth,
    bool? fragmentBefore,
    bool? fragmentAfter,
  }) => EpubNodeStyle(
    textAlign: textAlign ?? this.textAlign,
    direction: direction ?? this.direction,
    fontSizeMultiplier: fontSizeMultiplier ?? this.fontSizeMultiplier,
    marginLeftEm: marginLeftEm ?? this.marginLeftEm,
    blockBeforeEm: blockBeforeEm ?? this.blockBeforeEm,
    blockAfterEm: blockAfterEm ?? this.blockAfterEm,
    width: width ?? this.width,
    height: height ?? this.height,
    maxWidth: maxWidth ?? this.maxWidth,
    fragmentBefore: fragmentBefore ?? this.fragmentBefore,
    fragmentAfter: fragmentAfter ?? this.fragmentAfter,
  );
}

/// A styled run of inline text, or a bounded MathML replacement.
class EpubTextSpan {
  EpubTextSpan({
    required this.text,
    this.bold = false,
    this.italic = false,
    this.monospace = false,
    this.fontFamily,
    this.fontSizeMultiplier = 1.0,
    this.preserveWhitespace = false,
    this.link,
    this.math,
    this.canonical,
  });

  String text;
  bool bold;
  bool italic;
  bool monospace;

  /// First admitted embedded family from the computed CSS fallback list.
  String? fontFamily;
  double fontSizeMultiplier;
  bool preserveWhitespace;

  /// If set, this span is a link to the given URL/href.
  String? link;

  /// Bounded Presentation MathML, when this span replaces a `<math>` element.
  EpubMath? math;

  /// Canonical scalar mapping, assigned by [assignCanonicalOffsets].
  EpubCanonicalSpan? canonical;

  /// Element ids/legacy anchor names that resolve to this span's start.
  List<String> anchorIds = const [];

  /// Whether this span's canonical text is selectable by the reader.
  ///
  /// Hidden fallbacks (a successfully rendered image's alt text, a rendered
  /// math expression's fallback) stay in the canonical stream but are not
  /// user-selectable, matching the production canonical/visible split.
  bool selectable = true;

  EpubTextSpan copy() => EpubTextSpan(
    text: text,
    bold: bold,
    italic: italic,
    monospace: monospace,
    fontFamily: fontFamily,
    fontSizeMultiplier: fontSizeMultiplier,
    preserveWhitespace: preserveWhitespace,
    link: link,
    math: math,
    canonical: canonical,
  );
}

/// Canonical scalar range of one span within its chapter stream.
class EpubCanonicalSpan {
  const EpubCanonicalSpan(this.start, this.end);

  final int start;
  final int end;

  int get length => end - start;
}

enum EpubMathDisplay { inline, block }

/// Bounded Presentation MathML: a readable fallback plus an optional
/// expression tree used for layout. The prototype lays out the fallback text;
/// the tree is retained so the boundary cost of real math layout is visible.
class EpubMath {
  const EpubMath({
    required this.display,
    required this.fallback,
    this.expression,
  });

  final EpubMathDisplay display;
  final String fallback;
  final EpubMathExpression? expression;
}

sealed class EpubMathExpression {
  const EpubMathExpression();
}

class EpubMathRow extends EpubMathExpression {
  const EpubMathRow(this.children);

  final List<EpubMathExpression> children;
}

class EpubMathToken extends EpubMathExpression {
  const EpubMathToken(this.text);

  final String text;
}

class EpubMathFraction extends EpubMathExpression {
  const EpubMathFraction(this.numerator, this.denominator);

  final EpubMathExpression numerator;
  final EpubMathExpression denominator;
}

class EpubMathRadical extends EpubMathExpression {
  const EpubMathRadical({required this.radicand, this.index});

  final EpubMathExpression radicand;
  final EpubMathExpression? index;
}

class EpubMathScript extends EpubMathExpression {
  const EpubMathScript({required this.base, this.sub, this.sup});

  final EpubMathExpression base;
  final EpubMathExpression? sub;
  final EpubMathExpression? sup;
}

class EpubMathFenced extends EpubMathExpression {
  const EpubMathFenced({
    required this.open,
    required this.close,
    required this.content,
  });

  final String open;
  final String close;
  final List<EpubMathExpression> content;
}

class EpubMathTable extends EpubMathExpression {
  const EpubMathTable(this.rows);

  final List<List<EpubMathExpression>> rows;
}

/// Semantic row-group role retained from an EPUB table.
enum EpubTableRowGroupKind { head, body, foot }

class EpubTableRowGroup {
  EpubTableRowGroup({required this.kind, required this.rows});

  final EpubTableRowGroupKind kind;
  final List<EpubTableRow> rows;
}

class EpubTableRow {
  EpubTableRow({required this.cells});

  final List<EpubTableCell> cells;
}

class EpubTableCell {
  EpubTableCell({
    this.id,
    this.header = false,
    this.scope,
    this.headers = const [],
    this.rowSpan = 1,
    this.columnSpan = 1,
    required this.children,
    this.blockStarts = const [],
    this.style = const EpubNodeStyle(),
  });

  final String? id;
  final bool header;
  final String? scope;
  final List<String> headers;

  /// Source `rowspan`; zero means all remaining rows in the row group.
  final int rowSpan;
  final int columnSpan;
  final List<EpubContentNode> children;

  /// Indices in [children] that begin a source block and therefore carry a
  /// generated newline before them in the canonical stream.
  final List<int> blockStarts;
  final EpubNodeStyle style;
}

/// A content node in the simplified document model.
sealed class EpubContentNode {
  EpubContentNode({this.canonical});

  EpubCanonicalSpan? canonical;

  /// Element ids/legacy anchor names that resolve to this node's start.
  List<String> anchorIds = const [];

  EpubNodeStyle? get style;
}

class EpubHeading extends EpubContentNode {
  EpubHeading({required this.level, required this.spans, this.nodeStyle})
    : super();

  final int level;
  final List<EpubTextSpan> spans;
  final EpubNodeStyle? nodeStyle;

  @override
  EpubNodeStyle? get style => nodeStyle;
}

class EpubParagraph extends EpubContentNode {
  EpubParagraph(this.spans, this.nodeStyle);

  final List<EpubTextSpan> spans;
  final EpubNodeStyle nodeStyle;

  @override
  EpubNodeStyle? get style => nodeStyle;
}

class EpubBlockQuote extends EpubContentNode {
  EpubBlockQuote({required this.children, this.nodeStyle});

  final List<EpubContentNode> children;
  final EpubNodeStyle? nodeStyle;

  @override
  EpubNodeStyle? get style => nodeStyle;
}

class EpubFigure extends EpubContentNode {
  EpubFigure({required this.children, this.nodeStyle});

  final List<EpubContentNode> children;
  final EpubNodeStyle? nodeStyle;

  @override
  EpubNodeStyle? get style => nodeStyle;
}

class EpubTable extends EpubContentNode {
  EpubTable({
    required this.caption,
    this.captionStyle,
    required this.rowGroups,
    this.nodeStyle,
  });

  final List<EpubTextSpan> caption;
  final EpubNodeStyle? captionStyle;
  final List<EpubTableRowGroup> rowGroups;
  final EpubNodeStyle? nodeStyle;

  @override
  EpubNodeStyle? get style => nodeStyle;
}

class EpubMathNode extends EpubContentNode {
  EpubMathNode({required this.content, this.nodeStyle, this.link});

  final EpubMath content;
  final EpubNodeStyle? nodeStyle;
  final String? link;

  @override
  EpubNodeStyle? get style => nodeStyle;
}

class EpubUnorderedList extends EpubContentNode {
  EpubUnorderedList(this.items);

  final List<List<EpubTextSpan>> items;

  @override
  EpubNodeStyle? get style => null;
}

class EpubOrderedList extends EpubContentNode {
  EpubOrderedList({required this.items, this.start = 1});

  final List<List<EpubTextSpan>> items;
  final int start;

  @override
  EpubNodeStyle? get style => null;
}

class EpubImage extends EpubContentNode {
  EpubImage({
    required this.src,
    required this.alt,
    this.nodeStyle,
    this.caption = const [],
    this.captionStyle,
    this.intrinsicSize,
    this.kind,
  });

  /// Path to the image within the EPUB archive (canonical).
  final String src;
  final String alt;
  final EpubNodeStyle? nodeStyle;

  /// Figure caption retained with the image so pagination keeps them together.
  final List<EpubTextSpan> caption;
  final EpubNodeStyle? captionStyle;

  /// Intrinsic raster dimensions populated from the admitted EPUB resource.
  EpubImageSize? intrinsicSize;

  /// Resource representation established while processing the admitted
  /// resource.
  EpubImageKind? kind;

  @override
  EpubNodeStyle? get style => nodeStyle;
}

class EpubCodeBlock extends EpubContentNode {
  EpubCodeBlock({required this.code, this.language});

  final String code;
  final String? language;

  @override
  EpubNodeStyle? get style => null;
}

class EpubHorizontalRule extends EpubContentNode {
  EpubHorizontalRule();

  @override
  EpubNodeStyle? get style => null;
}

class EpubImageSize {
  const EpubImageSize(this.width, this.height);

  final int width;
  final int height;

  double get aspectRatio => height == 0 ? 1 : width / height;

  @override
  bool operator ==(Object other) =>
      other is EpubImageSize && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() => '${width}x$height';
}

enum EpubImageKind { raster, svg }

/// A TOC entry parsed from the EPUB 3 nav document or EPUB 2 NCX.
class EpubTocEntry {
  const EpubTocEntry({
    required this.title,
    required this.resource,
    this.fragment,
    this.children = const [],
  });

  final String title;

  /// Canonical archive path of the target content document.
  final String resource;

  /// Fragment identifier within the target document, if any.
  final String? fragment;
  final List<EpubTocEntry> children;
}

/// One normalized spine chapter.
class EpubChapter {
  EpubChapter({
    required this.spine,
    required this.resource,
    required this.title,
    required this.blocks,
    required this.canonicalText,
    required this.anchors,
    required this.scalarCount,
  });

  /// Zero-based spine occurrence.
  final int spine;

  /// Canonical archive path of the content document.
  final String resource;
  final String title;
  final List<EpubContentNode> blocks;

  /// The canonical stream: exactly the production `search_text()` order,
  /// including generated separators, image alt text and math fallback.
  final String canonicalText;

  /// Element `id`/legacy anchor name to canonical scalar offset.
  final Map<String, int> anchors;
  final int scalarCount;
}

/// A parsed book. Resources are retained as admitted bytes.
class EpubBook {
  EpubBook({
    required this.title,
    required this.author,
    required this.language,
    required this.spine,
    required this.toc,
    required this.resources,
    required this.chapters,
    required this.embeddedFonts,
    required this.warnings,
  });

  final String title;
  final String? author;
  final String? language;

  /// Canonical resource paths in reading order.
  final List<String> spine;
  final List<EpubTocEntry> toc;
  final Map<String, EpubResource> resources;
  final List<EpubChapter> chapters;

  /// `@font-face` family name to admitted font resource path.
  final Map<String, String> embeddedFonts;

  /// Non-fatal admission notes (rejected resources, unsupported CSS).
  final List<String> warnings;
}

class EpubResource {
  const EpubResource({
    required this.path,
    required this.mediaType,
    required this.bytes,
  });

  final String path;
  final String mediaType;
  final List<int> bytes;

  int get byteLength => bytes.length;
}
