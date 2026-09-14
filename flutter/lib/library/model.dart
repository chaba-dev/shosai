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
    this.loaded = false,
    this.error,
    this.loadError,
    this.hasMore = false,
    this.failure = LibraryFailure.none,
    this.providerCleanupPending = false,
    this.managedFileDeletionPending = false,
    this.notice,
  });

  final List<FlutterLibraryBook> books;
  final Map<int, Uint8List> covers;
  final int coverRevision;
  final String query;
  final FlutterBookFormat? format;
  final FlutterReaderSettings? settings;
  final bool busy;
  final bool loaded;
  final String? error;
  final String? loadError;
  String? get displayError => error ?? loadError;
  final bool hasMore;
  final LibraryFailure failure;
  final bool providerCleanupPending;
  final bool managedFileDeletionPending;
  final Notice? notice;

  LibraryModel copyWith({
    List<FlutterLibraryBook>? books,
    Map<int, Uint8List>? covers,
    int? coverRevision,
    String? query,
    Object? format = _same,
    Object? settings = _same,
    bool? busy,
    bool? loaded,
    Object? error = _same,
    Object? loadError = _same,
    bool? hasMore,
    LibraryFailure? failure,
    bool? providerCleanupPending,
    bool? managedFileDeletionPending,
    Object? notice = _same,
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
    notice: identical(notice, _same) ? this.notice : notice as Notice?,
  );
}

enum LibraryFailure { none, load, import, removal, settings }

const _same = Object();
