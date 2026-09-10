import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shosai_flutter/main.dart';
import 'package:shosai_flutter/src/rust/api.dart';
import 'package:shosai_flutter/src/rust/frb_generated.dart';

const _warmups = 5;
const _samples = 50;
const _resourceCycles = 20;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('M2 packaged bridge and reader measurements', (tester) async {
    await RustLib.init(externalLibrary: nativeLibrary());

    final directory = await Directory.systemTemp.createTemp('shosai-m2-');
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    final fixture = '${directory.path}/fixture.pdf';
    await File(fixture).writeAsBytes(_selectablePdf());
    final bridge = FlutterBridge.withDatabasePath(
      databasePath: '${directory.path}/annotations.sqlite',
    );
    addTearDown(bridge.dispose);
    final cancellation = bridge.createCancellation();
    addTearDown(() => bridge.releaseCancellation(id: cancellation));
    final request = FlutterOpenRequest(localId: fixture, pathKey: fixture);

    for (var index = 0; index < _warmups; index += 1) {
      final token = bridge.createCancellation();
      expect(bridge.releaseCancellation(id: token), isTrue);
    }
    final bridgeRoundTrips = <double>[];
    for (var index = 0; index < _samples; index += 1) {
      final stopwatch = Stopwatch()..start();
      final token = bridge.createCancellation();
      expect(bridge.releaseCancellation(id: token), isTrue);
      stopwatch.stop();
      bridgeRoundTrips.add(stopwatch.elapsedMicroseconds / 1000);
    }

    final document = await bridge.openDocument(
      request: request,
      cancellationId: cancellation,
    );
    var documentReleased = false;
    addTearDown(() {
      if (!documentReleased) {
        bridge.releaseDocument(handle: document.handle);
      }
    });
    final scene = await bridge.selectionSurface(
      document: document.handle,
      unit: BigInt.zero,
      scale: 1,
      width: 680,
      fontSize: 18,
      cancellationId: cancellation,
    );
    for (var index = 0; index < _warmups; index += 1) {
      final echoed = bridge.roundTripVisibleScene(scene: scene);
      expect(echoed.endpoints, hasLength(scene.endpoints.length));
    }
    final sceneRoundTrips = <double>[];
    for (var index = 0; index < _samples; index += 1) {
      final stopwatch = Stopwatch()..start();
      final echoed = bridge.roundTripVisibleScene(scene: scene);
      stopwatch.stop();
      sceneRoundTrips.add(stopwatch.elapsedMicroseconds / 1000);
      expect(echoed.endpoints, hasLength(scene.endpoints.length));
    }
    expect(bridge.releaseSelection(handle: scene.handle), isTrue);

    for (var index = 0; index < _warmups; index += 1) {
      final rendered = await bridge.renderPage(
        document: document.handle,
        page: BigInt.zero,
        scale: 1,
        cancellationId: cancellation,
      );
      expect(bridge.releaseBuffer(handle: rendered.handle), isTrue);
    }
    final renderRoundTrips = <double>[];
    for (var index = 0; index < _samples; index += 1) {
      final stopwatch = Stopwatch()..start();
      final rendered = await bridge.renderPage(
        document: document.handle,
        page: BigInt.zero,
        scale: 1,
        cancellationId: cancellation,
      );
      stopwatch.stop();
      renderRoundTrips.add(stopwatch.elapsedMicroseconds / 1000);
      expect(rendered.byteLen, greaterThan(BigInt.zero));
      expect(bridge.releaseBuffer(handle: rendered.handle), isTrue);
    }
    expect(bridge.releaseDocument(handle: document.handle), isTrue);
    documentReleased = true;

    final rssByCycle = <int>[];
    for (var index = 0; index < _warmups + _resourceCycles; index += 1) {
      final cycleDocument = await bridge.openDocument(
        request: request,
        cancellationId: cancellation,
      );
      final surface = await bridge.selectionSurface(
        document: cycleDocument.handle,
        unit: BigInt.zero,
        scale: 1,
        width: 680,
        fontSize: 18,
        cancellationId: cancellation,
      );
      final rendered = await bridge.renderPage(
        document: cycleDocument.handle,
        page: BigInt.zero,
        scale: 1,
        cancellationId: cancellation,
      );
      final pixels = bridge.takeBuffer(handle: rendered.handle);
      expect(pixels, hasLength(rendered.byteLen.toInt()));
      expect(bridge.releaseBuffer(handle: rendered.handle), isTrue);
      expect(bridge.releaseSelection(handle: surface.handle), isTrue);
      expect(bridge.releaseDocument(handle: cycleDocument.handle), isTrue);
      await tester.pump();
      if (index >= _warmups) {
        rssByCycle.add(ProcessInfo.currentRss);
      }
    }

    final sliceBridge = FlutterBridge.withDatabasePath(
      databasePath: '${directory.path}/packaged-slice.sqlite',
    );
    final sliceCancellation = sliceBridge.createCancellation();
    await _exercisePackagedFormat(
      sliceBridge,
      request,
      sliceCancellation,
      expectsRaster: false,
    );
    final epubFixture = '${directory.path}/fixture.epub';
    await File(epubFixture).writeAsBytes(base64Decode(_sampleEpubBase64));
    await _exercisePackagedFormat(
      sliceBridge,
      FlutterOpenRequest(localId: epubFixture, pathKey: epubFixture),
      sliceCancellation,
      expectsRaster: true,
    );
    expect(sliceBridge.releaseCancellation(id: sliceCancellation), isTrue);
    sliceBridge.dispose();

    final uiBridge = await createApplicationBridge(
      applicationSupportDirectory: () async => directory,
    );
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(bridge: uiBridge)));
    await tester.pumpAndSettle();
    tester.widget<TextField>(find.byType(TextField)).controller!.text = fixture;
    await tester.pump();
    await tester.tap(find.byType(FilledButton));
    await tester.pump();
    await _pumpUntilFound(
      tester,
      find.byKey(const ValueKey('reader-selection-surface')),
    );
    final selectionSurface = find.byKey(
      const ValueKey('reader-selection-surface'),
    );
    final bounds = tester.getRect(selectionSurface);
    final painterFinder = find.byWidgetPredicate(
      (widget) => widget is CustomPaint && widget.painter is PagePainter,
    );
    final painter =
        tester.widget<CustomPaint>(painterFinder).painter! as PagePainter;
    final sourceSize = Size(painter.surface.width, painter.surface.height);
    final scale = math.min(
      bounds.width / sourceSize.width,
      bounds.height / sourceSize.height,
    );
    final pageOffset =
        bounds.center -
        Offset(sourceSize.width * scale, sourceSize.height * scale) / 2;
    Offset endpointPosition(FlutterSelectionEndpoint endpoint) =>
        pageOffset +
        Offset(
              (endpoint.rect.left + endpoint.rect.right) / 2,
              (endpoint.rect.top + endpoint.rect.bottom) / 2,
            ) *
            scale;
    final dragStart = endpointPosition(painter.surface.endpoints.first);
    final dragEnd = endpointPosition(painter.surface.endpoints.last);
    final gesture = await tester.startGesture(dragStart);
    final previousFramePolicy = binding.framePolicy;
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.benchmark;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    var frameTime = binding.currentSystemFrameTimeStamp;
    Future<void> pumpBenchmark() {
      frameTime += const Duration(milliseconds: 16);
      return tester.pumpBenchmark(frameTime);
    }

    for (var index = 0; index < _warmups; index += 1) {
      final progress = (math.sin(index * math.pi / 12) + 1) / 2;
      await gesture.moveTo(Offset.lerp(dragStart, dragEnd, progress)!);
      await pumpBenchmark();
    }
    final overlaySubmissionMs = <double>[];
    try {
      for (var index = 0; index < _samples; index += 1) {
        final progress = (math.sin(index * math.pi / 12) + 1) / 2;
        final stopwatch = Stopwatch()..start();
        await gesture.moveTo(Offset.lerp(dragStart, dragEnd, progress)!);
        await pumpBenchmark();
        stopwatch.stop();
        overlaySubmissionMs.add(stopwatch.elapsedMicroseconds / 1000);
      }
      await gesture.up();
      await pumpBenchmark();
    } finally {
      binding.framePolicy = previousFramePolicy;
      await tester.pump();
    }
    await binding.watchPerformance(() async {
      final performanceGesture = await tester.startGesture(dragStart);
      for (var index = 0; index < _samples; index += 1) {
        final progress = (math.sin(index * math.pi / 12) + 1) / 2;
        await performanceGesture.moveTo(
          Offset.lerp(dragStart, dragEnd, progress)!,
        );
        await tester.pump();
      }
      await performanceGesture.up();
      await tester.pump();
    }, reportKey: 'drag_frames');
    final selectedPainter =
        tester.widget<CustomPaint>(painterFinder).painter! as PagePainter;
    expect(selectedPainter.anchor, isNotNull);
    expect(selectedPainter.focus, isNotNull);
    if (Platform.isAndroid) {
      await binding.convertFlutterSurfaceToImage();
      await tester.pumpAndSettle();
      await binding.takeScreenshot('m2-reader-android');
    } else if (Platform.isIOS) {
      await binding.takeScreenshot('m2-reader-ios');
    }
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    final applicationSupportDirectory = await getApplicationSupportDirectory();
    final databaseName =
        'm2-${DateTime.now().microsecondsSinceEpoch}-annotations.sqlite3';
    addTearDown(() async {
      for (final suffix in ['', '-shm', '-wal']) {
        final file = File(
          '${applicationSupportDirectory.path}/$databaseName$suffix',
        );
        if (await file.exists()) await file.delete();
      }
    });
    await _exerciseRenderedPersistence(
      tester,
      FlutterOpenRequest(localId: epubFixture, pathKey: epubFixture),
      databaseName,
    );

    final driverReport = binding.reportData;
    final report = <String, dynamic>{
      if (driverReport case {'drag_frames': final dragFrames})
        'drag_frames': dragFrames,
      'm2': <String, dynamic>{
        'schema': 1,
        'platform': Platform.operatingSystem,
        'platform_version': Platform.operatingSystemVersion,
        'processors': Platform.numberOfProcessors,
        'fixture': fixture,
        'samples': _samples,
        'bridge_round_trip_ms': _summary(bridgeRoundTrips),
        'visible_scene_dto_round_trip_ms': _summary(sceneRoundTrips),
        'uncached_pdf_render_ms': _summary(renderRoundTrips),
        'drag_overlay_submission_ms': overlaySubmissionMs,
        'resource_cycle_rss_bytes': rssByCycle,
        'resource_cycle_rss_slope_bytes': _slope(rssByCycle),
        'peak_rss_bytes': rssByCycle.reduce(math.max),
      },
    };
    binding.reportData = <String, dynamic>{...?driverReport, ...report};
    _printReport(jsonEncode(report));
  });
}

