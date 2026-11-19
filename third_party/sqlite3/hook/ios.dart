import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';
import 'package:sqlite3/src/hook/compile/description.dart';

const _archiveHash =
    '1e71ddf93849c6a6ecf58b827c0692073d2dd7ee40196158068f7b29f422e87d';

/// Only called for iOS. Other targets retain the upstream hook verbatim.
Future<void> buildIos(BuildInput input, BuildOutputBuilder output) async {
  final archive = File.fromUri(
    input.outputDirectoryShared.resolve('sqlite-$_archiveHash.zip'),
  );
  List<int>? bytes = archive.existsSync() ? archive.readAsBytesSync() : null;
  if (bytes == null || sha256.convert(bytes).toString() != _archiveHash) {
    final client = HttpClient()
      ..findProxy = HttpClient.findProxyFromEnvironment;
    try {
      final request = await client.getUrl(
        Uri.parse('https://sqlite.org/2026/sqlite-amalgamation-3530400.zip'),
      );
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw StateError('SQLite download returned ${response.statusCode}');
      }
      bytes = await response.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
      if (sha256.convert(bytes).toString() != _archiveHash) {
        throw StateError('SQLite source archive SHA-256 mismatch');
      }
      archive.parent.createSync(recursive: true);
      final temporary = File('${archive.path}.$pid.partial');
      temporary.writeAsBytesSync(bytes, flush: true);
      temporary.renameSync(archive.path);
    } finally {
      client.close();
    }
  }
  final member = ZipDecoder()
      .decodeBytes(bytes)
      .findFile('sqlite-amalgamation-3530400/sqlite3.c')!;
  var source = utf8.decode(member.content);
  // Exclude only the Apple FAT/exFAT probe in unixOpen. All other statfs
  // sites are already excluded by SQLITE_ENABLE_LOCKING_STYLE=0.
  source = _replaceOnce(
    source,
    '''
#if defined(__APPLE__) || SQLITE_ENABLE_LOCKING_STYLE
  if( fstatfs(fd, &fsInfo) == -1 ){''',
    '''
#if SQLITE_ENABLE_LOCKING_STYLE
  if( fstatfs(fd, &fsInfo) == -1 ){''',
  );
  // Admission happens before any file descriptor is opened or reused. It
  // covers ATTACH and journals too, not only the application's first open.
  source = _replaceOnce(
    source,
    '''
  unixFile *p = (unixFile *)pFile;
  int fd = -1;''',
    '''
  if( !shosaiContainerPath(zPath) ) return SQLITE_CANTOPEN;
  unixFile *p = (unixFile *)pFile;
  int fd = -1;''',
  );
  final amalgamation = input.outputDirectory.resolve('sqlite3.c');
  File.fromUri(amalgamation).writeAsStringSync(source);
  final admission = input.packageRoot.resolve('hook/ios_container.m');
  final wrapper = input.outputDirectory.resolve('sqlite3_ios.m');
  File.fromUri(wrapper).writeAsStringSync(
    '#include "${admission.toFilePath()}"\n#include "sqlite3.c"\n',
  );
  await CBuilder.library(
    name: 'sqlite3',
    packageName: 'sqlite3',
    assetName: 'src/ffi/libsqlite3.g.dart',
    language: Language.objectiveC,
    sources: [wrapper.toFilePath()],
    frameworks: ['Foundation'],
    defines: {
      ...CompilerDefines.defaults(false),
      'SQLITE_ENABLE_LOCKING_STYLE': '0',
      // Never spill temporary tables onto an unadmitted filesystem.
      'SQLITE_TEMP_STORE': '3',
    },
    flags: [
      '-Os',
      '-headerpad_max_install_names',
      '-install_name',
      '@rpath/libsqlite3.dylib',
    ],
  ).run(input: input, output: output);
  output.dependencies
    ..add(archive.uri)
    ..add(amalgamation)
    ..add(admission);
}

String _replaceOnce(String source, String before, String after) {
  if (before.allMatches(source).length != 1) {
    throw StateError('SQLite iOS patch no longer matches exactly once');
  }
  return source.replaceFirst(before, after);
}
