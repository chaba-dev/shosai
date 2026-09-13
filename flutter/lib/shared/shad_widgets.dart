import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// A ghost [ShadIconButton] with an accessible tooltip.
///
/// Shared presentation helper so reader and library chrome keep one tooltip
/// and button treatment.
class ShadIconAction extends StatelessWidget {
  const ShadIconAction({
    super.key,
    required this.tooltip,
    required this.onPressed,
    required this.icon,
  });

  final String tooltip;
  final VoidCallback? onPressed;
  final Widget icon;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: ShadIconButton.ghost(onPressed: onPressed, icon: icon),
  );
}
