import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shosai_flutter/app_theme.dart';
import 'package:shosai_flutter/reader/controller.dart';
import 'package:shosai_flutter/shared/shad_widgets.dart';
import 'package:shosai_flutter/src/rust/api.dart';
import 'package:shosai_flutter/theme_tokens.dart';

part 'geometry.dart';
part 'painting.dart';
part 'view_dialogs.dart';
part 'view_document.dart';
part 'view_selection.dart';

class ReaderScreen extends StatefulWidget {
  const ReaderScreen({
    super.key,
    this.bridge,
    this.bridgeFactory,
    this.decoder = _decodeRgba,
    this.initialPath,
    this.initialBookId,
    this.initialSettings,
    this.onLocatorChanged,
  }) : assert(bridge == null || bridgeFactory == null);

  final FlutterBridge? bridge;
  final FlutterBridge Function()? bridgeFactory;
  final PageDecoder decoder;
  final String? initialPath;
  final int? initialBookId;
  final FlutterReaderSettings? initialSettings;
  final void Function(String path, int? bookId)? onLocatorChanged;

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen>
    with WidgetsBindingObserver, RestorationMixin {
  final RestorableTextEditingController _path =
      RestorableTextEditingController();
  final RestorableStringN _openDocumentPath = RestorableStringN(null);
  final RestorableIntN _openDocumentBookId = RestorableIntN(null);
  final GlobalKey _pathFieldKey = GlobalKey(debugLabel: 'document path');
  final GlobalKey _contentKey = GlobalKey(debugLabel: 'reader content');
  final FocusNode _openFocus = FocusNode(debugLabel: 'open document');
  final FocusNode _readerFocus = FocusNode(debugLabel: 'reader surface');
  final FocusNode _actionFocus = FocusNode(debugLabel: 'selection actions');
  ShadDialogRoute<String>? _noteDialogRoute;
  ShadDialogRoute<AnnotationAssociationChoice>? _associationDialogRoute;
  late final ReaderController _controller;
  bool _controllerInitialized = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    if (!_controllerInitialized) {
      _controllerInitialized = true;
      _controller = ReaderController(
        bridge:
            widget.bridge ?? widget.bridgeFactory?.call() ?? FlutterBridge(),
        decoder: (pixels, {required width, required height}) =>
            widget.decoder(pixels, width: width, height: height),
        initialScale: (widget.initialSettings?.pdfZoom ?? 0) > 0
            ? widget.initialSettings!.pdfZoom
            : View.of(context).devicePixelRatio,
        initialLineSpacing: widget.initialSettings?.epubLineSpacing ?? 1.5,
        noteEditor: _editNote,
        bookmarkNoteEditor: _editBookmarkNote,
        noteEditorCanceller: _cancelNoteEditor,
        annotationAssociationPicker: _pickAnnotationAssociation,
        annotationAssociationPickerCanceller:
            _cancelAnnotationAssociationPicker,
        focusAdapter: (target) => switch (target) {
          ReaderFocusTarget.surface => _readerFocus.requestFocus(),
          ReaderFocusTarget.actions => _actionFocus.requestFocus(),
        },
        frameScheduler: (callback) =>
            WidgetsBinding.instance.addPostFrameCallback((_) => callback()),
        selectionCopier: (text) => Clipboard.setData(ClipboardData(text: text)),
        selectionAnnouncer:
            usesExplicitSelectionAnnouncements(defaultTargetPlatform)
            ? (description) => SemanticsService.sendAnnouncement(
                View.of(context),
                description,
                Directionality.of(context),
              )
            : null,
      )..addListener(_modelChanged);
    }
    super.didChangeDependencies();
  }

  @override
  String get restorationId => 'reader';

  @override
  void restoreState(RestorationBucket? oldBucket, bool initialRestore) {
    registerForRestoration(_path, 'document_path');
    registerForRestoration(_openDocumentPath, 'open_document_path');
    registerForRestoration(_openDocumentBookId, 'open_document_book_id');
    if (_openDocumentPath.value case final path?) {
      _controller.dispatch(
        ReaderOpenRequested(path, bookId: _openDocumentBookId.value),
      );
    } else if (widget.initialPath case final path?) {
      _path.value.text = path;
      _controller.dispatch(
        ReaderOpenRequested(path, bookId: widget.initialBookId),
      );
    }
  }

  Future<String?> _editNote(String? initialValue) =>
      _showNoteEditor(initialValue, title: 'Highlight note');

  Future<String?> _editBookmarkNote(String? initialValue) =>
      _showNoteEditor(initialValue, title: 'Bookmark note');

