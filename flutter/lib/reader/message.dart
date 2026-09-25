part of 'controller.dart';

sealed class ReaderMessage {
  const ReaderMessage();
}

final class ReaderOpenRequested extends ReaderMessage {
  const ReaderOpenRequested(this.path, {this.bookId});

  final String path;
  final int? bookId;
}

final class ReaderLayoutChanged extends ReaderMessage {
  const ReaderLayoutChanged(this.layout);

  final ReaderLayout layout;
}

final class ReaderViewportChanged extends ReaderMessage {
  const ReaderViewportChanged(this.layout);

  final ReaderLayout layout;
}

final class ReaderUnitRequested extends ReaderMessage {
  const ReaderUnitRequested(this.unit, {this.offset, this.length});

  final int unit;
  final int? offset;
  final int? length;
}

final class ReaderSearchRequested extends ReaderMessage {
  const ReaderSearchRequested(this.query);
  final String query;
}

final class ReaderBookmarkToggled extends ReaderMessage {
  const ReaderBookmarkToggled();
}

final class ReaderBookmarkNoteRequested extends ReaderMessage {
  const ReaderBookmarkNoteRequested([this.bookmark]);
  final FlutterBookmark? bookmark;
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

/// Activates the tab with [tabId] (presentation-only in 4B).
final class ReaderTabActivated extends ReaderMessage {
  const ReaderTabActivated(this.tabId);
  final String tabId;
}

/// Requests closing the tab with [tabId] (presentation-only in 4B).
///
/// Real close semantics (adjacent selection, last-tab return, pending saves,
/// resource release) are 5F; 4B applies its documented fixture policy.
final class ReaderTabCloseRequested extends ReaderMessage {
  const ReaderTabCloseRequested(this.tabId);
  final String tabId;
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

final class _ReaderBookmarkNoteEdited extends ReaderMessage {
  const _ReaderBookmarkNoteEdited({
    required this.generation,
    required this.revision,
    required this.bookId,
    required this.unit,
    required this.offset,
    required this.bookmarkId,
    required this.note,
  });
  final int generation;
  final int revision;
  final int bookId;
  final int unit;
  final int? offset;
  final int? bookmarkId;
  final String? note;
}

final class _ReaderBookmarkNoteEditFailed extends ReaderMessage {
  const _ReaderBookmarkNoteEditFailed(
    this.generation,
    this.revision,
    this.error,
  );
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
  const ReaderSelectionKeyboardExtended(this.movement);
  final ReaderSelectionMovement movement;
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
    required this.unit,
    required this.bookmarks,
    required this.layout,
    required this.restoredLayout,
    required this.restorationFailed,
    this.restorationError,
    this.offset,
    this.toolError,
  });

  final int generation;
  final FlutterDocumentSummary document;
  final int unit;
  final List<FlutterBookmark> bookmarks;
  final ReaderLayout layout;
  final bool restoredLayout;
  final bool restorationFailed;
  final String? restorationError;
  final int? offset;
  final String? toolError;
}

final class _ReaderImageDecoded extends ReaderMessage {
  const _ReaderImageDecoded({
    required this.generation,
    required this.pageImage,
  });

  final int generation;
  final ui.Image? pageImage;
}

final class _ReaderSurfaceLoaded extends ReaderMessage {
  const _ReaderSurfaceLoaded({required this.generation, required this.surface});
  final int generation;
  final FlutterSelectionSurface surface;
}

final class _ReaderEpubContentLoaded extends ReaderMessage {
  const _ReaderEpubContentLoaded({
    required this.generation,
    required this.surface,
    required this.pageImage,
  });
  final int generation;
  final FlutterSelectionSurface surface;
  final ui.Image pageImage;
}

final class _ReaderSelectionSupportFailed extends ReaderMessage {
  const _ReaderSelectionSupportFailed(this.generation, this.error);
  final int generation;
  final String error;
}

final class _ReaderRelayoutCompleted extends ReaderMessage {
  const _ReaderRelayoutCompleted({
    required this.generation,
    required this.revision,
    required this.cancellation,
    required this.unit,
    required this.layout,
    required this.surface,
    required this.pageImage,
    required this.annotations,
    required this.replaceReadingOffset,
    this.offset,
    this.length,
    this.selectionError,
    this.annotationError,
  });

  final int generation;
  final int revision;
  final BigInt cancellation;
  final int unit;
  final ReaderLayout layout;
  final FlutterSelectionSurface? surface;
  final ui.Image pageImage;
  final List<FlutterAnnotation> annotations;
  final bool replaceReadingOffset;
  final int? offset;
  final int? length;
  final String? selectionError;
  final String? annotationError;
}

final class _ReaderRelayoutFailed extends ReaderMessage {
  const _ReaderRelayoutFailed({
    required this.generation,
    required this.revision,
    required this.layout,
    required this.error,
  });

  final int generation;
  final int revision;
  final ReaderLayout layout;
  final String error;
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
  });

  final int generation;
  final FlutterDocumentSummary? document;
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
  /// revisions collide (bookmark editors count with `_bookmarkRevision`,
  /// selection/annotation editors with `_noteRevision`).
  final int token;
}

final class _ReaderDisposeRequested extends ReaderMessage {
  const _ReaderDisposeRequested();
}
