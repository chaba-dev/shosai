import 'dart:async';
import 'dart:ui' as ui;

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

Future<ui.Image> _image({int width = 8, int height = 8}) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder);
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(width, height);
  } finally {
    picture.dispose();
  }
}

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

  group('the tab switcher', () {
    test('opens over the reader only', () {
      expect(
        update(
          _open([1], reading: false),
          const ShellSwitcherOpened(),
        ).switching,
        isFalse,
      );
      final open = update(_open([1, 2]), const ShellSwitcherOpened());
      expect(open.switching, isTrue);
      expect(update(open, const ShellSwitcherOpened()), same(open));
      expect(update(open, const ShellSwitcherClosed()).switching, isFalse);
    });

    test('choosing a book reads it, the current one too', () {
      final open = update(_open([1, 2]), const ShellSwitcherOpened());
      final other = update(open, const ShellBookActivated(1));
      expect(other.currentBookId, 1);
      expect(other.switching, isFalse);
      final same = update(open, const ShellBookActivated(2));
      expect(same.currentBookId, 2);
      expect(same.switching, isFalse);
    });

    test('closing a book stays in it until the last book goes', () {
      final open = update(_open([1, 2]), const ShellSwitcherOpened());
      final closed = update(open, const ShellBookClosed(1));
      expect(closed.switching, isTrue);
      final empty = update(closed, const ShellBookClosed(2));
      expect(empty.reading, isFalse);
      expect(empty.switching, isFalse);
    });

    test('leaving the reader closes it', () {
      final open = update(_open([1]), const ShellSwitcherOpened());
      expect(
        update(open, const ShellPlaceSelected(ShellPlace.library)).switching,
        isFalse,
      );
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

    test(
      'current and last books release their page miniatures when closed',
      () async {
        final first = await _image();
        final second = await _image();
        final captures = [first, second];
        final presentation = Completer<void>();
        final owned = ShellController(
          presentReader: () => presentation.future,
          dismissReader: () {
            if (!presentation.isCompleted) presentation.complete();
          },
          capturePageMiniature: (_) => captures.removeAt(0),
        );
        addTearDown(owned.dispose);

        owned.dispatch(ShellBookOpened(_book(1)));
        owned.dispatch(ShellBookOpened(_book(2)));
        owned.dispatch(const ShellSwitcherOpened());
        await pumpEventQueue();
        expect(owned.pages.keys, [1, 2]);

        owned.dispatch(const ShellBookClosed(2));
        expect(second.debugDisposed, isTrue);
        expect(owned.pages.keys, [1]);
        owned.dispatch(const ShellBookClosed(1));
        expect(first.debugDisposed, isTrue);
        expect(owned.pages, isEmpty);
      },
    );

    test('a changed document identity invalidates its old miniature', () async {
      final page = await _image();
      final presentation = Completer<void>();
      final owned = ShellController(
        presentReader: () => presentation.future,
        dismissReader: () {
          if (!presentation.isCompleted) presentation.complete();
        },
        capturePageMiniature: (_) => page,
      );
      addTearDown(owned.dispose);

      owned.dispatch(ShellBookOpened(_book(1)));
      owned.dispatch(const ShellSwitcherOpened());
      await pumpEventQueue();
      expect(owned.pages[1], same(page));
      owned.dispatch(const ShellSwitcherClosed());
      owned.dispatch(
        const ShellLocatorChanged(
          1,
          path: '/books/replacement.pdf',
          bookId: null,
        ),
      );
      expect(page.debugDisposed, isTrue);
      expect(owned.pages, isEmpty);
    });

    test('a late miniature for a replaced document is disposed', () async {
      final capture = Completer<ui.Image?>();
      final page = await _image();
      final owned = ShellController(
        presentReader: () => Completer<void>().future,
        dismissReader: () {},
        capturePageMiniature: (_) => capture.future,
      );
      addTearDown(owned.dispose);

      owned.dispatch(ShellBookOpened(_book(1)));
      owned.dispatch(const ShellSwitcherOpened());
      owned.dispatch(
        const ShellLocatorChanged(
          1,
          path: '/books/replacement.pdf',
          bookId: null,
        ),
      );
      capture.complete(page);
      await pumpEventQueue();

      expect(page.debugDisposed, isTrue);
      expect(owned.pages, isEmpty);
    });

    test('a late miniature cannot cross a close and reopen', () async {
      final capture = Completer<ui.Image?>();
      final page = await _image();
      final owned = ShellController(
        presentReader: () => Completer<void>().future,
        dismissReader: () {},
        capturePageMiniature: (_) => capture.future,
      );
      addTearDown(owned.dispose);

      owned.dispatch(ShellBookOpened(_book(1)));
      owned.dispatch(const ShellSwitcherOpened());
      owned.dispatch(const ShellBookClosed(1));
      owned.dispatch(ShellBookOpened(_book(1)));
      capture.complete(page);
      await pumpEventQueue();

      expect(page.debugDisposed, isTrue);
      expect(owned.pages, isEmpty);
    });

    test('a late miniature cannot cross a locator change and return', () async {
      final capture = Completer<ui.Image?>();
      final page = await _image();
      final presentation = Completer<void>();
      final owned = ShellController(
        presentReader: () => presentation.future,
        dismissReader: () {
          if (!presentation.isCompleted) presentation.complete();
        },
        capturePageMiniature: (_) => capture.future,
      );
      addTearDown(owned.dispose);

      owned.dispatch(ShellBookOpened(_book(1)));
      owned.dispatch(const ShellSwitcherOpened());
      owned.dispatch(
        const ShellLocatorChanged(
          1,
          path: '/books/replacement.pdf',
          bookId: null,
        ),
      );
      owned.dispatch(
        ShellLocatorChanged(1, path: _book(1).pathKey, bookId: _book(1).bookId),
      );
      capture.complete(page);
      await pumpEventQueue();

      expect(page.debugDisposed, isTrue);
      expect(owned.pages, isEmpty);
    });

    test('page miniatures stay within the controller memory budget', () async {
      final images = [
        for (var index = 0; index < 5; index += 1)
          await _image(width: 1000, height: 1000),
      ];
      var next = 0;
      final presentation = Completer<void>();
      final owned = ShellController(
        presentReader: () => presentation.future,
        dismissReader: () {
          if (!presentation.isCompleted) presentation.complete();
        },
        capturePageMiniature: (_) => images[next++],
      );
      addTearDown(owned.dispose);

      for (var id = 1; id <= 6; id += 1) {
        owned.dispatch(ShellBookOpened(_book(id)));
      }
      await pumpEventQueue();
      expect(images.first.debugDisposed, isTrue);
      expect(owned.pages.length, 4);
      expect(
        owned.pages.values.fold<int>(
          0,
          (bytes, image) => bytes + image.width * image.height * 4,
        ),
        lessThanOrEqualTo(ShellController.pageMiniatureBudgetBytes),
      );
    });
  });
}