  Future<String?> _showNoteEditor(
    String? initialValue, {
    required String title,
  }) async {
    final navigator = Navigator.of(context, rootNavigator: true);
    final readerTheme = _readerTheme(context, widget.initialSettings?.theme);
    final route = ShadDialogRoute<String>(
      pageBuilder: (context) => Theme(
        data: readerTheme,
        child: ShadTheme(
          data: shosaiReaderShadTheme(widget.initialSettings?.theme),
          child: _NoteDialog(initialValue: initialValue, title: title),
        ),
      ),
      barrierDismissible: true,
      barrierLabel: '',
    );
    _noteDialogRoute = route;
    try {
      return await navigator.push(route);
    } finally {
      if (identical(_noteDialogRoute, route)) _noteDialogRoute = null;
    }
  }

  void _cancelNoteEditor() {
    final route = _noteDialogRoute;
    _noteDialogRoute = null;
    if (route == null) return;
    scheduleMicrotask(() {
      final navigator = route.navigator;
      if (route.isActive && navigator != null) navigator.removeRoute(route);
    });
  }

  Future<AnnotationAssociationChoice> _pickAnnotationAssociation(
    AnnotationAssociationPage page,
  ) async {
    final navigator = Navigator.of(context, rootNavigator: true);
    final readerTheme = _readerTheme(context, widget.initialSettings?.theme);
    final route = ShadDialogRoute<AnnotationAssociationChoice>(
      pageBuilder: (context) => Theme(
        data: readerTheme,
        child: ShadTheme(
          data: shosaiReaderShadTheme(widget.initialSettings?.theme),
          child: _AnnotationAssociationDialog(page: page),
        ),
      ),
      barrierDismissible: true,
      barrierLabel: '',
    );
    _associationDialogRoute = route;
    try {
      return await navigator.push(route) ??
          const AnnotationAssociationCancelled();
    } finally {
      if (identical(_associationDialogRoute, route)) {
        _associationDialogRoute = null;
      }
    }
  }

  void _cancelAnnotationAssociationPicker() {
    final route = _associationDialogRoute;
    _associationDialogRoute = null;
    if (route == null) return;
    scheduleMicrotask(() {
      final navigator = route.navigator;
      if (route.isActive && navigator != null) navigator.removeRoute(route);
    });
  }

  void _modelChanged() {
    final openPath = _controller.model.openPath;
    if (openPath != null) {
      // Persist the accepted locator as one pair. In particular, clear a
      // previous library identity while an untracked replacement is opening
      // and leave it cleared if that replacement fails.
      final bookId = _controller.model.openBookId;
      if (_openDocumentPath.value != openPath ||
          _openDocumentBookId.value != bookId) {
        _openDocumentPath.value = openPath;
        _openDocumentBookId.value = bookId;
        widget.onLocatorChanged?.call(openPath, bookId);
      }
    }
    setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _controller.dispatch(const ReaderResumed());
      case AppLifecycleState.hidden ||
          AppLifecycleState.paused ||
          AppLifecycleState.detached:
        _controller.dispatch(const ReaderSuspended());
      case AppLifecycleState.inactive:
        break;
    }
  }

  @override
  void didHaveMemoryPressure() {
    _controller.dispatch(const ReaderMemoryPressureReceived());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.removeListener(_modelChanged);
    _controller.dispose();
    _path.dispose();
    _openDocumentPath.dispose();
    _openDocumentBookId.dispose();
    _openFocus.dispose();
    _readerFocus.dispose();
    _actionFocus.dispose();
    super.dispose();
  }

  void _open() {
    final path = _path.value.text.trim();
    _controller.dispatch(ReaderOpenRequested(path));
  }

  @override
  Widget build(BuildContext context) {
    final model = _controller.model;
    final compact = MediaQuery.sizeOf(context).width < 600;
    final associationEnabled =
        !model.busy &&
        model.annotationOperations.isEmpty &&
        !model.relayoutBusy;
    final theme = _readerTheme(context, widget.initialSettings?.theme);
    return Theme(
      data: theme,
      child: ShadTheme(
        data: shosaiReaderShadTheme(widget.initialSettings?.theme),
        child: Scaffold(
          appBar: AppBar(
            title: Text(
              compact ? 'Shōsai' : model.document?.title ?? 'Shōsai Reader',
            ),
            actions: model.document != null
                ? [
                    ShadIconAction(
                      tooltip: 'Search and bookmarks',
                      onPressed: () =>
                          _controller.dispatch(const ReaderToolsToggled()),
                      icon: const Icon(LucideIcons.search),
                    ),
                    if (model.document!.format != FlutterBookFormat.cbz)
                      ShadIconAction(
                        tooltip: model.annotationsReady
                            ? 'Associate highlights from an earlier version…'
                            : 'Retry loading highlights',
                        onPressed: associationEnabled
                            ? () => _controller.dispatch(
                                model.annotationsReady
                                    ? const ReaderAnnotationAssociationRequested()
                                    : const ReaderAnnotationReloadRequested(),
                              )
                            : null,
                        icon: Icon(
                          model.annotationsReady
                              ? LucideIcons.link
                              : LucideIcons.refreshCw,
                        ),
                      ),
                  ]
                : null,
          ),
          body: SafeArea(
            child: _ResponsiveReaderBody(
              model: model,
              settings: widget.initialSettings,
              path: _path.value,
              pathFieldKey: _pathFieldKey,
              contentKey: _contentKey,
              openFocus: _openFocus,
              open: _open,
              dispatch: _controller.dispatch,
              readerFocus: _readerFocus,
              actionFocus: _actionFocus,
            ),
          ),
        ),
      ),
    );
  }
}

