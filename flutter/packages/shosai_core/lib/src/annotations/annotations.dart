/// Highlights and notes anchored in book text (RFD 6).
library;

import 'dart:convert';
import 'dart:isolate';

import '../cancellation.dart';
import '../errors.dart';
import '../store/store.dart';
import '../unit_text.dart';
import 'annotation.dart';
import 'quote.dart';
import 'records.dart';
import 'resolution.dart';

/// Text resolved in one isolate run, in UTF-16 code units.
const _resolutionBatchUnits = 4 * 1024 * 1024;

/// A book's annotations: highlights with optional notes, anchored by layered
/// evidence (offsets in the content they were made on, the normalized quote
/// and its context) so they survive relayout and changed bytes, and page
/// notes and book notes, anchored at a place or at nothing.
///
/// Annotations belong to a document that can span several contents (an
/// earlier edition, a re-exported file). They follow a book's content
/// through removal and re-import; [associate] brings another content's
/// annotations to the book being read.
final class Annotations {
  Annotations(Store store) : _records = AnnotationRecords(store);

  final AnnotationRecords _records;

  /// Annotate [selection] in book [bookId].
  Future<ResolvedAnnotation> create(
    int bookId,
    AnnotationSelection selection, {
    HighlightColor color = HighlightColor.yellow,
    String? body,
    AnnotationProvenance? provenance,
  }) => _create(
    LibraryBookOwner(bookId),
    selection,
    color: color,
    body: body,
    provenance: provenance,
  );

  /// Annotate [selection] in [content], a document opened outside the
  /// library.
  Future<ResolvedAnnotation> createInContent(
    AnnotatedContent content,
    AnnotationSelection selection, {
    HighlightColor color = HighlightColor.yellow,
    String? body,
    AnnotationProvenance? provenance,
  }) => _create(
    ContentOwner(content),
    selection,
    color: color,
    body: body,
    provenance: provenance,
  );

  /// Write [body] as a page note at [anchor], or as a book note when
  /// [anchor] is a [BookAnchor], in book [bookId].
  Future<ResolvedAnnotation> createNote(
    int bookId,
    NoteAnchor anchor,
    String body, {
    AnnotationProvenance? provenance,
  }) => _createNote(LibraryBookOwner(bookId), anchor, body, provenance);

  /// Write a note in [content], a document opened outside the library, as
  /// [createNote] does in a book.
  Future<ResolvedAnnotation> createNoteInContent(
    AnnotatedContent content,
    NoteAnchor anchor,
    String body, {
    AnnotationProvenance? provenance,
  }) => _createNote(ContentOwner(content), anchor, body, provenance);

  Future<ResolvedAnnotation> _createNote(
    AnnotationOwner owner,
    NoteAnchor anchor,
    String body,
    AnnotationProvenance? provenance,
  ) async {
    checkNoteBody(body);
    checkProvenance(provenance);
    _checkNoteAnchor(anchor);
    return _resolvedAsCreated(
      await _records.create(
        owner,
        NewAnnotation(
          anchor: anchor,
          quote: null,
          color: null,
          body: body,
          provenance: provenance,
        ),
      ),
    );
  }

  Future<ResolvedAnnotation> _create(
    AnnotationOwner owner,
    AnnotationSelection selection, {
    required HighlightColor color,
    required String? body,
    required AnnotationProvenance? provenance,
  }) async {
    checkAnnotationBody(body);
    checkProvenance(provenance);
    final (anchor, quote) = _anchorOf(selection);
    return _resolvedAsCreated(
      await _records.create(
        owner,
        NewAnnotation(
          anchor: anchor,
          quote: quote,
          color: color,
          body: body,
          provenance: provenance,
        ),
      ),
    );
  }

