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
/// Returns `null` when the target resource is not a spine item, or when the
/// target names a fragment that does not resolve in the chapter (including an
/// empty fragment). A fragment-less reference resolves to the chapter start.
/// Nothing else is invented: the production internal-link policy never
/// fabricates a position for an unknown anchor.
EpubDurablePoint? resolveInternalLink({
  required EpubBook book,
  required String resource,
  String? fragment,
}) {
  final spine = book.spine.indexOf(resource);
  if (spine < 0) return null;
  if (fragment == null) {
    return EpubDurablePoint(spine: spine, resource: resource, scalar: 0);
  }
  // An empty fragment is not an anchor even if the anchor map somehow carries
  // an empty key: the production parser never records an empty name, and `#`
  // must not resolve to a position.
  if (fragment.isEmpty) return null;
  final scalar = book.chapters[spine].anchors[fragment];
  if (scalar == null) return null;
  return EpubDurablePoint(spine: spine, resource: resource, scalar: scalar);
}

/// A resolved internal link: the durable point plus whether the reference named
/// a fragment, whose scalar is an anchor offset rather than a chapter start.
class EpubLinkTarget {
  const EpubLinkTarget({required this.point, required this.hasFragment});

  final EpubDurablePoint point;

  /// Whether the reference carried a fragment. A fragment offset is only
  /// meaningful in a canonical stream the caller shares with its store; a
  /// chapter start is stream-independent.
  final bool hasFragment;
}

/// Resolve an internal link href found in [fromResource].
///
/// `#fragment` stays in the current document; any other reference resolves
/// against that document's directory. Returns `null` for a foreign origin, an
/// escape above the archive root, a target that is not a spine item, or a
/// fragment that does not resolve in the target chapter.
EpubLinkTarget? resolveBookLink({
  required EpubBook book,
  required String fromResource,
  required String href,
}) {
  final String resource;
  final String? fragment;
  try {
    if (href.startsWith('#')) {
      resource = fromResource;
      fragment = decodeEpubFragment(href.substring(1));
    } else {
      final resolved = resolveEpubReference(directoryOf(fromResource), href);
      resource = resolved.path;
      fragment = resolved.fragment;
    }
  } on EpubPathError {
    return null;
  }
  final point = resolveInternalLink(
    book: book,
    resource: resource,
    fragment: fragment,
  );
  if (point == null) return null;
  return EpubLinkTarget(point: point, hasFragment: fragment != null);
}

/// One resolved table-of-contents row.
///
/// [offset] is the named fragment's canonical scalar, or null when the entry
/// names only a chapter; [depth] is the authored nesting depth, which is
/// retained even when a parent entry itself does not resolve.
class EpubTocLocation {
  const EpubTocLocation({
    required this.depth,
    required this.title,
    required this.spine,
    this.offset,
  });

  final int depth;
  final String title;
  final int spine;
  final int? offset;

  @override
  bool operator ==(Object other) =>
      other is EpubTocLocation &&
      other.depth == depth &&
      other.title == title &&
      other.spine == spine &&
      other.offset == offset;

  @override
  int get hashCode => Object.hash(depth, title, spine, offset);

  @override
  String toString() =>
      'EpubTocLocation(depth: $depth, title: $title, spine: $spine, '
      'offset: $offset)';
}

/// Every table-of-contents entry of [book] that resolves to a durable location.
///
/// Entries that do not resolve (a target outside the spine, or a fragment the
/// target chapter does not carry) are omitted — the production contents policy
/// never invents a position — while their children are still collected at their
/// authored depth.
List<EpubTocLocation> resolveTocLocations(EpubBook book) {
  final locations = <EpubTocLocation>[];
  void collect(List<EpubTocEntry> entries, int depth) {
    for (final entry in entries) {
      final point = resolveInternalLink(
        book: book,
        resource: entry.resource,
        fragment: entry.fragment,
      );
      if (point != null) {
        locations.add(
          EpubTocLocation(
            depth: depth,
            title: entry.title,
            spine: point.spine,
            offset: entry.fragment == null ? null : point.scalar,
          ),
        );
      }
      collect(entry.children, depth + 1);
    }
  }

  collect(book.toc, 0);
  return locations;
}
