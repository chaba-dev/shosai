part of 'view.dart';

/// Provisional minimum readable tab label width (plan decision 11).
///
/// Decision 11 requires readable tab widths in the one horizontally scrollable
/// strip but does not fix a numeric floor, and 1A has not frozen one
/// (contract §9.2 item 2). This named constant is 4B's provisional floor: a
/// label never shrinks below it, so a short title still presents a readable
/// target. It is recorded, not presented as an approved design value, and the
/// owner or a 1A amendment replaces it. Both sides of it are rendered for
/// inspection (`reader-tab-overflow-*`).
const double readerTabMinLabelWidth = 120;

/// Characters a tab label keeps before it is ellipsized (Iced: 34).
const int readerTabLabelMaxChars = 34;

/// Truncates a reader label the way the pinned Iced reference does.
String _truncateReaderLabel(String label, int maxChars) {
  final characters = label.characters;
  if (characters.length <= maxChars) return label;
  return '${characters.take(maxChars - 1)}…';
}

/// Wraps a reader control so it keeps an accessible label *and* an activation
/// action.
///
/// The inner control's own semantics are excluded (its label is not localized
/// and would duplicate the wrapper's), so the wrapper has to supply the
/// activation action itself: a `button: true` node with a label but no `onTap`
/// is a named button a screen reader cannot activate. The action is gated the
/// same way the control is, so a disabled control has no tap action.
Widget _readerSemanticButton({
  Key? key,
  required bool enabled,
  bool? selected,
  required String label,
  required VoidCallback? onPressed,
  required Widget child,
}) => Semantics(
  key: key,
  button: true,
  enabled: enabled,
  selected: selected,
  label: label,
  onTap: onPressed,
  child: ExcludeSemantics(child: child),
);

/// The laid-out width of the reader back control at the current text scale.
///
/// Used only to decide how much room the header's action group may take before
/// it wraps; the control itself is laid out by Flutter.
double _readerBackActionWidth(BuildContext context, String label) {
  final painter = TextPainter(
    text: TextSpan(
      text: label,
      style: TextStyle(
        fontSize: ShosaiTokens.layoutButtonLabelSize,
        fontFamily: shosaiInterfaceFontForText(label),
        fontFamilyFallback: shosaiInterfaceFontFallback,
      ),
    ),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
  )..layout();
  final width = painter.width;
  painter.dispose();
  return width +
      2 * ShosaiTokens.layoutButtonSecondaryPaddingHorizontal +
      // A small margin so a rounding difference never re-introduces an
      // overflow; the extra space only makes the actions wrap earlier.
      4;
}

/// The reader tab strip (RD-03, RD-04).
///
/// One horizontally scrollable row: tabs never wrap and there is no overflow
/// menu. The active tab is revealed by the controller through
/// [ReaderTabRevealAdapter]; this widget only owns the scroll controller and
/// the per-tab keys that implement it.
class _ReaderTabStrip extends StatelessWidget {
  const _ReaderTabStrip({
    required this.model,
    required this.dispatch,
    required this.scrollController,
    required this.tabKey,
    required this.tabFocusNode,
    required this.tabCloseFocusNode,
  });

  final ReaderModel model;
  final void Function(ReaderMessage) dispatch;
  final ScrollController scrollController;
  final GlobalKey Function(String tabId) tabKey;
  final FocusNode Function(String tabId) tabFocusNode;
  final FocusNode Function(String tabId) tabCloseFocusNode;

