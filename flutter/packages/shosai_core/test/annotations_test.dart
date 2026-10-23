import 'dart:async';
import 'dart:typed_data';

import 'package:shosai_core/shosai_core.dart';
import 'package:test/test.dart';

import 'support/library_fixtures.dart';
import 'support/temp_store.dart';

const _chapter = 'OEBPS/chapter1.xhtml';
const _text = 'The lead Café text tail of the chapter.';

/// A book's unit texts, as a format engine would supply them.
final class FakeText implements UnitTextSource {
  FakeText(this.units);

  final List<UnitText?> units;
  final requested = <int>[];

  @override
  int get unitCount => units.length;

  @override
  Future<UnitText?> unitText(
    int unit, {
    CancellationToken? cancellation,
  }) async {
    requested.add(unit);
    return units[unit];
  }
}

FakeText _epubText(String text, {String path = _chapter}) =>
    FakeText([UnitText(text, resourcePath: path)]);

EpubTextSelection _select(
  String text,
  String selected, {
  int spineIndex = 0,
  String path = _chapter,
}) {
  final start = text.substring(0, text.indexOf(selected)).runes.length;
  return EpubTextSelection(
    spineIndex: spineIndex,
    resourcePath: path,
    text: text,
    start: start,
    end: start + selected.runes.length,
  );
}

const _rectangles = [PageRect(10.5, 20, 110.25, 32)];

/// Unit texts that run [onRead] as each one is read.
final class _HookedText extends FakeText {
  _HookedText(super.units, this.onRead);

  final void Function(int unit) onRead;

  @override
  Future<UnitText?> unitText(
    int unit, {
    CancellationToken? cancellation,
  }) async {
    final text = await super.unitText(unit, cancellation: cancellation);
    onRead(unit);
    return text;
  }
}

