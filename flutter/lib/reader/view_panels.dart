part of 'view.dart';

// The reader's panels (`docs/design-system.md`, Overlays and panels):
//
// | Panel | Desktop | Tablet | Phone |
// | --- | --- | --- | --- |
// | Contents | Popover under the Contents control | Popover | Bottom sheet |
// | Display settings | Popover under Aa | Popover | Bottom sheet |
// | Notes | Docked right at `panel-width` | Over the stage at the right | Bottom sheet |
//
// A popover or sheet floats over the stage, so opening one never lays the
// book out again; only the docked Notes panel narrows the stage.

/// How an open panel is shown.
enum _ReaderPanelPresentation { popover, sheet, side, docked }

_ReaderPanelPresentation _readerPanelPresentation(
  ReaderPanel panel,
  ShellLayout layout,
) => switch ((panel, layout)) {
  (_, ShellLayout.phone) => _ReaderPanelPresentation.sheet,
  (ReaderPanel.notes, ShellLayout.desktop) => _ReaderPanelPresentation.docked,
  (ReaderPanel.notes, _) => _ReaderPanelPresentation.side,
  _ => _ReaderPanelPresentation.popover,
};

/// The popover width of [panel]: `panel-width` for Contents, the 288 px
/// `sh-popover` for Display settings.
double _readerPopoverWidth(ReaderPanel panel) =>
    panel == ReaderPanel.contents ? ShosaiTokens.sizePanelWidth : 288;

/// `shadow-modal`: popovers, sheets and dialogs over the page.
List<BoxShadow> _readerModalShadow(ShellPalette palette) => [
  BoxShadow(
    color: palette.shadowBase.withValues(alpha: palette.dark ? .8 : .4),
    offset: const Offset(0, 24),
    blurRadius: 60,
    spreadRadius: -20,
  ),
  BoxShadow(
    color: palette.dark
        ? ShosaiTokens.colorDarkInk.withValues(alpha: .08)
        : palette.shadowBase.withValues(alpha: .08),
    spreadRadius: 1,
  ),
];

/// The open panel over the stage: a scrim that closes it and the panel
/// placed for its presentation. Empty when no floating panel is open.
List<Widget> _readerPanelOverlay({
  required ReaderModel model,
  required ShellLayout layout,
  required BoxConstraints stage,
  required void Function(ReaderMessage) dispatch,
  required FocusNode focusNode,
  required Map<ReaderPanel, Key> hostKeys,
}) {
  final panel = model.openPanel;
  if (panel == null) return const [];
  final presentation = _readerPanelPresentation(panel, layout);
  if (presentation == _ReaderPanelPresentation.docked) return const [];
  final host = _ReaderPanelHost(
    key: hostKeys[panel],
    panel: panel,
    presentation: presentation,
    model: model,
    dispatch: dispatch,
    focusNode: focusNode,
  );
  final inset = ShosaiTokens.space2;
  final maxHeight = math.max(0.0, stage.maxHeight - 2 * inset);
  return [
    Positioned.fill(
      child: GestureDetector(
        key: const ValueKey('reader-panel-scrim'),
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        onTap: () => dispatch(ReaderPanelToggled(panel)),
        child: presentation == _ReaderPanelPresentation.sheet
            ? ColoredBox(
                color: ShosaiTokens.colorLightInverse.withValues(alpha: .28),
              )
            : const SizedBox.expand(),
      ),
    ),
    switch (presentation) {
      _ReaderPanelPresentation.sheet => Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: stage.maxHeight * .8),
          child: host,
        ),
      ),
      _ReaderPanelPresentation.side => Positioned(
        top: 0,
        right: 0,
        bottom: 0,
        width: math.min(ShosaiTokens.sizePanelWidth, stage.maxWidth),
        child: host,
      ),
      _ => Positioned(
        top: inset,
        left: panel == ReaderPanel.contents ? inset : null,
        right: panel == ReaderPanel.contents ? null : inset,
        width: math.min(_readerPopoverWidth(panel), stage.maxWidth - 2 * inset),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: host,
        ),
      ),
    },
  ];
}

/// The reader panel host: one labelled container for the open panel (RD-13).
///
/// The host owns the panel's surface for its presentation, its focus and
/// Escape; the bodies own their content.
class _ReaderPanelHost extends StatelessWidget {
  const _ReaderPanelHost({
    super.key,
    required this.panel,
    required this.presentation,
    required this.model,
    required this.dispatch,
    required this.focusNode,
  });

