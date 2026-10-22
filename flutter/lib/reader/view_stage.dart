part of 'view.dart';

// The reading stage (`docs/design-system.md`, Reading): a lit surface the
// page sits on, with quiet page-turn chevrons in its margins.
//
// | Layout | Stage | Page |
// | --- | --- | --- |
// | Desktop and tablet | `stage` to `stage-edge`, `space-5` around the page | An EPUB page is at most the measure wide, on `page-*` paper with `shadow-page`; a PDF page is the rendered raster |
// | Phone | None: the page is full-bleed | The page fills the stage |

/// The widest EPUB page box: the `measure` (36em) at the default text size
/// plus the page margins.
///
/// The box does not follow the text size: a text-size change already lays the
/// book out again, and a box that moved with it would report a second
/// viewport and lay it out twice.
const double _readerEpubPageMaxWidth =
    ShosaiTokens.sizeMeasure * 18 + 2 * kEpubPageMargin;

/// The width of a page-turn margin beside the page.
const double _readerEdgeWidth = 40;
const double _readerPhoneEdgeWidth = 24;

/// `shadow-page`: a page or spread on the stage.
List<BoxShadow> _readerPageShadow(ShellPalette palette) => [
  BoxShadow(
    color: palette.shadowBase.withValues(alpha: palette.dark ? .9 : .55),
    offset: const Offset(0, 30),
    blurRadius: 50,
    spreadRadius: -28,
  ),
  BoxShadow(
    color: palette.shadowBase.withValues(alpha: palette.dark ? .6 : .3),
    offset: const Offset(0, 10),
    blurRadius: 20,
    spreadRadius: -12,
  ),
  BoxShadow(
    color: palette.dark
        ? ShosaiTokens.colorDarkInk.withValues(alpha: .05)
        : palette.shadowBase.withValues(alpha: .07),
    spreadRadius: 1,
  ),
];

/// Whether the reader lays its document out as EPUB pages on paper.
///
/// Before a document arrives the open's path decides, so the page box the open
/// is laid out for is the box the document keeps.
bool _readerShowsPaper(ReaderModel model) {
  final document = model.document;
  if (document != null) return document.format == FlutterBookFormat.epub;
  final path = model.openPath?.toLowerCase();
  return path != null && path.endsWith('.epub');
}

/// The stage with the page box on it and the page-turn margins beside it.
class _ReaderStage extends StatelessWidget {
  const _ReaderStage({
    required this.model,
    required this.layout,
    required this.dispatch,
    required this.content,
  });

  final ReaderModel model;
  final ShellLayout layout;
  final void Function(ReaderMessage) dispatch;
  final Widget content;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final palette = ShellPalette.of(context);
    final colors = pageColors(model.typography.theme);
    final phone = layout == ShellLayout.phone;
    final document = model.document;
    final continuous = model.continuousPresentation;
    final paper = _readerShowsPaper(model);
    // Continuous mode scrolls instead of turning pages, so it has no margins;
    // a paginated reader keeps them while it opens, so the page box does not
    // change width when the document arrives.
    final showEdges = !continuous;
    final busy = model.busy || model.relayoutBusy;
    final total = document?.logicalUnitCount.toInt() ?? 0;
    final edgeWidth = phone ? _readerPhoneEdgeWidth : _readerEdgeWidth;
    final edgeColor = phone && paper ? colors.foreground : palette.inkMuted;
    Widget edge(int delta) => SizedBox(
      width: edgeWidth,
      child: Visibility(
        visible: document != null,
        maintainSize: true,
        maintainAnimation: true,
        maintainState: true,
        child: _ReaderEdgeButton(
          semanticsKey: ValueKey(
            delta < 0 ? 'reader-edge-previous' : 'reader-edge-next',
          ),
          icon: delta < 0 ? LucideIcons.chevronLeft : LucideIcons.chevronRight,
          semanticsLabel: delta < 0
              ? l10n.readerPreviousPage
              : l10n.readerNextPage,
          color: edgeColor,
          onPressed:
              document != null && !busy && _canStepPage(model, delta, total)
              ? () => dispatch(pageStepMessage(model, delta))
              : null,
        ),
      ),
    );

    final pageArea = LayoutBuilder(
      builder: (context, constraints) {
        if (phone || !paper) return content;
        final width = math.min(constraints.maxWidth, _readerEpubPageMaxWidth);
        return Center(
          child: SizedBox(
            key: const ValueKey('reader-page'),
            width: width,
            height: constraints.maxHeight,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colors.background,
                borderRadius: BorderRadius.circular(3),
                boxShadow: _readerPageShadow(palette),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(3),
                // The page's own margins around the layout's: a page on the
                // stage reads with wider margins than a full-bleed phone page.
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: ShosaiTokens.space5,
                    vertical: ShosaiTokens.space4,
                  ),
                  child: content,
                ),
              ),
            ),
          ),
        );
      },
    );

    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showEdges) edge(-1),
        Expanded(child: pageArea),
        if (showEdges) edge(1),
      ],
    );
    if (phone) {
      // The phone page is full-bleed: the stage is the page.
      return ColoredBox(
        key: const ValueKey('reader-stage'),
        color: paper ? colors.background : palette.canvas,
        child: row,
      );
    }
    return DecoratedBox(
      key: const ValueKey('reader-stage'),
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: const Alignment(0, -.4),
          radius: 1.2,
          colors: palette.dark
              ? const [
                  ShosaiTokens.colorDarkStage,
                  ShosaiTokens.colorDarkStageEdge,
                ]
              : const [
                  ShosaiTokens.colorLightStage,
                  ShosaiTokens.colorLightStageEdge,
                ],
        ),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          vertical: continuous ? 0 : ShosaiTokens.space5,
          horizontal: showEdges
              ? ShosaiTokens.space5 - _readerEdgeWidth / 2
              : ShosaiTokens.space5,
        ),
        child: row,
      ),
    );
  }
}

/// One page-turn margin (RD-06): a quiet chevron the height of the stage.
class _ReaderEdgeButton extends StatelessWidget {
  const _ReaderEdgeButton({
    required this.icon,
    required this.semanticsKey,
    required this.semanticsLabel,
    required this.color,
    required this.onPressed,
  });

  final IconData icon;
  final Key semanticsKey;
  final String semanticsLabel;
  final Color color;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = ShellPalette.of(context);
    final enabled = onPressed != null;
    final ink = enabled ? color : color.withValues(alpha: .3);
    return _readerSemanticButton(
      key: semanticsKey,
      enabled: enabled,
      label: semanticsLabel,
      onPressed: onPressed,
      child: ShadButton.raw(
        variant: ShadButtonVariant.ghost,
        enabled: enabled,
        width: double.infinity,
        height: double.infinity,
        padding: EdgeInsets.zero,
        backgroundColor: palette.hover.withValues(alpha: 0),
        hoverBackgroundColor: palette.hover.withValues(alpha: .5),
        pressedBackgroundColor: palette.hover,
        foregroundColor: ink,
        hoverForegroundColor: ink,
        decoration: ShadDecoration(
          border: ShadBorder.all(radius: BorderRadius.circular(6), width: 0),
        ),
        onPressed: onPressed,
        child: Icon(icon, size: 20, color: ink),
      ),
    );
  }
}
