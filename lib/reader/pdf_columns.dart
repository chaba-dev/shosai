part of 'controller.dart';

final class _ReaderColumnsLoaded extends ReaderMessage {
  const _ReaderColumnsLoaded(
    this.generation,
    this.revision,
    this.layout,
    this.screen,
    this.image,
    this.pages,
    this.columnWidth,
    this.back,
    this.ahead,
    this.selection,
    this.annotations,
    this.annotationError,
    this.targetOffset,
    this.targetLength,
    this.passive,
  );
  final int generation;
  final int revision;
  final ReaderLayout layout;
  final PdfStripScreen screen;
  final ui.Image image;
  final Map<int, PdfStripPage> pages;
  final double? columnWidth;
  final List<PdfStripPosition> back;
  final List<PdfStripPosition> ahead;
  final PdfStripSelection selection;
  final List<FlutterAnnotation> annotations;
  final String? annotationError;
  final int? targetOffset;
  final int? targetLength;

  /// Whether the load only served scrolling already in progress, whose
  /// completion must re-anchor to the reader's live place.
  final bool passive;
}

final class _ReaderColumnsFailed extends ReaderMessage {
  const _ReaderColumnsFailed(this.generation, this.revision, this.error);
  final int generation;
  final int revision;
  final String error;
}

final class _ReaderColumnsFinished extends ReaderMessage {
  const _ReaderColumnsFinished();
}

extension on ReaderController {
  void _columnsViewportChanged(ReaderColumnsViewportChanged message) {
    final screen = message.screen;
    if (!identical(screen, _model.pdfColumns) ||
        (!screen.continuous && screen.strip == null) ||
        _closing ||
        _suspended) {
      return;
    }
    // A refill in flight does not invalidate the strip on screen: the reader
    // keeps scrolling and its live place must keep being reported and saved.
    // The completed refill re-anchors to this latest point instead of the one
    // captured when it was requested. Only the next overscan request waits.
    final refilling = _model.relayoutBusy;
    // A scroll can arrive measured against a superseded window's extents.
    final top = message.viewport.top
        .clamp(0.0, math.max(0.0, screen.height - .01))
        .toDouble();
    _columnsViewport = (screen: screen, top: top);
    final piece = screen.pieces.firstWhere((p) => p.top + p.height > top);
    final page = piece.page;
    final visible = ui.Rect.fromLTWH(
      piece.left,
      piece.top,
      piece.width,
      piece.height,
    ).intersect(message.viewport);
    if (visible.isEmpty) return;
    final point = piece.toPage(visible.center.dx, visible.top);
    if (_model.unit == page &&
        _model.pdfX == point.x &&
        _model.pdfY == point.y) {
      return;
    }
    final selection = _model.pdfColumnSelection!;
    final endpoint = selection.surface.endpoints.where((e) {
      final rect = e.rect;
      return rect.left < visible.right &&
          rect.right > visible.left &&
          rect.top < visible.bottom &&
          rect.bottom > visible.top;
    }).firstOrNull;
    final offset = endpoint == null
        ? null
        : selection.location(endpoint.offset.toInt()).offset;
    _emit(
      _model.copyWith(
        unit: page,
        pdfX: point.x,
        pdfY: point.y,
        readingOffset: offset,
      ),
    );
    final bookId = _model.document?.bookId;
    if (bookId != null) {
      _queueReadingStateSave(
        bookId,
        _model.document!.logicalUnitCount,
        FlutterReadingState(
          unit: BigInt.from(piece.page),
          offset: offset == null ? null : BigInt.from(offset),
          pdfX: point.x,
          pdfY: point.y,
          pdfFit: _pdfFitOverride,
          zoom: _model.layout.scale,
          progress: _bookProgress(_model),
        ),
      );
    }
    if (!refilling &&
        screen.continuous &&
        _model.selectionPhase == ReaderSelectionPhase.idle) {
      final first = screen.pieces.first;
      final bounds =
          _columnsPages[first.page]!.columns.regions[first.region].bounds;
      final before =
          first.page > 0 ||
          first.region > 0 ||
          first.source.top > bounds.top + .01;
      final after = screen.next.page < _pdfDocument!.pageCount;
      final threshold =
          math.min(
            message.viewport.height,
            screen.height - message.viewport.height,
          ) *
          .25;
      if (before && message.viewport.top < threshold ||
          after && message.viewport.bottom > screen.height - threshold) {
        final topPiece = screen.pieces.firstWhere(
          (p) => p.top + p.height > top,
        );
        _requestColumns(
          PdfStripPosition(
            topPiece.page,
            region: topPiece.region,
            y: topPiece.toPage(topPiece.left, top).y,
          ),
          passive: true,
        );
      }
    }
  }

