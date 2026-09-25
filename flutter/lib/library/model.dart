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

/// The number of books one library page holds.
///
/// The controller requests this many books per page, and the continue-reading
/// rule below only considers the first page, so a book that only arrives on a
/// later page cannot introduce the section. The pinned Iced reference pages by
/// its own `LIBRARY_PAGE_SIZE` of 40 (`crates/shosai-app/src/app.rs:425`);
/// Flutter keeps its retained page size and applies the same first-page rule
/// with this value.
const int libraryPageSize = 50;

/// Which composition the collection column shows.
///
/// The pinned Iced `library_collection` (`crates/shosai-app/src/app.rs:7124`)
/// picks between these shapes in this order: a first-page load is the skeleton
/// grid, an empty result is the centred empty-library or no-matches
/// composition, and anything else is the grid with an optional failure alert
/// above it.
enum LibraryCollectionState {
  /// A first-page load is in flight: the reference's skeleton grid, which also
  /// replaces the grid while a search, filter or refresh reloads page one.
  loading,

  /// No books, no search and no format filter: the empty-library composition
  /// with its add-first-books action.
  empty,

  /// No books because a search or a format filter is active: the no-matches
  /// composition, which has no action.
  noMatches,

  /// Books to show. A failure is reported by the collection's alert above them
  /// instead of replacing them.
  ready,
}

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
    this.loading = false,
    this.loadingMore = false,
    this.loaded = false,
    this.error,
    this.loadError,
    this.pagingFailed = false,
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

  /// True while a library load effect is in flight.
  ///
  /// A load is the one effect that owns this flag, and only a completion that
  /// still owns the current load revision clears it, so a superseded load
  /// cannot end the skeleton a newer load started.
  final bool loading;

  /// True while the in-flight load appends a later page instead of page one.
  ///
  /// The reference's skeleton branch is `library_loading && library_offset ==
  /// 0`: a later page keeps the grid and shows its loading-more state instead.
  final bool loadingMore;

  final bool loaded;
  final String? error;
  final String? loadError;

  /// True when the last load failure was an appended page rather than page one.
  ///
  /// A paging failure keeps the loaded collection and its next page advertised,
  /// so its recovery is the collection's alert at the paging row: it retries
  /// the page that failed instead of reloading the collection.
  final bool pagingFailed;

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

  /// Which composition the collection column shows.
  LibraryCollectionState get collectionState {
    if (loading && !loadingMore) return LibraryCollectionState.loading;
    if (books.isNotEmpty) return LibraryCollectionState.ready;
    if (query.isEmpty && format == null) return LibraryCollectionState.empty;
    return LibraryCollectionState.noMatches;
  }

  /// The book the reference's continue-reading section shows, or null.
  ///
  /// The pinned Iced `continue_reading_book`
  /// (`crates/shosai-app/src/app.rs:7856-7866`) returns null while a search or
  /// a format filter is active, and otherwise takes the first book of the
  /// first page whose reading history is set (`lastRead`) and whose progress is
  /// still below 1.0. A finished book and a book that was never opened are both
  /// skipped, and a book that only arrives on a later page cannot introduce the
  /// section. The selection is a pure function of immutable model state; the
  /// card dispatches the book it was built with, so a later reload cannot
  /// change which book opens.
  FlutterLibraryBook? get continueBook {
    if (query.isNotEmpty || format != null) return null;
    for (final book in books.take(libraryPageSize)) {
      if (book.lastRead != null && book.progress < 1.0) return book;
    }
    return null;
  }

  LibraryModel copyWith({
    List<FlutterLibraryBook>? books,
    Map<int, Uint8List>? covers,
    int? coverRevision,
    String? query,
    Object? format = _same,
    Object? settings = _same,
    bool? busy,
    bool? importing,
    bool? loading,
    bool? loadingMore,
    bool? loaded,
    Object? error = _same,
    Object? loadError = _same,
    bool? pagingFailed,
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
    loading: loading ?? this.loading,
    loadingMore: loadingMore ?? this.loadingMore,
    loaded: loaded ?? this.loaded,
    error: identical(error, _same) ? this.error : error as String?,
    loadError: identical(loadError, _same)
        ? this.loadError
        : loadError as String?,
    pagingFailed: pagingFailed ?? this.pagingFailed,
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
