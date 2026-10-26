part of 'view.dart';

// Package 3A: the library's navigation composition.
//
// The shape is the pinned Iced reference — `library_header`, `library_sidebar`
// and `mobile_library_filters` in `crates/shosai-app/src/app.rs` at the pinned
// base `1e54270a6bb2`, with the values frozen in
// `docs/flutter-ui-reference-spec.md` §3.5: a header carrying the page title,
// subtitle, a 380 px search and the add-books action, and a filter row carrying
// the format entries. Settings belongs to the shell navigation instead.
//
// Deliberate differences from the reference:
//
// * The Bookshelf shell's sidebar (RFD 12, 2026-10-20) replaced the reference's
//   184 px collection sidebar. The filter row carries only format entries;
//   Settings lives in the sidebar, reader rail, or phone's bottom navigation.

// * The compact row sizes its entries to their labels instead of filling the
//   width (chosen when a fifth CBZ entry could not share one equal-width row at
//   390 px without truncating "Settings"; CBZ left with its format support on
//   2026-10-20 and the sizing stays), and at 200% text it wraps onto a second
//   line rather than clipping or hiding an entry.
// * Refresh is a retained Flutter capability with no Iced counterpart in the
//   library header. It stays reachable as a header action.
//
// Every control here renders immutable [LibraryModel] state and dispatches a
// typed message; no widget owns an effect.

/// The library header: title with the book and open counts beside it,
/// subtitle, constrained search and the add-books action.
///
/// `compact` follows the shared 760 logical-pixel breakpoint: the reference
/// stacks title, search and action in compact windows and places them in one
/// row with the search capped at
/// [ShosaiTokens.layoutLibraryHeaderSearchMaxWidth] in wide ones.
class LibraryHeader extends StatelessWidget {
  const LibraryHeader({
    super.key,
    required this.compact,
    required this.model,
    this.openCount = 0,
    required this.canCancelOperation,
    required this.onQueryChanged,
    required this.onImportRequested,
    required this.onImportCancelled,
    required this.onOperationCancelled,
    required this.onRefresh,
  });

  final bool compact;
  final LibraryModel model;

  /// How many books are open in Reading now.
  final int openCount;

  /// Whether a cancellable operation other than the add-books import is in
  /// flight, so the header keeps a cancel action for it.
  final bool canCancelOperation;

  final ValueChanged<String> onQueryChanged;
  final VoidCallback onImportRequested;
  final VoidCallback onImportCancelled;
  final VoidCallback onOperationCancelled;
  final VoidCallback onRefresh;

  /// The reference's header search padding (`library_header` applies
  /// `[10, 12]`), which the Shad input's own theme does not carry.
  static const EdgeInsets _searchPadding = EdgeInsets.symmetric(
    vertical: 10,
    horizontal: 12,
  );

