part of 'controller.dart';

sealed class ReaderMessage {
  const ReaderMessage();
}

/// A non-link tap in the page, measured in physical left-to-right thirds.
final class ReaderPageTapped extends ReaderMessage {
  const ReaderPageTapped(this.fraction, {required this.touch});
  final double fraction;
  final bool touch;
}

final class ReaderPointerMoved extends ReaderMessage {
  const ReaderPointerMoved();
}

final class ReaderPointerExited extends ReaderMessage {
  const ReaderPointerExited();
}

final class ReaderChromeHovered extends ReaderMessage {
  const ReaderChromeHovered(this.hovered);
  final bool hovered;
}

final class ReaderChromeDismissed extends ReaderMessage {
  const ReaderChromeDismissed();
}

final class ReaderZonesHintDismissed extends ReaderMessage {
  const ReaderZonesHintDismissed({this.persist = true});
  final bool persist;
}

final class _ReaderChromeIdle extends ReaderMessage {
  const _ReaderChromeIdle(this.generation, this.revision);
  final int generation;
  final int revision;
}

final class ReaderOpenRequested extends ReaderMessage {
  const ReaderOpenRequested(this.path, {this.bookId, this.place});

  final String path;
  final int? bookId;

  /// Where to open instead of the saved reading position: a note's place.
  final ReaderPlace? place;
}

/// A place in a book: an EPUB spine index or PDF page, and where in its text,
/// in Unicode scalars, when known; a search match also has its [length].
///
/// A highlight's or note's place names it by [annotationId]: [unit] and
/// [offset] are where it was made, and the reader resolves it in the book as
/// it opens, as it lists the book's notes.
final class ReaderPlace {
  const ReaderPlace(
    this.unit, {
    this.offset,
    this.length,
    this.annotationId,
    this.note,
    this.returnPoints,
  });

  final int unit;
  final int? offset;
  final int? length;
  final String? annotationId;

  /// Whether [annotationId] is a page note's or book note's, not a
  /// highlight's.
  final bool? note;

  /// The return points a book opened here starts with, the latest last, in
  /// place of the one back to where it was left: the way Back leads to the
  /// book it was opened from. Only a book that opens at this place takes
  /// them.
  final List<ReaderReturnPoint>? returnPoints;

  @override
  bool operator ==(Object other) =>
      other is ReaderPlace &&
      other.unit == unit &&
      other.offset == offset &&
      other.length == length &&
      other.annotationId == annotationId &&
      other.note == note &&
      listEquals(other.returnPoints, returnPoints);

  @override
  int get hashCode => Object.hash(
    unit,
    offset,
    length,
    annotationId,
    note,
    returnPoints == null ? null : Object.hashAll(returnPoints!),
  );
}

/// Returns to where the last jump left from (the BackPill, Alt+← or ⌘[).
final class ReaderReturnRequested extends ReaderMessage {
  const ReaderReturnRequested();
}

/// Closes the BackPill, forgetting every return point.
final class ReaderReturnDismissed extends ReaderMessage {
  const ReaderReturnDismissed();
}

/// Goes to [place] in the open document, as a note or search hit chosen
/// outside the reader asks; ignored while the reader is busy.
final class ReaderPlaceRequested extends ReaderMessage {
  const ReaderPlaceRequested(this.place);

  final ReaderPlace place;
}

final class ReaderLayoutChanged extends ReaderMessage {
  const ReaderLayoutChanged(this.layout);

  final ReaderLayout layout;
}

final class ReaderViewportChanged extends ReaderMessage {
  const ReaderViewportChanged(
    this.layout, {
    this.height,
    this.devicePixelRatio,
  });

  final ReaderLayout layout;

  /// The reported content-box height, when the reporter could measure it.
  ///
  /// EPUB pagination needs a page height: an EPUB document waits for its first
  /// reported height instead of paginating for a guessed box.
  final double? height;

  /// The display's pixel ratio, when the reporter knows it.
  ///
  /// A PDF page in a fit mode renders at its fitted size in device pixels, so
  /// moving the window to a display with another ratio renders it again.
  final double? devicePixelRatio;
}

/// Steps the reader's page by [delta] (±1) (RD-06 edge navigation).
///
/// In an EPUB this turns a page inside the chapter and only crosses into the
/// neighbouring chapter at a chapter edge. A PDF keeps the logical-unit
/// semantics of [ReaderUnitRequested].
final class ReaderPageStepRequested extends ReaderMessage {
  const ReaderPageStepRequested(this.delta);
  final int delta;
}

