part of 'view.dart';

// The library as a shelf (`docs/design-system.md`, Library): the Continue
// reading hero, then the covers in a grid.
//
// | Layout | Columns | Gaps (column × row) | Hero |
// | --- | --- | --- | --- |
// | Phone | 3 | 14 × 20 | None: Reading now cards above |
// | Tablet | at least 118 px | 22 × 22 | 124 px cover; 72 px when narrow |
// | Desktop | at least 118 px | 28 × 28 | 168 px cover |
//
// Covers are the book's own at 2:3, or a typographic cover (the shell's
// [ShellGeneratedCover]). A tile reserves the cover and the text it paints,
// measured from the styles it renders with, so a scaled English, Japanese or
// mixed title is never clipped.
//
// Every card renders immutable [LibraryModel] state and dispatches a typed
// message through the callbacks [LibraryCollection] receives; no widget owns an
// effect. A card asks for its cover when it is first built, so the grid's lazy
// building bounds the requests and the controller bounds how many are in flight
// (LB-15).

/// The shelf's narrowest column (`sh-shelf`).
const double libraryShelfMinColumn = 118;

/// The shelf's geometry for one layout and width: how many columns, how wide,
/// and the gaps between them.
final class LibraryShelf {
  const LibraryShelf._({
    required this.columns,
    required this.columnWidth,
    required this.columnGap,
    required this.rowGap,
    required this.layout,
    required this.openTag,
  });

  /// The shelf for [available] px of content width at [layout]: three
  /// columns on a phone, otherwise as many columns of at least
  /// [libraryShelfMinColumn] as fit (seven across at 1440 px, six on a
  /// tablet).
  ///
  /// [openTag] says a book on the shelf is open in Reading now, so every card
  /// keeps a line for the *Open* tag and the rows stay level.
  factory LibraryShelf.of(
    ShellLayout layout,
    double available, {
    bool openTag = false,
  }) {
    final columnGap = switch (layout) {
      ShellLayout.phone => 14.0,
      ShellLayout.tablet => 22.0,
      ShellLayout.desktop => 28.0,
    };
    final columns = libraryGridColumns(available, layout: layout);
    return LibraryShelf._(
      columns: columns,
      columnWidth: math.max(
        0,
        (available - columnGap * (columns - 1)) / columns,
      ),
      columnGap: columnGap,
      rowGap: layout == ShellLayout.phone ? 20 : columnGap,
      layout: layout,
      openTag: openTag,
    );
  }

  final int columns;
  final double columnWidth;
  final double columnGap;
  final double rowGap;
  final ShellLayout layout;

  /// Whether the cards keep a line for the *Open* tag.
  final bool openTag;

  bool get phone => layout == ShellLayout.phone;

  /// How the generated covers set their text at this shelf's size.
  ShellCoverType get coverType =>
      phone ? ShellCoverType.phoneShelf : ShellCoverType.shelf;

  SliverGridDelegate gridDelegate(BuildContext context) =>
      SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        crossAxisSpacing: columnGap,
        mainAxisSpacing: rowGap,
        mainAxisExtent: libraryCardTileExtent(context, this),
      );
}

/// The number of shelf columns for [availableWidth] px of content width.
int libraryGridColumns(
  double availableWidth, {
  ShellLayout layout = ShellLayout.desktop,
}) {
  if (layout == ShellLayout.phone) return 3;
  if (availableWidth <= 0) return 1;
  final gap = layout == ShellLayout.tablet ? 22.0 : 28.0;
  return math.max(
    1,
    ((availableWidth + gap) / (libraryShelfMinColumn + gap)).floor(),
  );
}

/// The gap between a card's cover, title and meta line.
const double _cardSpacing = 8;

/// The card's progress bar: 3 px, shown while a book is under way.
const double _cardProgressHeight = 3;

/// The height one shelf tile occupies: the 2:3 cover, the two-line title box,
/// the meta line and the progress bar, with the gaps between them.
///
/// The title and meta boxes are measured from the styles the card paints with
/// at the ambient text scale, so the tile grows with scaled text instead of
/// cutting it.
double libraryCardTileExtent(BuildContext context, LibraryShelf shelf) =>
    shelf.columnWidth * 3 / 2 +
    _cardSpacing * 3 +
    _cardTitleBox(context, shelf) +
    _cardMetadataBox(context, shelf) +
    _cardProgressHeight;

/// The title box: two lines of the card's editorial title, the second
/// keeping the face's own descent ([_cardTitleHeightBehavior]).
double _cardTitleBox(BuildContext context, LibraryShelf shelf) => _textHeight(
  context,
  _cardTitleStyle(shelf),
  lines: 2,
  textHeightBehavior: _cardTitleHeightBehavior,
);

/// Whether the card's meta line wraps into a second run: above 100% text a
/// format badge and a status no longer share a column's width.
bool _cardMetadataWraps(BuildContext context) =>
    MediaQuery.textScalerOf(context).scale(12) > 12;

/// The meta line's height.
///
/// At 100% text it is one run: the format badge beside the status, or the
/// removal-pending chip, whichever is taller. Above it the line wraps: the
/// badge on a run of its own, then the status or the chip, each allowed a
/// second line so a scaled `Not started` in a phone's column is wrapped rather
/// than cut. A shelf with an open book adds a run for the *Open* tag, which
/// wraps onto it where it does not fit after the status.
double _cardMetadataBox(BuildContext context, LibraryShelf shelf) {
  final tag = shelf.openTag
      ? _cardMetadataRunSpacing + _lineHeight(context, _cardOpenTagStyle)
      : 0.0;
  return _cardMetadataRuns(context) + tag;
}

/// The badge and status runs of the meta line.
double _cardMetadataRuns(BuildContext context) {
  final status = _lineHeight(context, _cardMetaStyle(context));
  final badge =
      _lineHeight(context, shellInterfaceStyle(10, 12)) +
      _cardBadgePaddingVertical * 2;
  final chipChrome =
      (ShosaiTokens.layoutLibraryCardRemovePaddingVertical +
          ShosaiTokens.layoutLibraryCardBorderWidth) *
      2;
  if (!_cardMetadataWraps(context)) {
    return math.max(math.max(status, badge), status + chipChrome);
  }
  final lines = _cardMetadataWrappedLines;
  return badge +
      _cardMetadataRunSpacing +
      math.max(status * lines, status * lines + chipChrome);
}

/// The *Open* tag: `ui-label` weight in `accent`.
final TextStyle _cardOpenTagStyle = shellInterfaceStyle(
  11,
  14,
  weight: FontWeight.w600,
);

/// How many lines a wrapped meta line gives the status or the chip.
const int _cardMetadataWrappedLines = 2;

const double _cardBadgePaddingVertical = 3;
const double _cardMetadataRunSpacing = 4;

/// The height one line of [style] paints at the ambient text scale.
double _lineHeight(BuildContext context, TextStyle style) =>
    _textHeight(context, style);

