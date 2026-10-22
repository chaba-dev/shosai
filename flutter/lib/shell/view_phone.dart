part of 'view.dart';

/// The phone's bottom bar: the sidebar's four places as icons over 10 px
/// labels on `chrome`; the current place is `accent`. It shows on the
/// library-side screens only.
class ShellBottomNav extends StatelessWidget {
  const ShellBottomNav({
    super.key,
    required this.place,
    required this.onSelected,
  });

  final ShellPlace place;
  final ValueChanged<ShellPlace> onSelected;

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
  final VoidCallback onPressed;

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
            // Four places share a phone's width, so a label scaled past its
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
              for (final entry in model.openBooks)
                _ReadingNowCard(
                  entry: entry,
                  cover: covers[entry.id],
                  actions: actions,
                ),
            ],
          ),
        ),
      ],
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
/// Each card shows the book's cover where the design system shows a
/// miniature of the open page; the page's text is the reader's, and the
/// switcher does not reach into it.
class ShellTabSwitcher extends StatelessWidget {
  const ShellTabSwitcher({
    super.key,
    required this.model,
    required this.covers,
    required this.actions,
  });

  static const double gap = 12;

  final ShellModel model;
  final Map<int, Uint8List> covers;
  final ShellActions actions;

  @override
  Widget build(BuildContext context) {
    final palette = ShellPalette.of(context);
    final l10n = AppLocalizations.of(context);
    final title = l10n.shellOpenBooks(model.openBooks.length);
    final close = actions.closeSwitcher;
    return PopScope(
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
                      (constraints.maxWidth - 32 - gap) / 2,
                    );
                    return SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                      child: Wrap(
                        spacing: gap,
                        runSpacing: gap,
                        children: [
                          for (final entry in model.openBooks)
                            SizedBox(
                              width: width,
                              child: _TabCard(
                                entry: entry,
                                cover: covers[entry.id],
                                current: entry.id == model.currentBookId,
                                actions: actions,
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
  }
}

/// One open book in the switcher (`sh-tabcard`): its title, its cover, the
/// format badge and place, and a progress bar; it closes from its corner.
class _TabCard extends StatelessWidget {
  const _TabCard({
    required this.entry,
    required this.cover,
    required this.current,
    required this.actions,
  });

  final OpenBook entry;
  final Uint8List? cover;
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
                    style: shellEditorialStyle(
                      14,
                      19,
                    ).copyWith(color: palette.ink),
                  ),
                ),
                Container(
                  height: 96,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: palette.surfaceSunken,
                    borderRadius: BorderRadius.circular(ShosaiTokens.radiusXs),
                  ),
                  child: ShellCoverThumb(
                    book: book,
                    cover: cover,
                    loadCover: actions.loadCover,
                    width: 52,
                  ),
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