Future<void> _exerciseRenderedPersistence(
  WidgetTester tester,
  FlutterOpenRequest request,
  String databaseName,
) async {
  final bridge = await createApplicationBridge(databaseName: databaseName);
  await tester.pumpWidget(MaterialApp(home: ReaderScreen(bridge: bridge)));
  await tester.pumpAndSettle();
  tester.widget<TextField>(find.byType(TextField)).controller!.text =
      request.pathKey;
  await tester.tap(find.byType(FilledButton));
  await tester.pump();
  await _pumpUntilFound(
    tester,
    find.byKey(const ValueKey('reader-selection-surface')),
  );
  final surfaceFinder = find.byKey(const ValueKey('reader-selection-surface'));
  final painterFinder = find.byWidgetPredicate(
    (widget) => widget is CustomPaint && widget.painter is PagePainter,
  );
  final painter =
      tester.widget<CustomPaint>(painterFinder).painter! as PagePainter;
  expect(painter.image, isNotNull);
  expect(painter.surface.endpoints, isNotEmpty);
  final bounds = tester.getRect(surfaceFinder);
  final sourceSize = Size(painter.surface.width, painter.surface.height);
  final scale = math.min(
    bounds.width / sourceSize.width,
    bounds.height / sourceSize.height,
  );
  final pageOffset =
      bounds.center -
      Offset(sourceSize.width * scale, sourceSize.height * scale) / 2;
  Offset position(FlutterSelectionEndpoint endpoint) =>
      pageOffset +
      Offset(
            (endpoint.rect.left + endpoint.rect.right) / 2,
            (endpoint.rect.top + endpoint.rect.bottom) / 2,
          ) *
          scale;
  final gesture = await tester.startGesture(
    position(painter.surface.endpoints.first),
  );
  await gesture.moveTo(position(painter.surface.endpoints.last));
  await gesture.up();
  await tester.pump();
  final yellowAction = find.widgetWithText(FilledButton, 'Yellow');
  await _pumpUntilEnabledButton(tester, yellowAction);
  await tester.tap(yellowAction);
  await _pumpUntilFound(tester, find.textContaining('Highlight 1'));
  await tester.pumpWidget(const SizedBox());
  await tester.pumpAndSettle();

  final reopenedBridge = await createApplicationBridge(
    databaseName: databaseName,
  );
  final cancellation = reopenedBridge.createCancellation();
  final document = await reopenedBridge.openDocument(
    request: request,
    cancellationId: cancellation,
  );
  final annotations = await reopenedBridge.listAnnotations(
    document: document.handle,
    scale: 1,
    cancellationId: cancellation,
  );
  expect(annotations, hasLength(1));
  expect(reopenedBridge.releaseDocument(handle: document.handle), isTrue);
  expect(reopenedBridge.releaseCancellation(id: cancellation), isTrue);
  reopenedBridge.dispose();
}

