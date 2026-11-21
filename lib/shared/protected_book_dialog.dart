import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shosai_flutter/l10n/app_localizations.dart';
import 'package:shosai_flutter/shell/view.dart';
import 'package:shosai_flutter/theme_tokens.dart';

/// The protected-book dialogs share a scoped theme, not a global restyle.
class ProtectedBookDialog extends StatelessWidget {
  const ProtectedBookDialog({
    super.key,
    required this.title,
    required this.actions,
    this.description,
    this.child,
    this.expandActionsWhenTiny = true,
  });

  final Widget title;
  final List<Widget> actions;
  final Widget? description;
  final Widget? child;
  final bool expandActionsWhenTiny;

  static double controlHeight(BuildContext context) {
    final platform = Theme.of(context).platform;
    final touch =
        platform == TargetPlatform.android ||
        platform == TargetPlatform.iOS ||
        ShellLayout.forWidth(MediaQuery.sizeOf(context).width) !=
            ShellLayout.desktop;
    return touch
        ? ShosaiTokens.sizeTouchTarget
        : ShosaiTokens.sizeControlHeight;
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final palette = ShellPalette.of(context);
    final target = controlHeight(context);
    final touch = target == ShosaiTokens.sizeTouchTarget;
    final controlStyle = theme.textTheme.small.copyWith(
      fontSize: 13,
      height: 18 / 13,
      fontWeight: FontWeight.w500,
    );
    final bodyStyle = theme.textTheme.p.copyWith(fontSize: 14, height: 20 / 14);
    final verticalPadding = touch ? ShosaiTokens.space2 : ShosaiTokens.space1;
    final buttonHeight = math.max(
      target,
      MediaQuery.textScalerOf(context).scale(13) * (18 / 13) +
          verticalPadding * 2,
    );
    final sizes = theme.buttonSizesTheme.copyWith(
      regular: ShadButtonSizeTheme(
        height: buttonHeight,
        padding: EdgeInsets.symmetric(
          horizontal: ShosaiTokens.space3,
          vertical: verticalPadding,
        ),
      ),
      icon: ShadButtonSizeTheme(
        height: target,
        width: target,
        padding: EdgeInsets.zero,
      ),
    );
    return ShadTheme(
      data: theme.copyWith(
        buttonSizesTheme: sizes,
        primaryButtonTheme: theme.primaryButtonTheme.copyWith(
          textStyle: controlStyle,
        ),
        outlineButtonTheme: theme.outlineButtonTheme.copyWith(
          textStyle: controlStyle,
          // Shad adds the 1 px border outside its constrained content box.
          // Include that border in the system's total control height.
          height: buttonHeight - 2,
          sizesTheme: sizes.copyWith(
            regular: sizes.regular!.copyWith(
              padding: EdgeInsets.symmetric(
                horizontal: ShosaiTokens.space3,
                vertical: verticalPadding - 1,
              ),
            ),
          ),
        ),
      ),
      child: DefaultTextStyle(
        style: bodyStyle.copyWith(color: palette.ink),
        child: ShadDialog(
          // The close control is positioned over the dialog, outside its
          // content flow. Keep wrapped/localized headings out of its target.
          title: Padding(
            padding: EdgeInsets.only(right: target + ShosaiTokens.space2),
            child: title,
          ),
          titleStyle: shellEditorialStyle(20, 24),
          titleTextAlign: TextAlign.start,
          description: description,
          descriptionStyle: bodyStyle.copyWith(color: palette.inkMuted),
          descriptionTextAlign: TextAlign.start,
          backgroundColor: palette.surface,
          // Dialogs have 12 px corners; keep the existing edge-to-edge phone.
          radius: BorderRadius.circular(12),
          border: Border.all(
            color: palette.surface.withValues(alpha: 0),
            width: 0,
          ),
          shadows: palette.modal,
          closeIcon: Builder(
            builder: (context) => Tooltip(
              message: AppLocalizations.of(context).locationClose,
              excludeFromSemantics: true,
              child: MergeSemantics(
                child: Semantics(
                  label: AppLocalizations.of(context).locationClose,
                  child: ShadIconButton.ghost(
                    icon: Icon(LucideIcons.x, size: touch ? 20 : 16),
                    onPressed: () => Navigator.pop(context),
                  ),
                ),
              ),
            ),
          ),
          expandActionsWhenTiny: expandActionsWhenTiny,
          actions: actions,
          child: child == null
              ? null
              : DefaultTextStyle(
                  style: bodyStyle.copyWith(color: palette.ink),
                  child: child!,
                ),
        ),
      ),
    );
  }
}
