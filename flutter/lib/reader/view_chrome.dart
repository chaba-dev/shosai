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

/// Line-height ratio for a tab label's own line box.
///
/// The Shad interface text style sets `height: 1` (leading-none), which is
/// shorter than the interface font's ink. A label that does not overflow paints
/// outside that line box and is still visible, but a *truncated* label turns the
/// paragraph's own clip on, so the descenders and accents of a long mixed
/// Latin/Japanese label were cut at 200 % text (`reader-tab-overflow-390-ja-t200`,
/// `4B-RENDER`, Oracle follow-up). The label therefore carries its own line
/// metrics and the tab grows by the same delta; the shared button geometry and
/// the theme stay untouched.
const double readerTabLabelLineHeight = 1.25;

/// The scaled line box a tab label needs at the current text scale.
///
/// The budget is rounded up to a whole logical pixel because the engine rounds
/// the laid-out line height to whole logical pixels as well (`SkParagraph`
/// rounds the line height and lays the line out in that rounded box). At a
/// fractional scale the nominal budget would otherwise fall just below the
/// engine's line box (1.25 * 12 * 1.92 = 28.8 < 29), constrain the paragraph
/// and switch its own clip on again — the same clipping the line metrics fix.
double _readerTabLabelLineBox(BuildContext context) =>
    (MediaQuery.textScalerOf(context).scale(ShosaiTokens.typeSize12) *
            readerTabLabelLineHeight)
        .ceilToDouble();

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
        height: readerTabLabelLineHeight,
        color: selected ? scheme.accentForeground : scheme.mutedForeground,
      ),
      label,
    );
    const labelPadding = EdgeInsets.only(
      top: ShosaiTokens.layoutReaderChromeTabPaddingVertical,
      right: ShosaiTokens.layoutReaderChromeTabLabelPaddingRight,
      bottom: ShosaiTokens.layoutReaderChromeTabPaddingVertical,
      left: ShosaiTokens.layoutReaderChromeTabLabelPaddingLeft,
    );
    // The tab grows so the label's own line box fits the content box the Shad
    // button pins it inside; the theme height stays the floor at 100 % text.
    final labelHeight = math.max(
      shosaiShadButtonHeight(context, padding: labelPadding),
      labelPadding.vertical + _readerTabLabelLineBox(context),
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
                  height: labelHeight,
                  padding: labelPadding,
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
              padding: EdgeInsets.zero,
              // The panel bodies are 4C's: the Contents panel with its saved
              // places (RD-07, RD-08), the typography controls (RD-09) and the
              // more panel (RD-10). Each body applies its own pinned padding;
              // the host owns the container, exclusivity, focus and Escape.
              child: switch (panel) {
                ReaderPanel.contents => _ReaderContentsPanel(
                  model: model,
                  dispatch: dispatch,
                ),
                ReaderPanel.more => _ReaderMorePanel(
                  model: model,
                  compact: compact,
                  dispatch: dispatch,
                ),
                ReaderPanel.typography => _ReaderTypographyPanel(
                  model: model,
                  compact: compact,
                  dispatch: dispatch,
                ),
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// The Contents panel body: the chapter list and the saved places section
/// (RD-07, RD-08).
///
/// The pinned reference composes one `bookmarks_panel` with a heading, a
/// "Chapters" section and a "Bookmarks · N" saved-places section; the 4B host
/// keeps the reader surface beside the wide panel and replaces the body in
/// compact. Entries are fixture-provided in 4C — the bridge exposes no TOC DTO
/// — and an untitled entry renders the localized chapter number for its unit
/// (the pinned fallback, `app.rs:6062-6071`).
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
    final model = widget.model;
    final dispatch = widget.dispatch;
    final contents = model.contents;
    if (contents.status == ReaderContentsStatus.ready &&
        contents.entries.any((entry) => entry.current)) {
      _scheduleReveal();
    }
    return SingleChildScrollView(
      key: const ValueKey('reader-contents-scroll'),
      child: Padding(
        padding: const EdgeInsets.all(ShosaiTokens.layoutReaderPanelPadding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.readerContentsAction,
                        key: const ValueKey('reader-contents-heading'),
                        style: shosaiInterfaceStyleForText(
                          const TextStyle(
                            fontSize: ShosaiTokens.typeSize18,
                            color: ShosaiTokens.appText,
                          ),
                          l10n.readerContentsAction,
                        ),
                      ),
                      const SizedBox(
                        height: ShosaiTokens.layoutReaderPanelHeadingSpacing,
                      ),
                      Text(
                        l10n.readerContentsSubheading,
                        key: const ValueKey('reader-contents-subheading'),
                        style: shosaiInterfaceStyleForText(
                          const TextStyle(
                            fontSize: ShosaiTokens.typeSize11,
                            color: ShosaiTokens.appTextMuted,
                          ),
                          l10n.readerContentsSubheading,
                        ),
                      ),
                    ],
                  ),
                ),
                _ReaderControlButton(
                  key: const ValueKey('reader-contents-close'),
                  label: '×',
                  semanticsLabel: l10n.readerCloseContents,
                  selected: false,
                  onPressed: () =>
                      dispatch(const ReaderPanelToggled(ReaderPanel.contents)),
                ),
              ],
            ),
            const SizedBox(height: ShosaiTokens.layoutReaderPanelSpacing),
            Text(
              l10n.readerChaptersHeading,
              key: const ValueKey('reader-contents-chapters-label'),
              style: shosaiInterfaceStyleForText(
                const TextStyle(
                  fontSize: ShosaiTokens.typeSize12,
                  color: ShosaiTokens.appTextMuted,
                ),
                l10n.readerChaptersHeading,
              ),
            ),
            const SizedBox(height: ShosaiTokens.layoutReaderPanelSpacing),
            ..._chapterSection(l10n, contents, dispatch),
            const SizedBox(height: ShosaiTokens.layoutReaderPanelSpacing),
            Text(
              l10n.readerBookmarksHeading(model.bookmarks.length),
              key: const ValueKey('reader-contents-bookmarks-count'),
              style: shosaiInterfaceStyleForText(
                const TextStyle(
                  fontSize: ShosaiTokens.typeSize12,
                  color: ShosaiTokens.appTextMuted,
                ),
                l10n.readerBookmarksHeading(model.bookmarks.length),
              ),
            ),
            const SizedBox(height: ShosaiTokens.layoutReaderPanelSpacing),
            ..._savedPlacesSection(l10n, model, dispatch),
          ],
        ),
      ),
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
    ReaderContentsStatus.ready => [
      for (final entry in contents.entries) ...[
        // The pinned panel column spaces every child by 10 px, including
        // consecutive chapter rows.
        if (entry != contents.entries.first)
          const SizedBox(height: ShosaiTokens.layoutReaderPanelSpacing),
        KeyedSubtree(
          key: entry.current ? _currentEntryKey : null,
          child: _ReaderChapterRow(
            entry: entry,
            label: entry.title.trim().isEmpty
                ? l10n.readerChapterNumber(entry.unit + 1)
                : _truncateReaderLabel(entry.title, 38),
            dispatch: dispatch,
          ),
        ),
      ],
    ],
  };

  /// The saved places list and the Markdown export action (RD-08).
  List<Widget> _savedPlacesSection(
    AppLocalizations l10n,
    ReaderModel model,
    void Function(ReaderMessage) dispatch,
  ) {
    if (model.bookmarks.isEmpty) {
      return [
        Padding(
          key: const ValueKey('reader-contents-empty'),
          padding: const EdgeInsets.symmetric(
            vertical: ShosaiTokens.layoutReaderPanelEmptyPaddingVertical,
            horizontal: ShosaiTokens.layoutReaderPanelEmptyPaddingHorizontal,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.readerNoBookmarks,
                style: shosaiInterfaceStyleForText(
                  const TextStyle(
                    fontSize: ShosaiTokens.typeBookmarkEmpty,
                    color: ShosaiTokens.appText,
                  ),
                  l10n.readerNoBookmarks,
                ),
              ),
              const SizedBox(
                height: ShosaiTokens.layoutReaderPanelEmptySpacing,
              ),
              Text(
                l10n.readerBookmarkEmptyHint,
                style: shosaiInterfaceStyleForText(
                  const TextStyle(
                    fontSize: ShosaiTokens.typeSize12,
                    color: ShosaiTokens.appTextMuted,
                  ),
                  l10n.readerBookmarkEmptyHint,
                ),
              ),
            ],
          ),
        ),
      ];
    }
    final exportFailed =
        model.exportState == ReaderExportState.failed &&
        model.exportError != null;
    // The pinned panel column spaces every child by 10 px, including
    // consecutive saved places and the export action.
    return [
      for (var index = 0; index < model.bookmarks.length; index += 1) ...[
        if (index > 0)
          const SizedBox(height: ShosaiTokens.layoutReaderPanelSpacing),
        _ReaderSavedPlaceRow(
          bookmark: model.bookmarks[index],
          enabled: !model.bookmarkBusy,
          dispatch: dispatch,
        ),
      ],
      if (exportFailed) ...[
        const SizedBox(height: ShosaiTokens.layoutReaderPanelSpacing),
        _ReaderPanelNote(
          key: const ValueKey('reader-bookmark-export-error'),
          text: model.exportError!,
          danger: true,
          liveRegion: true,
        ),
      ],
      const SizedBox(height: ShosaiTokens.layoutReaderPanelSpacing),
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
}

