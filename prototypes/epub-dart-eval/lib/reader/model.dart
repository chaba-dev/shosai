/// Immutable reader model for the evaluation prototype.
library;

import 'dart:ui' as ui;

import 'package:shosai_epub/shosai_epub.dart';

import 'layout/flow.dart';
import 'layout/text_style.dart';
import 'layout/pages.dart';
import 'theme.dart';

enum EpubReaderMode { paginated, continuous }

enum EpubReaderStatus { idle, loading, ready, failed }

enum EpubSelectionPhase { idle, selecting, selected }

class EpubSelection {
  const EpubSelection({
    required this.anchor,
    required this.focus,
    this.phase = EpubSelectionPhase.selecting,
  });

  final int anchor;
  final int focus;
  final EpubSelectionPhase phase;

  int get start => anchor <= focus ? anchor : focus;
  int get end => anchor <= focus ? focus : anchor;

  EpubSelection copyWith({
    int? anchor,
    int? focus,
    EpubSelectionPhase? phase,
  }) => EpubSelection(
    anchor: anchor ?? this.anchor,
    focus: focus ?? this.focus,
    phase: phase ?? this.phase,
  );
}

class EpubHighlight {
  const EpubHighlight({
    required this.id,
    required this.spine,
    required this.start,
    required this.end,
    required this.color,
  });

  final String id;
  final int spine;
  final int start;
  final int end;
  final ReaderHighlightColor color;
}

/// Reader viewport and layout geometry for the current mode.
class EpubLayoutGeometry {
  const EpubLayoutGeometry({
    required this.viewportWidth,
    required this.viewportHeight,
    required this.contentWidth,
    required this.contentHeight,
    required this.columns,
    required this.pageWidth,
    required this.pageHeight,
  });

  final double viewportWidth;
  final double viewportHeight;

  /// One text column's width.
  final double contentWidth;

  /// Content height available to one page (paginated).
  final double contentHeight;

  /// 1 or 2 (paginated spread).
  final int columns;
  final double pageWidth;
  final double pageHeight;

  @override
  bool operator ==(Object other) =>
      other is EpubLayoutGeometry &&
      other.viewportWidth == viewportWidth &&
      other.viewportHeight == viewportHeight &&
      other.contentWidth == contentWidth &&
      other.contentHeight == contentHeight &&
      other.columns == columns &&
      other.pageWidth == pageWidth &&
      other.pageHeight == pageHeight;

  @override
  int get hashCode => Object.hash(
    viewportWidth,
    viewportHeight,
    contentWidth,
    contentHeight,
    columns,
    pageWidth,
    pageHeight,
  );
}

class EpubReaderModel {
  EpubReaderModel({
    this.status = EpubReaderStatus.idle,
    this.book,
    this.path,
    this.error,
    this.generation = 0,
    this.mode = EpubReaderMode.paginated,
    this.typography = const ReaderTypography(
      fontFamily: 'Inter',
      fontFamilyFallback: ['Noto Sans JP'],
      fontSize: 18,
      lineHeight: 1.5,
      palette: ReaderPalette.light,
    ),
    this.theme = ReaderTheme.light,
    this.spine = 0,
    this.scalar = 0,
    this.unit = 0,
    this.unitCount = 0,
    this.layoutRevision = 0,
    this.geometry,
    this.flow,
    this.paginated,
    Map<String, ui.Image> images = const {},
    Map<String, String> embeddedFamilies = const {},
    this.relayoutBusy = false,
    this.relayoutPending = false,
    this.selection,
    List<EpubHighlight> highlights = const [],
    this.contentsOpen = false,
    this.contentsSpine,
    this.notice,
    List<String> warnings = const [],
    this.progress = 0,
    this.continuousOffset = 0,
    this.firstContentMicros,
    this.lastLayoutMicros,
  }) : images = Map.unmodifiable(images),
       embeddedFamilies = Map.unmodifiable(embeddedFamilies),
       highlights = List.unmodifiable(highlights),
       warnings = List.unmodifiable(warnings);

  final EpubReaderStatus status;
  final EpubBook? book;
  final String? path;
  final String? error;
  final int generation;
  final EpubReaderMode mode;
  final ReaderTypography typography;
  final ReaderTheme theme;

  /// Current durable position.
  final int spine;
  final int scalar;

