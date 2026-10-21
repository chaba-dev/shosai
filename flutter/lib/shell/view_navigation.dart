part of 'view.dart';

/// The places in their one order, with their glyphs.
const List<(ShellPlace, IconData)> _places = [
  (ShellPlace.library, LucideIcons.library),
  (ShellPlace.notes, LucideIcons.messageSquareText),
  (ShellPlace.bookmarks, LucideIcons.bookmark),
  (ShellPlace.search, LucideIcons.search),
];

String shellPlaceLabel(AppLocalizations l10n, ShellPlace place) =>
    switch (place) {
      ShellPlace.library => l10n.shellPlaceLibrary,
      ShellPlace.notes => l10n.shellPlaceNotes,
      ShellPlace.bookmarks => l10n.shellPlaceBookmarks,
      ShellPlace.search => l10n.shellPlaceSearch,
    };

/// The study's left wall on desktop and tablet: the mark and wordmark, a
/// search button (desktop), the places, the open books as Reading now and
/// Add books at the foot.
class ShellSidebar extends StatelessWidget {
  const ShellSidebar({
    super.key,
    required this.layout,
    required this.model,
    required this.covers,
    required this.actions,
  });

  final ShellLayout layout;
  final ShellModel model;
  final Map<int, Uint8List> covers;
  final ShellActions actions;

