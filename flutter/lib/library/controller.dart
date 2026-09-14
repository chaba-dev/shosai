import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show Listenable, VoidCallback;
import 'package:shosai_flutter/android_document_import_adapter.dart';
import 'package:shosai_flutter/library/errors.dart';
import 'package:shosai_flutter/shared/notice.dart';
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
  int _noticeId = 0;
  String? _displayedQuery;
  FlutterBookFormat? _displayedFormat;
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
        if (_model.hasMore &&
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
      case LibrarySettingsRequested():
        _settings();
      case _LibraryDebounceElapsed():
        if (message.revision == _queryRevision) _load();
      case _LibraryLoaded():
        _releaseCancellation(message.cancellation);
        if (message.revision == _loadRevision) {
          if (!message.append) {
            _displayedQuery = _model.query;
            _displayedFormat = _model.format;
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
              loadError: null,
              hasMore: message.page.hasMore,
            ),
          );
        }
      case _LibraryFailed():
        _releaseCancellation(message.cancellation);
        if (message.revision == _loadRevision) {
          _emit(_model.copyWith(loadError: message.error, hasMore: false));
        }
      case _LibraryMutationCompleted():
        if (message.cancellation case final cancellation?) {
          _releaseCancellation(cancellation);
        }
        if (_closing) break;
        if (message.error case final error?) {
          _emit(_model.copyWith(error: error, failure: message.failure));
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
              notice: message.notice ?? _same,
            ),
          );
          if (message.failure == LibraryFailure.import ||
              message.failure == LibraryFailure.removal) {
            _load();
          }
        }
      case LibraryNoticeConsumed():
        if (_model.notice?.id == message.id) {
          _emit(_model.copyWith(notice: null));
        }
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

  void _beginEffect() {
    _activeEffects += 1;
    _activeBusyEffects += 1;
    _emit(_model.copyWith(busy: true));
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
      _emit(_model.copyWith(loadError: safeError(error), hasMore: false));
      return;
    }
    _cancellations.add(cancellation);
    _foregroundCancellations.add(cancellation);
    _loadCancellations.add(cancellation);
    _beginEffect();
    unawaited(() async {
      try {
        final page = await _bridge.libraryPage(
          query: query,
          format: format,
          limit: 50,
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
          ),
        );
      } finally {
        dispatch(const _LibraryEffectFinished());
      }
    }());
  }

  void _import() {
    if (_closing || _model.busy) return;
    _beginEffect();
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
        late final FlutterImportReport report;
        if (selection.runner case final runner?) {
          report = await runner(_bridge, cancellation);
        } else if (selection.directory) {
          report = await _bridge.importDirectory(
            pathKey: selection.paths.single,
            managed: selection.managed,
            cancellationId: cancellation,
          );
        } else {
          report = await _bridge.importPaths(
            pathKeys: selection.paths,
            managed: selection.managed,
            cancellationId: cancellation,
          );
        }
        final terminalStatus = _importReportStatus(report);
        dispatch(
          _LibraryMutationCompleted(
            failure: LibraryFailure.import,
            notice: Notice(
              id: ++_noticeId,
              message:
                  terminalStatus ?? 'Imported ${_bookCount(report.imported)}.',
              kind: terminalStatus == null
                  ? NoticeKind.success
                  : NoticeKind.destructive,
            ),
            cancellation: cancellation,
            refresh: report.imported > BigInt.zero,
          ),
        );
        cancellation = null;
      } catch (error) {
        dispatch(
          _LibraryMutationCompleted(
            failure: LibraryFailure.import,
            notice: Notice(
              id: ++_noticeId,
              message: safeError(error),
              kind: NoticeKind.destructive,
            ),
            cancellation: cancellation,
          ),
        );
        cancellation = null;
      } finally {
        _pendingImportAdapter = false;
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
      try {
        if (!await _confirmRemoval(book)) return;
        if (!_ownsAdapter(adapterRevision)) return;
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
            notice: Notice(
              id: ++_noticeId,
              message: 'Reader settings saved.',
              kind: NoticeKind.success,
            ),
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
    if (!report.cancelled &&
        report.failed == BigInt.zero &&
        failure == null &&
        warnings.isEmpty) {
      return null;
    }
    final parts = <String>[];
    if (report.cancelled) parts.add('Import cancelled.');
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
    return parts.join(' ');
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