void main() {
  late TempLibrary t;
  late Annotations annotations;
  var books = 0;

  /// A library row for a book of [format]; its file is never read, since
  /// the tests supply each book's text.
  Future<int> book(String format, {String title = 'Edition'}) {
    final hash = (++books).toRadixString(16).padLeft(64, 'a');
    final path = '/books/$hash.$format';
    return t.execute(
      '''INSERT INTO books (title, format, file_path, storage_kind,
           original_path, content_hash, file_size)
         VALUES (?, ?, ?, 'referenced', ?, ?, 0)''',
      [title, format, path, path, hash],
    );
  }

  Future<String> versionOf(int bookId) async {
    final page = await annotations.associationSources(bookId);
    return page.sources.single.versionId;
  }

  setUp(() async {
    t = await TempLibrary.create();
    annotations = Annotations(t.store);
  });

  group('annotations', () {
    test('an EPUB annotation round trips and updates', () async {
      final bookId = await book('epub');

      final created = await annotations.create(
        bookId,
        _select(_text, 'Café text'),
        body: 'First thought',
      );

      expect(created.resolution, AnnotationResolution.exact);
      expect((created.start, created.end), (9, 18));
      final stored = created.annotation;
      expect(stored.id, hasLength(36));
      expect(stored.quote!.exact, 'Café text');
      expect(stored.quote!.prefix, 'The lead');
      expect(stored.quote!.suffix, 'tail of the chapter.');
      expect(
        stored.anchor,
        const EpubAnchor(
          spineIndex: 0,
          resourcePath: _chapter,
          start: 9,
          end: 18,
        ),
      );
      expect(stored.color, HighlightColor.yellow);
      expect(stored.body, 'First thought');
      expect(await annotations.list(bookId, _epubText(_text)), [created]);

      expect(
        await annotations.update(
          bookId,
          stored.id,
          color: HighlightColor.purple,
          body: 'Remember this',
        ),
        isTrue,
      );
      final [updated] = await annotations.list(bookId, _epubText(_text));
      expect(updated.annotation.color, HighlightColor.purple);
      expect(updated.annotation.body, 'Remember this');
      expect(updated.annotation.createdAt, stored.createdAt);
      expect(
        updated.annotation.modifiedAt.compareTo(stored.modifiedAt),
        greaterThan(0),
      );

      expect(
        await annotations.update(bookId, stored.id, color: HighlightColor.blue),
        isTrue,
      );
      final [cleared] = await annotations.list(bookId, _epubText(_text));
      expect(cleared.annotation.body, isNull);
      expect(
        cleared.annotation.modifiedAt.compareTo(updated.annotation.modifiedAt),
        greaterThan(0),
      );
    });

    test('annotations are listed oldest first, only for their book', () async {
      final bookId = await book('epub');
      final other = await book('epub');
      final first = await annotations.create(bookId, _select(_text, 'lead'));
      final second = await annotations.create(bookId, _select(_text, 'tail'));
      await annotations.create(other, _select(_text, 'chapter'));

      expect(
        [
          for (final a in await annotations.list(bookId, _epubText(_text)))
            a.id,
        ],
        [first.id, second.id],
      );
      expect(
        await annotations.update(other, first.id, color: HighlightColor.green),
        isFalse,
      );
      expect(await annotations.delete(other, first.id), isFalse);
    });

    test('a book without annotations lists none', () async {
      final bookId = await book('epub');
      final text = _epubText(_text);

      expect(await annotations.list(bookId, text), isEmpty);
      expect(text.requested, isEmpty);
      expect(
        await annotations.update(bookId, 'unknown', color: HighlightColor.pink),
        isFalse,
      );
      expect(await annotations.delete(bookId, 'unknown'), isFalse);
      expect(
        () => annotations.list(9999, text),
        throwsCoreError(CoreErrorKind.notFound),
      );
    });

    test('a summary counts live annotations and quotes the latest', () async {
      final bookId = await book('epub');
      expect(await annotations.summary(bookId), NotesSummary.empty);
      expect(await annotations.summary(9999), NotesSummary.empty);

      await annotations.create(bookId, _select(_text, 'lead'));
      final cafe = await annotations.create(
        bookId,
        _select(_text, 'Café text'),
        body: 'A thought',
      );
      expect(
        await annotations.summary(bookId),
        const NotesSummary(2, 'Café text'),
        reason: 'a highlight is quoted, not its note',
      );

      await annotations.delete(bookId, cafe.id);
      expect(await annotations.summary(bookId), const NotesSummary(1, 'lead'));
    });

    test('a summary quotes the text as selected, not as normalized', () async {
      final bookId = await book('epub');
      // A decomposed é normalizes to the composed one.
      const decomposed = 'The lead Café text tail of the chapter.';
      await annotations.create(bookId, _select(decomposed, 'Café'));

      expect((await annotations.summary(bookId)).latest, 'Café');
    });

    test('a summary passes over annotations without words', () async {
      final bookId = await book('pdf');
      const page = 'Page two text with a quotable phrase.';
      final start = page.indexOf('quotable');
      await annotations.create(
        bookId,
        PdfSelection(
          page: 1,
          rectangles: _rectangles,
          text: page,
          start: start,
          end: start + 'quotable phrase'.length,
        ),
      );
      // Geometry quotes nothing, and these notes are blank.
      for (final body in ['', ' \n\u3000']) {
        await annotations.create(
          bookId,
          const PdfSelection(page: 0, rectangles: _rectangles),
          body: body,
        );
      }

      expect(
        await annotations.summary(bookId),
        const NotesSummary(3, 'quotable phrase'),
      );

      final blank = await book('pdf', title: 'Blank');
      await annotations.create(
        blank,
        const PdfSelection(page: 0, rectangles: _rectangles),
        body: ' ',
      );
      expect(await annotations.summary(blank), const NotesSummary(1, null));
    });

    test('delete leaves a hidden tombstone', () async {
      final bookId = await book('epub');
      final created = await annotations.create(bookId, _select(_text, 'lead'));

      expect(await annotations.delete(bookId, created.id), isTrue);

      expect(await annotations.list(bookId, _epubText(_text)), isEmpty);
      final [row] = await t.select(
        'SELECT deleted_at, modified_at FROM annotations',
      );
      expect(row['deleted_at'], isNotNull);
      expect(
        (row['modified_at']! as String).compareTo(
          created.annotation.modifiedAt,
        ),
        greaterThan(0),
      );
      expect(await annotations.delete(bookId, created.id), isFalse);
      expect(
        await annotations.update(
          bookId,
          created.id,
          color: HighlightColor.green,
        ),
        isFalse,
      );
    });

    test(
      'annotations follow the content through removal and re-import',
      () async {
        final path = t.copyFixture('sample.epub', 'sample.epub');
        final imported = await t.importBook(path);
        final created = await annotations.create(
          imported.id,
          _select(_text, 'Café'),
        );

        await t.library.remove(imported.id);
        expect(await t.count('annotations'), 1);
        final reimported = await t.importBook(path);

        expect(await annotations.list(reimported.id, _epubText(_text)), [
          created,
        ]);
      },
    );

    test('a content opened outside the library keeps its annotations, '
        'which its library book shares', () async {
      final path = t.copyFixture('sample.epub', 'sample.epub');
      final hash = (await fingerprintFile(path)).hash;
      expect(await hashBookBytes(await readBookBytes(path)), hash);
      final content = AnnotatedContent(
        contentHash: hash,
        format: BookFormat.epub,
        title: 'sample.epub',
      );
      final other = AnnotatedContent(
        contentHash: 'b' * 64,
        format: BookFormat.epub,
        title: 'other.epub',
      );

      final created = await annotations.createInContent(
        content,
        _select(_text, 'Café'),
        body: 'Direct',
      );
      expect(created.annotation.contentHash, hash);
      expect(await annotations.listInContent(content, _epubText(_text)), [
        created,
      ]);
      expect(await annotations.listInContent(other, _epubText(_text)), isEmpty);
      expect(
        await annotations.updateInContent(
          other,
          created.id,
          color: HighlightColor.green,
        ),
        isFalse,
      );
      expect(
        await annotations.updateInContent(
          content,
          created.id,
          color: HighlightColor.green,
        ),
        isTrue,
      );
      expect(
        () => annotations.createInContent(
          AnnotatedContent(
            contentHash: hash,
            format: BookFormat.pdf,
            title: 'sample.epub',
          ),
          PdfSelection(page: 0, rectangles: _rectangles),
        ),
        throwsCoreError(CoreErrorKind.invalidRequest),
      );

      // Importing the same bytes later reaches the same annotations.
      final imported = await t.importBook(path);
      final [listed] = await annotations.list(imported.id, _epubText(_text));
      expect(listed.id, created.id);
      expect(listed.annotation.color, HighlightColor.green);

      expect(await annotations.deleteInContent(other, created.id), isFalse);
      expect(await annotations.deleteInContent(content, created.id), isTrue);
      expect(await annotations.list(imported.id, _epubText(_text)), isEmpty);
    });

    test('annotated content is checked', () {
      expect(
        () => AnnotatedContent(
          contentHash: 'A' * 64,
          format: BookFormat.epub,
          title: 'x',
        ),
        throwsCoreError(CoreErrorKind.invalidRequest),
      );
      expect(
        () => AnnotatedContent(
          contentHash: 'a' * 64,
          format: BookFormat.epub,
          title: '',
        ),
        throwsCoreError(CoreErrorKind.invalidRequest),
      );
    });

    test('concurrent first annotations create one document version', () async {
      final bookId = await book('epub');

      await Future.wait([
        for (final word in ['lead', 'Café', 'tail', 'chapter'])
          annotations.create(bookId, _select(_text, word)),
      ]);

      expect(await t.count('annotation_documents'), 1);
      expect(await t.count('annotation_document_versions'), 1);
      expect(await t.count('annotations'), 4);
    });
  });

  group('PDF annotations', () {
    test('text and geometry-only annotations round trip', () async {
      final bookId = await book('pdf');
      const page = 'Page two text with a quotable phrase.';
      final start = page.indexOf('quotable');

      final text = await annotations.create(
        bookId,
        PdfSelection(
          page: 1,
          rectangles: _rectangles,
          text: page,
          start: start,
          end: start + 'quotable phrase'.length,
        ),
        color: HighlightColor.green,
      );
      final geometry = await annotations.create(
        bookId,
        const PdfSelection(page: 0, rectangles: _rectangles),
        provenance: const AnnotationProvenance('kindle', 'note-7'),
      );

      expect(text.resolution, AnnotationResolution.exact);
      expect((text.start, text.end), (start, start + 15));
      expect(text.annotation.quote!.exact, 'quotable phrase');
      expect(geometry.resolution, AnnotationResolution.exact);
      expect(geometry.rectangles, _rectangles);
      expect(geometry.annotation.quote, isNull);
      expect(
        geometry.annotation.provenance,
        const AnnotationProvenance('kindle', 'note-7'),
      );

      final source = FakeText([null, const UnitText(page)]);
      final listed = await annotations.list(bookId, source);
      expect(listed, [text, geometry]);
      expect(source.requested, [1]);
    });

    test('rectangles are checked as the float32 values stored', () async {
      final bookId = await book('pdf');
      for (final rectangle in [
        // Overflows float32 to infinity.
        const PageRect(0, 0, 1e40, 9),
        const PageRect(-1e40, 0, 5, 9),
        // Distinct doubles, one float32: an empty rectangle.
        const PageRect(16777216, 0, 16777217, 9),
        const PageRect(0, 16777216, 9, 16777217),
      ]) {
        await expectLater(
          annotations.create(
            bookId,
            PdfSelection(page: 0, rectangles: [_rectangles.first, rectangle]),
          ),
          throwsCoreError(CoreErrorKind.invalidRequest),
          reason: '$rectangle',
        );
      }
      expect(await t.count('annotations'), 0);

      // Not representable in float32, and still valid once rounded.
      const ordinary = PageRect(0.1, 0.2, 100.3, 50.7);
      final created = await annotations.create(
        bookId,
        const PdfSelection(page: 0, rectangles: [ordinary]),
      );
      expect(created.rectangles, [ordinary.quantized]);
      expect(ordinary.quantized, isNot(ordinary));
      expect(ordinary.quantized.isValid, isTrue);
      final [listed] = await annotations.list(bookId, FakeText([null]));
      expect(listed.rectangles, [ordinary.quantized]);
    });

    test('stored rectangles and quotes are checked when read', () async {
      final pdf = await book('pdf');
      await annotations.create(
        pdf,
        const PdfSelection(page: 0, rectangles: _rectangles),
      );
      final empty = ByteData(16)
        ..setFloat32(0, 5, Endian.little)
        ..setFloat32(4, 0, Endian.little)
        ..setFloat32(8, 5, Endian.little)
        ..setFloat32(12, 9, Endian.little);
      await t.execute('UPDATE annotations SET pdf_rectangles = ?', [
        empty.buffer.asUint8List(),
      ]);
      await expectLater(
        annotations.list(pdf, FakeText([null])),
        throwsCoreError(CoreErrorKind.malformed),
      );

      final epub = await book('epub');
      await annotations.create(epub, _select(_text, 'lead'));
      for (final (column, value) in [
        ('normalized_exact', 'other'),
        ('normalized_exact', 'a  b'),
        ('normalized_prefix', ' The'),
      ]) {
        await t.execute(
          "UPDATE annotations SET $column = ? WHERE format = 'epub'",
          [value],
        );
        await expectLater(
          annotations.list(epub, _epubText(_text)),
          throwsCoreError(CoreErrorKind.malformed),
          reason: '$column $value',
        );
      }
    });

    test('stored oversized clusters are malformed without stalling', () async {
      final epub = await book('epub');
      await annotations.create(epub, _select(_text, 'lead'));
      // One cluster of combining marks: already normalized and within the
      // scalar limits, but quadratic for NFC.
      final marks = '́' * maxQuoteScalars;
      final watch = Stopwatch()..start();
      for (final (original, exact) in [(null, marks), (marks, 'lead')]) {
        await t.execute(
          '''UPDATE annotations SET original_quote = ?, normalized_exact = ?
             WHERE format = 'epub' ''',
          [original, exact],
        );
        await expectLater(
          annotations.list(epub, _epubText(_text)),
          throwsCoreError(CoreErrorKind.malformed),
          reason: '${original?.length} ${exact.length}',
        );
        // Cancellation is observed before stored rows are checked.
        await expectLater(
          annotations.list(
            epub,
            _epubText(_text),
            cancellation: CancellationToken()..cancel(),
          ),
          throwsCoreError(CoreErrorKind.cancelled),
        );
      }
      expect(watch.elapsed, lessThan(const Duration(seconds: 1)));

      // A stored cluster at the ceiling is still read.
      final ceiling = '́' * maxAnchorGraphemeScalars;
      await t.execute(
        '''UPDATE annotations SET original_quote = ?, normalized_exact = ?
           WHERE format = 'epub' ''',
        [ceiling, ceiling],
      );
      final [listed] = await annotations.list(epub, _epubText(_text));
      expect(listed.annotation.quote?.exact, ceiling);
    });

    test('one listing bounds the normalization work of all its rows', () async {
      // Ordinary text that needs the normalizer: precomposed and decomposed
      // Latin, Cyrillic and Greek, in a full document of annotations.
      const text =
          'Lead. Съешь же ещё этих мягких французских булок, да выпей чаю. '
          'Tiếng Việt có dấu. Ελληνικά κείμενα. Cafe\u0301 au lait. Tail.';
      final epub = await book('epub');
      final first = await annotations.create(
        epub,
        _select(text, text.substring(6, text.length - 6)),
      );
      await t.executeMany(
        '''INSERT INTO annotations (id, version_id, format, kind,
             anchor_version, original_quote, normalization_profile,
             normalized_exact, normalized_prefix, normalized_suffix, color,
             epub_spine_index, epub_resource_path, epub_scalar_start,
             epub_scalar_end)
           SELECT ?, version_id, format, kind, anchor_version, original_quote,
             normalization_profile, normalized_exact, normalized_prefix,
             normalized_suffix, color, epub_spine_index, epub_resource_path,
             epub_scalar_start, epub_scalar_end
           FROM annotations WHERE id = ?''',
        [
          for (var index = 1; index < maxAnnotationsPerDocument; index++)
            [
              '00000000-0000-4000-8000-${index.toString().padLeft(12, '0')}',
              first.id,
            ],
        ],
      );
      final listed = await annotations.list(epub, _epubText(text));
      expect(listed, hasLength(maxAnnotationsPerDocument));
      expect(listed.map((annotation) => annotation.resolution).toSet(), {
        AnnotationResolution.exact,
      });

      // Each row holds one distinct cluster within the ceiling, already
      // normalized; together they need more NFC work than one listing may
      // spend.
      await t.execute(
        '''UPDATE annotations SET original_quote = NULL, normalized_exact =
             replace(hex(zeroblob(? - rowid)), '00', char(0x301))''',
        [maxQuoteGraphemeScalars + 1],
      );
      final watch = Stopwatch()..start();
      await expectLater(
        annotations.list(epub, _epubText(text)),
        throwsCoreError(CoreErrorKind.limitExceeded, contains('work limit')),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));

      // A few such rows are still read.
      await t.execute('DELETE FROM annotations WHERE rowid > 4');
      expect(await annotations.list(epub, _epubText(text)), hasLength(4));
    });

    test('geometry resolves only on the content it was drawn on', () async {
      final drawn = await book('pdf');
      final edition = await book('pdf');
      await annotations.create(
        drawn,
        const PdfSelection(page: 0, rectangles: _rectangles),
      );

      expect(
        await annotations.associate(await versionOf(edition), edition),
        AssociationOutcome.associated,
      );

      final [resolved] = await annotations.list(edition, FakeText([null]));
      expect(resolved.resolution, AnnotationResolution.orphaned);
      expect(resolved.rectangles, isEmpty);
      final [original] = await annotations.list(drawn, FakeText([null]));
      expect(original.resolution, AnnotationResolution.exact);
      // A page the open document no longer has.
      final [missing] = await annotations.list(drawn, FakeText([]));
      expect(missing.resolution, AnnotationResolution.orphaned);
    });
  });

  group('resolution', () {
    test('changed content recovers, loses, or cannot place quotes', () async {
      final original = await book('epub');
      final edition = await book('epub');
      final recovered = await annotations.create(
        original,
        _select(_text, 'Café text'),
      );
      final lost = await annotations.create(
        original,
        _select(_text, 'chapter'),
      );
      await annotations.associate(await versionOf(edition), edition);

      final listed = await annotations.list(
        edition,
        _epubText('Inserted words. The lead Café text tail.'),
      );

      expect(listed.map((a) => a.id), [recovered.id, lost.id]);
      expect(listed[0].resolution, AnnotationResolution.recovered);
      expect((listed[0].start, listed[0].end), (25, 34));
      expect(listed[1].resolution, AnnotationResolution.orphaned);
      expect(listed[1].start, isNull);

      final [ambiguous, _] = await annotations.list(
        edition,
        _epubText('Café text, and again Café text.'),
      );
      expect(ambiguous.resolution, AnnotationResolution.ambiguous);
    });

    test('stale offsets on another content are not evidence', () async {
      final original = await book('epub');
      final edition = await book('epub');
      const before = 'one two one';
      await annotations.create(original, _select(before, 'two'));
      await annotations.associate(await versionOf(edition), edition);

      // The old offsets still cover the quote, but on another content only
      // the quote places it.
      final [resolved] = await annotations.list(edition, _epubText('xxx two'));

      expect(resolved.resolution, AnnotationResolution.recovered);
      expect((resolved.start, resolved.end), (4, 7));
    });

    test('a spine item holding another resource orphans its anchors', () async {
      final bookId = await book('epub');
      await annotations.create(bookId, _select(_text, 'lead'));

      final [moved] = await annotations.list(
        bookId,
        _epubText(_text, path: 'OEBPS/other.xhtml'),
      );
      final [unknown] = await annotations.list(
        bookId,
        FakeText([const UnitText(_text)]),
      );
      final [empty] = await annotations.list(bookId, FakeText([null]));
      final [gone] = await annotations.list(bookId, FakeText([]));

      expect(moved.resolution, AnnotationResolution.orphaned);
      expect(unknown.resolution, AnnotationResolution.exact);
      expect(empty.resolution, AnnotationResolution.orphaned);
      expect(gone.resolution, AnnotationResolution.orphaned);
    });

    test('anchors are resolved against each unit once', () async {
      final bookId = await book('epub');
      final units = [
        for (var spine = 0; spine < 3; spine++)
          UnitText('Chapter $spine text', resourcePath: 'c$spine.xhtml'),
      ];
      for (final spine in [2, 0, 2]) {
        await annotations.create(
          bookId,
          _select(
            units[spine].text,
            'text',
            spineIndex: spine,
            path: 'c$spine.xhtml',
          ),
        );
      }
      final source = FakeText(units);

      final listed = await annotations.list(bookId, source);

      expect(listed.map((a) => (a.unit, a.resolution)), [
        (2, AnnotationResolution.exact),
        (0, AnnotationResolution.exact),
        (2, AnnotationResolution.exact),
      ]);
      expect(source.requested.toSet(), {0, 2});
      expect(source.requested, hasLength(2));
    });

    test('cancellation while the last unit text is read fails', () async {
      final bookId = await book('epub');
      await annotations.create(bookId, _select(_text, 'lead'));
      final cancellation = CancellationToken();
      // The only unit cancels and has no text, so no batch is left to run.
      final source = _HookedText([null], (_) => cancellation.cancel());

      await expectLater(
        annotations.list(bookId, source, cancellation: cancellation),
        throwsCoreError(CoreErrorKind.cancelled),
      );
      expect(source.requested, [0]);
    });

    test('cancellation while the final batch runs fails', () async {
      final bookId = await book('epub');
      await annotations.create(bookId, _select(_text, 'lead'));
      final cancellation = CancellationToken();
      // Cancels once the batch has been sent to its isolate.
      final source = _HookedText([
        const UnitText(_text, resourcePath: _chapter),
      ], (_) => Timer.run(cancellation.cancel));

      await expectLater(
        annotations.list(bookId, source, cancellation: cancellation),
        throwsCoreError(CoreErrorKind.cancelled),
      );
      expect(source.requested, [0]);
    });

    test('listing observes cancellation', () async {
      final bookId = await book('epub');
      await annotations.create(bookId, _select(_text, 'lead'));
      final cancellation = CancellationToken()..cancel();

      expect(
        () => annotations.list(
          bookId,
          _epubText(_text),
          cancellation: cancellation,
        ),
        throwsCoreError(CoreErrorKind.cancelled),
      );
    });
  });

  group('association', () {
    test('brings a source document to a book without annotations', () async {
      final original = await book('epub', title: 'First edition');
      final edition = await book('epub');
      final created = await annotations.create(
        original,
        _select(_text, 'lead'),
      );

      final page = await annotations.associationSources(edition);
      final [source] = page.sources;
      expect(source.title, 'First edition');
      expect(source.liveAnnotations, 1);
      expect(page.nextCursor, isNull);
      expect(page.previousCursor, isNull);

      expect(
        await annotations.associate(source.versionId, edition),
        AssociationOutcome.associated,
      );
      expect(
        await annotations.associate(source.versionId, edition),
        AssociationOutcome.alreadyAssociated,
      );
      expect((await annotations.associationSources(edition)).sources, isEmpty);
      final [listed] = await annotations.list(edition, _epubText(_text));
      expect(listed.annotation, created.annotation);
      expect(listed.annotation.contentHash, isNot(await _hashOf(t, edition)));

      // New annotations on the edition join the same document.
      await annotations.create(edition, _select(_text, 'tail'));
      expect(await t.count('annotation_documents'), 1);
      expect(await annotations.list(original, _epubText(_text)), hasLength(2));
    });

    test('merges two annotated documents', () async {
      final original = await book('epub');
      final edition = await book('epub');
      await annotations.create(original, _select(_text, 'lead'));
      await annotations.create(edition, _select(_text, 'tail'));

      final sourceVersion = await versionOf(edition);
      expect(
        await annotations.associate(sourceVersion, edition),
        AssociationOutcome.associated,
      );

      expect(await t.count('annotation_documents'), 1);
      expect(await t.count('annotation_document_versions'), 2);
      expect(await annotations.list(edition, _epubText(_text)), hasLength(2));
      expect(await annotations.list(original, _epubText(_text)), hasLength(2));
    });

    test('rejects unknown and cross-format sources', () async {
      final epub = await book('epub');
      final pdf = await book('pdf');
      final other = await book('pdf');
      await annotations.create(
        pdf,
        const PdfSelection(page: 0, rectangles: _rectangles),
      );
      final pdfVersion = await versionOf(other);

      expect(
        () => annotations.associate(pdfVersion, epub),
        throwsCoreError(CoreErrorKind.invalidRequest),
      );
      expect(
        () => annotations.associate(_unknownVersion, epub),
        throwsCoreError(CoreErrorKind.notFound),
      );
      expect((await annotations.associationSources(epub)).sources, isEmpty);
      expect(await t.count('annotation_document_versions'), 1);
    });

    test('tombstone-only documents are not sources', () async {
      final original = await book('epub');
      final edition = await book('epub');
      final created = await annotations.create(
        original,
        _select(_text, 'lead'),
      );
      await annotations.delete(original, created.id);

      expect((await annotations.associationSources(edition)).sources, isEmpty);
    });

    test('source pages filter by format and navigate both ways', () async {
      final target = await book('epub');
      final sources = <String>[];
      for (var index = 0; index < 5; index++) {
        final source = await book('epub', title: 'Edition $index');
        await annotations.create(source, _select(_text, 'lead'));
        final tombstoned = await book('epub');
        final deleted = await annotations.create(
          tombstoned,
          _select(_text, 'tail'),
        );
        await annotations.delete(tombstoned, deleted.id);
        final pdf = await book('pdf');
        await annotations.create(
          pdf,
          const PdfSelection(page: 0, rectangles: _rectangles),
        );
      }
      final all = await annotations.associationSources(target, limit: 100);
      sources.addAll(all.sources.map((s) => s.versionId));
      expect(sources, hasLength(5));
      expect(sources, orderedEquals([...sources]..sort()));

      final first = await annotations.associationSources(target, limit: 2);
      final second = await annotations.associationSources(
        target,
        limit: 2,
        cursor: first.nextCursor,
      );
      final third = await annotations.associationSources(
        target,
        limit: 2,
        cursor: second.nextCursor,
      );

      expect(first.sources.map((s) => s.versionId), sources.sublist(0, 2));
      expect(first.previousCursor, isNull);
      expect(second.sources.map((s) => s.versionId), sources.sublist(2, 4));
      expect(second.previousCursor, isNull);
      expect(third.sources.map((s) => s.versionId), sources.sublist(4));
      expect(third.nextCursor, isNull);
      final back = await annotations.associationSources(
        target,
        limit: 2,
        cursor: third.previousCursor,
      );
      expect(back.sources.map((s) => s.versionId), sources.sublist(2, 4));

      for (final limit in [0, maxAssociationSourcesPerPage + 1]) {
        expect(
          () => annotations.associationSources(target, limit: limit),
          throwsCoreError(CoreErrorKind.invalidRequest),
        );
      }
    });

    test('rejects a 129th document version', () async {
      final original = await book('epub');
      await annotations.create(original, _select(_text, 'lead'));
      final source = await versionOf(await book('epub'));
      for (var index = 1; index < maxAnnotationDocumentVersions; index++) {
        await annotations.associate(source, await book('epub'));
      }
      expect(
        await t.count('annotation_document_versions'),
        maxAnnotationDocumentVersions,
      );

      final overflow = await book('epub');
      expect(
        () => annotations.associate(source, overflow),
        throwsCoreError(CoreErrorKind.limitExceeded),
      );
      // Merging is held to the same limit.
      await annotations.create(overflow, _select(_text, 'tail'));
      expect(
        () => annotations.associate(source, overflow),
        throwsCoreError(CoreErrorKind.limitExceeded),
      );
      expect(await t.count('annotation_documents'), 2);
    });
  });

  group('notes', () {
    test('page and book notes round trip in an EPUB', () async {
      final bookId = await book('epub');
      const place = EpubPlaceAnchor(
        spineIndex: 0,
        resourcePath: _chapter,
        offset: 9,
      );

      final page = await annotations.createNote(bookId, place, 'Read again');
      final whole = await annotations.createNote(
        bookId,
        const BookAnchor(),
        'Reading group pick',
      );

      expect(page.annotation.kind, AnnotationKind.pageNote);
      expect(page.annotation.anchor, place);
      expect(page.annotation.color, isNull);
      expect(page.annotation.quote, isNull);
      expect((page.start, page.end), (9, null));
      expect(whole.annotation.kind, AnnotationKind.bookNote);
      expect(whole.unit, isNull);

      final listed = await annotations.list(bookId, _epubText(_text));
      expect(listed, [page, whole]);

      expect(await annotations.updateNote(bookId, page.id, 'Twice'), isTrue);
      expect(await annotations.delete(bookId, whole.id), isTrue);
      final [updated] = await annotations.list(bookId, _epubText(_text));
      expect(updated.annotation.body, 'Twice');
      expect(
        updated.annotation.modifiedAt.compareTo(page.annotation.modifiedAt),
        greaterThan(0),
      );
    });

    test('a PDF page note sits on its page', () async {
      final bookId = await book('pdf');
      final created = await annotations.createNote(
        bookId,
        const PdfPageAnchor(1),
        'Fig. 1 is the model',
      );

      final [listed] = await annotations.list(
        bookId,
        FakeText([const UnitText('one'), const UnitText('two')]),
      );
      final [gone] = await annotations.list(
        bookId,
        FakeText([const UnitText('one')]),
      );

      expect(created.annotation.anchor, const PdfPageAnchor(1));
      expect(listed.resolution, AnnotationResolution.exact);
      expect(listed.unit, 1);
      expect(gone.resolution, AnnotationResolution.orphaned);
    });

    test('notes and highlights are updated only as what they are', () async {
      final bookId = await book('epub');
      final highlight = await annotations.create(
        bookId,
        _select(_text, 'lead'),
      );
      final note = await annotations.createNote(
        bookId,
        const BookAnchor(),
        'Whole',
      );

      expect(await annotations.updateNote(bookId, highlight.id, 'x'), isFalse);
      expect(
        await annotations.update(bookId, note.id, color: HighlightColor.blue),
        isFalse,
      );
      expect(
        (await annotations.list(
          bookId,
          _epubText(_text),
        )).map((a) => (a.annotation.color, a.annotation.body)),
        [(HighlightColor.yellow, null), (null, 'Whole')],
      );
    });

    test('notes need words and a valid place', () async {
      final bookId = await book('epub');
      final pdfBook = await book('pdf');
      for (final (id, anchor, body) in [
        (bookId, const BookAnchor(), ''),
        (bookId, const BookAnchor(), ' \n\t'),
        (
          bookId,
          const EpubPlaceAnchor(
            spineIndex: -1,
            resourcePath: _chapter,
            offset: 0,
          ),
          'x',
        ),
        (
          bookId,
          const EpubPlaceAnchor(
            spineIndex: 0,
            resourcePath: _chapter,
            offset: -1,
          ),
          'x',
        ),
        (
          bookId,
          const EpubPlaceAnchor(spineIndex: 0, resourcePath: null, offset: 0),
          'x',
        ),
        (
          bookId,
          const EpubPlaceAnchor(spineIndex: 0, resourcePath: '', offset: 0),
          'x',
        ),
        (pdfBook, const PdfPageAnchor(-1), 'x'),
        // A place of the other format.
        (
          pdfBook,
          const EpubPlaceAnchor(
            spineIndex: 0,
            resourcePath: _chapter,
            offset: 0,
          ),
          'x',
        ),
        (bookId, const PdfPageAnchor(0), 'x'),
      ]) {
        await expectLater(
          annotations.createNote(id, anchor, body),
          throwsCoreError(CoreErrorKind.invalidRequest),
          reason: '$anchor $body',
        );
      }
      final note = await annotations.createNote(
        bookId,
        const BookAnchor(),
        'kept',
      );
      await expectLater(
        annotations.updateNote(bookId, note.id, '  '),
        throwsCoreError(CoreErrorKind.invalidRequest),
      );
      expect(await t.count('annotations'), 1);
    });

    test(
      'page notes on another content stay in their chapter or page',
      () async {
        final original = await book('epub');
        final edition = await book('epub');
        final kept = await annotations.createNote(
          original,
          const EpubPlaceAnchor(
            spineIndex: 0,
            resourcePath: _chapter,
            offset: 30,
          ),
          'kept',
        );
        final moved = await annotations.createNote(
          original,
          const EpubPlaceAnchor(
            spineIndex: 1,
            resourcePath: 'OEBPS/chapter2.xhtml',
            offset: 0,
          ),
          'moved',
        );
        await annotations.associate(await versionOf(edition), edition);

        final text = FakeText([
          const UnitText('A shorter chapter.', resourcePath: _chapter),
          const UnitText('Another', resourcePath: 'OEBPS/other.xhtml'),
        ]);
        final listed = await annotations.list(edition, text);

        expect(listed.map((a) => a.id), [kept.id, moved.id]);
        expect(listed[0].resolution, AnnotationResolution.recovered);
        // At most at the chapter's end.
        expect(listed[0].start, 18);
        expect(listed[1].resolution, AnnotationResolution.orphaned);
        expect(text.requested, [0, 1]);

        final pdfOriginal = await book('pdf');
        final pdfEdition = await book('pdf');
        await annotations.createNote(
          pdfOriginal,
          const PdfPageAnchor(0),
          'page',
        );
        await annotations.associate(await versionOf(pdfEdition), pdfEdition);
        final [page] = await annotations.list(
          pdfEdition,
          FakeText([const UnitText('changed')]),
        );
        expect(page.resolution, AnnotationResolution.recovered);
      },
    );

    test(
      'a page note with a known chapter is not kept in an unknown one',
      () async {
        final original = await book('epub');
        final edition = await book('epub');
        final known = await annotations.createNote(
          original,
          const EpubPlaceAnchor(
            spineIndex: 0,
            resourcePath: _chapter,
            offset: 10,
          ),
          'known',
        );
        await annotations.associate(await versionOf(edition), edition);

        final [listed] = await annotations.list(
          edition,
          FakeText([const UnitText('An unrelated chapter')]),
        );

        expect(listed.id, known.id);
        expect(listed.resolution, AnnotationResolution.orphaned);
      },
    );

    test('page notes on another content share the resolution budget', () async {
      final original = await book('epub');
      final edition = await book('epub');
      // 17 chapters of 4 Mi scalars each exceed the 64 Mi budget.
      const units = 17;
      for (var spine = 0; spine < units; spine++) {
        await annotations.createNote(
          original,
          EpubPlaceAnchor(
            spineIndex: spine,
            resourcePath: 'c$spine.xhtml',
            offset: 0,
          ),
          'note $spine',
        );
      }
      await annotations.associate(await versionOf(edition), edition);
      final chapter = 'a' * (maxAnchorResolutionWork ~/ 16);

      await expectLater(
        annotations.list(
          edition,
          FakeText([
            for (var spine = 0; spine < units; spine++)
              UnitText(chapter, resourcePath: 'c$spine.xhtml'),
          ]),
        ),
        throwsCoreError(CoreErrorKind.limitExceeded),
      );
    });

    test('a summary counts notes and quotes the latest note', () async {
      final bookId = await book('epub');
      await annotations.create(bookId, _select(_text, 'lead'));
      await annotations.createNote(bookId, const BookAnchor(), 'Whole book');

      expect(
        await annotations.summary(bookId),
        const NotesSummary(2, 'Whole book'),
      );
    });
  });

  group('library notes', () {
    Future<void> read(int bookId, String at) =>
        t.execute('UPDATE books SET last_read = ? WHERE id = ?', [at, bookId]);

    test('lists books with notes, most recently read first', () async {
      final older = await book('epub', title: 'Older');
      final newer = await book('pdf', title: 'Newer');
      final unread = await book('epub', title: 'Unread');
      final empty = await book('epub', title: 'Empty');
      await read(older, '2026-01-01T00:00:00.000Z');
      await read(newer, '2026-02-01T00:00:00.000Z');
      await read(empty, '2026-03-01T00:00:00.000Z');

      final later = await annotations.create(
        older,
        _select(_text, 'tail', spineIndex: 2),
        color: HighlightColor.green,
        body: 'Noted',
      );
      final place = await annotations.createNote(
        older,
        const EpubPlaceAnchor(spineIndex: 0, resourcePath: _chapter, offset: 4),
        'Start here',
      );
      final first = await annotations.create(older, _select(_text, 'Café'));
      final whole = await annotations.createNote(
        older,
        const BookAnchor(),
        'Whole book',
      );
      final page = await annotations.createNote(
        newer,
        const PdfPageAnchor(3),
        'Fig. 1',
      );
      await annotations.createNote(unread, const BookAnchor(), 'Soon');
      final gone = await annotations.createNote(
        empty,
        const BookAnchor(),
        'Gone',
      );
      await annotations.delete(empty, gone.id);

      final listed = await annotations.libraryNotes();

      expect(listed.hasMore, isFalse);
      expect(listed.books.map((b) => (b.book.title, b.book.format)), [
        ('Newer', BookFormat.pdf),
        ('Older', BookFormat.epub),
        ('Unread', BookFormat.epub),
      ]);
      expect(
        listed.books[0].notes.single,
        (NoteEntry(
          id: page.id,
          kind: AnnotationKind.pageNote,
          color: null,
          quote: null,
          body: 'Fig. 1',
          unit: 3,
          offset: null,
          createdAt: page.annotation.createdAt,
          modifiedAt: page.annotation.modifiedAt,
        )),
      );
      final notes = listed.books[1].notes;
      // The book note, then each unit's notes by where they start.
      expect(notes.map((n) => n.id), [whole.id, place.id, first.id, later.id]);
      expect(notes.map((n) => (n.unit, n.offset)), [
        (null, null),
        (0, 4),
        (0, 9),
        (2, 19),
      ]);
      expect(notes[3].quote, 'tail');
      expect(notes[3].color, HighlightColor.green);
      expect(notes[3].body, 'Noted');
      expect(listed.books[1].book.id, older);
    });

    test('pages through the books', () async {
      for (var index = 0; index < 3; index++) {
        final id = await book('epub', title: 'Book $index');
        await read(id, '2026-01-0${index + 1}T00:00:00.000Z');
        await annotations.createNote(id, const BookAnchor(), 'Note $index');
      }

      final first = await annotations.libraryNotes(limit: 2);
      final second = await annotations.libraryNotes(offset: 2, limit: 2);

      expect(first.books.map((b) => b.book.title), ['Book 2', 'Book 1']);
      expect(first.hasMore, isTrue);
      expect(second.books.map((b) => b.book.title), ['Book 0']);
      expect(second.hasMore, isFalse);
      for (final (offset, limit) in [(-1, 1), (0, 0), (0, 101)]) {
        await expectLater(
          annotations.libraryNotes(offset: offset, limit: limit),
          throwsCoreError(CoreErrorKind.invalidRequest),
        );
      }
      final cancelled = CancellationToken()..cancel();
      await expectLater(
        annotations.libraryNotes(cancellation: cancelled),
        throwsCoreError(CoreErrorKind.cancelled),
      );
    });
  });

  group('migration', () {
    test('highlights written before notes existed stay highlights', () async {
      final directory = tempDataDirectory();
      final path = '${directory.path}/library.sqlite3';
      final before = await Store.open(
        path,
        migrations: schemaMigrations.where((m) => m.version <= 5).toList(),
      );
      final hash = 'b' * 64;
      await before.transaction((db) {
        db.execute(
          '''INSERT INTO books (title, format, file_path, storage_kind,
               original_path, content_hash, file_size)
             VALUES ('Old', 'epub', '/old.epub', 'referenced', '/old.epub', ?, 0)''',
          [hash],
        );
        db.execute(
          "INSERT INTO annotation_documents (id, format) VALUES (?, 'epub')",
          [_unknownVersion],
        );
        db.execute(
          '''INSERT INTO annotation_document_versions
               (id, document_id, format, content_hash, title)
             VALUES (?, ?, 'epub', ?, 'Old')''',
          [_unknownVersion, _unknownVersion, hash],
        );
        db.execute(
          '''INSERT INTO annotations (id, version_id, format, anchor_version,
               original_quote, normalization_profile, normalized_exact,
               normalized_prefix, normalized_suffix, color, body,
               epub_spine_index, epub_resource_path, epub_scalar_start,
               epub_scalar_end)
             VALUES ('33333333-3333-4333-8333-333333333333', ?, 'epub', 1,
               'lead', 'shosai-quote-v1', 'lead', 'The', 'Café text', 'pink',
               'Kept', 0, ?, 4, 8)''',
          [_unknownVersion, _chapter],
        );
      });
      await before.close();

      final store = await Store.open(path);
      addTearDown(store.close);
      final [bookRow] = await store.read(
        (db) => [
          for (final row in db.select('SELECT id FROM books')) row.columnAt(0),
        ],
      );
      final [listed] = await Annotations(
        store,
      ).list(bookRow as int, _epubText(_text));

      expect(store.schemaVersion, greaterThanOrEqualTo(6));
      expect(listed.annotation.kind, AnnotationKind.highlight);
      expect(listed.annotation.color, HighlightColor.pink);
      expect(listed.annotation.body, 'Kept');
      expect(listed.resolution, AnnotationResolution.exact);
      expect((listed.start, listed.end), (4, 8));
    });
  });

  group('limits', () {
    test('inputs are checked before anything is written', () async {
      final epub = await book('epub');
      final pdf = await book('pdf');

      final rejected = <(int, AnnotationSelection, CoreErrorKind)>[
        (pdf, _select(_text, 'lead'), CoreErrorKind.invalidRequest),
        (
          epub,
          const PdfSelection(page: 0, rectangles: _rectangles),
          CoreErrorKind.invalidRequest,
        ),
        (epub, _select(_text, 'lead', path: ''), CoreErrorKind.invalidRequest),
        (
          epub,
          _select(_text, 'lead', path: 'x' * (maxEpubResourcePathBytes + 1)),
          CoreErrorKind.invalidRequest,
        ),
        (
          epub,
          const EpubTextSelection(
            spineIndex: 0,
            resourcePath: _chapter,
            text: 'short',
            start: 3,
            end: 9,
          ),
          CoreErrorKind.invalidRequest,
        ),
        (
          pdf,
          const PdfSelection(page: 0, rectangles: []),
          CoreErrorKind.invalidRequest,
        ),
        // NFC expands each U+0958 to two scalars, past the quote limit.
        (
          epub,
          EpubTextSelection(
            spineIndex: 0,
            resourcePath: _chapter,
            text: '\u0958' * 32769,
            start: 0,
            end: 32769,
          ),
          CoreErrorKind.limitExceeded,
        ),
        (
          pdf,
          const PdfSelection(page: 0, rectangles: [PageRect(5, 5, 5, 9)]),
          CoreErrorKind.invalidRequest,
        ),
        (
          pdf,
          const PdfSelection(
            page: 0,
            rectangles: [PageRect(0, 0, double.infinity, 9)],
          ),
          CoreErrorKind.invalidRequest,
        ),
        (
          pdf,
          const PdfSelection(page: 0, rectangles: _rectangles, text: 'text'),
          CoreErrorKind.invalidRequest,
        ),
        (
          pdf,
          const PdfSelection(page: -1, rectangles: _rectangles),
          CoreErrorKind.invalidRequest,
        ),
      ];
      for (final (bookId, selection, kind) in rejected) {
        await expectLater(
          annotations.create(bookId, selection),
          throwsCoreError(kind),
        );
      }
      await expectLater(
        annotations.create(
          epub,
          _select(_text, 'lead'),
          body: 'x' * (maxAnnotationBodyScalars + 1),
        ),
        throwsCoreError(CoreErrorKind.limitExceeded),
      );
      for (final provenance in [
        const AnnotationProvenance(' '),
        const AnnotationProvenance('kindle', ''),
        AnnotationProvenance('x' * (maxProvenanceSystemBytes + 1)),
      ]) {
        await expectLater(
          annotations.create(
            epub,
            _select(_text, 'lead'),
            provenance: provenance,
          ),
          throwsCoreError(CoreErrorKind.invalidRequest),
        );
      }

      expect(await t.count('annotation_documents'), 0);
      expect(await t.count('annotations'), 0);
    });

    test('values at their limits round trip', () async {
      final bookId = await book('epub');
      final body = '😀' * maxAnnotationBodyScalars;
      final path = 'p' * maxEpubResourcePathBytes;

      final created = await annotations.create(
        bookId,
        _select(_text, 'lead', path: path),
        body: body,
        provenance: AnnotationProvenance(
          's' * maxProvenanceSystemBytes,
          'i' * maxProvenanceIdBytes,
        ),
      );

      final [listed] = await annotations.list(
        bookId,
        _epubText(_text, path: path),
      );
      expect(listed, created);
      expect(listed.annotation.body, body);
    });

    test('a document holds at most 1024 live annotations', () async {
      final bookId = await book('epub');
      final first = await annotations.create(bookId, _select(_text, 'lead'));
      await t.executeMany(
        '''INSERT INTO annotations (id, version_id, format, kind,
             anchor_version, original_quote, normalization_profile,
             normalized_exact, normalized_prefix, normalized_suffix, color,
             epub_spine_index, epub_resource_path, epub_scalar_start,
             epub_scalar_end)
           SELECT ?, version_id, format, kind, anchor_version, original_quote,
             normalization_profile, normalized_exact, normalized_prefix,
             normalized_suffix, color, epub_spine_index, epub_resource_path,
             epub_scalar_start, epub_scalar_end
           FROM annotations WHERE id = ?''',
        [
          for (var index = 1; index < maxAnnotationsPerDocument; index++)
            [
              '00000000-0000-4000-8000-${index.toString().padLeft(12, '0')}',
              first.id,
            ],
        ],
      );

      await expectLater(
        annotations.create(bookId, _select(_text, 'tail')),
        throwsCoreError(CoreErrorKind.limitExceeded),
      );
      expect(await t.count('annotations'), maxAnnotationsPerDocument);
      expect(
        await annotations.list(bookId, _epubText(_text)),
        hasLength(maxAnnotationsPerDocument),
      );

      // A tombstone frees its place.
      await annotations.delete(bookId, first.id);
      await annotations.create(bookId, _select(_text, 'tail'));
    });

    test('the snapshot size limit applies to create and update', () async {
      final bookId = await book('epub');
      final body = 'x' * maxAnnotationBodyScalars;
      var created = 0;
      ResolvedAnnotation? last;
      try {
        while (created < 200) {
          last = await annotations.create(
            bookId,
            _select(_text, 'lead'),
            body: body,
          );
          created++;
        }
      } on CoreException catch (error) {
        expect(error.kind, CoreErrorKind.limitExceeded);
      }
      final perAnnotation = maxAnnotationDocumentBytes ~/ created;
      expect(perAnnotation, greaterThan(body.length));
      expect(await t.count('annotations'), created);

      await annotations.delete(bookId, last!.id);
      final small = await annotations.create(bookId, _select(_text, 'tail'));
      // As many scalars, four times the bytes.
      await expectLater(
        annotations.update(
          bookId,
          small.id,
          color: HighlightColor.yellow,
          body: '😀' * maxAnnotationBodyScalars,
        ),
        throwsCoreError(CoreErrorKind.limitExceeded),
      );
      final listed = await annotations.list(bookId, _epubText(_text));
      expect(listed.last.annotation.body, isNull);
    });

    test('the schema rejects records the API cannot produce', () async {
      final bookId = await book('epub');
      final created = await annotations.create(bookId, _select(_text, 'lead'));
      final pdfBook = await book('pdf');
      final pdfCreated = await annotations.create(
        pdfBook,
        const PdfSelection(page: 0, rectangles: _rectangles),
      );
      final [epubVersion] = await t.select(
        'SELECT version_id FROM annotations WHERE id = ?',
        [created.id],
      );
      final [pdfVersion] = await t.select(
        'SELECT version_id FROM annotations WHERE id = ?',
        [pdfCreated.id],
      );
      final kept = [created.id, pdfCreated.id];
      const deleteOthers = 'DELETE FROM annotations WHERE id NOT IN (?, ?)';
      const insert = '''INSERT INTO annotations (id, version_id, format,
          kind, anchor_version, original_quote, normalization_profile,
          normalized_exact, normalized_prefix, normalized_suffix, color, body,
          epub_spine_index, epub_resource_path, epub_scalar_start,
          epub_scalar_end, pdf_page, pdf_rectangles)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''';
      List<Object?> row({
        String format = 'epub',
        String kind = 'highlight',
        int anchor = 1,
        String? profile = 'shosai-quote-v1',
        String? exact = 'lead',
        String? prefix = '',
        String? color = 'yellow',
        String? body,
        int? spineIndex = 0,
        String? path = _chapter,
        int? start = 0,
        int? end = 4,
        int? page,
        int? rectangles,
        String? versionFormat,
      }) => [
        '11111111-1111-4111-8111-111111111111',
        ((versionFormat ?? format) == 'epub'
            ? epubVersion
            : pdfVersion)['version_id'],
        format,
        kind,
        anchor,
        null,
        profile,
        exact,
        prefix,
        prefix,
        color,
        body,
        format == 'epub' ? spineIndex : null,
        format == 'epub' ? path : null,
        start,
        end,
        page,
        rectangles == null ? null : Uint8List(rectangles),
      ];

      /// A note row: [kind] `page` or `book`, in [format].
      List<Object?> noteRow({
        String format = 'epub',
        String kind = 'page',
        String? color,
        String? body = 'A note',
        String? exact,
        int? spineIndex = 0,
        String? path = _chapter,
        int? start = 3,
        int? end,
        int? page,
        int? rectangles,
      }) => row(
        format: format,
        kind: kind,
        profile: exact == null ? null : 'shosai-quote-v1',
        exact: exact,
        prefix: exact == null ? null : '',
        color: color,
        body: body,
        spineIndex: spineIndex,
        path: path,
        start: start,
        end: end,
        page: page,
        rectangles: rectangles,
      );

      List<Object?> pdfRow({String? versionFormat}) => row(
        format: 'pdf',
        exact: null,
        profile: null,
        prefix: null,
        start: null,
        end: null,
        page: 0,
        rectangles: 16,
        versionFormat: versionFormat,
      );

      List<Object?> bookNote({String format = 'epub', int? page}) => noteRow(
        format: format,
        kind: 'book',
        spineIndex: null,
        path: null,
        start: null,
        page: page,
      );

      for (final valid in [
        row(),
        pdfRow(),
        noteRow(),
        // A page note made from a bookmark never recorded its chapter path.
        noteRow(path: null),
        noteRow(format: 'pdf', start: null, page: 2),
        bookNote(),
        bookNote(format: 'pdf'),
      ]) {
        await t.execute(insert, valid);
        await t.execute(deleteOthers, kept);
      }
      for (final invalid in [
        row(kind: 'bookmark'),
        row(color: null),
        // Notes have a note, no color, no quote and no range.
        noteRow(body: null),
        noteRow(body: ''),
        noteRow(color: 'yellow'),
        noteRow(exact: 'lead'),
        noteRow(end: 4),
        noteRow(start: null),
        noteRow(spineIndex: null),
        noteRow(page: 0),
        noteRow(format: 'pdf', start: null, page: null),
        noteRow(format: 'pdf', start: null, page: 0, rectangles: 16),
        bookNote(page: 0),
        noteRow(kind: 'book'),
        // An annotation has its version's format.
        row(versionFormat: 'pdf'),
        pdfRow(versionFormat: 'epub'),
        row(anchor: 2),
        row(color: 'red'),
        row(end: 0),
        row(end: null),
        row(exact: ''),
        row(exact: null, profile: null, prefix: null),
        row(prefix: null),
        row(prefix: 'p' * 33),
        row(page: 0),
        row(format: 'pdf', exact: null, profile: null, prefix: null, page: 0),
        row(
          format: 'pdf',
          exact: null,
          profile: null,
          prefix: null,
          start: null,
          end: null,
          page: 0,
          rectangles: 20,
        ),
        row(format: 'pdf', start: null, end: null, page: 0, rectangles: 16),
      ]) {
        await expectLater(
          t.execute(insert, invalid),
          throwsCoreError(CoreErrorKind.storage),
          reason: '$invalid',
        );
      }
      await t.execute(deleteOthers, kept);
      expect(await t.count('annotations'), 2);
    });
  });
}

Future<String> _hashOf(TempLibrary t, int bookId) async {
  final [row] = await t.select('SELECT content_hash FROM books WHERE id = ?', [
    bookId,
  ]);
  return row['content_hash']! as String;
}

const _unknownVersion = '22222222-2222-4222-8222-222222222222';