/// The reader's Material theme, mapped from the shared design tokens.
///
/// The page and surface colors are the pinned Iced reader palettes, so
/// [pageColors] reads the document palette for the active reader theme; the
/// pre-2C brown seed is rejected by plan decision 2.
ThemeData _readerTheme(BuildContext context, String? theme) =>
    shosaiReaderMaterialTheme(context, theme);

enum _ReaderComposition { compact, medium, expanded }

class _ResponsiveReaderBody extends StatelessWidget {
  const _ResponsiveReaderBody({
    required this.model,
    required this.settings,
    required this.path,
    required this.pathFieldKey,
    required this.contentKey,
    required this.openFocus,
    required this.open,
    required this.dispatch,
    required this.readerFocus,
    required this.actionFocus,
  });

  final ReaderModel model;
  final FlutterReaderSettings? settings;
  final TextEditingController path;
  final GlobalKey pathFieldKey;
  final GlobalKey contentKey;
  final FocusNode openFocus;
  final VoidCallback open;
  final void Function(ReaderMessage) dispatch;
  final FocusNode readerFocus;
  final FocusNode actionFocus;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final composition = constraints.maxWidth >= 1024
          ? _ReaderComposition.expanded
          : constraints.maxWidth >= 600
          ? _ReaderComposition.medium
          : _ReaderComposition.compact;
      final controls = _ReaderControls(
        model: model,
        path: path,
        pathFieldKey: pathFieldKey,
        openFocus: openFocus,
        open: open,
        horizontal: composition == _ReaderComposition.medium,
      );
      final content = _ReaderContentPane(
        key: contentKey,
        model: model,
        settings: settings,
        dispatch: dispatch,
        readerFocus: readerFocus,
        actionFocus: actionFocus,
      );
      final key = ValueKey('reader-composition-${composition.name}');
      if (composition == _ReaderComposition.expanded) {
        return Padding(
          key: key,
          padding: const EdgeInsets.all(24),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 320,
                child: SingleChildScrollView(child: controls),
              ),
              const SizedBox(width: 24),
              Expanded(child: content),
            ],
          ),
        );
      }
      return Padding(
        key: key,
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            controls,
            const SizedBox(height: 20),
            Expanded(child: content),
          ],
        ),
      );
    },
  );
}

class _ReaderControls extends StatelessWidget {
  const _ReaderControls({
    required this.model,
    required this.path,
    required this.pathFieldKey,
    required this.openFocus,
    required this.open,
    required this.horizontal,
  });

  final ReaderModel model;
  final TextEditingController path;
  final GlobalKey pathFieldKey;
  final FocusNode openFocus;
  final VoidCallback open;
  final bool horizontal;

