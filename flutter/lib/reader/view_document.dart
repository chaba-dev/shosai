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
              _ReaderUnitNavigation(
                document: document,
                model: model,
                dispatch: dispatch,
              ),
              if (model.toolsVisible)
                Flexible(
                  child: _ReaderTools(
                    document: document,
                    model: model,
                    dispatch: dispatch,
                  ),
                ),
              if (model.persistenceError != null)
                Flexible(child: _ReaderToolError(model: model)),
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
          _ReaderUnitNavigation(
            document: document,
            model: model,
            dispatch: dispatch,
          ),
          if (model.toolsVisible)
            Flexible(
              child: _ReaderTools(
                document: document,
                model: model,
                dispatch: dispatch,
              ),
            ),
          if (model.persistenceError != null)
            Flexible(child: _ReaderToolError(model: model)),
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

class _ReaderUnitNavigation extends StatelessWidget {
  const _ReaderUnitNavigation({
    required this.document,
    required this.model,
    required this.dispatch,
  });

  final FlutterDocumentSummary document;
  final ReaderModel model;
  final void Function(ReaderMessage) dispatch;

  @override
  Widget build(BuildContext context) {
    if (document.logicalUnitCount <= BigInt.one) return const SizedBox.shrink();
    return Semantics(
      container: true,
      label:
          '${document.format == FlutterBookFormat.epub ? 'Chapter' : 'Page'} ${model.unit + 1} of ${document.logicalUnitCount}',
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          ShadIconAction(
            tooltip: 'Previous',
            onPressed: model.unit > 0 && !model.relayoutBusy
                ? () => dispatch(ReaderUnitRequested(model.unit - 1))
                : null,
            icon: const Icon(LucideIcons.chevronLeft),
          ),
          Text('${model.unit + 1} / ${document.logicalUnitCount}'),
          ShadIconAction(
            tooltip: 'Next',
            onPressed:
                model.unit + 1 < document.logicalUnitCount.toInt() &&
                    !model.relayoutBusy
                ? () => dispatch(ReaderUnitRequested(model.unit + 1))
                : null,
            icon: const Icon(LucideIcons.chevronRight),
          ),
        ],
      ),
    );
  }
}

class _ReaderTools extends StatelessWidget {
  const _ReaderTools({
    required this.document,
    required this.model,
    required this.dispatch,
  });

  final FlutterDocumentSummary document;
  final ReaderModel model;
  final void Function(ReaderMessage) dispatch;

