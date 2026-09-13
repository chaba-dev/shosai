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

final class LibraryImportRequested extends LibraryMessage {
  const LibraryImportRequested();
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

final class LibraryBookRemovalRequested extends LibraryMessage {
  const LibraryBookRemovalRequested(this.book);
  final FlutterLibraryBook book;
}

final class LibrarySettingsRequested extends LibraryMessage {
  const LibrarySettingsRequested();
}

final class _LibraryLoaded extends LibraryMessage {
  const _LibraryLoaded(
    this.revision,
    this.page,
    this.settings,
    this.append,
    this.cancellation,
  );
  final int revision;
  final FlutterLibraryPage page;
  final FlutterReaderSettings? settings;
  final bool append;
  final BigInt cancellation;
}

final class _LibraryFailed extends LibraryMessage {
  const _LibraryFailed(
    this.revision,
    this.error,
    this.failure,
    this.cancellation,
  );
  final int revision;
  final String error;
  final LibraryFailure failure;
  final BigInt cancellation;
}

final class _LibraryDebounceElapsed extends LibraryMessage {
  const _LibraryDebounceElapsed(this.revision);
  final int revision;
}

final class _LibraryMutationCompleted extends LibraryMessage {
  const _LibraryMutationCompleted({
    required this.failure,
    this.error,
    this.settings,
    this.cancellation,
    this.refresh = false,
    this.managedFileDeletionPending = false,
  });
  final LibraryFailure failure;
  final String? error;
  final FlutterReaderSettings? settings;
  final BigInt? cancellation;
  final bool refresh;
  final bool managedFileDeletionPending;
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
