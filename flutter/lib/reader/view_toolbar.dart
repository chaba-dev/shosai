part of 'view.dart';

// The reader's own bars in the Bookshelf look (`docs/design-system.md`,
// Navigation: ReaderToolbar and StatusBar):
//
// | Layout | Toolbar | Under the page |
// | --- | --- | --- |
// | Desktop and tablet | Contents and Search, the title and section, then Aa, Bookmark and Notes | The status line |
// | Phone | Back, the title and section, Search and the open books | A bar with Contents, Aa, the place, Bookmark and Notes |
//
// The same controls exist for EPUB and PDF; only their arrangement adapts.

/// The bookmark that marks the reader's current place, if any.
FlutterBookmark? _currentBookmark(ReaderModel model) => model.bookmarks
    .where(
      (bookmark) =>
          bookmark.unit.toInt() == model.unit &&
          bookmark.offset?.toInt() == model.readingOffset,
    )
    .firstOrNull;

/// The title of the Contents entry the reader is in, when the entries are
/// loaded and the entry has one.
String? _currentSectionTitle(ReaderModel model) {
  final contents = model.contents;
  if (contents.status != ReaderContentsStatus.ready) return null;
  for (final entry in contents.entries) {
    if (entry.current && entry.title.trim().isNotEmpty) {
      return entry.title.trim();
    }
  }
  return null;
}

/// Whether the chrome may start a new action: a document is open and no open,
/// relayout or modal effect is in flight (contract §3.1, §5.1).
bool _readerChromeEnabled(ReaderModel model) =>
    model.document != null &&
    !model.busy &&
    !model.relayoutBusy &&
    model.modalEffect == null;

/// The reader toolbar: `toolbar-height` on `chrome`, on every layout.
class _ReaderToolbar extends StatelessWidget {
  const _ReaderToolbar({
    required this.model,
    required this.layout,
    required this.dispatch,
    required this.backFocus,
    required this.contentsFocus,
    required this.typographyFocus,
    required this.notesFocus,
    this.openBooksAction,
  });

  final ReaderModel model;
  final ShellLayout layout;
  final void Function(ReaderMessage) dispatch;
  final FocusNode backFocus;
  final FocusNode contentsFocus;
  final FocusNode typographyFocus;
  final FocusNode notesFocus;

  /// The shell's open-book count button, shown at the phone toolbar's end.
  final Widget? openBooksAction;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final palette = ShellPalette.of(context);
    final enabled = _readerChromeEnabled(model);
    final phone = layout == ShellLayout.phone;
    final title = _ReaderToolbarTitle(
      title: model.document?.title ?? l10n.readerFallbackTitle,
      section: _currentSectionTitle(model),
    );
    final search = _ReaderToolButton(
      key: const ValueKey('reader-header-search'),
      icon: LucideIcons.search,
      label: l10n.readerSearchAction,
      selected: model.searchOpen,
      touch: layout.touch,
      onPressed: enabled && model.typography.searchable
          ? () => dispatch(const ReaderSearchToggled())
          : null,
    );
    final List<Widget> leading;
    final List<Widget> trailing;
    if (phone) {
      leading = [
        _ReaderToolButton(
          key: const ValueKey('reader-header-back'),
          icon: LucideIcons.chevronLeft,
          label: l10n.readerBackToLibrary,
          touch: true,
          focusNode: backFocus,
          onPressed: () => dispatch(const ReaderBackRequested()),
        ),
      ];
      trailing = [search, ?openBooksAction];
    } else {
      leading = [
        _ReaderToolButton(
          key: const ValueKey('reader-header-contents'),
          icon: LucideIcons.list,
          label: l10n.readerContentsAction,
          selected: model.openPanel == ReaderPanel.contents,
          touch: layout.touch,
          focusNode: contentsFocus,
          onPressed: enabled
              ? () => dispatch(const ReaderPanelToggled(ReaderPanel.contents))
              : null,
        ),
        search,
      ];
      trailing = _readerPageActions(
        context,
        model: model,
        layout: layout,
        dispatch: dispatch,
        typographyFocus: typographyFocus,
        notesFocus: notesFocus,
        includeNotesLabel: true,
      );
    }
    return Semantics(
      container: true,
      explicitChildNodes: true,
      child: Container(
        key: const ValueKey('reader-header'),
        constraints: const BoxConstraints(
          minHeight: ShosaiTokens.sizeToolbarHeight,
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: ShosaiTokens.space3,
          vertical: ShosaiTokens.space1,
        ),
        decoration: BoxDecoration(
          color: palette.chrome,
          border: Border(bottom: BorderSide(color: palette.line)),
        ),
        // The title takes the room between the two groups and stays centred
        // on the bar while the groups differ in width.
        child: Row(
          children: [
            _ReaderToolGroup(children: leading),
            const SizedBox(width: ShosaiTokens.space2),
            Expanded(child: title),
            const SizedBox(width: ShosaiTokens.space2),
            _ReaderToolGroup(children: trailing),
          ],
        ),
      ),
    );
  }
}

