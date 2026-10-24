part of 'controller.dart';

extension on ReaderController {
  bool get _canPeek =>
      !_closing &&
      !_suspended &&
      !_model.busy &&
      !_model.relayoutBusy &&
      !_model.relayoutPending &&
      _model.annotationOperations.isEmpty;

  void _referenceRequested(int unit, int? offset, {String? label}) {
    final document = _model.document;
    if (!_canPeek ||
        document == null ||
        unit < 0 ||
        unit >= document.logicalUnitCount.toInt()) {
      return;
    }
    if (document.format == FlutterBookFormat.pdf) {
      _startPdfReference(target: unit);
      return;
    }
    final source = _epubSource;
    if (document.format != FlutterBookFormat.epub ||
        source == null ||
        _epubSourceGeneration != _model.generation ||
        unit >= source.book.chapters.length) {
      return;
    }
    final chapter = source.book.chapters[unit];
    final scalar = offset ?? 0;
    if (scalar < 0 || scalar > chapter.scalarCount) return;
    final title = chapter.title;
    final entry = _model.contents.entries
        .where(
          (entry) =>
              entry.unit == unit &&
              (entry.offset ?? 0) == scalar &&
              entry.title.isNotEmpty,
        )
        .firstOrNull;
    final block = chapter.blocks
        .where(
          (node) =>
              node.canonical != null &&
              node.canonical!.start <= scalar &&
              scalar < node.canonical!.end,
        )
        .firstOrNull;
    final heading = block is EpubHeading
        ? String.fromCharCodes(
            chapter.canonicalText.runes
                .skip(block.canonical!.start)
                .take(block.canonical!.length),
          ).trim()
        : null;
    _referenceRevision += 1;
    _selectionCancelled(requestSurfaceFocus: false);
    _emit(
      _model.copyWith(
        referencePeek: ReaderReferencePeek(
          unit: unit,
          offset: offset,
          label:
              entry?.title ??
              heading ??
              (label?.trim().isNotEmpty == true ? label! : title),
          preview: _referencePreview(
            chapter.canonicalText,
            scalar,
            end: block is EpubHeading ? null : block?.canonical?.end,
          ),
        ),
      ),
    );
  }

  void _pdfLinkTapped(double x, double y) {
    if (!_canPeek ||
        _model.document?.format != FlutterBookFormat.pdf ||
        !x.isFinite ||
        !y.isFinite) {
      return;
    }
    _startPdfReference(x: x, y: y);
  }

  void _startPdfReference({int? target, double? x, double? y}) {
    final pdf = _pdfDocument;
    if (pdf == null) return;
    final generation = _model.generation;
    final revision = ++_referenceRevision;
    final unit = _model.unit;
    var spread = _model.pdfSpread;
    // Text geometry uses the committed layout scale, independently of the
    // fitted raster resolution. Only the textless fallback uses raster pixels.
    final scale = _model.selectionSurface != null
        ? _model.layout.scale
        : _renderedRasterScale ?? _model.layout.scale;
    if (_model.selectionSurface == null && spread != null) {
      spread = ReaderPdfSpread(
        facingUnit: spread.facingUnit,
        textShift: 0,
        firstLeft: pdf.rightToLeft
            ? pdf.pageSize(spread.facingUnit).width * scale
            : 0,
        facingLeft: pdf.rightToLeft ? 0 : pdf.pageSize(unit).width * scale,
      );
    }
    _activeBridgeOperations += 1;
    final effect = _pdfReferenceEffect(
      pdf,
      generation,
      revision,
      unit,
      spread,
      scale,
      target: target,
      x: x,
      y: y,
    );
    _referenceEffects.add(effect);
    unawaited(effect.then((_) => _referenceEffects.remove(effect)));
  }

  Future<void> _pdfReferenceEffect(
    PdfEngineDocument pdf,
    int generation,
    int revision,
    int firstUnit,
    ReaderPdfSpread? spread,
    double scale, {
    int? target,
    double? x,
    double? y,
  }) async {
    bool current() => _isCurrent(generation) && revision == _referenceRevision;
    try {
      ({double x, double y})? destination;
      if (target == null) {
        for (final unit in [firstUnit, ?spread?.facingUnit]) {
          final size = pdf.pageSize(unit);
          final left = spread?.leftOf(unit, firstUnit) ?? 0;
          final px = (x! - left) / scale;
          final py = size.height - y! / scale;
          if (px < 0 || px > size.width || py < 0 || py > size.height) continue;
          final links = await pdf.links(unit);
          if (!current()) return;
          for (final link in links) {
            if (!link.rects.any(
              (rect) =>
                  px >= rect.left &&
                  px <= rect.right &&
                  py >= rect.bottom &&
                  py <= rect.top,
            )) {
              continue;
            }
            if (link.page case final page?) {
              target = page;
              destination = link.destination;
            } else if (link.url case final url?
                when classifyEpubLink(url.toString()) ==
                    EpubLinkKind.external) {
              await _openExternalLink(url.toString());
              return;
            }
            break;
          }
          if (target != null) break;
        }
      }
      if (target == null || target < 0 || target >= pdf.pageCount) return;
      String text;
      var offset = 0;
      try {
        if (destination case final point?) {
          final surface = await pdf.selectionSurface(target, 1);
          text = surface.text;
          double? nearest;
          for (final endpoint in surface.endpoints) {
            final rect = endpoint.rect;
            final dx = point.x.clamp(rect.left, rect.right) - point.x;
            final dy = point.y.clamp(rect.top, rect.bottom) - point.y;
            final distance = dx * dx + dy * dy;
            if (nearest == null || distance < nearest) {
              nearest = distance;
              offset = endpoint.rangeStart.toInt();
            }
          }
        } else {
          text = await pdf.pageText(target);
        }
      } catch (_) {
        // Scanned pages and extraction failures still have a valid destination.
        text = '';
      }
      if (!current()) return;
      dispatch(
        _ReaderReferenceLoaded(
          generation,
          revision,
          ReaderReferencePeek(
            unit: target,
            offset: offset,
            label:
                _model.contents.entries
                    .where(
                      (entry) => entry.unit == target && entry.title.isNotEmpty,
                    )
                    .firstOrNull
                    ?.title ??
                '',
            preview: _referencePreview(text, offset),
          ),
        ),
      );
    } catch (_) {
      // An unreadable annotation is not a failed page.
    } finally {
      dispatch(const _ReaderReferenceFinished());
    }
  }
}

/// Take a small canonical excerpt at the destination, never the whole chapter.
String _referencePreview(String text, int offset, {int? end}) {
  final excerpt = String.fromCharCodes(
    text.runes
        .skip(offset)
        .take(end == null ? 501 : math.min(501, end - offset)),
  ).trim();
  if (excerpt.runes.length <= 500) return excerpt;
  return '${String.fromCharCodes(excerpt.runes.take(500)).trimRight()}…';
}