final class ReaderUnitRequested extends ReaderMessage {
  const ReaderUnitRequested(
    this.unit, {
    this.offset,
    this.length,
    this.turn = false,
  });

  final int unit;
  final int? offset;
  final int? length;

  /// Whether this is a page turn (a PDF's), not a jump to [unit].
  final bool turn;
}

final class ReaderSearchRequested extends ReaderMessage {
  const ReaderSearchRequested(this.query);
  final String query;
}

/// Jumps along the book-wide progress track, not the chapter ordinal list.
final class ReaderProgressRequested extends ReaderMessage {
  const ReaderProgressRequested(this.fraction);
  final double fraction;
}

final class ReaderBookmarkToggled extends ReaderMessage {
  const ReaderBookmarkToggled();
}

final class ReaderBookmarkDeleted extends ReaderMessage {
  const ReaderBookmarkDeleted(this.id);
  final int id;
}

final class ReaderBookmarkNavigated extends ReaderMessage {
  const ReaderBookmarkNavigated(this.unit, {this.offset});
  final int unit;
  final int? offset;
}

/// Writes a new page note at the place being read.
final class ReaderPageNoteRequested extends ReaderMessage {
  const ReaderPageNoteRequested();
}

/// Writes the book's note, or edits it when the book has one.
final class ReaderBookNoteRequested extends ReaderMessage {
  const ReaderBookNoteRequested();
}

/// Saves the body a page note or book note was edited to in place.
final class ReaderNoteSaved extends ReaderMessage {
  const ReaderNoteSaved(this.id, this.body);
  final String id;
  final String body;
}

/// Starts editing note card [card]'s note in place, from [text]. Another
/// card's edit is dropped.
final class ReaderNoteEditStarted extends ReaderMessage {
  const ReaderNoteEditStarted(this.card, this.text);
  final String card;
  final String text;
}

/// The note being edited in place now reads [text].
final class ReaderNoteDraftChanged extends ReaderMessage {
  const ReaderNoteDraftChanged(this.text);
  final String text;
}

/// Drops the note being edited in place.
final class ReaderNoteEditCancelled extends ReaderMessage {
  const ReaderNoteEditCancelled();
}

/// Deletes a page note or book note.
final class ReaderNoteDeleted extends ReaderMessage {
  const ReaderNoteDeleted(this.id);
  final String id;
}

/// Goes to the place a page note is written at.
final class ReaderNoteNavigated extends ReaderMessage {
  const ReaderNoteNavigated(this.unit, {this.offset});
  final int unit;
  final int? offset;
}

/// Lists this book's notes or every book's in the Notes panel.
final class ReaderNotesScopeChanged extends ReaderMessage {
  const ReaderNotesScopeChanged(this.scope);
  final ReaderNotesScope scope;
}

/// Lists the next page of books in the Notes panel's All books, or retries
/// the list or the page that failed.
final class ReaderLibraryNotesMoreRequested extends ReaderMessage {
  const ReaderLibraryNotesMoreRequested();
}

/// Opens a note from All books at its place: in this book the reader goes
/// there, and another book is opened there.
final class ReaderLibraryNoteOpened extends ReaderMessage {
  const ReaderLibraryNoteOpened(this.book, this.note);
  final FlutterLibraryBook book;
  final FlutterNoteEntry note;
}

/// Toggles one of the three mutually exclusive reader panels (RD-13).
///
/// Toggling the open panel closes it; opening a panel closes the other two.
final class ReaderPanelToggled extends ReaderMessage {
  const ReaderPanelToggled(this.panel);
  final ReaderPanel panel;
}

/// Opens or closes the search bar (RD-11).
///
/// Search is independent of the three panels. Closing cancels an in-flight
/// search and clears the query and results, mirroring the Iced reference.
final class ReaderSearchToggled extends ReaderMessage {
  const ReaderSearchToggled();
}

/// Leaves the reader. The controller invokes the injected navigation adapter;
/// a widget never pops the route itself.
final class ReaderBackRequested extends ReaderMessage {
  const ReaderBackRequested();
}

/// Requests keyboard focus for the open panel through the focus adapter.
final class ReaderPanelFocusRequested extends ReaderMessage {
  const ReaderPanelFocusRequested(this.panel);
  final ReaderPanel panel;
}

