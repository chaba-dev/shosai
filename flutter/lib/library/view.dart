import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shosai_flutter/android_document_import_adapter.dart';
import 'package:shosai_flutter/app_theme.dart';
import 'package:shosai_flutter/core/records.dart';
import 'package:shosai_flutter/l10n/app_localizations.dart';
import 'package:shosai_flutter/library/controller.dart';
import 'package:shosai_flutter/library/errors.dart';
import 'package:shosai_flutter/notices/library_notice_text.dart';
import 'package:shosai_flutter/notices/notices.dart';
import 'package:shosai_flutter/reader/controller.dart';
import 'package:shosai_flutter/shared/shad_widgets.dart';
import 'package:shosai_flutter/core/bridge.dart';
import 'package:shosai_flutter/shell/view.dart';
import 'package:shosai_flutter/theme_tokens.dart';

export 'package:shosai_flutter/library/controller.dart';

part 'view_collection.dart';
part 'view_dialogs.dart';
part 'view_navigation.dart';

typedef ProductReaderBuilder =
    Widget Function(
      FlutterBridge bridge,
      FlutterLibraryBook book,
      FlutterReaderSettings? settings,
      String initialPath,
      int? initialBookId,
      void Function(String path, int? bookId) locatorChanged,
      ReaderNoticeReporter noticeReporter,
      Widget openBooksAction,
      void Function(bool twoPages) pagesChanged,
    );

class ProductShell extends StatefulWidget {
  const ProductShell({
    super.key,
    required this.bridgeFactory,
    required this.readerBuilder,
    this.androidImport,
    this.noticeReporter,
  });

  final FlutterBridge Function() bridgeFactory;
  final ProductReaderBuilder readerBuilder;
  final AndroidDocumentImportAdapter? androidImport;

  /// The application notice center's reporter, injected by the composition
  /// root. A shell built without one presents no library feedback.
  final NoticeReporter? noticeReporter;

  @override
  State<ProductShell> createState() => _ProductShellState();
}

class _ProductShellState extends State<ProductShell> with RestorationMixin {
  /// The open books and whether the reader was showing, kept across a
  /// platform restoration.
  final RestorableStringN _session = RestorableStringN(null);
  final Set<Route<Object?>> _dialogRoutes = {};
  NavigatorState? _navigator;
  _RestoredSession? _pendingRestoredSession;
  bool _restoredOpenScheduled = false;

  /// Add books chosen from the rail: the library opens the picker once the
  /// reader has gone and the library is idle again.
  bool _pendingImport = false;

  late final ShellController _shell = ShellController(
    presentReader: _presentReader,
    dismissReader: _dismissReader,
  )..addListener(_shellChanged);
  ModalRoute<void>? _readerRoute;

  /// The reader for the current open book, built once per book so a locator
  /// report does not rebuild it.
  (int, Widget)? _reader;

