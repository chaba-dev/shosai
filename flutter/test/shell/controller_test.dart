import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_flutter/shell/controller.dart';
import 'package:shosai_flutter/core/bridge.dart';

FlutterLibraryBook _book(int id, {double progress = 0, String? title}) =>
    FlutterLibraryBook(
      bookId: id,
      title: title ?? 'Book $id',
      format: FlutterBookFormat.epub,
      pathKey: '/books/$id.epub',
      managed: true,
      progress: progress,
      dateAdded: '2026-10-21',
    );

ShellModel _open(List<int> ids, {int? current, bool reading = true}) {
  var model = const ShellModel();
  for (final id in ids) {
    model = update(model, ShellBookOpened(_book(id)));
  }
  if (current != null) model = update(model, ShellBookActivated(current));
  return reading ? model : model.copyWith(reading: false);
}

List<int> _ids(ShellModel model) => [
  for (final entry in model.openBooks) entry.id,
];

void main() {
  group('update', () {
    test('opening a book adds it, focuses it and enters the reader', () {
      final model = update(const ShellModel(), ShellBookOpened(_book(1)));
      expect(_ids(model), [1]);
      expect(model.currentBookId, 1);
      expect(model.reading, isTrue);
      expect(model.currentBook!.path, '/books/1.epub');
      expect(model.currentBook!.bookId, 1);
    });

    test('opening an open book focuses it instead of opening it twice', () {
      final opened = _open([1, 2]);
      final model = update(opened, ShellBookOpened(_book(1, progress: .5)));
      expect(_ids(model), [1, 2]);
      expect(model.currentBookId, 1);
      expect(model.openBooks.first.book.progress, .5);
    });

    test('reopening keeps the place the reader reported', () {
      var model = _open([1]);
      model = update(
        model,
        const ShellLocatorChanged(1, path: '/books/1.epub#c4', bookId: 1),
      );
      model = update(model, ShellBookOpened(_book(1)));
      expect(model.currentBook!.path, '/books/1.epub#c4');
      expect(model.currentBook!.bookId, 1);
    });

    test('closing the current book selects the one below it', () {
      final model = update(_open([1, 2, 3], current: 2), ShellBookClosed(2));
      expect(_ids(model), [1, 3]);
      expect(model.currentBookId, 3);
      expect(model.reading, isTrue);
    });

    test('closing the last row selects the one above it', () {
      final model = update(_open([1, 2, 3]), ShellBookClosed(3));
      expect(model.currentBookId, 2);
    });

    test('closing another book keeps the current one', () {
      final model = update(_open([1, 2, 3], current: 3), ShellBookClosed(1));
      expect(_ids(model), [2, 3]);
      expect(model.currentBookId, 3);
    });

    test('closing the only book returns to the library', () {
      final model = update(
        _open([1]).copyWith(place: ShellPlace.notes),
        ShellBookClosed(1),
      );
      expect(model.openBooks, isEmpty);
      expect(model.currentBookId, isNull);
      expect(model.reading, isFalse);
      expect(model.place, ShellPlace.library);
    });

    test('a place leaves the reader and keeps the open books', () {
      final model = update(
        _open([1, 2]),
        const ShellPlaceSelected(ShellPlace.notes),
      );
      expect(model.reading, isFalse);
      expect(model.place, ShellPlace.notes);
      expect(_ids(model), [1, 2]);
      expect(model.currentBookId, 2);
    });

    test('activating an unknown book changes nothing', () {
      final model = _open([1]);
      expect(update(model, const ShellBookActivated(9)), same(model));
    });

    test('rows reorder by moving', () {
      final model = update(_open([1, 2, 3]), const ShellBookMoved(2, 0));
      expect(_ids(model), [3, 1, 2]);
      expect(update(model, const ShellBookMoved(0, 5)), same(model));
    });

    test('library reloads refresh the open entries they list', () {
      final model = update(
        _open([1, 2]),
        ShellLibraryBooksChanged([_book(2, progress: .4), _book(5)]),
      );
      expect(model.openBooks[0].book.progress, 0);
      expect(model.openBooks[1].book.progress, .4);
      final unchanged = update(model, ShellLibraryBooksChanged([_book(1)]));
      expect(unchanged, same(model));
    });
  });

  test('restoring brings back the open books without reading', () {
    final restored = _open([1, 2], current: 1);
    final model = update(const ShellModel(), ShellRestored(restored));
    expect(_ids(model), [1, 2]);
    expect(model.currentBookId, 1);
    expect(model.reading, isFalse);
    // A session that already has open books keeps them.
    expect(update(model, ShellRestored(_open([3]))), same(model));
  });

  group('ShellController', () {
    late List<Completer<void>> presentations;
    late int dismissals;
    late ShellController controller;

    setUp(() {
      presentations = [];
      dismissals = 0;
      controller = ShellController(
        presentReader: () {
          final presentation = Completer<void>();
          presentations.add(presentation);
          return presentation.future;
        },
        dismissReader: () {
          dismissals += 1;
          presentations.last.complete();
        },
      );
    });

    tearDown(() => controller.dispose());

    test('presents the reader once while books switch', () async {
      controller.dispatch(ShellBookOpened(_book(1)));
      controller.dispatch(ShellBookOpened(_book(2)));
      controller.dispatch(const ShellBookActivated(1));
      expect(presentations, hasLength(1));
      expect(controller.model.currentBookId, 1);
    });

    test('a place dismisses the reader and settles the open effect', () async {
      controller.dispatch(ShellBookOpened(_book(1)));
      var settled = false;
      unawaited(controller.readerDismissed.then((_) => settled = true));
      controller.dispatch(const ShellPlaceSelected(ShellPlace.search));
      await pumpEventQueue();
      expect(dismissals, 1);
      expect(settled, isTrue);
      expect(controller.model.reading, isFalse);
      expect(controller.model.place, ShellPlace.search);
    });

    test('the reader leaving on its own ends reading', () async {
      controller.dispatch(ShellBookOpened(_book(1)));
      presentations.single.complete();
      await pumpEventQueue();
      expect(controller.model.reading, isFalse);
      expect(dismissals, 0);
      expect(controller.model.openBooks, hasLength(1));
    });

    test('closing the last book dismisses the reader', () async {
      controller.dispatch(ShellBookOpened(_book(1)));
      controller.dispatch(const ShellBookClosed(1));
      await pumpEventQueue();
      expect(dismissals, 1);
      expect(controller.model.reading, isFalse);
    });

    test('reading again presents a new reader', () async {
      controller.dispatch(ShellBookOpened(_book(1)));
      controller.dispatch(const ShellPlaceSelected(ShellPlace.library));
      await pumpEventQueue();
      controller.dispatch(const ShellBookActivated(1));
      expect(presentations, hasLength(2));
      expect(controller.model.reading, isTrue);
    });

    test('a stale presentation cannot end the next reader session', () async {
      // The first presentation's dismissal is held until after the reader
      // was presented again.
      final held = <Completer<void>>[];
      final overlapping = ShellController(
        presentReader: () {
          final presentation = Completer<void>();
          held.add(presentation);
          return presentation.future;
        },
        dismissReader: () {},
      );
      addTearDown(overlapping.dispose);
      overlapping.dispatch(ShellBookOpened(_book(1)));
      final firstDismissed = overlapping.readerDismissed;
      overlapping.dispatch(const ShellPlaceSelected(ShellPlace.library));
      overlapping.dispatch(const ShellBookActivated(1));
      expect(held, hasLength(2));

      held.first.complete();
      await pumpEventQueue();
      await firstDismissed;
      expect(overlapping.model.reading, isTrue);

      var settled = false;
      unawaited(overlapping.readerDismissed.then((_) => settled = true));
      await pumpEventQueue();
      expect(settled, isFalse);
      held.last.complete();
      await pumpEventQueue();
      expect(settled, isTrue);
      expect(overlapping.model.reading, isFalse);
    });

    test('readerDismissed is complete when nothing is presented', () async {
      await controller.readerDismissed;
    });
  });
}
