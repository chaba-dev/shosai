import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shosai_flutter/src/rust/api.dart';

typedef ProductReaderBuilder =
    Widget Function(FlutterBridge bridge, FlutterLibraryBook book);

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

class _ProductShellState extends State<ProductShell> {
  late final LibraryController controller = LibraryController(
    bridge: widget.bridgeFactory(),
  )..addListener(_changed);

  void _changed() => setState(() {});

  @override
  void initState() {
    super.initState();
    controller.dispatch(const LibraryStarted());
  }

  @override
  void dispose() {
    controller.removeListener(_changed);
    controller.dispose();
    super.dispose();
  }

  Future<void> _openBook(FlutterLibraryBook book) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => widget.readerBuilder(widget.bridgeFactory(), book),
      ),
    );
    controller.dispatch(const LibraryRefreshed());
  }

  Future<void> _import() async {
    final path = await _textDialog(
      context,
      title: 'Add a book',
      label: 'Local PDF, EPUB, or CBZ path',
    );
    if (path != null) controller.dispatch(LibraryImportRequested(path));
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
                : () => _showSettings(context, controller, model.settings!),
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: model.busy ? null : _import,
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
            SizedBox(
              height: 52,
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                scrollDirection: Axis.horizontal,
                children: [
                  for (final filter in <FlutterBookFormat?>[
                    null,
                    FlutterBookFormat.pdf,
                    FlutterBookFormat.epub,
                    FlutterBookFormat.cbz,
                  ])
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: ChoiceChip(
                        label: Text(
                          filter == null ? 'All' : filter.name.toUpperCase(),
                        ),
                        selected: model.format == filter,
                        onSelected: (_) =>
                            controller.dispatch(LibraryFormatChanged(filter)),
                      ),
                    ),
                ],
              ),
            ),
            if (model.busy) const LinearProgressIndicator(),
            if (model.error case final error?)
              MaterialBanner(
                content: Semantics(liveRegion: true, child: Text(error)),
                actions: [
                  TextButton(
                    onPressed: () =>
                        controller.dispatch(const LibraryRefreshed()),
                    child: const Text('Retry'),
                  ),
                ],
              ),
            Expanded(
              child: _LibraryCollection(
                model: model,
                openBook: _openBook,
                removeBook: (book) =>
                    controller.dispatch(LibraryBookRemoved(book.bookId)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LibraryCollection extends StatelessWidget {
  const _LibraryCollection({
    required this.model,
    required this.openBook,
    required this.removeBook,
  });

  final LibraryModel model;
  final ValueChanged<FlutterLibraryBook> openBook;
  final ValueChanged<FlutterLibraryBook> removeBook;

  @override
  Widget build(BuildContext context) {
    if (!model.loaded && model.busy) {
      return const Center(child: CircularProgressIndicator());
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
        final columns = constraints.maxWidth >= 1100
            ? 5
            : constraints.maxWidth >= 760
            ? 3
            : 1;
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            childAspectRatio: columns == 1 ? 3.6 : 1.35,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
          ),
          itemCount: model.books.length,
          itemBuilder: (context, index) {
            final book = model.books[index];
            return Card(
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => openBook(book),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    children: [
                      Icon(_formatIcon(book.format), size: 42),
                      const SizedBox(width: 14),
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
                            if (book.author case final author?) Text(author),
                            const SizedBox(height: 8),
                            LinearProgressIndicator(value: book.progress),
                            Text('${(book.progress * 100).round()}% read'),
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
            );
          },
        );
      },
    );
  }
}

IconData _formatIcon(FlutterBookFormat format) => switch (format) {
  FlutterBookFormat.pdf => Icons.picture_as_pdf_outlined,
  FlutterBookFormat.epub => Icons.menu_book_outlined,
  FlutterBookFormat.cbz => Icons.collections_bookmark_outlined,
};

Future<String?> _textDialog(
  BuildContext context, {
  required String title,
  required String label,
}) async {
  final controller = TextEditingController();
  try {
    return await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(labelText: label),
          onSubmitted: (value) => Navigator.pop(context, value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Add'),
          ),
        ],
      ),
    );
  } finally {
    controller.dispose();
  }
}

Future<void> _showSettings(
  BuildContext context,
  LibraryController controller,
  FlutterReaderSettings initial,
) async {
  var value = initial;
  final result = await showDialog<FlutterReaderSettings>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('Reader settings'),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SwitchListTile(
                title: const Text('Continuous reading'),
                value: value.continuous,
                onChanged: (enabled) => setState(
                  () => value = FlutterReaderSettings(
                    continuous: enabled,
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
                      epubFontSize: fontSize,
                      epubLineSpacing: value.epubLineSpacing,
                      pdfZoom: value.pdfZoom,
                    ),
                  ),
                ),
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
            onPressed: () => Navigator.pop(context, value),
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
  if (result != null) controller.dispatch(LibrarySettingsSaved(result));
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
    this.revision = 0,
  });

  final List<FlutterLibraryBook> books;
  final String query;
  final FlutterBookFormat? format;
  final FlutterReaderSettings? settings;
  final bool busy;
  final bool loaded;
  final String? error;
  final int revision;

  LibraryModel copyWith({
    List<FlutterLibraryBook>? books,
    String? query,
    Object? format = _same,
    Object? settings = _same,
    bool? busy,
    bool? loaded,
    Object? error = _same,
    int? revision,
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
    revision: revision ?? this.revision,
  );
}

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

