import 'dart:async';
import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shosai_flutter/android_document_import_adapter.dart';
import 'package:shosai_flutter/reader_controller.dart';
import 'package:shosai_flutter/src/rust/api.dart';

typedef ProductReaderBuilder =
    Widget Function(
      FlutterBridge bridge,
      FlutterLibraryBook book,
      FlutterReaderSettings? settings,
      String initialPath,
      int? initialBookId,
      void Function(String path, int? bookId) locatorChanged,
    );
typedef LibraryRemovalConfirmer =
    Future<bool> Function(FlutterLibraryBook book);
typedef LibraryImportPicker = Future<LibraryImportSelection?> Function();
typedef LibraryBookOpener = Future<void> Function(FlutterLibraryBook book);
typedef LibraryReaderSaveDrainer = Future<void> Function(int bookId);
typedef LibrarySettingsEditor =
    Future<FlutterReaderSettings?> Function(FlutterReaderSettings initial);
typedef LibraryImportAdapterCanceller = void Function();
void _ignoreImportAdapterCancellation() {}

final class LibraryImportSelection {
  const LibraryImportSelection({
    required this.paths,
    required this.managed,
    this.directory = false,
    this.cleanup,
  });

  final List<String> paths;
  final bool managed;
  final bool directory;
  final Future<void> Function()? cleanup;
}

class ProductShell extends StatefulWidget {
  const ProductShell({
    super.key,
    required this.bridgeFactory,
    required this.readerBuilder,
  });

