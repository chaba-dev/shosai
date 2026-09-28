part of 'controller.dart';

final class AnnotationAssociationPage {
  AnnotationAssociationPage({
    required List<FlutterAnnotationAssociationSource> sources,
    required this.canGoBack,
    required this.canGoForward,
  }) : sources = List.unmodifiable(sources);

  final List<FlutterAnnotationAssociationSource> sources;
  final bool canGoBack;
  final bool canGoForward;
}

sealed class AnnotationAssociationChoice {
  const AnnotationAssociationChoice();
}

final class AnnotationAssociationSelected extends AnnotationAssociationChoice {
  const AnnotationAssociationSelected(this.source);
  final FlutterAnnotationAssociationSource source;
}

final class AnnotationAssociationNextPage extends AnnotationAssociationChoice {
  const AnnotationAssociationNextPage();
}

final class AnnotationAssociationPreviousPage
    extends AnnotationAssociationChoice {
  const AnnotationAssociationPreviousPage();
}

final class AnnotationAssociationCancelled extends AnnotationAssociationChoice {
  const AnnotationAssociationCancelled();
}

/// The three reader panels that are mutually exclusive (RD-13).
///
/// Search is deliberately not a member: it is an independent bar (RD-11).
enum ReaderPanel { contents, typography, more }

/// Which ordinal the reader status text names (RD-05).
///
/// `page` is supplied for paginated EPUB/PDF/CBZ page ordinals and `chapter`
/// only for the EPUB logical-unit fallback; the widget never derives this from
/// the document format.
enum ReaderDisplayUnit { chapter, page }

/// The status-wording state of the reader progress bar (RD-05).
///
/// `none` means no document is loaded and `loading` that an open is in flight;
/// `single` and `range` carry supplied presentation ordinals.
enum ReaderProgressKind { none, loading, single, range }

/// The one controller-owned modal effect currently active, if any.
///
/// Controls that would start another modal are disabled while this is set.
/// `documentPicker` is the more panel's open-book picker (RD-10).
enum ReaderModalEffect {
  selectionNote,
  annotationNote,
  bookmarkNote,
  associationPicker,
  documentPicker,
}

/// One tab strip entry (RD-03, RD-04).
///
/// Fixture-injected in 4B: the bridge has no session or tab API, and the real
/// tab identity and lifecycle are 5F work.
final class ReaderTabPresentation {
  const ReaderTabPresentation({
    required this.id,
    required this.title,
    this.selected = false,
  });

  final String id;
  final String title;
  final bool selected;

  ReaderTabPresentation copyWith({String? title, bool? selected}) =>
      ReaderTabPresentation(
        id: id,
        title: title ?? this.title,
        selected: selected ?? this.selected,
      );

  @override
  bool operator ==(Object other) =>
      other is ReaderTabPresentation &&
      other.id == id &&
      other.title == title &&
      other.selected == selected;

  @override
  int get hashCode => Object.hash(id, title, selected);
}

/// The progress bar and status wording inputs (RD-05).
///
/// Ordinals are 1-based presentation data supplied by the fixture in 4B and by
/// the renderer in 5G. They are never durable addresses and never double as a
/// page total.
final class ReaderProgressPresentation {
  const ReaderProgressPresentation({
    required this.kind,
    this.hasDocument = false,
    this.displayUnit = ReaderDisplayUnit.page,
    this.firstOrdinal,
    this.lastOrdinal,
    this.percentage = 0,
  });

  final ReaderProgressKind kind;

  /// Whether a document is loaded; the bar is hidden without one.
  final bool hasDocument;
  final ReaderDisplayUnit displayUnit;
  final int? firstOrdinal;
  final int? lastOrdinal;

  /// Whole-percent progress, 0–100.
  final int percentage;

  bool get showsRange =>
      kind == ReaderProgressKind.range &&
      firstOrdinal != null &&
      lastOrdinal != null;

  @override
  bool operator ==(Object other) =>
      other is ReaderProgressPresentation &&
      other.kind == kind &&
      other.hasDocument == hasDocument &&
      other.displayUnit == displayUnit &&
      other.firstOrdinal == firstOrdinal &&
      other.lastOrdinal == lastOrdinal &&
      other.percentage == percentage;

