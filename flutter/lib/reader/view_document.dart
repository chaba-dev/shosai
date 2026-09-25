part of 'view.dart';

class _DocumentView extends StatelessWidget {
  const _DocumentView({
    required this.document,
    required this.image,
    required this.model,
    required this.settings,
    required this.dispatch,
    required this.readerFocus,
    required this.actionFocus,
  });

  final FlutterDocumentSummary document;
  final ui.Image? image;
  final ReaderModel model;
  final FlutterReaderSettings? settings;
  final void Function(ReaderMessage) dispatch;
  final FocusNode readerFocus;
  final FocusNode actionFocus;

  @override
  Widget build(BuildContext context) {
    final title = document.title ?? 'Untitled document';
    final surface = model.selectionSurface;
    final page = image;
    if (model.contentState == ReaderContentState.failed) {
      return Center(child: Text(model.error ?? 'Document content unavailable'));
    }
    if ((document.format == FlutterBookFormat.epub && surface == null) ||
        (document.format != FlutterBookFormat.epub && page == null)) {
      return const Center(child: CircularProgressIndicator());
    }
    if (surface == null) {
      return CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.pageUp): () =>
              dispatch(ReaderUnitRequested(model.unit - 1)),
          const SingleActivator(LogicalKeyboardKey.pageDown): () =>
              dispatch(ReaderUnitRequested(model.unit + 1)),
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
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            dispatch(const ReaderSelectionCancelled()),
        const SingleActivator(LogicalKeyboardKey.keyC, control: true): () =>
            dispatch(const ReaderSelectionCopyRequested()),
        const SingleActivator(LogicalKeyboardKey.keyC, meta: true): () =>
            dispatch(const ReaderSelectionCopyRequested()),
        const SingleActivator(LogicalKeyboardKey.pageUp): () =>
            dispatch(ReaderUnitRequested(model.unit - 1)),
        const SingleActivator(LogicalKeyboardKey.pageDown): () =>
            dispatch(ReaderUnitRequested(model.unit + 1)),
      },
      child: Column(
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
                onTapOutside: (event) => dispatch(
                  ReaderSelectionPointerPressedOutside(event.pointer),
                ),
                child: LayoutBuilder(
                  builder: (context, constraints) => Stack(
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
                                  presentationKey: ValueKey(
                                    settings?.continuous == true
                                        ? 'reader-continuous-presentation'
                                        : 'reader-paginated-presentation',
                                  ),
                                  document: document,
                                  settings: settings,
                                  surface: surface,
                                  image: page,
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
                          child: CustomSingleChildLayout(
                            delegate: _SelectionActionsLayout(
                              target:
                                  _readerFit(document.format, settings) ==
                                      BoxFit.contain
                                  ? _selectionActionTarget(
                                      surface,
                                      model,
                                      constraints.biggest,
                                      BoxFit.contain,
                                    )
                                  : Rect.fromCenter(
                                      center: Offset(
                                        constraints.maxWidth / 2,
                                        0,
                                      ),
                                      width: 0,
                                      height: 0,
                                    ),
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
          if (model.annotations.isNotEmpty)
            SizedBox(
              height: 64,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: model.annotations
                    .map(
                      (annotation) => Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: ShadCard(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              ShadButton.ghost(
                                onPressed: () => dispatch(
                                  ReaderAnnotationNavigated(annotation.id),
                                ),
                                child: Text(
                                  'Highlight ${annotation.unit.toInt() + 1}'
                                  '${_annotationResolutionSuffix(annotation.resolution)}',
                                ),
                              ),
                              ShadIconAction(
                                tooltip: 'Change color',
                                onPressed:
                                    model.annotationOperations.isNotEmpty ||
                                        model.relayoutBusy
                                    ? null
                                    : () => dispatch(
                                        ReaderAnnotationUpdated(
                                          annotation.id,
                                          _nextColor(annotation.color),
                                          annotation.body,
                                        ),
                                      ),
                                icon: const Icon(LucideIcons.palette),
                              ),
                              ShadIconAction(
                                tooltip: 'Edit note',
                                onPressed:
                                    model.annotationOperations.isNotEmpty ||
                                        model.relayoutBusy
                                    ? null
                                    : () => dispatch(
                                        ReaderAnnotationNoteRequested(
                                          annotation.id,
                                        ),
                                      ),
                                icon: const Icon(LucideIcons.notebookPen),
                              ),
                              ShadIconAction(
                                tooltip: 'Delete highlight',
                                onPressed:
                                    model.annotationOperations.isNotEmpty ||
                                        model.relayoutBusy
                                    ? null
                                    : () => dispatch(
                                        ReaderAnnotationDeleted(annotation.id),
                                      ),
                                icon: const Icon(LucideIcons.trash2),
                              ),
                            ],
                          ),
                        ),
                      ),
                    )
                    .toList(),
              ),
            ),
        ],
      ),
    );
  }
}

BoxFit _readerFit(FlutterBookFormat format, FlutterReaderSettings? settings) {
  if (format == FlutterBookFormat.epub) return BoxFit.contain;
  final zoom = settings?.pdfZoom ?? 0;
  if (zoom == -1) return BoxFit.fitWidth;
  if (zoom > 0) return BoxFit.none;
  return BoxFit.contain;
}

FlutterHighlightColor _nextColor(FlutterHighlightColor color) =>
    switch (color) {
      FlutterHighlightColor.yellow => FlutterHighlightColor.green,
      FlutterHighlightColor.green => FlutterHighlightColor.blue,
      FlutterHighlightColor.blue => FlutterHighlightColor.pink,
      FlutterHighlightColor.pink => FlutterHighlightColor.purple,
      FlutterHighlightColor.purple => FlutterHighlightColor.yellow,
    };

String _annotationResolutionSuffix(FlutterAnnotationResolution resolution) =>
    switch (resolution) {
      FlutterAnnotationResolution.exact => '',
      FlutterAnnotationResolution.recovered => ' — recovered',
      FlutterAnnotationResolution.ambiguous => ' — ambiguous',
      FlutterAnnotationResolution.orphaned => ' — unavailable',
    };

String _colorName(FlutterHighlightColor color) => switch (color) {
  FlutterHighlightColor.yellow => 'Yellow',
  FlutterHighlightColor.green => 'Green',
  FlutterHighlightColor.blue => 'Blue',
  FlutterHighlightColor.pink => 'Pink',
  FlutterHighlightColor.purple => 'Purple',
};
