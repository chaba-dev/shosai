// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get libraryTitle => 'Library';

  @override
  String get librarySubtitle => 'Your private reading room';

  @override
  String get searchLibraryPlaceholder => 'Search title or author';

  @override
  String get collectionLabel => 'COLLECTION';

  @override
  String get filterAll => 'All';

  @override
  String get filterAllBooks => 'All books';

  @override
  String get filterSettings => 'Settings';

  @override
  String get filterFormatEpub => 'EPUB';

  @override
  String get filterFormatPdf => 'PDF';

  @override
  String get filterFormatCbz => 'CBZ';

  @override
  String get addBooksAction => 'Add books';

  @override
  String get cancelImportAction => 'Cancel';

  @override
  String get cancelOperationTooltip => 'Cancel operation';

  @override
  String get refreshLibraryTooltip => 'Refresh library';

  @override
  String get cardUnknownAuthor => 'Unknown author';

  @override
  String get cardNotStarted => 'Not started';

  @override
  String cardPercentRead(int percentage) {
    return '$percentage%';
  }

  @override
  String cardCoverSemantics(String title) {
    return 'Cover of $title';
  }

  @override
  String get cardActionsTooltip => 'Book actions';

  @override
  String get cardRemoveFromLibrary => 'Remove from library';

  @override
  String get cardRemoveManagedCopy => 'Remove and delete copy';

  @override
  String get cardRemoving => 'Removing…';

  @override
  String get collectionLoadMore => 'Load more books';

  @override
  String get libraryContinueReading => 'Continue reading';

  @override
  String get libraryContinue => 'Continue  ›';

  @override
  String libraryPercentComplete(int percentage) {
    return '$percentage% complete';
  }

  @override
  String get librarySearchResults => 'Search results';

  @override
  String get libraryEmptyHeading => 'A quiet place for every book';

  @override
  String get libraryEmptyBody =>
      'No books in library. Import files to get started.';

  @override
  String get libraryNoMatchesHeading => 'No matching books';

  @override
  String get libraryNoMatchesBody => 'No books match your search or filter.';

  @override
  String get libraryAddFirstBooks => 'Add your first books';

  @override
  String get libraryRetry => 'Retry';

  @override
  String get libraryCleanupPending =>
      'Temporary import data could not be removed yet.';

  @override
  String get libraryCleanupRetry => 'Retry cleanup';

  @override
  String get libraryDeletionPending =>
      'Book removed. Its private copy will be deleted later.';

  @override
  String get libraryDeletionDismiss => 'Dismiss';

  @override
  String noticeImportSucceeded(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Imported $count books.',
      one: 'Imported 1 book.',
    );
    return '$_temp0';
  }

  @override
  String get noticeImportPartialTitle => 'Some books could not be imported.';

  @override
  String get noticeImportFailedTitle => 'The import could not be completed.';

  @override
  String get noticeSettingsSaved => 'Reader settings saved.';

  @override
  String get noticeSettingsSaveFailed => 'Reader settings could not be saved.';

  @override
  String get noticeBookRemoved => 'Book removed.';

  @override
  String get noticeBookRemovalFailed => 'The book could not be removed.';

  @override
  String get noticeRetry => 'Retry';

  @override
  String get noticeDismiss => 'Dismiss';

  @override
  String get readerBackToLibrary => '‹ Library';

  @override
  String get readerFallbackTitle => 'Reader';

  @override
  String get readerContentsAction => 'Contents';

  @override
  String get readerAppearanceAction => 'Reading appearance';

  @override
  String get readerMoreAction => 'More';

  @override
  String get readerOpeningDocument => 'Opening document…';

  @override
  String get readerNoBookOpen => 'No book open';

  @override
  String readerPageStatus(int page, int percentage) {
    return 'Page $page · $percentage%';
  }

  @override
  String readerPageRangeStatus(int first, int last, int percentage) {
    return 'Pages $first–$last · $percentage%';
  }

  @override
  String readerChapterStatus(int chapter, int percentage) {
    return 'Chapter $chapter · $percentage%';
  }

  @override
  String readerChapterRangeStatus(int first, int last, int percentage) {
    return 'Chapters $first–$last · $percentage%';
  }

  @override
  String readerCloseTab(String title) {
    return 'Close $title';
  }

  @override
  String get readerTabsLabel => 'Open books';

  @override
  String get readerPreviousPage => 'Previous page';

  @override
  String get readerNextPage => 'Next page';

  @override
  String get readerRetryOpen => 'Retry';

  @override
  String get readerMissingBook =>
      'This book could not be found at its previous location.';

  @override
  String get readerLocateFile => 'Locate File…';

  @override
  String get readerRemoveFromLibrary => 'Remove from Library';
}