/// A row of toolbar controls a scaled interface can wrap instead of clip.
class _ReaderToolGroup extends StatelessWidget {
  const _ReaderToolGroup({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    spacing: ShosaiTokens.space1,
    children: children,
  );
}

/// The reader's page actions in one order: Display settings (Aa), Bookmark,
/// then Notes with its count.
///
/// The toolbar shows them on desktop and tablet; on a phone they move to the
/// bar under the page.
List<Widget> _readerPageActions(
  BuildContext context, {
  required ReaderModel model,
  required ShellLayout layout,
  required void Function(ReaderMessage) dispatch,
  required FocusNode typographyFocus,
  required FocusNode notesFocus,
  required bool includeNotesLabel,
}) {
  final l10n = AppLocalizations.of(context);
  final palette = ShellPalette.of(context);
  final enabled = _readerChromeEnabled(model);
  final bookmark = _currentBookmark(model);
  final document = model.document;
  return [
    _ReaderToolButton(
      key: const ValueKey('reader-header-typography'),
      text: 'Aa',
      label: l10n.readerAppearanceAction,
      selected: model.openPanel == ReaderPanel.typography,
      touch: layout.touch,
      focusNode: typographyFocus,
      onPressed: enabled
          ? () => dispatch(const ReaderPanelToggled(ReaderPanel.typography))
          : null,
    ),
    _ReaderToolButton(
      key: const ValueKey('reader-header-bookmark'),
      icon: LucideIcons.bookmark,
      // The bookmark fills with vermilion when the page is bookmarked.
      iconFill: bookmark == null ? null : ShosaiTokens.colorLightVermilion,
      foreground: bookmark == null ? null : ShosaiTokens.colorLightVermilion,
      label: bookmark == null
          ? l10n.readerBookmarkPage
          : l10n.readerRemoveBookmark,
      selected: bookmark != null,
      selectedFill: false,
      touch: layout.touch,
      onPressed:
          enabled &&
              !model.bookmarkBusy &&
              document != null &&
              document.bookId != null
          ? () => dispatch(const ReaderBookmarkToggled())
          : null,
    ),
    _ReaderToolButton(
      key: const ValueKey('reader-header-notes'),
      icon: LucideIcons.messageSquareText,
      text: includeNotesLabel ? l10n.readerNotesAction : null,
      label: l10n.readerNotesAction,
      count: model.annotations.isEmpty ? null : model.annotations.length,
      countColor: palette.surfaceSunken,
      selected: model.openPanel == ReaderPanel.notes,
      touch: layout.touch,
      focusNode: notesFocus,
      onPressed: enabled
          ? () => dispatch(const ReaderPanelToggled(ReaderPanel.notes))
          : null,
    ),
  ];
}

/// The book title in the editorial serif, then the current section.
class _ReaderToolbarTitle extends StatelessWidget {
  const _ReaderToolbarTitle({required this.title, required this.section});

