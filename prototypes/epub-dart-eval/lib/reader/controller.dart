/// Elm-style reader controller for the evaluation prototype.
///
/// Widgets dispatch typed messages; message handling computes immutable model
/// transitions and starts controller-owned effects; effects report results with
/// revision-guarded typed completions. The controller owns images, fonts,
/// clipboard access and layout work.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:shosai_epub/shosai_epub.dart';

import 'effects.dart';
import 'geometry.dart';
import 'layout/cache.dart';
import 'layout/flow.dart';
import 'layout/text_style.dart';
import 'layout/pages.dart';
import 'message.dart';
import 'model.dart';
import 'theme.dart';

/// How the controller measures a chapter.
enum EpubLayoutStrategy {
  /// Measure every node before installing the layout. This is the
  /// pre-progressive baseline, kept for comparison.
  eager,

  /// Install a window around the durable location first, then extend it in
  /// bounded batches that yield to the event loop.
  progressive,
}

class EpubReaderController extends ChangeNotifier {
  EpubReaderController({
    EpubDocumentSource source = const EpubFileDocumentSource(),
    EpubClipboard clipboard = const EpubSystemClipboard(),
    EpubFontRegistrar fontRegistrar = const EpubEngineFontRegistrar(),
    EpubImageDecoder imageDecoder = const EpubEngineImageDecoder(),
    EpubPositionStore? positionStore,
    List<String> contentFallbackFamilies = const [],
    EpubLimits limits = const EpubLimits(),
    EpubLayoutStrategy layoutStrategy = EpubLayoutStrategy.progressive,
    EpubLayoutCache? layoutCache,
    this.onNotice,
  }) : _layoutStrategy = layoutStrategy,
       _layoutCache = layoutCache ?? EpubLayoutCache(),
       _contentFallbackFamilies = contentFallbackFamilies,
       _source = source,
       _clipboard = clipboard,
       _fontRegistrar = fontRegistrar,
       _imageDecoder = imageDecoder,
       _positionStore = positionStore ?? EpubMemoryPositionStore(),
       _limits = limits;

  final EpubDocumentSource _source;
  final EpubClipboard _clipboard;
  final EpubFontRegistrar _fontRegistrar;
  final EpubImageDecoder _imageDecoder;
  final EpubPositionStore _positionStore;
  final List<String> _contentFallbackFamilies;
  final EpubLimits _limits;
  final EpubLayoutStrategy _layoutStrategy;
  final EpubLayoutCache _layoutCache;

  /// The session the progressive driver is currently extending, if any.
  /// Navigation uses it to extend the laid-out range on demand.
  ChapterLayoutSession? _activeSession;
  _LayoutRequest? _activeRequest;

  /// Batch bounds for the progressive driver: one batch stays under a frame
  /// budget, and the driver yields between batches.
  static const int _layoutBatchNodes = 24;
  static const int _layoutBatchMicros = 8000;

  /// Total synchronous layout work this controller spent, microseconds.
  /// Measurement-only: wall time also includes the driver's yields.
  int _layoutWorkMicros = 0;
  int get layoutWorkMicros => _layoutWorkMicros;

  void _countSessionWork(ChapterLayoutSession session) {
    final delta = session.layoutWorkMicros - session.reportedWorkMicros;
    if (delta > 0) {
      _layoutWorkMicros += delta;
      session.reportedWorkMicros = session.layoutWorkMicros;
    }
  }

  /// Layout cache statistics, for measurement and tests.
  int get layoutCacheHits => _layoutCache.hits;
  int get layoutCacheMisses => _layoutCache.misses;
  int get layoutCacheEvictions => _layoutCache.evictions;
  final void Function(String message)? onNotice;

  EpubReaderModel get _initialModel => EpubReaderModel(
    typography: ReaderTypography(
      fontFamily: 'Inter',
      fontFamilyFallback: ['Noto Sans JP', ..._contentFallbackFamilies],
      fontSize: 18,
      lineHeight: 1.5,
      palette: ReaderPalette.light,
    ),
  );

  late EpubReaderModel _model = _initialModel;
  EpubReaderModel get model => _model;

