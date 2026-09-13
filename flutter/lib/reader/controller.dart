import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart'
    show FlutterError, FlutterErrorDetails, Listenable, VoidCallback;
import 'package:shosai_flutter/src/rust/api.dart';

part 'effects.dart';
part 'message.dart';
part 'model.dart';

final class ReaderController implements Listenable {
  ReaderController({
    required FlutterBridge bridge,
    required PageDecoder decoder,
    double initialScale = 1,
    double initialLineSpacing = 1.5,
    NoteEditor? noteEditor,
    NoteEditor? bookmarkNoteEditor,
    NoteEditorCanceller? noteEditorCanceller,
    AnnotationAssociationPicker? annotationAssociationPicker,
    AnnotationAssociationPickerCanceller? annotationAssociationPickerCanceller,
    ReaderFocusAdapter? focusAdapter,
    ReaderFrameScheduler? frameScheduler,
    SelectionCopier? selectionCopier,
    ReaderSelectionAnnouncer? selectionAnnouncer,
  }) : _bridge = bridge,
       _decoder = decoder,
       _noteEditor = noteEditor ?? ((_) async => null),
       _bookmarkNoteEditor =
           bookmarkNoteEditor ?? noteEditor ?? ((_) async => null),
       _noteEditorCanceller = noteEditorCanceller ?? (() {}),
       _annotationAssociationPicker =
           annotationAssociationPicker ??
           ((_) async => const AnnotationAssociationCancelled()),
       _annotationAssociationPickerCanceller =
           annotationAssociationPickerCanceller ?? (() {}),
       _focusAdapter = focusAdapter ?? ((_) {}),
       _frameScheduler = frameScheduler ?? ((callback) => callback()),
       _selectionCopier = selectionCopier ?? ((_) async {}),
       _selectionAnnouncer = selectionAnnouncer,
       _requestedLayout = ReaderLayout(
         scale: initialScale,
         lineSpacing: initialLineSpacing,
       );

  final FlutterBridge _bridge;
  final PageDecoder _decoder;
  final NoteEditor _noteEditor;
  final NoteEditor _bookmarkNoteEditor;
  final NoteEditorCanceller _noteEditorCanceller;
  final AnnotationAssociationPicker _annotationAssociationPicker;
  final AnnotationAssociationPickerCanceller
  _annotationAssociationPickerCanceller;
  final ReaderFocusAdapter _focusAdapter;
  final ReaderFrameScheduler _frameScheduler;
  final SelectionCopier _selectionCopier;
  final ReaderSelectionAnnouncer? _selectionAnnouncer;

  ReaderModel _model = ReaderModel();
  BigInt? _activeCancellation;
  final Set<BigInt> _relayoutCancellations = {};
  final Set<BigInt> _annotationCancellations = {};
  final Set<BigInt> _noteCreateCancellations = {};
  final Set<BigInt> _interruptedNoteCreates = {};
  final Set<String> _noteUpdateOperations = {};
  final Set<String> _interruptedNoteUpdates = {};
  final Map<BigInt, int> _selectionCancellations = {};
  final Set<int> _cancelledSelectionCreates = {};
  int _activeBridgeOperations = 0;
  int _annotationRevision = 0;
  int _layoutRevision = 0;
  int _selectionRevision = 0;
  int _nextOperationId = 0;
  int _noteRevision = 0;
  int _searchRevision = 0;
  int _bookmarkRevision = 0;
  String _searchQuery = '';
  final Set<BigInt> _toolCancellations = {};
  final Set<BigInt> _searchCancellations = {};
  BigInt? _bookmarkMutationCancellation;
  _ReaderNoteTarget? _activeNoteEditor;
  int? _activeNoteEditorRevision;
  bool _associationPickerActive = false;
  String? _recoverySelectionNotice;
  String? _recoveryAnnotationNotice;
  ReaderLayout _requestedLayout;
  _RelayoutIntent? _activeRelayoutIntent;
  ReaderLayout? _failedLayout;
  String? _recoveryPath;
  int? _recoveryBookId;
  static final Map<int, _ReadingStateSaveQueue> _bookReadingStateSaves = {};
  static final Map<int, _BookWriteDrain> _bookWrites = {};
  static final Map<int, Map<String, String>> _bookWriteFailures = {};
  bool _suspended = false;
  bool _releaseForRecovery = false;
  bool _reopenForRecovery = false;
  bool _closing = false;
  bool _listenersDisposed = false;
  int _readingStateSaveRevision = 0;
  String? _readingStateSaveError;
  bool _readingStatePersistenceBlocked = false;
  final Set<VoidCallback> _listeners = {};

  ReaderModel get model => _model;

  /// Completes after every accepted durable write for [bookId] in-process.
  static Future<void> drainBookWrites(int bookId) async {
    await (_bookWrites[bookId]?.drained.future ?? Future<void>.value());
    final failures = _bookWriteFailures.remove(bookId)?.values.toList();
    if (failures != null && failures.isNotEmpty) {
      throw ReaderPersistenceException(failures.join(' '));
    }
  }

  @Deprecated(
    'Use drainBookWrites; it also includes bookmarks and annotations.',
  )
  static Future<void> drainBookReadingStateWrites(int bookId) =>
      drainBookWrites(bookId);

  Future<void> drainReadingStateWrites(int bookId) => drainBookWrites(bookId);

  static void _beginBookWrite(int bookId) {
    _bookWrites.putIfAbsent(bookId, _BookWriteDrain.new).begin();
  }

  static void _finishBookWrite(
    int bookId, {
    String? failureKind,
    String? error,
    bool succeeded = false,
  }) {
    if (failureKind != null && error != null) {
      _bookWriteFailures.putIfAbsent(bookId, () => {})[failureKind] = error;
    } else if (failureKind != null && succeeded) {
      final failures = _bookWriteFailures[bookId];
      if (failures != null) {
        failures.remove(failureKind);
        if (failures.isEmpty) _bookWriteFailures.remove(bookId);
      }
    }
    final drain = _bookWrites[bookId];
    if (drain != null && drain.finish()) _bookWrites.remove(bookId);
  }

  bool get _recovering => _releaseForRecovery || _reopenForRecovery;

