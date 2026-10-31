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
enum ReaderPanel { contents, typography, notes }

/// A place a jump left from, which Back returns to: a unit and where in its
/// text, in this book or, when the point names a book, in the book being read
/// when a note or search hit opened this one.
typedef ReaderReturnPoint = ({int unit, int? offset, FlutterLibraryBook? book});

/// Which notes the Notes panel lists: this book's, or every book's.
enum ReaderNotesScope { thisBook, allBooks }

/// Which ordinal the reader status text names (RD-05).
///
/// `page` is supplied for paginated EPUB/PDF page ordinals and `chapter`
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
  placeNote,
  associationPicker,
  documentPicker,
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
    this.marks = const [],
  });

  final ReaderProgressKind kind;

  /// Whether a document is loaded; the bar is hidden without one.
  final bool hasDocument;
  final ReaderDisplayUnit displayUnit;
  final int? firstOrdinal;
  final int? lastOrdinal;

  /// Whole-percent progress, 0–100.
  final int percentage;

  /// Bookmark ticks in the same book-wide coordinate as the progress track.
  final List<double> marks;

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
      other.percentage == percentage &&
      listEquals(other.marks, marks);

  @override
  int get hashCode => Object.hash(
    kind,
    hasDocument,
    displayUnit,
    firstOrdinal,
    lastOrdinal,
    percentage,
    Object.hashAll(marks),
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

/// Typed raster fit for PDF (RD-09).
///
/// The persisted preference codec that replaces the legacy `pdfZoom` sentinel
/// is 5A/6B work; 4C presents and applies the value locally.
enum ReaderRasterFit { fitPage, fitWidth, manual }

/// Mode-specific typography presentation (RD-09).
///
/// Availability is derived from [format] and [continuous], never from a
/// widget-local boolean: a reflowable (EPUB) document shows font size, line
/// spacing and the theme cycle; a raster (PDF) document shows zoom and the
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
    this.twoPages = true,
    this.animations = true,
    this.progress = FlutterReaderProgress.page,
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

  /// The Pages setting: two pages side by side where the stage has room for
  /// them (the default), or always one. Phones and narrow stages show one page
  /// either way.
  final bool twoPages;

  /// Animate page turns without affecting document layout.
  final bool animations;
  final FlutterReaderProgress progress;

  /// Whether the document is reflowable (EPUB), so the EPUB controls apply.
  bool get reflowable => format == FlutterBookFormat.epub;

  /// Whether the document is searchable. Every supported format (EPUB and
  /// PDF) is; the retired CBZ format was the one that had no text.
  bool get searchable => switch (format) {
    FlutterBookFormat.pdf || FlutterBookFormat.epub => true,
  };

  ReaderTypographyPresentation copyWith({
    FlutterBookFormat? format,
    bool? continuous,
    String? theme,
    double? epubFontSize,
    double? epubLineSpacing,
    ReaderRasterFit? rasterFit,
    double? rasterZoom,
    bool? twoPages,
    bool? animations,
    FlutterReaderProgress? progress,
  }) => ReaderTypographyPresentation(
    format: format ?? this.format,
    continuous: continuous ?? this.continuous,
    theme: theme ?? this.theme,
    epubFontSize: epubFontSize ?? this.epubFontSize,
    epubLineSpacing: epubLineSpacing ?? this.epubLineSpacing,
    rasterFit: rasterFit ?? this.rasterFit,
    rasterZoom: rasterZoom ?? this.rasterZoom,
    twoPages: twoPages ?? this.twoPages,
    animations: animations ?? this.animations,
    progress: progress ?? this.progress,
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
      other.rasterZoom == rasterZoom &&
      other.twoPages == twoPages &&
      other.animations == animations &&
      other.progress == progress;

  @override
  int get hashCode => Object.hash(
    format,
    continuous,
    theme,
    epubFontSize,
    epubLineSpacing,
    rasterFit,
    rasterZoom,
    twoPages,
    animations,
    progress,
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
    this.spread = false,
  });

  final double scale;
  final double width;
  final double fontSize;
  final double lineSpacing;

  /// Whether the view shows two pages side by side in [width]; the view
  /// decides from the Pages setting and the room on the stage.
  final bool spread;

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
      lineSpacing == other.lineSpacing &&
      spread == other.spread;

  @override
  int get hashCode => Object.hash(scale, width, fontSize, lineSpacing, spread);
}

