import 'package:shosai_flutter/l10n/app_localizations.dart';

import 'notice.dart';

/// Library notice copy, resolved through the generated catalogs.
///
/// The library controller reports these through the injected [NoticeReporter]
/// and the host resolves them at render time, so the copy lives in the ARB
/// catalogs instead of the controller.

/// Brief success after an import that landed books.
final class LibraryImportSucceededNotice implements NoticeText {
  const LibraryImportSucceededNotice({required this.count});

  final int count;

  @override
  String resolve(AppLocalizations localizations) =>
      localizations.noticeImportSucceeded(count);
}

/// Persistent failure title after a partial import.
final class LibraryImportPartialNotice implements NoticeText {
  const LibraryImportPartialNotice();

  @override
  String resolve(AppLocalizations localizations) =>
      localizations.noticeImportPartialTitle;
}

/// Persistent failure title after a failed import.
final class LibraryImportFailedNotice implements NoticeText {
  const LibraryImportFailedNotice();

  @override
  String resolve(AppLocalizations localizations) =>
      localizations.noticeImportFailedTitle;
}

/// Brief success after saving reader settings.
final class LibrarySettingsSavedNotice implements NoticeText {
  const LibrarySettingsSavedNotice();

  @override
  String resolve(AppLocalizations localizations) =>
      localizations.noticeSettingsSaved;
}

/// Persistent failure title after a failed settings save.
final class LibrarySettingsSaveFailedNotice implements NoticeText {
  const LibrarySettingsSaveFailedNotice();

  @override
  String resolve(AppLocalizations localizations) =>
      localizations.noticeSettingsSaveFailed;
}

/// Brief success after removing a book.
final class LibraryBookRemovedNotice implements NoticeText {
  const LibraryBookRemovedNotice();

  @override
  String resolve(AppLocalizations localizations) =>
      localizations.noticeBookRemoved;
}

/// Persistent failure title after a failed removal.
final class LibraryBookRemovalFailedNotice implements NoticeText {
  const LibraryBookRemovalFailedNotice();

  @override
  String resolve(AppLocalizations localizations) =>
      localizations.noticeBookRemovalFailed;
}

/// The recovery action label for a library failure notice.
final class NoticeRetryText implements NoticeText {
  const NoticeRetryText();

  @override
  String resolve(AppLocalizations localizations) => localizations.noticeRetry;
}

/// The acknowledgment action label for a library notice.
final class NoticeDismissText implements NoticeText {
  const NoticeDismissText();

  @override
  String resolve(AppLocalizations localizations) => localizations.noticeDismiss;
}