  @override
  void addListener(VoidCallback listener) {
    if (!_listenersDisposed) _listeners.add(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    _listeners.remove(listener);
  }

  void dispatch(ReaderMessage message) {
    if (_recovering &&
        switch (message) {
          ReaderSelectionStarted() ||
          ReaderSelectionExtended() ||
          ReaderSelectionPointerStarted() ||
          ReaderSelectionPointerPressedOutside() ||
          ReaderSelectionPointerMoved() ||
          ReaderSelectionPointerEnded() ||
          ReaderSelectionPointerCancelled() ||
          ReaderSelectionKeyboardExtended() ||
          ReaderSelectionEnded() ||
          ReaderSelectionActionsRequested() ||
          ReaderSelectionAllRequested() ||
          ReaderSelectionCommitted() ||
          ReaderSelectionNoteRequested() ||
          ReaderSelectionCopyRequested() ||
          ReaderSelectionCancelled() ||
          ReaderAnnotationUpdated() ||
          ReaderAnnotationNoteRequested() ||
          ReaderAnnotationDeleted() ||
          ReaderAnnotationNavigated() ||
          ReaderAnnotationReloadRequested() ||
          ReaderAnnotationAssociationRequested() ||
          ReaderSearchRequested() ||
          ReaderBookmarkToggled() ||
          ReaderBookmarkNoteRequested() ||
          ReaderBookmarkDeleted() ||
          ReaderBookmarkNavigated() => true,
          _ => false,
        }) {
      return;
    }
    switch (message) {
      case ReaderOpenRequested():
        _openRequested(message);
      case ReaderLayoutChanged():
        _layoutChanged(message.layout);
      case ReaderViewportChanged():
        _viewportChanged(message.layout);
      case ReaderUnitRequested():
        _unitRequested(
          message.unit,
          offset: message.offset,
          length: message.length,
        );
      case ReaderSearchRequested():
        _searchRequested(message.query);
      case ReaderBookmarkToggled():
        _bookmarkToggled();
      case ReaderBookmarkNoteRequested():
        _bookmarkNoteRequested(message.bookmark);
      case ReaderBookmarkDeleted():
        _bookmarkDeleted(message.id);
      case ReaderBookmarkNavigated():
        _unitRequested(
          message.unit,
          offset: message.offset,
          replaceReadingOffset: true,
        );
      case ReaderToolsToggled():
        _emit(_model.copyWith(toolsVisible: !_model.toolsVisible));
      case _ReaderSearchCompleted():
        if (_isCurrent(message.generation) &&
            message.revision == _searchRevision) {
          _emit(
            _model.copyWith(searchResults: message.results, searchBusy: false),
          );
        }
      case _ReaderSearchFailed():
        if (_isCurrent(message.generation) &&
            message.revision == _searchRevision) {
          _emit(_model.copyWith(searchBusy: false, toolError: message.error));
        }
      case _ReaderSearchFinished():
        _searchCancellations.remove(message.cancellation);
        _toolCancellations.remove(message.cancellation);
        _bridge.releaseCancellation(id: message.cancellation);
        _activeBridgeOperations -= 1;
        _recoverIfIdle();
        _disposeBridgeIfIdle();
      case _ReaderBookmarksCompleted():
        if (_isCurrent(message.generation) &&
            message.revision == _bookmarkRevision) {
          _emit(_model.copyWith(bookmarks: message.items, bookmarkBusy: false));
        }
      case _ReaderBookmarksFailed():
        if (_isCurrent(message.generation) &&
            message.revision == _bookmarkRevision) {
          final error = message.persistence
              ? 'Bookmark changes were not saved: ${message.error}'
              : message.error;
          _emit(
            _model.copyWith(
              bookmarkBusy: false,
              toolError: error,
              persistenceError: message.persistence ? error : _unchanged,
            ),
          );
        }
      case _ReaderBookmarkFinished():
        if (_bookmarkMutationCancellation == message.cancellation) {
          _bookmarkMutationCancellation = null;
        }
        _toolCancellations.remove(message.cancellation);
        _bridge.releaseCancellation(id: message.cancellation);
        _activeBridgeOperations -= 1;
        _recoverIfIdle();
        _disposeBridgeIfIdle();
      case _ReaderBookmarkNoteEdited():
        _bookmarkNoteEdited(message);
      case _ReaderBookmarkNoteEditFailed():
        if (_isCurrent(message.generation) &&
            message.revision == _bookmarkRevision) {
          _emit(_model.copyWith(bookmarkBusy: false, toolError: message.error));
        }
      case _ReaderReadingStateSaveFailed():
        if (_isCurrent(message.generation) &&
            message.revision == _readingStateSaveRevision &&
            !_closing) {
          final error = 'Reading position was not saved: ${message.error}';
          final ownsPersistenceError =
              _model.persistenceError == null ||
              _model.persistenceError == _readingStateSaveError;
          _readingStateSaveError = error;
          _emit(
            _model.copyWith(
              toolError: error,
              persistenceError: ownsPersistenceError ? error : _unchanged,
            ),
          );
        }
      case _ReaderReadingStateSaveSucceeded():
        if (_isCurrent(message.generation) &&
            message.revision == _readingStateSaveRevision &&
            _readingStateSaveError != null) {
          final ownsToolError = _model.toolError == _readingStateSaveError;
          final ownsPersistenceError =
              _model.persistenceError == _readingStateSaveError;
          _readingStateSaveError = null;
          _emit(
            _model.copyWith(
              toolError: ownsToolError ? null : _unchanged,
              persistenceError: ownsPersistenceError ? null : _unchanged,
            ),
          );
        }
      case _ReaderReadingStateSaveFinished():
        _activeBridgeOperations -= 1;
        _recoverIfIdle();
        _disposeBridgeIfIdle();
      case ReaderSuspended():
        _suspendRequested();
      case ReaderResumed():
        _resumeRequested();
      case ReaderMemoryPressureReceived():
        _memoryPressureReceived();
      case ReaderSelectionStarted():
        _selectionStarted(message.offset);
      case ReaderSelectionExtended():
        _selectionExtended(message.offset);
      case ReaderSelectionPointerStarted():
        _selectionPointerStarted(
          message.pointer,
          message.offset,
          message.rangeStart,
          message.rangeEnd,
          message.x,
          message.y,
        );
      case ReaderSelectionPointerPressedOutside():
        if (_model.selectionPointer == null) {
          _selectionCancelled();
        }
      case ReaderSelectionPointerMoved():
        _selectionPointerMoved(
          message.pointer,
          message.offset,
          message.x,
          message.y,
        );
      case ReaderSelectionPointerEnded():
        _selectionPointerEnded(message.pointer);
      case ReaderSelectionPointerCancelled():
        _selectionPointerCancelled(message.pointer);
      case ReaderSelectionKeyboardExtended():
        _selectionKeyboardExtended(message.movement);
      case ReaderSelectionEnded():
        _selectionEnded();
      case ReaderSelectionActionsRequested():
        if (_model.selectionPhase == ReaderSelectionPhase.selected) {
          _emit(_model.copyWith(keyboardActionInvocation: true));
          _focusAdapter(ReaderFocusTarget.actions);
        }
      case ReaderSelectionAllRequested():
        _selectionAllRequested();
      case _ReaderSelectionActionFocusReady():
        if (_isCurrent(message.generation) &&
            message.revision == _selectionRevision &&
            _model.selectionPhase == ReaderSelectionPhase.selected &&
            _model.keyboardActionInvocation &&
            !_closing) {
          _focusAdapter(ReaderFocusTarget.actions);
        }
      case _ReaderSurfaceFocusReady():
        if (_isCurrent(message.generation) &&
            message.revision == _layoutRevision &&
            !_closing &&
            !_suspended &&
            !_recovering) {
          _focusAdapter(ReaderFocusTarget.surface);
        }
      case ReaderSelectionCommitted():
        _selectionCommitted(message.color, message.body);
      case ReaderSelectionNoteRequested():
        _selectionNoteRequested();
      case ReaderSelectionCopyRequested():
        _selectionCopyRequested();
      case _ReaderSelectionNoteCompleted():
        if (_isCurrent(message.generation) &&
            message.revision == _noteRevision) {
          if (message.selectionRevision == _selectionRevision) {
            _selectionCommitted(FlutterHighlightColor.yellow, message.body);
          } else {
            _emit(
              _model.copyWith(
                selectionActionError:
                    'The note was not saved because the selection or reader layout changed. Try again.',
              ),
            );
          }
        }
      case _ReaderSelectionEffectFailed():
        if (_isCurrent(message.generation) &&
            message.revision == _noteRevision &&
            message.selectionRevision == _selectionRevision) {
          _emit(_model.copyWith(selectionActionError: message.error));
        }
      case ReaderAnnotationUpdated():
        unawaited(_updateAnnotation(message));
      case ReaderAnnotationNoteRequested():
        _noteRequested(message.id);
      case _ReaderAnnotationNoteCompleted():
        _noteCompleted(message);
      case _ReaderAnnotationNoteFailed():
        if (_isCurrent(message.generation) &&
            message.revision == _noteRevision) {
          _emit(_model.copyWith(annotationError: message.error));
        }
      case ReaderAnnotationDeleted():
        unawaited(_deleteAnnotation(message.id));
      case ReaderAnnotationNavigated():
        _navigateAnnotation(message.id);
      case ReaderAnnotationReloadRequested():
        _annotationReloadRequested();
      case ReaderAnnotationAssociationRequested():
        _associationRequested();
      case _ReaderAssociationSourcesLoaded():
        _associationSourcesLoaded(message);
      case _ReaderAssociationChoiceCompleted():
        _associationChoiceCompleted(message);
      case _ReaderAssociationPersisted():
        _associationPersisted(message);
      case _ReaderAssociationFinished():
        _associationFinished(message);
      case ReaderSelectionCancelled():
        _selectionCancelled();
      case _ReaderDocumentOpened():
        _documentOpened(message);
      case _ReaderImageDecoded():
        _imageDecoded(message);
      case _ReaderSurfaceLoaded():
        if (_isCurrent(message.generation)) {
          _emit(
            _model.copyWith(
              selectionSurface: _freezeSurface(message.surface),
              contentState: ReaderContentState.ready,
            ),
          );
        } else {
          _releaseSurface(message.surface);
        }
      case _ReaderEpubContentLoaded():
        if (_isCurrent(message.generation)) {
          _emit(
            _model.copyWith(
              selectionSurface: _freezeSurface(message.surface),
              pageImage: message.pageImage,
              contentState: ReaderContentState.ready,
            ),
          );
        } else {
          message.pageImage.dispose();
          _releaseSurface(message.surface);
        }
      case _ReaderSelectionSupportFailed():
        if (_isCurrent(message.generation)) {
          final mandatory = _model.document?.format == FlutterBookFormat.epub;
          _emit(
            _model.copyWith(
              selectionError: message.error,
              contentState: mandatory
                  ? ReaderContentState.failed
                  : _model.contentState,
              error: mandatory ? message.error : _unchanged,
            ),
          );
        }
      case _ReaderRelayoutCompleted():
        _relayoutCompleted(message);
      case _ReaderRelayoutFailed():
        if (_isCurrent(message.generation) &&
            message.revision == _layoutRevision) {
          _activeRelayoutIntent = null;
          _failedLayout = message.layout;
          _emit(
            _model.copyWith(
              relayoutBusy: false,
              relayoutPending: false,
              selectionError: 'Relayout failed: ${message.error}',
            ),
          );
        }
      case _ReaderRelayoutFinished():
        _relayoutCancellations.remove(message.cancellation);
        _bridge.releaseCancellation(id: message.cancellation);
        _activeBridgeOperations -= 1;
        _recoverIfIdle();
        _disposeBridgeIfIdle();
      case _ReaderAnnotationListFailed():
        if (_isCurrent(message.generation) &&
            message.revision == _annotationRevision) {
          _emit(_model.copyWith(annotationError: message.error));
        }
      case _ReaderAnnotationsChanged():
        _annotationsChanged(message);
      case _ReaderOpenFailed():
        _openFailed(message);
      case _ReaderOperationFinished():
        _operationFinished(message);
      case _ReaderAnnotationCreateFinished():
        final interruptedNote = _interruptedNoteCreates.remove(
          message.cancellation,
        );
        _noteCreateCancellations.remove(message.cancellation);
        if (interruptedNote && !message.succeeded) {
          _recoverySelectionNotice =
              'The note could not be saved while the app was suspended. Try again.';
        }
        final selectionRevision = _selectionCancellations[message.cancellation];
        _annotationCancellations.remove(message.cancellation);
        _selectionCancellations.remove(message.cancellation);
        if (selectionRevision != null &&
            !_selectionCancellations.containsValue(selectionRevision)) {
          _cancelledSelectionCreates.remove(selectionRevision);
        }
        _bridge.releaseCancellation(id: message.cancellation);
        _activeBridgeOperations -= 1;
        _recoverIfIdle();
        _disposeBridgeIfIdle();
      case _ReaderAnnotationOperationFinished():
        _activeBridgeOperations -= 1;
        _recoverIfIdle();
        _disposeBridgeIfIdle();
      case _ReaderNoteEditorFinished():
        if (message.revision == _activeNoteEditorRevision) {
          _activeNoteEditor = null;
          _activeNoteEditorRevision = null;
        }
      case _ReaderAnnotationUpdateCompleted():
        _recordNoteUpdateOutcome(
          message.operationId,
          succeeded: message.changed,
        );
        _annotationUpdateCompleted(message);
      case _ReaderDisposeRequested():
        _disposeRequested();
    }
  }

  void _openRequested(ReaderOpenRequested message) {
    final path = message.path.trim();
    if (path.isEmpty || _closing) return;
    if (_recovering) {
      _recoveryPath = path;
      _recoveryBookId = message.bookId;
      _emit(_model.copyWith(openPath: path, openBookId: message.bookId));
      return;
    }
    if (_bookmarkMutationCancellation != null) {
      _emit(
        _model.copyWith(
          toolError:
              'Bookmark changes are still saving. Try opening again shortly.',
          toolsVisible: true,
        ),
      );
      return;
    }
    if (_model.busy || _model.annotationOperations.isNotEmpty || _suspended) {
      return;
    }

    _recoveryPath = path;
    _recoveryBookId = message.bookId;
    final generation = _model.generation + 1;
    for (final cancellation in _relayoutCancellations) {
      _bridge.cancel(id: cancellation);
    }
    for (final cancellation in _toolCancellations) {
      _bridge.cancel(id: cancellation);
    }
    _layoutRevision += 1;
    _activeRelayoutIntent = null;
    final openLayout = _requestedLayout;
    _failedLayout = null;
    _annotationRevision += 1;
    _releaseModelResources(publish: true);
    late final BigInt cancellation;
    try {
      cancellation = _bridge.createCancellation();
    } on FlutterBridgeError catch (error) {
      _emit(
        _model.copyWith(
          openPath: path,
          openBookId: message.bookId,
          error: _consumeRecoveryNotices(error.message),
          generation: generation,
          relayoutBusy: false,
          relayoutPending: false,
        ),
      );
      return;
    } catch (error) {
      _emit(
        _model.copyWith(
          openPath: path,
          openBookId: message.bookId,
          error: _consumeRecoveryNotices(error.toString()),
          generation: generation,
          relayoutBusy: false,
          relayoutPending: false,
        ),
      );
      return;
    }
    _activeCancellation = cancellation;
    _activeBridgeOperations += 1;
    _emit(
      _model.copyWith(
        openPath: path,
        openBookId: message.bookId,
        document: null,
        unit: 0,
        readingOffset: null,
        pageImage: null,
        error: null,
        selectionSurface: null,
        selectionPhase: ReaderSelectionPhase.idle,
        anchor: null,
        focus: null,
        selectionPointer: null,
        selectionVisualLine: null,
        selectionPreferredX: null,
        savedSelections: const [],
        annotations: const [],
        searchResults: const [],
        bookmarks: const [],
        annotationOperations: const {},
        selectionError: null,
        selectionActionError: null,
        keyboardActionInvocation: false,
        annotationError: null,
        annotationsReady: false,
        searchBusy: false,
        bookmarkBusy: false,
        toolError: null,
        persistenceError: null,
        toolsVisible: false,
        relayoutBusy: false,
        relayoutPending: false,
        contentState: ReaderContentState.loading,
        busy: true,
        generation: generation,
        layout: openLayout,
      ),
    );
    unawaited(
      _openEffect(path, message.bookId, generation, cancellation, openLayout),
    );
  }

  Future<void> _openEffect(
    String path,
    int? bookId,
    int generation,
    BigInt cancellation,
    ReaderLayout layout,
  ) async {
    FlutterDocumentSummary? opened;
    try {
      if (bookId != null) await drainBookWrites(bookId);
      opened = bookId == null
          ? await _bridge.openDocument(
              request: FlutterOpenRequest(localId: path, pathKey: path),
              cancellationId: cancellation,
            )
          : await _bridge.openLibraryBook(
              bookId: bookId,
              cancellationId: cancellation,
            );
      final document = opened;
      FlutterReadingState? restored;
      String? toolError;
      String? restorationError;
      var restorationFailed = false;
      if (bookId != null) {
        try {
          restored = await _bridge.loadReadingState(
            bookId: bookId,
            cancellationId: cancellation,
          );
        } catch (error) {
          restorationFailed = true;
          restorationError = 'Reading position could not be restored: $error';
        }
      }
      final unit = (restored?.unit.toInt() ?? 0).clamp(
        0,
        document.logicalUnitCount.toInt() - 1,
      );
      final restoredLayout = restored == null
          ? layout
          : ReaderLayout(
              scale: restored.zoom,
              width: layout.width,
              fontSize: layout.fontSize,
              lineSpacing: layout.lineSpacing,
            );
      List<FlutterBookmark> bookmarks = const [];
      if (bookId != null) {
        try {
          bookmarks = await _bridge.listBookmarks(
            bookId: bookId,
            cancellationId: cancellation,
          );
        } catch (error) {
          toolError = 'Bookmarks are unavailable: $error';
        }
      }
      dispatch(
        _ReaderDocumentOpened(
          generation: generation,
          document: document,
          unit: unit,
          bookmarks: bookmarks,
          layout: restoredLayout,
          restoredLayout: restored != null,
          restorationFailed: restorationFailed,
          restorationError: restorationError,
          offset: restored?.offset?.toInt(),
          toolError: toolError,
        ),
      );
      opened = null;
      if (!_isCurrent(generation)) return;

      if (document.format != FlutterBookFormat.cbz) {
        FlutterSelectionSurface? effectSurface;
        try {
          final surface = await _bridge.selectionSurface(
            document: document.handle,
            unit: BigInt.from(unit),
            scale: restoredLayout.scale,
            width: restoredLayout.width,
            fontSize: restoredLayout.fontSize,
            lineSpacing: restoredLayout.lineSpacing,
            cancellationId: cancellation,
          );
          effectSurface = surface;
          if (!_isCurrent(generation)) {
            if (surface.raster case final raster?) {
              _bridge.releaseBuffer(handle: raster.handle);
            }
            _releaseSurface(surface);
            effectSurface = null;
            return;
          }
          if (document.format == FlutterBookFormat.epub) {
            final raster = surface.raster;
            if (raster == null) {
              _releaseSurface(surface);
              effectSurface = null;
              throw StateError('EPUB selection surface is missing its raster');
            }
            late final ui.Image image;
            try {
              final pixels = _bridge.takeBuffer(handle: raster.handle);
              premultiplyRgba(pixels);
              image = await _decoder(
                pixels,
                width: raster.width,
                height: raster.height,
              );
            } finally {
              _bridge.releaseBuffer(handle: raster.handle);
            }
            if (!_isCurrent(generation)) {
              image.dispose();
              _releaseSurface(surface);
              effectSurface = null;
              return;
            }
            dispatch(
              _ReaderEpubContentLoaded(
                generation: generation,
                surface: surface,
                pageImage: image,
              ),
            );
            effectSurface = null;
          } else {
            dispatch(
              _ReaderSurfaceLoaded(generation: generation, surface: surface),
            );
            effectSurface = null;
          }
        } catch (error) {
          if (effectSurface case final surface?) _releaseSurface(surface);
          if (!_isCurrent(generation)) return;
          dispatch(_ReaderSelectionSupportFailed(generation, error.toString()));
        }
        final revision = _annotationRevision;
        try {
          final annotations = await _bridge.listAnnotations(
            document: document.handle,
            scale: restoredLayout.scale,
            cancellationId: cancellation,
          );
          if (!_isCurrent(generation)) return;
          dispatch(
            _ReaderAnnotationsChanged(
              generation,
              revision,
              null,
              null,
              annotations,
            ),
          );
        } catch (error) {
          if (!_isCurrent(generation)) return;
          dispatch(
            _ReaderAnnotationListFailed(generation, revision, error.toString()),
          );
        }
      }

      if (document.format != FlutterBookFormat.epub) {
        final rendered = await _bridge.renderPage(
          document: document.handle,
          page: BigInt.from(unit),
          scale: restoredLayout.scale,
          cancellationId: cancellation,
        );
        if (!_isCurrent(generation)) {
          _bridge.releaseBuffer(handle: rendered.handle);
          return;
        }
        late final ui.Image image;
        try {
          final pixels = _bridge.takeBuffer(handle: rendered.handle);
          if (document.format == FlutterBookFormat.cbz) {
            premultiplyRgba(pixels);
          }
          image = await _decoder(
            pixels,
            width: rendered.width,
            height: rendered.height,
          );
        } finally {
          _bridge.releaseBuffer(handle: rendered.handle);
        }
        if (!_isCurrent(generation)) {
          image.dispose();
          return;
        }
        dispatch(_ReaderImageDecoded(generation: generation, pageImage: image));
      }
    } on FlutterBridgeError catch (error) {
      dispatch(
        _ReaderOpenFailed(
          generation: generation,
          document: opened,
          error: error.message,
        ),
      );
      opened = null;
    } catch (error) {
      dispatch(
        _ReaderOpenFailed(
          generation: generation,
          document: opened,
          error: error.toString(),
        ),
      );
      opened = null;
    } finally {
      _bridge.releaseCancellation(id: cancellation);
      dispatch(
        _ReaderOperationFinished(
          generation: generation,
          cancellation: cancellation,
        ),
      );
    }
  }

  void _documentOpened(_ReaderDocumentOpened message) {
    if (!_isCurrent(message.generation)) {
      _bridge.releaseDocument(handle: message.document.handle);
      return;
    }
    final requestedLayout = ReaderLayout(
      scale: message.restoredLayout
          ? message.layout.scale
          : _requestedLayout.scale,
      width: _requestedLayout.width,
      fontSize: _requestedLayout.fontSize,
      lineSpacing: _requestedLayout.lineSpacing,
    );
    _requestedLayout = requestedLayout;
    _readingStatePersistenceBlocked = message.restorationFailed;
    _emit(
      _model.copyWith(
        document: message.document,
        unit: message.unit,
        readingOffset: message.offset,
        bookmarks: message.bookmarks,
        layout: message.layout,
        relayoutPending: requestedLayout != message.layout,
        anchor: message.offset,
        focus: message.offset,
        toolError: message.toolError,
        persistenceError: message.restorationError,
      ),
    );
  }

  void _layoutChanged(ReaderLayout layout) {
    if (!layout.isValid || _closing) return;
    if (_suspended || _recovering) {
      _requestedLayout = layout;
      _failedLayout = null;
      _setRelayoutPending(layout != _model.layout);
      return;
    }
    if (_model.busy) {
      _requestedLayout = layout;
      _failedLayout = null;
      _setRelayoutPending(layout != _model.layout);
      return;
    }
    final document = _model.document;
    if (document == null) {
      _requestedLayout = layout;
      _emit(_model.copyWith(layout: layout, relayoutPending: false));
      return;
    }
    if (layout == _model.layout && _relayoutCancellations.isNotEmpty) {
      _requestedLayout = layout;
      _activeRelayoutIntent = null;
      _failedLayout = null;
      _layoutRevision += 1;
      for (final active in _relayoutCancellations) {
        _bridge.cancel(id: active);
      }
      _emit(
        _model.copyWith(
          relayoutBusy: false,
          relayoutPending: false,
          selectionError: null,
        ),
      );
      return;
    }
    if (_model.annotationOperations.isNotEmpty) {
      _requestedLayout = layout;
      _failedLayout = null;
      _setRelayoutPending(layout != _model.layout);
      return;
    }
    if (_model.contentState != ReaderContentState.ready ||
        document.format == FlutterBookFormat.cbz) {
      _requestedLayout = layout;
      _failedLayout = null;
      _setRelayoutPending(false);
      return;
    }
    if (layout == _requestedLayout || layout == _failedLayout) {
      return;
    }
    _startRelayout(document, layout);
  }

  void _viewportChanged(ReaderLayout observed) {
    final layout = _model.document == null && !_model.busy
        ? observed
        : ReaderLayout(
            scale: _requestedLayout.scale,
            width: observed.width,
            fontSize: observed.fontSize,
            lineSpacing: observed.lineSpacing,
          );
    final document = _model.document;
    final intent = _activeRelayoutIntent;
    final isNavigation =
        intent != null &&
        (intent.unit != _model.unit ||
            intent.offset != null ||
            intent.length != null ||
            intent.replaceReadingOffset);
    if (document != null &&
        _model.relayoutBusy &&
        !isNavigation &&
        layout == _model.layout) {
      _layoutChanged(layout);
      return;
    }
    if (document != null && _model.relayoutBusy && intent != null) {
      _startRelayout(
        document,
        layout,
        unit: intent.unit,
        offset: intent.offset,
        length: intent.length,
        replaceReadingOffset: intent.replaceReadingOffset,
      );
      return;
    }
    _layoutChanged(layout);
  }

  void _setRelayoutPending(bool pending) {
    if (_model.relayoutPending != pending) {
      _emit(_model.copyWith(relayoutPending: pending));
    }
  }

  void _startRelayout(
    FlutterDocumentSummary document,
    ReaderLayout layout, {
    int? unit,
    int? offset,
    int? length,
    bool replaceReadingOffset = false,
  }) {
    final generation = _model.generation;
    final targetUnit = unit ?? _model.unit;
    _requestedLayout = layout;
    late final BigInt cancellation;
    try {
      cancellation = _bridge.createCancellation();
    } catch (error) {
      _failedLayout = layout;
      _emit(
        _model.copyWith(
          relayoutPending: false,
          selectionError: 'Relayout failed: ${error.toString()}',
        ),
      );
      return;
    }
    _failedLayout = null;
    _activeRelayoutIntent = _RelayoutIntent(
      unit: targetUnit,
      offset: offset,
      length: length,
      replaceReadingOffset: replaceReadingOffset,
    );
    for (final active in _relayoutCancellations) {
      _bridge.cancel(id: active);
    }
    final revision = ++_layoutRevision;
    _relayoutCancellations.add(cancellation);
    _activeBridgeOperations += 1;
    final selectionActionError = _model.selectionActionError;
    _selectionCancelled();
    _emit(
      _model.copyWith(
        relayoutBusy: true,
        relayoutPending: false,
        selectionError: null,
        selectionActionError: selectionActionError,
      ),
    );
    unawaited(
      _relayoutEffect(
        document,
        generation,
        revision,
        cancellation,
        targetUnit,
        layout,
        offset: offset,
        length: length,
        replaceReadingOffset: replaceReadingOffset,
      ),
    );
  }

  void _unitRequested(
    int unit, {
    int? offset,
    int? length,
    bool replaceReadingOffset = false,
  }) {
    final document = _model.document;
    if (document == null ||
        unit < 0 ||
        unit >= document.logicalUnitCount.toInt() ||
        (unit == _model.unit && offset == null && !replaceReadingOffset) ||
        _model.busy ||
        _model.relayoutBusy ||
        _model.annotationOperations.isNotEmpty ||
        _closing ||
        _suspended) {
      return;
    }
    _startRelayout(
      document,
      _model.layout,
      unit: unit,
      offset: offset,
      length: length,
      replaceReadingOffset: replaceReadingOffset,
    );
  }

  void _searchRequested(String query) {
    final document = _model.document;
    if (document == null ||
        document.format == FlutterBookFormat.cbz ||
        _closing ||
        _suspended ||
        _recovering) {
      return;
    }
    final revision = ++_searchRevision;
    _searchQuery = query.trim();
    for (final active in _searchCancellations) {
      _bridge.cancel(id: active);
    }
    if (_searchQuery.isEmpty) {
      _emit(_model.copyWith(searchResults: const [], searchBusy: false));
      return;
    }
    late final BigInt cancellation;
    try {
      cancellation = _bridge.createCancellation();
    } catch (error) {
      _emit(_model.copyWith(toolError: error.toString()));
      return;
    }
    _toolCancellations.add(cancellation);
    _searchCancellations.add(cancellation);
    _activeBridgeOperations += 1;
    final generation = _model.generation;
    _emit(_model.copyWith(searchBusy: true, toolError: null));
    unawaited(() async {
      try {
        final results = await _bridge.searchDocument(
          document: document.handle,
          query: _searchQuery,
          cancellationId: cancellation,
        );
        dispatch(_ReaderSearchCompleted(generation, revision, results));
      } catch (error) {
        dispatch(_ReaderSearchFailed(generation, revision, error.toString()));
      } finally {
        dispatch(_ReaderSearchFinished(cancellation));
      }
    }());
  }

  void _bookmarkToggled() {
    final bookId = _model.document?.bookId;
    if (bookId == null ||
        _model.bookmarkBusy ||
        _closing ||
        _suspended ||
        _recovering) {
      return;
    }
    final revision = ++_bookmarkRevision;
    final generation = _model.generation;
    final unit = _model.unit;
    final offset = _model.readingOffset;
    final existing = _model.bookmarks
        .where(
          (bookmark) =>
              bookmark.unit.toInt() == unit &&
              bookmark.offset?.toInt() == offset,
        )
        .firstOrNull;
    _startBookmarkMutation(
      generation: generation,
      revision: revision,
      bookId: bookId,
      mutation: () => existing == null
          ? _bridge.toggleBookmark(
              bookId: bookId,
              unit: BigInt.from(unit),
              offset: offset == null ? null : BigInt.from(offset),
            )
          : _bridge.deleteBookmark(id: existing.id),
    );
  }

  void _bookmarkNoteRequested(FlutterBookmark? bookmark) {
    if (_model.bookmarkBusy || _closing || _suspended || _recovering) return;
    final generation = _model.generation;
    final revision = ++_bookmarkRevision;
    final bookId = _model.document?.bookId;
    final unit = _model.unit;
    final offset = _model.readingOffset;
    if (bookId == null) return;
    _emit(_model.copyWith(bookmarkBusy: true, toolError: null));
    _activeNoteEditor = _ReaderNoteTarget.bookmark;
    _activeNoteEditorRevision = revision;
    unawaited(() async {
      try {
        final note = await _bookmarkNoteEditor(bookmark?.note);
        dispatch(
          _ReaderBookmarkNoteEdited(
            generation: generation,
            revision: revision,
            bookId: bookId,
            unit: unit,
            offset: offset,
            bookmarkId: bookmark?.id,
            note: note,
          ),
        );
      } catch (error) {
        dispatch(
          _ReaderBookmarkNoteEditFailed(generation, revision, error.toString()),
        );
      } finally {
        dispatch(_ReaderNoteEditorFinished(revision));
      }
    }());
  }

  void _bookmarkNoteEdited(_ReaderBookmarkNoteEdited message) {
    if (!_isCurrent(message.generation) ||
        message.revision != _bookmarkRevision) {
      return;
    }
    if (message.note == null) {
      _emit(_model.copyWith(bookmarkBusy: false));
      return;
    }
    _startBookmarkMutation(
      generation: message.generation,
      revision: message.revision,
      bookId: message.bookId,
      mutation: () => message.bookmarkId == null
          ? _bridge.toggleBookmark(
              bookId: message.bookId,
              unit: BigInt.from(message.unit),
              offset: message.offset == null
                  ? null
                  : BigInt.from(message.offset!),
              note: message.note,
            )
          : _bridge.updateBookmarkNote(
              id: message.bookmarkId!,
              note: message.note,
            ),
    );
  }

  void _bookmarkDeleted(int id) {
    final bookId = _model.document?.bookId;
    if (bookId == null || _model.bookmarkBusy || _closing || _suspended) return;
    final generation = _model.generation;
    final revision = ++_bookmarkRevision;
    _startBookmarkMutation(
      generation: generation,
      revision: revision,
      bookId: bookId,
      mutation: () => _bridge.deleteBookmark(id: id),
    );
  }

  void _startBookmarkMutation({
    required int generation,
    required int revision,
    required int bookId,
    required Future<Object?> Function() mutation,
  }) {
    late final BigInt cancellation;
    try {
      cancellation = _bridge.createCancellation();
    } catch (error) {
      _emit(_model.copyWith(bookmarkBusy: false, toolError: error.toString()));
      return;
    }
    _toolCancellations.add(cancellation);
    _bookmarkMutationCancellation = cancellation;
    _activeBridgeOperations += 1;
    _beginBookWrite(bookId);
    _emit(_model.copyWith(bookmarkBusy: true, toolError: null));
    unawaited(() async {
      String? writeError;
      var mutationCommitted = false;
      try {
        await mutation();
        mutationCommitted = true;
        final items = await _bridge.listBookmarks(
          bookId: bookId,
          cancellationId: cancellation,
        );
        dispatch(_ReaderBookmarksCompleted(generation, revision, items));
      } catch (error) {
        if (!mutationCommitted) writeError = error.toString();
        dispatch(
          _ReaderBookmarksFailed(
            generation,
            revision,
            error.toString(),
            persistence: !mutationCommitted,
          ),
        );
      } finally {
        _finishBookWrite(
          bookId,
          failureKind: 'bookmark',
          error: writeError == null
              ? null
              : 'Bookmark changes were not saved: $writeError',
        );
        dispatch(_ReaderBookmarkFinished(cancellation));
      }
    }());
  }

  Future<void> _relayoutEffect(
    FlutterDocumentSummary document,
    int generation,
    int revision,
    BigInt cancellation,
    int unit,
    ReaderLayout layout, {
    int? offset,
    int? length,
    bool replaceReadingOffset = false,
  }) async {
    FlutterSelectionSurface? ownedSurface;
    FlutterBufferHandle? ownedRaster;
    ui.Image? ownedImage;
    try {
      FlutterSelectionSurface? surface;
      String? selectionError;
      if (document.format != FlutterBookFormat.cbz) {
        try {
          surface = await _bridge.selectionSurface(
            document: document.handle,
            unit: BigInt.from(unit),
            scale: layout.scale,
            width: layout.width,
            fontSize: layout.fontSize,
            lineSpacing: layout.lineSpacing,
            cancellationId: cancellation,
          );
          ownedSurface = surface;
          ownedRaster = surface.raster?.handle;
          if (!_isCurrentLayout(generation, revision)) return;
        } catch (error) {
          if (document.format == FlutterBookFormat.epub) rethrow;
          selectionError = error.toString();
        }
      }
      if (document.format == FlutterBookFormat.epub) {
        final raster = surface!.raster;
        if (raster == null) {
          throw StateError('EPUB selection surface is missing its raster');
        }
        try {
          final pixels = _bridge.takeBuffer(handle: raster.handle);
          premultiplyRgba(pixels);
          ownedImage = await _decoder(
            pixels,
            width: raster.width,
            height: raster.height,
          );
        } finally {
          _bridge.releaseBuffer(handle: raster.handle);
          ownedRaster = null;
        }
      } else {
        final rendered = await _bridge.renderPage(
          document: document.handle,
          page: BigInt.from(unit),
          scale: layout.scale,
          cancellationId: cancellation,
        );
        try {
          if (!_isCurrentLayout(generation, revision)) return;
          final pixels = _bridge.takeBuffer(handle: rendered.handle);
          if (document.format == FlutterBookFormat.cbz) {
            premultiplyRgba(pixels);
          }
          ownedImage = await _decoder(
            pixels,
            width: rendered.width,
            height: rendered.height,
          );
        } finally {
          _bridge.releaseBuffer(handle: rendered.handle);
        }
      }
      if (!_isCurrentLayout(generation, revision)) return;
      List<FlutterAnnotation> annotations = const [];
      String? annotationError;
      if (document.format != FlutterBookFormat.cbz) {
        try {
          annotations = await _bridge.listAnnotations(
            document: document.handle,
            scale: layout.scale,
            cancellationId: cancellation,
          );
        } catch (error) {
          annotationError = error.toString();
        }
      }
      if (!_isCurrentLayout(generation, revision)) return;
      dispatch(
        _ReaderRelayoutCompleted(
          generation: generation,
          revision: revision,
          cancellation: cancellation,
          unit: unit,
          layout: layout,
          surface: surface,
          pageImage: ownedImage,
          annotations: annotations,
          offset: offset,
          length: length,
          replaceReadingOffset: replaceReadingOffset,
          selectionError: selectionError,
          annotationError: annotationError,
        ),
      );
      ownedSurface = null;
      ownedImage = null;
    } catch (error) {
      dispatch(
        _ReaderRelayoutFailed(
          generation: generation,
          revision: revision,
          layout: layout,
          error: error.toString(),
        ),
      );
    } finally {
      ownedImage?.dispose();
      if (ownedRaster case final raster?) {
        _bridge.releaseBuffer(handle: raster);
      }
      if (ownedSurface case final surface?) _releaseSurface(surface);
      dispatch(_ReaderRelayoutFinished(cancellation));
    }
  }

  void _relayoutCompleted(_ReaderRelayoutCompleted message) {
    if (!_isCurrentLayout(message.generation, message.revision) ||
        !_relayoutCancellations.contains(message.cancellation)) {
      message.pageImage.dispose();
      if (message.surface case final surface?) _releaseSurface(surface);
      return;
    }
    final oldImage = _model.pageImage;
    final oldSurface = _model.selectionSurface;
    _activeRelayoutIntent = null;
    final changedLocation =
        message.unit != _model.unit ||
        message.offset != null ||
        message.replaceReadingOffset;
    if (changedLocation) _readingStatePersistenceBlocked = false;
    final readingOffset = changedLocation
        ? message.offset
        : _model.readingOffset;
    _emit(
      _model.copyWith(
        unit: message.unit,
        readingOffset: readingOffset,
        pageImage: message.pageImage,
        selectionSurface: message.surface == null
            ? null
            : _freezeSurface(message.surface!),
        annotations: message.annotations,
        savedSelections: _savedSelections(message.annotations, message.unit),
        anchor: message.offset ?? _model.anchor,
        focus: message.offset == null
            ? _model.focus
            : message.offset! + (message.length ?? 0),
        selectionPhase: message.length == null
            ? _model.selectionPhase
            : ReaderSelectionPhase.selected,
        annotationsReady: message.annotationError == null,
        annotationError:
            message.annotationError ??
            (_model.annotationsReady ? _model.annotationError : null),
        layout: message.layout,
        relayoutBusy: false,
        relayoutPending: false,
        selectionError: message.selectionError,
        selectionVisualLine: null,
        selectionPreferredX: null,
      ),
    );
    oldImage?.dispose();
    if (oldSurface != null) _releaseSurface(oldSurface);
    if (message.length != null) {
      _frameScheduler(
        () => dispatch(
          _ReaderSurfaceFocusReady(message.generation, message.revision),
        ),
      );
    }
    final bookId = _model.document?.bookId;
    if (bookId != null) {
      _queueReadingStateSave(
        bookId,
        _model.document!.logicalUnitCount,
        FlutterReadingState(
          unit: BigInt.from(message.unit),
          offset: readingOffset == null ? null : BigInt.from(readingOffset),
          zoom: message.layout.scale,
        ),
      );
    }
  }

  void _queueReadingStateSave(
    int bookId,
    BigInt unitCount,
    FlutterReadingState value,
  ) {
    if (_readingStatePersistenceBlocked) return;
    final generation = _model.generation;
    final revision = ++_readingStateSaveRevision;
    _activeBridgeOperations += 1;
    _beginBookWrite(bookId);
    late final _ReadingStateSaveQueue queue;
    queue = _bookReadingStateSaves.putIfAbsent(
      bookId,
      () => _ReadingStateSaveQueue(() {
        if (identical(_bookReadingStateSaves[bookId], queue)) {
          _bookReadingStateSaves.remove(bookId);
        }
      }),
    );
    queue.add(
      _QueuedReadingStateSave(
        run: () async {
          String? writeError;
          try {
            await _bridge.saveReadingState(
              bookId: bookId,
              value: value,
              unitCount: unitCount,
            );
            dispatch(_ReaderReadingStateSaveSucceeded(generation, revision));
          } catch (error) {
            writeError = error.toString();
            dispatch(
              _ReaderReadingStateSaveFailed(generation, revision, writeError),
            );
          } finally {
            _finishBookWrite(
              bookId,
              failureKind: 'reading-state',
              error: writeError == null
                  ? null
                  : 'Reading position was not saved: $writeError',
              succeeded: writeError == null,
            );
            dispatch(const _ReaderReadingStateSaveFinished());
          }
        },
        discard: () {
          _finishBookWrite(bookId);
          dispatch(const _ReaderReadingStateSaveFinished());
        },
      ),
    );
  }

  bool _isCurrentLayout(int generation, int revision) =>
      _isCurrent(generation) && revision == _layoutRevision;

  void _imageDecoded(_ReaderImageDecoded message) {
    if (!_isCurrent(message.generation)) {
      message.pageImage?.dispose();
      return;
    }
    _emit(
      _model.copyWith(
        pageImage: message.pageImage,
        contentState: ReaderContentState.ready,
      ),
    );
  }

  void _selectionStarted(int offset) {
    if (_model.selectionSurface == null || _model.relayoutBusy || _closing) {
      return;
    }
    _cancelSelectionCreates();
    _selectionRevision += 1;
    _emit(
      _model.copyWith(
        selectionPhase: ReaderSelectionPhase.selecting,
        anchor: offset,
        focus: offset,
        selectionPointer: null,
        selectionVisualLine: null,
        selectionPreferredX: null,
        selectionActionError: null,
        keyboardActionInvocation: false,
      ),
    );
  }

  void _selectionExtended(int offset) {
    if (_model.selectionPhase != ReaderSelectionPhase.selecting) return;
    _emit(_model.copyWith(focus: offset));
  }

  void _selectionPointerStarted(
    int pointer,
    int offset,
    int? rangeStart,
    int? rangeEnd,
    double? x,
    double? y,
  ) {
    final surface = _model.selectionSurface;
    if (surface == null || _model.relayoutBusy || _closing) return;
    if (_model.selectionPointer case final owner? when owner != pointer) return;
    _focusAdapter(ReaderFocusTarget.surface);
    final anchor = _model.anchor;
    final focus = _model.focus;
    if (_model.selectionPhase == ReaderSelectionPhase.selected &&
        anchor != null &&
        focus != null &&
        (rangeStart ?? offset) >= (anchor < focus ? anchor : focus) &&
        (rangeEnd ?? offset) <= (anchor < focus ? focus : anchor)) {
      return;
    }
    final affinity = _caretNear(surface.visualLines, offset, x, y);
    _cancelSelectionCreates();
    _selectionRevision += 1;
    _emit(
      _model.copyWith(
        selectionPhase: ReaderSelectionPhase.selecting,
        anchor: offset,
        focus: offset,
        selectionPointer: pointer,
        selectionVisualLine: affinity?.line,
        selectionPreferredX: affinity?.preferredX,
        selectionActionError: null,
      ),
    );
  }

  void _selectionPointerMoved(int pointer, int offset, double? x, double? y) {
    if (_model.selectionPhase != ReaderSelectionPhase.selecting ||
        _model.selectionPointer != pointer) {
      return;
    }
    final affinity = _caretNear(
      _model.selectionSurface!.visualLines,
      offset,
      x,
      y,
    );
    _emit(
      _model.copyWith(
        focus: offset,
        selectionVisualLine: affinity?.line,
        selectionPreferredX: affinity?.preferredX,
      ),
    );
  }

  void _selectionPointerEnded(int pointer) {
    if (_model.selectionPointer != pointer) return;
    _selectionEnded();
  }

  void _selectionPointerCancelled(int pointer) {
    if (_model.selectionPointer != pointer) return;
    _selectionCancelled();
  }

  void _selectionKeyboardExtended(ReaderSelectionMovement movement) {
    final surface = _model.selectionSurface;
    if (surface == null ||
        surface.graphemeBoundaries.length < 2 ||
        _model.busy ||
        _model.relayoutBusy ||
        _model.relayoutPending ||
        _closing) {
      return;
    }
    final graphemes = surface.graphemeBoundaries.toList(growable: false);

    final forward = switch (movement) {
      ReaderSelectionMovement.nextGrapheme ||
      ReaderSelectionMovement.nextWord ||
      ReaderSelectionMovement.nextLine ||
      ReaderSelectionMovement.lineEnd ||
      ReaderSelectionMovement.visualRight => true,
      _ => false,
    };
    final current = _model.focus;
    final horizontalMove = switch (movement) {
      ReaderSelectionMovement.visualLeft ||
      ReaderSelectionMovement.visualRight => _horizontalCaret(
        surface.visualLines,
        current,
        _model.selectionVisualLine,
        _model.selectionPreferredX,
        movement == ReaderSelectionMovement.visualRight,
      ),
      _ => null,
    };
    final lineMove = switch (movement) {
      ReaderSelectionMovement.previousLine ||
      ReaderSelectionMovement.nextLine => _lineOffset(
        surface.visualLines,
        current,
        _model.selectionVisualLine,
        _model.selectionPreferredX,
        forward,
      ),
      ReaderSelectionMovement.lineStart ||
      ReaderSelectionMovement.lineEnd => _currentLineEdge(
        surface.visualLines,
        current,
        _model.selectionVisualLine,
        forward,
      ),
      _ => null,
    };
    final boundaries = switch (movement) {
      ReaderSelectionMovement.previousWord ||
      ReaderSelectionMovement.nextWord => surface.wordBoundaries.toList(
        growable: false,
      ),
      _ => graphemes,
    };
    final next =
        lineMove?.offset ??
        horizontalMove?.offset ??
        switch (movement) {
          ReaderSelectionMovement.previousGrapheme ||
          ReaderSelectionMovement.nextGrapheme ||
          ReaderSelectionMovement.previousWord ||
          ReaderSelectionMovement.nextWord => _adjacentOffset(
            boundaries,
            current,
            forward,
          ),
          ReaderSelectionMovement.previousLine ||
          ReaderSelectionMovement.nextLine ||
          ReaderSelectionMovement.lineStart ||
          ReaderSelectionMovement.lineEnd ||
          ReaderSelectionMovement.visualLeft ||
          ReaderSelectionMovement.visualRight => null,
        };
    if (next == null) return;
    final anchor =
        _model.anchor ??
        horizontalMove?.origin ??
        (forward ? graphemes.first : graphemes.last);
    final affinity =
        lineMove ??
        (horizontalMove == null
            ? null
            : (
                offset: horizontalMove.offset,
                line: horizontalMove.line,
                preferredX: horizontalMove.preferredX,
              )) ??
        _caretForOffset(surface.visualLines, next, _model.selectionVisualLine);
    final vertical =
        movement == ReaderSelectionMovement.previousLine ||
        movement == ReaderSelectionMovement.nextLine;
    _cancelSelectionCreates();
    _selectionRevision += 1;
    if (anchor == next) {
      _emit(
        _model.copyWith(
          selectionPhase: ReaderSelectionPhase.idle,
          anchor: anchor,
          focus: anchor,
          selectionPointer: null,
          selectionVisualLine: affinity?.line,
          selectionPreferredX: vertical
              ? _model.selectionPreferredX ?? affinity?.preferredX
              : affinity?.preferredX,
          selectionActionError: null,
          keyboardActionInvocation: false,
        ),
      );
      return;
    }
    _emit(
      _model.copyWith(
        selectionPhase: ReaderSelectionPhase.selected,
        anchor: anchor,
        focus: next,
        selectionPointer: null,
        selectionVisualLine: affinity?.line,
        selectionPreferredX: vertical
            ? _model.selectionPreferredX ?? affinity?.preferredX
            : affinity?.preferredX,
        selectionActionError: null,
        keyboardActionInvocation: false,
      ),
    );
  }

  void _selectionEnded() {
    if (_model.selectionPhase != ReaderSelectionPhase.selecting) return;
    final anchor = _model.anchor;
    final focus = _model.focus;
    _emit(
      _model.copyWith(
        selectionPhase: anchor != null && focus != null && anchor != focus
            ? ReaderSelectionPhase.selected
            : ReaderSelectionPhase.idle,
        anchor: anchor,
        focus: focus,
        selectionPointer: null,
        keyboardActionInvocation: false,
      ),
    );
  }

  void _selectionAllRequested() {
    final surface = _model.selectionSurface;
    if (surface == null ||
        surface.graphemeBoundaries.length < 2 ||
        _model.busy ||
        _model.relayoutBusy ||
        _model.relayoutPending ||
        _closing) {
      return;
    }
    final start = surface.graphemeBoundaries.first;
    final end = surface.graphemeBoundaries.last;
    if (start == end) return;
    _cancelSelectionCreates();
    final revision = ++_selectionRevision;
    final generation = _model.generation;
    _emit(
      _model.copyWith(
        selectionPhase: ReaderSelectionPhase.selected,
        anchor: start,
        focus: end,
        selectionPointer: null,
        selectionVisualLine: null,
        selectionPreferredX: null,
        selectionActionError: null,
        keyboardActionInvocation: true,
      ),
    );
    _frameScheduler(
      () => dispatch(_ReaderSelectionActionFocusReady(generation, revision)),
    );
  }

  void _selectionNoteRequested() {
    if (_model.selectionPhase != ReaderSelectionPhase.selected ||
        _model.relayoutBusy ||
        _activeNoteEditor != null) {
      return;
    }
    _emit(_model.copyWith(selectionActionError: null));
    final generation = _model.generation;
    final revision = ++_noteRevision;
    final selectionRevision = _selectionRevision;
    _activeNoteEditor = _ReaderNoteTarget.selection;
    _activeNoteEditorRevision = revision;
    unawaited(() async {
      try {
        final body = await _noteEditor(null);
        if (body != null) {
          dispatch(
            _ReaderSelectionNoteCompleted(
              generation,
              revision,
              selectionRevision,
              body,
            ),
          );
        }
      } catch (error) {
        dispatch(
          _ReaderSelectionEffectFailed(
            generation,
            revision,
            selectionRevision,
            error.toString(),
          ),
        );
      } finally {
        dispatch(_ReaderNoteEditorFinished(revision));
      }
    }());
  }

  void _selectionCopyRequested() {
    final text = _model.selectedText;
    if (_model.selectionPhase != ReaderSelectionPhase.selected ||
        text == null) {
      return;
    }
    _emit(_model.copyWith(selectionActionError: null));
    final generation = _model.generation;
    final revision = ++_noteRevision;
    final selectionRevision = _selectionRevision;
    unawaited(() async {
      try {
        await _selectionCopier(text);
      } catch (error) {
        dispatch(
          _ReaderSelectionEffectFailed(
            generation,
            revision,
            selectionRevision,
            error.toString(),
          ),
        );
      }
    }());
  }

  void _selectionCommitted(FlutterHighlightColor color, String? body) {
    final anchor = _model.anchor;
    final focus = _model.focus;
    if (_model.selectionPhase != ReaderSelectionPhase.selected ||
        anchor == null ||
        focus == null ||
        !_model.annotationsReady ||
        _model.busy ||
        _model.relayoutBusy) {
      return;
    }
    final selection = ReaderSelection(
      anchor < focus ? anchor : focus,
      anchor < focus ? focus : anchor,
    );
    final document = _model.document;
    if (document == null) return;
    final generation = _model.generation;
    final selectionRevision = _selectionRevision;
    if (_model.annotationOperations.isNotEmpty || _closing) return;
    final revision = ++_annotationRevision;
    _noteRevision += 1;
    final operationId = 'create:${++_nextOperationId}';
    late final BigInt cancellation;
    try {
      cancellation = _bridge.createCancellation();
    } catch (error) {
      _emit(_model.copyWith(selectionActionError: error.toString()));
      return;
    }
    _annotationCancellations.add(cancellation);
    if (body != null) _noteCreateCancellations.add(cancellation);
    _selectionCancellations[cancellation] = selectionRevision;
    _activeBridgeOperations += 1;
    final bookId = document.bookId;
    if (bookId != null) _beginBookWrite(bookId);
    _emit(
      _model.copyWith(
        selectionPhase: ReaderSelectionPhase.committing,
        annotationOperations: {operationId},
        selectionActionError: null,
      ),
    );
    unawaited(() async {
      var succeeded = false;
      String? writeError;
      try {
        final created = await _bridge.createAnnotation(
          document: document.handle,
          unit: BigInt.from(_model.unit),
          start: BigInt.from(selection.start),
          end: BigInt.from(selection.end),
          displayScale: _model.layout.scale,
          color: color,
          body: body,
          cancellationId: cancellation,
        );
        succeeded = true;
        if (!_isCurrent(generation)) return;
        dispatch(
          _ReaderAnnotationsChanged(
            generation,
            revision,
            operationId,
            selectionRevision,
            [..._model.annotations, created],
          ),
        );
      } catch (error) {
        writeError = error.toString();
        dispatch(
          _ReaderAnnotationsChanged(
            generation,
            revision,
            operationId,
            selectionRevision,
            null,
            writeError,
          ),
        );
      } finally {
        if (bookId != null) {
          final wasCancelled = _cancelledSelectionCreates.contains(
            selectionRevision,
          );
          _finishBookWrite(
            bookId,
            failureKind: 'annotations',
            error: writeError == null || wasCancelled
                ? null
                : 'Highlight changes were not saved: $writeError',
          );
        }
        dispatch(
          _ReaderAnnotationCreateFinished(cancellation, succeeded: succeeded),
        );
      }
    }());
  }

  void _setAnnotations(
    List<FlutterAnnotation> annotations, {
    bool? annotationsReady,
  }) {
    _emit(
      _model.copyWith(
        annotations: List.unmodifiable(annotations),
        annotationsReady: annotationsReady,
        savedSelections: _savedSelections(annotations, _model.unit),
      ),
    );
  }

  Future<void> _updateAnnotation(
    ReaderAnnotationUpdated message, {
    bool fromNote = false,
  }) async {
    final document = _model.document;
    if (document == null ||
        !_model.annotationsReady ||
        _model.annotationOperations.isNotEmpty ||
        _model.relayoutBusy ||
        _closing) {
      return;
    }
    final generation = _model.generation;
    late final BigInt cancellation;
    String? writeError;
    try {
      cancellation = _bridge.createCancellation();
    } on FlutterBridgeError catch (error) {
      if (_isCurrent(generation)) {
        _emit(_model.copyWith(annotationError: error.message));
      }
      return;
    } catch (error) {
      if (_isCurrent(generation)) {
        _emit(_model.copyWith(annotationError: error.toString()));
      }
      return;
    }
    final revision = ++_annotationRevision;
    final operationId = 'update:${message.id}:${++_nextOperationId}';
    if (fromNote) _noteUpdateOperations.add(operationId);
    _annotationCancellations.add(cancellation);
    _activeBridgeOperations += 1;
    final bookId = document.bookId;
    if (bookId != null) _beginBookWrite(bookId);
    _emit(
      _model.copyWith(
        annotationOperations: {operationId},
        annotationError: null,
      ),
    );
    try {
      final changed = await _bridge.updateAnnotation(
        document: document.handle,
        id: message.id,
        color: message.color,
        body: message.body,
      );
      dispatch(
        _ReaderAnnotationUpdateCompleted(
          generation: generation,
          revision: revision,
          operationId: operationId,
          id: message.id,
          color: message.color,
          body: message.body,
          changed: changed,
        ),
      );
    } catch (error) {
      writeError = error.toString();
      dispatch(
        _ReaderAnnotationsChanged(
          generation,
          revision,
          operationId,
          null,
          null,
          writeError,
        ),
      );
    } finally {
      if (bookId != null) {
        _finishBookWrite(
          bookId,
          failureKind: 'annotations',
          error: writeError == null
              ? null
              : 'Highlight changes were not saved: $writeError',
        );
      }
      _annotationCancellations.remove(cancellation);
      _bridge.releaseCancellation(id: cancellation);
      dispatch(const _ReaderAnnotationOperationFinished());
    }
  }

  void _annotationUpdateCompleted(_ReaderAnnotationUpdateCompleted message) {
    if (!_isCurrent(message.generation)) return;
    final pending = {..._model.annotationOperations}
      ..remove(message.operationId);
    _emit(_model.copyWith(annotationOperations: pending));
    if (message.revision != _annotationRevision) {
      _startRequestedRelayoutIfReady();
      return;
    }
    if (message.changed) {
      _setAnnotations(
        _model.annotations
            .map(
              (annotation) => annotation.id == message.id
                  ? FlutterAnnotation(
                      id: annotation.id,
                      unit: annotation.unit,
                      resolution: annotation.resolution,
                      textRange: annotation.textRange,
                      quote: annotation.quote,
                      rectangles: annotation.rectangles,
                      color: message.color,
                      body: message.body,
                    )
                  : annotation,
            )
            .toList(growable: false),
      );
    }
    _emit(_model.copyWith(annotationError: null));
    _startRequestedRelayoutIfReady();
  }

  Future<void> _deleteAnnotation(String id) async {
    final document = _model.document;
    if (document == null ||
        !_model.annotationsReady ||
        _model.annotationOperations.isNotEmpty ||
        _model.relayoutBusy ||
        _closing) {
      return;
    }
    final generation = _model.generation;
    final revision = ++_annotationRevision;
    final operationId = 'delete:$id:${++_nextOperationId}';
    _activeBridgeOperations += 1;
    final bookId = document.bookId;
    if (bookId != null) _beginBookWrite(bookId);
    _emit(
      _model.copyWith(
        annotationOperations: {operationId},
        annotationError: null,
      ),
    );
    String? writeError;
    try {
      final changed = await _bridge.deleteAnnotation(
        document: document.handle,
        id: id,
      );
      if (!_isCurrent(generation)) return;
      dispatch(
        _ReaderAnnotationsChanged(
          generation,
          revision,
          operationId,
          null,
          changed
              ? _model.annotations.where((item) => item.id != id).toList()
              : _model.annotations,
        ),
      );
    } catch (error) {
      writeError = error.toString();
      dispatch(
        _ReaderAnnotationsChanged(
          generation,
          revision,
          operationId,
          null,
          null,
          writeError,
        ),
      );
    } finally {
      if (bookId != null) {
        _finishBookWrite(
          bookId,
          failureKind: 'annotations',
          error: writeError == null
              ? null
              : 'Highlight changes were not saved: $writeError',
        );
      }
      dispatch(const _ReaderAnnotationOperationFinished());
    }
  }

  void _noteRequested(String id) {
    if (_closing || _activeNoteEditor != null) return;
    final annotation = _model.annotations
        .where((item) => item.id == id)
        .firstOrNull;
    if (annotation == null) return;
    final generation = _model.generation;
    final revision = ++_noteRevision;
    _activeNoteEditor = _ReaderNoteTarget.annotation;
    _activeNoteEditorRevision = revision;
    unawaited(() async {
      try {
        final body = await _noteEditor(annotation.body);
        if (body != null) {
          dispatch(
            _ReaderAnnotationNoteCompleted(generation, revision, id, body),
          );
        }
      } catch (error) {
        dispatch(
          _ReaderAnnotationNoteFailed(generation, revision, error.toString()),
        );
      } finally {
        dispatch(_ReaderNoteEditorFinished(revision));
      }
    }());
  }

  void _noteCompleted(_ReaderAnnotationNoteCompleted message) {
    if (!_isCurrent(message.generation) || message.revision != _noteRevision) {
      return;
    }
    final annotation = _model.annotations
        .where((item) => item.id == message.id)
        .firstOrNull;
    if (annotation == null) return;
    if (_model.relayoutBusy) {
      _emit(
        _model.copyWith(
          annotationError:
              'The note was not saved because the reader layout changed. Try again.',
        ),
      );
      return;
    }
    if (_model.annotationOperations.isNotEmpty) {
      _emit(
        _model.copyWith(
          annotationError:
              'Finish the current highlight change, then save the note again.',
        ),
      );
      return;
    }
    unawaited(
      _updateAnnotation(
        ReaderAnnotationUpdated(
          annotation.id,
          annotation.color,
          message.body.isEmpty ? null : message.body,
        ),
        fromNote: true,
      ),
    );
  }

  void _annotationsChanged(_ReaderAnnotationsChanged message) {
    final operation = message.operationId;
    if (operation != null && message.error != null) {
      _recordNoteUpdateOutcome(operation, succeeded: false);
    }
    if (!_isCurrent(message.generation)) {
      return;
    }
    if (operation != null) {
      final pending = {..._model.annotationOperations}..remove(operation);
      _emit(_model.copyWith(annotationOperations: pending));
    }
    if (message.revision != _annotationRevision) {
      _startRequestedRelayoutIfReady();
      return;
    }
    if (message.items case final items?) {
      _setAnnotations(
        items,
        annotationsReady:
            operation == null ||
                operation.startsWith('reload:') ||
                operation.startsWith('associate:')
            ? true
            : null,
      );
    }
    if (operation == null) return;
    final mutatesAnnotations =
        operation.startsWith('create:') ||
        operation.startsWith('update:') ||
        operation.startsWith('delete:');
    final createsSelection = operation.startsWith('create:');
    final ownsSelection =
        createsSelection && message.selectionRevision == _selectionRevision;
    final wasCancelled = _cancelledSelectionCreates.contains(
      message.selectionRevision,
    );
    _emit(
      _model.copyWith(
        selectionPhase: ownsSelection
            ? (message.error == null
                  ? ReaderSelectionPhase.idle
                  : ReaderSelectionPhase.selected)
            : null,
        anchor: ownsSelection && message.error == null ? null : _unchanged,
        focus: ownsSelection && message.error == null ? null : _unchanged,
        selectionActionError: ownsSelection && message.error != null
            ? message.error
            : ownsSelection
            ? null
            : _unchanged,
        annotationError: message.error == null
            ? null
            : !ownsSelection && !wasCancelled
            ? createsSelection
                  ? 'An earlier highlight could not be saved: ${message.error}'
                  : message.error
            : _unchanged,
        persistenceError:
            mutatesAnnotations && message.error != null && !wasCancelled
            ? 'Highlight changes were not saved: ${message.error}'
            : _unchanged,
      ),
    );
    _startRequestedRelayoutIfReady();
  }

  void _startRequestedRelayoutIfReady() {
    final document = _model.document;
    if (document != null &&
        !_model.busy &&
        !_model.relayoutBusy &&
        _model.annotationOperations.isEmpty &&
        _model.contentState == ReaderContentState.ready &&
        document.format != FlutterBookFormat.cbz &&
        _requestedLayout != _model.layout &&
        _requestedLayout != _failedLayout) {
      _startRelayout(document, _requestedLayout);
    }
  }

  void _navigateAnnotation(String id) {
    final item = _model.annotations.where((item) => item.id == id).firstOrNull;
    if (item == null) return;
    final range = item.textRange;
    final unit = item.unit.toInt();
    if (unit != _model.unit) {
      _unitRequested(
        unit,
        offset: range?.start.toInt(),
        length: range == null ? null : range.end.toInt() - range.start.toInt(),
      );
      return;
    }
    _cancelSelectionCreates();
    _selectionRevision += 1;
    _emit(
      _model.copyWith(
        anchor: range?.start.toInt(),
        focus: range?.end.toInt(),
        selectionPhase: range == null
            ? ReaderSelectionPhase.idle
            : ReaderSelectionPhase.selected,
        selectionPointer: null,
        selectionVisualLine: null,
        selectionPreferredX: null,
        selectionActionError: null,
        keyboardActionInvocation: false,
      ),
    );
    _focusAdapter(ReaderFocusTarget.surface);
  }

  void _associationRequested() {
    final document = _model.document;
    if (document == null ||
        document.format == FlutterBookFormat.cbz ||
        _model.busy ||
        !_model.annotationsReady ||
        _model.annotationOperations.isNotEmpty ||
        _model.relayoutBusy ||
        _associationPickerActive ||
        _closing) {
      return;
    }
    late final BigInt cancellation;
    try {
      cancellation = _bridge.createCancellation();
    } catch (error) {
      _emit(_model.copyWith(annotationError: error.toString()));
      return;
    }
    final generation = _model.generation;
    final revision = ++_annotationRevision;
    final operationId = 'associate:${++_nextOperationId}';
    _annotationCancellations.add(cancellation);
    _activeBridgeOperations += 1;
    _emit(
      _model.copyWith(
        annotationOperations: {operationId},
        annotationError: null,
      ),
    );
    unawaited(
      _loadAssociationSourcesEffect(
        document,
        generation,
        revision,
        operationId,
        cancellation,
        null,
      ),
    );
  }

  void _annotationReloadRequested() {
    final document = _model.document;
    if (document == null ||
        document.format == FlutterBookFormat.cbz ||
        _model.busy ||
        _model.annotationsReady ||
        _model.annotationOperations.isNotEmpty ||
        _model.relayoutBusy ||
        _closing) {
      return;
    }
    late final BigInt cancellation;
    try {
      cancellation = _bridge.createCancellation();
    } catch (error) {
      _emit(_model.copyWith(annotationError: error.toString()));
      return;
    }
    final generation = _model.generation;
    final revision = ++_annotationRevision;
    final operationId = 'reload:${++_nextOperationId}';
    _annotationCancellations.add(cancellation);
    _activeBridgeOperations += 1;
    _emit(
      _model.copyWith(
        annotationOperations: {operationId},
        annotationError: null,
      ),
    );
    unawaited(() async {
      List<FlutterAnnotation>? annotations;
      String? error;
      try {
        annotations = await _bridge.listAnnotations(
          document: document.handle,
          scale: _model.layout.scale,
          cancellationId: cancellation,
        );
      } catch (caught) {
        error = caught.toString();
      }
      if (_annotationCancellations.remove(cancellation)) {
        dispatch(
          _ReaderAnnotationsChanged(
            generation,
            revision,
            operationId,
            null,
            annotations,
            error,
          ),
        );
        _bridge.releaseCancellation(id: cancellation);
        dispatch(const _ReaderAnnotationOperationFinished());
      }
    }());
  }

  Future<void> _loadAssociationSourcesEffect(
    FlutterDocumentSummary document,
    int generation,
    int revision,
    String operationId,
    BigInt cancellation,
    String? cursor,
  ) async {
    try {
      final page = await _bridge.listAnnotationAssociationSources(
        target: document.handle,
        cursor: cursor,
        limit: BigInt.from(32),
        cancellationId: cancellation,
      );
      dispatch(
        _ReaderAssociationSourcesLoaded(
          generation: generation,
          revision: revision,
          operationId: operationId,
          cancellation: cancellation,
          document: document,
          cursor: cursor,
          page: page,
        ),
      );
    } catch (error) {
      dispatch(
        _ReaderAssociationFinished(
          sources: _ReaderAssociationSourcesLoaded(
            generation: generation,
            revision: revision,
            operationId: operationId,
            cancellation: cancellation,
            document: document,
            cursor: cursor,
            page: const FlutterAnnotationAssociationSourcePage(sources: []),
          ),
          error: error.toString(),
        ),
      );
    }
  }

  void _associationSourcesLoaded(_ReaderAssociationSourcesLoaded message) {
    if (!_isCurrentAssociation(message)) {
      dispatch(_ReaderAssociationFinished(sources: message));
      return;
    }
    if (message.page.sources.isEmpty) {
      dispatch(
        _ReaderAssociationFinished(
          sources: message,
          error: 'No saved highlights are available to associate.',
        ),
      );
      return;
    }
    _associationPickerActive = true;
    unawaited(() async {
      AnnotationAssociationChoice? choice;
      String? error;
      try {
        choice = await _annotationAssociationPicker(
          AnnotationAssociationPage(
            sources: message.page.sources,
            canGoBack: message.cursor != null,
            canGoForward: message.page.nextCursor != null,
          ),
        );
      } catch (caught) {
        error = caught.toString();
      }
      dispatch(
        _ReaderAssociationChoiceCompleted(
          sources: message,
          choice: choice,
          error: error,
        ),
      );
    }());
  }

  void _associationChoiceCompleted(_ReaderAssociationChoiceCompleted message) {
    final sources = message.sources;
    if (!_isCurrentAssociation(sources)) {
      dispatch(_ReaderAssociationFinished(sources: sources));
      return;
    }
    _associationPickerActive = false;
    if (message.error case final error?) {
      dispatch(_ReaderAssociationFinished(sources: sources, error: error));
      return;
    }
    switch (message.choice) {
      case AnnotationAssociationSelected(:final source):
        unawaited(_associateAnnotationVersionEffect(sources, source));
      case AnnotationAssociationNextPage():
        final cursor = sources.page.nextCursor;
        if (cursor == null) {
          dispatch(_ReaderAssociationFinished(sources: sources));
          return;
        }
        unawaited(
          _loadAssociationSourcesEffect(
            sources.document,
            sources.generation,
            sources.revision,
            sources.operationId,
            sources.cancellation,
            cursor,
          ),
        );
      case AnnotationAssociationPreviousPage():
        if (sources.cursor == null) {
          dispatch(_ReaderAssociationFinished(sources: sources));
          return;
        }
        unawaited(
          _loadAssociationSourcesEffect(
            sources.document,
            sources.generation,
            sources.revision,
            sources.operationId,
            sources.cancellation,
            sources.page.previousCursor,
          ),
        );
      case AnnotationAssociationCancelled() || null:
        dispatch(
          _ReaderAssociationFinished(
            sources: sources,
            items: _model.annotations,
          ),
        );
    }
  }

  Future<void> _associateAnnotationVersionEffect(
    _ReaderAssociationSourcesLoaded sources,
    FlutterAnnotationAssociationSource selected,
  ) async {
    final bookId = sources.document.bookId;
    if (bookId != null) _beginBookWrite(bookId);
    String? writeError;
    try {
      final outcome = await _bridge.associateAnnotationVersion(
        sourceVersionId: selected.versionId,
        target: sources.document.handle,
        cancellationId: sources.cancellation,
      );
      dispatch(_ReaderAssociationPersisted(sources: sources, outcome: outcome));
    } catch (error) {
      writeError = error.toString();
      if (_isCurrentAssociation(sources)) {
        _emit(
          _model.copyWith(
            persistenceError:
                'Highlight association was not saved: $writeError',
          ),
        );
      }
      dispatch(_ReaderAssociationFinished(sources: sources, error: writeError));
    } finally {
      if (bookId != null) {
        _finishBookWrite(
          bookId,
          failureKind: 'association',
          error: writeError == null
              ? null
              : 'Highlight association was not saved: $writeError',
        );
      }
    }
  }

  void _associationPersisted(_ReaderAssociationPersisted message) {
    final sources = message.sources;
    if (!_isCurrentAssociation(sources)) {
      dispatch(_ReaderAssociationFinished(sources: sources));
      return;
    }
    switch (message.outcome) {
      case FlutterAnnotationAssociationOutcome.associated ||
          FlutterAnnotationAssociationOutcome.alreadyAssociated:
        _setAnnotations(const [], annotationsReady: false);
        unawaited(_reloadAssociatedAnnotationsEffect(sources));
    }
  }

  Future<void> _reloadAssociatedAnnotationsEffect(
    _ReaderAssociationSourcesLoaded sources,
  ) async {
    try {
      final annotations = await _bridge.listAnnotations(
        document: sources.document.handle,
        scale: _model.layout.scale,
        cancellationId: sources.cancellation,
      );
      dispatch(
        _ReaderAssociationFinished(sources: sources, items: annotations),
      );
    } catch (error) {
      dispatch(
        _ReaderAssociationFinished(
          sources: sources,
          error:
              'Association saved, but highlights could not be loaded: $error',
        ),
      );
    }
  }

  void _associationFinished(_ReaderAssociationFinished message) {
    final sources = message.sources;
    if (_annotationCancellations.remove(sources.cancellation)) {
      dispatch(
        _ReaderAnnotationsChanged(
          sources.generation,
          sources.revision,
          sources.operationId,
          null,
          message.items,
          message.error,
        ),
      );
      _bridge.releaseCancellation(id: sources.cancellation);
      dispatch(const _ReaderAnnotationOperationFinished());
    }
  }

  bool _isCurrentAssociation(_ReaderAssociationSourcesLoaded message) =>
      _isCurrent(message.generation) &&
      message.revision == _annotationRevision &&
      _model.annotationOperations.contains(message.operationId) &&
      _annotationCancellations.contains(message.cancellation);

  void _selectionCancelled() {
    _cancelSelectionCreates();
    _selectionRevision += 1;
    _emit(
      _model.copyWith(
        selectionPhase: ReaderSelectionPhase.idle,
        anchor: null,
        focus: null,
        selectionPointer: null,
        selectionVisualLine: null,
        selectionPreferredX: null,
        selectionActionError: null,
        keyboardActionInvocation: false,
      ),
    );
    _focusAdapter(ReaderFocusTarget.surface);
  }

  void _cancelSelectionCreates() {
    for (final entry in _selectionCancellations.entries) {
      if (entry.value == _selectionRevision) {
        _cancelledSelectionCreates.add(entry.value);
        _bridge.cancel(id: entry.key);
      }
    }
  }

  void _openFailed(_ReaderOpenFailed message) {
    final opened = message.document;
    if (opened != null) {
      _bridge.releaseDocument(handle: opened.handle);
    }
    if (_isCurrent(message.generation)) {
      _releaseModelResources();
      _emit(
        _model.copyWith(
          document: null,
          pageImage: null,
          contentState: ReaderContentState.failed,
          error: _consumeRecoveryNotices(message.error),
        ),
      );
    }
  }

  void _operationFinished(_ReaderOperationFinished message) {
    if (_activeCancellation == message.cancellation) {
      _activeCancellation = null;
    }
    if (_isCurrent(message.generation)) {
      final recovered = _model.document != null;
      final selectionNotice = recovered ? _recoverySelectionNotice : null;
      final annotationsRecovered = recovered && _model.annotationsReady;
      final annotationNotice = annotationsRecovered
          ? _recoveryAnnotationNotice
          : null;
      final recoveryError = recovered && !annotationsRecovered
          ? _recoveryAnnotationNotice
          : null;
      if (recovered) {
        _recoverySelectionNotice = null;
        _recoveryAnnotationNotice = null;
      }
      _emit(
        _model.copyWith(
          busy: false,
          selectionActionError: selectionNotice ?? _model.selectionActionError,
          annotationError: annotationNotice ?? _model.annotationError,
          error: recoveryError == null
              ? _unchanged
              : [?_model.error, recoveryError].join('\n'),
        ),
      );
      _startRequestedRelayoutIfReady();
    }
    _activeBridgeOperations -= 1;
    _recoverIfIdle();
    _disposeBridgeIfIdle();
  }

  void _suspendRequested() {
    if (_suspended || _closing) return;
    _suspended = true;
    if (_model.document == null && !_model.busy) return;
    final bookmarkNotice = _activeNoteEditor == _ReaderNoteTarget.bookmark
        ? 'The bookmark note was not saved because the app was suspended. Try again.'
        : _model.toolError;
    switch (_activeNoteEditor) {
      case _ReaderNoteTarget.selection:
        _recoverySelectionNotice =
            'The note was not saved because the app was suspended. Try again.';
      case _ReaderNoteTarget.annotation:
        _recoveryAnnotationNotice =
            'The note was not saved because the app was suspended. Try again.';
      case _ReaderNoteTarget.bookmark:
      case null:
        break;
    }
    _cancelActiveNoteEditor();
    _cancelAssociationPicker();
    _releaseForRecovery = true;
    _reopenForRecovery = true;
    _interruptedNoteCreates.addAll(_noteCreateCancellations);
    _interruptedNoteUpdates.addAll(_noteUpdateOperations);
    final cancellation = _activeCancellation;
    if (cancellation != null) _bridge.cancel(id: cancellation);
    for (final cancellation in _annotationCancellations) {
      _bridge.cancel(id: cancellation);
    }
    for (final cancellation in _relayoutCancellations) {
      _bridge.cancel(id: cancellation);
    }
    for (final cancellation in _toolCancellations) {
      _bridge.cancel(id: cancellation);
    }
    _layoutRevision += 1;
    _annotationRevision += 1;
    _selectionRevision += 1;
    _noteRevision += 1;
    _searchRevision += 1;
    _bookmarkRevision += 1;
    _emit(
      _model.copyWith(
        busy: true,
        relayoutBusy: false,
        relayoutPending: false,
        searchBusy: false,
        bookmarkBusy: false,
        toolError: bookmarkNotice,
        annotationOperations: const {},
        selectionPhase: ReaderSelectionPhase.idle,
        anchor: null,
        focus: null,
        selectionPointer: null,
        selectionVisualLine: null,
        selectionPreferredX: null,
        keyboardActionInvocation: false,
        generation: _model.generation + 1,
      ),
    );
    _recoverIfIdle();
  }

  void _resumeRequested() {
    if (!_suspended || _closing) return;
    _suspended = false;
    _recoverIfIdle();
  }

  void _memoryPressureReceived() {
    if (_closing || _recoveryPath == null) return;
    if (_suspended) {
      _reopenForRecovery = true;
      _recoverIfIdle();
      return;
    }
    _suspendRequested();
    _resumeRequested();
  }

  void _recoverIfIdle() {
    if (_activeBridgeOperations != 0 || _closing) return;
    if (_releaseForRecovery) {
      _releaseForRecovery = false;
      _releaseModelResources(publish: true);
      _emit(
        _model.copyWith(
          document: null,
          pageImage: null,
          selectionSurface: null,
          savedSelections: const [],
          annotations: const [],
          annotationsReady: false,
          contentState: ReaderContentState.loading,
          error: null,
          busy: false,
        ),
      );
    }
    final path = _recoveryPath;
    if (!_suspended && _reopenForRecovery && path != null) {
      _reopenForRecovery = false;
      _openRequested(ReaderOpenRequested(path, bookId: _recoveryBookId));
    }
  }

  bool _isCurrent(int generation) {
    return !_closing && generation == _model.generation;
  }

  void _emit(ReaderModel model, {bool notifyListeners = true}) {
    final selectionChanged =
        _model.selectionDescription != model.selectionDescription;
    _model = model;
    if (!_closing && selectionChanged && _selectionAnnouncer != null) {
      unawaited(_announceSelection(model.selectionDescription));
    }
    if (notifyListeners && !_listenersDisposed) {
      for (final listener in _listeners.toList(growable: false)) {
        try {
          listener();
        } catch (error, stackTrace) {
          scheduleMicrotask(
            () => FlutterError.reportError(
              FlutterErrorDetails(
                exception: error,
                stack: stackTrace,
                library: 'shosai_flutter',
              ),
            ),
          );
        }
      }
    }
  }

  Future<void> _announceSelection(String description) async {
    try {
      await _selectionAnnouncer!(description);
    } catch (error, stackTrace) {
      if (!_closing) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stackTrace,
            library: 'shosai_flutter',
          ),
        );
      }
    }
  }

  void _releaseModelResources({bool publish = false}) {
    final pageImage = _model.pageImage;
    final document = _model.document;
    final surface = _model.selectionSurface;
    final released = _model.copyWith(
      document: null,
      pageImage: null,
      selectionSurface: null,
      selectionPhase: ReaderSelectionPhase.idle,
      anchor: null,
      focus: null,
      selectionPointer: null,
      selectionVisualLine: null,
      selectionPreferredX: null,
    );
    if (publish) {
      _emit(released, notifyListeners: false);
    } else {
      _model = released;
    }
    pageImage?.dispose();
    if (surface != null) _releaseSurface(surface);
    if (document != null) {
      _bridge.releaseDocument(handle: document.handle);
    }
  }

  void _releaseSurface(FlutterSelectionSurface surface) {
    _bridge.releaseSelection(handle: surface.handle);
  }

  void _disposeRequested() {
    if (_closing) return;
    _closing = true;
    _cancelActiveNoteEditor();
    _cancelAssociationPicker();
    final cancellation = _activeCancellation;
    if (cancellation != null) {
      _bridge.cancel(id: cancellation);
    }
    for (final cancellation in _annotationCancellations) {
      _bridge.cancel(id: cancellation);
    }
    for (final cancellation in _relayoutCancellations) {
      _bridge.cancel(id: cancellation);
    }
    for (final cancellation in _toolCancellations) {
      _bridge.cancel(id: cancellation);
    }
    _searchRevision += 1;
    _bookmarkRevision += 1;
    _model = _model.copyWith(busy: false, generation: _model.generation + 1);
    _disposeBridgeIfIdle();
  }

  void _cancelActiveNoteEditor() {
    if (_activeNoteEditor == null) return;
    _activeNoteEditor = null;
    _activeNoteEditorRevision = null;
    try {
      _noteEditorCanceller();
    } catch (error, stackTrace) {
      scheduleMicrotask(
        () => FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stackTrace,
            library: 'shosai_flutter',
          ),
        ),
      );
    }
  }

  void _cancelAssociationPicker() {
    if (!_associationPickerActive) return;
    _associationPickerActive = false;
    try {
      _annotationAssociationPickerCanceller();
    } catch (error, stackTrace) {
      scheduleMicrotask(
        () => FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stackTrace,
            library: 'shosai_flutter',
          ),
        ),
      );
    }
  }

  void _recordNoteUpdateOutcome(String operationId, {required bool succeeded}) {
    _noteUpdateOperations.remove(operationId);
    final interrupted = _interruptedNoteUpdates.remove(operationId);
    if (interrupted && !succeeded) {
      _recoveryAnnotationNotice =
          'The note could not be saved while the app was suspended. Try again.';
    }
  }

  String _consumeRecoveryNotices(String error) {
    final notices = [?_recoverySelectionNotice, ?_recoveryAnnotationNotice];
    _recoverySelectionNotice = null;
    _recoveryAnnotationNotice = null;
    return notices.isEmpty ? error : '$error\n${notices.join('\n')}';
  }

  void _disposeBridgeIfIdle() {
    if (_closing && _activeBridgeOperations == 0 && !_bridge.isDisposed) {
      _releaseModelResources();
      _bridge.dispose();
    }
    if (_closing && _activeBridgeOperations == 0 && !_listenersDisposed) {
      _listenersDisposed = true;
      _listeners.clear();
    }
  }

  void dispose() {
    dispatch(const _ReaderDisposeRequested());
  }
}

