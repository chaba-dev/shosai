part of 'controller.dart';

sealed class LibraryMessage {
  const LibraryMessage();
}

final class LibraryStarted extends LibraryMessage {
  const LibraryStarted();
}

final class LibraryRefreshed extends LibraryMessage {
  const LibraryRefreshed();
}

final class LibraryMoreRequested extends LibraryMessage {
  const LibraryMoreRequested();
}

final class LibraryRetryRequested extends LibraryMessage {
  const LibraryRetryRequested();
}

/// The paging row's recovery: retry the page an appended load failed to add.
///
/// It is a separate intent from [LibraryRetryRequested] because the collection
/// alert above the grid recovers a mutation (an import, a removal, a settings
/// save) or a collection-level load, while the paging row recovers only the
/// page it asked for. Sharing one intent would let the paging row's Retry run
/// an unrelated mutation's recovery and vice versa.
final class LibraryMoreRetryRequested extends LibraryMessage {
  const LibraryMoreRetryRequested();
}

final class LibraryCleanupRetryRequested extends LibraryMessage {
  const LibraryCleanupRetryRequested();
}

final class LibraryManagedDeletionNoticeDismissed extends LibraryMessage {
  const LibraryManagedDeletionNoticeDismissed();
}

final class LibraryQueryChanged extends LibraryMessage {
  const LibraryQueryChanged(this.query);
  final String query;
}

final class LibraryFormatChanged extends LibraryMessage {
  const LibraryFormatChanged(this.format);
  final FlutterBookFormat? format;
}

/// The shelf's order changed; page one reloads in the new order.
final class LibrarySortChanged extends LibraryMessage {
  const LibrarySortChanged(this.sort);
  final FlutterLibrarySort sort;
}

/// The reader's Display panel changed settings the library saves: the
/// theme, the EPUB text size and line spacing, or the Pages setting (two pages
/// side by side, or one). Null fields are unchanged.
final class LibraryDisplayChanged extends LibraryMessage {
  const LibraryDisplayChanged({
    this.theme,
    this.fontSize,
    this.lineSpacing,
    this.twoPages,
    this.animations,
  });
  final String? theme;
  final double? fontSize;
  final double? lineSpacing;
  final bool? twoPages;
  final bool? animations;
}

/// Save the settings again after their last write failed.
final class LibrarySettingsSaveRetried extends LibraryMessage {
  const LibrarySettingsSaveRetried();
}

/// The failed settings write's report was dismissed.
final class LibrarySettingsFailureDismissed extends LibraryMessage {
  const LibrarySettingsFailureDismissed();
}

final class LibraryImportRequested extends LibraryMessage {
  const LibraryImportRequested();
}

/// A generation-guarded platform intake completion; the controller owns it.
final class _LibraryDocumentsOpened extends LibraryMessage {
  const _LibraryDocumentsOpened(this.paths);
  final List<String> paths;
}

final class LibraryCoverRequested extends LibraryMessage {
  const LibraryCoverRequested(this.bookId);
  final int bookId;
}

final class LibraryOperationCancelled extends LibraryMessage {
  const LibraryOperationCancelled();
}

final class LibraryBookOpened extends LibraryMessage {
  const LibraryBookOpened(this.book);
  final FlutterLibraryBook book;
}

final class LibrarySourceFileOpened extends LibraryMessage {
  const LibrarySourceFileOpened(this.file);
  final LibrarySourceFile file;
}

final class _LibrarySourceFileAdmitted extends LibraryMessage {
  const _LibrarySourceFileAdmitted(this.book, this.revision);
  final FlutterLibraryBook book;
  final int revision;
}

final class LibraryBookRemovalRequested extends LibraryMessage {
  const LibraryBookRemovalRequested(this.book);
  final FlutterLibraryBook book;
}

final class LibraryBookKeepRequested extends LibraryMessage {
  const LibraryBookKeepRequested(this.book);
  final FlutterLibraryBook book;
}

final class LibraryConnectionsRequested extends LibraryMessage {
  const LibraryConnectionsRequested();
}