/// One chapter row (RD-07): 12 px per-level indent, truncated at 38 characters,
/// link styling, and a selected treatment for the current entry.
class _ReaderChapterRow extends StatelessWidget {
  const _ReaderChapterRow({
    required this.entry,
    required this.label,
    required this.dispatch,
  });

  final ReaderContentsEntry entry;
  final String label;
  final void Function(ReaderMessage) dispatch;

  @override
  Widget build(BuildContext context) {
    final scheme = ShadTheme.of(context).colorScheme;
    const padding = EdgeInsets.symmetric(
      vertical: ShosaiTokens.layoutReaderPanelEntryPaddingVertical,
      horizontal: ShosaiTokens.layoutReaderPanelEntryPaddingHorizontal,
    );
    final style = shosaiInterfaceStyleForText(
      TextStyle(
        fontSize: ShosaiTokens.typeSize12,
        height: 1.25,
        color: scheme.accentForeground,
      ),
      label,
    );
    // The pinned reference entry is its padding plus the 12 px label's line
    // box. The Shad button's own minimum height would make the row (and the
    // list pitch) taller than the reference, so the row is sized to its
    // content; it keeps the full panel width as its target and grows with the
    // text scale, so a scaled interface never clips the label.
    final labelBox =
        (MediaQuery.textScalerOf(context).scale(ShosaiTokens.typeSize12) * 1.25)
            .ceilToDouble();
    return Padding(
      padding: EdgeInsets.only(
        left: entry.depth * ShosaiTokens.layoutReaderPanelEntryIndent,
      ),
      child: _readerSemanticButton(
        key: ValueKey('reader-contents-entry-${entry.unit}'),
        enabled: true,
        selected: entry.current,
        label: label,
        onPressed: () =>
            dispatch(ReaderLocationNavigated(entry.unit, offset: entry.offset)),
        child: ShadButton.raw(
          variant: ShadButtonVariant.ghost,
          mainAxisAlignment: MainAxisAlignment.start,
          height: padding.vertical + labelBox,
          padding: padding,
          backgroundColor: entry.current ? scheme.selection : null,
          hoverBackgroundColor: scheme.accent,
          pressedBackgroundColor: scheme.accent,
          foregroundColor: scheme.accentForeground,
          hoverForegroundColor: scheme.accentForeground,
          onPressed: () => dispatch(
            ReaderLocationNavigated(entry.unit, offset: entry.offset),
          ),
          child: Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
        ),
      ),
    );
  }
}

