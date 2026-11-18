import 'dart:io';

import 'package:shosai_flutter/core/connection_credentials.dart';

/// Only synthetic test passwords. A new engine shares the vault, not RAM state.
final class TestPasswordStore implements ConnectionCredentialStore {
  final values = <String, String>{};
  bool unavailable = false;

  @override
  Future<String?> read(String key) async {
    if (unavailable) throw Exception('Test vault unavailable');
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (unavailable) throw Exception('Test vault unavailable');
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async => values.remove(key);
}

/// A new, minimal PDF, encrypted by qpdf from the repository's Nix shell.
Future<File> protectedPdf(
  Directory directory, {
  String name = 'password-sample',
  String password = 'fixture-password',
}) async {
  const text = 'BT /F1 18 Tf 20 100 Td (Synthetic PDF fixture) Tj ET';
  final objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 240 180] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>',
    '<< /Length ${text.length} >>\nstream\n$text\nendstream',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
    '<< /Title (Unlocked fixture title) /Author (Fixture author) >>',
  ];
  final pdf = StringBuffer('%PDF-1.7\n');
  final offsets = <int>[];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(pdf.length);
    pdf.write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
  }
  final xref = pdf.length;
  pdf.write('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n');
  for (final offset in offsets) {
    pdf.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  pdf.write(
    'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R /Info 6 0 R >>\nstartxref\n$xref\n%%EOF\n',
  );
  final input = File('${directory.path}/$name-plain.pdf');
  await input.writeAsString(pdf.toString());
  final output = File('${directory.path}/$name.pdf');
  final encrypted = await Process.run('qpdf', [
    '--encrypt',
    password,
    'fixture-owner-password',
    '256',
    '--print=none',
    '--extract=n',
    '--',
    input.path,
    output.path,
  ]);
  if (encrypted.exitCode != 0) {
    throw StateError('Synthetic PDF generation failed: ${encrypted.stderr}');
  }
  return output;
}
