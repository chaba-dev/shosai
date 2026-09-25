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

  test('pagingFailed is explicit state a copyWith keeps', () {
    // A paging failure keeps the collection and its next page, so its recovery
    // is the paging row's alert: the flag is what tells the two failure
    // positions apart.
    expect(const LibraryModel().pagingFailed, isFalse);
    const failed = LibraryModel(
      loadError: 'page failed',
      pagingFailed: true,
      hasMore: true,
    );
    expect(failed.copyWith(loadingMore: true).pagingFailed, isTrue);
    expect(failed.copyWith(pagingFailed: false).pagingFailed, isFalse);
  });

  test('collectionState distinguishes the four collection shapes', () {
    // Page one loading is the skeleton, even over an empty model and over the
    // books a reload is replacing.
    expect(
      const LibraryModel(loading: true).collectionState,
      LibraryCollectionState.loading,
    );
    expect(
      const LibraryModel(loading: true, books: []).collectionState,
      LibraryCollectionState.loading,
    );

    // A later page keeps the grid: it is not page one.
    expect(
      const LibraryModel(
        loading: true,
        loadingMore: true,
        books: [],
      ).collectionState,
      LibraryCollectionState.empty,
    );

    // No books, no search, no filter: the empty-library composition.
    expect(
      const LibraryModel(loaded: true).collectionState,
      LibraryCollectionState.empty,
    );

    // A search or a format filter makes it the no-matches composition.
    expect(
      const LibraryModel(loaded: true, query: 'x').collectionState,
      LibraryCollectionState.noMatches,
    );
    expect(
      const LibraryModel(
        loaded: true,
        format: FlutterBookFormat.epub,
      ).collectionState,
      LibraryCollectionState.noMatches,
    );
  });

  test('copyWith carries the loading flags', () {
    const model = LibraryModel();
    final loading = model.copyWith(loading: true, loadingMore: true);
    expect(loading.loading, isTrue);
    expect(loading.loadingMore, isTrue);

    final cleared = loading.copyWith(loading: false, loadingMore: false);
    expect(cleared.loading, isFalse);
    expect(cleared.loadingMore, isFalse);
  });
}
