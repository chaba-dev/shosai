import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

/// Writes the keep-books harness's screenshots and log to `KEEP_BOOKS_OUT`.
Future<void> main() => integrationDriver(
  responseDataCallback: (data) async {
    final out = Directory(
      Platform.environment['KEEP_BOOKS_OUT'] ?? 'target/keep-books',
    )..createSync(recursive: true);
    if (data == null) return;
    final shots = (data['shots'] as Map?) ?? const {};
    for (final entry in shots.entries) {
      File(
        '${out.path}/${entry.key}.png',
      ).writeAsBytesSync(base64Decode(entry.value as String));
    }
    final log = (data['log'] as List?)?.join('\n') ?? '';
    File('${out.path}/log.txt').writeAsStringSync('$log\n', mode: FileMode.append);
  },
);
