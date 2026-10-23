part of 'controller.dart';

typedef PageDecoder =
    Future<ui.Image> Function(
      Uint8List pixels, {
      required int width,
      required int height,
    });

typedef NoteEditor = Future<String?> Function(String? initialValue);

/// Writes the body of a new page note or book note; null when dismissed.
typedef PlaceNoteEditor = Future<String?> Function(FlutterNoteKind kind);
typedef NoteEditorCanceller = void Function();
typedef AnnotationAssociationPicker =
    Future<AnnotationAssociationChoice> Function(
      AnnotationAssociationPage page,
    );
typedef AnnotationAssociationPickerCanceller = void Function();
typedef ReaderFocusAdapter = void Function(ReaderFocusTarget target);
typedef ReaderFrameScheduler = void Function(VoidCallback callback);

/// Leaves the reader (the injected platform navigation effect).
///
/// The controller starts it; a widget never pops the route itself.
typedef ReaderNavigationAdapter = Future<void> Function();

/// Supplies the 4B progress ordinals for a loaded document (RD-05).
///
/// The fixture supplies them in 4B; 5G supplies real renderer values. The
/// controller applies the `none`/`loading` precedence before consulting this
/// source, so a fixture cannot bypass it.
typedef ReaderProgressSource =
    ReaderProgressPresentation Function(ReaderModel model);

/// Supplies the Contents entries for a loaded document (RD-07).
///
/// The injected loader is the fixture seam the panel tests use; production
/// leaves it null and the controller resolves the document's real table of
/// contents from the Dart EPUB engine (falling back to the EPUB chapter
/// fallback). The controller owns the guarded effect and rejects stale
/// completions.
typedef ReaderContentsLoader =
    Future<List<ReaderContentsEntry>> Function(FlutterDocumentSummary document);

/// Opens one allowed external link through the platform.
///
/// The controller classifies a rendered link's href and calls this adapter only
/// for the allowed schemes (`http`, `https`, `mailto`); `file`, `data`,
/// `javascript` and every other scheme never reach it, and the reader itself
/// never fetches a remote resource or resolves a book reference against the
/// network. The composition root injects the platform opener; a reader built
/// without one opens nothing.
typedef ReaderExternalLinkOpener = Future<void> Function(String url);

/// A document the more panel's open-book picker returned (RD-10).
final class ReaderPickedDocument {
  const ReaderPickedDocument(this.path, {this.bookId});

  final String path;
  final int? bookId;
}

/// Chooses a supported document for the more panel's open-book action (RD-10).
///
/// The shell injects the platform picker; a null result is a neutral
/// cancellation. The selected document opens through the normal open path.
typedef ReaderDocumentPickerAdapter = Future<ReaderPickedDocument?> Function();

/// Delivers the Markdown export text (RD-08).
///
/// The controller calls the injected adapter after `exportBookmarks` succeeds;
/// the screen's default copies the text to the clipboard. Choosing a save
/// location instead is a shell-level adapter swap, not a schema change.
typedef ReaderExportSink = Future<void> Function(String markdown);

/// Saves the Pages setting the reader chose: two pages side by side, or one.
///
/// The shell injects the library's settings writer, so later books open with
/// the same setting; a reader built without one keeps it for its session.
typedef ReaderPagesSink = void Function(bool twoPages);

/// Reports reader notices through the application notice center.
///
/// The reader route is outside the shell's `NoticeHost`, so the composition
/// root injects the center's reporter; a reader built without one reports
/// nothing.
typedef ReaderNoticeReporter = void Function(NoticeRequest request);

final class _QueuedReadingStateSave {
  const _QueuedReadingStateSave({required this.run, required this.discard});

  final Future<void> Function() run;
  final VoidCallback discard;
}

final class _ReadingStateSaveQueue {
  _ReadingStateSaveQueue(this.onDrained);

  final VoidCallback onDrained;
  final Completer<void> _drained = Completer<void>();
  _QueuedReadingStateSave? _pending;
  bool _running = false;

  Future<void> get drained => _drained.future;

  void add(_QueuedReadingStateSave save) {
    if (_running) {
      _pending?.discard();
      _pending = save;
      return;
    }
    _running = true;
    unawaited(_run(save));
  }

  Future<void> _run(_QueuedReadingStateSave save) async {
    var current = save;
    while (true) {
      await current.run();
      final pending = _pending;
      _pending = null;
      if (pending == null) break;
      current = pending;
    }
    _running = false;
    onDrained();
    _drained.complete();
  }
}

