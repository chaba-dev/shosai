import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_ja.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('ja'),
  ];

  /// Iced reference key: library (crates/shosai-app/locales/en-US/main.ftl).
  ///
  /// In en, this message translates to:
  /// **'Library'**
  String get libraryTitle;

  /// Iced reference key: library-subtitle.
  ///
  /// In en, this message translates to:
  /// **'Your private reading room'**
  String get librarySubtitle;

  /// No description provided for @libraryCheckingSource.
  ///
  /// In en, this message translates to:
  /// **'Checking {source}'**
  String libraryCheckingSource(String source);

  /// Metadata candidates found in the current source; the total book count is unknown until the scan completes.
  ///
  /// In en, this message translates to:
  /// **'Source {index} of {total} · {books, plural, =1{1 book found} other{{books} books found}}'**
  String libraryDiscoveryCount(int index, int total, int books);

  /// No description provided for @libraryCheckCancelled.
  ///
  /// In en, this message translates to:
  /// **'Library check cancelled.'**
  String get libraryCheckCancelled;

  /// Iced reference key: search-library-placeholder. The retained Flutter string keeps the approved candidate wording.
  ///
  /// In en, this message translates to:
  /// **'Search title or author'**
  String get searchLibraryPlaceholder;

  /// Iced reference key: all (compact filter row).
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get filterAll;

  /// Iced reference key: all-books (wide sidebar).
  ///
  /// In en, this message translates to:
  /// **'All books'**
  String get filterAllBooks;

  /// Iced reference key: settings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get filterSettings;

  /// Format names stay Latin in both locales, as in the Iced reference; the value is identical in every catalog on purpose.
  ///
  /// In en, this message translates to:
  /// **'EPUB'**
  String get filterFormatEpub;

  /// Format names stay Latin in both locales, as in the Iced reference; the value is identical in every catalog on purpose.
  ///
  /// In en, this message translates to:
  /// **'PDF'**
  String get filterFormatPdf;

  /// Iced reference key: add-books. The Flutter action draws the plus as an icon, so the label carries no plus sign.
  ///
  /// In en, this message translates to:
  /// **'Add books'**
  String get addBooksAction;

  /// Iced reference key: cancel. Iced's cancel-adding-books-progress variant needs import progress the Flutter model does not carry yet.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancelImportAction;

  /// Retained Flutter capability (load cancellation); no Iced library-header counterpart.
  ///
  /// In en, this message translates to:
  /// **'Cancel operation'**
  String get cancelOperationTooltip;

  /// Retained Flutter capability; no Iced library-header counterpart.
  ///
  /// In en, this message translates to:
  /// **'Refresh library'**
  String get refreshLibraryTooltip;

  /// Iced reference key: unknown-author. Shown on the card when a book has no author.
  ///
  /// In en, this message translates to:
  /// **'Unknown author'**
  String get cardUnknownAuthor;

  /// Iced reference key: not-started. The card's reading status at zero progress.
  ///
  /// In en, this message translates to:
  /// **'Not started'**
  String get cardNotStarted;

  /// A book's reading status once it is read to the end.
  ///
  /// In en, this message translates to:
  /// **'Finished'**
  String get cardFinished;

  /// Iced reference key: percent. The card's reading status above zero progress; the placeholder is the rounded percentage, never concatenated in Dart.
  ///
  /// In en, this message translates to:
  /// **'{percentage}%'**
  String cardPercentRead(int percentage);

  /// Retained Flutter semantics label for the card's cover image.
  ///
  /// In en, this message translates to:
  /// **'Cover of {title}'**
  String cardCoverSemantics(String title);

  /// Semantics label for a shelf card's title: the title with its author, which the card shows only on a generated cover.
  ///
  /// In en, this message translates to:
  /// **'{title}, by {author}'**
  String cardTitleByAuthorSemantics(String title, String author);

  /// Retained Flutter tooltip for the card's overflow action; no Iced counterpart (Iced draws a bare glyph).
  ///
  /// In en, this message translates to:
  /// **'Book actions'**
  String get cardActionsTooltip;

  /// Iced reference key: remove-from-library. The card menu's action for a referenced book.
  ///
  /// In en, this message translates to:
  /// **'Remove from library'**
  String get cardRemoveFromLibrary;

  /// Retained Flutter variant of the card menu's action: a managed book also deletes the private copy. The confirmation dialog still explains the deletion.
  ///
  /// In en, this message translates to:
  /// **'Remove and delete copy'**
  String get cardRemoveManagedCopy;

  /// Iced reference key: removing. The card's status while its removal is in flight.
  ///
  /// In en, this message translates to:
  /// **'Removing…'**
  String get cardRemoving;

  /// Iced reference key: loading-more. The collection's paging feedback; the owner replaced the retained Load more button with automatic next-page loading (2026-09-25).
  ///
  /// In en, this message translates to:
  /// **'Loading more…'**
  String get libraryLoadingMore;

  /// Iced reference key: continue-reading. The collection section heading above the continue card.
  ///
  /// In en, this message translates to:
  /// **'Continue reading'**
  String get libraryContinueReading;

  /// The Continue reading hero's primary action, which opens the book at its saved place.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get libraryContinue;

  /// Iced reference key: percent-complete. The continue card's progress label; the placeholder is the rounded percentage, never concatenated in Dart.
  ///
  /// In en, this message translates to:
  /// **'{percentage}% complete'**
  String libraryPercentComplete(int percentage);

  /// Iced reference key: search-results. The collection section title while a search is active; the unfiltered title reuses filterAllBooks (Iced all-books).
  ///
  /// In en, this message translates to:
  /// **'Search results'**
  String get librarySearchResults;

  /// Iced reference key: empty-library-heading. The empty-library composition's 24 px heading.
  ///
  /// In en, this message translates to:
  /// **'A quiet place for every book'**
  String get libraryEmptyHeading;

  /// Iced reference key: empty-library. The empty-library composition's body; a library failure replaces it with the failure's own text.
  ///
  /// In en, this message translates to:
  /// **'No books in library. Import files to get started.'**
  String get libraryEmptyBody;

  /// Iced reference key: no-matching-books. The no-matches composition's 24 px heading.
  ///
  /// In en, this message translates to:
  /// **'No matching books'**
  String get libraryNoMatchesHeading;

  /// Iced reference key: empty-search. The no-matches composition's body; a library failure replaces it with the failure's own text.
  ///
  /// In en, this message translates to:
  /// **'No books match your search or filter.'**
  String get libraryNoMatchesBody;

  /// Iced reference key: add-first-books. The empty-library action; the Flutter action draws the plus as an icon, so the label carries no plus sign.
  ///
  /// In en, this message translates to:
  /// **'Add your first books'**
  String get libraryAddFirstBooks;

  /// Retained Flutter recovery action on the collection's failure alert; Iced's alert bar carries no action.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get libraryRetry;

  /// Retained Flutter debt state (provider cleanup pending); Iced has no counterpart. The wording is the pre-3C surface, now translated.
  ///
  /// In en, this message translates to:
  /// **'Temporary import data could not be removed yet.'**
  String get libraryCleanupPending;

  /// Retained Flutter recovery action for the provider-cleanup debt state.
  ///
  /// In en, this message translates to:
  /// **'Retry cleanup'**
  String get libraryCleanupRetry;

  /// Retained Flutter debt state (managed file deletion pending); Iced has no counterpart. The wording is the pre-3C surface, now translated.
  ///
  /// In en, this message translates to:
  /// **'Book removed. Its private copy will be deleted later.'**
  String get libraryDeletionPending;

  /// Retained Flutter acknowledgement action for the managed-deletion debt state.
  ///
  /// In en, this message translates to:
  /// **'Dismiss'**
  String get libraryDeletionDismiss;

  /// Package 2D notice copy: brief success after a clean import. Owned by 2D; the catalog entry is added by 3C so the notice module compiles.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Imported 1 book.} other{Imported {count} books.}}'**
  String noticeImportSucceeded(int count);

  /// Package 2D notice copy: persistent failure title after a partial import.
  ///
  /// In en, this message translates to:
  /// **'Some books could not be imported.'**
  String get noticeImportPartialTitle;

  /// Package 2D notice copy: persistent failure title after a failed import.
  ///
  /// In en, this message translates to:
  /// **'The import could not be completed.'**
  String get noticeImportFailedTitle;

  /// Package 2D notice copy: brief success after saving reader settings.
  ///
  /// In en, this message translates to:
  /// **'Reader settings saved.'**
  String get noticeSettingsSaved;

  /// Package 2D notice copy: persistent failure after a failed settings save.
  ///
  /// In en, this message translates to:
  /// **'Reader settings could not be saved.'**
  String get noticeSettingsSaveFailed;

  /// Package 2D notice copy: brief success after a removal.
  ///
  /// In en, this message translates to:
  /// **'Book removed.'**
  String get noticeBookRemoved;

  /// Package 2D notice copy: persistent failure after a failed removal.
  ///
  /// In en, this message translates to:
  /// **'The book could not be removed.'**
  String get noticeBookRemovalFailed;

  /// Package 2D notice copy: recovery action label.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get noticeRetry;

  /// Package 2D notice copy: acknowledgement action label.
  ///
  /// In en, this message translates to:
  /// **'Dismiss'**
  String get noticeDismiss;

  /// The phone reader toolbar back control (a chevron); its accessible name and tooltip.
  ///
  /// In en, this message translates to:
  /// **'Back to library'**
  String get readerBackToLibrary;

  /// Iced reference key: reader. The reader chrome title when no document title is available.
  ///
  /// In en, this message translates to:
  /// **'Reader'**
  String get readerFallbackTitle;

  /// Iced reference key: contents.
  ///
  /// In en, this message translates to:
  /// **'Contents'**
  String get readerContentsAction;

  /// The reader toolbar Aa control and the popover it opens: page theme, text size, zoom.
  ///
  /// In en, this message translates to:
  /// **'Display settings'**
  String get readerAppearanceAction;

  /// The reader toolbar Notes control and the panel it opens: bookmarks and highlights in this book.
  ///
  /// In en, this message translates to:
  /// **'Notes'**
  String get readerNotesAction;

  /// The Notes panel close control.
  ///
  /// In en, this message translates to:
  /// **'Close notes'**
  String get readerCloseNotes;

  /// The reader toolbar bookmark control while the page is not bookmarked.
  ///
  /// In en, this message translates to:
  /// **'Bookmark this page'**
  String get readerBookmarkPage;

  /// The reader toolbar bookmark control while the page is bookmarked.
  ///
  /// In en, this message translates to:
  /// **'Remove bookmark'**
  String get readerRemoveBookmark;

  /// Iced reference key: opening-document.
  ///
  /// In en, this message translates to:
  /// **'Opening document…'**
  String get readerOpeningDocument;

  /// Iced reference key: no-book-open.
  ///
  /// In en, this message translates to:
  /// **'No book open'**
  String get readerNoBookOpen;

  /// The reader place under the page: percent read, then the page.
  ///
  /// In en, this message translates to:
  /// **'{percentage}% · page {page}'**
  String readerPageStatus(int percentage, int page);

  /// The reader place under the page: percent read, then the pages shown.
  ///
  /// In en, this message translates to:
  /// **'{percentage}% · pages {first}–{last}'**
  String readerPageRangeStatus(int percentage, int first, int last);

  /// The reader place under the page: percent read, then the chapter (EPUB without page numbers).
  ///
  /// In en, this message translates to:
  /// **'{percentage}% · chapter {chapter}'**
  String readerChapterStatus(int percentage, int chapter);

  /// The reader place under the page: percent read, then the chapters shown.
  ///
  /// In en, this message translates to:
  /// **'{percentage}% · chapters {first}–{last}'**
  String readerChapterRangeStatus(int percentage, int first, int last);

  /// The reader place under the page: percent read, then the page and the page count.
  ///
  /// In en, this message translates to:
  /// **'{percentage}% · page {page} of {total}'**
  String readerPageOfStatus(int percentage, int page, int total);

  /// The reader place under the page: percent read, then the pages shown and the page count.
  ///
  /// In en, this message translates to:
  /// **'{percentage}% · pages {first}–{last} of {total}'**
  String readerPageRangeOfStatus(
    int percentage,
    int first,
    int last,
    int total,
  );

  /// The reader place under the page: percent read, then the chapter and the chapter count.
  ///
  /// In en, this message translates to:
  /// **'{percentage}% · chapter {chapter} of {total}'**
  String readerChapterOfStatus(int percentage, int chapter, int total);

  /// The reader place under the page: percent read, then the chapters shown and the chapter count.
  ///
  /// In en, this message translates to:
  /// **'{percentage}% · chapters {first}–{last} of {total}'**
  String readerChapterRangeOfStatus(
    int percentage,
    int first,
    int last,
    int total,
  );

  /// NEW: no Iced string. The reader edge navigation; Iced paints ‹/› glyphs (app.rs reader_edge_button), these are their accessible labels.
  ///
  /// In en, this message translates to:
  /// **'Previous page'**
  String get readerPreviousPage;

  /// NEW: no Iced string, the same accessible labels as readerPreviousPage.
  ///
  /// In en, this message translates to:
  /// **'Next page'**
  String get readerNextPage;

  /// NEW: no Iced string. The reader open-failure retry action.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get readerRetryOpen;

  /// Iced reference key: missing-book.
  ///
  /// In en, this message translates to:
  /// **'This book could not be found at its previous location.'**
  String get readerMissingBook;

  /// Iced reference key: locate-file.
  ///
  /// In en, this message translates to:
  /// **'Locate File…'**
  String get readerLocateFile;

  /// Iced reference key: remove-from-library.
  ///
  /// In en, this message translates to:
  /// **'Remove from Library'**
  String get readerRemoveFromLibrary;

  /// Iced reference key: chapters-saved-places. The Contents panel subheading.
  ///
  /// In en, this message translates to:
  /// **'Chapters and saved places'**
  String get readerContentsSubheading;

  /// NEW: no Iced string. The Contents panel close control; Iced paints a x glyph (app.rs bookmarks_panel).
  ///
  /// In en, this message translates to:
  /// **'Close contents'**
  String get readerCloseContents;

  /// Iced reference key: chapters.
  ///
  /// In en, this message translates to:
  /// **'Chapters'**
  String get readerChaptersHeading;

  /// Iced reference key: chapter-number. The chapter fallback for an untitled Contents entry.
  ///
  /// In en, this message translates to:
  /// **'Chapter {number}'**
  String readerChapterNumber(int number);

  /// Iced reference key: bookmark-count.
  ///
  /// In en, this message translates to:
  /// **'Bookmarks · {count}'**
  String readerBookmarksHeading(int count);

  /// Iced reference key: no-bookmarks.
  ///
  /// In en, this message translates to:
  /// **'No bookmarks yet'**
  String get readerNoBookmarks;

  /// Iced reference key: bookmark-empty-hint.
  ///
  /// In en, this message translates to:
  /// **'Save a page to keep it close at hand.'**
  String get readerBookmarkEmptyHint;

  /// Iced reference key: page-short. The saved-place title fallback.
  ///
  /// In en, this message translates to:
  /// **'Pg {page}'**
  String readerPageShort(int page);

  /// Iced reference key: page-abbreviated.
  ///
  /// In en, this message translates to:
  /// **'p.{page}'**
  String readerPageAbbreviated(int page);

  /// NEW: no Iced string. The saved-place delete control; Iced paints a x glyph (app.rs bookmarks_panel).
  ///
  /// In en, this message translates to:
  /// **'Delete {title}'**
  String readerDeleteBookmark(String title);

  /// Iced reference key: edit-note.
  ///
  /// In en, this message translates to:
  /// **'Edit note'**
  String get readerEditNote;

  /// Iced reference key: add-note.
  ///
  /// In en, this message translates to:
  /// **'Add note'**
  String get readerAddNote;

  /// A note on a page or place in the book, with no text range: the note dialog title and the Notes panel's new-note action.
  ///
  /// In en, this message translates to:
  /// **'Page note'**
  String get readerPageNoteTitle;

  /// A note about the whole book: the note dialog title and the Notes panel's new-note action.
  ///
  /// In en, this message translates to:
  /// **'Book note'**
  String get readerBookNoteTitle;

  /// The controller-injected note dialog title for a highlight (retained selection behavior).
  ///
  /// In en, this message translates to:
  /// **'Highlight note'**
  String get readerHighlightNoteTitle;

  /// The note dialog save action.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get readerNoteSave;

  /// The note dialog cancel action.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get readerNoteCancel;

  /// The BackPill after a jump: returns to the PDF page the jump left from.
  ///
  /// In en, this message translates to:
  /// **'Back to page {page}'**
  String readerBackToPage(int page);

  /// The BackPill after a jump: returns to the EPUB section the jump left from, by its contents title, or to the book a note or search hit was opened from, by its title.
  ///
  /// In en, this message translates to:
  /// **'Back to {place}'**
  String readerBackTo(String place);

  /// Closes the BackPill without going back.
  ///
  /// In en, this message translates to:
  /// **'Stay here'**
  String get readerBackDismiss;

  /// Notes panel: how many highlights, page notes and book notes are listed.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 note} other{{count} notes}}'**
  String readerNotesCount(int count);

  /// The Notes panel: the group of scope options (This book / All books).
  ///
  /// In en, this message translates to:
  /// **'Show notes from'**
  String get readerNotesScope;

  /// Notes panel: the empty state.
  ///
  /// In en, this message translates to:
  /// **'No notes yet. Select text to highlight it, or add a note to this page.'**
  String get readerNotesEmpty;

  /// A note card's place on a PDF page.
  ///
  /// In en, this message translates to:
  /// **'page {page}'**
  String readerPageNumber(int page);

  /// A page note card's meta line on a PDF page.
  ///
  /// In en, this message translates to:
  /// **'Page note · page {page}'**
  String readerPageNoteAt(int page);

  /// Notes panel: opens a note card's actions.
  ///
  /// In en, this message translates to:
  /// **'Note actions'**
  String get readerNoteActions;

  /// Notes panel: deletes a page note or book note.
  ///
  /// In en, this message translates to:
  /// **'Delete note'**
  String get readerDeleteNote;

  /// Iced reference key: export-markdown. 4C's delivery is the clipboard plus a brief notice (contract 9.2 item 1).
  ///
  /// In en, this message translates to:
  /// **'Export as Markdown'**
  String get readerExportMarkdown;

  /// NEW: no Iced string. The Contents panel's loading state (RD-07).
  ///
  /// In en, this message translates to:
  /// **'Loading contents…'**
  String get readerContentsLoading;

  /// NEW: no Iced string. The Contents panel's empty state (RD-07).
  ///
  /// In en, this message translates to:
  /// **'No chapters in this document'**
  String get readerContentsEmpty;

  /// NEW: no Iced string. The Contents panel's failure fallback (RD-07).
  ///
  /// In en, this message translates to:
  /// **'Contents unavailable'**
  String get readerContentsUnavailable;

  /// NEW: no Iced string. The Contents panel's retry action (RD-07).
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get readerRetry;

  /// Iced reference key: reading. The compact typography row label.
  ///
  /// In en, this message translates to:
  /// **'Reading'**
  String get readerReading;

  /// NEW: no Iced string. The EPUB A- control's accessible label (RD-09).
  ///
  /// In en, this message translates to:
  /// **'Decrease font size'**
  String get readerDecreaseFontSize;

  /// NEW: no Iced string. The EPUB A+ control's accessible label (RD-09).
  ///
  /// In en, this message translates to:
  /// **'Increase font size'**
  String get readerIncreaseFontSize;

  /// Iced reference format: the pinned reader_settings_panel renders `{}px` (app.rs:5914).
  ///
  /// In en, this message translates to:
  /// **'{size}px'**
  String readerFontSizeValue(int size);

  /// Iced reference key: default-epub-line-spacing. The line-spacing control's accessible label (contract 4.8).
  ///
  /// In en, this message translates to:
  /// **'Line spacing'**
  String get readerLineSpacingLabel;

  /// NEW: no Iced string. The line-spacing control's numeric label; the pinned settings pick list shows the raw value.
  ///
  /// In en, this message translates to:
  /// **'{spacing}×'**
  String readerLineSpacingValue(String spacing);

  /// NEW: no Iced string. The theme cycle control's accessible label; Iced shows only the theme name (RD-09).
  ///
  /// In en, this message translates to:
  /// **'Reading theme'**
  String get readerThemeCycle;

  /// The default page theme: warm paper.
  ///
  /// In en, this message translates to:
  /// **'Paper'**
  String get readerThemeLight;

  /// The dark page theme.
  ///
  /// In en, this message translates to:
  /// **'Night'**
  String get readerThemeDark;

  /// Iced reference key: sepia.
  ///
  /// In en, this message translates to:
  /// **'Sepia'**
  String get readerThemeSepia;

  /// The status line's progress track, read out as a slider; its value is the place.
  ///
  /// In en, this message translates to:
  /// **'Reading progress'**
  String get readerProgressTrack;

  /// Display settings: the page theme section heading.
  ///
  /// In en, this message translates to:
  /// **'Page theme'**
  String get readerPageTheme;

  /// Display settings: the EPUB text size section heading.
  ///
  /// In en, this message translates to:
  /// **'Text size'**
  String get readerTextSize;

  /// Display settings: under the text size stepper.
  ///
  /// In en, this message translates to:
  /// **'Pages reflow; your place is kept.'**
  String get readerTextSizeHint;

  /// Display settings: the PDF zoom section heading.
  ///
  /// In en, this message translates to:
  /// **'Zoom'**
  String get readerZoom;

  /// NEW: no Iced string. The raster zoom-out control's accessible label (RD-09).
  ///
  /// In en, this message translates to:
  /// **'Zoom out'**
  String get readerZoomOut;

  /// NEW: no Iced string. The raster zoom-in control's accessible label (RD-09).
  ///
  /// In en, this message translates to:
  /// **'Zoom in'**
  String get readerZoomIn;

  /// Iced reference key: fit-width.
  ///
  /// In en, this message translates to:
  /// **'Fit width'**
  String get readerFitWidth;

  /// Iced reference key: fit-page.
  ///
  /// In en, this message translates to:
  /// **'Fit page'**
  String get readerFitPage;

  /// NEW: no Iced string. The Display settings field that chooses one or two pages (RFD 12).
  ///
  /// In en, this message translates to:
  /// **'Pages'**
  String get readerPages;

  /// Whether page turns are animated in the reader.
  ///
  /// In en, this message translates to:
  /// **'Page animations'**
  String get readerPageAnimations;

  /// NEW: no Iced string. The hint under the Pages field: phones and narrow windows show one page.
  ///
  /// In en, this message translates to:
  /// **'Two pages show when the window has room.'**
  String get readerPagesHint;

  /// NEW: no Iced string. The one-page choice of the Pages field.
  ///
  /// In en, this message translates to:
  /// **'One'**
  String get readerOnePage;

  /// NEW: no Iced string. The two-page (spread) choice of the Pages field.
  ///
  /// In en, this message translates to:
  /// **'Two'**
  String get readerTwoPages;

  /// Iced reference key: page. The more panel's page-input placeholder.
  ///
  /// In en, this message translates to:
  /// **'Page'**
  String get readerPageInputLabel;

  /// Iced reference key: of-pages.
  ///
  /// In en, this message translates to:
  /// **'of {total}'**
  String readerPageOf(int total);

  /// NEW: no Iced string; the contract requires an inline error instead of the pinned field reset (contract 4.9).
  ///
  /// In en, this message translates to:
  /// **'Enter a page between 1 and {total}.'**
  String readerPageInputInvalid(int total);

  /// Contents: the label of the page field at the bottom.
  ///
  /// In en, this message translates to:
  /// **'Go to page'**
  String get readerGoToPage;

  /// No description provided for @readerGoToChapter.
  ///
  /// In en, this message translates to:
  /// **'Go to chapter'**
  String get readerGoToChapter;

  /// No description provided for @readerChapterInputLabel.
  ///
  /// In en, this message translates to:
  /// **'Chapter'**
  String get readerChapterInputLabel;

  /// No description provided for @readerChapterInputInvalid.
  ///
  /// In en, this message translates to:
  /// **'Enter a chapter between 1 and {total}.'**
  String readerChapterInputInvalid(int total);

  /// Iced reference key: search.
  ///
  /// In en, this message translates to:
  /// **'Search'**
  String get readerSearchAction;

  /// Iced reference key: search-document-placeholder.
  ///
  /// In en, this message translates to:
  /// **'Search in document...'**
  String get readerSearchPlaceholder;

  /// Iced reference key: no-results.
  ///
  /// In en, this message translates to:
  /// **'No results'**
  String get readerNoResults;

  /// Iced reference format: the pinned search_bar renders `{current} / {total}` (app.rs:6247).
  ///
  /// In en, this message translates to:
  /// **'{current} / {total}'**
  String readerSearchCount(int current, int total);

  /// NEW: no Iced string. The search previous-result control's accessible label (RD-11).
  ///
  /// In en, this message translates to:
  /// **'Previous result'**
  String get readerPreviousResult;

  /// NEW: no Iced string. The search next-result control's accessible label (RD-11).
  ///
  /// In en, this message translates to:
  /// **'Next result'**
  String get readerNextResult;

  /// NEW: no Iced string. The search close control's accessible label (RD-11).
  ///
  /// In en, this message translates to:
  /// **'Close search'**
  String get readerCloseSearch;

  /// NEW: no Iced string (RFD 16 authority). The selection action surface's container label (RD-12).
  ///
  /// In en, this message translates to:
  /// **'Selection actions'**
  String get readerSelectionActions;

  /// NEW: no Iced string (RFD 16 authority). The selection copy action, enabled only for a copy-eligible surface (RD-12).
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get readerCopy;

  /// NEW: no Iced string (RFD 16 authority). The selection cancel action (RD-12).
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get readerSelectionCancel;

  /// NEW: no Iced string (RFD 16 authority). The yellow highlight color action (RD-12).
  ///
  /// In en, this message translates to:
  /// **'Yellow'**
  String get readerHighlightYellow;

  /// NEW: no Iced string (RFD 16 authority). The green highlight color action (RD-12).
  ///
  /// In en, this message translates to:
  /// **'Green'**
  String get readerHighlightGreen;

  /// NEW: no Iced string (RFD 16 authority). The blue highlight color action (RD-12).
  ///
  /// In en, this message translates to:
  /// **'Blue'**
  String get readerHighlightBlue;

  /// NEW: no Iced string (RFD 16 authority). The pink highlight color action (RD-12).
  ///
  /// In en, this message translates to:
  /// **'Pink'**
  String get readerHighlightPink;

  /// NEW: no Iced string (RFD 16 authority). The purple highlight color action (RD-12).
  ///
  /// In en, this message translates to:
  /// **'Purple'**
  String get readerHighlightPurple;

  /// NEW: no Iced string (RFD 16 authority). The resolution suffix of a highlight recovered by quote context (RD-12).
  ///
  /// In en, this message translates to:
  /// **'recovered'**
  String get readerAnnotationRecovered;

  /// NEW: no Iced string (RFD 16 authority). The resolution suffix of a highlight with several candidate locations (RD-12).
  ///
  /// In en, this message translates to:
  /// **'ambiguous'**
  String get readerAnnotationAmbiguous;

  /// NEW: no Iced string (RFD 16 authority). The resolution suffix of an orphaned highlight (RD-12).
  ///
  /// In en, this message translates to:
  /// **'unavailable'**
  String get readerAnnotationUnavailable;

  /// NEW: no Iced string (RFD 16 authority). The recolor annotation action and its menu entry (RD-12, salvaged from #114).
  ///
  /// In en, this message translates to:
  /// **'Change color'**
  String get readerChangeColor;

  /// NEW: no Iced string (RFD 16 authority). The delete annotation action and its menu entry (RD-12, salvaged from #114).
  ///
  /// In en, this message translates to:
  /// **'Delete highlight'**
  String get readerDeleteHighlight;

  /// Package 4C notice copy: brief success after copying the Markdown bookmark export.
  ///
  /// In en, this message translates to:
  /// **'Bookmarks copied as Markdown'**
  String get noticeReaderExportSucceeded;

  /// Package 4C notice copy: persistent failure title after a failed Markdown bookmark export.
  ///
  /// In en, this message translates to:
  /// **'Bookmarks could not be exported'**
  String get noticeReaderExportFailed;

  /// The Bookshelf shell: accessible name of the sidebar, rail and bottom bar that hold the places.
  ///
  /// In en, this message translates to:
  /// **'Places'**
  String get shellPlacesLabel;

  /// The Bookshelf shell: the Library place in the sidebar, rail and bottom bar.
  ///
  /// In en, this message translates to:
  /// **'Library'**
  String get shellPlaceLibrary;

  /// The Bookshelf shell: the Notes place (notes and highlights across all books).
  ///
  /// In en, this message translates to:
  /// **'Notes'**
  String get shellPlaceNotes;

  /// The Bookshelf shell: the Bookmarks place (bookmarks across all books).
  ///
  /// In en, this message translates to:
  /// **'Bookmarks'**
  String get shellPlaceBookmarks;

  /// The Bookshelf shell: the Search place and the sidebar's field-shaped search button.
  ///
  /// In en, this message translates to:
  /// **'Search'**
  String get shellPlaceSearch;

  /// The Bookshelf shell: heading of the open books in the sidebar and on the phone's library.
  ///
  /// In en, this message translates to:
  /// **'Reading now'**
  String get shellReadingNow;

  /// The Bookshelf shell: accessible name and tooltip of an open book's close button.
  ///
  /// In en, this message translates to:
  /// **'Close {title}'**
  String shellCloseBook(String title);

  /// The Bookshelf shell: the Notes place before any note or highlight exists.
  ///
  /// In en, this message translates to:
  /// **'No notes yet'**
  String get shellNotesEmptyHeading;

  /// The Bookshelf shell: the Notes place's empty state, saying what to do.
  ///
  /// In en, this message translates to:
  /// **'Select text in a book to highlight it, or add a note to a page. Every note and highlight appears here.'**
  String get shellNotesEmptyBody;

  /// The Bookshelf shell: the Notes place while the library's notes are listed.
  ///
  /// In en, this message translates to:
  /// **'Loading notes…'**
  String get shellNotesLoading;

  /// The Bookshelf shell: lists the next books' notes in the Notes place.
  ///
  /// In en, this message translates to:
  /// **'More notes'**
  String get shellNotesMore;

  /// The search palette's field: its placeholder and accessible name.
  ///
  /// In en, this message translates to:
  /// **'Search books and notes'**
  String get shellSearchField;

  /// The search palette: the group of scope options.
  ///
  /// In en, this message translates to:
  /// **'Search in'**
  String get shellSearchScope;

  /// The search palette: search only the book being read.
  ///
  /// In en, this message translates to:
  /// **'This book'**
  String get shellSearchThisBook;

  /// The search palette: search every library book.
  ///
  /// In en, this message translates to:
  /// **'All books'**
  String get shellSearchAllBooks;

  /// The search palette: the group of filter options.
  ///
  /// In en, this message translates to:
  /// **'Find'**
  String get shellSearchFilter;

  /// The search palette: find book text and notes.
  ///
  /// In en, this message translates to:
  /// **'Everything'**
  String get shellSearchEverything;

  /// The search palette: find book text only.
  ///
  /// In en, this message translates to:
  /// **'Text'**
  String get shellSearchText;

  /// The search palette: find notes and highlights only.
  ///
  /// In en, this message translates to:
  /// **'Notes'**
  String get shellSearchNotes;

  /// The search palette before a query is typed.
  ///
  /// In en, this message translates to:
  /// **'Type to search the text and notes of your books.'**
  String get shellSearchHint;

  /// The search palette while books are still being searched.
  ///
  /// In en, this message translates to:
  /// **'Searching…'**
  String get shellSearchSearching;

  /// The search palette's close button.
  ///
  /// In en, this message translates to:
  /// **'Close search'**
  String get shellSearchClose;

  /// A search result group: the book was too long to search whole.
  ///
  /// In en, this message translates to:
  /// **'Only the beginning of this long book was searched.'**
  String get shellSearchPartial;

  /// The search palette when nothing matched.
  ///
  /// In en, this message translates to:
  /// **'No matches for “{query}”'**
  String shellSearchNoMatches(String query);

  /// The search palette's notes group heading with how many notes matched.
  ///
  /// In en, this message translates to:
  /// **'Notes · {count}'**
  String shellSearchNotesGroup(int count);

  /// A search result group: how many matches a book has.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 match} other{{count} matches}}'**
  String shellSearchMatches(int count);

  /// A search result group: a book with more matches than are shown.
  ///
  /// In en, this message translates to:
  /// **'{count}+ matches'**
  String shellSearchMoreMatches(int count);

  /// A search result group: why the book could not be read.
  ///
  /// In en, this message translates to:
  /// **'This book could not be searched: {error}'**
  String shellSearchBookFailed(String error);

  /// The Bookshelf shell: the Bookmarks place before any bookmark exists.
  ///
  /// In en, this message translates to:
  /// **'No bookmarks yet'**
  String get shellBookmarksEmptyHeading;

  /// The Bookshelf shell: the Bookmarks place's empty state, saying what to do.
  ///
  /// In en, this message translates to:
  /// **'Bookmark a page from the reader’s toolbar and it appears here.'**
  String get shellBookmarksEmptyBody;

  /// The library title row: how many books the library holds.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 book} other{{count} books}}'**
  String libraryBookCount(int count);

  /// The library title row, after the book count and a middle dot: how many books are open (Reading now). Hidden at zero.
  ///
  /// In en, this message translates to:
  /// **'{count} open'**
  String libraryOpenCount(int count);

  /// The accessible name of the library's sort control.
  ///
  /// In en, this message translates to:
  /// **'Sort'**
  String get librarySortLabel;

  /// The library's sort control: most recently read first.
  ///
  /// In en, this message translates to:
  /// **'Recent'**
  String get librarySortRecent;

  /// The library's sort control: by title.
  ///
  /// In en, this message translates to:
  /// **'Title'**
  String get librarySortTitle;

  /// The library's sort control: by author.
  ///
  /// In en, this message translates to:
  /// **'Author'**
  String get librarySortAuthor;

  /// The shelf card's meta line: the book is open (in Reading now).
  ///
  /// In en, this message translates to:
  /// **'Open'**
  String get cardOpenTag;

  /// The phone reader's open-book count button (its tooltip and accessible name) and the tab switcher's title.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 open book} other{{count} open books}}'**
  String shellOpenBooks(int count);

  /// No description provided for @importChooseFiles.
  ///
  /// In en, this message translates to:
  /// **'Choose files'**
  String get importChooseFiles;

  /// No description provided for @importChooseFilesHint.
  ///
  /// In en, this message translates to:
  /// **'Select one or more PDF or EPUB files'**
  String get importChooseFilesHint;

  /// No description provided for @importChooseFolder.
  ///
  /// In en, this message translates to:
  /// **'Choose a folder'**
  String get importChooseFolder;

  /// No description provided for @importChooseFolderHint.
  ///
  /// In en, this message translates to:
  /// **'Find supported books in all subfolders'**
  String get importChooseFolderHint;

  /// No description provided for @importReviewBooks.
  ///
  /// In en, this message translates to:
  /// **'Review books'**
  String get importReviewBooks;

  /// No description provided for @importReviewFolder.
  ///
  /// In en, this message translates to:
  /// **'Review folder import'**
  String get importReviewFolder;

  /// No description provided for @importBooksType.
  ///
  /// In en, this message translates to:
  /// **'Books'**
  String get importBooksType;

  /// No description provided for @importAction.
  ///
  /// In en, this message translates to:
  /// **'Import'**
  String get importAction;

  /// No description provided for @importManagedCopy.
  ///
  /// In en, this message translates to:
  /// **'Copy into managed storage'**
  String get importManagedCopy;

  /// No description provided for @importPickedCopyHint.
  ///
  /// In en, this message translates to:
  /// **'Shōsai keeps its own copy of each picked book.'**
  String get importPickedCopyHint;

  /// No description provided for @importPrivateCopyHint.
  ///
  /// In en, this message translates to:
  /// **'Shōsai keeps a private copy available to the reader.'**
  String get importPrivateCopyHint;

  /// No description provided for @importLinkedCopyHint.
  ///
  /// In en, this message translates to:
  /// **'Keep books in their selected locations.'**
  String get importLinkedCopyHint;

  /// No description provided for @importStatusImported.
  ///
  /// In en, this message translates to:
  /// **'Imported {count, plural, =1{1 book} other{{count} books}}.'**
  String importStatusImported(int count);

  /// No description provided for @importStatusFailed.
  ///
  /// In en, this message translates to:
  /// **'{count} failed.'**
  String importStatusFailed(int count);

  /// No description provided for @importDetailsUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Some imported book details could not be loaded.'**
  String get importDetailsUnavailable;

  /// No description provided for @importUnsupported.
  ///
  /// In en, this message translates to:
  /// **'This file type is not supported.'**
  String get importUnsupported;

  /// No description provided for @importNotFound.
  ///
  /// In en, this message translates to:
  /// **'The selected file could not be found.'**
  String get importNotFound;

  /// No description provided for @importTooLarge.
  ///
  /// In en, this message translates to:
  /// **'The selected book exceeds the supported size limits.'**
  String get importTooLarge;

  /// No description provided for @importFailed.
  ///
  /// In en, this message translates to:
  /// **'The selected book could not be imported.'**
  String get importFailed;

  /// No description provided for @importOperationFailed.
  ///
  /// In en, this message translates to:
  /// **'The operation could not be completed.'**
  String get importOperationFailed;

  /// No description provided for @importProviderUnavailable.
  ///
  /// In en, this message translates to:
  /// **'The document provider is unavailable.'**
  String get importProviderUnavailable;

  /// No description provided for @importProviderBusy.
  ///
  /// In en, this message translates to:
  /// **'The document provider is busy. Try again.'**
  String get importProviderBusy;

  /// No description provided for @importPermissionDenied.
  ///
  /// In en, this message translates to:
  /// **'Permission to read the selected document was denied.'**
  String get importPermissionDenied;

  /// No description provided for @importSelectionTooLarge.
  ///
  /// In en, this message translates to:
  /// **'The selection or document exceeds the import limit.'**
  String get importSelectionTooLarge;

  /// No description provided for @importReadFailed.
  ///
  /// In en, this message translates to:
  /// **'The selected document could not be read.'**
  String get importReadFailed;

  /// No description provided for @importCancelled.
  ///
  /// In en, this message translates to:
  /// **'Import cancelled.'**
  String get importCancelled;

  /// No description provided for @importInvalidRequest.
  ///
  /// In en, this message translates to:
  /// **'The document provider request is no longer valid.'**
  String get importInvalidRequest;

  /// No description provided for @libraryBookUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Unavailable'**
  String get libraryBookUnavailable;

  /// No description provided for @libraryLocations.
  ///
  /// In en, this message translates to:
  /// **'Connections'**
  String get libraryLocations;

  /// No description provided for @libraryConnections.
  ///
  /// In en, this message translates to:
  /// **'Library connections'**
  String get libraryConnections;

  /// No description provided for @manageConnections.
  ///
  /// In en, this message translates to:
  /// **'Manage connections'**
  String get manageConnections;

  /// No description provided for @libraryLocationsDescription.
  ///
  /// In en, this message translates to:
  /// **'Manage the folders that supply your library.'**
  String get libraryLocationsDescription;

  /// No description provided for @locationSourceFolder.
  ///
  /// In en, this message translates to:
  /// **'Source folder'**
  String get locationSourceFolder;

  /// No description provided for @locationConfirmSource.
  ///
  /// In en, this message translates to:
  /// **'Choose where to look for books, then select Use this folder to save the connection.'**
  String get locationConfirmSource;

  /// No description provided for @locationMyDrive.
  ///
  /// In en, this message translates to:
  /// **'My Drive'**
  String get locationMyDrive;

  /// No description provided for @locationDropboxAppFolder.
  ///
  /// In en, this message translates to:
  /// **'Dropbox app folder'**
  String get locationDropboxAppFolder;

  /// No description provided for @locationSourceDescription.
  ///
  /// In en, this message translates to:
  /// **'EPUB and PDF files in this folder and its subfolders appear in your library automatically. Files are fetched only when opened or kept on this device.'**
  String get locationSourceDescription;

  /// No description provided for @locationChooseFolder.
  ///
  /// In en, this message translates to:
  /// **'Change source folder'**
  String get locationChooseFolder;

  /// No description provided for @locationUseFolder.
  ///
  /// In en, this message translates to:
  /// **'Use this folder'**
  String get locationUseFolder;

  /// No description provided for @locationAddFolder.
  ///
  /// In en, this message translates to:
  /// **'Connect folder'**
  String get locationAddFolder;

  /// No description provided for @locationAddGoogleDrive.
  ///
  /// In en, this message translates to:
  /// **'Connect Google Drive'**
  String get locationAddGoogleDrive;

  /// No description provided for @locationGoogleDriveRegistrationRequired.
  ///
  /// In en, this message translates to:
  /// **'Google Drive is not configured in this build. The app distributor must configure Google OAuth first.'**
  String get locationGoogleDriveRegistrationRequired;

  /// No description provided for @locationGoogleDriveTokenRejected.
  ///
  /// In en, this message translates to:
  /// **'Google rejected the token exchange ({error}). The connection was not saved. Check the OAuth registration and try again.'**
  String locationGoogleDriveTokenRejected(String error);

  /// No description provided for @locationGoogleDrivePermissionsIncomplete.
  ///
  /// In en, this message translates to:
  /// **'Google did not return persistent Drive authorization. The connection was not saved. Try again and allow Drive access.'**
  String get locationGoogleDrivePermissionsIncomplete;

  /// No description provided for @locationGoogleDriveCredentialStorageFailed.
  ///
  /// In en, this message translates to:
  /// **'Google authorization completed, but the device credential store could not save it. Unlock your keyring and try again. The connection was not saved.'**
  String get locationGoogleDriveCredentialStorageFailed;

  /// No description provided for @dropboxConnect.
  ///
  /// In en, this message translates to:
  /// **'Connect Dropbox'**
  String get dropboxConnect;

  /// No description provided for @dropboxCancelTitle.
  ///
  /// In en, this message translates to:
  /// **'Cancel connecting to Dropbox?'**
  String get dropboxCancelTitle;

  /// No description provided for @dropboxCancelConnection.
  ///
  /// In en, this message translates to:
  /// **'Cancel connection'**
  String get dropboxCancelConnection;

  /// No description provided for @dropboxKeepWaiting.
  ///
  /// In en, this message translates to:
  /// **'Keep waiting'**
  String get dropboxKeepWaiting;

  /// No description provided for @dropboxCodeDescription.
  ///
  /// In en, this message translates to:
  /// **'Approve access in your browser, then paste the Dropbox authorization code here. Add your books to this app’s folder under Apps in Dropbox. Next, confirm that folder or choose a subfolder before the connection is saved. Books are fetched only when opened or kept on this device.'**
  String get dropboxCodeDescription;

  /// No description provided for @dropboxAuthorizationCode.
  ///
  /// In en, this message translates to:
  /// **'Authorization code'**
  String get dropboxAuthorizationCode;

  /// No description provided for @dropboxRegistrationRequired.
  ///
  /// In en, this message translates to:
  /// **'Dropbox is not configured in this build. A registered Dropbox app key is required. Device folders remain available.'**
  String get dropboxRegistrationRequired;

  /// No description provided for @locationClose.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get locationClose;

  /// No description provided for @locationCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get locationCancel;

  /// No description provided for @locationLoading.
  ///
  /// In en, this message translates to:
  /// **'Loading folder'**
  String get locationLoading;

  /// No description provided for @locationOffline.
  ///
  /// In en, this message translates to:
  /// **'This location is offline. Try again when it is connected.'**
  String get locationOffline;

  /// No description provided for @locationRevoked.
  ///
  /// In en, this message translates to:
  /// **'Access to this folder was revoked. Connect it again. Your notes are still here.'**
  String get locationRevoked;

  /// No description provided for @locationMissing.
  ///
  /// In en, this message translates to:
  /// **'The folder or book is missing. Your notes are still here.'**
  String get locationMissing;

  /// No description provided for @locationFailed.
  ///
  /// In en, this message translates to:
  /// **'The folder could not be accessed. Check its permission and connection, then try again.'**
  String get locationFailed;

  /// No description provided for @locationScanWarning.
  ///
  /// In en, this message translates to:
  /// **'Could not refresh “{source}”. Check its connection and permissions, or choose a smaller source folder in Settings, then retry. Other books are still available.'**
  String locationScanWarning(String source);

  /// No description provided for @locationBack.
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get locationBack;

  /// No description provided for @locationRemove.
  ///
  /// In en, this message translates to:
  /// **'Disconnect folder'**
  String get locationRemove;

  /// No description provided for @locationRemoveDescription.
  ///
  /// In en, this message translates to:
  /// **'Books and notes stay in your library. Books with no other location become unavailable. No source files are deleted.'**
  String get locationRemoveDescription;

  /// No description provided for @locationNoFolders.
  ///
  /// In en, this message translates to:
  /// **'Connect a device folder or a folder offered by your system’s file provider.'**
  String get locationNoFolders;

  /// No description provided for @locationNextPage.
  ///
  /// In en, this message translates to:
  /// **'Next page'**
  String get locationNextPage;

  /// The tab switcher's action that returns to the current book.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get shellSwitcherDone;

  /// No description provided for @readerReference.
  ///
  /// In en, this message translates to:
  /// **'Reference'**
  String get readerReference;

  /// No description provided for @readerReferenceClose.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get readerReferenceClose;

  /// No description provided for @readerReferenceGoTo.
  ///
  /// In en, this message translates to:
  /// **'Go to'**
  String get readerReferenceGoTo;

  /// No description provided for @readerReferencePage.
  ///
  /// In en, this message translates to:
  /// **'Page {page}'**
  String readerReferencePage(int page);

  /// No description provided for @readerReferenceNoPreview.
  ///
  /// In en, this message translates to:
  /// **'No text preview available. Go to the page to view this reference.'**
  String get readerReferenceNoPreview;

  /// No description provided for @cardKeepOnDevice.
  ///
  /// In en, this message translates to:
  /// **'Keep on this device'**
  String get cardKeepOnDevice;

  /// No description provided for @cardStopKeeping.
  ///
  /// In en, this message translates to:
  /// **'Stop keeping on this device'**
  String get cardStopKeeping;

  /// No description provided for @readerProgressLabel.
  ///
  /// In en, this message translates to:
  /// **'Progress'**
  String get readerProgressLabel;

  /// No description provided for @readerProgressPage.
  ///
  /// In en, this message translates to:
  /// **'Page'**
  String get readerProgressPage;

  /// No description provided for @readerProgressPercent.
  ///
  /// In en, this message translates to:
  /// **'Percent'**
  String get readerProgressPercent;

  /// No description provided for @readerProgressOff.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get readerProgressOff;

  /// No description provided for @readerQuietPageOf.
  ///
  /// In en, this message translates to:
  /// **'page {page} of {total}'**
  String readerQuietPageOf(int page, int total);

  /// No description provided for @readerControls.
  ///
  /// In en, this message translates to:
  /// **'Controls'**
  String get readerControls;

  /// No description provided for @readerZonesTitle.
  ///
  /// In en, this message translates to:
  /// **'How to turn pages'**
  String get readerZonesTitle;

  /// No description provided for @readerZonesInstruction.
  ///
  /// In en, this message translates to:
  /// **'Tap the sides to turn, the middle for controls.\nYou can also swipe. Tap anywhere to begin.'**
  String get readerZonesInstruction;

  /// No description provided for @readerZonesLeftward.
  ///
  /// In en, this message translates to:
  /// **'This book turns leftward.\nTap the sides to turn, the middle for controls. You can also swipe. Tap anywhere to begin.'**
  String get readerZonesLeftward;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'ja'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'ja':
      return AppLocalizationsJa();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