  @override
  Widget build(BuildContext context) {
    final field = Semantics(
      textField: true,
      label: 'Document path',
      child: ShadInput(
        key: pathFieldKey,
        controller: path,
        enabled: !model.busy,
        onSubmitted: (_) => open(),
        placeholder: const Text('/path/to/book.pdf'),
      ),
    );
    final button = ShadButton(
      height: shosaiShadButtonHeight(context),
      focusNode: openFocus,
      onPressed: model.busy ? null : open,
      leading: const Icon(LucideIcons.bookOpen),
      child: Flexible(
        child: Text(
          model.busy ? 'Opening…' : 'Open document',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (horizontal)
          Row(
            children: [
              Expanded(child: field),
              const SizedBox(width: 12),
              button,
            ],
          )
        else ...[
          field,
          const SizedBox(height: 12),
          Align(alignment: Alignment.centerLeft, child: button),
        ],
        if (model.error != null) ...[
          const SizedBox(height: 12),
          Semantics(
            liveRegion: true,
            child: Text(
              model.error!,
              style: TextStyle(
                color: ShadTheme.of(context).colorScheme.destructive,
              ),
            ),
          ),
        ],
        if (model.selectionError != null && model.document != null)
          Semantics(
            liveRegion: true,
            child: Text('Selection unavailable: ${model.selectionError}'),
          ),
        if (model.selectionActionError != null && model.document != null)
          Semantics(
            liveRegion: true,
            child: Text(
              'Selection action failed: ${model.selectionActionError}',
            ),
          ),
        if (model.annotationError != null && model.document != null)
          Semantics(
            liveRegion: true,
            child: Text(
              model.annotationsReady
                  ? 'Highlight action failed: ${model.annotationError}'
                  : 'Highlights unavailable: ${model.annotationError}',
            ),
          ),
        if (model.relayoutBusy) const ShadProgress(minHeight: 4),
      ],
    );
  }
}

class _ReaderContentPane extends StatelessWidget {
  const _ReaderContentPane({
    super.key,
    required this.model,
    required this.settings,
    required this.dispatch,
    required this.readerFocus,
    required this.actionFocus,
  });

  final ReaderModel model;
  final FlutterReaderSettings? settings;
  final void Function(ReaderMessage) dispatch;
  final FocusNode readerFocus;
  final FocusNode actionFocus;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Expanded(
        child: _ReaderLayoutReporter(
          model: model,
          settings: settings,
          dispatch: dispatch,
          child: model.document == null
              ? const WelcomePanel()
              : _DocumentView(
                  document: model.document!,
                  image: model.pageImage,
                  model: model,
                  settings: settings,
                  dispatch: dispatch,
                  readerFocus: readerFocus,
                  actionFocus: actionFocus,
                ),
        ),
      ),
      Semantics(
        key: const ValueKey('reader-selection-status'),
        container: true,
        liveRegion: true,
        label: model.selectionDescription,
        child: const SizedBox(width: double.infinity, height: 1),
      ),
    ],
  );
}

class _ReaderLayoutReporter extends StatefulWidget {
  const _ReaderLayoutReporter({
    required this.model,
    required this.settings,
    required this.dispatch,
    required this.child,
  });

  final ReaderModel model;
  final FlutterReaderSettings? settings;
  final void Function(ReaderMessage) dispatch;
  final Widget child;

  @override
  State<_ReaderLayoutReporter> createState() => _ReaderLayoutReporterState();
}

class _ReaderLayoutReporterState extends State<_ReaderLayoutReporter> {
  bool _scheduled = false;
  ReaderLayout? _observedLayout;
  ReaderLayout? _pendingLayout;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final availableWidth = constraints.maxWidth.isFinite
          ? math.max(1.0, constraints.maxWidth).roundToDouble()
          : widget.model.layout.width;
      final layout = ReaderLayout(
        scale: widget.model.document != null
            ? widget.model.layout.scale
            : (widget.settings?.pdfZoom ?? 0) > 0
            ? widget.settings!.pdfZoom
            : MediaQuery.devicePixelRatioOf(context),
        width: availableWidth,
        fontSize: MediaQuery.textScalerOf(
          context,
        ).scale(widget.settings?.epubFontSize ?? 18),
        lineSpacing: widget.settings?.epubLineSpacing ?? 1.5,
      );
      if (layout != _observedLayout) {
        _observedLayout = layout;
        _pendingLayout = layout;
      }
      if (_pendingLayout != null && !_scheduled) {
        _scheduled = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _scheduled = false;
          final pending = _pendingLayout;
          _pendingLayout = null;
          if (mounted && pending != null) {
            widget.dispatch(ReaderViewportChanged(pending));
          }
        });
      }
      return widget.child;
    },
  );
}

class WelcomePanel extends StatelessWidget {
  const WelcomePanel({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Text(
        'Enter a local document path to exercise the generated Rust bridge.',
        textAlign: TextAlign.center,
      ),
    );
  }
}

bool usesExplicitSelectionAnnouncements(TargetPlatform platform) =>
    platform == TargetPlatform.linux ||
    platform == TargetPlatform.macOS ||
    platform == TargetPlatform.windows;

Future<ui.Image> _decodeRgba(
  Uint8List pixels, {
  required int width,
  required int height,
}) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(pixels);
  try {
    final descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: width,
      height: height,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    try {
      final codec = await descriptor.instantiateCodec();
      try {
        return (await codec.getNextFrame()).image;
      } finally {
        codec.dispose();
      }
    } finally {
      descriptor.dispose();
    }
  } finally {
    buffer.dispose();
  }
}