  void _pdfViewportChanged(ReaderPdfViewportChanged message) {
    final pdf = _pdfDocument;
    if (pdf == null ||
        message.generation != _model.generation ||
        message.revision != _model.locationRequestRevision ||
        _model.columnsPresentation ||
        _model.relayoutBusy ||
        _closing ||
        _suspended ||
        !message.y.isFinite) {
      return;
    }
    final location = _model.readingLocation;
    final y = message.y.clamp(0.0, pdf.pageSize(location.unit).height);
    if (_model.pdfY == y) return;
    final surface = _model.selectionSurface;
    final endpoint = surface?.endpoints
        .where(
          (e) =>
              e.rect.bottom / _model.layout.scale >= y &&
              (_model.pdfSpread?.unitOf(e.rangeStart.toInt(), _model.unit) ??
                      _model.unit) ==
                  location.unit,
        )
        .firstOrNull;
    final offset = endpoint?.rangeStart.toInt();
    _emit(_model.copyWith(pdfY: y, pdfX: null, readingOffset: offset));
    final savedOffset = _model.readingLocation.offset;
    final bookId = _model.document?.bookId;
    if (bookId != null) {
      _queueReadingStateSave(
        bookId,
        _model.document!.logicalUnitCount,
        FlutterReadingState(
          unit: BigInt.from(location.unit),
          offset: savedOffset == null ? null : BigInt.from(savedOffset),
          pdfY: y,
          pdfFit: _pdfFitOverride,
          zoom: _model.layout.scale,
          progress: _bookProgress(_model),
        ),
      );
    }
  }

  void _pdfDoubleTapped(double x, double y) {
    if (!_canPeek || !x.isFinite || !y.isFinite) return;
    final screen = _model.pdfColumns;
    if (screen != null) {
      for (final piece in screen.pieces) {
        if (piece.kind == PdfRegionKind.figure &&
            (screen.strip != null ||
                x >= piece.left &&
                    x < piece.left + piece.width &&
                    y >= piece.top &&
                    y < piece.top + piece.height)) {
          dispatch(
            ReaderColumnsDetailRequested(
              screen,
              piece,
              screen.strip == null ? 2 : 1,
            ),
          );
          return;
        }
      }
    }
    if (_model.columnsPresentation || _rasterFit == ReaderRasterFit.manual) {
      _typographyChanged(
        const ReaderTypographyChanged(rasterFit: ReaderRasterFit.fitPage),
      );
      return;
    }
    final pdf = _pdfDocument;
    if (pdf == null) return;
    var page = _model.unit;
    final spread = _model.pdfSpread;
    final scale = _model.layout.scale;
    if (spread != null &&
        x >= spread.facingLeft &&
        x < spread.facingLeft + pdf.pageSize(spread.facingUnit).width * scale) {
      page = spread.facingUnit;
    }
    final px = (x - (spread?.leftOf(page, _model.unit) ?? 0)) / scale;
    final py = y / scale;
    final size = pdf.pageSize(page);
    if (px < 0 || px > size.width || py < 0 || py > size.height) return;
    // Enter directly with the tap's original page coordinate, not a 2x bitmap.
    _typographyChanged(
      const ReaderTypographyChanged(rasterFit: ReaderRasterFit.columns),
    );
    _readingStatePersistenceBlocked = false;
    _requestColumns(PdfStripPosition(page, y: py), x: px, locate: true);
  }

  bool _isCurrentColumns(int generation, int revision) =>
      _isCurrent(generation) &&
      !_suspended &&
      revision == _columnsRevision &&
      _rasterFit == ReaderRasterFit.columns;

