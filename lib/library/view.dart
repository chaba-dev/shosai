import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shosai_flutter/android_document_import_adapter.dart';
import 'package:shosai_flutter/app_theme.dart';
import 'package:shosai_flutter/core/records.dart';
import 'package:shosai_flutter/core/library_folders.dart';
import 'package:shosai_flutter/core/connection_credentials.dart';
import 'package:shosai_flutter/core/dropbox_authorization.dart';
import 'package:shosai_flutter/core/dropbox_connection.dart';
import 'package:shosai_flutter/l10n/app_localizations.dart';
import 'package:shosai_flutter/library/controller.dart';
import 'package:shosai_flutter/library/dropbox_dialog.dart';
import 'package:shosai_flutter/library/errors.dart';
import 'package:shosai_flutter/library/folders_controller.dart';
import 'package:shosai_flutter/library/folders_view.dart';
import 'package:shosai_flutter/notices/library_notice_text.dart';
import 'package:shosai_flutter/notices/notices.dart';
import 'package:shosai_flutter/opened_documents.dart';
import 'package:shosai_flutter/reader/controller.dart';
import 'package:shosai_flutter/shared/shad_widgets.dart';
import 'package:shosai_flutter/core/bridge.dart';
import 'package:shosai_flutter/shell/view.dart';
import 'package:shosai_flutter/theme_tokens.dart';
import 'package:url_launcher/url_launcher.dart';

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
      ReaderDisplaySink displayChanged,
      ReaderPlaceRequests placeRequests,
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

  /// Whether a platform restoration brought a session back; it is newer than
  /// the open books saved with the library.
  bool _platformRestored = false;
  bool _started = false;

  /// The open book a restored session was reading: the library opens it
  /// once it is idle, unless the person has gone to a book first.
  int? _pendingResume;

  /// The open books are saved with the library through a bridge of their
  /// own, which outlives the shell until its last save settles.
  late final FlutterBridge _sessionBridge = widget.bridgeFactory();
  late final ShosaiRecords _sessionRecords = recordsOf(_sessionBridge);

  /// Actions chosen from the rail run after reader saves finish and the
  /// library becomes idle again. The book remains in Reading now.
  LibraryMessage? _pendingLibraryAction;

  late final ShellController _shell = ShellController(
    presentReader: _presentReader,
    dismissReader: _dismissReader,
    capturePageMiniature: _capturePageMiniature,
    loadOpenBooks: _sessionRecords.loadOpenBooks,
    saveOpenBooks: _sessionRecords.saveOpenBooks,
    resumeReading: (book) {
      _pendingResume = book.id;
      _scheduleRestoredOpen();
    },
  )..addListener(_shellChanged);
  ModalRoute<void>? _readerRoute;

  /// The Notes place's list; it lists again each time the place shows.
  late final ShellNotesController _notes = ShellNotesController(
    bridge: widget.bridgeFactory(),
  )..addListener(_notesChanged);
  bool _notesShowing = false;

  /// The search palette's searches; its query carries over between openings.
  late final ShellSearchController _search = ShellSearchController(
    bridge: widget.bridgeFactory(),
  );
  Route<ShellSearchChoice>? _searchRoute;

  /// The book a note or search hit was opened in and its place: the reader
  /// built next for that book opens there instead of where it was left.
  (int, ReaderPlace)? _openAt;

  /// The reader for the current open book, built once per book so a locator
  /// report does not rebuild it, and the places the shell asks it to go to.
  (int, Widget, ReaderPlaceRequests)? _reader;

  /// The open books the reader showed during one presentation; their saves
  /// are drained before the library reloads.
  final Set<int> _shownBooks = {};
  List<FlutterLibraryBook>? _listedBooks;
  final OpenedDocuments _openedDocuments = OpenedDocuments();
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
    manageConnections: _manageLocations,
    retryProviderCleanup: _androidImport.retryCleanup,
    cancelImportAdapter: _cancelImportAdapter,
    localizations: () => AppLocalizations.of(context),
    openedDocuments: defaultTargetPlatform == TargetPlatform.iOS
        ? _openedDocuments
        : null,
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
    _schedulePendingLibraryAction();
  }

  void _shellChanged() {
    setState(() {});
    _session.value = _encodeSession(_shell.model);
    final model = _shell.model;
    // The person went to a book before a restoration could: theirs stands.
    if (model.openBooks.isNotEmpty) _pendingRestoredSession = null;
    if (model.reading) _pendingResume = null;
    final notesShowing = model.place == ShellPlace.notes && !model.reading;
    if (notesShowing && !_notesShowing) {
      _notes.dispatch(const ShellNotesRequested());
    }
    _notesShowing = notesShowing;
  }

  void _notesChanged() => setState(() {});

  /// Captures the current reader's page for the shell controller, which owns
  /// its admission, invalidation and disposal.
  Future<ui.Image?> _capturePageMiniature(int id) async {
    final source = switch (_reader) {
      (final reader, _, final requests) when reader == id => requests,
      _ => null,
    };
    var capture = source?.pageMiniature;
    if (capture == null) return null;
    if (capture() case final image?) return image;

    for (var attempt = 0; attempt < 16; attempt += 1) {
      WidgetsBinding.instance.scheduleFrame();
      await WidgetsBinding.instance.endOfFrame;
      final current = switch (_reader) {
        (final reader, _, final requests) when reader == id => requests,
        _ => null,
      };
      if (!identical(current, source)) return null;
      capture = source?.pageMiniature;
      if (capture == null) return null;
      final image = capture();
      if (image != null) return image;
    }
    return null;
  }

  /// Opens [book] at [note]'s place; a book note opens where it was left.
  void _openNote(FlutterBookNotes book, FlutterNoteEntry note) {
    final unit = note.unit;
    _openBookAt(
      book.book,
      unit == null
          ? null
          : ReaderPlace(
              unit,
              offset: note.offset,
              annotationId: note.id,
              note: note.kind != FlutterNoteEntryKind.highlight,
            ),
    );
  }

  /// Opens the search palette over whatever shows, on the book being read
  /// when there is one, and reads the hit chosen in it.
  Future<void> _openSearch() async {
    if (!mounted || _searchRoute != null) return;
    final shell = _shell.model;
    _search.dispatch(
      ShellSearchOpened(book: shell.reading ? shell.currentBook?.book : null),
    );
    final navigator = Navigator.of(context);
    final route = RawDialogRoute<ShellSearchChoice>(
      barrierDismissible: true,
      barrierLabel: AppLocalizations.of(context).shellSearchClose,
      barrierColor: ShellPalette.of(context).dark
          ? ShosaiTokens.colorDarkScrim
          : ShosaiTokens.colorLightScrim,
      pageBuilder: (context, _, _) => LayoutBuilder(
        builder: (context, constraints) => ListenableBuilder(
          listenable: _search,
          builder: (context, _) => ShellSearchPalette(
            layout: ShellLayout.forWidth(constraints.maxWidth),
            model: _search.model,
            onQuery: (query) =>
                _search.dispatch(ShellSearchQueryChanged(query)),
            onScope: (scope) =>
                _search.dispatch(ShellSearchScopeChanged(scope)),
            onFilter: (filter) =>
                _search.dispatch(ShellSearchFilterChanged(filter)),
            onChosen: (choice) => Navigator.of(context).pop(choice),
            onClose: () => Navigator.of(context).pop(),
          ),
        ),
      ),
    );
    _searchRoute = route;
    _dialogRoutes.add(route);
    final ShellSearchChoice? choice;
    try {
      choice = await navigator.push(route);
    } finally {
      _dialogRoutes.remove(route);
      _searchRoute = null;
    }
    if (!mounted || choice == null) return;
    final (book, place) = choice;
    _openBookAt(
      book,
      place == null
          ? null
          : ReaderPlace(
              place.unit,
              offset: place.offset,
              length: place.length,
              annotationId: place.annotationId,
              note: place.note,
            ),
    );
  }

  /// Ctrl+K or ⌘K, or `/` outside a text field, opens the search palette from
  /// any screen.
  KeyEventResult _searchShortcut(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    final command = keyboard.isControlPressed || keyboard.isMetaPressed;
    final key = event.logicalKey;
    final open =
        (command && !keyboard.isAltPressed && key == LogicalKeyboardKey.keyK) ||
        (!command &&
            !keyboard.isAltPressed &&
            key == LogicalKeyboardKey.slash &&
            !_typing());
    if (!open) return KeyEventResult.ignored;
    unawaited(_openSearch());
    return KeyEventResult.handled;
  }

  /// Whether the focused widget takes text, where `/` is typed.
  bool _typing() {
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused == null) return false;
    return focused.widget is EditableText ||
        focused.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  /// [child] with the search shortcuts.
  Widget _searchShortcuts(Widget child) => Focus(
    // Focused while nothing inside is, so the keys still reach it.
    autofocus: true,
    skipTraversal: true,
    onKeyEvent: _searchShortcut,
    child: child,
  );

  /// Reads [book] at [place], or where it was left when [place] is null: the
  /// reader showing it goes there, and another opens there.
  void _openBookAt(FlutterLibraryBook book, ReaderPlace? place) {
    // The book's tab may hold another document its reader opened in the
    // book's place; the place is this book's, so the tab is bound back to it
    // and its reader built again.
    final entry = _shell.model.openBooks
        .where((open) => open.id == book.bookId)
        .firstOrNull;
    final rebound =
        entry != null &&
        (entry.path != book.pathKey || entry.bookId != book.bookId);
    if (rebound) {
      if (_reader?.$1 == book.bookId) _reader = null;
      _shell.dispatch(
        ShellLocatorChanged(
          book.bookId,
          path: book.pathKey,
          bookId: book.bookId,
        ),
      );
    }
    final shell = _shell.model;
    if (shell.reading) {
      if (_reader case (
        final id,
        _,
        final requests,
      ) when id == book.bookId && shell.currentBookId == id) {
        if (place != null) requests.go(place);
        return;
      }
      _openAt = place == null
          ? null
          : (book.bookId, _wayBackTo(shell.currentBook, book, place));
      // The library's open effect is still waiting on the reader, so the
      // shell opens or focuses the book itself.
      _shell.dispatch(ShellBookOpened(book));
      return;
    }
    _openAt = place == null ? null : (book.bookId, place);
    controller.dispatch(LibraryBookOpened(book));
    // A library that is busy refuses the open; the place goes with it.
    if (!_shell.model.reading) _openAt = null;
  }

  /// [place] in [to], opened from [from], the book being read, with the way
  /// Back leads from it: to [from] where it is read, then through the return
  /// points [from] had, or, when [place] is itself a Back, the ones it
  /// carries. Each point names the book it is in, except [to]'s own.
  ReaderPlace _wayBackTo(
    OpenBook? from,
    FlutterLibraryBook to,
    ReaderPlace place,
  ) {
    // A tab can temporarily show a document opened by path. Its reader's
    // return points belong to that document, not to the library book that
    // owns the tab, so do not mislabel them as places in the book.
    final fromOwnBook =
        from != null &&
        from.path == from.book.pathKey &&
        from.bookId == from.book.bookId;
    final points =
        place.returnPoints ??
        switch (_reader) {
          (final id, _, final requests) when fromOwnBook && id == from.id =>
            requests.wayBack?.call(),
          _ => null,
        };
    if (points == null || from == null) return place;
    return ReaderPlace(
      place.unit,
      offset: place.offset,
      length: place.length,
      annotationId: place.annotationId,
      note: place.note,
      returnPoints: [
        for (final point in points)
          (
            unit: point.unit,
            offset: point.offset,
            book: switch (point.book) {
              null => from.book,
              final book when book.bookId == to.bookId => null,
              final book => book,
            },
          ),
      ],
    );
  }

  void _scheduleRestoredOpen() {
    if ((_pendingRestoredSession != null || _pendingResume != null) &&
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
        if (restored != null) {
          final before = _shell.model;
          _shell.dispatch(ShellRestored(restored.model));
          // A shell that already had books refused the session, and its
          // reader with it.
          if (restored.reading && !identical(_shell.model, before)) {
            _pendingResume = restored.model.currentBookId;
          }
        }
        final resume = _pendingResume;
        _pendingResume = null;
        final open = _shell.model.currentBook;
        if (resume != null && !_shell.model.reading && open?.id == resume) {
          controller.dispatch(LibraryBookOpened(open!.book));
        }
      });
    }
  }

  void _schedulePendingLibraryAction() {
    final action = _pendingLibraryAction;
    if (action == null ||
        _shell.model.reading ||
        !controller.model.loaded ||
        controller.model.busy) {
      return;
    }
    _pendingLibraryAction = null;
    scheduleMicrotask(() {
      if (mounted) controller.dispatch(action);
    });
  }

  @override
  String get restorationId => 'product-shell';

  @override
  void restoreState(RestorationBucket? oldBucket, bool initialRestore) {
    registerForRestoration(_session, 'open-books');
    if (_session.value case final encoded?) {
      _platformRestored = true;
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
    // The first restoration has run by now, so the saved open books know
    // whether a newer session came back.
    if (!_started) {
      _started = true;
      _shell.dispatch(ShellStarted(restoring: _platformRestored));
    }
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
    final sessionBridge = _sessionBridge;
    unawaited(_shell.openBooksSaved.whenComplete(sessionBridge.dispose));
    _notes.removeListener(_notesChanged);
    _notes.dispose();
    _search.dispose();
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
      builder: (_) => _searchShortcuts(
        ListenableBuilder(
          listenable: Listenable.merge([_shell, controller]),
          builder: (context, _) => _readerFrame(),
        ),
      ),
    );
    _readerRoute = route;
    try {
      unawaited(Navigator.of(context).push<void>(route));
      await route.completed;
    } finally {
      if (identical(_readerRoute, route)) _readerRoute = null;
      _reader = null;
      _openAt = null;
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
        pages: _shell.pages,
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
  /// alert is under the reader's route, and a Display change made in the
  /// reader is lost on the next launch unless it is saved. It stays until a retry
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
    if (_reader case (final id, final reader, _) when id == open.id) {
      return reader;
    }
    _shownBooks.add(open.id);
    // A note in the reader's All books opens its own book here.
    final requests = ReaderPlaceRequests(
      openSearch: () => unawaited(_openSearch()),
      openBook: (book, place) {
        // The reader can report twice before Flutter replaces it, or report
        // after it has become stale. Only the reader still current may move
        // the shell; otherwise a later callback can overwrite the way Back.
        if (mounted &&
            _shell.model.currentBookId == open.id &&
            _reader?.$1 == open.id) {
          _openBookAt(book, place);
        }
      },
    );
    if (_openAt case (final id, final place) when id == open.id) {
      requests.go(place);
      _openAt = null;
    }
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
        // The Display settings are saved with the library's settings, so the
        // next book opens with them too.
        (change) {
          if (mounted) {
            controller.dispatch(
              LibraryDisplayChanged(
                theme: change.theme,
                fontSize: change.fontSize,
                lineSpacing: change.lineSpacing,
                twoPages: change.twoPages,
                animations: change.animations,
                progress: change.progress,
                zonesHintDismissed: change.zonesHintDismissed,
              ),
            );
          }
        },
        requests,
      ),
    );
    _reader = (open.id, reader, requests);
    return reader;
  }

  ShellActions get _shellActions => ShellActions(
    // Search is a palette over the screen, not a place of its own.
    selectPlace: (place) => place == ShellPlace.search
        ? unawaited(_openSearch())
        : _shell.dispatch(ShellPlaceSelected(place)),
    openBook: (open) => _shell.model.reading
        ? _shell.dispatch(ShellBookActivated(open.id))
        : controller.dispatch(LibraryBookOpened(open.book)),
    closeBook: (open) => _shell.dispatch(ShellBookClosed(open.id)),
    moveBook: (from, to) => _shell.dispatch(ShellBookMoved(from, to)),
    addBooks: _shell.model.reading
        ? () {
            _pendingLibraryAction = const LibraryImportRequested();
            _shell.dispatch(const ShellPlaceSelected(ShellPlace.library));
          }
        : controller.model.busy
        ? null
        : () => controller.dispatch(const LibraryImportRequested()),
    loadCover: controller.requestCover,
    settings: () =>
        _shell.dispatch(const ShellPlaceSelected(ShellPlace.settings)),
    closeSwitcher: () => _shell.dispatch(const ShellSwitcherClosed()),
  );

  Future<LibraryImportSelection?> _pickImport() async {
    if (defaultTargetPlatform == TargetPlatform.android) {
      return _pickAndroidImport();
    }
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return _pickIosImport();
    }
    final directory = await _showOwnedDialog<bool>(
      (context) => ShadDialog(
        title: Text(AppLocalizations.of(context).addBooksAction),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _DialogActionTile(
              icon: LucideIcons.file,
              title: AppLocalizations.of(context).importChooseFiles,
              subtitle: AppLocalizations.of(context).importChooseFilesHint,
              onPressed: () => Navigator.pop(context, false),
            ),
            _DialogActionTile(
              icon: LucideIcons.folder,
              title: AppLocalizations.of(context).importChooseFolder,
              subtitle: AppLocalizations.of(context).importChooseFolderHint,
              onPressed: () => Navigator.pop(context, true),
            ),
          ],
        ),
      ),
    );
    if (directory == null || !mounted) return null;
    final l10n = AppLocalizations.of(context);
    final paths = directory
        ? [
            await getDirectoryPath(confirmButtonText: l10n.importReviewBooks),
          ].whereType<String>().toList()
        : (await openFiles(
            acceptedTypeGroups: [
              XTypeGroup(
                label: l10n.importBooksType,
                extensions: ['pdf', 'epub'],
              ),
            ],
            confirmButtonText: l10n.importReviewBooks,
          )).map((file) => file.path).toList();
    if (paths.isEmpty || !mounted) return null;
    return _reviewImport(paths, directory: directory);
  }

  /// iOS opens the system document picker, which copies each chosen book
  /// into the app's inbox. The library keeps its own copy, so the inbox
  /// copies are deleted once the import has run or been declined.
  Future<LibraryImportSelection?> _pickIosImport() async {
    final l10n = AppLocalizations.of(context);
    final paths = (await openFiles(
      acceptedTypeGroups: [
        XTypeGroup(
          label: l10n.importBooksType,
          extensions: ['pdf', 'epub'],
          // iOS filters by UTI rather than extension.
          uniformTypeIdentifiers: ['com.adobe.pdf', 'org.idpf.epub-container'],
        ),
      ],
      confirmButtonText: l10n.importReviewBooks,
    )).map((file) => file.path).toList(growable: false);
    if (paths.isEmpty) return null;
    final reviewed = mounted
        ? await _reviewImport(paths, directory: false, managedOnly: true)
        : null;
    if (reviewed == null) {
      await _openedDocuments.discard(paths);
      return null;
    }
    return LibraryImportSelection(
      paths: reviewed.paths,
      managed: true,
      cleanup: () => _openedDocuments.discard(paths),
    );
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
      if (!mounted) return null;
      throw SafeUserError(
        documentImportErrorText(error, AppLocalizations.of(context)),
      );
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
    final l10n = AppLocalizations.of(context);
    return _showOwnedDialog<LibraryImportSelection>(
      (context) => StatefulBuilder(
        builder: (context, setState) => ShadDialog(
          title: Text(
            directory ? l10n.importReviewFolder : l10n.importReviewBooks,
          ),
          actions: [
            ShadButton.outline(
              height: shosaiShadButtonHeight(context),
              onPressed: () => Navigator.pop(context),
              child: Text(l10n.cancelImportAction),
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
              child: Text(l10n.importAction),
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
                  title: l10n.importManagedCopy,
                  subtitle: managedOnly
                      ? l10n.importPickedCopyHint
                      : managed
                      ? l10n.importPrivateCopyHint
                      : l10n.importLinkedCopyHint,
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

  Future<void> _manageLocations() async {
    final host = _sessionBridge;
    if (host is! LibraryFoldersHost) return;
    final folders = FoldersController(
      folders: (host as LibraryFoldersHost).folders,
      setup: (id) => (host as LibraryFoldersHost).folders.setup('folder', id),
      setupDropbox: (id) async {
        if (DropboxConnectionProvider.defaultClientId.isEmpty) {
          await _showOwnedDialog<void>(
            (context) => ShadDialog.alert(
              title: Text(AppLocalizations.of(context).dropboxConnect),
              description: Text(
                AppLocalizations.of(context).dropboxRegistrationRequired,
              ),
              actions: [
                ShadButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(AppLocalizations.of(context).locationClose),
                ),
              ],
            ),
          );
          return null;
        }
        return DropboxConnectionProvider(
          credentials: const PlatformConnectionCredentialStore(),
          authorizeNative: DropboxAuthorization.supported
              ? DropboxAuthorization(
                  cancellationTitle: AppLocalizations.of(
                    context,
                  ).dropboxCancelTitle,
                  cancelAction: AppLocalizations.of(
                    context,
                  ).dropboxCancelConnection,
                  keepWaitingAction: AppLocalizations.of(
                    context,
                  ).dropboxKeepWaiting,
                ).authorize
              : null,
          authorize: (authorization) async {
            if (!await launchUrl(
              authorization,
              mode: LaunchMode.externalApplication,
            )) {
              throw StateError('The system browser could not be opened.');
            }
            if (!mounted) return null;
            return _showOwnedDialog<String>((_) => const DropboxCodeDialog());
          },
        ).setup(id);
      },
      setupGoogleDrive: (id) =>
          (host as LibraryFoldersHost).folders.setup('google-drive', id),
      confirmRemoval: (grant) async =>
          await _showOwnedDialog<bool>((context) {
            final l10n = AppLocalizations.of(context);
            return ShadDialog.alert(
              title: Text(l10n.locationRemove),
              description: Text(l10n.locationRemoveDescription),
              actions: [
                ShadButton.outline(
                  onPressed: () => Navigator.pop(context, false),
                  child: Text(l10n.locationCancel),
                ),
                ShadButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: Text(l10n.locationRemove),
                ),
              ],
            );
          }) ??
          false,
    )..dispatch(const FoldersStarted());
    try {
      await _showOwnedDialog<void>(
        (_) => LibraryFoldersDialog(controller: folders),
      );
    } finally {
      folders.dispose();
      await folders.drain();
    }
  }

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
      body: _searchShortcuts(
        LayoutBuilder(
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
                  : shell.place == ShellPlace.notes
                  ? ListenableBuilder(
                      listenable: _notes,
                      builder: (context, _) => ShellNotesPage(
                        layout: layout,
                        model: _notes.model,
                        onOpen: _openNote,
                        onRetry: () =>
                            _notes.dispatch(const ShellNotesRequested()),
                        onMore: () =>
                            _notes.dispatch(const ShellNotesMoreRequested()),
                      ),
                    )
                  : shell.place == ShellPlace.settings
                  ? _SettingsPage(
                      layout: layout,
                      model: controller.model,
                      onChanged: (value) =>
                          controller.dispatch(LibrarySettingsChanged(value)),
                      onConnections: _sessionBridge is LibraryFoldersHost
                          ? () => controller.dispatch(
                              const LibraryConnectionsRequested(),
                            )
                          : null,
                      onRetry: () => controller.dispatch(
                        const LibrarySettingsSaveRetried(),
                      ),
                    )
                  : ShellPlacePage(layout: layout, place: shell.place),
            );
          },
        ),
      ),
    );
  }

  /// The Library place: the header and format filters, then the
  /// collection; on a phone the open books lead as Reading now cards.
  Widget _libraryPlace(ShellLayout layout) {
    final model = controller.model;
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
            openSourceFile: (file) =>
                controller.dispatch(LibrarySourceFileOpened(file)),
            openNotes: () =>
                _shell.dispatch(const ShellPlaceSelected(ShellPlace.notes)),
            removeBook: (book) =>
                controller.dispatch(LibraryBookRemovalRequested(book)),
            keepBook: (book) =>
                controller.dispatch(LibraryBookKeepRequested(book)),
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
