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

/// The narrowest book-text column a spread may give each page, in ems of the
/// book's text size: below it the reader shows one page rather than shrink
/// the text to fit two.
const double _readerSpreadMinColumnEms = 12;

/// Whether the stage shows two pages side by side (`docs/design-system.md`,
/// Reading surfaces).
///
/// Two pages need the Pages setting, a paginated reader off the phone, a page
/// area at least `spread-min-width` wide and wider than it is tall, and for
/// EPUB a text column of at least [_readerSpreadMinColumnEms] on each page.
bool _readerShowsSpread(
  ReaderModel model,
  ShellLayout layout,
  BoxConstraints area,
) {
  final typography = model.typography;
  if (layout == ShellLayout.phone ||
      !typography.twoPages ||
      model.continuousPresentation ||
      area.maxWidth < ShosaiTokens.sizeSpreadMinWidth ||
      area.maxWidth < area.maxHeight) {
    return false;
  }
  // A PDF page without a partner (the last of an odd count, or a document of
  // one page) is shown alone in the spread's box.
  if (!_readerShowsPaper(model)) return true;
  final paper = math.min(area.maxWidth, 2 * _readerEpubPageMaxWidth);
  final column =
      epubSpreadPageWidth(paper - 2 * ShosaiTokens.space5) -
      2 * kEpubPageMargin;
  return column >= _readerSpreadMinColumnEms * typography.epubFontSize;
}

/// Tells the layout reporter under the stage whether the stage shows a
/// spread, so the page is laid out for the slots the stage draws.
class _ReaderSpreadScope extends InheritedWidget {
  const _ReaderSpreadScope({required this.spread, required super.child});

  final bool spread;

  static bool of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_ReaderSpreadScope>()
          ?.spread ??
      false;

  @override
  bool updateShouldNotify(_ReaderSpreadScope oldWidget) =>
      spread != oldWidget.spread;
}

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
    final showEdges = !continuous && layout == ShellLayout.desktop;
    final busy = model.busy || model.relayoutBusy;
    final total = document?.logicalUnitCount.toInt() ?? 0;
    final edgeWidth = _readerEdgeWidth;
    final edgeColor = phone && paper ? colors.foreground : palette.inkMuted;
    // A right-to-left book turns leftward: its next page is behind the left
    // margin. Each chevron still points away from the page.
    final rightToLeft = model.rightToLeft;
    Widget edge(int delta, {required bool left}) => SizedBox(
      width: edgeWidth,
      child: Visibility(
        visible: document != null && model.chromeShown && model.pointerChrome,
        maintainSize: true,
        maintainAnimation: true,
        maintainState: true,
        child: MouseRegion(
          onEnter: (_) => dispatch(const ReaderChromeHovered(true)),
          onExit: (_) => dispatch(const ReaderChromeHovered(false)),
          child: _ReaderEdgeButton(
            semanticsKey: ValueKey(
              delta < 0 ? 'reader-edge-previous' : 'reader-edge-next',
            ),
            icon: left ? LucideIcons.chevronLeft : LucideIcons.chevronRight,
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
      ),
    );

    final pageArea = LayoutBuilder(
      builder: (context, constraints) {
        final spread = _readerShowsSpread(model, layout, constraints);
        final scoped = _ReaderSpreadScope(
          spread: spread,
          child: paper
              ? _ReaderPageFurniture(
                  model: model,
                  spread: spread,
                  child: content,
                )
              : phone && document != null
              ? Column(
                  children: [
                    Expanded(child: content),
                    Padding(
                      padding: const EdgeInsets.all(ShosaiTokens.space3),
                      child: _ReaderFolio(model: model, muted: true),
                    ),
                  ],
                )
              : content,
        );
        if (phone || !paper) {
          return _ReaderPageTapScope(
            model: model,
            dispatch: dispatch,
            child: scoped,
          );
        }
        // A spread is two pages of paper side by side, each as wide as a
        // single page may be, under one `shadow-page`.
        final width = math.min(
          constraints.maxWidth,
          (spread ? 2 : 1) * _readerEpubPageMaxWidth,
        );
        return Center(
          child: SizedBox(
            key: const ValueKey('reader-page'),
            width: width,
            height: constraints.maxHeight,
            child: _ReaderPageTapScope(
              model: model,
              dispatch: dispatch,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.background,
                  borderRadius: BorderRadius.circular(3),
                  boxShadow: _readerPageShadow(palette),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // The page's own margins around the layout's: a page on
                      // the stage reads with wider margins than a full-bleed
                      // phone page.
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: ShosaiTokens.space5,
                          vertical: ShosaiTokens.space4,
                        ),
                        child: scoped,
                      ),
                      if (spread)
                        Center(
                          child: _ReaderSpreadGutter(
                            shade: palette.shadowBase,
                            dark: palette.dark,
                            rightToLeft: rightToLeft,
                          ),
                        ),
                    ],
                  ),
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
        if (showEdges) edge(rightToLeft ? 1 : -1, left: true),
        Expanded(child: pageArea),
        if (showEdges) edge(rightToLeft ? -1 : 1, left: false),
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

/// The fold between the two pages of a spread: the second page darkens toward
/// its inner edge, as `sh-spread`'s inset shadow does. A right-to-left
/// spread's second page is the left one.
class _ReaderSpreadGutter extends StatelessWidget {
  const _ReaderSpreadGutter({
    required this.shade,
    required this.dark,
    required this.rightToLeft,
  });

  final Color shade;
  final bool dark;
  final bool rightToLeft;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: SizedBox(
      key: const ValueKey('reader-spread-gutter'),
      width: 32,
      height: double.infinity,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: rightToLeft ? Alignment.centerRight : Alignment.centerLeft,
            end: rightToLeft ? Alignment.centerLeft : Alignment.centerRight,
            colors: [
              shade.withValues(alpha: 0),
              shade.withValues(alpha: 0),
              shade.withValues(alpha: dark ? .3 : .16),
              shade.withValues(alpha: 0),
            ],
            stops: const [0, .5, .5, 1],
          ),
        ),
      ),
    ),
  );
}

