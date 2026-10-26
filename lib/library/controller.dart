import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show Listenable, VoidCallback;
import 'package:shosai_core/shosai_core.dart'
    show maxSelectedImportPaths, CancellationToken, CancellationCheck;
import 'package:shosai_flutter/android_document_import_adapter.dart';
import 'package:shosai_flutter/core/library_folders.dart';
import 'package:shosai_flutter/core/records.dart';
import 'package:shosai_flutter/library/errors.dart';
import 'package:shosai_flutter/l10n/app_localizations.dart';
import 'package:shosai_flutter/l10n/app_localizations_en.dart';
import 'package:shosai_flutter/notices/library_notice_text.dart';
import 'package:shosai_flutter/notices/notices.dart';
import 'package:shosai_flutter/opened_documents.dart';
import 'package:shosai_flutter/core/bridge.dart';

part 'message.dart';
part 'model.dart';

class LibraryController implements Listenable {
  LibraryController({
    required FlutterBridge bridge,
    required LibraryRemovalConfirmer confirmRemoval,
    required LibraryImportPicker pickImport,
    required LibraryBookOpener openBook,
    required LibraryReaderSaveDrainer drainReaderSaves,
    Future<void> Function()? manageConnections,
    LibraryProviderCleanupRetrier retryProviderCleanup =
        _ignoreProviderCleanupRetry,
    LibraryImportAdapterCanceller cancelImportAdapter =
        _ignoreImportAdapterCancellation,
    LibraryCoverEvicter evictCover = _ignoreCoverEviction,
    NoticeReporter noticeReporter = ignoreNotice,
    AppLocalizations Function() localizations = AppLocalizationsEn.new,
    OpenedDocuments? openedDocuments,
  }) : _bridge = bridge,
       _records = recordsOf(bridge),
       _confirmRemoval = confirmRemoval,
       _pickImport = pickImport,
       _openBook = openBook,
       _drainReaderSaves = drainReaderSaves,
       _manageConnections = manageConnections,
       _retryProviderCleanup = retryProviderCleanup,
       _cancelImportAdapter = cancelImportAdapter,
       _evictCover = evictCover,
       _reportNotice = noticeReporter,
       _localizations = localizations,
       _openedDocuments = openedDocuments;

  final FlutterBridge _bridge;

  /// The library's books and settings, served beside [_bridge].
  final ShosaiRecords _records;
  final LibraryRemovalConfirmer _confirmRemoval;
  final LibraryImportPicker _pickImport;
  final LibraryBookOpener _openBook;
  final LibraryReaderSaveDrainer _drainReaderSaves;
  final Future<void> Function()? _manageConnections;
  final LibraryProviderCleanupRetrier _retryProviderCleanup;
  final LibraryImportAdapterCanceller _cancelImportAdapter;
  final LibraryCoverEvicter _evictCover;
  final AppLocalizations Function() _localizations;
  final OpenedDocuments? _openedDocuments;
  final Set<String> _openedPaths = {};
  bool _listeningForDocuments = false;

  /// Reports brief success feedback to the application notice center.
  ///
  /// The composition root injects the center's reporter; a controller built
  /// without one reports nothing.
  final NoticeReporter _reportNotice;
  LibraryModel _model = const LibraryModel();
  final Set<VoidCallback> _listeners = {};
  final Set<BigInt> _cancellations = {};
  final Set<BigInt> _foregroundCancellations = {};
  final Set<BigInt> _loadCancellations = {};
  final Map<int, BigInt> _coverRequests = {};
  final Map<int, Uint8List> _coverCache = {};
  final Set<int> _coverFailures = {};
  int _coverCacheBytes = 0;
  Timer? _searchTimer;
  int _loadRevision = 0;
  int _queryRevision = 0;
  int _activeEffects = 0;
  int _activeBusyEffects = 0;
  int _adapterRevision = 0;
  int _cleanupRevision = 0;
  String? _displayedQuery;
  FlutterBookFormat? _displayedFormat;
  FlutterLibrarySort? _displayedSort;

  /// Whether the shelf's order was chosen in this session, so the saved one
  /// no longer applies.
  bool _sortChosen = false;

  /// Whether a settings write is running. Writes run one at a time, each
  /// with the settings as they are when it starts: a change made meanwhile
  /// sets [_settingsQueued] and is written next, and [_settingsNotify] says
  /// whether a written change came from the settings dialog.
  bool _settingsWriting = false;
  bool _settingsQueued = false;
  bool _settingsNotify = false;
  int? _stalledAppendOffset;
  CancellationToken? _keepCancellation;
  CancellationToken? _sourceCancellation;
  CancellationToken? _discoveryCancellation;
  bool _closing = false;
  bool _bridgeDisposed = false;
  bool _pendingImportAdapter = false;