/// One saved place (RD-08): title link, page label, note, note action and
/// delete.
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
    final scheme = ShadTheme.of(context).colorScheme;
    final page = bookmark.unit.toInt() + 1;
    final authored = bookmark.title?.trim();
    final title = authored == null || authored.isEmpty
        ? l10n.readerPageShort(page)
        : authored;
    final note = bookmark.note;
    final hasNote = note != null && note.isNotEmpty;
    return Container(
      key: ValueKey('reader-saved-place-${bookmark.id}'),
      padding: const EdgeInsets.all(ShosaiTokens.layoutReaderPanelPlacePadding),
      decoration: BoxDecoration(
        color: scheme.card,
        border: Border.all(color: scheme.border),
        borderRadius: BorderRadius.circular(ShosaiTokens.radiusMedium),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            // The pinned reference fills the gap between the title and the
            // page/delete group (`Space::new().width(Length::Fill)`), so the
            // group sits at the entry's right edge; `spaceBetween` leaves the
            // title at its content width and puts the remaining space in that
            // gap.
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
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
              // The page label and the delete control form one right-hand group,
              // so `spaceBetween` puts the whole remaining gap between the title
              // and this group (the pinned reference's filler).
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    l10n.readerPageAbbreviated(page),
                    style: shosaiInterfaceStyleForText(
                      const TextStyle(
                        fontSize: ShosaiTokens.typeSize10,
                        color: ShosaiTokens.appTextMuted,
                      ),
                      l10n.readerPageAbbreviated(page),
                    ),
                  ),
                  const SizedBox(
                    width: ShosaiTokens.layoutReaderPanelPlaceRowSpacing,
                  ),
                  _ReaderControlButton(
                    key: ValueKey('reader-saved-place-delete-${bookmark.id}'),
                    label: '✕',
                    semanticsLabel: l10n.readerDeleteBookmark(title),
                    // The pinned reference draws the delete control as a 10 px `✕`
                    // text glyph in a [4, 6] button; that glyph is not legible in
                    // the interface font at 10 px, so the bundled icon font's `x`
                    // paints the mark at 12 px in the same [4, 6] button. Recorded
                    // as a toolkit/glyph-availability difference (plan decision 1:
                    // accessibility must not regress to match Iced).
                    icon: LucideIcons.x,
                    padding: const EdgeInsets.symmetric(
                      vertical: ShosaiTokens.layoutReaderPanelPlaceSpacing,
                      horizontal: ShosaiTokens.layoutReaderPanelPlaceRowSpacing,
                    ),
                    fontSize: ShosaiTokens.typeSize12,
                    selected: false,
                    onPressed: enabled
                        ? () => dispatch(ReaderBookmarkDeleted(bookmark.id))
                        : null,
                  ),
                ],
              ),
            ],
          ),
          if (hasNote) ...[
            const SizedBox(height: ShosaiTokens.layoutReaderPanelPlaceSpacing),
            Text(
              note,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: shosaiInterfaceStyleForText(
                const TextStyle(
                  fontSize: ShosaiTokens.typeSize11,
                  color: ShosaiTokens.appTextMuted,
                ),
                note,
              ),
            ),
          ],
          const SizedBox(height: ShosaiTokens.layoutReaderPanelPlaceSpacing),
          _ReaderLinkButton(
            key: ValueKey('reader-saved-place-note-${bookmark.id}'),
            label: hasNote ? l10n.readerEditNote : l10n.readerAddNote,
            fontSize: ShosaiTokens.typeSize10,
            onPressed: enabled
                ? () => dispatch(ReaderBookmarkNoteRequested(bookmark))
                : null,
          ),
        ],
      ),
    );
  }
}

