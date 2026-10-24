import 'package:shosai_flutter/android_document_import_adapter.dart';
import 'package:shosai_flutter/l10n/app_localizations.dart';
import 'package:shosai_flutter/l10n/app_localizations_en.dart';
import 'package:shosai_flutter/reader/controller.dart';
import 'package:shosai_flutter/core/bridge.dart';

String safeError(Object error) => switch (error) {
  FlutterBridgeError() => error.message,
  ReaderPersistenceException() => error.message,
  SafeUserError() => error.message,
  _ => 'The operation could not be completed.',
};

final class SafeUserError implements Exception {
  const SafeUserError(this.message);
  final String message;
}

String documentImportErrorText(
  DocumentImportError error, [
  AppLocalizations? localizations,
]) {
  final l10n = localizations ?? AppLocalizationsEn();
  return switch (error) {
    DocumentImportError.unavailable => l10n.importProviderUnavailable,
    DocumentImportError.busy => l10n.importProviderBusy,
    DocumentImportError.permissionDenied => l10n.importPermissionDenied,
    DocumentImportError.tooLarge => l10n.importSelectionTooLarge,
    DocumentImportError.readFailed => l10n.importReadFailed,
    DocumentImportError.cancelled => l10n.importCancelled,
    DocumentImportError.invalidRequest => l10n.importInvalidRequest,
  };
}

String documentImportErrorToken(DocumentImportError error) =>
    'provider_error:${error.name}';