  /// [stored] resolved against the content it was just made on.
  ResolvedAnnotation _resolvedAsCreated(StoredAnnotation stored) =>
      switch (stored.anchor) {
        EpubAnchor(:final start, :final end) ||
        PdfAnchor(:final int start, :final int end) => ResolvedAnnotation(
          annotation: stored,
          resolution: AnnotationResolution.exact,
          start: start,
          end: end,
        ),
        PdfAnchor(:final rectangles) => ResolvedAnnotation(
          annotation: stored,
          resolution: AnnotationResolution.exact,
          rectangles: rectangles,
        ),
        EpubPlaceAnchor(:final offset) => ResolvedAnnotation(
          annotation: stored,
          resolution: AnnotationResolution.exact,
          start: offset,
        ),
        PdfPageAnchor() || BookAnchor() => ResolvedAnnotation(
          annotation: stored,
          resolution: AnnotationResolution.exact,
        ),
      };

  /// Book [bookId]'s live annotations, oldest first, resolved against
  /// [text], the book as it is open now.
  ///
  /// [cancellation] is observed between steps: before and after each unit's
  /// text is read, around each resolution batch, and before returning, so a
  /// cancelled listing never returns results. Work inside one batch (at most
  /// a few MiB of text, bounded by [maxAnchorResolutionWork]) runs in another
  /// isolate and is not interrupted; its results are discarded.
  ///
  /// Checking the stored selectors and resolving them share one
  /// [maxQuoteNormalizationWork] allowance; a listing that needs more throws
  /// [CoreErrorKind.limitExceeded].
  ///
  /// With [kinds], only annotations of those kinds are resolved and listed.
  Future<List<ResolvedAnnotation>> list(
    int bookId,
    UnitTextSource text, {
    Set<AnnotationKind>? kinds,
    CancellationToken? cancellation,
  }) => _list(LibraryBookOwner(bookId), text, kinds, cancellation);

  /// [content]'s live annotations, as [list] resolves a book's.
  Future<List<ResolvedAnnotation>> listInContent(
    AnnotatedContent content,
    UnitTextSource text, {
    Set<AnnotationKind>? kinds,
    CancellationToken? cancellation,
  }) => _list(ContentOwner(content), text, kinds, cancellation);

  Future<List<ResolvedAnnotation>> _list(
    AnnotationOwner owner,
    UnitTextSource text,
    Set<AnnotationKind>? kinds,
    CancellationToken? cancellation,
  ) async {
    // Reading checks every stored selector, so a cancelled listing skips it.
    cancellation.throwIfCancelled();
    var book = await _records.list(owner);
    cancellation.throwIfCancelled();
    if (kinds != null) {
      book = BookAnnotations(book.contentHash, [
        for (final annotation in book.annotations)
          if (kinds.contains(annotation.kind)) annotation,
      ], book.normalization);
    }
    return _resolve(book, text, cancellation);
  }

  /// A page of the library's books that have annotations, most recently
  /// read first, each with its annotations in reading order. Read from the
  /// store alone: nothing is resolved, so no book need be open.
  Future<LibraryNotesPage> libraryNotes({
    int offset = 0,
    int limit = 20,
    CancellationToken? cancellation,
  }) async {
    if (offset < 0 || limit < 1 || limit > maxLibraryNotesBooksPerPage) {
      throw const CoreException.invalidRequest(
        'A library notes page lists 1 to $maxLibraryNotesBooksPerPage books '
        'from a non-negative offset.',
      );
    }
    cancellation.throwIfCancelled();
    final page = await _records.libraryNotes(offset, limit);
    cancellation.throwIfCancelled();
    return page;
  }

  /// How many annotations book [bookId] has and the words of the latest one,
  /// read from the store alone: nothing is resolved, so the book need not be
  /// open. A book that is not in the library has none.
  Future<NotesSummary> summary(int bookId) => _records.summary(bookId);

  /// Change highlight [id]'s color and body. Returns false when book
  /// [bookId] has no such live highlight.
  Future<bool> update(
    int bookId,
    String id, {
    required HighlightColor color,
    String? body,
  }) async {
    checkAnnotationBody(body);
    return _records.update(LibraryBookOwner(bookId), id, color, body);
  }