  final String title;
  final String? section;

  @override
  Widget build(BuildContext context) {
    final palette = ShellPalette.of(context);
    final section = this.section;
    return Semantics(
      key: const ValueKey('reader-header-title'),
      header: true,
      label: section == null ? title : '$title, $section',
      child: ExcludeSemantics(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              // A taller line than the 21 of the type scale: Literata's
              // descenders fall below a 21 line box at a scaled interface,
              // and further on macOS than on Linux.
              style: shellEditorialStyle(17, 24).copyWith(color: palette.ink),
            ),
            if (section != null)
              Text(
                section,
                key: const ValueKey('reader-header-section'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: shellInterfaceStyle(
                  12,
                  16,
                ).copyWith(color: palette.inkMuted),
              ),
          ],
        ),
      ),
    );
  }
}

/// A quiet toolbar control: an icon, a short text ("Aa") or both, with an
/// optional count, the `accent-soft` fill when [selected] and a tooltip with
/// the same words as its accessible label.
class _ReaderToolButton extends StatelessWidget {
  const _ReaderToolButton({
    super.key,
    this.icon,
    this.text,
    required this.label,
    required this.onPressed,
    this.selected = false,
    this.selectedFill = true,
    this.touch = false,
    this.count,
    this.countColor,
    this.iconFill,
    this.foreground,
    this.focusNode,
  });

  final IconData? icon;
  final String? text;

  /// The accessible name and tooltip.
  final String label;
  final VoidCallback? onPressed;
  final bool selected;

  /// Whether [selected] paints the `accent-soft` fill; the bookmark shows its
  /// state with a filled glyph instead.
  final bool selectedFill;

  /// Touch layouts get a `touch-target` box and 20 px glyphs.
  final bool touch;
  final int? count;
  final Color? countColor;
  final Color? iconFill;
  final Color? foreground;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final palette = ShellPalette.of(context);
    final enabled = onPressed != null;
    final filled = selected && selectedFill;
    final ink = !enabled
        ? palette.inkMuted.withValues(alpha: .55)
        : foreground ??
              (filled ? ShosaiTokens.colorLightOnAccentSoft : palette.ink);
    final box = touch
        ? ShosaiTokens.sizeTouchTarget
        : ShosaiTokens.sizeControlHeight;
    final glyphSize = touch ? 20.0 : 16.0;
    final icon = this.icon;
    final text = this.text;
    final count = this.count;
    final iconOnly = text == null && count == null;
    final children = <Widget>[
      if (icon != null)
        iconFill == null
            ? Icon(icon, size: glyphSize, color: ink)
            : _FilledGlyph(icon: icon, size: glyphSize, fill: iconFill!),
      if (text != null)
        Text(
          text,
          maxLines: 1,
          style: text == 'Aa'
              ? shellInterfaceStyle(
                  14,
                  18,
                  weight: FontWeight.w600,
                ).copyWith(color: ink, letterSpacing: -.14)
              : shellInterfaceStyle(
                  13,
                  18,
                  weight: FontWeight.w500,
                ).copyWith(color: ink),
        ),
      if (count != null)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(
            color: filled ? palette.surface : countColor,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Text(
            '$count',
            style: shellInterfaceStyle(11, 18, weight: FontWeight.w600)
                .copyWith(
                  color: filled
                      ? ShosaiTokens.colorLightOnAccentSoft
                      : palette.inkMuted,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
          ),
        ),
    ];
    final button = ShadButton.raw(
      variant: ShadButtonVariant.ghost,
      focusNode: focusNode,
      enabled: enabled,
      width: iconOnly ? box : null,
      height: math.max(
        box,
        MediaQuery.textScalerOf(context).scale(18) + ShosaiTokens.space2,
      ),
      padding: iconOnly
          ? EdgeInsets.zero
          : const EdgeInsets.symmetric(horizontal: ShosaiTokens.space2),
      backgroundColor: filled ? ShosaiTokens.colorLightAccentSoft : null,
      hoverBackgroundColor: filled
          ? ShosaiTokens.colorLightAccentSoft
          : palette.hover,
      pressedBackgroundColor: filled
          ? ShosaiTokens.colorLightAccentSoft
          : palette.hover,
      foregroundColor: ink,
      hoverForegroundColor: ink,
      decoration: ShadDecoration(
        border: ShadBorder.all(radius: BorderRadius.circular(6), width: 0),
      ),
      onPressed: onPressed,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: ShosaiTokens.space1 + 2,
        children: children,
      ),
    );
    // The semantic button is the outermost node, so the control's key finds
    // the node that carries the label and the activation action.
    return _readerSemanticButton(
      enabled: enabled,
      selected: selected,
      label: label,
      onPressed: onPressed,
      child: Tooltip(message: label, child: button),
    );
  }
}