  int _generation = 0;
  int _layoutRevision = 0;
  Timer? _relayoutTimer;
  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    _relayoutTimer?.cancel();
    _layoutCache.clear();
    _clearActiveSessionForDisposal();
    _releaseImages();
    super.dispose();
  }

  void _releaseImages() {
    for (final image in _model.images.values) {
      image.dispose();
    }
  }

  void dispatch(EpubReaderMessage message) {
    if (_disposed) return;
    switch (message) {
      case EpubReaderOpenRequested():
        _open(message);
      case EpubReaderViewportChanged():
        _viewportChanged(message);
      case EpubReaderModeChanged():
        _modeChanged(message);
      case EpubReaderFontSizeChanged():
        _fontSizeChanged(message);
      case EpubReaderThemeChanged():
        _themeChanged(message);
      case EpubReaderUnitRequested():
        _unitRequested(message);
      case EpubReaderScalarJumpRequested():
        _scalarJump(message);
      case EpubReaderContinuousOffsetChanged():
        _continuousOffsetChanged(message);
      case EpubReaderContentsToggled():
        _emit(_model.copyWith(contentsOpen: !_model.contentsOpen));
      case EpubReaderContentsEntryActivated():
        _emit(
          _model.copyWith(contentsOpen: false, contentsSpine: message.spine),
        );
        _scalarJump(
          EpubReaderScalarJumpRequested(
            spine: message.spine,
            scalar: message.scalar,
          ),
        );
      case EpubReaderTapRequested():
        _tapRequested(message.position);
      case EpubReaderSelectionStarted():
        _selectionStarted(message.position);
      case EpubReaderSelectionExtended():
        _selectionExtended(message.position);
      case EpubReaderSelectionEnded():
        if (_model.selection != null) {
          _emit(
            _model.copyWith(
              selection: _model.selection!.copyWith(
                phase: EpubSelectionPhase.selected,
              ),
            ),
          );
        }
      case EpubReaderSelectionCancelled():
        _emit(_model.copyWith(selection: null));
      case EpubReaderSelectionCopyRequested():
        _copySelection();
      case EpubReaderHighlightRequested():
        _createHighlight(message.color);
      case EpubReaderHighlightDeleted():
        _emit(
          _model.copyWith(
            highlights: [
              for (final highlight in _model.highlights)
                if (highlight.id != message.id) highlight,
            ],
          ),
        );
      case EpubReaderLinkActivated():
        _activateLink(message.href);
      case EpubReaderNoticeDismissed():
        _emit(_model.copyWith(notice: null));
      case EpubReaderDisposed():
        _releaseImages();
      case EpubReaderDocumentLoaded():
        _documentLoaded(message);
      case EpubReaderOpenFailed():
        _openFailed(message);
      case EpubReaderLayoutProgressed():
        _layoutProgressed(message);
      case EpubReaderLayoutCompleted():
        _layoutCompleted(message);
    }
  }

  void _emit(EpubReaderModel model, {bool notify = true}) {
    _model = model;
    if (notify && !_disposed) notifyListeners();
  }

  // -------------------------------------------------------------------------
  // Document open
  // -------------------------------------------------------------------------

  void _open(EpubReaderOpenRequested message) {
    _generation++;
    // The cache is scoped to one document lifetime: keys use internal
    // resource paths, which two books can share, and cached blocks can
    // reference images that `_releaseImages` is about to dispose.
    _layoutCache.clear();
    _clearActiveSessionForDisposal();
    _releaseImages();
    _emit(
      EpubReaderModel(
        status: EpubReaderStatus.loading,
        path: message.path,
        generation: _generation,
        mode: _model.mode,
        typography: _model.typography,
        theme: _model.theme,
        geometry: _model.geometry,
      ),
    );
    unawaited(_openEffect(message.path, _generation));
  }

  Future<void> _openEffect(String path, int generation) async {
    final stopwatch = Stopwatch()..start();
    try {
      final bytes = await _source.read(path);
      final stored = await _positionStore.read(path);
      final book = openEpubBytes(bytes, limits: _limits);
      final embeddedFamilies = <String, String>{};
      for (final entry in book.embeddedFonts.entries) {
        final resource = book.resources[entry.value];
        if (resource == null) continue;
        final family = 'shosai-epub-${_stableHash(entry.value)}';
        await _fontRegistrar.register(
          family,
          Uint8List.fromList(resource.bytes),
        );
        embeddedFamilies[entry.key] = family;
      }
      final images = <String, ui.Image>{};
      for (final resource in book.resources.values) {
        if (!resource.mediaType.startsWith('image/')) continue;
        final image = await _imageDecoder.decode(
          Uint8List.fromList(resource.bytes),
        );
        if (image != null) images[resource.path] = image;
      }
      if (_disposed || generation != _generation) {
        for (final image in images.values) {
          image.dispose();
        }
        return;
      }
      dispatch(
        EpubReaderDocumentLoaded(
          generation: generation,
          book: book,
          images: images,
          embeddedFamilies: embeddedFamilies,
          storedPosition: stored,
          elapsedMicros: stopwatch.elapsedMicroseconds,
        ),
      );
    } catch (error) {
      dispatch(EpubReaderOpenFailed(generation: generation, error: '$error'));
    }
  }

  void _documentLoaded(EpubReaderDocumentLoaded message) {
    if (message.generation != _generation) {
      for (final image in message.images.values) {
        image.dispose();
      }
      return;
    }
    final stored = message.storedPosition;
    final spine = stored == null
        ? 0
        : stored.spine
              .clamp(0, math.max(0, message.book.chapters.length - 1))
              .toInt();
    final scalar = stored == null
        ? 0
        : clampScalar(stored.scalar, message.book.chapters[spine].scalarCount);
    _emit(
      _model.copyWith(
        status: EpubReaderStatus.ready,
        book: message.book,
        images: message.images,
        embeddedFamilies: message.embeddedFamilies,
        warnings: message.book.warnings,
        spine: spine,
        scalar: scalar,
        unit: 0,
        error: null,
        firstContentMicros: message.elapsedMicros,
      ),
    );
    _startLayout(preserve: true);
  }

  void _openFailed(EpubReaderOpenFailed message) {
    if (message.generation != _generation) return;
    _emit(
      _model.copyWith(
        status: EpubReaderStatus.failed,
        error: message.error,
        notice: message.error,
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Layout
  // -------------------------------------------------------------------------

  EpubLayoutGeometry? _geometryFor(
    double width,
    double height, {
    EpubReaderMode? mode,
    ReaderTypography? typography,
  }) {
    final effectiveMode = mode ?? _model.mode;
    final effectiveTypography = typography ?? _model.typography;
    if (width <= 0 || height <= 0) return null;
    if (effectiveMode == EpubReaderMode.paginated) {
      final availableWidth = math.max(0.0, width - 48).toDouble();
      final availableHeight = math.max(0.0, height - 48).toDouble();
      final decision = spreadDecision(
        availableWidth: availableWidth,
        fontSize: effectiveTypography.fontSize,
      );
      final columnWidth =
          (decision.columns == 2
                  ? decision.usableColumnWidth
                  : availableWidth - 40)
              .toDouble();
      final contentHeight =
          (availableHeight -
                  40 -
                  (11 * 1.2 +
                      effectiveTypography.fontSize *
                          effectiveTypography.lineHeight))
              .toDouble();
      final pageWidth =
          (decision.columns == 2 ? (availableWidth - 20) / 2 : availableWidth)
              .toDouble();
      return EpubLayoutGeometry(
        viewportWidth: width,
        viewportHeight: height,
        contentWidth: math.max(120.0, columnWidth).toDouble(),
        contentHeight: math.max(120.0, contentHeight).toDouble(),
        columns: decision.columns,
        pageWidth: math.max(120.0, pageWidth).toDouble(),
        pageHeight: math.max(160.0, availableHeight).toDouble(),
      );
    }
    final columnWidth = math.min(math.max(120.0, width - 40), 800.0).toDouble();
    return EpubLayoutGeometry(
      viewportWidth: width,
      viewportHeight: height,
      contentWidth: columnWidth,
      contentHeight: math.max(120.0, height).toDouble(),
      columns: 1,
      pageWidth: columnWidth,
      pageHeight: math.max(120, height),
    );
  }

  void _viewportChanged(EpubReaderViewportChanged message) {
    final geometry = _geometryFor(message.width, message.height);
    if (geometry == null) return;
    if (geometry == _model.geometry) return;
    _emit(_model.copyWith(geometry: geometry, relayoutPending: true));
    _scheduleRelayout();
  }

  void _scheduleRelayout() {
    _relayoutTimer?.cancel();
    // A new intent invalidates any layout already in flight: its completion
    // must not install a layout computed for the previous intent. Without
    // this, a completion could clear `relayoutPending` and a readiness check
    // could pass on the stale layout before the debounced relayout starts.
    _layoutRevision++;
    _relayoutTimer = Timer(const Duration(milliseconds: 80), () {
      _startLayout(preserve: true);
    });
  }

  void _modeChanged(EpubReaderModeChanged message) {
    if (message.mode == _model.mode) return;
    final geometry = _geometryFor(
      _model.geometry?.viewportWidth ?? 0,
      _model.geometry?.viewportHeight ?? 0,
    );
    _emit(
      _model.copyWith(
        mode: message.mode,
        geometry: geometry,
        relayoutPending: true,
      ),
    );
    _scheduleRelayout();
  }

  void _fontSizeChanged(EpubReaderFontSizeChanged message) {
    final next = (_model.typography.fontSize + message.delta)
        .clamp(12.0, 48.0)
        .toDouble();
    if (next == _model.typography.fontSize) return;
    final typography = _model.typography.copyWith(fontSize: next);
    // Geometry follows the new typography: a page height computed for the
    // previous font size would lay the chapter out against the wrong page.
    final geometry = _geometryFor(
      _model.geometry?.viewportWidth ?? 0,
      _model.geometry?.viewportHeight ?? 0,
      typography: typography,
    );
    _emit(
      _model.copyWith(
        typography: typography,
        geometry: geometry,
        relayoutPending: true,
      ),
    );
    _scheduleRelayout();
  }

  void _themeChanged(EpubReaderThemeChanged message) {
    final palette = ReaderPalette.of(message.theme);
    _emit(
      _model.copyWith(
        theme: message.theme,
        typography: _model.typography.copyWith(palette: palette),
        relayoutPending: true,
      ),
    );
    _scheduleRelayout();
  }

  void _startLayout({required bool preserve}) {
    final book = _model.book;
    final geometry = _model.geometry;
    if (book == null ||
        geometry == null ||
        _model.status != EpubReaderStatus.ready) {
      return;
    }
    final revision = ++_layoutRevision;
    final request = _LayoutRequest(
      generation: _generation,
      revision: revision,
      spine: _model.spine
          .clamp(0, math.max(0, book.chapters.length - 1))
          .toInt(),
      scalar: preserve ? _model.scalar : 0,
      geometry: geometry,
      typography: _model.typography.copyWith(
        embeddedFamilies: _model.embeddedFamilies,
      ),
      mode: _model.mode,
      book: book,
      images: Map.of(_model.images),
      strategy: _layoutStrategy,
    );
    _emit(_model.copyWith(relayoutBusy: true, relayoutPending: false));
    unawaited(_layoutEffect(request));
  }

  bool _isStale(_LayoutRequest request) =>
      _disposed ||
      request.generation != _generation ||
      request.revision != _layoutRevision;

  EpubLayoutKey _layoutKey(_LayoutRequest request, EpubChapter chapter) =>
      EpubLayoutKey(
        resource: chapter.resource,
        contentWidth: request.geometry.contentWidth,
        contentHeight: request.geometry.contentHeight,
        typography: request.typography,
        imageSignature: Object.hashAll(request.images.keys),
      );

  Map<String, String> _imageMediaTypes(EpubBook book) => {
    for (final resource in book.resources.values)
      resource.path: resource.mediaType,
  };

  PaginatedChapter? _paginate(ChapterFlow flow, _LayoutRequest request) =>
      request.mode == EpubReaderMode.paginated
      ? paginateFlow(
          flow: flow,
          pageHeight: request.geometry.contentHeight,
          pageWidth: request.geometry.contentWidth,
        )
      : null;

  /// Measure one chapter according to the configured strategy.
  Future<void> _layoutEffect(_LayoutRequest request) async {
    final stopwatch = Stopwatch()..start();
    // Yield once so a loading state can paint; Flutter text layout itself
    // cannot move to a background isolate (dart:ui is UI-thread bound).
    await Future<void>.delayed(Duration.zero);
    if (_isStale(request)) return;
    final book = request.book;
    if (request.spine >= book.chapters.length) return;
    final chapter = book.chapters[request.spine];
    if (request.strategy == EpubLayoutStrategy.eager) {
      _layoutEager(request, chapter, stopwatch);
      return;
    }
    await _layoutProgressive(request, chapter, stopwatch);
  }

  /// The pre-progressive baseline: measure the whole chapter, then install.
  void _layoutEager(
    _LayoutRequest request,
    EpubChapter chapter,
    Stopwatch stopwatch,
  ) {
    final flow = layoutChapterFlow(
      chapter: chapter,
      spec: ChapterLayoutSpec(
        width: request.geometry.contentWidth,
        height: request.geometry.contentHeight,
        typography: request.typography,
      ),
      images: request.images,
      imageMediaTypes: _imageMediaTypes(request.book),
    );
    if (_isStale(request)) return;
    dispatch(
      EpubReaderLayoutCompleted(
        generation: request.generation,
        revision: request.revision,
        spine: request.spine,
        flow: flow,
        paginated: _paginate(flow, request),
        elapsedMicros: stopwatch.elapsedMicroseconds,
      ),
    );
  }

  /// Visible-location-first: install a window around the durable location, then
  /// extend it forward and backward in bounded batches that yield between
  /// batches. A superseded request stops at the next batch boundary and its
  /// measured blocks stay in the cache for a later request with the same key.
  Future<void> _layoutProgressive(
    _LayoutRequest request,
    EpubChapter chapter,
    Stopwatch stopwatch,
  ) async {
    final key = _layoutKey(request, chapter);
    var session = _layoutCache.get(key);
    if (session == null ||
        (!session.complete && !session.covers(request.scalar))) {
      // No reusable session, or the cached range does not contain the
      // requested location (a distant jump): start a fresh window.
      session = ChapterLayoutSession(
        chapter: chapter,
        spec: ChapterLayoutSpec(
          width: request.geometry.contentWidth,
          height: request.geometry.contentHeight,
          typography: request.typography,
        ),
        images: request.images,
        imageMediaTypes: _imageMediaTypes(request.book),
      );
      _layoutCache.store(key, session);
      session.layoutWindowAt(request.scalar);
    }
    _activeSession = session;
    _activeRequest = request;
    if (_isStale(request)) {
      _clearActiveSession(request);
      return;
    }
    _installSession(
      session,
      request,
      elapsedMicros: stopwatch.elapsedMicroseconds,
    );
    while (!session.complete) {
      // A real event-loop turn: frames and input run between batches.
      await Future<void>.delayed(const Duration(milliseconds: 1));
      if (_isStale(request)) {
        _clearActiveSession(request);
        return;
      }
      final progressed = session.lastNodeIndex + 1 < session.totalNodes
          ? session.layoutForward(
              maxNodes: _layoutBatchNodes,
              maxMicros: _layoutBatchMicros,
            )
          : session.layoutBackward(
              maxNodes: _layoutBatchNodes,
              maxMicros: _layoutBatchMicros,
            );
      if (progressed == 0) break;
      if (_isStale(request)) {
        _clearActiveSession(request);
        return;
      }
      _installSession(
        session,
        request,
        elapsedMicros: stopwatch.elapsedMicroseconds,
      );
    }
    _clearActiveSession(request);
  }

  /// Detach the active session unconditionally (document replacement or
  /// disposal), where no driver may keep using it.
  void _clearActiveSessionForDisposal() {
    _activeSession = null;
    _activeRequest = null;
  }

  /// Release the active session only when it still belongs to [request].
  ///
  /// A superseded driver resumes after its successor installed a new session;
  /// without the identity guard it would clear the successor's session and
  /// on-demand navigation would lose its handle.
  void _clearActiveSession(_LayoutRequest request) {
    if (!identical(_activeRequest, request)) return;
    _activeSession = null;
    _activeRequest = null;
  }

  /// Report a session snapshot: partial installs stay honest about totals,
  /// the final one is a completion.
  void _installSession(
    ChapterLayoutSession session,
    _LayoutRequest request, {
    required int elapsedMicros,
  }) {
    _countSessionWork(session);
    final flow = session.snapshot();
    final paginated = _paginate(flow, request);
    if (session.complete) {
      dispatch(
        EpubReaderLayoutCompleted(
          generation: request.generation,
          revision: request.revision,
          spine: request.spine,
          flow: flow,
          paginated: paginated,
          elapsedMicros: elapsedMicros,
        ),
      );
      return;
    }
    dispatch(
      EpubReaderLayoutProgressed(
        generation: request.generation,
        revision: request.revision,
        spine: request.spine,
        flow: flow,
        paginated: paginated,
        elapsedMicros: elapsedMicros,
      ),
    );
  }

  void _layoutProgressed(EpubReaderLayoutProgressed message) {
    if (message.generation != _generation ||
        message.revision != _layoutRevision) {
      return;
    }
    _installLayout(
      message.flow,
      message.paginated,
      complete: false,
      elapsedMicros: message.elapsedMicros,
    );
  }

  void _layoutCompleted(EpubReaderLayoutCompleted message) {
    if (message.generation != _generation ||
        message.revision != _layoutRevision) {
      return;
    }
    _installLayout(
      message.flow,
      message.paginated,
      complete: true,
      elapsedMicros: message.elapsedMicros,
    );
  }

  /// Install a flow (complete or partial) and re-derive the presentation from
  /// the durable scalar, so extending the window never moves the reader.
  void _installLayout(
    ChapterFlow flow,
    PaginatedChapter? paginated, {
    required bool complete,
    required int elapsedMicros,
  }) {
    final book = _model.book;
    if (book == null) return;
    final spine = _model.spine
        .clamp(0, math.max(0, book.chapters.length - 1))
        .toInt();
    final chapter = book.chapters[spine];
    final columns = _model.geometry?.columns ?? 1;
    // The durable scalar is clamped to the chapter, never to the rendered
    // range: a chapter-end position sits after the last rendered glyph (the
    // canonical stream has trailing separators) and must not move. Pagination
    // and continuous geometry clamp internally.
    final scalar = clampScalar(_model.scalar, chapter.scalarCount);
    final unit = paginated == null
        ? 0
        : paginated.pageOfCanonical(scalar) ~/ columns;
    // Continuous geometry clamps to the scrollable extent: a chapter-end
    // scalar maps to the last screenful, never to an offset the view cannot
    // reach (which would make the scroll surface correct it and report that
    // correction as navigation).
    final double continuousOffset = paginated == null
        ? offsetForCanonical(flow, scalar).clamp(
            0.0,
            math.max(0.0, flow.height - (_model.geometry?.viewportHeight ?? 0)),
          )
        : 0.0;
    final unitCount = paginated == null
        ? book.chapters.length
        : (paginated.pages.length + columns - 1) ~/ columns;
    _emit(
      _model.copyWith(
        flow: flow,
        paginated: paginated,
        unit: unit,
        unitCount: unitCount,
        scalar: scalar,
        spine: spine,
        continuousOffset: continuousOffset,
        relayoutBusy: false,
        relayoutPending: false,
        layoutComplete: complete,
        progress: _progress(spine, scalar, chapter),
        lastLayoutMicros: elapsedMicros,
        contentsSpine: spine,
      ),
    );
  }

  /// Extend the active session so [scalar] is inside the laid-out range.
  ///
  /// Bounded: returns false when there is no session to extend, the session is
  /// already complete or already covers the scalar, or the budget is spent
  /// (the background fill continues and a later attempt succeeds).
  bool _ensureLaidOut(int scalar) {
    final session = _activeSession;
    final request = _activeRequest;
    if (session == null || request == null || !session.started) return false;
    if (session.complete || session.covers(scalar)) return false;
    final first = session.firstCanonical;
    final last = session.lastCanonical;
    if (first == null || last == null) return false;
    final progressed = scalar < first
        ? session.layoutBackward(
            maxNodes: _layoutBatchNodes,
            maxMicros: _layoutBatchMicros,
          )
        : session.layoutForward(
            maxNodes: _layoutBatchNodes,
            maxMicros: _layoutBatchMicros,
          );
    if (progressed == 0) return false;
    _installSession(session, request, elapsedMicros: 0);
    return true;
  }

  /// Position writes are serialized: an older write can never land after a
  /// newer one.
  Future<void>? _positionWrite;

  void _savePosition() {
    final path = _model.path;
    if (path == null) return;
    final position = EpubStoredPosition(
      spine: _model.spine,
      scalar: _model.scalar,
    );
    final previous = _positionWrite ?? Future<void>.value();
    _positionWrite = previous
        .then((_) => _positionStore.write(path, position))
        .catchError((Object error) {
          if (!_disposed) {
            _emit(_model.copyWith(notice: 'Position save failed: $error'));
          }
        });
  }

  double _progress(int spine, int scalar, EpubChapter chapter) => epubProgress(
    spine: spine,
    scalar: scalar,
    chapterScalars: chapter.scalarCount,
    spineCount: _model.book?.chapters.length ?? 1,
  );

  // -------------------------------------------------------------------------
  // Navigation
  // -------------------------------------------------------------------------

  void _unitRequested(EpubReaderUnitRequested message) {
    if (_model.paginated == null) {
      // Continuous mode: advance by one viewport.
      final flow = _model.flow;
      final geometry = _model.geometry;
      if (flow == null || geometry == null) return;
      final delta = geometry.viewportHeight * 0.9 * message.delta;
      _continuousOffsetChanged(
        EpubReaderContinuousOffsetChanged(
          (_model.continuousOffset + delta)
              .clamp(0.0, math.max(0.0, flow.height - 1))
              .toDouble(),
        ),
      );
      return;
    }
    var next = (_model.unit + message.delta)
        .clamp(0, math.max(0, _model.unitCount - 1))
        .toInt();
    if (next == _model.unit && !_model.layoutComplete) {
      // At the edge of a partially measured chapter: measure more content in
      // the requested direction, then retry once.
      final flow = _model.flow;
      final edge = message.delta > 0
          ? flow?.lastCanonical
          : flow?.firstCanonical;
      if (edge != null &&
          _ensureLaidOut(
            message.delta > 0 ? edge + 1 : math.max(0, edge - 1),
          )) {
        next = (_model.unit + message.delta)
            .clamp(0, math.max(0, _model.unitCount - 1))
            .toInt();
      }
    }
    if (next == _model.unit) return;
    final pages = _model.pagesForUnit(next);
    final page = _model.paginated!.pages[pages.first];
    _emit(
      _model.copyWith(
        unit: next,
        scalar: page.canonicalStart,
        selection: null,
        progress: _progress(_model.spine, page.canonicalStart, _model.chapter!),
      ),
    );
    _savePosition();
  }

  void _scalarJump(EpubReaderScalarJumpRequested message) {
    final book = _model.book;
    if (book == null) return;
    final spine = message.spine.clamp(0, book.chapters.length - 1).toInt();
    final scalar = clampScalar(
      message.scalar,
      book.chapters[spine].scalarCount,
    );
    final flow = _model.flow;
    if (spine == _model.spine &&
        flow != null &&
        _model.paginated != null &&
        flow.covers(scalar)) {
      final page = _model.paginated!.pageOfCanonical(scalar);
      final columns = _model.geometry?.columns ?? 1;
      _emit(
        _model.copyWith(
          scalar: scalar,
          unit: page ~/ columns,
          selection: null,
          progress: _progress(spine, scalar, book.chapters[spine]),
        ),
      );
      _savePosition();
      return;
    }
    _emit(
      _model.copyWith(
        spine: spine,
        scalar: scalar,
        unit: 0,
        flow: null,
        paginated: null,
        selection: null,
        relayoutPending: true,
      ),
    );
    _savePosition();
    _startLayout(preserve: true);
  }

  void _continuousOffsetChanged(EpubReaderContinuousOffsetChanged message) {
    if (_model.mode != EpubReaderMode.continuous) return;
    var flow = _model.flow;
    if (flow == null) return;
    if (!_model.layoutComplete && message.offset >= flow.height - 1) {
      // Scrolled to the end of a partially measured chapter: measure more.
      final edge = flow.lastCanonical;
      if (edge != null && _ensureLaidOut(edge + 1)) {
        flow = _model.flow ?? flow;
      }
    }
    final clamped = message.offset
        .clamp(0.0, math.max(0.0, flow.height))
        .toDouble();
    if ((clamped - _model.continuousOffset).abs() < 0.5) return;
    final hit = hitTestFlow(flow: flow, local: Offset(0, clamped + 1));
    final chapter = _model.chapter!;
    _emit(
      _model.copyWith(
        continuousOffset: clamped,
        scalar: hit.scalar,
        progress: _progress(_model.spine, hit.scalar, chapter),
      ),
      notify: false,
    );
    _savePosition();
    notifyListeners();
  }

  // -------------------------------------------------------------------------
  // Selection, copy, highlights
  // -------------------------------------------------------------------------

  EpubHit _hitTestAt(Offset position) {
    final flow = _model.flow;
    final geometry = _model.geometry;
    if (flow == null || geometry == null) {
      return const EpubHit(scalar: 0, selectable: false);
    }
    if (_model.mode == EpubReaderMode.continuous) {
      // The painter centres the column; hit testing applies the inverse
      // translation so a pointer addresses the glyph it is over.
      final gutter = math.max(0.0, (geometry.viewportWidth - flow.width) / 2);
      return hitTestFlow(
        flow: flow,
        local: Offset(
          position.dx - gutter,
          _model.continuousOffset + position.dy,
        ),
      );
    }
    final paginated = _model.paginated;
    if (paginated == null) {
      return const EpubHit(scalar: 0, selectable: false);
    }
    final columns = geometry.columns;
    final slot = geometry.pageWidth;
    final gutter = columns == 2 ? 20.0 : 0.0;
    var column = columns == 2 ? (position.dx / (slot + gutter)).floor() : 0;

    column = column.clamp(0, columns - 1);
    final pageIndex = _model.unit * columns + column;
    final local = Offset(position.dx - column * (slot + gutter), position.dy);
    return hitTestPage(chapter: paginated, pageIndex: pageIndex, local: local);
  }

  void _tapRequested(Offset position) {
    final hit = _hitTestAt(position);
    if (hit.link != null) {
      _activateLink(hit.link!);
      return;
    }
    if (_model.selection != null) {
      _emit(_model.copyWith(selection: null));
    }
  }

  void _selectionStarted(Offset position) {
    final hit = _hitTestAt(position);
    if (!hit.selectable) {
      _emit(_model.copyWith(notice: 'That object has no selectable text.'));
      return;
    }
    _emit(
      _model.copyWith(
        selection: EpubSelection(anchor: hit.scalar, focus: hit.scalar),
        notice: null,
      ),
    );
  }

  void _selectionExtended(Offset position) {
    final selection = _model.selection;
    if (selection == null) return;
    final hit = _hitTestAt(position);
    _emit(_model.copyWith(selection: selection.copyWith(focus: hit.scalar)));
  }

  void _copySelection() {
    final selection = _model.selection;
    final chapter = _model.chapter;
    if (selection == null || chapter == null) return;
    final text = copyTextForRange(
      canonicalText: chapter.canonicalText,
      start: selection.start,
      end: selection.end,
      hiddenRanges: _hiddenRanges(),
    );
    if (text.isEmpty) {
      _emit(_model.copyWith(notice: 'The selection has no copyable text.'));
      return;
    }
    final generation = _generation;
    unawaited(
      _clipboard
          .setText(text)
          .then((_) {
            if (_disposed || generation != _generation) return;
            if (!identical(_model.selection, selection)) {
              // A newer selection started while the clipboard write was in
              // flight; report the copy but leave that selection alone.
              _emit(
                _model.copyWith(
                  notice: 'Copied ${text.runes.length} characters.',
                ),
              );
              return;
            }
            _emit(
              _model.copyWith(
                notice: 'Copied ${text.runes.length} characters.',
                selection: null,
              ),
            );
          })
          .catchError((Object error) {
            if (_disposed || generation != _generation) return;
            _emit(_model.copyWith(notice: 'Copy failed: $error'));
          }),
    );
  }

  /// Canonical ranges that must not be copied: rendered image alt text.
  List<({int start, int end})> _hiddenRanges() {
    final flow = _model.flow;
    if (flow == null) return const [];
    final ranges = <({int start, int end})>[];
    for (final block in flow.blocks) {
      final image = block.image;
      if (image == null) continue;
      if (image.image == null && image.fallbackText != null) continue;
      final scalars = image.alt.runes.length;
      if (scalars > 0) {
        ranges.add((
          start: block.canonicalStart,
          end: block.canonicalStart + scalars,
        ));
      }
    }
    return ranges;
  }

  void _createHighlight(ReaderHighlightColor color) {
    final selection = _model.selection;
    if (selection == null || selection.end <= selection.start) return;
    final highlight = EpubHighlight(
      id: 'h${_model.highlights.length}-${selection.start}',
      spine: _model.spine,
      start: selection.start,
      end: selection.end,
      color: color,
    );
    _emit(
      _model.copyWith(
        highlights: [..._model.highlights, highlight],
        selection: null,
      ),
    );
  }

  void _activateLink(String href) {
    final book = _model.book;
    final chapter = _model.chapter;
    if (book == null || chapter == null) return;
    try {
      // Fragment-only hrefs stay in the current document.
      final resolved = href.startsWith('#')
          ? (path: chapter.resource, fragment: href.substring(1))
          : resolveEpubReference(directoryOf(chapter.resource), href);
      final spine = book.spine.indexOf(resolved.path);
      if (spine < 0) {
        _emit(_model.copyWith(notice: 'Link target is outside the book.'));
        return;
      }
      final scalar = resolved.fragment == null
          ? 0
          : (book.chapters[spine].anchors[resolved.fragment!] ?? 0);
      _scalarJump(EpubReaderScalarJumpRequested(spine: spine, scalar: scalar));
    } on EpubPathError {
      _emit(
        _model.copyWith(
          notice: 'External links are not opened by the prototype.',
        ),
      );
    }
  }

  static int _stableHash(String value) {
    var hash = 0x811c9dc5;
    for (final unit in value.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0x7fffffff;
    }
    return hash;
  }
}

/// One immutable layout request captured when the intent is handled.
class _LayoutRequest {
  const _LayoutRequest({
    required this.generation,
    required this.revision,
    required this.spine,
    required this.scalar,
    required this.geometry,
    required this.typography,
    required this.mode,
    required this.book,
    required this.images,
    required this.strategy,
  });

  final int generation;
  final int revision;
  final int spine;
  final int scalar;
  final EpubLayoutGeometry geometry;
  final ReaderTypography typography;
  final EpubReaderMode mode;
  final EpubBook book;
  final Map<String, ui.Image> images;
  final EpubLayoutStrategy strategy;
}

/// Flow-space offset of a canonical scalar (top of its block, plus the line
/// offset inside a text block).
double offsetForCanonical(ChapterFlow flow, int scalar) {
  for (final block in flow.blocks) {
    if (scalar < block.canonicalStart) return block.top;
    if (scalar > block.canonicalEnd) continue;
    final text = block.text;
    if (text != null) {
      for (final line in text.lines) {
        if (scalar < line.canonicalEnd) {
          return block.top + line.top;
        }
      }
      return block.top;
    }
    return block.top;
  }
  return flow.height;
}
