import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show Listenable, VoidCallback;
import 'package:shosai_flutter/android_document_import_adapter.dart';
import 'package:shosai_flutter/library/errors.dart';
import 'package:shosai_flutter/src/rust/api.dart';

part 'message.dart';
part 'model.dart';

class LibraryController implements Listenable {
  LibraryController({
    required FlutterBridge bridge,
    required LibraryRemovalConfirmer confirmRemoval,
    required LibraryImportPicker pickImport,
    required LibraryBookOpener openBook,
    required LibraryReaderSaveDrainer drainReaderSaves,
    required LibrarySettingsEditor editSettings,
    LibraryProviderCleanupRetrier retryProviderCleanup =
        _ignoreProviderCleanupRetry,
    LibraryImportAdapterCanceller cancelImportAdapter =
        _ignoreImportAdapterCancellation,
    LibraryCoverEvicter evictCover = _ignoreCoverEviction,
  }) : _bridge = bridge,
       _confirmRemoval = confirmRemoval,
       _pickImport = pickImport,
       _openBook = openBook,
       _drainReaderSaves = drainReaderSaves,
       _editSettings = editSettings,
       _retryProviderCleanup = retryProviderCleanup,
       _cancelImportAdapter = cancelImportAdapter,
       _evictCover = evictCover;

  final FlutterBridge _bridge;
  final LibraryRemovalConfirmer _confirmRemoval;
  final LibraryImportPicker _pickImport;
  final LibraryBookOpener _openBook;
  final LibraryReaderSaveDrainer _drainReaderSaves;
  final LibrarySettingsEditor _editSettings;
  final LibraryProviderCleanupRetrier _retryProviderCleanup;
  final LibraryImportAdapterCanceller _cancelImportAdapter;
  final LibraryCoverEvicter _evictCover;
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
  int? _stalledAppendOffset;
  bool _closing = false;
  bool _bridgeDisposed = false;
  bool _pendingImportAdapter = false;

  LibraryModel get model => _model;
  bool get canCancel =>
      _pendingImportAdapter || _foregroundCancellations.isNotEmpty;

  bool requestCover(int bookId) {
    if (!_canLoadCover(bookId)) return false;
    dispatch(LibraryCoverRequested(bookId));
    return true;
  }

