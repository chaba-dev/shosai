part of 'view.dart';

class LibraryCollection extends StatelessWidget {
  const LibraryCollection({
    super.key,
    required this.model,
    required this.openBook,
    required this.removeBook,
    required this.loadMore,
    required this.loadCover,
  });

  final LibraryModel model;
  final ValueChanged<FlutterLibraryBook> openBook;
  final ValueChanged<FlutterLibraryBook> removeBook;
  final VoidCallback loadMore;
  final bool Function(int) loadCover;

  @override
  Widget build(BuildContext context) {
    if (!model.loaded && model.busy) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!model.loaded && model.loadError != null) {
      return const Center(child: Text('The library could not be loaded.'));
    }
    if (model.books.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            model.query.isEmpty && model.format == null
                ? 'Your library is empty. Add a PDF, EPUB, or CBZ to begin.'
                : 'No books match these filters.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final textScale = MediaQuery.textScalerOf(context).scale(1);
        final needsExpandedCard = textScale > 1;
        final columns = constraints.maxWidth >= 1100
            ? 5
            : constraints.maxWidth >= 760
            ? 3
            : 1;
        return GridView.builder(
          // The 96 px bottom inset belonged to the floating add-books button
          // that package 3A replaced with the header action.
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 22),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            childAspectRatio: 1.35,
            mainAxisExtent: needsExpandedCard
                ? 180 + (textScale - 1) * (columns == 1 ? 100 : 140)
                : (columns == 1 ? 180 : null),
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
          ),
          itemCount: model.books.length + (model.hasMore ? 1 : 0),
          itemBuilder: (context, index) {
            if (index == model.books.length) {
              return ShadCard(
                padding: const EdgeInsets.all(8),
                child: Center(
                  child: ShadButton.outline(
                    height: shosaiShadButtonHeight(context),
                    width: double.infinity,
                    onPressed: model.busy ? null : loadMore,
                    trailing: const Icon(LucideIcons.chevronDown),
                    child: const Flexible(
                      child: Text(
                        'Load more books',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ),
              );
            }
            final book = model.books[index];
            final titleStyle = Theme.of(context).textTheme.titleMedium;
            final bodyStyle = DefaultTextStyle.of(context).style;
            return ShadCard(
              padding: const EdgeInsets.all(14),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => openBook(book),
                child: LayoutBuilder(
                  builder: (context, cardConstraints) => Row(
                    children: [
                      if (cardConstraints.maxWidth >= 150) ...[
                        _BookCover(
                          book: book,
                          cover: model.covers[book.bookId],
                          demandRevision: model.coverRevision,
                          loadCover: loadCover,
                        ),
                        const SizedBox(width: 14),
                      ],
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              book.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: titleStyle == null
                                  ? null
                                  : shosaiInterfaceStyleForText(
                                      titleStyle,
                                      book.title,
                                    ),
                            ),
                            if (book.author case final author?)
                              Text(
                                author,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: shosaiInterfaceStyleForText(
                                  bodyStyle,
                                  author,
                                ),
                              ),
                            const SizedBox(height: 8),
                            ShadProgress(value: book.progress, minHeight: 8),
                            Text(
                              book.lastRead == null
                                  ? '${(book.progress * 100).round()}% read'
                                  : 'Continue reading · ${(book.progress * 100).round()}%',
                              // The card's tile extent is fixed, so every text
                              // in it needs a line bound: the title and author
                              // already have one, and an unbounded progress
                              // label can overflow the tile at 200% text.
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      _BookActionsMenu(
                        managed: book.managed,
                        onRemove: () => removeBook(book),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _BookActionsMenu extends StatefulWidget {
  const _BookActionsMenu({required this.managed, required this.onRemove});

  final bool managed;
  final VoidCallback onRemove;

  @override
  State<_BookActionsMenu> createState() => _BookActionsMenuState();
}

class _BookActionsMenuState extends State<_BookActionsMenu> {
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
      child: ShadButton.ghost(
        height: shosaiShadButtonHeight(context),
        width: double.infinity,
        mainAxisAlignment: MainAxisAlignment.start,
        onPressed: () {
          _controller.hide();
          widget.onRemove();
        },
        child: Text(
          widget.managed ? 'Remove and delete copy' : 'Remove from library',
        ),
      ),
    ),
    child: ShadIconAction(
      tooltip: 'Book actions',
      icon: const Icon(LucideIcons.ellipsis),
      onPressed: _controller.toggle,
    ),
  );
}

class _BookCover extends StatefulWidget {
  const _BookCover({
    required this.book,
    required this.cover,
    required this.demandRevision,
    required this.loadCover,
  });

  final FlutterLibraryBook book;
  final Uint8List? cover;
  final int demandRevision;
  final bool Function(int) loadCover;

  @override
  State<_BookCover> createState() => _BookCoverState();
}

class _BookCoverState extends State<_BookCover> {
  late bool _requested;

  @override
  void initState() {
    super.initState();
    _requested = widget.cover != null;
  }

  @override
  void didUpdateWidget(_BookCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.book.bookId != widget.book.bookId ||
        oldWidget.demandRevision != widget.demandRevision) {
      _requested = widget.cover != null;
    } else if (widget.cover != null) {
      _requested = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    final fallback = Icon(_formatIcon(widget.book.format), size: 42);
    final bytes = widget.cover;
    if (bytes == null && !_requested) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.loadCover(widget.book.bookId)) {
          setState(() => _requested = true);
        }
      });
    }
    if (bytes == null) {
      return fallback;
    }
    if (bytes.isEmpty) return fallback;
    return Semantics(
      container: true,
      image: true,
      label: 'Cover of ${widget.book.title}',
      child: SizedBox(
        width: 56,
        height: 80,
        child: Image.memory(
          bytes,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => Center(child: fallback),
        ),
      ),
    );
  }
}

IconData _formatIcon(FlutterBookFormat format) => switch (format) {
  FlutterBookFormat.pdf => Icons.picture_as_pdf_outlined,
  FlutterBookFormat.epub => Icons.menu_book_outlined,
  FlutterBookFormat.cbz => Icons.collections_bookmark_outlined,
};