int? _adjacentOffset(List<int> offsets, int? current, bool forward) {
  if (current == null) {
    return forward ? offsets[1] : offsets[offsets.length - 2];
  }
  if (forward) {
    for (final offset in offsets) {
      if (offset > current) return offset;
    }
  } else {
    for (final offset in offsets.reversed) {
      if (offset < current) return offset;
    }
  }
  return null;
}

({int offset, int origin, int line, double preferredX})? _horizontalCaret(
  List<FlutterSelectionVisualLine> lines,
  int? current,
  int? currentLine,
  double? currentX,
  bool right,
) {
  if (lines.isEmpty) return null;
  var line = currentLine;
  var index = -1;
  if (current != null) {
    final candidateLines = <int>[
      if (line != null && line >= 0 && line < lines.length) line,
      for (var candidate = 0; candidate < lines.length; candidate += 1)
        if (candidate != line) candidate,
    ];
    for (final candidateLine in candidateLines) {
      final carets = lines[candidateLine].carets;
      for (var candidate = 0; candidate < carets.length; candidate += 1) {
        if (carets[candidate].offset.toInt() != current) continue;
        if (index < 0 ||
            (currentX != null &&
                (carets[candidate].alongLine - currentX).abs() <
                    (carets[index].alongLine - currentX).abs())) {
          line = candidateLine;
          index = candidate;
        }
      }
      if (index >= 0) break;
    }
  } else {
    line = _navigableLine(lines, right);
    if (line == null) return null;
    index = right ? 0 : lines[line].carets.length - 1;
  }
  if (line == null || index < 0) return null;
  final carets = lines[line].carets;
  final destination = index + (right ? 1 : -1);
  final origin = carets[index];
  FlutterSelectionCaret next;
  var destinationLine = line;
  if (destination >= 0 && destination < carets.length) {
    next = carets[destination];
  } else {
    do {
      destinationLine += right ? 1 : -1;
      if (destinationLine < 0 || destinationLine >= lines.length) return null;
    } while (lines[destinationLine].carets.isEmpty);
    final destinationCarets = lines[destinationLine].carets;
    next = right ? destinationCarets.first : destinationCarets.last;
  }
  return (
    offset: next.offset.toInt(),
    origin: origin.offset.toInt(),
    line: destinationLine,
    preferredX: next.alongLine,
  );
}