Future<void> _exercisePackagedFormat(
  FlutterBridge bridge,
  FlutterOpenRequest request,
  BigInt cancellation, {
  required bool expectsRaster,
}) async {
  final document = await bridge.openDocument(
    request: request,
    cancellationId: cancellation,
  );
  final surface = await bridge.selectionSurface(
    document: document.handle,
    unit: BigInt.zero,
    scale: 1,
    width: 680,
    fontSize: 18,
    cancellationId: cancellation,
  );
  expect(surface.endpoints, isNotEmpty);
  expect(surface.raster != null, expectsRaster);
  if (surface.raster case final raster?) {
    expect(
      bridge.takeBuffer(handle: raster.handle),
      hasLength(raster.byteLen.toInt()),
    );
    expect(bridge.releaseBuffer(handle: raster.handle), isTrue);
  }
  final endpoint = surface.endpoints.first;
  final annotation = await bridge.createAnnotation(
    document: document.handle,
    unit: BigInt.zero,
    start: endpoint.rangeStart,
    end: endpoint.rangeEnd,
    displayScale: 1,
    color: FlutterHighlightColor.yellow,
    body: 'packaged slice',
    cancellationId: cancellation,
  );
  expect(bridge.releaseSelection(handle: surface.handle), isTrue);
  expect(bridge.releaseDocument(handle: document.handle), isTrue);

  final reopened = await bridge.openDocument(
    request: request,
    cancellationId: cancellation,
  );
  final persisted = await bridge.listAnnotations(
    document: reopened.handle,
    scale: 1,
    cancellationId: cancellation,
  );
  expect(persisted.map((value) => value.id), contains(annotation.id));
  expect(
    await bridge.updateAnnotation(
      document: reopened.handle,
      id: annotation.id,
      color: FlutterHighlightColor.blue,
      body: 'updated packaged slice',
    ),
    isTrue,
  );
  expect(
    await bridge.deleteAnnotation(document: reopened.handle, id: annotation.id),
    isTrue,
  );
  expect(bridge.releaseDocument(handle: reopened.handle), isTrue);
}

