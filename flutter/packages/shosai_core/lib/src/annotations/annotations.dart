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
/// and its context) so they survive relayout and changed bytes.
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
  }) async {
    checkAnnotationBody(body);
    checkProvenance(provenance);
    final (anchor, quote) = _anchorOf(selection);
    final stored = await _records.create(
      bookId,
      NewAnnotation(
        anchor: anchor,
        quote: quote,
        color: color,
        body: body,
        provenance: provenance,
      ),
    );
    return switch (stored.anchor) {
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
    };
  }

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
  Future<List<ResolvedAnnotation>> list(
    int bookId,
    UnitTextSource text, {
    CancellationToken? cancellation,
  }) async {
    // Reading checks every stored selector, so a cancelled listing skips it.
    cancellation.throwIfCancelled();
    final book = await _records.list(bookId);
    cancellation.throwIfCancelled();
    return _resolve(book, text, cancellation);
  }

  /// Change annotation [id]'s color and body. Returns false when book
  /// [bookId] has no such live annotation.
  Future<bool> update(
    int bookId,
    String id, {
    required HighlightColor color,
    String? body,
  }) async {
    checkAnnotationBody(body);
    return _records.update(bookId, id, color, body);
  }

  /// Delete annotation [id], leaving a tombstone for synchronization.
  /// Returns false when book [bookId] has no such live annotation.
  Future<bool> delete(int bookId, String id) => _records.delete(bookId, id);

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
  for (var index = 0; index < annotations.length; index++) {
    final annotation = annotations[index];
    final sameContent = annotation.contentHash == book.contentHash;
    final quote = annotation.quote;
    switch (annotation.anchor) {
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
  final batch = <({String text, List<_Pending> anchors})>[];
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

  for (final MapEntry(key: unit, value: anchors) in byUnit.entries) {
    cancellation.throwIfCancelled();
    final text = await source.unitText(unit, cancellation: cancellation);
    cancellation.throwIfCancelled();
    if (text == null) continue;
    final epubPath = text.resourcePath;
    final matching = [
      for (final pending in anchors)
        if (annotations[pending.index].anchor case EpubAnchor(
          :final resourcePath,
        ))
          // A spine item that now holds another resource is another chapter.
          if (resourcePath == epubPath) pending else null
        else
          pending,
    ].nonNulls.toList();
    if (matching.isEmpty) continue;
    batch.add((text: text.text, anchors: matching));
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
  List<({String text, List<_Pending> anchors})> work,
  int budget,
  int normalization,
) => Isolate.run(() => _resolveBatch(work, budget, normalization));

/// Resolve every anchor of [work] within [budget] work units and
/// [normalization] normalization units. Runs in its own isolate.
(List<(int, ResolvedAnchor)>, int, int) _resolveBatch(
  List<({String text, List<_Pending> anchors})> work,
  int budget,
  int normalization,
) {
  final shared = ResolutionBudget(budget, null, normalization);
  final results = <(int, ResolvedAnchor)>[];
  for (final unit in work) {
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