/// A note being edited in place on its Notes panel card.
final class ReaderNoteEdit {
  const ReaderNoteEdit(this.card, this.text);

  /// The card's key prefix: `reader-annotation-<id>` or
  /// `reader-place-note-<id>`.
  final String card;

  /// The draft.
  final String text;
}

/// A reference's destination and bounded preview, without changing the page.
final class ReaderReferencePeek {
  const ReaderReferencePeek({
    required this.unit,
    required this.offset,
    required this.label,
    required this.preview,
    this.source,
  });

  final int unit;
  final int? offset;
  final String label;
  final String preview;

  /// A tapped PDF page can be the facing page, not the active spread's first.
  final ReaderReturnPoint? source;
}

final class ReaderModel {
  ReaderModel({
    this.openPath,
    this.openBookId,
    this.document,
    this.referencePeek,
    this.turnPreview,
    this.unit = 0,
    this.readingOffset,
    this.pageImage,
    this.epubPage,
    this.pdfSpread,
    this.pdfRightToLeft = false,
    this.readingPage,
    this.locationRequestRevision = 0,
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
    List<FlutterNote> notes = const [],
    List<ReaderReturnPoint> returnPoints = const [],
    this.notesScope = ReaderNotesScope.thisBook,
    this.libraryNotes = const ShellNotesModel(),
    Set<String> annotationOperations = const {},
    this.selectionError,
    this.relayoutError,
    this.layoutRefusal,
    this.selectionActionError,
    this.annotationError,
    this.annotationsReady = false,
    this.searchBusy = false,
    this.bookmarkBusy = false,
    this.notesBusy = false,
    this.noteEdit,
    this.toolError,
    this.persistenceError,
    this.openPanel,
    this.searchOpen = false,
    this.chromeVisible = false,
    this.pointerChrome = false,
    this.chromeHovered = false,
    this.zonesHintDismissed = false,
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
       notes = List.unmodifiable(notes),
       returnPoints = List.unmodifiable(returnPoints),
       annotationOperations = Set.unmodifiable(annotationOperations);

  final String? openPath;
  final int? openBookId;
  final FlutterDocumentSummary? document;
  final ReaderTurnPreview? turnPreview;
  final int unit;

  /// Durable document location. Selection endpoints are intentionally separate.
  final int? readingOffset;
  final ui.Image? pageImage;

  /// The Dart-engine page window currently rendered, or null when the page is
  /// the retained renderer's raster.
  final ReaderEpubPage? epubPage;

  /// The second page shown beside [unit] when a PDF is read in spreads, or
  /// null for one page. [selectionSurface] and [pageImage] then span both.
  final ReaderPdfSpread? pdfSpread;

  /// Whether the open PDF reads right to left (its viewer preferences say
  /// `/Direction /R2L`).
  final bool pdfRightToLeft;

  /// Whether pages turn leftward: the next page is behind the left margin,
  /// and a spread's first page is on the right.
  bool get rightToLeft => epubPage?.rightToLeft ?? pdfRightToLeft;

  /// The page being read when a PDF is read in spreads: [unit] or the
  /// spread's second page. A place on the second page may have no offset (a
  /// bookmark made with the page shown alone, say), so the page is kept apart
  /// from [readingOffset]. Null when the PDF is not read in spreads.
  final int? readingPage;

  /// The durable reading location: the page being read and an offset in that
  /// page's own text.
  ///
  /// [unit] and [readingOffset] address what the reader shows; on a PDF
  /// spread that is the spread's first page, and an offset on its second page
  /// lies past the first page's text. Bookmarks, saved positions and a layout
  /// that shows the page alone use this location instead.
  ({int unit, int? offset}) get readingLocation {
    final spread = pdfSpread;
    final offset = readingOffset;
    final page = readingPage ?? unit;
    if (spread == null || offset == null) return (unit: page, offset: offset);
    return (unit: page, offset: spread.pageOffset(offset));
  }

  /// Revision of the latest explicit location request [epubPage] answers.
  ///
  /// Advances whenever a page is installed for a navigation (a chapter change,
  /// an offset target, a replaced position) and never for a passive relayout
  /// (a resize or a height refresh), so a continuous view scrolls to
  /// [ReaderEpubPage.targetScalar] once per request — including a repeated
  /// request for the same location, or for the chapter start.
  final int locationRequestRevision;

  /// Whether the document area presents a continuous page the view scrolls.
  ///
  /// Follows the installed EPUB page, so a page laid out for the paginated
  /// reader is never presented as a continuous one.
  bool get continuousPresentation =>
      typography.continuous && (epubPage?.continuous ?? true);
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

  /// The book's notes: its book notes, then its page notes in reading order.
  final List<FlutterNote> notes;

  /// Where each jump left from, the latest last: Back returns to the last.
  final List<ReaderReturnPoint> returnPoints;
  final ReaderReferencePeek? referencePeek;

  /// Which notes the Notes panel lists.
  final ReaderNotesScope notesScope;

  /// Every book's notes, listed while the Notes panel shows All books.
  final ShellNotesModel libraryNotes;
  final Set<String> annotationOperations;
  final String? selectionError;

  /// A failed page layout, kept apart from [selectionError].
  ///
  /// The retained reader wrote layout failures into `selectionError`, so the
  /// shared error surface labelled them "Selection unavailable"; a layout
  /// failure is not a selection problem and now has its own value.
  final String? relayoutError;

  /// The typed refusal of the last chapter the reader asked to lay out, when
  /// one of its indivisible blocks exceeds a bounded-work ceiling.
  ///
  /// Kept apart from [relayoutError]: a refusal is not transient, so a passive
  /// relayout of the page still shown (a resize, the alert's own height) keeps
  /// it, and only a new location request or document clears it.
  final EpubLayoutLimitExceeded? layoutRefusal;
  final String? selectionActionError;
  final String? annotationError;
  final bool annotationsReady;
  final bool searchBusy;
  final bool bookmarkBusy;

  /// Whether a page note or book note is being edited or saved.
  final bool notesBusy;

  /// The note being edited in place, kept while the reader is busy so a
  /// relayout or another note's save leaves the draft alone.
  final ReaderNoteEdit? noteEdit;
  final String? toolError;

  /// Reading-position restoration/save feedback, independent of tool chrome.
  final String? persistenceError;

  /// The single open panel, if any; at most one is open (RD-13).
  final ReaderPanel? openPanel;

  /// Whether the search bar is open. Search is independent of [openPanel].
  final bool searchOpen;

  final bool chromeVisible;
  final bool pointerChrome;
  final bool chromeHovered;
  final bool zonesHintDismissed;

  bool get chromePinned =>
      openPanel != null ||
      searchOpen ||
      modalEffect != null ||
      referencePeek != null;

  bool get chromeShown => document == null || chromeVisible || chromePinned;

  // A selection menu preserves existing chrome without revealing hidden chrome
  // during keyboard-only selection.
  bool get chromeIdleInhibited =>
      chromePinned || selectionPhase == ReaderSelectionPhase.selected;

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
    Object? referencePeek = _unchanged,
    Object? turnPreview = _unchanged,
    int? unit,
    Object? readingOffset = _unchanged,
    Object? pageImage = _unchanged,
    Object? epubPage = _unchanged,
    Object? pdfSpread = _unchanged,
    bool? pdfRightToLeft,
    Object? readingPage = _unchanged,
    int? locationRequestRevision,
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
    List<FlutterNote>? notes,
    List<ReaderReturnPoint>? returnPoints,
    ReaderNotesScope? notesScope,
    ShellNotesModel? libraryNotes,
    Set<String>? annotationOperations,
    Object? selectionError = _unchanged,
    Object? relayoutError = _unchanged,
    Object? layoutRefusal = _unchanged,
    Object? selectionActionError = _unchanged,
    Object? annotationError = _unchanged,
    bool? annotationsReady,
    bool? searchBusy,
    bool? bookmarkBusy,
    bool? notesBusy,
    Object? noteEdit = _unchanged,
    Object? toolError = _unchanged,
    Object? persistenceError = _unchanged,
    Object? openPanel = _unchanged,
    bool? searchOpen,
    bool? chromeVisible,
    bool? pointerChrome,
    bool? chromeHovered,
    bool? zonesHintDismissed,
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
      turnPreview: identical(turnPreview, _unchanged)
          ? this.turnPreview
          : turnPreview as ReaderTurnPreview?,
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
      pdfSpread: identical(pdfSpread, _unchanged)
          ? this.pdfSpread
          : pdfSpread as ReaderPdfSpread?,
      pdfRightToLeft: pdfRightToLeft ?? this.pdfRightToLeft,
      readingPage: identical(readingPage, _unchanged)
          ? this.readingPage
          : readingPage as int?,
      locationRequestRevision:
          locationRequestRevision ?? this.locationRequestRevision,
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
      notes: notes ?? this.notes,
      returnPoints: returnPoints ?? this.returnPoints,
      referencePeek: identical(referencePeek, _unchanged)
          ? this.referencePeek
          : referencePeek as ReaderReferencePeek?,
      notesScope: notesScope ?? this.notesScope,
      libraryNotes: libraryNotes ?? this.libraryNotes,
      annotationOperations: annotationOperations == null
          ? this.annotationOperations
          : Set.unmodifiable(annotationOperations),
      selectionError: identical(selectionError, _unchanged)
          ? this.selectionError
          : selectionError as String?,
      relayoutError: identical(relayoutError, _unchanged)
          ? this.relayoutError
          : relayoutError as String?,
      layoutRefusal: identical(layoutRefusal, _unchanged)
          ? this.layoutRefusal
          : layoutRefusal as EpubLayoutLimitExceeded?,
      selectionActionError: identical(selectionActionError, _unchanged)
          ? this.selectionActionError
          : selectionActionError as String?,
      annotationError: identical(annotationError, _unchanged)
          ? this.annotationError
          : annotationError as String?,
      annotationsReady: annotationsReady ?? this.annotationsReady,
      searchBusy: searchBusy ?? this.searchBusy,
      bookmarkBusy: bookmarkBusy ?? this.bookmarkBusy,
      notesBusy: notesBusy ?? this.notesBusy,
      noteEdit: identical(noteEdit, _unchanged)
          ? this.noteEdit
          : noteEdit as ReaderNoteEdit?,
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
      chromeVisible: chromeVisible ?? this.chromeVisible,
      pointerChrome: pointerChrome ?? this.pointerChrome,
      chromeHovered: chromeHovered ?? this.chromeHovered,
      zonesHintDismissed: zonesHintDismissed ?? this.zonesHintDismissed,
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
/// `header` focuses the toolbar action that opened the panel being closed and
/// `panel` the open panel container; the widget resolves both from its own
/// focus nodes when the controller asks, and never moves focus on its own.
enum ReaderFocusTarget { surface, actions, header, panel }

enum _ReaderNoteTarget { selection, annotation, place }

/// Where a new page note or book note editor writes: at [unit] and [offset],
/// or on the whole book when [unit] is null.
final class _PlaceNoteTarget {
  const _PlaceNoteTarget({required this.kind, this.unit, this.offset});
  final FlutterNoteKind kind;
  final int? unit;
  final int? offset;
}

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
