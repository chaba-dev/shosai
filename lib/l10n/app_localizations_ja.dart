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
  String get cardFinished => '読了';

  @override
  String cardPercentRead(int percentage) {
    return '$percentage%';
  }

  @override
  String cardCoverSemantics(String title) {
    return '$titleの表紙';
  }

  @override
  String cardTitleByAuthorSemantics(String title, String author) {
    return '$title、$author';
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
  String get libraryContinue => '続きを読む';

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
  String get readerBackToLibrary => 'ライブラリに戻る';

  @override
  String get readerFallbackTitle => 'リーダー';

  @override
  String get readerContentsAction => '目次';

  @override
  String get readerAppearanceAction => '表示設定';

  @override
  String get readerNotesAction => 'ノート';

  @override
  String get readerCloseNotes => 'ノートを閉じる';

  @override
  String get readerBookmarkPage => 'このページをブックマーク';

  @override
  String get readerRemoveBookmark => 'ブックマークを外す';

  @override
  String get readerOpeningDocument => 'ドキュメントを開いています…';

  @override
  String get readerNoBookOpen => '本が開かれていません';

  @override
  String readerPageStatus(int percentage, int page) {
    return '$percentage% · $pageページ';
  }

  @override
  String readerPageRangeStatus(int percentage, int first, int last) {
    return '$percentage% · $first～$lastページ';
  }

  @override
  String readerChapterStatus(int percentage, int chapter) {
    return '$percentage% · 第$chapter章';
  }

  @override
  String readerChapterRangeStatus(int percentage, int first, int last) {
    return '$percentage% · $first～$last章';
  }

  @override
  String readerPageOfStatus(int percentage, int page, int total) {
    return '$percentage% · $page / $totalページ';
  }

  @override
  String readerPageRangeOfStatus(
    int percentage,
    int first,
    int last,
    int total,
  ) {
    return '$percentage% · $first～$last / $totalページ';
  }

  @override
  String readerChapterOfStatus(int percentage, int chapter, int total) {
    return '$percentage% · 第$chapter章 / 全$total章';
  }

  @override
  String readerChapterRangeOfStatus(
    int percentage,
    int first,
    int last,
    int total,
  ) {
    return '$percentage% · $first～$last章 / 全$total章';
  }

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
  String get readerPageNoteTitle => 'ページのメモ';

  @override
  String get readerBookNoteTitle => '本のメモ';

  @override
  String get readerHighlightNoteTitle => 'ハイライトのメモ';

  @override
  String get readerNoteSave => '保存';

  @override
  String get readerNoteCancel => 'キャンセル';

  @override
  String readerBackToPage(int page) {
    return '$pageページに戻る';
  }

  @override
  String readerBackTo(String place) {
    return '$placeに戻る';
  }

  @override
  String get readerBackDismiss => 'ここにとどまる';

  @override
  String readerNotesCount(int count) {
    return 'メモ $count件';
  }

  @override
  String get readerNotesScope => '表示するメモ';

  @override
  String get readerNotesEmpty =>
      'まだメモはありません。テキストを選んでハイライトするか、このページにメモを追加してください。';

  @override
  String readerPageNumber(int page) {
    return '$pageページ';
  }

  @override
  String readerPageNoteAt(int page) {
    return 'ページのメモ · $pageページ';
  }

  @override
  String get readerNoteActions => 'メモの操作';

  @override
  String get readerDeleteNote => 'メモを削除';

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
  String get readerThemeLight => '紙';

  @override
  String get readerThemeDark => '夜';

  @override
  String get readerThemeSepia => 'セピア';

  @override
  String get readerProgressTrack => '読書の進み具合';

  @override
  String get readerPageTheme => 'ページの色';

  @override
  String get readerTextSize => '文字サイズ';

  @override
  String get readerTextSizeHint => 'ページは組み直されます。読んでいる場所はそのままです。';

  @override
  String get readerZoom => 'ズーム';

  @override
  String get readerZoomOut => '縮小';

  @override
  String get readerZoomIn => '拡大';

  @override
  String get readerFitWidth => '幅に合わせる';

  @override
  String get readerFitPage => 'ページに合わせる';

  @override
  String get readerPages => 'ページ';

  @override
  String get readerPageAnimations => 'ページアニメーション';

  @override
  String get readerPagesHint => '画面に余裕があるときは見開きで表示します。';

  @override
  String get readerOnePage => '単ページ';

  @override
  String get readerTwoPages => '見開き';

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
  String get readerGoToPage => 'ページへ移動';

  @override
  String get readerGoToChapter => '章へ移動';

  @override
  String get readerChapterInputLabel => '章';

  @override
  String readerChapterInputInvalid(int total) {
    return '1～$totalの章を入力してください。';
  }

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

  @override
  String get shellPlacesLabel => '場所';

  @override
  String get shellPlaceLibrary => 'ライブラリ';

  @override
  String get shellPlaceNotes => 'ノート';

  @override
  String get shellPlaceBookmarks => 'ブックマーク';

  @override
  String get shellPlaceSearch => '検索';

  @override
  String get shellReadingNow => '読書中';

  @override
  String shellCloseBook(String title) {
    return '$titleを閉じる';
  }

  @override
  String get shellNotesEmptyHeading => 'ノートはまだありません';

  @override
  String get shellNotesEmptyBody =>
      '本の文章を選んでハイライトするか、ページにノートを追加してください。すべてのノートとハイライトがここに並びます。';

  @override
  String get shellNotesLoading => 'ノートを読み込んでいます…';

  @override
  String get shellNotesMore => 'さらに表示';

  @override
  String get shellSearchField => '本とノートを検索';

  @override
  String get shellSearchScope => '検索範囲';

  @override
  String get shellSearchThisBook => 'この本';

  @override
  String get shellSearchAllBooks => 'すべての本';

  @override
  String get shellSearchFilter => '検索対象';

  @override
  String get shellSearchEverything => 'すべて';

  @override
  String get shellSearchText => '本文';

  @override
  String get shellSearchNotes => 'ノート';

  @override
  String get shellSearchHint => '入力すると、本の本文とノートを検索します。';

  @override
  String get shellSearchSearching => '検索しています…';

  @override
  String get shellSearchClose => '検索を閉じる';

  @override
  String get shellSearchPartial => '長い本のため、冒頭の部分だけを検索しました。';

  @override
  String shellSearchNoMatches(String query) {
    return '「$query」に一致するものはありません';
  }

  @override
  String shellSearchNotesGroup(int count) {
    return 'ノート · $count';
  }

  @override
  String shellSearchMatches(int count) {
    return '$count件';
  }

  @override
  String shellSearchMoreMatches(int count) {
    return '$count件以上';
  }

  @override
  String shellSearchBookFailed(String error) {
    return 'この本は検索できませんでした: $error';
  }

  @override
  String get shellBookmarksEmptyHeading => 'ブックマークはまだありません';

  @override
  String get shellBookmarksEmptyBody => 'リーダーのツールバーからページをブックマークすると、ここに表示されます。';

  @override
  String libraryBookCount(int count) {
    return '$count冊';
  }

  @override
  String libraryOpenCount(int count) {
    return '$count冊を読書中';
  }

  @override
  String get librarySortLabel => '並べ替え';

  @override
  String get librarySortRecent => '最近';

  @override
  String get librarySortTitle => 'タイトル';

  @override
  String get librarySortAuthor => '著者';

  @override
  String get cardOpenTag => '読書中';

  @override
  String shellOpenBooks(int count) {
    return '読書中の本 $count冊';
  }

  @override
  String get importChooseFiles => 'ファイルを選択';

  @override
  String get importChooseFilesHint => 'PDFまたはEPUBファイルを選択します（複数選択可）';

  @override
  String get importChooseFolder => 'フォルダを選択';

  @override
  String get importChooseFolderHint => 'サブフォルダも含めて対応する本を探します';

  @override
  String get importReviewBooks => '追加する本を確認';

  @override
  String get importReviewFolder => '追加するフォルダを確認';

  @override
  String get importBooksType => '本';

  @override
  String get importAction => '追加';

  @override
  String get importManagedCopy => 'アプリ内にコピーを保存';

  @override
  String get importPickedCopyHint => '選択した本のコピーをShōsai内に保存します。';

  @override
  String get importPrivateCopyHint => '読書用のコピーをShōsai内に保存します。';

  @override
  String get importLinkedCopyHint => '本を選択した場所に残します。';

  @override
  String importStatusImported(int count) {
    return '$count冊を追加しました。';
  }

  @override
  String importStatusFailed(int count) {
    return '$count件を追加できませんでした。';
  }

  @override
  String get importDetailsUnavailable => '追加した本の一部の詳細を読み込めませんでした。';

  @override
  String get importUnsupported => 'このファイル形式には対応していません。';

  @override
  String get importNotFound => '選択したファイルが見つかりませんでした。';

  @override
  String get importTooLarge => '選択した本は対応するサイズの上限を超えています。';

  @override
  String get importFailed => '選択した本を追加できませんでした。';

  @override
  String get importOperationFailed => '操作を完了できませんでした。';

  @override
  String get importProviderUnavailable => '書類プロバイダを利用できません。';

  @override
  String get importProviderBusy => '書類プロバイダは使用中です。もう一度お試しください。';

  @override
  String get importPermissionDenied => '選択した書類の読み取りが許可されませんでした。';

  @override
  String get importSelectionTooLarge => '選択した書類の数またはサイズが追加の上限を超えています。';

  @override
  String get importReadFailed => '選択した書類を読み取れませんでした。';

  @override
  String get importCancelled => '追加をキャンセルしました。';

  @override
  String get importInvalidRequest => '書類プロバイダへの要求は無効になりました。';

  @override
  String get libraryBookUnavailable => '利用できません';

  @override
  String get libraryLocations => '接続';

  @override
  String get libraryConnections => 'ライブラリの接続';

  @override
  String get manageConnections => '接続を管理';

  @override
  String get libraryLocationsDescription =>
      '本は選択したフォルダに残ります。追加または開いた本だけを読み込みます。';

  @override
  String get locationAddFolder => 'フォルダを接続';

  @override
  String get locationClose => '閉じる';

  @override
  String get locationCancel => 'キャンセル';

  @override
  String get locationLoading => 'フォルダを読み込み中';

  @override
  String get locationOffline => 'この保存場所はオフラインです。接続後にもう一度お試しください。';

  @override
  String get locationRevoked => 'フォルダへのアクセスが取り消されました。再接続してください。ノートは残っています。';

  @override
  String get locationMissing => 'フォルダまたは本が見つかりません。ノートは残っています。';

  @override
  String get locationFailed => 'フォルダにアクセスできません。権限と接続を確認して、もう一度お試しください。';

  @override
  String get locationBookAdded => '本を追加しました。ライブラリに戻って開けます。';

  @override
  String get locationBack => '戻る';

  @override
  String get locationRemove => 'フォルダを切断';

  @override
  String get locationRemoveDescription =>
      '本とノートはライブラリに残ります。他の保存場所がない本は利用できなくなります。元のファイルは削除されません。';

  @override
  String get locationNoFolders =>
      '端末のフォルダ、またはシステムのファイルプロバイダが提供するフォルダを接続してください。';

  @override
  String get locationAddBook => 'ライブラリに追加';

  @override
  String get locationNextPage => '次のページ';

  @override
  String get shellSwitcherDone => '完了';

  @override
  String get readerReference => '参照';

  @override
  String get readerReferenceClose => '閉じる';

  @override
  String get readerReferenceGoTo => '移動';

  @override
  String readerReferencePage(int page) {
    return '$pageページ';
  }

  @override
  String get readerReferenceNoPreview =>
      'プレビューできるテキストがありません。ページに移動して参照を確認できます。';

  @override
  String get cardKeepOnDevice => 'この端末に保存';

  @override
  String get cardStopKeeping => 'この端末への保存を解除';
}