/// Shares page coordinates with the selectable surface. Links and long presses
/// keep their own gestures; only a completed non-link tap reaches this scope.
class _ReaderPageTapScope extends StatefulWidget {
  const _ReaderPageTapScope({
    required this.model,
    required this.dispatch,
    required this.child,
  });
  final ReaderModel model;
  final void Function(ReaderMessage) dispatch;
  final Widget child;

  static ReaderPageTapped? tap(
    BuildContext context,
    Offset global,
    ui.PointerDeviceKind? kind,
  ) {
    final scope = context.findAncestorWidgetOfExactType<_ReaderPageTapHost>();
    return scope?.tap(global, kind);
  }

  @override
  State<_ReaderPageTapScope> createState() => _ReaderPageTapScopeState();
}

class _ReaderPageTapScopeState extends State<_ReaderPageTapScope> {
  bool _active = true;

  @override
  void deactivate() {
    _active = false;
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _active = true;
  }

  @override
  Widget build(BuildContext context) => Builder(
    builder: (context) {
      ReaderPageTapped? tap(Offset global, ui.PointerDeviceKind? kind) {
        if (!_active) return null;
        final box = context.findRenderObject()! as RenderBox;
        return ReaderPageTapped(
          box.globalToLocal(global).dx / box.size.width,
          touch:
              kind != ui.PointerDeviceKind.mouse ||
              ShellLayout.forWidth(MediaQuery.sizeOf(context).width) !=
                  ShellLayout.desktop,
        );
      }

      return _ReaderPageTapHost(
        tap: tap,
        // Content's recognizer wins within the document (including PDF
        // pan/pinch and selection). This ancestor handles furniture/margins.
        child: _ReaderPageGestures(
          model: widget.model,
          dispatch: widget.dispatch,
          fittedZoom: null,
          builder: (_, _) => GestureDetector(
            behavior: HitTestBehavior.opaque,
            excludeFromSemantics: true,
            onTapUp: (details) {
              if (tap(details.globalPosition, details.kind)
                  case final message?) {
                widget.dispatch(message);
              }
            },
            child: widget.child,
          ),
        ),
      );
    },
  );
}

class _ReaderPageTapHost extends InheritedWidget {
  const _ReaderPageTapHost({required this.tap, required super.child});
  final ReaderPageTapped? Function(Offset, ui.PointerDeviceKind?) tap;
  @override
  bool updateShouldNotify(_ReaderPageTapHost oldWidget) => tap != oldWidget.tap;
}

TextStyle _readerFolioStyle(ReaderModel model, {Color? color}) => TextStyle(
  fontFamily: shosaiInterfaceFontFamily,
  fontFamilyFallback: shosaiInterfaceFontFallback,
  fontSize: ShosaiTokens.readerFolioFontSize,
  height: ShosaiTokens.readerFolioLineHeight / ShosaiTokens.readerFolioFontSize,
  fontWeight: FontWeight.w400,
  color:
      color ??
      pageColors(
        model.typography.theme,
      ).foreground.withValues(alpha: ShosaiTokens.readerFolioInkAlpha),
);

class _ReaderFolio extends StatelessWidget {
  const _ReaderFolio({required this.model, this.ordinal, this.muted = false});
  final ReaderModel model;
  final int? ordinal;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final progress = model.progress;
    final l10n = AppLocalizations.of(context);
    final page = ordinal ?? progress.firstOrdinal;
    final text =
        model.typography.progress == FlutterReaderProgress.off || page == null
        ? ''
        : model.typography.progress == FlutterReaderProgress.percent
        ? '${progress.percentage}%'
        : model.document?.format == FlutterBookFormat.pdf
        ? l10n.readerQuietPageOf(page, model.document!.logicalUnitCount.toInt())
        : l10n.readerPageNumber(page);
    return Text(
      text,
      key: const ValueKey('reader-folio'),
      textAlign: TextAlign.center,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: _readerFolioStyle(
        model,
        color: muted ? ShellPalette.of(context).inkMuted : null,
      ),
    );
  }
}

