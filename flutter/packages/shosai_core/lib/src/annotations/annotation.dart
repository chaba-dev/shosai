/// Annotation records: anchors, selections and resolved annotations.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../errors.dart';
import '../library/book.dart';
import 'quote.dart';
import 'resolution.dart';

/// Anchor format version of every stored annotation.
const anchorVersion = 1;

/// Longest annotation body, in Unicode scalars.
const maxAnnotationBodyScalars = 65536;

/// Most rectangles one PDF annotation covers.
const maxPdfRectangles = 16384;

/// Longest EPUB resource path, in UTF-8 bytes.
const maxEpubResourcePathBytes = 4096;

/// Most live annotations a document (all its versions) holds.
const maxAnnotationsPerDocument = 1024;

/// Most PDF rectangles across a document's live annotations.
const maxPdfRectanglesPerDocument = 65536;

/// Most bytes a document's live annotations retain in memory, estimated.
const maxAnnotationDocumentBytes = 8 * 1024 * 1024;

/// Fixed per-annotation share of [maxAnnotationDocumentBytes].
const annotationBaseBytes = 256;

/// Most contents (versions) one document spans.
const maxAnnotationDocumentVersions = 128;

const maxProvenanceSystemBytes = 256;
const maxProvenanceIdBytes = 4096;

enum HighlightColor { yellow, green, blue, pink, purple }

/// The three kinds of note (RFD 6, Notes and search), all stored and listed
/// the same way.
enum AnnotationKind {
  /// A text range, with a color and an optional note.
  highlight,

  /// A place, an EPUB position or a PDF page, with a note and no text range.
  pageNote,

  /// The whole book, with a note.
  bookNote,
}

/// A document's content that is not a library book, known by its content
/// hash: what a file opened directly keeps its annotations under.
///
/// Annotations belong to contents, not paths, so a file's annotations are
/// the ones made on the same bytes, whether it was opened directly or
/// imported later.
final class AnnotatedContent {
  /// Throws [CoreErrorKind.invalidRequest] unless [contentHash] is a
  /// lowercase hexadecimal SHA-256 and [title] is 1 to [maxAnnotatedTitleBytes]
  /// UTF-8 bytes.
  AnnotatedContent({
    required this.contentHash,
    required this.format,
    required this.title,
  }) {
    if (!_sha256Hex.hasMatch(contentHash)) {
      throw const CoreException.invalidRequest(
        'A content hash is a lowercase hexadecimal SHA-256.',
      );
    }
    final bytes = utf8.encode(title).length;
    if (bytes < 1 || bytes > maxAnnotatedTitleBytes) {
      throw const CoreException.invalidRequest(
        'An annotated content title is 1 to $maxAnnotatedTitleBytes bytes.',
      );
    }
  }

  /// Lowercase hexadecimal SHA-256 of the content's bytes.
  final String contentHash;
  final BookFormat format;

  /// What the person recognizes the content by, kept with its annotations.
  final String title;
}

/// Longest title an [AnnotatedContent] keeps, in UTF-8 bytes.
const maxAnnotatedTitleBytes = 4096;

final _sha256Hex = RegExp(r'^[0-9a-f]{64}$');

/// A rectangle on a PDF page, in the page's coordinate space (points, y
/// growing downward). Stored as float32 coordinates, so a stored annotation
/// holds the float32 rounding of the rectangles it was created with.
final class PageRect {
  const PageRect(this.left, this.top, this.right, this.bottom);

  final double left;
  final double top;
  final double right;
  final double bottom;

  /// Finite and non-empty. Annotations check this of the float32 rounding
  /// they store ([quantized]), not of the coordinates given.
  bool get isValid =>
      left.isFinite &&
      top.isFinite &&
      right.isFinite &&
      bottom.isFinite &&
      left < right &&
      top < bottom;