  final FlutterBridge Function() bridgeFactory;
  final ProductReaderBuilder readerBuilder;

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
  final AndroidDocumentImportAdapter _androidImport =
      AndroidDocumentImportAdapter();
  final Set<String> _providerOperations = {};
  int _providerRevision = 0;
  late final LibraryController controller = LibraryController(
    bridge: widget.bridgeFactory(),
    confirmRemoval: _confirmRemoval,
    pickImport: _pickImport,
    openBook: _openBook,
    drainReaderSaves: ReaderController.drainBookReadingStateWrites,
    editSettings: _editSettings,
    cancelImportAdapter: _cancelImportAdapter,
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
        (context) => AlertDialog(
          title: const Text('Import unavailable'),
          content: const Text(
            'Document-provider import has not yet been validated on iOS.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        ),
      );
      return null;
    }
    final directory = await _showOwnedDialog<bool>(
      (context) => SimpleDialog(
        title: const Text('Add books'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, false),
            child: const ListTile(
              leading: Icon(Icons.file_open_outlined),
              title: Text('Choose files'),
              subtitle: Text('Select one or more PDF, EPUB, or CBZ files'),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, true),
            child: const ListTile(
              leading: Icon(Icons.folder_open_outlined),
              title: Text('Choose a folder'),
              subtitle: Text('Find supported books in all subfolders'),
            ),
          ),
        ],
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
    final acquired = <AcquiredProviderDocument>[];
    for (var index = 0; index < documents.length; index += 1) {
      final document = documents[index];
      final operation = '${revision}_${document.token}';
      _providerOperations.add(operation);
      final result = await _androidImport.acquire(
        document: document,
        operationId: operation,
      );
      _providerOperations.remove(operation);
      if (result case AcquiredProviderDocument()) {
        acquired.add(result);
      } else {
        await Future.wait([
          ...acquired.map((item) => _androidImport.release(item.releaseToken)),
          ...documents
              .skip(acquired.length + 1)
              .map((item) => _androidImport.discardSelection(item.token)),
        ]);
        return null;
      }
      if (revision != _providerRevision) {
        await Future.wait([
          ...acquired.map((item) => _androidImport.release(item.releaseToken)),
          ...documents
              .skip(index + 1)
              .map((item) => _androidImport.discardSelection(item.token)),
        ]);
        return null;
      }
    }
    return LibraryImportSelection(
      paths: acquired.map((item) => item.path).toList(growable: false),
      managed: true,
      cleanup: () => Future.wait(
        acquired.map((item) => _androidImport.release(item.releaseToken)),
      ),
    );
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
        builder: (context, setState) => AlertDialog(
          scrollable: true,
          title: Text(directory ? 'Review folder import' : 'Review books'),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 240),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: paths.length,
                    itemBuilder: (_, index) => ListTile(
                      leading: Icon(
                        directory
                            ? Icons.folder_outlined
                            : Icons.description_outlined,
                      ),
                      title: Text(
                        paths[index],
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ),
                if (managedOnly)
                  const ListTile(
                    leading: Icon(Icons.lock_outline),
                    title: Text('Copy into managed storage'),
                    subtitle: Text(
                      'Android provider documents are copied, then temporary access is released.',
                    ),
                  )
                else
                  SwitchListTile(
                    title: const Text('Copy into managed storage'),
                    subtitle: Text(
                      managed
                          ? 'Shōsai keeps a private copy available to the reader.'
                          : 'Keep books in their selected locations.',
                    ),
                    value: managed,
                    onChanged: (value) => setState(() => managed = value),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
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
        ),
      ),
    );
  }

  Future<FlutterReaderSettings?> _editSettings(FlutterReaderSettings initial) =>
      _settingsDialog(context, initial, showOwnedDialog: _showOwnedDialog);

  Future<T?> _showOwnedDialog<T>(WidgetBuilder builder) async {
    if (!mounted) return null;
    final navigator = Navigator.of(context);
    final route = DialogRoute<T>(
      context: context,
      builder: builder,
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
          (context) => AlertDialog(
            title: const Text('Delete managed copy?'),
            content: Text(
              '“${book.title}” will be removed from the library and its managed file will be deleted.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Shōsai'),
        actions: [
          IconButton(
            tooltip: 'Refresh library',
            onPressed: model.busy
                ? null
                : () => controller.dispatch(const LibraryRefreshed()),
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'Reader settings',
            onPressed: model.settings == null
                ? null
                : () => controller.dispatch(const LibrarySettingsRequested()),
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: model.busy
            ? null
            : () => controller.dispatch(const LibraryImportRequested()),
        icon: const Icon(Icons.add),
        label: const Text('Add books'),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: SearchBar(
                hintText: 'Search title or author',
                leading: const Icon(Icons.search),
                onChanged: (query) =>
                    controller.dispatch(LibraryQueryChanged(query)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final filter in <FlutterBookFormat?>[
                      null,
                      FlutterBookFormat.pdf,
                      FlutterBookFormat.epub,
                      FlutterBookFormat.cbz,
                    ])
                      ChoiceChip(
                        label: Text(
                          filter == null ? 'All' : filter.name.toUpperCase(),
                        ),
                        selected: model.format == filter,
                        onSelected: (_) =>
                            controller.dispatch(LibraryFormatChanged(filter)),
                      ),
                  ],
                ),
              ),
            ),
            if (model.busy)
              Row(
                children: [
                  const Expanded(child: LinearProgressIndicator()),
                  if (controller.canCancel)
                    IconButton(
                      tooltip: 'Cancel operation',
                      onPressed: () => controller.dispatch(
                        const LibraryOperationCancelled(),
                      ),
                      icon: const Icon(Icons.close),
                    ),
                ],
              ),
            if (model.displayError case final error?)
              MaterialBanner(
                content: Semantics(liveRegion: true, child: Text(error)),
                actions: [
                  TextButton(
                    onPressed: () =>
                        controller.dispatch(const LibraryRetryRequested()),
                    child: const Text('Retry'),
                  ),
                ],
              ),
            Expanded(
              child: _LibraryCollection(
                model: model,
                openBook: (book) =>
                    controller.dispatch(LibraryBookOpened(book)),
                removeBook: (book) =>
                    controller.dispatch(LibraryBookRemovalRequested(book)),
                loadMore: () =>
                    controller.dispatch(const LibraryMoreRequested()),
                loadCover: (bookId) =>
                    controller.dispatch(LibraryCoverRequested(bookId)),
              ),
            ),
          ],
        ),
      ),
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

