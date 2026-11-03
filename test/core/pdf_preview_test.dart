import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_core/shosai_core.dart' hide Row;
import 'package:shosai_flutter/core/core_records.dart';
import 'package:shosai_flutter/reader/pdf/pdfrx_engine.dart';

/// A PDF of [pages] pages, each a page-sized rectangle of its colour with
/// `padding` bytes of comment lines in its content stream, so a page can be
/// made as heavy as a test needs. The Info dictionary names a title and
/// author unless [info] is false.
Uint8List _pdf(
  List<({List<double> rgb, int padding})> pages, {
  bool info = true,
}) {
  final objects = <String>[
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [${[for (var i = 0; i < pages.length; i++) '${4 + i * 2} 0 R'].join(' ')}] /Count ${pages.length} >>',
    '<< /Title (A Ranged Report) /Author (P. Writer) >>',
  ];
  for (var i = 0; i < pages.length; i++) {
    final (:rgb, :padding) = pages[i];
    final content = StringBuffer()
      ..write('${rgb.join(' ')} rg 0 0 300 400 re f\n');
    final line = '% ${'x' * 76}\n';
    while (content.length < padding) {
      content.write(line);
    }
    objects
      ..add(
        '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] '
        '/Contents ${5 + i * 2} 0 R >>',
      )
      ..add('<< /Length ${content.length} >>\nstream\n${content}endstream');
  }
  final pdf = StringBuffer('%PDF-1.7\n');
  final offsets = <int>[];
  for (var index = 0; index < objects.length; index++) {
    offsets.add(pdf.length);
    pdf.write('${index + 1} 0 obj\n${objects[index]}\nendobj\n');
  }
  final xref = pdf.length;
  pdf.write('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n');
  for (final offset in offsets) {
    pdf.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  pdf.write(
    'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R '
    '${info ? '/Info 3 0 R ' : ''}>>\nstartxref\n$xref\n%%EOF\n',
  );
  return Uint8List.fromList(latin1.encode(pdf.toString()));
}

/// Serves files' bytes, optionally holding reads at [gate].
final class _Files implements LibraryLocation {
  _Files(this.files);

  final Map<String, Uint8List> files;
  Completer<void>? gate;
  int bytesRead = 0;

  @override
  String get id => 'cloud';

  @override
  Future<LocationPage> list({
    String? directory,
    String? cursor,
    int limit = 100,
    CancellationToken? cancellation,
  }) async => LocationPage(const []);

  @override
  Future<LocationEntry> stat(String key, {CancellationToken? cancellation}) =>
      throw StateError('The size is listed');

  @override
  Stream<List<int>> read(
    String key, {
    int start = 0,
    int? end,
    CancellationToken? cancellation,
  }) async* {
    if (gate case final gate?) await gate.future;
    final bytes = files[key]!;
    final stop = end == null || end > bytes.length ? bytes.length : end;
    bytesRead += stop - start;
    yield bytes.sublist(start, stop);
  }

  @override
  Future<LocationEntry> write(
    String name,
    Stream<List<int>> bytes, {
    String? directory,
    CancellationToken? cancellation,
  }) => throw UnimplementedError();
}

LocationEntry _entry(String key, Uint8List bytes) =>
    LocationEntry(key: key, name: key, isDirectory: false, size: bytes.length);

void main() {
  final engine = PdfrxPdfEngine();
  const blue = (rgb: [0.2, 0.3, 0.6], padding: 0);

  Future<BookMetadata> inspected(Uint8List bytes) async {
    final directory = await Directory.systemTemp.createTemp('shosai-pdf-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/book.pdf')..writeAsBytesSync(bytes);
    return PdfEngineInspector(engine).inspect(file.path);
  }

  test('a preview reads what an import reads, small or large', () async {
    for (final bytes in [
      File('fixtures/sample.pdf').readAsBytesSync(),
      _pdf([blue]),
      // Over the in-memory size, so PDFium reads it block by block.
      _pdf([
        blue,
        (rgb: [0.9, 0.9, 0.1], padding: 600 * 1024),
      ]),
    ]) {
      final location = _Files({'book.pdf': bytes});
      final preview = await PdfEnginePreviewer(
        engine,
      ).preview(location, _entry('book.pdf', bytes));
      final import = await inspected(bytes);
      expect(preview.title, import.title);
      expect(preview.author, import.author);
      expect(preview.cover, isNotNull);
      expect(preview.cover, import.cover);
    }
  });

  test('a heavy later page is never read', () async {
    final bytes = _pdf([
      blue,
      (rgb: [0.9, 0.2, 0.1], padding: 6 * 1024 * 1024),
    ]);
    final location = _Files({'big.pdf': bytes});
    final preview = await PdfEnginePreviewer(
      engine,
    ).preview(location, _entry('big.pdf', bytes));
    expect(preview.title, 'A Ranged Report');
    expect(preview.author, 'P. Writer');
    expect(preview.cover, isNotNull);
    expect(location.bytesRead, lessThan(512 * 1024));
  });

  test('a file that needs more than the cap is not read past it', () async {
    final bytes = _pdf([
      (rgb: [0.1, 0.6, 0.3], padding: 3 * 1024 * 1024),
    ]);
    final location = _Files({'heavy.pdf': bytes});
    await expectLater(
      PdfEnginePreviewer(
        engine,
        budget: 1024 * 1024,
      ).preview(location, _entry('heavy.pdf', bytes)),
      throwsA(
        isA<CoreException>().having(
          (e) => e.kind,
          'kind',
          CoreErrorKind.limitExceeded,
        ),
      ),
    );
    expect(location.bytesRead, lessThanOrEqualTo(1024 * 1024));
  });

  test('a file without Info keeps no title but still gets a cover', () async {
    final bytes = _pdf([blue], info: false);
    final preview = await PdfEnginePreviewer(
      engine,
    ).preview(_Files({'x.pdf': bytes}), _entry('x.pdf', bytes));
    expect(preview.title, isNull);
    expect(preview.cover, isNotNull);
  });

  test('a cancelled preview fails as cancelled, not as unreadable', () async {
    final bytes = _pdf([
      blue,
      (rgb: [0.9, 0.2, 0.1], padding: 600 * 1024),
    ]);
    final location = _Files({'book.pdf': bytes});
    final gate = location.gate = Completer<void>();
    final cancellation = CancellationToken();
    final preview = PdfEnginePreviewer(
      engine,
    ).preview(location, _entry('book.pdf', bytes), cancellation: cancellation);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    cancellation.cancel();
    gate.complete();
    await expectLater(
      preview,
      throwsA(
        isA<CoreException>().having(
          (e) => e.kind,
          'kind',
          CoreErrorKind.cancelled,
        ),
      ),
    );
  });

  test('an unreachable file fails with its location error', () async {
    final bytes = _pdf([blue]);
    final location = _Unreachable();
    await expectLater(
      PdfEnginePreviewer(engine).preview(location, _entry('book.pdf', bytes)),
      throwsA(isA<LocationException>()),
    );
  });
}

final class _Unreachable extends _Files {
  _Unreachable() : super(const {});

  @override
  Stream<List<int>> read(
    String key, {
    int start = 0,
    int? end,
    CancellationToken? cancellation,
  }) => Stream.error(const LocationException(LocationFailure.offline));
}
