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

typedef SelectionCopier = Future<void> Function(String text);
typedef ReaderSelectionAnnouncer = Future<void> Function(String description);

const _unchanged = Object();
final _frozenSurfaces = Expando<bool>();
final _frozenAnnotations = Expando<bool>();