  @override
  int get hashCode => Object.hash(
    kind,
    hasDocument,
    displayUnit,
    firstOrdinal,
    lastOrdinal,
    percentage,
  );
}

/// The Contents panel load state (RD-07).
///
/// `loading` is the panel-opened-before-entries state, `empty` a document
/// without chapters, `failed` carries the error payload and a retry.
enum ReaderContentsStatus { loading, ready, empty, failed }

/// One Contents row (RD-07).
///
/// Entries are fixture-provided in 4C: the bridge exposes no TOC DTO, so the
/// production loader renders the EPUB chapter fallback. [title] is empty when
/// the row has no authored title and the panel renders the localized chapter
/// number for [unit] (the pinned Iced fallback, `app.rs:6062-6071`).
final class ReaderContentsEntry {
  const ReaderContentsEntry({
    this.depth = 0,
    this.title = '',
    required this.unit,
    this.offset,
    this.current = false,
  });

  /// Nesting depth; the panel indents 12 logical px per level (RD-07).
  final int depth;
  final String title;
  final int unit;
  final int? offset;

  /// Whether this row is the reader's current location.
  final bool current;

  ReaderContentsEntry copyWith({bool? current}) => ReaderContentsEntry(
    depth: depth,
    title: title,
    unit: unit,
    offset: offset,
    current: current ?? this.current,
  );

  @override
  bool operator ==(Object other) =>
      other is ReaderContentsEntry &&
      other.depth == depth &&
      other.title == title &&
      other.unit == unit &&
      other.offset == offset &&
      other.current == current;

  @override
  int get hashCode => Object.hash(depth, title, unit, offset, current);
}

/// The Contents panel state (RD-07, 4C acceptance).
final class ReaderContentsPresentation {
  const ReaderContentsPresentation({
    required this.status,
    this.entries = const [],
    this.error,
  });

  final ReaderContentsStatus status;
  final List<ReaderContentsEntry> entries;
  final String? error;

  @override
  bool operator ==(Object other) =>
      other is ReaderContentsPresentation &&
      other.status == status &&
      _listEquals(other.entries, entries) &&
      other.error == error;

  @override
  int get hashCode => Object.hash(status, Object.hashAll(entries), error);
}

/// The more panel's page-input draft and inline validation (RD-10).
final class ReaderPageInputPresentation {
  const ReaderPageInputPresentation({this.draft = '', this.error});

  final String draft;

  /// The controller's diagnostic for a rejected submission. The panel renders
  /// its own localized invalid-input message; this value keeps the rejection
  /// observable for tests and diagnostics.
  final String? error;

  @override
  bool operator ==(Object other) =>
      other is ReaderPageInputPresentation &&
      other.draft == draft &&
      other.error == error;

  @override
  int get hashCode => Object.hash(draft, error);
}

/// Typed raster fit for PDF/CBZ (RD-09).
///
/// The persisted preference codec that replaces the legacy `pdfZoom` sentinel
/// is 5A/6B work; 4C presents and applies the value locally.
enum ReaderRasterFit { fitPage, fitWidth, manual }

/// Mode-specific typography presentation (RD-09).
///
/// Availability is derived from [format] and [continuous], never from a
/// widget-local boolean: a reflowable (EPUB) document shows font size, line
/// spacing and the theme cycle; a raster (PDF/CBZ) document shows zoom and the
/// fit controls.
final class ReaderTypographyPresentation {
  const ReaderTypographyPresentation({
    required this.format,
    required this.continuous,
    required this.theme,
    required this.epubFontSize,
    required this.epubLineSpacing,
    required this.rasterFit,
    required this.rasterZoom,
  });

  final FlutterBookFormat format;
  final bool continuous;
  final String theme;
  final double epubFontSize;
  final double epubLineSpacing;
  final ReaderRasterFit rasterFit;

  /// The effective raster scale: the manual zoom for [ReaderRasterFit.manual]
  /// and the reader's base density for the fit modes. Applying a real fit-page
  /// or fit-width computation from page geometry is 5A/6B.
  final double rasterZoom;