  @override
  Widget build(BuildContext context) {
    final scheme = ShadTheme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    final title = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 2,
      children: [
        // The library is a screen of its own, titled in `ed-display`.
        _title(context, l10n, scheme),
        Text(
          l10n.librarySubtitle,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: scheme.mutedForeground),
        ),
      ],
    );
    final search = ConstrainedBox(
      constraints: const BoxConstraints(
        maxWidth: ShosaiTokens.layoutLibraryHeaderSearchMaxWidth,
      ),
      child: ShadInput(
        // The input is recreated when the window crosses the breakpoint, so it
        // restores the query the controller still filters by instead of
        // starting empty.
        initialValue: model.query,
        padding: _searchPadding,
        // The input lays its placeholder out in a single-line box, so a scaled
        // placeholder that wraps is clipped rather than shown; an ellipsized
        // single line is the visible, non-clipping form.
        placeholder: Text(
          l10n.searchLibraryPlaceholder,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        leading: const Icon(LucideIcons.search, size: 16),
        onChanged: onQueryChanged,
      ),
    );
    final actions = Wrap(
      spacing: 12,
      runSpacing: 4,
      children: [
        if (canCancelOperation && model.discoveryProgress == null)
          ShadIconAction(
            tooltip: l10n.cancelOperationTooltip,
            onPressed: onOperationCancelled,
            icon: const Icon(LucideIcons.x),
          ),
        ShadIconAction(
          tooltip: l10n.refreshLibraryTooltip,
          onPressed: model.busy ? null : onRefresh,
          icon: const Icon(LucideIcons.refreshCw),
        ),
        _addBooksAction(context),
      ],
    );
    final content = compact
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 12,
            children: [
              title,
              // Stretch would hand the search a tight width that its 380 px
              // cap cannot narrow, so the capped search is aligned instead.
              Align(alignment: AlignmentDirectional.centerStart, child: search),
              actions,
            ],
          )
        : Row(
            // The title region and the search share the space the actions
            // leave, and both are flexible: a narrow wide window shrinks them
            // instead of overflowing the row, and a leftover appears only once
            // the search reaches its 380 px cap, where it is distributed
            // between the entries so the actions stay flush with the header's
            // padding. The 3:2 split keeps the search next to the actions and
            // reaches the cap at the primary wide reference (LB-07).
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            spacing: 16,
            children: [
              Expanded(flex: 3, child: title),
              Flexible(flex: 2, child: search),
              actions,
            ],
          );
    return Container(
      decoration: BoxDecoration(
        // The header surface is the mapped application surface: the pinned
        // Iced surface in the light theme and the retained dark palette's card
        // surface in the dark one, so the header cannot paint a light band
        // under a dark theme's foreground.
        color: scheme.card,
        boxShadow: [
          BoxShadow(
            color: ShosaiTokens.appShadowHairline,
            offset: const Offset(0, 1),
            blurRadius: 6,
          ),
        ],
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
            child: content,
          ),
          if (model.discoveryProgress case final progress?)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 8,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Semantics(
                          liveRegion: true,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(l10n.libraryCheckingSource(progress.source)),
                              Text(
                                l10n.libraryDiscoveryCount(
                                  progress.sourceIndex,
                                  progress.sourceCount,
                                  progress.booksFound,
                                ),
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (canCancelOperation)
                        ShadButton.ghost(
                          onPressed: onOperationCancelled,
                          child: Text(l10n.cancelImportAction),
                        ),
                    ],
                  ),
                  const LinearProgressIndicator(),
                ],
              ),
            )
          else
            _LibraryActivityBar(active: model.busy),
        ],
      ),
    );
  }

  /// The title with the counts beside it on its baseline; where the two do
  /// not share the width, the counts take the line below.
  Widget _title(
    BuildContext context,
    AppLocalizations l10n,
    ShadColorScheme scheme,
  ) {
    final titleStyle = shellScreenTitleStyle(
      ShellLayout.forWidth(MediaQuery.sizeOf(context).width),
    ).copyWith(color: scheme.foreground);
    final title = Text(l10n.libraryTitle, style: titleStyle);
    final counts = _counts(l10n);
    if (counts == null) return title;
    final countsStyle = shosaiInterfaceStyleForText(
      shellInterfaceStyle(12, 16).copyWith(
        color: scheme.mutedForeground,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
      counts,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final countsText = Text(counts, style: countsStyle);
        final width =
            _textWidth(context, l10n.libraryTitle, titleStyle) +
            _titleCountsGap +
            _textWidth(context, counts, countsStyle);
        if (width > constraints.maxWidth) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [title, countsText],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          spacing: _titleCountsGap,
          children: [title, countsText],
        );
      },
    );
  }

  static const double _titleCountsGap = 14;

  /// `12 books · 2 open`: the library's size, then the open books when there
  /// are any; null until the library has reported its size.
  String? _counts(AppLocalizations l10n) {
    final books = model.bookCount;
    if (books == null) return null;
    return [
      l10n.libraryBookCount(books),
      if (openCount > 0) l10n.libraryOpenCount(openCount),
    ].join(' · ');
  }

  /// The add-books action, or the cancel action while the import is in flight.
  ///
  /// The action keeps the reference's primary button geometry
  /// (`app.button.primary`) and its opaque hovered fill, the design system's
  /// accent-hover in each theme, instead of the Shad primary variant's
  /// translucent one, which darkens the light dark-theme accent under its dark
  /// label.
  Widget _addBooksAction(BuildContext context) {
    const padding = EdgeInsets.symmetric(
      vertical: ShosaiTokens.layoutButtonPrimaryPaddingVertical,
      horizontal: ShosaiTokens.layoutButtonPrimaryPaddingHorizontal,
    );
    final theme = ShadTheme.of(context);
    final l10n = AppLocalizations.of(context);
    final height = shosaiShadButtonHeight(context, padding: padding);
    final hover = theme.brightness == Brightness.dark
        ? ShosaiTokens.appDarkPrimaryHovered
        : ShosaiTokens.appAccentHovered;
    if (model.importing) {
      return ShadButton(
        height: height,
        padding: padding,
        hoverBackgroundColor: hover,
        pressedBackgroundColor: hover,
        onPressed: onImportCancelled,
        leading: const Icon(LucideIcons.x),
        child: Text(l10n.cancelImportAction),
      );
    }
    return ShadButton(
      height: height,
      padding: padding,
      hoverBackgroundColor: hover,
      pressedBackgroundColor: hover,
      enabled: !model.busy,
      onPressed: model.busy ? null : onImportRequested,
      leading: const Icon(LucideIcons.plus),
      child: Text(l10n.addBooksAction),
    );
  }
}

