import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:hooks/hooks.dart';
import 'package:test/test.dart';

import '../hook/build.dart' as hook;

void main() {
  test('declares the cached archive and library as dependencies', () async {
    final archive = Archive();
    final library = utf8.encode('the real library');
    archive.addFile(ArchiveFile('lib/libpdfium.so', library.length, library));
    final bytes = GZipEncoder().encode(TarEncoder().encode(archive));

    await testCodeBuildHook(
      targetOS: OS.linux,
      targetArchitecture: Architecture.x64,
      mainMethod: (args) => build(
        args,
        (input, output) => hook.buildPdfium(
          input,
          output,
          download: (_) async => bytes,
          archiveSha256: {'linux-x64': sha256.convert(bytes).toString()},
        ),
      ),
      check: (input, output) {
        final asset = output.assets.code.single;
        expect(
          File.fromUri(asset.file!).readAsStringSync(),
          'the real library',
        );
        // Without them the runner reuses this output without running the
        // hook, so a cached library changed afterwards is never rechecked.
        expect(
          output.dependencies,
          unorderedEquals([asset.file!.resolve('pdfium.tgz'), asset.file!]),
        );
      },
    );
  });
}