  @override
  Widget build(BuildContext context) {
    final tabs = model.tabs;
    if (tabs.isEmpty) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context);
    return Semantics(
      container: true,
      label: l10n.readerTabsLabel,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: ShosaiTokens.appTabStripBackground,
          border: Border.all(color: ShosaiTokens.appBorder),
        ),
        // The strip viewport (not the unbounded scroll child) bounds a
        // complete tab, so the active tab and its close control can always be
        // revealed fully (RD-04, decision 11). A label ellipsizes inside the
        // room the close control leaves; the provisional readable minimum
        // applies while it fits.
        child: LayoutBuilder(
          builder: (context, constraints) {
            final tabMaxWidth = math.max(
              readerTabMinLabelWidth,
              constraints.maxWidth -
                  2 * ShosaiTokens.layoutReaderChromeTabStripPaddingHorizontal,
            );
            return SingleChildScrollView(
              key: const ValueKey('reader-tab-strip-scroll'),
              controller: scrollController,
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(
                vertical:
                    ShosaiTokens.layoutReaderChromeTabStripPaddingVertical,
                horizontal:
                    ShosaiTokens.layoutReaderChromeTabStripPaddingHorizontal,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var index = 0; index < tabs.length; index += 1) ...[
                    if (index > 0)
                      const SizedBox(
                        width: ShosaiTokens.layoutReaderChromeTabStripSpacing,
                      ),
                    _ReaderTab(
                      key: tabKey(tabs[index].id),
                      tab: tabs[index],
                      dispatch: dispatch,
                      focusNode: tabFocusNode(tabs[index].id),
                      closeFocusNode: tabCloseFocusNode(tabs[index].id),
                      maxWidth: tabMaxWidth,
                    ),
                  ],
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// One tab: its label and its always-present close control (RD-03).
class _ReaderTab extends StatelessWidget {
  const _ReaderTab({
    super.key,
    required this.tab,
    required this.dispatch,
    required this.focusNode,
    required this.maxWidth,
    required this.closeFocusNode,
  });

  final ReaderTabPresentation tab;
  final void Function(ReaderMessage) dispatch;
  final FocusNode focusNode;
  final FocusNode closeFocusNode;

  /// Upper bound for the complete tab (label + close control), from the strip
  /// viewport.
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = ShadTheme.of(context).colorScheme;
    final selected = tab.selected;
    final label = _truncateReaderLabel(tab.title, readerTabLabelMaxChars);
    final labelStyle = shosaiInterfaceStyleForText(
      TextStyle(
        fontSize: ShosaiTokens.typeSize12,
        color: selected ? scheme.accentForeground : scheme.mutedForeground,
      ),
      label,
    );
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: selected ? ShosaiTokens.appSurface : null,
          border: selected ? Border.all(color: ShosaiTokens.appBorder) : null,
          borderRadius: BorderRadius.circular(ShosaiTokens.radiusSmall),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Loose: the label takes the room the close control leaves and
            // ellipsizes inside it; the readable floor applies while it fits.
            Flexible(
              child: _readerSemanticButton(
                key: ValueKey('reader-tab-${tab.id}'),
                enabled: true,
                selected: selected,
                label: tab.title,
                onPressed: () => dispatch(ReaderTabActivated(tab.id)),
                child: ShadButton.raw(
                  variant: ShadButtonVariant.ghost,
                  focusNode: focusNode,
                  height: shosaiShadButtonHeight(
                    context,
                    padding: const EdgeInsets.only(
                      top: ShosaiTokens.layoutReaderChromeTabPaddingVertical,
                      right:
                          ShosaiTokens.layoutReaderChromeTabLabelPaddingRight,
                      bottom: ShosaiTokens.layoutReaderChromeTabPaddingVertical,
                      left: ShosaiTokens.layoutReaderChromeTabLabelPaddingLeft,
                    ),
                  ),
                  padding: const EdgeInsets.only(
                    top: ShosaiTokens.layoutReaderChromeTabPaddingVertical,
                    right: ShosaiTokens.layoutReaderChromeTabLabelPaddingRight,
                    bottom: ShosaiTokens.layoutReaderChromeTabPaddingVertical,
                    left: ShosaiTokens.layoutReaderChromeTabLabelPaddingLeft,
                  ),
                  backgroundColor: selected ? scheme.selection : null,
                  hoverBackgroundColor: scheme.muted,
                  pressedBackgroundColor: scheme.muted,
                  foregroundColor: labelStyle.color,
                  hoverForegroundColor: labelStyle.color,
                  onPressed: () => dispatch(ReaderTabActivated(tab.id)),
                  // Flexible *inside* the button as well: a Shad button lays its
                  // content out in a Row whose non-flexible children get an
                  // unbounded width, so the label ellipsizes instead of
                  // overflowing the bounded tab.
                  child: Flexible(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        minWidth: readerTabMinLabelWidth,
                      ),
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: labelStyle,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            _readerSemanticButton(
              key: ValueKey('reader-tab-close-${tab.id}'),
              enabled: true,
              label: l10n.readerCloseTab(tab.title),
              onPressed: () => dispatch(ReaderTabCloseRequested(tab.id)),
              child: ShadButton.raw(
                variant: ShadButtonVariant.ghost,
                focusNode: closeFocusNode,
                height: shosaiShadButtonHeight(
                  context,
                  padding: const EdgeInsets.only(
                    top: ShosaiTokens.layoutReaderChromeTabPaddingVertical,
                    right: ShosaiTokens.layoutReaderChromeTabClosePaddingRight,
                    bottom: ShosaiTokens.layoutReaderChromeTabPaddingVertical,
                    left: ShosaiTokens.layoutReaderChromeTabClosePaddingLeft,
                  ),
                ),
                padding: const EdgeInsets.only(
                  top: ShosaiTokens.layoutReaderChromeTabPaddingVertical,
                  right: ShosaiTokens.layoutReaderChromeTabClosePaddingRight,
                  bottom: ShosaiTokens.layoutReaderChromeTabPaddingVertical,
                  left: ShosaiTokens.layoutReaderChromeTabClosePaddingLeft,
                ),
                hoverBackgroundColor: scheme.muted,
                pressedBackgroundColor: scheme.muted,
                foregroundColor: scheme.mutedForeground,
                hoverForegroundColor: scheme.mutedForeground,
                onPressed: () => dispatch(ReaderTabCloseRequested(tab.id)),
                child: Text(
                  '×',
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: ShosaiTokens.typeSize12,
                    color: scheme.mutedForeground,
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

/// The reader header (RD-01, RD-02).
class _ReaderHeader extends StatelessWidget {
  const _ReaderHeader({
    required this.model,
    required this.compact,
    required this.dispatch,
    required this.backFocus,
    required this.contentsFocus,
    required this.typographyFocus,
    required this.moreFocus,
  });

  final ReaderModel model;
  final bool compact;
  final void Function(ReaderMessage) dispatch;
  final FocusNode backFocus;
  final FocusNode contentsFocus;
  final FocusNode typographyFocus;
  final FocusNode moreFocus;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final title = model.document?.title ?? l10n.readerFallbackTitle;
    final label = _truncateReaderLabel(title, compact ? 24 : 58);
    // Controls that would start another modal or another open are disabled
    // while one is active (contract §3.1, §5.1).
    final enabled =
        model.document != null &&
        !model.busy &&
        !model.relayoutBusy &&
        model.modalEffect == null;
    final spacing = compact
        ? ShosaiTokens.layoutReaderChromeHeaderSpacingCompact
        : ShosaiTokens.layoutReaderChromeHeaderSpacingWide;
    final titleStyle = shosaiInterfaceStyleForText(
      TextStyle(
        fontSize: compact
            ? ShosaiTokens.typeReaderTitleCompact
            : ShosaiTokens.typeReaderTitleWide,
        color: ShosaiTokens.appText,
      ),
      label,
    );
    final titleWidget = Semantics(
      key: const ValueKey('reader-header-title'),
      label: title,
      child: ExcludeSemantics(
        child: Text(
          label,
          textAlign: _stacksTitle(context) || !compact
              ? TextAlign.center
              : TextAlign.start,
          maxLines: compact ? 2 : 1,
          overflow: TextOverflow.ellipsis,
          style: titleStyle,
        ),
      ),
    );
    final actions = [
      _ReaderHeaderAction(
        key: const ValueKey('reader-header-contents'),
        label: l10n.readerContentsAction,
        semanticsLabel: l10n.readerContentsAction,
        selected: model.openPanel == ReaderPanel.contents,
        focusNode: contentsFocus,
        onPressed: enabled
            ? () => dispatch(const ReaderPanelToggled(ReaderPanel.contents))
            : null,
      ),
      _ReaderHeaderAction(
        key: const ValueKey('reader-header-typography'),
        label: 'Aa',
        semanticsLabel: l10n.readerAppearanceAction,
        selected: model.openPanel == ReaderPanel.typography,
        focusNode: typographyFocus,
        onPressed: enabled
            ? () => dispatch(const ReaderPanelToggled(ReaderPanel.typography))
            : null,
      ),
      _ReaderHeaderAction(
        key: const ValueKey('reader-header-more'),
        label: '⋯',
        semanticsLabel: l10n.readerMoreAction,
        selected: model.openPanel == ReaderPanel.more,
        focusNode: moreFocus,
        onPressed: enabled
            ? () => dispatch(const ReaderPanelToggled(ReaderPanel.more))
            : null,
      ),
      // The annotation-association recovery action has no Iced counterpart and
      // no home in the three-action reference header; 4B keeps the existing
      // Flutter capability rather than dropping it (its final home — a panel
      // or a recovery surface — is 4C/4D work).
      if (model.document != null &&
          model.document!.format != FlutterBookFormat.cbz)
        ShadIconAction(
          tooltip: model.annotationsReady
              ? 'Associate highlights from an earlier version…'
              : 'Retry loading highlights',
          onPressed: enabled && model.annotationOperations.isEmpty
              ? () => dispatch(
                  model.annotationsReady
                      ? const ReaderAnnotationAssociationRequested()
                      : const ReaderAnnotationReloadRequested(),
                )
              : null,
          icon: Icon(
            model.annotationsReady ? LucideIcons.link : LucideIcons.refreshCw,
          ),
        ),
    ];
    final back = _ReaderBackAction(
      label: l10n.readerBackToLibrary,
      focusNode: backFocus,
      onPressed: () => dispatch(const ReaderBackRequested()),
    );
    return DecoratedBox(
      decoration: const BoxDecoration(color: ShosaiTokens.appSurface),
      child: Padding(
        key: const ValueKey('reader-header'),
        padding: const EdgeInsets.symmetric(
          vertical: ShosaiTokens.layoutReaderChromeHeaderPaddingVertical,
          horizontal: ShosaiTokens.layoutReaderChromeHeaderPaddingHorizontal,
        ),
        child: _stacksTitle(context)
            // A scaled interface cannot keep the back control, a readable title
            // and three actions on one compact line without clipping one of
            // them, so the title moves to its own line instead (RD-02, `T200`).
            // The back control and the action group each take their own line
            // too: sharing one line would squeeze the action group down to the
            // few pixels the back control's scaled label leaves, which clips a
            // label instead of moving it (contract §5.4). Every line stays
            // bounded, so no control is ever squeezed below the line width.
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      // Loose so a viewport narrower than the scaled label
                      // ellipsizes the label rather than overflowing the row.
                      Flexible(child: back),
                    ],
                  ),
                  const SizedBox(height: 4),
                  // The action group takes its own line; the stretched column
                  // bounds it, and the runs align to the trailing edge.
                  Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 4,
                    runSpacing: 4,
                    children: actions,
                  ),
                  const SizedBox(height: 4),
                  titleWidget,
                ],
              )
            : LayoutBuilder(
                builder: (context, constraints) {
                  // The action group wraps among itself rather than clipping a
                  // label when a compact window cannot hold it (RD-02, `T200`).
                  // The room left for it is the row minus the back control,
                  // measured with the interface scale in force.
                  final actionsMaxWidth = math.max(
                    0.0,
                    constraints.maxWidth -
                        _readerBackActionWidth(
                          context,
                          l10n.readerBackToLibrary,
                        ) -
                        spacing * 2,
                  );
                  return Row(
                    children: [
                      back,
                      SizedBox(width: spacing),
                      Expanded(child: titleWidget),
                      SizedBox(width: spacing),
                      ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: actionsMaxWidth),
                        child: Wrap(
                          alignment: WrapAlignment.end,
                          spacing: 4,
                          runSpacing: 4,
                          children: actions,
                        ),
                      ),
                    ],
                  );
                },
              ),
      ),
    );
  }

  /// Whether the compact header stacks the title above its action row.
  ///
  /// The pinned reference composes the title inline with the actions at normal
  /// interface scale; at a scaled interface the row is allowed to wrap instead
  /// of clipping a label (contract §5.4).
  bool _stacksTitle(BuildContext context) =>
      compact && MediaQuery.textScalerOf(context).scale(1) > 1;
}

class _ReaderBackAction extends StatelessWidget {
  const _ReaderBackAction({
    required this.label,
    required this.focusNode,
    required this.onPressed,
  });

  final String label;
  final FocusNode focusNode;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final padding = const EdgeInsets.symmetric(
      vertical: ShosaiTokens.layoutButtonSecondaryPaddingVertical,
      horizontal: ShosaiTokens.layoutButtonSecondaryPaddingHorizontal,
    );
    final style = shosaiInterfaceStyleForText(
      TextStyle(
        fontSize: ShosaiTokens.layoutButtonLabelSize,
        color: ShosaiTokens.appText,
      ),
      label,
    );
    // The back control keeps its own (already localized) label semantics; it is
    // not wrapped, so the button's tap action stays intact.
    return ShadButton.outline(
      key: const ValueKey('reader-header-back'),
      focusNode: focusNode,
      height: shosaiShadButtonHeight(context, padding: padding),
      padding: padding,
      onPressed: onPressed,
      child: Flexible(
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: style,
        ),
      ),
    );
  }
}

/// A reader header action: a 13 px control button with a selected treatment.
class _ReaderHeaderAction extends StatelessWidget {
  const _ReaderHeaderAction({
    super.key,
    required this.label,
    required this.semanticsLabel,
    required this.selected,
    required this.focusNode,
    required this.onPressed,
  });

