import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart'
    show FlutterError, FlutterErrorDetails, Listenable, VoidCallback;
import 'package:shosai_epub/shosai_epub.dart';
import 'package:shosai_flutter/app_theme.dart'
    show shosaiJapaneseInterfaceFontFamily;
import 'package:shosai_flutter/core/reader_text.dart';
import 'package:shosai_flutter/core/records.dart';
import 'package:shosai_flutter/notices/notice.dart';
import 'package:shosai_flutter/notices/policy.dart';
import 'package:shosai_flutter/notices/reader_notice_text.dart';
import 'package:shosai_flutter/reader/epub/content.dart';
import 'package:shosai_flutter/reader/epub/continuous.dart';
import 'package:shosai_flutter/reader/epub/flow.dart';
import 'package:shosai_flutter/reader/epub/pages.dart';
import 'package:shosai_flutter/reader/epub/text_style.dart';
import 'package:shosai_flutter/core/bridge.dart';
import 'package:shosai_flutter/theme_tokens.dart';

import 'pdf/engine.dart';
import 'pdf/pdfrx_engine.dart';
import 'pdf/spread.dart';

part 'effects.dart';
part 'message.dart';
part 'model.dart';

final class ReaderController implements Listenable {
  ReaderController({
    required FlutterBridge bridge,
    required PageDecoder decoder,
    PdfEngine? pdfEngine,
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
    ReaderNavigationAdapter? navigationAdapter,
    ReaderProgressSource? progressSource,
    ReaderContentsLoader? contentsLoader,
    ReaderExternalLinkOpener? externalLinkOpener,
    ReaderDocumentPickerAdapter? documentPickerAdapter,
    ReaderExportSink? exportSink,
    ReaderNoticeReporter? noticeReporter,
    EpubImageDecoder? epubImageDecoder,
    EpubFontRegistrar? epubFontRegistrar,
    this.debugEpubSessionObserver,
    this.debugContinuousStepObserver,
    ReaderTypographyPresentation initialTypography =
        const ReaderTypographyPresentation(
          format: FlutterBookFormat.epub,
          continuous: false,
          theme: 'light',
          epubFontSize: 18,
          epubLineSpacing: 1.5,
          rasterFit: ReaderRasterFit.fitPage,
          rasterZoom: 1,
        ),
    double? baseScale,
  }) : _bridge = bridge,
       _records = recordsOf(bridge),
       _decoder = decoder,
       // The PDF engine is the reader's own; a bridge that is also an engine
       // (the test fakes) serves both so a fixture bridge keeps one seam.
       _pdfEngine =
           pdfEngine ??
           (bridge is PdfEngine ? bridge as PdfEngine : PdfrxPdfEngine()),
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
       _navigationAdapter = navigationAdapter ?? (() async {}),
       _progressSource = progressSource,
       _contentsLoader = contentsLoader,
       _externalLinkOpener = externalLinkOpener ?? ((_) async {}),
       _documentPickerAdapter = documentPickerAdapter ?? (() async => null),
       _exportSink = exportSink ?? ((_) async {}),
       _reportNotice = noticeReporter ?? ignoreNotice,
       _epubImageDecoder = epubImageDecoder ?? _noEpubImage,
       _epubFontRegistrar = epubFontRegistrar ?? _noEpubFont,
       _typographyFontSize = initialTypography.epubFontSize,
       _typographyLineSpacing = initialTypography.epubLineSpacing,
       _typographyTheme = initialTypography.theme,
       _typographyContinuous = initialTypography.continuous,
       _typographyTwoPages = initialTypography.twoPages,
       _rasterFit = initialTypography.rasterFit,
       _rasterZoom = initialTypography.rasterZoom,
       _baseScale = baseScale ?? initialTypography.rasterZoom,
       _requestedLayout = ReaderLayout(
         scale: initialScale,
         lineSpacing: initialLineSpacing,
       ) {
    _model = ReaderModel(typography: initialTypography);
  }

  final FlutterBridge _bridge;

  /// Books, reading state, bookmarks, annotations and book search, served
  /// beside [_bridge].
  final ShosaiRecords _records;
  final PageDecoder _decoder;
  final PdfEngine _pdfEngine;

  /// The engine document behind the current PDF, owned with the model's
  /// document summary: opened by the open effect, released with the model's
  /// resources.
  PdfEngineDocument? _pdfDocument;
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
  final ReaderNavigationAdapter _navigationAdapter;
  final ReaderProgressSource? _progressSource;
  final ReaderContentsLoader? _contentsLoader;
  final ReaderExternalLinkOpener _externalLinkOpener;
  final ReaderDocumentPickerAdapter _documentPickerAdapter;
  final ReaderExportSink _exportSink;
  final ReaderNoticeReporter _reportNotice;
  final EpubImageDecoder _epubImageDecoder;
  final EpubFontRegistrar _epubFontRegistrar;

  /// Test-only observer for the chapter sessions this controller creates.
  ///
  /// A session's native text painters are the layout's retained resource, so a
  /// test that asserts ownership (a superseded session is released, a painted
  /// one is not) needs to reach the session object itself.
  final void Function(ChapterLayoutSession session)? debugEpubSessionObserver;

  /// Test and measurement hook: the synchronous microseconds of each
  /// continuous window step (layout, geometry and page derivation).
  final void Function(int micros)? debugContinuousStepObserver;

  ReaderModel _model = ReaderModel();

  /// The last content-box height the view reported, or null before the first
  /// report. EPUB pages are paginated for it, so an EPUB waits for the first
  /// report.
  double? _epubViewportHeight;

  /// The parsed EPUB source for the current document generation, and the
  /// generation it belongs to.
  EpubContentSource? _epubSource;
  int? _epubSourceGeneration;

  /// The in-flight load for [_epubSourceGeneration].
  Future<EpubContentSource>? _epubSourceLoad;

  /// The bridge cancellation owned by the in-flight source load.
  ///
  /// The load is shared by concurrent relayouts and Contents requests, so an
  /// individual request's supersession must not cancel it: its token belongs to
  /// the controller and is cancelled only when the document is replaced,
  /// suspended or released.
  BigInt? _epubSourceCancellation;

  /// The controller-owned chapter layout session of the Dart EPUB renderer,
  /// its layout key, and the page height it was laid out for.
  ChapterLayoutSession? _epubSession;
  _EpubLayoutKey? _epubSessionKey;
  double? _epubLayoutHeight;

  /// The column extents of the continuous chapter at [_continuousExtentsKey].
  ///
  /// Keyed by layout rather than by session: a navigation that replaces the
  /// session keeps the chapter's measured column, so its nodes keep their
  /// places.
  ContinuousExtents? _continuousExtents;
  _EpubLayoutKey? _continuousExtentsKey;

  /// The per-node geometry of each continuous session's window.
  final Expando<ContinuousGeometryCache> _continuousCaches = Expando();

  /// The column region the continuous view last reported showing, for the
  /// location request it answers; null until the view reports one.
  ({double top, double bottom})? _continuousViewport;

  /// The pending window step, if any, and the layout it was scheduled for: a
  /// step is one bounded batch per frame.
  int _continuousTickToken = 0;
  ({int generation, int revision})? _continuousTickFor;

  /// Blocks a window step released whose page may still be on screen; each
  /// list is released after the frame that replaces its page.
  final List<List<FlowBlock>> _releasedEpubBlocks = [];

  /// Blocks window steps detached from the session that the installed page may
  /// still paint. They are owned here from the moment they are detached, so a
  /// step that throws after detaching them loses nothing: they are released
  /// after the next page is shown, or when the session is retired.
  List<FlowBlock> _detachedEpubBlocks = [];

  /// Hands the detached blocks to the after-frame release: the page that
  /// painted them has just been replaced.
  void _releaseDetachedEpubBlocks() {
    if (_detachedEpubBlocks.isEmpty) return;
    final blocks = _detachedEpubBlocks;
    _detachedEpubBlocks = [];
    _releaseEpubBlocksAfterFrame(blocks);
  }

  /// Whether an EPUB layout waits for the first reported page height. The
  /// first report then lays the chapter out.
  bool _epubHeightPending = false;

  /// Embedded `@font-face` families already registered in this process.
  ///
  /// Flutter has no font-unload API, so a family is registered once per
  /// (declared family, resource) pair and stays available; registering the
  /// same family again for another book would either duplicate the face or
  /// collide with it.
  static final Set<String> _registeredEpubFonts = {};

  BigInt? _activeCancellation;
  final Set<BigInt> _relayoutCancellations = {};
  final Set<BigInt> _contentsCancellations = {};
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

  /// The keyboard movement a continuous window is still laying out for, if
  /// any; it owns the window until it lands or is superseded.
  _ReaderSelectionMovementContinued? _continuousMovement;
  int _nextOperationId = 0;
  int _noteRevision = 0;
  int _searchRevision = 0;
  int _bookmarkRevision = 0;
  String _searchQuery = '';
  String? _searchError;
  int _searchCurrentIndex = 0;
  int _contentsRevision = 0;

  /// The scale the displayed PDF page's raster was rendered at. Set only when
  /// a rendered page is adopted, so failed or superseded renders leave it at
  /// the image that is still shown.
  double? _renderedRasterScale;

  /// The display's current pixel ratio, which a fitted PDF raster renders at.
  late double _devicePixelRatio = _baseScale;

  /// The scale the latest fitted re-render asked for, so a render that fails
  /// is not asked for again until the box or the display changes.
  double? _refitScale;

  /// Whether a Contents load is in flight, so the panel opening while the
  /// open's own load runs does not start a second one.
  bool _contentsLoading = false;
  int _exportRevision = 0;
  int _documentPickerRevision = 0;
  bool _documentPickerActive = false;
  double _typographyFontSize;
  double _typographyLineSpacing;
  String _typographyTheme;
  final bool _typographyContinuous;
  bool _typographyTwoPages;
  ReaderRasterFit _rasterFit;
  double _rasterZoom;
  final double _baseScale;
  final Set<BigInt> _toolCancellations = {};
  final Set<BigInt> _searchCancellations = {};
  BigInt? _bookmarkMutationCancellation;
  _ReaderNoteTarget? _activeNoteEditor;
  bool _associationPickerActive = false;

  /// Controller-wide ownership token of the active note editor.
  ///
  /// The per-operation revisions are not comparable across editors (bookmark
  /// editors count with `_bookmarkRevision`, selection/annotation editors with
  /// `_noteRevision`), so completion ownership needs its own token.
  int _noteEditorToken = 0;
  int? _activeNoteEditorToken;

