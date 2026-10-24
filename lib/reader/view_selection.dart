part of 'view.dart';

class _SelectionActions extends StatelessWidget {
  const _SelectionActions({
    required this.model,
    required this.dispatch,
    required this.focusNode,
  });

  final ReaderModel model;
  final void Function(ReaderMessage) dispatch;
  final FocusNode focusNode;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final copyEnabled = model.selectedText != null;
    final persistenceEnabled =
        !model.busy &&
        !model.relayoutBusy &&
        model.annotationsReady &&
        model.annotationOperations.isEmpty;
    return Semantics(
      key: const ValueKey('selection-actions'),
      label: l10n.readerSelectionActions,
      container: true,
      child: ShadCard(
        padding: const EdgeInsets.all(8),
        child: SingleChildScrollView(
          child: Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              ShadButton.ghost(
                height: shosaiShadButtonHeight(context),
                focusNode: copyEnabled ? focusNode : null,
                onPressed: !copyEnabled
                    ? null
                    : () => dispatch(const ReaderSelectionCopyRequested()),
                // A Shad button lays its content out in a Row whose
                // non-flexible children get an unbounded width; a flexible
                // label ellipsizes instead of overflowing when the selection
                // surface is narrower than the label's natural width (a
                // compact viewport at a scaled interface, where the RD-06 edge
                // columns also scale with the interface).
                child: Flexible(child: Text(l10n.readerCopy)),
              ),
              for (final color in FlutterHighlightColor.values)
                ShadButton(
                  height: shosaiShadButtonHeight(context),
                  focusNode:
                      !copyEnabled &&
                          persistenceEnabled &&
                          color == FlutterHighlightColor.yellow
                      ? focusNode
                      : null,
                  onPressed: !persistenceEnabled
                      ? null
                      : () => dispatch(ReaderSelectionCommitted(color: color)),
                  child: Flexible(
                    child: Text(
                      _colorName(l10n, color),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ShadButton.ghost(
                height: shosaiShadButtonHeight(context),
                onPressed: !persistenceEnabled
                    ? null
                    : () => dispatch(const ReaderSelectionNoteRequested()),
                child: Flexible(child: Text(l10n.readerAddNote)),
              ),
              ShadButton.ghost(
                height: shosaiShadButtonHeight(context),
                focusNode: !copyEnabled && !persistenceEnabled
                    ? focusNode
                    : null,
                onPressed: () => dispatch(const ReaderSelectionCancelled()),
                child: Flexible(child: Text(l10n.readerSelectionCancel)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Rect? _selectionRangeRect(FlutterSelectionSurface surface, ReaderModel model) {
  final first = model.anchor!;
  final second = model.focus!;
  final start = first < second ? first : second;
  final end = first < second ? second : first;
  Rect? selected;
  for (final endpoint in surface.endpoints) {
    final rangeStart = endpoint.rangeStart.toInt();
    final rangeEnd = endpoint.rangeEnd.toInt();
    final focusedOffset = second == end ? end - 1 : start;
    final include = model.keyboardActionInvocation
        ? rangeStart <= focusedOffset && focusedOffset < rangeEnd
        : rangeStart < end && start < rangeEnd;
    if (!include) {
      continue;
    }
    final rect = endpoint.rect;
    final area = Rect.fromLTRB(rect.left, rect.top, rect.right, rect.bottom);
    selected = selected?.expandToInclude(area) ?? area;
  }
  return selected;
}

class _SelectionActionsLayout extends SingleChildLayoutDelegate {
  const _SelectionActionsLayout({required this.target});

  static const _gap = 8.0;
  final Rect target;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints(
        maxWidth: math.max(0, constraints.maxWidth - _gap * 2),
        maxHeight: math.max(0, constraints.maxHeight - _gap * 2),
      );

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final maxLeft = math.max(_gap, size.width - childSize.width - _gap);
    final left = (target.center.dx - childSize.width / 2).clamp(_gap, maxLeft);
    final above = target.top - childSize.height - _gap;
    final below = target.bottom + _gap;
    final maxTop = math.max(_gap, size.height - childSize.height - _gap);
    final top = (above >= _gap ? above : below).clamp(_gap, maxTop);
    return Offset(left, top);
  }

  @override
  bool shouldRelayout(_SelectionActionsLayout oldDelegate) =>
      target != oldDelegate.target;
}

class _ReachableSelectableSurface extends StatelessWidget {
  const _ReachableSelectableSurface({
    required this.contentKey,
    required this.onContentGeometryChanged,
    required this.presentationKey,
    required this.document,
    required this.surface,
    required this.image,
    required this.epubPage,
    required this.model,
    required this.dispatch,
  });

  /// The rendered content box, used to map the selected range into the
  /// overlay's coordinate space.
  final Key contentKey;

  /// Called after the content box's laid-out size changes, so the overlay can
  /// re-read the geometry it positions itself from.
  final VoidCallback onContentGeometryChanged;
  final Key presentationKey;
  final FlutterDocumentSummary document;
  final FlutterSelectionSurface surface;
  final ui.Image? image;

  /// The Dart-engine page window whose slices are painted, or null when the
  /// surface is the retained renderer's raster.
  final ReaderEpubPage? epubPage;
  final ReaderModel model;
  final void Function(ReaderMessage) dispatch;

  @override
  Widget build(BuildContext context) {
    final fit = _readerFit(model.typography);
    return LayoutBuilder(
      builder: (context, constraints) {
        Widget gestures(
          Widget Function(ScrollController, ScrollController) builder,
        ) => _ReaderPageGestures(
          model: model,
          dispatch: dispatch,
          fittedZoom: document.format == FlutterBookFormat.pdf
              ? model.typography.rasterZoom *
                    SurfaceTransform.create(
                      fit,
                      Size(surface.width, surface.height),
                      constraints.biggest,
                    ).scaleX
              : null,
          builder: builder,
        );
        Widget content(Size size) => KeyedSubtree(
          key: contentKey,
          child: SizedBox.fromSize(
            size: size,
            child: _ContentSizeProbe(
              // Inside the sized box, so the probe observes the content's own
              // tight, finite size rather than the scroll view's unbounded
              // constraints.
              onSizeChanged: onContentGeometryChanged,
              child: _SelectableSurface(
                key: ValueKey((
                  model.generation,
                  model.unit,
                  epubPage?.pageIndex,
                )),
                surface: surface,
                image: image,
                epubPage: epubPage,
                model: model,
                fit: fit,
                dispatch: dispatch,
              ),
            ),
          ),
        );
        final continuousPage = model.continuousPresentation ? epubPage : null;
        if (continuousPage != null) {
          // A continuous chapter is one page as tall as the chapter: the view
          // scrolls it, and starts at the location the page was requested for.
          return KeyedSubtree(
            key: presentationKey,
            child: _ContinuousEpubScroll(
              key: ValueKey(
                'reader-vertical-scroll-${model.generation}-${model.unit}',
              ),
              page: continuousPage,
              generation: model.generation,
              revealRevision: model.locationRequestRevision,
              dispatch: dispatch,
              child: content(
                Size(
                  constraints.maxWidth,
                  math.max(constraints.maxHeight, surface.height),
                ),
              ),
            ),
          );
        }
        if (document.format == FlutterBookFormat.epub ||
            fit == BoxFit.contain) {
          return KeyedSubtree(
            key: presentationKey,
            child: gestures((_, _) => content(constraints.biggest)),
          );
        }
        final natural = fit == BoxFit.fitWidth
            ? Size(
                constraints.maxWidth,
                constraints.maxWidth * surface.height / surface.width,
              )
            : Size(surface.width, surface.height);
        final reachable = Size(
          math.max(constraints.maxWidth, natural.width),
          math.max(constraints.maxHeight, natural.height),
        );
        return KeyedSubtree(
          key: presentationKey,
          child: gestures((horizontal, vertical) {
            final scrolled = SingleChildScrollView(
              key: ValueKey(
                'reader-vertical-scroll-${model.generation}-${model.unit}',
              ),
              controller: vertical,
              child: content(reachable),
            );
            if (fit == BoxFit.fitWidth) return scrolled;
            return SingleChildScrollView(
              key: ValueKey(
                'reader-horizontal-scroll-${model.generation}-${model.unit}',
              ),
              controller: horizontal,
              scrollDirection: Axis.horizontal,
              child: scrolled,
            );
          }),
        );
      },
    );
  }
}

/// Touch page turns and PDF zoom share a recognizer, so a pinch cannot also
/// turn a page. The same recognizer pans enlarged PDFs, leaving scroll views
/// to handle wheel/trackpad input without competing for touch pinches.
class _ReaderPageGestures extends StatefulWidget {
  const _ReaderPageGestures({
    required this.model,
    required this.dispatch,
    required this.fittedZoom,
    required this.builder,
  });

  final ReaderModel model;
  final void Function(ReaderMessage) dispatch;
  final double? fittedZoom;
  final Widget Function(ScrollController, ScrollController) builder;

  @override
  State<_ReaderPageGestures> createState() => _ReaderPageGesturesState();
}

class _ReaderPageGesturesState extends State<_ReaderPageGestures> {
  final _horizontal = ScrollController();
  final _vertical = ScrollController();
  final Map<int, Offset> _pointers = {};
  Offset _distance = Offset.zero;
  (int, int, int?)? _startedPage;
  double _startZoom = 1;
  double _startSpan = 1;
  double _previewScale = 1;
  bool _multiTouch = false;
  bool _cancelled = false;

  @override
  void dispose() {
    _horizontal.dispose();
    _vertical.dispose();
    super.dispose();
  }

  (int, int, int?) get _page => (
    widget.model.generation,
    widget.model.unit,
    widget.model.epubPage?.pageIndex,
  );

  bool get _enabled =>
      !widget.model.busy &&
      !widget.model.relayoutBusy &&
      widget.model.selectionPhase == ReaderSelectionPhase.idle;

  @override
  void didUpdateWidget(_ReaderPageGestures oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_startedPage != _page) {
      _startedPage = null;
      _previewScale = 1;
    }
  }

  void _finish() {
    final started = _startedPage;
    _startedPage = null;
    final model = widget.model;
    final scale = _previewScale;
    setState(() => _previewScale = 1);
    if (started != _page || !_enabled || _cancelled) return;
    if (_multiTouch) {
      if (widget.fittedZoom != null && (scale - 1).abs() >= .03) {
        widget.dispatch(ReaderTypographyChanged(zoom: _startZoom * scale));
      }
      return;
    }
    if (model.continuousPresentation ||
        _readerFit(model.typography) != BoxFit.contain ||
        _distance.dx.abs() < 48 ||
        _distance.dx.abs() < _distance.dy.abs() * 1.5) {
      return;
    }
    final delta = (_distance.dx < 0 ? 1 : -1) * (model.rightToLeft ? -1 : 1);
    final total = model.document?.logicalUnitCount.toInt() ?? 0;
    if (_canStepPage(model, delta, total)) {
      widget.dispatch(pageStepMessage(model, delta));
    }
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (event) {
      if (event.kind != ui.PointerDeviceKind.touch) return;
      if (_pointers.isEmpty) {
        _cancelled = false;
        _multiTouch = false;
        _distance = Offset.zero;
      }
      _pointers[event.pointer] = event.localPosition;
      if (_pointers.length == 2) {
        _startSpan = (_pointers.values.first - _pointers.values.last).distance;
      }
      _multiTouch |= _pointers.length > 1;
    },
    onPointerMove: (event) {
      if (_pointers.containsKey(event.pointer)) {
        _pointers[event.pointer] = event.localPosition;
      }
    },
    onPointerUp: (event) {
      if (_pointers.remove(event.pointer) != null && _pointers.isEmpty) {
        _finish();
      }
    },
    onPointerCancel: (event) {
      _pointers.remove(event.pointer);
      _cancelled = true;
      _startedPage = null;
      setState(() => _previewScale = 1);
    },
    child: GestureDetector(
      supportedDevices: const {ui.PointerDeviceKind.touch},
      excludeFromSemantics: true,
      behavior: HitTestBehavior.opaque,
      onDoubleTap: widget.fittedZoom == null || !_enabled
          ? null
          : () {
              if (!_enabled) return;
              widget.dispatch(
                widget.model.typography.rasterFit == ReaderRasterFit.manual
                    ? const ReaderTypographyChanged(
                        rasterFit: ReaderRasterFit.fitPage,
                      )
                    : ReaderTypographyChanged(zoom: widget.fittedZoom! * 2),
              );
            },
      onScaleStart: (details) {
        if (_startedPage != null) return;
        _startZoom = widget.fittedZoom ?? 1;
        _startedPage = _enabled && !_cancelled ? _page : null;
      },
      onScaleUpdate: (details) {
        _distance += details.focalPointDelta;
        _multiTouch |= details.pointerCount > 1;
        if (!_multiTouch && widget.fittedZoom != null && _enabled) {
          for (final (controller, delta) in [
            (_horizontal, details.focalPointDelta.dx),
            (_vertical, details.focalPointDelta.dy),
          ]) {
            if (!controller.hasClients) continue;
            final position = controller.position;
            controller.jumpTo(
              (position.pixels - delta).clamp(
                position.minScrollExtent,
                position.maxScrollExtent,
              ),
            );
          }
        }
        if (_pointers.length == 2 &&
            _startSpan > 0 &&
            widget.fittedZoom != null &&
            _startedPage == _page &&
            _enabled) {
          final scale =
              (_pointers.values.first - _pointers.values.last).distance /
              _startSpan;
          setState(
            () =>
                _previewScale = (_startZoom * scale).clamp(.25, 5) / _startZoom,
          );
        }
      },
      onScaleEnd: (details) {
        if (_multiTouch || _cancelled || !_enabled) return;
        for (final (controller, velocity) in [
          (_horizontal, details.velocity.pixelsPerSecond.dx),
          (_vertical, details.velocity.pixelsPerSecond.dy),
        ]) {
          if (controller.hasClients) {
            (controller.position as ScrollPositionWithSingleContext)
                .goBallistic(-velocity);
          }
        }
      },
      child: ClipRect(
        clipBehavior: _previewScale == 1 ? Clip.none : Clip.hardEdge,
        child: Transform.scale(
          scale: _previewScale,
          child: ScrollConfiguration(
            behavior: ScrollConfiguration.of(context).copyWith(
              dragDevices: {...ScrollConfiguration.of(context).dragDevices}
                ..remove(ui.PointerDeviceKind.touch),
            ),
            child: widget.builder(_horizontal, _vertical),
          ),
        ),
      ),
    ),
  );
}

/// Scrolls a continuous EPUB chapter, and brings the location each explicit
/// request was for into view.
///
/// Every location request (an open, a chapter change, a Contents entry, a
/// bookmark, a search hit, a link) advances [revealRevision], and its page's
/// target line is scrolled to the top of the view — the chapter start
/// included, and the same location again after the reader scrolled away. A
/// passive relayout (a resize, a height refresh) installs a page with the same
/// revision and keeps the scroll offset the reader has.
///
/// The page lays out only a window of the chapter: the view reports the region
/// it shows, and the controller moves the window toward it. When a new window
/// measures nodes above the viewport, the content the reader sees moves in the
/// column; the view scrolls by the same amount so it stays in place.
class _ContinuousEpubScroll extends StatefulWidget {
  const _ContinuousEpubScroll({
    super.key,
    required this.page,
    required this.generation,
    required this.revealRevision,
    required this.dispatch,
    required this.child,
  });

  final ReaderEpubPage page;
  final int generation;

  /// The model's [ReaderModel.locationRequestRevision] [page] answers.
  final int revealRevision;
  final void Function(ReaderMessage) dispatch;
  final Widget child;

  @override
  State<_ContinuousEpubScroll> createState() => _ContinuousEpubScrollState();
}

class _ContinuousEpubScrollState extends State<_ContinuousEpubScroll> {
  final ScrollController _scroll = ScrollController();

  /// The revision whose target has been revealed; the view reports what it
  /// shows only for it.
  int? _revealed;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_report);
    _revealTarget();
  }

  @override
  void didUpdateWidget(_ContinuousEpubScroll oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.revealRevision != oldWidget.revealRevision) {
      _revealTarget();
      return;
    }
    final before = oldWidget.page.window;
    final after = widget.page.window;
    if (before == null ||
        after == null ||
        identical(before, after) ||
        !_scroll.hasClients ||
        before.nodeTops.length != after.nodeTops.length) {
      return;
    }
    // What the reader sees keeps its place ([continuousCorrectedTop]): a
    // correction, not a scroll, so the new extent is applied at the next
    // layout, in the same frame the new window paints.
    final position = _scroll.position;
    final shift =
        continuousCorrectedTop(
          before,
          after,
          position.pixels - kEpubPageMargin,
        ) -
        (position.pixels - kEpubPageMargin);
    if (shift != 0) position.correctBy(shift);
    // The controller moves the window toward what the view shows now.
    WidgetsBinding.instance.addPostFrameCallback((_) => _report());
  }

  /// Reports the region the view shows, in the page's coordinates.
  void _report() {
    if (!mounted || !_scroll.hasClients || _revealed != widget.revealRevision) {
      return;
    }
    final position = _scroll.position;
    if (!position.hasContentDimensions) return;
    widget.dispatch(
      ReaderContinuousViewportChanged(
        generation: widget.generation,
        revision: widget.revealRevision,
        top: position.pixels,
        bottom: position.pixels + position.viewportDimension,
        window: widget.page.window,
      ),
    );
  }

  void _revealTarget() {
    final revision = widget.revealRevision;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // A newer request scheduled its own reveal: this one is superseded and
      // must not move the view back. A passive relayout in between keeps the
      // revision, so the target is read from the page installed now.
      if (!mounted ||
          !_scroll.hasClients ||
          widget.revealRevision != revision) {
        return;
      }
      final page = widget.page;
      // The chapter start is a target like any other: it scrolls to the top.
      final top = page.targetScalar <= 0
          ? 0.0
          : (_continuousTargetTop(page) ?? kEpubPageMargin) - kEpubPageMargin;
      final position = _scroll.position;
      _revealed = revision;
      _scroll.jumpTo(
        top.clamp(position.minScrollExtent, position.maxScrollExtent),
      );
      // A jump to the offset the view already has notifies nothing.
      _report();
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      SingleChildScrollView(controller: _scroll, child: widget.child);
}

/// The top, in page coordinates, of the line holding [page]'s target scalar
/// (the first caret at or after it in the target's node), or of the target's
/// node when it has no such line (an image, a rule); null when the page has
/// no target node.
double? _continuousTargetTop(ReaderEpubPage page) {
  final window = page.window;
  final node = window?.targetNode;
  if (window == null || node == null || node >= window.nodeTops.length - 1) {
    return null;
  }
  final nodeTop = window.nodeTops[node] + kEpubPageMargin;
  final nodeEnd = window.nodeTops[node + 1] + kEpubPageMargin;
  final target = BigInt.from(page.targetScalar);
  FlutterSelectionEndpoint? best;
  for (final endpoint in page.surface.endpoints) {
    if (endpoint.offset < target || endpoint.rect.top >= nodeEnd) continue;
    if (best == null || endpoint.offset < best.offset) best = endpoint;
  }
  return best?.rect.top ?? nodeTop;
}

/// Reports the content box's laid-out size after it changes.
///
/// The action overlay positions itself from the content box's rendered
/// transform, and a size change (a resize, a new fit) does not necessarily
/// rebuild the document view: the probe schedules a post-layout notification so
/// the overlay re-reads the geometry instead of keeping a stale target.
class _ContentSizeProbe extends StatefulWidget {
  const _ContentSizeProbe({required this.onSizeChanged, required this.child});

  final VoidCallback onSizeChanged;
  final Widget child;

  @override
  State<_ContentSizeProbe> createState() => _ContentSizeProbeState();
}

class _ContentSizeProbeState extends State<_ContentSizeProbe> {
  Size? _reported;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final size = constraints.biggest;
      if (_reported != size) {
        _reported = size;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) widget.onSizeChanged();
        });
      }
      return widget.child;
    },
  );
}