  /// Every passive refresh replays a pending destination or the saved place.
  /// In particular, deferred annotation/open effects must not drop its height.
  /// A pending passive refill is replayed without its passive tag: after a
  /// layout or size change the reading point is still the anchor to rebuild
  /// around, so the completion may legitimately re-anchor the reader.
  void _refreshColumns() {
    final pending = _columnsIntent;
    final screen = _model.pdfColumns;
    final piece = screen?.strip == null ? null : screen!.pieces.single;
    _requestColumns(
      pending?.position ??
          (screen?.continuous == true
              ? PdfStripPosition(_model.readingLocation.unit, y: _model.pdfY)
              : null) ??
          screen?.start ??
          PdfStripPosition(_model.readingLocation.unit, y: _model.pdfY),
      back: pending?.back,
      ahead: pending?.ahead,
      previous: pending?.previous ?? false,
      offset: pending?.offset,
      length: pending?.length,
      x: pending?.x ?? (screen?.continuous == true ? _model.pdfX : null),
      locate: pending?.locate ?? screen?.continuous ?? false,
      detail: pending != null
          ? pending.detail
          : piece == null
          ? null
          : (
              page: piece.page,
              region: piece.region,
              zoom: screen!.detailZoom,
              baseScale: piece.scale / screen.detailZoom,
            ),
      strip: pending != null ? pending.strip : screen?.strip,
      retainDetailPlace: pending?.retainDetailPlace ?? piece != null,
    );
  }

  void _columnsStep(int delta) {
    final screen = _model.pdfColumns;
    if (screen == null ||
        delta == 0 ||
        _model.busy ||
        _model.relayoutBusy ||
        _closing ||
        _suspended) {
      return;
    }
    if (screen.continuous) {
      // A separator has no durable page point. Keep its exact viewport origin
      // separately from the first visible content point saved for reopening.
      final viewport = _columnsViewport;
      final currentTop = identical(viewport?.screen, screen)
          ? viewport!.top
          : screen.viewportTop;
      final current = screen.pieces.firstWhere(
        (p) => p.top + p.height > currentTop,
      );
      // PDF has no CSS line height. Use the median physical row advance at
      // the current crop's scale; figures borrow nearby body rows. Textless
      // scans retain a 16pt overlap rather than losing the edge entirely.
      var overlap = 16.0;
      final nearbyPages = _columnsPages.keys.toList()
        ..sort(
          (a, b) =>
              (a - current.page).abs().compareTo((b - current.page).abs()),
        );
      for (final candidate in [
        for (final piece in [
          current,
          ...screen.pieces.where((p) => p != current),
        ])
          (
            region: _columnsPages[piece.page]!.columns.regions[piece.region],
            scale: piece.scale,
          ),
        // A tall figure can fill the entire raster window. Retained nearby
        // body geometry still supplies its pitch at the same strip scale.
        for (final page in nearbyPages)
          for (final region in _columnsPages[page]!.columns.regions)
            (
              region: region,
              scale:
                  screen.width *
                  (region.kind == PdfRegionKind.page
                      ? 1
                      : _rasterZoom.clamp(.5, 1)) /
                  (region.kind == PdfRegionKind.column
                      ? _columnsWidth ?? region.bounds.width
                      : region.bounds.width),
            ),
      ]) {
        final region = candidate.region;
        if (region.kind == PdfRegionKind.figure) continue;
        final rows = region.lines.where((line) => !line.isVertical).toList()
          ..sort((a, b) => a.bounds.top.compareTo(b.bounds.top));
        if (rows.isEmpty) continue;
        final tops = <double>[];
        var bottom = double.negativeInfinity;
        for (final row in rows) {
          if (row.bounds.top >= bottom) tops.add(row.bounds.top);
          bottom = math.max(bottom, row.bounds.bottom);
        }
        final advances = [
          for (var i = 1; i < tops.length; i++) tops[i] - tops[i - 1],
        ]..sort();
        overlap =
            (advances.isEmpty
                ? rows.first.bounds.height
                : advances[advances.length ~/ 2]) *
            candidate.scale;
        break;
      }
      final stride = math.max(1.0, screen.viewportHeight! - overlap);
      final first = screen.pieces.first;
      final bounds =
          _columnsPages[first.page]!.columns.regions[first.region].bounds;
      final before =
          first.page > 0 ||
          first.region > 0 ||
          first.source.top > bounds.top + .01;
      // Raster-window edges are not document limits. Extrapolated page points
      // let the next window center on the full step, including across a band.
      final last = screen.pieces.last;
      final end = last.top + last.height;
      final top = (currentTop + delta * stride)
          .clamp(
            before ? -stride : 0.0,
            screen.next.page < _pdfDocument!.pageCount
                ? end - .001
                : math.max(0.0, end - screen.viewportHeight!),
          )
          .toDouble();
      if ((top - currentTop).abs() < 1.0) {
        // A window's piece-anchored top can sit a fraction of a pixel short of
        // the scrollable end. Reloading the same window for that slack would
        // only churn the screen identity, so refuse sub-pixel steps.
        return;
      }
      final piece = screen.pieces.firstWhere((p) => p.top + p.height > top);
      _requestColumns(
        PdfStripPosition(
          piece.page,
          region: piece.region,
          y: piece.toPage(piece.left, top).y,
        ),
      );
      return;
    }
    if (delta > 0) {
      if (screen.next.page >= _pdfDocument!.pageCount) return;
      _readingStatePersistenceBlocked = false;
      _requestColumns(
        screen.next,
        back: [..._columnsBack, screen.start],
        ahead: _columnsAhead.isEmpty
            ? const []
            : _columnsAhead.sublist(0, _columnsAhead.length - 1),
      );
    } else if (_columnsBack.isNotEmpty) {
      _readingStatePersistenceBlocked = false;
      _requestColumns(
        _columnsBack.last,
        back: _columnsBack.sublist(0, _columnsBack.length - 1),
        ahead: [..._columnsAhead, screen.start],
      );
    } else if (screen.start.page > 0 ||
        screen.start.region > 0 ||
        screen.start.y != null) {
      _readingStatePersistenceBlocked = false;
      _requestColumns(screen.start, previous: true);
    }
  }