/// Loads or retries the Contents entries (RD-07).
///
/// The controller owns the guarded effect. An injected loader is the test
/// fixture seam; the default loader resolves the document's real table of
/// contents from the Dart EPUB engine, and falls back to the EPUB chapter
/// fallback when no TOC is available (a book without one, or an unparseable
/// source).
final class ReaderContentsRequested extends ReaderMessage {
  const ReaderContentsRequested();
}

/// Navigates to a Contents entry (RD-07).
///
/// Same handler semantics as [ReaderBookmarkNavigated] — the durable offset is
/// replaced when the entry has none — with the neutral name that keeps TOC
/// navigation from being modeled as a bookmark.
final class ReaderLocationNavigated extends ReaderMessage {
  const ReaderLocationNavigated(this.unit, {this.offset});
  final int unit;
  final int? offset;
}

/// Activates a link painted on an EPUB page.
///
/// [href] is the link's raw source attribute; the controller
/// classifies it and resolves internal references against the document's parsed
/// source. An external reference never reaches the platform unless its scheme
/// is one of the allowed ones, and the reader never fetches a book resource.
final class ReaderLinkActivated extends ReaderMessage {
  const ReaderLinkActivated(this.href, {this.label});
  final String href;
  final String? label;
}

/// A completed tap in the PDF selection surface (or textless raster) frame.
final class ReaderPdfLinkTapped extends ReaderMessage {
  const ReaderPdfLinkTapped(this.x, this.y, {this.pageTap});
  final double x;
  final double y;
  final ReaderPageTapped? pageTap;
}

final class ReaderReferenceDismissed extends ReaderMessage {
  const ReaderReferenceDismissed();
}

final class ReaderReferenceGoToRequested extends ReaderMessage {
  const ReaderReferenceGoToRequested();
}

final class _ReaderReferenceLoaded extends ReaderMessage {
  const _ReaderReferenceLoaded(this.generation, this.revision, this.peek);
  final int generation;
  final int revision;
  final ReaderReferencePeek peek;
}

final class _ReaderReferenceFinished extends ReaderMessage {
  const _ReaderReferenceFinished();
}

/// Updates the more panel's page-input draft (RD-10).
final class ReaderPageInputChanged extends ReaderMessage {
  const ReaderPageInputChanged(this.draft);
  final String draft;
}

/// Submits the more panel's page-input draft (RD-10).
///
/// The controller validates the 1-based display ordinal against the document's
/// unit count, converts it to the 0-based unit and sets the inline error
/// without navigating on invalid input.
final class ReaderPageInputSubmitted extends ReaderMessage {
  const ReaderPageInputSubmitted();
}

/// Changes reader-local typography presentation (RD-09).
///
/// The controller clamps the supplied values and hands global Display changes
/// to the application settings sink. Per-book override precedence and the
/// typed fit/zoom codec are 5A/6B (contract §4.8).
final class ReaderTypographyChanged extends ReaderMessage {
  const ReaderTypographyChanged({
    this.fontSize,
    this.lineSpacing,
    this.theme,
    this.rasterFit,
    this.zoom,
    this.twoPages,
    this.animations,
    this.progress,
  });

  final double? fontSize;
  final double? lineSpacing;
  final String? theme;
  final ReaderRasterFit? rasterFit;
  final double? zoom;

  /// The Pages setting: two pages where they fit, or always one.
  final bool? twoPages;
  final bool? animations;
  final FlutterReaderProgress? progress;
}

/// Requests the Markdown export of the current book's bookmarks (RD-08).
final class ReaderBookmarkExportRequested extends ReaderMessage {
  const ReaderBookmarkExportRequested();
}

/// Steps the current search result by [delta] (±1) without re-querying (RD-11).
final class ReaderSearchResultStepRequested extends ReaderMessage {
  const ReaderSearchResultStepRequested({required this.delta});
  final int delta;
}

/// Requests the more panel's open-book action (RD-10).
///
/// The controller starts the injected document-picker adapter; the selected
/// supported document opens through the normal open path and cancellation is
/// neutral. Real tab creation/activation is 5F.
final class ReaderOpenBookRequested extends ReaderMessage {
  const ReaderOpenBookRequested();
}

final class _ReaderSearchCompleted extends ReaderMessage {
  const _ReaderSearchCompleted(this.generation, this.revision, this.results);
  final int generation;
  final int revision;
  final List<FlutterSearchMatch> results;
}

final class _ReaderSearchFailed extends ReaderMessage {
  const _ReaderSearchFailed(this.generation, this.revision, this.error);
  final int generation;
  final int revision;
  final String error;
}

final class _ReaderSearchFinished extends ReaderMessage {
  const _ReaderSearchFinished(this.cancellation);
  final BigInt cancellation;
}