({int offset, int line, double preferredX})? _lineOffset(
  List<FlutterSelectionVisualLine> lines,
  int? current,
  int? currentLine,
  double? preferredX,
  bool forward,
) {
  if (lines.isEmpty) return null;
  final originLine = _navigableLine(lines, forward);
  final origin = current == null
      ? originLine == null
            ? null
            : _lineEdge(lines, originLine, forward)
      : _caretForOffset(lines, current, currentLine);
  if (origin == null) return null;
  var destinationLine = origin.line;
  do {
    destinationLine += forward ? 1 : -1;
    if (destinationLine < 0 || destinationLine >= lines.length) return null;
  } while (lines[destinationLine].carets.isEmpty);
  final carets = lines[destinationLine].carets;
  final targetX = preferredX ?? origin.preferredX;
  final caret = carets.reduce(
    (best, candidate) =>
        (candidate.alongLine - targetX).abs() < (best.alongLine - targetX).abs()
        ? candidate
        : best,
  );
  return (
    offset: caret.offset.toInt(),
    line: destinationLine,
    preferredX: targetX,
  );
}

({int offset, int line, double preferredX})? _currentLineEdge(
  List<FlutterSelectionVisualLine> lines,
  int? current,
  int? currentLine,
  bool forward,
) {
  if (lines.isEmpty) return null;
  if (current == null) {
    final line = _navigableLine(lines, forward);
    return line == null ? null : _lineEdge(lines, line, !forward);
  }
  final origin = _caretForOffset(lines, current, currentLine);
  if (origin == null) return null;
  return _lineEdge(lines, origin.line, !forward);
}

