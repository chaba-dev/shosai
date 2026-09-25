import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;
import 'package:path_provider/path_provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shosai_flutter/app_theme.dart';
import 'package:shosai_flutter/l10n/app_localizations.dart';
import 'package:shosai_flutter/library/view.dart';
import 'package:shosai_flutter/notices/notices.dart';
import 'package:shosai_flutter/reader/view.dart';
import 'package:shosai_flutter/src/rust/api.dart';
import 'package:shosai_flutter/src/rust/frb_generated.dart';

export 'package:shosai_flutter/reader/view.dart'
    show
        PagePainter,
        ReaderScreen,
        WelcomePanel,
        pageColors,
        pageImageSource,
        usesExplicitSelectionAnnouncements;

export 'package:shosai_flutter/reader/controller.dart'
    show
        AnnotationAssociationPicker,
        AnnotationAssociationPickerCanceller,
        AnnotationAssociationCancelled,
        AnnotationAssociationChoice,
        AnnotationAssociationNextPage,
        AnnotationAssociationPage,
        AnnotationAssociationPreviousPage,
        AnnotationAssociationSelected,
        PageDecoder,
        NoteEditorCanceller,
        ReaderController,
        ReaderPersistenceException,
        ReaderAnnotationAssociationRequested,
        ReaderAnnotationReloadRequested,
        ReaderAnnotationDeleted,
        ReaderAnnotationNavigated,
        ReaderAnnotationNoteRequested,
        ReaderAnnotationUpdated,
        ReaderFocusTarget,
        ReaderLayout,
        ReaderLayoutChanged,
        ReaderViewportChanged,
        ReaderMemoryPressureReceived,
        ReaderMessage,
        ReaderModel,
        ReaderOpenRequested,
        ReaderResumed,
        ReaderSelection,
        ReaderSelectionAllRequested,
        ReaderSelectionAnnouncer,
        ReaderSelectionActionsRequested,
        ReaderSelectionCancelled,
        ReaderSelectionCommitted,
        ReaderSelectionCopyRequested,
        ReaderSelectionEnded,
        ReaderSelectionExtended,
        ReaderSelectionKeyboardExtended,
        ReaderSelectionMovement,
        ReaderSelectionNoteRequested,
        ReaderSelectionPhase,
        ReaderSelectionPointerCancelled,
        ReaderSelectionPointerEnded,
        ReaderSelectionPointerMoved,
        ReaderSelectionPointerPressedOutside,
        ReaderSelectionPointerStarted,
        ReaderContentState,
        ReaderSelectionStarted,
        ReaderSuspended,
        ReaderUnitRequested,
        ReaderSearchRequested,
        ReaderBookmarkToggled,
        ReaderBookmarkNoteRequested,
        ReaderBookmarkDeleted,
        ReaderBookmarkNavigated,
        ReaderToolsToggled,
        premultiplyRgba;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init(externalLibrary: nativeLibrary());
  final directory = await getApplicationSupportDirectory();
  final databasePath = '${directory.path}/shosai.sqlite3';
  runApp(
    ShosaiApp(
      productBridgeFactory: () =>
          FlutterBridge.withDatabasePath(databasePath: databasePath),
    ),
  );
}

Future<FlutterBridge> createApplicationBridge({
  Future<Directory> Function()? applicationSupportDirectory,
  String databaseName = 'annotations.sqlite3',
}) async {
  final directory =
      await (applicationSupportDirectory ?? getApplicationSupportDirectory)();
  return FlutterBridge.withDatabasePath(
    databasePath: '${directory.path}/$databaseName',
  );
}

ExternalLibrary? nativeLibrary() {
  final executableDirectory = File(Platform.resolvedExecutable).parent.path;
  if (Platform.isLinux) {
    return ExternalLibrary.open(
      '$executableDirectory/lib/libshosai_flutter_bridge.so',
    );
  }
  if (Platform.isMacOS) {
    return ExternalLibrary.open(
      '$executableDirectory/../Frameworks/libshosai_flutter_bridge.dylib',
    );
  }
  if (Platform.isIOS) {
    return ExternalLibrary.open(
      'shosai_flutter_bridge.framework/shosai_flutter_bridge',
    );
  }
  return null;
}

