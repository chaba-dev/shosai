part of 'view.dart';

/// The phone's bottom bar: the places and Settings as icons over 10 px
/// labels on `chrome`; the current place is `accent`. It shows on the
/// library-side screens only.
class ShellBottomNav extends StatelessWidget {
  const ShellBottomNav({
    super.key,
    required this.place,
    required this.onSelected,
    this.onSettings,
  });

  final ShellPlace place;
  final ValueChanged<ShellPlace> onSelected;
  final VoidCallback? onSettings;

  @override
  Widget build(BuildContext context) {
    final palette = ShellPalette.of(context);
    final l10n = AppLocalizations.of(context);
    final inset = MediaQuery.paddingOf(context).bottom;
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: l10n.shellPlacesLabel,
      child: Container(
        constraints: BoxConstraints(minHeight: shellBottomNavHeight + inset),
        padding: EdgeInsets.fromLTRB(8, 6, 8, 10 + inset),
        decoration: BoxDecoration(
          color: palette.chrome,
          border: Border(top: BorderSide(color: palette.line)),
        ),
        child: Row(
          children: [
            for (final (entry, icon) in _places)
              Expanded(
                child: _BottomNavButton(
                  icon: icon,
                  label: shellPlaceLabel(l10n, entry),
                  current: entry == place,
                  onPressed: () => onSelected(entry),
                ),
              ),
            Expanded(
              child: _BottomNavButton(
                icon: LucideIcons.settings,
                label: l10n.filterSettings,
                current: place == ShellPlace.settings,
                onPressed: onSettings,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BottomNavButton extends StatelessWidget {
  const _BottomNavButton({
    required this.icon,
    required this.label,
    required this.current,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final bool current;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = ShellPalette.of(context);
    final color = current ? palette.accent : palette.inkMuted;
    return _ShellPressable(
      onPressed: onPressed,
      current: current,
      semanticLabel: label,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          spacing: 3,
          children: [
            Icon(icon, size: 20, color: color),
            // Navigation entries share a phone's width, so a label scaled past its
            // slot shrinks to fit instead of losing its end.
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                label,
                maxLines: 1,
                style: shosaiInterfaceStyleForText(
                  shellInterfaceStyle(
                    10,
                    12,
                    weight: FontWeight.w500,
                  ).copyWith(color: color),
                  label,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The open books on a phone's library: Reading now cards above the shelf,
/// in the sidebar's order. Each card opens its book or closes it.
class ShellReadingNowCards extends StatelessWidget {
  const ShellReadingNowCards({
    super.key,
    required this.model,
    required this.covers,
    required this.actions,
  });

  static const double cardWidth = 248;

  final ShellModel model;
  final Map<int, Uint8List> covers;
  final ShellActions actions;

  @override
  Widget build(BuildContext context) {
    if (model.openBooks.isEmpty) return const SizedBox.shrink();
    final palette = ShellPalette.of(context);
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 10,
      children: [
        Semantics(
          header: true,
          child: Text(
            l10n.shellReadingNow,
            style: shellEditorialStyle(20, 24).copyWith(color: palette.ink),
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          clipBehavior: Clip.none,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 12,
            children: [
              for (var index = 0; index < model.openBooks.length; index++)
                _ReorderablePhoneBook(
                  key: ValueKey(model.openBooks[index].id),
                  model: model,
                  index: index,
                  actions: actions,
                  axis: Axis.horizontal,
                  child: _ReadingNowCard(
                    entry: model.openBooks[index],
                    cover: covers[model.openBooks[index].id],
                    actions: actions,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Both phone book lists use the shell's existing durable ordering. A normal
/// drag still scrolls; a long press lifts a book to drop onto another slot.
class _ReorderablePhoneBook extends StatelessWidget {
  const _ReorderablePhoneBook({
    super.key,
    required this.model,
    required this.index,
    required this.actions,
    required this.child,
    this.axis = Axis.vertical,
  });

  final ShellModel model;
  final int index;
  final ShellActions actions;
  final Widget child;
  final Axis axis;

  @override
  Widget build(BuildContext context) {
    final l10n = WidgetsLocalizations.of(context);
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final earlier = axis == Axis.vertical
        ? l10n.reorderItemUp
        : rtl
        ? l10n.reorderItemRight
        : l10n.reorderItemLeft;
    final later = axis == Axis.vertical
        ? l10n.reorderItemDown
        : rtl
        ? l10n.reorderItemLeft
        : l10n.reorderItemRight;
    final bookId = model.openBooks[index].id;
    return Semantics(
      customSemanticsActions: {
        if (index > 0)
          CustomSemanticsAction(label: earlier): () =>
              actions.moveBook(index, index - 1),
        if (index + 1 < model.openBooks.length)
          CustomSemanticsAction(label: later): () =>
              actions.moveBook(index, index + 1),
      },
      child: LayoutBuilder(
        builder: (context, constraints) => LongPressDraggable<int>(
          data: bookId,
          maxSimultaneousDrags: 1,
          feedback: SizedBox(
            width: constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : ShellReadingNowCards.cardWidth,
            child: Material(
              type: MaterialType.transparency,
              child: Opacity(opacity: .85, child: child),
            ),
          ),
          childWhenDragging: Opacity(opacity: .35, child: child),
          child: DragTarget<int>(
            onWillAcceptWithDetails: (details) => details.data != bookId,
            onAcceptWithDetails: (details) {
              final from = model.openBooks.indexWhere(
                (entry) => entry.id == details.data,
              );
              if (from >= 0) actions.moveBook(from, index);
            },
            builder: (context, candidates, rejected) => DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: candidates.isEmpty
                    ? null
                    : Border.all(
                        color: ShellPalette.of(context).accent,
                        width: 2,
                      ),
              ),
              position: DecorationPosition.foreground,
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

class _ReadingNowCard extends StatelessWidget {
  const _ReadingNowCard({
    required this.entry,
    required this.cover,
    required this.actions,
  });

  final OpenBook entry;
  final Uint8List? cover;
  final ShellActions actions;

  @override
  Widget build(BuildContext context) {
    final palette = ShellPalette.of(context);
    final l10n = AppLocalizations.of(context);
    final book = entry.book;
    final status = shellReadingStatus(l10n, book.progress);
    final started = book.progress > 0;
    return SizedBox(
      width: ShellReadingNowCards.cardWidth,
      child: Stack(
        children: [
          _ShellPressable(
            onPressed: () => actions.openBook(entry),
            radius: 12,
            color: palette.surface,
            shadow: palette.raised,
            child: Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(12, 12, 48, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 12,
                children: [
                  ShellCoverThumb(
                    book: book,
                    cover: cover,
                    loadCover: actions.loadCover,
                    width: 44,
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      spacing: 6,
                      children: [
                        Text(
                          book.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: shellEditorialStyle(
                            14,
                            19,
                          ).copyWith(color: palette.ink),
                        ),
                        Text(
                          status,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: shosaiInterfaceStyleForText(
                            shellInterfaceStyle(12, 16).copyWith(
                              color: palette.inkMuted,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                            status,
                          ),
                        ),
                        if (started) ShellProgressBar(value: book.progress),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          PositionedDirectional(
            top: 4,
            end: 4,
            child: _CloseButton(
              label: l10n.shellCloseBook(book.title),
              size: ShosaiTokens.sizeTouchTarget,
              onPressed: () => actions.closeBook(entry),
            ),
          ),
        ],
      ),
    );
  }
}

/// The open-book count in the phone reader's toolbar (`docs/design-system.md`,
/// ReaderToolbar): the number in a rounded square, at `touch-target` size.
/// It opens the tab switcher.
class ShellOpenBooksButton extends StatelessWidget {
  const ShellOpenBooksButton({
    super.key,
    required this.count,
    required this.onPressed,
  });

  final int count;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = ShellPalette.of(context);
    final label = AppLocalizations.of(context).shellOpenBooks(count);
    return _ShellPressable(
      onPressed: onPressed,
      tooltip: label,
      semanticLabel: label,
      child: SizedBox.square(
        dimension: ShosaiTokens.sizeTouchTarget,
        child: Center(
          child: Container(
            constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
            padding: const EdgeInsets.symmetric(horizontal: 4),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              border: Border.all(color: palette.ink, width: 1.75),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              '$count',
              style: shellInterfaceStyle(12, 16, weight: FontWeight.w600)
                  .copyWith(
                    color: palette.ink,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The phone's tab switcher (`docs/design-system.md`, TabSwitcher): the open
/// books, in the sidebar's order, as a grid of cards over the reader, then
/// the library card. A card reads its book and closes the switcher; the
/// current one is outlined in `accent`. **Done** returns to the current book,
/// and so does the system back gesture.
///
/// Each card shows a miniature of the book's open page as the reader last
/// showed it, or, for a book not shown since launch, its cover.
///
/// It takes keyboard focus while it shows and gives it back to what had it,
/// such as the count button, when it closes.
class ShellTabSwitcher extends StatefulWidget {
  const ShellTabSwitcher({
    super.key,
    required this.model,
    required this.covers,
    this.pages = const {},
    required this.actions,
  });

  static const double gap = 12;

  /// The source crop has the narrowest phone card's proportions. Capture is
  /// capped at 1.5× its widest rendered width; the controller also admits all
  /// retained miniatures under one memory budget.
  static const double miniatureSourceWidth = 280;
  static const double miniatureSourceHeight = 168;
  static const int miniatureMaxPixelWidth = 420;

  final ShellModel model;
  final Map<int, Uint8List> covers;

  /// Miniatures of the open books' pages, by book id.
  final Map<int, ui.Image> pages;
  final ShellActions actions;

  @override
  State<ShellTabSwitcher> createState() => _ShellTabSwitcherState();
}

class _ShellTabSwitcherState extends State<ShellTabSwitcher> {
  /// What had focus when the switcher opened.
  final FocusNode? _restore = FocusManager.instance.primaryFocus;

  @override
  void dispose() {
    final restore = _restore;
    // The reader under the switcher becomes focusable again in this frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (restore?.context?.mounted ?? false) restore!.requestFocus();
    });
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ShellTabSwitcher(:model, :covers, :pages, :actions) = widget;
    final palette = ShellPalette.of(context);
    final l10n = AppLocalizations.of(context);
    final title = l10n.shellOpenBooks(model.openBooks.length);
    final close = actions.closeSwitcher;
    final sheet = PopScope(
      canPop: close == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) close?.call();
      },
      child: Material(
        color: palette.chrome,
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: ShosaiTokens.sizeToolbarHeight,
                ),
                child: Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(16, 0, 8, 0),
                  child: Row(
                    spacing: 8,
                    children: [
                      Expanded(
                        child: Semantics(
                          header: true,
                          child: Text(
                            title,
                            style: shosaiInterfaceStyleForText(
                              shellInterfaceStyle(
                                16,
                                22,
                                weight: FontWeight.w600,
                              ).copyWith(color: palette.ink),
                              title,
                            ),
                          ),
                        ),
                      ),
                      if (close != null)
                        _ShellPressable(
                          onPressed: close,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(
                              minHeight: ShosaiTokens.sizeTouchTarget,
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              child: Center(
                                widthFactor: 1,
                                child: Text(
                                  l10n.shellSwitcherDone,
                                  style: shosaiInterfaceStyleForText(
                                    shellInterfaceStyle(
                                      15,
                                      20,
                                      weight: FontWeight.w600,
                                    ).copyWith(color: palette.accent),
                                    l10n.shellSwitcherDone,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final width = math.max(
                      0.0,
                      (constraints.maxWidth - 32 - ShellTabSwitcher.gap) / 2,
                    );
                    return SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                      child: Wrap(
                        spacing: ShellTabSwitcher.gap,
                        runSpacing: ShellTabSwitcher.gap,
                        children: [
                          for (
                            var index = 0;
                            index < model.openBooks.length;
                            index++
                          )
                            SizedBox(
                              key: ValueKey(model.openBooks[index].id),
                              width: width,
                              child: _ReorderablePhoneBook(
                                model: model,
                                index: index,
                                actions: actions,
                                child: _TabCard(
                                  entry: model.openBooks[index],
                                  cover: covers[model.openBooks[index].id],
                                  page: pages[model.openBooks[index].id],
                                  current:
                                      model.openBooks[index].id ==
                                      model.currentBookId,
                                  actions: actions,
                                ),
                              ),
                            ),
                          SizedBox(
                            width: width,
                            child: _LibraryTabCard(
                              onPressed: () =>
                                  actions.selectPlace(ShellPlace.library),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    // Its own scope, so Tab moves among its controls only.
    return FocusScope(autofocus: true, child: sheet);
  }
}

/// One open book in the switcher (`sh-tabcard`): its title, the top of its
/// open page (or its cover), the format badge and place, and a progress bar;
/// it closes from its corner.
class _TabCard extends StatelessWidget {
  const _TabCard({
    required this.entry,
    required this.cover,
    required this.page,
    required this.current,
    required this.actions,
  });

  final OpenBook entry;
  final Uint8List? cover;
  final ui.Image? page;
  final bool current;
  final ShellActions actions;

  static const double radius = 12;

  @override
  Widget build(BuildContext context) {
    final palette = ShellPalette.of(context);
    final l10n = AppLocalizations.of(context);
    final book = entry.book;
    final status = shellReadingStatus(l10n, book.progress);
    return Stack(
      children: [
        _ShellPressable(
          onPressed: () => actions.openBook(entry),
          current: current,
          radius: radius,
          color: palette.surface,
          shadow: palette.raised,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 8,
              children: [
                // Clear of the close button in the corner.
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: 28),
                  child: Text(
                    book.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    // Literata's descent reaches past the tight leading, and an
                    // ellipsized title clips it to its box: on macOS the cut is
                    // a visible pixel row.
                    textHeightBehavior: const TextHeightBehavior(
                      applyHeightToLastDescent: false,
                    ),
                    style: shellEditorialStyle(
                      14,
                      19,
                    ).copyWith(color: palette.ink),
                  ),
                ),
                Container(
                  height: 96,
                  alignment: Alignment.center,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: palette.surfaceSunken,
                    borderRadius: BorderRadius.circular(ShosaiTokens.radiusXs),
                  ),
                  child: switch (page) {
                    // The page across the card, from its top.
                    final page? => RawImage(
                      key: ValueKey('shell-tab-page-${entry.id}'),
                      image: page,
                      width: double.infinity,
                      height: double.infinity,
                      fit: BoxFit.cover,
                      alignment: Alignment.topCenter,
                      filterQuality: FilterQuality.medium,
                    ),
                    null => ShellCoverThumb(
                      book: book,
                      cover: cover,
                      loadCover: actions.loadCover,
                      width: 52,
                    ),
                  },
                ),
                Row(
                  spacing: 6,
                  children: [
                    ShellFormatBadge(format: book.format),
                    Flexible(
                      child: Text(
                        status,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: shosaiInterfaceStyleForText(
                          shellInterfaceStyle(12, 16).copyWith(
                            color: palette.inkMuted,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                          status,
                        ),
                      ),
                    ),
                  ],
                ),
                ShellProgressBar(value: book.progress),
              ],
            ),
          ),
        ),
        if (current)
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(radius),
                  border: Border.all(color: palette.accent, width: 2),
                ),
              ),
            ),
          ),
        PositionedDirectional(
          top: 0,
          end: 0,
          child: _CloseButton(
            label: l10n.shellCloseBook(book.title),
            size: ShosaiTokens.sizeTouchTarget,
            onPressed: () => actions.closeBook(entry),
          ),
        ),
      ],
    );
  }
}

/// The switcher's last card: back to the library.
class _LibraryTabCard extends StatelessWidget {
  const _LibraryTabCard({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = ShellPalette.of(context);
    final label = AppLocalizations.of(context).shellPlaceLibrary;
    return DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(_TabCard.radius),
        border: Border.all(color: palette.lineStrong),
      ),
      child: _ShellPressable(
        onPressed: onPressed,
        radius: _TabCard.radius,
        child: SizedBox(
          height: 160,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            spacing: 8,
            children: [
              Icon(LucideIcons.library, size: 20, color: palette.inkMuted),
              Text(
                label,
                style: shosaiInterfaceStyleForText(
                  shellInterfaceStyle(
                    13,
                    18,
                    weight: FontWeight.w500,
                  ).copyWith(color: palette.inkMuted),
                  label,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