/// The library activity bar the reference shows under the header.
///
/// Iced always lays the bar out and fades it with the activity opacity, so the
/// slot keeps its height when nothing is in flight and only the bar itself is
/// absent.
class _LibraryActivityBar extends StatelessWidget {
  const _LibraryActivityBar({required this.active});

  final bool active;

  @override
  Widget build(BuildContext context) {
    final scheme = ShadTheme.of(context).colorScheme;
    return SizedBox(
      height: ShosaiTokens.layoutProgressGirth,
      width: double.infinity,
      child: active
          ? ShadProgress(
              minHeight: ShosaiTokens.layoutProgressGirth,
              // The reference paints the track on the muted surface with its
              // own 2 px radius; Shad would use the secondary surface instead.
              backgroundColor: scheme.muted,
              color: scheme.primary,
              borderRadius: BorderRadius.circular(ShosaiTokens.radiusProgress),
              innerBorderRadius: BorderRadius.circular(
                ShosaiTokens.radiusProgress,
              ),
            )
          : null,
    );
  }
}

/// The filter row under the header.
///
/// All/EPUB/PDF stay directly reachable; the entries size to
/// their labels so every one of them stays readable, and the row wraps onto a
/// second line at large text instead of clipping or dropping an entry.
class LibraryFilterRow extends StatelessWidget {
  const LibraryFilterRow({
    super.key,
    required this.model,
    required this.onFormatChanged,
  });

  final LibraryModel model;
  final ValueChanged<FlutterBookFormat?> onFormatChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        children: [
          ..._libraryFormatEntries(
            model: model,
            l10n: l10n,
            onFormatChanged: onFormatChanged,
          ),
        ],
      ),
    );
  }
}

/// One format entry per retained filter, in the reference's order. Format
/// names stay Latin in both catalogs, as they are in the reference.
List<Widget> _libraryFormatEntries({
  required LibraryModel model,
  required AppLocalizations l10n,
  required ValueChanged<FlutterBookFormat?> onFormatChanged,
}) => [
  for (final (filter, label) in <(FlutterBookFormat?, String)>[
    (null, l10n.filterAll),
    (FlutterBookFormat.epub, l10n.filterFormatEpub),
    (FlutterBookFormat.pdf, l10n.filterFormatPdf),
  ])
    LibraryNavigationButton(
      label: label,
      selected: model.format == filter,
      onPressed: () => onFormatChanged(filter),
      fillWidth: false,
    ),
];

