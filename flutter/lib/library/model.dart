part of 'controller.dart';

typedef LibraryRemovalConfirmer =
    Future<bool> Function(FlutterLibraryBook book);
typedef LibraryImportPicker = Future<LibraryImportSelection?> Function();
typedef LibraryImportRunner =
    Future<FlutterImportReport> Function(
      FlutterBridge bridge,
      BigInt cancellation,
    );
typedef LibraryBookOpener = Future<void> Function(FlutterLibraryBook book);
typedef LibraryReaderSaveDrainer = Future<void> Function(int bookId);
typedef LibrarySettingsEditor =
    Future<FlutterReaderSettings?> Function(FlutterReaderSettings initial);
typedef LibraryImportAdapterCanceller = void Function();
typedef LibraryCoverEvicter = void Function(Uint8List bytes);
typedef LibraryProviderCleanupRetrier = Future<bool> Function();
void _ignoreImportAdapterCancellation() {}
void _ignoreCoverEviction(Uint8List _) {}
Future<bool> _ignoreProviderCleanupRetry() async => false;

final class LibraryImportSelection {
  const LibraryImportSelection({
    required this.paths,
    required this.managed,
    this.directory = false,
    this.runner,
    this.cleanup,
  });

  final List<String> paths;
  final bool managed;
  final bool directory;
  final LibraryImportRunner? runner;
  final Future<void> Function()? cleanup;
}

final class LibraryModel {
  const LibraryModel({
    this.books = const [],
    this.covers = const {},
    this.coverRevision = 0,
    this.query = '',
    this.format,
    this.settings,
    this.busy = false,
    this.importing = false,
    this.loaded = false,
    this.error,
    this.loadError,
    this.hasMore = false,
    this.failure = LibraryFailure.none,
    this.providerCleanupPending = false,
    this.managedFileDeletionPending = false,
    this.removingBookId,
  });

  final List<FlutterLibraryBook> books;
  final Map<int, Uint8List> covers;
  final int coverRevision;
  final String query;
  final FlutterBookFormat? format;
  final FlutterReaderSettings? settings;
  final bool busy;

  /// True while the add-books import is the foreground operation.
  ///
  /// The header's add-books action becomes the cancel action for this effect
  /// only; a library load is cancellable through the header's separate cancel
  /// action instead, so the two states are deliberately distinct.
  final bool importing;

  final bool loaded;
  final String? error;
  final String? loadError;
  String? get displayError => error ?? loadError;
  final bool hasMore;
  final LibraryFailure failure;
  final bool providerCleanupPending;
  final bool managedFileDeletionPending;

  /// The book whose confirmed removal is in flight, or null.
  ///
  /// The card shows the reference's removal-pending state for this book while
  /// the controller-owned removal effect runs; only the controller sets it, and
  /// only after the confirmation, so a cancelled confirmation leaves no card
  /// pending.
  final int? removingBookId;

  LibraryModel copyWith({
    List<FlutterLibraryBook>? books,
    Map<int, Uint8List>? covers,
    int? coverRevision,
    String? query,
    Object? format = _same,
    Object? settings = _same,
    bool? busy,
    bool? importing,
    bool? loaded,
    Object? error = _same,
    Object? loadError = _same,
    bool? hasMore,
    LibraryFailure? failure,
    bool? providerCleanupPending,
    bool? managedFileDeletionPending,
    Object? removingBookId = _same,
  }) => LibraryModel(
    books: books ?? this.books,
    covers: covers ?? this.covers,
    coverRevision: coverRevision ?? this.coverRevision,
    query: query ?? this.query,
    format: identical(format, _same)
        ? this.format
        : format as FlutterBookFormat?,
    settings: identical(settings, _same)
        ? this.settings
        : settings as FlutterReaderSettings?,
    busy: busy ?? this.busy,
    importing: importing ?? this.importing,
    loaded: loaded ?? this.loaded,
    error: identical(error, _same) ? this.error : error as String?,
    loadError: identical(loadError, _same)
        ? this.loadError
        : loadError as String?,
    hasMore: hasMore ?? this.hasMore,
    failure: failure ?? this.failure,
    providerCleanupPending:
        providerCleanupPending ?? this.providerCleanupPending,
    managedFileDeletionPending:
        managedFileDeletionPending ?? this.managedFileDeletionPending,
    removingBookId: identical(removingBookId, _same)
        ? this.removingBookId
        : removingBookId as int?,
  );
}

enum LibraryFailure { none, load, import, removal, settings }

const _same = Object();
