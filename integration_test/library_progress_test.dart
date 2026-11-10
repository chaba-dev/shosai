import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shosai_flutter/core/bridge.dart';
import 'package:shosai_flutter/core/library_connection.dart';
import 'package:shosai_flutter/core/records.dart';
import 'package:shosai_flutter/library/view.dart';
import 'package:shosai_flutter/main.dart';
import 'package:shosai_flutter/shell/view.dart';

import '../test/support/epub_navigation_fixture.dart';
import '../test/support/production_shell_harness.dart' show revealReaderChrome;
import '../test/support/reference_documents.dart';

// Real Drive transport/metadata/media, redirected to a local HTTP fixture.
// Only authorization storage is faked; no Google account or token is used.
class _DriveHttp extends HttpOverrides {
  _DriveHttp(this.port);
  final int port;

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _DriveClient(super.createHttpClient(context), port);
}

class _DriveClient extends Fake implements HttpClient {
  _DriveClient(this.client, this.port);
  final HttpClient client;
  final int port;

  @override
  set connectionTimeout(Duration? value) => client.connectionTimeout = value;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) => client.openUrl(
    method,
    url.host == 'www.googleapis.com'
        ? Uri.http('127.0.0.1:$port', url.path, url.queryParameters)
        : url,
  );

  @override
  void close({bool force = false}) => client.close(force: force);
}

