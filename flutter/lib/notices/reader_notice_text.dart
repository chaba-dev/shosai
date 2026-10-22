import 'package:shosai_flutter/l10n/app_localizations.dart';

import 'notice.dart';

/// Reader notice copy, resolved through the generated catalogs.
///
/// The reader controller reports these through the injected
/// [NoticeReporter]; the host resolves them at render time, so the copy lives
/// in the ARB catalogs instead of the controller. The reader route sits
/// outside the shell's `NoticeHost`, so the composition root injects the
/// application center's reporter into `ReaderScreen`.

/// Brief success after copying the Markdown bookmark export.
final class ReaderExportSucceededNotice implements NoticeText {
  const ReaderExportSucceededNotice();

  @override
  String resolve(AppLocalizations localizations) =>
      localizations.noticeReaderExportSucceeded;
}

/// Persistent failure title after a failed Markdown bookmark export.
final class ReaderExportFailedNotice implements NoticeText {
  const ReaderExportFailedNotice();

  @override
  String resolve(AppLocalizations localizations) =>
      localizations.noticeReaderExportFailed;
}
