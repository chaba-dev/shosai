part of 'view.dart';

// Package 3A: the library's navigation composition.
//
// The shape is the pinned Iced reference — `library_header`, `library_sidebar`
// and `mobile_library_filters` in `crates/shosai-app/src/app.rs` at the pinned
// base `1e54270a6bb2`, with the values frozen in
// `docs/flutter-ui-reference-spec.md` §3.5: a header carrying the page title,
// subtitle, a 380 px search and the add-books action; a 184 px collection
// sidebar with Settings pinned to its bottom in wide windows; and a filter row
// carrying the same entries in compact windows. Neither layout has a drawer.
//
// Two deliberate differences from the reference, both recorded in the package
// report:
//
// * The CBZ entry is the retained Flutter extension of Iced's All/EPUB/PDF
//   entries (plan decision 9). Five entries cannot share one equal-width row at
//   390 px without truncating "Settings", so the compact row sizes its entries
//   to their labels instead of filling the width; at 200% text it wraps onto a
//   second line rather than clipping or hiding an entry.
// * Refresh is a retained Flutter capability with no Iced counterpart in the
//   library header. It stays reachable as a header action.
//
// Every control here renders immutable [LibraryModel] state and dispatches a
// typed message; no widget owns an effect.

/// The library header: title, subtitle, constrained search and the add-books
/// action.
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
    required this.canCancelOperation,
    required this.onQueryChanged,
    required this.onImportRequested,
    required this.onImportCancelled,
    required this.onOperationCancelled,
    required this.onRefresh,
  });

  final bool compact;
  final LibraryModel model;

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
    final title = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 2,
      children: [
        Text('Library', style: Theme.of(context).textTheme.headlineMedium),
        Text(
          'Your private reading room',
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
        placeholder: const Text(
          'Search title or author',
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
        if (canCancelOperation)
          ShadIconAction(
            tooltip: 'Cancel operation',
            onPressed: onOperationCancelled,
            icon: const Icon(LucideIcons.x),
          ),
        ShadIconAction(
          tooltip: 'Refresh library',
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
          _LibraryActivityBar(active: model.busy),
        ],
      ),
    );
  }

  /// The add-books action, or the cancel action while the import is in flight.
  ///
  /// The action keeps the reference's primary button geometry
  /// (`app.button.primary`) and its opaque hovered fill instead of the Shad
  /// primary variant's translucent one. That fill is a pinned light-theme
  /// value, so the dark theme keeps its own variant behavior: overriding only
  /// the background there would leave the theme's dark label on a dark fill.
  Widget _addBooksAction(BuildContext context) {
    const padding = EdgeInsets.symmetric(
      vertical: ShosaiTokens.layoutButtonPrimaryPaddingVertical,
      horizontal: ShosaiTokens.layoutButtonPrimaryPaddingHorizontal,
    );
    final theme = ShadTheme.of(context);
    final height = shosaiShadButtonHeight(context, padding: padding);
    final hover = theme.brightness == Brightness.dark
        ? null
        : ShosaiTokens.appAccentHovered;
    if (model.importing) {
      return ShadButton(
        height: height,
        padding: padding,
        hoverBackgroundColor: hover,
        pressedBackgroundColor: hover,
        onPressed: onImportCancelled,
        leading: const Icon(LucideIcons.x),
        child: const Text('Cancel'),
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
      child: const Text('Add books'),
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

/// The wide layout's collection sidebar.
///
/// The format entries sit in a group under the `COLLECTION` label and Settings
/// is pinned to the bottom, as in the reference. It is not a drawer and is
/// never shown in compact windows.
class LibrarySidebar extends StatelessWidget {
  const LibrarySidebar({
    super.key,
    required this.model,
    required this.onFormatChanged,
    required this.onSettingsRequested,
  });

  final LibraryModel model;
  final ValueChanged<FlutterBookFormat?> onFormatChanged;
  final VoidCallback? onSettingsRequested;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final scheme = theme.colorScheme;
    final group = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 6,
      children: [
        Text(
          'COLLECTION',
          style: Theme.of(
            context,
          ).textTheme.labelSmall?.copyWith(color: scheme.mutedForeground),
        ),
        ..._libraryFormatEntries(
          model: model,
          allLabel: 'All books',
          onFormatChanged: onFormatChanged,
          fillWidth: true,
        ),
      ],
    );
    final settings = LibraryNavigationButton(
      label: 'Settings',
      selected: false,
      onPressed: onSettingsRequested,
      fillWidth: true,
    );
    return Container(
      width: ShosaiTokens.layoutLibrarySidebarWidth,
      // The pinned Iced sidebar surface has no dark counterpart in the token
      // source, so the retained dark palette's raised surface stands in for it.
      color: theme.brightness == Brightness.dark
          ? scheme.secondary
          : ShosaiTokens.appSidebarBackground,
      // Settings stays pinned to the bottom while the sidebar has room for it
      // and scrolls into reach when a short window does not. The padding sits
      // inside the scroll view: a padded viewport would be narrower than the
      // entries and would clip the focus ring they paint outside themselves.
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: IntrinsicHeight(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  vertical: 22,
                  horizontal: 14,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 12,
                  children: [group, const Spacer(), settings],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The compact layout's filter row.
///
/// All/EPUB/PDF/CBZ and Settings stay directly reachable; the entries size to
/// their labels so every one of them stays readable, and the row wraps onto a
/// second line at large text instead of clipping or dropping an entry.
class LibraryFilterRow extends StatelessWidget {
  const LibraryFilterRow({
    super.key,
    required this.model,
    required this.onFormatChanged,
    required this.onSettingsRequested,
  });

  final LibraryModel model;
  final ValueChanged<FlutterBookFormat?> onFormatChanged;
  final VoidCallback? onSettingsRequested;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
    child: Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        ..._libraryFormatEntries(
          model: model,
          allLabel: 'All',
          onFormatChanged: onFormatChanged,
          fillWidth: false,
        ),
        LibraryNavigationButton(
          label: 'Settings',
          selected: false,
          onPressed: onSettingsRequested,
          fillWidth: false,
        ),
      ],
    ),
  );
}

/// One format entry per retained filter, in the reference's order.
///
/// `All` selects the unfiltered collection; CBZ is the retained Flutter
/// extension of the reference's All/EPUB/PDF entries.
List<Widget> _libraryFormatEntries({
  required LibraryModel model,
  required String allLabel,
  required ValueChanged<FlutterBookFormat?> onFormatChanged,
  required bool fillWidth,
}) => [
  for (final (filter, label) in <(FlutterBookFormat?, String)>[
    (null, allLabel),
    (FlutterBookFormat.epub, 'EPUB'),
    (FlutterBookFormat.pdf, 'PDF'),
    (FlutterBookFormat.cbz, 'CBZ'),
  ])
    LibraryNavigationButton(
      label: label,
      selected: model.format == filter,
      onPressed: () => onFormatChanged(filter),
      fillWidth: fillWidth,
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
