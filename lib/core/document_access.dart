/// Document access is a controller-owned effect, separate from opening a tab.
library;

import 'package:shosai_flutter/l10n/app_localizations.dart';
import 'package:shosai_flutter/core/bridge.dart';
import 'package:shosai_flutter/reader/pdf/engine.dart';

abstract interface class DocumentAccessHost {
  /// Resolve a migrated book's protection before navigating into the reader.
  Future<FlutterBookProtection> bookProtection({
    required int bookId,
    required BigInt cancellationId,
  });

  /// Try a saved password, or verify and remember [password]. False means the
  /// PDF still needs a password. A bad password is never saved.
  Future<bool> unlockPdf({
    int? bookId,
    required String pathKey,
    String? password,
    required BigInt cancellationId,
  });
}

final class PdfPasswordRequest {
  const PdfPasswordRequest(this.title, {this.error});
  final String title;
  final String? error;
}

typedef PdfPasswordPrompt =
    Future<String?> Function(PdfPasswordRequest request);

/// Called only from a controller effect. Passwords stay out of model state,
/// messages, logs and the library database.
Future<bool> unlockPdfWithPrompt({
  required DocumentAccessHost host,
  required PdfPasswordPrompt prompt,
  required String title,
  required String pathKey,
  int? bookId,
  required BigInt cancellationId,
  required bool Function() isCurrent,
  required AppLocalizations Function() localizations,
}) async {
  if (!isCurrent()) return false;
  if (await host.unlockPdf(
    bookId: bookId,
    pathKey: pathKey,
    cancellationId: cancellationId,
  )) {
    return isCurrent();
  }
  String? error;
  while (isCurrent()) {
    final password = await prompt(PdfPasswordRequest(title, error: error));
    if (!isCurrent() || password == null) return false;
    try {
      if (await host.unlockPdf(
        bookId: bookId,
        pathKey: pathKey,
        password: password,
        cancellationId: cancellationId,
      )) {
        return isCurrent();
      }
      error = localizations().pdfPasswordIncorrect;
    } on PdfPasswordStorageException {
      error = localizations().pdfPasswordSaveFailed;
    }
  }
  return false;
}
