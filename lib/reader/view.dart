import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, listEquals, setEquals;
import 'package:flutter/gestures.dart' show GestureBinding, kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show OffsetLayer, PaintingContext, RenderRepaintBoundary;
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shosai_flutter/app_theme.dart';
import 'package:shosai_flutter/l10n/app_localizations.dart';
import 'package:shosai_flutter/reader/controller.dart';
import 'package:shosai_flutter/reader/epub/content.dart';
import 'package:shosai_flutter/reader/epub/continuous.dart';
import 'package:shosai_flutter/reader/epub/flow.dart';
import 'package:shosai_flutter/reader/epub/surface.dart';
import 'package:shosai_flutter/reader/pdf/spread.dart';
import 'package:shosai_flutter/shell/view.dart';
import 'package:shosai_flutter/core/bridge.dart';
import 'package:shosai_flutter/theme_tokens.dart';

part 'geometry.dart';
part 'painting.dart';
part 'view_chrome.dart';
part 'view_dialogs.dart';
part 'view_document.dart';
part 'view_notes.dart';
part 'view_panels.dart';
part 'view_selection.dart';
part 'view_stage.dart';
part 'view_toolbar.dart';

/// Viewport shares that bound the fixed reader chrome rows.
///
/// These are robustness bounds, not design values: the pinned reference fixes
/// no such limit. They only take effect on a viewport too short for the row (a
/// short window at a scaled interface), where the alternative is an overflow
/// that pushes the document out of reach. The alert and error surfaces keep the
/// pre-existing 0.15 bound.
const double _readerHeaderBoundShare = 0.3;
const double _readerSearchBoundShare = 0.4;
const double _readerAlertBoundShare = 0.15;
const double _readerStatusBoundShare = 0.2;
const double _readerDevEntryBoundShare = 0.4;

class ReaderScreen extends StatefulWidget {
  const ReaderScreen({
    super.key,
    this.bridge,
    this.bridgeFactory,
    this.decoder = _decodeRgba,
    this.initialPath,
    this.initialBookId,
    this.initialPlace,
    this.placeRequests,
    this.initialSettings,
    this.onLocatorChanged,
    this.progressSource,
    this.contentsLoader,
    this.externalLinkOpener,
    this.documentPicker,
    this.exportSink,
    this.onDisplayChanged,
    this.noticeReporter,
    this.epubImageDecoder,
    this.epubFontRegistrar,
    this.debugEpubSessionObserver,
    this.debugContinuousStepObserver,
    this.debugLayoutClock,
    this.debugPathEntry = false,
    this.openBooksAction,
  }) : assert(
         (bridge == null) != (bridgeFactory == null),
         'a reader takes exactly one of bridge and bridgeFactory',
       );

  final FlutterBridge? bridge;
  final FlutterBridge Function()? bridgeFactory;
  final PageDecoder decoder;
  final String? initialPath;
  final int? initialBookId;

  /// Where [initialPath] opens instead of its saved reading position.
  final ReaderPlace? initialPlace;

  /// Places the shell asks this reader to go to; a request made before the
  /// document opened is where it opens.
  final ReaderPlaceRequests? placeRequests;
  final FlutterReaderSettings? initialSettings;
  final void Function(String path, int? bookId)? onLocatorChanged;

  /// Fixture-supplied progress ordinals (RD-05); 5G supplies real values.
  final ReaderProgressSource? progressSource;

  /// Test-supplied Contents entries (RD-07); production resolves the real TOC.
  final ReaderContentsLoader? contentsLoader;

  /// The shell's platform opener for allowed external links.
  ///
  /// The reader classifies a rendered link's scheme and calls this adapter only
  /// for `http`, `https` and `mailto`; without one, allowed external links open
  /// nothing (the reader never launches or fetches anything itself).
  final ReaderExternalLinkOpener? externalLinkOpener;

  /// The shell's platform document picker for the more panel (RD-10).
  final ReaderDocumentPickerAdapter? documentPicker;

  /// Delivers the Markdown export text (RD-08); defaults to the clipboard.
  final ReaderExportSink? exportSink;

  /// Saves the Display settings when the reader changes them.
  final ReaderDisplaySink? onDisplayChanged;

  /// The application notice center's reporter, injected by the composition
  /// root; a reader built without one reports no notices.
  final ReaderNoticeReporter? noticeReporter;

  /// Decodes one admitted EPUB image resource; defaults to the engine codec.
  ///
  /// A composition root or a test can inject its own decoder, the way the page
  /// decoder is injected: the reader paints a null result as the image's alt
  /// text.
  final EpubImageDecoder? epubImageDecoder;

  /// Registers one admitted `@font-face` family; defaults to `FontLoader`.
  final EpubFontRegistrar? epubFontRegistrar;

  /// Test-only observer for the chapter sessions the reader creates.
  ///
  /// Like [debugPathEntry], this exists so a test can assert the layout's
  /// resource ownership (which session was released, and when) without reaching
  /// into the controller; production composition leaves it null.
  final void Function(ChapterLayoutSession session)? debugEpubSessionObserver;

