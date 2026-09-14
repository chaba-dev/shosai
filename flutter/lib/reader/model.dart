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
    this.selectionActionError,
    this.annotationError,
    this.annotationsReady = false,
    this.searchBusy = false,
    this.bookmarkBusy = false,
    this.toolError,
    this.persistenceError,
    this.notice,
    this.toolsVisible = false,
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
       annotationOperations = Set.unmodifiable(annotationOperations);

  final String? openPath;
  final int? openBookId;
  final FlutterDocumentSummary? document;
  final int unit;

  /// Durable document location. Selection endpoints are intentionally separate.
  final int? readingOffset;
  final ui.Image? pageImage;
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
  final String? selectionActionError;
  final String? annotationError;
  final bool annotationsReady;
  final bool searchBusy;
  final bool bookmarkBusy;
  final String? toolError;

  /// Reading-position restoration/save feedback, independent of tool chrome.
  final String? persistenceError;
  final Notice? notice;
  final bool toolsVisible;
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
    Object? selectionActionError = _unchanged,
    Object? annotationError = _unchanged,
    bool? annotationsReady,
    bool? searchBusy,
    bool? bookmarkBusy,
    Object? toolError = _unchanged,
    Object? persistenceError = _unchanged,
    Object? notice = _unchanged,
    bool? toolsVisible,
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
      notice: identical(notice, _unchanged) ? this.notice : notice as Notice?,
      toolsVisible: toolsVisible ?? this.toolsVisible,
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

enum ReaderFocusTarget { surface, actions }

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
