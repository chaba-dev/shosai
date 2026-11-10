/// Conservative, document-wide projection of another file's quoted passages.
library;

import 'dart:isolate';

import '../cancellation.dart';
import '../errors.dart';
import '../unit_text.dart';
import 'annotation.dart';
import 'resolution.dart';

const maxProjectionTextUnits = 2 * 1024 * 1024;
const maxProjectionUnits = 10000;

/// A bounded target snapshot. Only the most recently used target is retained
/// by Annotations. Durable projections avoid rebuilding it after a restart.
final class ProjectionText {
  const ProjectionText(this.units);
  final List<String> units;

  static Future<ProjectionText> read(
    UnitTextSource source,
    CancellationToken? cancellation,
  ) async {
    if (source.unitCount > maxProjectionUnits) {
      throw const CoreException.limitExceeded(
        'Cross-format text indexing is incomplete.',
      );
    }
    final units = <String>[];
    var length = 0;
    for (var unit = 0; unit < source.unitCount; unit++) {
      cancellation.throwIfCancelled();
      final text = await source.unitText(unit, cancellation: cancellation);
      cancellation.throwIfCancelled();
      // An unknown text layer must not join two disconnected passages.
      final value = text?.text ?? '\u0000';
      length += value.length + 1;
      if (length > maxProjectionTextUnits) {
        throw const CoreException.limitExceeded(
          'Cross-format text indexing is incomplete.',
        );
      }
      units.add(value);
    }
    return ProjectionText(List.unmodifiable(units));
  }

  Future<List<ResolvedAnnotation>> project(
    List<StoredAnnotation> annotations,
    int normalization,
    CancellationToken? cancellation,
  ) async {
    cancellation.throwIfCancelled();
    final units = this.units;
    final result = await Isolate.run(
      () => _project(units, annotations, normalization),
    );
    cancellation.throwIfCancelled();
    return result;
  }
}

List<ResolvedAnnotation> _project(
  List<String> units,
  List<StoredAnnotation> annotations,
  int normalization,
) {
  final budget = ResolutionBudget(maxAnchorResolutionWork, null, normalization);
  final results = <ResolvedAnnotation>[];
  try {
    final starts = <int>[];
    final ends = <int>[];
    var offset = 0;
    for (final unit in units) {
      budget.spend(unit.length);
      starts.add(offset);
      offset += unit.runes.length;
      ends.add(offset);
      offset++; // The explicit inter-unit space.
    }
    final text = AnchorText(units.join(' '), budget: budget);
    for (final annotation in annotations) {
      final match = resolveStoredAnchor(text, 0, 0, annotation.quote!, budget);
      final fragments = <AnnotationFragment>[];
      if (match.start case final start?) {
        final end = match.end!;
        for (var unit = 0; unit < units.length; unit++) {
          budget.spend(1);
          final left = start > starts[unit] ? start : starts[unit];
          final right = end < ends[unit] ? end : ends[unit];
          if (left < right) {
            fragments.add((
              unit: unit,
              start: left - starts[unit],
              end: right - starts[unit],
            ));
          }
        }
      }
      results.add(
        ResolvedAnnotation(
          annotation: annotation,
          resolution: match.resolution,
          start: fragments.firstOrNull?.start,
          end: fragments.firstOrNull?.end,
          fragments: List.unmodifiable(fragments),
        ),
      );
    }
  } on CoreException catch (error) {
    if (error.kind != CoreErrorKind.limitExceeded) rethrow;
    // A budget limit does not prove a passage absent. Keep completed results,
    // leave the rest explicitly incomplete, and never cache those as misses.
    for (final annotation in annotations.skip(results.length)) {
      results.add(
        ResolvedAnnotation(
          annotation: annotation,
          resolution: AnnotationResolution.incomplete,
        ),
      );
    }
  }
  return results;
}
