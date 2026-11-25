import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:shosai_core/catalog.dart';
import 'package:sqlite3/sqlite3.dart';

// Leave some headroom under Pages' 25 MiB per-file limit. Fail instead of
// shifting partition boundaries and producing unrelated Git diffs.
const _maxPartitionBytes = 24 * 1024 * 1024;

void main(List<String> args) {
  if (args.length != 2 && !(args.length == 4 && args[2] == '--previous')) {
    stderr.writeln(
      'Usage: dart run tool/export_catalog_json.dart '
      '<catalog.sqlite> <new-output-directory> [--previous <checked-in-directory>]',
    );
    exitCode = 64;
    return;
  }
  try {
    exportCatalogJson(
      args[0],
      args[1],
      previous: args.length == 4 ? args[3] : null,
    );
  } on Exception catch (error) {
    stderr.writeln('Catalog export failed: $error');
    exitCode = 1;
  }
}

void exportCatalogJson(String input, String destination, {String? previous}) {
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
    if (counts.any((row) => (row['source_id'] as String).isEmpty)) {
      throw const FormatException('Catalog has an empty source ID');
    }

    final staging = Directory(p.dirname(output)).createTempSync('.catalog-');
    try {
      final files = <String, CatalogFile>{};
      for (final MapEntry(key: table, value: layout) in {
        ...catalogTables,
        ...optionalCatalogTables,
      }.entries) {
        Directory(p.join(staging.path, table)).createSync();
        final stmt = db.prepare(
          'SELECT * FROM $table ORDER BY ${layout.orderBy}',
        );
        final handles = <String, RandomAccessFile>{};
        try {
          for (final part in layout.parts.split('')) {
            final file = File(p.join(staging.path, '$table/$part.json'));
            handles[part] = file.openSync(mode: FileMode.write)
              ..writeStringSync('[\n');
          }
          final cursor = stmt.selectCursor();
          while (cursor.moveNext()) {
            final row = cursor.current;
            final part = layout.parts.length == 1
                ? '0'
                : sha256
                      .convert(utf8.encode(row['book_id'] as String))
                      .toString()[0];
            final handle = handles[part]!;
            final prefix = handle.positionSync() == 2 ? '  ' : ',\n  ';
            final bytes = utf8.encode('$prefix${jsonEncode(row)}');
            if (handle.positionSync() + bytes.length + 3 > _maxPartitionBytes) {
              throw FormatException('$table/$part exceeds the partition limit');
            }
            handle.writeFromSync(bytes);
          }
          for (final handle in handles.values) {
            handle.writeStringSync('\n]\n');
          }
        } finally {
          for (final handle in handles.values) {
            handle.closeSync();
          }
          stmt.close();
        }
        for (final part in layout.parts.split('')) {
          final path = '$table/$part.json';
          final bytes = File(p.join(staging.path, path)).readAsBytesSync();
          files[path] = (
            sizeBytes: bytes.length,
            sha256: sha256.convert(bytes).toString(),
          );
        }
      }
      final sourceCounts = {
        for (final row in counts) row['source_id'] as String: row['count'],
      };
      var builtAt = DateTime.now().toUtc();
      if (previous != null) {
        final old = CatalogManifest.parse(
          File(p.join(previous, CatalogManifest.fileName)).readAsStringSync(),
        );
        if (files.length == old.files.length &&
            files.entries.every(
              (entry) => old.files[entry.key] == entry.value,
            ) &&
            sourceCounts.length == old.sourceCounts.length &&
            sourceCounts.entries.every(
              (entry) => old.sourceCounts[entry.key] == entry.value,
            )) {
          builtAt = old.builtAt;
        }
      }
      final manifest = const JsonEncoder.withIndent('  ').convert({
        'formatVersion': catalogFormatVersion,
        'builtAt': builtAt.toIso8601String(),
        'sourceCounts': sourceCounts,
        'files': {
          for (final entry in files.entries)
            entry.key: {
              'sizeBytes': entry.value.sizeBytes,
              'sha256': entry.value.sha256,
            },
        },
      });
      File(
        p.join(staging.path, CatalogManifest.fileName),
      ).writeAsStringSync('$manifest\n');
      db.execute('COMMIT');
      _requireAbsent(output);
      staging.renameSync(output);
      stdout.writeln('Wrote ${files.length} catalog partitions to $output');
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
