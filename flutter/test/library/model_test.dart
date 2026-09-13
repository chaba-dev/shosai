import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_flutter/library/view.dart';
import 'package:shosai_flutter/src/rust/api.dart';

void main() {
  test('copyWith preserves fields when they are not passed', () {
    const model = LibraryModel(
      query: 'needle',
      format: FlutterBookFormat.epub,
      hasMore: true,
    );

    final updated = model.copyWith(busy: true);

    expect(updated.query, 'needle');
    expect(updated.format, FlutterBookFormat.epub);
    expect(updated.hasMore, isTrue);
    expect(updated.busy, isTrue);
  });

  test('copyWith sentinels can clear nullable fields', () {
    const model = LibraryModel(
      format: FlutterBookFormat.pdf,
      error: 'boom',
      loadError: 'load boom',
      settings: FlutterReaderSettings(
        continuous: false,
        theme: 'light',
        epubFontSize: 18,
        epubLineSpacing: 1.5,
        pdfZoom: 0,
      ),
    );

    final cleared = model.copyWith(
      format: null,
      error: null,
      loadError: null,
      settings: null,
    );

    expect(cleared.format, isNull);
    expect(cleared.error, isNull);
    expect(cleared.loadError, isNull);
    expect(cleared.settings, isNull);
  });

  test('displayError prefers the mutation error over the load error', () {
    const both = LibraryModel(error: 'mutation', loadError: 'load');
    expect(both.displayError, 'mutation');
    expect(const LibraryModel(loadError: 'load').displayError, 'load');
  });
}