  /// Whether the document is reflowable (EPUB), so the EPUB controls apply.
  bool get reflowable => format == FlutterBookFormat.epub;

  /// Whether the document is searchable (Iced: EPUB and PDF, not CBZ).
  bool get searchable => format != FlutterBookFormat.cbz;

  ReaderTypographyPresentation copyWith({
    FlutterBookFormat? format,
    bool? continuous,
    String? theme,
    double? epubFontSize,
    double? epubLineSpacing,
    ReaderRasterFit? rasterFit,
    double? rasterZoom,
  }) => ReaderTypographyPresentation(
    format: format ?? this.format,
    continuous: continuous ?? this.continuous,
    theme: theme ?? this.theme,
    epubFontSize: epubFontSize ?? this.epubFontSize,
    epubLineSpacing: epubLineSpacing ?? this.epubLineSpacing,
    rasterFit: rasterFit ?? this.rasterFit,
    rasterZoom: rasterZoom ?? this.rasterZoom,
  );

  @override
  bool operator ==(Object other) =>
      other is ReaderTypographyPresentation &&
      other.format == format &&
      other.continuous == continuous &&
      other.theme == theme &&
      other.epubFontSize == epubFontSize &&
      other.epubLineSpacing == epubLineSpacing &&
      other.rasterFit == rasterFit &&
      other.rasterZoom == rasterZoom;

  @override
  int get hashCode => Object.hash(
    format,
    continuous,
    theme,
    epubFontSize,
    epubLineSpacing,
    rasterFit,
    rasterZoom,
  );
}

/// Markdown export feedback (RD-08).
enum ReaderExportState { idle, busy, failed }

/// The search bar state (RD-11).
///
/// `query.isEmpty` distinguishes idle from no matches; [currentIndex] is the
/// 0-based index into [results] that the previous/next controls step through.
final class ReaderSearchPresentation {
  const ReaderSearchPresentation({
    this.query = '',
    this.busy = false,
    this.results = const [],
    this.currentIndex = 0,
    this.error,
  });

  final String query;
  final bool busy;
  final List<FlutterSearchMatch> results;
  final int currentIndex;
  final String? error;

  bool get hasQuery => query.isNotEmpty;
  bool get hasResults => results.isNotEmpty;

  @override
  bool operator ==(Object other) =>
      other is ReaderSearchPresentation &&
      other.query == query &&
      other.busy == busy &&
      _listEquals(other.results, results) &&
      other.currentIndex == currentIndex &&
      other.error == error;

  @override
  int get hashCode =>
      Object.hash(query, busy, Object.hashAll(results), currentIndex, error);
}

bool _listEquals<T>(List<T> first, List<T> second) {
  if (identical(first, second)) return true;
  if (first.length != second.length) return false;
  for (var index = 0; index < first.length; index += 1) {
    if (first[index] != second[index]) return false;
  }
  return true;
}

final class ReaderLayout {
  const ReaderLayout({
    this.scale = 1,
    this.width = 680,
    this.fontSize = 18,
    this.lineSpacing = 1.5,
  });

  final double scale;
  final double width;
  final double fontSize;
  final double lineSpacing;

  bool get isValid =>
      scale.isFinite &&
      scale > 0 &&
      width.isFinite &&
      width > 0 &&
      fontSize.isFinite &&
      fontSize > 0 &&
      lineSpacing.isFinite &&
      lineSpacing >= 1 &&
      lineSpacing <= 3;

  @override
  bool operator ==(Object other) =>
      other is ReaderLayout &&
      scale == other.scale &&
      width == other.width &&
      fontSize == other.fontSize &&
      lineSpacing == other.lineSpacing;

  @override
  int get hashCode => Object.hash(scale, width, fontSize, lineSpacing);
}