  /// This rectangle with each coordinate rounded to float32, as stored. A
  /// coordinate beyond float32's range becomes infinite and two distinct
  /// coordinates may become equal, so a valid rectangle can become invalid.
  PageRect get quantized {
    final coordinates = Float32List.fromList([left, top, right, bottom]);
    return PageRect(
      coordinates[0],
      coordinates[1],
      coordinates[2],
      coordinates[3],
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PageRect &&
      other.left == left &&
      other.top == top &&
      other.right == right &&
      other.bottom == bottom;

  @override
  int get hashCode => Object.hash(left, top, right, bottom);

  @override
  String toString() => 'PageRect($left, $top, $right, $bottom)';
}

/// Where an annotation was made, in the version it was made on.
sealed class AnnotationAnchor {
  const AnnotationAnchor();

  /// The EPUB spine index or PDF page; null for a book note.
  int? get unit;

  AnnotationKind get kind;
}

/// A half-open range of Unicode scalars in one EPUB spine item's canonical
/// text.
final class EpubAnchor extends AnnotationAnchor {
  const EpubAnchor({
    required this.spineIndex,
    required this.resourcePath,
    required this.start,
    required this.end,
  });

  final int spineIndex;

  /// The spine item's canonical resource path, so a reordered spine does not
  /// move the annotation to another chapter.
  final String resourcePath;
  final int start;
  final int end;

  @override
  int get unit => spineIndex;

  @override
  AnnotationKind get kind => AnnotationKind.highlight;

  @override
  bool operator ==(Object other) =>
      other is EpubAnchor &&
      other.spineIndex == spineIndex &&
      other.resourcePath == resourcePath &&
      other.start == start &&
      other.end == end;

  @override
  int get hashCode => Object.hash(spineIndex, resourcePath, start, end);
}

/// Rectangles on a PDF page and, when the page text could be mapped, the
/// half-open range of Unicode scalars of the page text they cover.
final class PdfAnchor extends AnnotationAnchor {
  const PdfAnchor({
    required this.page,
    required this.rectangles,
    this.start,
    this.end,
  });

  final int page;
  final List<PageRect> rectangles;
  final int? start;
  final int? end;

  bool get hasText => start != null;

  @override
  int get unit => page;

  @override
  AnnotationKind get kind => AnnotationKind.highlight;

  @override
  bool operator ==(Object other) =>
      other is PdfAnchor &&
      other.page == page &&
      other.start == start &&
      other.end == end &&
      _listEquals(other.rectangles, rectangles);

  @override
  int get hashCode => Object.hash(page, start, end, Object.hashAll(rectangles));
}

/// Where a page note or a book note is attached: a place, or the whole book.
sealed class NoteAnchor extends AnnotationAnchor {
  const NoteAnchor();
}

/// A place in an EPUB spine item: a Unicode-scalar [offset] into its
/// canonical text, where a page note sits.
final class EpubPlaceAnchor extends NoteAnchor {
  const EpubPlaceAnchor({
    required this.spineIndex,
    required this.resourcePath,
    required this.offset,
  });

  final int spineIndex;

  /// The spine item's canonical resource path; null only for a note whose
  /// chapter path was never recorded, which then follows its spine index.
  final String? resourcePath;
  final int offset;

  @override
  int get unit => spineIndex;

  @override
  AnnotationKind get kind => AnnotationKind.pageNote;

  @override
  bool operator ==(Object other) =>
      other is EpubPlaceAnchor &&
      other.spineIndex == spineIndex &&
      other.resourcePath == resourcePath &&
      other.offset == offset;

  @override
  int get hashCode => Object.hash(spineIndex, resourcePath, offset);
}

/// A PDF page, where a page note sits.
final class PdfPageAnchor extends NoteAnchor {
  const PdfPageAnchor(this.page);

  final int page;

  @override
  int get unit => page;

  @override
  AnnotationKind get kind => AnnotationKind.pageNote;

  @override
  bool operator ==(Object other) =>
      other is PdfPageAnchor && other.page == page;

  @override
  int get hashCode => page.hashCode;
}

/// The whole book: a book note's anchor.
final class BookAnchor extends NoteAnchor {
  const BookAnchor();

  @override
  int? get unit => null;

  @override
  AnnotationKind get kind => AnnotationKind.bookNote;

  @override
  bool operator ==(Object other) => other is BookAnchor;

  @override
  int get hashCode => (BookAnchor).hashCode;
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var index = 0; index < a.length; index++) {
    if (a[index] != b[index]) return false;
  }
  return true;
}

/// Where an imported annotation came from.
final class AnnotationProvenance {
  const AnnotationProvenance(this.system, [this.id]);

  final String system;
  final String? id;

  @override
  bool operator ==(Object other) =>
      other is AnnotationProvenance && other.system == system && other.id == id;

  @override
  int get hashCode => Object.hash(system, id);
}

/// What the reader selected to annotate.
sealed class AnnotationSelection {
  const AnnotationSelection();
}

/// A range of Unicode scalars in an EPUB spine item's canonical [text].
final class EpubTextSelection extends AnnotationSelection {
  const EpubTextSelection({
    required this.spineIndex,
    required this.resourcePath,
    required this.text,
    required this.start,
    required this.end,
  });