final class _ReaderBookmarksCompleted extends ReaderMessage {
  const _ReaderBookmarksCompleted(this.generation, this.revision, this.items);
  final int generation;
  final int revision;
  final List<FlutterBookmark> items;
}

final class _ReaderBookmarksFailed extends ReaderMessage {
  const _ReaderBookmarksFailed(
    this.generation,
    this.revision,
    this.error, {
    this.persistence = false,
  });
  final int generation;
  final int revision;
  final String error;
  final bool persistence;
}

final class _ReaderBookmarkFinished extends ReaderMessage {
  const _ReaderBookmarkFinished(this.cancellation);
  final BigInt cancellation;
}

final class _ReaderNotesCompleted extends ReaderMessage {
  const _ReaderNotesCompleted(this.generation, this.revision, this.items);
  final int generation;
  final int revision;
  final List<FlutterNote> items;
}

final class _ReaderNotesFailed extends ReaderMessage {
  const _ReaderNotesFailed(
    this.generation,
    this.revision,
    this.error, {
    this.persistence = false,
  });
  final int generation;
  final int revision;
  final String error;
  final bool persistence;
}

/// Where a note or highlight the shell asked for resolves in the open
/// document: null when it is not there, or [error] when it could not be told.
final class _ReaderPlaceResolved extends ReaderMessage {
  const _ReaderPlaceResolved(
    this.generation,
    this.revision,
    this.place, {
    this.error,
  });
  final int generation;
  final int revision;
  final ReaderPlace? place;
  final String? error;
}

final class _ReaderPlaceResolveFinished extends ReaderMessage {
  const _ReaderPlaceResolveFinished(this.cancellation);
  final BigInt cancellation;
}

final class _ReaderNotesFinished extends ReaderMessage {
  const _ReaderNotesFinished(this.cancellation);
  final BigInt cancellation;
}

final class _ReaderLibraryNotesLoaded extends ReaderMessage {
  const _ReaderLibraryNotesLoaded(
    this.generation,
    this.revision,
    this.page, {
    required this.append,
  });
  final int generation;
  final int revision;
  final FlutterLibraryNotesPage page;
  final bool append;
}

final class _ReaderLibraryNotesFailed extends ReaderMessage {
  const _ReaderLibraryNotesFailed(
    this.generation,
    this.revision,
    this.error, {
    required this.append,
  });
  final int generation;
  final int revision;
  final String error;
  final bool append;
}

final class _ReaderLibraryNotesFinished extends ReaderMessage {
  const _ReaderLibraryNotesFinished(this.cancellation);
  final BigInt cancellation;
}

/// The note editor's result for a page note or book note: [body] is null when
/// the editor was dismissed.
final class _ReaderPlaceNoteEdited extends ReaderMessage {
  const _ReaderPlaceNoteEdited({
    required this.generation,
    required this.revision,
    required this.target,
    required this.body,
  });
  final int generation;
  final int revision;
  final _PlaceNoteTarget target;
  final String? body;
}

final class _ReaderPlaceNoteEditFailed extends ReaderMessage {
  const _ReaderPlaceNoteEditFailed(this.generation, this.revision, this.error);
  final int generation;
  final int revision;
  final String error;
}

final class _ReaderReadingStateSaveFailed extends ReaderMessage {
  const _ReaderReadingStateSaveFailed(
    this.generation,
    this.revision,
    this.error,
  );
  final int generation;
  final int revision;
  final String error;
}

final class _ReaderReadingStateSaveSucceeded extends ReaderMessage {
  const _ReaderReadingStateSaveSucceeded(this.generation, this.revision);
  final int generation;
  final int revision;
}

final class _ReaderReadingStateSaveFinished extends ReaderMessage {
  const _ReaderReadingStateSaveFinished();
}

final class ReaderSuspended extends ReaderMessage {
  const ReaderSuspended();
}

final class ReaderResumed extends ReaderMessage {
  const ReaderResumed();
}

final class ReaderMemoryPressureReceived extends ReaderMessage {
  const ReaderMemoryPressureReceived();
}

final class ReaderSelectionStarted extends ReaderMessage {
  const ReaderSelectionStarted(this.offset);
  final int offset;
}

final class ReaderSelectionExtended extends ReaderMessage {
  const ReaderSelectionExtended(this.offset);
  final int offset;
}