  final String label;
  final String semanticsLabel;
  final bool selected;
  final FocusNode focusNode;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = ShadTheme.of(context).colorScheme;
    final foreground = selected ? scheme.accentForeground : scheme.foreground;
    final padding = const EdgeInsets.symmetric(
      vertical: ShosaiTokens.layoutReaderChromeControlPaddingVertical,
      horizontal: ShosaiTokens.layoutReaderChromeControlPaddingHorizontal,
    );
    final style = shosaiInterfaceStyleForText(
      TextStyle(fontSize: ShosaiTokens.typeSize13, color: foreground),
      label,
    );
    return _readerSemanticButton(
      enabled: onPressed != null,
      selected: selected,
      label: semanticsLabel,
      onPressed: onPressed,
      child: ShadButton.raw(
        variant: ShadButtonVariant.ghost,
        focusNode: focusNode,
        enabled: onPressed != null,
        height: shosaiShadButtonHeight(context, padding: padding),
        padding: padding,
        backgroundColor: selected ? scheme.selection : null,
        hoverBackgroundColor: scheme.muted,
        pressedBackgroundColor: scheme.muted,
        foregroundColor: foreground,
        hoverForegroundColor: foreground,
        onPressed: onPressed,
        // A Shad button lays its content out in a Row whose non-flexible
        // children get an unbounded width; the label must be flexible so a
        // squeezed button ellipsizes instead of overflowing.
        child: Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        ),
      ),
    );
  }
}