  /// Test and measurement hook: each continuous window step's synchronous
  /// microseconds and the nodes it measured.
  final void Function(({int micros, int measured}) step)?
  debugContinuousStepObserver;

  /// Test-only clock for EPUB layout's time budgets; production composition
  /// leaves it null and the budgets are spent on the system clock.
  ///
  /// A test passes a clock that never advances so each layout step's work is
  /// bounded by its node counts alone, whatever the machine's speed.
  final LayoutClock? debugLayoutClock;

  /// Renders the retired path entry for tests and development only.
  ///
  /// Contract §7.2 item 6 retires the raw path field from the restored reader
  /// composition; the capability moves to the library entry and the more
  /// panel's document picker. This dev/test-only entry must not appear in
  /// production renders, so it is off by default.
  final bool debugPathEntry;

  /// The shell's open-books control, shown at the end of the phone toolbar.
  ///
  /// The reader only places it; on desktop and tablet the shell's sidebar
  /// lists the open books instead, so the reader ignores it there.
  final Widget? openBooksAction;

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

/// Installs the application localization delegates for [child] when the
/// embedding app has not (a bare `MaterialApp` in a widget test, for example),
/// so the reader and its root-navigator dialogs are never rendered unlocalized.
/// The production shell already provides them, so this is a no-op there.
Widget _withReaderLocalizations(BuildContext context, Widget child) {
  if (Localizations.of<AppLocalizations>(context, AppLocalizations) != null) {
    return child;
  }
  return Localizations(
    locale: Localizations.maybeLocaleOf(context) ?? const Locale('en'),
    delegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
    ],
    child: child,
  );
}