  final int spineIndex;
  final String resourcePath;
  final String text;
  final int start;
  final int end;
}

/// A selection on a PDF page: the [rectangles] it covers and, when the page
/// [text] maps to characters, the range of Unicode scalars of that text.
/// Without text the annotation is geometry only and resolves only on the
/// same content.
final class PdfSelection extends AnnotationSelection {
  const PdfSelection({
    required this.page,
    required this.rectangles,
    this.text,
    this.start,
    this.end,
  });

  final int page;
  final List<PageRect> rectangles;
  final String? text;
  final int? start;
  final int? end;
}

/// A book's notes at a glance: how many there are, and the words of the
/// latest one.
final class NotesSummary {
  const NotesSummary(this.count, this.latest);

  static const empty = NotesSummary(0, null);

  /// The book's live annotations.
  final int count;

  /// The words of the latest annotation that has any: its quote as it was
  /// selected, or its note when it quotes nothing. Blank text is no words;
  /// null when no annotation has any.
  final String? latest;

  @override
  bool operator ==(Object other) =>
      other is NotesSummary && other.count == count && other.latest == latest;

  @override
  int get hashCode => Object.hash(count, latest);

  @override
  String toString() => 'NotesSummary($count, $latest)';
}

/// One annotation as the notes surfaces list it across books: read from the
/// store alone, so the book need not be open, and placed as it was made.
final class NoteEntry {
  const NoteEntry({
    required this.id,
    required this.kind,
    required this.color,
    required this.quote,
    required this.body,
    required this.unit,
    required this.offset,
    required this.createdAt,
    required this.modifiedAt,
  });

  final String id;
  final AnnotationKind kind;
  final HighlightColor? color;

  /// A highlight's text as it was selected; null for notes and for PDF
  /// highlights of unmapped text.
  final String? quote;
  final String? body;

  /// The EPUB spine index or PDF page it was made on; null for a book note.
  final int? unit;

  /// Where in [unit] it starts, in Unicode scalars of the unit's text: a
  /// highlight's start or an EPUB page note's place. Null when unknown.
  final int? offset;

  /// ISO 8601 UTC timestamps.
  final String createdAt;
  final String modifiedAt;

  @override
  bool operator ==(Object other) =>
      other is NoteEntry &&
      other.id == id &&
      other.kind == kind &&
      other.color == color &&
      other.quote == quote &&
      other.body == body &&
      other.unit == unit &&
      other.offset == offset &&
      other.createdAt == createdAt &&
      other.modifiedAt == modifiedAt;

  @override
  int get hashCode => Object.hash(
    id,
    kind,
    color,
    quote,
    body,
    unit,
    offset,
    createdAt,
    modifiedAt,
  );

  @override
  String toString() => 'NoteEntry($id, ${kind.name}, $unit, $offset)';
}

/// A library book's notes, in reading order: its book notes first, then
/// each unit's notes by where they start.
final class BookNotes {
  const BookNotes(this.book, this.notes);

  final Book book;
  final List<NoteEntry> notes;
}

/// A page of the library's books that have notes, most recently read first.
final class LibraryNotesPage {
  const LibraryNotesPage(this.books, {required this.hasMore});

  final List<BookNotes> books;
  final bool hasMore;
}

/// Most books one [LibraryNotesPage] lists.
const maxLibraryNotesBooksPerPage = 100;

/// An annotation as stored.
final class StoredAnnotation {
  const StoredAnnotation({
    required this.id,
    required this.contentHash,
    required this.anchor,
    required this.quote,
    required this.color,
    required this.body,
    required this.provenance,
    required this.createdAt,
    required this.modifiedAt,
  });

  /// A random UUID, stable across devices.
  final String id;

  /// The content the anchor was captured from.
  final String contentHash;
  final AnnotationAnchor anchor;

  /// Required for EPUB and for PDF text anchors; notes quote nothing.
  final QuoteSelector? quote;

  /// A highlight's color; notes have none.
  final HighlightColor? color;

  /// The note: optional on a highlight, never blank on a page or book note.
  final String? body;
  final AnnotationProvenance? provenance;

  /// ISO 8601 UTC timestamps.
  final String createdAt;
  final String modifiedAt;

  AnnotationKind get kind => anchor.kind;

  @override
  bool operator ==(Object other) =>
      other is StoredAnnotation &&
      other.id == id &&
      other.contentHash == contentHash &&
      other.anchor == anchor &&
      other.quote == quote &&
      other.color == color &&
      other.body == body &&
      other.provenance == provenance &&
      other.createdAt == createdAt &&
      other.modifiedAt == modifiedAt;

