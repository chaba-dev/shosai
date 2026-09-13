import 'package:shosai_flutter/android_document_import_adapter.dart';
import 'package:shosai_flutter/reader/controller.dart';
import 'package:shosai_flutter/src/rust/api.dart';

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

String documentImportErrorText(DocumentImportError error) => switch (error) {
  DocumentImportError.unavailable => 'The document provider is unavailable.',
  DocumentImportError.busy => 'The document provider is busy. Try again.',
  DocumentImportError.permissionDenied =>
    'Permission to read the selected document was denied.',
  DocumentImportError.tooLarge =>
    'The selection or document exceeds the import limit.',
  DocumentImportError.readFailed => 'The selected document could not be read.',
  DocumentImportError.cancelled => 'Import cancelled.',
  DocumentImportError.invalidRequest =>
    'The document provider request is no longer valid.',
};

String documentImportErrorToken(DocumentImportError error) =>
    'provider_error:${error.name}';