/// A Lucide outline glyph with its inside filled: the bookmarked page's
/// vermilion bookmark.
class _FilledGlyph extends StatelessWidget {
  const _FilledGlyph({
    required this.icon,
    required this.size,
    required this.fill,
  });

  final IconData icon;
  final double size;
  final Color fill;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: CustomPaint(
      painter: _BookmarkFillPainter(fill),
      child: Icon(icon, size: size, color: fill),
    ),
  );
}

/// Fills the Lucide bookmark's outline (`M19 21l-7-4-7 4V5a2 2 0 0 1 2-2h10a2
/// 2 0 0 1 2 2v16z` on its 24 px grid).
class _BookmarkFillPainter extends CustomPainter {
  const _BookmarkFillPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final unit = size.width / 24;
    final path = Path()
      ..moveTo(19 * unit, 21 * unit)
      ..lineTo(12 * unit, 17 * unit)
      ..lineTo(5 * unit, 21 * unit)
      ..lineTo(5 * unit, 5 * unit)
      ..arcToPoint(
        Offset(7 * unit, 3 * unit),
        radius: Radius.circular(2 * unit),
      )
      ..lineTo(17 * unit, 3 * unit)
      ..arcToPoint(
        Offset(19 * unit, 5 * unit),
        radius: Radius.circular(2 * unit),
      )
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_BookmarkFillPainter oldDelegate) =>
      oldDelegate.color != color;
}

/// The phone's bar under the page: Contents, Aa, the place, Bookmark and
/// Notes.
class _ReaderPhoneBar extends StatelessWidget {
  const _ReaderPhoneBar({
    required this.model,
    required this.dispatch,
    required this.contentsFocus,
    required this.typographyFocus,
    required this.notesFocus,
  });

  final ReaderModel model;
  final void Function(ReaderMessage) dispatch;
  final FocusNode contentsFocus;
  final FocusNode typographyFocus;
  final FocusNode notesFocus;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final palette = ShellPalette.of(context);
    final enabled = _readerChromeEnabled(model);
    final actions = _readerPageActions(
      context,
      model: model,
      layout: ShellLayout.phone,
      dispatch: dispatch,
      typographyFocus: typographyFocus,
      notesFocus: notesFocus,
      includeNotesLabel: false,
    );
    return Container(
      key: const ValueKey('reader-phone-bar'),
      constraints: const BoxConstraints(
        minHeight: ShosaiTokens.sizeToolbarHeight,
      ),
      padding: const EdgeInsets.symmetric(horizontal: ShosaiTokens.space2),
      decoration: BoxDecoration(
        color: palette.chrome,
        border: Border(top: BorderSide(color: palette.line)),
      ),
      child: Row(
        children: [
          _ReaderToolButton(
            key: const ValueKey('reader-header-contents'),
            icon: LucideIcons.list,
            label: l10n.readerContentsAction,
            selected: model.openPanel == ReaderPanel.contents,
            touch: true,
            focusNode: contentsFocus,
            onPressed: enabled
                ? () => dispatch(const ReaderPanelToggled(ReaderPanel.contents))
                : null,
          ),
          actions.first,
          Expanded(child: _ReaderPlaceLabel(model: model, short: true)),
          ...actions.skip(1),
        ],
      ),
    );
  }
}

