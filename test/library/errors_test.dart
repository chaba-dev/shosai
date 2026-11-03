import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_flutter/android_document_import_adapter.dart';
import 'package:shosai_flutter/library/errors.dart';
import 'package:shosai_flutter/l10n/app_localizations_ja.dart';
import 'package:shosai_flutter/reader/controller.dart';
import 'package:shosai_flutter/core/bridge.dart';

void main() {
  test(
    'safeError translates engine kinds and preserves presentation errors',
    () {
      expect(
        safeError(
          const FlutterBridgeError(
            kind: FlutterBridgeErrorKind.cancelled,
            message: 'cancelled',
          ),
        ),
        'The operation was cancelled.',
      );
      expect(
        safeError(const SafeUserError('Document provider is busy.')),
        'Document provider is busy.',
      );
      expect(
        safeError(
          const ReaderPersistenceException('Reading position was lost.'),
        ),
        'Reading position was lost.',
      );
    },
  );

  test('safeError hides unexpected error details', () {
    expect(
      safeError(StateError('internal secret')),
      'The operation could not be completed.',
    );
  });

  test('Japanese failures never expose engine diagnostics', () {
    final ja = AppLocalizationsJa();
    expect(
      safeError(
        const FlutterBridgeError(
          kind: FlutterBridgeErrorKind.notFound,
          message: '/private/book.pdf is missing',
        ),
        ja,
      ),
      'ファイルが見つかりません。保存場所を確認して、もう一度お試しください。',
    );
    expect(
      safeError(
        const FlutterBridgeError(
          kind: FlutterBridgeErrorKind.inaccessible,
          message: 'provider token rejected',
        ),
        ja,
      ),
      'ファイルにアクセスできません。権限と接続を確認して、もう一度お試しください。',
    );
    expect(safeError(StateError('internal secret'), ja), '操作を完了できませんでした。');
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