/// The reader progress bar and status wording (RD-05).
class _ReaderStatusBar extends StatelessWidget {
  const _ReaderStatusBar({required this.model});

  final ReaderModel model;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final progress = model.progress;
    final label = _readerStatusLabel(l10n, progress);
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: ShosaiTokens.appSurface,
        border: Border(top: BorderSide(color: ShosaiTokens.appBorder)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          vertical: ShosaiTokens.layoutReaderChromeStatusPaddingVertical,
          horizontal: ShosaiTokens.layoutReaderChromeStatusPaddingHorizontal,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (progress.hasDocument)
              ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: ShosaiTokens.layoutReaderProgressWidth,
                ),
                child: _ReaderProgressBar(value: progress.percentage / 100),
              ),
            if (progress.hasDocument)
              const SizedBox(
                height: ShosaiTokens.layoutReaderChromeStatusSpacing,
              ),
            Semantics(
              key: const ValueKey('reader-progress'),
              container: true,
              liveRegion: true,
              label: label,
              child: ExcludeSemantics(
                child: Text(
                  label,
                  textAlign: TextAlign.center,
                  style: shosaiInterfaceStyleForText(
                    const TextStyle(
                      fontSize: ShosaiTokens.typeSize11,
                      color: ShosaiTokens.appTextMuted,
                    ),
                    label,
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

class _ReaderProgressBar extends StatelessWidget {
  const _ReaderProgressBar({required this.value});

  final double value;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: double.infinity,
    height: ShosaiTokens.layoutProgressGirth,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: ShosaiTokens.appSurfaceMuted,
        borderRadius: BorderRadius.circular(ShosaiTokens.radiusProgress),
      ),
      child: FractionallySizedBox(
        alignment: Alignment.centerLeft,
        widthFactor: value.clamp(0, 1).toDouble(),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: ShosaiTokens.appAccent,
            borderRadius: BorderRadius.circular(ShosaiTokens.radiusProgress),
          ),
        ),
      ),
    ),
  );
}