  /// Presentation page ordinal (paginated) or the first visible chapter
  /// ordinal in continuous mode.
  final int unit;
  final int unitCount;
  final int layoutRevision;
  final EpubLayoutGeometry? geometry;
  final ChapterFlow? flow;
  final PaginatedChapter? paginated;
  final Map<String, ui.Image> images;
  final Map<String, String> embeddedFamilies;
  final bool relayoutBusy;
  final bool relayoutPending;
  final EpubSelection? selection;
  final List<EpubHighlight> highlights;
  final bool contentsOpen;
  final int? contentsSpine;
  final String? notice;
  final List<String> warnings;
  final double progress;
  final double continuousOffset;

  /// Time from open request to the first laid-out chapter, when measured.
  final int? firstContentMicros;
  final int? lastLayoutMicros;

  EpubChapter? get chapter {
    final current = book;
    if (current == null || spine < 0 || spine >= current.chapters.length) {
      return null;
    }
    return current.chapters[spine];
  }

  String get title => book?.title.isNotEmpty == true ? book!.title : 'Untitled';

  /// The spread's visible page ordinals.
  List<int> get visiblePages {
    final paginatedChapter = paginated;
    if (paginatedChapter == null) return const [];
    return pagesForUnit(unit);
  }

  /// Page ordinals shown for one spread unit.
  List<int> pagesForUnit(int unit) {
    final paginatedChapter = paginated;
    if (paginatedChapter == null) return const [];
    final columns = geometry?.columns ?? 1;
    final start = unit * columns;
    final pages = <int>[];
    for (
      var index = start;
      index < start + columns && index < paginatedChapter.pages.length;
      index++
    ) {
      pages.add(index);
    }
    return pages;
  }

  EpubReaderModel copyWith({
    EpubReaderStatus? status,
    EpubBook? book,
    String? path,
    Object? error = _unset,
    int? generation,
    EpubReaderMode? mode,
    ReaderTypography? typography,
    ReaderTheme? theme,
    int? spine,
    int? scalar,
    int? unit,
    int? unitCount,
    int? layoutRevision,
    Object? geometry = _unset,
    Object? flow = _unset,
    Object? paginated = _unset,
    Map<String, ui.Image>? images,
    Map<String, String>? embeddedFamilies,
    bool? relayoutBusy,
    bool? relayoutPending,
    Object? selection = _unset,
    List<EpubHighlight>? highlights,
    bool? contentsOpen,
    Object? contentsSpine = _unset,
    Object? notice = _unset,
    List<String>? warnings,
    double? progress,
    double? continuousOffset,
    Object? firstContentMicros = _unset,
    Object? lastLayoutMicros = _unset,
  }) => EpubReaderModel(
    status: status ?? this.status,
    book: book ?? this.book,
    path: path ?? this.path,
    error: identical(error, _unset) ? this.error : error as String?,
    generation: generation ?? this.generation,
    mode: mode ?? this.mode,
    typography: typography ?? this.typography,
    theme: theme ?? this.theme,
    spine: spine ?? this.spine,
    scalar: scalar ?? this.scalar,
    unit: unit ?? this.unit,
    unitCount: unitCount ?? this.unitCount,
    layoutRevision: layoutRevision ?? this.layoutRevision,
    geometry: identical(geometry, _unset)
        ? this.geometry
        : geometry as EpubLayoutGeometry?,
    flow: identical(flow, _unset) ? this.flow : flow as ChapterFlow?,
    paginated: identical(paginated, _unset)
        ? this.paginated
        : paginated as PaginatedChapter?,
    images: images == null ? this.images : Map.unmodifiable(images),
    embeddedFamilies: embeddedFamilies == null
        ? this.embeddedFamilies
        : Map.unmodifiable(embeddedFamilies),
    relayoutBusy: relayoutBusy ?? this.relayoutBusy,
    relayoutPending: relayoutPending ?? this.relayoutPending,
    selection: identical(selection, _unset)
        ? this.selection
        : selection as EpubSelection?,
    highlights: highlights == null
        ? this.highlights
        : List.unmodifiable(highlights),
    contentsOpen: contentsOpen ?? this.contentsOpen,
    contentsSpine: identical(contentsSpine, _unset)
        ? this.contentsSpine
        : contentsSpine as int?,
    notice: identical(notice, _unset) ? this.notice : notice as String?,
    warnings: warnings == null ? this.warnings : List.unmodifiable(warnings),
    progress: progress ?? this.progress,
    continuousOffset: continuousOffset ?? this.continuousOffset,
    firstContentMicros: identical(firstContentMicros, _unset)
        ? this.firstContentMicros
        : firstContentMicros as int?,
    lastLayoutMicros: identical(lastLayoutMicros, _unset)
        ? this.lastLayoutMicros
        : lastLayoutMicros as int?,
  );
}

const Object _unset = Object();
