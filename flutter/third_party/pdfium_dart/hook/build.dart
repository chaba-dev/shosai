import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:http/http.dart' as http;

import 'pdfium_archives.dart';
import 'verified_archive.dart';

const _assetName = 'libpdfium';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    if (input.config.code.targetOS == OS.iOS) return;

    final target = _PdfiumTarget.fromCodeConfig(input.config.code);
    final expectedSha256 = pdfiumArchiveSha256[target.archiveName];
    if (expectedSha256 == null) {
      throw UnsupportedError(
        'No pinned PDFium archive for ${target.archiveName}; '
        'see tool/pin_pdfium.py.',
      );
    }
    // The directory names the archive's hash, so a pin change never reuses
    // another archive's cache; extractVerifiedPdfium rechecks the cache itself.
    final outputSubdir = pdfiumRelease.replaceAll('%2F', '_');
    final outputFile = input.outputDirectoryShared.resolve(
      '$outputSubdir/${target.archiveName}-${expectedSha256.substring(0, 16)}/${target.libraryFileName}',
    );

    await _downloadPdfium(
      outputFile: outputFile,
      target: target,
      pdfiumRelease: pdfiumRelease,
      expectedSha256: expectedSha256,
    );

    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: _assetName,
        linkMode: DynamicLoadingBundled(),
        file: outputFile,
      ),
    );
  });
}

Future<void> _downloadPdfium({
  required Uri outputFile,
  required _PdfiumTarget target,
  required String pdfiumRelease,
  required String expectedSha256,
}) async {
  final archiveUri = Uri.parse(
    'https://github.com/bblanchon/pdfium-binaries/releases/download/'
    '$pdfiumRelease/pdfium-${target.archivePlatform}-${target.archiveArch}.tgz',
  );

  await extractVerifiedPdfium(
    archive: File.fromUri(outputFile.resolve('pdfium.tgz')),
    library: File.fromUri(outputFile),
    expectedSha256: expectedSha256,
    libraryPath: target.archiveLibraryPath,
    source: archiveUri,
    download: () async {
      final response = await http.get(archiveUri);
      if (response.statusCode != 200) {
        throw Exception('Failed to download PDFium: $archiveUri');
      }
      return response.bodyBytes;
    },
  );
}

final class _PdfiumTarget {
  const _PdfiumTarget({
    required this.archivePlatform,
    required this.archiveArch,
    required this.archiveLibraryPath,
    required this.libraryFileName,
  });

  final String archivePlatform;
  final String archiveArch;
  final String archiveLibraryPath;
  final String libraryFileName;

  String get archiveName => '$archivePlatform-$archiveArch';

  static _PdfiumTarget fromCodeConfig(CodeConfig config) {
    final arch = switch (config.targetArchitecture) {
      Architecture.ia32 => 'x86',
      Architecture.x64 => 'x64',
      Architecture.arm => 'arm',
      Architecture.arm64 => 'arm64',
      _ => throw UnsupportedError(
        'Unsupported PDFium architecture: ${config.targetArchitecture}',
      ),
    };

    return switch (config.targetOS) {
      OS.android => _PdfiumTarget(
        archivePlatform: 'android',
        archiveArch: arch,
        archiveLibraryPath: 'lib/libpdfium.so',
        libraryFileName: 'libpdfium.so',
      ),
      OS.windows => _PdfiumTarget(
        archivePlatform: 'win',
        archiveArch: arch,
        archiveLibraryPath: 'bin/pdfium.dll',
        libraryFileName: 'pdfium.dll',
      ),
      OS.linux => _PdfiumTarget(
        archivePlatform: 'linux',
        archiveArch: arch,
        archiveLibraryPath: 'lib/libpdfium.so',
        libraryFileName: 'libpdfium.so',
      ),
      OS.macOS => _PdfiumTarget(
        archivePlatform: 'mac',
        archiveArch: arch,
        archiveLibraryPath: 'lib/libpdfium.dylib',
        libraryFileName: 'libpdfium.dylib',
      ),
      _ => throw UnsupportedError(
        'Unsupported PDFium platform: ${config.targetOS}',
      ),
    };
  }
}
