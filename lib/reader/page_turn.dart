part of 'controller.dart';

/// A speculative leaf, never a navigation or a durable reading position.
final class ReaderTurnPreview {
  const ReaderTurnPreview({required this.delta, this.page, this.image});
  final int delta;
  final ReaderEpubPage? page;
  final ui.Image? image;
}

/// Zero cancels speculation; ±1 asks for the neighboring leaf.
final class ReaderTurnPreviewRequested extends ReaderMessage {
  const ReaderTurnPreviewRequested(this.delta);
  final int delta;
}

final class _ReaderTurnPreviewFinished extends ReaderMessage {
  const _ReaderTurnPreviewFinished();
}

final class _ReaderTurnPreviewLoaded extends ReaderMessage {
  const _ReaderTurnPreviewLoaded(
    this.generation,
    this.layoutRevision,
    this.revision,
    this.preview,
    this.session,
  );
  final int generation;
  final int layoutRevision;
  final int revision;
  final ReaderTurnPreview preview;
  final ChapterLayoutSession? session;
}

extension on ReaderController {
  void _clearTurnPreview() {
    _turnPreviewRevision++;
    final image = _model.turnPreview?.image;
    final session = _turnPreviewSession;
    _turnPreviewSession = null;
    if (_model.turnPreview != null) {
      _model = _model.copyWith(turnPreview: null);
    }
    if (image != null) _frameScheduler(image.dispose);
    if (session != null) _frameScheduler(session.dispose);
  }

  void _turnPreviewRequested(int delta) {
    if (delta == 0) {
      _clearTurnPreview();
      _emit(_model);
      return;
    }
    if (!_canPeek || _model.continuousPresentation) return;
    _clearTurnPreview();
    final generation = _model.generation;
    final layoutRevision = _layoutRevision;
    final revision = _turnPreviewRevision;
    final origin = _model;
    _activeBridgeOperations++;
    final effect = _loadTurnPreview(
      origin,
      delta,
      generation,
      layoutRevision,
      revision,
    );
    // Like a reference lookup, speculation retains the PDF document until its
    // in-flight work drains, even if the reader closes in the meantime.
    _referenceEffects.add(effect);
    unawaited(effect.then((_) => _referenceEffects.remove(effect)));
  }

  Future<void> _loadTurnPreview(
    ReaderModel origin,
    int delta,
    int generation,
    int layoutRevision,
    int revision,
  ) async {
    bool current() =>
        _isCurrentLayout(generation, layoutRevision) &&
        revision == _turnPreviewRevision;
    ui.Image? image;
    ChapterLayoutSession? ownedSession;
    try {
      final document = origin.document;
      if (document == null) return;
      ReaderEpubPage? previewPage;
      if (document.format == FlutterBookFormat.pdf) {
        final pdf = _pdfDocument;
        if (pdf == null) return;
        final unit = origin.layout.spread
            ? pdfSpreadStep(origin.unit, delta)
            : origin.unit + delta;
        if (unit < 0 || unit >= pdf.pageCount) return;
        final (raster, _) = await _renderPdfPage(
          pdf,
          unit,
          origin.layout,
          facing: _pdfFacingUnit(pdf, unit, origin.layout),
        );
        if (!current()) return;
        image = await _decoder(
          raster.pixels,
          width: raster.width,
          height: raster.height,
        );
      } else {
        final page = origin.epubPage;
        final source = _epubSource;
        final key = _epubSessionKey;
        var session = _epubSession;
        if (page == null || source == null || key == null || session == null) {
          return;
        }
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
        var unit = origin.unit;
        var scalar = step.scalar;
        var edge = EpubPositionEdge.startOrInterior;
        var vertical = key.vertical;
        if (scalar == null) {
          if (!step.complete) return;
          unit += delta;
          if (unit < 0 || unit >= source.book.chapters.length) return;
          final refusal = source.layoutLimitExceeded(unit);
          if (refusal != null) return;
          final chapter = source.book.chapters[unit];
          vertical = chapter.writingMode == EpubWritingMode.verticalRl;
          await source.ensureImages(chapter, _epubImageDecoder);
          if (!current()) return;
          final box = epubPageBoxFor(
            ui.Size(key.pageWidth, key.height),
            vertical: vertical,
          );
          ownedSession = ChapterLayoutSession(
            chapter: chapter,
            spec: ChapterLayoutSpec(
              width: box.inlineExtent,
              height: box.blockExtent,
              typography: _epubTypography(origin.layout, source),
              vertical: vertical,
            ),
            images: source.images,
            clock: _layoutClock,
          );
          session = ownedSession;
          scalar = delta < 0 ? chapter.scalarCount : 0;
          edge = delta < 0
              ? EpubPositionEdge.end
              : EpubPositionEdge.startOrInterior;
          session.layoutWindowAt(scalar);
          while (session.firstNodeIndex > 0 ||
              (delta < 0 && !session.complete)) {
            await Future<void>.delayed(const Duration(milliseconds: 1));
            if (!current()) return;
            final grown = session.firstNodeIndex > 0
                ? session.layoutBackward(maxNodes: 24, maxMicros: 8000)
                : session.layoutForward(maxNodes: 24, maxMicros: 8000);
            if (grown == 0) break;
          }
        }
        previewPage = pageWindowFor(
          session: session,
          scalar: scalar,
          unit: unit,
          chapterCount: document.logicalUnitCount.toInt(),
          windowSize: ui.Size(origin.layout.width, key.height),
          spread: _ensureFacingPage(session, key, scalar),
          edge: edge,
          rightToLeft:
              source.book.pageProgression == EpubDirection.rtl || vertical,
          vertical: vertical,
        );
      }
      if (!current()) return;
      dispatch(
        _ReaderTurnPreviewLoaded(
          generation,
          layoutRevision,
          revision,
          ReaderTurnPreview(delta: delta, page: previewPage, image: image),
          ownedSession,
        ),
      );
      image = null;
      ownedSession = null;
    } catch (_) {
      // A preview failure is not a failed navigation. Release still asks the
      // normal guarded navigation path to turn, or cancels without any write.
    } finally {
      image?.dispose();
      ownedSession?.dispose();
      dispatch(const _ReaderTurnPreviewFinished());
    }
  }
}