final class ReaderSelectionPointerStarted extends ReaderMessage {
  const ReaderSelectionPointerStarted(
    this.pointer,
    this.offset, {
    this.rangeStart,
    this.rangeEnd,
    this.x,
    this.y,
  });
  final int pointer;
  final int offset;
  final int? rangeStart;
  final int? rangeEnd;
  final double? x;
  final double? y;
}

final class ReaderSelectionPointerPressedOutside extends ReaderMessage {
  const ReaderSelectionPointerPressedOutside(this.pointer);
  final int pointer;
}

final class ReaderSelectionPointerMoved extends ReaderMessage {
  const ReaderSelectionPointerMoved(
    this.pointer,
    this.offset, {
    this.x,
    this.y,
  });
  final int pointer;
  final int offset;
  final double? x;
  final double? y;
}

final class ReaderSelectionPointerEnded extends ReaderMessage {
  const ReaderSelectionPointerEnded(this.pointer);
  final int pointer;
}

final class ReaderSelectionPointerCancelled extends ReaderMessage {
  const ReaderSelectionPointerCancelled(this.pointer);
  final int pointer;
}

final class ReaderSelectionKeyboardExtended extends ReaderMessage {
  const ReaderSelectionKeyboardExtended(this.movement, {this.arrow = false});
  final ReaderSelectionMovement movement;

  /// Whether [movement] names the direction of an arrow key on screen
  /// rather than a movement in the text: in a vertical column Up and Down
  /// then move along it, and Left and Right across columns.
  final bool arrow;
}

final class ReaderSelectionEnded extends ReaderMessage {
  const ReaderSelectionEnded();
}

final class ReaderSelectionActionsRequested extends ReaderMessage {
  const ReaderSelectionActionsRequested();
}

final class ReaderSelectionAllRequested extends ReaderMessage {
  const ReaderSelectionAllRequested();
}

final class ReaderSelectionCommitted extends ReaderMessage {
  const ReaderSelectionCommitted({
    this.color = FlutterHighlightColor.yellow,
    this.body,
  });
  final FlutterHighlightColor color;
  final String? body;
}

final class ReaderSelectionNoteRequested extends ReaderMessage {
  const ReaderSelectionNoteRequested();
}

final class ReaderSelectionCopyRequested extends ReaderMessage {
  const ReaderSelectionCopyRequested();
}

final class _ReaderSelectionNoteCompleted extends ReaderMessage {
  const _ReaderSelectionNoteCompleted(
    this.generation,
    this.revision,
    this.selectionRevision,
    this.body,
  );
  final int generation;
  final int revision;
  final int selectionRevision;
  final String body;
}

final class _ReaderSelectionEffectFailed extends ReaderMessage {
  const _ReaderSelectionEffectFailed(
    this.generation,
    this.revision,
    this.selectionRevision,
    this.error,
  );
  final int generation;
  final int revision;
  final int selectionRevision;
  final String error;
}

final class ReaderAnnotationUpdated extends ReaderMessage {
  const ReaderAnnotationUpdated(this.id, this.color, this.body);
  final String id;
  final FlutterHighlightColor color;
  final String? body;
}

final class _ReaderAnnotationUpdateCompleted extends ReaderMessage {
  const _ReaderAnnotationUpdateCompleted({
    required this.generation,
    required this.revision,
    required this.operationId,
    required this.id,
    required this.color,
    required this.body,
    required this.changed,
  });

  final int generation;
  final int revision;
  final String operationId;
  final String id;
  final FlutterHighlightColor color;
  final String? body;
  final bool changed;
}

final class ReaderAnnotationNoteRequested extends ReaderMessage {
  const ReaderAnnotationNoteRequested(this.id);
  final String id;
}

/// Saves the note a highlight's card was edited to in place; an empty body
/// removes the note.
final class ReaderAnnotationNoteSaved extends ReaderMessage {
  const ReaderAnnotationNoteSaved(this.id, this.body);
  final String id;
  final String body;
}

/// Completion from a controller-owned note editor effect.
final class _ReaderAnnotationNoteCompleted extends ReaderMessage {
  const _ReaderAnnotationNoteCompleted(
    this.generation,
    this.revision,
    this.id,
    this.body,
  );
  final int generation;
  final int revision;
  final String id;
  final String body;
}

final class _ReaderAnnotationNoteFailed extends ReaderMessage {
  const _ReaderAnnotationNoteFailed(this.generation, this.revision, this.error);
  final int generation;
  final int revision;
  final String error;
}

final class ReaderAnnotationDeleted extends ReaderMessage {
  const ReaderAnnotationDeleted(this.id);
  final String id;
}

