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
  });

  final String label;
  final List<ShellSegment<T>> segments;
  final T selected;
  final ValueChanged<T> onSelected;
  final bool touch;

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
  });

  final String label;
  final bool chosen;
  final double height;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = ShellPalette.of(context);
    return _ShellPressable(
      onPressed: onPressed,
      current: chosen,
      radius: ShosaiTokens.radiusSm,
      color: chosen ? palette.controlRaised : null,
      shadow: chosen ? palette.menu : null,
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: height),
        child: Padding(
          padding: _segmentPadding,
          child: Center(
            widthFactor: 1,
            child: Text(
              label,
              style: _segmentStyle(
                label,
              ).copyWith(color: chosen ? palette.ink : palette.inkMuted),
            ),
          ),
        ),
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