  final ReaderPanel panel;
  final _ReaderPanelPresentation presentation;
  final ReaderModel model;
  final void Function(ReaderMessage) dispatch;
  final FocusNode focusNode;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final palette = ShellPalette.of(context);
    final label = switch (panel) {
      ReaderPanel.contents => l10n.readerContentsAction,
      ReaderPanel.typography => l10n.readerAppearanceAction,
      ReaderPanel.notes => l10n.readerNotesAction,
    };
    final body = switch (panel) {
      ReaderPanel.contents => _ReaderContentsPanel(
        model: model,
        dispatch: dispatch,
      ),
      ReaderPanel.typography => _ReaderDisplayPanel(
        model: model,
        dispatch: dispatch,
      ),
      ReaderPanel.notes => _ReaderNotesPanel(model: model, dispatch: dispatch),
    };
    final decoration = switch (presentation) {
      _ReaderPanelPresentation.popover => BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(ShosaiTokens.radiusMd),
        boxShadow: _readerModalShadow(palette),
      ),
      _ReaderPanelPresentation.sheet => BoxDecoration(
        color: palette.chrome,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(ShosaiTokens.radiusLg),
        ),
        boxShadow: _readerModalShadow(palette),
      ),
      _ReaderPanelPresentation.side => BoxDecoration(
        color: palette.chrome,
        border: Border(left: BorderSide(color: palette.line)),
        boxShadow: _readerModalShadow(palette),
      ),
      _ReaderPanelPresentation.docked => BoxDecoration(
        color: palette.chrome,
        border: Border(left: BorderSide(color: palette.line)),
      ),
    };
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            dispatch(ReaderPanelToggled(panel)),
      },
      child: Focus(
        focusNode: focusNode,
        child: Semantics(
          key: ValueKey('reader-panel-${panel.name}'),
          container: true,
          label: label,
          // A floating panel is dismissed like the scrim around it.
          onDismiss: presentation == _ReaderPanelPresentation.docked
              ? null
              : () => dispatch(ReaderPanelToggled(panel)),
          child: Material(
            type: MaterialType.transparency,
            child: DecoratedBox(
              decoration: decoration,
              child: ClipRRect(
                borderRadius:
                    decoration.borderRadius?.resolve(
                      Directionality.of(context),
                    ) ??
                    BorderRadius.zero,
                child: Column(
                  mainAxisSize:
                      presentation == _ReaderPanelPresentation.popover ||
                          presentation == _ReaderPanelPresentation.sheet
                      ? MainAxisSize.min
                      : MainAxisSize.max,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (presentation == _ReaderPanelPresentation.sheet)
                      Center(
                        child: Container(
                          width: 36,
                          height: 4,
                          margin: const EdgeInsets.only(
                            top: ShosaiTokens.space2,
                            bottom: ShosaiTokens.space1,
                          ),
                          decoration: BoxDecoration(
                            color: palette.lineStrong.withValues(alpha: .6),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                    Flexible(
                      fit:
                          presentation == _ReaderPanelPresentation.popover ||
                              presentation == _ReaderPanelPresentation.sheet
                          ? FlexFit.loose
                          : FlexFit.tight,
                      child: body,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A panel's heading row: the title in the editorial serif, any actions, then
/// a close control.
class _ReaderPanelHeading extends StatelessWidget {
  const _ReaderPanelHeading({
    required this.headingKey,
    required this.title,
    required this.closeKey,
    required this.closeLabel,
    required this.onClose,
    this.actions = const [],
  });

  final Key headingKey;
  final String title;
  final Key closeKey;
  final String closeLabel;
  final VoidCallback onClose;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final palette = ShellPalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        ShosaiTokens.space4,
        ShosaiTokens.space3,
        ShosaiTokens.space2,
        ShosaiTokens.space2,
      ),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              header: true,
              child: Text(
                title,
                key: headingKey,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: shellEditorialStyle(20, 24).copyWith(color: palette.ink),
              ),
            ),
          ),
          ...actions,
          _ReaderToolButton(
            key: closeKey,
            icon: LucideIcons.x,
            label: closeLabel,
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

/// A small uppercase group label inside a panel (`sh-panel__group`).
class _ReaderPanelGroup extends StatelessWidget {
  const _ReaderPanelGroup({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      ShosaiTokens.space1,
      ShosaiTokens.space2,
      ShosaiTokens.space1,
      0,
    ),
    child: Text(
      text.toUpperCase(),
      style: shellInterfaceStyle(
        11,
        14,
        weight: FontWeight.w600,
      ).copyWith(color: ShellPalette.of(context).inkMuted, letterSpacing: .88),
    ),
  );
}

/// The height, at 100% text, below which the Contents panel scrolls as a
/// whole: its heading, a few chapter rows, and the page field with its error.
const double _contentsPanelMinHeight = 200;

/// The Contents panel: the chapter list and the book's bookmarks, then a
/// field to go to a page (RD-07, RD-08, RD-10).
class _ReaderContentsPanel extends StatefulWidget {
  const _ReaderContentsPanel({required this.model, required this.dispatch});

  final ReaderModel model;
  final void Function(ReaderMessage) dispatch;

  @override
  State<_ReaderContentsPanel> createState() => _ReaderContentsPanelState();
}

class _ReaderContentsPanelState extends State<_ReaderContentsPanel> {
  /// The current entry's key, so the panel can reveal it when it opens.
  final GlobalKey _currentEntryKey = GlobalKey(debugLabel: 'contents-current');
  bool _revealed = false;
  bool _revealScheduled = false;
  late final TextEditingController _pageInput = TextEditingController(
    text: widget.model.pageInput.draft,
  );

  @override
  void didUpdateWidget(_ReaderContentsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final draft = widget.model.pageInput.draft;
    if (draft != _pageInput.text) _pageInput.text = draft;
  }

  @override
  void dispose() {
    _pageInput.dispose();
    super.dispose();
  }

  /// Reveals the current entry once, after the ready rows are laid out.
  ///
  /// The rows are created by the build that first sees ready contents, so their
  /// context cannot be resolved during that build; the post-frame callback runs
  /// after they are mounted. This is a local scroll of the panel's own list,
  /// not a controller effect, and it does not move focus.
  void _scheduleReveal() {
    if (_revealed || _revealScheduled) return;
    _revealScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _revealScheduled = false;
      if (!mounted || _revealed) return;
      final target = _currentEntryKey.currentContext;
      if (target == null) return;
      _revealed = true;
      Scrollable.ensureVisible(target, duration: Duration.zero, alignment: 0);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final palette = ShellPalette.of(context);
    final model = widget.model;
    final dispatch = widget.dispatch;
    final contents = model.contents;
    if (contents.status == ReaderContentsStatus.ready &&
        contents.entries.any((entry) => entry.current)) {
      _scheduleReveal();
    }
    // At ordinary heights only the chapter list scrolls, between the heading
    // and the page field. In a short window (a scaled interface, a keyboard,
    // the page field's error) the panel keeps room for a few rows and scrolls
    // as a whole, so its heading and page field stay reachable. The tree is
    // the same either way, so the page field keeps its focus as the keyboard
    // opens.
    final minHeight =
        _contentsPanelMinHeight *
        math.max(1.0, MediaQuery.textScalerOf(context).scale(1));
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        key: const ValueKey('reader-contents-panel-scroll'),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: math.max(constraints.maxHeight, minHeight),
          ),
          child: _panelColumn(l10n, palette, model, contents, dispatch),
        ),
      ),
    );
  }

  Widget _panelColumn(
    AppLocalizations l10n,
    ShellPalette palette,
    ReaderModel model,
    ReaderContentsPresentation contents,
    void Function(ReaderMessage) dispatch,
  ) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ReaderPanelHeading(
          headingKey: const ValueKey('reader-contents-heading'),
          title: l10n.readerContentsAction,
          closeKey: const ValueKey('reader-contents-close'),
          closeLabel: l10n.readerCloseContents,
          onClose: () =>
              dispatch(const ReaderPanelToggled(ReaderPanel.contents)),
        ),
        Flexible(
          child: SingleChildScrollView(
            key: const ValueKey('reader-contents-scroll'),
            padding: const EdgeInsets.fromLTRB(
              ShosaiTokens.space2,
              0,
              ShosaiTokens.space2,
              ShosaiTokens.space2,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ..._chapterSection(l10n, contents, dispatch),
                // The book's bookmarks follow its chapters; notes have their
                // own panel (RFD 6).
                if (model.document?.bookId != null) ...[
                  const SizedBox(height: ShosaiTokens.space2),
                  _ReaderPanelGroup(
                    key: const ValueKey('reader-contents-bookmarks-count'),
                    text: l10n.readerBookmarksHeading(model.bookmarks.length),
                  ),
                  const SizedBox(height: ShosaiTokens.space2),
                  ...[
                    for (final row in _readerBookmarkRows(
                      context,
                      l10n,
                      model,
                      dispatch,
                    ))
                      Padding(
                        padding: const EdgeInsets.only(
                          bottom: ShosaiTokens.space2,
                        ),
                        child: row,
                      ),
                  ],
                ],
              ],
            ),
          ),
        ),
        if (model.document case final document?)
          DecoratedBox(
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: palette.line)),
            ),
            child: Padding(
              padding: const EdgeInsets.all(ShosaiTokens.space3),
              child: _pageField(l10n, palette, model, document, dispatch),
            ),
          ),
      ],
    );
  }

  Widget _pageField(
    AppLocalizations l10n,
    ShellPalette palette,
    ReaderModel model,
    FlutterDocumentSummary document,
    void Function(ReaderMessage) dispatch,
  ) {
    final total = document.logicalUnitCount.toInt();
    final busy = model.busy || model.relayoutBusy;
    final muted = shellInterfaceStyle(12, 16).copyWith(color: palette.inkMuted);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          spacing: ShosaiTokens.space2,
          children: [
            Text(
              l10n.readerGoToPage,
              style: shellInterfaceStyle(
                12,
                16,
                weight: FontWeight.w600,
              ).copyWith(color: palette.ink),
            ),
            SizedBox(
              width: 72,
              child: ShadInput(
                key: const ValueKey('reader-page-input'),
                controller: _pageInput,
                enabled: !busy,
                padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
                placeholder: Text(l10n.readerPageInputLabel),
                keyboardType: TextInputType.number,
                textInputAction: TextInputAction.go,
                onChanged: (value) => dispatch(ReaderPageInputChanged(value)),
                onSubmitted: (_) => dispatch(const ReaderPageInputSubmitted()),
              ),
            ),
            Flexible(
              child: Text(
                l10n.readerPageOf(total),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: muted,
              ),
            ),
          ],
        ),
        if (model.pageInput.error != null)
          Padding(
            padding: const EdgeInsets.only(top: ShosaiTokens.space1),
            child: Semantics(
              key: const ValueKey('reader-page-input-error'),
              liveRegion: true,
              child: Text(
                l10n.readerPageInputInvalid(total),
                style: shellInterfaceStyle(
                  12,
                  16,
                ).copyWith(color: ShosaiTokens.appDanger),
              ),
            ),
          ),
      ],
    );
  }

  /// The chapter rows for the current [ReaderContentsPresentation].
  List<Widget> _chapterSection(
    AppLocalizations l10n,
    ReaderContentsPresentation contents,
    void Function(ReaderMessage) dispatch,
  ) => switch (contents.status) {
    ReaderContentsStatus.loading => [
      _ReaderPanelNote(text: l10n.readerContentsLoading),
    ],
    ReaderContentsStatus.empty => [
      _ReaderPanelNote(text: l10n.readerContentsEmpty),
    ],
    ReaderContentsStatus.failed => [
      _ReaderPanelNote(
        key: const ValueKey('reader-contents-error'),
        text: contents.error ?? l10n.readerContentsUnavailable,
        danger: true,
        liveRegion: true,
      ),
      const SizedBox(height: ShosaiTokens.space2),
      Align(
        alignment: Alignment.centerLeft,
        child: _ReaderAlertAction(
          key: const ValueKey('reader-contents-retry'),
          label: l10n.readerRetry,
          contentSized: true,
          onPressed: () => dispatch(const ReaderContentsRequested()),
        ),
      ),
    ],
    ReaderContentsStatus.ready => _chapterRows(l10n, contents, dispatch),
  };

  /// The ready-state chapter rows.
  ///
  /// A real table of contents can name one chapter several times, so the row
  /// key carries the entry's occurrence within its unit: the first row of a
  /// unit keeps the historical `reader-contents-entry-<unit>` key, and later
  /// rows are suffixed. Duplicate sibling keys are a widget error, and the
  /// reveal key must stay unique as well.
  List<Widget> _chapterRows(
    AppLocalizations l10n,
    ReaderContentsPresentation contents,
    void Function(ReaderMessage) dispatch,
  ) {
    final occurrences = <int, int>{};
    return [
      for (final entry in contents.entries)
        KeyedSubtree(
          key: entry.current ? _currentEntryKey : null,
          child: _ReaderChapterRow(
            entryKey: switch ((occurrences[entry.unit] =
                (occurrences[entry.unit] ?? 0) + 1)) {
              1 => 'reader-contents-entry-${entry.unit}',
              final occurrence =>
                'reader-contents-entry-${entry.unit}-$occurrence',
            },
            entry: entry,
            label: entry.title.trim().isEmpty
                ? l10n.readerChapterNumber(entry.unit + 1)
                : entry.title.trim(),
            dispatch: dispatch,
          ),
        ),
    ];
  }
}

