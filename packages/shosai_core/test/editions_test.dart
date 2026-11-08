import 'package:shosai_core/shosai_core.dart';
import 'package:test/test.dart';

import 'support/library_fixtures.dart';

void main() {
  late TempLibrary t;
  late LibraryEditions shelf;
  var sequence = 0;
  setUp(() async {
    t = await TempLibrary.create();
    shelf = LibraryEditions(t.store);
  });

  Future<Book> book({
    String title = 'Agent workflows',
    String author = 'Ada Lee',
    String format = 'epub',
    String? edition = '2',
    String? language = 'en',
    String? volume,
    List<String> identifiers = const [],
    bool embedded = true,
    String? name,
    String? folder,
  }) async {
    final hash = (++sequence).toRadixString(16).padLeft(64, '0');
    final path = '/books/$hash.$format';
    final id = await t.execute(
      '''INSERT INTO books(title, author, format, file_path,
      storage_kind, original_path, content_hash, file_size, publication_metadata,
      display_name, source_folder)
      VALUES (?, ?, ?, ?, 'referenced', ?, ?, 20, ?, ?, ?)''',
      [
        title,
        author,
        format,
        path,
        path,
        hash,
        PublicationMetadata(
          title: embedded ? title : null,
          contributors: embedded ? [author] : [],
          identifiers: identifiers,
          edition: edition,
          language: language,
          volume: volume,
        ).encode(),
        name,
        folder,
      ],
    );
    return (await t.library.get(id))!;
  }

  test(
    'groups all files before pagination, search, filters and counts',
    () async {
      final epub = await book();
      final pdf = await book(format: 'pdf');
      final other = await book(title: 'Zoology');
      final first = await shelf.page(
        sources: [],
        sort: LibrarySort.title,
        limit: 1,
      );
      expect(first.bookCount, 2);
      expect(first.hasMore, isTrue);
      expect(first.editions.single.files.map((f) => f.book!.id), [
        epub.id,
        pdf.id,
      ]);
      final second = await shelf.page(
        sources: [],
        sort: LibrarySort.title,
        limit: 1,
        offset: 1,
      );
      expect(second.editions.single.files.single.book!.id, other.id);
      expect(second.hasMore, isFalse);
      final filtered = await shelf.page(
        sources: [],
        format: BookFormat.pdf,
        query: 'Ada',
      );
      expect(filtered.editions.single.files.length, 2);
      await shelf.prefer(
        first.editions.single.id,
        contentEditionKey(pdf.contentHash),
      );
      expect(
        (await shelf.page(
          sources: [],
          query: 'Agent',
        )).editions.single.preferred!.book!.id,
        pdf.id,
      );
      await t.library.updateProgress(epub.id, .23);
      await t.library.updateProgress(pdf.id, .71);
      expect((await t.library.get(epub.id))!.progress, .23);
      expect((await t.library.get(pdf.id))!.progress, .71);
    },
  );

  test(
    'unknown edition, authors, languages, volumes and named editions do not bridge',
    () async {
      await book();
      await book(format: 'pdf', edition: null);
      await book(format: 'pdf', edition: '1');
      await book(format: 'pdf', author: 'Other Author');
      await book(format: 'pdf', language: 'ja');
      await book(format: 'pdf', volume: '2');
      await book(
        format: 'pdf',
        title: 'Agent workflows Second Edition',
        edition: null,
      );
      final result = await shelf.page(sources: []);
      expect(result.bookCount, 6);
      final second = result.editions.firstWhere(
        (e) => e.files.any((f) => f.publication.edition == '2'),
      );
      final first = result.editions.singleWhere(
        (e) => e.files.any((f) => f.publication.edition == '1'),
      );
      final unspecified = result.editions.singleWhere(
        (e) => e.files.any(
          (f) => f.publication.edition == null && f.title == 'Agent workflows',
        ),
      );
      expect(unspecified.possibleMatches, contains(second.id));
      expect(unspecified.canGroupWith(second), isTrue);
      expect(second.canGroupWith(first), isFalse);
      await expectLater(
        shelf.group(second.id, first.id, sources: []),
        throwsA(isA<CoreException>()),
      );
      expect((await shelf.page(sources: [])).bookCount, 6);
    },
  );

  test(
    'publisher exports auto-group without ISBN, edition or language',
    () async {
      final epub = await book(
        title: 'AI Agents and Applications',
        author: 'Roberto Infante',
        edition: null,
        language: null,
        name: 'AI_Agents_and_Applications.epub',
      );
      final pdf = await book(
        title: 'AI Agents and Applications',
        author: 'Infante, Roberto',
        format: 'pdf',
        edition: null,
        language: null,
        name: 'AI_Agents_and_Applications (1) [from Manning Books].pdf',
      );
      await book(
        title: 'AI Agents and Applications',
        author: 'Roberto Infante',
        format: 'pdf',
        edition: null,
        language: null,
        name: 'AI Agents and Applications - Roberto Infante.pdf',
      );
      final grouped = (await shelf.page(sources: [])).editions.single;
      expect(grouped.files.length, 3);
      expect(grouped.possibleMatches, isEmpty);
      await shelf.prefer(grouped.id, contentEditionKey(pdf.contentHash));
      await shelf.separate(grouped.id, contentEditionKey(epub.contentHash));
      final reopened = await Store.open(t.store.path);
      addTearDown(reopened.close);
      final separated = (await LibraryEditions(
        reopened,
      ).page(sources: [])).editions;
      expect(separated.length, 2);
      expect(separated.every((e) => e.possibleMatches.isEmpty), isTrue);
      expect(
        separated.singleWhere((e) => e.files.length == 2).preferred!.book!.id,
        pdf.id,
      );
    },
  );

  test('coauthor punctuation does not split publisher exports', () async {
    final epub = await book(
      title: 'Amazon Web Services in Action',
      author: 'Michael Wittig Andreas Wittig',
      edition: null,
      language: 'en',
      name: 'Amazon_Web_Services_in_Action.epub',
    );
    final pdf = await book(
      title: 'Amazon Web Services in Action',
      author: 'Michael Wittig, Andreas Wittig',
      edition: null,
      language: null,
      format: 'pdf',
      name: 'Amazon_Web_Services_in_Action [from Manning Books].pdf',
    );
    final grouped = (await shelf.page(sources: [])).editions.single;
    expect(grouped.files.map((f) => f.book!.id), [epub.id, pdf.id]);
    expect(grouped.possibleMatches, isEmpty);
    expect(grouped.files.map((f) => f.author), [
      'Michael Wittig Andreas Wittig',
      'Michael Wittig, Andreas Wittig',
    ]);
  });

  test(
    'folder corroborates publication facts but does not replace them',
    () async {
      await book(
        edition: null,
        language: null,
        name: 'publisher.epub',
        folder: 'Agent workflows',
      );
      await book(
        edition: null,
        language: null,
        format: 'pdf',
        name: 'print.pdf',
        folder: 'Agent workflows',
      );
      await book(
        edition: null,
        language: null,
        author: 'Other Author',
        name: 'alternate.epub',
        folder: 'Agent workflows',
      );
      await book(
        edition: null,
        language: null,
        title: 'Another book',
        name: 'another.epub',
        folder: 'Agent workflows',
      );
      final entries = (await shelf.page(sources: [])).editions;
      expect(entries.length, 3);
      final automatic = entries.singleWhere((e) => e.files.length == 2);
      expect(automatic.possibleMatches.length, 1);
      expect(
        automatic.possibleMatches.values.single,
        contains(EditionMatchEvidence.metadataConflict),
      );
    },
  );

  test(
    'bad metadata suggests matching filenames without sharing identity',
    () async {
      await book(
        title: 'Elixir in Action',
        author: 'Saša Jurić',
        edition: null,
        name: 'Elixir_in_Action.epub',
      );
      await book(
        title: 'Elixir.book',
        author: 'Dottie',
        edition: null,
        format: 'pdf',
        name: 'Elixir_in_Action.pdf',
      );
      final entries = (await shelf.page(sources: [])).editions;
      expect(entries.length, 2);
      expect(entries.first.possibleMatches.keys, [entries.last.id]);
      expect(
        entries.first.possibleMatches.values.single,
        containsAll([
          EditionMatchEvidence.filename,
          EditionMatchEvidence.metadataConflict,
        ]),
      );
      await shelf.group(entries.first.id, entries.last.id, sources: []);
      final grouped = (await shelf.page(sources: [])).editions.single;
      expect(grouped.files.length, 2);
      expect(grouped.displayFile.title, 'Elixir in Action');
    },
  );

  test(
    'title and author alone with missing edition remain a suggestion',
    () async {
      await book(edition: null, language: null, name: 'publisher.epub');
      await book(
        edition: null,
        language: null,
        format: 'pdf',
        name: 'different.pdf',
      );
      await book(edition: null, language: null, name: 'book.epub');
      await book(
        edition: null,
        language: null,
        format: 'pdf',
        name: 'book.pdf',
      );
      final entries = (await shelf.page(sources: [])).editions;
      expect(entries.length, 4);
      final publisher = entries.singleWhere(
        (e) => e.files.single.name == 'publisher.epub',
      );
      expect(
        publisher.possibleMatches.values.every(
          (reasons) =>
              reasons.length == 1 &&
              reasons.contains(EditionMatchEvidence.title),
        ),
        isTrue,
      );
    },
  );

  test(
    'edition aliases agree while folder qualifiers and version numbers stay separate',
    () async {
      await book(
        edition: null,
        name: 'Agent_workflows_Second_Ed.epub',
        language: null,
      );
      await book(
        edition: null,
        name: 'Agent_workflows_2nd_Edition.pdf',
        format: 'pdf',
        language: null,
      );
      await book(
        edition: null,
        name: 'Agent_workflows.pdf',
        folder: 'Agent workflows, First Edition',
        format: 'pdf',
      );
      await book(
        edition: null,
        name: 'Agent_workflows_v1.epub',
        folder: 'Agent workflows',
      );
      await book(
        edition: null,
        name: 'Agent_workflows_v2.pdf',
        format: 'pdf',
        folder: 'Agent workflows',
      );
      final entries = (await shelf.page(sources: [])).editions;
      expect(entries.length, 4);
      final first = entries.singleWhere(
        (e) => e.displayFile.folderName?.contains('First Edition') ?? false,
      );
      expect(
        entries.singleWhere((e) => e.files.length == 2).possibleMatches,
        isNot(contains(first.id)),
      );
      final versions = entries
          .where((e) => e.displayFile.name.contains('_v'))
          .toList();
      expect(versions[0].canGroupWith(versions[1]), isFalse);
      expect(versions[0].possibleMatches, isNot(contains(versions[1].id)));
    },
  );

  test(
    'validated ISBN equivalents group but invalid IDs and UUIDs do not',
    () async {
      final a = await book(
        edition: null,
        language: null,
        identifiers: ['0-306-40615-2'],
      );
      final b = await book(
        format: 'pdf',
        edition: null,
        language: null,
        identifiers: ['urn:isbn:9780306406157'],
      );
      await book(
        edition: null,
        language: null,
        title: 'Contradictory title',
        identifiers: ['9780306406157'],
      );
      await book(
        edition: null,
        language: null,
        author: 'Another author',
        identifiers: ['9780306406157'],
      );
      await book(edition: null, identifiers: ['9780306406158']);
      await book(edition: null, identifiers: ['urn:uuid:9780306406157']);
      final result = await shelf.page(sources: []);
      expect(result.bookCount, 5);
      expect(
        result.editions
            .singleWhere((e) => e.files.length == 2)
            .files
            .map((f) => f.book!.id),
        [a.id, b.id],
      );
    },
  );

  test(
    'existing book metadata and meaningful title tokens are preserved',
    () async {
      final a = await book(edition: null, name: 'Agent_workflows.epub');
      final b = await book(
        edition: null,
        name: 'Agent_workflows.pdf',
        format: 'pdf',
      );
      await t.execute(
        'UPDATE books SET publication_metadata = NULL WHERE id IN (?, ?)',
        [a.id, b.id],
      );
      for (final title in [
        'Programming Elixir 1.6',
        'Programming Elixir 16',
        'C in Action',
        'C++ in Action',
      ]) {
        await book(title: title, edition: null, name: '$title.epub');
      }
      await book(
        title: 'Shared book',
        author: 'Ann Lee, Bo Tan',
        edition: null,
        name: 'Shared_book.epub',
      );
      await book(
        title: 'Shared book',
        author: 'Ann Tan, Bo Lee',
        edition: null,
        format: 'pdf',
        name: 'Shared_book.pdf',
      );
      final entries = (await shelf.page(sources: [])).editions;
      expect(entries.length, 7);
      expect(
        entries
            .singleWhere((e) => e.files.length == 2)
            .files
            .map((f) => f.book!.id),
        [a.id, b.id],
      );
    },
  );

  test(
    'folder evidence persists through catalog, admission and reopening',
    () async {
      final locations = LibraryLocations(t.store);
      final generation = await locations.connect('dropbox', 'Dropbox');
      const entries = [
        LocationEntry(
          key: 'epub',
          name: 'publisher.epub',
          isDirectory: false,
          size: 20,
          folderName: 'Agent workflows',
        ),
        LocationEntry(
          key: 'pdf',
          name: 'print.pdf',
          isDirectory: false,
          size: 20,
          folderName: 'Agent workflows',
        ),
      ];
      await locations.scan('dropbox', generation, entries);
      for (final entry in entries) {
        await locations.savePreview(
          'dropbox',
          generation,
          entry,
          const BookMetadata(
            title: 'Agent workflows',
            author: 'Ada Lee',
            publication: PublicationMetadata(
              title: 'Agent workflows',
              contributors: ['Ada Lee'],
            ),
          ),
        );
      }
      final sources = [
        for (final entry in entries) (locationId: 'dropbox', key: entry.key),
      ];
      expect(
        (await shelf.page(sources: sources)).editions.single.files.length,
        2,
      );
      final admitted = await book(edition: null, language: null);
      await locations.admit(
        'dropbox',
        generation,
        entries.first,
        admitted.contentHash,
      );
      final reopened = await Store.open(t.store.path);
      addTearDown(reopened.close);
      expect(
        (await LibraryLocations(reopened).catalog()).single.entry.folderName,
        'Agent workflows',
      );
      final grouped = (await LibraryEditions(
        reopened,
      ).page(sources: sources)).editions.single;
      expect(grouped.files.length, 2);
      expect(
        grouped.files.every((file) => file.folderName == 'Agent workflows'),
        isTrue,
      );
    },
  );

  test(
    'subset queries retain preferences and validate hidden members',
    () async {
      final locations = LibraryLocations(t.store);
      final generation = await locations.connect('dropbox', 'Dropbox');
      const entry = LocationEntry(
        key: 'first',
        name: 'Agent_workflows_First_Edition.epub',
        isDirectory: false,
        size: 20,
      );
      const locator = (locationId: 'dropbox', key: 'first');
      await locations.scan('dropbox', generation, [entry]);
      final unknown = await book(edition: null, embedded: false);
      final second = await book(format: 'pdf');
      final entries = (await shelf.page(sources: [locator])).editions;
      final original = entries.singleWhere(
        (e) => e.files.any((f) => f.book?.id == unknown.id),
      );
      final other = entries.singleWhere(
        (e) => e.files.any((f) => f.book?.id == second.id),
      );
      final source = entries.singleWhere((e) => e.files.single.locator != null);
      await shelf.group(source.id, original.id, sources: [locator]);
      await shelf.prefer(original.id, source.files.single.key);
      final subset = (await shelf.page(sources: [])).editions;
      expect(subset.singleWhere((e) => e.id == original.id).files.length, 1);
      expect(
        (await shelf.page(
          sources: [locator],
        )).editions.singleWhere((e) => e.id == original.id).preferred?.locator,
        locator,
      );
      for (final sources in [
        <BookLocator>[],
        [locator],
      ]) {
        await expectLater(
          shelf.group(original.id, other.id, sources: sources),
          throwsA(isA<CoreException>()),
        );
      }
      final full = (await shelf.page(sources: [locator])).editions;
      expect(full.length, 2);
      expect(full.singleWhere((e) => e.id == original.id).files.length, 2);
      expect(
        full.singleWhere((e) => e.id == other.id).files.single.book?.id,
        second.id,
      );
    },
  );

  test(
    'manual grouping, chosen file and separation survive a reopened store',
    () async {
      final a = await book(edition: null, embedded: false);
      final b = await book(format: 'pdf', edition: null);
      var entries = (await shelf.page(sources: [])).editions;
      final one = entries.singleWhere((e) => e.files.single.book!.id == a.id);
      final two = entries.singleWhere((e) => e.files.single.book!.id == b.id);
      await shelf.group(two.id, one.id, sources: []);
      await shelf.prefer(one.id, contentEditionKey(b.contentHash));
      final reopened = await Store.open(t.store.path);
      addTearDown(reopened.close);
      final persisted = LibraryEditions(reopened);
      final grouped = (await persisted.page(sources: [])).editions.single;
      expect(grouped.preferred!.book!.id, b.id);
      await persisted.separate(grouped.id, contentEditionKey(b.contentHash));
      entries = (await shelf.page(sources: [])).editions;
      expect(entries.length, 2);
      expect((await persisted.page(sources: [])).bookCount, 2);
    },
  );

  test(
    'unopened source membership survives verified admission but not changed bytes',
    () async {
      final locations = LibraryLocations(t.store);
      final generation = await locations.connect('dropbox', 'Dropbox');
      const entry = LocationEntry(
        key: 'id:one',
        name: 'Agent_workflows.epub',
        isDirectory: false,
        size: 20,
        revision: 'r1',
      );
      await locations.scan('dropbox', generation, [entry]);
      const locator = (locationId: 'dropbox', key: 'id:one');
      final pdf = await book(format: 'pdf', edition: null);
      final before = await shelf.page(sources: [locator]);
      final source = before.editions.singleWhere(
        (e) => e.files.single.locator != null,
      );
      final target = before.editions.singleWhere(
        (e) => e.files.single.book != null,
      );
      expect(source.displayFile.title, 'Agent workflows');
      await shelf.group(source.id, target.id, sources: [locator]);
      await shelf.prefer(target.id, source.files.single.key);
      final admitted = await book(edition: null, embedded: false);
      await locations.admit('dropbox', generation, entry, admitted.contentHash);
      final after = (await shelf.page(sources: [])).editions.single;
      expect(after.id, target.id);
      expect(after.preferred!.book!.id, admitted.id);
      expect(after.preferred!.name, 'Agent_workflows.epub');
      expect(after.files.map((f) => f.book!.id), contains(pdf.id));
      const changed = LocationEntry(
        key: 'id:one',
        name: 'Agent_workflows.epub',
        isDirectory: false,
        size: 21,
        revision: 'r2',
      );
      await locations.scan('dropbox', generation, [changed]);
      expect((await shelf.page(sources: [locator])).bookCount, 2);
    },
  );

  test('verified publication facts override a provisional group', () async {
    final locations = LibraryLocations(t.store);
    final generation = await locations.connect('dropbox', 'Dropbox');
    const entry = LocationEntry(
      key: 'id:unknown',
      name: 'Agent_workflows.pdf',
      isDirectory: false,
      size: 20,
      revision: 'r1',
    );
    const locator = (locationId: 'dropbox', key: 'id:unknown');
    await locations.scan('dropbox', generation, [entry]);
    await locations.savePreview(
      'dropbox',
      generation,
      entry,
      const BookMetadata(),
    );
    final first = await book(edition: '1');
    final before = (await shelf.page(sources: [locator])).editions;
    final original = before.singleWhere((e) => e.files.single.book != null);
    final preview = before.singleWhere((e) => e.files.single.locator != null);
    await shelf.group(preview.id, original.id, sources: [locator]);
    await shelf.prefer(original.id, preview.files.single.key);

    final second = await book(format: 'pdf', edition: '2');
    expect(
      await locations.admit('dropbox', generation, entry, second.contentHash),
      isFalse,
    );
    expect(await locations.catalog(), isEmpty);
    final reopened = await Store.open(t.store.path);
    addTearDown(reopened.close);
    final groups = (await LibraryEditions(reopened).page(sources: [])).editions;
    expect(groups.length, 2);
    expect(
      groups.singleWhere((e) => e.id == original.id).files.single.book?.id,
      first.id,
    );
    expect(groups.singleWhere((e) => e.id == original.id).preferred, isNull);
    final verified = groups.singleWhere((e) => e.id != original.id);
    expect(verified.files.single.book?.id, second.id);
    expect(
      verified.canGroupWith(groups.firstWhere((e) => e.id == original.id)),
      isFalse,
    );
  });

  test('an unverifiable revision cannot transfer a preview decision', () async {
    final locations = LibraryLocations(t.store);
    final generation = await locations.connect('dropbox', 'Dropbox');
    const entry = LocationEntry(
      key: 'id:unknown',
      name: 'Agent_workflows.epub',
      isDirectory: false,
      size: 20,
    );
    const locator = (locationId: 'dropbox', key: 'id:unknown');
    await locations.scan('dropbox', generation, [entry]);
    await book(edition: null, embedded: false);
    final before = (await shelf.page(sources: [locator])).editions;
    final original = before.singleWhere((e) => e.files.single.book != null);
    final preview = before.singleWhere((e) => e.files.single.locator != null);
    await shelf.group(preview.id, original.id, sources: [locator]);
    final verified = await book(edition: null, embedded: false);
    expect(
      await locations.admit(
        'dropbox',
        generation,
        entry,
        verified.contentHash,
        inheritPreview: false,
      ),
      isFalse,
    );
    expect((await shelf.page(sources: [])).bookCount, 2);
  });

  test('verified copies cannot bridge two confirmed groups', () async {
    final locations = LibraryLocations(t.store);
    final generation = await locations.connect('dropbox', 'Dropbox');
    const entry = LocationEntry(
      key: 'id:copy',
      name: 'Agent_workflows.epub',
      isDirectory: false,
      size: 20,
      revision: 'r1',
    );
    const locator = (locationId: 'dropbox', key: 'id:copy');
    await locations.scan('dropbox', generation, [entry]);
    final original = await book(edition: null, embedded: false);
    final companion = await book(format: 'pdf', edition: null, embedded: false);
    final other = await book(format: 'pdf', edition: null, embedded: false);
    final all = (await shelf.page(sources: [locator])).editions;
    String containing(Book book) => all
        .singleWhere(
          (edition) => edition.files.any((file) => file.book?.id == book.id),
        )
        .id;
    final preview = all.singleWhere((e) => e.files.single.locator != null);
    await shelf.group(
      containing(companion),
      containing(original),
      sources: [locator],
    );
    await shelf.group(preview.id, containing(other), sources: [locator]);
    await expectLater(
      locations.admit('dropbox', generation, entry, original.contentHash),
      throwsA(isA<CoreException>()),
    );
    final groups = (await shelf.page(sources: [locator])).editions;
    expect(groups.length, 2);
    expect(
      groups
          .singleWhere((e) => e.id == containing(original))
          .files
          .map((f) => f.book?.id),
      [original.id, companion.id],
    );
    expect(
      groups
          .singleWhere((e) => e.id == containing(other))
          .files
          .any((f) => f.locator == locator),
      isTrue,
    );
  });
}