/// Production shell, reader, PDFium and SQLite. The filtered shelf reproduces
/// stale open-book metadata independently of the reported iPhone session.
/// SHOSAI_PROGRESS_ARTIFACTS saves review PNGs.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final captureKey = GlobalKey();

  // Absolute fixture root for device and simulator runs; host runs keep the
  // repository-relative default. See pdf_columns_continuous_test.dart.
  const fixtureRoot = String.fromEnvironment(
    'SHOSAI_FIXTURES',
    defaultValue: 'fixtures',
  );

  Future<void> capture(String name) async {
    final artifacts = Platform.environment['SHOSAI_PROGRESS_ARTIFACTS'];
    if (artifacts == null) return;
    final boundary =
        captureKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    await Directory(artifacts).create(recursive: true);
    await File('$artifacts/$name.png').writeAsBytes(data!.buffer.asUint8List());
  }

  for (final drive in [false, true]) {
    for (final fit in [FlutterPdfFit.fitWidth, FlutterPdfFit.columns]) {
      testWidgets(
        'first ${drive ? 'Drive' : 'local'} PDF screen records reading in ${fit.name}',
        (tester) async {
          final directory = await Directory.systemTemp.createTemp(
            'first-screen-',
          );
          final owner = await applicationCoreOwner(
            applicationSupportDirectory: () async => directory,
          );
          final bridge = owner.bridge();
          final records = recordsOf(bridge);
          final path = '${directory.path}/Thrift.pdf';
          await File('$fixtureRoot/pdf-columns/thrift.pdf').copy(path);
          if (drive) {
            final bytes = await File(path).readAsBytes();
            final server = await HttpServer.bind(
              InternetAddress.loopbackIPv4,
              0,
            );
            final previous = HttpOverrides.current;
            HttpOverrides.global = _DriveHttp(server.port);
            final previousStorage = FlutterSecureStoragePlatform.instance;
            const key = 'shosai.google-drive.drive.fixture';
            FlutterSecureStorage.setMockInitialValues({
              key: jsonEncode({'kind': 'android', 'access_token': 'fixture'}),
            });
            addTearDown(() async {
              FlutterSecureStoragePlatform.instance = previousStorage;
              HttpOverrides.global = previous;
              await server.close(force: true);
            });
            final metadata = {
              'id': 'paper',
              'name': path.split('/').last,
              'mimeType': 'application/pdf',
              'size': '${bytes.length}',
              'version': '1',
              'ownedByMe': true,
              'trashed': false,
            };
            server.listen((request) async {
              if (request.uri.queryParameters['alt'] == 'media') {
                final range = request.headers.value('range');
                if (range == null) {
                  request.response.add(bytes);
                } else {
                  final match = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(range)!;
                  final start = int.parse(match[1]!);
                  final end = int.parse(
                    match[2]!,
                  ).clamp(start, bytes.length - 1);
                  request.response.statusCode = 206;
                  request.response.headers.set(
                    'content-range',
                    'bytes $start-$end/${bytes.length}',
                  );
                  request.response.add(bytes.sublist(start, end + 1));
                }
              } else {
                request.response.headers.contentType = ContentType.json;
                request.response.write(
                  jsonEncode(
                    request.uri.path == '/drive/v3/files'
                        ? {
                            'files': [metadata],
                          }
                        : metadata,
                  ),
                );
              }
              await request.response.close();
            });
            await owner.core.folders.add(
              LibraryConnection('drive', 'Google Drive', 'google-drive', {
                'credential': key,
              }),
            );
          } else {
            await records.importPaths(
              pathKeys: [path],
              managed: false,
              cancellationId: bridge.createCancellation(),
            );
          }
          await records.saveReaderSettings(
            value: FlutterReaderSettings(
              continuous: false,
              theme: 'light',
              epubFontSize: 18,
              epubLineSpacing: 1.6,
              pdfZoom: 0,
              pdfFit: fit,
              twoPages: false,
              zonesHintDismissed: true,
            ),
          );
          tester.view.physicalSize = const Size(430, 932);
          tester.view.devicePixelRatio = 1;
          await binding.setSurfaceSize(const Size(430, 932));
          addTearDown(() async {
            await tester.pumpWidget(const SizedBox());
            await closeApplicationCores();
            await directory.delete(recursive: true);
            await binding.setSurfaceSize(null);
            tester.view.reset();
          });
          await tester.pumpWidget(
            RepaintBoundary(
              key: captureKey,
              child: ShosaiApp(
                locale: const Locale('ja'),
                productBridgeFactory: owner.bridge,
              ),
            ),
          );
          Future<void> until(bool Function() ready) async {
            for (var i = 0; i < 400 && !ready(); i++) {
              await tester.pump(const Duration(milliseconds: 20));
            }
            expect(ready(), isTrue);
            await tester.pumpAndSettle();
          }

          bool libraryReady() {
            final collection = find.byType(LibraryCollection);
            if (collection.evaluate().isEmpty) return false;
            final model = tester.widget<LibraryCollection>(collection).model;
            return !model.loading && !model.busy;
          }

          await until(libraryReady);
          final entry = find.text(drive ? 'Google Drive' : '未読');
          expect(entry, findsOneWidget);
          await capture('${drive ? 'drive' : 'local'}-${fit.name}-before');
          await tester.tap(entry);
          await until(
            () => tester
                .widgetList<CustomPaint>(find.byType(CustomPaint))
                .map((paint) => paint.painter)
                .whereType<PagePainter>()
                .any(
                  (paint) =>
                      (paint.image != null || paint.columns != null) &&
                      (paint.columns != null) == (fit == FlutterPdfFit.columns),
                ),
          );
          // No page turn or fit switch: simply reading the first screen counts.
          final back = find
              .byKey(const ValueKey('reader-header-back'))
              .hitTestable();
          for (var i = 0; i < 4 && back.evaluate().isEmpty; i++) {
            await revealReaderChrome(tester);
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(back, findsOneWidget);
          await tester.tap(back);
          await until(libraryReady);
          expect(find.text('未読'), findsNothing);
          expect(find.text('13%'), findsNWidgets(2));
          await capture('${drive ? 'drive' : 'local'}-${fit.name}-after');
          final book = (await records.libraryPage(
            limit: 10,
            offset: 0,
            cancellationId: bridge.createCancellation(),
          )).books.single;
          expect(book.progress, .125);
          expect(book.lastRead, isNotNull);
          final saved = await records.loadReadingState(
            bookId: book.bookId,
            cancellationId: bridge.createCancellation(),
          );
          expect(saved!.unit, BigInt.zero);
        },
      );
    }
  }

  testWidgets(
    'reader progress reaches the Japanese library and filtered shelf',
    (tester) async {
      final directory = await Directory.systemTemp.createTemp(
        'shosai-progress-',
      );
      final owner = await applicationCoreOwner(
        applicationSupportDirectory: () async => directory,
      );
      final bridge = owner.bridge();
      final records = recordsOf(bridge);
      final pdf = File('${directory.path}/Thrift.pdf')
        ..writeAsBytesSync(referencePdf());
      final epub = File('${directory.path}/ResNet.epub')
        ..writeAsBytesSync(navigationEpub());
      await records.importPaths(
        pathKeys: [pdf.path, epub.path],
        managed: false,
        cancellationId: bridge.createCancellation(),
      );
      final books = (await records.libraryPage(
        limit: 10,
        offset: 0,
        cancellationId: bridge.createCancellation(),
      )).books;
      final book = books.singleWhere((b) => b.format == FlutterBookFormat.pdf);
      final unread = books.singleWhere(
        (b) => b.format == FlutterBookFormat.epub,
      );
      // An open tab and recorded progress are independent, including a tab
      // restored from a session with no recorded reading yet.
      await records.saveOpenBooks((
        books: [(book: unread, path: unread.pathKey, bookId: unread.bookId)],
        current: unread.bookId,
        reading: false,
      ));
      await records.saveReadingState(
        bookId: book.bookId,
        value: FlutterReadingState(unit: BigInt.zero, zoom: 1, progress: .13),
        unitCount: BigInt.from(3),
      );
      await records.saveReaderSettings(
        value: const FlutterReaderSettings(
          continuous: false,
          theme: 'light',
          epubFontSize: 18,
          epubLineSpacing: 1.6,
          pdfZoom: 0,
          twoPages: false,
          zonesHintDismissed: true,
        ),
      );
      tester.view.physicalSize = const Size(430, 932);
      tester.view.devicePixelRatio = 1;
      await binding.setSurfaceSize(const Size(430, 932));
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        bridge.dispose();
        await closeApplicationCores();
        await directory.delete(recursive: true);
        await binding.setSurfaceSize(null);
        tester.view.reset();
      });
      await tester.pumpWidget(
        RepaintBoundary(
          key: captureKey,
          child: ShosaiApp(
            locale: const Locale('ja'),
            productBridgeFactory: owner.bridge,
          ),
        ),
      );

      Future<void> until(bool Function() ready) async {
        for (var i = 0; i < 400 && !ready(); i++) {
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(ready(), isTrue);
        await tester.pumpAndSettle();
      }

      bool libraryReady() {
        final collection = find.byType(LibraryCollection);
        if (collection.evaluate().isEmpty) return false;
        final model = tester.widget<LibraryCollection>(collection).model;
        return !model.loading && !model.busy;
      }

      Finder card(int bookId) {
        final model = tester
            .widget<LibraryCollection>(find.byType(LibraryCollection))
            .model;
        final edition = model.editions!
            .where(
              (entry) => entry.files.any((file) => file.book?.id == bookId),
            )
            .firstOrNull;
        return find.byKey(ValueKey('edition-${edition?.id}'));
      }

      PagePainter? page() => tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((paint) => paint.painter)
          .whereType<PagePainter>()
          .where((paint) => paint.image != null)
          .firstOrNull;
      Finder shelfStatus(String text) => find.descendant(
        of: find.byType(ShellReadingNowCards),
        matching: find.text(text),
      );

      await until(
        () => libraryReady() && card(book.bookId).evaluate().isNotEmpty,
      );
      expect(
        find.descendant(of: card(book.bookId), matching: find.text('13%')),
        findsOneWidget,
      );
      final unreadCard = card(unread.bookId);
      await until(
        () => find
            .descendant(of: unreadCard, matching: find.text('開いた本'))
            .evaluate()
            .isNotEmpty,
      );
      expect(
        find.descendant(of: unreadCard, matching: find.text('未読')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: unreadCard, matching: find.text('読書中')),
        findsNothing,
      );
      await capture('library-before');
      await tester.tap(card(book.bookId));
      await until(() => page() != null);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await until(() => page()?.currentUnit == 1);
      await revealReaderChrome(tester);
      await capture('reader-page-two');
      await tester.tap(find.byKey(const ValueKey('reader-header-back')));
      await until(libraryReady);
      expect(shelfStatus('67%'), findsOneWidget);
      expect(
        find.descendant(of: card(book.bookId), matching: find.text('67%')),
        findsOneWidget,
      );
      await capture('library-after');

      // Keep the PDF open, but exclude it from the library's visible results.
      await tester.tap(find.text('EPUB').first);
      await until(() => libraryReady() && card(book.bookId).evaluate().isEmpty);
      expect(shelfStatus('67%'), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.byType(ShellReadingNowCards),
          matching: find.text('67%'),
        ),
      );
      await until(() => page() != null);
      expect(page()!.currentUnit, 1, reason: 'the saved position reopens');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await until(() => page()?.currentUnit == 2);
      await revealReaderChrome(tester);
      await tester.tap(find.byKey(const ValueKey('reader-header-back')));
      await until(libraryReady);
      final persisted = (await records.loadOpenBooks())!.books;
      expect(
        persisted
            .singleWhere((open) => open.book.bookId == book.bookId)
            .book
            .progress,
        1,
        reason: 'the reader saved the last page',
      );
      expect(
        persisted
            .singleWhere((open) => open.book.bookId == unread.bookId)
            .book
            .progress,
        0,
        reason: 'reading the PDF must not change the other tab',
      );
      expect(
        card(book.bookId),
        findsNothing,
        reason: 'the EPUB filter is still active',
      );
      expect(shelfStatus('読了'), findsOneWidget);
      expect(shelfStatus('67%'), findsNothing);
      await capture('filtered-library-after');
    },
  );
}