String _readerStatusLabel(
  AppLocalizations l10n,
  ReaderProgressPresentation progress,
) {
  switch (progress.kind) {
    case ReaderProgressKind.none:
      return l10n.readerNoBookOpen;
    case ReaderProgressKind.loading:
      return l10n.readerOpeningDocument;
    case ReaderProgressKind.single:
      final ordinal = progress.firstOrdinal ?? 0;
      return progress.displayUnit == ReaderDisplayUnit.chapter
          ? l10n.readerChapterStatus(ordinal, progress.percentage)
          : l10n.readerPageStatus(ordinal, progress.percentage);
    case ReaderProgressKind.range:
      final first = progress.firstOrdinal ?? 0;
      final last = progress.lastOrdinal ?? first;
      return progress.displayUnit == ReaderDisplayUnit.chapter
          ? l10n.readerChapterRangeStatus(first, last, progress.percentage)
          : l10n.readerPageRangeStatus(first, last, progress.percentage);
  }
}

/// One edge-navigation control (RD-06).
class _ReaderEdgeButton extends StatelessWidget {
  const _ReaderEdgeButton({
    required this.glyph,
    required this.semanticsKey,
    required this.semanticsLabel,
    required this.compact,
    required this.onPressed,
  });

  final String glyph;
  final Key semanticsKey;
  final String semanticsLabel;
  final bool compact;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = ShadTheme.of(context).colorScheme;
    final foreground = scheme.mutedForeground;
    final padding = EdgeInsets.symmetric(
      vertical: ShosaiTokens.layoutReaderChromeEdgePaddingVertical,
      horizontal: compact
          ? ShosaiTokens.layoutReaderChromeEdgePaddingHorizontalCompact
          : ShosaiTokens.layoutReaderChromeEdgePaddingHorizontalWide,
    );
    return _readerSemanticButton(
      key: semanticsKey,
      enabled: onPressed != null,
      label: semanticsLabel,
      onPressed: onPressed,
      child: ShadButton.raw(
        variant: ShadButtonVariant.ghost,
        enabled: onPressed != null,
        width: null,
        height: double.infinity,
        padding: padding,
        hoverBackgroundColor: scheme.muted,
        pressedBackgroundColor: scheme.muted,
        foregroundColor: foreground,
        hoverForegroundColor: foreground,
        onPressed: onPressed,
        child: Text(
          glyph,
          maxLines: 1,
          style: TextStyle(
            fontSize: compact
                ? ShosaiTokens.typeReaderEdgeGlyphCompact
                : ShosaiTokens.typeReaderEdgeGlyphWide,
            color: foreground,
          ),
        ),
      ),
    );
  }
}

