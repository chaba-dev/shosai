import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shosai_flutter/app_theme.dart';
import 'package:shosai_flutter/core/document_access.dart';
import 'package:shosai_flutter/l10n/app_localizations.dart';
import 'package:shosai_flutter/shared/shad_widgets.dart';
import 'package:shosai_flutter/shell/view.dart' show shellEditorialStyle;
import 'package:shosai_flutter/theme_tokens.dart';

/// Platform UI adapter only: the controller verifies and remembers passwords.
class PdfPasswordDialog extends StatefulWidget {
  const PdfPasswordDialog({super.key, required this.request});
  final PdfPasswordRequest request;

  @override
  State<PdfPasswordDialog> createState() => _PdfPasswordDialogState();
}

class _PdfPasswordDialogState extends State<PdfPasswordDialog> {
  final _password = TextEditingController();
  bool _obscured = true;

  @override
  void dispose() {
    _password.clear();
    _password.dispose();
    super.dispose();
  }

  void _open() {
    if (_password.text.isNotEmpty) Navigator.pop(context, _password.text);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final contentWidth = MediaQuery.sizeOf(context).width < 512
        ? MediaQuery.sizeOf(context).width - 48
        : 392.0;
    final stackActions =
        MediaQuery.sizeOf(context).width <
            ShadTheme.of(context).breakpoints.sm.value ||
        MediaQuery.textScalerOf(context).scale(1) > 1.3;
    return ShadDialog(
      title: Text(l10n.pdfUnlockTitle),
      expandActionsWhenTiny: false,
      actions: [
        SizedBox(
          width: contentWidth,
          child: Flex(
            direction: stackActions ? Axis.vertical : Axis.horizontal,
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: stackActions
                ? CrossAxisAlignment.stretch
                : CrossAxisAlignment.center,
            verticalDirection: VerticalDirection.up,
            spacing: ShosaiTokens.space2,
            children: [
              ShadButton.outline(
                height: shosaiShadButtonHeight(context),
                onPressed: () => Navigator.pop(context),
                child: Text(l10n.readerNoteCancel),
              ),
              ShadButton(
                height: shosaiShadButtonHeight(context),
                onPressed: _password.text.isEmpty ? null : _open,
                child: Text(l10n.pdfUnlockAction),
              ),
            ],
          ),
        ),
      ],
      child: SizedBox(
        width: contentWidth,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 12,
          children: [
            Text(l10n.pdfPasswordRequired),
            Text(widget.request.title, style: shellEditorialStyle(18, 24)),
            Text(l10n.pdfPasswordLabel),
            // Share the field border, but keep the toggle outside the field's
            // merged semantics so it remains a separately named button.
            Stack(
              alignment: Alignment.centerRight,
              clipBehavior: Clip.none,
              children: [
                MergeSemantics(
                  child: Semantics(
                    label: l10n.pdfPasswordLabel,
                    child: ShadInput(
                      controller: _password,
                      padding: const EdgeInsets.all(ShosaiTokens.space3),
                      inputPadding: const EdgeInsets.only(
                        right: ShosaiTokens.sizeTouchTarget,
                      ),
                      autofocus: true,
                      obscureText: _obscured,
                      autocorrect: false,
                      enableSuggestions: false,
                      enableIMEPersonalizedLearning: false,
                      onChanged: (_) => setState(() {}),
                      onSubmitted: (_) => _open(),
                    ),
                  ),
                ),
                ShadIconAction(
                  tooltip: _obscured
                      ? l10n.pdfPasswordShow
                      : l10n.pdfPasswordHide,
                  onPressed: () => setState(() => _obscured = !_obscured),
                  icon: Icon(_obscured ? LucideIcons.eye : LucideIcons.eyeOff),
                ),
              ],
            ),
            if (widget.request.error case final error?)
              Semantics(
                liveRegion: true,
                child: Text(
                  error,
                  style: TextStyle(
                    color: ShadTheme.of(context).colorScheme.destructive,
                  ),
                ),
              ),
            Text(l10n.pdfPasswordSavedHint),
          ],
        ),
      ),
    );
  }
}