  /// The open books the reader showed during one presentation; their saves
  /// are drained before the library reloads.
  final Set<int> _shownBooks = {};
  List<FlutterLibraryBook>? _listedBooks;
  late final AndroidDocumentImportAdapter _androidImport =
      widget.androidImport ?? AndroidDocumentImportAdapter();
  final Set<String> _providerOperations = {};
  int _providerRevision = 0;
  late final LibraryController controller = LibraryController(
    bridge: widget.bridgeFactory(),
    confirmRemoval: _confirmRemoval,
    pickImport: _pickImport,
    openBook: _openBook,
    drainReaderSaves: ReaderController.drainBookWrites,
    editSettings: _editSettings,
    retryProviderCleanup: _androidImport.retryCleanup,
    cancelImportAdapter: _cancelImportAdapter,
    noticeReporter: widget.noticeReporter ?? ignoreNotice,
    evictCover: (bytes) {
      final provider = MemoryImage(bytes);
      imageCache.evict(provider, includeLive: true);
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => imageCache.evict(provider, includeLive: true),
      );
    },
  )..addListener(_changed);

  void _changed() {
    setState(() {});
    final books = controller.model.books;
    if (!identical(books, _listedBooks)) {
      _listedBooks = books;
      _shell.dispatch(ShellLibraryBooksChanged(books));
    }
    _scheduleRestoredOpen();
    _schedulePendingImport();
  }

  void _shellChanged() {
    setState(() {});
    _session.value = _encodeSession(_shell.model);
  }

  void _scheduleRestoredOpen() {
    if (_pendingRestoredSession != null &&
        controller.model.loaded &&
        !controller.model.busy &&
        !_restoredOpenScheduled) {
      _restoredOpenScheduled = true;
      scheduleMicrotask(() {
        _restoredOpenScheduled = false;
        if (!mounted || !controller.model.loaded || controller.model.busy) {
          return;
        }
        final restored = _pendingRestoredSession;
        _pendingRestoredSession = null;
        if (restored == null) return;
        _shell.dispatch(ShellRestored(restored.model));
        final open = restored.model.currentBook;
        if (restored.reading && open != null) {
          controller.dispatch(LibraryBookOpened(open.book));
        }
      });
    }
  }

  void _schedulePendingImport() {
    if (!_pendingImport ||
        _shell.model.reading ||
        !controller.model.loaded ||
        controller.model.busy) {
      return;
    }
    _pendingImport = false;
    scheduleMicrotask(() {
      if (mounted) controller.dispatch(const LibraryImportRequested());
    });
  }

  @override
  String get restorationId => 'product-shell';

  @override
  void restoreState(RestorationBucket? oldBucket, bool initialRestore) {
    registerForRestoration(_session, 'open-books');
    if (_session.value case final encoded?) {
      _pendingRestoredSession = _decodeSession(encoded);
      _scheduleRestoredOpen();
    }
  }

  @override
  void initState() {
    super.initState();
    controller.dispatch(const LibraryStarted());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _navigator = Navigator.maybeOf(context);
  }

  @override
  void dispose() {
    final navigator = _navigator;
    if (navigator != null) {
      for (final route in _dialogRoutes.toList()) {
        navigator.removeRoute(route);
      }
    }
    controller.removeListener(_changed);
    controller.dispose();
    _shell.removeListener(_shellChanged);
    _shell.dispose();
    _session.dispose();
    super.dispose();
  }

  /// The library's open adapter: the shell opens or focuses [book] and the
  /// effect lasts until the reader has gone, so the library refreshes after it
  /// as it did when each book was a route of its own.
  Future<void> _openBook(FlutterLibraryBook book) async {
    _shell.dispatch(ShellBookOpened(book));
    await _shell.readerDismissed;
    // The library drains [book]'s saves itself; the other books the reader
    // showed are drained here, so the reload reads their final progress.
    final shown = _shownBooks.where((id) => id != book.bookId).toList();
    _shownBooks.clear();
    Object? failure;
    for (final id in shown) {
      try {
        await ReaderController.drainBookWrites(id);
      } catch (error) {
        failure ??= error;
      }
    }
    if (failure != null) throw failure;
  }

  /// Presents the reader inside the shell: the rail beside it on desktop and
  /// tablet, the reader alone on a phone. Completes when the route has gone.
  Future<void> _presentReader() async {
    if (!mounted) return;
    final route = MaterialPageRoute<void>(
      builder: (_) => ListenableBuilder(
        listenable: Listenable.merge([_shell, controller]),
        builder: (context, _) => _readerFrame(),
      ),
    );
    _readerRoute = route;
    try {
      unawaited(Navigator.of(context).push<void>(route));
      await route.completed;
    } finally {
      if (identical(_readerRoute, route)) _readerRoute = null;
      _reader = null;
    }
  }

  void _dismissReader() {
    final route = _readerRoute;
    final navigator = route?.navigator;
    if (route == null || navigator == null) return;
    if (route.isCurrent) {
      navigator.pop();
    } else {
      navigator.removeRoute(route);
    }
  }

  Widget _readerFrame() {
    final current = _shell.model.currentBook;
    return LayoutBuilder(
      builder: (context, constraints) => ShellFrame(
        layout: ShellLayout.forWidth(constraints.maxWidth),
        // The leaving route keeps its rail while it animates away.
        model: _shell.model.copyWith(reading: true),
        covers: controller.model.covers,
        actions: _shellActions,
        child: current == null
            ? const SizedBox.expand()
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ?_settingsFailure(),
                  Expanded(child: _readerFor(current)),
                ],
              ),
      ),
    );
  }

  /// The failed settings write, reported over the reader: the library's own
  /// alert is under the reader's route, and a Pages change made in the reader
  /// is lost on the next launch unless it is saved. It stays until a retry
  /// saves the settings or it is dismissed.
  Widget? _settingsFailure() {
    final model = controller.model;
    final error = model.error;
    if (model.failure != LibraryFailure.settings || error == null) return null;
    return PersistentNoticeSurface(
      key: const ValueKey('reader-settings-failure'),
      notice: Notice(
        id: 0,
        kind: NoticeKind.failure,
        lifetime: NoticeLifetime.persistent,
        text: const LibrarySettingsSaveFailedNotice(),
        details: RawNoticeText(error),
        actions: const [
          NoticeAction(id: 'retry', label: NoticeRetryText(), primary: true),
        ],
        dedupeKey: NoticePolicy.librarySettingsKey,
      ),
      onDismiss: () =>
          controller.dispatch(const LibrarySettingsFailureDismissed()),
      onAction: (_) => controller.dispatch(const LibrarySettingsSaveRetried()),
    );
  }

  Widget _readerFor(OpenBook open) {
    if (_reader case (final id, final reader) when id == open.id) {
      return reader;
    }
    _shownBooks.add(open.id);
    // A global key moves the reader when the layout changes (the rail beside
    // it on a tablet, alone on a phone) instead of remounting it: the reader
    // owns its bridge, and a remount would dispose it.
    final reader = KeyedSubtree(
      key: GlobalKey(debugLabel: 'reader ${open.id}'),
      child: widget.readerBuilder(
        widget.bridgeFactory(),
        open.book,
        controller.model.settings,
        open.path,
        open.bookId,
        (path, bookId) {
          if (mounted) {
            _shell.dispatch(
              ShellLocatorChanged(open.id, path: path, bookId: bookId),
            );
          }
        },
        // The reader route is pushed outside the shell's notice host, so the
        // composition root's reporter is handed to it (package 4C).
        widget.noticeReporter ?? ignoreNotice,
        // The phone toolbar's open-book count; it opens the tab switcher.
        ListenableBuilder(
          listenable: _shell,
          builder: (context, _) => ShellOpenBooksButton(
            count: _shell.model.openBooks.length,
            onPressed: () => _shell.dispatch(const ShellSwitcherOpened()),
          ),
        ),
        // The Pages setting is saved with the library's settings, so the next
        // book opens with it too.
        (twoPages) {
          if (mounted) controller.dispatch(LibraryPagesChanged(twoPages));
        },
      ),
    );
    _reader = (open.id, reader);
    return reader;
  }

  ShellActions get _shellActions => ShellActions(
    selectPlace: (place) => _shell.dispatch(ShellPlaceSelected(place)),
    openBook: (open) => _shell.model.reading
        ? _shell.dispatch(ShellBookActivated(open.id))
        : controller.dispatch(LibraryBookOpened(open.book)),
    closeBook: (open) => _shell.dispatch(ShellBookClosed(open.id)),
    moveBook: (from, to) => _shell.dispatch(ShellBookMoved(from, to)),
    addBooks: _shell.model.reading
        ? () {
            _pendingImport = true;
            _shell.dispatch(const ShellPlaceSelected(ShellPlace.library));
          }
        : controller.model.busy
        ? null
        : () => controller.dispatch(const LibraryImportRequested()),
    loadCover: controller.requestCover,
    closeSwitcher: () => _shell.dispatch(const ShellSwitcherClosed()),
  );

  Future<LibraryImportSelection?> _pickImport() async {
    if (defaultTargetPlatform == TargetPlatform.android) {
      return _pickAndroidImport();
    }
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      await _showOwnedDialog<void>(
        (context) => ShadDialog(
          title: const Text('Import unavailable'),
          description: const Text(
            'Document-provider import has not yet been validated on iOS.',
          ),
          actions: [
            ShadButton.outline(
              height: shosaiShadButtonHeight(context),
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        ),
      );
      return null;
    }
    final directory = await _showOwnedDialog<bool>(
      (context) => ShadDialog(
        title: const Text('Add books'),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _DialogActionTile(
              icon: LucideIcons.file,
              title: 'Choose files',
              subtitle: 'Select one or more PDF or EPUB files',
              onPressed: () => Navigator.pop(context, false),
            ),
            _DialogActionTile(
              icon: LucideIcons.folder,
              title: 'Choose a folder',
              subtitle: 'Find supported books in all subfolders',
              onPressed: () => Navigator.pop(context, true),
            ),
          ],
        ),
      ),
    );
    if (directory == null || !mounted) return null;
    final paths = directory
        ? [
            await getDirectoryPath(confirmButtonText: 'Review books'),
          ].whereType<String>().toList()
        : (await openFiles(
            acceptedTypeGroups: const [
              XTypeGroup(label: 'Books', extensions: ['pdf', 'epub']),
            ],
            confirmButtonText: 'Review books',
          )).map((file) => file.path).toList();
    if (paths.isEmpty || !mounted) return null;
    return _reviewImport(paths, directory: directory);
  }

  Future<LibraryImportSelection?> _pickAndroidImport() async {
    final revision = _providerRevision;
    final selected = await _androidImport.selectFiles();
    if (revision != _providerRevision) {
      if (selected case DocumentSelection(:final documents)) {
        await Future.wait(
          documents.map(
            (document) => _androidImport.discardSelection(document.token),
          ),
        );
      }
      return null;
    }
    if (selected case DocumentSelectionFailure(:final error)) {
      throw SafeUserError(documentImportErrorText(error));
    }
    if (selected is! DocumentSelection || selected.documents.isEmpty) {
      return null;
    }
    final documents = selected.documents;
    final reviewed = await _reviewImport(
      documents.map((document) => document.name).toList(growable: false),
      directory: false,
      managedOnly: true,
    );
    if (reviewed == null || revision != _providerRevision) {
      await Future.wait(
        documents.map(
          (document) => _androidImport.discardSelection(document.token),
        ),
      );
      return null;
    }
    return LibraryImportSelection(
      paths: documents.map((item) => item.name).toList(growable: false),
      managed: true,
      runner: (records, cancellation) =>
          _importAndroidDocuments(documents, records, cancellation, revision),
      cleanup: () => _discardProviderDocuments(documents),
    );
  }

  Future<FlutterImportReport> _importAndroidDocuments(
    List<SelectedProviderDocument> documents,
    ShosaiRecords records,
    BigInt cancellation,
    int revision,
  ) async {
    final items = <FlutterImportItem>[];
    var imported = 0;
    var failed = 0;
    var cancelled = false;
    for (var index = 0; index < documents.length; index += 1) {
      final document = documents[index];
      if (revision != _providerRevision) {
        cancelled = true;
        break;
      }
      final operation = '${revision}_${index}_${document.token}';
      _providerOperations.add(operation);
      DocumentAcquisitionResult acquisition;
      try {
        acquisition = await _androidImport.acquire(
          document: document,
          operationId: operation,
        );
      } finally {
        _providerOperations.remove(operation);
      }
      switch (acquisition) {
        case DocumentAcquisitionFailure(:final error):
          if (error == DocumentImportError.cancelled) {
            cancelled = true;
          } else {
            failed += 1;
            items.add(
              FlutterImportItem(
                pathKey: document.name,
                error: documentImportErrorToken(error),
              ),
            );
          }
        case AcquiredProviderDocument():
          try {
            final beginUseError = await _androidImport.beginUse(
              acquisition.releaseToken,
            );
            if (beginUseError != null) {
              failed += 1;
              items.add(
                FlutterImportItem(
                  pathKey: document.name,
                  error: documentImportErrorToken(beginUseError),
                ),
              );
            } else {
              try {
                final importedReport = await records.importPaths(
                  pathKeys: [acquisition.path],
                  managed: true,
                  cancellationId: cancellation,
                );
                imported += importedReport.imported.toInt();
                failed += importedReport.failed.toInt();
                for (final item in importedReport.items) {
                  final reviewedItem = FlutterImportItem(
                    pathKey: document.name,
                    book: item.book,
                    error: item.error,
                    warning: item.warning,
                  );
                  items.add(reviewedItem);
                }
                if (importedReport.cancelled) cancelled = true;
              } on FlutterBridgeError catch (error) {
                if (error.kind == FlutterBridgeErrorKind.cancelled) {
                  cancelled = true;
                } else {
                  failed += 1;
                  items.add(
                    FlutterImportItem(
                      pathKey: document.name,
                      error: safeError(error),
                    ),
                  );
                }
              }
            }
          } finally {
            try {
              await _androidImport.release(acquisition.releaseToken);
            } catch (_) {
              // The adapter retains cleanup ownership and retries below.
            }
          }
      }
      if (cancelled) break;
    }
    await _discardProviderDocuments(documents);
    controller.dispatch(const LibraryCleanupRetryRequested());
    return FlutterImportReport(
      imported: BigInt.from(imported),
      failed: BigInt.from(failed),
      cancelled: cancelled,
      items: List.unmodifiable(items.take(256)),
    );
  }

  Future<void> _discardProviderDocuments(
    Iterable<SelectedProviderDocument> documents,
  ) async {
    for (final document in documents) {
      try {
        await _androidImport.discardSelection(document.token);
      } catch (_) {
        // Selection tokens are also dropped when the Android host is destroyed.
      }
    }
  }

  void _cancelImportAdapter() {
    _providerRevision += 1;
    for (final operation in _providerOperations) {
      unawaited(_androidImport.cancel(operation));
    }
  }

  Future<LibraryImportSelection?> _reviewImport(
    List<String> paths, {
    required bool directory,
    bool managedOnly = false,
  }) async {
    var managed = true;
    return _showOwnedDialog<LibraryImportSelection>(
      (context) => StatefulBuilder(
        builder: (context, setState) => ShadDialog(
          title: Text(directory ? 'Review folder import' : 'Review books'),
          actions: [
            ShadButton.outline(
              height: shosaiShadButtonHeight(context),
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ShadButton(
              height: shosaiShadButtonHeight(context),
              onPressed: () => Navigator.pop(
                context,
                LibraryImportSelection(
                  paths: List.unmodifiable(paths),
                  managed: managed,
                  directory: directory,
                ),
              ),
              child: const Text('Import'),
            ),
          ],
          child: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 240),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: paths.length,
                    itemBuilder: (_, index) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Row(
                        children: [
                          Icon(
                            directory
                                ? LucideIcons.folder
                                : LucideIcons.fileText,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              paths[index],
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                _SettingSwitch(
                  title: 'Copy into managed storage',
                  subtitle: managedOnly
                      ? 'Android provider documents are copied, then temporary access is released.'
                      : managed
                      ? 'Shōsai keeps a private copy available to the reader.'
                      : 'Keep books in their selected locations.',
                  value: managed,
                  onChanged: managedOnly
                      ? null
                      : (value) => setState(() => managed = value),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<FlutterReaderSettings?> _editSettings(FlutterReaderSettings initial) =>
      _settingsDialog(context, initial, showOwnedDialog: _showOwnedDialog);

  Future<T?> _showOwnedDialog<T>(WidgetBuilder builder) async {
    if (!mounted) return null;
    final navigator = Navigator.of(context);
    final route = ShadDialogRoute<T>(
      pageBuilder: builder,
      barrierDismissible: true,
    );
    _dialogRoutes.add(route);
    try {
      return await navigator.push<T>(route);
    } finally {
      _dialogRoutes.remove(route);
    }
  }

  Future<bool> _confirmRemoval(FlutterLibraryBook book) async {
    if (!book.managed) return true;
    return await _showOwnedDialog<bool>(
          (context) => ShadDialog.alert(
            title: const Text('Delete managed copy?'),
            description: Text(
              '“${book.title}” will be removed from the library and its managed file will be deleted.',
            ),
            actions: [
              ShadButton.outline(
                height: shosaiShadButtonHeight(context),
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              ShadButton.destructive(
                height: shosaiShadButtonHeight(context),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Remove and delete'),
              ),
            ],
          ),
        ) ??
        false;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // The shell's window class and the library's header breakpoint are both
      // measured on the client width, so the probes sit outside the safe
      // area, which insets the content rather than the window.
      body: LayoutBuilder(
        builder: (context, constraints) {
          final layout = ShellLayout.forWidth(constraints.maxWidth);
          final shell = _shell.model;
          return ShellFrame(
            layout: layout,
            model: shell.copyWith(reading: false),
            covers: controller.model.covers,
            actions: _shellActions,
            child: shell.place == ShellPlace.library
                ? SafeArea(
                    bottom: layout != ShellLayout.phone,
                    child: _libraryPlace(layout),
                  )
                : ShellPlacePage(layout: layout, place: shell.place),
          );
        },
      ),
    );
  }

  /// The Library place: the header, the format filters and Settings, then the
  /// collection; on a phone the open books lead as Reading now cards.
  Widget _libraryPlace(ShellLayout layout) {
    final model = controller.model;
    final settingsRequest = model.settings == null
        ? null
        : () => controller.dispatch(const LibrarySettingsRequested());
    return LayoutBuilder(
      builder: (context, constraints) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LibraryHeader(
            compact:
                constraints.maxWidth <
                ShosaiTokens.layoutLibraryCompactBreakpoint,
            model: model,
            openCount: _shell.model.openBooks.length,
            // The header's add-books action is the import's cancel action;
            // every other cancellable operation keeps the separate cancel
            // action (the retained Flutter capability Iced has no
            // counterpart for).
            canCancelOperation: controller.canCancel && !model.importing,
            onQueryChanged: (query) =>
                controller.dispatch(LibraryQueryChanged(query)),
            onImportRequested: () =>
                controller.dispatch(const LibraryImportRequested()),
            onImportCancelled: () =>
                controller.dispatch(const LibraryOperationCancelled()),
            onOperationCancelled: () =>
                controller.dispatch(const LibraryOperationCancelled()),
            onRefresh: () => controller.dispatch(const LibraryRefreshed()),
          ),
          LibraryFilterRow(
            model: model,
            onFormatChanged: (format) =>
                controller.dispatch(LibraryFormatChanged(format)),
            onSettingsRequested: settingsRequest,
          ),
          if (layout == ShellLayout.phone && _shell.model.openBooks.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: ShellReadingNowCards(
                model: _shell.model,
                covers: model.covers,
                actions: _shellActions,
              ),
            ),
          Expanded(child: _libraryContent(model)),
        ],
      ),
    );
  }

  /// The collection column, with the retained debt surfaces above it.
  ///
  /// The failure alert itself belongs to the collection (the reference draws it
  /// inside the scroll column above the grid), and the two debt states are
  /// retained Flutter surfaces with no Iced counterpart, so they stay above the
  /// collection with their own recovery actions.
  Widget _libraryContent(LibraryModel model) {
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (model.providerCleanupPending)
          LibraryBanner(
            message: l10n.libraryCleanupPending,
            actionLabel: l10n.libraryCleanupRetry,
            onAction: () =>
                controller.dispatch(const LibraryCleanupRetryRequested()),
          ),
        if (model.managedFileDeletionPending)
          LibraryBanner(
            message: l10n.libraryDeletionPending,
            actionLabel: l10n.libraryDeletionDismiss,
            onAction: () => controller.dispatch(
              const LibraryManagedDeletionNoticeDismissed(),
            ),
          ),
        Expanded(
          child: LibraryCollection(
            model: model,
            openBookIds: {for (final open in _shell.model.openBooks) open.id},
            sortBooks: (sort) => controller.dispatch(LibrarySortChanged(sort)),
            openBook: (book) => controller.dispatch(LibraryBookOpened(book)),
            openNotes: () =>
                _shell.dispatch(const ShellPlaceSelected(ShellPlace.notes)),
            removeBook: (book) =>
                controller.dispatch(LibraryBookRemovalRequested(book)),
            loadMore: () => controller.dispatch(const LibraryMoreRequested()),
            retryPaging: () =>
                controller.dispatch(const LibraryMoreRetryRequested()),
            loadCover: controller.requestCover,
            retry: () => controller.dispatch(const LibraryRetryRequested()),
            addFirstBooks: () =>
                controller.dispatch(const LibraryImportRequested()),
            cancelImport: () =>
                controller.dispatch(const LibraryOperationCancelled()),
          ),
        ),
      ],
    );
  }
}

class LibraryBanner extends StatelessWidget {
  const LibraryBanner({
    super.key,
    required this.message,
    required this.actionLabel,
    required this.onAction,
    this.destructive = false,
  });

  final String message;
  final String actionLabel;
  final VoidCallback onAction;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final alert = destructive
        ? ShadAlert.destructive(
            icon: const Icon(LucideIcons.circleAlert),
            description: Semantics(liveRegion: true, child: Text(message)),
            trailing: ShadButton.ghost(
              onPressed: onAction,
              child: Text(actionLabel),
            ),
          )
        : ShadAlert(
            icon: const Icon(LucideIcons.info),
            description: Semantics(liveRegion: true, child: Text(message)),
            trailing: ShadButton.ghost(
              onPressed: onAction,
              child: Text(actionLabel),
            ),
          );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: alert,
    );
  }
}

/// The open books, the current one and whether the reader was showing.
String _encodeSession(ShellModel model) => jsonEncode({
  'books': [
    for (final open in model.openBooks)
      {
        'id': open.book.bookId,
        'title': open.book.title,
        'author': open.book.author,
        'format': open.book.format.name,
        'path': open.book.pathKey,
        'managed': open.book.managed,
        'progress': open.book.progress,
        'added': open.book.dateAdded,
        'read': open.book.lastRead,
        'openPath': open.path,
        'openBookId': open.bookId,
      },
  ],
  'current': model.currentBookId,
  'reading': model.reading,
});

typedef _RestoredSession = ({ShellModel model, bool reading});

_RestoredSession? _decodeSession(String encoded) {
  try {
    final value = jsonDecode(encoded) as Map<String, Object?>;
    final books = [
      for (final entry in value['books']! as List<Object?>)
        if (entry case final Map<String, Object?> book)
          OpenBook(
            book: FlutterLibraryBook(
              bookId: book['id']! as int,
              title: book['title']! as String,
              author: book['author'] as String?,
              format: FlutterBookFormat.values.byName(
                book['format']! as String,
              ),
              pathKey: book['path']! as String,
              managed: book['managed']! as bool,
              cover: null,
              progress: (book['progress']! as num).toDouble(),
              dateAdded: book['added']! as String,
              lastRead: book['read'] as String?,
            ),
            path: book['openPath'] as String? ?? book['path']! as String,
            bookId: book['openBookId'] as int?,
          ),
    ];
    final current = value['current'] as int?;
    return (
      model: ShellModel(
        openBooks: List.unmodifiable(books),
        currentBookId: books.any((open) => open.id == current) ? current : null,
      ),
      reading: value['reading'] == true,
    );
  } catch (_) {
    return null;
  }
}
