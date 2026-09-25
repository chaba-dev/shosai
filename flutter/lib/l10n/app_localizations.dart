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

  /// Iced reference key: search-library-placeholder. The retained Flutter string keeps the approved candidate wording.
  ///
  /// In en, this message translates to:
  /// **'Search title or author'**
  String get searchLibraryPlaceholder;

  /// Iced reference key: collection. Uppercase in both locales by reference design.
  ///
  /// In en, this message translates to:
  /// **'COLLECTION'**
  String get collectionLabel;

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

  /// Retained Flutter extension of the Iced All/EPUB/PDF entries (plan decision 9). Latin in both locales on purpose.
  ///
  /// In en, this message translates to:
  /// **'CBZ'**
  String get filterFormatCbz;

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

  /// Iced reference key: continue. The continue card's right-hand link label; the two spaces before the chevron are the reference's own spacing.
  ///
  /// In en, this message translates to:
  /// **'Continue  ›'**
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

  /// Iced reference key: back-library.
  ///
  /// In en, this message translates to:
  /// **'‹ Library'**
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

  /// Iced reference key: reading-appearance.
  ///
  /// In en, this message translates to:
  /// **'Reading appearance'**
  String get readerAppearanceAction;

  /// NEW: no Iced string. Accessible name for the reader overflow control.
  ///
  /// In en, this message translates to:
  /// **'More'**
  String get readerMoreAction;

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

  /// Iced reference key: single-page-status.
  ///
  /// In en, this message translates to:
  /// **'Page {page} · {percentage}%'**
  String readerPageStatus(int page, int percentage);

  /// Iced reference key: page-range-status.
  ///
  /// In en, this message translates to:
  /// **'Pages {first}–{last} · {percentage}%'**
  String readerPageRangeStatus(int first, int last, int percentage);

  /// NEW: no Iced string; names the logical-unit display kind, composed from Iced chapter-number.
  ///
  /// In en, this message translates to:
  /// **'Chapter {chapter} · {percentage}%'**
  String readerChapterStatus(int chapter, int percentage);

  /// NEW: no Iced string, same reason as readerChapterStatus.
  ///
  /// In en, this message translates to:
  /// **'Chapters {first}–{last} · {percentage}%'**
  String readerChapterRangeStatus(int first, int last, int percentage);

  /// NEW: no Iced string. The reader tab close control; Iced paints a × glyph (app.rs tabs_view), this is its accessible label.
  ///
  /// In en, this message translates to:
  /// **'Close {title}'**
  String readerCloseTab(String title);

  /// NEW: no Iced string. The reader tab strip label; Iced renders the strip without an accessible label.
  ///
  /// In en, this message translates to:
  /// **'Open books'**
  String get readerTabsLabel;

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