  void _requestColumns(
    PdfStripPosition position, {
    List<PdfStripPosition>? back,
    List<PdfStripPosition>? ahead,
    bool previous = false,
    ({int page, int region, double zoom, double baseScale})? detail,
    PdfStripScreen? strip,
    bool retainDetailPlace = false,
    int? offset,
    int? length,
    double? x,
    bool locate = false,
    bool passive = false,
  }) {
    final pdf = _pdfDocument;
    final height = _epubViewportHeight;
    if (pdf == null ||
        _model.busy ||
        _model.annotationOperations.isNotEmpty ||
        _closing ||
        _suspended ||
        height == null ||
        height <= 0 ||
        _requestedLayout.width <= 0) {
      return;
    }
    final generation = _model.generation;
    final revision = ++_columnsRevision;
    // Viewport changes during an effect replay this destination, not the
    // previous screen. This matters when entering at a tapped column or hit.
    final intent = (
      position: position,
      back: List<PdfStripPosition>.unmodifiable(back ?? _columnsBack),
      ahead: List<PdfStripPosition>.unmodifiable(ahead ?? _columnsAhead),
      previous: previous,
      offset:
          offset ??
          (x == null && _model.pdfColumns == null
              ? _model.readingLocation.offset
              : null),
      length: length,
      // A figure has no canonical text offset. Keep its original horizontal
      // anchor across page fits/reopen rather than guessing from height alone.
      x: x ?? (_model.pdfColumns == null && !locate ? _model.pdfX : null),
      locate: locate || _model.pdfColumns == null,
      detail: detail,
      strip: strip,
      retainDetailPlace: retainDetailPlace,
      // Overscan refills serve scrolling that continues while they load, so
      // their completion must re-anchor to the reader's live place.
      passive: passive,
    );
    _columnsIntent = intent;
    // A whole-page render started before a fit switch cannot overwrite a
    // strip screen when it finishes. The same effect drain retains the PDF.
    _layoutRevision++;
    _activeRelayoutIntent = null;
    for (final cancellation in _relayoutCancellations) {
      _bridge.cancel(id: cancellation);
    }
    _emit(
      _model.copyWith(
        relayoutBusy: true,
        relayoutPending: false,
        relayoutError: null,
      ),
    );
    _activeBridgeOperations++;
    final effect = _loadColumns(
      pdf,
      generation,
      revision,
      _requestedLayout,
      height,
      _devicePixelRatio,
      _rasterZoom,
      position,
      intent.back,
      ahead: intent.ahead,
      previous: intent.previous,
      detail: detail,
      strip: strip,
      offset: intent.offset,
      length: length,
      x: intent.x,
      locate: intent.locate,
      passive: intent.passive,
    );
    _referenceEffects.add(effect);
    unawaited(effect.then((_) => _referenceEffects.remove(effect)));
  }