/// A library navigation entry, styled from the reference's navigation button
/// (`app.button.navigation`): a 14 px label, `[9, 12]` padding, the accent-soft
/// surface and accent text for the selected entry, the muted surface on hover.
///
/// The selected entry is exclusive because [LibraryModel.format] holds at most
/// one format. The button is a real Shad button, so it keeps the shared focus
/// ring, Enter/Space activation and button semantics (LB-09).
class LibraryNavigationButton extends StatelessWidget {
  const LibraryNavigationButton({
    super.key,
    required this.label,
    required this.selected,
    required this.onPressed,
    required this.fillWidth,
  });

  final String label;
  final bool selected;
  final VoidCallback? onPressed;

  /// Whether the entry fills its container's width (the sidebar) or sizes to
  /// its label (the compact filter row).
  final bool fillWidth;

  /// Scrolls this entry to the middle of its viewport when it takes focus.
  ///
  /// Keyboard traversal reveals an offscreen control flush with the viewport
  /// edge, and the shared focus ring paints outside the control, so a reveal
  /// without clearance would clip the ring. Centering leaves the ring inside
  /// the viewport; a sidebar with nothing to scroll does not move.
  void _revealFocused(BuildContext context) {
    if (Scrollable.maybeOf(context) == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!context.mounted) return;
      Scrollable.ensureVisible(
        context,
        alignment: 0.5,
        duration: Duration.zero,
      );
    });
  }

  static const EdgeInsets _padding = EdgeInsets.symmetric(
    vertical: ShosaiTokens.layoutButtonNavigationPaddingVertical,
    horizontal: ShosaiTokens.layoutButtonNavigationPaddingHorizontal,
  );

  @override
  Widget build(BuildContext context) {
    // The mapped roles resolve to the pinned Iced values in the light theme
    // (`app.accentSoft`, `app.accent`, `app.text`, `app.surfaceMuted`) and to
    // the retained dark palette in the dark one, so a selected entry stays
    // distinct from a hovered one under either theme.
    final scheme = ShadTheme.of(context).colorScheme;
    final foreground = selected ? scheme.accentForeground : scheme.foreground;
    final hover = selected ? scheme.selection : scheme.muted;
    return ShadButton.raw(
      variant: ShadButtonVariant.ghost,
      // A null callback alone leaves a Shad button looking active; the entry
      // has to carry its disabled state so it dims and reports itself
      // disabled to assistive technology.
      enabled: onPressed != null,
      width: fillWidth ? double.infinity : null,
      height: shosaiShadButtonHeight(context, padding: _padding),
      padding: _padding,
      mainAxisAlignment: MainAxisAlignment.start,
      backgroundColor: selected ? scheme.selection : null,
      hoverBackgroundColor: hover,
      pressedBackgroundColor: hover,
      foregroundColor: foreground,
      hoverForegroundColor: foreground,
      onFocusChange: (focused) {
        if (focused) _revealFocused(context);
      },
      onPressed: onPressed,
      child: Flexible(
        // A Shad button lays its content out in a Row, whose non-flexible
        // children receive an unbounded width; the label has to be a flexible
        // child of that row so a scaled or long label ellipsizes inside the
        // button instead of overflowing it (LB-10).
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: _navigationLabelStyle(label),
        ),
      ),
    );
  }
}

/// The family override that keeps a Japanese label on the bundled face.
///
/// The button's own text style supplies the size and color, so only the family
/// is overridden here: a fallback run would be positioned against the primary
/// font's metrics and can paint outside the paragraph box (see
/// [shosaiInterfaceStyleForText]).
TextStyle? _navigationLabelStyle(String label) =>
    shosaiInterfaceFontForText(label) == shosaiJapaneseInterfaceFontFamily
    ? const TextStyle(
        fontFamily: shosaiJapaneseInterfaceFontFamily,
        fontFamilyFallback: [shosaiInterfaceFontFamily],
      )
    : null;