/// One chapter row (RD-07): indented by level, the current entry set in
/// semibold on the hover ground.
class _ReaderChapterRow extends StatelessWidget {
  const _ReaderChapterRow({
    required this.entryKey,
    required this.entry,
    required this.label,
    required this.dispatch,
  });

  /// The row's unique key within the chapter list.
  final String entryKey;
  final ReaderContentsEntry entry;
  final String label;
  final void Function(ReaderMessage) dispatch;

  @override
  Widget build(BuildContext context) {
    final palette = ShellPalette.of(context);
    void open() =>
        dispatch(ReaderLocationNavigated(entry.unit, offset: entry.offset));
    final style = shellInterfaceStyle(
      13,
      18,
      weight: entry.current ? FontWeight.w600 : FontWeight.w400,
    ).copyWith(color: palette.ink);
    final radius = BorderRadius.circular(ShosaiTokens.radiusSm);
    return _readerSemanticButton(
      key: ValueKey(entryKey),
      enabled: true,
      selected: entry.current,
      label: label,
      onPressed: open,
      // A long title wraps to a second line, so the row is an ink well that
      // grows with its text rather than a fixed-height button.
      child: Material(
        type: MaterialType.transparency,
        child: Ink(
          decoration: BoxDecoration(
            color: entry.current ? palette.hover : null,
            borderRadius: radius,
          ),
          child: InkWell(
            borderRadius: radius,
            hoverColor: palette.hover,
            splashFactory: NoSplash.splashFactory,
            onTap: open,
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                ShosaiTokens.space2 +
                    entry.depth * ShosaiTokens.layoutReaderPanelEntryIndent,
                7,
                ShosaiTokens.space2,
                7,
              ),
              child: Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: style,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The Display settings panel (RD-09): the page theme, then text size and
/// line spacing for EPUB or zoom for PDF.
///
/// The controls are disabled while a relayout is in flight; a failed relayout
/// reports through the shared error surface.
class _ReaderDisplayPanel extends StatelessWidget {
  const _ReaderDisplayPanel({required this.model, required this.dispatch});

  final ReaderModel model;
  final void Function(ReaderMessage) dispatch;

  /// The default EPUB text size; the stepper shows sizes as a share of it.
  static const double baseFontSize = 18;
  static const int minTextPercent = 70;
  static const int maxTextPercent = 160;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final typography = model.typography;
    final enabled =
        model.document != null && !model.busy && !model.relayoutBusy;
    final percent =
        ((typography.epubFontSize / baseFontSize * 100) / 10).round() * 10;
    void textSize(int next) =>
        dispatch(ReaderTypographyChanged(fontSize: baseFontSize * next / 100));
    final spacing = typography.epubLineSpacing;
    final spacingIndex = _readerLineSpacingSteps.indexWhere(
      (step) => step >= spacing - .001,
    );
    return SingleChildScrollView(
      padding: const EdgeInsets.all(ShosaiTokens.space4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: ShosaiTokens.space3,
        children: [
          _ReaderField(
            label: l10n.readerPageTheme,
            child: Row(
              spacing: ShosaiTokens.space2,
              children: [
                for (final theme in _readerThemes)
                  Expanded(
                    child: _ReaderThemeTile(
                      theme: theme,
                      label: _readerThemeLabel(l10n, theme),
                      selected: typography.theme == theme,
                      onPressed: enabled
                          ? () =>
                                dispatch(ReaderTypographyChanged(theme: theme))
                          : null,
                    ),
                  ),
              ],
            ),
          ),
          if (typography.reflowable) ...[
            _ReaderField(
              label: l10n.readerTextSize,
              hint: l10n.readerTextSizeHint,
              child: _ReaderStepper(
                decreaseKey: const ValueKey('reader-typography-font-decrease'),
                increaseKey: const ValueKey('reader-typography-font-increase'),
                decreaseLabel: l10n.readerDecreaseFontSize,
                increaseLabel: l10n.readerIncreaseFontSize,
                value: '$percent%',
                onDecrease: enabled && percent > minTextPercent
                    ? () => textSize(percent - 10)
                    : null,
                onIncrease: enabled && percent < maxTextPercent
                    ? () => textSize(percent + 10)
                    : null,
              ),
            ),
            _ReaderField(
              label: l10n.readerLineSpacingLabel,
              child: _ReaderStepper(
                decreaseKey: const ValueKey(
                  'reader-typography-line-spacing-decrease',
                ),
                increaseKey: const ValueKey(
                  'reader-typography-line-spacing-increase',
                ),
                decreaseLabel: l10n.readerLineSpacingLabel,
                increaseLabel: l10n.readerLineSpacingLabel,
                value: l10n.readerLineSpacingValue(spacing.toStringAsFixed(1)),
                onDecrease: enabled && spacingIndex > 0
                    ? () => dispatch(
                        ReaderTypographyChanged(
                          lineSpacing:
                              _readerLineSpacingSteps[spacingIndex - 1],
                        ),
                      )
                    : null,
                onIncrease:
                    enabled &&
                        spacingIndex >= 0 &&
                        spacingIndex < _readerLineSpacingSteps.length - 1
                    ? () => dispatch(
                        ReaderTypographyChanged(
                          lineSpacing:
                              _readerLineSpacingSteps[spacingIndex + 1],
                        ),
                      )
                    : null,
              ),
            ),
          ] else
            _ReaderField(
              label: l10n.readerZoom,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: ShosaiTokens.space2,
                children: [
                  _ReaderSegmented(
                    segments: [
                      (
                        key: const ValueKey('reader-typography-fit-width'),
                        icon: null,
                        label: l10n.readerFitWidth,
                        selected:
                            typography.rasterFit == ReaderRasterFit.fitWidth,
                        onPressed: enabled
                            ? () => dispatch(
                                const ReaderTypographyChanged(
                                  rasterFit: ReaderRasterFit.fitWidth,
                                ),
                              )
                            : null,
                      ),
                      (
                        key: const ValueKey('reader-typography-fit-page'),
                        icon: null,
                        label: l10n.readerFitPage,
                        selected:
                            typography.rasterFit == ReaderRasterFit.fitPage,
                        onPressed: enabled
                            ? () => dispatch(
                                const ReaderTypographyChanged(
                                  rasterFit: ReaderRasterFit.fitPage,
                                ),
                              )
                            : null,
                      ),
                    ],
                  ),
                  _ReaderStepper(
                    decreaseKey: const ValueKey('reader-typography-zoom-out'),
                    increaseKey: const ValueKey('reader-typography-zoom-in'),
                    decreaseLabel: l10n.readerZoomOut,
                    increaseLabel: l10n.readerZoomIn,
                    value: '${(typography.rasterZoom * 100).round()}%',
                    onDecrease: enabled
                        ? () => dispatch(
                            ReaderTypographyChanged(
                              zoom: typography.rasterZoom - 0.25,
                            ),
                          )
                        : null,
                    onIncrease: enabled
                        ? () => dispatch(
                            ReaderTypographyChanged(
                              zoom: typography.rasterZoom + 0.25,
                            ),
                          )
                        : null,
                  ),
                ],
              ),
            ),
          // A phone in portrait never has room for two pages, so Pages is
          // hidden there.
          if (!_phonePortrait(context))
            _ReaderField(
              label: l10n.readerPages,
              hint: l10n.readerPagesHint,
              child: _ReaderSegmented(
                segments: [
                  (
                    key: const ValueKey('reader-typography-one-page'),
                    icon: LucideIcons.rectangleVertical,
                    label: l10n.readerOnePage,
                    selected: !typography.twoPages,
                    onPressed: enabled
                        ? () => dispatch(
                            const ReaderTypographyChanged(twoPages: false),
                          )
                        : null,
                  ),
                  (
                    key: const ValueKey('reader-typography-two-pages'),
                    icon: LucideIcons.columns2,
                    label: l10n.readerTwoPages,
                    selected: typography.twoPages,
                    onPressed: enabled
                        ? () => dispatch(
                            const ReaderTypographyChanged(twoPages: true),
                          )
                        : null,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// A labelled group of controls (`sh-field`).
class _ReaderField extends StatelessWidget {
  const _ReaderField({required this.label, required this.child, this.hint});

  final String label;
  final String? hint;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final palette = ShellPalette.of(context);
    final hint = this.hint;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: ShosaiTokens.space2,
      children: [
        Text(
          label,
          style: shellInterfaceStyle(
            12,
            16,
            weight: FontWeight.w600,
          ).copyWith(color: palette.ink),
        ),
        child,
        if (hint != null)
          Text(
            hint,
            style: shellInterfaceStyle(
              12,
              16,
            ).copyWith(color: palette.inkMuted),
          ),
      ],
    );
  }
}

/// Whether the reader is on a phone held upright, where Pages is hidden.
bool _phonePortrait(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  return ShellLayout.forWidth(size.width) == ShellLayout.phone &&
      size.height >= size.width;
}

/// One page theme as a tile in its own colours (`sh-theme`).
///
/// The tile is a keyboard control like the toolbar's buttons: it takes focus,
/// shows the 2 px `accent` focus ring and activates on Enter or Space.
class _ReaderThemeTile extends StatefulWidget {
  const _ReaderThemeTile({
    required this.theme,
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final String theme;
  final String label;
  final bool selected;
  final VoidCallback? onPressed;

  @override
  State<_ReaderThemeTile> createState() => _ReaderThemeTileState();
}

class _ReaderThemeTileState extends State<_ReaderThemeTile> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final label = widget.label;
    final selected = widget.selected;
    final onPressed = widget.onPressed;
    final palette = ShellPalette.of(context);
    final colors = pageColors(theme);
    final tile = AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      // At least the tile's height; a scaled interface grows it.
      constraints: const BoxConstraints(minHeight: 56),
      padding: const EdgeInsets.symmetric(vertical: ShosaiTokens.space1),
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(ShosaiTokens.radiusSm),
        border: Border.all(color: palette.line),
        boxShadow: selected
            ? [
                BoxShadow(color: palette.surface, spreadRadius: 2),
                BoxShadow(color: palette.accent, spreadRadius: 4),
              ]
            : null,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        spacing: 2,
        children: [
          Text(
            'Aa',
            style: TextStyle(
              fontFamily: ShosaiTokens.typeFamilyEditorialLatinFlutter,
              fontSize: 17,
              height: 1.1,
              fontWeight: FontWeight.w500,
              color: colors.foreground,
            ),
          ),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: shellInterfaceStyle(
              12,
              16,
            ).copyWith(color: colors.foreground),
          ),
        ],
      ),
    );
    return _readerSemanticButton(
      key: ValueKey('reader-typography-theme-$theme'),
      enabled: onPressed != null,
      selected: selected,
      label: label,
      onPressed: onPressed,
      child: FocusableActionDetector(
        enabled: onPressed != null,
        mouseCursor: onPressed == null
            ? MouseCursor.defer
            : SystemMouseCursors.click,
        onShowFocusHighlight: (focused) => setState(() => _focused = focused),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              onPressed?.call();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          excludeFromSemantics: true,
          onTap: onPressed,
          child: _readerFocusRing(
            focused: _focused && onPressed != null,
            color: palette.accent,
            radius: ShosaiTokens.radiusSm,
            child: tile,
          ),
        ),
      ),
    );
  }
}

/// A −/value/+ stepper (`sh-stepper`).
class _ReaderStepper extends StatelessWidget {
  const _ReaderStepper({
    required this.decreaseKey,
    required this.increaseKey,
    required this.decreaseLabel,
    required this.increaseLabel,
    required this.value,
    required this.onDecrease,
    required this.onIncrease,
  });

  final Key decreaseKey;
  final Key increaseKey;
  final String decreaseLabel;
  final String increaseLabel;
  final String value;
  final VoidCallback? onDecrease;
  final VoidCallback? onIncrease;

  @override
  Widget build(BuildContext context) {
    final palette = ShellPalette.of(context);
    Widget step(Key key, IconData icon, String label, VoidCallback? onPressed) {
      final ink = onPressed == null
          ? palette.inkMuted.withValues(alpha: .55)
          : palette.ink;
      return Tooltip(
        message: label,
        child: _readerSemanticButton(
          key: key,
          enabled: onPressed != null,
          label: label,
          onPressed: onPressed,
          child: ShadButton.raw(
            variant: ShadButtonVariant.outline,
            enabled: onPressed != null,
            width: ShosaiTokens.sizeControlHeight,
            height: ShosaiTokens.sizeControlHeight,
            padding: EdgeInsets.zero,
            backgroundColor: palette.surface,
            hoverBackgroundColor: palette.hover,
            pressedBackgroundColor: palette.hover,
            foregroundColor: ink,
            hoverForegroundColor: ink,
            decoration: ShadDecoration(
              border: ShadBorder.all(
                color: palette.lineStrong,
                radius: BorderRadius.circular(ShosaiTokens.radiusSm),
                width: 1,
              ),
            ),
            onPressed: onPressed,
            child: Icon(icon, size: 16, color: ink),
          ),
        ),
      );
    }

    return Row(
      spacing: ShosaiTokens.space2,
      children: [
        step(decreaseKey, LucideIcons.minus, decreaseLabel, onDecrease),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.center,
            style: shellInterfaceStyle(13, 18, weight: FontWeight.w500)
                .copyWith(
                  color: palette.ink,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
          ),
        ),
        step(increaseKey, LucideIcons.plus, increaseLabel, onIncrease),
      ],
    );
  }
}

/// A segmented choice (`sh-seg`).
class _ReaderSegmented extends StatelessWidget {
  const _ReaderSegmented({required this.segments});

  final List<
    ({
      Key key,
      IconData? icon,
      String label,
      bool selected,
      VoidCallback? onPressed,
    })
  >
  segments;

  @override
  Widget build(BuildContext context) {
    final palette = ShellPalette.of(context);
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: palette.surfaceSunken,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        spacing: 2,
        children: [
          for (final segment in segments)
            Expanded(
              child: _readerSemanticButton(
                key: segment.key,
                enabled: segment.onPressed != null,
                selected: segment.selected,
                label: segment.label,
                onPressed: segment.onPressed,
                child: ShadButton.raw(
                  variant: ShadButtonVariant.ghost,
                  enabled: segment.onPressed != null,
                  height: math.max(
                    28,
                    MediaQuery.textScalerOf(context).scale(16) + 8,
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: ShosaiTokens.space3,
                  ),
                  backgroundColor: segment.selected ? palette.surface : null,
                  hoverBackgroundColor: segment.selected
                      ? palette.surface
                      : palette.hover,
                  pressedBackgroundColor: palette.hover,
                  foregroundColor: segment.selected
                      ? palette.ink
                      : palette.inkMuted,
                  hoverForegroundColor: palette.ink,
                  decoration: ShadDecoration(
                    border: ShadBorder.all(
                      radius: BorderRadius.circular(ShosaiTokens.radiusSm),
                      width: 0,
                    ),
                  ),
                  onPressed: segment.onPressed,
                  leading: segment.icon == null
                      ? null
                      : Icon(
                          segment.icon,
                          size: 14,
                          color: segment.selected
                              ? palette.ink
                              : palette.inkMuted,
                        ),
                  child: Flexible(
                    child: Text(
                      segment.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          shellInterfaceStyle(
                            12,
                            16,
                            weight: FontWeight.w500,
                          ).copyWith(
                            color: segment.selected
                                ? palette.ink
                                : palette.inkMuted,
                          ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The book's saved places and the Markdown export action (RD-08), listed in
/// the Contents panel under the chapters.
List<Widget> _readerBookmarkRows(
  BuildContext context,
  AppLocalizations l10n,
  ReaderModel model,
  void Function(ReaderMessage) dispatch,
) {
  final palette = ShellPalette.of(context);
  if (model.bookmarks.isEmpty) {
    return [
      Padding(
        key: const ValueKey('reader-contents-empty'),
        padding: const EdgeInsets.symmetric(horizontal: ShosaiTokens.space1),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 2,
          children: [
            Text(
              l10n.readerNoBookmarks,
              style: shellInterfaceStyle(
                13,
                18,
                weight: FontWeight.w500,
              ).copyWith(color: palette.ink),
            ),
            Text(
              l10n.readerBookmarkEmptyHint,
              style: shellInterfaceStyle(
                12,
                16,
              ).copyWith(color: palette.inkMuted),
            ),
          ],
        ),
      ),
    ];
  }
  final exportFailed =
      model.exportState == ReaderExportState.failed &&
      model.exportError != null;
  return [
    for (final bookmark in model.bookmarks)
      _ReaderSavedPlaceRow(
        bookmark: bookmark,
        enabled: !model.bookmarkBusy,
        dispatch: dispatch,
      ),
    if (exportFailed)
      _ReaderPanelNote(
        key: const ValueKey('reader-bookmark-export-error'),
        text: model.exportError!,
        danger: true,
        liveRegion: true,
      ),
    Align(
      alignment: Alignment.centerLeft,
      child: _ReaderAlertAction(
        key: const ValueKey('reader-bookmark-export'),
        label: l10n.readerExportMarkdown,
        contentSized: true,
        onPressed:
            model.exportState == ReaderExportState.busy || model.bookmarkBusy
            ? null
            : () => dispatch(const ReaderBookmarkExportRequested()),
      ),
    ),
  ];
}

/// One saved place (RD-08): a card with the title, page, and delete action.
class _ReaderSavedPlaceRow extends StatelessWidget {
  const _ReaderSavedPlaceRow({
    required this.bookmark,
    required this.enabled,
    required this.dispatch,
  });

  final FlutterBookmark bookmark;
  final bool enabled;
  final void Function(ReaderMessage) dispatch;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final palette = ShellPalette.of(context);
    final page = bookmark.unit.toInt() + 1;
    final authored = bookmark.title?.trim();
    final title = authored == null || authored.isEmpty
        ? l10n.readerPageShort(page)
        : authored;
    return Container(
      key: ValueKey('reader-saved-place-${bookmark.id}'),
      padding: const EdgeInsets.all(ShosaiTokens.space2),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(ShosaiTokens.radiusMd),
        boxShadow: palette.raised,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Padding(
                padding: EdgeInsets.only(right: ShosaiTokens.space1),
                child: _FilledGlyph(
                  icon: LucideIcons.bookmark,
                  size: 14,
                  fill: ShosaiTokens.colorLightVermilion,
                ),
              ),
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: _ReaderLinkButton(
                    key: ValueKey('reader-saved-place-open-${bookmark.id}'),
                    label: title,
                    onPressed: enabled
                        ? () => dispatch(
                            ReaderBookmarkNavigated(
                              bookmark.unit.toInt(),
                              offset: bookmark.offset?.toInt(),
                            ),
                          )
                        : null,
                  ),
                ),
              ),
              Text(
                l10n.readerPageAbbreviated(page),
                style: shellInterfaceStyle(11, 14).copyWith(
                  color: palette.inkMuted,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              _ReaderToolButton(
                key: ValueKey('reader-saved-place-delete-${bookmark.id}'),
                icon: LucideIcons.x,
                label: l10n.readerDeleteBookmark(title),
                onPressed: enabled
                    ? () => dispatch(ReaderBookmarkDeleted(bookmark.id))
                    : null,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
