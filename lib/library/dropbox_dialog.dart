import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shosai_flutter/l10n/app_localizations.dart';

/// Presentation only: the controller's injected setup adapter owns the browser
/// and token exchange. No OAuth code or verifier is persisted by this widget.
class DropboxCodeDialog extends StatefulWidget {
  const DropboxCodeDialog({super.key});

  @override
  State<DropboxCodeDialog> createState() => _DropboxCodeDialogState();
}

class _DropboxCodeDialogState extends State<DropboxCodeDialog> {
  final _code = TextEditingController();

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ShadDialog(
      title: Text(l10n.dropboxConnect),
      description: Text(l10n.dropboxCodeDescription),
      actions: [
        ShadButton.outline(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.locationCancel),
        ),
        ValueListenableBuilder(
          valueListenable: _code,
          builder: (context, value, _) => ShadButton(
            enabled: value.text.trim().isNotEmpty,
            onPressed: value.text.trim().isEmpty
                ? null
                : () => Navigator.pop(context, value.text.trim()),
            child: Text(l10n.dropboxConnect),
          ),
        ),
      ],
      child: SizedBox(
        width: 440,
        child: ShadInput(
          controller: _code,
          autofocus: true,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          placeholder: Text(l10n.dropboxAuthorizationCode),
        ),
      ),
    );
  }
}
