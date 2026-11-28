part of 'view.dart';

/// A count inside a toggle (`sh-count`): how many items it holds, in
/// tabular figures on a `surface-sunken` capsule. Callers hide it at zero.
class ShellCount extends StatelessWidget {
  const ShellCount({super.key, required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final palette = ShellPalette.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.surfaceSunken,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Padding(
        // 16 px tall, so a 32 px button keeps its height.
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Text(
          '$count',
          style: shellInterfaceStyle(11, 16, weight: FontWeight.w600).copyWith(
            color: palette.inkMuted,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
  }
}

/// A text link (`sh-link`; `docs/design-system.md`, Link): words that go
/// somewhere, such as an author's books, a source's page or its donation
/// page. Accent text with no fill or padding, underlined on hover, with the
/// shared focus ring and a 44 px minimum target that grows with the label.
/// Actions that change something stay a [ShadButton].
class ShellLink extends StatefulWidget {
  const ShellLink({
    super.key,
    required this.label,
    required this.onPressed,
    this.trailing,
    this.style,
  });

  final String label;
  final VoidCallback onPressed;
  final IconData? trailing;

  /// Interface body 16/24 unless the surrounding line sets another role.
  final TextStyle? style;

  @override
  State<ShellLink> createState() => _ShellLinkState();
}

class _ShellLinkState extends State<ShellLink> {
  final _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = ShellPalette.of(context).accent;
    // One link node for assistive technology instead of Shad's button. The
    // button below owns keyboard focus and activation; the node reflects
    // that same focus node, so assistive technology sees and moves it.
    return ListenableBuilder(
      listenable: _focus,
      builder: (context, child) => Semantics(
        container: true,
        link: true,
        label: widget.label,
        focusable: _focus.canRequestFocus,
        focused: _focus.hasFocus,
        onFocus: _focus.requestFocus,
        onTap: widget.onPressed,
        excludeSemantics: true,
        child: child,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minWidth: ShosaiTokens.sizeTouchTarget,
          minHeight: math.max(
            ShosaiTokens.sizeTouchTarget,
            shosaiShadButtonHeight(context),
          ),
        ),
        child: ShadButton.link(
          focusNode: _focus,
          height: 0,
          padding: EdgeInsets.zero,
          foregroundColor: accent,
          hoverForegroundColor: accent,
          pressedForegroundColor: accent,
          hoverTextDecoration: TextDecoration.underline,
          onPressed: widget.onPressed,
          trailing: widget.trailing == null
              ? null
              : Icon(widget.trailing, size: 18, color: accent),
          child: Flexible(
            child: Text(
              widget.label,
              style: widget.style ?? shellInterfaceStyle(16, 24),
            ),
          ),
        ),
      ),
    );
  }
}

/// One option of a [ShellSegmentedControl]: its value and its short noun.
typedef ShellSegment<T> = ({T value, String label});

/// A segmented control (`sh-seg`; `docs/design-system.md`,
/// SegmentedControl): two to four exclusive views of the same content.
///
/// The options sit on `surface-sunken`; the chosen one is raised on
/// `control-raised` under `shadow-menu`. Each option is a button inside a
/// group named [label], and the chosen one reports itself selected. On touch
/// layouts each option is `touch-target` tall inside a 48 px track.
///
/// The control renders [selected] and reports a choice through [onSelected];
/// it holds no state of its own.
class ShellSegmentedControl<T> extends StatelessWidget {
  const ShellSegmentedControl({
    super.key,
    required this.label,
    required this.segments,
    required this.selected,
    required this.onSelected,
    this.touch = false,
    this.icons,
  });

  final String label;
  final List<ShellSegment<T>> segments;
  final T selected;
  final ValueChanged<T> onSelected;
  final bool touch;

  /// Draws each option as its icon alone, a square of the option's height,
  /// when the icon carries the meaning; its noun becomes the option's
  /// tooltip and accessible name.
  final Map<T, IconData>? icons;

  /// The width a control with [labels] takes on one line at the ambient text
  /// scale, so a parent can tell whether it fits beside something else.
  static double widthOf(BuildContext context, Iterable<String> labels) {
    final scaler = MediaQuery.textScalerOf(context);
    // The 2 px inset on either side and the 2 px gap between options.
    var width = 4.0 + 2 * (labels.length - 1);
    for (final label in labels) {
      final painter = TextPainter(
        text: TextSpan(text: label, style: _segmentStyle(label)),
        textScaler: scaler,
        textDirection: TextDirection.ltr,
      )..layout();
      width += painter.width + _segmentPadding.horizontal;
      painter.dispose();
    }
    return width.ceilToDouble();
  }

  @override
  Widget build(BuildContext context) {
    final palette = ShellPalette.of(context);
    // The option is what takes the tap, so on touch it is the target; the
    // 2 px inset around it is not.
    final segmentHeight = touch ? ShosaiTokens.sizeTouchTarget : 28.0;
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: label,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: palette.surfaceSunken,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: const EdgeInsets.all(2),
          // At large text the options wrap onto another line rather than
          // being cut.
          child: Wrap(
            spacing: 2,
            runSpacing: 2,
            children: [
              for (final segment in segments)
                _Segment(
                  label: segment.label,
                  icon: icons?[segment.value],
                  chosen: segment.value == selected,
                  height: segmentHeight,
                  onPressed: () => onSelected(segment.value),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({
    required this.label,
    required this.chosen,
    required this.height,
    required this.onPressed,
    this.icon,
  });

  final String label;
  final IconData? icon;
  final bool chosen;
  final double height;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = ShellPalette.of(context);
    final color = chosen ? palette.ink : palette.inkMuted;
    final icon = this.icon;
    return _ShellPressable(
      onPressed: onPressed,
      current: chosen,
      radius: ShosaiTokens.radiusSm,
      color: chosen ? palette.controlRaised : null,
      shadow: chosen ? palette.menu : null,
      tooltip: icon == null ? null : label,
      semanticLabel: icon == null ? null : label,
      child: icon == null
          ? ConstrainedBox(
              constraints: BoxConstraints(minHeight: height),
              child: Padding(
                padding: _segmentPadding,
                child: Center(
                  widthFactor: 1,
                  child: Text(
                    label,
                    style: _segmentStyle(label).copyWith(color: color),
                  ),
                ),
              ),
            )
          // Square, so a touch option is a whole touch target.
          : SizedBox.square(
              dimension: height,
              child: Icon(icon, size: 16, color: color),
            ),
    );
  }
}

const EdgeInsets _segmentPadding = EdgeInsets.symmetric(
  horizontal: 12,
  vertical: 4,
);

TextStyle _segmentStyle(String label) => shosaiInterfaceStyleForText(
  shellInterfaceStyle(12, 16, weight: FontWeight.w500),
  label,
);