  LibraryModel get model => _model;
  bool get canCancel =>
      _pendingImportAdapter ||
      _foregroundCancellations.isNotEmpty ||
      _keepCancellation != null ||
      _sourceCancellation != null;

  bool requestCover(int bookId) {
    if (!_canLoadCover(bookId)) return false;
    dispatch(LibraryCoverRequested(bookId));
    return true;
  }

  void dispatch(LibraryMessage message) {
    if (_closing && message is _LibraryDocumentsOpened) {
      unawaited(_openedDocuments?.discard(message.paths));
      return;
    }
    if (_closing &&
        message is! _LibraryLoaded &&
        message is! _LibraryFailed &&
        message is! _LibraryMutationCompleted &&
        message is! _LibraryReaderClosed &&
        message is! _LibraryEffectFinished &&
        message is! _LibraryCoverLoaded &&
        message is! _LibraryCoverFailed &&
        message is! _LibraryCoverEffectFinished &&
        message is! _LibrarySettingsSaved &&
        message is! _LibraryCleanupStatusChanged) {
      return;
    }
    switch (message) {
      case LibraryStarted():
        _retryCleanup();
        _load();
        if (!_listeningForDocuments && _openedDocuments != null) {
          _listeningForDocuments = true;
          unawaited(
            _openedDocuments.listen(
              (paths) => dispatch(_LibraryDocumentsOpened(paths)),
            ),
          );
        }
      case _LibraryDocumentsOpened(:final paths):
        _openedPaths.addAll(paths);
      case LibraryRefreshed():
        _coverFailures.clear();
        _emit(_model.copyWith(coverRevision: _model.coverRevision + 1));
        _load(refreshSources: true);
      case LibraryMoreRequested():
        // The scroll trigger can fire again before the model it was built with
        // is replaced, so the request is refused while a load is in flight:
        // one page is fetched per completed page, never two for one trigger.
        // A paging failure keeps its own recovery — its alert's Retry is the
        // way back — so the trigger cannot retry the failed page by itself,
        // and an append that added no books while still advertising another
        // page cannot make progress, so its offset is not asked for again.
        if (_model.hasMore &&
            !_model.loading &&
            _model.loadError == null &&
            _stalledAppendOffset != _model.books.length &&
            _displayedQuery == _model.query &&
            _displayedFormat == _model.format &&
            _displayedSort == _model.sort) {
          _load(append: true);
        }
      case LibraryMoreRetryRequested():
        // The paging row's Retry retries the page that failed, and only while
        // that failure still belongs to the displayed collection: a retry is
        // not a new trigger, so it obeys the same admission as the trigger.
        if (_model.pagingFailed &&
            _model.loadError != null &&
            !_model.loading &&
            _displayedQuery == _model.query &&
            _displayedFormat == _model.format &&
            _displayedSort == _model.sort) {
          _load(append: true);
        }
      case LibraryRetryRequested():
        switch (_model.failure) {
          case LibraryFailure.load || LibraryFailure.none:
            _load(refreshSources: true);
          case LibraryFailure.import:
            _import();
          case LibraryFailure.removal:
            _load();
          case LibraryFailure.settings:
            _saveSettings();
        }
      case LibraryCleanupRetryRequested():
        _retryCleanup();
      case LibraryQueryChanged():
        _emit(_model.copyWith(query: message.query, hasMore: false));
        _loadRevision += 1;
        _searchTimer?.cancel();
        final revision = ++_queryRevision;
        _searchTimer = Timer(
          const Duration(milliseconds: 250),
          () => dispatch(_LibraryDebounceElapsed(revision)),
        );
      case LibraryFormatChanged():
        _emit(_model.copyWith(format: message.format, hasMore: false));
        _loadRevision += 1;
        _load();
      case LibrarySortChanged():
        if (message.sort == _model.sort) return;
        _sortChosen = true;
        final settings = _model.settings?.copyWith(librarySort: message.sort);
        _emit(
          _model.copyWith(
            sort: message.sort,
            settings: settings ?? _model.settings,
            hasMore: false,
          ),
        );
        if (settings != null) _saveSettings();
        _loadRevision += 1;
        _load();
      case LibraryDisplayChanged():
        final settings = _model.settings;
        if (settings == null) return;
        final changed = settings.copyWith(
          theme: message.theme,
          epubFontSize: message.fontSize,
          epubLineSpacing: message.lineSpacing,
          twoPages: message.twoPages,
          animations: message.animations,
        );
        if (changed == settings) return;
        _emit(_model.copyWith(settings: changed));
        _saveSettings();
      case LibrarySettingsSaveRetried():
        // Retry the settings already in place, without leaving the page or
        // the reader where the change was made.
        if (_model.failure == LibraryFailure.settings &&
            _model.settings != null) {
          _saveSettings();
        }
      case LibrarySettingsFailureDismissed():
        if (_model.failure == LibraryFailure.settings) {
          _emit(_model.copyWith(error: null, failure: LibraryFailure.none));
        }
      case LibrarySettingsChanged():
        if (_model.settings == null) return;
        // Preserve the shelf order and reader-only settings when applying
        // the fields exposed by the settings page.
        final edited = message.settings;
        _emit(
          _model.copyWith(
            settings: _model.settings!.copyWith(
              continuous: edited.continuous,
              theme: edited.theme,
              epubFontSize: edited.epubFontSize,
              epubLineSpacing: edited.epubLineSpacing,
              pdfZoom: edited.pdfZoom,
            ),
          ),
        );
        _saveSettings(notify: true);
      case _LibrarySettingsSaved():
        _activeEffects -= 1;
        _settingsWriting = false;
        if (_settingsQueued) {
          // The next write saves a newer change and reports for both.
          _settingsNotify = _settingsNotify || message.notify;
          _saveSettings();
        } else if (!_closing) {
          if (message.error case final error?) {
            _emit(
              _model.copyWith(error: error, failure: LibraryFailure.settings),
            );
          } else {
            if (message.notify) {
              _reportNotice(
                const NoticeRequest(
                  text: LibrarySettingsSavedNotice(),
                  kind: NoticeKind.success,
                ),
              );
            }
            if (_model.failure == LibraryFailure.settings) {
              _emit(_model.copyWith(error: null, failure: LibraryFailure.none));
            }
          }
        }
        _disposeBridgeIfIdle();
      case LibraryImportRequested():
        _import();
      case LibraryCoverRequested():
        _loadCover(message.bookId);
      case LibraryOperationCancelled():
        _adapterRevision += 1;
        _keepCancellation?.cancel();
        _sourceCancellation?.cancel();
        _discoveryCancellation?.cancel();
        _pendingImportAdapter = false;
        _cancelImportAdapter();
        for (final cancellation in _foregroundCancellations) {
          _bridge.cancel(id: cancellation);
        }
        _emit(_model.copyWith(discoveryProgress: null));
      case LibraryBookOpened():
        _open(message.book);
      case LibrarySourceFileOpened():
        _openSource(message.file);
      case _LibrarySourceFileAdmitted():
        if (!_closing && message.revision == _adapterRevision) {
          _open(message.book);
        }
      case LibraryBookRemovalRequested():
        _requestRemoval(message.book);
      case LibraryBookKeepRequested():
        _keep(message.book);
      case _LibraryRemovalConfirmed():
        if (_closing) break;
        // The reference marks the card as removing once the removal is
        // confirmed and running; the mutation completion clears it again.
        _emit(_model.copyWith(removingBookId: message.book.bookId));
        _remove(message.book);
      case LibraryConnectionsRequested():
        _connections();
      case _LibraryDebounceElapsed():
        if (message.revision == _queryRevision) _load();
      case _LibrarySettingsLoaded():
        if (!_closing &&
            message.revision == _loadRevision &&
            _model.settings == null) {
          _emit(_model.copyWith(settings: message.settings));
        }
      case _LibraryDiscoveryProgressed():
        if (message.revision == _loadRevision &&
            _model.loading &&
            !(_discoveryCancellation?.isCancelled ?? true)) {
          _emit(_model.copyWith(discoveryProgress: message.progress));
        }
      case _LibraryLoaded():
        _releaseCancellation(message.cancellation);
        // A closed controller drains its effects but owns no model state: a
        // completion that arrives after disposal cannot write it.
        if (!_closing && message.revision == _loadRevision) {
          if (!message.append) {
            _displayedQuery = _model.query;
            _displayedFormat = _model.format;
            _displayedSort = message.sort;
            // A replacement load is a new collection: whatever offset stalled
            // before it is not this collection's.
            _stalledAppendOffset = null;
          } else if (message.page.books.isEmpty && message.page.hasMore) {
            // The page claimed another page but added nothing, so the next
            // request would repeat this offset and return the same empty page.
            // The Rust producer derives `has_more` from a `limit + 1` fetch and
            // cannot report this shape; refusing the repeat bounds a malformed
            // response instead of looping on it.
            _stalledAppendOffset = _model.books.length;
          }
          _emit(
            _model.copyWith(
              books: List.unmodifiable(
                message.append
                    ? [
                        ..._model.books,
                        ...message.page.books.map(_withoutCover),
                      ]
                    : message.page.books.map(_withoutCover).toList(),
              ),
              sourceFiles: message.sourceFiles,
              // An order chosen while the settings loaded is the one kept.
              settings: (_model.settings ?? message.settings)?.copyWith(
                librarySort: message.sort,
              ),
              sort: message.sort,
              bookCount: message.page.bookCount == null
                  ? null
                  : message.page.bookCount! + message.sourceFiles.length,
              continueReading: switch (message.page.continueReading) {
                final book? => _withoutCover(book),
                null => null,
              },
              continueReadingNotes: message.page.continueReadingNotes,
              loaded: true,
              loading: false,
              loadingMore: false,
              discoveryProgress: null,
              loadError: message.discoveryError,
              sourceWarning: message.sourceWarning,
              pagingFailed: false,
              hasMore: message.page.hasMore,
            ),
          );
          // An order chosen before the saved settings arrived is saved now
          // that there are settings to save it with.
          if (message.settings case final loaded?
              when loaded.librarySort != message.sort) {
            _saveSettings();
          }
        }
      case _LibraryFailed():
        _releaseCancellation(message.cancellation);
        if (!_closing && message.revision == _loadRevision) {
          _emit(
            _model.copyWith(
              loading: false,
              loadingMore: false,
              discoveryProgress: null,
              loadError: message.error,
              // A failed first page leaves the page state unknown; a failed
              // append does not, so its next page stays advertised until the
              // failure is retried — by the paging row's alert, in place.
              pagingFailed: message.append,
              hasMore: message.append ? _model.hasMore : false,
            ),
          );
        }
      case _LibraryMutationCompleted():
        if (message.cancellation case final cancellation?) {
          _releaseCancellation(cancellation);
        }
        if (_closing) break;
        if (message.notice case final notice?) _reportNotice(notice);
        if (message.error case final error?) {
          _emit(
            _model.copyWith(
              error: error,
              failure: message.failure,
              removingBookId: null,
            ),
          );
          if (message.refresh) _load();
        } else {
          _emit(
            _model.copyWith(
              error: null,
              failure: LibraryFailure.none,
              managedFileDeletionPending:
                  _model.managedFileDeletionPending ||
                  message.managedFileDeletionPending,
              // A completed mutation ends any pending removal state; only a
              // removal sets it, and a removal cannot run beside another
              // mutation because both take the busy flag.
              removingBookId: null,
            ),
          );
          if (message.failure == LibraryFailure.import ||
              message.failure == LibraryFailure.removal) {
            _load();
          }
        }
      case _LibraryImportEnded():
        if (_closing) break;
        _emit(_model.copyWith(importing: false));
      case LibraryManagedDeletionNoticeDismissed():
        _emit(_model.copyWith(managedFileDeletionPending: false));
      case _LibraryReaderClosed():
        if (_closing) break;
        if (message.error case final error?) {
          _emit(_model.copyWith(error: error));
        }
        _load();
      case _LibraryEffectFinished():
        _activeEffects -= 1;
        _activeBusyEffects -= 1;
        if (!_closing) {
          _emit(_model.copyWith(busy: _activeBusyEffects > 0));
        }
        _disposeBridgeIfIdle();
      case _LibraryCoverLoaded():
        _releaseCancellation(message.cancellation);
        if (!_closing) {
          _coverFailures.remove(message.bookId);
          final cover = message.cover ?? Uint8List(0);
          final previous = _coverCache.remove(message.bookId);
          _coverCacheBytes -= previous?.length ?? 0;
          _coverCache[message.bookId] = cover;
          _coverCacheBytes += cover.length;
          while ((_coverCacheBytes > _coverCacheByteLimit ||
                  _coverCache.length > _coverCacheEntryLimit) &&
              _coverCache.isNotEmpty) {
            final oldest = _coverCache.keys.first;
            final removed = _coverCache.remove(oldest)!;
            _coverCacheBytes -= removed.length;
            _evictCover(removed);
          }
          _emit(_model.copyWith(covers: Map.unmodifiable(_coverCache)));
        }
      case _LibraryCoverFailed():
        _releaseCancellation(message.cancellation);
        _coverFailures.add(message.bookId);
      case _LibraryCoverEffectFinished():
        _coverRequests.remove(message.bookId);
        _activeEffects -= 1;
        if (!_closing) _emit(_model);
        _disposeBridgeIfIdle();
      case _LibraryCleanupStatusChanged():
        if (_closing) break;
        if (message.revision == _cleanupRevision) {
          _emit(_model.copyWith(providerCleanupPending: message.pending));
        }
    }
    _importOpenedDocuments();
  }

