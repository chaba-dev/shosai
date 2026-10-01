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

class _DocumentViewState extends State<_DocumentView> {
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

  @override
  void dispose() {
    _contentGeometry.dispose();
    super.dispose();
  }

  void _bumpContentGeometry() {
    if (!mounted) return;
    _contentGeometry.value += 1;
  }

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
      return CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.pageUp): () =>
              dispatch(pageStepMessage(model, -1)),
          const SingleActivator(LogicalKeyboardKey.pageDown): () =>
              dispatch(pageStepMessage(model, 1)),
        },
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
                  child: Center(
                    child: RawImage(image: page, fit: BoxFit.contain),
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
                              ),
                            ),
                            const SingleActivator(
                              LogicalKeyboardKey.arrowRight,
                              shift: true,
                            ): () => dispatch(
                              const ReaderSelectionKeyboardExtended(
                                ReaderSelectionMovement.visualRight,
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
                              ),
                            ),
                            const SingleActivator(
                              LogicalKeyboardKey.arrowDown,
                              shift: true,
                            ): () => dispatch(
                              const ReaderSelectionKeyboardExtended(
                                ReaderSelectionMovement.nextLine,
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
                              animation: readerFocus,
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
                                    border: readerFocus.hasFocus
                                        ? Border.all(
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.primary,
                                            width: 3,
                                          )
                                        : null,
                                  ),
                                  child: child,
                                ),
                              ),
                              child: GestureDetector(
                                behavior: HitTestBehavior.translucent,
                                excludeFromSemantics: true,
                                onTap: readerFocus.requestFocus,
                                child: _ReachableSelectableSurface(
                                  contentKey: _contentKey,
                                  onContentGeometryChanged:
                                      _bumpContentGeometry,
                                  presentationKey: ValueKey(
                                    model.typography.continuous
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

/// The reader's saved-highlight strip below the document area.
///
/// The strip is a sibling of the document surface, not a child of it: the
/// reader's reported document box must be the box the page is rendered in, and
/// a strip inside that box would silently shrink the page (and, on the Dart
/// renderer, paginate it for a height it does not get).
class ReaderAnnotationStrip extends StatelessWidget {
  const ReaderAnnotationStrip({
    super.key,
    required this.model,
    required this.dispatch,
  });

  final ReaderModel model;
  final void Function(ReaderMessage) dispatch;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 64,
    child: ListView(
      scrollDirection: Axis.horizontal,
      children: model.annotations
          .map(
            (annotation) => _AnnotationCard(
              // The card owns its menu controller, so its identity must follow
              // the annotation: an unkeyed card would hand an open menu to
              // whichever annotation lands in its list position after a delete.
              key: ValueKey(annotation.id),
              annotation: annotation,
              model: model,
              dispatch: dispatch,
            ),
          )
          .toList(),
    ),
  );
}

/// One saved highlight's actions: the retained inline controls plus the
/// annotation context menu salvaged from #114.
///
/// The menu carries the same three actions as the inline controls (Change
/// color, Edit note, Delete highlight) and dispatches the same messages; the
/// card's own composition is the restored one, so no rejected visual ancestor
/// returns with it. It opens on secondary click and, as its keyboard
/// equivalent, on the ContextMenu key or Shift+F10 while a control in the card
/// has focus. The inline controls stay the primary, always-visible actions and
/// remain Tab-reachable.
class _AnnotationCard extends StatefulWidget {
  const _AnnotationCard({
    super.key,
    required this.annotation,
    required this.model,
    required this.dispatch,
  });

  final FlutterAnnotation annotation;
  final ReaderModel model;
  final void Function(ReaderMessage) dispatch;

  @override
  State<_AnnotationCard> createState() => _AnnotationCardState();
}

class _AnnotationCardState extends State<_AnnotationCard> {
  final ShadContextMenuController _menu = ShadContextMenuController();

  @override
  void dispose() {
    _menu.dispose();
    super.dispose();
  }

  /// The keyboard equivalent of a secondary click on the card.
  void _openMenu() {
    if (!_menu.isOpen) _menu.show();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final annotation = widget.annotation;
    final model = widget.model;
    final actionsDisabled =
        model.annotationOperations.isNotEmpty || model.relayoutBusy;
    void recolor() => widget.dispatch(
      ReaderAnnotationUpdated(
        annotation.id,
        _nextColor(annotation.color),
        annotation.body,
      ),
    );
    void editNote() =>
        widget.dispatch(ReaderAnnotationNoteRequested(annotation.id));
    void delete() => widget.dispatch(ReaderAnnotationDeleted(annotation.id));
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.contextMenu): _openMenu,
          const SingleActivator(LogicalKeyboardKey.f10, shift: true): _openMenu,
        },
        // The card's own controls are ShadButtons, whose secondary-tap
        // recognizer wins the gesture arena over the region's (the component
        // layer always installs the callbacks), so the region alone would only
        // open over the card's padding. A raw listener is not a gesture-arena
        // competitor: it sees the secondary press wherever it lands in the
        // card. The region still supplies the menu surface and its own
        // pointer-anchored placement for presses outside the controls.
        child: Listener(
          onPointerDown: (event) {
            if (event.buttons == kSecondaryButton) _openMenu();
          },
          child: ShadContextMenuRegion(
            controller: _menu,
            // The retained gestures stay untouched: the menu is a secondary
            // click affordance, and the keyboard equivalent is bound above.
            tapEnabled: false,
            longPressEnabled: false,
            items: [
              ShadContextMenuItem(
                enabled: !actionsDisabled,
                onPressed: recolor,
                child: Text(l10n.readerChangeColor),
              ),
              ShadContextMenuItem(
                enabled: !actionsDisabled,
                onPressed: editNote,
                child: Text(l10n.readerEditNote),
              ),
              ShadContextMenuItem(
                enabled: !actionsDisabled,
                onPressed: delete,
                child: Text(l10n.readerDeleteHighlight),
              ),
            ],
            child: ShadCard(
              key: ValueKey('reader-annotation-${annotation.id}'),
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ShadButton.ghost(
                    key: ValueKey(
                      'reader-annotation-navigate-${annotation.id}',
                    ),
                    // The label scales with the interface; the shared helper
                    // keeps the button's box at least as tall as the scaled
                    // line box, so 200% text is not clipped (RD-15).
                    height: shosaiShadButtonHeight(context),
                    onPressed: () => widget.dispatch(
                      ReaderAnnotationNavigated(annotation.id),
                    ),
                    child: Text(
                      '${l10n.readerHighlightLabel(annotation.unit.toInt() + 1)}'
                      '${_annotationResolutionSuffix(l10n, annotation.resolution)}',
                    ),
                  ),
                  ShadIconAction(
                    key: ValueKey('reader-annotation-color-${annotation.id}'),
                    tooltip: l10n.readerChangeColor,
                    onPressed: actionsDisabled ? null : recolor,
                    icon: const Icon(LucideIcons.palette),
                  ),
                  ShadIconAction(
                    key: ValueKey('reader-annotation-note-${annotation.id}'),
                    tooltip: l10n.readerEditNote,
                    onPressed: actionsDisabled ? null : editNote,
                    icon: const Icon(LucideIcons.notebookPen),
                  ),
                  ShadIconAction(
                    key: ValueKey('reader-annotation-delete-${annotation.id}'),
                    tooltip: l10n.readerDeleteHighlight,
                    onPressed: actionsDisabled ? null : delete,
                    icon: const Icon(LucideIcons.trash2),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The page-step message for [delta] (±1).
///
/// On the Dart EPUB path a step turns a page inside the chapter; every other
/// document and the retained EPUB path keep the logical-unit semantics, which
/// is what the edge columns and PageUp/PageDown have always dispatched.
ReaderMessage pageStepMessage(ReaderModel model, int delta) =>
    model.epubPage == null
    ? ReaderUnitRequested(model.unit + delta)
    : ReaderPageStepRequested(delta);

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
  return delta < 0 ? model.unit > 0 : model.unit + 1 < total;
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
