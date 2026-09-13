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