/// The height [lines] lines of [style] paint at the ambient text scale.
///
/// Measured with a Japanese glyph as well as a Latin one, because a card's
/// title and status can each be Japanese and the tile has to fit the taller.
double _textHeight(
  BuildContext context,
  TextStyle style, {
  int lines = 1,
  TextHeightBehavior? textHeightBehavior,
}) {
  final painter = TextPainter(
    text: TextSpan(text: List.filled(lines, 'Mあ').join('\n'), style: style),
    textScaler: MediaQuery.textScalerOf(context),
    textDirection: TextDirection.ltr,
    textHeightBehavior: textHeightBehavior,
  )..layout();
  final height = painter.height;
  painter.dispose();
  return height;
}

/// The card title: `ed-title`, 14/18 on the shelf and 13/17 on a phone's.
TextStyle _cardTitleStyle(LibraryShelf shelf) =>
    shelf.phone ? shellEditorialStyle(13, 17) : shellEditorialStyle(14, 18);

/// The card title's last line keeps the face's own descent.
///
/// `ed-title` leading is tighter than Literata's ascent and descent, so a
/// descender on the last line reaches past the paragraph, and an ellipsized
/// title clips it to its box: on macOS the cut is a visible pixel row.
const _cardTitleHeightBehavior = TextHeightBehavior(
  applyHeightToLastDescent: false,
);

/// The card's meta line: `ui-caption` in `ink-muted`, with tabular figures so
/// percentages line up across the shelf.
TextStyle _cardMetaStyle(BuildContext context) =>
    shellInterfaceStyle(12, 16).copyWith(
      color: ShellPalette.of(context).inkMuted,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

/// A heading of the empty states, at [style]'s size and the interface's
/// regular weight.
TextStyle _libraryHeadingStyle(BuildContext context, TextStyle style) =>
    style.copyWith(
      fontWeight: FontWeight.w400,
      color: ShadTheme.of(context).colorScheme.foreground,
    );

/// An interface label at [size] in the theme's muted foreground color.
TextStyle _libraryMutedStyle(BuildContext context, double size) =>
    (Theme.of(context).textTheme.bodySmall ?? const TextStyle()).copyWith(
      fontSize: size,
      color: ShadTheme.of(context).colorScheme.mutedForeground,
    );

/// The placeholder cards shown while an empty library loads.
const int _libraryFirstLoadSkeletonCount = 8;

/// The window class the collection lays out for.
ShellLayout _layoutOf(BuildContext context) =>
    ShellLayout.forWidth(MediaQuery.sizeOf(context).width);

/// The library's margins (`mk-lib` in the mock): wider on a desktop, where
/// the shelf has room to breathe.
EdgeInsets _collectionPadding(ShellLayout layout) => switch (layout) {
  ShellLayout.phone => const EdgeInsets.all(16),
  ShellLayout.tablet => const EdgeInsets.fromLTRB(32, 24, 32, 32),
  ShellLayout.desktop => const EdgeInsets.fromLTRB(48, 28, 48, 40),
};

/// The space between the hero, the section head and the shelf.
double _sectionSpacing(ShellLayout layout) => switch (layout) {
  ShellLayout.phone => 16,
  ShellLayout.tablet => 18,
  ShellLayout.desktop => 22,
};

/// The library collection: the hero, the section head and the shelf.
///
/// Page-one loading shows a skeleton shelf, and an empty result shows its
/// empty-library or no-matches composition; each is a distinct state, never a
/// restyled grid.
class LibraryCollection extends StatelessWidget {
  const LibraryCollection({
    super.key,
    required this.model,
    this.openBookIds = const {},
    this.sortBooks,
    required this.openBook,
    this.openSourceFile,
    required this.openNotes,
    required this.removeBook,
    this.keepBook,
    required this.loadMore,
    required this.retryPaging,
    required this.loadCover,
    required this.retry,
    required this.addFirstBooks,
    required this.cancelImport,
  });

  final LibraryModel model;

  /// The books open in Reading now; their cards carry the *Open* tag.
  final Set<int> openBookIds;

  /// The section head's sort control; null leaves it out.
  final ValueChanged<FlutterLibrarySort>? sortBooks;
  final ValueChanged<FlutterLibraryBook> openBook;
  final ValueChanged<LibrarySourceFile>? openSourceFile;

  /// The hero's Notes action: the Notes place.
  final VoidCallback openNotes;
  final ValueChanged<FlutterLibraryBook> removeBook;
  final ValueChanged<FlutterLibraryBook>? keepBook;
  final VoidCallback loadMore;

  /// The paging row's recovery: retry the page an appended load failed to add.
  ///
  /// It is separate from [retry] because the alert above the grid recovers a
  /// mutation or a collection-level load, and the paging row recovers only its
  /// own page.
  final VoidCallback retryPaging;
  final bool Function(int) loadCover;

  /// The failure alert's recovery action.
  final VoidCallback retry;

  /// The empty-library composition's action.
  final VoidCallback addFirstBooks;

  /// The empty-library composition's action while the add-books import is the
  /// foreground operation.
  final VoidCallback cancelImport;

  @override
  Widget build(BuildContext context) => switch (model.collectionState) {
    LibraryCollectionState.loading => LibrarySkeletonGrid(
      model: model,
      sortBooks: sortBooks,
      retry: retry,
    ),
    LibraryCollectionState.empty ||
    LibraryCollectionState.noMatches => _LibraryEmptyCollection(
      model: model,
      retry: retry,
      addFirstBooks: addFirstBooks,
      cancelImport: cancelImport,
    ),
    LibraryCollectionState.ready => _LibraryGrid(
      model: model,
      openBookIds: openBookIds,
      sortBooks: sortBooks,
      openBook: openBook,
      openSourceFile: openSourceFile,
      openNotes: openNotes,
      removeBook: removeBook,
      keepBook: keepBook,
      loadMore: loadMore,
      retryPaging: retryPaging,
      loadCover: loadCover,
      retry: retry,
    ),
  };
}

/// The section head above the shelf (`sh-section`): *All books*, or *Search
/// results* while a search is active, in `ed-section` with a `line` rule
/// running to the sort control at the right edge.
///
/// A filter alone keeps *All books*, because only a query changes what the
/// shelf is a list of. Where the head and the sort control do not share the
/// width, as on a phone, the sort control takes the line below, at the right.
///
/// The design system places the sort control at the right of the title row;
/// that row still carries the library search and Add books here, so the sort
/// sits with the shelf it orders and scrolls with it.
class _CollectionSectionTitle extends StatelessWidget {
  const _CollectionSectionTitle({
    required this.model,
    required this.layout,
    required this.sortBooks,
  });

  final LibraryModel model;
  final ShellLayout layout;
  final ValueChanged<FlutterLibrarySort>? sortBooks;

  /// The narrowest the rule between the head and the sort control gets.
  static const double _minRule = 24;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final palette = ShellPalette.of(context);
    final label = model.query.isEmpty
        ? l10n.filterAllBooks
        : l10n.librarySearchResults;
    final style = shellEditorialStyle(22, 26).copyWith(color: palette.ink);
    final sortBooks = this.sortBooks;
    final segments = <ShellSegment<FlutterLibrarySort>>[
      (value: FlutterLibrarySort.recent, label: l10n.librarySortRecent),
      (value: FlutterLibrarySort.title, label: l10n.librarySortTitle),
      (value: FlutterLibrarySort.author, label: l10n.librarySortAuthor),
    ];
    return LayoutBuilder(
      // The head takes the width it needs and the rule the rest; a scaled
      // head that needs the whole line wraps and leaves the rule a stub.
      builder: (context, constraints) {
        Widget head({double reserved = 0}) => Semantics(
          header: true,
          child: Row(
            spacing: 12,
            children: [
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: math.max(
                    0,
                    constraints.maxWidth - reserved - 12 - _minRule,
                  ),
                ),
                child: Text(label, style: style),
              ),
              Expanded(child: Container(height: 1, color: palette.line)),
            ],
          ),
        );
        if (sortBooks == null) return head();
        final sort = ShellSegmentedControl<FlutterLibrarySort>(
          label: l10n.librarySortLabel,
          touch: layout.touch,
          segments: segments,
          selected: model.sort,
          onSelected: sortBooks,
        );
        final sortWidth = ShellSegmentedControl.widthOf(
          context,
          segments.map((segment) => segment.label),
        );
        final fits =
            _textWidth(context, label, style) +
                12 +
                _minRule +
                12 +
                sortWidth <=
            constraints.maxWidth;
        if (fits) {
          return Row(
            spacing: 12,
            children: [
              Expanded(child: head(reserved: sortWidth + 12)),
              sort,
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 12,
          children: [
            head(),
            Align(alignment: AlignmentDirectional.centerEnd, child: sort),
          ],
        );
      },
    );
  }
}

