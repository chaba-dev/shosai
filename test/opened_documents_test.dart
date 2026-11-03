import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_flutter/opened_documents.dart';

const _channel = MethodChannel('dev.shosai/opened_documents');

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;

  test('an iOS response after cancellation releases Inbox copies', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final inbox = await Directory.systemTemp.createTemp('shosai-late-open');
    addTearDown(() => inbox.delete(recursive: true));
    final file = await File('${inbox.path}/late.epub').writeAsString('book');
    final response = Completer<List<String>>();
    messenger.setMockMethodCallHandler(_channel, (_) => response.future);
    addTearDown(() => messenger.setMockMethodCallHandler(_channel, null));
    final adapter = OpenedDocuments();
    final delivered = <String>[];
    final listening = adapter.listen(delivered.addAll);
    adapter.cancel();
    response.complete([file.path]);
    await listening;
    expect(delivered, isEmpty);
    expect(await file.exists(), isFalse);
  });

  test(
    'iOS wake-ups deduplicate copies and arrivals between listeners',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final inbox = await Directory.systemTemp.createTemp('shosai-open-wakeup');
      addTearDown(() => inbox.delete(recursive: true));
      final files = [
        for (final name in ['first.epub', 'second.pdf', 'between.epub'])
          await File('${inbox.path}/$name').writeAsString(name),
      ];
      var pending = [files.first.path];
      messenger.setMockMethodCallHandler(_channel, (_) async {
        final taken = pending;
        pending = [];
        return taken;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(_channel, null));
      final adapter = OpenedDocuments();
      addTearDown(adapter.cancel);
      final batches = <List<String>>[];
      await adapter.listen(batches.add);
      pending = [files.first.path, files[1].path];
      final replied = Completer<void>();
      await messenger.handlePlatformMessage(
        _channel.name,
        _channel.codec.encodeMethodCall(const MethodCall('opened')),
        (_) => replied.complete(),
      );
      await replied.future;
      expect(batches, [
        [files.first.path],
        [files[1].path],
      ]);
      expect(files.every((file) => file.existsSync()), isTrue);
      await adapter.discard(files.take(2).map((file) => file.path));
      adapter.cancel();
      pending = [files.last.path];
      await adapter.listen(batches.add);
      expect(batches.last, [files.last.path]);
      await adapter.discard(batches.last);
      expect(files.any((file) => file.existsSync()), isFalse);
    },
  );

  for (final platform in [TargetPlatform.android, TargetPlatform.macOS]) {
    test('$platform idle cleanup needs no native host', () async {
      debugDefaultTargetPlatformOverride = platform;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      await OpenedDocuments().discard([]);
    });

    test('$platform never deletes an original during native cleanup', () async {
      debugDefaultTargetPlatformOverride = platform;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final directory = await Directory.systemTemp.createTemp(
        'opened-documents',
      );
      addTearDown(() => directory.delete(recursive: true));
      final original = await File(
        '${directory.path}/original.epub',
      ).writeAsString('original');
      final staged = await File(
        '${directory.path}/copy',
      ).writeAsString('original');
      var pending = [staged.path];
      messenger.setMockMethodCallHandler(_channel, (call) async {
        if (call.method == 'discard') {
          for (final path in (call.arguments! as List).cast<String>()) {
            if (path == staged.path && await staged.exists()) {
              await staged.delete();
            }
          }
          return null;
        }
        final paths = pending;
        pending = [];
        return paths;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(_channel, null));
      final documents = OpenedDocuments();
      addTearDown(documents.cancel);
      final batches = <List<String>>[];
      await documents.listen(batches.add);
      pending = [staged.path];
      await messenger.handlePlatformMessage(
        _channel.name,
        _channel.codec.encodeMethodCall(const MethodCall('opened')),
        (_) {},
      );
      expect(batches, [
        [staged.path],
      ], reason: 'an active copy is not redelivered');
      await documents.discard([staged.path, original.path]);
      expect(await staged.exists(), isFalse);
      expect(await original.readAsString(), 'original');
    });

    test(
      '$platform releases startup copies if delivery is cancelled',
      () async {
        debugDefaultTargetPlatformOverride = platform;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        final response = Completer<List<String>>();
        final discarded = <String>[];
        messenger.setMockMethodCallHandler(_channel, (call) async {
          if (call.method == 'takePending') return response.future;
          discarded.addAll((call.arguments! as List).cast<String>());
          return null;
        });
        addTearDown(() => messenger.setMockMethodCallHandler(_channel, null));
        final documents = OpenedDocuments();
        final listening = documents.listen((_) => fail('cancelled delivery'));
        documents.cancel();
        response.complete(['/temporary/book']);
        await listening;
        expect(discarded, ['/temporary/book']);
      },
    );
  }
}
