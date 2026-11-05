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
    this.selection,
    this.annotations,
    this.annotationError,
    this.targetOffset,
    this.targetLength,
  );
  final int generation;
  final int revision;
  final ReaderLayout layout;
  final PdfStripScreen screen;
  final ui.Image image;
  final Map<int, PdfStripPage> pages;
  final double? columnWidth;
  final List<PdfStripPosition> back;
  final PdfStripSelection selection;
  final List<FlutterAnnotation> annotations;
  final String? annotationError;
  final int? targetOffset;
  final int? targetLength;
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
        screen.strip == null ||
        _model.relayoutBusy ||
        _closing ||
        _suspended) {
      return;
    }
    final piece = screen.pieces.single;
    final visible = ui.Rect.fromLTWH(
      piece.left,
      piece.top,
      piece.width,
      piece.height,
    ).intersect(message.viewport);
    if (visible.isEmpty) return;
    final point = piece.toPage(visible.center.dx, visible.top);
    if (_model.pdfX == point.x && _model.pdfY == point.y) return;
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
    _emit(_model.copyWith(pdfX: point.x, pdfY: point.y, readingOffset: offset));
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
          zoom: _model.layout.scale,
          progress: _bookProgress(_model),
        ),
      );
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
          zoom: _model.layout.scale,
          progress: _bookProgress(_model),
        ),
      );
    }
  }

  void _pdfDoubleTapped(double x, double y) {
    if (!_canPeek || !x.isFinite || !y.isFinite) return;
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
  void _refreshColumns() {
    final pending = _columnsIntent;
    final screen = _model.pdfColumns;
    final piece = screen?.strip == null ? null : screen!.pieces.single;
    _requestColumns(
      pending?.position ??
          screen?.start ??
          PdfStripPosition(_model.readingLocation.unit, y: _model.pdfY),
      back: pending?.back,
      previous: pending?.previous ?? false,
      offset: pending?.offset,
      length: pending?.length,
      x: pending?.x,
      locate: pending?.locate ?? false,
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
    if (delta > 0) {
      if (screen.next.page >= _pdfDocument!.pageCount) return;
      _readingStatePersistenceBlocked = false;
      _requestColumns(screen.next, back: [..._columnsBack, screen.start]);
    } else if (_columnsBack.isNotEmpty) {
      _readingStatePersistenceBlocked = false;
      _requestColumns(
        _columnsBack.last,
        back: _columnsBack.sublist(0, _columnsBack.length - 1),
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
    bool previous = false,
    ({int page, int region, double zoom, double baseScale})? detail,
    PdfStripScreen? strip,
    bool retainDetailPlace = false,
    int? offset,
    int? length,
    double? x,
    bool locate = false,
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
      previous: intent.previous,
      detail: detail,
      strip: strip,
      offset: intent.offset,
      length: length,
      x: intent.x,
      locate: intent.locate,
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
    required bool previous,
    required ({int page, int region, double zoom, double baseScale})? detail,
    required PdfStripScreen? strip,
    required int? offset,
    required int? length,
    required double? x,
    required bool locate,
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
            // Front matter may leave the fixed sample without body columns.
            // Once a body is needed, find the first analyzable one in document
            // order, never whichever later page happened to enter the cache.
            // Pure fallback documents do not trigger this forward search.
            for (var p = 0; p < pdf.pageCount; p++) {
              if (!await load(p)) return null;
              columnWidth = typicalPdfColumnWidth([pages[p]!.columns]);
              if (columnWidth != null) break;
            }
          }
          final screen = layoutPdfColumnScreen(
            pages: pages,
            pageCount: pdf.pageCount,
            start: start,
            width: math.max(1, layout.width - 2 * pdfStripSideInset),
            height: math.max(1, height - pdfStripHeaderHeight),
            zoom: zoom,
            columnWidth: columnWidth,
            // A jumped-to range must clear the overlaid toolbar and capsule.
            // Reserve space in layout, not by hiding part of the raster.
            topInset: length == null
                ? 0
                : math.min(96, math.max(1, height - pdfStripHeaderHeight) / 3),
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
          var moved = true;
          while (moved) {
            moved = false;
            for (final line in regions[region].lines) {
              if (line.bounds.top < y! && line.bounds.bottom > y) {
                y = line.bounds.top;
                moved = true;
              }
            }
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
          final reached =
              next.page > position.page ||
              next.page == position.page &&
                  (next.region > position.region ||
                      next.region == position.region &&
                          (next.y ?? -1) >= (position.y ?? -1));
          if (reached) break;
          back.add(cursor);
          cursor = next;
        }
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
        final availableHeight = math.max(1.0, height - pdfStripHeaderHeight);
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
            start: screen.start,
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
                zoomable: true,
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
          selection,
          annotations,
          annotationError,
          offset,
          length,
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
    _columnsWidth = message.columnWidth;
    final old = _model.pageImage;
    _columnsPages
      ..clear()
      ..addEntries(
        message.pages.entries.where(
          (entry) =>
              entry.key < 3 || (entry.key - message.screen.topPage).abs() <= 2,
        ),
      );
    _columnsBack
      ..clear()
      ..addAll(message.back);
    final first = message.screen.pieces.first;
    final endpoint = message.selection.surface.endpoints
        .where(
          (e) =>
              message.selection.location(e.offset.toInt()).page == first.page &&
              e.rect.top < first.top + first.height &&
              e.rect.bottom > first.top,
        )
        .firstOrNull;
    final offset = retainDetailPlace
        ? _model.readingLocation.offset
        : endpoint == null
        ? null
        : message.selection.location(endpoint.offset.toInt()).offset;
    // A passive detail render keeps the visible page point, not the region
    // origin. Initial detail entry instead starts at its actual visible center.
    final y = retainDetailPlace ? _model.pdfY! : first.source.top;
    final x = retainDetailPlace
        ? _model.pdfX!
        : message.screen.strip == null
        ? (first.source.left + first.source.right) / 2
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
        pdfColumns: message.screen,
        pdfColumnSelection: message.selection,
        pdfY: y,
        pdfX: x,
        pageImage: message.image,
        pdfSpread: null,
        readingPage: null,
        unit: message.screen.topPage,
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
          progress: _bookProgress(_model),
        ),
      );
    }
    if (old != null) _frameScheduler(old.dispose);
  }
}
