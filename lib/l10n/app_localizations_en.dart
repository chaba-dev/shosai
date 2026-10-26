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
  String libraryCheckingSource(String source) {
    return 'Checking $source';
  }

  @override
  String libraryDiscoveryCount(int index, int total, int books) {
    String _temp0 = intl.Intl.pluralLogic(
      books,
      locale: localeName,
      other: '$books books found',
      one: '1 book found',
    );
    return 'Source $index of $total · $_temp0';
  }

  @override
  String get libraryCheckCancelled => 'Library check cancelled.';

  @override
  String get searchLibraryPlaceholder => 'Search title or author';

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
  String get cardFinished => 'Finished';

  @override
  String cardPercentRead(int percentage) {
    return '$percentage%';
  }

  @override
  String cardCoverSemantics(String title) {
    return 'Cover of $title';
  }

  @override
  String cardTitleByAuthorSemantics(String title, String author) {
    return '$title, by $author';
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
  String get libraryLoadingMore => 'Loading more…';

  @override
  String get libraryContinueReading => 'Continue reading';

  @override
  String get libraryContinue => 'Continue';

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
  String get readerBackToLibrary => 'Back to library';

  @override
  String get readerFallbackTitle => 'Reader';

  @override
  String get readerContentsAction => 'Contents';

  @override
  String get readerAppearanceAction => 'Display settings';

  @override
  String get readerNotesAction => 'Notes';

  @override
  String get readerCloseNotes => 'Close notes';

  @override
  String get readerBookmarkPage => 'Bookmark this page';

  @override
  String get readerRemoveBookmark => 'Remove bookmark';

  @override
  String get readerOpeningDocument => 'Opening document…';

  @override
  String get readerNoBookOpen => 'No book open';

  @override
  String readerPageStatus(int percentage, int page) {
    return '$percentage% · page $page';
  }

  @override
  String readerPageRangeStatus(int percentage, int first, int last) {
    return '$percentage% · pages $first–$last';
  }

  @override
  String readerChapterStatus(int percentage, int chapter) {
    return '$percentage% · chapter $chapter';
  }

  @override
  String readerChapterRangeStatus(int percentage, int first, int last) {
    return '$percentage% · chapters $first–$last';
  }

  @override
  String readerPageOfStatus(int percentage, int page, int total) {
    return '$percentage% · page $page of $total';
  }

  @override
  String readerPageRangeOfStatus(
    int percentage,
    int first,
    int last,
    int total,
  ) {
    return '$percentage% · pages $first–$last of $total';
  }

  @override
  String readerChapterOfStatus(int percentage, int chapter, int total) {
    return '$percentage% · chapter $chapter of $total';
  }

  @override
  String readerChapterRangeOfStatus(
    int percentage,
    int first,
    int last,
    int total,
  ) {
    return '$percentage% · chapters $first–$last of $total';
  }

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

  @override
  String get readerContentsSubheading => 'Chapters and saved places';

  @override
  String get readerCloseContents => 'Close contents';

  @override
  String get readerChaptersHeading => 'Chapters';

  @override
  String readerChapterNumber(int number) {
    return 'Chapter $number';
  }

  @override
  String readerBookmarksHeading(int count) {
    return 'Bookmarks · $count';
  }

  @override
  String get readerNoBookmarks => 'No bookmarks yet';

  @override
  String get readerBookmarkEmptyHint => 'Save a page to keep it close at hand.';

  @override
  String readerPageShort(int page) {
    return 'Pg $page';
  }

  @override
  String readerPageAbbreviated(int page) {
    return 'p.$page';
  }

  @override
  String readerDeleteBookmark(String title) {
    return 'Delete $title';
  }

  @override
  String get readerEditNote => 'Edit note';

  @override
  String get readerAddNote => 'Add note';

  @override
  String get readerPageNoteTitle => 'Page note';

  @override
  String get readerBookNoteTitle => 'Book note';

  @override
  String get readerHighlightNoteTitle => 'Highlight note';

  @override
  String get readerNoteSave => 'Save';

  @override
  String get readerNoteCancel => 'Cancel';

  @override
  String readerBackToPage(int page) {
    return 'Back to page $page';
  }

  @override
  String readerBackTo(String place) {
    return 'Back to $place';
  }

  @override
  String get readerBackDismiss => 'Stay here';

  @override
  String readerNotesCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count notes',
      one: '1 note',
    );
    return '$_temp0';
  }

  @override
  String get readerNotesScope => 'Show notes from';

  @override
  String get readerNotesEmpty =>
      'No notes yet. Select text to highlight it, or add a note to this page.';

  @override
  String readerPageNumber(int page) {
    return 'page $page';
  }

  @override
  String readerPageNoteAt(int page) {
    return 'Page note · page $page';
  }

  @override
  String get readerNoteActions => 'Note actions';

  @override
  String get readerDeleteNote => 'Delete note';

  @override
  String get readerExportMarkdown => 'Export as Markdown';

  @override
  String get readerContentsLoading => 'Loading contents…';

  @override
  String get readerContentsEmpty => 'No chapters in this document';

  @override
  String get readerContentsUnavailable => 'Contents unavailable';

  @override
  String get readerRetry => 'Retry';

  @override
  String get readerReading => 'Reading';

  @override
  String get readerDecreaseFontSize => 'Decrease font size';

  @override
  String get readerIncreaseFontSize => 'Increase font size';

  @override
  String readerFontSizeValue(int size) {
    return '${size}px';
  }

  @override
  String get readerLineSpacingLabel => 'Line spacing';

  @override
  String readerLineSpacingValue(String spacing) {
    return '$spacing×';
  }

  @override
  String get readerThemeCycle => 'Reading theme';

  @override
  String get readerThemeLight => 'Paper';

  @override
  String get readerThemeDark => 'Night';

  @override
  String get readerThemeSepia => 'Sepia';

  @override
  String get readerProgressTrack => 'Reading progress';

  @override
  String get readerPageTheme => 'Page theme';

  @override
  String get readerTextSize => 'Text size';

  @override
  String get readerTextSizeHint => 'Pages reflow; your place is kept.';

  @override
  String get readerZoom => 'Zoom';

  @override
  String get readerZoomOut => 'Zoom out';

  @override
  String get readerZoomIn => 'Zoom in';

  @override
  String get readerFitWidth => 'Fit width';

  @override
  String get readerFitPage => 'Fit page';

  @override
  String get readerPages => 'Pages';

  @override
  String get readerPageAnimations => 'Page animations';

  @override
  String get readerPagesHint => 'Two pages show when the window has room.';

  @override
  String get readerOnePage => 'One';

  @override
  String get readerTwoPages => 'Two';

  @override
  String get readerPageInputLabel => 'Page';

  @override
  String readerPageOf(int total) {
    return 'of $total';
  }

  @override
  String readerPageInputInvalid(int total) {
    return 'Enter a page between 1 and $total.';
  }

  @override
  String get readerGoToPage => 'Go to page';

  @override
  String get readerGoToChapter => 'Go to chapter';

  @override
  String get readerChapterInputLabel => 'Chapter';

  @override
  String readerChapterInputInvalid(int total) {
    return 'Enter a chapter between 1 and $total.';
  }

  @override
  String get readerSearchAction => 'Search';

  @override
  String get readerSearchPlaceholder => 'Search in document...';

  @override
  String get readerNoResults => 'No results';

  @override
  String readerSearchCount(int current, int total) {
    return '$current / $total';
  }

  @override
  String get readerPreviousResult => 'Previous result';

  @override
  String get readerNextResult => 'Next result';

  @override
  String get readerCloseSearch => 'Close search';

  @override
  String get readerSelectionActions => 'Selection actions';

  @override
  String get readerCopy => 'Copy';

  @override
  String get readerSelectionCancel => 'Cancel';

  @override
  String get readerHighlightYellow => 'Yellow';

  @override
  String get readerHighlightGreen => 'Green';

  @override
  String get readerHighlightBlue => 'Blue';

  @override
  String get readerHighlightPink => 'Pink';

  @override
  String get readerHighlightPurple => 'Purple';

  @override
  String get readerAnnotationRecovered => 'recovered';

  @override
  String get readerAnnotationAmbiguous => 'ambiguous';

  @override
  String get readerAnnotationUnavailable => 'unavailable';

  @override
  String get readerChangeColor => 'Change color';

  @override
  String get readerDeleteHighlight => 'Delete highlight';

  @override
  String get noticeReaderExportSucceeded => 'Bookmarks copied as Markdown';

  @override
  String get noticeReaderExportFailed => 'Bookmarks could not be exported';

  @override
  String get shellPlacesLabel => 'Places';

  @override
  String get shellPlaceLibrary => 'Library';

  @override
  String get shellPlaceNotes => 'Notes';

  @override
  String get shellPlaceBookmarks => 'Bookmarks';

  @override
  String get shellPlaceSearch => 'Search';

  @override
  String get shellReadingNow => 'Reading now';

  @override
  String shellCloseBook(String title) {
    return 'Close $title';
  }

  @override
  String get shellNotesEmptyHeading => 'No notes yet';

  @override
  String get shellNotesEmptyBody =>
      'Select text in a book to highlight it, or add a note to a page. Every note and highlight appears here.';

  @override
  String get shellNotesLoading => 'Loading notes…';

  @override
  String get shellNotesMore => 'More notes';

  @override
  String get shellSearchField => 'Search books and notes';

  @override
  String get shellSearchScope => 'Search in';

  @override
  String get shellSearchThisBook => 'This book';

  @override
  String get shellSearchAllBooks => 'All books';

  @override
  String get shellSearchFilter => 'Find';

  @override
  String get shellSearchEverything => 'Everything';

  @override
  String get shellSearchText => 'Text';

  @override
  String get shellSearchNotes => 'Notes';

  @override
  String get shellSearchHint =>
      'Type to search the text and notes of your books.';

  @override
  String get shellSearchSearching => 'Searching…';

  @override
  String get shellSearchClose => 'Close search';

  @override
  String get shellSearchPartial =>
      'Only the beginning of this long book was searched.';

  @override
  String shellSearchNoMatches(String query) {
    return 'No matches for “$query”';
  }

  @override
  String shellSearchNotesGroup(int count) {
    return 'Notes · $count';
  }

  @override
  String shellSearchMatches(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count matches',
      one: '1 match',
    );
    return '$_temp0';
  }

  @override
  String shellSearchMoreMatches(int count) {
    return '$count+ matches';
  }

  @override
  String shellSearchBookFailed(String error) {
    return 'This book could not be searched: $error';
  }

  @override
  String get shellBookmarksEmptyHeading => 'No bookmarks yet';

  @override
  String get shellBookmarksEmptyBody =>
      'Bookmark a page from the reader’s toolbar and it appears here.';

  @override
  String libraryBookCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count books',
      one: '1 book',
    );
    return '$_temp0';
  }

  @override
  String libraryOpenCount(int count) {
    return '$count open';
  }

  @override
  String get librarySortLabel => 'Sort';

  @override
  String get librarySortRecent => 'Recent';

  @override
  String get librarySortTitle => 'Title';

  @override
  String get librarySortAuthor => 'Author';

  @override
  String get cardOpenTag => 'Open';

  @override
  String shellOpenBooks(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count open books',
      one: '1 open book',
    );
    return '$_temp0';
  }

  @override
  String get importChooseFiles => 'Choose files';

  @override
  String get importChooseFilesHint => 'Select one or more PDF or EPUB files';

  @override
  String get importChooseFolder => 'Choose a folder';

  @override
  String get importChooseFolderHint => 'Find supported books in all subfolders';

  @override
  String get importReviewBooks => 'Review books';

  @override
  String get importReviewFolder => 'Review folder import';

  @override
  String get importBooksType => 'Books';

  @override
  String get importAction => 'Import';

  @override
  String get importManagedCopy => 'Copy into managed storage';

  @override
  String get importPickedCopyHint =>
      'Shōsai keeps its own copy of each picked book.';

  @override
  String get importPrivateCopyHint =>
      'Shōsai keeps a private copy available to the reader.';

  @override
  String get importLinkedCopyHint => 'Keep books in their selected locations.';

  @override
  String importStatusImported(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count books',
      one: '1 book',
    );
    return 'Imported $_temp0.';
  }

  @override
  String importStatusFailed(int count) {
    return '$count failed.';
  }

  @override
  String get importDetailsUnavailable =>
      'Some imported book details could not be loaded.';

  @override
  String get importUnsupported => 'This file type is not supported.';

  @override
  String get importNotFound => 'The selected file could not be found.';

  @override
  String get importTooLarge =>
      'The selected book exceeds the supported size limits.';

  @override
  String get importFailed => 'The selected book could not be imported.';

  @override
  String get importOperationFailed => 'The operation could not be completed.';

  @override
  String get importProviderUnavailable =>
      'The document provider is unavailable.';

  @override
  String get importProviderBusy => 'The document provider is busy. Try again.';

  @override
  String get importPermissionDenied =>
      'Permission to read the selected document was denied.';

  @override
  String get importSelectionTooLarge =>
      'The selection or document exceeds the import limit.';

  @override
  String get importReadFailed => 'The selected document could not be read.';

  @override
  String get importCancelled => 'Import cancelled.';

  @override
  String get importInvalidRequest =>
      'The document provider request is no longer valid.';

  @override
  String get libraryBookUnavailable => 'Unavailable';

  @override
  String get libraryLocations => 'Connections';

  @override
  String get libraryConnections => 'Library connections';

  @override
  String get manageConnections => 'Manage connections';

  @override
  String get libraryLocationsDescription =>
      'Manage the folders that supply your library.';

  @override
  String get locationSourceFolder => 'Source folder';

  @override
  String get locationSourceDescription =>
      'EPUB and PDF files in this folder and its subfolders appear in your library automatically. Files are fetched only when opened or kept on this device.';

  @override
  String get locationChooseFolder => 'Change source folder';

  @override
  String get locationUseFolder => 'Use this folder';

  @override
  String get locationAddFolder => 'Connect folder';

  @override
  String get locationAddGoogleDrive => 'Connect Google Drive';

  @override
  String get locationGoogleDriveRegistrationRequired =>
      'Google Drive is not configured in this build. The app distributor must configure Google OAuth first.';

  @override
  String get dropboxConnect => 'Connect Dropbox';

  @override
  String get dropboxCodeDescription =>
      'Approve access in your browser, then paste the Dropbox authorization code here. Add your books to this app’s folder under Apps in Dropbox. You can select a subfolder after connecting. Books are fetched only when opened or kept on this device.';

  @override
  String get dropboxAuthorizationCode => 'Authorization code';

  @override
  String get dropboxRegistrationRequired =>
      'Dropbox is not configured in this build. A registered Dropbox app key is required. Device folders remain available.';

  @override
  String get locationClose => 'Close';

  @override
  String get locationCancel => 'Cancel';

  @override
  String get locationLoading => 'Loading folder';

  @override
  String get locationOffline =>
      'This location is offline. Try again when it is connected.';

  @override
  String get locationRevoked =>
      'Access to this folder was revoked. Connect it again. Your notes are still here.';

  @override
  String get locationMissing =>
      'The folder or book is missing. Your notes are still here.';

  @override
  String get locationFailed =>
      'The folder could not be accessed. Check its permission and connection, then try again.';

  @override
  String locationScanWarning(String source) {
    return 'Could not refresh “$source”. Check its connection and permissions, or choose a smaller source folder in Settings, then retry. Other books are still available.';
  }

  @override
  String get locationBack => 'Back';

  @override
  String get locationRemove => 'Disconnect folder';

  @override
  String get locationRemoveDescription =>
      'Books and notes stay in your library. Books with no other location become unavailable. No source files are deleted.';

  @override
  String get locationNoFolders =>
      'Connect a device folder or a folder offered by your system’s file provider.';

  @override
  String get locationNextPage => 'Next page';

  @override
  String get shellSwitcherDone => 'Done';

  @override
  String get readerReference => 'Reference';

  @override
  String get readerReferenceClose => 'Close';

  @override
  String get readerReferenceGoTo => 'Go to';

  @override
  String readerReferencePage(int page) {
    return 'Page $page';
  }

  @override
  String get readerReferenceNoPreview =>
      'No text preview available. Go to the page to view this reference.';

  @override
  String get cardKeepOnDevice => 'Keep on this device';

  @override
  String get cardStopKeeping => 'Stop keeping on this device';
}