final class ReaderAnnotationNavigated extends ReaderMessage {
  const ReaderAnnotationNavigated(this.id);
  final String id;
}

final class ReaderAnnotationAssociationRequested extends ReaderMessage {
  const ReaderAnnotationAssociationRequested();
}

final class ReaderAnnotationReloadRequested extends ReaderMessage {
  const ReaderAnnotationReloadRequested();
}

final class _ReaderAssociationSourcesLoaded extends ReaderMessage {
  const _ReaderAssociationSourcesLoaded({
    required this.generation,
    required this.revision,
    required this.operationId,
    required this.cancellation,
    required this.document,
    required this.cursor,
    required this.page,
  });

  final int generation;
  final int revision;
  final String operationId;
  final BigInt cancellation;
  final FlutterDocumentSummary document;
  final String? cursor;
  final FlutterAnnotationAssociationSourcePage page;
}

final class _ReaderAssociationChoiceCompleted extends ReaderMessage {
  const _ReaderAssociationChoiceCompleted({
    required this.sources,
    required this.choice,
    this.error,
  });

  final _ReaderAssociationSourcesLoaded sources;
  final AnnotationAssociationChoice? choice;
  final String? error;
}

final class _ReaderAssociationPersisted extends ReaderMessage {
  const _ReaderAssociationPersisted({
    required this.sources,
    required this.outcome,
  });

  final _ReaderAssociationSourcesLoaded sources;
  final FlutterAnnotationAssociationOutcome outcome;
}

final class _ReaderAssociationFinished extends ReaderMessage {
  const _ReaderAssociationFinished({
    required this.sources,
    this.items,
    this.error,
  });

  final _ReaderAssociationSourcesLoaded sources;
  final List<FlutterAnnotation>? items;
  final String? error;
}

final class ReaderSelectionCancelled extends ReaderMessage {
  const ReaderSelectionCancelled();
}

final class _ReaderDocumentOpened extends ReaderMessage {
  const _ReaderDocumentOpened({
    required this.generation,
    required this.document,
    required this.pdfDocument,
    required this.unit,
    required this.bookmarks,
    required this.layout,
    required this.restoredLayout,
    required this.restorationFailed,
    this.restorationError,
    this.offset,
    this.toolError,
    this.returnPoints = const [],
    this.match,
  });

  final int generation;
  final FlutterDocumentSummary document;

  /// The engine document behind a PDF; null for every other format.
  final PdfEngineDocument? pdfDocument;
  final int unit;
  final List<FlutterBookmark> bookmarks;
  final ReaderLayout layout;
  final bool restoredLayout;
  final bool restorationFailed;
  final String? restorationError;
  final int? offset;
  final String? toolError;

  /// The return points the book opens with: where it was left, when it
  /// opened at another place, or the way back to the book it was opened from.
  final List<ReaderReturnPoint> returnPoints;

  /// The search match the book opened at: its page, which on a PDF spread
  /// may be the second, and where in that page's text it runs.
  final ({int unit, int offset, int length})? match;
}

final class _ReaderImageDecoded extends ReaderMessage {
  const _ReaderImageDecoded({
    required this.generation,
    required this.pageImage,
    this.rasterScale,
  });

  final int generation;
  final ui.Image? pageImage;

  /// The scale [pageImage] was rendered at, for a PDF page.
  final double? rasterScale;
}

final class _ReaderSurfaceLoaded extends ReaderMessage {
  const _ReaderSurfaceLoaded({
    required this.generation,
    required this.surface,
    this.pdfSpread,
    this.readingPage,
    this.readingOffset,
  });
  final int generation;
  final FlutterSelectionSurface surface;
  final ReaderPdfSpread? pdfSpread;

  /// The spread's page the restored position is on, with [pdfSpread].
  final int? readingPage;

  /// The restored reading offset in [surface]'s text, when it moved: a
  /// position on a spread's second page lies past the first page's text.
  final int? readingOffset;
}

final class _ReaderSelectionSupportFailed extends ReaderMessage {
  const _ReaderSelectionSupportFailed(
    this.generation,
    this.error, {
    this.pdfSpread,
    this.readingPage,
  });
  final int generation;
  final String error;

  /// The spread shown without text, when a PDF opened on one.
  final ReaderPdfSpread? pdfSpread;

  /// The spread's page the restored position is on, with [pdfSpread].
  final int? readingPage;
}

