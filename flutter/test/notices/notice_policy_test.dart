import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_flutter/notices/notices.dart';

/// Decision 13's policy matrix.
///
/// Package 2D implements and tests this policy; 6A/6B verify it in the
/// completed import and settings workflows. A failure here is a policy
/// regression, not a presentation preference.
void main() {
  test('successful operations use brief feedback', () {
    final disposition = NoticePolicy.dispositionFor(NoticeOutcome.success);

    expect(disposition, isNotNull);
    expect(disposition!.kind, NoticeKind.success);
    expect(disposition.lifetime, NoticeLifetime.brief);
  });

  test(
    'failures, partial imports, missing files and permissions stay visible',
    () {
      for (final outcome in const [
        NoticeOutcome.partialImport,
        NoticeOutcome.failure,
        NoticeOutcome.missingFile,
        NoticeOutcome.permissionDenied,
      ]) {
        final disposition = NoticePolicy.dispositionFor(outcome);

        expect(disposition, isNotNull, reason: '$outcome must not be silent');
        expect(disposition!.kind, NoticeKind.failure);
        expect(
          disposition.lifetime,
          NoticeLifetime.persistent,
          reason: '$outcome must not expire like a success toast',
        );
      }
    },
  );

  test(
    'cleanup and deletion debt stays visible without reading as an error',
    () {
      final disposition = NoticePolicy.dispositionFor(
        NoticeOutcome.deletionDebt,
      );

      expect(disposition, isNotNull);
      expect(disposition!.kind, NoticeKind.warning);
      expect(disposition.lifetime, NoticeLifetime.persistent);
    },
  );

  test('cancellation is neutral: it produces no notice at all', () {
    expect(NoticePolicy.dispositionFor(NoticeOutcome.cancellation), isNull);
  });

  test('a correctable dialog error stays inline in its dialog', () {
    expect(
      NoticePolicy.dispositionFor(NoticeOutcome.correctableDialogError),
      isNull,
    );
  });

  test('the brief duration is short enough to be transient feedback', () {
    expect(NoticePolicy.briefDuration, greaterThan(Duration.zero));
    expect(
      NoticePolicy.briefDuration,
      lessThanOrEqualTo(const Duration(seconds: 6)),
    );
  });

  test('unresolved-condition keys are distinct', () {
    final keys = {
      NoticePolicy.libraryImportKey,
      NoticePolicy.librarySettingsKey,
      NoticePolicy.libraryRemovalKey,
    };

    expect(keys, hasLength(3));
  });
}