final class ReaderModel {
  ReaderModel({
    this.openPath,
    this.openBookId,
    this.document,
    this.unit = 0,
    this.readingOffset,
    this.pageImage,
    this.epubPage,
    FlutterSelectionSurface? selectionSurface,
    this.selectionPhase = ReaderSelectionPhase.idle,
    this.anchor,
    this.focus,
    this.selectionPointer,
    this.selectionVisualLine,
    this.selectionPreferredX,
    this.keyboardActionInvocation = false,
    List<ReaderSelection> savedSelections = const [],
    List<FlutterAnnotation> annotations = const [],
    List<FlutterSearchMatch> searchResults = const [],
    List<FlutterBookmark> bookmarks = const [],
    Set<String> annotationOperations = const {},
    this.selectionError,
    this.relayoutError,
    this.selectionActionError,
    this.annotationError,
    this.annotationsReady = false,
    this.searchBusy = false,
    this.bookmarkBusy = false,
    this.toolError,
    this.persistenceError,
    this.openPanel,
    this.searchOpen = false,
    List<ReaderTabPresentation> tabs = const [],
    this.progress = const ReaderProgressPresentation(
      kind: ReaderProgressKind.none,
    ),
    this.contents = const ReaderContentsPresentation(
      status: ReaderContentsStatus.loading,
    ),
    this.pageInput = const ReaderPageInputPresentation(),
    this.typography = const ReaderTypographyPresentation(
      format: FlutterBookFormat.epub,
      continuous: false,
      theme: 'light',
      epubFontSize: 18,
      epubLineSpacing: 1.5,
      rasterFit: ReaderRasterFit.fitPage,
      rasterZoom: 1,
    ),
    this.exportState = ReaderExportState.idle,
    this.exportError,
    this.search = const ReaderSearchPresentation(),
    this.modalEffect,
    this.layout = const ReaderLayout(),
    this.relayoutBusy = false,
    this.relayoutPending = false,
    this.contentState = ReaderContentState.loading,
    this.error,
    this.busy = false,
    this.generation = 0,
  }) : selectionSurface = selectionSurface == null
           ? null
           : _freezeSurface(selectionSurface),
       savedSelections = List.unmodifiable(savedSelections),
       annotations = List.unmodifiable(annotations.map(_freezeAnnotation)),
       searchResults = List.unmodifiable(searchResults),
       bookmarks = List.unmodifiable(bookmarks),
       tabs = List.unmodifiable(tabs),
       annotationOperations = Set.unmodifiable(annotationOperations);

  final String? openPath;
  final int? openBookId;
  final FlutterDocumentSummary? document;
  final int unit;

  /// Durable document location. Selection endpoints are intentionally separate.
  final int? readingOffset;
  final ui.Image? pageImage;

  /// The Dart-engine page window currently rendered, or null when the page is
  /// the retained renderer's raster.
  final ReaderEpubPage? epubPage;
  final FlutterSelectionSurface? selectionSurface;
  final ReaderSelectionPhase selectionPhase;
  final int? anchor;
  final int? focus;
  final int? selectionPointer;
  final int? selectionVisualLine;
  final double? selectionPreferredX;
  final bool keyboardActionInvocation;
  final List<ReaderSelection> savedSelections;
  final List<FlutterAnnotation> annotations;
  final List<FlutterSearchMatch> searchResults;
  final List<FlutterBookmark> bookmarks;
  final Set<String> annotationOperations;
  final String? selectionError;

  /// A failed page layout, kept apart from [selectionError].
  ///
  /// The retained reader wrote layout failures into `selectionError`, so the
  /// shared error surface labelled them "Selection unavailable"; a layout
  /// failure is not a selection problem and now has its own value.
  final String? relayoutError;
  final String? selectionActionError;
  final String? annotationError;
  final bool annotationsReady;
  final bool searchBusy;
  final bool bookmarkBusy;
  final String? toolError;

  /// Reading-position restoration/save feedback, independent of tool chrome.
  final String? persistenceError;

  /// The single open panel, if any; at most one is open (RD-13).
  final ReaderPanel? openPanel;

  /// Whether the search bar is open. Search is independent of [openPanel].
  final bool searchOpen;

  /// Ordered tab strip entries; empty hides the strip.
  final List<ReaderTabPresentation> tabs;

  /// Progress bar and status wording inputs (RD-05).
  final ReaderProgressPresentation progress;

  /// The Contents panel state (RD-07).
  final ReaderContentsPresentation contents;

  /// The more panel's page-input draft and inline validation (RD-10).
  final ReaderPageInputPresentation pageInput;

  /// Mode-specific typography presentation (RD-09).
  final ReaderTypographyPresentation typography;

