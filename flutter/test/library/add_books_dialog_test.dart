import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shosai_flutter/library/view.dart';
import 'package:shosai_flutter/src/rust/api.dart';

class _Bridge implements FlutterBridge {
  @override
  bool get isDisposed => false;
  @override
  void dispose() {}
  @override
  BigInt createCancellation() => BigInt.one;
  @override
  bool cancel({required BigInt id}) => true;
  @override
  bool releaseCancellation({required BigInt id}) => true;
  @override
  Future<FlutterLibraryPage> libraryPage({
    String? query,
    FlutterBookFormat? format,
    required int limit,
    required int offset,
    required BigInt cancellationId,
  }) async => const FlutterLibraryPage(books: [], hasMore: false);
  @override
  Future<FlutterReaderSettings> loadReaderSettings({
    required BigInt cancellationId,
  }) async => const FlutterReaderSettings(
    continuous: false,
    theme: 'light',
    epubFontSize: 18,
    epubLineSpacing: 1.5,
    pdfZoom: 0,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('add-books dialog lays out under active semantics', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(
      ShadApp(
        home: ProductShell(
          bridgeFactory: () => _Bridge(),
          readerBuilder: (_, _, _, _, _, _) => const SizedBox(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add books'));
    // The import effect stays pending while the picker is open, so settle is
    // not available; pump the dialog entrance instead.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Choose files'), findsOneWidget);
    expect(find.text('Choose a folder'), findsOneWidget);
    expect(tester.takeException(), isNull);

    debugDefaultTargetPlatformOverride = null;
    semantics.dispose();
  });
}