class _ReaderScreenState extends State<ReaderScreen>
    with WidgetsBindingObserver, RestorationMixin {
  final RestorableTextEditingController _path =
      RestorableTextEditingController();
  final RestorableStringN _openDocumentPath = RestorableStringN(null);
  final RestorableIntN _openDocumentBookId = RestorableIntN(null);
  final GlobalKey _pathFieldKey = GlobalKey(debugLabel: 'document path');
  final GlobalKey _contentKey = GlobalKey(debugLabel: 'reader content');

  /// One key per panel, so an open panel keeps its scroll position and focus
  /// when a resize moves it between floating and docked.
  final Map<ReaderPanel, GlobalKey> _panelKeys = {
    for (final panel in ReaderPanel.values)
      panel: GlobalKey(debugLabel: 'reader ${panel.name} panel'),
  };
  final FocusNode _openFocus = FocusNode(debugLabel: 'open document');
  final FocusNode _readerFocus = FocusNode(debugLabel: 'reader surface');

  /// The document the surface last took the keyboard for.
  FlutterDocumentSummary? _surfaceFocusedFor;
  final FocusNode _actionFocus = FocusNode(debugLabel: 'selection actions');
  final FocusNode _backFocus = FocusNode(debugLabel: 'reader back');
  final FocusNode _contentsFocus = FocusNode(debugLabel: 'reader contents');
  final FocusNode _typographyFocus = FocusNode(debugLabel: 'reader typography');
  final FocusNode _notesFocus = FocusNode(debugLabel: 'reader notes');
  final FocusNode _panelFocus = FocusNode(debugLabel: 'reader panel');
  ReaderPanel? _lastOpenPanel;
  ShadDialogRoute<String>? _noteDialogRoute;
  ShadDialogRoute<AnnotationAssociationChoice>? _associationDialogRoute;
  late final ReaderController _controller;
  bool _controllerInitialized = false;
  ReaderModel? _stageModel;
  _ReaderMiniatureRenderBoundary? _stageBoundary;
  bool _stageFrameComplete = false;
  int _stageFrameRevision = 0;

  void _focusHeaderAction() {
    final focus = switch (_lastOpenPanel) {
      ReaderPanel.contents => _contentsFocus,
      ReaderPanel.typography => _typographyFocus,
      ReaderPanel.notes => _notesFocus,
      null => _backFocus,
    };
    if (focus.canRequestFocus) focus.requestFocus();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.placeRequests
      ?..addListener(_placeRequested)
      ..wayBack = _wayBack
      ..pageMiniature = _pageMiniature;
  }

  @override
  void didUpdateWidget(ReaderScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.placeRequests, widget.placeRequests)) {
      _releasePlaceRequests(oldWidget.placeRequests);
      widget.placeRequests
        ?..addListener(_placeRequested)
        ..wayBack = _wayBack
        ..pageMiniature = _pageMiniature;
    }
  }

  void _releasePlaceRequests(ReaderPlaceRequests? requests) {
    if (requests == null) return;
    requests.removeListener(_placeRequested);
    if (requests.wayBack == _wayBack) requests.wayBack = null;
    if (requests.pageMiniature == _pageMiniature) {
      requests.pageMiniature = null;
    }
  }

  /// The top of the last fully painted stage, bounded to the pixels the tab
  /// card can expose. A model or viewport change makes it unavailable until
  /// the resulting frame has painted.
  ui.Image? _pageMiniature() {
    final stage = _stageBoundary;
    if (stage == null ||
        !_stageFrameComplete ||
        !_controllerInitialized ||
        _controller.model.document == null) {
      return null;
    }
    return stage.capture(
      devicePixelRatio: View.of(context).devicePixelRatio,
      sourceAspectRatio:
          ShellTabSwitcher.miniatureSourceWidth /
          ShellTabSwitcher.miniatureSourceHeight,
      maxPixelWidth: ShellTabSwitcher.miniatureMaxPixelWidth,
    );
  }

  void _stageChanged() {
    _stageFrameComplete = false;
    final revision = ++_stageFrameRevision;
    WidgetsBinding.instance
      ..addPostFrameCallback((_) {
        if (mounted && revision == _stageFrameRevision) {
          _stageFrameComplete = true;
        }
      })
      ..scheduleFrame();
  }

  bool _stageAppearanceChanged(ReaderModel before, ReaderModel after) =>
      !identical(before.document, after.document) ||
      before.unit != after.unit ||
      before.readingOffset != after.readingOffset ||
      before.readingPage != after.readingPage ||
      !identical(before.pageImage, after.pageImage) ||
      !identical(before.epubPage, after.epubPage) ||
      before.pdfSpread != after.pdfSpread ||
      !identical(before.selectionSurface, after.selectionSurface) ||
      before.selectionPhase != after.selectionPhase ||
      before.anchor != after.anchor ||
      before.focus != after.focus ||
      !listEquals(before.savedSelections, after.savedSelections) ||
      !listEquals(before.annotations, after.annotations) ||
      !setEquals(before.annotationOperations, after.annotationOperations) ||
      before.annotationsReady != after.annotationsReady ||
      before.typography != after.typography ||
      before.layout != after.layout ||
      before.relayoutBusy != after.relayoutBusy ||
      before.relayoutPending != after.relayoutPending ||
      before.contentState != after.contentState ||
      before.busy != after.busy ||
      before.error != after.error ||
      before.relayoutError != after.relayoutError ||
      before.layoutRefusal != after.layoutRefusal;

  List<ReaderReturnPoint>? _wayBack() =>
      _controllerInitialized ? _controller.wayBack : null;

  void _placeRequested() {
    if (widget.placeRequests?.take() case final place?) {
      _controller.dispatch(ReaderPlaceRequested(place));
    }
  }

  @override
  void didChangeDependencies() {
    if (!_controllerInitialized) {
      _controllerInitialized = true;
      _controller = ReaderController(
        bridge: widget.bridge ?? widget.bridgeFactory!(),
        decoder: (pixels, {required width, required height}) =>
            widget.decoder(pixels, width: width, height: height),
        initialScale: (widget.initialSettings?.pdfZoom ?? 0) > 0
            ? widget.initialSettings!.pdfZoom
            : View.of(context).devicePixelRatio,
        initialLineSpacing: widget.initialSettings?.epubLineSpacing ?? 1.5,
        initialTypography: _initialTypography(
          View.of(context).devicePixelRatio,
        ),
        baseScale: View.of(context).devicePixelRatio,
        librarySearchOpener: widget.placeRequests?.openSearch,
        noteEditor: _editNote,
        placeNoteEditor: _editPlaceNote,
        noteEditorCanceller: _cancelNoteEditor,
        annotationAssociationPicker: _pickAnnotationAssociation,
        annotationAssociationPickerCanceller:
            _cancelAnnotationAssociationPicker,
        focusAdapter: (target) => switch (target) {
          // The adapter honors every request it is given: the controller only
          // asks for the surface when the transition is explicit (user
          // cancellation, annotation navigation). A passive relayout
          // invalidation does not request focus, so a resize cannot pull focus
          // out of an open panel or the header.
          ReaderFocusTarget.surface => _readerFocus.requestFocus(),
          ReaderFocusTarget.actions => _actionFocus.requestFocus(),
          ReaderFocusTarget.header => _focusHeaderAction(),
          ReaderFocusTarget.panel => _panelFocus.requestFocus(),
        },
        navigationAdapter: () async {
          final navigator = Navigator.maybeOf(context);
          if (navigator != null && navigator.canPop()) navigator.pop();
        },
        progressSource: widget.progressSource,
        contentsLoader: widget.contentsLoader,
        externalLinkOpener: widget.externalLinkOpener,
        bookOpener: widget.placeRequests?.openBook,
        documentPickerAdapter: widget.documentPicker,
        exportSink: widget.exportSink ?? _copyExportToClipboard,
        displaySink: widget.onDisplayChanged,
        noticeReporter: widget.noticeReporter,
        // The Dart EPUB renderer's platform adapters: decoding an admitted
        // image resource, registering an embedded `@font-face` family and
        // reading the bundled faces' coverage are engine effects, so they stay
        // on the widget side of the boundary.
        epubImageDecoder: widget.epubImageDecoder ?? _decodeEpubImage,
        epubFontRegistrar: widget.epubFontRegistrar ?? _registerEpubFont,
        debugEpubSessionObserver: widget.debugEpubSessionObserver,
        debugContinuousStepObserver: widget.debugContinuousStepObserver,
        layoutClock: widget.debugLayoutClock,
        // A callback runs after the next frame, and asks for that frame: a
        // continuous window step that installs nothing new still runs.
        frameScheduler: (callback) {
          WidgetsBinding.instance
            ..addPostFrameCallback((_) => callback())
            ..scheduleFrame();
        },
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
      _stageModel = _controller.model;
    }
    _stageChanged();
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
        ReaderOpenRequested(
          path,
          bookId: widget.initialBookId,
          place: widget.initialPlace ?? widget.placeRequests?.take(),
        ),
      );
    }
  }

  Future<String?> _editNote(String? initialValue) =>
      _showNoteEditor(initialValue, kind: null);

  Future<String?> _editPlaceNote(FlutterNoteKind kind) =>
      _showNoteEditor(null, kind: kind);

  Future<String?> _showNoteEditor(
    String? initialValue, {
    required FlutterNoteKind? kind,
  }) async {
    final navigator = Navigator.of(context, rootNavigator: true);
    final readerTheme = _readerTheme(
      context,
      _controller.model.typography.theme,
    );
    final route = ShadDialogRoute<String>(
      // The dialog is pushed on the root navigator, outside the reader's own
      // localization subtree, so it installs the application delegates for its
      // own subtree when the embedding app has not provided them.
      pageBuilder: (context) => _withReaderLocalizations(
        context,
        Theme(
          data: readerTheme,
          child: ShadTheme(
            data: shosaiReaderShadTheme(_controller.model.typography.theme),
            child: _NoteDialog(initialValue: initialValue, kind: kind),
          ),
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
    final readerTheme = _readerTheme(
      context,
      _controller.model.typography.theme,
    );
    final route = ShadDialogRoute<AnnotationAssociationChoice>(
      pageBuilder: (context) => Theme(
        data: readerTheme,
        child: ShadTheme(
          data: shosaiReaderShadTheme(_controller.model.typography.theme),
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
    final model = _controller.model;
    final previousStageModel = _stageModel;
    _stageModel = model;
    if (model.openPanel != null) _lastOpenPanel = model.openPanel;
    if (model.document case final document?
        when !identical(document, _surfaceFocusedFor)) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _focusSurfaceIfUnclaimed(document),
      );
    }
    final openPath = model.openPath;
    if (openPath != null) {
      // Persist the accepted locator as one pair. In particular, clear a
      // previous library identity while an untracked replacement is opening
      // and leave it cleared if that replacement fails.
      final bookId = model.openBookId;
      if (_openDocumentPath.value != openPath ||
          _openDocumentBookId.value != bookId) {
        _openDocumentPath.value = openPath;
        _openDocumentBookId.value = bookId;
        widget.onLocatorChanged?.call(openPath, bookId);
      }
    }
    setState(() {});
    if (previousStageModel == null ||
        _stageAppearanceChanged(previousStageModel, model)) {
      _stageChanged();
    }
  }

  /// Gives a newly shown document the keyboard, so its page keys work
  /// without a click first, unless focus is already somewhere of its own.
  ///
  /// The surface's own autofocus loses to a key-catching ancestor the shell
  /// focuses before the document exists; that ancestor (or no focus at all)
  /// counts as unclaimed. A surface not built yet is tried again on the next
  /// model change.
  void _focusSurfaceIfUnclaimed(FlutterDocumentSummary document) {
    if (!mounted ||
        identical(_surfaceFocusedFor, document) ||
        !identical(_controller.model.document, document) ||
        _readerFocus.context == null) {
      return;
    }
    _surfaceFocusedFor = document;
    final primary = FocusManager.instance.primaryFocus;
    if (primary == null || _readerFocus.ancestors.contains(primary)) {
      _readerFocus.requestFocus();
    }
  }

  @override
  void didChangeMetrics() => _stageChanged();

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
    _releasePlaceRequests(widget.placeRequests);
    _controller.removeListener(_modelChanged);
    _controller.dispose();
    _path.dispose();
    _openDocumentPath.dispose();
    _openDocumentBookId.dispose();
    _openFocus.dispose();
    _readerFocus.dispose();
    _actionFocus.dispose();
    _backFocus.dispose();
    _contentsFocus.dispose();
    _typographyFocus.dispose();
    _notesFocus.dispose();
    _panelFocus.dispose();
    super.dispose();
  }

  void _open() {
    final path = _path.value.text.trim();
    _controller.dispatch(ReaderOpenRequested(path));
  }

  /// The reader-local typography the controller starts from.
  ///
  /// The legacy `pdfZoom` sentinel (0 = fit page, -1 = fit width, >0 = manual
  /// scale) maps onto the typed [ReaderRasterFit]; the codec that replaces the
  /// sentinel is 5A/6B.
  ReaderTypographyPresentation _initialTypography(double baseScale) {
    final settings = widget.initialSettings;
    final zoom = settings?.pdfZoom ?? 0;
    final fit = zoom == 0
        ? ReaderRasterFit.fitPage
        : zoom == -1
        ? ReaderRasterFit.fitWidth
        : ReaderRasterFit.manual;
    return ReaderTypographyPresentation(
      format: FlutterBookFormat.epub,
      continuous: settings?.continuous ?? false,
      theme: settings?.theme ?? 'light',
      epubFontSize: settings?.epubFontSize ?? 18,
      epubLineSpacing: settings?.epubLineSpacing ?? 1.5,
      rasterFit: fit,
      rasterZoom: fit == ReaderRasterFit.manual ? zoom : baseScale,
      twoPages: settings?.twoPages ?? true,
    );
  }

  /// The default export delivery (RD-08): copy the Markdown to the clipboard.
  ///
  /// A shell that wants a save location injects its own [ReaderExportSink]
  /// instead; the success/failure feedback stays with the controller's notice
  /// and export state.
  Future<void> _copyExportToClipboard(String markdown) =>
      Clipboard.setData(ClipboardData(text: markdown));

  @override
  Widget build(BuildContext context) {
    final model = _controller.model;
    final layout = ShellLayout.forWidth(MediaQuery.sizeOf(context).width);
    final phone = layout == ShellLayout.phone;
    final theme = _readerTheme(context, model.typography.theme);
    final reader = Theme(
      data: theme,
      child: ShadTheme(
        data: shosaiReaderShadTheme(model.typography.theme),
        // The palette follows the reader's own theme, not the app's: a reader
        // may sit under no app theme at all.
        child: Builder(
          builder: (context) => Scaffold(
            backgroundColor: ShellPalette.of(context).chrome,
            body: SafeArea(
              // Back after a jump: Alt+← on Linux and Windows, ⌘[ on macOS.
              child: Focus(
                canRequestFocus: false,
                skipTraversal: true,
                onKeyEvent: _returnKey,
                child: CallbackShortcuts(
                  // The retired more panel's Open book action lives on as a
                  // shortcut; the library is the usual way to open a book.
                  bindings: {
                    const SingleActivator(
                      LogicalKeyboardKey.keyO,
                      control: true,
                    ): _openBook,
                    const SingleActivator(LogicalKeyboardKey.keyO, meta: true):
                        _openBook,
                  },
                  child: // The chrome rows are bounded by the height the reader is
                      // actually laid out with, not by the ambient `MediaQuery`: a
                      // host may install a `MediaQuery` whose size does not match
                      // the reader's viewport (the widget tests do that to set a
                      // text scale), and a zero height there would collapse the
                      // chrome.
                      LayoutBuilder(
                        builder: (context, constraints) => Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // Every fixed chrome row is bounded to a share of the
                            // viewport and scrolls inside that bound, so a very
                            // short viewport with a scaled interface cannot push
                            // the document out of reach.
                            _boundedChrome(
                              viewportHeight: constraints.maxHeight,
                              share: _readerHeaderBoundShare,
                              child: _ReaderToolbar(
                                model: model,
                                layout: layout,
                                dispatch: _controller.dispatch,
                                backFocus: _backFocus,
                                contentsFocus: _contentsFocus,
                                typographyFocus: _typographyFocus,
                                notesFocus: _notesFocus,
                                openBooksAction: widget.openBooksAction,
                              ),
                            ),
                            // The search bar is its own row under the toolbar
                            // (RD-11); search is independent of the panels.
                            if (model.searchOpen &&
                                model.document != null &&
                                model.typography.searchable)
                              _boundedChrome(
                                viewportHeight: constraints.maxHeight,
                                share: _readerSearchBoundShare,
                                child: _ReaderSearchBar(
                                  model: model,
                                  compact: phone,
                                  dispatch: _controller.dispatch,
                                ),
                              ),
                            // A content failure is shown inside the document view;
                            // the alert is for an open that never produced one.
                            if (model.error != null &&
                                !(model.document != null &&
                                    model.contentState ==
                                        ReaderContentState.failed))
                              ConstrainedBox(
                                constraints: BoxConstraints(
                                  maxHeight:
                                      constraints.maxHeight *
                                      _readerAlertBoundShare,
                                ),
                                child: SingleChildScrollView(
                                  child: _ReaderFailureAlert(
                                    error: model.error!,
                                    onRetry: model.openPath == null
                                        ? null
                                        : () => _controller.dispatch(
                                            ReaderOpenRequested(
                                              model.openPath!,
                                              bookId: model.openBookId,
                                            ),
                                          ),
                                  ),
                                ),
                              ),
                            Expanded(child: _readerBody(model, layout)),
                            ConstrainedBox(
                              constraints: BoxConstraints(
                                maxHeight:
                                    constraints.maxHeight *
                                    _readerAlertBoundShare,
                              ),
                              child: _ReaderErrorSurfaces(model: model),
                            ),
                            // The place stays mounted while an open is in flight:
                            // its `loading` wording is a live region, so the
                            // opening state must not remove it.
                            _boundedChrome(
                              viewportHeight: constraints.maxHeight,
                              share: _readerStatusBoundShare,
                              child: phone
                                  ? _ReaderPhoneBar(
                                      model: model,
                                      dispatch: _controller.dispatch,
                                      contentsFocus: _contentsFocus,
                                      typographyFocus: _typographyFocus,
                                      notesFocus: _notesFocus,
                                    )
                                  : _ReaderStatusLine(
                                      model: model,
                                      dispatch: _controller.dispatch,
                                    ),
                            ),
                            if (widget.debugPathEntry) ...[
                              const SizedBox(height: 12),
                              // A dev/test-only entry, bounded so a short viewport
                              // at a scaled interface cannot overflow the reader
                              // column.
                              ConstrainedBox(
                                constraints: BoxConstraints(
                                  maxHeight:
                                      constraints.maxHeight *
                                      _readerDevEntryBoundShare,
                                ),
                                child: SingleChildScrollView(
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: ShosaiTokens.space4,
                                    ),
                                    child: _ReaderControls(
                                      model: model,
                                      path: _path.value,
                                      pathFieldKey: _pathFieldKey,
                                      openFocus: _openFocus,
                                      open: _open,
                                      // A single row keeps the dev-only entry short
                                      // enough not to push the chrome out of a small
                                      // viewport at a scaled interface.
                                      horizontal: true,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final panel = model.openPanel;
    final floatingPanel =
        panel != null &&
        !ShellReaderOverlayScope.coveredOf(context) &&
        _readerPanelPresentation(panel, layout) !=
            _ReaderPanelPresentation.docked;
    return PopScope(
      canPop: !floatingPanel,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && floatingPanel) {
          _controller.dispatch(ReaderPanelToggled(panel));
        }
      },
      child: _withReaderLocalizations(context, reader),
    );
  }

  /// Back after a jump, unless a text field takes the key for moving by
  /// word.
  KeyEventResult _returnKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    final mac = defaultTargetPlatform == TargetPlatform.macOS;
    final back = mac
        ? event.logicalKey == LogicalKeyboardKey.bracketLeft &&
              keyboard.isMetaPressed &&
              !keyboard.isControlPressed &&
              !keyboard.isAltPressed
        : event.logicalKey == LogicalKeyboardKey.arrowLeft &&
              keyboard.isAltPressed &&
              !keyboard.isControlPressed &&
              !keyboard.isMetaPressed;
    if (!back || keyboard.isShiftPressed) return KeyEventResult.ignored;
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused != null &&
        (focused.widget is EditableText ||
            focused.findAncestorWidgetOfExactType<EditableText>() != null)) {
      return KeyEventResult.ignored;
    }
    _controller.dispatch(const ReaderReturnRequested());
    return KeyEventResult.handled;
  }

  void _openBook() {
    final model = _controller.model;
    if (model.busy || model.modalEffect != null) return;
    _controller.dispatch(const ReaderOpenBookRequested());
  }

  /// Bounds a fixed chrome row to a share of the reader's own height and lets
  /// it scroll inside that bound.
  ///
  /// The bound only takes effect on a viewport too short for the natural row
  /// (a very short window with a scaled interface); a row that fits is laid out
  /// exactly as before. [viewportHeight] comes from the reader's layout, so a
  /// host `MediaQuery` with a different size cannot collapse the chrome.
  Widget _boundedChrome({
    required double viewportHeight,
    required double share,
    required Widget child,
  }) => ConstrainedBox(
    constraints: BoxConstraints(
      maxHeight: viewportHeight.isFinite
          ? viewportHeight * share
          : double.infinity,
    ),
    child: SingleChildScrollView(child: child),
  );

  /// The stage with the open panel: floating panels over it, the docked Notes
  /// panel beside it.
  Widget _readerBody(ReaderModel model, ShellLayout layout) {
    final content = _ReaderContentPane(
      key: _contentKey,
      model: model,
      dispatch: _controller.dispatch,
      readerFocus: _readerFocus,
      actionFocus: _actionFocus,
      debugPathEntry: widget.debugPathEntry,
    );
    final openPanel = model.openPanel;
    // A floating panel covers the page: the page leaves keyboard traversal
    // and the semantics tree until it closes, so focus and a screen reader
    // stay with the panel. The controller's requests for the document's focus
    // while it is covered (a note chosen in the panel) fail, so focus stays on
    // the chosen note; closing the panel returns it to the toolbar.
    final covered =
        openPanel != null &&
        _readerPanelPresentation(openPanel, layout) !=
            _ReaderPanelPresentation.docked;
    final stage = LayoutBuilder(
      builder: (context, constraints) => Stack(
        children: [
          Positioned.fill(
            child: ExcludeFocus(
              excluding: covered,
              child: ExcludeSemantics(
                excluding: covered,
                // The phone's tab switcher shows the page from here.
                child: _ReaderMiniatureBoundary(
                  onPainted: (stage) => _stageBoundary = stage,
                  child: _ReaderStage(
                    model: model,
                    layout: layout,
                    dispatch: _controller.dispatch,
                    content: content,
                  ),
                ),
              ),
            ),
          ),
          if (model.returnPoints.isNotEmpty && model.document != null)
            Positioned(
              left: ShosaiTokens.space4,
              right: ShosaiTokens.space4,
              bottom: ShosaiTokens.space6,
              child: Center(
                child: _ReaderBackPill(
                  model: model,
                  dispatch: _controller.dispatch,
                ),
              ),
            ),
          ..._readerPanelOverlay(
            model: model,
            layout: layout,
            stage: constraints,
            dispatch: _controller.dispatch,
            focusNode: _panelFocus,
            hostKeys: _panelKeys,
          ),
        ],
      ),
    );
    final panel = openPanel;
    if (panel == null || covered) return stage;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: stage),
        SizedBox(
          width: ShosaiTokens.sizePanelWidth,
          child: _ReaderPanelHost(
            key: _panelKeys[panel],
            panel: panel,
            presentation: _ReaderPanelPresentation.docked,
            model: model,
            dispatch: _controller.dispatch,
            focusNode: _panelFocus,
          ),
        ),
      ],
    );
  }
}

/// A repaint boundary that reports the exact render object only after its
/// stage pixels have been painted. The report mutates no model state; it is
/// the presentation adapter the shell asks to capture synchronously.
class _ReaderMiniatureBoundary extends SingleChildRenderObjectWidget {
  const _ReaderMiniatureBoundary({
    required this.onPainted,
    required super.child,
  });

  final ValueChanged<_ReaderMiniatureRenderBoundary> onPainted;

  @override
  _ReaderMiniatureRenderBoundary createRenderObject(BuildContext context) =>
      _ReaderMiniatureRenderBoundary(onPainted);

  @override
  void updateRenderObject(
    BuildContext context,
    _ReaderMiniatureRenderBoundary renderObject,
  ) => renderObject.onPainted = onPainted;
}

class _ReaderMiniatureRenderBoundary extends RenderRepaintBoundary {
  _ReaderMiniatureRenderBoundary(this.onPainted);

  ValueChanged<_ReaderMiniatureRenderBoundary> onPainted;
  bool hasPainted = false;

  ui.Image? capture({
    required double devicePixelRatio,
    required double sourceAspectRatio,
    required int maxPixelWidth,
  }) {
    final imageLayer = layer;
    if (!hasPainted ||
        !attached ||
        !hasSize ||
        size.isEmpty ||
        imageLayer is! OffsetLayer) {
      return null;
    }
    final sourceHeight = math.min(size.height, size.width / sourceAspectRatio);
    final pixelRatio = math.min(devicePixelRatio, maxPixelWidth / size.width);
    return imageLayer.toImageSync(
      Rect.fromLTWH(0, 0, size.width, sourceHeight),
      pixelRatio: pixelRatio,
    );
  }

  @override
  void markNeedsPaint() {
    hasPainted = false;
    super.markNeedsPaint();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    hasPainted = true;
    onPainted(this);
  }
}

/// The reader's Material theme, mapped from the shared design tokens.
///
/// The page and surface colors are the pinned Iced reader palettes, so
/// [pageColors] reads the document palette for the active reader theme; the
/// pre-2C brown seed is rejected by plan decision 2.
ThemeData _readerTheme(BuildContext context, String? theme) =>
    shosaiReaderMaterialTheme(context, theme);

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
              Expanded(flex: 3, child: field),
              const SizedBox(width: 12),
              // Both children share the row so a scaled interface ellipsizes
              // the dev-only entry instead of overflowing it.
              Flexible(flex: 2, child: button),
            ],
          )
        else ...[
          field,
          const SizedBox(height: 12),
          Align(alignment: Alignment.centerLeft, child: button),
        ],
        // The progress row keeps its room when idle: the page below is fitted
        // to the box that is left, which must not move as a relayout starts
        // and ends.
        SizedBox(
          height: 4,
          child: model.relayoutBusy ? const ShadProgress(minHeight: 4) : null,
        ),
      ],
    );
  }
}

