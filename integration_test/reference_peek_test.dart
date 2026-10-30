import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shosai_flutter/main.dart';
import 'package:shosai_flutter/reader/epub/surface.dart';
import 'package:shosai_flutter/reader/view.dart';

import '../test/support/production_shell_harness.dart'
    show dismissReaderZonesHint, revealReaderChrome;
import '../test/support/reference_documents.dart';

/// Real engines, application core, fonts, and reader composition; no bridge fake.
/// Run with `flutter test -d linux integration_test/reference_peek_test.dart`.
/// SHOSAI_REFERENCE_ARTIFACTS optionally saves the exercised states as PNGs.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final captureKey = GlobalKey();
  Finder keyed(String value) => find.byKey(ValueKey(value));

  // Optional native pointer input for a review recording, not synthetic hover.
  var pointer = const Offset(20, 20);
  Future<void> tapAt(WidgetTester tester, Offset point) async {
    if (Platform.environment['SHOSAI_REFERENCE_POINTER'] != '1') {
      await tester.tapAt(point);
      return;
    }
    final window = await Process.run('xdotool', [
      'search',
      '--onlyvisible',
      '--pid',
      '$pid',
    ]);
    expect(window.exitCode, 0);
    final id = window.stdout.toString().trim().split('\n').last;
    final arguments = <String>[];
    for (var step = 1; step <= 16; step++) {
      final next = Offset.lerp(pointer, point, step / 16)!;
      arguments.addAll([
        'mousemove',
        '--window',
        id,
        '${next.dx.round()}',
        '${next.dy.round()}',
        'sleep',
        '.02',
      ]);
    }
    arguments.addAll(['click', '1']);
    final result = await Process.run('xdotool', arguments);
    expect(result.exitCode, 0);
    pointer = point;
    await tester.pump(const Duration(milliseconds: 400));
  }

  ReaderEpubPageContentPainter? epub(WidgetTester tester) => tester
      .widgetList<CustomPaint>(find.byType(CustomPaint))
      .map((paint) => paint.painter)
      .whereType<ReaderEpubPageContentPainter>()
      .firstOrNull;

  PagePainter? pdf(WidgetTester tester) => tester
      .widgetList<CustomPaint>(find.byType(CustomPaint))
      .map((paint) => paint.painter)
      .whereType<PagePainter>()
      .where((paint) => paint.image != null)
      .firstOrNull;

  Future<void> until(WidgetTester tester, bool Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 40));
    while (!condition() && DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 50));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(condition(), isTrue);
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> capture(WidgetTester tester, String name) async {
    final path = Platform.environment['SHOSAI_REFERENCE_ARTIFACTS'];
    if (path == null) return;
    await tester.pump();
    final boundary =
        captureKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    await Directory(path).create(recursive: true);
    await File('$path/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
  }

  Offset sourcePoint(WidgetTester tester, Size source, Offset point) {
    final box = tester.renderObject<RenderBox>(keyed('reader-page-paint'));
    final transform = SurfaceTransform.create(BoxFit.contain, source, box.size);
    return box.localToGlobal(
      transform
          .toDestinationRect(Rect.fromLTWH(point.dx, point.dy, 0, 0))
          .center,
    );
  }

  Offset epubLink(WidgetTester tester, String fragment) {
    final page = epub(tester)!.page;
    for (final slice in page.page.slices) {
      for (final placed in placedPageText(slice)) {
        for (final link in placed.block.links) {
          if (!link.href.endsWith(fragment)) continue;
          final rect = placed.block.painter
              .getBoxesForSelection(
                TextSelection(baseOffset: link.start, extentOffset: link.end),
              )
              .first
              .toRect()
              .shift(placed.origin);
          return sourcePoint(
            tester,
            page.box.size,
            page.box.rectToPage(rect).center,
          );
        }
      }
    }
    throw StateError('Reference $fragment is not painted');
  }

  for (final width in [1200.0, 800.0, 390.0]) {
    for (final format in ['epub', 'pdf']) {
      testWidgets('$format peek, dismiss, jump and Back at width $width', (
        tester,
      ) async {
        final propagate = tester.binding.shouldPropagateDevicePointerEvents;
        tester.binding.shouldPropagateDevicePointerEvents =
            Platform.environment['SHOSAI_REFERENCE_POINTER'] == '1';
        try {
          final directory = await Directory.systemTemp.createTemp(
            'shosai-reference-',
          );
          addTearDown(() => directory.delete(recursive: true));
          final path = '${directory.path}/Quiet places.$format';
          await File(
            path,
          ).writeAsBytes(format == 'epub' ? referenceEpub() : referencePdf());
          final bridge = await createApplicationBridge(
            applicationSupportDirectory: () async => directory,
          );
          await tester.pumpWidget(
            ShosaiShell(
              home: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: width,
                  height: 800,
                  child: RepaintBoundary(
                    key: captureKey,
                    child: MediaQuery(
                      data: MediaQueryData(size: Size(width, 800)),
                      child: ReaderScreen(bridge: bridge, initialPath: path),
                    ),
                  ),
                ),
              ),
            ),
          );
          bool onPage(int unit) => format == 'epub'
              ? epub(tester)?.page.unit == unit
              : pdf(tester)?.currentUnit == unit;
          await until(tester, () => onPage(0));
          await dismissReaderZonesHint(tester);
          final form = width == 390
              ? 'phone'
              : width == 800
              ? 'tablet'
              : 'desktop';
          final name = '$format-$form';
          await capture(tester, '$name-source');

          // A complete footnote can be read and closed without a jump or Back.
          Offset linkPoint(int index) => format == 'epub'
              ? epubLink(
                  tester,
                  [
                    'note-one',
                    'observations',
                    'figure-one',
                    'table-one',
                  ][index],
                )
              : sourcePoint(
                  tester,
                  Size(pdf(tester)!.surface.width, pdf(tester)!.surface.height),
                  Offset(
                    160 * pdf(tester)!.surface.width / 612,
                    (index == 0
                            ? 259
                            : index == 1
                            ? 209
                            : index == 2
                            ? 309
                            : 359) *
                        pdf(tester)!.surface.height /
                        792,
                  ),
                );
          if (format == 'pdf') {
            final point = linkPoint(0);
            await tester.tapAt(point);
            await tester.pump(const Duration(milliseconds: 60));
            await tester.tapAt(point);
            await until(
              tester,
              () => keyed('reader-fit-none').evaluate().isNotEmpty,
            );
            expect(
              keyed('reader-reference-peek'),
              findsNothing,
              reason: 'double-tapping a link zooms rather than opening it',
            );
            final center = tester.getCenter(keyed('reader-document-semantics'));
            await tester.tapAt(center);
            await tester.pump(const Duration(milliseconds: 60));
            await tester.tapAt(center);
            await until(
              tester,
              () => keyed('reader-fit-contain').evaluate().isNotEmpty,
            );
            await tester.dragFrom(linkPoint(0), const Offset(-90, 0));
            await until(tester, () => onPage(1));
            expect(
              keyed('reader-reference-peek'),
              findsNothing,
              reason:
                  'swiping over a link turns the page rather than opening it',
            );
            await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
            await until(tester, () => onPage(0));
          }
          await tapAt(tester, linkPoint(0));
          await until(
            tester,
            () => keyed('reader-reference-peek').evaluate().isNotEmpty,
          );
          expect(
            onPage(0),
            isTrue,
            reason: 'peek must leave the source page installed',
          );
          expect(
            find.textContaining('old name for the sheltered bend'),
            findsOneWidget,
          );
          expect(keyed('reader-back-pill'), findsNothing);
          await capture(tester, '$name-footnote');
          expect(
            tester.getSize(keyed('reader-reference-go-to')).height,
            greaterThanOrEqualTo(44),
          );
          if (width == 390) {
            final handle = keyed('reader-reference-drag-handle');
            await tester.drag(handle, const Offset(0, -260));
            await tester.pumpAndSettle();
            await capture(tester, '$name-expanded');
            await tester.drag(handle, const Offset(0, 500));
            await until(
              tester,
              () => keyed('reader-reference-peek').evaluate().isEmpty,
            );
            expect(onPage(0), isTrue);
            expect(keyed('reader-back-pill'), findsNothing);
            await tapAt(tester, linkPoint(0));
            await until(
              tester,
              () => keyed('reader-reference-peek').evaluate().isNotEmpty,
            );
          }
          await tapAt(
            tester,
            tester.getCenter(keyed('reader-reference-close')),
          );
          await until(
            tester,
            () => keyed('reader-reference-peek').evaluate().isEmpty,
          );
          expect(onPage(0), isTrue);

          for (var index = 1; index <= 3; index++) {
            await tapAt(tester, linkPoint(index));
            await until(
              tester,
              () => keyed('reader-reference-peek').evaluate().isNotEmpty,
            );
            expect(onPage(0), isTrue);
            await capture(tester, '$name-peek-$index');
            await tapAt(
              tester,
              tester.getCenter(keyed('reader-reference-go-to')),
            );
            await until(tester, () => onPage(1));
            expect(keyed('reader-reference-peek'), findsNothing);
            expect(keyed('reader-back-pill'), findsOneWidget);
            await capture(tester, '$name-target-$index');
            await tapAt(tester, tester.getCenter(keyed('reader-back')));
            await until(tester, () => onPage(0));
            expect(keyed('reader-back-pill'), findsNothing);
            await capture(tester, '$name-back-$index');
          }

          // Contents uses the same non-destructive preview contract.
          if (format == 'epub') {
            await revealReaderChrome(tester);
            await tester.tap(keyed('reader-header-contents'));
            await until(
              tester,
              () => keyed('reader-contents-entry-1').evaluate().isNotEmpty,
            );
            await tester.tap(keyed('reader-contents-entry-1'));
            await until(
              tester,
              () => keyed('reader-reference-peek').evaluate().isNotEmpty,
            );
            expect(onPage(0), isTrue);
            await tester.sendKeyEvent(LogicalKeyboardKey.escape);
            await until(
              tester,
              () => keyed('reader-reference-peek').evaluate().isEmpty,
            );
            expect(keyed('reader-back-pill'), findsNothing);
          }
          if (width == 1200 && format == 'pdf') {
            await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
            await until(tester, () => onPage(1));
            final spread = pdf(tester)!.spread!;
            final surface = pdf(tester)!.surface;
            final scale = surface.height / 792;
            await tapAt(
              tester,
              sourcePoint(
                tester,
                Size(surface.width, surface.height),
                Offset(spread.facingLeft + 160 * scale, 179 * scale),
              ),
            );
            await until(
              tester,
              () => keyed('reader-reference-peek').evaluate().isNotEmpty,
            );
            await tapAt(
              tester,
              tester.getCenter(keyed('reader-reference-go-to')),
            );
            await until(tester, () => onPage(0));
            expect(
              find.text('Back to page 3'),
              findsOneWidget,
              reason:
                  'a link on the facing page records that page as its source',
            );
            await tapAt(tester, tester.getCenter(keyed('reader-back')));
            await until(tester, () => onPage(1));
          }
          if (width == 1200 && format == 'epub') {
            await revealReaderChrome(tester);
            await tester.tap(keyed('reader-header-notes'));
            await tester.pumpAndSettle();
            final size = epub(tester)!.page.box.size;
            await tapAt(tester, linkPoint(0));
            await until(
              tester,
              () => keyed('reader-reference-peek').evaluate().isNotEmpty,
            );
            expect(
              epub(tester)!.page.box.size,
              size,
              reason:
                  'a peek must not remove docked Notes and relayout the page',
            );
            await tester.sendKeyEvent(LogicalKeyboardKey.escape);
            await until(
              tester,
              () => keyed('reader-reference-peek').evaluate().isEmpty,
            );
          }
          if (width == 390) {
            await tapAt(tester, linkPoint(0));
            await until(
              tester,
              () => keyed('reader-reference-peek').evaluate().isNotEmpty,
            );
            await tester.binding.handlePopRoute();
            await until(
              tester,
              () => keyed('reader-reference-peek').evaluate().isEmpty,
            );
            expect(
              onPage(0),
              isTrue,
              reason: 'system Back dismisses the sheet, not the reader',
            );
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await until(tester, () => bridge.isDisposed);
        } finally {
          tester.binding.shouldPropagateDevicePointerEvents = propagate;
        }
      });
    }
  }
}