/// The reader panel host: one labelled container for the open panel (RD-13).
///
/// The panel *bodies* are 4C's (Contents/saved places, typography, more and
/// search presentation); 4B owns the host, its exclusivity, its focus and
/// Escape behavior and the layout report its open/close produces.
class _ReaderPanelHost extends StatelessWidget {
  const _ReaderPanelHost({
    required this.panel,
    required this.model,
    required this.compact,
    required this.dispatch,
    required this.focusNode,
  });

  final ReaderPanel panel;
  final ReaderModel model;
  final bool compact;
  final void Function(ReaderMessage) dispatch;
  final FocusNode focusNode;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final label = switch (panel) {
      ReaderPanel.contents => l10n.readerContentsAction,
      ReaderPanel.typography => l10n.readerAppearanceAction,
      ReaderPanel.more => l10n.readerMoreAction,
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
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: ShosaiTokens.appPanelBackground,
              border: Border.all(color: ShosaiTokens.appBorder),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                vertical: ShosaiTokens.layoutReaderChromeAlertPaddingVertical,
                horizontal:
                    ShosaiTokens.layoutReaderChromeAlertPaddingHorizontal,
              ),
              // The Iced-shaped bodies are 4C's. Until they land the host
              // renders the reader's existing live controls rather than an
              // empty label: contract §7.2 retires the tools *surface*, not the
              // bookmark and search operations behind it, and dropping them
              // would lose live capabilities (Oracle review of 4B).
              child: switch (panel) {
                ReaderPanel.contents => _ReaderSavedPlaces(
                  model: model,
                  dispatch: dispatch,
                ),
                ReaderPanel.more => _ReaderToolsBody(
                  model: model,
                  dispatch: dispatch,
                ),
                ReaderPanel.typography => Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: shosaiInterfaceStyleForText(
                    const TextStyle(
                      fontSize: ShosaiTokens.typeSize13,
                      color: ShosaiTokens.appText,
                    ),
                    label,
                  ),
                ),
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// The retained saved-places body (RD-08's predecessor).
///
/// The Iced-shaped saved-places design is 4C's; this is the reader's existing
/// live bookmark list: navigate to a saved location, edit its note, delete it.
class _ReaderSavedPlaces extends StatelessWidget {
  const _ReaderSavedPlaces({required this.model, required this.dispatch});

  final ReaderModel model;
  final void Function(ReaderMessage) dispatch;

