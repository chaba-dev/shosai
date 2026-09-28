/// Bounded reuse of still-valid layout work.
///
/// Layout work is expensive (text measurement) and a cancelled request's work
/// is still valid when a later request asks for the same chapter, width,
/// typography and admitted images. The cache keeps a small number of sessions
/// so bursts (rapid font/resize changes, a mode switch, a resize that does not
/// change the column width) reuse measured blocks instead of measuring again.
library;

import 'dart:collection';

import 'flow.dart';
import 'text_style.dart';

/// Identity of one layout.
///
/// The reader mode is deliberately absent: a flow does not depend on paginated
/// versus continuous, so a mode switch can reuse the same measured blocks.
class EpubLayoutKey {
  const EpubLayoutKey({
    required this.resource,
    required this.contentWidth,
    required this.contentHeight,
    required this.typography,
    required this.imageSignature,
  });

  final String resource;
  final double contentWidth;
  final double contentHeight;
  final ReaderTypography typography;

  /// Identity of the admitted image set (a missing image renders as alt text,
  /// so the set of decoded images changes the layout).
  final int imageSignature;

  @override
  bool operator ==(Object other) =>
      other is EpubLayoutKey &&
      other.resource == resource &&
      other.contentWidth == contentWidth &&
      other.contentHeight == contentHeight &&
      other.typography == typography &&
      other.imageSignature == imageSignature;

  @override
  int get hashCode => Object.hash(
    resource,
    contentWidth,
    contentHeight,
    typography,
    imageSignature,
  );

  @override
  String toString() =>
      'EpubLayoutKey($resource, ${contentWidth}x$contentHeight, '
      '${typography.fontSize}, images=$imageSignature)';
}

/// A small LRU cache of layout sessions.
class EpubLayoutCache {
  EpubLayoutCache({this.maxEntries = 2});

  final int maxEntries;
  final LinkedHashMap<EpubLayoutKey, ChapterLayoutSession> _sessions =
      LinkedHashMap<EpubLayoutKey, ChapterLayoutSession>();

  /// Cache statistics for measurement and tests.
  int hits = 0;
  int misses = 0;
  int evictions = 0;

  int get length => _sessions.length;

  /// The cached session for [key], moved to most-recently-used.
  ChapterLayoutSession? get(EpubLayoutKey key) {
    final session = _sessions.remove(key);
    if (session == null) {
      misses++;
      return null;
    }
    hits++;
    _sessions[key] = session;
    return session;
  }

  /// Cache [session] for [key], evicting the least recently used entry when
  /// the bound is exceeded.
  void store(EpubLayoutKey key, ChapterLayoutSession session) {
    _sessions.remove(key);
    _sessions[key] = session;
    while (_sessions.length > maxEntries) {
      _sessions.remove(_sessions.keys.first);
      evictions++;
    }
  }

  void clear() {
    _sessions.clear();
  }
}
