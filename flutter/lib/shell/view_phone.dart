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
    final started = (book.progress * 100).round() > 0;
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
              padding: const EdgeInsetsDirectional.fromSTEB(12, 12, 40, 12),
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
              size: 36,
              onPressed: () => actions.closeBook(entry),
            ),
          ),
        ],
      ),
    );
  }
}