class _ReaderContentPane extends StatelessWidget {
  const _ReaderContentPane({
    super.key,
    required this.model,
    required this.dispatch,
    required this.readerFocus,
    required this.actionFocus,
    required this.debugPathEntry,
  });

  final ReaderModel model;
  final void Function(ReaderMessage) dispatch;
  final FocusNode readerFocus;
  final FocusNode actionFocus;

  /// Whether the dev/test-only path entry is rendered (contract §7.2 item 6:
  /// the production composition renders no raw path field). The no-document
  /// body shows the retained welcome copy with or without this entry.
  final bool debugPathEntry;

  @override
  Widget build(BuildContext context) {
    final document = model.document;
    // The document-level shortcuts cover the document area *and* the
    // saved-highlight strip below it, so a focused strip control keeps the
    // reader's page steps, escape and copy behavior.
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            dispatch(const ReaderSelectionCancelled()),
        const SingleActivator(LogicalKeyboardKey.keyC, control: true): () =>
            dispatch(const ReaderSelectionCopyRequested()),
        const SingleActivator(LogicalKeyboardKey.keyC, meta: true): () =>
            dispatch(const ReaderSelectionCopyRequested()),
        ...readerPageKeys(model, dispatch),
      },
      child: Column(
        children: [
          Expanded(
            child: _ReaderLayoutReporter(
              model: model,
              dispatch: dispatch,
              child: model.busy
                  ? _ReaderOpeningView(
                      title:
                          document?.title ??
                          AppLocalizations.of(context).readerFallbackTitle,
                    )
                  : document == null
                  // The no-document body. The app always opens a book from
                  // the library, so only a bare reader (the debug path entry)
                  // shows it; it sits on the stage unless a failed EPUB open
                  // left the page paper in place.
                  ? WelcomePanel(
                      color: _readerShowsPaper(model)
                          ? pageColors(model.typography.theme).foreground
                          : ShellPalette.of(context).inkMuted,
                    )
                  : _DocumentView(
                      document: document,
                      image: model.pageImage,
                      model: model,
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
      ),
    );
  }
}

class _ReaderLayoutReporter extends StatefulWidget {
  const _ReaderLayoutReporter({
    required this.model,
    required this.dispatch,
    required this.child,
  });

  final ReaderModel model;
  final void Function(ReaderMessage) dispatch;
  final Widget child;

  @override
  State<_ReaderLayoutReporter> createState() => _ReaderLayoutReporterState();
}

class _ReaderLayoutReporterState extends State<_ReaderLayoutReporter> {
  bool _scheduled = false;
  ReaderLayout? _observedLayout;
  double? _observedHeight;
  double? _observedPixelRatio;
  ReaderLayout? _pendingLayout;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final availableWidth = constraints.maxWidth.isFinite
          ? math.max(1.0, constraints.maxWidth).roundToDouble()
          : widget.model.layout.width;
      // The content-box height is reported alongside the width: EPUB
      // pagination needs the page height.
      final availableHeight = constraints.maxHeight.isFinite
          ? math.max(1.0, constraints.maxHeight).roundToDouble()
          : null;
      final typography = widget.model.typography;
      final layout = ReaderLayout(
        scale: widget.model.document != null
            ? widget.model.layout.scale
            : typography.rasterZoom,
        width: availableWidth,
        // The interface text scale must not change the document font: `T200`
        // scales interface chrome only (specification `T200`/`BF*` separation,
        // contract §2.3 item 5b). The EPUB font size is the reader preference.
        fontSize: typography.epubFontSize,
        lineSpacing: typography.epubLineSpacing,
        spread: _ReaderSpreadScope.of(context),
      );
      final observedHeight = availableHeight;
      final pixelRatio = MediaQuery.devicePixelRatioOf(context);
      if (layout != _observedLayout ||
          observedHeight != _observedHeight ||
          pixelRatio != _observedPixelRatio) {
        _observedLayout = layout;
        _observedHeight = observedHeight;
        _observedPixelRatio = pixelRatio;
        _pendingLayout = layout;
      }
      if (_pendingLayout != null && !_scheduled) {
        _scheduled = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _scheduled = false;
          final pending = _pendingLayout;
          final pendingHeight = _observedHeight;
          final pendingPixelRatio = _observedPixelRatio;
          _pendingLayout = null;
          if (mounted && pending != null) {
            widget.dispatch(
              ReaderViewportChanged(
                pending,
                height: pendingHeight,
                devicePixelRatio: pendingPixelRatio,
              ),
            );
          }
        });
      }
      return widget.child;
    },
  );
}

