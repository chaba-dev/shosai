part of 'controller.dart';

typedef PageDecoder =
    Future<ui.Image> Function(
      Uint8List pixels, {
      required int width,
      required int height,
    });

typedef NoteEditor = Future<String?> Function(String? initialValue);
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

/// Brings a tab strip entry fully into view.
///
/// The widget owns the Flutter `ScrollController` that implements this; the
/// controller decides *when* a reveal happens (after the initial layout, after
/// the active tab changes, after a close and after a resize) and never the
/// widget.
typedef ReaderTabRevealAdapter = Future<void> Function(String tabId);

/// Supplies the 4B progress ordinals for a loaded document (RD-05).
///
/// The fixture supplies them in 4B; 5G supplies real renderer values. The
/// controller applies the `none`/`loading` precedence before consulting this
/// source, so a fixture cannot bypass it.
typedef ReaderProgressSource =
    ReaderProgressPresentation Function(ReaderModel model);

/// Supplies the Contents entries for a loaded document (RD-07).
///
/// The fixture supplies them in 4C because the bridge exposes no TOC DTO; the
/// default loader renders the EPUB chapter fallback (contract §4.6). The
/// controller owns the guarded effect and rejects stale completions.
typedef ReaderContentsLoader =
    Future<List<ReaderContentsEntry>> Function(FlutterDocumentSummary document);

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

  @override
  bool operator ==(Object other) =>
      other is _EpubLayoutKey &&
      other.generation == generation &&
      other.unit == unit &&
      other.width == width &&
      other.height == height &&
      other.fontSize == fontSize &&
      other.lineSpacing == lineSpacing &&
      other.theme == theme;

  @override
  int get hashCode => Object.hash(
    generation,
    unit,
    width,
    height,
    fontSize,
    lineSpacing,
    theme,
  );
}

typedef SelectionCopier = Future<void> Function(String text);
typedef ReaderSelectionAnnouncer = Future<void> Function(String description);

const _unchanged = Object();
final _frozenSurfaces = Expando<bool>();
final _frozenAnnotations = Expando<bool>();