/// Paints one Dart-engine page window's slices.
///
/// The painters are the measured ones the page's own selection surface was
/// built from, so what is painted and what a pointer addresses cannot drift.
class ReaderEpubPageContentPainter extends CustomPainter {
  const ReaderEpubPageContentPainter({required this.page, required this.fit});

  final ReaderEpubPage page;
  final BoxFit fit;

  @override
  void paint(Canvas canvas, Size size) {
    final source = Rect.fromLTWH(
      0,
      0,
      page.box.size.width,
      page.box.size.height,
    );
    final transform = SurfaceTransform.create(fit, source.size, size);
    canvas.save();
    transform.apply(canvas);
    canvas.drawRect(source, Paint()..color = page.palette.background);
    paintPageSlices(canvas, page.page, page.palette, page.box);
    if ((page.facing, page.facingBox) case (final facing?, final box?)) {
      paintPageSlices(canvas, facing, page.palette, box);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(ReaderEpubPageContentPainter oldDelegate) =>
      oldDelegate.page != page || oldDelegate.fit != fit;
}

class _SelectableSurface extends StatefulWidget {
  const _SelectableSurface({
    super.key,
    required this.surface,
    required this.image,
    required this.epubPage,
    required this.model,
    required this.fit,
    required this.dispatch,
  });

  final FlutterSelectionSurface surface;
  final ui.Image? image;

  /// The Dart-engine page window to paint, or null for the retained raster.
  final ReaderEpubPage? epubPage;
  final ReaderModel model;
  final BoxFit fit;
  final void Function(ReaderMessage) dispatch;

  @override
  State<_SelectableSurface> createState() => _SelectableSurfaceState();
}

class _SelectableSurfaceState extends State<_SelectableSurface> {
  /// Movement past this many logical pixels turns a press into a drag.
  ///
  /// A press that never travels further is a tap, and a tap on a painted link
  /// activates it (the evaluated prototype's policy). A drag is a selection
  /// gesture and never activates a link.
  static const double _tapSlop = 6;

  int? _touchPointer;

  /// The pointer that may still become a tap, and where it went down.
  int? _tapPointer;
  Offset? _tapOrigin;

  /// Starts a tap candidate for a primary press.
  void _beginTapCandidate(PointerDownEvent event) {
    final primary =
        event.kind != ui.PointerDeviceKind.mouse || (event.buttons & 1) != 0;
    if (!primary) return;
    _tapPointer = event.pointer;
    _tapOrigin = event.localPosition;
  }

  /// Drops the candidate once the press travels past [_tapSlop].
  void _moveTapCandidate(PointerMoveEvent event) {
    if (_tapPointer != event.pointer) return;
    final origin = _tapOrigin;
    if (origin == null || (event.localPosition - origin).distance > _tapSlop) {
      _tapPointer = null;
      _tapOrigin = null;
    }
  }

  void _cancelTapCandidate(int pointer) {
    if (_tapPointer == pointer) _clearTapCandidate();
  }

  void _clearTapCandidate() {
    _tapPointer = null;
    _tapOrigin = null;
  }

  /// Activates a painted link under a completed tap, if there is one.
  ///
  /// The retained renderer exposes no link geometry, so only a Dart page
  /// produces the intent; the controller owns classification and resolution.
  void _endTapCandidate(PointerUpEvent event, SurfaceTransform transform) {
    final origin = _tapOrigin;
    final isTap =
        _tapPointer == event.pointer &&
        origin != null &&
        (event.localPosition - origin).distance <= _tapSlop;
    _tapPointer = null;
    _tapOrigin = null;
    if (!isTap) return;
    final page = widget.epubPage;
    if (page == null) return;
    final source = transform.toSource(event.localPosition);
    final href =
        pageLinkAt(page.page, page.box, source) ??
        switch ((page.facing, page.facingBox)) {
          (final facing?, final box?) => pageLinkAt(facing, box, source),
          _ => null,
        };
    if (href != null) widget.dispatch(ReaderLinkActivated(href));
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final transform = SurfaceTransform.create(
          widget.fit,
          Size(widget.surface.width, widget.surface.height),
          constraints.biggest,
        );
        FlutterSelectionEndpoint? endpoint(
          Offset position, {
          bool nearest = false,
        }) {
          if (!nearest && !transform.destination.contains(position)) {
            return null;
          }
          final source = transform.toSource(position, clamp: nearest);
          for (final endpoint in widget.surface.endpoints) {
            final rect = endpoint.rect;
            if (Rect.fromLTRB(
              rect.left,
              rect.top,
              rect.right,
              rect.bottom,
            ).contains(source)) {
              return endpoint;
            }
          }
          if (!nearest || widget.surface.endpoints.isEmpty) return null;
          FlutterSelectionEndpoint? closest;
          double? distance;
          for (final endpoint in widget.surface.endpoints) {
            final rect = endpoint.rect;
            final dx = source.dx.clamp(rect.left, rect.right) - source.dx;
            final dy = source.dy.clamp(rect.top, rect.bottom) - source.dy;
            final candidate = dx * dx + dy * dy;
            if (distance == null || candidate < distance) {
              closest = endpoint;
              distance = candidate;
            }
          }
          return closest;
        }

        final epubPage = widget.epubPage;
        final pdfPageShadow =
            epubPage == null &&
            widget.model.document?.format == FlutterBookFormat.pdf &&
            ShellLayout.forWidth(MediaQuery.sizeOf(context).width) !=
                ShellLayout.phone;
        final contentPainter = epubPage == null
            ? _PageContentPainter(
                image: widget.image,
                surface: widget.surface,
                backgroundColor: pageColors(
                  widget.model.typography.theme,
                ).background,
                foregroundColor: pageColors(
                  widget.model.typography.theme,
                ).foreground,
                recolorImage:
                    widget.model.document?.format == FlutterBookFormat.epub,
                fit: widget.fit,
              )
            : ReaderEpubPageContentPainter(page: epubPage, fit: widget.fit);
        return Listener(
          key: const ValueKey('reader-selection-surface'),
          behavior: HitTestBehavior.opaque,
          onPointerDown: (event) {
            _beginTapCandidate(event);
            if (event.kind == ui.PointerDeviceKind.touch) {
              _touchPointer ??= event.pointer;
              return;
            }
            final primary =
                event.kind != ui.PointerDeviceKind.mouse ||
                (event.buttons & 1) != 0;
            if (!primary) return;
            final value = endpoint(event.localPosition);
            if (value == null) {
              widget.dispatch(
                ReaderSelectionPointerPressedOutside(event.pointer),
              );
            } else {
              final source = transform.toSource(event.localPosition);
              widget.dispatch(
                ReaderSelectionPointerStarted(
                  event.pointer,
                  value.offset.toInt(),
                  rangeStart: value.rangeStart.toInt(),
                  rangeEnd: value.rangeEnd.toInt(),
                  x: source.dx,
                  y: source.dy,
                ),
              );
            }
          },
          onPointerMove: (event) {
            _moveTapCandidate(event);
            if (event.kind == ui.PointerDeviceKind.touch) return;
            final value = endpoint(event.localPosition, nearest: true);
            if (value != null) {
              final source = transform.toSource(
                event.localPosition,
                clamp: true,
              );
              widget.dispatch(
                ReaderSelectionPointerMoved(
                  event.pointer,
                  value.offset.toInt(),
                  x: source.dx,
                  y: source.dy,
                ),
              );
            }
          },
          onPointerUp: (event) {
            _endTapCandidate(event, transform);
            if (event.kind != ui.PointerDeviceKind.touch) {
              widget.dispatch(ReaderSelectionPointerEnded(event.pointer));
            }
          },
          onPointerCancel: (event) {
            _cancelTapCandidate(event.pointer);
            if (event.kind != ui.PointerDeviceKind.touch ||
                _touchPointer == event.pointer) {
              widget.dispatch(ReaderSelectionPointerCancelled(event.pointer));
            }
            if (_touchPointer == event.pointer) _touchPointer = null;
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onLongPressStart: (details) {
              // A long press is a selection gesture, never a link tap.
              _clearTapCandidate();
              final pointer = _touchPointer;
              final value = endpoint(details.localPosition);
              if (pointer == null || value == null) return;
              final source = transform.toSource(details.localPosition);
              widget.dispatch(
                ReaderSelectionPointerStarted(
                  pointer,
                  value.offset.toInt(),
                  rangeStart: value.rangeStart.toInt(),
                  rangeEnd: value.rangeEnd.toInt(),
                  x: source.dx,
                  y: source.dy,
                ),
              );
            },
            onLongPressMoveUpdate: (details) {
              final pointer = _touchPointer;
              final value = endpoint(details.localPosition, nearest: true);
              if (pointer == null || value == null) return;
              final source = transform.toSource(
                details.localPosition,
                clamp: true,
              );
              widget.dispatch(
                ReaderSelectionPointerMoved(
                  pointer,
                  value.offset.toInt(),
                  x: source.dx,
                  y: source.dy,
                ),
              );
            },
            onLongPressEnd: (_) {
              final pointer = _touchPointer;
              if (pointer != null) {
                widget.dispatch(ReaderSelectionPointerEnded(pointer));
              }
              _touchPointer = null;
            },
            onLongPressCancel: () {
              final pointer = _touchPointer;
              if (pointer != null) {
                widget.dispatch(ReaderSelectionPointerCancelled(pointer));
              }
              _touchPointer = null;
            },
            child: Stack(
              fit: StackFit.expand,
              children: [
                // A PDF page lies on the stage like the EPUB page's paper,
                // with `shadow-page` under the raster; a phone page is
                // full-bleed and has none.
                if (pdfPageShadow)
                  Positioned.fromRect(
                    rect: transform.destination,
                    child: DecoratedBox(
                      key: const ValueKey('reader-pdf-page-shadow'),
                      decoration: BoxDecoration(
                        boxShadow: _readerPageShadow(ShellPalette.of(context)),
                      ),
                    ),
                  ),
                RepaintBoundary(
                  key: const ValueKey('reader-page-paint'),
                  child: KeyedSubtree(
                    key: ValueKey('reader-fit-${widget.fit.name}'),
                    child: CustomPaint(painter: contentPainter),
                  ),
                ),
                CustomPaint(
                  painter: PagePainter(
                    image: widget.image,
                    surface: widget.surface,
                    backgroundColor: pageColors(
                      widget.model.typography.theme,
                    ).background,
                    foregroundColor: pageColors(
                      widget.model.typography.theme,
                    ).foreground,
                    recolorImage:
                        widget.model.document?.format == FlutterBookFormat.epub,
                    fit: widget.fit,
                    anchor: widget.model.anchor,
                    focus: widget.model.focus,
                    savedSelections: widget.model.savedSelections,
                    annotations: widget.model.annotations
                        .where(
                          (item) =>
                              item.unit.toInt() == widget.model.unit ||
                              item.unit.toInt() ==
                                  widget.model.pdfSpread?.facingUnit,
                        )
                        .toList(growable: false),
                    currentUnit: widget.model.unit,
                    spread: widget.model.pdfSpread,
                    paintContent: false,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
