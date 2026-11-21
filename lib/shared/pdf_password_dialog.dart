import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shosai_flutter/core/document_access.dart';
import 'package:shosai_flutter/l10n/app_localizations.dart';
import 'package:shosai_flutter/shared/protected_book_dialog.dart';
import 'package:shosai_flutter/shell/view.dart';
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
    final controlHeight = ProtectedBookDialog.controlHeight(context);
    final touch = controlHeight == ShosaiTokens.sizeTouchTarget;
    final contentWidth = MediaQuery.sizeOf(context).width < 512
        ? MediaQuery.sizeOf(context).width - 48
        : 392.0;
    final stackActions =
        MediaQuery.sizeOf(context).width <
            ShadTheme.of(context).breakpoints.sm.value ||
        MediaQuery.textScalerOf(context).scale(1) > 1.3;
    return ProtectedBookDialog(
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
              MergeSemantics(
                child: ShadButton.outline(
                  onPressed: () => Navigator.pop(context),
                  child: Text(l10n.readerNoteCancel),
                ),
              ),
              MergeSemantics(
                child: ShadButton(
                  onPressed: _password.text.isEmpty ? null : _open,
                  child: Text(l10n.pdfUnlockAction),
                ),
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
          spacing: ShosaiTokens.space3,
          children: [
            Text(l10n.pdfPasswordRequired),
            Text(widget.request.title, style: shellEditorialStyle(14, 19)),
            ExcludeSemantics(child: Text(l10n.pdfPasswordLabel)),
            // Share the field border, but keep the toggle outside the field's
            // merged semantics so it remains a separately named button.
            Stack(
              alignment: Alignment.centerRight,
              clipBehavior: Clip.none,
              children: [
                MergeSemantics(
                  child: Semantics(
                    textField: true,
                    label: l10n.pdfPasswordLabel,
                    child: ShadInput(
                      controller: _password,
                      style: ShadTheme.of(
                        context,
                      ).textTheme.small.copyWith(fontSize: 13, height: 18 / 13),
                      padding: EdgeInsets.symmetric(
                        horizontal: ShosaiTokens.space3,
                        // Include the field's 1 px border in its height.
                        vertical: (controlHeight - 18) / 2 - 1,
                      ),
                      inputPadding: EdgeInsets.only(right: controlHeight),
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
                Tooltip(
                  message: _obscured
                      ? l10n.pdfPasswordShow
                      : l10n.pdfPasswordHide,
                  excludeFromSemantics: true,
                  child: MergeSemantics(
                    child: Semantics(
                      label: _obscured
                          ? l10n.pdfPasswordShow
                          : l10n.pdfPasswordHide,
                      child: ShadIconButton.ghost(
                        onPressed: () => setState(() => _obscured = !_obscured),
                        icon: Icon(
                          _obscured ? LucideIcons.eye : LucideIcons.eyeOff,
                          size: touch ? 20 : 16,
                        ),
                      ),
                    ),
                  ),
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
            Text(
              l10n.pdfPasswordSavedHint,
              style: shellInterfaceStyle(
                12,
                16,
              ).copyWith(color: ShellPalette.of(context).inkMuted),
            ),
          ],
        ),
      ),
    );
  }
}