  Future<void> _loadColumns(
    PdfEngineDocument pdf,
    int generation,
    int revision,
    ReaderLayout layout,
    double height,
    double density,
    double zoom,
    PdfStripPosition position,
    List<PdfStripPosition> back, {
    required List<PdfStripPosition> ahead,
    required bool previous,
    required ({int page, int region, double zoom, double baseScale})? detail,
    required PdfStripScreen? strip,
    required int? offset,
    required int? length,
    required double? x,
    required bool locate,
    required bool passive,
  }) async {
    bool current() => _isCurrentColumns(generation, revision);
    final pages = Map<int, PdfStripPage>.of(_columnsPages);
    final images = <ui.Image>[];
    ui.PictureRecorder? recorder;
    ui.Picture? picture;
    ui.Image? owned;
    BigInt? cancellation;
    final document = _model.document!;
    try {
      cancellation = _bridge.createCancellation();
      // Three pages establish repeated/alternating heads without scanning a
      // large document before its first screen. Other geometry loads on demand.
      final samples = <int, PdfPageGeometry>{};
      for (var p = 0; p < math.min(3, pdf.pageCount); p++) {
        try {
          samples[p] = pages[p]?.geometry ?? await pdf.pageGeometry(p);
        } catch (_) {
          // The target page's load below supplies fit-width scan fallback.
        }
        if (!current()) return;
      }
      // Use the same bounded sample on every turn/reopen, independent of the
      // target page and which later pages happen to be cached.
      var columnWidth =
          _columnsWidth ??
          typicalPdfColumnWidth(
            analyzePdfColumns(
              samples.values.toList(),
              rightToLeft: pdf.rightToLeft,
            ),
          );
      Future<bool> load(int p) async {
        if (pages.containsKey(p)) return true;
        PdfPageGeometry geometry;
        try {
          geometry = samples[p] ?? await pdf.pageGeometry(p);
        } catch (_) {
          // An unreadable text layer must not hide an otherwise readable scan.
          final size = pdf.pageSize(p);
          geometry = PdfPageGeometry(
            width: size.width,
            height: size.height,
            lines: const [],
            images: const [],
          );
        }
        if (!current()) return false;
        final batch = {...samples, p: geometry};
        final keys = batch.keys.toList();
        pages[p] = PdfStripPage(
          geometry,
          analyzePdfColumns(
            batch.values.toList(),
            rightToLeft: pdf.rightToLeft,
          )[keys.indexOf(p)],
        );
        return true;
      }

      Future<PdfStripScreen?> window(PdfStripPosition start) async {
        while (current()) {
          if (columnWidth == null &&
              pages.values.any((page) => page.columns.columnCount >= 2)) {
            // Preserve the document's stable sampled body width in both modes.
            for (var p = 0; p < pdf.pageCount; p++) {
              if (!await load(p)) return null;
              columnWidth = typicalPdfColumnWidth([pages[p]!.columns]);
              if (columnWidth != null) break;
            }
          }
          final screen = _typographyContinuous
              ? layoutPdfColumnWindow(
                  pages: pages,
                  pageCount: pdf.pageCount,
                  position: start,
                  width: math.max(1, layout.width - 2 * pdfStripSideInset),
                  height: math.max(1, height - pdfStripHeaderHeight),
                  zoom: zoom,
                  columnWidth: columnWidth,
                  topInset: length == null ? 0 : math.min(96, height / 3),
                  density: density,
                )
              : layoutPdfColumnScreen(
                  pages: pages,
                  pageCount: pdf.pageCount,
                  start: start,
                  width: math.max(1, layout.width - 2 * pdfStripSideInset),
                  height: math.max(1, height - pdfStripHeaderHeight),
                  zoom: zoom,
                  columnWidth: columnWidth,
                  locate: locate && !previous,
                  stop: previous ? position : ahead.lastOrNull,
                  // A jumped-to range must clear the overlaid toolbar and capsule.
                  // Reserve space in layout, not by hiding part of the raster.
                  topInset: length == null
                      ? 0
                      : math.min(
                          96,
                          math.max(1, height - pdfStripHeaderHeight) / 3,
                        ),
                );
          final needed = screen.needsPage;
          if (needed == null) return screen;
          if (!await load(needed)) return null;
        }
        return null;
      }

      if (locate) {
        if (!await load(position.page)) return;
        final regions = pages[position.page]!.columns.regions;
        var region = 0;
        if (offset != null) {
          final found = regions.indexWhere(
            (r) => r.lines.any((l) => l.start <= offset && offset < l.end),
          );
          if (found >= 0) region = found;
        } else if (position.y != null) {
          final found = regions.indexWhere(
            (r) =>
                (x == null || x >= r.bounds.left && x <= r.bounds.right) &&
                position.y! >= r.bounds.top &&
                position.y! <= r.bounds.bottom,
          );
          if (found >= 0) region = found;
        }
        final bounds = regions[region].bounds;
        var y = position.y;
        if (y == null && offset != null) {
          y = regions[region].lines
              .where((l) => l.start <= offset && offset < l.end)
              .firstOrNull
              ?.bounds
              .top;
        }
        if (y != null) {
          y = y.clamp(bounds.top, bounds.bottom);
          // Match screen breaks: overlapping physical boxes are indivisible.
          // Reach a fixed point so fit switches/reopens cannot creep upward
          // one overlapping line at a time.
          var moved = !_typographyContinuous;
          while (moved) {
            moved = false;
            for (final line in regions[region].lines) {
              if (line.bounds.top < y! && line.bounds.bottom > y) {
                y = line.bounds.top;
                moved = true;
              }
            }
          }
          if (!_typographyContinuous &&
              regions[region].lines.any((line) => line.bounds.top == y)) {
            // Tight glyph boxes omit raster antialiasing. Put an anchored row
            // in preceding whitespace, with at most the crop's 3pt ink guard.
            // A large blank gap must not pull a footnote destination upward.
            final before = regions[region].lines.where(
              (line) => line.bounds.bottom <= y!,
            );
            y = math.max(
              y! - 3,
              before.isEmpty
                  ? bounds.top
                  : (before.map((line) => line.bounds.bottom).reduce(math.max) +
                            y) /
                        2,
            );
          }
        }
        position = PdfStripPosition(position.page, region: region, y: y);
      }
      PdfStripScreen? screen;
      if (previous) {
        // After an explicit page jump there may be no navigation history.
        // Reconstruct only the current/previous page's windows, not the book.
        var cursor = PdfStripPosition(math.max(0, position.page - 1));
        back = [];
        while (current()) {
          final candidate = await window(cursor);
          if (candidate == null || candidate.pieces.isEmpty) return;
          screen = candidate;
          final next = candidate.next;
          if (next.compareTo(position) >= 0) break;
          back.add(cursor);
          cursor = next;
        }
        ahead = [...ahead, position];
      } else {
        screen = await window(position);
      }
      if (!current()) return;
      if (screen == null || screen.pieces.isEmpty) {
        throw const PdfEngineException('No PDF content fits this screen');
      }
      if (detail != null) {
        if (!await load(detail.page)) return;
        final page = pages[detail.page]!;
        final region = page.columns.regions[detail.region];
        final bounds = region.bounds;
        final availableWidth = math.max(
          1.0,
          layout.width - 2 * pdfStripSideInset,
        );
        final availableHeight = math.max(
          1.0,
          height - pdfStripDetailHeaderHeight,
        );
        bool admits(double scale) {
          try {
            // The source crop can gain pixels from the virtual page's ceil
            // and outward clipping. The composed canvas also reserves the
            // viewport, including blank paper around a short figure.
            pdfBitmapSizeFor(
              pdf.pageSize(detail.page),
              scale * density,
              clip: bounds,
            );
            pdfBitmapSizeFor(
              PdfPageSize(
                math.max(availableWidth, bounds.width * scale),
                math.max(availableHeight, bounds.height * scale),
              ),
              density,
            );
            return true;
          } on PdfEngineLimitException {
            return false;
          }
        }

        var scale = detail.baseScale * detail.zoom;
        if (!admits(scale)) {
          var low = 0.0;
          var high = scale;
          for (var i = 0; i < 32; i++) {
            final mid = (low + high) / 2;
            if (admits(mid)) {
              low = mid;
            } else {
              high = mid;
            }
          }
          scale = low;
        }
        // An extremely tall page may not admit even whole-region fit. Keep
        // its already-crisp screen strip rather than shrink/upscale or fail.
        if (scale > detail.baseScale * 1.03) {
          screen = PdfStripScreen(
            // Detail returns to the visible cursor, not its overscan start.
            start: position,
            next: screen.next,
            width: math.max(availableWidth, bounds.width * scale),
            height: math.max(availableHeight, bounds.height * scale),
            pageWidth: page.geometry.width,
            pageHeight: page.geometry.height,
            pieces: [
              PdfStripPiece(
                page: detail.page,
                region: detail.region,
                source: bounds,
                left: math.max(0, (availableWidth - bounds.width * scale) / 2),
                top: 0,
                scale: scale,
                kind: region.kind,
              ),
            ],
            separators: const [],
            strip: strip ?? screen,
            detailZoom: scale / detail.baseScale,
          );
        }
      }
      final surfaces = <int, FlutterSelectionSurface>{};
      for (final page in screen.pieces.map((p) => p.page).toSet()) {
        try {
          surfaces[page] = await pdf.selectionSurface(page, 1);
        } catch (_) {
          // Textless pieces retain links and area marks through their transform.
        }
        if (!current()) return;
      }
      final selection = PdfStripSelection(screen, surfaces);
      List<FlutterAnnotation> annotations = const [];
      String? annotationError;
      try {
        annotations = await _records.listAnnotations(
          document: document,
          text: _readerText(document, cancellation, pdf: pdf),
          scale: 1,
          cancellationId: cancellation,
        );
      } catch (error) {
        annotationError = _describeError(error);
      }
      if (!current()) return;
      final size = pdfBitmapSizeFor(
        PdfPageSize(screen.width, screen.height),
        density,
      );
      recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder)..scale(density);
      for (final piece in screen.pieces) {
        final raster = await pdf.render(
          piece.page,
          piece.scale * density,
          clip: piece.source,
        );
        if (!current()) return;
        final image = await _decoder(
          raster.pixels,
          width: raster.width,
          height: raster.height,
        );
        images.add(image);
        if (!current()) return;
        final source = raster.source!;
        // Outward rounding adds edge pixels. Trim those, not the page text;
        // source pixels are always at least as dense as the destination.
        final sx = raster.width / source.width;
        final sy = raster.height / source.height;
        canvas.drawImageRect(
          image,
          ui.Rect.fromLTWH(
            (piece.source.left - source.left) * sx,
            (piece.source.top - source.top) * sy,
            piece.source.width * sx,
            piece.source.height * sy,
          ),
          ui.Rect.fromLTWH(piece.left, piece.top, piece.width, piece.height),
          ui.Paint()..filterQuality = ui.FilterQuality.high,
        );
      }
      picture = recorder.endRecording();
      recorder = null;
      owned = await picture.toImage(size.width, size.height);
      if (!current()) return;
      dispatch(
        _ReaderColumnsLoaded(
          generation,
          revision,
          layout,
          screen,
          owned,
          pages,
          columnWidth,
          back,
          ahead,
          selection,
          annotations,
          annotationError,
          offset,
          length,
          passive,
        ),
      );
      owned = null;
    } catch (error) {
      dispatch(
        _ReaderColumnsFailed(generation, revision, _describeError(error)),
      );
    } finally {
      if (cancellation != null) _bridge.releaseCancellation(id: cancellation);
      if (recorder != null && recorder.isRecording) {
        recorder.endRecording().dispose();
      }
      owned?.dispose();
      picture?.dispose();
      for (final image in images) {
        image.dispose();
      }
      dispatch(const _ReaderColumnsFinished());
    }
  }

  void _columnsLoaded(_ReaderColumnsLoaded message) {
    if (!_isCurrentColumns(message.generation, message.revision)) {
      message.image.dispose();
      return;
    }
    final retainDetailPlace =
        (_columnsIntent?.retainDetailPlace ?? false) &&
        message.screen.strip != null;
    _columnsIntent = null;
    var screen = message.screen;
    // A passive refill raced scrolling that continued while it loaded. Anchor
    // the loaded window to the content point the viewport shows now, instead
    // of yanking the reader back to the point captured at request time.
    if (message.passive && _model.pdfColumns != null) {
      final current = _model.pdfColumns!;
      final viewport = _columnsViewport;
      if (identical(viewport?.screen, current)) {
        final top = viewport!.top
            .clamp(0.0, math.max(0.0, current.height - .01))
            .toDouble();
        final piece = current.pieces.firstWhere((p) => p.top + p.height > top);
        final point = piece.toPage(piece.left, top);
        // The live point usually lands inside a piece the new window covers.
        // When it does not (scrolled past the window during the load, or into
        // a separator band), anchor at the nearest covered content instead of
        // the request-time point, so the post-jump scroll report still
        // converges with a fresh refill instead of yanking back.
        PdfStripPiece? target;
        var distance = double.infinity;
        for (final candidate in screen.pieces) {
          if (candidate.page != piece.page ||
              candidate.region != piece.region) {
            continue;
          }
          final candidateDistance =
              candidate.source.top <= point.y &&
                  candidate.source.bottom >= point.y
              ? 0.0
              : math.min(
                  (point.y - candidate.source.top).abs(),
                  (point.y - candidate.source.bottom).abs(),
                );
          if (candidateDistance < distance) {
            distance = candidateDistance;
            target = candidate;
            if (candidateDistance == 0) break;
          }
        }
        if (target != null) {
          final maxTop = math.max(
            0.0,
            screen.height - (screen.viewportHeight ?? 0),
          );
          screen = screen.withViewportTop(
            target.fromPage(point.x, point.y).y.clamp(0.0, maxTop).toDouble(),
          );
        }
      }
    }
    _columnsWidth = message.columnWidth;
    _columnsViewport = (screen: screen, top: screen.viewportTop);
    final old = _model.pageImage;
    _columnsPages
      ..clear()
      ..addEntries(
        message.pages.entries.where(
          (entry) =>
              entry.key < 3 ||
              (entry.key - screen.topPage).abs() <= 2 ||
              screen.pieces.any((piece) => piece.page == entry.key),
        ),
      );
    _columnsBack
      ..clear()
      ..addAll(message.back);
    _columnsAhead
      ..clear()
      ..addAll(message.ahead);
    final viewportTop = screen.viewportTop;
    final first = screen.pieces.firstWhere(
      (p) => p.top + p.height > viewportTop,
    );
    final endpoint = message.selection.surface.endpoints
        .where(
          (e) =>
              message.selection.location(e.offset.toInt()).page == first.page &&
              e.rect.top < first.top + first.height &&
              e.rect.bottom > math.max(first.top, viewportTop),
        )
        .firstOrNull;
    final offset = retainDetailPlace
        ? _model.readingLocation.offset
        : endpoint == null
        ? null
        : message.selection.location(endpoint.offset.toInt()).offset;
    // A passive detail render keeps the visible page point, not the region
    // origin. Initial detail entry instead starts at its actual visible center.
    final y = retainDetailPlace
        ? _model.pdfY!
        : first.toPage(first.left, math.max(first.top, viewportTop)).y;
    final x = retainDetailPlace
        ? _model.pdfX!
        : first
              .toPage(
                first.left +
                    math.min(
                          first.width,
                          message.layout.width - 2 * pdfStripSideInset,
                        ) /
                        2,
                first.top,
              )
              .x;
    final target = message.targetOffset == null
        ? null
        : message.targetOffset! + (message.selection.shifts[first.page] ?? 0);
    _referenceRevision++;
    _selectionRevision++;
    _emit(
      _model.copyWith(
        pdfColumns: screen,
        pdfColumnSelection: message.selection,
        pdfY: y,
        pdfX: x,
        pageImage: message.image,
        pdfSpread: null,
        readingPage: null,
        unit: first.page,
        readingOffset: offset,
        selectionSurface: _freezeSurface(message.selection.surface),
        annotations: message.annotations,
        annotationsReady: message.annotationError == null,
        annotationError: message.annotationError,
        savedSelections: _savedSelections(
          message.annotations,
          first.page,
          null,
          message.selection,
        ),
        selectionPhase: message.targetLength == null
            ? ReaderSelectionPhase.idle
            : ReaderSelectionPhase.selected,
        anchor: message.targetLength == null ? null : target,
        focus: message.targetLength == null
            ? null
            : target! + message.targetLength!,
        layout: message.layout,
        relayoutBusy: false,
        relayoutPending: false,
        contentState: ReaderContentState.ready,
        relayoutError: null,
      ),
    );
    final bookId = _model.document?.bookId;
    if (bookId != null) {
      _queueReadingStateSave(
        bookId,
        _model.document!.logicalUnitCount,
        FlutterReadingState(
          unit: BigInt.from(first.page),
          offset: offset == null ? null : BigInt.from(offset),
          zoom: message.layout.scale,
          pdfY: y,
          pdfX: x,
          pdfFit: _pdfFitOverride,
          progress: _bookProgress(_model),
        ),
      );
    }
    if (old != null) _frameScheduler(old.dispose);
  }
}