class _ReaderPageFurniture extends StatelessWidget {
  const _ReaderPageFurniture({
    required this.model,
    required this.spread,
    required this.child,
  });
  final ReaderModel model;
  final bool spread;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final first = model.progress.firstOrdinal;
    final ordinals = <int?>[first, if (spread) model.progress.lastOrdinal];
    final physical = model.rightToLeft ? ordinals.reversed : ordinals;
    final heading =
        model.contents.entries.where((e) => e.current).firstOrNull?.title ??
        model.document?.title ??
        '';
    return Column(
      children: [
        SizedBox(
          height: 28,
          child: Row(
            children: [
              for (final ordinal in physical)
                Expanded(
                  child: Center(
                    child: Text(
                      // Chapter openings leave this space quiet, with the title below.
                      ordinal == null || ordinal == 1 || model.document == null
                          ? ''
                          : heading,
                      key: const ValueKey('reader-running-head'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _readerFolioStyle(model),
                    ),
                  ),
                ),
            ],
          ),
        ),
        Expanded(child: child),
        SizedBox(
          height: 28,
          child: Row(
            children: [
              for (final ordinal in physical)
                Expanded(
                  child: Center(
                    child: ordinal == null
                        ? const SizedBox.shrink()
                        : _ReaderFolio(model: model, ordinal: ordinal),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ReaderZonesHint extends StatelessWidget {
  const _ReaderZonesHint({required this.rightToLeft, required this.dismiss});
  final bool rightToLeft;
  final VoidCallback dismiss;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final ink = ShosaiTokens.colorLightOnInverse;
    final labels = [
      rightToLeft ? l10n.readerNextPage : l10n.readerPreviousPage,
      l10n.readerControls,
      rightToLeft ? l10n.readerPreviousPage : l10n.readerNextPage,
    ];
    return Semantics(
      key: const ValueKey('reader-zones-hint'),
      scopesRoute: true,
      explicitChildNodes: true,
      namesRoute: true,
      label: l10n.readerZonesTitle,
      onTap: dismiss,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: dismiss,
        child: ColoredBox(
          color: ShosaiTokens.colorLightInverse.withValues(alpha: .62),
          child: Stack(
            children: [
              Row(
                children: [
                  for (var i = 0; i < 3; i++)
                    Expanded(
                      child: CustomPaint(
                        painter: i == 0
                            ? null
                            : _ReaderZonesStroke(
                                color: ink.withValues(alpha: .45),
                              ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            SizedBox(
                              width: 44,
                              height: 44,
                              child: CustomPaint(
                                painter: _ReaderZonesStroke(
                                  color: ink.withValues(alpha: .7),
                                  ring: true,
                                  dashed: i == 1,
                                ),
                                child: Icon(
                                  [
                                    LucideIcons.chevronLeft,
                                    LucideIcons.list,
                                    LucideIcons.chevronRight,
                                  ][i],
                                  size: 22,
                                  color: ink,
                                ),
                              ),
                            ),
                            const SizedBox(height: ShosaiTokens.space2),
                            Text(
                              labels[i],
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontFamily: shosaiInterfaceFontFamily,
                                fontFamilyFallback: shosaiInterfaceFontFallback,
                                fontSize: 13,
                                height: 18 / 13,
                                fontWeight: FontWeight.w500,
                                color: ink,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
              Positioned(
                left: 16,
                right: 16,
                bottom: 56,
                child: Text(
                  rightToLeft
                      ? l10n.readerZonesLeftward
                      : l10n.readerZonesInstruction,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: shosaiInterfaceFontFamily,
                    fontFamilyFallback: shosaiInterfaceFontFallback,
                    fontSize: 12,
                    height: 16 / 12,
                    color: ink,
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

/// The dashed zone dividers and ringed glyphs of `sh-zones`.
class _ReaderZonesStroke extends CustomPainter {
  const _ReaderZonesStroke({
    required this.color,
    this.ring = false,
    this.dashed = true,
  });
  final Color color;
  final bool ring;
  final bool dashed;

  @override
  void paint(Canvas canvas, Size size) {
    final path = ring
        ? (Path()..addOval((Offset.zero & size).deflate(.75)))
        : (Path()..lineTo(0, size.height));
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = ring ? 1.5 : 1;
    if (!dashed) {
      canvas.drawPath(path, paint);
      return;
    }
    for (final metric in path.computeMetrics()) {
      for (var start = 0.0; start < metric.length; start += 8) {
        canvas.drawPath(metric.extractPath(start, start + 4), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_ReaderZonesStroke oldDelegate) =>
      color != oldDelegate.color ||
      ring != oldDelegate.ring ||
      dashed != oldDelegate.dashed;
}