  @override
  Widget build(BuildContext context) {
    final document = model.document;
    if (document == null || document.bookId == null) {
      return const SizedBox.shrink();
    }
    return SingleChildScrollView(
      key: const ValueKey('reader-saved-places-scroll'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final bookmark in model.bookmarks)
            Row(
              children: [
                Flexible(
                  child: ShadButton.ghost(
                    onPressed: () => dispatch(
                      ReaderBookmarkNavigated(
                        bookmark.unit.toInt(),
                        offset: bookmark.offset?.toInt(),
                      ),
                    ),
                    // Flexible *inside* the button too: the button's Row gives
                    // non-flexible children an unbounded width, so a long saved
                    // note ellipsizes instead of overflowing the bounded panel
                    // row.
                    child: Flexible(
                      child: Text(
                        bookmark.note?.isNotEmpty == true
                            ? '${bookmark.unit.toInt() + 1}: ${bookmark.note}'
                            : '${bookmark.unit.toInt() + 1}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ),
                _BookmarkActionsMenu(
                  enabled: !model.bookmarkBusy,
                  onEdit: () => dispatch(ReaderBookmarkNoteRequested(bookmark)),
                  onDelete: () => dispatch(ReaderBookmarkDeleted(bookmark.id)),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// The retained reader tools body: document search and the current-location
/// bookmark actions, moved from the retired tools surface into the more panel
/// so the live operations stay reachable (4C replaces this body).
class _ReaderToolsBody extends StatelessWidget {
  const _ReaderToolsBody({required this.model, required this.dispatch});

  final ReaderModel model;
  final void Function(ReaderMessage) dispatch;

  @override
  Widget build(BuildContext context) {
    final document = model.document;
    if (document == null) return const SizedBox.shrink();
    final currentBookmark = model.bookmarks
        .where(
          (bookmark) =>
              bookmark.unit.toInt() == model.unit &&
              bookmark.offset?.toInt() == model.readingOffset,
        )
        .firstOrNull;
    final locationBookmarked = currentBookmark != null;
    return SingleChildScrollView(
      key: const ValueKey('reader-tools-scroll'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (document.format != FlutterBookFormat.cbz)
            ShadInput(
              key: const ValueKey('reader-search-input'),
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
              onSubmitted: (query) => dispatch(ReaderSearchRequested(query)),
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
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
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
                          ReaderBookmarkNoteRequested(currentBookmark),
                        ),
                  icon: const Icon(LucideIcons.bookmarkPlus),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// The retained bookmark row actions menu (edit note, delete).
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

/// The reader open-failure alert (RD-17).
///
/// The alert is a live region and stays visible until the failure is resolved
/// (plan decision 13). Retry re-runs the open with the same path/book id; the
/// missing-book locate and remove actions are shell/library flows owned by
/// 3D/6A and are not invented here.
class _ReaderFailureAlert extends StatelessWidget {
  const _ReaderFailureAlert({required this.error, required this.onRetry});

  final String error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return DecoratedBox(
      decoration: const BoxDecoration(color: ShosaiTokens.appAlertBackground),
      child: Padding(
        key: const ValueKey('reader-open-error'),
        padding: const EdgeInsets.symmetric(
          vertical: ShosaiTokens.layoutReaderChromeAlertPaddingVertical,
          horizontal: ShosaiTokens.layoutReaderChromeAlertPaddingHorizontal,
        ),
        child: Row(
          children: [
            Expanded(
              child: Semantics(
                container: true,
                liveRegion: true,
                child: Text(
                  error,
                  style: shosaiInterfaceStyleForText(
                    const TextStyle(
                      fontSize: ShosaiTokens.typeSize13,
                      color: ShosaiTokens.appDanger,
                    ),
                    error,
                  ),
                ),
              ),
            ),
            const SizedBox(width: ShosaiTokens.layoutReaderChromeAlertSpacing),
            _ReaderAlertAction(
              key: const ValueKey('reader-open-error-retry'),
              label: l10n.readerRetryOpen,
              onPressed: onRetry,
            ),
          ],
        ),
      ),
    );
  }
}

class _ReaderAlertAction extends StatelessWidget {
  const _ReaderAlertAction({
    super.key,
    required this.label,
    required this.onPressed,
  });

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final padding = const EdgeInsets.symmetric(
      vertical: ShosaiTokens.layoutButtonSecondaryPaddingVertical,
      horizontal: ShosaiTokens.layoutButtonSecondaryPaddingHorizontal,
    );
    return ShadButton.outline(
      height: shosaiShadButtonHeight(context, padding: padding),
      padding: padding,
      onPressed: onPressed,
      child: Flexible(
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: shosaiInterfaceStyleForText(
            const TextStyle(
              fontSize: ShosaiTokens.layoutButtonLabelSize,
              color: ShosaiTokens.appText,
            ),
            label,
          ),
        ),
      ),
    );
  }
}

/// The document-opening view (RD-16).
class _ReaderOpeningView extends StatelessWidget {
  const _ReaderOpeningView({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final coverLabel = _truncateReaderLabel(title, 20);
    return Center(
      key: const ValueKey('reader-opening'),
      // A short viewport at a scaled interface cannot hold the whole opening
      // composition; scrolling keeps every line reachable instead of clipping
      // it (RD-16). A scroll view inside a `Center` is exactly as tall as its
      // content while that fits, so the composition stays centered normally.
      child: SingleChildScrollView(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: ShosaiTokens.layoutReaderChromeOpeningMaxWidth,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: ShosaiTokens.layoutReaderChromeOpeningCoverWidth,
                height: ShosaiTokens.layoutReaderChromeOpeningCoverHeight,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: ShosaiTokens.appCoverPlaceholderBackground,
                  // The pinned Iced cover placeholder and its library cover use
                  // the same 4.0 radius literal (app.rs:8131); the shared token
                  // is 3C's to add.
                  borderRadius: BorderRadius.circular(
                    ShosaiTokens.layoutLibraryCardCoverRadius,
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(
                    ShosaiTokens.layoutLibraryCardPlaceholderPadding,
                  ),
                  child: Text(
                    coverLabel,
                    textAlign: TextAlign.center,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: shosaiInterfaceStyleForText(
                      const TextStyle(
                        fontSize: ShosaiTokens.typeSize14,
                        color: ShosaiTokens.appTextOnAccent,
                      ),
                      coverLabel,
                    ),
                  ),
                ),
              ),
              const SizedBox(
                height: ShosaiTokens.layoutReaderChromeOpeningSpacing,
              ),
              Text(
                title,
                textAlign: TextAlign.center,
                style: shosaiInterfaceStyleForText(
                  const TextStyle(
                    fontSize: ShosaiTokens.typeSize16,
                    color: ShosaiTokens.appText,
                  ),
                  title,
                ),
              ),
              const SizedBox(
                height: ShosaiTokens.layoutReaderChromeOpeningSpacing,
              ),
              Text(
                l10n.readerOpeningDocument,
                textAlign: TextAlign.center,
                style: shosaiInterfaceStyleForText(
                  const TextStyle(
                    fontSize: ShosaiTokens.typeSize13,
                    color: ShosaiTokens.appTextMuted,
                  ),
                  l10n.readerOpeningDocument,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The reader's error surfaces: each one a live region above the status bar.
///
/// The open failure is the alert above the body (RD-17); these are the
/// selection, annotation and reading-position errors that have no panel of
/// their own. Errors from stale completions never reach here (the controller
/// guards them), and a surface disappears when its error clears.
class _ReaderErrorSurfaces extends StatelessWidget {
  const _ReaderErrorSurfaces({required this.model});

  final ReaderModel model;

  @override
  Widget build(BuildContext context) {
    final document = model.document;
    final persistenceError = model.persistenceError;
    final toolError = model.toolError;
    final relayoutError = model.relayoutError;
    final entries = <String>[
      // A failed page layout is not a selection problem: it is rendered as its
      // own message instead of the retained "Selection unavailable" prefix.
      ?relayoutError,
      if (model.selectionError != null && document != null)
        'Selection unavailable: ${model.selectionError}',
      if (model.selectionActionError != null && document != null)
        'Selection action failed: ${model.selectionActionError}',
      if (model.annotationError != null && document != null)
        model.annotationsReady
            ? 'Highlight action failed: ${model.annotationError}'
            : 'Highlights unavailable: ${model.annotationError}',
      ?persistenceError,
      // A tool error (a rejected open while a bookmark write is pending, a
      // failed search start) has no panel of its own while the panel bodies are
      // retained controls; it is rendered persistently here, deduplicated
      // against the persistence error that carries the same message.
      if (toolError != null && toolError != persistenceError) toolError,
    ];
    if (entries.isEmpty) return const SizedBox.shrink();
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final entry in entries)
            Semantics(
              key: entry == persistenceError
                  ? const ValueKey('reader-persistence-error')
                  : entry == toolError
                  ? const ValueKey('reader-tool-error')
                  : entry == relayoutError
                  ? const ValueKey('reader-relayout-error')
                  : null,
              liveRegion: true,
              child: Text(
                entry,
                style: shosaiInterfaceStyleForText(
                  TextStyle(
                    fontSize: ShosaiTokens.typeSize13,
                    color: ShadTheme.of(context).colorScheme.destructive,
                  ),
                  entry,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