  /// Change highlight [id]'s color and body. Returns false when [content]
  /// has no such live highlight.
  Future<bool> updateInContent(
    AnnotatedContent content,
    String id, {
    required HighlightColor color,
    String? body,
  }) async {
    checkAnnotationBody(body);
    return _records.update(ContentOwner(content), id, color, body);
  }

  /// Rewrite page or book note [id]. Returns false when book [bookId] has no
  /// such live note.
  Future<bool> updateNote(int bookId, String id, String body) async {
    checkNoteBody(body);
    return _records.updateNote(LibraryBookOwner(bookId), id, body);
  }

  /// Rewrite page or book note [id] of [content], as [updateNote] does a
  /// book's.
  Future<bool> updateNoteInContent(
    AnnotatedContent content,
    String id,
    String body,
  ) async {
    checkNoteBody(body);
    return _records.updateNote(ContentOwner(content), id, body);
  }

  /// Delete annotation [id], leaving a tombstone for synchronization.
  /// Returns false when book [bookId] has no such live annotation.
  Future<bool> delete(int bookId, String id) =>
      _records.delete(LibraryBookOwner(bookId), id);

  /// Delete annotation [id] of [content], as [delete] does a book's.
  Future<bool> deleteInContent(AnnotatedContent content, String id) =>
      _records.delete(ContentOwner(content), id);

  /// Other contents of book [bookId]'s format whose annotations could be
  /// brought to it, a page at a time.
  Future<AssociationSourcePage> associationSources(
    int bookId, {
    String? cursor,
    int limit = 20,
    CancellationToken? cancellation,
  }) async {
    if (limit < 1 || limit > maxAssociationSourcesPerPage) {
      throw const CoreException.invalidRequest(
        'An association source page lists 1 to '
        '$maxAssociationSourcesPerPage sources.',
      );
    }
    cancellation.throwIfCancelled();
    final page = await _records.associationSources(bookId, cursor, limit);
    cancellation.throwIfCancelled();
    return page;
  }

  /// Bring the annotations of the document [sourceVersionId] belongs to into
  /// book [bookId]'s document.
  Future<AssociationOutcome> associate(String sourceVersionId, int bookId) =>
      _records.associate(sourceVersionId, bookId);
}

void _checkNoteAnchor(NoteAnchor anchor) {
  switch (anchor) {
    case EpubPlaceAnchor(:final spineIndex, :final resourcePath, :final offset):
      if (spineIndex < 0 ||
          offset < 0 ||
          resourcePath == null ||
          resourcePath.isEmpty ||
          utf8.encode(resourcePath).length > maxEpubResourcePathBytes) {
        throw const CoreException.invalidRequest(
          'An EPUB page note needs a spine index, a place and a resource path '
          'of at most $maxEpubResourcePathBytes bytes.',
        );
      }
    case PdfPageAnchor(:final page):
      if (page < 0) {
        throw const CoreException.invalidRequest(
          'A PDF page note needs a page.',
        );
      }
    case BookAnchor():
  }
}

