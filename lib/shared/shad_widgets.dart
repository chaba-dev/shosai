import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// A ghost [ShadIconButton] with an accessible tooltip.
///
/// Shared presentation helper so reader and library chrome keep one tooltip
/// and button treatment. The optional style arguments default to that ghost
/// treatment; the library card passes the mapped card-action colors so its
/// trigger keeps the shared focus ring and tooltip while matching the
/// reference's bordered surface.
class ShadIconAction extends StatelessWidget {
  const ShadIconAction({
    super.key,
    required this.tooltip,
    required this.onPressed,
    required this.icon,
    this.backgroundColor,
    this.hoverBackgroundColor,
    this.pressedBackgroundColor,
    this.foregroundColor,
    this.hoverForegroundColor,
    this.padding,
    this.decoration,
  });

  final String tooltip;
  final VoidCallback? onPressed;
  final Widget icon;
  final Color? backgroundColor;
  final Color? hoverBackgroundColor;
  final Color? pressedBackgroundColor;
  final Color? foregroundColor;
  final Color? hoverForegroundColor;
  final EdgeInsetsGeometry? padding;
  final ShadDecoration? decoration;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: ShadIconButton.ghost(
      onPressed: onPressed,
      icon: icon,
      backgroundColor: backgroundColor,
      hoverBackgroundColor: hoverBackgroundColor,
      pressedBackgroundColor: pressedBackgroundColor,
      foregroundColor: foregroundColor,
      hoverForegroundColor: hoverForegroundColor,
      padding: padding,
      decoration: decoration,
    ),
  );
}
