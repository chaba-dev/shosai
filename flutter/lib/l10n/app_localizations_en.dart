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
}