final class _LibraryLoaded extends LibraryMessage {
  const _LibraryLoaded(
    this.revision,
    this.page,
    this.settings,
    this.append,
    this.cancellation,
    this.sort,
    this.sourceFiles, {
    this.discoveryError,
  });
  final int revision;
  final FlutterLibraryPage page;
  final FlutterReaderSettings? settings;
  final bool append;
  final BigInt cancellation;

  /// The order [page] is listed in.
  final FlutterLibrarySort sort;
  final List<LibrarySourceFile> sourceFiles;
  final String? discoveryError;
}

final class _LibrarySettingsLoaded extends LibraryMessage {
  const _LibrarySettingsLoaded(this.revision, this.settings);
  final int revision;
  final FlutterReaderSettings settings;
}

/// A field on the settings page changed.
final class LibrarySettingsChanged extends LibraryMessage {
  const LibrarySettingsChanged(this.settings);
  final FlutterReaderSettings settings;
}

/// A settings write finished, with its error if it failed.
final class _LibrarySettingsSaved extends LibraryMessage {
  const _LibrarySettingsSaved(this.error, {required this.notify});
  final String? error;

  /// Whether the write carried a change from the settings page, whose
  /// success is reported.
  final bool notify;
}

final class _LibraryFailed extends LibraryMessage {
  const _LibraryFailed(
    this.revision,
    this.error,
    this.failure,
    this.cancellation, {
    this.append = false,
  });
  final int revision;
  final String error;
  final LibraryFailure failure;
  final BigInt cancellation;

  /// Whether the failed load was appending a later page rather than page one.
  final bool append;
}

final class _LibraryDebounceElapsed extends LibraryMessage {
  const _LibraryDebounceElapsed(this.revision);
  final int revision;
}

final class _LibraryMutationCompleted extends LibraryMessage {
  const _LibraryMutationCompleted({
    required this.failure,
    this.error,
    this.cancellation,
    this.refresh = false,
    this.managedFileDeletionPending = false,
    this.notice,
  });
  final LibraryFailure failure;
  final String? error;
  final BigInt? cancellation;
  final bool refresh;
  final bool managedFileDeletionPending;

  /// The brief success feedback for this mutation, or null.
  ///
  /// The notice travels on the completion message so the handler owns raising
  /// it: a completion that arrives after disposal never reports feedback for an
  /// operation whose controller is gone.
  final NoticeRequest? notice;
}

/// The add-books import effect has unwound.
///
/// The import's completion is its own transition: it clears the state the
/// header's cancel action renders, before the generic effect-finished message
/// updates the busy count.
final class _LibraryImportEnded extends LibraryMessage {
  const _LibraryImportEnded();
}

/// The removal confirmation accepted the request.
///
/// The confirmation is an effect result like any other: it reports back as a
/// typed message, and the handler owns the pending-card transition and starts
/// the removal effect. A declined or stale confirmation never reaches the
/// handler.
final class _LibraryRemovalConfirmed extends LibraryMessage {
  const _LibraryRemovalConfirmed(this.book);

  final FlutterLibraryBook book;
}

final class _LibraryReaderClosed extends LibraryMessage {
  const _LibraryReaderClosed(this.error);
  final String? error;
}

final class _LibraryEffectFinished extends LibraryMessage {
  const _LibraryEffectFinished();
}

final class _LibraryCoverLoaded extends LibraryMessage {
  const _LibraryCoverLoaded(this.bookId, this.cover, this.cancellation);
  final int bookId;
  final Uint8List? cover;
  final BigInt cancellation;
}

final class _LibraryCoverFailed extends LibraryMessage {
  const _LibraryCoverFailed(this.bookId, this.cancellation);
  final int bookId;
  final BigInt cancellation;
}

final class _LibraryCoverEffectFinished extends LibraryMessage {
  const _LibraryCoverEffectFinished(this.bookId);
  final int bookId;
}

final class _LibraryCleanupStatusChanged extends LibraryMessage {
  const _LibraryCleanupStatusChanged(this.pending, this.revision);
  final bool pending;
  final int revision;
}

const _coverCacheByteLimit = 16 * 1024 * 1024;
const _coverCacheEntryLimit = 64;
const _coverLoadLimit = 4;
