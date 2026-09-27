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

  @override
  String get readerContentsSubheading => '章と保存した場所';

  @override
  String get readerCloseContents => '目次を閉じる';

  @override
  String get readerChaptersHeading => '章';

  @override
  String readerChapterNumber(int number) {
    return '第$number章';
  }

  @override
  String readerBookmarksHeading(int count) {
    return 'ブックマーク · $count';
  }

  @override
  String get readerNoBookmarks => 'ブックマークはありません';

  @override
  String get readerBookmarkEmptyHint => 'ページを保存すると、あとですぐに開けます。';

  @override
  String readerPageShort(int page) {
    return '$pageページ';
  }

  @override
  String readerPageAbbreviated(int page) {
    return '$pageページ';
  }

  @override
  String readerDeleteBookmark(String title) {
    return '$titleを削除';
  }

  @override
  String get readerEditNote => 'メモを編集';

  @override
  String get readerAddNote => 'メモを追加';

  @override
  String get readerBookmarkNoteTitle => 'ブックマークのメモ';

  @override
  String get readerHighlightNoteTitle => 'ハイライトのメモ';

  @override
  String get readerNoteSave => '保存';

  @override
  String get readerNoteCancel => 'キャンセル';

  @override
  String get readerExportMarkdown => 'Markdownで書き出す';

  @override
  String get readerContentsLoading => '目次を読み込んでいます…';

  @override
  String get readerContentsEmpty => 'この文書に章はありません';

  @override
  String get readerContentsUnavailable => '目次を表示できません';

  @override
  String get readerRetry => '再試行';

  @override
  String get readerReading => '表示';

  @override
  String get readerDecreaseFontSize => '文字を小さく';

  @override
  String get readerIncreaseFontSize => '文字を大きく';

  @override
  String readerFontSizeValue(int size) {
    return '${size}px';
  }

  @override
  String get readerLineSpacingLabel => '行間';

  @override
  String readerLineSpacingValue(String spacing) {
    return '$spacing×';
  }

  @override
  String get readerThemeCycle => '読書テーマ';

  @override
  String get readerThemeLight => 'ライト';

  @override
  String get readerThemeDark => 'ダーク';

  @override
  String get readerThemeSepia => 'セピア';

  @override
  String get readerZoomOut => '縮小';

  @override
  String get readerZoomIn => '拡大';

  @override
  String get readerFitWidth => '幅に合わせる';

  @override
  String get readerFitPage => 'ページに合わせる';

  @override
  String get readerPageInputLabel => 'ページ';

  @override
  String readerPageOf(int total) {
    return '/ $total';
  }

  @override
  String readerPageInputInvalid(int total) {
    return '1～$totalのページを入力してください。';
  }

  @override
  String get readerSaved => '★ 保存済み';

  @override
  String get readerBookmark => '☆ ブックマーク';

  @override
  String get readerOpenBook => '本を開く';

  @override
  String get readerSearchAction => '検索';

  @override
  String get readerSearchPlaceholder => '文書内を検索...';

  @override
  String get readerNoResults => '結果なし';

  @override
  String readerSearchCount(int current, int total) {
    return '$current / $total';
  }

  @override
  String get readerPreviousResult => '前の結果';

  @override
  String get readerNextResult => '次の結果';

  @override
  String get readerCloseSearch => '検索を閉じる';

  @override
  String get readerSelectionActions => '選択操作';

  @override
  String get readerCopy => 'コピー';

  @override
  String get readerSelectionCancel => 'キャンセル';

  @override
  String get readerHighlightYellow => '黄';

  @override
  String get readerHighlightGreen => '緑';

  @override
  String get readerHighlightBlue => '青';

  @override
  String get readerHighlightPink => 'ピンク';

  @override
  String get readerHighlightPurple => '紫';

  @override
  String readerHighlightLabel(int number) {
    return 'ハイライト$number';
  }

  @override
  String get readerAnnotationRecovered => '復元';

  @override
  String get readerAnnotationAmbiguous => '候補が複数';

  @override
  String get readerAnnotationUnavailable => '利用不可';

  @override
  String get readerChangeColor => '色を変更';

  @override
  String get readerDeleteHighlight => 'ハイライトを削除';

  @override
  String get noticeReaderExportSucceeded => 'ブックマークをMarkdownとしてコピーしました';

  @override
  String get noticeReaderExportFailed => 'ブックマークを書き出せませんでした';
}
