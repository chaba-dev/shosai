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