/// The typography panel (RD-09).
///
/// Mode-specific availability comes from [ReaderTypographyPresentation]:
/// a reflowable (EPUB) document shows font size, line spacing and the theme
/// cycle; a raster (PDF/CBZ) document shows zoom and the fit controls. The
/// controls are disabled while a relayout is in flight; a failed relayout
/// reports through the shared error surface.
class _ReaderTypographyPanel extends StatelessWidget {
  const _ReaderTypographyPanel({
    required this.model,
    required this.compact,
    required this.dispatch,
  });

  final ReaderModel model;
  final bool compact;
  final void Function(ReaderMessage) dispatch;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final typography = model.typography;
    final enabled =
        model.document != null && !model.busy && !model.relayoutBusy;
    final controls = <Widget>[
      if (typography.reflowable) ..._epubControls(l10n, typography, enabled),
      if (!typography.reflowable) ..._rasterControls(l10n, typography, enabled),
    ];
    // The pinned reference sizes this row to its content: the row's [7, 12]
    // padding plus the control group (4 px padding around 13 px controls), which
    // renders 53 logical px tall in the 1C captures. The Iced layout *math*
    // reserves 62 px when it sizes the page box (`app.rs:4390`), so that
    // reservation is a paginated-document concern owned by 5A/5G, not a rendered
    // row height; painting 62 here would be 9 px taller than the reference.
    return Padding(
      padding: const EdgeInsets.symmetric(
        vertical: ShosaiTokens.layoutReaderPanelSettingsPaddingVertical,
        horizontal: ShosaiTokens.layoutReaderPanelSettingsPaddingHorizontal,
      ),
      child: Row(
        children: [
          Text(
            compact ? l10n.readerReading : l10n.readerAppearanceAction,
            style: shosaiInterfaceStyleForText(
              const TextStyle(
                fontSize: ShosaiTokens.typeSize12,
                color: ShosaiTokens.appTextMuted,
              ),
              compact ? l10n.readerReading : l10n.readerAppearanceAction,
            ),
          ),
          const SizedBox(width: ShosaiTokens.layoutReaderPanelSettingsSpacing),
          // The pinned reference scrolls the control group horizontally so a
          // narrow window or a scaled interface never clips a control.
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: ShadTheme.of(context).colorScheme.card,
                  border: Border.all(
                    color: ShadTheme.of(context).colorScheme.border,
                  ),
                  borderRadius: BorderRadius.circular(
                    ShosaiTokens.radiusMedium,
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(
                    ShosaiTokens.layoutReaderPanelControlGroupPadding,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (
                        var index = 0;
                        index < controls.length;
                        index += 1
                      ) ...[
                        if (index > 0) const SizedBox(width: 5),
                        controls[index],
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _epubControls(
    AppLocalizations l10n,
    ReaderTypographyPresentation typography,
    bool enabled,
  ) => [
    _ReaderControlButton(
      key: const ValueKey('reader-typography-font-decrease'),
      label: 'A−',
      semanticsLabel: l10n.readerDecreaseFontSize,
      selected: false,
      onPressed: enabled
          ? () => dispatch(
              ReaderTypographyChanged(fontSize: typography.epubFontSize - 2),
            )
          : null,
    ),
    _ReaderZoomLabel(
      label: l10n.readerFontSizeValue(typography.epubFontSize.round()),
    ),
    _ReaderControlButton(
      key: const ValueKey('reader-typography-font-increase'),
      label: 'A+',
      semanticsLabel: l10n.readerIncreaseFontSize,
      selected: false,
      onPressed: enabled
          ? () => dispatch(
              ReaderTypographyChanged(fontSize: typography.epubFontSize + 2),
            )
          : null,
    ),
    _ReaderControlButton(
      key: const ValueKey('reader-typography-line-spacing'),
      label: l10n.readerLineSpacingValue(
        typography.epubLineSpacing.toStringAsFixed(1),
      ),
      semanticsLabel: l10n.readerLineSpacingLabel,
      selected: false,
      onPressed: enabled
          ? () => dispatch(
              ReaderTypographyChanged(
                lineSpacing: _nextReaderLineSpacing(typography.epubLineSpacing),
              ),
            )
          : null,
    ),
    _ReaderControlButton(
      key: const ValueKey('reader-typography-theme'),
      label: _readerThemeLabel(l10n, typography.theme),
      semanticsLabel: l10n.readerThemeCycle,
      selected: false,
      onPressed: enabled
          ? () => dispatch(
              ReaderTypographyChanged(
                theme: _nextReaderTheme(typography.theme),
              ),
            )
          : null,
    ),
  ];

  List<Widget> _rasterControls(
    AppLocalizations l10n,
    ReaderTypographyPresentation typography,
    bool enabled,
  ) => [
    _ReaderControlButton(
      key: const ValueKey('reader-typography-zoom-out'),
      label: '−',
      semanticsLabel: l10n.readerZoomOut,
      selected: false,
      onPressed: enabled
          ? () => dispatch(
              ReaderTypographyChanged(zoom: typography.rasterZoom - 0.25),
            )
          : null,
    ),
    _ReaderZoomLabel(label: _readerZoomLabel(l10n, typography)),
    _ReaderControlButton(
      key: const ValueKey('reader-typography-zoom-in'),
      label: '+',
      semanticsLabel: l10n.readerZoomIn,
      selected: false,
      onPressed: enabled
          ? () => dispatch(
              ReaderTypographyChanged(zoom: typography.rasterZoom + 0.25),
            )
          : null,
    ),
    _ReaderControlButton(
      key: const ValueKey('reader-typography-fit-width'),
      label: l10n.readerFitWidth,
      selected: typography.rasterFit == ReaderRasterFit.fitWidth,
      onPressed: enabled
          ? () => dispatch(
              const ReaderTypographyChanged(
                rasterFit: ReaderRasterFit.fitWidth,
              ),
            )
          : null,
    ),
    _ReaderControlButton(
      key: const ValueKey('reader-typography-fit-page'),
      label: l10n.readerFitPage,
      selected: typography.rasterFit == ReaderRasterFit.fitPage,
      onPressed: enabled
          ? () => dispatch(
              const ReaderTypographyChanged(rasterFit: ReaderRasterFit.fitPage),
            )
          : null,
    ),
  ];
}

/// The more panel (RD-10): page input, bookmark toggle, open book and search.
class _ReaderMorePanel extends StatefulWidget {
  const _ReaderMorePanel({
    required this.model,
    required this.compact,
    required this.dispatch,
  });

  final ReaderModel model;
  final bool compact;
  final void Function(ReaderMessage) dispatch;

  @override
  State<_ReaderMorePanel> createState() => _ReaderMorePanelState();
}

class _ReaderMorePanelState extends State<_ReaderMorePanel> {
  late final TextEditingController _pageInput = TextEditingController(
    text: widget.model.pageInput.draft,
  );

  @override
  void didUpdateWidget(_ReaderMorePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final draft = widget.model.pageInput.draft;
    if (draft != _pageInput.text) _pageInput.text = draft;
  }

  @override
  void dispose() {
    _pageInput.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final model = widget.model;
    final dispatch = widget.dispatch;
    final document = model.document;
    if (document == null) return const SizedBox.shrink();
    final total = document.logicalUnitCount.toInt();
    final busy = model.busy || model.relayoutBusy;
    final current = model.bookmarks
        .where(
          (bookmark) =>
              bookmark.unit.toInt() == model.unit &&
              bookmark.offset?.toInt() == model.readingOffset,
        )
        .firstOrNull;
    final bookmarked = current != null;
    final location = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: ShosaiTokens.layoutReaderPanelPageInputWidth,
          child: ShadInput(
            key: const ValueKey('reader-page-input'),
            controller: _pageInput,
            enabled: !busy,
            // The pinned reference input is its [7, 8] padding plus a 13 px
            // line; the Shad default would make the row taller.
            padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 8),
            placeholder: Text(l10n.readerPageInputLabel),
            textInputAction: TextInputAction.go,
            onChanged: (value) => dispatch(ReaderPageInputChanged(value)),
            onSubmitted: (_) => dispatch(const ReaderPageInputSubmitted()),
          ),
        ),
        const SizedBox(width: ShosaiTokens.layoutReaderPanelPlaceRowSpacing),
        Text(
          l10n.readerPageOf(total),
          style: shosaiInterfaceStyleForText(
            const TextStyle(
              fontSize: ShosaiTokens.typeSize12,
              color: ShosaiTokens.appTextMuted,
            ),
            l10n.readerPageOf(total),
          ),
        ),
        if (model.pageInput.error != null) ...[
          const SizedBox(width: ShosaiTokens.layoutReaderPanelPlaceRowSpacing),
          Flexible(
            child: Semantics(
              key: const ValueKey('reader-page-input-error'),
              liveRegion: true,
              child: Text(
                l10n.readerPageInputInvalid(total),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: shosaiInterfaceStyleForText(
                  TextStyle(
                    fontSize: ShosaiTokens.typeSize11,
                    color: ShadTheme.of(context).colorScheme.destructive,
                  ),
                  l10n.readerPageInputInvalid(total),
                ),
              ),
            ),
          ),
        ],
      ],
    );
    final actions = Wrap(
      spacing: ShosaiTokens.layoutReaderPanelMoreRowSpacing,
      runSpacing: ShosaiTokens.layoutReaderPanelMoreStackSpacing,
      children: [
        _ReaderControlButton(
          key: const ValueKey('reader-more-bookmark'),
          label: bookmarked ? l10n.readerSaved : l10n.readerBookmark,
          selected: bookmarked,
          onPressed: busy || document.bookId == null
              ? null
              : () => dispatch(const ReaderBookmarkToggled()),
        ),
        _ReaderControlButton(
          key: const ValueKey('reader-more-open-book'),
          label: l10n.readerOpenBook,
          selected: false,
          onPressed: busy || model.modalEffect != null
              ? null
              : () => dispatch(const ReaderOpenBookRequested()),
        ),
        if (model.typography.searchable)
          _ReaderControlButton(
            key: const ValueKey('reader-more-search'),
            label: l10n.readerSearchAction,
            selected: model.searchOpen,
            onPressed: busy
                ? null
                : () => dispatch(const ReaderSearchToggled()),
          ),
      ],
    );
    // The pinned reference stacks the location row above the actions in
    // compact windows. A scaled interface needs the same stacking at wide
    // widths, because one line cannot hold both groups without clipping a
    // control (contract §5.4).
    final stacks =
        widget.compact || MediaQuery.textScalerOf(context).scale(1) > 1;
    // The pinned reference fixes this row's height (58 wide / 84 compact) and
    // centers its content; a minimum keeps a scaled interface from clipping a
    // control.
    return ConstrainedBox(
      constraints: BoxConstraints(
        minHeight: widget.compact
            ? ShosaiTokens.layoutReaderMoreHeightCompact
            : ShosaiTokens.layoutReaderMoreHeightWide,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          vertical: ShosaiTokens.layoutReaderPanelMorePaddingVertical,
          horizontal: ShosaiTokens.layoutReaderPanelMorePaddingHorizontal,
        ),
        child: stacks
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  location,
                  const SizedBox(
                    height: ShosaiTokens.layoutReaderPanelMoreStackSpacing,
                  ),
                  actions,
                ],
              )
            : Row(children: [location, const Spacer(), actions]),
      ),
    );
  }
}

