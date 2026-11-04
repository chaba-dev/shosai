part of 'controller.dart';

final class _ReaderColumnsLoaded extends ReaderMessage {
  const _ReaderColumnsLoaded(
    this.generation,
    this.revision,
    this.layout,
    this.screen,
    this.image,
    this.pages,
    this.back,
  );
  final int generation;
  final int revision;
  final ReaderLayout layout;
  final PdfStripScreen screen;
  final ui.Image image;
  final Map<int, PdfStripPage> pages;
  final List<PdfStripPosition> back;
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
  bool _isCurrentColumns(int generation, int revision) =>
      _isCurrent(generation) &&
      !_suspended &&
      revision == _columnsRevision &&
      _rasterFit == ReaderRasterFit.columns;

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
      _requestColumns(screen.next, back: [..._columnsBack, screen.start]);
    } else if (_columnsBack.isNotEmpty) {
      _requestColumns(
        _columnsBack.last,
        back: _columnsBack.sublist(0, _columnsBack.length - 1),
      );
    } else if (screen.start.page > 0 ||
        screen.start.region > 0 ||
        screen.start.y != null) {
      _requestColumns(screen.start, previous: true);
    }
  }

  void _requestColumns(
    PdfStripPosition position, {
    List<PdfStripPosition>? back,
    bool previous = false,
    ({int page, int region, double zoom, double baseScale})? detail,
    PdfStripScreen? strip,
  }) {
    final pdf = _pdfDocument;
    final height = _epubViewportHeight;
    if (pdf == null ||
        _model.busy ||
        _closing ||
        _suspended ||
        height == null ||
        height <= 0 ||
        _requestedLayout.width <= 0) {
      return;
    }
    final generation = _model.generation;
    final revision = ++_columnsRevision;
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
      back ?? List.of(_columnsBack),
      previous: previous,
      detail: detail,
      strip: strip,
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
  }) async {
    bool current() => _isCurrentColumns(generation, revision);
    final pages = Map<int, PdfStripPage>.of(_columnsPages);
    final images = <ui.Image>[];
    ui.PictureRecorder? recorder;
    ui.Picture? picture;
    ui.Image? owned;
    try {
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
          final screen = layoutPdfColumnScreen(
            pages: pages,
            pageCount: pdf.pageCount,
            start: start,
            width: math.max(1, layout.width - 2 * pdfStripSideInset),
            height: math.max(1, height - pdfStripHeaderHeight),
            zoom: zoom,
          );
          final needed = screen.needsPage;
          if (needed == null) return screen;
          if (!await load(needed)) return null;
        }
        return null;
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
        final scale = detail.baseScale * detail.zoom;
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
          detailZoom: detail.zoom,
        );
      }
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
          back,
        ),
      );
      owned = null;
    } catch (error) {
      dispatch(
        _ReaderColumnsFailed(generation, revision, _describeError(error)),
      );
    } finally {
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
    _emit(
      _model.copyWith(
        pdfColumns: message.screen,
        pageImage: message.image,
        pdfSpread: null,
        readingPage: null,
        unit: message.screen.topPage,
        readingOffset: null,
        selectionSurface: null,
        selectionPhase: ReaderSelectionPhase.idle,
        anchor: null,
        focus: null,
        layout: message.layout,
        relayoutBusy: false,
        relayoutPending: false,
        contentState: ReaderContentState.ready,
        relayoutError: null,
      ),
    );
    if (old != null) _frameScheduler(old.dispose);
  }
}