  /// Intake is controller-owned work, not widget state. A reader or a load
  /// holds the busy effect; retain arrivals until that effect has drained.
  void _importOpenedDocuments() {
    if (_closing || !_model.loaded || _model.busy || _openedPaths.isEmpty) {
      return;
    }
    final paths = List<String>.unmodifiable(
      _openedPaths.take(maxSelectedImportPaths),
    );
    _openedPaths.removeAll(paths);
    _import(
      LibraryImportSelection(
        paths: paths,
        managed: true,
        cleanup: () => _openedDocuments!.discard(paths),
      ),
    );
  }

  void _beginEffect({bool importing = false}) {
    _activeEffects += 1;
    _activeBusyEffects += 1;
    // Another effect may start while an import is still in flight (a search
    // change loads during one), so starting an effect never clears the import
    // state it did not start.
    _emit(
      _model.copyWith(busy: true, importing: _model.importing || importing),
    );
  }

  void _retryCleanup() {
    final revision = ++_cleanupRevision;
    unawaited(() async {
      bool pending;
      try {
        pending = await _retryProviderCleanup();
      } catch (_) {
        pending = true;
      }
      dispatch(_LibraryCleanupStatusChanged(pending, revision));
    }());
  }

  void _loadCover(int bookId) {
    if (!_canLoadCover(bookId)) return;
    late final BigInt cancellation;
    try {
      cancellation = _bridge.createCancellation();
    } catch (_) {
      return;
    }
    _cancellations.add(cancellation);
    _coverRequests[bookId] = cancellation;
    _activeEffects += 1;
    unawaited(() async {
      try {
        final cover = await _records.libraryCover(
          bookId: bookId,
          cancellationId: cancellation,
        );
        dispatch(_LibraryCoverLoaded(bookId, cover, cancellation));
      } catch (_) {
        dispatch(_LibraryCoverFailed(bookId, cancellation));
      } finally {
        dispatch(_LibraryCoverEffectFinished(bookId));
      }
    }());
  }

