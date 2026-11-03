part of 'controller.dart';

/// A PDF leaf (a page, or a spread) next to the one shown, rendered before
/// it is asked for so that a page turn adopts it at once.
///
/// A PDF turn otherwise reads the page's text, renders and decodes it after
/// the tap, a few hundred milliseconds on a phone during which the curl cannot
/// start. A leaf is only a cache: whoever finds one that matches what it would
/// render takes it, and anything else renders as before.
final class _PdfLeaf {
  _PdfLeaf({
    required this.generation,
    required this.unit,
    required this.facing,
    required this.layout,
    required this.rasterScale,
  });
  final int generation;
  final int unit;
  final int? facing;
  final ReaderLayout layout;
  final double rasterScale;
  late final Future<_PdfLeafContent?> content;

  /// Owned by the leaf until taken. Null once taken or discarded.
  ui.Image? _image;
  bool _discarded = false;

  bool matches(
    int generation,
    int unit,
    int? facing,
    ReaderLayout layout,
    double rasterScale,
  ) =>
      !_discarded &&
      generation == this.generation &&
      unit == this.unit &&
      facing == this.facing &&
      layout == this.layout &&
      rasterScale == this.rasterScale;

  /// Gives the decoded leaf to the caller, who owns it from now on.
  ui.Image? take() {
    final image = _image;
    _image = null;
    _discarded = true;
    return image;
  }

  void discard() {
    _discarded = true;
    _image?.dispose();
    _image = null;
  }
}

/// What a leaf's page text read gave: the surface, or why there is none.
final class _PdfLeafContent {
  const _PdfLeafContent({this.surface, this.spread, this.selectionError});
  final FlutterSelectionSurface? surface;
  final ReaderPdfSpread? spread;
  final String? selectionError;
}

extension on ReaderController {
  /// The leaf a turn by [delta] would show from [model]'s place, or null past
  /// either end of the document.
  int? _pdfLeafUnit(ReaderModel model, PdfEngineDocument pdf, int delta) {
    final unit = model.layout.spread
        ? pdfSpreadStep(model.unit, delta)
        : model.unit + delta;
    if (unit < 0 || unit >= pdf.pageCount) return null;
    return model.layout.spread ? pdfSpreadStart(unit) : unit;
  }

  double _pdfLeafScale(
    PdfEngineDocument pdf,
    int unit,
    ReaderLayout layout,
    int? facing,
  ) =>
      _fittedRasterScale(pdf, unit, layout.width, facing: facing) ??
      layout.scale;

  /// Renders the leaves on either side of a settled PDF page, the next one
  /// first, and drops the ones a turn can no longer reach.
  void _prefetchPdfLeaves() {
    final pdf = _pdfDocument;
    final document = _model.document;
    if (!renderPdfAhead ||
        pdf == null ||
        document == null ||
        document.format != FlutterBookFormat.pdf ||
        _model.contentState != ReaderContentState.ready ||
        _model.continuousPresentation ||
        !_canPeek) {
      return;
    }
    final generation = _model.generation;
    final layout = _model.layout;
    final wanted = <_PdfLeaf>[];
    for (final delta in const [1, -1]) {
      final unit = _pdfLeafUnit(_model, pdf, delta);
      if (unit == null) continue;
      final facing = _pdfFacingUnit(pdf, unit, layout);
      final double scale;
      try {
        scale = _pdfLeafScale(pdf, unit, layout, facing);
      } catch (_) {
        continue;
      }
      final cached = _pdfLeaves
          .where(
            (leaf) => leaf.matches(generation, unit, facing, layout, scale),
          )
          .firstOrNull;
      if (cached != null) {
        wanted.add(cached);
        continue;
      }
      final leaf = _PdfLeaf(
        generation: generation,
        unit: unit,
        facing: facing,
        layout: layout,
        rasterScale: scale,
      );
      leaf.content = _loadPdfLeaf(pdf, leaf);
      // Like a turn preview, the render retains the engine document until it
      // drains, even if the reader closes in the meantime.
      final effect = leaf.content.then((_) {});
      _referenceEffects.add(effect);
      unawaited(effect.then((_) => _referenceEffects.remove(effect)));
      wanted.add(leaf);
    }
    for (final leaf in _pdfLeaves) {
      if (!wanted.contains(leaf)) leaf.discard();
    }
    _pdfLeaves
      ..clear()
      ..addAll(wanted);
  }

  Future<_PdfLeafContent?> _loadPdfLeaf(
    PdfEngineDocument pdf,
    _PdfLeaf leaf,
  ) async {
    try {
      var content = const _PdfLeafContent();
      try {
        final (:surface, :spread) = await _pdfSurface(
          pdf,
          leaf.unit,
          leaf.layout.scale,
          facing: leaf.facing,
        );
        content = _PdfLeafContent(surface: surface, spread: spread);
      } catch (error) {
        content = _PdfLeafContent(
          spread: _textlessSpread(leaf.facing),
          selectionError: ReaderController._describeError(error),
        );
      }
      if (leaf._discarded) return null;
      final (rendered, _) = await _renderPdfPage(
        pdf,
        leaf.unit,
        leaf.layout,
        facing: leaf.facing,
      );
      if (leaf._discarded) return null;
      final image = await _decoder(
        rendered.pixels,
        width: rendered.width,
        height: rendered.height,
      );
      if (leaf._discarded) {
        image.dispose();
        return null;
      }
      leaf._image = image;
      return content;
    } catch (_) {
      // A leaf that fails to render is rendered again, and its error
      // reported, by the turn that asks for it.
      return null;
    }
  }

  /// The rendered leaf for [unit], if one is ready or on its way.
  _PdfLeaf? _pdfLeafFor(
    PdfEngineDocument pdf,
    int generation,
    int unit,
    int? facing,
    ReaderLayout layout,
  ) {
    final double scale;
    try {
      scale = _pdfLeafScale(pdf, unit, layout, facing);
    } catch (_) {
      return null;
    }
    return _pdfLeaves
        .where((leaf) => leaf.matches(generation, unit, facing, layout, scale))
        .firstOrNull;
  }

  void _discardPdfLeaves() {
    for (final leaf in _pdfLeaves) {
      leaf.discard();
    }
    _pdfLeaves.clear();
  }
}
