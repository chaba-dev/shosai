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

  @override
  String get cardUnknownAuthor => '著者不明';

  @override
  String get cardNotStarted => '未読';

  @override
  String cardPercentRead(int percentage) {
    return '$percentage%';
  }

  @override
  String cardCoverSemantics(String title) {
    return '$titleの表紙';
  }

  @override
  String get cardActionsTooltip => '本の操作';

  @override
  String get cardRemoveFromLibrary => 'ライブラリから削除';

  @override
  String get cardRemoveManagedCopy => 'コピーも削除';

  @override
  String get cardRemoving => '削除中…';

  @override
  String get libraryLoadingMore => 'さらに読み込み中…';

  @override
  String get libraryContinueReading => '読書を続ける';

  @override
  String get libraryContinue => '続きを読む  ›';

  @override
  String libraryPercentComplete(int percentage) {
    return '$percentage% 完了';
  }

  @override
  String get librarySearchResults => '検索結果';

  @override
  String get libraryEmptyHeading => 'すべての本に静かな居場所を';

  @override
  String get libraryEmptyBody => 'ライブラリに本がありません。ファイルを追加してください。';

  @override
  String get libraryNoMatchesHeading => '一致する本はありません';

  @override
  String get libraryNoMatchesBody => '検索条件に一致する本はありません。';

  @override
  String get libraryAddFirstBooks => '最初の本を追加';

  @override
  String get libraryRetry => '再試行';

  @override
  String get libraryCleanupPending => '一時的な取り込みデータをまだ削除できませんでした。';

  @override
  String get libraryCleanupRetry => 'クリーンアップを再試行';

  @override
  String get libraryDeletionPending => '本を削除しました。プライベートコピーは後で削除されます。';

  @override
  String get libraryDeletionDismiss => '閉じる';

  @override
  String noticeImportSucceeded(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count冊を取り込みました。',
    );
    return '$_temp0';
  }

  @override
  String get noticeImportPartialTitle => '一部の本を取り込めませんでした。';

  @override
  String get noticeImportFailedTitle => '取り込みを完了できませんでした。';

  @override
  String get noticeSettingsSaved => 'リーダー設定を保存しました。';

  @override
  String get noticeSettingsSaveFailed => 'リーダー設定を保存できませんでした。';

  @override
  String get noticeBookRemoved => '本を削除しました。';

  @override
  String get noticeBookRemovalFailed => '本を削除できませんでした。';

  @override
  String get noticeRetry => '再試行';

  @override
  String get noticeDismiss => '閉じる';

  @override
  String get readerBackToLibrary => '‹ ライブラリ';

  @override
  String get readerFallbackTitle => 'リーダー';

  @override
  String get readerContentsAction => '目次';

  @override
  String get readerAppearanceAction => '読書画面の表示';

  @override
  String get readerMoreAction => 'その他';

  @override
  String get readerOpeningDocument => 'ドキュメントを開いています…';

  @override
  String get readerNoBookOpen => '本が開かれていません';

  @override
  String readerPageStatus(int page, int percentage) {
    return '$pageページ · $percentage%';
  }

  @override
  String readerPageRangeStatus(int first, int last, int percentage) {
    return '$first～$lastページ · $percentage%';
  }

  @override
  String readerChapterStatus(int chapter, int percentage) {
    return '第$chapter章 · $percentage%';
  }

  @override
  String readerChapterRangeStatus(int first, int last, int percentage) {
    return '$first～$last章 · $percentage%';
  }

  @override
  String readerCloseTab(String title) {
    return '$titleを閉じる';
  }

  @override
  String get readerTabsLabel => '開いている本';

  @override
  String get readerPreviousPage => '前のページ';

  @override
  String get readerNextPage => '次のページ';

  @override
  String get readerRetryOpen => '再試行';

  @override
  String get readerMissingBook => 'この本は以前の場所に見つかりませんでした。';

  @override
  String get readerLocateFile => 'ファイルを探す…';

  @override
  String get readerRemoveFromLibrary => 'ライブラリから削除';
}