  bool _canLoadCover(int bookId) =>
      !_closing &&
      !_coverRequests.containsKey(bookId) &&
      !_coverCache.containsKey(bookId) &&
      !_coverFailures.contains(bookId) &&
      _coverRequests.length < _coverLoadLimit;

  FlutterLibraryBook _withoutCover(FlutterLibraryBook book) =>
      FlutterLibraryBook(
        bookId: book.bookId,
        title: book.title,
        author: book.author,
        format: book.format,
        pathKey: book.pathKey,
        managed: book.managed,
        cover: null,
        progress: book.progress,
        dateAdded: book.dateAdded,
        lastRead: book.lastRead,
        unavailable: book.unavailable,
        located: book.located,
        keptOnDevice: book.keptOnDevice,
      );

  void _load({bool append = false, bool refreshSources = false}) {
    if (_closing) return;
    for (final cancellation in _loadCancellations) {
      _bridge.cancel(id: cancellation);
    }
    final revision = ++_loadRevision;
    final query = _model.query;
    final format = _model.format;
    final sort = _model.sort;
    final sortChosen = _sortChosen;
    final offset = append ? _model.books.length : 0;
    late final BigInt cancellation;
    try {
      cancellation = _bridge.createCancellation();
    } catch (error) {
      // A load that cannot even start still ends the skeleton: this is the
      // newest load, so nothing else owns the flags.
      _emit(
        _model.copyWith(
          loading: false,
          loadingMore: false,
          discoveryProgress: null,
          loadError: safeError(error),
          // A first page that cannot start leaves the collection's length
          // unknown; an append keeps the next page it was advertising.
          pagingFailed: append,
          hasMore: append ? _model.hasMore : false,
        ),
      );
      return;
    }
    _cancellations.add(cancellation);
    _foregroundCancellations.add(cancellation);
    _loadCancellations.add(cancellation);
    _beginEffect();
    // The load effect owns the collection's loading state: the skeleton shows
    // for a first-page load and the grid stays for an appended page, exactly as
    // the reference's `library_loading && library_offset == 0` branch does.
    _emit(
      _model.copyWith(
        loading: true,
        loadingMore: append,
        discoveryProgress: null,
      ),
    );
    _discoveryCancellation?.cancel();
    final discovery = _discoveryCancellation = CancellationToken();
    unawaited(() async {
      try {
        final settings = _model.settings == null
            ? await _records.loadReaderSettings(cancellationId: cancellation)
            : null;
        if (settings != null) {
          dispatch(_LibrarySettingsLoaded(revision, settings));
        }
        // The first page lists the shelf in its saved order, unless an order
        // was chosen before the settings arrived.
        final pageSort = settings != null && !sortChosen
            ? settings.librarySort
            : sort;
        final host = _bridge;
        var sourceFiles = <LibrarySourceFile>[];
        String? discoveryError;
        String? sourceWarning;
        try {
          sourceFiles = host is LibraryFoldersHost
              ? (await (host as LibraryFoldersHost).folders.discover(
                      refresh: refreshSources,
                      cancellation: discovery,
                      onProgress: (progress) => dispatch(
                        _LibraryDiscoveryProgressed(revision, progress),
                      ),
                    ))
                    .where(
                      (file) =>
                          (format == null ||
                              file.entry.name.toLowerCase().endsWith(
                                '.${format.name}',
                              )) &&
                          (query.isEmpty ||
                              file.title.toLowerCase().contains(
                                query.toLowerCase(),
                              )),
                    )
                    .toList()
              : <LibrarySourceFile>[];
          if (host is LibraryFoldersHost) {
            final warnings = (host as LibraryFoldersHost).folders.scanWarnings;
            if (warnings.isNotEmpty) {
              sourceWarning = warnings
                  .map(_localizations().locationScanWarning)
                  .join('\n');
            }
          }
        } catch (error) {
          discovery.throwIfCancelled();
          discoveryError = safeError(error);
        }
        sourceFiles.sort(
          (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
        );
        final page = await _records.libraryPage(
          query: query,
          format: format,
          sort: pageSort,
          limit: libraryPageSize,
          offset: offset,
          cancellationId: cancellation,
        );
        dispatch(
          _LibraryLoaded(
            revision,
            page,
            settings,
            append,
            cancellation,
            pageSort,
            List.unmodifiable(sourceFiles),
            discoveryError: discoveryError,
            sourceWarning: sourceWarning,
          ),
        );
      } catch (error) {
        dispatch(
          _LibraryFailed(
            revision,
            discovery.isCancelled
                ? _localizations().libraryCheckCancelled
                : safeError(error),
            LibraryFailure.load,
            cancellation,
            append: append,
          ),
        );
      } finally {
        dispatch(const _LibraryEffectFinished());
      }
    }());
  }

  void _import([LibraryImportSelection? chosen]) {
    if (_closing || _model.busy) {
      unawaited(chosen?.cleanup?.call());
      return;
    }
    final l10n = _localizations();
    _beginEffect(importing: true);
    _pendingImportAdapter = true;
    final adapterRevision = ++_adapterRevision;
    unawaited(() async {
      BigInt? cancellation;
      LibraryImportSelection? selection;
      try {
        selection = chosen ?? await _pickImport();
        _pendingImportAdapter = false;
        if (!_closing) _emit(_model);
        if (selection == null || selection.paths.isEmpty) return;
        if (!_ownsAdapter(adapterRevision)) return;
        cancellation = _bridge.createCancellation();
        _cancellations.add(cancellation);
        _foregroundCancellations.add(cancellation);
        late final List<FlutterImportItem> items;
        var refresh = false;
        String? terminalStatus;
        NoticeRequest? successNotice;
        if (selection.runner case final runner?) {
          final report = await runner(_records, cancellation);
          items = report.items;
          refresh = report.imported > BigInt.zero;
          terminalStatus = _importReportStatus(report, l10n);
          successNotice = _importSuccessNotice(report);
        } else if (selection.directory) {
          final report = await _records.importDirectory(
            pathKey: selection.paths.single,
            managed: selection.managed,
            cancellationId: cancellation,
          );
          items = report.items;
          refresh = report.imported > BigInt.zero;
          terminalStatus = _importReportStatus(report, l10n);
          successNotice = _importSuccessNotice(report);
        } else {
          final report = await _records.importPaths(
            pathKeys: selection.paths,
            managed: selection.managed,
            cancellationId: cancellation,
          );
          items = report.items;
          refresh = report.imported > BigInt.zero;
          terminalStatus = _importReportStatus(report, l10n);
          successNotice = _importSuccessNotice(report);
        }
        final failure = items.where((item) => item.error != null).firstOrNull;
        dispatch(
          _LibraryMutationCompleted(
            failure: LibraryFailure.import,
            error:
                terminalStatus ??
                (failure == null
                    ? null
                    : _safeImportError(failure.error!, l10n)),
            cancellation: cancellation,
            refresh: refresh,
            notice: successNotice,
          ),
        );
        cancellation = null;
      } catch (error) {
        dispatch(
          _LibraryMutationCompleted(
            failure: LibraryFailure.import,
            error: error is SafeUserError
                ? error.message
                : l10n.importOperationFailed,
            cancellation: cancellation,
          ),
        );
        cancellation = null;
      } finally {
        _pendingImportAdapter = false;
        dispatch(const _LibraryImportEnded());
        try {
          await selection?.cleanup?.call();
        } catch (_) {
          // The import result is authoritative; cleanup is best effort here and
          // the Android host also removes retained acquisitions on teardown.
        }
        if (cancellation != null) {
          _releaseCancellation(cancellation);
        }
        dispatch(const _LibraryEffectFinished());
      }
    }());
  }

  void _requestRemoval(FlutterLibraryBook book) {
    if (_closing || _model.busy) return;
    _beginEffect();
    final adapterRevision = ++_adapterRevision;
    unawaited(() async {
      bool confirmed;
      try {
        confirmed = await _confirmRemoval(book);
      } catch (error) {
        dispatch(
          _LibraryMutationCompleted(
            failure: LibraryFailure.removal,
            error: safeError(error),
          ),
        );
        dispatch(const _LibraryEffectFinished());
        return;
      }
      if (!confirmed) {
        // A declined confirmation is neutral: no error and no pending card.
        dispatch(const _LibraryEffectFinished());
        return;
      }
      if (!_ownsAdapter(adapterRevision)) {
        dispatch(const _LibraryEffectFinished());
        return;
      }
      // The confirmation is a completion like any other: it reports back as a
      // typed message and the handler owns the transition and the removal
      // effect, so no continuation writes model state.
      dispatch(_LibraryRemovalConfirmed(book));
    }());
  }

  void _remove(FlutterLibraryBook book) {
    unawaited(() async {
      try {
        final outcome = await _records.removeLibraryBook(bookId: book.bookId);
        dispatch(
          _LibraryMutationCompleted(
            failure: LibraryFailure.removal,
            managedFileDeletionPending: outcome.managedFileDeletionPending,
          ),
        );
      } catch (error) {
        dispatch(
          _LibraryMutationCompleted(
            failure: LibraryFailure.removal,
            error: safeError(error),
          ),
        );
      } finally {
        dispatch(const _LibraryEffectFinished());
      }
    }());
  }

  void _keep(FlutterLibraryBook book) {
    final host = _bridge;
    if (_closing ||
        _model.busy ||
        !book.located ||
        host is! LibraryFoldersHost) {
      return;
    }
    _beginEffect();
    final revision = ++_adapterRevision;
    final cancellation = _keepCancellation = CancellationToken();
    unawaited(() async {
      try {
        await (host as LibraryFoldersHost).folders.setKept(
          book.bookId,
          !book.keptOnDevice,
          cancellation: cancellation,
        );
        if (_ownsAdapter(revision)) dispatch(const LibraryRefreshed());
      } catch (error) {
        if (_ownsAdapter(revision)) {
          dispatch(
            _LibraryMutationCompleted(
              failure: LibraryFailure.load,
              error: safeError(error),
            ),
          );
        }
      } finally {
        if (identical(_keepCancellation, cancellation)) {
          _keepCancellation = null;
        }
        dispatch(const _LibraryEffectFinished());
      }
    }());
  }

  void _open(FlutterLibraryBook book) {
    if (_closing || _model.busy) return;
    _beginEffect();
    unawaited(() async {
      try {
        await _openBook(book);
        await _drainReaderSaves(book.bookId);
        dispatch(const _LibraryReaderClosed(null));
      } catch (error) {
        dispatch(_LibraryReaderClosed(safeError(error)));
      } finally {
        dispatch(const _LibraryEffectFinished());
      }
    }());
  }

  void _openSource(LibrarySourceFile file) {
    final host = _bridge;
    if (_closing || _model.busy || host is! LibraryFoldersHost) return;
    final revision = ++_adapterRevision;
    final cancellation = _sourceCancellation = CancellationToken();
    _beginEffect();
    unawaited(() async {
      FlutterLibraryBook? book;
      try {
        book = await (host as LibraryFoldersHost).admitSourceFile(
          file,
          cancellation: cancellation,
        );
        cancellation.throwIfCancelled();
      } catch (error) {
        book = null;
        if (_ownsAdapter(revision)) {
          dispatch(_LibraryReaderClosed(safeError(error)));
        }
      } finally {
        if (identical(_sourceCancellation, cancellation)) {
          _sourceCancellation = null;
        }
        dispatch(const _LibraryEffectFinished());
      }
      if (book != null) dispatch(_LibrarySourceFileAdmitted(book, revision));
    }());
  }

  void _connections() {
    final manage = _manageConnections;
    if (_closing || _model.busy || manage == null) return;
    _beginEffect();
    final adapterRevision = ++_adapterRevision;
    unawaited(() async {
      try {
        await manage();
        if (_ownsAdapter(adapterRevision)) {
          dispatch(const LibraryRefreshed());
        }
      } catch (error) {
        dispatch(
          _LibraryMutationCompleted(
            failure: LibraryFailure.settings,
            error: safeError(error),
          ),
        );
      } finally {
        dispatch(const _LibraryEffectFinished());
      }
    }());
  }

  /// Saves the model's settings in the background, after the write already
  /// running if there is one. A change takes effect before it is saved; a
  /// failed write reports as a settings failure unless a newer one follows,
  /// and [notify] reports the settings page's success.
  void _saveSettings({bool notify = false}) {
    _settingsNotify = _settingsNotify || notify;
    if (_settingsWriting) {
      _settingsQueued = true;
      return;
    }
    final settings = _model.settings!;
    final reports = _settingsNotify;
    _settingsWriting = true;
    _settingsQueued = false;
    _settingsNotify = false;
    _activeEffects += 1;
    unawaited(() async {
      String? error;
      try {
        await _records.saveReaderSettings(value: settings);
      } catch (caught) {
        error = safeError(caught);
      }
      dispatch(_LibrarySettingsSaved(error, notify: reports));
    }());
  }

  bool _ownsAdapter(int revision) => !_closing && revision == _adapterRevision;

  String _safeImportError(String error, AppLocalizations l10n) {
    if (error.startsWith('provider_error:')) {
      final name = error.substring('provider_error:'.length);
      final providerError = DocumentImportError.values
          .where((value) => value.name == name)
          .firstOrNull;
      if (providerError != null) {
        return documentImportErrorText(providerError, l10n);
      }
    }
    final lower = error.toLowerCase();
    if (lower.contains('unsupported')) {
      return l10n.importUnsupported;
    }
    if (lower.contains('not found') || lower.contains('no such file')) {
      return l10n.importNotFound;
    }
    if (lower.contains('limit') || lower.contains('too large')) {
      return l10n.importTooLarge;
    }
    return l10n.importFailed;
  }

  /// The brief success notice for an import that landed books without failures
  /// or warnings, or null.
  ///
  /// A clean, completed import is decision 13's brief success feedback. A
  /// cancellation reports nothing: cancellation is neutral, and the books a
  /// cancelled import did land are reloaded into the grid by the completion.
  /// A cancelled import that also failed or warned keeps its inline failure
  /// summary.
  NoticeRequest? _importSuccessNotice(FlutterImportReport report) {
    if (report.cancelled) return null;
    if (report.imported <= BigInt.zero) return null;
    if (report.failed > BigInt.zero) return null;
    if (report.items.any(
      (item) => item.error != null || item.warning != null,
    )) {
      return null;
    }
    return NoticeRequest(
      text: LibraryImportSucceededNotice(count: report.imported.toInt()),
      kind: NoticeKind.success,
    );
  }

  String? _importReportStatus(
    FlutterImportReport report,
    AppLocalizations l10n,
  ) {
    final failure = report.items
        .where((item) => item.error != null)
        .firstOrNull;
    final warnings = report.items
        .map((item) => item.warning)
        .whereType<String>()
        .toList(growable: false);
    if (report.failed == BigInt.zero && failure == null && warnings.isEmpty) {
      // A clean import needs no failure surface (its success feedback belongs
      // to the notice policy), and a cancellation on its own is neutral rather
      // than an error (plan decision 13): the books a cancelled import did land
      // are in the grid after the reload. A cancelled import that also failed
      // or warned keeps the summary below.
      return null;
    }
    final parts = <String>[];
    if (report.imported > BigInt.zero) {
      parts.add(l10n.importStatusImported(report.imported.toInt()));
    }
    if (report.failed > BigInt.zero) {
      parts.add(l10n.importStatusFailed(report.failed.toInt()));
      if (failure != null) parts.add(_safeImportError(failure.error!, l10n));
    }
    if (warnings.isNotEmpty) {
      parts.add(l10n.importDetailsUnavailable);
    }
    return parts.isEmpty ? null : parts.join(' ');
  }

  void _releaseCancellation(BigInt cancellation) {
    if (_cancellations.remove(cancellation)) {
      _foregroundCancellations.remove(cancellation);
      _loadCancellations.remove(cancellation);
      _bridge.releaseCancellation(id: cancellation);
    }
  }

  void _emit(LibraryModel model) {
    _model = model;
    for (final listener in List<VoidCallback>.of(_listeners)) {
      listener();
    }
  }

  @override
  void addListener(VoidCallback listener) => _listeners.add(listener);

  @override
  void removeListener(VoidCallback listener) => _listeners.remove(listener);

  void dispose() {
    if (_closing) return;
    _closing = true;
    _keepCancellation?.cancel();
    _sourceCancellation?.cancel();
    _discoveryCancellation?.cancel();
    _openedDocuments?.cancel();
    final queued = List<String>.of(_openedPaths);
    _openedPaths.clear();
    unawaited(_openedDocuments?.discard(queued));
    for (final cover in _coverCache.values) {
      _evictCover(cover);
    }
    _coverCache.clear();
    _coverCacheBytes = 0;
    _model = _model.copyWith(covers: const {});
    _adapterRevision += 1;
    _cancelImportAdapter();
    _searchTimer?.cancel();
    for (final cancellation in _cancellations) {
      _bridge.cancel(id: cancellation);
    }
    _listeners.clear();
    _disposeBridgeIfIdle();
  }

  void _disposeBridgeIfIdle() {
    if (_closing && _activeEffects == 0 && !_bridgeDisposed) {
      _bridgeDisposed = true;
      _bridge.dispose();
    }
  }
}
