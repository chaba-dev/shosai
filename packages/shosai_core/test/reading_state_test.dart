import 'package:shosai_core/shosai_core.dart';
import 'package:test/test.dart';

import 'support/library_fixtures.dart';

void main() {
  late TempLibrary t;
  late Book epub;
  late Book pdf;

  setUp(() async {
    t = await TempLibrary.create();
    epub = await t.importBook(t.copyFixture('sample.epub', 'sample.epub'));
    pdf = await t.importBook(t.copyFixture('sample.pdf', 'sample.pdf'));
  });

  group('reading state', () {
    test('a book without a saved position has none', () async {
      expect(await ReadingState(t.store).load(epub.id), isNull);
    });

    test('saves and restores the position, overwriting the last', () async {
      final state = ReadingState(t.store);

      await state.save(
        epub.id,
        const ReadingPosition(unit: 2, offset: 1234, zoom: 1),
        unitCount: 5,
      );
      expect(
        await state.load(epub.id),
        const ReadingPosition(unit: 2, offset: 1234, zoom: 1),
      );

      await state.save(
        epub.id,
        const ReadingPosition(unit: 3, zoom: 1.5),
        unitCount: 5,
      );
      expect(
        await state.load(epub.id),
        const ReadingPosition(unit: 3, zoom: 1.5),
      );
    });

    test('books keep independent positions', () async {
      final state = ReadingState(t.store);

      await state.save(epub.id, const ReadingPosition(unit: 1), unitCount: 3);
      await state.save(
        pdf.id,
        const ReadingPosition(unit: 0, zoom: 2),
        unitCount: 1,
      );
      await state.save(epub.id, const ReadingPosition(unit: 2), unitCount: 3);

      expect(await state.load(epub.id), const ReadingPosition(unit: 2));
      expect(await state.load(pdf.id), const ReadingPosition(unit: 0, zoom: 2));
    });

    test('saving records library progress and the reading time', () async {
      final state = ReadingState(t.store);

      await state.save(epub.id, const ReadingPosition(unit: 2), unitCount: 5);
      final book = (await t.library.get(epub.id))!;

      expect(book.progress, 0.5);
      expect(book.lastRead, isNotNull);
      expect(readingProgress(0, 5), 0);
      expect(readingProgress(4, 5), 1);
      expect(readingProgress(9, 5), 1);
      expect(readingProgress(0, 1), 1);
    });

    test('the last unit in view counts toward progress', () async {
      final state = ReadingState(t.store);

      // A four-page spread's last two pages: the position is the first.
      await state.save(
        epub.id,
        const ReadingPosition(unit: 2),
        unitCount: 4,
        lastUnit: 3,
      );
      expect((await t.library.get(epub.id))!.progress, 1);
      expect(await state.load(epub.id), const ReadingPosition(unit: 2));

      await expectLater(
        state.save(
          epub.id,
          const ReadingPosition(unit: 2),
          unitCount: 4,
          lastUnit: 1,
        ),
        throwsA(isA<CoreException>()),
      );
    });

    test('canonical progress is atomic with its durable position', () async {
      final state = ReadingState(t.store);
      const position = ReadingPosition(unit: 0, offset: 230, zoom: 1.5);
      await state.save(epub.id, position, unitCount: 3, progress: .23);
      expect((await t.library.get(epub.id))!.progress, .23);
      expect(await state.load(epub.id), position);
      for (final invalid in [-.1, 1.1, double.nan, double.infinity]) {
        await expectLater(
          state.save(
            epub.id,
            const ReadingPosition(unit: 1),
            unitCount: 3,
            progress: invalid,
          ),
          throwsA(isA<CoreException>()),
        );
        expect((await t.library.get(epub.id))!.progress, .23);
        expect(await state.load(epub.id), position);
      }
    });

    test('a failed progress update rolls back the whole save', () async {
      final state = ReadingState(t.store);
      await state.save(
        epub.id,
        const ReadingPosition(unit: 1, offset: 7),
        unitCount: 5,
      );
      final before = (await t.library.get(epub.id))!;
      await t.execute('''CREATE TRIGGER reject_progress
           BEFORE UPDATE OF progress ON books
           BEGIN SELECT RAISE(ABORT, 'injected progress failure'); END''');

      await expectLater(
        state.save(
          epub.id,
          const ReadingPosition(unit: 4, offset: 3, zoom: 2),
          unitCount: 5,
        ),
        throwsCoreError(CoreErrorKind.storage),
      );

      expect(
        await state.load(epub.id),
        const ReadingPosition(unit: 1, offset: 7),
      );
      final after = (await t.library.get(epub.id))!;
      expect(before.progress, 0.25);
      expect(after.progress, 0.25);
      expect(after.lastRead, isNotNull);
      expect(after.lastRead, before.lastRead);
    });

    test('positions persist across opens', () async {
      await ReadingState(
        t.store,
      ).save(epub.id, const ReadingPosition(unit: 7, offset: 42), unitCount: 9);
      await t.store.close();

      final reopened = await Store.open(t.store.path);
      addTearDown(reopened.close);

      expect(
        await ReadingState(reopened).load(epub.id),
        const ReadingPosition(unit: 7, offset: 42),
      );
    });

    test(
      'a position follows the content through removal and re-import',
      () async {
        final state = ReadingState(t.store);
        await state.save(
          epub.id,
          const ReadingPosition(unit: 1, offset: 9),
          unitCount: 2,
        );

        await t.library.remove(epub.id);
        final again = await t.importBook(t.path('sample.epub'));

        expect(again.id, isNot(epub.id));
        expect(
          await state.load(again.id),
          const ReadingPosition(unit: 1, offset: 9),
        );
      },
    );

    test('accepts large units and small zooms', () async {
      final state = ReadingState(t.store);
      const position = ReadingPosition(unit: 1 << 40, offset: 0, zoom: 0.01);

      await state.save(pdf.id, position, unitCount: 1 << 41);

      expect(await state.load(pdf.id), position);
    });

    test('rejects unrepresentable positions and unknown books', () async {
      final state = ReadingState(t.store);
      for (final position in [
        const ReadingPosition(unit: -1),
        const ReadingPosition(unit: 0, offset: -1),
        const ReadingPosition(unit: 0, zoom: 0),
        const ReadingPosition(unit: 0, zoom: -1),
        const ReadingPosition(unit: 0, zoom: double.nan),
        const ReadingPosition(unit: 0, zoom: double.infinity),
      ]) {
        await expectLater(
          state.save(epub.id, position, unitCount: 1),
          throwsCoreError(CoreErrorKind.invalidRequest),
          reason: '$position',
        );
      }
      await expectLater(
        state.save(epub.id, const ReadingPosition(unit: 0), unitCount: 0),
        throwsCoreError(CoreErrorKind.invalidRequest),
      );
      await expectLater(
        state.save(pdf.id + 1, const ReadingPosition(unit: 0), unitCount: 1),
        throwsCoreError(CoreErrorKind.notFound),
      );
      await expectLater(
        state.load(pdf.id + 1),
        throwsCoreError(CoreErrorKind.notFound),
      );
      expect(await state.load(epub.id), isNull);
    });

    test('the schema rejects malformed rows', () async {
      for (final row in <List<Object?>>[
        ['A' * 64, 0, null, 1.0],
        ['a' * 64, -1, null, 1.0],
        ['a' * 64, 0, -1, 1.0],
        ['a' * 64, 0, null, 0.0],
        ['a' * 64, 0, null, double.infinity],
      ]) {
        await expectLater(
          t.execute(
            '''INSERT INTO reading_state (content_hash, unit, location_offset, zoom)
               VALUES (?, ?, ?, ?)''',
            row,
          ),
          throwsCoreError(CoreErrorKind.storage),
          reason: '$row',
        );
      }
    });
  });

  group('reader settings', () {
    test('defaults until saved, then round-trips', () async {
      final settings = ReaderSettingsStore(t.store);
      expect(await settings.load(), const ReaderSettings());
      expect((await settings.load()).animations, isTrue);

      const saved = ReaderSettings(
        continuous: true,
        theme: ReaderTheme.sepia,
        epubFontSize: 20,
        epubLineSpacing: 1.8,
        pdfZoom: ReaderSettings.pdfZoomFitWidth,
        twoPages: false,
        animations: false,
      );
      await settings.save(saved);

      expect(await settings.load(), saved);
      expect((await ReaderSettingsStore(t.store).load()).animations, isFalse);
      expect(await Preferences(t.store).get('reader.mode'), 'continuous');
      expect(await Preferences(t.store).get('reader.pages'), 'one');
      await t.store.close();
      final reopened = await Store.open(t.store.path);
      addTearDown(reopened.close);
      expect(await ReaderSettingsStore(reopened).load(), saved);
    });

    test('accepts the range ends and rejects values outside them', () async {
      final settings = ReaderSettingsStore(t.store);
      await settings.save(
        const ReaderSettings(
          epubFontSize: 8,
          epubLineSpacing: 3,
          pdfZoom: ReaderSettings.maxPdfZoom,
        ),
      );

      for (final invalid in const [
        ReaderSettings(epubFontSize: 7.9),
        ReaderSettings(epubFontSize: 72.1),
        ReaderSettings(epubFontSize: double.nan),
        ReaderSettings(epubLineSpacing: 0.9),
        ReaderSettings(epubLineSpacing: 3.1),
        ReaderSettings(pdfZoom: 0.2),
        ReaderSettings(pdfZoom: 8.5),
        ReaderSettings(pdfZoom: -2),
        ReaderSettings(pdfZoom: double.infinity),
      ]) {
        await expectLater(
          settings.save(invalid),
          throwsCoreError(CoreErrorKind.invalidRequest),
          reason: '$invalid',
        );
      }
      expect((await settings.load()).pdfZoom, ReaderSettings.maxPdfZoom);
    });

    test('settings saved before the Pages setting still load', () async {
      await Preferences(t.store).setAll({
        'reader.mode': 'continuous',
        'reader.theme': 'dark',
        'reader.epub_font_size': '22',
        'reader.epub_line_spacing': '2.0',
        'reader.pdf_zoom': '${ReaderSettings.pdfZoomFitWidth}',
      });

      expect(
        await ReaderSettingsStore(t.store).load(),
        const ReaderSettings(
          continuous: true,
          theme: ReaderTheme.dark,
          epubFontSize: 22,
          epubLineSpacing: 2,
          pdfZoom: ReaderSettings.pdfZoomFitWidth,
        ),
      );
      expect(
        await LibrarySettingsStore(t.store).loadSort(),
        LibrarySort.recent,
      );
    });

    test('a damaged stored value falls back to its default', () async {
      await Preferences(t.store).setAll({
        'reader.mode': 'sideways',
        'reader.theme': 'neon',
        'reader.epub_font_size': 'large',
        'reader.epub_line_spacing': '9',
        'reader.pdf_zoom': '3.5',
        'reader.pages': 'three',
        'reader.animations': 'broken',
      });

      expect(
        await ReaderSettingsStore(t.store).load(),
        const ReaderSettings(pdfZoom: 3.5),
      );
    });
  });

  group('library settings', () {
    test('the sort defaults to recent until saved, then round-trips', () async {
      final settings = LibrarySettingsStore(t.store);
      expect(await settings.loadSort(), LibrarySort.recent);

      await settings.saveSort(LibrarySort.author);

      expect(
        await LibrarySettingsStore(t.store).loadSort(),
        LibrarySort.author,
      );
      expect(await Preferences(t.store).get('library.sort'), 'author');
    });

    test('an unknown stored sort falls back to recent', () async {
      await Preferences(t.store).set('library.sort', 'colour');

      expect(
        await LibrarySettingsStore(t.store).loadSort(),
        LibrarySort.recent,
      );
    });
  });
}