  /// Markdown export feedback (RD-08).
  final ReaderExportState exportState;
  final String? exportError;

  /// The search bar state (RD-11).
  final ReaderSearchPresentation search;

  /// The one controller-owned modal effect currently active, if any.
  final ReaderModalEffect? modalEffect;

  final ReaderLayout layout;
  final bool relayoutBusy;
  final bool relayoutPending;
  final ReaderContentState contentState;
  final String? error;
  final bool busy;
  final int generation;

  String? get selectedText {
    final surface = selectionSurface;
    final first = anchor;
    final second = focus;
    if (surface == null ||
        !surface.copyEligible ||
        first == null ||
        second == null ||
        first == second) {
      return null;
    }
    final start = first < second ? first : second;
    final end = first < second ? second : first;
    final scalars = surface.text.runes.toList(growable: false);
    if (start < 0 || end > scalars.length) return null;
    return String.fromCharCodes(scalars.sublist(start, end));
  }

  String get selectionDescription {
    final selected = selectedText;
    return switch (selectionPhase) {
      ReaderSelectionPhase.idle => 'No text selected',
      ReaderSelectionPhase.selecting =>
        selected == null ? 'Selecting text' : 'Selecting text: $selected',
      ReaderSelectionPhase.selected =>
        selected == null ? 'Text selection ready' : 'Selected text: $selected',
      ReaderSelectionPhase.committing => 'Saving selected text',
    };
  }

