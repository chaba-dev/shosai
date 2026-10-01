import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shosai_flutter/app_theme.dart';
import 'package:shosai_flutter/l10n/app_localizations.dart';
import 'package:shosai_flutter/reader/controller.dart';
import 'package:shosai_flutter/reader/epub/content.dart';
import 'package:shosai_flutter/reader/epub/flow.dart';
import 'package:shosai_flutter/reader/epub/font_coverage.dart';
import 'package:shosai_flutter/reader/epub/surface.dart';
import 'package:shosai_flutter/shared/shad_widgets.dart';
import 'package:shosai_flutter/src/rust/api.dart';
import 'package:shosai_flutter/theme_tokens.dart';

part 'geometry.dart';
part 'painting.dart';
part 'view_chrome.dart';

part 'view_dialogs.dart';
part 'view_document.dart';
part 'view_selection.dart';

/// Viewport shares that bound the fixed reader chrome rows.
///
/// These are robustness bounds, not design values: the pinned reference fixes
/// no such limit. They only take effect on a viewport too short for the row (a
/// short window at a scaled interface), where the alternative is an overflow
/// that pushes the document out of reach. The alert and error surfaces keep the
/// pre-existing 0.15 bound.
const double _readerTabStripBoundShare = 0.2;
const double _readerHeaderBoundShare = 0.3;
const double _readerPanelBoundShare = 0.4;
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
    this.initialSettings,
    this.onLocatorChanged,
    this.initialTabs = const [],
    this.progressSource,
    this.contentsLoader,
    this.documentPicker,
    this.exportSink,
    this.noticeReporter,
    this.fontCoverageLoader,
    this.epubImageDecoder,
    this.epubFontRegistrar,
    this.debugEpubSessionObserver,
    this.debugPathEntry = false,
  }) : assert(bridge == null || bridgeFactory == null);

  final FlutterBridge? bridge;
  final FlutterBridge Function()? bridgeFactory;
  final PageDecoder decoder;
  final String? initialPath;
  final int? initialBookId;
  final FlutterReaderSettings? initialSettings;
  final void Function(String path, int? bookId)? onLocatorChanged;

  /// Fixture-injected tab strip entries (4B presentation; 5F owns sessions).
  final List<ReaderTabPresentation> initialTabs;

  /// Fixture-supplied progress ordinals (RD-05); 5G supplies real values.
  final ReaderProgressSource? progressSource;

  /// Fixture-supplied Contents entries (RD-07); 5E supplies the real TOC.
  final ReaderContentsLoader? contentsLoader;

  /// The shell's platform document picker for the more panel (RD-10).
  final ReaderDocumentPickerAdapter? documentPicker;

  /// Delivers the Markdown export text (RD-08); defaults to the clipboard.
  final ReaderExportSink? exportSink;

  /// The application notice center's reporter, injected by the composition
  /// root; a reader built without one reports no notices.
  final ReaderNoticeReporter? noticeReporter;

  /// Loads the bundled document faces' coverage for the EPUB routing gate.
  ///
  /// Defaults to the reader's own bundled faces; a test can inject a fixed
  /// coverage so the routing decision is independent of the shipped assets.
  final EpubFontCoverageLoader? fontCoverageLoader;

  /// Decodes one admitted EPUB image resource; defaults to the engine codec.
  ///
  /// A composition root or a test can inject its own decoder, the way the page
  /// decoder is injected: the reader treats a null result as the retained
  /// renderer's missing-image fallback.
  final EpubImageDecoder? epubImageDecoder;

  /// Registers one admitted `@font-face` family; defaults to `FontLoader`.
  final EpubFontRegistrar? epubFontRegistrar;

  /// Test-only observer for the chapter sessions the reader creates.
  ///
  /// Like [debugPathEntry], this exists so a test can assert the layout's
  /// resource ownership (which session was released, and when) without reaching
  /// into the controller; production composition leaves it null.
  final void Function(ChapterLayoutSession session)? debugEpubSessionObserver;

  /// Renders the retired path entry for tests and development only.
  ///
  /// Contract §7.2 item 6 retires the raw path field from the restored reader
  /// composition; the capability moves to the library entry and the more
  /// panel's document picker. This dev/test-only entry must not appear in
  /// production renders, so it is off by default.
  final bool debugPathEntry;

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
  final FocusNode _openFocus = FocusNode(debugLabel: 'open document');
  final FocusNode _readerFocus = FocusNode(debugLabel: 'reader surface');
  final FocusNode _actionFocus = FocusNode(debugLabel: 'selection actions');
  final FocusNode _backFocus = FocusNode(debugLabel: 'reader back');
  final FocusNode _contentsFocus = FocusNode(debugLabel: 'reader contents');
  final FocusNode _typographyFocus = FocusNode(debugLabel: 'reader typography');
  final FocusNode _moreFocus = FocusNode(debugLabel: 'reader more');
  final FocusNode _panelFocus = FocusNode(debugLabel: 'reader panel');
  final ScrollController _tabScroll = ScrollController();
  final Map<String, GlobalKey> _tabKeys = {};
  final Map<String, FocusNode> _tabFocusNodes = {};
  ReaderPanel? _lastOpenPanel;
  ShadDialogRoute<String>? _noteDialogRoute;
  ShadDialogRoute<AnnotationAssociationChoice>? _associationDialogRoute;
  late final ReaderController _controller;
  bool _controllerInitialized = false;

  /// The stable key the reveal adapter scrolls into view for [tabId].
  GlobalKey _tabKey(String tabId) => _tabKeys.putIfAbsent(
    tabId,
    () => GlobalKey(debugLabel: 'reader-tab-$tabId'),
  );

  /// The focus node the tab strip hands to the label control for [tabId].
  FocusNode _tabFocusNode(String tabId) => _tabFocusNodes.putIfAbsent(
    tabId,
    () => FocusNode(debugLabel: 'reader-tab-label-$tabId'),
  );

  /// The focus node the tab strip hands to the close control for [tabId].
  FocusNode _tabCloseFocusNode(String tabId) => _tabFocusNodes.putIfAbsent(
    _tabCloseNodeKey(tabId),
    () => FocusNode(debugLabel: 'reader-tab-close-$tabId'),
  );

  static String _tabCloseNodeKey(String tabId) => '$tabId::close';

  void _pruneTabResources(ReaderModel model) {
    final ids = {for (final tab in model.tabs) tab.id};
    for (final key in _tabFocusNodes.keys.toList()) {
      final id = key.endsWith('::close')
          ? key.substring(0, key.length - '::close'.length)
          : key;
      if (!ids.contains(id)) {
        _tabFocusNodes.remove(key)?.dispose();
      }
    }
    for (final id in _tabKeys.keys.toList()) {
      if (!ids.contains(id)) _tabKeys.remove(id);
    }
  }

  /// Brings the tab into view; the controller decides when this runs.
  Future<void> _revealTab(String tabId) async {
    final context = _tabKeys[tabId]?.currentContext;
    if (context == null || !mounted) return;
    await Scrollable.ensureVisible(
      context,
      duration: Duration.zero,
      alignment: 0,
    );
  }

  void _focusHeaderAction() {
    final focus = switch (_lastOpenPanel) {
      ReaderPanel.contents => _contentsFocus,
      ReaderPanel.typography => _typographyFocus,
      ReaderPanel.more => _moreFocus,
      null => _backFocus,
    };
    if (focus.canRequestFocus) focus.requestFocus();
  }

  void _focusActiveTab() {
    for (final tab in _controller.model.tabs) {
      if (tab.selected) {
        _tabFocusNodes[tab.id]?.requestFocus();
        return;
      }
    }
  }

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
        initialTypography: _initialTypography(
          View.of(context).devicePixelRatio,
        ),
        baseScale: View.of(context).devicePixelRatio,
        noteEditor: _editNote,
        bookmarkNoteEditor: _editBookmarkNote,
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
          ReaderFocusTarget.tabStrip => _focusActiveTab(),
        },
        navigationAdapter: () async {
          final navigator = Navigator.maybeOf(context);
          if (navigator != null && navigator.canPop()) navigator.pop();
        },
        tabRevealAdapter: _revealTab,
        progressSource: widget.progressSource,
        contentsLoader: widget.contentsLoader,
        documentPickerAdapter: widget.documentPicker,
        exportSink: widget.exportSink ?? _copyExportToClipboard,
        noticeReporter: widget.noticeReporter,
        // The Dart EPUB renderer's platform adapters: decoding an admitted
        // image resource, registering an embedded `@font-face` family and
        // reading the bundled faces' coverage are engine effects, so they stay
        // on the widget side of the boundary.
        epubImageDecoder: widget.epubImageDecoder ?? _decodeEpubImage,
        epubFontRegistrar: widget.epubFontRegistrar ?? _registerEpubFont,
        debugEpubSessionObserver: widget.debugEpubSessionObserver,
        epubFontCoverage: widget.fontCoverageLoader ?? _bundledFontCoverage,
        initialTabs: widget.initialTabs,
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
      _showNoteEditor(initialValue, bookmark: false);

  Future<String?> _editBookmarkNote(String? initialValue) =>
      _showNoteEditor(initialValue, bookmark: true);

  Future<String?> _showNoteEditor(
    String? initialValue, {
    required bool bookmark,
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
            child: _NoteDialog(initialValue: initialValue, bookmark: bookmark),
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
    if (model.openPanel != null) _lastOpenPanel = model.openPanel;
    _pruneTabResources(model);
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
    _backFocus.dispose();
    _contentsFocus.dispose();
    _typographyFocus.dispose();
    _moreFocus.dispose();
    _panelFocus.dispose();
    for (final node in _tabFocusNodes.values) {
      node.dispose();
    }
    _tabFocusNodes.clear();
    _tabKeys.clear();
    _tabScroll.dispose();
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
    final compact =
        MediaQuery.sizeOf(context).width <
        ShosaiTokens.layoutReaderCompactBreakpoint;
    final theme = _readerTheme(context, model.typography.theme);
    final reader = Theme(
      data: theme,
      child: ShadTheme(
        data: shosaiReaderShadTheme(model.typography.theme),
        child: Scaffold(
          body: SafeArea(
            child: _withChromeShortcuts(
              // The chrome rows are bounded by the height the reader is
              // actually laid out with, not by the ambient `MediaQuery`: a host
              // may install a `MediaQuery` whose size does not match the
              // reader's viewport (the widget tests do that to set a text
              // scale), and a zero height there would collapse the chrome.
              LayoutBuilder(
                builder: (context, constraints) => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Every fixed chrome row is bounded to a share of the
                    // viewport and scrolls inside that bound. At a very short
                    // viewport with a scaled interface the header alone would
                    // otherwise be taller than the reader (the `T200` stacked
                    // header wraps its action group), which would overflow the
                    // column and push the document out of reach.
                    _boundedChrome(
                      viewportHeight: constraints.maxHeight,
                      share: _readerTabStripBoundShare,
                      child: _ReaderTabStrip(
                        model: model,
                        dispatch: _controller.dispatch,
                        scrollController: _tabScroll,
                        tabKey: _tabKey,
                        tabFocusNode: _tabFocusNode,
                        tabCloseFocusNode: _tabCloseFocusNode,
                      ),
                    ),
                    _boundedChrome(
                      viewportHeight: constraints.maxHeight,
                      share: _readerHeaderBoundShare,
                      child: _ReaderHeader(
                        model: model,
                        compact: compact,
                        dispatch: _controller.dispatch,
                        backFocus: _backFocus,
                        contentsFocus: _contentsFocus,
                        typographyFocus: _typographyFocus,
                        moreFocus: _moreFocus,
                      ),
                    ),
                    for (final row in _panelRows(model, compact: compact))
                      _boundedChrome(
                        viewportHeight: constraints.maxHeight,
                        share: _readerPanelBoundShare,
                        child: row,
                      ),
                    // The search bar is its own row below the panels (RD-11);
                    // search is independent of the three exclusive panels.
                    if (model.searchOpen &&
                        model.document != null &&
                        model.typography.searchable)
                      _boundedChrome(
                        viewportHeight: constraints.maxHeight,
                        share: _readerPanelBoundShare,
                        child: _ReaderSearchBar(
                          model: model,
                          compact: compact,
                          dispatch: _controller.dispatch,
                        ),
                      ),
                    // A content failure is shown inside the document view; the
                    // alert is for an open that never produced one.
                    if (model.error != null &&
                        !(model.document != null &&
                            model.contentState == ReaderContentState.failed))
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight:
                              constraints.maxHeight * _readerAlertBoundShare,
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
                    Expanded(child: _readerBody(model, compact: compact)),
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight:
                            constraints.maxHeight * _readerAlertBoundShare,
                      ),
                      child: _ReaderErrorSurfaces(model: model),
                    ),
                    // The status bar stays mounted while an open is in flight:
                    // the `loading` wording is a live region and the bar itself
                    // is hidden without a document (`hasDocument`), so the
                    // opening state must not remove the status surface.
                    _boundedChrome(
                      viewportHeight: constraints.maxHeight,
                      share: _readerStatusBoundShare,
                      child: _ReaderStatusBar(model: model),
                    ),
                    if (widget.debugPathEntry) ...[
                      const SizedBox(height: 12),
                      // A dev/test-only entry, bounded so a short viewport at
                      // a scaled interface cannot overflow the reader column.
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight:
                              constraints.maxHeight * _readerDevEntryBoundShare,
                        ),
                        child: SingleChildScrollView(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: ShosaiTokens
                                  .layoutReaderChromeHeaderPaddingHorizontal,
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
    );
    return _withReaderLocalizations(context, reader);
  }

  /// Reader-chrome shortcuts: `Ctrl+W`, `Ctrl+Tab` and `Ctrl+1..9`.
  ///
  /// The modifier is platform-adapted (Command on macOS) and mirrors the Iced
  /// reference. Chrome shortcuts must not fire while a text field has focus
  /// (search input, page input, note editor), so the handler ignores them then.
  Widget _withChromeShortcuts(Widget child) {
    final primary = defaultTargetPlatform == TargetPlatform.macOS;
    final digits = [
      LogicalKeyboardKey.digit1,
      LogicalKeyboardKey.digit2,
      LogicalKeyboardKey.digit3,
      LogicalKeyboardKey.digit4,
      LogicalKeyboardKey.digit5,
      LogicalKeyboardKey.digit6,
      LogicalKeyboardKey.digit7,
      LogicalKeyboardKey.digit8,
      LogicalKeyboardKey.digit9,
    ];
    return CallbackShortcuts(
      bindings: {
        SingleActivator(
          LogicalKeyboardKey.keyW,
          control: !primary,
          meta: primary,
        ): _closeActiveTabShortcut,
        SingleActivator(
          LogicalKeyboardKey.tab,
          control: !primary,
          meta: primary,
        ): _nextTabShortcut,
        for (var index = 0; index < digits.length; index += 1)
          SingleActivator(
            digits[index],
            control: !primary,
            meta: primary,
          ): () =>
              _selectTabShortcut(index),
      },
      child: child,
    );
  }

  void _closeActiveTabShortcut() => _chromeShortcut(() {
    final tabs = _controller.model.tabs;
    for (final tab in tabs) {
      if (tab.selected) {
        _controller.dispatch(ReaderTabCloseRequested(tab.id));
        return;
      }
    }
  });

  void _nextTabShortcut() => _chromeShortcut(() {
    final tabs = _controller.model.tabs;
    final index = tabs.indexWhere((tab) => tab.selected);
    if (tabs.length < 2 || index < 0) return;
    _controller.dispatch(
      ReaderTabActivated(tabs[(index + 1) % tabs.length].id),
    );
  });

  void _selectTabShortcut(int index) => _chromeShortcut(() {
    final tabs = _controller.model.tabs;
    if (index < tabs.length) {
      _controller.dispatch(ReaderTabActivated(tabs[index].id));
    }
  });

  void _chromeShortcut(VoidCallback action) {
    final focus = FocusManager.instance.primaryFocus;
    final context = focus?.context;
    if (context != null &&
        context.findAncestorWidgetOfExactType<EditableText>() != null) {
      return;
    }
    action();
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

  /// The full-width panel rows (RD-13).
  ///
  /// The Contents panel is a side panel at wide widths and replaces the body
  /// in compact, mirroring the pinned reference; the typography and more panels
  /// are rows below the header. Panel bodies are 4C's.
  List<Widget> _panelRows(ReaderModel model, {required bool compact}) {
    final panel = model.openPanel;
    if (panel == null || panel == ReaderPanel.contents) return const [];
    return [
      _ReaderPanelHost(
        panel: panel,
        model: model,
        compact: compact,
        dispatch: _controller.dispatch,
        focusNode: _panelFocus,
      ),
    ];
  }

  Widget _readerBody(ReaderModel model, {required bool compact}) {
    final content = _ReaderContentPane(
      key: _contentKey,
      model: model,
      dispatch: _controller.dispatch,
      readerFocus: _readerFocus,
      actionFocus: _actionFocus,
      debugPathEntry: widget.debugPathEntry,
    );
    // The reader palette is the *document* palette (owner decision 2026-09-28):
    // the surface the page (or the no-document welcome body) sits on follows the
    // reader theme, while the shared chrome around it keeps the application
    // palette. Painting it here preserves the pre-decision document-area
    // backdrop — including behind the RD-06 edge columns — instead of letting
    // the light chrome scaffold show through.
    Widget surface() => ColoredBox(
      color: pageColors(model.typography.theme).background,
      child: _ReaderSurface(
        model: model,
        compact: compact,
        dispatch: _controller.dispatch,
        content: content,
      ),
    );
    if (model.openPanel == ReaderPanel.contents) {
      final panel = _ReaderPanelHost(
        panel: ReaderPanel.contents,
        model: model,
        compact: compact,
        dispatch: _controller.dispatch,
        focusNode: _panelFocus,
      );
      if (compact) return panel;
      // The pinned Iced composition keeps the reader surface (and therefore its
      // edge navigation) beside the wide Contents panel; only compact replaces
      // the body with the panel.
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: surface()),
          SizedBox(
            width: ShosaiTokens.layoutReaderBookmarksPanelWidth,
            child: panel,
          ),
        ],
      );
    }
    return surface();
  }
}

/// The content area with the RD-06 edge navigation around it.
class _ReaderSurface extends StatelessWidget {
  const _ReaderSurface({
    required this.model,
    required this.compact,
    required this.dispatch,
    required this.content,
  });

  final ReaderModel model;
  final bool compact;
  final void Function(ReaderMessage) dispatch;
  final Widget content;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final document = model.document;
    final continuous = model.typography.continuous;
    // Edge navigation is hidden entirely in continuous mode and when no
    // document is open (Iced returns the bare content). While no document is
    // open the columns keep their space with the controls invisible, so the
    // content area does not change width when the document arrives and the
    // open is laid out for the width it will keep.
    final showEdges = document != null && !continuous;
    // Only a paginated reader reserves the columns: continuous mode has no
    // edges at all, so reserving there would change the content width when a
    // document arrives and cost a relayout for nothing.
    final reserveSpace = document == null && !continuous;
    final busy = model.busy || model.relayoutBusy;
    final total = document?.logicalUnitCount.toInt() ?? 0;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _edge(
          visible: showEdges || reserveSpace,
          reserved: reserveSpace,
          semanticsKey: const ValueKey('reader-edge-previous'),
          glyph: '‹',
          semanticsLabel: l10n.readerPreviousPage,
          compact: compact,
          onPressed: showEdges && !busy && _canStepPage(model, -1, total)
              ? () => dispatch(pageStepMessage(model, -1))
              : null,
        ),
        Expanded(child: content),
        _edge(
          visible: showEdges || reserveSpace,
          reserved: reserveSpace,
          semanticsKey: const ValueKey('reader-edge-next'),
          glyph: '›',
          semanticsLabel: l10n.readerNextPage,
          compact: compact,
          onPressed: showEdges && !busy && _canStepPage(model, 1, total)
              ? () => dispatch(pageStepMessage(model, 1))
              : null,
        ),
      ],
    );
  }

  Widget _edge({
    required bool visible,
    required bool reserved,
    required Key semanticsKey,
    required String glyph,
    required String semanticsLabel,
    required bool compact,
    required VoidCallback? onPressed,
  }) {
    final button = _ReaderEdgeButton(
      semanticsKey: semanticsKey,
      glyph: glyph,
      semanticsLabel: semanticsLabel,
      compact: compact,
      onPressed: onPressed,
    );
    if (visible && !reserved) return button;
    if (reserved) {
      return Visibility(
        visible: false,
        maintainSize: true,
        maintainAnimation: true,
        maintainState: true,
        child: button,
      );
    }
    return const SizedBox.shrink();
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
        if (model.relayoutBusy) const ShadProgress(minHeight: 4),
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
        const SingleActivator(LogicalKeyboardKey.pageUp): () =>
            dispatch(pageStepMessage(model, -1)),
        const SingleActivator(LogicalKeyboardKey.pageDown): () =>
            dispatch(pageStepMessage(model, 1)),
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
                  // The retained welcome body: the no-document state keeps its
                  // guidance until 4C lands the Iced welcome composition (title
                  // + `Open File` picker action, RD-10). Its copy still
                  // describes the retired path entry, which is recorded as a 4C
                  // item; the production composition renders no path field
                  // (contract §7.2 item 6).
                  ? WelcomePanel(
                      color: pageColors(model.typography.theme).foreground,
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
          if (model.annotations.isNotEmpty)
            ReaderAnnotationStrip(model: model, dispatch: dispatch),
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
  ReaderLayout? _pendingLayout;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final availableWidth = constraints.maxWidth.isFinite
          ? math.max(1.0, constraints.maxWidth).roundToDouble()
          : widget.model.layout.width;
      // The content-box height is reported alongside the width: real EPUB
      // pagination needs the page height, and the retained renderer ignores it.
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
      );
      final observedHeight = availableHeight;
      if (layout != _observedLayout || observedHeight != _observedHeight) {
        _observedLayout = layout;
        _observedHeight = observedHeight;
        _pendingLayout = layout;
      }
      if (_pendingLayout != null && !_scheduled) {
        _scheduled = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _scheduled = false;
          final pending = _pendingLayout;
          final pendingHeight = _observedHeight;
          _pendingLayout = null;
          if (mounted && pending != null) {
            widget.dispatch(
              ReaderViewportChanged(pending, height: pendingHeight),
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

  /// The document-area foreground for the active reader theme
  /// ([pageColors]). The welcome body sits on the document backdrop, so its ink
  /// follows the reader palette while the shared chrome stays on the
  /// application palette (owner decision 2026-09-28); a caller that renders the
  /// panel outside the reader keeps the ambient style.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        'Enter a local document path to exercise the generated Rust bridge.',
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

/// The reader's bundled document faces, parsed once per process.
///
/// The parsed *value* is cached rather than the future that produced it: a
/// settled future belongs to the zone that awaited it, so reusing one across
/// calls (a second reader, or a later relayout) can leave the caller waiting on
/// a completion that will never be delivered to it. Every call therefore gets a
/// fresh future; only the parse is shared.
EpubFontCoverage? _bundledCoverage;
bool _bundledCoverageFailed = false;
Future<EpubFontCoverage?> _bundledFontCoverage() async {
  final cached = _bundledCoverage;
  if (cached != null) return cached;
  if (_bundledCoverageFailed) return null;
  try {
    final inter = await rootBundle.load('../assets/fonts/InterVariable.ttf');
    final noto = await rootBundle.load(
      '../assets/fonts/NotoSansJP-Variable.ttf',
    );
    return _bundledCoverage = EpubFontCoverage.fromFonts([
      inter.buffer.asUint8List(),
      noto.buffer.asUint8List(),
    ]);
  } catch (_) {
    // Without the faces' coverage the reader cannot promise the Dart renderer
    // will draw a chapter, so it keeps the retained renderer instead.
    _bundledCoverageFailed = true;
    return null;
  }
}

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