  @override
  Widget build(BuildContext context) {
    if (!model.toolsVisible) return const SizedBox.shrink();
    final currentBookmark = model.bookmarks
        .where(
          (bookmark) =>
              bookmark.unit.toInt() == model.unit &&
              bookmark.offset?.toInt() == model.readingOffset,
        )
        .firstOrNull;
    final locationBookmarked = currentBookmark != null;
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: math.max(1, MediaQuery.sizeOf(context).height * .35),
      ),
      child: SingleChildScrollView(
        key: const ValueKey('reader-tools-scroll'),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (document.format != FlutterBookFormat.cbz)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: ShadInput(
                  placeholder: const Text('Search this document'),
                  leading: const Icon(LucideIcons.search, size: 16),
                  trailing: model.searchBusy
                      ? const Padding(
                          padding: EdgeInsets.only(left: 8),
                          child: SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : null,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (query) =>
                      dispatch(ReaderSearchRequested(query)),
                ),
              ),
            if (model.searchResults.isNotEmpty)
              SizedBox(
                height: 52,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: model.searchResults.length,
                  itemBuilder: (context, index) {
                    final result = model.searchResults[index];
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: ShadButton.outline(
                        onPressed: () => dispatch(
                          ReaderUnitRequested(
                            result.unit.toInt(),
                            offset: result.offset.toInt(),
                            length: result.length.toInt(),
                          ),
                        ),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 180),
                          child: Text(
                            result.context,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            if (document.bookId != null)
              SizedBox(
                height: 48,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: model.bookmarks.length + 1,
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      return Row(
                        children: [
                          ShadIconAction(
                            tooltip: locationBookmarked
                                ? 'Remove bookmark'
                                : 'Bookmark this location',
                            onPressed: model.bookmarkBusy
                                ? null
                                : () => dispatch(const ReaderBookmarkToggled()),
                            icon: Icon(
                              locationBookmarked
                                  ? LucideIcons.bookmarkCheck
                                  : LucideIcons.bookmark,
                            ),
                          ),
                          ShadIconAction(
                            tooltip: 'Bookmark with note',
                            onPressed: model.bookmarkBusy
                                ? null
                                : () => dispatch(
                                    ReaderBookmarkNoteRequested(
                                      currentBookmark,
                                    ),
                                  ),
                            icon: const Icon(LucideIcons.bookmarkPlus),
                          ),
                        ],
                      );
                    }
                    final bookmark = model.bookmarks[index - 1];
                    return Row(
                      children: [
                        ShadButton.ghost(
                          onPressed: () => dispatch(
                            ReaderBookmarkNavigated(
                              bookmark.unit.toInt(),
                              offset: bookmark.offset?.toInt(),
                            ),
                          ),
                          child: Text(
                            bookmark.note?.isNotEmpty == true
                                ? '${bookmark.unit.toInt() + 1}: ${bookmark.note}'
                                : '${bookmark.unit.toInt() + 1}',
                          ),
                        ),
                        _BookmarkActionsMenu(
                          enabled: !model.bookmarkBusy,
                          onEdit: () =>
                              dispatch(ReaderBookmarkNoteRequested(bookmark)),
                          onDelete: () =>
                              dispatch(ReaderBookmarkDeleted(bookmark.id)),
                        ),
                      ],
                    );
                  },
                ),
              ),
            if (model.toolError case final error?)
              Semantics(
                liveRegion: true,
                child: Text(
                  error,
                  style: TextStyle(
                    color: ShadTheme.of(context).colorScheme.destructive,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ReaderToolError extends StatelessWidget {
  const _ReaderToolError({required this.model});

  final ReaderModel model;

  @override
  Widget build(BuildContext context) {
    final error = model.persistenceError;
    if (error == null) return const SizedBox.shrink();
    return SingleChildScrollView(
      child: Semantics(
        liveRegion: true,
        child: Text(
          error,
          key: const ValueKey('reader-tool-error'),
          style: TextStyle(
            color: ShadTheme.of(context).colorScheme.destructive,
          ),
        ),
      ),
    );
  }
}

class _BookmarkActionsMenu extends StatefulWidget {
  const _BookmarkActionsMenu({
    required this.enabled,
    required this.onEdit,
    required this.onDelete,
  });

  final bool enabled;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  State<_BookmarkActionsMenu> createState() => _BookmarkActionsMenuState();
}

class _BookmarkActionsMenuState extends State<_BookmarkActionsMenu> {
  final ShadPopoverController _controller = ShadPopoverController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ShadPopover(
    controller: _controller,
    popover: (context) => Padding(
      padding: const EdgeInsets.all(4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ShadButton.ghost(
            width: double.infinity,
            mainAxisAlignment: MainAxisAlignment.start,
            onPressed: widget.enabled
                ? () {
                    _controller.hide();
                    widget.onEdit();
                  }
                : null,
            child: const Text('Edit note'),
          ),
          ShadButton.ghost(
            width: double.infinity,
            mainAxisAlignment: MainAxisAlignment.start,
            onPressed: widget.enabled
                ? () {
                    _controller.hide();
                    widget.onDelete();
                  }
                : null,
            child: const Text('Delete'),
          ),
        ],
      ),
    ),
    child: ShadIconAction(
      tooltip: 'Bookmark actions',
      onPressed: widget.enabled ? _controller.toggle : null,
      icon: const Icon(LucideIcons.ellipsis),
    ),
  );
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