int? _navigableLine(List<FlutterSelectionVisualLine> lines, bool forward) {
  final indexes = forward
      ? Iterable<int>.generate(lines.length)
      : Iterable<int>.generate(
          lines.length,
          (index) => lines.length - index - 1,
        );
  for (final index in indexes) {
    if (lines[index].carets.isNotEmpty) return index;
  }
  return null;
}

({int offset, int line, double preferredX})? _caretForOffset(
  List<FlutterSelectionVisualLine> lines,
  int offset,
  int? preferredLine,
) {
  if (preferredLine != null &&
      preferredLine >= 0 &&
      preferredLine < lines.length) {
    for (final caret in lines[preferredLine].carets) {
      if (caret.offset.toInt() == offset) {
        return (
          offset: offset,
          line: preferredLine,
          preferredX: caret.alongLine,
        );
      }
    }
  }
  for (var line = 0; line < lines.length; line += 1) {
    for (final caret in lines[line].carets) {
      if (caret.offset.toInt() == offset) {
        return (offset: offset, line: line, preferredX: caret.alongLine);
      }
    }
  }
  return null;
}

({int offset, int line, double preferredX})? _caretNear(
  List<FlutterSelectionVisualLine> lines,
  int offset,
  double? x,
  double? y,
) {
  if (x == null || y == null) return _caretForOffset(lines, offset, null);
  ({int offset, int line, double preferredX})? best;
  double? bestDistance;
  for (var line = 0; line < lines.length; line += 1) {
    for (final caret in lines[line].carets) {
      if (caret.offset.toInt() != offset) continue;
      final dy = caret.vertical
          ? caret.alongLine - y
          : y.clamp(caret.top, caret.bottom) - y;
      final dx = caret.x - x;
      final distance = dx * dx + dy * dy;
      if (bestDistance == null || distance < bestDistance) {
        best = (offset: offset, line: line, preferredX: caret.alongLine);
        bestDistance = distance;
      }
    }
  }
  return best;
}

