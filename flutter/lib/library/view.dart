import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shosai_flutter/android_document_import_adapter.dart';
import 'package:shosai_flutter/app_theme.dart';
import 'package:shosai_flutter/l10n/app_localizations.dart';
import 'package:shosai_flutter/library/controller.dart';
import 'package:shosai_flutter/library/errors.dart';
import 'package:shosai_flutter/reader/controller.dart';
import 'package:shosai_flutter/shared/shad_widgets.dart';
import 'package:shosai_flutter/src/rust/api.dart';
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
    );

class ProductShell extends StatefulWidget {
  const ProductShell({
    super.key,
    required this.bridgeFactory,
    required this.readerBuilder,
    this.androidImport,
  });

  final FlutterBridge Function() bridgeFactory;
  final ProductReaderBuilder readerBuilder;
  final AndroidDocumentImportAdapter? androidImport;

  @override
  State<ProductShell> createState() => _ProductShellState();
}

class _ProductShellState extends State<ProductShell> with RestorationMixin {
  final RestorableStringN _activeBook = RestorableStringN(null);
  final Set<Route<Object?>> _dialogRoutes = {};
  NavigatorState? _navigator;
  ({FlutterLibraryBook book, String path, int? bookId})? _pendingRestoredBook;
  ({String path, int? bookId})? _restoredLocator;
  bool _restoredOpenScheduled = false;
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
    _scheduleRestoredOpen();
  }

  void _scheduleRestoredOpen() {
    if (_pendingRestoredBook != null &&
        controller.model.loaded &&
        !controller.model.busy &&
        !_restoredOpenScheduled) {
      _restoredOpenScheduled = true;
      scheduleMicrotask(() {
        _restoredOpenScheduled = false;
        if (!mounted || !controller.model.loaded || controller.model.busy) {
          return;
        }
        final restored = _pendingRestoredBook;
        _pendingRestoredBook = null;
        if (restored != null) {
          _restoredLocator = (path: restored.path, bookId: restored.bookId);
          controller.dispatch(LibraryBookOpened(restored.book));
        }
      });
    }
  }

  @override
  String get restorationId => 'product-shell';

  @override
  void restoreState(RestorationBucket? oldBucket, bool initialRestore) {
    registerForRestoration(_activeBook, 'active-book');
    if (_activeBook.value case final encoded?) {
      _pendingRestoredBook = _decodeActiveBook(encoded);
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
    _activeBook.dispose();
    super.dispose();
  }

  Future<void> _openBook(FlutterLibraryBook book) async {
    final restored = _restoredLocator;
    _restoredLocator = null;
    final initialPath = restored?.path ?? book.pathKey;
    final initialBookId = restored == null ? book.bookId : restored.bookId;
    _activeBook.value = _encodeBook(
      book,
      path: initialPath,
      bookId: initialBookId,
    );
    try {
      final route = MaterialPageRoute<void>(
        builder: (_) => widget.readerBuilder(
          widget.bridgeFactory(),
          book,
          controller.model.settings,
          initialPath,
          initialBookId,
          (path, bookId) {
            if (mounted) {
              _activeBook.value = _encodeBook(book, path: path, bookId: bookId);
            }
          },
        ),
      );
      unawaited(Navigator.of(context).push<void>(route));
      await route.completed;
    } finally {
      if (mounted) _activeBook.value = null;
    }
  }

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
              subtitle: 'Select one or more PDF, EPUB, or CBZ files',
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
              XTypeGroup(label: 'Books', extensions: ['pdf', 'epub', 'cbz']),
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
      runner: (bridge, cancellation) =>
          _importAndroidDocuments(documents, bridge, cancellation, revision),
      cleanup: () => _discardProviderDocuments(documents),
    );
  }

  Future<FlutterImportReport> _importAndroidDocuments(
    List<SelectedProviderDocument> documents,
    FlutterBridge bridge,
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
                final importedReport = await bridge.importPaths(
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
    final model = controller.model;
    void formatChanged(FlutterBookFormat? format) =>
        controller.dispatch(LibraryFormatChanged(format));
    final settingsRequest = model.settings == null
        ? null
        : () => controller.dispatch(const LibrarySettingsRequested());
    return Scaffold(
      // The shared library/settings breakpoint is measured on the client
      // width, so the probe sits outside the safe area, which insets the
      // content rather than the window.
      body: LayoutBuilder(
        builder: (context, constraints) {
          final compact =
              constraints.maxWidth <
              ShosaiTokens.layoutLibraryCompactBreakpoint;
          return SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LibraryHeader(
                  compact: compact,
                  model: model,
                  // The header's add-books action is the import's cancel
                  // action; every other cancellable operation keeps the
                  // separate cancel action (the retained Flutter capability
                  // Iced has no counterpart for).
                  canCancelOperation: controller.canCancel && !model.importing,
                  onQueryChanged: (query) =>
                      controller.dispatch(LibraryQueryChanged(query)),
                  onImportRequested: () =>
                      controller.dispatch(const LibraryImportRequested()),
                  onImportCancelled: () =>
                      controller.dispatch(const LibraryOperationCancelled()),
                  onOperationCancelled: () =>
                      controller.dispatch(const LibraryOperationCancelled()),
                  onRefresh: () =>
                      controller.dispatch(const LibraryRefreshed()),
                ),
                Expanded(
                  child: compact
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            LibraryFilterRow(
                              model: model,
                              onFormatChanged: formatChanged,
                              onSettingsRequested: settingsRequest,
                            ),
                            Expanded(child: _libraryContent(model)),
                          ],
                        )
                      : Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            LibrarySidebar(
                              model: model,
                              onFormatChanged: formatChanged,
                              onSettingsRequested: settingsRequest,
                            ),
                            Expanded(child: _libraryContent(model)),
                          ],
                        ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// The collection column: retained debt surfaces above the collection, so the
  /// sidebar keeps the full height it has in the reference.
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
            openBook: (book) => controller.dispatch(LibraryBookOpened(book)),
            removeBook: (book) =>
                controller.dispatch(LibraryBookRemovalRequested(book)),
            loadMore: () => controller.dispatch(const LibraryMoreRequested()),
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

String _encodeBook(
  FlutterLibraryBook book, {
  required String path,
  required int? bookId,
}) => jsonEncode({
  'id': book.bookId,
  'title': book.title,
  'author': book.author,
  'format': book.format.name,
  'path': book.pathKey,
  'managed': book.managed,
  'progress': book.progress,
  'added': book.dateAdded,
  'read': book.lastRead,
  'openPath': path,
  'openBookId': bookId,
});

({FlutterLibraryBook book, String path, int? bookId})? _decodeActiveBook(
  String encoded,
) {
  try {
    final value = jsonDecode(encoded) as Map<String, Object?>;
    final format = FlutterBookFormat.values.byName(value['format']! as String);
    final book = FlutterLibraryBook(
      bookId: value['id']! as int,
      title: value['title']! as String,
      author: value['author'] as String?,
      format: format,
      pathKey: value['path']! as String,
      managed: value['managed']! as bool,
      cover: null,
      progress: (value['progress']! as num).toDouble(),
      dateAdded: value['added']! as String,
      lastRead: value['read'] as String?,
    );
    return (
      book: book,
      path: value['openPath'] as String? ?? book.pathKey,
      bookId: value['openBookId'] as int?,
    );
  } catch (_) {
    return null;
  }
}