  void dispatch(LibraryMessage message) {
    if (_closing &&
        message is! _LibraryLoaded &&
        message is! _LibraryFailed &&
        message is! _LibraryMutationCompleted &&
        message is! _LibraryReaderClosed &&
        message is! _LibraryEffectFinished &&
        message is! _LibraryCoverLoaded &&
        message is! _LibraryCoverFailed &&
        message is! _LibraryCoverEffectFinished &&
        message is! _LibraryCleanupStatusChanged) {
      return;
    }
    switch (message) {
      case LibraryStarted():
        _retryCleanup();
        _load();
      case LibraryRefreshed():
        _coverFailures.clear();
        _emit(_model.copyWith(coverRevision: _model.coverRevision + 1));
        _load();
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
            _displayedFormat == _model.format) {
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
            _displayedFormat == _model.format) {
          _load(append: true);
        }
      case LibraryRetryRequested():
        switch (_model.failure) {
          case LibraryFailure.load || LibraryFailure.none:
            _load();
          case LibraryFailure.import:
            _import();
          case LibraryFailure.removal:
            _load();
          case LibraryFailure.settings:
            _settings();
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
      case LibraryImportRequested():
        _import();
      case LibraryCoverRequested():
        _loadCover(message.bookId);
      case LibraryOperationCancelled():
        _adapterRevision += 1;
        _pendingImportAdapter = false;
        _cancelImportAdapter();
        for (final cancellation in _foregroundCancellations) {
          _bridge.cancel(id: cancellation);
        }
        _emit(_model);
      case LibraryBookOpened():
        _open(message.book);
      case LibraryBookRemovalRequested():
        _requestRemoval(message.book);
      case _LibraryRemovalConfirmed():
        if (_closing) break;
        // The reference marks the card as removing once the removal is
        // confirmed and running; the mutation completion clears it again.
        _emit(_model.copyWith(removingBookId: message.book.bookId));
        _remove(message.book);
      case LibrarySettingsRequested():
        _settings();
      case _LibraryDebounceElapsed():
        if (message.revision == _queryRevision) _load();
      case _LibraryLoaded():
        _releaseCancellation(message.cancellation);
        // A closed controller drains its effects but owns no model state: a
        // completion that arrives after disposal cannot write it.
        if (!_closing && message.revision == _loadRevision) {
          if (!message.append) {
            _displayedQuery = _model.query;
            _displayedFormat = _model.format;
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
              settings: message.settings ?? _model.settings,
              loaded: true,
              loading: false,
              loadingMore: false,
              loadError: null,
              pagingFailed: false,
              hasMore: message.page.hasMore,
            ),
          );
        }
      case _LibraryFailed():
        _releaseCancellation(message.cancellation);
        if (!_closing && message.revision == _loadRevision) {
          _emit(
            _model.copyWith(
              loading: false,
              loadingMore: false,
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
              settings: message.settings ?? _model.settings,
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
        final cover = await _bridge.libraryCover(
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
      );

  void _load({bool append = false}) {
    if (_closing) return;
    for (final cancellation in _loadCancellations) {
      _bridge.cancel(id: cancellation);
    }
    final revision = ++_loadRevision;
    final query = _model.query;
    final format = _model.format;
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
    _emit(_model.copyWith(loading: true, loadingMore: append));
    unawaited(() async {
      try {
        final page = await _bridge.libraryPage(
          query: query,
          format: format,
          limit: libraryPageSize,
          offset: offset,
          cancellationId: cancellation,
        );
        final settings = _model.settings == null
            ? await _bridge.loadReaderSettings(cancellationId: cancellation)
            : null;
        dispatch(
          _LibraryLoaded(revision, page, settings, append, cancellation),
        );
      } catch (error) {
        dispatch(
          _LibraryFailed(
            revision,
            safeError(error),
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

  void _import() {
    if (_closing || _model.busy) return;
    _beginEffect(importing: true);
    _pendingImportAdapter = true;
    final adapterRevision = ++_adapterRevision;
    unawaited(() async {
      BigInt? cancellation;
      LibraryImportSelection? selection;
      try {
        selection = await _pickImport();
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
        if (selection.runner case final runner?) {
          final report = await runner(_bridge, cancellation);
          items = report.items;
          refresh = report.imported > BigInt.zero;
          terminalStatus = _importReportStatus(report);
        } else if (selection.directory) {
          final report = await _bridge.importDirectory(
            pathKey: selection.paths.single,
            managed: selection.managed,
            cancellationId: cancellation,
          );
          items = report.items;
          refresh = report.imported > BigInt.zero;
          terminalStatus = _importReportStatus(report);
        } else {
          final report = await _bridge.importPaths(
            pathKeys: selection.paths,
            managed: selection.managed,
            cancellationId: cancellation,
          );
          items = report.items;
          refresh = report.imported > BigInt.zero;
          terminalStatus = _importReportStatus(report);
        }
        final failure = items.where((item) => item.error != null).firstOrNull;
        dispatch(
          _LibraryMutationCompleted(
            failure: LibraryFailure.import,
            error:
                terminalStatus ??
                (failure == null ? null : _safeImportError(failure.error!)),
            cancellation: cancellation,
            refresh: refresh,
          ),
        );
        cancellation = null;
      } catch (error) {
        dispatch(
          _LibraryMutationCompleted(
            failure: LibraryFailure.import,
            error: safeError(error),
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
        final outcome = await _bridge.removeLibraryBook(bookId: book.bookId);
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

  void _settings() {
    final initial = _model.settings;
    if (_closing || _model.busy || initial == null) return;
    _beginEffect();
    final adapterRevision = ++_adapterRevision;
    unawaited(() async {
      try {
        final settings = await _editSettings(initial);
        if (settings == null) return;
        if (!_ownsAdapter(adapterRevision)) return;
        await _bridge.saveReaderSettings(value: settings);
        dispatch(
          _LibraryMutationCompleted(
            failure: LibraryFailure.settings,
            settings: settings,
          ),
        );
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

  bool _ownsAdapter(int revision) => !_closing && revision == _adapterRevision;

  String _safeImportError(String error) {
    if (error.startsWith('provider_error:')) {
      final name = error.substring('provider_error:'.length);
      final providerError = DocumentImportError.values
          .where((value) => value.name == name)
          .firstOrNull;
      if (providerError != null) return documentImportErrorText(providerError);
    }
    final lower = error.toLowerCase();
    if (lower.contains('unsupported')) {
      return 'This file type is not supported.';
    }
    if (lower.contains('not found') || lower.contains('no such file')) {
      return 'The selected file could not be found.';
    }
    if (lower.contains('limit') || lower.contains('too large')) {
      return 'The selected book exceeds the supported size limits.';
    }
    return 'The selected book could not be imported.';
  }

  String? _importReportStatus(FlutterImportReport report) {
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
      parts.add('Imported ${_bookCount(report.imported)}.');
    }
    if (report.failed > BigInt.zero) {
      parts.add('${report.failed} failed.');
      if (failure != null) parts.add(_safeImportError(failure.error!));
    }
    if (warnings.isNotEmpty) {
      parts.add('Some imported book details could not be loaded.');
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

String _bookCount(BigInt count) =>
    '$count book${count == BigInt.one ? '' : 's'}';