/// The search bar (RD-11): query input, `n / total`, previous/next and close.
///
/// Search is independent of the three exclusive panels and stays open while a
/// search runs; closing cancels the in-flight search and clears the query. The
/// wide input is capped at the pinned reference's 420 logical px and the
/// compact composition stacks the actions below it.
class _ReaderSearchBar extends StatefulWidget {
  const _ReaderSearchBar({
    required this.model,
    required this.compact,
    required this.dispatch,
  });

  final ReaderModel model;
  final bool compact;
  final void Function(ReaderMessage) dispatch;

  @override
  State<_ReaderSearchBar> createState() => _ReaderSearchBarState();
}

class _ReaderSearchBarState extends State<_ReaderSearchBar> {
  late final TextEditingController _query = TextEditingController(
    text: widget.model.search.query,
  );

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = ShadTheme.of(context).colorScheme;
    final search = widget.model.search;
    final dispatch = widget.dispatch;
    final count = search.hasResults
        ? l10n.readerSearchCount(search.currentIndex + 1, search.results.length)
        : search.hasQuery && !search.busy && search.error == null
        ? l10n.readerNoResults
        : '';
    final input = ShadInput(
      key: const ValueKey('reader-search-input'),
      controller: _query,
      autofocus: true,
      // The pinned reference input is its [8, 10] padding plus a line box; the
      // Shad default would make the compact bar taller than the reference.
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
      placeholder: Text(l10n.readerSearchPlaceholder),
      leading: const Icon(LucideIcons.search, size: 16),
      trailing: search.busy
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
    );
    final actions = Wrap(
      alignment: widget.compact ? WrapAlignment.start : WrapAlignment.end,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: ShosaiTokens.layoutReaderPanelMoreRowSpacing,
      runSpacing: ShosaiTokens.layoutReaderPanelMoreStackSpacing,
      children: [
        if (count.isNotEmpty)
          Text(
            count,
            style: shosaiInterfaceStyleForText(
              const TextStyle(
                fontSize: ShosaiTokens.typeSize12,
                color: ShosaiTokens.appTextMuted,
              ),
              count,
            ),
          ),
        _ReaderControlButton(
          key: const ValueKey('reader-search-previous'),
          label: '‹',
          semanticsLabel: l10n.readerPreviousResult,
          selected: false,
          onPressed: search.hasResults && !search.busy
              ? () => dispatch(const ReaderSearchResultStepRequested(delta: -1))
              : null,
        ),
        _ReaderControlButton(
          key: const ValueKey('reader-search-next'),
          label: '›',
          semanticsLabel: l10n.readerNextResult,
          selected: false,
          onPressed: search.hasResults && !search.busy
              ? () => dispatch(const ReaderSearchResultStepRequested(delta: 1))
              : null,
        ),
        // Close stays enabled while a search runs: it cancels the in-flight
        // query (RD-11, contract §5.1).
        _ReaderControlButton(
          key: const ValueKey('reader-search-close'),
          label: '×',
          semanticsLabel: l10n.readerCloseSearch,
          selected: false,
          onPressed: () => dispatch(const ReaderSearchToggled()),
        ),
      ],
    );
    final bar = widget.compact
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              input,
              const SizedBox(
                height: ShosaiTokens.layoutReaderPanelSearchStackSpacing,
              ),
              actions,
            ],
          )
        : Row(
            children: [
              // The pinned reference's wide row gives the field and the filler an
              // equal share of the free space (the field measures 557 px on the
              // committed capture), which keeps the actions at the bar's right
              // padding edge. `layout.readerPanel.searchInputMaxWidth` (420) is
              // not what the pinned build painted; the discrepancy is flagged to
              // the token owner.
              Expanded(child: input),
              const Spacer(),
              actions,
            ],
          );
    return DecoratedBox(
      key: const ValueKey('reader-search-bar'),
      decoration: BoxDecoration(
        color: scheme.card,
        border: Border.all(color: scheme.border),
      ),
      // The pinned reference fixes this bar's height (52 wide / 88 compact) and
      // centers its content; a minimum keeps a scaled interface from clipping a
      // control.
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: widget.compact
              ? ShosaiTokens.layoutReaderSearchHeightCompact
              : ShosaiTokens.layoutReaderSearchHeightWide,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            vertical: ShosaiTokens.layoutReaderPanelSearchPaddingVertical,
            horizontal: ShosaiTokens.layoutReaderPanelSearchPaddingHorizontal,
          ),
          child: bar,
        ),
      ),
    );
  }
}

