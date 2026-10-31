part of 'view.dart';

/// Presentation-only snapshots. The document controller continues to own live
/// rasters/layouts; these independent pixels survive their replacement.
class _ReaderPageTurn extends StatefulWidget {
  const _ReaderPageTurn({
    required this.model,
    required this.dispatch,
    required this.spread,
    required this.child,
  });
  final ReaderModel model;
  final void Function(ReaderMessage) dispatch;
  final bool spread;
  final Widget child;
  @override
  State<_ReaderPageTurn> createState() => _ReaderPageTurnState();
}

class _ReaderTurnScope extends InheritedWidget {
  const _ReaderTurnScope({required this.turn, required super.child});
  final _ReaderPageTurnState turn;
  static _ReaderPageTurnState? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_ReaderTurnScope>()?.turn;
  @override
  bool updateShouldNotify(_ReaderTurnScope oldWidget) => turn != oldWidget.turn;
}

class _ReaderPageTurnState extends State<_ReaderPageTurn>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final _boundaryKey = GlobalKey();
  GlobalKey? contentKey;
  late final AnimationController _progress;
  ui.Image? _outgoing;
  ui.Image? _incoming;
  Rect? _pageRect;
  int _delta = 1;
  bool _dragging = false;
  bool _committing = false;
  double _dragFraction = 0;
  int _captureRevision = 0;

  bool get pastMidpoint => _dragFraction > .5;

  bool get _motion =>
      widget.model.typography.animations &&
      !widget.model.continuousPresentation &&
      !MediaQuery.disableAnimationsOf(context) &&
      !View.of(context).platformDispatcher.accessibilityFeatures.reduceMotion;

  @override
  void initState() {
    super.initState();
    _progress = AnimationController(
      vsync: this,
      value: 1,
      duration: const Duration(milliseconds: 350),
    );
    WidgetsBinding.instance.addObserver(this);
  }

  void _reset() {
    _captureRevision++;
    _progress.stop();
    _outgoing?.dispose();
    _incoming?.dispose();
    _outgoing = _incoming = null;
    _pageRect = null;
    _dragging = _committing = false;
  }

  @override
  void didChangeAccessibilityFeatures() {
    if (!_motion) setState(_reset);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_motion) _reset();
  }

  ui.Image? _capture() {
    final boundary =
        _boundaryKey.currentContext?.findRenderObject()
            as RenderRepaintBoundary?;
    if (boundary == null ||
        !boundary.hasSize ||
        boundary.size.isEmpty ||
        (kDebugMode && boundary.debugNeedsPaint)) {
      return null;
    }
    // Cap the transient texture on high-density phones; never read pixels back
    // to Dart or re-rasterize text on an animation frame.
    final ratio = math.min(MediaQuery.devicePixelRatioOf(context), 2.0);
    return boundary.toImageSync(pixelRatio: ratio);
  }

  Rect? _pdfBounds(ReaderModel model) {
    final image = model.pageImage;
    if (model.document?.format != FlutterBookFormat.pdf || image == null) {
      return null;
    }
    final boundary =
        _boundaryKey.currentContext?.findRenderObject() as RenderBox?;
    final content =
        contentKey?.currentContext?.findRenderObject() as RenderBox?;
    if (boundary == null || content == null) return null;
    final fitted = applyBoxFit(
      _readerFit(model.typography),
      Size(image.width.toDouble(), image.height.toDouble()),
      content.size,
    );
    final local = Alignment.center.inscribe(
      fitted.destination,
      Offset.zero & content.size,
    );
    final origin = content.localToGlobal(local.topLeft, ancestor: boundary);
    return Rect.fromLTWH(
      origin.dx / boundary.size.width,
      origin.dy / boundary.size.height,
      local.width / boundary.size.width,
      local.height / boundary.size.height,
    );
  }

  @override
  void didUpdateWidget(_ReaderPageTurn oldWidget) {
    super.didUpdateWidget(oldWidget);
    final before = oldWidget.model;
    final after = widget.model;
    if (!_motion ||
        before.generation != after.generation ||
        before.layout != after.layout ||
        oldWidget.spread != widget.spread ||
        before.typography != after.typography ||
        after.selectionPhase != ReaderSelectionPhase.idle ||
        after.relayoutError != null) {
      _reset();
      return;
    }
    var delta = after.unit.compareTo(before.unit);
    if (delta == 0) {
      delta = (after.epubPage?.canonicalStart ?? 0).compareTo(
        before.epubPage?.canonicalStart ?? 0,
      );
    }
    if (delta == 0) {
      delta = (after.epubPage?.pageIndex ?? 0).compareTo(
        before.epubPage?.pageIndex ?? 0,
      );
    }
    if (delta != 0 && before.contentState == ReaderContentState.ready) {
      if (_outgoing == null) {
        _pageRect = _pdfBounds(before);
        _outgoing = _capture();
      }
      if (_outgoing == null) return;
      final from = _committing ? _progress.value : 0.0;
      _delta = delta;
      _dragging = _committing = false;
      _progress.value = from;
      final revision = ++_captureRevision;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || revision != _captureRevision) return;
        _incoming?.dispose();
        _incoming = _capture();
        _settle(1);
      });
    } else if (_dragging &&
        after.turnPreview != null &&
        after.turnPreview != before.turnPreview) {
      _makePreview(after.turnPreview!);
    }
  }

  void _makePreview(ReaderTurnPreview preview) {
    final boundary =
        _boundaryKey.currentContext?.findRenderObject() as RenderBox?;
    final content =
        contentKey?.currentContext?.findRenderObject() as RenderBox?;
    if (boundary == null || content == null || _outgoing == null) return;
    final rect =
        content.localToGlobal(Offset.zero, ancestor: boundary) & content.size;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final size = boundary.size;
    final ratio = _outgoing!.width / size.width;
    canvas.scale(ratio);
    canvas.drawImageRect(
      _outgoing!,
      Rect.fromLTWH(
        0,
        0,
        _outgoing!.width.toDouble(),
        _outgoing!.height.toDouble(),
      ),
      Offset.zero & size,
      Paint(),
    );
    canvas.save();
    canvas.clipRect(rect);
    canvas.translate(rect.left, rect.top);
    final colors = pageColors(widget.model.typography.theme);
    canvas.drawRect(
      Offset.zero & rect.size,
      Paint()..color = colors.background,
    );
    if (preview.page case final page?) {
      ReaderEpubPageContentPainter(
        page: page,
        fit: BoxFit.contain,
      ).paint(canvas, rect.size);
    } else if (preview.image case final image?) {
      final fitted = applyBoxFit(
        BoxFit.contain,
        Size(image.width.toDouble(), image.height.toDouble()),
        rect.size,
      );
      final target = Alignment.center.inscribe(
        fitted.destination,
        Offset.zero & rect.size,
      );
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        target,
        Paint()
          ..colorFilter = _pdfPageColorFilter(
            colors.background,
            colors.foreground,
          ),
      );
    }
    canvas.restore();
    final picture = recorder.endRecording();
    _incoming?.dispose();
    _incoming = picture.toImageSync(_outgoing!.width, _outgoing!.height);
    picture.dispose();
  }

  /// Returns true when this scope owns the swipe (also with motion disabled).
  bool drag(double dx) {
    if (_committing) return true;
    final model = widget.model;
    final delta = (dx < 0 ? 1 : -1) * (model.rightToLeft ? -1 : 1);
    if (!_canStepPage(
      model,
      delta,
      model.document?.logicalUnitCount.toInt() ?? 0,
    )) {
      return false;
    }
    if (!_dragging || _delta != delta) {
      _reset();
      _dragging = true;
      _delta = delta;
      _pageRect = _pdfBounds(model);
      if (_motion) _outgoing = _capture();
      if (_motion) widget.dispatch(ReaderTurnPreviewRequested(delta));
    }
    final box = context.findRenderObject()! as RenderBox;
    final width =
        box.size.width * (_pageRect?.width ?? 1) / (widget.spread ? 2 : 1);
    _dragFraction = dx.abs() / width;
    // Keep the lifted tip under the finger, rather than using an eased
    // animation fraction as a drag distance. Only the release is eased.
    setState(
      () => _progress.value = widget.spread
          ? math.acos((1 - _dragFraction).clamp(-1, 1)) / math.pi
          : (_dragFraction / (_delta < 0 ? 1 : 2)).clamp(0, 1),
    );
    return true;
  }

  void release({required bool complete}) {
    if (!_dragging) return;
    _dragging = false;
    if (complete) {
      _committing = true;
      widget.dispatch(pageStepMessage(widget.model, _delta));
      if (!_motion) setState(_reset);
    } else {
      _settle(0);
    }
  }

  void _settle(double end) {
    final revision = ++_captureRevision;
    final duration = Duration(
      milliseconds: (350 * (end - _progress.value).abs()).round().clamp(1, 350),
    );
    _progress
        .animateTo(end, duration: duration, curve: Curves.easeInOut)
        .whenCompleteOrCancel(() {
          if (!mounted ||
              revision != _captureRevision ||
              _progress.value != end) {
            return;
          }
          setState(_reset);
          widget.dispatch(const ReaderTurnPreviewRequested(0));
        });
    setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _reset();
    _progress.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _ReaderTurnScope(
    turn: this,
    child: Stack(
      fit: StackFit.expand,
      children: [
        RepaintBoundary(key: _boundaryKey, child: widget.child),
        if (_outgoing != null)
          Positioned.fill(
            child: IgnorePointer(
              child: ExcludeSemantics(
                child: AnimatedBuilder(
                  animation: _progress,
                  builder: (context, _) => CustomPaint(
                    key: const ValueKey('reader-page-curl'),
                    painter: _PageCurlPainter(
                      outgoing: _outgoing!,
                      incoming: _incoming,
                      pageRect: _pageRect,
                      progress: _progress.value,
                      backward: _delta < 0,
                      rightToLeft: widget.model.rightToLeft,
                      spread: widget.spread,
                      paper: pageColors(
                        widget.model.typography.theme,
                      ).background,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

/// One clipped texture for the front and a paper-colored reverse with faint
/// mirrored ink. No shaders, image decoding, layout or snapshots in paint.
class _PageCurlPainter extends CustomPainter {
  const _PageCurlPainter({
    required this.outgoing,
    required this.incoming,
    required this.pageRect,
    required this.progress,
    required this.backward,
    required this.rightToLeft,
    required this.spread,
    required this.paper,
  });
  final ui.Image outgoing;
  final ui.Image? incoming;
  // Normalized snapshot bounds: a fitted PDF turns at its raster edge, not
  // at the edge of the wider viewport around it.
  final Rect? pageRect;
  final double progress;
  final bool backward, rightToLeft, spread;
  final Color paper;

  void _image(Canvas canvas, ui.Image image, Size size, [double opacity = 1]) {
    canvas.save();
    // Mirror the geometry, not the book's text, for a leftward curl.
    if (rightToLeft) {
      canvas.translate(size.width, 0);
      canvas.scale(-1, 1);
    }
    canvas.drawImageRect(
      image,
      pageRect == null
          ? Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble())
          : Rect.fromLTWH(
              pageRect!.left * image.width,
              pageRect!.top * image.height,
              pageRect!.width * image.width,
              pageRect!.height * image.height,
            ),
      Offset.zero & size,
      Paint()
        ..color = paper.withValues(alpha: opacity)
        ..filterQuality = FilterQuality.low,
    );
    canvas.restore();
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    final under = backward ? outgoing : incoming;
    final leaf = backward ? incoming : outgoing;
    if (pageRect case final rect?) {
      final background = under ?? outgoing;
      canvas.drawImageRect(
        background,
        Rect.fromLTWH(
          0,
          0,
          background.width.toDouble(),
          background.height.toDouble(),
        ),
        Offset.zero & size,
        Paint(),
      );
      canvas.translate(rect.left * size.width, rect.top * size.height);
      size = Size(rect.width * size.width, rect.height * size.height);
      canvas.clipRect(Offset.zero & size);
    }
    if (rightToLeft) {
      canvas.translate(size.width, 0);
      canvas.scale(-1, 1);
    }
    canvas.drawColor(paper, BlendMode.srcOver);
    if (under != null) _image(canvas, under, size);
    if (leaf == null) {
      _image(canvas, outgoing, size);
      canvas.restore();
      return;
    }
    final t = backward ? 1 - progress : progress;
    final w = size.width, h = size.height;
    if (spread) {
      final spine = w / 2;
      // The stationary half stays put until the leaf crosses its spine.
      if (t < .5) {
        canvas.save();
        canvas.clipRect(Rect.fromLTWH(0, 0, spine, h));
        _image(canvas, leaf, size);
        canvas.restore();
      }
      final tip = spine + spine * math.cos(math.pi * t);
      final lift = math.sin(math.pi * t) * math.min(36.0, h * .06);
      final path = Path()
        ..moveTo(spine, 0)
        ..quadraticBezierTo((spine + tip) / 2, -lift, tip, lift)
        ..quadraticBezierTo(tip + lift * .4, h / 2, tip, h - lift)
        ..quadraticBezierTo((spine + tip) / 2, h + lift, spine, h)
        ..close();
      canvas.drawShadow(
        path,
        ShosaiTokens.appShadowBase.withValues(alpha: .25),
        12,
        false,
      );
      canvas.save();
      canvas.clipPath(path);
      if (t <= .5) {
        canvas.translate(spine, 0);
        canvas.scale(math.max(.001, (tip - spine) / spine), 1);
        canvas.translate(-spine, 0);
        _image(canvas, leaf, size);
      } else {
        canvas.drawColor(paper, BlendMode.srcOver);
        canvas.translate(spine, 0);
        canvas.scale(-math.max(.001, (spine - tip) / spine), 1);
        canvas.translate(-spine, 0);
        _image(canvas, leaf, size, .07);
      }
      canvas.restore();
      if (t > .5 && under != null) {
        canvas.save();
        canvas.clipPath(path);
        canvas.translate(spine, 0);
        canvas.scale((spine - tip) / spine, 1);
        canvas.translate(-spine, 0);
        _image(canvas, under, size, (2 * t - 1).clamp(0, 1));
        canvas.restore();
      }
      _shade(canvas, path, math.min(spine, tip), math.max(spine, tip));
    } else {
      final fold = w * (1 - t);
      final tip = w * (1 - 2 * t);
      final lift = math.sin(math.pi * t) * math.min(40.0, w * .08);
      final front = Path()
        ..moveTo(0, 0)
        ..lineTo(fold, 0)
        ..quadraticBezierTo(fold + lift, h / 2, fold, h)
        ..lineTo(0, h)
        ..close();
      canvas.save();
      canvas.clipPath(front);
      _image(canvas, leaf, size);
      canvas.restore();
      final back = Path()
        ..moveTo(fold, 0)
        ..quadraticBezierTo((tip + fold) / 2, lift, tip, lift)
        ..quadraticBezierTo(tip - lift, h / 2, tip, h - lift)
        ..quadraticBezierTo((tip + fold) / 2, h - lift, fold, h)
        ..quadraticBezierTo(fold + lift, h / 2, fold, 0)
        ..close();
      canvas.drawShadow(
        back,
        ShosaiTokens.appShadowBase.withValues(alpha: .25),
        10,
        false,
      );
      canvas.save();
      canvas.clipPath(back);
      canvas.drawColor(paper, BlendMode.srcOver);
      canvas.translate(2 * fold, 0);
      canvas.scale(-1, 1);
      _image(canvas, leaf, size, .065);
      canvas.restore();
      _shade(canvas, back, tip, fold + lift);
    }
    canvas.restore();
  }

  void _shade(Canvas canvas, Path path, double left, double right) {
    if (right - left < .1) return;
    final strength = math.sin(math.pi * progress);
    canvas.drawPath(
      path,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(left, 0),
          Offset(right, 0),
          [
            ShosaiTokens.appShadowBase.withValues(alpha: .09 * strength),
            ShosaiTokens.colorLightOnAccent.withValues(alpha: .12 * strength),
            ShosaiTokens.appShadowBase.withValues(alpha: .18 * strength),
          ],
          const [0, .55, 1],
        ),
    );
  }

  @override
  bool shouldRepaint(_PageCurlPainter oldDelegate) => true;
}