class WelcomePanel extends StatelessWidget {
  const WelcomePanel({super.key, this.color});

  /// The ink for what the panel sits on: the stage's muted ink, or the page's
  /// foreground on page paper. A caller that renders the panel outside the
  /// reader keeps the ambient style.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        'Enter a local document path to open it.',
        textAlign: TextAlign.center,
        style: color == null ? null : TextStyle(color: color),
      ),
    );
  }
}

bool usesExplicitSelectionAnnouncements(TargetPlatform platform) =>
    platform == TargetPlatform.linux ||
    platform == TargetPlatform.macOS ||
    platform == TargetPlatform.windows;

/// Decodes one admitted EPUB image resource.
///
/// A resource the engine cannot decode (an SVG, or a corrupt raster) returns
/// null, and the layout paints the image's alt fallback instead.
/// The longest side a document image is decoded at.
///
/// A page paints an image at most at its content width, so a raster beyond this
/// is decoded down rather than allocated at its authored size: an encoded
/// resource below the archive's byte ceiling can otherwise decode into a raster
/// far past the chapter's decoded-byte budget.
const int kEpubImageMaxDimension = 4096;

Future<ui.Image?> _decodeEpubImage(Uint8List bytes) async {
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  try {
    // The encoded header reports the intrinsic size, so a small image is never
    // upscaled and a large one is bounded before the raster is allocated.
    buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final width = descriptor.width;
    final height = descriptor.height;
    final longest = width > height ? width : height;
    codec = longest > kEpubImageMaxDimension
        ? await descriptor.instantiateCodec(
            targetWidth: width >= height ? kEpubImageMaxDimension : null,
            targetHeight: height > width ? kEpubImageMaxDimension : null,
          )
        : await descriptor.instantiateCodec();
    return (await codec.getNextFrame()).image;
  } catch (_) {
    return null;
  } finally {
    // The buffer is the caller's to release, and disposing the descriptor does
    // not release it.
    codec?.dispose();
    descriptor?.dispose();
    buffer?.dispose();
  }
}

/// Registers one admitted `@font-face` family under [family].
///
/// The family name is synthesized by the controller and namespaced per
/// resource, so two books cannot collide; Flutter has no font-unload API, so a
/// family stays registered for the process once loaded.
Future<void> _registerEpubFont(String family, Uint8List bytes) async {
  final loader = FontLoader(family);
  loader.addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
  await loader.load();
}

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