/// A pinned-reference reader control button (`reader_control_button`).
///
/// A selected control uses the accent-soft surface and accent text; hover and
/// press use the muted surface; a disabled control keeps the muted foreground
/// and the component layer's own disabled opacity.
class _ReaderControlButton extends StatelessWidget {
  const _ReaderControlButton({
    super.key,
    required this.label,
    required this.selected,
    required this.onPressed,
    this.semanticsLabel,
    this.icon,
    this.padding = const EdgeInsets.symmetric(
      vertical: ShosaiTokens.layoutReaderChromeControlPaddingVertical,
      horizontal: ShosaiTokens.layoutReaderChromeControlPaddingHorizontal,
    ),
    this.fontSize = ShosaiTokens.typeSize13,
  });

  /// The control's text label, or its accessible name when [icon] is set.
  final String label;
  final bool selected;
  final VoidCallback? onPressed;
  final String? semanticsLabel;

  /// An icon glyph from the bundled icon font.
  ///
  /// The pinned reference draws some controls as text glyphs (`×`, `‹`, `›`);
  /// a glyph that the interface font does not carry is not legible, so an
  /// icon-font glyph is used instead and the difference is recorded as a
  /// toolkit/glyph-availability difference (plan §"Allowed differences").
  final IconData? icon;