({int offset, int line, double preferredX})? _lineEdge(
  List<FlutterSelectionVisualLine> lines,
  int line,
  bool forward,
) {
  final carets = lines[line].carets;
  if (carets.isEmpty) return null;
  final caret = forward ? carets.first : carets.last;
  return (
    offset: caret.offset.toInt(),
    line: line,
    preferredX: caret.alongLine,
  );
}

List<ReaderSelection> _savedSelections(
  List<FlutterAnnotation> annotations,
  int unit,
) => List.unmodifiable(
  annotations
      .where((item) => item.unit.toInt() == unit && item.textRange != null)
      .map((item) {
        final range = item.textRange!;
        return ReaderSelection(
          range.start.toInt(),
          range.end.toInt(),
          item.color,
        );
      }),
);

FlutterSelectionSurface _freezeSurface(FlutterSelectionSurface surface) {
  if (_frozenSurfaces[surface] ?? false) return surface;
  final frozen = FlutterSelectionSurface(
    handle: surface.handle,
    width: surface.width,
    height: surface.height,
    text: surface.text,
    copyEligible: surface.copyEligible,
    resourcePath: surface.resourcePath,
    raster: surface.raster,
    endpoints: List.unmodifiable(surface.endpoints),
    graphemeBoundaries: Uint32List.fromList(
      surface.graphemeBoundaries.toList(growable: false),
    ).asUnmodifiableView(),
    wordBoundaries: Uint32List.fromList(
      surface.wordBoundaries.toList(growable: false),
    ).asUnmodifiableView(),
    visualLines: List.unmodifiable(
      surface.visualLines.map(
        (line) =>
            FlutterSelectionVisualLine(carets: List.unmodifiable(line.carets)),
      ),
    ),
  );
  _frozenSurfaces[frozen] = true;
  return frozen;
}

FlutterAnnotation _freezeAnnotation(FlutterAnnotation annotation) {
  if (_frozenAnnotations[annotation] ?? false) return annotation;
  final frozen = FlutterAnnotation(
    id: annotation.id,
    unit: annotation.unit,
    resolution: annotation.resolution,
    textRange: annotation.textRange,
    quote: annotation.quote,
    rectangles: annotation.rectangles == null
        ? null
        : List.unmodifiable(annotation.rectangles!),
    color: annotation.color,
    body: annotation.body,
  );
  _frozenAnnotations[frozen] = true;
  return frozen;
}

Uint8List premultiplyRgba(Uint8List pixels) {
  for (var offset = 0; offset < pixels.length; offset += 4) {
    final alpha = pixels[offset + 3];
    pixels[offset] = (pixels[offset] * alpha + 127) ~/ 255;
    pixels[offset + 1] = (pixels[offset + 1] * alpha + 127) ~/ 255;
    pixels[offset + 2] = (pixels[offset + 2] * alpha + 127) ~/ 255;
  }
  return pixels;
}