final class LibraryQueryChanged extends LibraryMessage {
  const LibraryQueryChanged(this.query);
  final String query;
}

final class LibraryFormatChanged extends LibraryMessage {
  const LibraryFormatChanged(this.format);
  final FlutterBookFormat? format;
}

final class LibraryImportRequested extends LibraryMessage {
  const LibraryImportRequested(this.path);
  final String path;
}

final class LibraryBookRemoved extends LibraryMessage {
  const LibraryBookRemoved(this.bookId);
  final int bookId;
}

final class LibrarySettingsSaved extends LibraryMessage {
  const LibrarySettingsSaved(this.settings);
  final FlutterReaderSettings settings;
}

final class _LibraryLoaded extends LibraryMessage {
  const _LibraryLoaded(this.revision, this.page, this.settings);
  final int revision;
  final FlutterLibraryPage page;
  final FlutterReaderSettings? settings;
}

final class _LibraryFailed extends LibraryMessage {
  const _LibraryFailed(this.revision, this.error);
  final int revision;
  final String error;
}

class LibraryController implements Listenable {
  LibraryController({required FlutterBridge bridge}) : _bridge = bridge;

  final FlutterBridge _bridge;
  LibraryModel _model = const LibraryModel();
  final Set<VoidCallback> _listeners = {};
  Timer? _searchTimer;
  bool _disposed = false;

  LibraryModel get model => _model;

  void dispatch(LibraryMessage message) {
    if (_disposed) return;
    switch (message) {
      case LibraryStarted() || LibraryRefreshed():
        _load();
      case LibraryQueryChanged():
        _emit(_model.copyWith(query: message.query));
        _searchTimer?.cancel();
        _searchTimer = Timer(const Duration(milliseconds: 250), _load);
      case LibraryFormatChanged():
        _emit(_model.copyWith(format: message.format));
        _load();
      case LibraryImportRequested():
        _import(message.path);
      case LibraryBookRemoved():
        _remove(message.bookId);
      case LibrarySettingsSaved():
        _saveSettings(message.settings);
      case _LibraryLoaded():
        if (message.revision == _model.revision) {
          _emit(
            _model.copyWith(
              books: List.unmodifiable(message.page.books),
              settings: message.settings ?? _model.settings,
              busy: false,
              loaded: true,
              error: null,
            ),
          );
        }
      case _LibraryFailed():
        if (message.revision == _model.revision) {
          _emit(
            _model.copyWith(busy: false, loaded: true, error: message.error),
          );
        }
    }
  }

  void _load() {
    final revision = _model.revision + 1;
    _emit(_model.copyWith(busy: true, error: null, revision: revision));
    unawaited(() async {
      try {
        final results = await Future.wait<Object>([
          _bridge.libraryPage(
            query: _model.query,
            format: _model.format,
            limit: 100,
            offset: 0,
          ),
          _bridge.loadReaderSettings(),
        ]);
        dispatch(
          _LibraryLoaded(
            revision,
            results[0] as FlutterLibraryPage,
            results[1] as FlutterReaderSettings,
          ),
        );
      } catch (error) {
        dispatch(_LibraryFailed(revision, _safeError(error)));
      }
    }());
  }

  void _import(String path) {
    if (path.isEmpty || _model.busy) return;
    final revision = _model.revision + 1;
    _emit(_model.copyWith(busy: true, error: null, revision: revision));
    unawaited(() async {
      BigInt? cancellation;
      try {
        cancellation = _bridge.createCancellation();
        final result = await _bridge.importPaths(
          pathKeys: [path],
          managed: true,
          cancellationId: cancellation,
        );
        final failure = result.where((item) => item.error != null).firstOrNull;
        if (failure != null) throw StateError(failure.error!);
        if (revision == _model.revision) _load();
      } catch (error) {
        dispatch(_LibraryFailed(revision, _safeError(error)));
      } finally {
        if (cancellation != null) {
          _bridge.releaseCancellation(id: cancellation);
        }
      }
    }());
  }

  void _remove(int bookId) {
    if (_model.busy) return;
    final revision = _model.revision + 1;
    _emit(_model.copyWith(busy: true, error: null, revision: revision));
    unawaited(() async {
      try {
        await _bridge.removeLibraryBook(bookId: bookId);
        if (revision == _model.revision) _load();
      } catch (error) {
        dispatch(_LibraryFailed(revision, _safeError(error)));
      }
    }());
  }

  void _saveSettings(FlutterReaderSettings settings) {
    final revision = _model.revision + 1;
    _emit(
      _model.copyWith(
        settings: settings,
        busy: true,
        error: null,
        revision: revision,
      ),
    );
    unawaited(() async {
      try {
        await _bridge.saveReaderSettings(value: settings);
        if (revision == _model.revision) {
          _emit(_model.copyWith(busy: false));
        }
      } catch (error) {
        dispatch(_LibraryFailed(revision, _safeError(error)));
      }
    }());
  }

  String _safeError(Object error) => switch (error) {
    FlutterBridgeError() => error.message,
    _ => 'The operation could not be completed.',
  };

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
    _disposed = true;
    _searchTimer?.cancel();
    _listeners.clear();
    _bridge.dispose();
  }
}