/// The status line under the page on desktop and tablet: the section, the
/// progress track with the bookmarks as ticks, then the place.
class _ReaderStatusLine extends StatelessWidget {
  const _ReaderStatusLine({required this.model, required this.dispatch});

  final ReaderModel model;
  final void Function(ReaderMessage) dispatch;

  @override
  Widget build(BuildContext context) {
    final palette = ShellPalette.of(context);
    final document = model.document;
    final section = _currentSectionTitle(model);
    final total = document?.logicalUnitCount.toInt() ?? 0;
    final style = shellInterfaceStyle(12, 16).copyWith(
      color: palette.inkMuted,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return Container(
      key: const ValueKey('reader-status-line'),
      constraints: const BoxConstraints(
        minHeight: ShosaiTokens.sizeStatusbarHeight,
      ),
      padding: const EdgeInsets.symmetric(horizontal: ShosaiTokens.space4),
      decoration: BoxDecoration(
        color: palette.chrome,
        border: Border(top: BorderSide(color: palette.line)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) => Row(
          spacing: ShosaiTokens.space3,
          children: [
            if (section != null)
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: constraints.maxWidth * .4,
                ),
                child: Text(
                  section,
                  key: const ValueKey('reader-status-section'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: style,
                ),
              ),
            Expanded(
              child: document != null && model.progress.hasDocument
                  ? _ReaderProgressTrack(
                      value: model.progress.percentage / 100,
                      marks: [
                        if (total > 0)
                          for (final bookmark in model.bookmarks)
                            (bookmark.unit.toInt() + .5) / total,
                      ],
                      valueLabel: _readerStatusLabel(
                        AppLocalizations.of(context),
                        model.progress,
                        total: total,
                        short: false,
                      ),
                      onJump: total > 0 && !model.busy
                          ? (fraction) => dispatch(
                              ReaderUnitRequested(
                                (fraction * total).floor().clamp(0, total - 1),
                              ),
                            )
                          : null,
                      increasedValue: _unitStepValue(context, model, 1),
                      decreasedValue: _unitStepValue(context, model, -1),
                      onStep: total > 0 && !model.busy
                          ? (delta) {
                              final unit = (model.unit + delta).clamp(
                                0,
                                total - 1,
                              );
                              if (unit != model.unit) {
                                dispatch(ReaderUnitRequested(unit));
                              }
                            }
                          : null,
                    )
                  : const SizedBox.shrink(),
            ),
            _ReaderPlaceLabel(model: model, short: false),
          ],
        ),
      ),
    );
  }
}

/// What the progress track would read after a keyboard step of [delta] units,
/// or null at either end of the book.
///
/// A step lands at the start of the neighbouring unit, so it names that unit
/// with the share of the book read once it is.
String? _unitStepValue(BuildContext context, ReaderModel model, int delta) {
  final total = model.document?.logicalUnitCount.toInt() ?? 0;
  final unit = model.unit + delta;
  if (total <= 0 || unit < 0 || unit >= total) return null;
  final l10n = AppLocalizations.of(context);
  final percent = ((unit + 1) / total * 100).round();
  return model.document?.format == FlutterBookFormat.epub
      ? l10n.readerChapterOfStatus(percent, unit + 1, total)
      : l10n.readerPageOfStatus(percent, unit + 1, total);
}

/// The place in the reader's terms: `4% · pages 18–19 of 502`, or the short
/// `4% · page 25` on a phone. Also the live region that announces it.
class _ReaderPlaceLabel extends StatelessWidget {
  const _ReaderPlaceLabel({required this.model, required this.short});