final class _BookWriteDrain {
  int pending = 0;
  Completer<void> drained = Completer<void>()..complete();

  void begin() {
    if (pending == 0) drained = Completer<void>();
    pending += 1;
  }

  bool finish() {
    pending -= 1;
    if (pending != 0) return false;
    drained.complete();
    return true;
  }
}

final class ReaderPersistenceException implements Exception {
  const ReaderPersistenceException(this.message);

  final String message;

  @override
  String toString() => message;
}

final class _RelayoutIntent {
  const _RelayoutIntent({
    required this.unit,
    required this.offset,
    required this.length,
    required this.replaceReadingOffset,
  });

  final int unit;
  final int? offset;
  final int? length;
  final bool replaceReadingOffset;
}

/// The layout identity of one Dart-rendered EPUB chapter.
///
/// A session is reused only when every input that changes its measured
/// geometry is equal: the page box, the typography, and the chapter. The
/// retained renderer's key stays width-based; the page height is part of this
/// key because pagination depends on it.
final class _EpubLayoutKey {
  const _EpubLayoutKey({
    required this.generation,
    required this.unit,
    required this.width,
    required this.height,
    required this.fontSize,
    required this.lineSpacing,
    required this.theme,
    required this.continuous,
    this.spread = false,
    this.vertical = false,
  });

  /// The document generation the session belongs to.
  ///
  /// The key must carry it: two documents can share a unit ordinal, a width and
  /// a typography, and a session measured from the first document's blocks
  /// would otherwise be reused for the second.
  final int generation;
  final int unit;
  final double width;
  final double height;
  final double fontSize;
  final double lineSpacing;
  final String theme;

  /// Whether the chapter is read continuously: one scrolled column whose
  /// laid-out window follows the viewport.
  final bool continuous;

  /// Whether [width] holds a two-page spread, so each page is laid out at
  /// [epubSpreadPageWidth] of it.
  final bool spread;

  /// Whether the chapter is vertical, so its pages are turned a quarter turn
  /// and its lines run down the page (see `EpubPageBox`).
  final bool vertical;

  /// The width one page is laid out at.
  double get pageWidth => spread ? epubSpreadPageWidth(width) : width;

  @override
  bool operator ==(Object other) =>
      other is _EpubLayoutKey &&
      other.generation == generation &&
      other.unit == unit &&
      other.width == width &&
      other.height == height &&
      other.fontSize == fontSize &&
      other.lineSpacing == lineSpacing &&
      other.theme == theme &&
      other.continuous == continuous &&
      other.spread == spread &&
      other.vertical == vertical;

  @override
  int get hashCode => Object.hash(
    generation,
    unit,
    width,
    height,
    fontSize,
    lineSpacing,
    theme,
    continuous,
    spread,
    vertical,
  );
}

typedef SelectionCopier = Future<void> Function(String text);
typedef ReaderSelectionAnnouncer = Future<void> Function(String description);

const _unchanged = Object();
final _frozenSurfaces = Expando<bool>();
final _frozenAnnotations = Expando<bool>();

/// Opens [book] at [place] (its saved position when null) in the shell.
typedef ReaderBookOpener =
    void Function(FlutterLibraryBook book, ReaderPlace? place);

/// Places the shell asks a reader to go to, such as a search hit's or a
/// note's, from outside it. The latest request wins: a reader still opening
/// opens there, and an open one goes there.
///
/// The other way, [openBook] is how the reader asks the shell to open another
/// book, such as one a note in All books sits in.
final class ReaderPlaceRequests extends ChangeNotifier {
  ReaderPlaceRequests({this.openSearch, this.openBook});

  /// Opens the shell's search palette, which the reader's Search action
  /// opens in its in-book search's stead.
  final VoidCallback? openSearch;

  /// Opens another book at a place, such as one a note in All books sits in.
  final ReaderBookOpener? openBook;

  /// The way Back leads from the reader showing the book
  /// ([ReaderController.wayBack]), which a book opened in its stead at a
  /// place starts with; the reader answers it while it shows.
  List<ReaderReturnPoint>? Function()? wayBack;

  ReaderPlace? _pending;

  /// Asks the reader to go to [place].
  void go(ReaderPlace place) {
    _pending = place;
    notifyListeners();
  }

  /// The request not yet taken, which the reader takes once.
  ReaderPlace? take() {
    final place = _pending;
    _pending = null;
    return place;
  }
}
