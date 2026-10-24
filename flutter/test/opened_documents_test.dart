import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_flutter/opened_documents.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.shosai/opened_documents');

  test(
    'a pending response after cancellation releases copies without delivery',
    () async {
      final inbox = await Directory.systemTemp.createTemp('shosai-late-open');
      addTearDown(() => inbox.delete(recursive: true));
      final file = await File('${inbox.path}/late.epub').writeAsString('book');
      final response = Completer<List<String>>();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (_) => response.future);
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final adapter = OpenedDocuments();
      final delivered = <String>[];
      final listening = adapter.listen(delivered.addAll);
      adapter.cancel();
      response.complete([file.path]);
      await listening;
      expect(delivered, isEmpty);
      expect(await file.exists(), isFalse);
    },
  );

  test(
    'wake-ups drain native pending copies and deduplicate active paths',
    () async {
      final inbox = await Directory.systemTemp.createTemp('shosai-open-wakeup');
      addTearDown(() => inbox.delete(recursive: true));
      final files = [
        for (final name in ['first.epub', 'second.pdf', 'between.epub'])
          await File('${inbox.path}/$name').writeAsString(name),
      ];
      var pending = [files.first.path];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (_) async {
        final taken = pending;
        pending = [];
        return taken;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final adapter = OpenedDocuments();
      addTearDown(adapter.cancel);
      final batches = <List<String>>[];
      await adapter.listen(batches.add);
      pending = [files.first.path, files[1].path];
      final replied = Completer<void>();
      await messenger.handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(const MethodCall('opened')),
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
      // Native retains these paths even when its wake-up has no Dart listener.
      pending = [files.last.path];
      await adapter.listen(batches.add);
      expect(batches.last, [files.last.path]);
      await adapter.discard(batches.last);
      expect(files.any((file) => file.existsSync()), isFalse);
    },
  );
}