/// The width one line of [text] paints in [style] at the ambient text scale.
double _textWidth(BuildContext context, String text, TextStyle style) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textScaler: MediaQuery.textScalerOf(context),
    textDirection: TextDirection.ltr,
  )..layout();
  final width = painter.width;
  painter.dispose();
  return width;
}

/// The reference's failure alert: the 13 px danger text on the alert
/// background, with the retained Flutter retry action.
///
/// The reference draws the alert bar without an action; the retry is the
/// retained recovery path for the same failure, so it keeps the shared control
/// height instead of shrinking to the bar.
class _CollectionAlert extends StatelessWidget {
  const _CollectionAlert({required this.message, required this.retry});

  final String message;
  final VoidCallback retry;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final dark = theme.brightness == Brightness.dark;
    // The reference's alert is a pinned light-theme surface; the dark theme
    // keeps its own raised surface and light danger foreground instead, so the
    // bar cannot paint a light band under the dark foreground.
    final background = dark
        ? theme.colorScheme.muted
        : ShosaiTokens.appAlertBackground;
    final foreground = dark
        ? theme.colorScheme.destructive
        : ShosaiTokens.appDanger;
    return Container(
      padding: const EdgeInsets.symmetric(
        vertical: ShosaiTokens.layoutLibraryAlertPaddingVertical,
        horizontal: ShosaiTokens.layoutLibraryAlertPaddingHorizontal,
      ),
      color: background,
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              liveRegion: true,
              child: Text(
                message,
                style:
                    (Theme.of(context).textTheme.bodyMedium ??
                            const TextStyle())
                        .copyWith(
                          fontSize: ShosaiTokens.typeSize13,
                          color: foreground,
                        ),
              ),
            ),
          ),
          ShadButton.ghost(
            height: shosaiShadButtonHeight(context),
            onPressed: retry,
            child: Text(AppLocalizations.of(context).libraryRetry),
          ),
        ],
      ),
    );
  }
}

/// The populated collection: the alert, the hero, the section head, the shelf
/// with its edge, and automatic paging with its feedback.
///
/// The ordinary "Load more books" control is gone: the collection asks for the
/// next page as the scroll approaches its end, and a page shorter than the
/// viewport asks for one after the frame instead of requiring an impossible
/// scroll. The trigger is presentation state this widget owns; the request it
/// dispatches is the same typed [LibraryMoreRequested] the button dispatched,
/// and the controller owns everything about it — admission, duplicate
/// suppression, exhaustion and stale completions — so the widget never awaits
/// anything and never writes model state.
class _LibraryGrid extends StatefulWidget {
  const _LibraryGrid({
    required this.model,
    required this.openBookIds,
    required this.sortBooks,
    required this.openBook,
    required this.openSourceFile,
    required this.openNotes,
    required this.removeBook,
    required this.keepBook,
    required this.loadMore,
    required this.retryPaging,
    required this.loadCover,
    required this.retry,
  });

  final LibraryModel model;
  final Set<int> openBookIds;
  final ValueChanged<FlutterLibrarySort>? sortBooks;
  final ValueChanged<FlutterLibraryBook> openBook;
  final ValueChanged<LibrarySourceFile>? openSourceFile;
  final VoidCallback openNotes;
  final ValueChanged<FlutterLibraryBook> removeBook;
  final ValueChanged<FlutterLibraryBook>? keepBook;
  final VoidCallback loadMore;
  final VoidCallback retryPaging;
  final bool Function(int) loadCover;
  final VoidCallback retry;

  @override
  State<_LibraryGrid> createState() => _LibraryGridState();
}