  ReaderModel copyWith({
    Object? openPath = _unchanged,
    Object? openBookId = _unchanged,
    Object? document = _unchanged,
    int? unit,
    Object? readingOffset = _unchanged,
    Object? pageImage = _unchanged,
    Object? epubPage = _unchanged,
    Object? selectionSurface = _unchanged,
    ReaderSelectionPhase? selectionPhase,
    Object? anchor = _unchanged,
    Object? focus = _unchanged,
    Object? selectionPointer = _unchanged,
    Object? selectionVisualLine = _unchanged,
    Object? selectionPreferredX = _unchanged,
    bool? keyboardActionInvocation,
    List<ReaderSelection>? savedSelections,
    List<FlutterAnnotation>? annotations,
    List<FlutterSearchMatch>? searchResults,
    List<FlutterBookmark>? bookmarks,
    Set<String>? annotationOperations,
    Object? selectionError = _unchanged,
    Object? relayoutError = _unchanged,
    Object? selectionActionError = _unchanged,
    Object? annotationError = _unchanged,
    bool? annotationsReady,
    bool? searchBusy,
    bool? bookmarkBusy,
    Object? toolError = _unchanged,
    Object? persistenceError = _unchanged,
    Object? openPanel = _unchanged,
    bool? searchOpen,
    List<ReaderTabPresentation>? tabs,
    ReaderProgressPresentation? progress,
    ReaderContentsPresentation? contents,
    ReaderPageInputPresentation? pageInput,
    ReaderTypographyPresentation? typography,
    ReaderExportState? exportState,
    Object? exportError = _unchanged,
    ReaderSearchPresentation? search,
    Object? modalEffect = _unchanged,
    ReaderLayout? layout,
    bool? relayoutBusy,
    bool? relayoutPending,
    ReaderContentState? contentState,
    Object? error = _unchanged,
    bool? busy,
    int? generation,
  }) {
    return ReaderModel(
      openPath: identical(openPath, _unchanged)
          ? this.openPath
          : openPath as String?,
      openBookId: identical(openBookId, _unchanged)
          ? this.openBookId
          : openBookId as int?,
      document: identical(document, _unchanged)
          ? this.document
          : document as FlutterDocumentSummary?,
      unit: unit ?? this.unit,
      readingOffset: identical(readingOffset, _unchanged)
          ? this.readingOffset
          : readingOffset as int?,
      pageImage: identical(pageImage, _unchanged)
          ? this.pageImage
          : pageImage as ui.Image?,
      epubPage: identical(epubPage, _unchanged)
          ? this.epubPage
          : epubPage as ReaderEpubPage?,
      selectionSurface: identical(selectionSurface, _unchanged)
          ? this.selectionSurface
          : selectionSurface as FlutterSelectionSurface?,
      selectionPhase: selectionPhase ?? this.selectionPhase,
      anchor: identical(anchor, _unchanged) ? this.anchor : anchor as int?,
      focus: identical(focus, _unchanged) ? this.focus : focus as int?,
      selectionPointer: identical(selectionPointer, _unchanged)
          ? this.selectionPointer
          : selectionPointer as int?,
      selectionVisualLine: identical(selectionVisualLine, _unchanged)
          ? this.selectionVisualLine
          : selectionVisualLine as int?,
      selectionPreferredX: identical(selectionPreferredX, _unchanged)
          ? this.selectionPreferredX
          : selectionPreferredX as double?,
      keyboardActionInvocation:
          keyboardActionInvocation ?? this.keyboardActionInvocation,
      savedSelections: savedSelections == null
          ? this.savedSelections
          : List.unmodifiable(savedSelections),
      annotations: annotations == null
          ? this.annotations
          : List.unmodifiable(annotations),
      searchResults: searchResults ?? this.searchResults,
      bookmarks: bookmarks ?? this.bookmarks,
      annotationOperations: annotationOperations == null
          ? this.annotationOperations
          : Set.unmodifiable(annotationOperations),
      selectionError: identical(selectionError, _unchanged)
          ? this.selectionError
          : selectionError as String?,
      relayoutError: identical(relayoutError, _unchanged)
          ? this.relayoutError
          : relayoutError as String?,
      selectionActionError: identical(selectionActionError, _unchanged)
          ? this.selectionActionError
          : selectionActionError as String?,
      annotationError: identical(annotationError, _unchanged)
          ? this.annotationError
          : annotationError as String?,
      annotationsReady: annotationsReady ?? this.annotationsReady,
      searchBusy: searchBusy ?? this.searchBusy,
      bookmarkBusy: bookmarkBusy ?? this.bookmarkBusy,
      toolError: identical(toolError, _unchanged)
          ? this.toolError
          : toolError as String?,
      persistenceError: identical(persistenceError, _unchanged)
          ? this.persistenceError
          : persistenceError as String?,
      openPanel: identical(openPanel, _unchanged)
          ? this.openPanel
          : openPanel as ReaderPanel?,
      searchOpen: searchOpen ?? this.searchOpen,
      tabs: tabs == null ? this.tabs : List.unmodifiable(tabs),
      progress: progress ?? this.progress,
      contents: contents ?? this.contents,
      pageInput: pageInput ?? this.pageInput,
      typography: typography ?? this.typography,
      exportState: exportState ?? this.exportState,
      exportError: identical(exportError, _unchanged)
          ? this.exportError
          : exportError as String?,
      search: search ?? this.search,
      modalEffect: identical(modalEffect, _unchanged)
          ? this.modalEffect
          : modalEffect as ReaderModalEffect?,
      layout: layout ?? this.layout,
      relayoutBusy: relayoutBusy ?? this.relayoutBusy,
      relayoutPending: relayoutPending ?? this.relayoutPending,
      contentState: contentState ?? this.contentState,
      error: identical(error, _unchanged) ? this.error : error as String?,
      busy: busy ?? this.busy,
      generation: generation ?? this.generation,
    );
  }
}

enum ReaderSelectionPhase { idle, selecting, selected, committing }

enum ReaderContentState { loading, ready, failed }

/// Where a controller-requested focus handoff lands.
///
/// `header` focuses the header action that opened the panel being closed,
/// `panel` the open panel container and `tabStrip` the active tab's label; the
/// widget resolves all three from its own focus nodes when the controller asks,
/// and never moves focus on its own.
enum ReaderFocusTarget { surface, actions, header, panel, tabStrip }

enum _ReaderNoteTarget { selection, annotation, bookmark }

enum ReaderSelectionMovement {
  previousGrapheme,
  nextGrapheme,
  previousWord,
  nextWord,
  previousLine,
  nextLine,
  lineStart,
  lineEnd,
  visualLeft,
  visualRight,
}

final class ReaderSelection {
  const ReaderSelection(this.start, this.end, [this.color]);

  final int start;
  final int end;
  final FlutterHighlightColor? color;
}
