/// Durable addresses and progress, ported from the 5B `renderer::address`
/// module. A durable point names a place in the *document*, never in a layout.
library;

import 'model.dart';
import 'paths.dart';

enum EpubPositionEdge { startOrInterior, end }

/// A stable place in an EPUB document: spine occurrence plus canonical scalar.
class EpubDurablePoint {
  const EpubDurablePoint({
    required this.spine,
    required this.resource,
    required this.scalar,
  });

  /// Spine occurrence (zero-based), not a layout page.
  final int spine;

  /// Canonical archive path of the spine item.
  final String resource;

  /// Canonical scalar offset within the chapter.
  final int scalar;

  void validate() {
    canonicalEpubPath(resource);
    if (scalar < 0) {
      throw const EpubPathError('durable scalar is negative');
    }
  }

  @override
  bool operator ==(Object other) =>
      other is EpubDurablePoint &&
      other.spine == spine &&
      other.resource == resource &&
      other.scalar == scalar;

  @override
  int get hashCode => Object.hash(spine, resource, scalar);

  @override
  String toString() => 'Epub($spine, $resource, $scalar)';
}

class EpubReadingPosition {
  const EpubReadingPosition({
    required this.point,
    this.edge = EpubPositionEdge.startOrInterior,
  });

  final EpubDurablePoint point;
  final EpubPositionEdge edge;
}

/// Progress is independent of pagination: `(spine + scalar / chapter_scalars)
/// / spine_count`, clamped to [0, 1]. Null offset contributes zero. At an
/// empty chapter's end the fraction is one.
double epubProgress({
  required int spine,
  required int? scalar,
  required int chapterScalars,
  required int spineCount,
  EpubPositionEdge edge = EpubPositionEdge.startOrInterior,
}) {
  if (spineCount == 0) return 0;
  final double chapterFraction;
  if (chapterScalars == 0) {
    chapterFraction = edge == EpubPositionEdge.end ? 1.0 : 0.0;
  } else {
    chapterFraction = ((scalar ?? 0) / chapterScalars).clamp(0.0, 1.0);
  }
  return ((spine + chapterFraction) / spineCount).clamp(0.0, 1.0);
}

/// Clamp a durable scalar into a chapter's canonical range.
int clampScalar(int scalar, int scalarCount) =>
    scalar < 0 ? 0 : (scalar > scalarCount ? scalarCount : scalar);

/// Resolve an internal link target (resource + fragment) to a durable point.
///
/// Returns `null` when the target resource is not a spine item or the fragment
/// is unknown. The reader then falls back to the chapter start, matching the
/// production internal-link policy of never inventing a position.
EpubDurablePoint? resolveInternalLink({
  required EpubBook book,
  required String resource,
  String? fragment,
}) {
  final spine = book.spine.indexOf(resource);
  if (spine < 0) return null;
  final chapter = book.chapters[spine];
  var scalar = 0;
  if (fragment != null && fragment.isNotEmpty) {
    scalar = chapter.anchors[fragment] ?? 0;
  }
  return EpubDurablePoint(spine: spine, resource: resource, scalar: scalar);
}
