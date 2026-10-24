part of 'view.dart';

class _DocumentView extends StatefulWidget {
  const _DocumentView({
    required this.document,
    required this.image,
    required this.model,
    required this.dispatch,
    required this.readerFocus,
    required this.actionFocus,
  });

  final FlutterDocumentSummary document;
  final ui.Image? image;
  final ReaderModel model;
  final void Function(ReaderMessage) dispatch;
  final FocusNode readerFocus;
  final FocusNode actionFocus;

  @override
  State<_DocumentView> createState() => _DocumentViewState();
}

class _DocumentViewState extends State<_DocumentView>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _pageTurn;
  late final _turnProgress = _pageTurn.drive(
    CurveTween(curve: Curves.easeOutCubic),
  );
  double _turnDirection = 1;

  /// The rendered content box of the selectable surface, i.e. the box the fit
  /// transform maps the surface into.
  final GlobalKey _contentKey = GlobalKey(debugLabel: 'reader content box');

  /// The overlay's own coordinate space: the action surface is positioned in
  /// the same space the [CustomSingleChildLayout] delegate receives.
  final GlobalKey _overlayKey = GlobalKey(debugLabel: 'reader overlay');

  /// Bumped whenever the rendered content geometry changes — a scroll or a
  /// content resize — so the action overlay re-reads the transform that
  /// positions it. Without it the target would be a snapshot taken when the
  /// selection was made.
  final ValueNotifier<int> _contentGeometry = ValueNotifier<int>(0);

  /// Whether the last interaction was a key press: the focus ring only shows
  /// then, so a click or a tap into the page does not frame it.
  final ValueNotifier<bool> _keyboardHighlight = ValueNotifier<bool>(false);

  @override
  void initState() {
    super.initState();
    _pageTurn = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
      value: 1,
    );
    WidgetsBinding.instance.addObserver(this);
    HardwareKeyboard.instance.addHandler(_keyPressed);
    GestureBinding.instance.pointerRouter.addGlobalRoute(_pointerEvent);
  }

  bool _keyPressed(KeyEvent event) {
    if (event is KeyDownEvent) _keyboardHighlight.value = true;
    return false;
  }

  void _pointerEvent(PointerEvent event) {
    if (event is PointerDownEvent) _keyboardHighlight.value = false;
  }

  // iOS reports Reduce Motion separately from disableAnimations in Flutter.
  bool get _reducedMotion =>
      MediaQuery.disableAnimationsOf(context) ||
      View.of(context).platformDispatcher.accessibilityFeatures.reduceMotion;

  @override
  void didChangeAccessibilityFeatures() {
    if (_reducedMotion) _pageTurn.value = 1;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_reducedMotion) _pageTurn.value = 1;
  }

  @override
  void didUpdateWidget(_DocumentView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final before = oldWidget.model;
    final after = widget.model;
    final oldPage = before.epubPage;
    final newPage = after.epubPage;
    if (!after.typography.animations ||
        _reducedMotion ||
        before.generation != after.generation ||
        before.continuousPresentation ||
        after.continuousPresentation ||
        before.layout != after.layout ||
        oldPage?.box.size != newPage?.box.size ||
        after.selectionPhase != ReaderSelectionPhase.idle) {
      _pageTurn.value = 1;
      return;
    }
    var direction = after.unit.compareTo(before.unit);
    if (direction == 0) {
      direction = (newPage?.canonicalStart ?? 0).compareTo(
        oldPage?.canonicalStart ?? 0,
      );
    }
    if (direction == 0) {
      // Empty table rows can occupy distinct pages at the same text offset.
      direction = (newPage?.pageIndex ?? 0).compareTo(oldPage?.pageIndex ?? 0);
    }
    if (direction == 0) return;
    _turnDirection = (after.rightToLeft ? -direction : direction).toDouble();
    _pageTurn.forward(from: 0);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    HardwareKeyboard.instance.removeHandler(_keyPressed);
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_pointerEvent);
    _pageTurn.dispose();
    _keyboardHighlight.dispose();
    _contentGeometry.dispose();
    super.dispose();
  }

  void _bumpContentGeometry() {
    if (!mounted) return;
    _contentGeometry.value += 1;
  }

  Widget _animatePage(Widget child) => AnimatedBuilder(
    animation: _pageTurn,
    builder: (context, child) => ClipRect(
      // Keep resting page shadows; only the moving page needs a viewport clip.
      clipBehavior: _pageTurn.value == 1 ? Clip.none : Clip.hardEdge,
      child: child,
    ),
    // Animate only the adopted page: outgoing PDF rasters are already
    // controller-released, including when text extraction is unavailable.
    child: FadeTransition(
      opacity: _turnProgress.drive(Tween<double>(begin: .72, end: 1)),
      child: SlideTransition(
        position: _turnProgress.drive(
          Tween<Offset>(
            begin: Offset(.06 * _turnDirection, 0),
            end: Offset.zero,
          ),
        ),
        child: child,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final document = widget.document;
    final image = widget.image;
    final model = widget.model;
    final dispatch = widget.dispatch;
    final readerFocus = widget.readerFocus;
    final actionFocus = widget.actionFocus;
    final title = document.title ?? 'Untitled document';
    final surface = model.selectionSurface;
    final page = image;
    if (model.contentState == ReaderContentState.failed) {
      // The failure message is a document-area text leaf: its ink follows the
      // reader palette (owner decision 2026-09-28) like the paper behind it,
      // not the light application chrome palette.
      return Center(
        child: Text(
          model.error ?? 'Document content unavailable',
          key: const ValueKey('reader-content-error'),
          style: TextStyle(
            color: pageColors(model.typography.theme).foreground,
          ),
        ),
      );
    }
    if ((document.format == FlutterBookFormat.epub && surface == null) ||
        (document.format != FlutterBookFormat.epub && page == null)) {
      return const Center(child: CircularProgressIndicator());
    }
    if (surface == null) {
      final colors = pageColors(model.typography.theme);
      final filter = _pdfPageColorFilter(colors.background, colors.foreground);
      final raster = RawImage(image: page, fit: BoxFit.contain);
      return CallbackShortcuts(
        bindings: readerPageKeys(model, dispatch, arrows: true),
        child: Focus(
          focusNode: readerFocus,
          autofocus: true,
          child: Column(
            children: [
              Expanded(
                child: Semantics(
                  key: const ValueKey('reader-document-semantics'),
                  label:
                      '$title, page ${model.unit + 1} of ${document.logicalUnitCount}.',
                  child: _animatePage(
                    Center(
                      child: filter == null
                          ? raster
                          : ColorFiltered(colorFilter: filter, child: raster),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }
    final screenReaderSelectionAvailable =
        !model.busy &&
        !model.relayoutBusy &&
        !model.relayoutPending &&
        surface.graphemeBoundaries.length >= 2 &&
        surface.graphemeBoundaries.first != surface.graphemeBoundaries.last;
    // The document-level shortcuts (escape, copy, page steps) are installed by
    // [_ReaderContentPane], above the document area and the saved-highlight
    // strip: the strip is outside this widget, and a shortcut that stopped at
    // the document edge would drop PageUp/PageDown from a focused strip control.
    return Column(
      children: [
        Expanded(
          child: Semantics(
            key: const ValueKey('reader-document-semantics'),
            container: true,
            explicitChildNodes: true,
            label: document.format == FlutterBookFormat.epub
                ? '$title, EPUB chapter ${model.unit + 1} of ${document.logicalUnitCount}. Selectable text.'
                : '$title, page ${model.unit + 1} of ${document.logicalUnitCount}. Selectable text.',
            child: TapRegion(
              onTapOutside: (event) =>
                  dispatch(ReaderSelectionPointerPressedOutside(event.pointer)),
              child: LayoutBuilder(
                builder: (context, constraints) => NotificationListener<Notification>(
                  // A scroll (or a clamped scroll offset after a resize)
                  // changes the content transform without rebuilding this
                  // widget, so the overlay is told to re-read it. The
                  // listener is typed for `Notification` because
                  // `ScrollMetricsNotification` is not a
                  // `ScrollNotification` in this Flutter version. It is a
                  // proxy: the Stack's coordinate space is unchanged.
                  onNotification: (notification) {
                    if (notification is ScrollUpdateNotification ||
                        notification is ScrollMetricsNotification) {
                      _bumpContentGeometry();
                    }
                    return false;
                  },
                  child: Stack(
                    key: _overlayKey,
                    children: [
                      Positioned.fill(
                        child: CallbackShortcuts(
                          bindings: {
                            ...readerPageKeys(model, dispatch, arrows: true),
                            const SingleActivator(
                              LogicalKeyboardKey.escape,
                            ): () =>
                                dispatch(const ReaderSelectionCancelled()),
                            const SingleActivator(
                              LogicalKeyboardKey.enter,
                            ): () =>
                                dispatch(const ReaderSelectionCommitted()),
                            const SingleActivator(
                              LogicalKeyboardKey.arrowLeft,
                              shift: true,
                            ): () => dispatch(
                              const ReaderSelectionKeyboardExtended(
                                ReaderSelectionMovement.visualLeft,
                                arrow: true,
                              ),
                            ),
                            const SingleActivator(
                              LogicalKeyboardKey.arrowRight,
                              shift: true,
                            ): () => dispatch(
                              const ReaderSelectionKeyboardExtended(
                                ReaderSelectionMovement.visualRight,
                                arrow: true,
                              ),
                            ),
                            const SingleActivator(
                              LogicalKeyboardKey.arrowLeft,
                              shift: true,
                              control: true,
                            ): () => dispatch(
                              const ReaderSelectionKeyboardExtended(
                                ReaderSelectionMovement.previousWord,
                              ),
                            ),
                            const SingleActivator(
                              LogicalKeyboardKey.arrowRight,
                              shift: true,
                              control: true,
                            ): () => dispatch(
                              const ReaderSelectionKeyboardExtended(
                                ReaderSelectionMovement.nextWord,
                              ),
                            ),
                            const SingleActivator(
                              LogicalKeyboardKey.arrowLeft,
                              shift: true,
                              alt: true,
                            ): () => dispatch(
                              const ReaderSelectionKeyboardExtended(
                                ReaderSelectionMovement.previousWord,
                              ),
                            ),
                            const SingleActivator(
                              LogicalKeyboardKey.arrowRight,
                              shift: true,
                              alt: true,
                            ): () => dispatch(
                              const ReaderSelectionKeyboardExtended(
                                ReaderSelectionMovement.nextWord,
                              ),
                            ),
                            const SingleActivator(
                              LogicalKeyboardKey.arrowUp,
                              shift: true,
                            ): () => dispatch(
                              const ReaderSelectionKeyboardExtended(
                                ReaderSelectionMovement.previousLine,
                                arrow: true,
                              ),
                            ),
                            const SingleActivator(
                              LogicalKeyboardKey.arrowDown,
                              shift: true,
                            ): () => dispatch(
                              const ReaderSelectionKeyboardExtended(
                                ReaderSelectionMovement.nextLine,
                                arrow: true,
                              ),
                            ),
                            const SingleActivator(
                              LogicalKeyboardKey.home,
                              shift: true,
                            ): () => dispatch(
                              const ReaderSelectionKeyboardExtended(
                                ReaderSelectionMovement.lineStart,
                              ),
                            ),
                            const SingleActivator(
                              LogicalKeyboardKey.end,
                              shift: true,
                            ): () => dispatch(
                              const ReaderSelectionKeyboardExtended(
                                ReaderSelectionMovement.lineEnd,
                              ),
                            ),
                            const SingleActivator(
                              LogicalKeyboardKey.arrowLeft,
                              shift: true,
                              meta: true,
                            ): () => dispatch(
                              const ReaderSelectionKeyboardExtended(
                                ReaderSelectionMovement.lineStart,
                              ),
                            ),
                            const SingleActivator(
                              LogicalKeyboardKey.arrowRight,
                              shift: true,
                              meta: true,
                            ): () => dispatch(
                              const ReaderSelectionKeyboardExtended(
                                ReaderSelectionMovement.lineEnd,
                              ),
                            ),
                            const SingleActivator(
                              LogicalKeyboardKey.contextMenu,
                            ): () => dispatch(
                              const ReaderSelectionActionsRequested(),
                            ),
                            const SingleActivator(
                              LogicalKeyboardKey.f10,
                              shift: true,
                            ): () => dispatch(
                              const ReaderSelectionActionsRequested(),
                            ),
                          },
                          child: Focus(
                            key: const ValueKey('reader-selection-focus'),
                            focusNode: readerFocus,
                            autofocus: true,
                            child: AnimatedBuilder(
                              animation: Listenable.merge([
                                readerFocus,
                                _keyboardHighlight,
                              ]),
                              builder: (context, child) => Semantics(
                                key: const ValueKey('reader-content-semantics'),
                                readOnly: true,
                                label: 'Document text: ${surface.text}',
                                hint: screenReaderSelectionAvailable
                                    ? 'Selects this text and shows selection actions.'
                                    : null,
                                onTap: screenReaderSelectionAvailable
                                    ? () => dispatch(
                                        const ReaderSelectionAllRequested(),
                                      )
                                    : null,
                                child: DecoratedBox(
                                  key: const ValueKey('reader-focus-indicator'),
                                  position: DecorationPosition.foreground,
                                  decoration: BoxDecoration(
                                    border:
                                        readerFocus.hasFocus &&
                                            _keyboardHighlight.value
                                        ? Border.all(
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.primary,
                                            width: 2,
                                          )
                                        : null,
                                  ),
                                  child: child,
                                ),
                              ),
                              child: Listener(
                                behavior: HitTestBehavior.translucent,
                                onPointerDown: (event) {
                                  if (event.kind !=
                                          ui.PointerDeviceKind.mouse ||
                                      (event.buttons & 1) != 0) {
                                    readerFocus.requestFocus();
                                  }
                                },
                                child: _animatePage(
                                  _ReachableSelectableSurface(
                                    contentKey: _contentKey,
                                    onContentGeometryChanged:
                                        _bumpContentGeometry,
                                    presentationKey: ValueKey(
                                      model.continuousPresentation
                                          ? 'reader-continuous-presentation'
                                          : 'reader-paginated-presentation',
                                    ),
                                    document: document,
                                    surface: surface,
                                    image: page,
                                    epubPage: model.epubPage,
                                    model: model,
                                    dispatch: dispatch,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (model.selectionPhase == ReaderSelectionPhase.selected)
                        Positioned.fill(
                          child: ValueListenableBuilder<int>(
                            // Re-reads the content transform after a scroll or a
                            // content resize, so the surface follows the range
                            // instead of staying where it was first placed.
                            valueListenable: _contentGeometry,
                            builder: (context, revision, child) =>
                                CustomSingleChildLayout(
                                  delegate: _SelectionActionsLayout(
                                    target: _selectionActionsTarget(
                                      surface,
                                      model,
                                      constraints.biggest,
                                    ),
                                  ),
                                  child: child,
                                ),
                            child: _SelectionActions(
                              model: model,
                              dispatch: dispatch,
                              focusNode: actionFocus,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// The selected range's rect in the overlay's own coordinate space.
  ///
  /// The range geometry lives in the surface's coordinate space and the
  /// overlay is a sibling of the (possibly scrolled) content, so the rect is
  /// mapped through the rendered content box's own transform. That keeps the
  /// action surface next to the range in every fit (EPUB, fit page, fit width,
  /// manual zoom) and while the content is scrolled, instead of assuming the
  /// content box equals the viewport.
  Rect _selectionActionsTarget(
    FlutterSelectionSurface surface,
    ReaderModel model,
    Size viewport,
  ) {
    final fit = _readerFit(model.typography);
    final selection = _selectionRangeRect(surface, model);
    if (selection == null) return Offset.zero & Size.zero;
    final surfaceSize = Size(surface.width, surface.height);
    final content = _contentKey.currentContext?.findRenderObject();
    final overlay = _overlayKey.currentContext?.findRenderObject();
    if (content is RenderBox &&
        overlay is RenderBox &&
        content.hasSize &&
        overlay.hasSize) {
      final destination = SurfaceTransform.create(
        fit,
        surfaceSize,
        content.size,
      ).toDestinationRect(selection);
      return MatrixUtils.transformRect(
        content.getTransformTo(overlay),
        destination,
      );
    }
    // Before the content box is laid out there is no rendered transform to
    // follow; the retained viewport-relative mapping still keeps the surface
    // inside the viewport.
    return SurfaceTransform.create(
      fit,
      surfaceSize,
      viewport,
    ).toDestinationRect(selection);
  }
}

/// The keys that turn pages wherever the reader's document has focus
/// (`docs/design-system.md`, Accessibility: arrow keys and Space for pages).
///
/// Left and Right follow the page on screen, so in a right-to-left book Left
/// turns forward, as its next-page margin does. Shift-arrows stay with
/// keyboard selection. The arrows are bound only with [arrows], around the
/// surface itself: elsewhere in the pane they move focus between controls
/// such as the selection actions.
///
/// A continuous page scrolls rather than turns, so it keeps only PageUp and
/// PageDown, which step between its chapters.
Map<ShortcutActivator, VoidCallback> readerPageKeys(
  ReaderModel model,
  void Function(ReaderMessage) dispatch, {
  bool arrows = false,
}) {
  final forward = model.rightToLeft ? -1 : 1;
  void step(int delta) => dispatch(pageStepMessage(model, delta));
  final paged = !model.continuousPresentation;
  return {
    const SingleActivator(LogicalKeyboardKey.pageUp): () => step(-1),
    const SingleActivator(LogicalKeyboardKey.pageDown): () => step(1),
    if (paged) ...{
      const SingleActivator(LogicalKeyboardKey.space): () => step(1),
      const SingleActivator(LogicalKeyboardKey.space, shift: true): () =>
          step(-1),
    },
    if (paged && arrows) ...{
      const SingleActivator(LogicalKeyboardKey.arrowRight): () => step(forward),
      const SingleActivator(LogicalKeyboardKey.arrowLeft): () => step(-forward),
    },
  };
}

/// The page-step message for [delta] (±1).
///
/// On the Dart EPUB path a step turns a page inside the chapter; every other
/// document and the retained EPUB path keep the logical-unit semantics, which
/// is what the edge columns and PageUp/PageDown have always dispatched.
ReaderMessage pageStepMessage(ReaderModel model, int delta) {
  if (model.epubPage != null) return ReaderPageStepRequested(delta);
  // A PDF read in spreads turns both pages of the spread.
  if (model.layout.spread && model.document?.format == FlutterBookFormat.pdf) {
    return ReaderUnitRequested(pdfSpreadStep(model.unit, delta), turn: true);
  }
  return ReaderUnitRequested(model.unit + delta, turn: true);
}

/// Whether a page step in [delta]'s direction can move the reader.
///
/// The Dart page window answers for itself (its window may still be filling,
/// in which case a step can extend it); the retained path keeps the unit-count
/// bound.
bool _canStepPage(ReaderModel model, int delta, int total) {
  final page = model.epubPage;
  if (page != null) {
    return delta < 0 ? page.canGoBackward : page.canGoForward;
  }
  final last = model.pdfSpread?.facingUnit ?? model.unit;
  return delta < 0 ? model.unit > 0 : last + 1 < total;
}

BoxFit _readerFit(ReaderTypographyPresentation typography) {
  if (typography.format == FlutterBookFormat.epub) return BoxFit.contain;
  return switch (typography.rasterFit) {
    ReaderRasterFit.fitPage => BoxFit.contain,
    ReaderRasterFit.fitWidth => BoxFit.fitWidth,
    ReaderRasterFit.manual => BoxFit.none,
  };
}

FlutterHighlightColor _nextColor(FlutterHighlightColor color) =>
    switch (color) {
      FlutterHighlightColor.yellow => FlutterHighlightColor.green,
      FlutterHighlightColor.green => FlutterHighlightColor.blue,
      FlutterHighlightColor.blue => FlutterHighlightColor.pink,
      FlutterHighlightColor.pink => FlutterHighlightColor.purple,
      FlutterHighlightColor.purple => FlutterHighlightColor.yellow,
    };

String _annotationResolutionSuffix(
  AppLocalizations l10n,
  FlutterAnnotationResolution resolution,
) => switch (resolution) {
  FlutterAnnotationResolution.exact => '',
  FlutterAnnotationResolution.recovered =>
    ' — ${l10n.readerAnnotationRecovered}',
  FlutterAnnotationResolution.ambiguous =>
    ' — ${l10n.readerAnnotationAmbiguous}',
  FlutterAnnotationResolution.orphaned =>
    ' — ${l10n.readerAnnotationUnavailable}',
};

String _colorName(AppLocalizations l10n, FlutterHighlightColor color) =>
    switch (color) {
      FlutterHighlightColor.yellow => l10n.readerHighlightYellow,
      FlutterHighlightColor.green => l10n.readerHighlightGreen,
      FlutterHighlightColor.blue => l10n.readerHighlightBlue,
      FlutterHighlightColor.pink => l10n.readerHighlightPink,
      FlutterHighlightColor.purple => l10n.readerHighlightPurple,
    };