(AnnotationAnchor, QuoteSelector?) _anchorOf(AnnotationSelection selection) {
  switch (selection) {
    case EpubTextSelection():
      final path = selection.resourcePath;
      if (selection.spineIndex < 0 ||
          path.isEmpty ||
          utf8.encode(path).length > maxEpubResourcePathBytes) {
        throw const CoreException.invalidRequest(
          'An EPUB annotation needs a spine index and a resource path of '
          'at most $maxEpubResourcePathBytes bytes.',
        );
      }
      final quote = QuoteSelector.fromText(
        selection.text.runes.toList(),
        selection.start,
        selection.end,
      );
      return (
        EpubAnchor(
          spineIndex: selection.spineIndex,
          resourcePath: path,
          start: selection.start,
          end: selection.end,
        ),
        quote,
      );
    case PdfSelection():
      final rectangles = checkRectangles(selection.rectangles);
      if (selection.page < 0) {
        throw const CoreException.invalidRequest(
          'A PDF annotation needs a page.',
        );
      }
      final text = selection.text;
      if (text == null) {
        return (PdfAnchor(page: selection.page, rectangles: rectangles), null);
      }
      final (start, end) = (selection.start, selection.end);
      if (start == null || end == null) {
        throw const CoreException.invalidRequest(
          'A PDF text annotation needs its character range.',
        );
      }
      return (
        PdfAnchor(
          page: selection.page,
          rectangles: rectangles,
          start: start,
          end: end,
        ),
        QuoteSelector.fromText(text.runes.toList(), start, end),
      );
  }
}

/// One page note on another content, waiting for its unit's text.
typedef _PendingPlace = ({int index, int offset});

/// One unit's text with the anchors and page notes to resolve in it.
typedef _BatchUnit = ({
  String text,
  List<_Pending> anchors,
  List<_PendingPlace> places,
});

/// One text anchor waiting for its unit's text.
typedef _Pending = ({
  int index,
  int start,
  int end,
  QuoteSelector quote,
  bool sameContent,
});

Future<List<ResolvedAnnotation>> _resolve(
  BookAnnotations book,
  UnitTextSource source,
  CancellationToken? cancellation,
) async {
  final annotations = book.annotations;
  final resolved = List<ResolvedAnnotation>.generate(
    annotations.length,
    (index) => ResolvedAnnotation(
      annotation: annotations[index],
      resolution: AnnotationResolution.orphaned,
    ),
  );
  final byUnit = <int, List<_Pending>>{};
  final placesByUnit = <int, List<_PendingPlace>>{};
  for (var index = 0; index < annotations.length; index++) {
    final annotation = annotations[index];
    final sameContent = annotation.contentHash == book.contentHash;
    final quote = annotation.quote;
    switch (annotation.anchor) {
      case BookAnchor():
        resolved[index] = ResolvedAnnotation(
          annotation: annotation,
          resolution: AnnotationResolution.exact,
        );
      case PdfPageAnchor(:final page):
        // A page is the only evidence a PDF page note has: on another
        // content it stays on the same page, if there is one.
        if (page < source.unitCount) {
          resolved[index] = ResolvedAnnotation(
            annotation: annotation,
            resolution: sameContent
                ? AnnotationResolution.exact
                : AnnotationResolution.recovered,
          );
        }
      case EpubPlaceAnchor(:final spineIndex, :final offset):
        if (spineIndex >= source.unitCount) continue;
        if (sameContent) {
          resolved[index] = ResolvedAnnotation(
            annotation: annotation,
            resolution: AnnotationResolution.exact,
            start: offset,
          );
        } else {
          // Another content keeps the note in the same chapter, at most at
          // its end, when the spine item still holds it.
          (placesByUnit[spineIndex] ??= []).add((index: index, offset: offset));
        }
      case PdfAnchor(:final page, :final rectangles, start: null):
        // Geometry is only meaningful on the content it was drawn on.
        if (sameContent && page < source.unitCount) {
          resolved[index] = ResolvedAnnotation(
            annotation: annotation,
            resolution: AnnotationResolution.exact,
            rectangles: rectangles,
          );
        }
      case EpubAnchor(:final spineIndex, :final start, :final end) ||
          PdfAnchor(page: final spineIndex, :final int start, :final int end):
        if (quote == null || spineIndex >= source.unitCount) continue;
        (byUnit[spineIndex] ??= []).add((
          index: index,
          start: start,
          end: end,
          quote: quote,
          sameContent: sameContent,
        ));
      case PdfAnchor():
      // A text anchor always has both ends; records never store one.
    }
  }

  var budget = maxAnchorResolutionWork;
  // The listing's normalization allowance, left from checking its records.
  var normalization = book.normalization;
  final batch = <_BatchUnit>[];
  var batchUnits = 0;
  Future<void> flush() async {
    if (batch.isEmpty) return;
    final work = List.of(batch);
    batch.clear();
    batchUnits = 0;
    cancellation.throwIfCancelled();
    final (results, left, normalizationLeft) = await _runBatch(
      work,
      budget,
      normalization,
    );
    cancellation.throwIfCancelled();
    budget = left;
    normalization = normalizationLeft;
    for (final (index, anchor) in results) {
      resolved[index] = ResolvedAnnotation(
        annotation: annotations[index],
        resolution: anchor.resolution,
        start: anchor.start,
        end: anchor.end,
      );
    }
  }

  for (final unit in {...byUnit.keys, ...placesByUnit.keys}) {
    final anchors = byUnit[unit] ?? const <_Pending>[];
    cancellation.throwIfCancelled();
    final text = await source.unitText(unit, cancellation: cancellation);
    cancellation.throwIfCancelled();
    if (text == null) continue;
    final epubPath = text.resourcePath;
    final places = [
      for (final place in placesByUnit[unit] ?? const <_PendingPlace>[])
        // A page note has no quote to tell its chapter by: a known path
        // must still be the spine item's. Only a note saved without one
        // falls back to the spine index.
        if ((annotations[place.index].anchor as EpubPlaceAnchor).resourcePath
            case final path when path == null || path == epubPath)
          place,
    ];
    final matching = [
      for (final pending in anchors)
        if (annotations[pending.index].anchor case EpubAnchor(
          :final resourcePath,
        ))
          // A spine item that now holds another resource is another chapter;
          // an unknown path leaves the text to decide.
          if (epubPath == null || resourcePath == epubPath) pending else null
        else
          pending,
    ].nonNulls.toList();
    if (matching.isEmpty && places.isEmpty) continue;
    batch.add((text: text.text, anchors: matching, places: places));
    batchUnits += text.text.length;
    if (batchUnits >= _resolutionBatchUnits) await flush();
  }
  await flush();
  cancellation.throwIfCancelled();
  return resolved;
}