/// The production application composition: Shad and Material themes, the
/// localization delegates, the [NoticeHost] that presents controller notices
/// and the [ShadAppBuilder] layer that installs the toaster and sonner hosts.
/// [home] is the shell content, so widget tests can render the real composition
/// while substituting only the platform boundary beneath it.
///
/// [locale] is the test injection point for the application language. The
/// production app leaves it null, so the supported system locale is used and an
/// unsupported system language falls back to the first supported locale
/// (English).
///
/// [noticeCenter] is the center [ShosaiApp] creates so the same reporter can be
/// injected into the feature controllers it builds. A test may pass its own
/// center to drive notices through the real host; when omitted, the shell owns
/// one for the lifetime of the render.
class ShosaiShell extends StatefulWidget {
  const ShosaiShell({
    super.key,
    required this.home,
    this.locale,
    this.noticeCenter,
  });

  final Widget home;
  final Locale? locale;
  final NoticeCenter? noticeCenter;

  @override
  State<ShosaiShell> createState() => _ShosaiShellState();
}

class _ShosaiShellState extends State<ShosaiShell> {
  NoticeCenter? _ownedCenter;

  NoticeCenter get _center =>
      widget.noticeCenter ?? (_ownedCenter ??= NoticeCenter());

  @override
  void didUpdateWidget(ShosaiShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.noticeCenter != widget.noticeCenter) {
      _ownedCenter?.dispose();
      _ownedCenter = null;
    }
  }

  @override
  void dispose() {
    _ownedCenter?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ShadApp.custom(
      theme: shosaiShadTheme(Brightness.light),
      darkTheme: shosaiShadTheme(Brightness.dark),
      appBuilder: (context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        locale: widget.locale,
        theme: shosaiMaterialTheme(context),
        darkTheme: shosaiMaterialTheme(context, Brightness.dark),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalShadLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => ShadAppBuilder(child: child!),
        restorationScopeId: 'shosai',
        // The notice host sits inside the navigator's route content so its
        // surfaces have an Overlay (tooltips, focus) and are covered by a modal
        // route the way the rest of the home surface is; the Sonner toasts it
        // presents live in the host ShadAppBuilder installs above the navigator.
        home: NoticeHost(center: _center, child: widget.home),
      ),
    );
  }
}

class ShosaiApp extends StatefulWidget {
  const ShosaiApp({
    super.key,
    this.bridge,
    this.productBridgeFactory,
    this.locale,
  });

  final FlutterBridge? bridge;
  final FlutterBridge Function()? productBridgeFactory;

  /// Application language for tests; the production app leaves it null and uses
  /// the supported system locale.
  final Locale? locale;

  @override
  State<ShosaiApp> createState() => _ShosaiAppState();
}

class _ShosaiAppState extends State<ShosaiApp> {
  /// The application's single notice center.
  ///
  /// It outlives every feature controller, so a notice reported by one surface
  /// survives navigation and is presented by the one host the shell installs.
  final NoticeCenter _noticeCenter = NoticeCenter();

  @override
  void dispose() {
    _noticeCenter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ShosaiShell(
      locale: widget.locale,
      noticeCenter: _noticeCenter,
      home: widget.productBridgeFactory == null
          ? ReaderScreen(bridge: widget.bridge)
          : ProductShell(
              bridgeFactory: widget.productBridgeFactory!,
              noticeReporter: _noticeCenter.reporter,
              readerBuilder:
                  (bridge, book, settings, path, bookId, locatorChanged) =>
                      ReaderScreen(
                        bridge: bridge,
                        initialPath: path,
                        initialBookId: bookId,
                        initialSettings: settings,
                        onLocatorChanged: locatorChanged,
                      ),
            ),
    );
  }
}
