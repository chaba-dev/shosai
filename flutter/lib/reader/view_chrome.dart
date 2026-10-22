part of 'view.dart';

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

/// The design system's keyboard focus ring around [child]: 2 px of `accent`,
/// offset 2 px outside the control, following its corner [radius].
Widget _readerFocusRing({
  required bool focused,
  required Color color,
  required double radius,
  required Widget child,
}) => Stack(
  // The control keeps the constraints it would have had on its own.
  fit: StackFit.passthrough,
  clipBehavior: Clip.none,
  children: [
    child,
    if (focused)
      Positioned(
        left: -4,
        top: -4,
        right: -4,
        bottom: -4,
        child: IgnorePointer(
          child: DecoratedBox(
            key: const ValueKey('reader-focus-ring'),
            decoration: BoxDecoration(
              border: Border.all(color: color, width: 2),
              borderRadius: BorderRadius.circular(radius + 4),
            ),
          ),
        ),
      ),
  ],
);

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
        _ReaderToolButton(
          key: const ValueKey('reader-search-previous'),
          icon: LucideIcons.chevronUp,
          label: l10n.readerPreviousResult,
          onPressed: search.hasResults && !search.busy
              ? () => dispatch(const ReaderSearchResultStepRequested(delta: -1))
              : null,
        ),
        _ReaderToolButton(
          key: const ValueKey('reader-search-next'),
          icon: LucideIcons.chevronDown,
          label: l10n.readerNextResult,
          onPressed: search.hasResults && !search.busy
              ? () => dispatch(const ReaderSearchResultStepRequested(delta: 1))
              : null,
        ),
        // Close stays enabled while a search runs: it cancels the in-flight
        // query (RD-11, contract §5.1).
        _ReaderToolButton(
          key: const ValueKey('reader-search-close'),
          icon: LucideIcons.x,
          label: l10n.readerCloseSearch,
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
    final child = Padding(
      padding: const EdgeInsets.symmetric(horizontal: ShosaiTokens.space1),
      child: Text(text, style: style),
    );
    return liveRegion ? Semantics(liveRegion: true, child: child) : child;
  }
}

/// The page themes in Display settings order: Paper, Sepia, Night.
const List<String> _readerThemes = ['light', 'sepia', 'dark'];

/// The reader's line-spacing steps (the pinned settings values).
const List<double> _readerLineSpacingSteps = [1.2, 1.4, 1.6, 1.8, 2.0];

/// The localized name of a reader theme value.
String _readerThemeLabel(AppLocalizations l10n, String theme) =>
    switch (theme) {
      'dark' => l10n.readerThemeDark,
      'sepia' => l10n.readerThemeSepia,
      _ => l10n.readerThemeLight,
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
    // A refused chapter with no page installed is the content area's own
    // error; over a page still shown it is an alert here.
    final layoutRefusal = model.contentState == ReaderContentState.failed
        ? null
        : model.layoutRefusal?.message;
    final entries = <String>[
      // A failed page layout is not a selection problem: it is rendered as its
      // own message instead of the retained "Selection unavailable" prefix.
      ?relayoutError,
      ?layoutRefusal,
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
                  : entry == layoutRefusal
                  ? const ValueKey('reader-layout-refusal')
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