class _LibraryGridState extends State<_LibraryGrid> {
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_maybeRequestNextPage);
  }

  @override
  void dispose() {
    _scroll.removeListener(_maybeRequestNextPage);
    _scroll.dispose();
    super.dispose();
  }

  /// Whether another page may be asked for.
  ///
  /// Exhaustion stops the trigger, a load failure keeps its own recovery
  /// instead of looping, and a load in flight is never asked twice; the
  /// controller repeats the same checks on its side, because this predicate
  /// reads the model the widget was last built with. A mutation error (a
  /// partial import, say) is a different surface and does not stop paging.
  bool get _canRequestNextPage =>
      widget.model.hasMore &&
      !widget.model.loading &&
      widget.model.loadError == null &&
      widget.model.collectionState == LibraryCollectionState.ready;

  /// Dispatches the typed paging intent when the scroll is within
  /// [ShosaiTokens.layoutLibraryPagingTriggerDistance] of the collection's end.
  void _maybeRequestNextPage() {
    if (!mounted || !_canRequestNextPage || !_scroll.hasClients) return;
    final position = _scroll.position;
    final remaining = position.maxScrollExtent - position.pixels;
    if (remaining > ShosaiTokens.layoutLibraryPagingTriggerDistance) return;
    widget.loadMore();
  }

  @override
  Widget build(BuildContext context) {
    final continueBook = widget.model.continueBook;
    // A paging failure is recovered where it happened, at the paging row below
    // the grid, so the alert above the grid carries only collection-level
    // failures and mutation errors.
    final loadError = widget.model.loadError;
    final pagingFailure = loadError != null && widget.model.pagingFailed;
    final error = widget.model.error ?? (pagingFailure ? null : loadError);
    // A page shorter than the viewport has no end to scroll to, so the next
    // page is requested after the frame. Every request is bounded by
    // `_canRequestNextPage` and by the controller's own admission, so a short
    // library fills without looping.
    if (_canRequestNextPage) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _maybeRequestNextPage();
      });
    }
    final layout = _layoutOf(context);
    final padding = _collectionPadding(layout);
    final spacing = _sectionSpacing(layout);
    final loadingMore = widget.model.loadingMore;
    final items = <Object>[...widget.model.books, ...widget.model.sourceFiles];
    if (widget.model.sourceFiles.isNotEmpty &&
        widget.model.sort != FlutterLibrarySort.recent) {
      String title(Object item) => switch (item) {
        FlutterLibraryBook() => item.title,
        LibrarySourceFile() => item.title,
        _ => throw StateError('Unknown shelf item'),
      };
      String author(Object item) =>
          item is FlutterLibraryBook ? item.author ?? '' : '';
      items.sort((a, b) {
        if (widget.model.sort == FlutterLibrarySort.author) {
          if (author(a).isEmpty != author(b).isEmpty) {
            return author(a).isEmpty ? 1 : -1;
          }
          final order = author(
            a,
          ).toLowerCase().compareTo(author(b).toLowerCase());
          if (order != 0) return order;
        }
        return title(a).toLowerCase().compareTo(title(b).toLowerCase());
      });
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final shelf = LibraryShelf.of(
          layout,
          constraints.maxWidth - padding.horizontal,
          openTag: widget.model.books.any(
            (book) => widget.openBookIds.contains(book.bookId),
          ),
        );
        return CustomScrollView(
          controller: _scroll,
          slivers: [
            SliverPadding(
              padding: padding.copyWith(bottom: 0),
              sliver: SliverMainAxisGroup(
                slivers: [
                  if (error != null)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.only(bottom: spacing),
                        child: _CollectionAlert(
                          message: error,
                          retry: widget.retry,
                        ),
                      ),
                    ),
                  // Phones list the open books as Reading now cards above the
                  // collection instead of a hero.
                  if (continueBook != null && !shelf.phone)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.only(bottom: spacing),
                        child: LibraryContinueCard(
                          book: continueBook,
                          notes: widget.model.continueReadingNotes,
                          cover: widget.model.covers[continueBook.bookId],
                          demandRevision: widget.model.coverRevision,
                          layout: layout,
                          loadCover: widget.loadCover,
                          openBook: widget.openBook,
                          openNotes: widget.openNotes,
                        ),
                      ),
                    ),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.only(bottom: spacing),
                      child: _CollectionSectionTitle(
                        model: widget.model,
                        layout: layout,
                        sortBooks: widget.sortBooks,
                      ),
                    ),
                  ),
                  SliverGrid.builder(
                    gridDelegate: shelf.gridDelegate(context),
                    itemCount: items.length,
                    itemBuilder: (context, index) {
                      final item = items[index];
                      if (item is LibrarySourceFile) {
                        final file = item;
                        return _SourceFileCard(
                          file: file,
                          shelf: shelf,
                          onPressed: widget.model.busy
                              ? null
                              : () => widget.openSourceFile?.call(file),
                        );
                      }
                      final book = item as FlutterLibraryBook;
                      return LibraryBookCard(
                        book: book,
                        cover: widget.model.covers[book.bookId],
                        demandRevision: widget.model.coverRevision,
                        shelf: shelf,
                        open: widget.openBookIds.contains(book.bookId),
                        removing: widget.model.removingBookId == book.bookId,
                        loadCover: widget.loadCover,
                        openBook: widget.openBook,
                        removeBook: widget.removeBook,
                        keepBook: widget.model.busy ? null : widget.keepBook,
                      );
                    },
                  ),
                ],
              ),
            ),
            SliverPadding(
              padding: padding.copyWith(top: 0),
              sliver: SliverMainAxisGroup(
                slivers: [
                  if (pagingFailure && !loadingMore)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.only(top: shelf.rowGap),
                        child: _CollectionAlert(
                          message: loadError,
                          retry: widget.retryPaging,
                        ),
                      ),
                    ),
                  if (loadingMore)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.only(top: shelf.rowGap),
                        child: Center(
                          child: Semantics(
                            liveRegion: true,
                            child: Text(
                              AppLocalizations.of(context).libraryLoadingMore,
                              style: _libraryMutedStyle(
                                context,
                                ShosaiTokens.typeSize16,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The page-one loading composition: the section head above a shelf of
/// placeholder cards in the loaded shelf's geometry, so the swap to content
/// cannot move the shelf.
///
/// An unresolved failure keeps the collection's alert above the placeholders:
/// a failure stays visible until it is resolved, and a reload is not a
/// resolution.
class LibrarySkeletonGrid extends StatelessWidget {
  const LibrarySkeletonGrid({
    super.key,
    required this.model,
    this.sortBooks,
    required this.retry,
  });

  final LibraryModel model;

  /// The section head's sort control; null leaves it out.
  final ValueChanged<FlutterLibrarySort>? sortBooks;

  /// The failure alert's recovery action.
  final VoidCallback retry;

  /// Eight placeholders for an empty library, otherwise as many as the page
  /// being replaced held.
  int get _placeholderCount => model.books.isEmpty
      ? _libraryFirstLoadSkeletonCount
      : math.min(model.books.length, libraryPageSize);

  @override
  Widget build(BuildContext context) {
    final layout = _layoutOf(context);
    final padding = _collectionPadding(layout);
    final spacing = _sectionSpacing(layout);
    return LayoutBuilder(
      builder: (context, constraints) {
        final shelf = LibraryShelf.of(
          layout,
          constraints.maxWidth - padding.horizontal,
        );
        return CustomScrollView(
          slivers: [
            SliverPadding(
              padding: padding,
              sliver: SliverMainAxisGroup(
                slivers: [
                  if (model.displayError case final error?)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.only(bottom: spacing),
                        child: _CollectionAlert(message: error, retry: retry),
                      ),
                    ),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.only(bottom: spacing),
                      child: _CollectionSectionTitle(
                        model: model,
                        layout: layout,
                        sortBooks: sortBooks,
                      ),
                    ),
                  ),
                  SliverGrid.builder(
                    gridDelegate: shelf.gridDelegate(context),
                    itemCount: _placeholderCount,
                    itemBuilder: (context, index) =>
                        const LibrarySkeletonCard(),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// A placeholder card: the 2:3 cover block and the title and meta bars, in
/// the loaded card's spacing.
class LibrarySkeletonCard extends StatelessWidget {
  const LibrarySkeletonCard({super.key});

  @override
  Widget build(BuildContext context) {
    final palette = ShellPalette.of(context);
    Widget bar(double widthFactor, double height) => FractionallySizedBox(
      alignment: AlignmentDirectional.centerStart,
      widthFactor: widthFactor,
      child: Container(
        height: height,
        decoration: BoxDecoration(
          color: palette.surfaceSunken,
          borderRadius: BorderRadius.circular(ShosaiTokens.radiusXs),
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: _cardSpacing,
      children: [
        AspectRatio(
          aspectRatio: 2 / 3,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: palette.surfaceSunken,
              borderRadius: BorderRadius.circular(ShellGeneratedCover.radius),
            ),
          ),
        ),
        bar(.85, 12),
        bar(.5, 9),
      ],
    );
  }
}

/// The reference's empty-library and no-matches compositions.
///
/// Both are a centred column: a 24 px heading, a 14 px muted body, and the
/// empty-library action. A failure replaces the body with its own text,
/// suppresses the add action — offering to add books while the library failed
/// to load would misstate the state — and shows the retained Retry instead, so
/// every collection shape keeps a recovery path.
class _LibraryEmptyCollection extends StatelessWidget {
  const _LibraryEmptyCollection({
    required this.model,
    required this.retry,
    required this.addFirstBooks,
    required this.cancelImport,
  });

  final LibraryModel model;

  /// The failure's retained recovery action: an empty composition is still a
  /// failure surface, so it keeps the same retry the alert offers.
  final VoidCallback retry;

  final VoidCallback addFirstBooks;
  final VoidCallback cancelImport;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = ShadTheme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final empty = model.collectionState == LibraryCollectionState.empty;
    final heading = empty
        ? l10n.libraryEmptyHeading
        : l10n.libraryNoMatchesHeading;
    final body =
        model.displayError ??
        (empty ? l10n.libraryEmptyBody : l10n.libraryNoMatchesBody);
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          // The composition is centred while it fits and scrolls once a scaled
          // heading, body and action no longer do, instead of overflowing the
          // collection area.
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Center(
            child: Padding(
              padding: _collectionPadding(_layoutOf(context)),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                spacing: ShosaiTokens.layoutLibraryEmptyStateSpacing,
                children: [
                  Text(
                    heading,
                    textAlign: TextAlign.center,
                    style: shosaiInterfaceStyleForText(
                      _libraryHeadingStyle(context, theme.textTheme.h3),
                      heading,
                    ),
                  ),
                  Text(
                    body,
                    textAlign: TextAlign.center,
                    style: shosaiInterfaceStyleForText(
                      // The reference's muted body colour, not the package's
                      // own muted role.
                      theme.textTheme.muted.copyWith(
                        color: scheme.mutedForeground,
                      ),
                      body,
                    ),
                  ),
                  if (model.displayError != null)
                    ShadButton.ghost(
                      height: shosaiShadButtonHeight(context),
                      onPressed: retry,
                      child: Text(l10n.libraryRetry),
                    ),
                  if (empty && model.displayError == null)
                    ShadButton(
                      // The shared single-line control height would cut a
                      // scaled label, so the action is content-sized with a
                      // flexible label that wraps: the reference's own button
                      // grows with its text.
                      height: 0,
                      padding: const EdgeInsets.symmetric(
                        vertical:
                            ShosaiTokens.layoutButtonPrimaryPaddingVertical,
                        horizontal:
                            ShosaiTokens.layoutButtonPrimaryPaddingHorizontal,
                      ),
                      // The primary button has an opaque hovered fill, the
                      // design system's accent-hover; the Shad primary
                      // variant's is translucent (the header's add-books
                      // action does the same).
                      hoverBackgroundColor: dark
                          ? ShosaiTokens.appDarkPrimaryHovered
                          : ShosaiTokens.appAccentHovered,
                      pressedBackgroundColor: dark
                          ? ShosaiTokens.appDarkPrimaryHovered
                          : ShosaiTokens.appAccentHovered,
                      onPressed: model.importing ? cancelImport : addFirstBooks,
                      leading: model.importing
                          ? null
                          : const Icon(LucideIcons.plus),
                      child: Flexible(
                        child: Text(
                          model.importing
                              ? l10n.cancelImportAction
                              : l10n.libraryAddFirstBooks,
                          textAlign: TextAlign.center,
                        ),
                      ),
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

/// The Continue reading hero (`sh-hero`): the book last opened for reading, on
/// the one lifted card of the library canvas.
///
/// The cover, the kicker, the title in `ed-screen`, the author and format, the
/// book's latest highlight or note quoted in the editorial face, the place
/// over a progress bar at most 480 px wide, then **Continue** beside **Notes**
/// with its count. A book with nothing to quote shows no quote, never a
/// placeholder, and the count hides at zero. A hero narrower than
/// [compactWidth] takes the compact form: a 72 px cover, an 18 px title and
/// no quote.
///
/// Continue dispatches [LibraryBookOpened] with the book the hero was built
/// with, so the book and its saved position are the ones it showed even if a
/// reload lands while the open effect runs.
class LibraryContinueCard extends StatelessWidget {
  const LibraryContinueCard({
    super.key,
    required this.book,
    this.notes,
    required this.cover,
    required this.demandRevision,
    required this.layout,
    required this.loadCover,
    required this.openBook,
    required this.openNotes,
  });

  static const double compactWidth = 560;
  static const double placeMaxWidth = 480;

  /// The quote's longest run of lines before it ends in an ellipsis.
  static const int quoteMaxLines = 3;

  /// The quote's measure: 52 em at 18 px.
  static const double quoteMaxWidth = 52 * 18;

  final FlutterLibraryBook book;

  /// [book]'s notes: the quote and the Notes count; null while unknown.
  final FlutterNotesSummary? notes;
  final Uint8List? cover;
  final int demandRevision;
  final ShellLayout layout;
  final bool Function(int) loadCover;
  final ValueChanged<FlutterLibraryBook> openBook;
  final VoidCallback openNotes;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final compact = constraints.maxWidth < compactWidth;
      final tablet = layout != ShellLayout.desktop;
      final palette = ShellPalette.of(context);
      final l10n = AppLocalizations.of(context);
      // Touch layouts take the 20 px touch icon, padded to `touch-target`.
      final (buttonPadding, iconSize) = layout.touch
          ? (_heroTouchButtonPadding, 20.0)
          : (_heroButtonPadding, 16.0);
      final (coverWidth, coverType) = compact
          ? (72.0, ShellCoverType.heroCompact)
          : tablet
          ? (124.0, ShellCoverType.heroTablet)
          : (168.0, ShellCoverType.hero);
      final titleStyle = compact
          ? shellEditorialStyle(18, 23)
          : tablet
          ? shellEditorialStyle(28, 34)
          : shellEditorialStyle(34, 40).copyWith(letterSpacing: -.34);
      // The hero's book is under way (below 1.0), so it never rounds to 100%;
      // a started book never rounds to 0% either.
      final percentage = (book.progress.clamp(0.0, 1.0) * 100).round().clamp(
        book.progress > 0 ? 1 : 0,
        99,
      );
      final place = l10n.libraryPercentComplete(percentage);
      final author = book.author ?? l10n.cardUnknownAuthor;
      final metaStyle = shellInterfaceStyle(
        13,
        18,
      ).copyWith(color: palette.inkMuted);
      final dark = palette.dark;
      final quote = compact ? null : notes?.latest;
      final noteCount = notes?.count ?? 0;
      final body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: compact ? 6 : 10,
        children: [
          _Kicker(label: l10n.libraryContinueReading),
          Text(
            book.title,
            maxLines: compact ? 2 : 3,
            overflow: TextOverflow.ellipsis,
            style: titleStyle.copyWith(color: palette.ink),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                author,
                style: shosaiInterfaceStyleForText(metaStyle, author),
              ),
              ShellFormatBadge(format: book.format),
            ],
          ),
          if (quote != null)
            Container(
              padding: const EdgeInsets.only(top: 4),
              constraints: const BoxConstraints(maxWidth: quoteMaxWidth),
              child: Text(
                '“$quote”',
                maxLines: quoteMaxLines,
                overflow: TextOverflow.ellipsis,
                style: shellEditorialStyle(
                  18,
                  27,
                  weight: FontWeight.w400,
                ).copyWith(color: palette.ink),
              ),
            ),
          Padding(
            padding: EdgeInsets.only(top: compact ? 0 : 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 8,
              children: [
                Text(
                  place,
                  style: shosaiInterfaceStyleForText(
                    metaStyle.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                    place,
                  ),
                ),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: placeMaxWidth),
                  child: ShellProgressBar(value: book.progress, height: 4),
                ),
              ],
            ),
          ),
          Padding(
            padding: EdgeInsets.only(top: compact ? 2 : 6),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ShadButton(
                  height: 0,
                  padding: buttonPadding,
                  // The primary button has an opaque hovered fill, the design
                  // system's accent-hover; the Shad primary variant's is
                  // translucent.
                  hoverBackgroundColor: dark
                      ? ShosaiTokens.appDarkPrimaryHovered
                      : ShosaiTokens.appAccentHovered,
                  pressedBackgroundColor: dark
                      ? ShosaiTokens.appDarkPrimaryHovered
                      : ShosaiTokens.appAccentHovered,
                  onPressed: () => openBook(book),
                  leading: Icon(LucideIcons.arrowRight, size: iconSize),
                  child: Text(l10n.libraryContinue),
                ),
                ShadButton.outline(
                  height: 0,
                  padding: buttonPadding,
                  backgroundColor: palette.surface,
                  onPressed: openNotes,
                  leading: Icon(LucideIcons.messageSquareText, size: iconSize),
                  trailing: noteCount > 0 ? ShellCount(count: noteCount) : null,
                  child: Text(l10n.shellPlaceNotes),
                ),
              ],
            ),
          ),
        ],
      );
      return DecoratedBox(
        decoration: BoxDecoration(
          color: palette.surface,
          borderRadius: BorderRadius.circular(
            compact ? ShosaiTokens.radiusMd : ShosaiTokens.radiusLg,
          ),
          boxShadow: compact ? palette.raised : palette.hero,
        ),
        child: Padding(
          padding: compact
              ? const EdgeInsets.all(16)
              : tablet
              ? const EdgeInsets.symmetric(horizontal: 22, vertical: 20)
              : const EdgeInsets.fromLTRB(26, 26, 28, 26),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: compact
                ? 16
                : tablet
                ? 24
                : 32,
            children: [
              LibraryBookCover(
                book: book,
                cover: cover,
                demandRevision: demandRevision,
                loadCover: loadCover,
                type: coverType,
                shadow: palette.heroCoverShadow,
                width: coverWidth,
              ),
              Expanded(child: body),
            ],
          ),
        ),
      );
    },
  );
}

/// The hero's buttons are content-sized, so a scaled label grows the button
/// instead of being cut; at 100% text they are the 32 px control height.
const EdgeInsets _heroButtonPadding = EdgeInsets.symmetric(
  horizontal: 12,
  vertical: 7,
);

/// On touch layouts the same buttons are at least `touch-target` (44 px)
/// tall: 12 px above and below the 20 px icon.
const EdgeInsets _heroTouchButtonPadding = EdgeInsets.symmetric(
  horizontal: 14,
  vertical: (ShosaiTokens.sizeTouchTarget - 20) / 2,
);

/// A kicker (`sh-kicker`): `ui-label` small capitals over a title. Japanese
/// has no capitals to set, so it reads in `ui-caption` without the tracking.
class _Kicker extends StatelessWidget {
  const _Kicker({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final palette = ShellPalette.of(context);
    final japanese = Localizations.localeOf(context).languageCode == 'ja';
    return Text(
      japanese ? label : label.toUpperCase(),
      style: shosaiInterfaceStyleForText(
        japanese
            ? shellInterfaceStyle(12, 16, weight: FontWeight.w600)
            : shellInterfaceStyle(
                11,
                14,
                weight: FontWeight.w600,
              ).copyWith(letterSpacing: .88),
        label,
      ).copyWith(color: palette.inkMuted),
    );
  }
}

/// Unopened source metadata uses a generated cover until first admission.
class _SourceFileCard extends StatelessWidget {
  const _SourceFileCard({
    required this.file,
    required this.shelf,
    required this.onPressed,
  });
  final LibrarySourceFile file;
  final LibraryShelf shelf;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => ShadButton.raw(
    variant: ShadButtonVariant.ghost,
    width: double.infinity,
    height: double.infinity,
    padding: EdgeInsets.zero,
    backgroundColor: _triggerNoFill,
    hoverBackgroundColor: _triggerNoFill,
    pressedBackgroundColor: _triggerNoFill,
    foregroundColor: ShellPalette.of(context).ink,
    onPressed: onPressed,
    child: Flexible(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: shelf.columnWidth * 1.5,
            child: ShellGeneratedCover(
              title: file.title,
              author: null,
              type: shelf.coverType,
            ),
          ),
          const SizedBox(height: _cardSpacing),
          SizedBox(
            height: _cardTitleBox(context, shelf),
            child: Text(
              file.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.start,
              style: _cardTitleStyle(shelf),
            ),
          ),
          const SizedBox(height: _cardSpacing),
          Row(
            spacing: 6,
            children: [
              ShellFormatBadge(
                format: FlutterBookFormat.values.byName(
                  file.entry.name.split('.').last.toLowerCase(),
                ),
              ),
              Flexible(
                child: Text(
                  file.failure == null
                      ? file.source
                      : AppLocalizations.of(context).libraryBookUnavailable,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _cardMetaStyle(context),
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

/// One identified book on the shelf, with its cover, format, reading state
/// and actions. Discovery-only files never receive record-only actions.
class LibraryBookCard extends StatelessWidget {
  const LibraryBookCard({
    super.key,
    required this.book,
    required this.cover,
    required this.demandRevision,
    required this.shelf,
    this.open = false,
    required this.removing,
    required this.loadCover,
    required this.openBook,
    required this.removeBook,
    this.keepBook,
  });

  final FlutterLibraryBook book;
  final Uint8List? cover;
  final int demandRevision;
  final LibraryShelf shelf;

  /// Whether the book is open in Reading now: the meta line ends on the
  /// *Open* tag, and opening the card switches to it.
  final bool open;

  /// Whether this card's removal is in flight: the action is hidden, opening
  /// is disabled and the meta line says so.
  final bool removing;

  final bool Function(int) loadCover;
  final ValueChanged<FlutterLibraryBook> openBook;
  final ValueChanged<FlutterLibraryBook> removeBook;
  final ValueChanged<FlutterLibraryBook>? keepBook;

  @override
  Widget build(BuildContext context) {
    final palette = ShellPalette.of(context);
    final l10n = AppLocalizations.of(context);
    final metaStyle = _cardMetaStyle(context);
    final status = book.unavailable
        ? l10n.libraryBookUnavailable
        : shellReadingStatus(l10n, book.progress);
    final wraps = _cardMetadataWraps(context);
    final statusLabel = removing
        ? Container(
            padding: const EdgeInsets.symmetric(
              vertical: ShosaiTokens.layoutLibraryCardRemovePaddingVertical,
              horizontal: ShosaiTokens.layoutLibraryCardRemovePaddingHorizontal,
            ),
            decoration: BoxDecoration(
              color: palette.surface,
              border: Border.all(
                color: palette.line,
                width: ShosaiTokens.layoutLibraryCardBorderWidth,
              ),
              borderRadius: BorderRadius.circular(ShosaiTokens.radiusSmall),
            ),
            child: Text(
              l10n.cardRemoving,
              maxLines: wraps ? _cardMetadataWrappedLines : 1,
              overflow: TextOverflow.ellipsis,
              style: shosaiInterfaceStyleForText(metaStyle, l10n.cardRemoving),
            ),
          )
        : Text(
            status,
            maxLines: wraps ? _cardMetadataWrappedLines : 1,
            overflow: TextOverflow.ellipsis,
            style: shosaiInterfaceStyleForText(metaStyle, status),
          );
    // The tag follows the status, or takes the next run where it does not
    // fit, so neither cuts the other.
    final tag = open && !removing
        ? Text(
            l10n.cardOpenTag,
            maxLines: 1,
            softWrap: false,
            style: shosaiInterfaceStyleForText(
              _cardOpenTagStyle,
              l10n.cardOpenTag,
            ).copyWith(color: palette.accent),
          )
        : null;
    final badge = ShellFormatBadge(format: book.format);
    final radius = BorderRadius.circular(ShosaiTokens.radiusSm);
    return Stack(
      children: [
        ShadButton.raw(
          variant: ShadButtonVariant.ghost,
          // The card fills its tile: the button's own size theme would pin the
          // content inside a single-line control box, and an infinite bound is
          // resolved against the grid cell.
          width: double.infinity,
          height: double.infinity,
          padding: EdgeInsets.zero,
          // The cover is the card's face, so hovering paints nothing behind
          // it; the focus ring still outlines the whole card.
          backgroundColor: _triggerNoFill,
          hoverBackgroundColor: _triggerNoFill,
          pressedBackgroundColor: _triggerNoFill,
          foregroundColor: palette.ink,
          decoration: ShadDecoration(
            border: ShadBorder.all(radius: radius, width: 0),
            focusedBorder:
                (ShadTheme.of(context).decoration.focusedBorder ??
                        ShadBorder.none)
                    .copyWith(radius: radius),
          ),
          enabled: !removing,
          onPressed: removing ? null : () => openBook(book),
          child: Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: _cardSpacing,
              children: [
                LibraryBookCover(
                  book: book,
                  cover: cover,
                  demandRevision: demandRevision,
                  loadCover: loadCover,
                  type: shelf.coverType,
                  shadow: palette.shelfCoverShadow,
                ),
                SizedBox(
                  height: _cardTitleBox(context, shelf),
                  child: Align(
                    alignment: AlignmentDirectional.topStart,
                    // The card prints the author only on a generated cover,
                    // which is decoration; assistive technology hears it with
                    // the title. The label sits outside the Text so the title
                    // stays a plain paragraph.
                    child: Semantics(
                      label: book.author == null
                          ? null
                          : l10n.cardTitleByAuthorSemantics(
                              book.title,
                              book.author!,
                            ),
                      excludeSemantics: book.author != null,
                      child: Text(
                        book.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.start,
                        textHeightBehavior: _cardTitleHeightBehavior,
                        style: _cardTitleStyle(
                          shelf,
                        ).copyWith(color: palette.ink),
                      ),
                    ),
                  ),
                ),
                SizedBox(
                  height: _cardMetadataBox(context, shelf),
                  child: Align(
                    alignment: AlignmentDirectional.topStart,
                    child: wraps
                        ? Wrap(
                            spacing: 6,
                            runSpacing: _cardMetadataRunSpacing,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [badge, statusLabel, ?tag],
                          )
                        : tag == null
                        ? Row(
                            spacing: 6,
                            children: [
                              badge,
                              Flexible(child: statusLabel),
                            ],
                          )
                        : Wrap(
                            spacing: 6,
                            runSpacing: _cardMetadataRunSpacing,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                spacing: 6,
                                children: [
                                  badge,
                                  Flexible(child: statusLabel),
                                ],
                              ),
                              tag,
                            ],
                          ),
                  ),
                ),
                // The bar shows while the book is under way: not before it is
                // started, and not once it is finished.
                SizedBox(
                  height: _cardProgressHeight,
                  child: book.progress > 0 && book.progress < 1
                      ? ShellProgressBar(
                          value: book.progress,
                          height: _cardProgressHeight,
                        )
                      : null,
                ),
              ],
            ),
          ),
        ),
        if (!removing)
          // Flush with the cover's top-right corner.
          Positioned(
            top: 0,
            right: 0,
            child: _BookActionsMenu(
              managed: book.managed,
              onRemove: () => removeBook(book),
              kept: book.keptOnDevice,
              onKeep: book.located && keepBook != null
                  ? () => keepBook!(book)
                  : null,
            ),
          ),
      ],
    );
  }
}

/// A book's cover box at 2:3: the decoded cover, or the typographic cover
/// while it is missing, pending or failed.
///
/// The box keeps its size either way (LB-12). The cover is requested once the
/// box is built, which is what makes loading lazy and bounded: the grid only
/// builds visible cards, and the controller refuses a request it cannot admit.
class LibraryBookCover extends StatefulWidget {
  const LibraryBookCover({
    super.key,
    required this.book,
    required this.cover,
    required this.demandRevision,
    required this.loadCover,
    required this.type,
    required this.shadow,
    this.width,
  });

  final FlutterLibraryBook book;
  final Uint8List? cover;
  final int demandRevision;
  final bool Function(int) loadCover;

  /// How the typographic cover sets its text at this size.
  final ShellCoverType type;
  final List<BoxShadow> shadow;

  /// The box width; null fills the available width, as a shelf column does.
  final double? width;

  @override
  State<LibraryBookCover> createState() => _LibraryBookCoverState();
}

class _LibraryBookCoverState extends State<LibraryBookCover> {
  late bool _requested;

  @override
  void initState() {
    super.initState();
    _requested = widget.cover != null;
  }

  @override
  void didUpdateWidget(LibraryBookCover oldWidget) {
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
    if (widget.cover == null && !_requested) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.loadCover(widget.book.bookId)) {
          setState(() => _requested = true);
        }
      });
    }
    return SizedBox(
      width: widget.width,
      child: ShellBookCoverFace(
        book: widget.book,
        cover: widget.cover,
        type: widget.type,
        shadow: widget.shadow,
        semanticLabel: AppLocalizations.of(
          context,
        ).cardCoverSemantics(widget.book.title),
      ),
    );
  }
}

/// The card's `•••` action and its removal menu.
///
/// The popover controller is presentation state the card owns; the removal
/// itself is dispatched through [onRemove], never awaited here.
class _BookActionsMenu extends StatefulWidget {
  const _BookActionsMenu({
    required this.managed,
    required this.onRemove,
    this.onKeep,
    this.kept = false,
  });

  final bool managed;
  final VoidCallback onRemove;
  final VoidCallback? onKeep;
  final bool kept;

  @override
  State<_BookActionsMenu> createState() => _BookActionsMenuState();
}

class _BookActionsMenuState extends State<_BookActionsMenu> {
  final ShadPopoverController _controller = ShadPopoverController();
  final ShadStatesController _triggerStates = ShadStatesController();

  @override
  void dispose() {
    _triggerStates.dispose();
    _controller.dispose();
    super.dispose();
  }

  /// The card's quiet `•••` trigger.
  ///
  /// The painted box is the reference's trigger — its 13 px glyph in the
  /// reference's `[5, 8]` padding at `radiusSmall` — at the retained Flutter
  /// cover-corner placement (the reference insets its own box 8 px inside that
  /// corner), inside the unchanged 40 px icon-button target, so the touch,
  /// keyboard and focus affordances do not shrink with the paint.
  ///
  /// The owner asked for a subtler trigger than the reference's opaque `SURFACE`
  /// square with its `BORDER`: the fill is a translucent ink scrim that deepens
  /// while the trigger is hovered, pressed or holding an open menu, so the
  /// persistent control reads as an overlay on the cover instead of a white
  /// block. The action, the hit target, the tooltip, the keyboard path and the
  /// shared focus ring are unchanged.
  Widget _trigger() {
    final l10n = AppLocalizations.of(context);
    // The shared icon-button control size: the hit target this refinement keeps.
    final target = ShadTheme.of(context).buttonSizesTheme.icon!;
    return Tooltip(
      message: l10n.cardActionsTooltip,
      child: ShadIconButton.ghost(
        onPressed: _controller.toggle,
        statesController: _triggerStates,
        iconSize: ShosaiTokens.typeSize13,
        width: target.width,
        height: target.height,
        padding: EdgeInsets.zero,
        // The button paints nothing in any state: the surface child owns the
        // paint, so the hit target can stay the full control size without a
        // visible fill. `app_*` colours are token-derived; the scanner rejects
        // `Colors.*` in `lib/`, and a zero alpha is the absence of paint rather
        // than a design value.
        backgroundColor: _triggerNoFill,
        hoverBackgroundColor: _triggerNoFill,
        pressedBackgroundColor: _triggerNoFill,
        // The paint is the reference's box at the retained cover-corner
        // placement: the target's top-right corner, not centred in it.
        icon: SizedBox(
          width: target.width,
          height: target.height,
          child: Align(
            alignment: Alignment.topRight,
            child: ListenableBuilder(
              listenable: Listenable.merge(<Listenable>[
                _triggerStates,
                _controller,
              ]),
              builder: (context, _) => _CardTriggerSurface(
                active:
                    _controller.isOpen ||
                    _triggerStates.value.contains(ShadState.hovered) ||
                    _triggerStates.value.contains(ShadState.pressed),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = ShadTheme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    final danger = scheme.destructive;
    return ShadPopover(
      controller: _controller,
      popover: (context) => ConstrainedBox(
        // The reference's action is 164 px wide; the constraint is a minimum so
        // a scaled label grows the menu instead of being cut.
        constraints: const BoxConstraints(
          minWidth: ShosaiTokens.layoutLibraryCardMenuWidth,
        ),
        child: Padding(
          padding: const EdgeInsets.all(
            ShosaiTokens.layoutLibraryCardMenuPadding,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.onKeep != null)
                ShadButton.ghost(
                  height: 0,
                  padding: const EdgeInsets.symmetric(
                    vertical:
                        ShosaiTokens.layoutLibraryCardMenuActionPaddingVertical,
                    horizontal: ShosaiTokens
                        .layoutLibraryCardMenuActionPaddingHorizontal,
                  ),
                  mainAxisAlignment: MainAxisAlignment.start,
                  onPressed: () {
                    _controller.hide();
                    widget.onKeep!();
                  },
                  child: Text(
                    widget.kept ? l10n.cardStopKeeping : l10n.cardKeepOnDevice,
                    style: shosaiInterfaceStyleForText(
                      shellInterfaceStyle(12, 16),
                      widget.kept
                          ? l10n.cardStopKeeping
                          : l10n.cardKeepOnDevice,
                    ),
                  ),
                ),
              ShadButton.raw(
                variant: ShadButtonVariant.ghost,
                // `height: 0` is the package's content-sized mode: without it the
                // button pins its label inside the theme's single-line control
                // height, which a scaled label overflows. The reference's 164 px is
                // the menu's minimum (below), so a scaled label grows the menu
                // instead of being cut.
                height: 0,
                padding: const EdgeInsets.symmetric(
                  vertical:
                      ShosaiTokens.layoutLibraryCardMenuActionPaddingVertical,
                  horizontal:
                      ShosaiTokens.layoutLibraryCardMenuActionPaddingHorizontal,
                ),
                mainAxisAlignment: MainAxisAlignment.start,
                foregroundColor: danger,
                hoverForegroundColor: danger,
                hoverBackgroundColor: danger.withValues(
                  alpha: ShosaiTokens.layoutLibraryCardMenuActionHoverAlpha,
                ),
                pressedBackgroundColor: danger.withValues(
                  alpha: ShosaiTokens.layoutLibraryCardMenuActionHoverAlpha,
                ),
                onPressed: () {
                  _controller.hide();
                  widget.onRemove();
                },
                child: Flexible(
                  child: Text(
                    widget.managed
                        ? l10n.cardRemoveManagedCopy
                        : l10n.cardRemoveFromLibrary,
                    style: shosaiInterfaceStyleForText(
                      shellInterfaceStyle(12, 16).copyWith(color: danger),
                      widget.managed
                          ? l10n.cardRemoveManagedCopy
                          : l10n.cardRemoveFromLibrary,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      child: _trigger(),
    );
  }
}

/// No paint: the trigger button's own surface is transparent in every state, so
/// only [_CardTriggerSurface] paints. Derived from the token source because the
/// literal scan rejects `Colors.*` in `lib/`.
Color get _triggerNoFill => ShosaiTokens.appShadowBase.withValues(alpha: 0);

/// The card trigger's painted box.
///
/// The geometry is the reference's: a [ShosaiTokens.typeSize13] glyph in the
/// reference's trigger padding at the shared small radius. The fill is the
/// refinement's translucent ink scrim rather than the reference's opaque
/// surface; [active] deepens it for hover, press and the open menu.
class _CardTriggerSurface extends StatelessWidget {
  const _CardTriggerSurface({required this.active});

  /// Whether the trigger is hovered, pressed or holding an open menu.
  final bool active;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: ShosaiTokens.appShadowBase.withValues(
        alpha: active
            ? ShosaiTokens.layoutLibraryCardTriggerScrimActiveAlpha
            : ShosaiTokens.layoutLibraryCardTriggerScrimAlpha,
      ),
      borderRadius: BorderRadius.circular(ShosaiTokens.radiusSmall),
    ),
    child: const Padding(
      padding: EdgeInsets.symmetric(
        vertical: ShosaiTokens.layoutLibraryCardTriggerPaddingVertical,
        horizontal: ShosaiTokens.layoutLibraryCardTriggerPaddingHorizontal,
      ),
      child: Icon(LucideIcons.ellipsis, color: ShosaiTokens.appTextOnAccent),
    ),
  );
}