  @override
  int get hashCode => Object.hash(
    id,
    contentHash,
    anchor,
    quote,
    color,
    body,
    provenance,
    createdAt,
    modifiedAt,
  );

  @override
  String toString() => 'StoredAnnotation($id, ${anchor.unit})';
}

/// An annotation resolved against the content being read.
final class ResolvedAnnotation {
  const ResolvedAnnotation({
    required this.annotation,
    required this.resolution,
    this.start,
    this.end,
    this.rectangles = const [],
  });

  final StoredAnnotation annotation;
  final AnnotationResolution resolution;

  /// The half-open Unicode-scalar range the annotation covers now in its
  /// unit's text, for text anchors that resolved. For an EPUB page note that
  /// resolved, [start] is its place and [end] is null.
  final int? start;
  final int? end;

  /// For a PDF geometry-only anchor that resolved: its page rectangles.
  final List<PageRect> rectangles;

  String get id => annotation.id;
  int? get unit => annotation.anchor.unit;

  @override
  bool operator ==(Object other) =>
      other is ResolvedAnnotation &&
      other.annotation == annotation &&
      other.resolution == resolution &&
      other.start == start &&
      other.end == end &&
      _listEquals(other.rectangles, rectangles);

  @override
  int get hashCode => Object.hash(
    annotation,
    resolution,
    start,
    end,
    Object.hashAll(rectangles),
  );

  @override
  String toString() =>
      'ResolvedAnnotation($id, ${resolution.name}, $start, $end)';
}

/// Another content's annotations that the person can choose to bring to the
/// book being read, for example an earlier edition's.
final class AssociationSource {
  const AssociationSource({
    required this.versionId,
    required this.title,
    required this.contentHash,
    required this.liveAnnotations,
  });

  final String versionId;

  /// The book's title when that content was first annotated.
  final String title;
  final String contentHash;

  /// Live annotations of the document that version belongs to.
  final int liveAnnotations;

  @override
  bool operator ==(Object other) =>
      other is AssociationSource &&
      other.versionId == versionId &&
      other.title == title &&
      other.contentHash == contentHash &&
      other.liveAnnotations == liveAnnotations;

  @override
  int get hashCode =>
      Object.hash(versionId, title, contentHash, liveAnnotations);
}

final class AssociationSourcePage {
  const AssociationSourcePage(
    this.sources, {
    this.nextCursor,
    this.previousCursor,
  });

  final List<AssociationSource> sources;
  final String? nextCursor;
  final String? previousCursor;
}

enum AssociationOutcome { associated, alreadyAssociated }

/// Most sources one [AssociationSourcePage] lists.
const maxAssociationSourcesPerPage = 100;

void checkAnnotationBody(String? body) {
  if (body != null &&
      body.length > maxAnnotationBodyScalars &&
      body.runes.length > maxAnnotationBodyScalars) {
    throw const CoreException.limitExceeded(
      'An annotation body exceeds $maxAnnotationBodyScalars Unicode scalars.',
    );
  }
}

/// Throw unless [body] is a note with words, as a page or book note needs.
void checkNoteBody(String body) {
  checkAnnotationBody(body);
  if (body.trim().isEmpty) {
    throw const CoreException.invalidRequest('A note needs some words.');
  }
}

void checkProvenance(AnnotationProvenance? provenance) {
  if (provenance == null) return;
  final system = utf8.encode(provenance.system).length;
  final id = provenance.id == null ? 1 : utf8.encode(provenance.id!).length;
  if (provenance.system.trim().isEmpty ||
      system > maxProvenanceSystemBytes ||
      id == 0 ||
      id > maxProvenanceIdBytes) {
    throw const CoreException.invalidRequest(
      'The annotation provenance is empty or exceeds its byte limit.',
    );
  }
}

/// [rectangles] rounded to float32 as they will be stored, after checking
/// that there are 1 to [maxPdfRectangles] of them and that every rounded
/// rectangle is finite and non-empty. Throws [kind] otherwise.
List<PageRect> checkRectangles(
  List<PageRect> rectangles, {
  CoreErrorKind kind = CoreErrorKind.invalidRequest,
}) {
  if (rectangles.isEmpty || rectangles.length > maxPdfRectangles) {
    throw CoreException(
      kind,
      'A PDF annotation covers 1 to $maxPdfRectangles rectangles.',
    );
  }
  final quantized = [for (final rectangle in rectangles) rectangle.quantized];
  if (!quantized.every((rectangle) => rectangle.isValid)) {
    throw CoreException(
      kind,
      'PDF annotation rectangles must be finite and non-empty in float32.',
    );
  }
  return quantized;
}
