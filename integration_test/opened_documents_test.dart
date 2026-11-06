import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shosai_flutter/core/bridge.dart';
import 'package:shosai_flutter/main.dart';

/// Desktop-host check of the shared intake with the real core and production UI.
/// Only the OS delivery channel is substituted; native dispatch needs separate
/// Android/Finder/Dock checks. Run from the repository root, e.g.:
/// flutter test -d linux integration_test/opened_documents_test.dart
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // Absolute fixture root for device and simulator runs; host runs keep the
  // repository-relative default. See pdf_columns_continuous_test.dart.
  const fixtureRoot = String.fromEnvironment(
    'SHOSAI_FIXTURES',
    defaultValue: 'fixtures',
  );

  testWidgets(
    'opened EPUB and PDF become durable managed library books',
    (tester) async {
      final directory = await Directory.systemTemp.createTemp('shosai-opened-');
      addTearDown(() => directory.delete(recursive: true));
      addTearDown(closeApplicationCores);
      // The Linux host has no OS Open in registration. Exercise the Android
      // composition and native-cleanup protocol against its real Dart core.
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final originalEpub = File('$fixtureRoot/sample.epub').absolute;
      final originalPdf = File('$fixtureRoot/sample.pdf').absolute;
      final epub = await originalEpub.copy('${directory.path}/arrival.epub');
      final pdf = await originalPdf.copy('${directory.path}/arrival.pdf');
      const channel = MethodChannel('dev.shosai/opened_documents');
      final messenger = tester.binding.defaultBinaryMessenger;
      var pending = [epub.path];
      final owned = {epub.path, pdf.path};
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'discard') {
          for (final path in (call.arguments! as List).cast<String>()) {
            if (owned.remove(path)) await File(path).delete();
          }
          return null;
        }
        final taken = pending;
        pending = [];
        return taken;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final owner = await applicationCoreOwner(
        applicationSupportDirectory: () async =>
            Directory('${directory.path}/core'),
      );
      await tester.pumpWidget(ShosaiApp(productBridgeFactory: owner.bridge));
      await _pumpUntil(tester, () => !epub.existsSync());
      expect(find.text('Sample Book'), findsWidgets);

      pending = [pdf.path];
      await messenger.handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(const MethodCall('opened')),
        (_) {},
      );
      await _pumpUntil(tester, () => !pdf.existsSync());
      final bridge = owner.bridge();
      final cancellation = bridge.createCancellation();
      final page = await bridge.libraryPage(
        limit: 10,
        offset: 0,
        cancellationId: cancellation,
      );
      expect(page.books.map((book) => book.format).toSet(), {
        FlutterBookFormat.epub,
        FlutterBookFormat.pdf,
      });
      expect(page.books.every((book) => book.managed), isTrue);
      for (final book in page.books) {
        expect(book.pathKey, startsWith('${directory.path}/core/books/'));
        expect(File(book.pathKey).existsSync(), isTrue);
        final opened = await bridge.openLibraryBook(
          bookId: book.bookId,
          cancellationId: cancellation,
        );
        expect(opened.logicalUnitCount, greaterThan(BigInt.zero));
        bridge.releaseDocument(handle: opened.handle);
      }
      expect(originalEpub.existsSync(), isTrue);
      expect(originalPdf.existsSync(), isTrue);
      bridge.releaseCancellation(id: cancellation);
      bridge.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
      debugDefaultTargetPlatformOverride = null;
    },
    skip: !Platform.isLinux && !Platform.isMacOS,
  );
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 60));
  while (!ready() && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(ready(), isTrue, reason: 'managed import did not finish');
  await tester.pumpAndSettle();
}