  @override
  Widget build(BuildContext context) {
    final palette = ShellPalette.of(context);
    final l10n = AppLocalizations.of(context);
    final open = model.openBooks;
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: l10n.shellPlacesLabel,
      child: Container(
        width: layout.sidebarWidth,
        decoration: BoxDecoration(
          color: palette.chrome,
          border: BorderDirectional(end: BorderSide(color: palette.line)),
        ),
        padding: const EdgeInsets.fromLTRB(14, 20, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 6,
          children: [
            const Padding(
              padding: EdgeInsetsDirectional.fromSTEB(6, 0, 6, 14),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: ShellWordmark(),
              ),
            ),
            if (layout == ShellLayout.desktop)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _SidebarSearchButton(
                  onPressed: () => actions.selectPlace(ShellPlace.search),
                ),
              ),
            for (final (place, icon) in _places)
              _PlaceRow(
                icon: icon,
                label: shellPlaceLabel(l10n, place),
                current: !model.reading && model.place == place,
                onPressed: () => actions.selectPlace(place),
              ),
            if (open.isNotEmpty) ...[
              _SidebarHead(
                label: l10n.shellReadingNow,
                count: '${open.length}',
              ),
              Expanded(
                child: ReorderableListView.builder(
                  buildDefaultDragHandles: false,
                  padding: EdgeInsets.zero,
                  itemCount: open.length,
                  onReorder: (from, to) =>
                      actions.moveBook(from, to > from ? to - 1 : to),
                  proxyDecorator: (child, _, _) =>
                      Material(type: MaterialType.transparency, child: child),
                  itemBuilder: (context, index) {
                    final entry = open[index];
                    return ReorderableDelayedDragStartListener(
                      key: ValueKey(entry.id),
                      index: index,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: _OpenBookRow(
                          entry: entry,
                          cover: covers[entry.id],
                          current: entry.id == model.currentBookId,
                          touch: layout.touch,
                          actions: actions,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ] else
              const Spacer(),
            _PlaceRow(
              icon: LucideIcons.plus,
              label: l10n.addBooksAction,
              current: false,
              muted: true,
              onPressed: actions.addBooks,
            ),
          ],
        ),
      ),
    );
  }
}

/// The sidebar while reading: the mark, the places as icon buttons, the open
/// books' covers under a hairline and Add books. It never hides.
class ShellRail extends StatelessWidget {
  const ShellRail({
    super.key,
    required this.layout,
    required this.model,
    required this.covers,
    required this.actions,
  });

  final ShellLayout layout;
  final ShellModel model;
  final Map<int, Uint8List> covers;
  final ShellActions actions;

  @override
  Widget build(BuildContext context) {
    final palette = ShellPalette.of(context);
    final l10n = AppLocalizations.of(context);
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: l10n.shellPlacesLabel,
      child: Container(
        width: layout.railWidth,
        decoration: BoxDecoration(
          color: palette.chrome,
          border: BorderDirectional(end: BorderSide(color: palette.line)),
        ),
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
        child: Column(
          spacing: 8,
          children: [
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: ShellMark(),
            ),
            for (final (place, icon) in _places)
              _RailButton(
                icon: icon,
                label: shellPlaceLabel(l10n, place),
                onPressed: () => actions.selectPlace(place),
              ),
            Expanded(
              child: Container(
                margin: const EdgeInsets.only(top: 6),
                padding: const EdgeInsets.only(top: 10),
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: palette.line)),
                ),
                child: ListView(
                  padding: EdgeInsets.zero,
                  children: [
                    for (final entry in model.openBooks)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Center(
                          child: _RailBook(
                            entry: entry,
                            cover: covers[entry.id],
                            current: entry.id == model.currentBookId,
                            actions: actions,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            _RailButton(
              icon: LucideIcons.plus,
              label: l10n.addBooksAction,
              onPressed: actions.addBooks,
            ),
          ],
        ),
      ),
    );
  }
}

/// A 34 px place row; the current one is a `surface` card lifted by
/// `shadow-raised`, its icon in `accent`.
class _PlaceRow extends StatelessWidget {
  const _PlaceRow({
    required this.icon,
    required this.label,
    required this.current,
    required this.onPressed,
    this.muted = false,
  });

  final IconData icon;
  final String label;
  final bool current;
  final bool muted;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = ShellPalette.of(context);
    final foreground = muted ? palette.inkMuted : palette.ink;
    return _ShellPressable(
      onPressed: onPressed,
      current: current,
      color: current ? palette.surface : null,
      shadow: current ? palette.raised : null,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 34),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            spacing: 10,
            children: [
              Icon(
                icon,
                size: 18,
                color: current ? palette.accent : palette.inkMuted,
              ),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: shosaiInterfaceStyleForText(
                    shellInterfaceStyle(
                      14,
                      18,
                      weight: FontWeight.w500,
                    ).copyWith(color: foreground),
                    label,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The field-shaped Search button under the wordmark (desktop only).
class _SidebarSearchButton extends StatelessWidget {
  const _SidebarSearchButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = ShellPalette.of(context);
    final label = AppLocalizations.of(context).shellPlaceSearch;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: palette.line),
      ),
      child: _ShellPressable(
        onPressed: onPressed,
        color: palette.surface,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 34),
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(10, 7, 8, 7),
            child: Row(
              spacing: 8,
              children: [
                Icon(LucideIcons.search, size: 16, color: palette.inkMuted),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: shosaiInterfaceStyleForText(
                      shellInterfaceStyle(
                        13,
                        18,
                      ).copyWith(color: palette.inkMuted),
                      label,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// `READING NOW` and the open count.
class _SidebarHead extends StatelessWidget {
  const _SidebarHead({required this.label, required this.count});

  final String label;
  final String count;

  @override
  Widget build(BuildContext context) {
    final palette = ShellPalette.of(context);
    final japanese =
        shosaiInterfaceFontForText(label) == shosaiJapaneseInterfaceFontFamily;
    final style = shellInterfaceStyle(
      japanese ? 12 : 11,
      japanese ? 16 : 14,
      weight: FontWeight.w600,
    ).copyWith(color: palette.inkMuted);
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(10, 18, 10, 6),
      child: Semantics(
        header: true,
        child: Row(
          children: [
            Expanded(
              child: Text(
                japanese ? label : label.toUpperCase(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: shosaiInterfaceStyleForText(
                  japanese ? style : style.copyWith(letterSpacing: .88),
                  label,
                ),
              ),
            ),
            Text(
              count,
              style: style.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One open book: a 34 px cover, the title in the editorial serif, its
/// status and a progress bar. The close button shows on hover, and always on
/// touch.
class _OpenBookRow extends StatefulWidget {
  const _OpenBookRow({
    required this.entry,
    required this.cover,
    required this.current,
    required this.touch,
    required this.actions,
  });

  final OpenBook entry;
  final Uint8List? cover;
  final bool current;
  final bool touch;
  final ShellActions actions;

  @override
  State<_OpenBookRow> createState() => _OpenBookRowState();
}

class _OpenBookRowState extends State<_OpenBookRow> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final palette = ShellPalette.of(context);
    final l10n = AppLocalizations.of(context);
    final book = widget.entry.book;
    final status = shellReadingStatus(l10n, book.progress);
    final started = (book.progress * 100).round() > 0;
    final closeLabel = l10n.shellCloseBook(book.title);
    // Focus anywhere in the row reveals the close button too, so a keyboard
    // user can see the control and its focus ring before pressing it.
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (focused) => setState(() => _focused = focused),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Stack(
          children: [
            _ShellPressable(
              onPressed: () => widget.actions.openBook(widget.entry),
              current: widget.current,
              color: widget.current ? palette.surface : null,
              shadow: widget.current ? palette.raised : null,
              child: Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(8, 6, 30, 6),
                child: Row(
                  spacing: 10,
                  children: [
                    ShellCoverThumb(
                      book: book,
                      cover: widget.cover,
                      loadCover: widget.actions.loadCover,
                      width: 34,
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        spacing: 3,
                        children: [
                          Text(
                            book.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: shellEditorialStyle(
                              13,
                              17,
                            ).copyWith(color: palette.ink),
                          ),
                          Text(
                            status,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: shosaiInterfaceStyleForText(
                              shellInterfaceStyle(11, 14).copyWith(
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
              end: 4,
              top: 0,
              bottom: 0,
              child: Center(
                child: Visibility.maintain(
                  visible: widget.touch || _hovered || _focused,
                  child: _CloseButton(
                    label: closeLabel,
                    size: widget.touch ? 32 : 24,
                    onPressed: () => widget.actions.closeBook(widget.entry),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CloseButton extends StatelessWidget {
  const _CloseButton({
    required this.label,
    required this.onPressed,
    this.size = 24,
  });

  final String label;
  final VoidCallback onPressed;
  final double size;

  @override
  Widget build(BuildContext context) {
    final palette = ShellPalette.of(context);
    return _ShellPressable(
      onPressed: onPressed,
      radius: 5,
      tooltip: label,
      semanticLabel: label,
      child: SizedBox.square(
        dimension: size,
        child: Icon(LucideIcons.x, size: 14, color: palette.inkMuted),
      ),
    );
  }
}

/// A 40 px icon place in the rail, with a tooltip in the same words.
class _RailButton extends StatelessWidget {
  const _RailButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = ShellPalette.of(context);
    return _ShellPressable(
      onPressed: onPressed,
      tooltip: label,
      semanticLabel: label,
      child: SizedBox.square(
        dimension: 40,
        child: Icon(icon, size: 18, color: palette.inkMuted),
      ),
    );
  }
}

/// An open book's 30 px cover in the rail; the current one is outlined in
/// `accent`.
class _RailBook extends StatelessWidget {
  const _RailBook({
    required this.entry,
    required this.cover,
    required this.current,
    required this.actions,
  });

  final OpenBook entry;
  final Uint8List? cover;
  final bool current;
  final ShellActions actions;

  @override
  Widget build(BuildContext context) {
    final palette = ShellPalette.of(context);
    return _ShellPressable(
      onPressed: () => actions.openBook(entry),
      radius: 4,
      tooltip: entry.book.title,
      semanticLabel: entry.book.title,
      current: current,
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(2),
            border: current
                ? Border.all(
                    color: palette.accent,
                    width: 2,
                    strokeAlign: BorderSide.strokeAlignOutside,
                  )
                : null,
          ),
          child: Opacity(
            opacity: current ? 1 : .7,
            child: ShellCoverThumb(
              book: entry.book,
              cover: cover,
              loadCover: actions.loadCover,
              width: 30,
            ),
          ),
        ),
      ),
    );
  }
}
