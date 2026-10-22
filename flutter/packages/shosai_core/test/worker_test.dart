import 'dart:io';

import 'package:shosai_core/src/worker.dart';
import 'package:shosai_core/shosai_core.dart';
import 'package:test/test.dart';

void main() {
  test('a worker returns its value and rethrows its error', () async {
    final cancellation = CancellationToken();
    expect(await runCancellable(() => 6 * 7, cancellation: cancellation), 42);
    await expectLater(
      runCancellable<int>(
        () => throw const CoreException.notFound('gone'),
        cancellation: cancellation,
      ),
      throwsA(
        isA<CoreException>().having(
          (e) => e.kind,
          'kind',
          CoreErrorKind.notFound,
        ),
      ),
    );
  });

  test('cancelling kills a worker that never yields', () async {
    final cancellation = CancellationToken();
    final running = runCancellable<int>(() {
      while (true) {}
    }, cancellation: cancellation);
    cancellation.cancel();
    await expectLater(
      running,
      throwsA(
        isA<CoreException>().having(
          (e) => e.kind,
          'kind',
          CoreErrorKind.cancelled,
        ),
      ),
    );
  });

  test('a cancelled worker has stopped when its future settles', () async {
    final directory = await Directory.systemTemp.createTemp('shosai-worker-');
    addTearDown(() => directory.delete(recursive: true));
    final marker = '${directory.path}/marker';
    final cancellation = CancellationToken();
    final running = runCancellable<int>(() {
      final file = File(marker);
      while (true) {
        file.writeAsStringSync('x', mode: FileMode.append);
      }
    }, cancellation: cancellation);
    while (!File(marker).existsSync()) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    cancellation.cancel();
    await expectLater(running, throwsA(isA<CoreException>()));

    final settled = File(marker).lengthSync();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(File(marker).lengthSync(), settled);
  });

  test('a copy cancelled mid-way leaves no destination behind', () async {
    final directory = await Directory.systemTemp.createTemp('shosai-worker-');
    addTearDown(() => directory.delete(recursive: true));
    final source = File('${directory.path}/book.pdf')
      ..writeAsBytesSync(List.filled(256 * 1024 * 1024, 7));
    final destination = '${directory.path}/copy.pdf';
    final cancellation = CancellationToken();
    final copying = copyAndFingerprint(
      source.path,
      destination,
      cancellation: cancellation,
    );
    while ((File(destination).statSync().size) == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    cancellation.cancel();
    await expectLater(copying, throwsA(isA<CoreException>()));
    expect(File(destination).existsSync(), isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(File(destination).existsSync(), isFalse);
  });

  test('a cancelled copy leaves no destination behind', () async {
    final directory = await Directory.systemTemp.createTemp('shosai-worker-');
    addTearDown(() => directory.delete(recursive: true));
    final source = File('${directory.path}/book.pdf')
      ..writeAsBytesSync(List.filled(8 * 1024 * 1024, 7));
    final destination = '${directory.path}/copy.pdf';
    final cancellation = CancellationToken();
    final copying = copyAndFingerprint(
      source.path,
      destination,
      cancellation: cancellation,
    );
    cancellation.cancel();
    await expectLater(copying, throwsA(isA<CoreException>()));
    expect(File(destination).existsSync(), isFalse);

    final copied = await copyAndFingerprint(source.path, '$destination.2');
    expect(copied, await fingerprintFile(source.path));
  });
}
