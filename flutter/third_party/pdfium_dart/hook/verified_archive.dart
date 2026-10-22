import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';

/// Writes the member [libraryPath] of the PDFium archive whose SHA-256 is
/// [expectedSha256] to [library].
///
/// The archive is cached at [archive] and hashed again on every call, so a
/// cached copy that changed or was cut short is fetched again with [download]
/// instead of being trusted, and a download that does not match fails. The
/// library is always taken from the verified archive: an existing [library]
/// is kept only when it already holds the same bytes. Each file is written
/// beside its final name and renamed into place, so an interrupted write
/// never leaves a partial file under that name.
Future<void> extractVerifiedPdfium({
  required File archive,
  required File library,
  required String expectedSha256,
  required String libraryPath,
  required Uri source,
  required Future<List<int>> Function() download,
}) async {
  List<int>? bytes = await archive.exists()
      ? await archive.readAsBytes()
      : null;
  if (bytes == null || sha256.convert(bytes).toString() != expectedSha256) {
    final downloaded = await download();
    final digest = sha256.convert(downloaded).toString();
    if (digest != expectedSha256) {
      throw Exception(
        'PDFium archive $source has SHA-256 $digest; '
        'expected $expectedSha256.',
      );
    }
    await _replace(archive, downloaded);
    bytes = downloaded;
  }

  final member = TarDecoder()
      .decodeBytes(GZipDecoder().decodeBytes(bytes))
      .findFile(libraryPath);
  if (member == null) {
    throw Exception('PDFium archive $source does not contain $libraryPath.');
  }
  final content = member.content as List<int>;
  if (await library.exists() &&
      _sameBytes(await library.readAsBytes(), content)) {
    return;
  }
  await _replace(library, content);
}

Future<void> _replace(File file, List<int> bytes) async {
  await file.parent.create(recursive: true);
  final partial = File('${file.path}.partial-$pid');
  await partial.writeAsBytes(bytes, flush: true);
  await partial.rename(file.path);
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