final class _ReaderRelayoutCompleted extends ReaderMessage {
  const _ReaderRelayoutCompleted({
    required this.generation,
    required this.revision,
    required this.cancellation,
    required this.unit,
    required this.layout,
    required this.surface,
    this.pdfSpread,
    this.readingPage,
    required this.pageImage,
    required this.annotations,
    required this.replaceReadingOffset,
    this.offset,
    this.length,
    this.selectionError,
    this.annotationError,
    this.rasterScale,
  });

  final int generation;
  final int revision;
  final BigInt cancellation;
  final int unit;
  final ReaderLayout layout;
  final FlutterSelectionSurface? surface;

  /// The spread [surface] and [pageImage] show, when they span two PDF pages.
  final ReaderPdfSpread? pdfSpread;

  /// The spread's page being read, with [pdfSpread]: the page asked for, or
  /// the one read before a relayout with no target of its own.
  final int? readingPage;
  final ui.Image pageImage;

  /// The scale [pageImage] was rendered at.
  final double? rasterScale;
  final List<FlutterAnnotation> annotations;
  final bool replaceReadingOffset;
  final int? offset;
  final int? length;
  final String? selectionError;
  final String? annotationError;
}

/// The region of a continuous EPUB chapter the view shows, in the page's
/// coordinates, for the location request it answers.
///
/// The controller lays out the chapter's window around it; a report for an
/// older request (before the view revealed the new location) is ignored.
final class ReaderContinuousViewportChanged extends ReaderMessage {
  const ReaderContinuousViewportChanged({
    required this.generation,
    required this.revision,
    required this.top,
    required this.bottom,
    required this.window,
  });

  final int generation;

  /// The window of the page the region was measured against. A report made
  /// before the view applied a newer window's correction is in that older
  /// column's coordinates; the controller maps it into the current column.
  final ReaderEpubWindow? window;

  /// The [ReaderModel.locationRequestRevision] the view has revealed.
  final int revision;
  final double top;
  final double bottom;
}

/// One due step of the continuous window, for the layout that scheduled it.
final class _ReaderContinuousWindowTick extends ReaderMessage {
  const _ReaderContinuousWindowTick(this.generation, this.revision, this.token);

  final int generation;
  final int revision;
  final int token;
}

/// A keyboard selection movement a continuous window could not complete in
/// one bounded step, continued in the next frame.
final class _ReaderSelectionMovementContinued extends ReaderMessage {
  const _ReaderSelectionMovementContinued({
    required this.generation,
    required this.layoutRevision,
    required this.selectionRevision,
    required this.focus,
    required this.movement,
  });

  final int generation;
  final int layoutRevision;
  final int selectionRevision;
  final int focus;
  final ReaderSelectionMovement movement;
}

/// One installed page window of the Dart EPUB renderer.
///
/// The effect reports the page it wants installed (by canonical scalar); the
/// controller derives the window from the session it owns, so a completion
/// cannot install a page from a session the controller has already retired.
final class _ReaderEpubPageLoaded extends ReaderMessage {
  const _ReaderEpubPageLoaded({
    required this.generation,
    required this.revision,
    required this.cancellation,
    required this.unit,
    required this.scalar,
    required this.layout,
    required this.height,
    required this.annotations,
    required this.replaceReadingOffset,
    required this.epubEdge,
    this.offset,
    this.length,
    this.annotationError,
    this.session,
    this.sessionKey,
  });

  final int generation;
  final int revision;
  final BigInt cancellation;
  final int unit;
  final int scalar;
  final ReaderLayout layout;
  final double height;
  final List<FlutterAnnotation> annotations;
  final bool replaceReadingOffset;
  final EpubPositionEdge epubEdge;
  final int? offset;
  final int? length;
  final String? annotationError;

  /// The replacement chapter session this page was measured from, when the
  /// relayout built one. The handler adopts it together with the page; a page
  /// that is superseded before installing never adopts it, and the effect that
  /// created it releases it.
  final ChapterLayoutSession? session;

  /// The layout key [session] was measured for.
  final _EpubLayoutKey? sessionKey;
}

final class _ReaderRelayoutFailed extends ReaderMessage {
  const _ReaderRelayoutFailed({
    required this.generation,
    required this.revision,
    required this.layout,
    required this.error,
    this.limit,
  });

  final int generation;
  final int revision;
  final ReaderLayout layout;
  final String error;

  /// The bounded-work ceiling the refused EPUB chapter exceeds, when the
  /// failure is a typed refusal rather than an error.
  final EpubLayoutLimitExceeded? limit;
}