  final ReaderModel model;
  final bool short;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final palette = ShellPalette.of(context);
    // The count names what the ordinals count: chapters, or PDF pages. EPUB
    // page ordinals count within the chapter, so they get no total.
    final document = model.document;
    final total =
        document != null &&
            (document.format != FlutterBookFormat.epub ||
                model.progress.displayUnit == ReaderDisplayUnit.chapter)
        ? document.logicalUnitCount.toInt()
        : 0;
    final label = _readerStatusLabel(
      l10n,
      model.progress,
      total: total,
      short: short,
    );
    return Semantics(
      key: const ValueKey('reader-progress'),
      container: true,
      liveRegion: true,
      label: label,
      child: ExcludeSemantics(
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: short ? TextAlign.center : TextAlign.end,
          style: shellInterfaceStyle(12, 16).copyWith(
            color: palette.inkMuted,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
  }
}

String _readerStatusLabel(
  AppLocalizations l10n,
  ReaderProgressPresentation progress, {
  required int total,
  required bool short,
}) {
  final percent = progress.percentage;
  switch (progress.kind) {
    case ReaderProgressKind.none:
      return l10n.readerNoBookOpen;
    case ReaderProgressKind.loading:
      return l10n.readerOpeningDocument;
    case ReaderProgressKind.single:
      final ordinal = progress.firstOrdinal ?? 0;
      final chapter = progress.displayUnit == ReaderDisplayUnit.chapter;
      if (short || total <= 0) {
        return chapter
            ? l10n.readerChapterStatus(percent, ordinal)
            : l10n.readerPageStatus(percent, ordinal);
      }
      return chapter
          ? l10n.readerChapterOfStatus(percent, ordinal, total)
          : l10n.readerPageOfStatus(percent, ordinal, total);
    case ReaderProgressKind.range:
      final first = progress.firstOrdinal ?? 0;
      final last = progress.lastOrdinal ?? first;
      final chapter = progress.displayUnit == ReaderDisplayUnit.chapter;
      if (short || total <= 0) {
        return chapter
            ? l10n.readerChapterRangeStatus(percent, first, last)
            : l10n.readerPageRangeStatus(percent, first, last);
      }
      return chapter
          ? l10n.readerChapterRangeOfStatus(percent, first, last, total)
          : l10n.readerPageRangeOfStatus(percent, first, last, total);
  }
}

/// The 4 px progress track: `accent` fill, bookmarks as `vermilion` ticks.
/// Clicking or dragging it jumps there.
///
/// It is also a slider for the keyboard and assistive technology: it takes
/// focus with the 2 px `accent` ring, and the arrow keys or the semantic
/// increase and decrease actions step one unit through [onStep].
class _ReaderProgressTrack extends StatefulWidget {
  const _ReaderProgressTrack({
    required this.value,
    required this.valueLabel,
    required this.increasedValue,
    required this.decreasedValue,
    required this.marks,
    required this.onJump,
    required this.onStep,
  });

  final double value;
  final String valueLabel;

  /// The place one unit on or back, or null at that end of the book.
  final String? increasedValue;
  final String? decreasedValue;
  final List<double> marks;
  final ValueChanged<double>? onJump;
  final ValueChanged<int>? onStep;

  @override
  State<_ReaderProgressTrack> createState() => _ReaderProgressTrackState();
}

class _ReaderProgressTrackState extends State<_ReaderProgressTrack> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final palette = ShellPalette.of(context);
    final onJump = widget.onJump;
    final onStep = widget.onStep;
    void step(int delta) => onStep?.call(delta);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        void jump(Offset local) {
          if (width <= 0) return;
          onJump?.call((local.dx / width).clamp(0.0, 1.0));
        }

        return Semantics(
          slider: true,
          enabled: onStep != null,
          label: AppLocalizations.of(context).readerProgressTrack,
          value: widget.valueLabel,
          increasedValue: onStep == null ? null : widget.increasedValue,
          decreasedValue: onStep == null ? null : widget.decreasedValue,
          onIncrease: onStep == null || widget.increasedValue == null
              ? null
              : () => step(1),
          onDecrease: onStep == null || widget.decreasedValue == null
              ? null
              : () => step(-1),
          child: FocusableActionDetector(
            enabled: onStep != null,
            mouseCursor: onJump == null
                ? MouseCursor.defer
                : SystemMouseCursors.click,
            onShowFocusHighlight: (focused) =>
                setState(() => _focused = focused),
            shortcuts: const {
              SingleActivator(LogicalKeyboardKey.arrowRight):
                  _ReaderTrackStepIntent(1),
              SingleActivator(LogicalKeyboardKey.arrowUp):
                  _ReaderTrackStepIntent(1),
              SingleActivator(LogicalKeyboardKey.arrowLeft):
                  _ReaderTrackStepIntent(-1),
              SingleActivator(LogicalKeyboardKey.arrowDown):
                  _ReaderTrackStepIntent(-1),
            },
            actions: {
              _ReaderTrackStepIntent: CallbackAction<_ReaderTrackStepIntent>(
                onInvoke: (intent) {
                  step(intent.delta);
                  return null;
                },
              ),
            },
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              excludeFromSemantics: true,
              onTapUp: onJump == null
                  ? null
                  : (details) => jump(details.localPosition),
              // A drag jumps once, where it ends, rather than laying the book
              // out again at every step.
              onHorizontalDragEnd: onJump == null
                  ? null
                  : (details) => jump(details.localPosition),
              child: _readerFocusRing(
                focused: _focused && onStep != null,
                color: palette.accent,
                radius: ShosaiTokens.radiusXs,
                child: SizedBox(
                  key: const ValueKey('reader-progress-track'),
                  height: 20,
                  child: CustomPaint(
                    painter: _ProgressTrackPainter(
                      value: widget.value.clamp(0.0, 1.0),
                      marks: widget.marks,
                      track: palette.surfaceSunken,
                      fill: palette.accent,
                      mark: ShosaiTokens.colorLightVermilion,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// A keyboard step along the progress track, in units.
class _ReaderTrackStepIntent extends Intent {
  const _ReaderTrackStepIntent(this.delta);

  final int delta;
}

class _ProgressTrackPainter extends CustomPainter {
  const _ProgressTrackPainter({
    required this.value,
    required this.marks,
    required this.track,
    required this.fill,
    required this.mark,
  });

  final double value;
  final List<double> marks;
  final Color track;
  final Color fill;
  final Color mark;

  @override
  void paint(Canvas canvas, Size size) {
    final top = (size.height - 4) / 2;
    final radius = const Radius.circular(ShosaiTokens.radiusXs);
    canvas.drawRRect(
      RRect.fromLTRBR(0, top, size.width, top + 4, radius),
      Paint()..color = track,
    );
    if (value > 0) {
      canvas.drawRRect(
        RRect.fromLTRBR(0, top, size.width * value, top + 4, radius),
        Paint()..color = fill,
      );
    }
    final tick = Paint()..color = mark;
    for (final position in marks) {
      final x = (size.width * position.clamp(0.0, 1.0)).clamp(
        1.0,
        math.max(1.0, size.width - 1),
      );
      canvas.drawRRect(
        RRect.fromLTRBR(
          x - 1,
          top - 3,
          x + 1,
          top + 7,
          const Radius.circular(1),
        ),
        tick,
      );
    }
  }

  @override
  bool shouldRepaint(_ProgressTrackPainter oldDelegate) =>
      oldDelegate.value != value ||
      !_sameMarks(oldDelegate.marks, marks) ||
      oldDelegate.track != track ||
      oldDelegate.fill != fill ||
      oldDelegate.mark != mark;

  static bool _sameMarks(List<double> a, List<double> b) {
    if (a.length != b.length) return false;
    for (var index = 0; index < a.length; index += 1) {
      if (a[index] != b[index]) return false;
    }
    return true;
  }
}
