// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Japanese (`ja`).
class AppLocalizationsJa extends AppLocalizations {
  AppLocalizationsJa([String locale = 'ja']) : super(locale);

  @override
  String get libraryTitle => 'ライブラリ';

  @override
  String get librarySubtitle => '自分だけの読書室';

  @override
  String get searchLibraryPlaceholder => 'タイトル・著者を検索...';

  @override
  String get collectionLabel => 'コレクション';

  @override
  String get filterAll => 'すべて';

  @override
  String get filterAllBooks => 'すべての本';

  @override
  String get filterSettings => '設定';

  @override
  String get filterFormatEpub => 'EPUB';

  @override
  String get filterFormatPdf => 'PDF';

  @override
  String get filterFormatCbz => 'CBZ';

  @override
  String get addBooksAction => '本を追加';

  @override
  String get cancelImportAction => 'キャンセル';

  @override
  String get cancelOperationTooltip => '操作をキャンセル';

  @override
  String get refreshLibraryTooltip => 'ライブラリを更新';
}
