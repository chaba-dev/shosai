import 'dart:async';
import 'dart:typed_data';

import 'package:shosai_core/shosai_core.dart';
import 'package:test/test.dart';

import 'support/library_fixtures.dart';

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
        '''INSERT INTO annotations (id, version_id, format, anchor_version,
             original_quote, normalization_profile, normalized_exact,
             normalized_prefix, normalized_suffix, color,
             epub_spine_index, epub_resource_path, epub_scalar_start,
             epub_scalar_end)
           SELECT ?, version_id, format, anchor_version, original_quote,
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
        '''INSERT INTO annotations (id, version_id, format, anchor_version,
             original_quote, normalization_profile, normalized_exact,
             normalized_prefix, normalized_suffix, color,
             epub_spine_index, epub_resource_path, epub_scalar_start,
             epub_scalar_end)
           SELECT ?, version_id, format, anchor_version, original_quote,
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
          anchor_version, original_quote, normalization_profile,
          normalized_exact, normalized_prefix, normalized_suffix, color,
          epub_spine_index, epub_resource_path, epub_scalar_start,
          epub_scalar_end, pdf_page, pdf_rectangles)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''';
      List<Object?> row({
        String format = 'epub',
        int anchor = 1,
        String? profile = 'shosai-quote-v1',
        String? exact = 'lead',
        String? prefix = '',
        String color = 'yellow',
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
        anchor,
        null,
        profile,
        exact,
        prefix,
        prefix,
        color,
        format == 'epub' ? 0 : null,
        format == 'epub' ? _chapter : null,
        start,
        end,
        page,
        rectangles == null ? null : Uint8List(rectangles),
      ];

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

      await t.execute(insert, row());
      await t.execute(deleteOthers, kept);
      await t.execute(insert, pdfRow());
      await t.execute(deleteOthers, kept);
      for (final invalid in [
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