class _LibraryCollection extends StatelessWidget {
  const _LibraryCollection({
    required this.model,
    required this.openBook,
    required this.removeBook,
    required this.loadMore,
    required this.loadCover,
  });

  final LibraryModel model;
  final ValueChanged<FlutterLibraryBook> openBook;
  final ValueChanged<FlutterLibraryBook> removeBook;
  final VoidCallback loadMore;
  final ValueChanged<int> loadCover;

  @override
  Widget build(BuildContext context) {
    if (!model.loaded && model.busy) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!model.loaded && model.loadError != null) {
      return const Center(child: Text('The library could not be loaded.'));
    }
    if (model.books.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            model.query.isEmpty && model.format == null
                ? 'Your library is empty. Add a PDF, EPUB, or CBZ to begin.'
                : 'No books match these filters.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final textScale = MediaQuery.textScalerOf(context).scale(1);
        final needsExpandedCard = textScale > 1;
        final columns = constraints.maxWidth >= 1100
            ? 5
            : constraints.maxWidth >= 760
            ? 3
            : 1;
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            childAspectRatio: 1.35,
            mainAxisExtent: needsExpandedCard
                ? 180 + (textScale - 1) * (columns == 1 ? 100 : 140)
                : (columns == 1 ? 180 : null),
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
          ),
          itemCount: model.books.length + (model.hasMore ? 1 : 0),
          itemBuilder: (context, index) {
            if (index == model.books.length) {
              return Card(
                child: Center(
                  child: TextButton.icon(
                    onPressed: model.busy ? null : loadMore,
                    icon: const Icon(Icons.expand_more),
                    label: const Text('Load more books'),
                  ),
                ),
              );
            }
            final book = model.books[index];
            return Card(
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => openBook(book),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: LayoutBuilder(
                    builder: (context, cardConstraints) => Row(
                      children: [
                        if (cardConstraints.maxWidth >= 150) ...[
                          _BookCover(book: book, loadCover: loadCover),
                          const SizedBox(width: 14),
                        ],
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                book.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              if (book.author case final author?)
                                Text(
                                  author,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              const SizedBox(height: 8),
                              LinearProgressIndicator(value: book.progress),
                              Text(
                                book.lastRead == null
                                    ? '${(book.progress * 100).round()}% read'
                                    : 'Continue reading · ${(book.progress * 100).round()}%',
                              ),
                            ],
                          ),
                        ),
                        PopupMenuButton<String>(
                          tooltip: 'Book actions',
                          onSelected: (action) {
                            if (action == 'remove') removeBook(book);
                          },
                          itemBuilder: (_) => [
                            PopupMenuItem(
                              value: 'remove',
                              child: Text(
                                book.managed
                                    ? 'Remove and delete copy'
                                    : 'Remove from library',
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _BookCover extends StatelessWidget {
  const _BookCover({required this.book, required this.loadCover});

  final FlutterLibraryBook book;
  final ValueChanged<int> loadCover;

  @override
  Widget build(BuildContext context) {
    final fallback = Icon(_formatIcon(book.format), size: 42);
    final cover = book.cover;
    if (cover == null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => loadCover(book.bookId),
      );
      return fallback;
    }
    if (cover.isEmpty) return fallback;
    return Semantics(
      image: true,
      label: 'Cover of ${book.title}',
      child: SizedBox(
        width: 56,
        height: 80,
        child: Image.memory(
          cover,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => Center(child: fallback),
        ),
      ),
    );
  }
}

IconData _formatIcon(FlutterBookFormat format) => switch (format) {
  FlutterBookFormat.pdf => Icons.picture_as_pdf_outlined,
  FlutterBookFormat.epub => Icons.menu_book_outlined,
  FlutterBookFormat.cbz => Icons.collections_bookmark_outlined,
};

Future<FlutterReaderSettings?> _settingsDialog(
  BuildContext context,
  FlutterReaderSettings initial, {
  required Future<T?> Function<T>(WidgetBuilder builder) showOwnedDialog,
}) async {
  var value = initial;
  final result = await showOwnedDialog<FlutterReaderSettings>(
    (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('Reader settings'),
        content: SizedBox(
          width: 360,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: value.theme,
                  decoration: const InputDecoration(labelText: 'Reader theme'),
                  items: const [
                    DropdownMenuItem(value: 'light', child: Text('Light')),
                    DropdownMenuItem(value: 'sepia', child: Text('Sepia')),
                    DropdownMenuItem(value: 'dark', child: Text('Dark')),
                  ],
                  onChanged: (theme) {
                    if (theme != null) {
                      setState(
                        () => value = FlutterReaderSettings(
                          continuous: value.continuous,
                          theme: theme,
                          epubFontSize: value.epubFontSize,
                          epubLineSpacing: value.epubLineSpacing,
                          pdfZoom: value.pdfZoom,
                        ),
                      );
                    }
                  },
                ),
                SwitchListTile(
                  title: const Text('Continuous reading'),
                  value: value.continuous,
                  onChanged: (continuous) => setState(
                    () => value = FlutterReaderSettings(
                      continuous: continuous,
                      theme: value.theme,
                      epubFontSize: value.epubFontSize,
                      epubLineSpacing: value.epubLineSpacing,
                      pdfZoom: value.pdfZoom,
                    ),
                  ),
                ),
                ListTile(
                  title: const Text('EPUB text size'),
                  subtitle: Slider(
                    min: 12,
                    max: 32,
                    divisions: 10,
                    value: value.epubFontSize.clamp(12, 32),
                    label: value.epubFontSize.round().toString(),
                    onChanged: (fontSize) => setState(
                      () => value = FlutterReaderSettings(
                        continuous: value.continuous,
                        theme: value.theme,
                        epubFontSize: fontSize,
                        epubLineSpacing: value.epubLineSpacing,
                        pdfZoom: value.pdfZoom,
                      ),
                    ),
                  ),
                ),
                ListTile(
                  title: const Text('EPUB line spacing'),
                  subtitle: Slider(
                    min: 1,
                    max: 3,
                    divisions: 8,
                    value: value.epubLineSpacing.clamp(1, 3),
                    label: value.epubLineSpacing.toStringAsFixed(2),
                    onChanged: (lineSpacing) => setState(
                      () => value = FlutterReaderSettings(
                        continuous: value.continuous,
                        theme: value.theme,
                        epubFontSize: value.epubFontSize,
                        epubLineSpacing: lineSpacing,
                        pdfZoom: value.pdfZoom,
                      ),
                    ),
                  ),
                ),
                DropdownButtonFormField<double>(
                  initialValue: value.pdfZoom,
                  decoration: const InputDecoration(labelText: 'PDF zoom'),
                  items: [
                    const DropdownMenuItem(value: 0, child: Text('Fit page')),
                    const DropdownMenuItem(value: -1, child: Text('Fit width')),
                    const DropdownMenuItem(value: 1, child: Text('100%')),
                    const DropdownMenuItem(value: 1.5, child: Text('150%')),
                    const DropdownMenuItem(value: 2, child: Text('200%')),
                    if (!const [
                      0.0,
                      -1.0,
                      1.0,
                      1.5,
                      2.0,
                    ].contains(value.pdfZoom))
                      DropdownMenuItem(
                        value: value.pdfZoom,
                        child: Text(
                          '${(value.pdfZoom * 100).round()}% (custom)',
                        ),
                      ),
                  ],
                  onChanged: (pdfZoom) {
                    if (pdfZoom != null) {
                      setState(
                        () => value = FlutterReaderSettings(
                          continuous: value.continuous,
                          theme: value.theme,
                          epubFontSize: value.epubFontSize,
                          epubLineSpacing: value.epubLineSpacing,
                          pdfZoom: pdfZoom,
                        ),
                      );
                    }
                  },
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, value),
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
  return result;
}

final class LibraryModel {
  const LibraryModel({
    this.books = const [],
    this.query = '',
    this.format,
    this.settings,
    this.busy = false,
    this.loaded = false,
    this.error,
    this.loadError,
    this.hasMore = false,
    this.failure = LibraryFailure.none,
  });

  final List<FlutterLibraryBook> books;
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

  LibraryModel copyWith({
    List<FlutterLibraryBook>? books,
    String? query,
    Object? format = _same,
    Object? settings = _same,
    bool? busy,
    bool? loaded,
    Object? error = _same,
    Object? loadError = _same,
    bool? hasMore,
    LibraryFailure? failure,
  }) => LibraryModel(
    books: books ?? this.books,
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
  );
}

enum LibraryFailure { none, load, import, removal, settings }

const _same = Object();

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
  });
  final LibraryFailure failure;
  final String? error;
  final FlutterReaderSettings? settings;
  final BigInt? cancellation;
  final bool refresh;
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

final class _LibraryCoverEffectFinished extends LibraryMessage {
  const _LibraryCoverEffectFinished();
}

class LibraryController implements Listenable {
  LibraryController({
    required FlutterBridge bridge,
    required LibraryRemovalConfirmer confirmRemoval,
    required LibraryImportPicker pickImport,
    required LibraryBookOpener openBook,
    required LibraryReaderSaveDrainer drainReaderSaves,
    required LibrarySettingsEditor editSettings,
    LibraryImportAdapterCanceller cancelImportAdapter =
        _ignoreImportAdapterCancellation,
  }) : _bridge = bridge,
       _confirmRemoval = confirmRemoval,
       _pickImport = pickImport,
       _openBook = openBook,
       _drainReaderSaves = drainReaderSaves,
       _editSettings = editSettings,
       _cancelImportAdapter = cancelImportAdapter;

  final FlutterBridge _bridge;
  final LibraryRemovalConfirmer _confirmRemoval;
  final LibraryImportPicker _pickImport;
  final LibraryBookOpener _openBook;
  final LibraryReaderSaveDrainer _drainReaderSaves;
  final LibrarySettingsEditor _editSettings;
  final LibraryImportAdapterCanceller _cancelImportAdapter;
  LibraryModel _model = const LibraryModel();
  final Set<VoidCallback> _listeners = {};
  final Set<BigInt> _cancellations = {};
  final Set<BigInt> _foregroundCancellations = {};
  final Set<BigInt> _loadCancellations = {};
  final Set<int> _coverRequests = {};
  Timer? _searchTimer;
  int _loadRevision = 0;
  int _queryRevision = 0;
  int _activeEffects = 0;
  int _activeBusyEffects = 0;
  int _adapterRevision = 0;
  String? _displayedQuery;
  FlutterBookFormat? _displayedFormat;
  bool _closing = false;
  bool _bridgeDisposed = false;
  bool _pendingImportAdapter = false;

  LibraryModel get model => _model;
  bool get canCancel =>
      _pendingImportAdapter || _foregroundCancellations.isNotEmpty;

  void dispatch(LibraryMessage message) {
    if (_closing &&
        message is! _LibraryLoaded &&
        message is! _LibraryFailed &&
        message is! _LibraryMutationCompleted &&
        message is! _LibraryReaderClosed &&
        message is! _LibraryEffectFinished &&
        message is! _LibraryCoverLoaded &&
        message is! _LibraryCoverEffectFinished) {
      return;
    }
    switch (message) {
      case LibraryStarted() || LibraryRefreshed():
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
                    ? [..._model.books, ...message.page.books]
                    : message.page.books,
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
          _cancellations.remove(cancellation);
          _bridge.releaseCancellation(id: cancellation);
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
            ),
          );
          if (message.failure == LibraryFailure.import ||
              message.failure == LibraryFailure.removal) {
            _load();
          }
        }
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
          _emit(
            _model.copyWith(
              books: _model.books
                  .map(
                    (book) => book.bookId == message.bookId
                        ? FlutterLibraryBook(
                            bookId: book.bookId,
                            title: book.title,
                            author: book.author,
                            format: book.format,
                            pathKey: book.pathKey,
                            managed: book.managed,
                            cover: message.cover ?? Uint8List(0),
                            progress: book.progress,
                            dateAdded: book.dateAdded,
                            lastRead: book.lastRead,
                          )
                        : book,
                  )
                  .toList(growable: false),
            ),
          );
        }
      case _LibraryCoverEffectFinished():
        _activeEffects -= 1;
        _disposeBridgeIfIdle();
    }
  }

  void _beginEffect() {
    _activeEffects += 1;
    _activeBusyEffects += 1;
    _emit(_model.copyWith(busy: true));
  }

  void _loadCover(int bookId) {
    if (_closing || !_coverRequests.add(bookId)) return;
    late final BigInt cancellation;
    try {
      cancellation = _bridge.createCancellation();
    } catch (_) {
      return;
    }
    _cancellations.add(cancellation);
    _activeEffects += 1;
    unawaited(() async {
      try {
        final cover = await _bridge.libraryCover(
          bookId: bookId,
          cancellationId: cancellation,
        );
        dispatch(_LibraryCoverLoaded(bookId, cover, cancellation));
      } catch (_) {
        _releaseCancellation(cancellation);
      } finally {
        dispatch(const _LibraryCoverEffectFinished());
      }
    }());
  }

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
      _emit(_model.copyWith(loadError: _safeError(error), hasMore: false));
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
            _safeError(error),
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
        late final List<FlutterImportItem> items;
        var refresh = false;
        String? terminalStatus;
        if (selection.directory) {
          final report = await _bridge.importDirectory(
            pathKey: selection.paths.single,
            managed: selection.managed,
            cancellationId: cancellation,
          );
          items = report.items;
          refresh = report.imported > BigInt.zero;
          if (report.cancelled) {
            terminalStatus = report.imported == BigInt.zero
                ? 'Import cancelled.'
                : 'Import cancelled after ${report.imported} books.';
          } else if (report.failed > BigInt.zero) {
            terminalStatus =
                'Imported ${report.imported} books; ${report.failed} failed.';
          }
        } else {
          items = await _bridge.importPaths(
            pathKeys: selection.paths,
            managed: selection.managed,
            cancellationId: cancellation,
          );
          refresh = items.any((item) => item.book != null);
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
            error: _safeError(error),
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
          _cancellations.remove(cancellation);
          _bridge.releaseCancellation(id: cancellation);
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
        await _bridge.removeLibraryBook(bookId: book.bookId);
        dispatch(
          const _LibraryMutationCompleted(failure: LibraryFailure.removal),
        );
      } catch (error) {
        dispatch(
          _LibraryMutationCompleted(
            failure: LibraryFailure.removal,
            error: _safeError(error),
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
        dispatch(_LibraryReaderClosed(_safeError(error)));
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
            error: _safeError(error),
          ),
        );
      } finally {
        dispatch(const _LibraryEffectFinished());
      }
    }());
  }

  String _safeError(Object error) => switch (error) {
    FlutterBridgeError() => error.message,
    _ => 'The operation could not be completed.',
  };

  bool _ownsAdapter(int revision) => !_closing && revision == _adapterRevision;

  String _safeImportError(String error) {
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
    _adapterRevision += 1;
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