/// Resolve [work] in another isolate. Top level so the closure sent there
/// captures only [work], [budget] and [normalization], not the caller's
/// context.
Future<(List<(int, ResolvedAnchor)>, int, int)> _runBatch(
  List<_BatchUnit> work,
  int budget,
  int normalization,
) => Isolate.run(() => _resolveBatch(work, budget, normalization));

/// Resolve every anchor of [work] within [budget] work units and
/// [normalization] normalization units. Runs in its own isolate.
(List<(int, ResolvedAnchor)>, int, int) _resolveBatch(
  List<_BatchUnit> work,
  int budget,
  int normalization,
) {
  final shared = ResolutionBudget(budget, null, normalization);
  final results = <(int, ResolvedAnchor)>[];
  for (final unit in work) {
    if (unit.places.isNotEmpty) {
      // Counting the unit's scalars to clamp its page notes is work too.
      shared.spend(unit.text.length);
      final length = unit.text.runes.length;
      for (final place in unit.places) {
        results.add((
          place.index,
          ResolvedAnchor(
            AnnotationResolution.recovered,
            place.offset < length ? place.offset : length,
          ),
        ));
      }
    }
    if (unit.anchors.isEmpty) continue;
    final text = AnchorText(unit.text, budget: shared);
    for (final anchor in unit.anchors) {
      // Offsets are only evidence on the content they were captured from.
      final (start, end) = anchor.sameContent
          ? (anchor.start, anchor.end)
          : (0, 0);
      // Records validated each selector when they read it.
      results.add((
        anchor.index,
        resolveStoredAnchor(text, start, end, anchor.quote, shared),
      ));
    }
  }
  return (results, shared.remaining, shared.normalization);
}