  /// The control's padding. The pinned reference gives the chrome controls
  /// [7, 10] and the saved-place row's compact controls [4, 6]
  /// (`reader_tab_close`).
  final EdgeInsetsGeometry padding;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final scheme = ShadTheme.of(context).colorScheme;
    final enabled = onPressed != null;
    final foreground = enabled
        ? (selected ? scheme.accentForeground : scheme.foreground)
        : scheme.mutedForeground;
    final padding = this.padding;
    final style = shosaiInterfaceStyleForText(
      TextStyle(fontSize: fontSize, color: foreground),
      label,
    );
    final glyph = icon;
    // The pinned reference control is its padding plus the label's line box;
    // the Shad button's own minimum would make every panel control taller than
    // the reference. The row keeps the full panel width as its target and grows
    // with the text scale.
    final labelBox = (MediaQuery.textScalerOf(context).scale(fontSize) * 1.25)
        .ceilToDouble();
    return _readerSemanticButton(
      enabled: enabled,
      selected: selected,
      label: semanticsLabel ?? label,
      onPressed: onPressed,
      child: ShadButton.raw(
        variant: ShadButtonVariant.ghost,
        enabled: enabled,
        height: padding.vertical + labelBox,
        padding: padding,
        backgroundColor: selected ? scheme.accent : null,
        hoverBackgroundColor: scheme.muted,
        pressedBackgroundColor: scheme.muted,
        foregroundColor: foreground,
        hoverForegroundColor: foreground,
        onPressed: onPressed,
        child: glyph == null
            ? Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: style,
                ),
              )
            : Icon(glyph, size: fontSize, color: foreground),
      ),
    );
  }
}

