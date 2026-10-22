import 'dart:io';

import 'package:shosai_core/shosai_core.dart';
import 'package:test/test.dart';

/// A fresh data directory deleted after the test.
Directory tempDataDirectory() {
  final directory = Directory.systemTemp.createTempSync('shosai_core_test_');
  addTearDown(() async {
    if (directory.existsSync()) await directory.delete(recursive: true);
  });
  return directory;
}

/// A store over a fresh database, closed after the test.
Future<Store> tempStore({Directory? directory}) async {
  final dataDirectory = directory ?? tempDataDirectory();
  final store = await Store.open('${dataDirectory.path}/library.sqlite3');
  addTearDown(store.close);
  return store;
}
