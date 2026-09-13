import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_flutter/android_document_import_adapter.dart';
import 'package:shosai_flutter/library/errors.dart';
import 'package:shosai_flutter/reader/controller.dart';
import 'package:shosai_flutter/src/rust/api.dart';

void main() {
  test('safeError surfaces allowlisted error messages', () {
    expect(
      safeError(
        const FlutterBridgeError(
          kind: FlutterBridgeErrorKind.cancelled,
          message: 'cancelled',
        ),
      ),
      'cancelled',
    );
    expect(
      safeError(const SafeUserError('Document provider is busy.')),
      'Document provider is busy.',
    );
    expect(
      safeError(const ReaderPersistenceException('Reading position was lost.')),
      'Reading position was lost.',
    );
  });

  test('safeError hides unexpected error details', () {
    expect(
      safeError(StateError('internal secret')),
      'The operation could not be completed.',
    );
  });

  test('document import error text and token are stable', () {
    expect(
      documentImportErrorText(DocumentImportError.busy),
      'The document provider is busy. Try again.',
    );
    expect(
      documentImportErrorToken(DocumentImportError.busy),
      'provider_error:busy',
    );
  });
}