/// A pinned-reference bookmark link (`bookmark_link`): accent text with the
/// accent-soft hover surface.
class _ReaderLinkButton extends StatelessWidget {
  const _ReaderLinkButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.fontSize = ShosaiTokens.typeSize12,
  });

  final String label;
  final VoidCallback? onPressed;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final scheme = ShadTheme.of(context).colorScheme;
    final enabled = onPressed != null;
    final foreground = enabled
        ? scheme.accentForeground
        : scheme.mutedForeground;
    const padding = EdgeInsets.symmetric(
      vertical: ShosaiTokens.layoutReaderPanelPlaceSpacing,
      horizontal: ShosaiTokens.layoutReaderPanelPlaceRowSpacing,
    );
    final style = shosaiInterfaceStyleForText(
      TextStyle(fontSize: fontSize, color: foreground),
      label,
    );
    // The pinned reference link is its padding plus the label's line box (20-24
    // logical px in the 1C saved-place captures). The Shad button's own minimum
    // height would make the entry taller than the reference, so the link is
    // sized to its content; it keeps the panel width as its target and grows
    // with the text scale, so a scaled interface never clips the label.
    final labelBox = (MediaQuery.textScalerOf(context).scale(fontSize) * 1.25)
        .ceilToDouble();
    return _readerSemanticButton(
      enabled: enabled,
      label: label,
      onPressed: onPressed,
      child: ShadButton.raw(
        variant: ShadButtonVariant.ghost,
        enabled: enabled,
        height: padding.vertical + labelBox,
        padding: padding,
        hoverBackgroundColor: scheme.accent,
        pressedBackgroundColor: scheme.accent,
        foregroundColor: foreground,
        hoverForegroundColor: foreground,
        onPressed: onPressed,
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

/// The fixed-width numeric label of a typography control (the pinned zoom
/// label's 70 px box).
class _ReaderZoomLabel extends StatelessWidget {
  const _ReaderZoomLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: ShosaiTokens.layoutReaderPanelZoomLabelWidth,
    child: Text(
      label,
      textAlign: TextAlign.center,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: shosaiInterfaceStyleForText(
        const TextStyle(
          fontSize: ShosaiTokens.typeSize12,
          color: ShosaiTokens.appTextMuted,
        ),
        label,
      ),
    ),
  );
}

/// A panel-level note: loading, empty and failure copy.
class _ReaderPanelNote extends StatelessWidget {
  const _ReaderPanelNote({
    super.key,
    required this.text,
    this.danger = false,
    this.liveRegion = false,
  });

  final String text;
  final bool danger;
  final bool liveRegion;

  @override
  Widget build(BuildContext context) {
    final style = shosaiInterfaceStyleForText(
      TextStyle(
        fontSize: ShosaiTokens.typeSize12,
        color: danger
            ? ShadTheme.of(context).colorScheme.destructive
            : ShosaiTokens.appTextMuted,
      ),
      text,
    );
    final child = Text(text, style: style);
    return liveRegion ? Semantics(liveRegion: true, child: child) : child;
  }
}

/// The reader's supported theme values, in cycle order (Iced `CycleTheme`).
const List<String> _readerThemes = ['light', 'dark', 'sepia'];

/// The reader's line-spacing steps (the pinned settings values).
const List<double> _readerLineSpacingSteps = [1.2, 1.4, 1.6, 1.8, 2.0];

/// The next line-spacing step after [current], wrapping at the last one.
double _nextReaderLineSpacing(double current) {
  for (final value in _readerLineSpacingSteps) {
    if (value > current + 0.001) return value;
  }
  return _readerLineSpacingSteps.first;
}

/// The next reader theme after [theme], wrapping at the last one.
String _nextReaderTheme(String theme) {
  final index = _readerThemes.indexOf(theme);
  return _readerThemes[(index + 1) % _readerThemes.length];
}

/// The localized name of a reader theme value.
String _readerThemeLabel(AppLocalizations l10n, String theme) =>
    switch (theme) {
      'dark' => l10n.readerThemeDark,
      'sepia' => l10n.readerThemeSepia,
      _ => l10n.readerThemeLight,
    };

/// The zoom label of a raster typography state (the pinned `zoom_label`).
String _readerZoomLabel(
  AppLocalizations l10n,
  ReaderTypographyPresentation typography,
) => switch (typography.rasterFit) {
  ReaderRasterFit.fitPage => l10n.readerFitPage,
  ReaderRasterFit.fitWidth => l10n.readerFitWidth,
  ReaderRasterFit.manual => '${(typography.rasterZoom * 100).round()}%',
};

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
    this.contentSized = false,
  });

  final String label;
  final VoidCallback? onPressed;

  /// Size the action to its padding plus the label's line box.
  ///
  /// The pinned reference's panel actions are content-sized (the export action
  /// renders 35 logical px tall); the component layer's own minimum would make
  /// them taller than the reference. The chrome's alert keeps the shared
  /// component height that 4B verified.
  final bool contentSized;

  @override
  Widget build(BuildContext context) {
    final padding = const EdgeInsets.symmetric(
      vertical: ShosaiTokens.layoutButtonSecondaryPaddingVertical,
      horizontal: ShosaiTokens.layoutButtonSecondaryPaddingHorizontal,
    );
    final labelBox =
        (MediaQuery.textScalerOf(
                  context,
                ).scale(ShosaiTokens.layoutButtonLabelSize) *
                1.25)
            .ceilToDouble();
    return ShadButton.outline(
      height: contentSized
          ? padding.vertical + labelBox
          : shosaiShadButtonHeight(context, padding: padding),
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