void _printReport(String report) {
  const chunkSize = 700;
  final chunks = <String>[];
  for (var offset = 0; offset < report.length; offset += chunkSize) {
    chunks.add(
      report.substring(offset, math.min(offset + chunkSize, report.length)),
    );
  }
  for (var index = 0; index < chunks.length; index += 1) {
    debugPrint(
      'SHOSAI_M2_METRICS:${index + 1}/${chunks.length}:${chunks[index]}',
    );
  }
}

Future<void> _pumpUntilFound(WidgetTester tester, Finder finder) async {
  for (var attempt = 0; attempt < 300; attempt += 1) {
    await tester.pump(const Duration(milliseconds: 16));
    if (finder.evaluate().isNotEmpty) return;
  }
  final visibleText = tester
      .widgetList<Text>(find.byType(Text))
      .map((widget) => widget.data)
      .whereType<String>()
      .join(' | ');
  fail('reader did not become operable: $visibleText');
}

Future<void> _pumpUntilEnabledButton(WidgetTester tester, Finder finder) async {
  for (var attempt = 0; attempt < 300; attempt += 1) {
    await tester.pump(const Duration(milliseconds: 16));
    final buttons = tester.widgetList<FilledButton>(finder);
    if (buttons.any((button) => button.onPressed != null)) return;
  }
  fail('reader action did not become enabled');
}

Uint8List _selectablePdf() {
  const content = 'BT /F1 24 Tf 1 0 0 1 40 80 Tm (M2 measurement) Tj ET';
  final objects = <String>[
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] '
        '/Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
    '<< /Length ${content.length + 1} >>\nstream\n$content\nendstream',
  ];
  final bytes = BytesBuilder()..add(ascii.encode('%PDF-1.4\n'));
  final offsets = <int>[];
  for (var index = 0; index < objects.length; index += 1) {
    offsets.add(bytes.length);
    bytes.add(ascii.encode('${index + 1} 0 obj\n${objects[index]}\nendobj\n'));
  }
  final xref = bytes.length;
  bytes
    ..add(ascii.encode('xref\n0 ${objects.length + 1}\n'))
    ..add(ascii.encode('0000000000 65535 f \n'));
  for (final offset in offsets) {
    bytes.add(ascii.encode('${offset.toString().padLeft(10, '0')} 00000 n \n'));
  }
  bytes.add(
    ascii.encode(
      'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\n'
      'startxref\n$xref\n%%EOF\n',
    ),
  );
  return bytes.takeBytes();
}

Map<String, double> _summary(List<double> values) {
  final sorted = [...values]..sort();
  double percentile(double value) =>
      sorted[(value * sorted.length).ceil().clamp(1, sorted.length) - 1];
  return <String, double>{
    'p50': percentile(.50),
    'p95': percentile(.95),
    'max': sorted.last,
  };
}

double _slope(List<int> values) {
  final meanX = (values.length - 1) / 2;
  final meanY = values.reduce((left, right) => left + right) / values.length;
  var numerator = 0.0;
  var denominator = 0.0;
  for (var index = 0; index < values.length; index += 1) {
    numerator += (index - meanX) * (values[index] - meanY);
    denominator += math.pow(index - meanX, 2);
  }
  return numerator / denominator;
}

const _sampleEpubBase64 =
    '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';