final class _ReaderRelayoutFinished extends ReaderMessage {
  const _ReaderRelayoutFinished(this.cancellation);

  final BigInt cancellation;
}

final class _ReaderAnnotationListFailed extends ReaderMessage {
  const _ReaderAnnotationListFailed(this.generation, this.revision, this.error);
  final int generation;
  final int revision;
  final String error;
}

final class _ReaderAnnotationsChanged extends ReaderMessage {
  const _ReaderAnnotationsChanged(
    this.generation,
    this.revision,
    this.operationId,
    this.selectionRevision,
    this.items, [
    this.error,
  ]);
  final int generation;
  final int revision;
  final String? operationId;
  final int? selectionRevision;
  final List<FlutterAnnotation>? items;
  final String? error;
}

final class _ReaderOpenFailed extends ReaderMessage {
  const _ReaderOpenFailed({
    required this.generation,
    required this.document,
    required this.error,
    this.pdfDocument,
  });

  final int generation;
  final FlutterDocumentSummary? document;

  /// An engine document the failed open still owns, released with it.
  final PdfEngineDocument? pdfDocument;
  final String error;
}

final class _ReaderOperationFinished extends ReaderMessage {
  const _ReaderOperationFinished({
    required this.generation,
    required this.cancellation,
  });

  final int generation;
  final BigInt cancellation;
}

final class _ReaderAnnotationCreateFinished extends ReaderMessage {
  const _ReaderAnnotationCreateFinished(
    this.cancellation, {
    required this.succeeded,
  });
  final BigInt cancellation;
  final bool succeeded;
}

final class _ReaderAnnotationOperationFinished extends ReaderMessage {
  const _ReaderAnnotationOperationFinished();
}

final class _ReaderSelectionActionFocusReady extends ReaderMessage {
  const _ReaderSelectionActionFocusReady(this.generation, this.revision);

  final int generation;
  final int revision;
}

final class _ReaderSurfaceFocusReady extends ReaderMessage {
  const _ReaderSurfaceFocusReady(this.generation, this.revision);

  final int generation;
  final int revision;
}

final class _ReaderNoteEditorFinished extends ReaderMessage {
  const _ReaderNoteEditorFinished(this.token);

  /// Controller-wide ownership token of the editor that finished, so a stale
  /// completion cannot clear a newer editor's slot even when the per-operation
  /// revisions collide (page and book note editors count with
  /// `_notesRevision`, selection/annotation editors with `_noteRevision`).
  final int token;
}

final class _ReaderDisposeRequested extends ReaderMessage {
  const _ReaderDisposeRequested();
}

final class _ReaderContentsLoaded extends ReaderMessage {
  const _ReaderContentsLoaded(this.generation, this.revision, this.entries);

  final int generation;
  final int revision;
  final List<ReaderContentsEntry> entries;
}

final class _ReaderContentsFailed extends ReaderMessage {
  const _ReaderContentsFailed(this.generation, this.revision, this.error);

  final int generation;
  final int revision;
  final String error;
}

/// Releases the bridge cancellation one Contents load owned.
final class _ReaderContentsFinished extends ReaderMessage {
  const _ReaderContentsFinished(this.cancellation);
  final BigInt cancellation;
}

/// Releases the bridge cancellation one shared EPUB source load owned.
///
/// The load is shared by concurrent relayouts and Contents requests, so its
/// token is owned by the controller rather than by one request.
final class _ReaderEpubSourceFinished extends ReaderMessage {
  const _ReaderEpubSourceFinished(this.cancellation);
  final BigInt cancellation;
}

final class _ReaderBookmarkExportFinished extends ReaderMessage {
  const _ReaderBookmarkExportFinished();
}

final class _ReaderBookmarkExportCompleted extends ReaderMessage {
  const _ReaderBookmarkExportCompleted(this.generation, this.revision);

  final int generation;
  final int revision;
}

final class _ReaderBookmarkExportFailed extends ReaderMessage {
  const _ReaderBookmarkExportFailed(this.generation, this.revision, this.error);

  final int generation;
  final int revision;
  final String error;
}

final class _ReaderDocumentPickerCompleted extends ReaderMessage {
  const _ReaderDocumentPickerCompleted(
    this.generation,
    this.revision,
    this.picked,
  );

  final int generation;
  final int revision;
  final ReaderPickedDocument? picked;
}

final class _ReaderDocumentPickerFailed extends ReaderMessage {
  const _ReaderDocumentPickerFailed(this.generation, this.revision, this.error);

  final int generation;
  final int revision;
  final String error;
}
