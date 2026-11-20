import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:shosai_core/catalog.dart';
import 'package:sqlite3/sqlite3.dart';

// Well below Pages' 25 MiB limit and small enough to decode one shard at a
// time on the device.
const _maxShardBytes = 4 * 1024 * 1024;

void main(List<String> args) {
  if (args.length != 2) {
    stderr.writeln(
      'Usage: dart run tool/export_catalog_json.dart '
      '<catalog.sqlite> <new-output-directory>',
    );
    exitCode = 64;
    return;
  }
  try {
    exportCatalogJson(args[0], args[1]);
  } on Exception catch (error) {
    stderr.writeln('Catalog export failed: $error');
    exitCode = 1;
  }
}

void exportCatalogJson(String input, String destination) {
  final output = p.normalize(p.absolute(destination));
  _requireAbsent(output);
  final db = sqlite3.open(input, mode: OpenMode.readOnly);
  try {
    db.execute('BEGIN');
    if (db.userVersion != catalogDatabaseVersion) {
      throw const FormatException('Unsupported catalog database version');
    }
    if (db.select('PRAGMA foreign_key_check').isNotEmpty) {
      throw const FormatException('Catalog has orphan rows');
    }
    final counts = db.select('''
      SELECT source_id, COUNT(*) AS count FROM editions
      GROUP BY source_id ORDER BY source_id
    ''');
    if (counts.isEmpty) {
      throw const FormatException('Catalog has no editions');
    }

    final staging = Directory(p.dirname(output)).createTempSync('.catalog-');
    try {
      final files = <String, Object>{};
      for (final MapEntry(key: table, value: order) in catalogTables.entries) {
        Directory(p.join(staging.path, table)).createSync();
        final stmt = db.prepare('SELECT * FROM $table ORDER BY $order');
        try {
          final cursor = stmt.selectCursor();
          final shard = BytesBuilder(copy: false)..addByte(0x5b); // [
          var part = 0;
          void writeShard() {
            shard.addByte(0x5d); // ]
            final bytes = shard.takeBytes();
            final path = '$table/${part++}.json';
            File(p.join(staging.path, path)).writeAsBytesSync(bytes);
            files[path] = {
              'sizeBytes': bytes.length,
              'sha256': sha256.convert(bytes).toString(),
            };
            shard.addByte(0x5b);
          }

          while (cursor.moveNext()) {
            final bytes = utf8.encode(jsonEncode(cursor.current));
            if (bytes.length + 2 > _maxShardBytes) {
              throw FormatException('A $table row exceeds the shard limit');
            }
            if (shard.length > 1 &&
                shard.length + 1 + bytes.length + 1 > _maxShardBytes) {
              writeShard();
            }
            if (shard.length > 1) shard.addByte(0x2c); // ,
            shard.add(bytes);
          }
          writeShard(); // Even an empty table has a shard.
        } finally {
          stmt.close();
        }
      }
      final manifest = jsonEncode({
        'formatVersion': catalogFormatVersion,
        'builtAt': DateTime.now().toUtc().toIso8601String(),
        'sourceCounts': {
          for (final row in counts) row['source_id'] as String: row['count'],
        },
        'files': files,
      });
      File(
        p.join(staging.path, CatalogManifest.fileName),
      ).writeAsStringSync(manifest);
      db.execute('COMMIT');
      _requireAbsent(output);
      staging.renameSync(output);
      stdout.writeln('Wrote ${files.length} catalog shards to $output');
    } finally {
      if (staging.existsSync()) staging.deleteSync(recursive: true);
    }
  } finally {
    db.close();
  }
}

void _requireAbsent(String path) {
  if (FileSystemEntity.typeSync(path, followLinks: false) !=
      FileSystemEntityType.notFound) {
    throw FileSystemException('Output already exists', path);
  }
}