  /// Revision that owns [ _associationPickerActive]; a stale completion may not
  /// clear a newer picker's slot.
  int? _associationPickerRevision;
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
        _viewportChanged(
          message.layout,
          height: message.height,
          devicePixelRatio: message.devicePixelRatio,
        );
      case ReaderUnitRequested():
        _unitRequested(
          message.unit,
          offset: message.offset,
          length: message.length,
        );
      case ReaderPageStepRequested():
        _pageStepRequested(message.delta);
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
      case ReaderPanelToggled():
        _panelToggled(message.panel);
      case ReaderSearchToggled():
        _searchToggled();
      case ReaderPanelFocusRequested():
        if (_model.openPanel == message.panel) {
          _focusAdapter(ReaderFocusTarget.header);
        }
      case ReaderContentsRequested():
        _contentsRequested();
      case ReaderLinkActivated():
        _linkActivated(message.href);
      case ReaderLocationNavigated():
        _closeContentsAfterChoice();
        _unitRequested(
          message.unit,
          offset: message.offset,
          replaceReadingOffset: true,
        );
      case ReaderPageInputChanged():
        _pageInputChanged(message.draft);
      case ReaderPageInputSubmitted():
        _pageInputSubmitted();
      case ReaderTypographyChanged():
        _typographyChanged(message);
      case ReaderBookmarkExportRequested():
        _bookmarkExportRequested();
      case ReaderSearchResultStepRequested():
        _searchResultStepRequested(message.delta);
      case ReaderOpenBookRequested():
        _openBookRequested();
      case _ReaderContentsLoaded():
        if (_isCurrent(message.generation) &&
            message.revision == _contentsRevision) {
          _contentsLoading = false;
          _emit(
            _model.copyWith(
              contents: ReaderContentsPresentation(
                status: message.entries.isEmpty
                    ? ReaderContentsStatus.empty
                    : ReaderContentsStatus.ready,
                entries: message.entries,
              ),
            ),
          );
        }
      case _ReaderContentsFailed():
        if (_isCurrent(message.generation) &&
            message.revision == _contentsRevision) {
          _contentsLoading = false;
          _emit(
            _model.copyWith(
              contents: ReaderContentsPresentation(
                status: ReaderContentsStatus.failed,
                error: message.error,
              ),
            ),
          );
        }
      case _ReaderContentsFinished():
        _contentsCancellations.remove(message.cancellation);
        _bridge.releaseCancellation(id: message.cancellation);
        _activeBridgeOperations -= 1;
        _recoverIfIdle();
        _disposeBridgeIfIdle();
      case _ReaderEpubSourceFinished():
        if (_epubSourceCancellation == message.cancellation) {
          _epubSourceCancellation = null;
        }
        _bridge.releaseCancellation(id: message.cancellation);
        _activeBridgeOperations -= 1;
        _recoverIfIdle();
        _disposeBridgeIfIdle();
      case _ReaderBookmarkExportCompleted():
        if (_isCurrent(message.generation) &&
            message.revision == _exportRevision) {
          _emit(_model.copyWith(exportState: ReaderExportState.idle));
          _reportNotice(
            const NoticeRequest(
              text: ReaderExportSucceededNotice(),
              kind: NoticeKind.success,
              lifetime: NoticeLifetime.brief,
            ),
          );
        }
      case _ReaderBookmarkExportFinished():
        _activeBridgeOperations -= 1;
        _recoverIfIdle();
        _disposeBridgeIfIdle();
      case _ReaderBookmarkExportFailed():
        if (_isCurrent(message.generation) &&
            message.revision == _exportRevision) {
          _emit(
            _model.copyWith(
              exportState: ReaderExportState.failed,
              exportError: message.error,
            ),
          );
          _reportNotice(
            NoticeRequest(
              text: const ReaderExportFailedNotice(),
              kind: NoticeKind.failure,
              lifetime: NoticeLifetime.persistent,
              details: RawNoticeText(message.error),
              dedupeKey: NoticePolicy.readerExportKey,
            ),
          );
        }
      case _ReaderDocumentPickerCompleted():
        if (_isCurrent(message.generation) &&
            message.revision == _documentPickerRevision) {
          _documentPickerActive = false;
          _emit(_model);
          final picked = message.picked;
          if (picked != null) {
            _openRequested(
              ReaderOpenRequested(picked.path, bookId: picked.bookId),
            );
          }
        }
      case _ReaderDocumentPickerFailed():
        if (_isCurrent(message.generation) &&
            message.revision == _documentPickerRevision) {
          _documentPickerActive = false;
          _emit(_model.copyWith(toolError: message.error));
        }
      case ReaderBackRequested():
        unawaited(_leaveReader());
      case _ReaderSearchCompleted():
        if (_isCurrent(message.generation) &&
            message.revision == _searchRevision) {
          _searchCurrentIndex = 0;
          _emit(
            _model.copyWith(searchResults: message.results, searchBusy: false),
          );
          // The pinned reference navigates to the first result when a search
          // completes (`dispatch.rs:2373`); an empty result list navigates
          // nowhere.
          if (message.results.isNotEmpty) {
            final first = message.results.first;
            _unitRequested(
              first.unit.toInt(),
              offset: first.offset.toInt(),
              length: first.length.toInt(),
            );
          }
        }
      case _ReaderSearchFailed():
        if (_isCurrent(message.generation) &&
            message.revision == _searchRevision) {
          _searchError = message.error;
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
              pdfSpread: message.pdfSpread,
              readingPage: message.pdfSpread == null
                  ? null
                  : message.readingPage,
              readingOffset: message.readingOffset ?? _unchanged,
              savedSelections: _savedSelections(
                _model.annotations,
                _model.unit,
                message.pdfSpread,
              ),
              contentState: ReaderContentState.ready,
            ),
          );
        }
      case _ReaderSelectionSupportFailed():
        if (_isCurrent(message.generation)) {
          _emit(
            _model.copyWith(
              selectionError: message.error,
              pdfSpread: message.pdfSpread,
              readingPage: message.pdfSpread == null
                  ? null
                  : message.readingPage,
              // A spread without text has no offsets to place a reading
              // position by; the page alone keeps it.
              readingOffset: message.pdfSpread == null ? _unchanged : null,
            ),
          );
        }
      case _ReaderRelayoutCompleted():
        _relayoutCompleted(message);
      case _ReaderEpubPageLoaded():
        if (_isCurrentLayout(message.generation, message.revision) &&
            _relayoutCancellations.contains(message.cancellation)) {
          _activeRelayoutIntent = null;
          _applyEpubPage(
            generation: message.generation,
            revision: message.revision,
            unit: message.unit,
            scalar: message.scalar,
            layout: message.layout,
            height: message.height,
            annotations: message.annotations,
            offset: message.offset,
            length: message.length,
            replaceReadingOffset: message.replaceReadingOffset,
            annotationError: message.annotationError,
            session: message.session,
            sessionKey: message.sessionKey,
          );
        }
      case ReaderContinuousViewportChanged():
        _continuousViewportChanged(message);
      case _ReaderContinuousWindowTick():
        _continuousWindowTick(message);
      case _ReaderSelectionMovementContinued():
        _selectionMovementContinued(message);
      case _ReaderRelayoutFailed():
        if (_isCurrent(message.generation) &&
            message.revision == _layoutRevision) {
          _activeRelayoutIntent = null;
          _failedLayout = message.layout;
          // A failed layout with nothing installed yet is the open's failure,
          // not a transient relayout failure over visible content, so it shows
          // the open's error surface.
          final nothingInstalled =
              _model.selectionSurface == null &&
              _model.pageImage == null &&
              _model.epubPage == null;
          // A refused chapter is not a transient failure: its typed refusal
          // names the chapter and the way on (another chapter), and the reader
          // keeps whatever page it shows.
          final refusal = message.limit;
          _emit(
            _model.copyWith(
              relayoutBusy: false,
              relayoutPending: false,
              relayoutError: refusal != null
                  ? null
                  : 'Layout failed: ${message.error}',
              layoutRefusal: refusal ?? _unchanged,
              contentState: nothingInstalled
                  ? ReaderContentState.failed
                  : _model.contentState,
              error: nothingInstalled ? message.error : _unchanged,
            ),
          );
        }
      case _ReaderRelayoutFinished():
        _relayoutCancellations.remove(message.cancellation);
        _bridge.releaseCancellation(id: message.cancellation);
        _activeBridgeOperations -= 1;
        _recoverIfIdle();
        _startRequestedRelayoutIfReady();
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
        if (message.token == _activeNoteEditorToken) {
          _activeNoteEditor = null;
          _activeNoteEditorToken = null;
          // Publish the owner-checked clear so the chrome is re-enabled as soon
          // as the dialog is gone, even if the effect reported no result.
          _emit(_model);
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
    _cancelContentsEffects();
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
          error: _consumeRecoveryNotices(_describeError(error)),
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
          error: _consumeRecoveryNotices(_describeError(error)),
          generation: generation,
          relayoutBusy: false,
          relayoutPending: false,
        ),
      );
      return;
    }
    _activeCancellation = cancellation;
    _activeBridgeOperations += 1;
    _searchQuery = '';
    _searchError = null;
    _searchCurrentIndex = 0;
    _exportRevision += 1;
    _retireDocumentPicker();
    _emit(
      _model.copyWith(
        openPath: path,
        openBookId: message.bookId,
        document: null,
        unit: 0,
        readingOffset: null,
        pageImage: null,
        epubPage: null,
        pdfSpread: null,
        readingPage: null,
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
        openPanel: null,
        searchOpen: false,
        contents: const ReaderContentsPresentation(
          status: ReaderContentsStatus.loading,
        ),
        pageInput: const ReaderPageInputPresentation(),
        exportState: ReaderExportState.idle,
        exportError: null,
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
    PdfEngineDocument? ownedPdf;
    try {
      if (bookId != null) await drainBookWrites(bookId);
      opened = bookId == null
          ? await _bridge.openDocument(
              request: FlutterOpenRequest(localId: path, pathKey: path),
              cancellationId: cancellation,
            )
          : await _records.openLibraryBook(
              bookId: bookId,
              cancellationId: cancellation,
            );
      final document = opened;
      // The PDF engine serves every PDF page operation, over the verified
      // snapshot the bridge opened rather than the path, whose file may
      // have been replaced since.
      final PdfEngineDocument? pdf;
      if (document.format == FlutterBookFormat.pdf) {
        pdf = await _pdfEngine.open(document.contentPath ?? path);
        ownedPdf = pdf;
      } else {
        pdf = null;
      }
      FlutterReadingState? restored;
      String? toolError;
      String? restorationError;
      var restorationFailed = false;
      if (bookId != null) {
        try {
          restored = await _records.loadReadingState(
            bookId: bookId,
            cancellationId: cancellation,
          );
        } catch (error) {
          restorationFailed = true;
          restorationError =
              'Reading position could not be restored: ${_describeError(error)}';
        }
      }
      final restoredUnit = (restored?.unit.toInt() ?? 0).clamp(
        0,
        document.logicalUnitCount.toInt() - 1,
      );
      // A PDF read in spreads opens on the spread that holds its page.
      final unit = pdf != null && layout.spread
          ? pdfSpreadStart(restoredUnit)
          : restoredUnit;
      final restoredLayout = restored == null
          ? layout
          : ReaderLayout(
              scale: restored.zoom,
              width: layout.width,
              fontSize: layout.fontSize,
              lineSpacing: layout.lineSpacing,
              spread: layout.spread,
            );
      List<FlutterBookmark> bookmarks = const [];
      if (bookId != null) {
        try {
          bookmarks = await _records.listBookmarks(
            bookId: bookId,
            cancellationId: cancellation,
          );
        } catch (error) {
          toolError = 'Bookmarks are unavailable: ${_describeError(error)}';
        }
      }
      dispatch(
        _ReaderDocumentOpened(
          generation: generation,
          document: document,
          pdfDocument: pdf,
          unit: unit,
          bookmarks: bookmarks,
          layout: restoredLayout,
          restoredLayout: restored != null,
          restorationFailed: restorationFailed,
          restorationError: restorationError,
          offset: unit == restoredUnit ? restored?.offset?.toInt() : null,
          toolError: toolError,
        ),
      );
      opened = null;
      ownedPdf = null;
      if (!_isCurrent(generation)) return;

      // An EPUB's first layout is started (or deferred to the first page-height
      // report) by the opened message's handler.
      if (pdf == null) return;
      final facing = _pdfFacingUnit(pdf, unit, restoredLayout);
      try {
        final (:surface, :spread) = await _pdfSurface(
          pdf,
          unit,
          restoredLayout.scale,
          facing: facing,
        );
        if (!_isCurrent(generation)) return;
        // A position saved on a spread's second page reopens there: its
        // offset moves past the first page's text.
        final restoredOffset = restored?.offset?.toInt();
        dispatch(
          _ReaderSurfaceLoaded(
            generation: generation,
            surface: surface,
            pdfSpread: spread,
            readingPage: restoredUnit,
            readingOffset:
                spread != null &&
                    restoredOffset != null &&
                    restoredUnit == spread.facingUnit
                ? restoredOffset + spread.textShift
                : null,
          ),
        );
      } catch (error) {
        if (!_isCurrent(generation)) return;
        dispatch(
          _ReaderSelectionSupportFailed(
            generation,
            _describeError(error),
            pdfSpread: _textlessSpread(facing),
            readingPage: restoredUnit,
          ),
        );
      }
      final revision = _annotationRevision;
      try {
        final annotations = await _records.listAnnotations(
          document: document,
          text: _readerText(document, cancellation, pdf: pdf),
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
          _ReaderAnnotationListFailed(
            generation,
            revision,
            _describeError(error),
          ),
        );
      }

      final (rendered, rasterScale) = await _renderPdfPage(
        pdf,
        unit,
        restoredLayout,
        facing: facing,
      );
      if (!_isCurrent(generation)) return;
      final image = await _decoder(
        rendered.pixels,
        width: rendered.width,
        height: rendered.height,
      );
      if (!_isCurrent(generation)) {
        image.dispose();
        return;
      }
      dispatch(
        _ReaderImageDecoded(
          generation: generation,
          pageImage: image,
          rasterScale: rasterScale,
        ),
      );
    } catch (error) {
      dispatch(
        _ReaderOpenFailed(
          generation: generation,
          document: opened,
          pdfDocument: ownedPdf,
          error: _describeError(error),
        ),
      );
      opened = null;
      ownedPdf = null;
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
      unawaited(message.pdfDocument?.dispose());
      return;
    }
    _pdfDocument = message.pdfDocument;
    final requestedLayout = ReaderLayout(
      scale: message.restoredLayout
          ? message.layout.scale
          : _requestedLayout.scale,
      width: _requestedLayout.width,
      fontSize: _requestedLayout.fontSize,
      lineSpacing: _requestedLayout.lineSpacing,
      spread: _requestedLayout.spread,
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
    if (message.pdfDocument == null) {
      // Every EPUB chapter is laid out by the Dart engine, which paginates for
      // the reported content-box height: an open that ran before the first
      // layout report waits for it, and the report starts the layout.
      if (_epubPageHeight(null) == null) {
        _epubHeightPending = true;
        return;
      }
      // The first page is laid out for the layout the open committed; a
      // different requested layout is pending and replays when it finishes.
      _startRelayout(
        message.document,
        message.layout,
        unit: message.unit,
        offset: message.offset,
        height: _epubViewportHeight,
      );
      // Starting a relayout records its layout as the requested one, but the
      // viewport's layout is still the one wanted: keep it, so it replays when
      // the first page finishes instead of leaving the book laid out for the
      // window it was last read in.
      _requestedLayout = requestedLayout;
    }
  }

  void _layoutChanged(ReaderLayout layout, {double? height}) {
    if (!layout.isValid || _closing) return;
    final epubHeight = _epubPageHeight(height);
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
    // The reader returned to the layout it is already displaying while a
    // relayout for a *different* layout is in flight: the pending result is no
    // longer wanted, and the displayed content is still correct, so it is
    // cancelled. A relayout that targets the displayed layout itself (a page
    // height refresh, or a navigation inside the current chapter) must be left
    // to finish: cancelling it would strand the chapter with nothing installed
    // and no successor to replay it.
    if (layout == _model.layout &&
        _relayoutCancellations.isNotEmpty &&
        _requestedLayout != _model.layout) {
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
    // A height-only change (a window resize that keeps the width, or the first
    // report after an open that had no height yet) must re-paginate the EPUB
    // page: its page breaks depend on the page height.
    final epubHeightChanged = _epubHeightNeedsLayout(
      document,
      layout,
      epubHeight,
    );
    if (_model.contentState != ReaderContentState.ready &&
        !(epubHeightChanged && _epubAwaitsFirstPage)) {
      _requestedLayout = layout;
      _failedLayout = null;
      _setRelayoutPending(false);
      return;
    }
    if (!epubHeightChanged &&
        (layout == _requestedLayout || layout == _failedLayout)) {
      return;
    }
    _startRelayout(document, layout, height: epubHeight);
  }

  /// Whether an open EPUB has no page installed yet and waits for its first
  /// page height.
  bool get _epubAwaitsFirstPage =>
      _epubHeightPending &&
      _model.epubPage == null &&
      _model.contentState == ReaderContentState.loading;

  /// Whether the reported page height requires a new EPUB layout.
  ///
  /// Chrome jitter smaller than one line (the relayout progress bar alone moves
  /// the box by 4 px) is absorbed by the fit transform; a real resize, or the
  /// first report after an open that had no height yet, re-paginates.
  bool _epubHeightNeedsLayout(
    FlutterDocumentSummary document,
    ReaderLayout layout,
    double? epubHeight,
  ) {
    if (document.format != FlutterBookFormat.epub || epubHeight == null) {
      return false;
    }
    final installed = _epubLayoutHeight;
    if (installed == null) return _epubHeightPending;
    if (!_epubHeightPending && _epubSessionKey == null) return false;
    return (epubHeight - installed).abs() > _epubPageHeightTolerance(layout);
  }

  /// The page-height change that counts as a resize rather than chrome jitter.
  ///
  /// The relayout progress bar is 4 logical px tall and appears while a layout
  /// is in flight, and a chrome row can differ by a few px; a change smaller
  /// than one line is absorbed by the fit transform instead of re-paginating
  /// (and, during a relayout, restarting or cancelling it).
  double _epubPageHeightTolerance(ReaderLayout layout) =>
      layout.fontSize * layout.lineSpacing;

  /// The page height EPUB pages are paginated for, given [height].
  ///
  /// Returns null when the view has not reported a usable height yet, so the
  /// layout waits instead of paginating for a guessed box.
  double? _epubPageHeight(double? height) {
    final observed = height ?? _epubViewportHeight;
    if (observed == null || !observed.isFinite || observed <= 0) return null;
    return observed;
  }

  void _viewportChanged(
    ReaderLayout observed, {
    double? height,
    double? devicePixelRatio,
  }) {
    if (height != null && height.isFinite && height > 0) {
      _epubViewportHeight = height;
    }
    final pixelRatioChanged =
        devicePixelRatio != null &&
        devicePixelRatio.isFinite &&
        devicePixelRatio > 0 &&
        devicePixelRatio != _devicePixelRatio;
    if (pixelRatioChanged) _devicePixelRatio = devicePixelRatio;
    final layout = _model.document == null && !_model.busy
        ? observed
        : ReaderLayout(
            scale: _requestedLayout.scale,
            width: observed.width,
            fontSize: observed.fontSize,
            lineSpacing: observed.lineSpacing,
            spread: observed.spread,
          );
    final document = _model.document;
    final intent = _activeRelayoutIntent;
    final isNavigation =
        intent != null &&
        // A passive relayout targets the page being read, which on a PDF
        // spread may be its second page.
        (intent.unit != _model.readingLocation.unit ||
            intent.offset != null ||
            intent.length != null ||
            intent.replaceReadingOffset);
    if (document != null &&
        _model.relayoutBusy &&
        !isNavigation &&
        layout == _model.layout) {
      _layoutChanged(layout, height: height);
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
        height: height,
      );
      return;
    }
    _layoutChanged(layout, height: height);
    if (height != null || pixelRatioChanged) _refitPdfPage();
  }

  /// The scale a PDF page's raster renders at in a fit mode: the page fitted
  /// to the content box at the display's pixel ratio, so it is re-rendered
  /// sharp at the size it is shown (RFD 4, the first release) instead of
  /// scaled from the zoom. Null when the zoom applies: a manual zoom, or a box
  /// that is not measured yet.
  ///
  /// Only the raster follows the box. The selection surface, the annotation
  /// geometry and the saved zoom stay at the layout's scale; the page painter
  /// draws the raster into the surface's rectangle, whatever its pixel size.
  /// The scale is kept exact, so the engine's pixel rounding sizes the bitmap;
  /// [_refitPdfPage]'s relative tolerance keeps a small resize from rendering
  /// the page again.
  double? _fittedRasterScale(
    PdfEngineDocument pdf,
    int unit,
    double width, {
    int? facing,
  }) {
    if (_rasterFit == ReaderRasterFit.manual) return null;
    if (!width.isFinite || width <= 0) return null;
    final PdfPageSize page;
    try {
      // A spread fits its two pages side by side as one page.
      final first = pdf.pageSize(unit);
      final second = facing == null ? null : pdf.pageSize(facing);
      page = second == null
          ? first
          : PdfPageSize(
              first.width + second.width,
              math.max(first.height, second.height),
            );
    } catch (_) {
      return null;
    }
    if (page.width <= 0 || page.height <= 0) return null;
    var fit = width / page.width;
    final height = _epubViewportHeight;
    if (_rasterFit == ReaderRasterFit.fitPage &&
        height != null &&
        height.isFinite &&
        height > 0) {
      fit = math.min(fit, height / page.height);
    }
    final scale = fit * _devicePixelRatio;
    if (!scale.isFinite || scale <= 0) return null;
    try {
      final first = pdf.bitmapSize(unit, scale);
      if (facing != null) {
        pdfSpreadBitmapSize(first, pdf.bitmapSize(facing, scale));
      }
    } on PdfEngineLimitException {
      // A page too large to render at its fitted size keeps the zoom and is
      // scaled to fit instead.
      return null;
    }
    return scale;
  }

  /// Renders [unit] of [pdf] for [layout]: at its fitted scale in a fit mode,
  /// otherwise at the layout's. With [facing], both pages of the spread are
  /// rendered at one scale and laid side by side in one raster. Returns the
  /// page with the scale it was rendered at, which its completion carries to
  /// adoption.
  Future<(PdfRenderedPage, double)> _renderPdfPage(
    PdfEngineDocument pdf,
    int unit,
    ReaderLayout layout, {
    int? facing,
  }) async {
    final scale =
        _fittedRasterScale(pdf, unit, layout.width, facing: facing) ??
        layout.scale;
    if (facing == null) return (await pdf.render(unit, scale), scale);
    // A spread too large to compose fails before either page renders.
    pdfSpreadBitmapSize(
      pdf.bitmapSize(unit, scale),
      pdf.bitmapSize(facing, scale),
    );
    // Both pages render at once; a failure reports the page's own error.
    final pages = await Future.wait([
      pdf.render(unit, scale),
      pdf.render(facing, scale),
    ], eagerError: true);
    return (composePdfSpread(pages[0], pages[1]), scale);
  }

  /// The page shown beside [unit] when [layout] reads in spreads: the next
  /// page, for the first page of a pair that has one.
  int? _pdfFacingUnit(PdfEngineDocument pdf, int unit, ReaderLayout layout) {
    if (!layout.spread || unit != pdfSpreadStart(unit)) return null;
    return unit + 1 < pdf.pageCount ? unit + 1 : null;
  }

  /// The spread for [facing] when its pages' text could not be read: both
  /// pages are still shown and turned together, but no offset lies on either.
  ReaderPdfSpread? _textlessSpread(int? facing) =>
      facing == null ? null : ReaderPdfSpread(facingUnit: facing, textShift: 0);

  /// The selection surface of [unit] at [scale], spanning [facing] too when
  /// the spread shows it.
  Future<({FlutterSelectionSurface surface, ReaderPdfSpread? spread})>
  _pdfSurface(
    PdfEngineDocument pdf,
    int unit,
    double scale, {
    int? facing,
  }) async {
    if (facing == null) {
      return (surface: await pdf.selectionSurface(unit, scale), spread: null);
    }
    final pages = await Future.wait([
      pdf.selectionSurface(unit, scale),
      pdf.selectionSurface(facing, scale),
    ], eagerError: true);
    final merged = mergePdfSpreadSurfaces(pages[0], pages[1]);
    return (
      surface: merged.surface,
      spread: ReaderPdfSpread(facingUnit: facing, textShift: merged.textShift),
    );
  }

  /// Renders the displayed PDF page again when a height report changes its
  /// fitted scale enough to matter: the layout has no height, so the width
  /// alone would not.
  ///
  /// A raster a little larger than its box is still sharp, so a box that
  /// shrinks (an alert row appearing, say) keeps the page until the raster is
  /// twice the size it needs; one that grows renders again past 5%.
  ///
  /// It is admitted like any relayout: while the reader is busy, laying out or
  /// writing a highlight it waits, and [_startRequestedRelayoutIfReady] asks
  /// again with the latest box when that work finishes.
  void _refitPdfPage() {
    final document = _model.document;
    final pdf = _pdfDocument;
    if (document == null ||
        pdf == null ||
        _model.busy ||
        _model.relayoutBusy ||
        _model.relayoutPending ||
        _model.annotationOperations.isNotEmpty ||
        _model.contentState != ReaderContentState.ready ||
        _requestedLayout != _model.layout) {
      return;
    }
    final scale = _fittedRasterScale(
      pdf,
      _model.unit,
      _model.layout.width,
      facing: _model.pdfSpread?.facingUnit,
    );
    final rendered = _renderedRasterScale;
    if (scale == null ||
        (rendered != null &&
            scale <= rendered * 1.05 &&
            scale * 2 > rendered) ||
        _refitFailedNear(scale)) {
      return;
    }
    _refitScale = scale;
    // The failed render's error stays up while the page renders again: the
    // alert row is part of the box the page is fitted to, so clearing it
    // would change the fitted size the retry is for. The refit is not a
    // navigation: its completion keeps the reading offset, and a box that
    // moves while it renders waits for it instead of restarting it.
    _startRelayout(document, _model.layout, keepRelayoutError: true);
  }

  /// Whether a fitted render near [scale] has just failed for the layout
  /// shown: a box that moves by a few pixels (the relayout progress bar, an
  /// alert row) does not ask for it again until the layout changes.
  bool _refitFailedNear(double scale) {
    final failed = _refitScale;
    return failed != null &&
        _failedLayout == _model.layout &&
        (scale - failed).abs() <= failed * 0.05;
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
    double? height,
    bool keepRelayoutError = false,
  }) {
    final generation = _model.generation;
    // A relayout with no target of its own keeps the page being read: on a
    // PDF spread that may be its second page, which a layout of one page
    // shows alone.
    final targetUnit =
        unit ??
        (document.format == FlutterBookFormat.pdf
            ? _model.readingLocation.unit
            : _model.unit);
    _requestedLayout = layout;
    if (document.format == FlutterBookFormat.epub) {
      // EPUB pages are paginated for the reported page height: before the
      // first report the layout waits, and the report starts it.
      final pageHeight = _epubPageHeight(height);
      if (pageHeight == null) {
        _epubHeightPending = true;
        return;
      }
      _epubLayoutHeight = pageHeight;
      _epubHeightPending = false;
    }
    late final BigInt cancellation;
    try {
      cancellation = _bridge.createCancellation();
    } catch (error) {
      _failedLayout = layout;
      _emit(
        _model.copyWith(
          relayoutPending: false,
          relayoutError: 'Layout failed: ${_describeError(error)}',
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
    // A relayout invalidates the selection passively: it must not move focus
    // into the document. An explicit user cancellation still returns focus to
    // the surface (see [_selectionCancelled]); otherwise a resize would steal
    // focus from an open panel or the header.
    _selectionCancelled(requestSurfaceFocus: false);
    final navigation =
        targetUnit != _model.unit ||
        offset != null ||
        length != null ||
        replaceReadingOffset;
    _emit(
      _model.copyWith(
        relayoutBusy: true,
        relayoutPending: false,
        selectionError: null,
        relayoutError: keepRelayoutError ? _unchanged : null,
        // A chapter refusal outlives a passive relayout of the page still
        // shown (its own alert changes the page height); a new location
        // request replaces it.
        layoutRefusal: navigation ? null : _unchanged,
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
        height: height,
      ),
    );
  }

  /// Turns a page by [delta] on the Dart EPUB path (RD-06 edge navigation).
  ///
  /// The durable position is the page's canonical start, and the page itself is
  /// derived from the controller-owned layout session, so a page turn costs one
  /// pagination pass over the measured window instead of a relayout. At a
  /// window edge the session is extended by one bounded batch; when the chapter
  /// is genuinely over the step becomes a chapter change through the normal
  /// guarded relayout path.
  void _pageStepRequested(int delta) {
    final page = _model.epubPage;
    final session = _epubSession;
    final document = _model.document;
    if (page == null || session == null || document == null || delta == 0) {
      // A PDF, or an EPUB with no page installed yet, steps by logical unit.
      _unitRequested(_model.unit + delta);
      return;
    }
    if (_model.busy ||
        _model.relayoutBusy ||
        _model.annotationOperations.isNotEmpty ||
        _closing ||
        _suspended) {
      return;
    }
    final layout = _model.layout;
    final height = _epubLayoutHeight;
    if (height == null) return;
    if (page.continuous) {
      // A continuous chapter scrolls; a page step moves between chapters.
      _unitRequested(_model.unit + delta);
      return;
    }
    // A spread turns both of its pages: forward from its second page, and
    // back two pages so the page before it lands in the second slot.
    var step = delta < 0
        ? _epubPageBefore(session, page.canonicalStart)
        : _epubPageAfter(
            session,
            page.facing?.canonicalStart ?? page.canonicalStart,
          );
    if (delta < 0 && page.spread && step.scalar != null) {
      final further = _epubPageBefore(session, step.scalar!);
      if (further.scalar != null) step = further;
    }
    final target = step.scalar;
    if (target == null) {
      if (step.complete) {
        // The window measured the whole chapter and has no further page: this
        // is a chapter edge.
        _unitRequested(_model.unit + delta);
      }
      // Otherwise the window simply does not reach that page yet; the step is
      // dropped rather than turned into a chapter change.
      return;
    }
    if (target == page.canonicalStart) return;
    // A page turn is a newer navigation: a link still deciding its target must
    // not move the reader back when its comparison completes.
    // The page the selection addresses is leaving the screen: invalidate it the
    // way a relayout does, without moving focus into the document (the turn is
    // not an explicit selection cancellation).
    _selectionCancelled(requestSurfaceFocus: false);
    _applyEpubPage(
      generation: _model.generation,
      revision: _layoutRevision,
      unit: _model.unit,
      scalar: target,
      layout: layout,
      height: height,
      annotations: _model.annotations,
      offset: target,
      replaceReadingOffset: true,
    );
  }

  /// The canonical start of the page before [scalar], extending the session by
  /// bounded batches when the window does not reach it yet.
  ///
  /// [complete] distinguishes the chapter's first page (no further content)
  /// from a window that has not been extended far enough yet.
  ({int? scalar, bool complete}) _epubPageBefore(
    ChapterLayoutSession session,
    int scalar,
  ) {
    for (var attempt = 0; attempt < 3; attempt += 1) {
      final paginated = _paginatedWindow(session);
      final index = paginated?.pageOfCanonical(scalar);
      if (paginated != null && index != null && index > 0) {
        return (
          scalar: paginated.pages[index - 1].canonicalStart,
          complete: true,
        );
      }
      if (session.firstNodeIndex == 0 ||
          session.layoutBackward(maxNodes: 12, maxMicros: 6000) == 0) {
        return (scalar: null, complete: session.firstNodeIndex == 0);
      }
    }
    return (scalar: null, complete: session.firstNodeIndex == 0);
  }

  /// The canonical start of the page after [scalar], extending the session by
  /// bounded batches when the window does not reach it yet.
  ({int? scalar, bool complete}) _epubPageAfter(
    ChapterLayoutSession session,
    int scalar,
  ) {
    for (var attempt = 0; attempt < 3; attempt += 1) {
      final paginated = _paginatedWindow(session);
      if (paginated != null) {
        final index = paginated.pageOfCanonical(scalar);
        if (index + 1 < paginated.pages.length) {
          return (
            scalar: paginated.pages[index + 1].canonicalStart,
            complete: true,
          );
        }
      }
      if (session.complete) return (scalar: null, complete: true);
      if (session.layoutForward(maxNodes: 12, maxMicros: 6000) == 0) {
        return (scalar: null, complete: session.complete);
      }
    }
    return (scalar: null, complete: session.complete);
  }

  /// Whether [key] lays pages out as spreads, after extending [session] so
  /// the page after the one holding [scalar] is laid out when the chapter has
  /// one: the spread shows both.
  bool _ensureFacingPage(
    ChapterLayoutSession session,
    _EpubLayoutKey? key,
    int scalar,
  ) {
    if (key == null || !key.spread) return false;
    for (var attempt = 0; attempt < 3; attempt += 1) {
      final paginated = paginateWindow(
        session.snapshot(),
        ui.Size(key.pageWidth, key.height),
      );
      if (paginated.pageOfCanonical(scalar) + 1 < paginated.pages.length ||
          session.complete ||
          session.layoutForward(maxNodes: 12, maxMicros: 6000) == 0) {
        break;
      }
    }
    return true;
  }

  PaginatedChapter? _paginatedWindow(ChapterLayoutSession session) {
    final key = _epubSessionKey;
    if (key == null) return null;
    return paginateWindow(
      session.snapshot(),
      ui.Size(key.pageWidth, key.height),
    );
  }

  /// Derives the page window containing [scalar] and publishes it.
  ///
  /// Shared by the guarded layout effect and a page turn, so both transitions
  /// produce the same model state: the durable offset is the page's canonical
  /// start, the surface is the page's own geometry, and the reading state is
  /// queued for the page the reader is looking at.
  void _applyEpubPage({
    required int generation,
    required int revision,
    required int unit,
    required int scalar,
    required ReaderLayout layout,
    required double height,
    required List<FlutterAnnotation> annotations,
    int? offset,
    int? length,
    bool replaceReadingOffset = false,
    String? annotationError,
    String? selectionError,
    ChapterLayoutSession? session,
    _EpubLayoutKey? sessionKey,
  }) {
    final installed = _epubSession;
    final document = _model.document;
    if ((installed == null && session == null) || document == null) return;
    final previousSession = installed;
    final pageSession = session ?? installed!;
    final pageKey = sessionKey ?? _epubSessionKey;
    final page = pageKey != null && pageKey.continuous
        ? _continuousPage(pageSession, pageKey, scalar)
        : pageWindowFor(
            session: pageSession,
            scalar: scalar,
            unit: unit,
            chapterCount: document.logicalUnitCount.toInt(),
            windowSize: ui.Size(layout.width, height),
            spread: _ensureFacingPage(pageSession, pageKey, scalar),
          );
    final oldImage = _model.pageImage;
    final changedLocation =
        unit != _model.unit || offset != null || replaceReadingOffset;
    if (changedLocation) {
      _readingStatePersistenceBlocked = false;
      // The view reveals the new location before it reports what it shows:
      // the region reported for the previous location is not this one's.
      _continuousViewport = null;
    }
    final readingOffset = changedLocation ? offset : _model.readingOffset;
    // The ownership transfer is the commit, and it happens after the next model
    // is derived but before it is published: a failure in the injected progress
    // source, or while releasing the previous page, must not leave a published
    // page whose session this effect still thinks it owns (and would then
    // release), nor an installed session whose page the model does not show.
    final next = _deriveModel(
      _model.copyWith(
        unit: unit,
        readingOffset: readingOffset,
        // The more panel's page input follows the reader's location, the way
        // the pinned reference syncs `page_input` on navigation (RD-10).
        pageInput: changedLocation
            ? ReaderPageInputPresentation(draft: '${unit + 1}')
            : _model.pageInput,
        pageImage: null,
        epubPage: page,
        pdfSpread: null,
        readingPage: null,
        locationRequestRevision: changedLocation
            ? _model.locationRequestRevision + 1
            : _model.locationRequestRevision,
        selectionSurface: _freezeSurface(page.surface),
        annotations: annotations,
        savedSelections: _savedSelections(annotations, unit),
        anchor: offset ?? _model.anchor,
        focus: offset == null ? _model.focus : offset + (length ?? 0),
        selectionPhase: length == null
            ? _model.selectionPhase
            : ReaderSelectionPhase.selected,
        relayoutError: null,
        layoutRefusal: changedLocation ? null : _model.layoutRefusal,
        annotationsReady: annotationError == null,
        annotationError:
            annotationError ??
            (_model.annotationsReady ? _model.annotationError : null),
        layout: layout,
        relayoutBusy: false,
        relayoutPending: false,
        selectionError: selectionError,
        contentState: ReaderContentState.ready,
        selectionVisualLine: null,
        selectionPreferredX: null,
      ),
    );
    final adopting = session != null && !identical(session, previousSession);
    if (adopting) {
      _epubSession = session;
      _epubSessionKey = sessionKey;
    }
    _publish(next);
    oldImage?.dispose();
    // The page that painted any window-detached blocks is replaced.
    _releaseDetachedEpubBlocks();
    // The page carried its own session, adopted above before publication; the
    // session the model painted until this frame is retired after it. A
    // document's first page has no predecessor, and `_retireEpubSession` with no
    // argument retires the *current* session, so it is only called with one.
    if (adopting && previousSession != null) {
      _retireEpubSession(previousSession);
    }
    if (page.continuous) _scheduleContinuousTick();
    if (length != null) {
      _frameScheduler(
        () => dispatch(_ReaderSurfaceFocusReady(generation, revision)),
      );
    }
    final bookId = _model.document?.bookId;
    if (bookId != null) {
      _queueReadingStateSave(
        bookId,
        _model.document!.logicalUnitCount,
        FlutterReadingState(
          unit: BigInt.from(unit),
          offset: readingOffset == null ? null : BigInt.from(readingOffset),
          zoom: layout.scale,
        ),
      );
    }
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
        // The other page of a PDF spread is shown already, but asking for it
        // makes it the page being read.
        (unit == _model.readingLocation.unit &&
            offset == null &&
            !replaceReadingOffset) ||
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

  /// Toggles one panel; at most one of the three is open (RD-13).
  void _panelToggled(ReaderPanel panel) {
    if (_closing) return;
    final opening = _model.openPanel != panel;
    _emit(_model.copyWith(openPanel: opening ? panel : null));
    if (opening) {
      // A docked panel narrows the content area, so the layout reporter
      // observes new constraints and relayouts through the guarded path.
      _requestPanelFocus(panel);
      // The Contents panel loads its entries when it opens unless the open
      // already did (RD-07), and its page field starts from the reader's
      // current location (RD-10).
      if (panel == ReaderPanel.contents) {
        final status = _model.contents.status;
        if ((status == ReaderContentsStatus.loading ||
                status == ReaderContentsStatus.failed) &&
            !_contentsLoading) {
          _contentsRequested();
        }
        _syncPageInput();
      }
    } else {
      _requestHeaderFocus();
    }
  }

  /// Closes the Contents panel once a place in it is chosen: the panel floats
  /// over the page, so it would hide the place the reader asked for.
  void _closeContentsAfterChoice() {
    if (_model.openPanel != ReaderPanel.contents) return;
    _emit(_model.copyWith(openPanel: null));
    _requestHeaderFocus();
  }

  /// Opens or closes the search bar and cancels an in-flight search on close.
  void _searchToggled() {
    if (_closing) return;
    if (_model.searchOpen) {
      _cancelSearch();
      _searchQuery = '';
      _searchError = null;
      _searchCurrentIndex = 0;
      _emit(
        _model.copyWith(
          searchOpen: false,
          searchResults: const [],
          searchBusy: false,
        ),
      );
      return;
    }
    _emit(_model.copyWith(searchOpen: true));
  }

  void _cancelSearch() {
    _searchRevision += 1;
    for (final active in _searchCancellations) {
      _bridge.cancel(id: active);
    }
  }

  /// Steps to another search result and navigates to it (RD-11).
  ///
  /// Stepping wraps in both directions, mirroring the pinned reference
  /// (`dispatch.rs:2386-2404`), and is ignored while searching or without
  /// results.
  void _searchResultStepRequested(int delta) {
    final results = _model.searchResults;
    if (results.isEmpty ||
        _model.searchBusy ||
        _model.busy ||
        _model.relayoutBusy ||
        _model.annotationOperations.isNotEmpty ||
        _closing ||
        _suspended) {
      return;
    }
    final count = results.length;
    final index = ((_searchCurrentIndex + delta) % count + count) % count;
    _searchCurrentIndex = index;
    _emit(_model);
    final result = results[index];
    _unitRequested(
      result.unit.toInt(),
      offset: result.offset.toInt(),
      length: result.length.toInt(),
    );
  }

  /// Loads or retries the Contents entries through a guarded effect (RD-07).
  ///
  /// The effect is controller-owned. An injected loader is the fixture seam;
  /// otherwise the document's real table of contents is resolved from the
  /// parsed EPUB, with the EPUB chapter fallback for a book without one or an
  /// unreadable source. A stale completion cannot publish entries for a newer
  /// document generation or load.
  void _contentsRequested() {
    final document = _model.document;
    if (document == null || _model.busy || _closing || _suspended) return;
    final generation = _model.generation;
    // Cancelling first invalidates the superseded load; the new load then owns
    // the current revision, so a later cancel can invalidate it the same way.
    _cancelContentsEffects();
    final revision = _contentsRevision;
    _contentsLoading = true;
    // A fresh document already starts out loading; only a retry changes it.
    if (_model.contents.status != ReaderContentsStatus.loading) {
      _emit(
        _model.copyWith(
          contents: ReaderContentsPresentation(
            status: ReaderContentsStatus.loading,
            entries: _model.contents.entries,
          ),
        ),
      );
    }
    final loader = _contentsLoader;
    if (loader != null) {
      unawaited(() async {
        try {
          final entries = await loader(document);
          dispatch(_ReaderContentsLoaded(generation, revision, entries));
        } catch (error) {
          dispatch(
            _ReaderContentsFailed(generation, revision, _describeError(error)),
          );
        }
      }());
      return;
    }
    if (document.format != FlutterBookFormat.epub) {
      final pdf = _pdfDocument;
      if (pdf == null) {
        dispatch(
          _ReaderContentsLoaded(
            generation,
            revision,
            _chapterFallback(document),
          ),
        );
        return;
      }
      unawaited(() async {
        try {
          final entries = await _pdfContents(document, pdf);
          if (!_isCurrent(generation) || revision != _contentsRevision) return;
          dispatch(_ReaderContentsLoaded(generation, revision, entries));
        } catch (error) {
          if (!_isCurrent(generation) || revision != _contentsRevision) return;
          dispatch(
            _ReaderContentsFailed(generation, revision, _describeError(error)),
          );
        }
      }());
      return;
    }
    final BigInt cancellation;
    try {
      cancellation = _bridge.createCancellation();
    } catch (error) {
      dispatch(
        _ReaderContentsFailed(generation, revision, _describeError(error)),
      );
      return;
    }
    _contentsCancellations.add(cancellation);
    _activeBridgeOperations += 1;
    unawaited(() async {
      try {
        final entries = await _defaultContents(
          document,
          generation,
          revision,
          cancellation,
        );
        if (!_isCurrent(generation) || revision != _contentsRevision) return;
        dispatch(_ReaderContentsLoaded(generation, revision, entries));
      } catch (error) {
        dispatch(
          _ReaderContentsFailed(generation, revision, _describeError(error)),
        );
      } finally {
        dispatch(_ReaderContentsFinished(cancellation));
      }
    }());
  }

  /// The default Contents source: the real EPUB table of contents, or the
  /// chapter fallback when the book has none or its source cannot be read.
  Future<List<ReaderContentsEntry>> _defaultContents(
    FlutterDocumentSummary document,
    int generation,
    int revision,
    BigInt cancellation,
  ) async {
    final EpubContentSource source;
    try {
      source = await _ensureEpubSource(document, generation);
    } catch (_) {
      return _chapterFallback(document);
    }
    if (!_isCurrent(generation) || revision != _contentsRevision) {
      return _chapterFallback(document);
    }
    final locations = resolveTocLocations(source.book);
    if (locations.isEmpty) return _chapterFallback(document);
    return [
      for (final location in locations)
        ReaderContentsEntry(
          depth: location.depth,
          title: location.title,
          unit: location.spine,
          offset: location.offset,
        ),
    ];
  }

  /// Cancels every in-flight Contents load and drops its completion.
  void _cancelContentsEffects() {
    _contentsRevision += 1;
    _contentsLoading = false;
    for (final cancellation in _contentsCancellations) {
      _bridge.cancel(id: cancellation);
    }
    _contentsCancellations.clear();
  }

  /// Activates a link painted on an EPUB page.
  ///
  /// Classification follows the reader's link policy: a reference without a
  /// scheme is internal and is resolved against the current chapter; `http`,
  /// `https` and `mailto` are the only external schemes and go to the injected
  /// platform opener; every other scheme is refused, and the reader never
  /// fetches a book resource.
  void _linkActivated(String href) {
    final document = _model.document;
    if (document == null || document.format != FlutterBookFormat.epub) return;
    if (_model.busy ||
        _model.relayoutBusy ||
        _model.annotationOperations.isNotEmpty ||
        _closing ||
        _suspended) {
      return;
    }
    final kind = classifyEpubLink(href);
    if (kind == EpubLinkKind.external) {
      unawaited(_openExternalLink(href));
      return;
    }
    if (kind == EpubLinkKind.unsupported) return;
    final source = _epubSource;
    if (source == null || _epubSourceGeneration != _model.generation) return;
    final unit = _model.unit;
    if (unit < 0 || unit >= source.book.chapters.length) return;
    final target = resolveBookLink(
      book: source.book,
      fromResource: source.book.chapters[unit].resource,
      href: href,
    );
    if (target == null) return;
    _unitRequested(
      target.point.spine,
      offset: target.hasFragment ? target.point.scalar : 0,
      replaceReadingOffset: true,
    );
  }

  /// Opens an allowed external link through the injected platform opener.
  ///
  /// The opener is a platform adapter with no reader error surface: the
  /// retained reference only warns when the platform refuses a URL, so a
  /// failure here is not turned into a reader error.
  Future<void> _openExternalLink(String url) async {
    try {
      await _externalLinkOpener(url);
    } catch (_) {
      // See above: a refused platform open is not a reader error.
    }
  }

  /// The EPUB chapter fallback: one untitled entry per logical unit.
  ///
  /// The panel renders the localized chapter number for an untitled entry, so
  /// no title is invented (contract §4.6).
  /// The PDF Contents source: the document outline, or the page fallback when
  /// the document has none.
  ///
  /// An outline entry without a page destination keeps its title and addresses
  /// the page of the nearest preceding entry that has one (its section), or
  /// the first page.
  Future<List<ReaderContentsEntry>> _pdfContents(
    FlutterDocumentSummary document,
    PdfEngineDocument pdf,
  ) async {
    final outline = await pdf.outline();
    if (outline.isEmpty) return _chapterFallback(document);
    final pages = document.logicalUnitCount.toInt();
    var unit = 0;
    return [
      for (final entry in outline)
        ReaderContentsEntry(
          depth: entry.depth,
          title: entry.title,
          unit: unit = switch (entry.page) {
            final page? when page >= 0 && page < pages => page,
            _ => unit,
          },
        ),
    ];
  }

  List<ReaderContentsEntry> _chapterFallback(FlutterDocumentSummary document) =>
      [
        for (var unit = 0; unit < document.logicalUnitCount.toInt(); unit += 1)
          ReaderContentsEntry(unit: unit),
      ];

  /// Seeds the Contents panel's page input from the current location (RD-10).
  void _syncPageInput() {
    final document = _model.document;
    if (document == null) return;
    _emit(
      _model.copyWith(
        pageInput: ReaderPageInputPresentation(
          draft: '${_model.readingLocation.unit + 1}',
        ),
      ),
    );
  }

  void _pageInputChanged(String draft) {
    if (_closing) return;
    _emit(
      _model.copyWith(pageInput: ReaderPageInputPresentation(draft: draft)),
    );
  }

  /// Validates and converts the 1-based page input, or sets the inline error.
  void _pageInputSubmitted() {
    final document = _model.document;
    if (document == null || _closing) return;
    final draft = _model.pageInput.draft.trim();
    final total = document.logicalUnitCount.toInt();
    final ordinal = int.tryParse(draft);
    if (ordinal == null || ordinal < 1 || ordinal > total) {
      _emit(
        _model.copyWith(
          pageInput: ReaderPageInputPresentation(
            draft: _model.pageInput.draft,
            error: 'page input out of range: "$draft" (1-$total)',
          ),
        ),
      );
      return;
    }
    _emit(
      _model.copyWith(pageInput: ReaderPageInputPresentation(draft: draft)),
    );
    _closeContentsAfterChoice();
    _unitRequested(ordinal - 1);
  }

  /// Applies a reader-local typography change (RD-09).
  ///
  /// Font size, line spacing and zoom are clamped to the pinned ranges; a
  /// layout-affecting change is applied through the guarded relayout path so a
  /// failed layout reports through the existing error surface. Persisting the
  /// value, per-book precedence and the typed fit codec are 5A/6B.
  void _typographyChanged(ReaderTypographyChanged message) {
    if (_closing) return;
    final document = _model.document;
    final before = _model.typography;
    final fontSize = message.fontSize?.clamp(8.0, 48.0);
    final lineSpacing = message.lineSpacing?.clamp(1.0, 2.4);
    final theme = message.theme;
    if (fontSize != null) _typographyFontSize = fontSize;
    if (lineSpacing != null) _typographyLineSpacing = lineSpacing;
    if (theme != null && _readerThemes.contains(theme)) {
      _typographyTheme = theme;
    }
    // The view decides whether two pages fit and reports the spread with the
    // viewport, which lays the page out again; the setting needs no relayout
    // of its own.
    if (message.twoPages case final twoPages?) _typographyTwoPages = twoPages;
    if (message.rasterFit case final fit?) {
      _rasterFit = fit;
      if (fit != ReaderRasterFit.manual) _rasterZoom = _baseScale;
    }
    if (message.zoom case final zoom?) {
      _rasterFit = ReaderRasterFit.manual;
      _rasterZoom = zoom.clamp(0.25, 5.0);
    }
    _emit(_model);
    final after = _model.typography;
    // A theme change re-palettes an EPUB page: its text is styled with the
    // palette captured when the page was laid out, unlike a PDF raster, which
    // is recolored from current model state at paint time.
    final themeChanged =
        document != null &&
        document.format == FlutterBookFormat.epub &&
        before.theme != after.theme;
    if (document == null ||
        _model.busy ||
        _model.contentState != ReaderContentState.ready ||
        (before.epubFontSize == after.epubFontSize &&
            before.epubLineSpacing == after.epubLineSpacing &&
            before.rasterZoom == after.rasterZoom &&
            before.rasterFit == after.rasterFit &&
            !themeChanged)) {
      return;
    }
    _startRelayout(
      document,
      ReaderLayout(
        scale: after.rasterZoom,
        width: _requestedLayout.width,
        fontSize: after.epubFontSize,
        lineSpacing: after.epubLineSpacing,
        spread: _requestedLayout.spread,
      ),
      unit: _model.readingLocation.unit,
      offset: _model.readingLocation.offset,
    );
  }

  /// The reader's supported theme values, in cycle order.
  static const List<String> _readerThemes = ['light', 'dark', 'sepia'];

  Future<void> _leaveReader() async {
    if (_closing) return;
    try {
      await _navigationAdapter();
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

  void _requestPanelFocus(ReaderPanel panel) {
    // The panel is built in the frame the open transition schedules, so the
    // request is deferred one further frame before the adapter runs.
    _frameScheduler(() {
      if (_closing || _model.openPanel != panel) return;
      _frameScheduler(() {
        if (_closing || _model.openPanel != panel) return;
        _focusAdapter(ReaderFocusTarget.panel);
      });
    });
  }

  void _requestHeaderFocus() {
    _frameScheduler(() {
      if (_closing) return;
      _focusAdapter(ReaderFocusTarget.header);
    });
  }

  void _searchRequested(String query) {
    final document = _model.document;
    if (document == null || _closing || _suspended || _recovering) {
      return;
    }
    final revision = ++_searchRevision;
    _searchQuery = query.trim();
    _searchError = null;
    _searchCurrentIndex = 0;
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
      _emit(_model.copyWith(toolError: _describeError(error)));
      return;
    }
    _toolCancellations.add(cancellation);
    _searchCancellations.add(cancellation);
    _activeBridgeOperations += 1;
    final generation = _model.generation;
    final pdf = _pdfDocument;
    _emit(_model.copyWith(searchBusy: true, toolError: null));
    unawaited(() async {
      try {
        final results = document.format == FlutterBookFormat.pdf
            ? await (pdf ??
                      (throw StateError('PDF engine document is missing')))
                  .search(_searchQuery)
            : await _records.searchDocument(
                document: document,
                text: _readerText(document, cancellation),
                query: _searchQuery,
                cancellationId: cancellation,
              );
        dispatch(_ReaderSearchCompleted(generation, revision, results));
      } catch (error) {
        dispatch(
          _ReaderSearchFailed(generation, revision, _describeError(error)),
        );
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
    // A bookmark marks the page being read, in its own offsets, even when a
    // PDF spread shows it beside another.
    final (:unit, :offset) = _model.readingLocation;
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
          ? _records.toggleBookmark(
              bookId: bookId,
              unit: BigInt.from(unit),
              offset: offset == null ? null : BigInt.from(offset),
            )
          : _records.deleteBookmark(id: existing.id),
    );
  }

  void _bookmarkNoteRequested(FlutterBookmark? bookmark) {
    if (_model.bookmarkBusy || _closing || _suspended || _recovering) return;
    final generation = _model.generation;
    final revision = ++_bookmarkRevision;
    final bookId = _model.document?.bookId;
    final (:unit, :offset) = _model.readingLocation;
    if (bookId == null) return;
    final token = ++_noteEditorToken;
    _activeNoteEditor = _ReaderNoteTarget.bookmark;
    _activeNoteEditorToken = token;
    // The owned modal slot is published with the same emission that starts the
    // dialog (contract §3.1 `modalEffect`).
    _emit(_model.copyWith(bookmarkBusy: true, toolError: null));
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
          _ReaderBookmarkNoteEditFailed(
            generation,
            revision,
            _describeError(error),
          ),
        );
      } finally {
        dispatch(_ReaderNoteEditorFinished(token));
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
          ? _records.toggleBookmark(
              bookId: message.bookId,
              unit: BigInt.from(message.unit),
              offset: message.offset == null
                  ? null
                  : BigInt.from(message.offset!),
              note: message.note,
            )
          : _records.updateBookmarkNote(
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
      mutation: () => _records.deleteBookmark(id: id),
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
      _emit(
        _model.copyWith(bookmarkBusy: false, toolError: _describeError(error)),
      );
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
        final items = await _records.listBookmarks(
          bookId: bookId,
          cancellationId: cancellation,
        );
        dispatch(_ReaderBookmarksCompleted(generation, revision, items));
      } catch (error) {
        if (!mutationCommitted) writeError = _describeError(error);
        dispatch(
          _ReaderBookmarksFailed(
            generation,
            revision,
            _describeError(error),
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

  /// Exports the book's bookmarks as Markdown through the guarded effect (RD-08).
  ///
  /// The bridge returns the Markdown text; the injected sink delivers it (the
  /// screen's default copies it to the clipboard) and a brief success notice is
  /// reported through the application notice center. A failure stays visible as
  /// the panel's export error and a persistent notice.
  void _bookmarkExportRequested() {
    final bookId = _model.document?.bookId;
    if (bookId == null ||
        _model.exportState == ReaderExportState.busy ||
        _closing ||
        _suspended ||
        _recovering) {
      return;
    }
    final generation = _model.generation;
    final revision = ++_exportRevision;
    _activeBridgeOperations += 1;
    _emit(
      _model.copyWith(exportState: ReaderExportState.busy, exportError: null),
    );
    unawaited(() async {
      try {
        final markdown = await _records.exportBookmarks(bookId: bookId);
        // A stale export must not deliver its text: an older book's Markdown
        // would overwrite the newer export's clipboard/notice.
        if (!_isCurrent(generation) || revision != _exportRevision) {
          return;
        }
        await _exportSink(markdown);
        dispatch(_ReaderBookmarkExportCompleted(generation, revision));
      } catch (error) {
        dispatch(
          _ReaderBookmarkExportFailed(
            generation,
            revision,
            _describeError(error),
          ),
        );
      } finally {
        dispatch(_ReaderBookmarkExportFinished());
      }
    }());
  }

  /// Retires the document-picker owner when the generation changes.
  ///
  /// The slot must be released by the transition that invalidates the effect
  /// (open, suspension, disposal), not by a completion that is then rejected as
  /// stale; otherwise the modal gate would stay set forever (contract §3.1).
  void _retireDocumentPicker() {
    _documentPickerRevision += 1;
    _documentPickerActive = false;
  }

  /// Starts the injected document picker for the more panel's open book (RD-10).
  ///
  /// The modal slot is published before the adapter starts and cleared on its
  /// completion; cancellation is neutral and the picked document opens through
  /// the normal open path. Real tab creation is 5F.
  void _openBookRequested() {
    if (_closing ||
        _suspended ||
        _recovering ||
        _documentPickerActive ||
        _model.busy ||
        _model.relayoutBusy) {
      return;
    }
    final generation = _model.generation;
    final revision = ++_documentPickerRevision;
    _documentPickerActive = true;
    _emit(_model);
    unawaited(() async {
      try {
        final picked = await _documentPickerAdapter();
        dispatch(_ReaderDocumentPickerCompleted(generation, revision, picked));
      } catch (error) {
        dispatch(
          _ReaderDocumentPickerFailed(
            generation,
            revision,
            _describeError(error),
          ),
        );
      }
    }());
  }

  /// Lays out one EPUB chapter with the Dart engine and installs the page
  /// window around the requested location.
  ///
  /// Throws when the chapter cannot be laid out (the archive could not be read
  /// or parsed, or [unit] is not one of its chapters); the relayout effect
  /// reports the failure.
  Future<void> _epubRelayout(
    FlutterDocumentSummary document,
    int generation,
    int revision,
    BigInt cancellation,
    int unit,
    ReaderLayout layout, {
    double? height,
    int? offset,
    int? length,
    bool replaceReadingOffset = false,
  }) async {
    final pageHeight =
        _epubPageHeight(height) ??
        (throw StateError('The reader has no page height yet'));
    final source = await _ensureEpubSource(document, generation);
    if (!_isCurrentLayout(generation, revision)) return;
    if (unit < 0 || unit >= source.book.chapters.length) {
      throw RangeError.index(unit, source.book.chapters, 'unit');
    }
    // One block is measured by one synchronous call, so a chapter whose single
    // paragraph or container is over the bounded-work ceilings is refused
    // before any layout (or image decode) runs; the relayout effect reports
    // the typed refusal.
    final refusal = source.layoutLimitExceeded(unit);
    if (refusal != null) throw refusal;
    // A continuous chapter lays out only a window around the viewport, so any
    // admitted chapter reads continuously however long it is.
    final continuous = _typographyContinuous;
    final chapter = source.book.chapters[unit];
    try {
      await source.ensureImages(chapter, _epubImageDecoder);
    } catch (_) {
      // A decode failure is not fatal: the layout paints the alt fallback.
    }
    if (!_isCurrentLayout(generation, revision)) return;
    final key = _EpubLayoutKey(
      generation: generation,
      unit: unit,
      width: layout.width,
      height: pageHeight,
      fontSize: layout.fontSize,
      lineSpacing: layout.lineSpacing,
      theme: _typographyTheme,
      continuous: continuous,
      // A continuous chapter is one scrolled column; only pages pair up.
      spread: layout.spread && !continuous,
    );
    final pageBox = epubPageBoxFor(ui.Size(key.pageWidth, pageHeight));
    final spec = ChapterLayoutSpec(
      width: pageBox.contentWidth,
      height: pageBox.contentHeight,
      typography: _epubTypography(layout, source),
    );
    // An explicit replacement with no offset is a chapter-level target: the
    // caller is replacing the durable position, so the reader goes to the
    // chapter start instead of keeping the stale offset the replacement is
    // meant to discard. A relayout without replacement keeps the reader's
    // position when it stays in the chapter.
    final target =
        (offset ??
                (replaceReadingOffset
                    ? null
                    : (unit == _model.unit ? _model.readingOffset : null)) ??
                0)
            .clamp(0, chapter.scalarCount);
    var session = _epubSession;
    final reusable =
        session != null &&
        _epubSessionKey == key &&
        (session.complete || !session.started || session.covers(target));
    // A replacement session belongs to *this effect* until its page is
    // accepted: the model still paints the installed session's page, and a
    // superseding relayout must not be able to dispose the session that page
    // belongs to. Only [_applyEpubPage] adopts it, together with the page.
    final replacement = reusable
        ? null
        : ChapterLayoutSession(
            chapter: chapter,
            spec: spec,
            images: source.images,
          );
    final active = replacement ?? session!;
    if (replacement != null) debugEpubSessionObserver?.call(replacement);
    // A replacement is this effect's to release until the page that carries it
    // is accepted; the `finally` covers every exit between here and adoption —
    // the first window measurement, a supersession, a suspension or a close
    // that invalidates the operation while its annotations are still in flight.
    var adopted = replacement == null;
    try {
      if (!active.started) active.layoutWindowAt(target);
      List<FlutterAnnotation> annotations = const [];
      String? annotationError;
      try {
        annotations = await _records.listAnnotations(
          document: document,
          text: _readerText(document, cancellation),
          scale: layout.scale,
          cancellationId: cancellation,
        );
      } catch (error) {
        annotationError = _describeError(error);
      }
      if (!_isCurrentLayout(generation, revision)) return;
      // The page is installed once, from the window around the requested
      // location. The remaining batches only *measure*: republishing on every
      // batch would overwrite a page turn, a selection or an annotation
      // snapshot the reader has since changed, and the model's own page turn
      // extends the session on demand (see [_epubPageAfter]).
      try {
        dispatch(
          _ReaderEpubPageLoaded(
            generation: generation,
            revision: revision,
            cancellation: cancellation,
            unit: unit,
            scalar: target,
            layout: layout,
            height: pageHeight,
            annotations: annotations,
            offset: offset,
            length: length,
            replaceReadingOffset: replaceReadingOffset,
            annotationError: annotationError,
            session: replacement,
            sessionKey: replacement == null ? null : key,
          ),
        );
      } finally {
        // The handler adopts the session before it publishes the page, so the
        // ownership transfer is settled even when publication unwinds: this
        // effect must never release a session the controller now owns.
        adopted = replacement == null || identical(_epubSession, replacement);
      }
      // A continuous window grows and shrinks with the viewport instead (see
      // [_continuousWindowTick]): measuring the whole chapter would retain it.
      if (!adopted || continuous) return;
      while (!active.complete) {
        // A real event-loop turn: frames and input run between batches.
        await Future<void>.delayed(const Duration(milliseconds: 1));
        if (!_isCurrentLayout(generation, revision)) return;
        final progressed = active.lastNodeIndex + 1 < active.totalNodes
            ? active.layoutForward(maxNodes: 24, maxMicros: 8000)
            : active.layoutBackward(maxNodes: 24, maxMicros: 8000);
        if (progressed == 0) return;
      }
    } finally {
      if (!adopted && replacement != null) {
        // The page never installed (or the handler rejected it), so nothing
        // paints this session: its owner releases it here. It is not deferred
        // to a frame, because no frame references it.
        replacement.dispose();
      }
    }
  }

  /// The open [document]'s text for annotations and book search: PDF pages
  /// from [pdf] (the current engine document when null), EPUB chapters in the
  /// canonical stream every selection surface indexes, with their resource
  /// paths.
  ReaderText _readerText(
    FlutterDocumentSummary document,
    BigInt cancellation, {
    PdfEngineDocument? pdf,
  }) {
    if (document.format == FlutterBookFormat.pdf) {
      return PdfReaderText(
        pdf ??
            _pdfDocument ??
            (throw StateError('PDF engine document is missing')),
      );
    }
    final generation = _model.generation;
    Future<EpubChapter> chapter(int unit) async {
      final chapters = (await _ensureEpubSource(
        document,
        generation,
      )).book.chapters;
      if (unit < 0 || unit >= chapters.length) {
        throw RangeError.index(unit, chapters, 'unit');
      }
      return chapters[unit];
    }

    return EpubReaderText(
      unitCount: document.logicalUnitCount.toInt(),
      text: (unit) async => (await chapter(unit)).canonicalText,
      resourcePath: (unit) async => (await chapter(unit)).resource,
    );
  }

  /// The parsed source for [document], opened once per generation.
  ///
  /// Opening is single-flight per generation: concurrent relayouts await the
  /// same load instead of racing to adopt two sources (the loser's decoded
  /// images would be released under the winner's session). Throws when the
  /// archive cannot be read or parsed, or when the document was replaced
  /// while it loaded.
  Future<EpubContentSource> _ensureEpubSource(
    FlutterDocumentSummary document,
    int generation,
  ) {
    final existing = _epubSource;
    if (existing != null && _epubSourceGeneration == generation) {
      return Future<EpubContentSource>.value(existing);
    }
    if (_epubSourceGeneration == generation) {
      final load = _epubSourceLoad;
      if (load != null) return load;
    } else {
      // A load for another generation belongs to a document that is gone.
      _cancelEpubSourceLoad();
      _epubSourceGeneration = generation;
    }
    final BigInt cancellation;
    try {
      cancellation = _bridge.createCancellation();
    } catch (error) {
      return Future<EpubContentSource>.error(error);
    }
    _epubSourceCancellation = cancellation;
    _activeBridgeOperations += 1;
    final load = _openEpubSource(document, generation, cancellation);
    _epubSourceLoad = load;
    // A failed load is not remembered: the next relayout retries it instead of
    // awaiting the settled failure, which would also pin the caller to the
    // zone the first attempt ran in. Concurrent callers already hold this
    // future, so the single-flight guarantee is preserved for them.
    unawaited(
      load.then(
        (_) => dispatch(_ReaderEpubSourceFinished(cancellation)),
        onError: (_) {
          if (identical(_epubSourceLoad, load)) _epubSourceLoad = null;
          dispatch(_ReaderEpubSourceFinished(cancellation));
        },
      ),
    );
    return load;
  }

  /// Cancels the in-flight source load, if any.
  void _cancelEpubSourceLoad() {
    final cancellation = _epubSourceCancellation;
    if (cancellation == null) return;
    _epubSourceCancellation = null;
    _bridge.cancel(id: cancellation);
  }

  /// Loads, parses and adopts one document's source.
  Future<EpubContentSource> _openEpubSource(
    FlutterDocumentSummary document,
    int generation,
    BigInt cancellation,
  ) async {
    void ensureCurrent() {
      if (!_isCurrent(generation) || _epubSourceGeneration != generation) {
        throw const FlutterBridgeError(
          kind: FlutterBridgeErrorKind.cancelled,
          message: 'The document was replaced while it loaded.',
        );
      }
    }

    final book = await _bridge.epubBook(
      document: document.handle,
      cancellationId: cancellation,
    );
    ensureCurrent();
    final families = <String, String>{};
    for (final entry in book.embeddedFonts.entries) {
      final resource = book.resources[entry.value];
      if (resource == null) continue;
      final family = _epubFontFamily(entry.key, entry.value, resource.bytes);
      if (_registeredEpubFonts.add(family)) {
        try {
          await _epubFontRegistrar(family, Uint8List.fromList(resource.bytes));
        } catch (_) {
          _registeredEpubFonts.remove(family);
          continue;
        }
      }
      families[entry.key] = family;
    }
    ensureCurrent();
    final source = EpubContentSource(book: book, embeddedFamilies: families);
    // Adoption replaces the source without touching the generation/load
    // bookkeeping, so a concurrent relayout for the same document keeps sharing
    // this one load instead of starting a second.
    final previous = _epubSource;
    _epubSource = source;
    _epubSourceLoad = null;
    if (previous != null) _frameScheduler(previous.dispose);
    return source;
  }

  /// The Dart layout typography for [layout].
  ReaderEpubTypography _epubTypography(
    ReaderLayout layout,
    EpubContentSource source,
  ) => ReaderEpubTypography(
    // The book face (`docs/typography.md`): Literata for Latin text. Japanese
    // falls back to the interface face until the reading mincho is bundled.
    fontFamily: ShosaiTokens.typeFamilyEditorialLatinFlutter,
    fontFamilyFallback: const [shosaiJapaneseInterfaceFontFamily],
    fontSize: layout.fontSize,
    lineHeight: layout.lineSpacing,
    palette: ReaderEpubPalette.of(_typographyTheme),
    embeddedFamilies: source.embeddedFamilies,
  );

  /// A process-stable family name for one `@font-face` declaration.
  ///
  /// The identity is the *content*: the declared name is namespaced by a hash of
  /// the resource path and the face's own bytes, so two books that declare the
  /// same family at the same path with different faces cannot collide, and the
  /// same book reopened reuses its registration instead of adding a second face.
  static String _epubFontFamily(
    String declared,
    String resource,
    List<int> bytes,
  ) {
    var hash = 0x811c9dc5;
    for (final unit in resource.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0x7fffffff;
    }
    for (final byte in bytes) {
      hash ^= byte;
      hash = (hash * 0x01000193) & 0x7fffffff;
    }
    final safe = declared.replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), '_').trim();
    return 'shosai-epub-$hash-${safe.isEmpty ? 'face' : safe}';
  }

  /// The continuous page of [session]'s window at [key], answering [scalar].
  ReaderEpubPage _continuousPage(
    ChapterLayoutSession session,
    _EpubLayoutKey key,
    int scalar, {
    double priorityTop = 0,
    int? selectionBudgetMicros,
    int? restartedAt,
  }) {
    var extents = _continuousExtents;
    if (extents == null || _continuousExtentsKey != key) {
      extents = ContinuousExtents(session.chapter);
      _continuousExtents = extents;
      _continuousExtentsKey = key;
      // The column is new, so the region the view reported is in the old
      // one's coordinates: the window waits for the view's next report.
      _continuousViewport = null;
    }
    final cache = _continuousCaches[session] ??= ContinuousGeometryCache(
      session.chapter,
    );
    return continuousWindowFor(
      session: session,
      extents: extents,
      cache: cache,
      scalar: scalar,
      unit: key.unit,
      chapterCount: _model.document?.logicalUnitCount.toInt() ?? key.unit + 1,
      windowSize: ui.Size(key.width, key.height),
      priorityTop: priorityTop,
      selectionBudgetMicros: selectionBudgetMicros,
      restartedAt: restartedAt,
    );
  }

  /// Lays out the continuous geometry a keyboard movement from [focus] needs,
  /// one bounded step of it, and installs it; false when there is nothing more
  /// to lay out.
  ///
  /// A focus outside the window restarts the window at the focus's node (one
  /// bounded batch, and the node before it) and reveals it, like a location
  /// request that keeps the selection. Inside the window, selection geometry
  /// still pending is built nearest the focus first; otherwise the window
  /// grows by one batch in the movement's direction. Each is one bounded step,
  /// in the message handler; a movement that needs more steps continues in a
  /// later frame ([_ReaderSelectionMovementContinued]).
  ///
  /// A continued movement ([probe]) is searching past the focus for the next
  /// caret: it never restarts at the focus, and once the window is
  /// [_kContinuousProbeViewports] tall it restarts at the node just past the
  /// window's edge instead of growing, and reveals that frontier. The search is then
  /// bounded in memory however far the next text is.
  bool _continuousEnsureSelectionGeometry(
    int focus,
    bool forward, {
    bool probe = false,
  }) {
    final session = _epubSession;
    final key = _epubSessionKey;
    final page = _model.epubPage;
    final extents = _continuousExtents;
    if (session == null ||
        key == null ||
        !key.continuous ||
        page == null ||
        !page.continuous ||
        extents == null ||
        _continuousExtentsKey != key) {
      return false;
    }
    var node = session.nodeIndexForScalar(focus);
    final outside =
        !session.started ||
        node < session.firstNodeIndex ||
        node > session.lastNodeIndex;
    final pending = _continuousCaches[session]?.selectionPending ?? false;
    final tops = extents.tops();
    // The node a probe restarts at, past the window's edge, when the window
    // is as tall as a probe may make it.
    int? frontier;
    if (probe && !pending && session.started) {
      final height =
          tops[session.lastNodeIndex + 1] - tops[session.firstNodeIndex];
      if (height > _kContinuousProbeViewports * key.height) {
        if (forward) {
          if (session.lastNodeIndex + 1 >= session.totalNodes) return false;
          frontier = session.lastNodeIndex + 1;
        } else {
          if (session.firstNodeIndex == 0) return false;
          frontier = session.firstNodeIndex - 1;
        }
      }
    }
    final restart = outside && !probe;
    final reveal = restart || frontier != null;
    var target = page.targetScalar;
    final ReaderEpubPage next;
    try {
      if (restart) {
        _detachedEpubBlocks.addAll(session.releaseAll());
        session.layoutWindowAt(
          focus,
          maxNodes: kContinuousBatchNodes,
          maxMicros: kContinuousBatchMicros,
        );
        session.layoutBackward(maxNodes: 1, maxMicros: kContinuousBatchMicros);
        target = focus;
      } else if (frontier != null) {
        _detachedEpubBlocks.addAll(session.releaseAll());
        // The frontier adjoins what the probe has searched: forward, the
        // window is laid out from it; backward, it is the frontier node alone
        // and grows backward, since a window laid out forward from further
        // back could stop at a tall node and leave the nodes before the
        // frontier unexamined.
        session.layoutWindowAt(
          0,
          node: frontier,
          maxNodes: forward ? _kContinuousProbeNodes : 1,
          maxMicros: kContinuousBatchMicros,
        );
        node = frontier;
        target = session.chapter.blocks[frontier].canonical?.start ?? focus;
      } else if (!pending) {
        // A probe grows by more nodes per step: the nodes it crosses have no
        // text, so the time budget bounds the step.
        final nodes = probe ? _kContinuousProbeNodes : kContinuousBatchNodes;
        final grown = forward
            ? session.layoutForward(
                maxNodes: nodes,
                maxMicros: kContinuousBatchMicros,
              )
            : session.layoutBackward(
                maxNodes: nodes,
                maxMicros: kContinuousBatchMicros,
              );
        if (grown == 0) return false;
      }
      next = _continuousPage(
        session,
        key,
        target,
        priorityTop: restart
            ? 0.0
            : extents.tops()[math.min(
                math.max(node, session.firstNodeIndex),
                session.lastNodeIndex,
              )],
        // A restarted window is one batch: all of its selection geometry is
        // built, so the focus's caret exists when the focus has one.
        selectionBudgetMicros: restart ? null : kContinuousSelectionMicros,
      );
    } catch (error) {
      // Detached blocks stay owned until the page painting them is replaced.
      _emit(_model.copyWith(relayoutError: 'Layout failed: $error'));
      return false;
    }
    if (reveal) _continuousViewport = null;
    _publish(
      _deriveModel(
        _model.copyWith(
          epubPage: next,
          selectionSurface: _freezeSurface(next.surface),
          selectionVisualLine: null,
          locationRequestRevision: reveal
              ? _model.locationRequestRevision + 1
              : _model.locationRequestRevision,
        ),
      ),
    );
    _releaseDetachedEpubBlocks();
    _scheduleContinuousTick();
    return true;
  }

  void _continuousViewportChanged(ReaderContinuousViewportChanged message) {
    final page = _model.epubPage;
    final window = page?.window;
    final reported = message.window;
    if (page == null ||
        !page.continuous ||
        window == null ||
        reported == null ||
        message.generation != _model.generation ||
        message.revision != _model.locationRequestRevision ||
        reported.nodeTops.length != window.nodeTops.length) {
      return;
    }
    // The view reports in the column of the page it built; a tick may have
    // installed a newer page since, in the same frame. The region is mapped
    // into the current column by the correction the view applies to it, so
    // a window that keeps changing still follows the view.
    final top = continuousCorrectedTop(
      reported,
      window,
      message.top - kEpubPageMargin,
    );
    _continuousViewport = (
      top: top,
      bottom: top + message.bottom - message.top,
    );
    _scheduleContinuousTick();
  }

  /// Schedules one window step after the next frame, unless one is pending.
  void _scheduleContinuousTick() {
    final generation = _model.generation;
    final revision = _layoutRevision;
    if (_closing ||
        _continuousTickFor == (generation: generation, revision: revision)) {
      return;
    }
    // A step pending for an older layout is superseded, not waited for.
    _continuousTickFor = (generation: generation, revision: revision);
    final token = ++_continuousTickToken;
    _frameScheduler(
      () => dispatch(_ReaderContinuousWindowTick(generation, revision, token)),
    );
  }

  /// Moves the continuous window one bounded step toward the viewport and
  /// installs the page of the new window.
  ///
  /// The step is the window's only layout work in a frame; when the window
  /// still does not cover the viewport's lead, the next step is scheduled for
  /// the next frame. Blocks the step released stay alive until the page that
  /// still paints them has been replaced on screen.
  void _continuousWindowTick(_ReaderContinuousWindowTick message) {
    if (message.token != _continuousTickToken) return;
    _continuousTickFor = null;
    final session = _epubSession;
    final key = _epubSessionKey;
    final page = _model.epubPage;
    final viewport = _continuousViewport;
    final extents = _continuousExtents;
    if (!_isCurrentLayout(message.generation, message.revision) ||
        session == null ||
        key == null ||
        !key.continuous ||
        page == null ||
        !page.continuous ||
        viewport == null ||
        extents == null ||
        _continuousExtentsKey != key ||
        _model.busy ||
        _model.relayoutBusy ||
        _closing ||
        _suspended ||
        _continuousMovement != null) {
      // A relayout in flight installs its own page and schedules a step then;
      // a keyboard movement owns the window until it lands, then schedules
      // one.
      return;
    }
    final stopwatch = Stopwatch()..start();
    final ContinuousWindowStep step;
    final ReaderEpubPage next;
    try {
      step = advanceContinuousWindow(
        session: session,
        extents: extents,
        viewportTop: viewport.top,
        viewportBottom: viewport.bottom,
        released: _detachedEpubBlocks,
      );
      final cache = _continuousCaches[session];
      if (!step.changed && !(cache?.selectionPending ?? false)) return;
      next = _continuousPage(
        session,
        key,
        page.targetScalar,
        priorityTop: viewport.top,
        selectionBudgetMicros: kContinuousSelectionMicros,
        restartedAt: step.restartedAt,
      );
    } catch (error) {
      // A failed batch adopted nothing; the page on screen stays valid.
      _emit(_model.copyWith(relayoutError: 'Layout failed: $error'));
      return;
    }
    // The content under the viewport's top keeps its place: the view scrolls
    // by the shift the measurement made ([continuousCorrectedTop]), and the
    // controller's copy of the viewport follows it until the view reports
    // again.
    final shift =
        continuousCorrectedTop(page.window!, next.window!, viewport.top) -
        viewport.top;
    _continuousViewport = (
      top: viewport.top + shift,
      bottom: viewport.bottom + shift,
    );
    _publish(
      _deriveModel(
        _model.copyWith(
          epubPage: next,
          selectionSurface: _freezeSurface(next.surface),
          // Line indexes change with the window; the preferred x does not.
          selectionVisualLine: null,
        ),
      ),
    );
    _releaseDetachedEpubBlocks();
    debugContinuousStepObserver?.call(stopwatch.elapsedMicroseconds);
    if (step.pending || _continuousCaches[session]!.selectionPending) {
      _scheduleContinuousTick();
    }
  }

  /// Releases [blocks] after the frame that stops painting them.
  void _releaseEpubBlocksAfterFrame(List<FlowBlock> blocks) {
    _releasedEpubBlocks.add(blocks);
    try {
      _frameScheduler(() {
        if (_releasedEpubBlocks.remove(blocks)) disposeFlowBlocks(blocks);
      });
    } catch (_) {
      _releasedEpubBlocks.remove(blocks);
      disposeFlowBlocks(blocks);
    }
  }

  /// Retires the active chapter session after the current frame.
  ///
  /// Deferred through the injected frame scheduler, so a page the model still
  /// renders in this frame keeps its measured paragraphs.
  void _retireEpubSession([
    ChapterLayoutSession? session,
    bool immediate = false,
  ]) {
    final retired = session ?? _epubSession;
    if (identical(retired, _epubSession)) {
      _epubSession = null;
      _epubSessionKey = null;
    }
    if (retired == null) return;
    // A replacement defers to the next frame, because the page the model still
    // renders in this frame keeps its measured paragraphs; a close disposes at
    // once, because no frame is coming and the painters must not be left to the
    // platform's finalizers.
    if (immediate) {
      retired.dispose();
      // No frame is coming: blocks the window released wait for none.
      _releasedEpubBlocks.add(_detachedEpubBlocks);
      _detachedEpubBlocks = [];
      for (final blocks in _releasedEpubBlocks) {
        disposeFlowBlocks(blocks);
      }
      _releasedEpubBlocks.clear();
      return;
    }
    // Blocks the window detached belong to the installed session only, so
    // they are released with it, after the frame that stops painting its page.
    _releaseDetachedEpubBlocks();
    try {
      _frameScheduler(retired.dispose);
    } catch (_) {
      // A scheduler that refuses the callback must not orphan the session: the
      // owner disposes it here instead, even though the current frame may still
      // paint it (a refused schedule is not an ordinary frame).
      retired.dispose();
    }
  }

  /// Retires the current document's parsed source and its decoded images.
  void _retireEpubSource({bool immediate = false}) {
    final retired = _epubSource;
    _epubSource = null;
    _epubSourceGeneration = null;
    _epubSourceLoad = null;
    _cancelEpubSourceLoad();
    if (retired == null) return;
    if (immediate) {
      retired.dispose();
    } else {
      _frameScheduler(retired.dispose);
    }
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
    double? height,
  }) async {
    ui.Image? ownedImage;
    final pdf = _pdfDocument;
    try {
      if (document.format == FlutterBookFormat.epub) {
        await _epubRelayout(
          document,
          generation,
          revision,
          cancellation,
          unit,
          layout,
          height: height,
          offset: offset,
          length: length,
          replaceReadingOffset: replaceReadingOffset,
        );
        return;
      }
      if (pdf == null) throw StateError('PDF engine document is missing');
      // A spread is addressed by its first page; a location on its second
      // page moves past the first page's text in the spread's surface.
      final target = unit;
      unit = layout.spread ? pdfSpreadStart(unit) : unit;
      final facing = _pdfFacingUnit(pdf, unit, layout);
      FlutterSelectionSurface? surface;
      ReaderPdfSpread? spread;
      String? selectionError;
      try {
        (:surface, :spread) = await _pdfSurface(
          pdf,
          unit,
          layout.scale,
          facing: facing,
        );
        if (!_isCurrentLayout(generation, revision)) {
          return;
        }
      } catch (error) {
        selectionError = _describeError(error);
        // The spread still shows and turns both pages; with no text, a
        // location on either is the page's top.
        spread = _textlessSpread(facing);
        offset = null;
        length = null;
      }
      if (offset != null && spread != null && target == spread.facingUnit) {
        offset += spread.textShift;
      }
      final (rendered, rasterScale) = await _renderPdfPage(
        pdf,
        unit,
        layout,
        facing: facing,
      );
      if (!_isCurrentLayout(generation, revision)) {
        return;
      }
      ownedImage = await _decoder(
        rendered.pixels,
        width: rendered.width,
        height: rendered.height,
      );
      if (!_isCurrentLayout(generation, revision)) {
        return;
      }
      List<FlutterAnnotation> annotations = const [];
      String? annotationError;
      try {
        annotations = await _records.listAnnotations(
          document: document,
          text: _readerText(document, cancellation),
          scale: layout.scale,
          cancellationId: cancellation,
        );
      } catch (error) {
        annotationError = _describeError(error);
      }
      if (!_isCurrentLayout(generation, revision)) {
        return;
      }
      dispatch(
        _ReaderRelayoutCompleted(
          generation: generation,
          revision: revision,
          cancellation: cancellation,
          unit: unit,
          layout: layout,
          surface: surface,
          pdfSpread: spread,
          readingPage: target,
          pageImage: ownedImage,
          annotations: annotations,
          offset: offset,
          length: length,
          replaceReadingOffset: replaceReadingOffset,
          selectionError: selectionError,
          annotationError: annotationError,
          rasterScale: rasterScale,
        ),
      );
      ownedImage = null;
    } on EpubLayoutLimitExceeded catch (refusal) {
      dispatch(
        _ReaderRelayoutFailed(
          generation: generation,
          revision: revision,
          layout: layout,
          error: refusal.message,
          limit: refusal,
        ),
      );
    } catch (error) {
      dispatch(
        _ReaderRelayoutFailed(
          generation: generation,
          revision: revision,
          layout: layout,
          error: _describeError(error),
        ),
      );
    } finally {
      ownedImage?.dispose();
      dispatch(_ReaderRelayoutFinished(cancellation));
    }
  }

  void _relayoutCompleted(_ReaderRelayoutCompleted message) {
    if (!_isCurrentLayout(message.generation, message.revision) ||
        !_relayoutCancellations.contains(message.cancellation)) {
      message.pageImage.dispose();
      return;
    }
    final oldImage = _model.pageImage;
    _renderedRasterScale = message.rasterScale;
    _activeRelayoutIntent = null;
    final explicitLocation =
        message.offset != null || message.replaceReadingOffset;
    // The page read can change within a PDF spread, its unit staying put.
    final readingPage = message.readingPage ?? message.unit;
    final changedPage = readingPage != _model.readingLocation.unit;
    final changedLocation =
        message.unit != _model.unit || changedPage || explicitLocation;
    if (changedLocation) _readingStatePersistenceBlocked = false;
    final int? readingOffset;
    if (message.pdfSpread != null && message.surface == null) {
      // A spread without text has no offsets to place a reading position
      // by; its page alone keeps it.
      readingOffset = null;
    } else if (changedPage || explicitLocation) {
      // Another page takes the offset asked for with it, or none: the old
      // page's offset is not a place on the new one.
      readingOffset = message.offset;
    } else if (message.pdfSpread != _model.pdfSpread) {
      // The page being read keeps its place when a PDF spread is made or
      // undone: its own offset, moved past the first page's text when it is
      // now the spread's second page.
      final location = _model.readingLocation;
      final offset = location.offset;
      final spread = message.pdfSpread;
      readingOffset = offset == null
          ? null
          : location.unit == message.unit
          ? offset
          : location.unit == spread?.facingUnit
          ? offset + spread!.textShift
          : null;
    } else {
      readingOffset = _model.readingOffset;
    }
    _emit(
      _model.copyWith(
        unit: message.unit,
        readingOffset: readingOffset,
        // The more panel's page input follows the reader's location, the way
        // the pinned reference syncs `page_input` on navigation (RD-10).
        pageInput: changedLocation
            ? ReaderPageInputPresentation(draft: '${readingPage + 1}')
            : _model.pageInput,
        pageImage: message.pageImage,
        selectionSurface: message.surface == null
            ? null
            : _freezeSurface(message.surface!),
        pdfSpread: message.pdfSpread,
        readingPage: message.pdfSpread == null ? null : message.readingPage,
        annotations: message.annotations,
        savedSelections: _savedSelections(
          message.annotations,
          message.unit,
          message.pdfSpread,
        ),
        anchor: message.offset ?? _model.anchor,
        focus: message.offset == null
            ? _model.focus
            : message.offset! + (message.length ?? 0),
        selectionPhase: message.length == null
            ? _model.selectionPhase
            : ReaderSelectionPhase.selected,
        relayoutError: null,
        annotationsReady: message.annotationError == null,
        annotationError:
            message.annotationError ??
            (_model.annotationsReady ? _model.annotationError : null),
        layout: message.layout,
        relayoutBusy: false,
        relayoutPending: false,
        contentState: ReaderContentState.ready,
        selectionError: message.selectionError,
        selectionVisualLine: null,
        selectionPreferredX: null,
      ),
    );
    oldImage?.dispose();
    if (message.length != null) {
      _frameScheduler(
        () => dispatch(
          _ReaderSurfaceFocusReady(message.generation, message.revision),
        ),
      );
    }
    final bookId = _model.document?.bookId;
    if (bookId != null) {
      // A location on a spread's second page is saved on that page, in its
      // own offsets, so it reopens there in one page or two.
      // Both of a spread's pages count as read, so its last spread finishes
      // the book.
      final (:unit, :offset) = _model.readingLocation;
      final lastUnit = message.pdfSpread?.facingUnit;
      _queueReadingStateSave(
        bookId,
        _model.document!.logicalUnitCount,
        FlutterReadingState(
          unit: BigInt.from(unit),
          offset: offset == null ? null : BigInt.from(offset),
          zoom: message.layout.scale,
          lastUnit: lastUnit != null && lastUnit > unit
              ? BigInt.from(lastUnit)
              : null,
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
            await _records.saveReadingState(
              bookId: bookId,
              value: value,
              unitCount: unitCount,
            );
            dispatch(_ReaderReadingStateSaveSucceeded(generation, revision));
          } catch (error) {
            writeError = _describeError(error);
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
    _renderedRasterScale = message.rasterScale;
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

  void _selectionKeyboardExtended(
    ReaderSelectionMovement movement, {
    bool retried = false,
    bool probing = false,
  }) {
    // A key press supersedes a movement still continuing.
    if (!probing) _continuousMovement = null;
    final surface = _model.selectionSurface;
    // A continuous window may paint no text (a run of images) while the
    // selection's focus is in text outside it.
    final continuous = _model.epubPage?.continuous ?? false;
    if (surface == null ||
        (!continuous && surface.graphemeBoundaries.length < 2) ||
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
    // A continuous page's surface covers its laid-out window only; a focus
    // outside it (or at its edge) still moves by the chapter's own boundaries
    // around it.
    final around = current != null && continuous
        ? switch (_epubSession) {
            final session? => _continuousCaches[session]?.boundariesAround(
              current,
            ),
            null => null,
          }
        : null;
    final boundaries = switch (movement) {
      ReaderSelectionMovement.previousWord ||
      ReaderSelectionMovement.nextWord =>
        around?.words ?? surface.wordBoundaries.toList(growable: false),
      _ => around?.graphemes ?? graphemes,
    };
    // A continuous focus with no caret of its own (the separator after a
    // block, the chapter's end) moves visually to the nearest caret in the
    // movement's direction, once the geometry around it is laid out.
    final snapped =
        continuous &&
            current != null &&
            lineMove == null &&
            horizontalMove == null &&
            _caretForOffset(surface.visualLines, current, null) == null &&
            (probing || _continuousSelectionResolved(current)) &&
            !_continuousSelectionPending()
        ? switch (movement) {
            ReaderSelectionMovement.previousGrapheme ||
            ReaderSelectionMovement.nextGrapheme ||
            ReaderSelectionMovement.previousWord ||
            ReaderSelectionMovement.nextWord => null,
            _ => _nearestCaret(
              surface.visualLines,
              current,
              forward,
              movement == ReaderSelectionMovement.previousLine ||
                      movement == ReaderSelectionMovement.nextLine
                  ? _model.selectionPreferredX
                  : null,
            ),
          }
        : null;
    final next =
        lineMove?.offset ??
        horizontalMove?.offset ??
        snapped?.offset ??
        switch (movement) {
          ReaderSelectionMovement.previousGrapheme ||
          ReaderSelectionMovement.nextGrapheme ||
          ReaderSelectionMovement.previousWord ||
          ReaderSelectionMovement.nextWord =>
            current == null && boundaries.length < 2
                ? null
                : _adjacentOffset(boundaries, current, forward),
          ReaderSelectionMovement.previousLine ||
          ReaderSelectionMovement.nextLine ||
          ReaderSelectionMovement.lineStart ||
          ReaderSelectionMovement.lineEnd ||
          ReaderSelectionMovement.visualLeft ||
          ReaderSelectionMovement.visualRight => null,
        };
    if (next == null) {
      // A visual movement needs the focus's line and its neighbour laid out:
      // a continuous window that lacks them lays out one bounded step of
      // them, then the movement is tried again; when that is not yet enough
      // (a run of images, geometry still pending) it continues next frame.
      if (current != null &&
          _continuousEnsureSelectionGeometry(
            current,
            forward,
            probe: probing,
          )) {
        if (!retried) {
          _selectionKeyboardExtended(movement, retried: true);
        } else {
          // The movement owns the window until it lands: window steps toward
          // the viewport wait for it, so they cannot release what it laid out.
          final message = _ReaderSelectionMovementContinued(
            generation: _model.generation,
            layoutRevision: _layoutRevision,
            selectionRevision: _selectionRevision,
            focus: current,
            movement: movement,
          );
          _continuousMovement = message;
          _frameScheduler(() => dispatch(message));
        }
      }
      return;
    }
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
        snapped ??
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

  /// Continues a keyboard movement a continuous window could not complete in
  /// the frame it was pressed in, unless the selection, the layout or the
  /// document changed since.
  void _selectionMovementContinued(_ReaderSelectionMovementContinued message) {
    if (!identical(message, _continuousMovement)) return;
    _continuousMovement = null;
    if (_isCurrentLayout(message.generation, message.layoutRevision) &&
        message.selectionRevision == _selectionRevision &&
        message.focus == _model.focus) {
      _selectionKeyboardExtended(
        message.movement,
        retried: true,
        probing: true,
      );
    }
    // Landed or abandoned: the window follows the viewport again.
    if (_continuousMovement == null) _scheduleContinuousTick();
  }

  /// Whether the continuous window still has selection geometry to build.
  bool _continuousSelectionPending() => switch (_epubSession) {
    final session? => _continuousCaches[session]?.selectionPending ?? true,
    null => true,
  };

  /// Whether the continuous window holds [focus]'s node with all of its
  /// selection geometry built, so a caret missing at [focus] is missing from
  /// the chapter, not just from the window.
  bool _continuousSelectionResolved(int focus) {
    final session = _epubSession;
    if (session == null || !session.started) return false;
    final node = session.nodeIndexForScalar(focus);
    return node >= session.firstNodeIndex &&
        node <= session.lastNodeIndex &&
        !(_continuousCaches[session]?.selectionPending ?? true);
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
    // A continuous page's surface covers its window; the chapter is the
    // document the reader sees, so Select All selects all of it.
    final continuous = _model.epubPage?.continuous ?? false;
    final start = continuous ? 0 : surface.graphemeBoundaries.first;
    final end = continuous
        ? _epubSession?.chapter.scalarCount ?? surface.graphemeBoundaries.last
        : surface.graphemeBoundaries.last;
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
    final generation = _model.generation;
    final revision = ++_noteRevision;
    final selectionRevision = _selectionRevision;
    final token = ++_noteEditorToken;
    _activeNoteEditor = _ReaderNoteTarget.selection;
    _activeNoteEditorToken = token;
    // The owned modal slot is set before the adapter starts and published with
    // the same emission, so the chrome gates on the modal for the whole dialog
    // lifetime instead of only after an unrelated transition.
    _emit(_model.copyWith(selectionActionError: null));
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
            _describeError(error),
          ),
        );
      } finally {
        dispatch(_ReaderNoteEditorFinished(token));
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
            _describeError(error),
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
    final surface = _model.selectionSurface;
    if (document == null || surface == null) return;
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
      _emit(_model.copyWith(selectionActionError: _describeError(error)));
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
    // A highlight on a PDF spread belongs to the page it was made on, in that
    // page's own offsets and against its own surface.
    final spread = _model.pdfSpread;
    final pdf = _pdfDocument;
    final unit = spread?.unitOf(selection.start, _model.unit) ?? _model.unit;
    final start = spread?.pageOffset(selection.start) ?? selection.start;
    final end = spread?.pageOffset(selection.end) ?? selection.end;
    final scale = _model.layout.scale;
    unawaited(() async {
      var succeeded = false;
      String? writeError;
      try {
        final created = await _records.createAnnotation(
          document: document,
          surface: spread == null || pdf == null
              ? surface
              : await pdf.selectionSurface(unit, scale),
          unit: BigInt.from(unit),
          start: BigInt.from(start),
          end: BigInt.from(end),
          displayScale: scale,
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
        writeError = _describeError(error);
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
        savedSelections: _savedSelections(
          annotations,
          _model.unit,
          _model.pdfSpread,
        ),
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
        _emit(_model.copyWith(annotationError: _describeError(error)));
      }
      return;
    } catch (error) {
      if (_isCurrent(generation)) {
        _emit(_model.copyWith(annotationError: _describeError(error)));
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
      final changed = await _records.updateAnnotation(
        document: document,
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
      writeError = _describeError(error);
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
      final changed = await _records.deleteAnnotation(
        document: document,
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
      writeError = _describeError(error);
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
    final token = ++_noteEditorToken;
    _activeNoteEditor = _ReaderNoteTarget.annotation;
    _activeNoteEditorToken = token;
    // Publish the owned modal slot before the adapter starts (contract §3.1).
    _emit(_model);
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
          _ReaderAnnotationNoteFailed(
            generation,
            revision,
            _describeError(error),
          ),
        );
      } finally {
        dispatch(_ReaderNoteEditorFinished(token));
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
    if (document == null ||
        _model.busy ||
        _model.relayoutBusy ||
        _model.annotationOperations.isNotEmpty) {
      return;
    }
    if (_model.contentState != ReaderContentState.ready) {
      // An EPUB whose open ran before the first page height was reported is
      // laid out once the height is known.
      final height = _epubViewportHeight;
      if (_epubAwaitsFirstPage &&
          _epubHeightNeedsLayout(document, _requestedLayout, height)) {
        _startRelayout(document, _requestedLayout, height: height);
      }
      return;
    }
    if (_requestedLayout != _model.layout &&
        _requestedLayout != _failedLayout) {
      _startRelayout(document, _requestedLayout);
      return;
    }
    // A page-height change that arrived while the reader was busy is replayed
    // here: the reporter has already observed the new height, so nothing else
    // would ask for it.
    final height = _epubViewportHeight;
    if (_epubHeightNeedsLayout(document, _model.layout, height)) {
      _startRelayout(document, _model.layout, height: height);
      return;
    }
    // Likewise a PDF box or pixel ratio change that arrived while the reader
    // was busy renders the page at its latest fitted size.
    _refitPdfPage();
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
    // On the Dart path the annotation can sit on another page of the same
    // chapter: the guarded relayout resolves the offset to its page (and
    // rewindow the session when the current window does not reach it), instead
    // of leaving the reader on the page it was showing.
    if (_model.epubPage != null && range != null && unit == _model.unit) {
      final document = _model.document;
      if (document == null || _model.busy || _model.relayoutBusy) return;
      _startRelayout(
        document,
        _model.layout,
        unit: unit,
        offset: range.start.toInt(),
        length: range.end.toInt() - range.start.toInt(),
        height: _epubViewportHeight,
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
      _emit(_model.copyWith(annotationError: _describeError(error)));
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
      _emit(_model.copyWith(annotationError: _describeError(error)));
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
        annotations = await _records.listAnnotations(
          document: document,
          text: _readerText(document, cancellation),
          scale: _model.layout.scale,
          cancellationId: cancellation,
        );
      } catch (caught) {
        error = _describeError(caught);
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
      final page = await _records.listAnnotationAssociationSources(
        target: document,
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
          error: _describeError(error),
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
    _associationPickerRevision = message.revision;
    // Publish the owned modal slot before the picker adapter starts.
    _emit(_model);
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
        error = _describeError(caught);
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
    final current = _isCurrentAssociation(sources);
    // Clear the slot this completion owns (and only this one), including a
    // stale completion: leaving it set would keep the chrome gated on a modal
    // that is no longer open. A newer picker's slot is left alone.
    if (_associationPickerRevision == sources.revision) {
      _associationPickerActive = false;
      _associationPickerRevision = null;
      if (current) _emit(_model);
    }
    if (!current) {
      dispatch(_ReaderAssociationFinished(sources: sources));
      return;
    }
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
      final outcome = await _records.associateAnnotationVersion(
        sourceVersionId: selected.versionId,
        target: sources.document,
        cancellationId: sources.cancellation,
      );
      dispatch(_ReaderAssociationPersisted(sources: sources, outcome: outcome));
    } catch (error) {
      writeError = _describeError(error);
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
      final annotations = await _records.listAnnotations(
        document: sources.document,
        text: _readerText(sources.document, sources.cancellation),
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
              'Association saved, but highlights could not be loaded: '
              '${_describeError(error)}',
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

  void _selectionCancelled({bool requestSurfaceFocus = true}) {
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
    if (requestSurfaceFocus) _focusAdapter(ReaderFocusTarget.surface);
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
    unawaited(message.pdfDocument?.dispose());
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
      // The toolbar and status line name the current section, so an opened
      // document loads its contents without waiting for the panel.
      if (_model.document != null &&
          _model.contents.status == ReaderContentsStatus.loading &&
          !_contentsLoading) {
        _contentsRequested();
      }
      _startRequestedRelayoutIfReady();
    }
    _activeBridgeOperations -= 1;
    _recoverIfIdle();
    _disposeBridgeIfIdle();
  }

  void _suspendRequested() {
    if (_suspended || _closing) return;
    _suspended = true;
    _retireDocumentPicker();
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
    _cancelContentsEffects();
    _cancelEpubSourceLoad();
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

  /// Renders a bridge or platform error for the reader's error surfaces.
  ///
  /// `FlutterBridgeError` carries a kind and a message but no `toString()`, so a
  /// bare `_describeError(error)` renders as "Instance of 'FlutterBridgeError'" and
  /// hides the reason the user (and a bug report) needs.
  static String _describeError(Object error) => error is FlutterBridgeError
      ? '${error.message} (${error.kind.name})'
      : error.toString();

  bool _isCurrent(int generation) {
    return !_closing && generation == _model.generation;
  }

  void _emit(ReaderModel model, {bool notifyListeners = true}) =>
      _publish(_deriveModel(model), notifyListeners: notifyListeners);

  /// Completes [model] with the state the controller derives for it.
  ///
  /// Separate from [_publish] because a derivation can fail (the progress
  /// source is injected): a caller that also transfers resource ownership must
  /// derive *before* it commits, so a failing derivation leaves the published
  /// page and the installed session paired.
  ReaderModel _deriveModel(ReaderModel model) => model.copyWith(
    focus: _spreadFocus(model),
    progress: _deriveProgress(model),
    contents: _deriveContents(model),
    typography: _deriveTypography(model),
    search: _deriveSearch(model),
    modalEffect: _deriveModalEffect(),
  );

  /// The selection's focus, kept on the PDF page its anchor is on: each page
  /// of a spread keeps its own highlights, so a selection cannot run from one
  /// onto the other.
  int? _spreadFocus(ReaderModel model) {
    final spread = model.pdfSpread;
    final anchor = model.anchor;
    final focus = model.focus;
    if (spread == null || anchor == null || focus == null) return focus;
    return anchor >= spread.textShift
        ? math.max(focus, spread.textShift)
        : math.min(focus, spread.textShift - 1);
  }

  void _publish(ReaderModel derived, {bool notifyListeners = true}) {
    // The description reads the selected text out of the surface's canonical
    // stream (a whole chapter): skip it when nothing it depends on changed,
    // as on a continuous window step.
    final previous = _model;
    final selectionChanged =
        !(previous.selectionPhase == derived.selectionPhase &&
            previous.anchor == derived.anchor &&
            previous.focus == derived.focus &&
            previous.selectionSurface?.copyEligible ==
                derived.selectionSurface?.copyEligible &&
            identical(
              previous.selectionSurface?.text,
              derived.selectionSurface?.text,
            )) &&
        previous.selectionDescription != derived.selectionDescription;
    _model = derived;
    if (!_closing && selectionChanged && _selectionAnnouncer != null) {
      unawaited(_announceSelection(derived.selectionDescription));
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

  /// Applies the RD-05 wording precedence to [model].
  ///
  /// `loading` wins while an open is in flight, `none` when no document is
  /// loaded, and only then is the supplied presentation source consulted. The
  /// 4B default source is the retained logical-unit fallback: the document's
  /// unit ordinal with the format's display kind. Real page ranges, spreads and
  /// durable-location mapping are 5A/5G.
  ReaderProgressPresentation _deriveProgress(ReaderModel model) {
    if (model.busy) {
      return ReaderProgressPresentation(
        kind: ReaderProgressKind.loading,
        hasDocument: model.document != null,
      );
    }
    final document = model.document;
    if (document == null) {
      return const ReaderProgressPresentation(kind: ReaderProgressKind.none);
    }
    final supplied = _progressSource?.call(model);
    if (supplied != null) return supplied;
    final total = document.logicalUnitCount.toInt();
    final ordinal = model.unit + 1;
    // A PDF spread names both of its pages and counts the second as read.
    final last = (model.pdfSpread?.facingUnit ?? model.unit) + 1;
    return ReaderProgressPresentation(
      kind: last > ordinal
          ? ReaderProgressKind.range
          : ReaderProgressKind.single,
      hasDocument: true,
      displayUnit: document.format == FlutterBookFormat.epub
          ? ReaderDisplayUnit.chapter
          : ReaderDisplayUnit.page,
      firstOrdinal: ordinal,
      lastOrdinal: last > ordinal ? last : null,
      percentage: total <= 0 ? 0 : ((last / total) * 100).round().clamp(0, 100),
    );
  }

  /// The single controller-owned modal effect, derived from the effect slots.
  ReaderModalEffect? _deriveModalEffect() {
    if (_associationPickerActive) return ReaderModalEffect.associationPicker;
    if (_documentPickerActive) return ReaderModalEffect.documentPicker;
    return switch (_activeNoteEditor) {
      _ReaderNoteTarget.selection => ReaderModalEffect.selectionNote,
      _ReaderNoteTarget.annotation => ReaderModalEffect.annotationNote,
      _ReaderNoteTarget.bookmark => ReaderModalEffect.bookmarkNote,
      null => null,
    };
  }

  /// Applies the Contents precedence to [model] (RD-07).
  ///
  /// `loading` wins while an open is in flight or before a load starts, and
  /// the stored entries gain their `current` flag from the live unit; the
  /// entries themselves come from the guarded load effect. A real table of
  /// contents can name the same chapter several times, so exactly one entry is
  /// current: the last entry of the current chapter at or before the reader's
  /// durable offset (the chapter's first entry when the reader is before all of
  /// them, and none when the chapter has no row). The panel's reveal target is
  /// a single key, and marking every row of a chapter would duplicate it.
  ReaderContentsPresentation _deriveContents(ReaderModel model) {
    final contents = model.contents;
    if (model.busy || model.document == null) {
      return ReaderContentsPresentation(
        status: ReaderContentsStatus.loading,
        entries: contents.entries,
      );
    }
    final location = model.readingLocation;
    final readingOffset = location.offset ?? 0;
    var current = -1;
    for (var index = 0; index < contents.entries.length; index += 1) {
      final entry = contents.entries[index];
      if (entry.unit != location.unit) continue;
      if ((entry.offset ?? 0) <= readingOffset) current = index;
    }
    if (current < 0) {
      current = contents.entries.indexWhere(
        (entry) => entry.unit == location.unit,
      );
    }
    return ReaderContentsPresentation(
      status: contents.status,
      entries: [
        for (var index = 0; index < contents.entries.length; index += 1)
          contents.entries[index].copyWith(current: index == current),
      ],
      error: contents.error,
    );
  }

  /// The mode-specific typography presentation for [model] (RD-09).
  ///
  /// The document format comes from the open document; the reader-local values
  /// come from the panel's guarded changes and the screen's initial settings.
  ReaderTypographyPresentation _deriveTypography(ReaderModel model) =>
      ReaderTypographyPresentation(
        format: model.document?.format ?? model.typography.format,
        continuous: _typographyContinuous,
        theme: _typographyTheme,
        epubFontSize: _typographyFontSize,
        epubLineSpacing: _typographyLineSpacing,
        rasterFit: _rasterFit,
        rasterZoom: _rasterZoom,
        twoPages: _typographyTwoPages,
      );

  /// The search bar presentation for [model] (RD-11).
  ReaderSearchPresentation _deriveSearch(ReaderModel model) =>
      ReaderSearchPresentation(
        query: _searchQuery,
        busy: model.searchBusy,
        results: model.searchResults,
        currentIndex: model.searchResults.isEmpty
            ? 0
            : _searchCurrentIndex.clamp(0, model.searchResults.length - 1),
        error: _searchError,
      );

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
    final released = _model.copyWith(
      document: null,
      pageImage: null,
      epubPage: null,
      // A PDF spread describes the released document's surface; a document
      // opened through the same controller starts without one.
      pdfSpread: null,
      readingPage: null,
      selectionSurface: null,
      selectionPhase: ReaderSelectionPhase.idle,
      anchor: null,
      focus: null,
      selectionPointer: null,
      selectionVisualLine: null,
      selectionPreferredX: null,
      // A layout failure belongs to the document that failed to lay out: the
      // release path is shared by open/replacement, failed open, recovery and
      // dispose, so clearing it here keeps a stale "Layout failed" alert from
      // surviving into the next document (the next open clears the other error
      // fields in its own transition, but a successful open whose requested
      // layout already matches the committed one never runs a relayout to
      // clear this one).
      relayoutError: null,
      layoutRefusal: null,
    );
    if (publish) {
      _emit(released, notifyListeners: false);
    } else {
      _model = released;
    }
    pageImage?.dispose();
    _retireEpubSession(null, _closing);
    _retireEpubSource(immediate: _closing);
    // The column extents hold the chapter they measure.
    _continuousExtents = null;
    _continuousExtentsKey = null;
    _continuousViewport = null;
    _epubLayoutHeight = null;
    _epubHeightPending = false;
    if (document != null) {
      _bridge.releaseDocument(handle: document.handle);
    }
    final pdf = _pdfDocument;
    _pdfDocument = null;
    unawaited(pdf?.dispose());
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
    _cancelContentsEffects();
    _cancelEpubSourceLoad();
    _searchRevision += 1;
    _bookmarkRevision += 1;
    _retireDocumentPicker();
    _model = _model.copyWith(busy: false, generation: _model.generation + 1);
    _disposeBridgeIfIdle();
  }

  void _cancelActiveNoteEditor() {
    if (_activeNoteEditor == null) return;
    _activeNoteEditor = null;
    _activeNoteEditorToken = null;
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
    _associationPickerRevision = null;
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

/// The window height a continued keyboard movement grows the continuous
/// window to before it restarts the window at its frontier.
const double _kContinuousProbeViewports = 6;

/// The most nodes one step of a continued keyboard movement lays out.
const int _kContinuousProbeNodes = 64;

/// The caret nearest [offset] strictly in the direction [forward], with its
/// line and position along it; on that caret's line, the caret nearest
/// [preferredX] when given (a line movement keeps its column).
({int offset, int line, double preferredX})? _nearestCaret(
  List<FlutterSelectionVisualLine> lines,
  int offset,
  bool forward, [
  double? preferredX,
]) {
  ({int offset, int line, double preferredX})? best;
  for (var line = 0; line < lines.length; line += 1) {
    for (final caret in lines[line].carets) {
      final candidate = caret.offset.toInt();
      if (forward ? candidate <= offset : candidate >= offset) continue;
      if (best == null ||
          (forward ? candidate < best.offset : candidate > best.offset)) {
        best = (offset: candidate, line: line, preferredX: caret.alongLine);
      }
    }
  }
  if (best == null || preferredX == null) return best;
  final caret = lines[best.line].carets.reduce(
    (a, b) =>
        (b.alongLine - preferredX).abs() < (a.alongLine - preferredX).abs()
        ? b
        : a,
  );
  return (
    offset: caret.offset.toInt(),
    line: best.line,
    preferredX: preferredX,
  );
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

/// The saved highlights of [unit], in the offsets of the surface that shows
/// it: a PDF [spread]'s second page's highlights move past the first page's
/// text.
List<ReaderSelection> _savedSelections(
  List<FlutterAnnotation> annotations,
  int unit, [
  ReaderPdfSpread? spread,
]) => List.unmodifiable(
  annotations
      .where(
        (item) =>
            item.textRange != null &&
            (item.unit.toInt() == unit ||
                item.unit.toInt() == spread?.facingUnit),
      )
      .map((item) {
        final range = item.textRange!;
        final shift = item.unit.toInt() == unit ? 0 : spread!.textShift;
        return ReaderSelection(
          range.start.toInt() + shift,
          range.end.toInt() + shift,
          item.color,
        );
      }),
);

FlutterSelectionSurface _freezeSurface(FlutterSelectionSurface surface) {
  if ((_frozenSurfaces[surface] ?? false) || continuousSurfaceFrozen(surface)) {
    return surface;
  }
  final frozen = FlutterSelectionSurface(
    width: surface.width,
    height: surface.height,
    text: surface.text,
    copyEligible: surface.copyEligible,
    resourcePath: surface.resourcePath,
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

/// The default EPUB image decoder: none, so a reader built without one paints
/// the missing-image alt fallback instead of failing the layout.
Future<ui.Image?> _noEpubImage(Uint8List bytes) async => null;

/// The default embedded-font registrar: none, so an embedded family falls back
/// to the reader's base family.
Future<void> _noEpubFont(String family, Uint8List bytes) async {}
