import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:xml/xml.dart';

const _source = 'standardebooks';
const _organization = 'standardebooks';
const _ebooks = 'https://standardebooks.org/ebooks/';
const _userAgent =
    'Shosai-catalog-refresh (+https://github.com/chaba-dev/shosai)';

/// Thumbnail size for catalog covers: the largest Browse cover is 136×204
/// points, 408 pixels on a 3× display.
const thumbnailWidth = 300;
const thumbnailHeight = 450;

/// Standard Ebooks genres that match an existing Browse category. Broad
/// genres such as Fiction and Nonfiction are not categories and are dropped.
const _genreCategories = {
  'Adventure': 'Adventure',
  'Autobiography': 'Biographies',
  'Biography': 'Biographies',
  'Children’s': 'Children & Young Adult Reading',
  'Comedy': 'Humour',
  'Drama': 'Plays/Films/Dramas',
  'Fantasy': 'Science-Fiction & Fantasy',
  'Memoir': 'Biographies',
  'Mystery': 'Crime, Thrillers and Mystery',
  'Philosophy': 'Philosophy & Ethics',
  'Poetry': 'Poetry',
  'Satire': 'Humour',
  'Science Fiction': 'Science-Fiction & Fantasy',
  'Shorts': 'Short Stories',
  'Spirituality': 'Religion/Spirituality',
  'Travel': 'Travel Writing',
};

Future<void> main(List<String> args) async {
  final token = Platform.environment['GITHUB_TOKEN'] ?? '';
  if ((args.length != 2 && !(args.length == 4 && args[2] == '--previous')) ||
      token.isEmpty) {
    stderr.writeln(
      'Usage: GITHUB_TOKEN=... dart run tool/import_standard_ebooks.dart '
      '<catalog.sqlite> <new-work-directory> [--previous <snapshot-directory>]',
    );
    stderr.writeln(
      'Adds Standard Ebooks to a catalog database made by import_gutenberg.dart '
      'and writes cover thumbnails to <new-work-directory>/thumbnails, reusing '
      'thumbnails already published in the previous snapshot.',
    );
    exitCode = 64;
    return;
  }
  final client = HttpClient()
    ..userAgent = _userAgent
    ..connectionTimeout = const Duration(seconds: 30)
    ..idleTimeout = const Duration(seconds: 30);
  try {
    final work = Directory(args[1]);
    if (work.existsSync()) {
      throw FileSystemException('Output already exists', work.path);
    }
    final thumbnails = Directory(p.join(work.path, 'thumbnails'))
      ..createSync(recursive: true);
    final repositories = await listRepositories(client, token);
    stdout.writeln('Found ${repositories.length} Standard Ebooks books.');
    final books = await _fetchBooks(
      client,
      repositories,
      thumbnails.path,
      args.length == 4 ? p.join(args[3], 'thumbnails') : null,
    );
    final db = sqlite3.open(args[0]);
    try {
      final result = importStandardEbooks(db, books);
      stdout.writeln(
        'Imported ${result.editions} Standard Ebooks editions; '
        '${result.joined} joined Project Gutenberg works.',
      );
    } finally {
      db.close();
    }
  } on Exception catch (error) {
    stderr.writeln('Standard Ebooks import failed: $error');
    exitCode = 1;
  } finally {
    client.close(force: true);
  }
}

/// One book repository at the commit its files are read from. Covers are
/// named by their Git blob ID, so an unchanged cover keeps its thumbnail.
typedef StandardEbooksRepository = ({
  String name,
  String commit,
  String opf,
  String? cover,
});

typedef StandardEbook = ({String repository, String opf, String? cover});

/// Lists the organization's repositories that contain a book's OPF. Tooling
/// repositories such as `tools` and `web` have none and are skipped.
Future<List<StandardEbooksRepository>> listRepositories(
  HttpClient client,
  String token,
) async {
  const query = r'''
query($cursor: String) {
  organization(login: "standardebooks") {
    repositories(first: 25, after: $cursor, orderBy: {field: NAME, direction: ASC}) {
      pageInfo { hasNextPage endCursor }
      nodes {
        name isArchived
        defaultBranchRef { target { oid } }
        opf: object(expression: "HEAD:src/epub/content.opf") { ... on Blob { oid } }
        cover: object(expression: "HEAD:images/cover.jpg") { ... on Blob { oid } }
      }
    }
  }
}''';
  final repositories = <StandardEbooksRepository>[];
  String? cursor;
  do {
    // A failed page is retried whole, so no cursor advances past an error.
    final page = await _retry(() async {
      final body = await _request(
        client,
        'POST',
        Uri.https('api.github.com', '/graphql'),
        16 * 1024 * 1024,
        prepare: (request) {
          request.headers
            ..set(HttpHeaders.authorizationHeader, 'bearer $token')
            ..contentType = ContentType.json;
          request.write(
            jsonEncode({
              'query': query,
              'variables': {'cursor': cursor},
            }),
          );
        },
      );
      return parseRepositoryPage(jsonDecode(utf8.decode(body)));
    });
    repositories.addAll(page.repositories);
    cursor = page.next;
  } while (cursor != null);
  return repositories;
}

/// One page of the repository listing. GitHub reports a failed field, such
/// as an OPF lookup, as null data plus an error; reading on would silently
/// drop that book or its cover, so any error fails the page.
({List<StandardEbooksRepository> repositories, String? next})
parseRepositoryPage(Object? json) {
  if (json case {'errors': List<dynamic> errors} when errors.isNotEmpty) {
    throw _GitHubError('GitHub GraphQL errors: ${jsonEncode(errors)}');
  }
  if (json case {
    'data': {
      'organization': {
        'repositories': {
          'pageInfo': {'hasNextPage': bool more, 'endCursor': final end},
          'nodes': List<dynamic> nodes,
        },
      },
    },
  } when !more || end is String) {
    return (
      repositories: [
        for (final node in nodes)
          if (node case {
            'name': String name,
            'isArchived': false,
            'defaultBranchRef': {'target': {'oid': String commit}},
            'opf': {'oid': String opf},
          })
            (
              name: name,
              commit: commit,
              opf: opf,
              cover: switch (node['cover']) {
                {'oid': String oid} => oid,
                _ => null,
              },
            ),
      ],
      next: more ? end as String : null,
    );
  }
  throw const FormatException('Unexpected GitHub response');
}

/// Retried like a network failure: GraphQL errors are often transient.
final class _GitHubError extends HttpException {
  _GitHubError(super.message);
}

Future<List<StandardEbook>> _fetchBooks(
  HttpClient client,
  List<StandardEbooksRepository> repositories,
  String thumbnails,
  String? previous,
) async {
  Uri raw(StandardEbooksRepository repo, String path) => Uri.https(
    'raw.githubusercontent.com',
    '/$_organization/${repo.name}/${repo.commit}/$path',
  );
  final opfs = <String, String>{};
  // Downloaded covers wait on disk, not in memory, until they are resized.
  final covers = <String, String>{};
  final downloads = Directory(p.join(p.dirname(thumbnails), 'covers'))
    ..createSync();
  final queue = [...repositories];
  var failed = false;
  Future<void> fetch(StandardEbooksRepository repo) async {
    final opf = await _retry(
      () => _request(
        client,
        'GET',
        raw(repo, 'src/epub/content.opf'),
        4 * 1024 * 1024,
      ),
    );
    _checkBlob(opf, repo.opf, repo.name);
    opfs[repo.name] = utf8.decode(opf);
    final cover = repo.cover;
    if (cover == null || covers.containsKey(cover)) return;
    final target = File(p.join(thumbnails, '$cover.jpg'));
    final published = previous == null
        ? null
        : File(p.join(previous, '$cover.jpg'));
    if (published != null && published.existsSync()) {
      published.copySync(target.path);
      return;
    }
    covers[cover] = p.join(downloads.path, '$cover.jpg');
    final bytes = await _retry(
      () => _request(
        client,
        'GET',
        raw(repo, 'images/cover.jpg'),
        32 * 1024 * 1024,
      ),
    );
    _checkBlob(bytes, cover, repo.name);
    File(covers[cover]!).writeAsBytesSync(bytes);
  }

  Future<void> worker() async {
    // After one failure the others stop taking work instead of fetching the
    // rest of the catalog before the import fails.
    while (queue.isNotEmpty && !failed) {
      final repo = queue.removeLast();
      try {
        await fetch(repo);
      } on Object {
        failed = true;
        rethrow;
      }
    }
  }

  await Future.wait(List.generate(16, (_) => worker()));
  await writeThumbnails(covers, thumbnails);
  downloads.deleteSync(recursive: true);
  return [
    for (final repo in repositories)
      (repository: repo.name, opf: opfs[repo.name]!, cover: repo.cover),
  ];
}

/// Resizes the cover files on worker isolates and writes `<blob ID>.jpg`
/// thumbnails. The encoder is deterministic, so the same cover yields the
/// same bytes.
Future<void> writeThumbnails(
  Map<String, String> covers,
  String directory,
) async {
  final entries = covers.entries.toList();
  final workers = Platform.numberOfProcessors.clamp(1, 8);
  await Future.wait([
    for (var w = 0; w < workers; w++)
      () async {
        for (var i = w; i < entries.length; i += workers) {
          final MapEntry(key: oid, value: path) = entries[i];
          final target = p.join(directory, '$oid.jpg');
          await Isolate.run(
            () => File(
              target,
            ).writeAsBytesSync(makeThumbnail(File(path).readAsBytesSync())),
          );
        }
      }(),
  ]);
}

Uint8List makeThumbnail(Uint8List cover) {
  final source = img.decodeImage(cover);
  if (source == null) throw const FormatException('Unreadable cover image');
  final thumbnail = img.copyResize(
    source,
    width: thumbnailWidth,
    height: thumbnailHeight,
    interpolation: img.Interpolation.average,
  )..exif = img.ExifData();
  return img.encodeJpg(thumbnail, quality: 80, chroma: img.JpegChroma.yuv420);
}

void _checkBlob(Uint8List bytes, String oid, String repository) {
  final digest = _DigestSink();
  sha1.startChunkedConversion(digest)
    ..add(utf8.encode('blob ${bytes.length}\u0000'))
    ..add(bytes)
    ..close();
  if (digest.value.toString() != oid) {
    throw FormatException('Changed file while reading $repository');
  }
}

final class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

const _deadline = Duration(seconds: 60);

/// Every wait has a deadline; a request that misses one is aborted.
Future<Uint8List> _request(
  HttpClient client,
  String method,
  Uri uri,
  int limit, {
  void Function(HttpClientRequest)? prepare,
}) async {
  final request = await client.openUrl(method, uri).timeout(_deadline);
  try {
    prepare?.call(request);
    final response = await request.close().timeout(_deadline);
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('HTTP ${response.statusCode} from $uri');
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(_deadline)) {
      builder.add(chunk);
      if (builder.length > limit) {
        throw FormatException('File too large: $uri');
      }
    }
    return builder.takeBytes();
  } finally {
    request.abort();
  }
}

Future<T> _retry<T>(Future<T> Function() attempt) async {
  for (var tries = 1; ; tries++) {
    try {
      return await attempt();
    } on Object catch (error) {
      if (error is! IOException && error is! TimeoutException || tries == 4) {
        rethrow;
      }
    }
    await Future<void>.delayed(Duration(seconds: 5 * tries));
  }
}

/// Adds the books to a catalog database that already holds Project
/// Gutenberg. A book whose OPF names exactly one Gutenberg ebook that the
/// catalog lists, and that no other book names, joins that work as its first
/// edition; its title and details replace Gutenberg's. Any other book is its
/// own work.
/// [books] with a cover use `thumbnails/<cover>.jpg`, which the export must
/// supply.
({int editions, int joined}) importStandardEbooks(
  Database db,
  Iterable<StandardEbook> books,
) {
  final parsed = [for (final book in books) _parse(book)];
  if (parsed.isEmpty) throw const FormatException('No Standard Ebooks books');
  parsed.sort((a, b) => a.path.compareTo(b.path));
  // A Gutenberg ebook that several books name is a collection of them, such
  // as a trilogy; each book then stays a work of its own.
  // Every book citing an ID counts, including books that cite several.
  final named = <int, int>{};
  for (final book in parsed) {
    for (final id in book.cited) {
      named[id] = (named[id] ?? 0) + 1;
    }
  }
  var joined = 0;
  final statements = <String, PreparedStatement>{};
  void write(String sql, List<Object?> values) =>
      statements.putIfAbsent(sql, () => db.prepare(sql)).execute(values);
  db.execute('BEGIN');
  try {
    write(
      'INSERT INTO sources (id, name, website, support_url) VALUES (?, ?, ?, ?)',
      [
        _source,
        'Standard Ebooks',
        'https://standardebooks.org/',
        'https://standardebooks.org/donate',
      ],
    );
    for (final book in parsed) {
      final gutenberg = book.gutenberg == null || named[book.gutenberg] != 1
          ? null
          : db.select('SELECT id FROM books WHERE id = ?', [
              'gutenberg:${book.gutenberg}',
            ]).firstOrNull?['id'];
      final work = gutenberg as String? ?? '$_source:${book.path}';
      if (gutenberg != null) {
        joined++;
        // Gutenberg titles often run on into subtitles; the first edition's
        // edited title names the work. Its author records stay Gutenberg's.
        write('UPDATE books SET title = ? WHERE id = ?', [book.title, work]);
        // Two steps keep (book_id, display_order) unique after each row.
        for (final shift in [1000001, -1000000]) {
          write(
            'UPDATE editions SET display_order = display_order + ? WHERE book_id = ?',
            [shift, work],
          );
        }
      } else {
        write('INSERT INTO books (id, title) VALUES (?, ?)', [
          work,
          book.title,
        ]);
        for (final (position, author) in book.authors.indexed) {
          final id = '$_source:${author.heading}';
          write(
            'INSERT INTO authors (id, name, sort_name) VALUES (?, ?, ?) '
            'ON CONFLICT (id) DO NOTHING',
            [id, author.heading, author.heading],
          );
          write('INSERT INTO book_authors VALUES (?, ?, ?)', [
            work,
            id,
            position,
          ]);
          write(
            'INSERT INTO author_details (author_id, display_name) VALUES (?, ?) '
            'ON CONFLICT (author_id) DO NOTHING',
            [id, author.name],
          );
        }
      }
      write(
        '''
        INSERT INTO editions (
          source_id, source_edition_id, book_id, title, variant_label,
          display_order, language, source_url, rights_line, acquisition_url,
          acquisition_format, size_bytes, cover_url
        ) VALUES (?, ?, ?, ?, ?, 0, ?, ?, ?, ?, 'epub', NULL, ?)
        ''',
        [
          _source,
          book.path,
          work,
          book.title,
          'Standard Ebooks edition',
          book.language,
          '$_ebooks${book.path}',
          'Public domain in the USA.',
          '$_ebooks${book.path}/downloads/'
              '${book.path.replaceAll('/', '_')}.epub?source=download',
          book.cover == null ? null : 'thumbnails/${book.cover}.jpg',
        ],
      );
      final described =
          book.summary != null ||
          book.readingEase != null ||
          book.description != null ||
          book.wordCount != null ||
          book.released != null;
      // A joined book's details replace Gutenberg's even when it has none.
      if (!described && gutenberg != null) {
        write('DELETE FROM book_details WHERE book_id = ?', [work]);
      }
      if (described) {
        write(
          '''
        INSERT INTO book_details (
          book_id, summary, reading_ease, description, word_count, released,
          released_by
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT (book_id) DO UPDATE SET summary = excluded.summary,
          reading_ease = excluded.reading_ease,
          description = excluded.description,
          word_count = excluded.word_count, released = excluded.released,
          released_by = excluded.released_by
        ''',
          [
            work,
            book.summary,
            book.readingEase,
            book.description,
            book.wordCount,
            book.released,
            if (book.released == null) null else _source,
          ],
        );
      }
      for (final subject in book.subjects) {
        write(
          'INSERT INTO subjects VALUES (?, ?) ON CONFLICT (id) DO NOTHING',
          ['lcsh:$subject', subject],
        );
        write(
          'INSERT INTO book_subjects VALUES (?, ?) ON CONFLICT DO NOTHING',
          [work, 'lcsh:$subject'],
        );
      }
      for (final category in book.categories) {
        write(
          'INSERT INTO categories VALUES (?, ?) ON CONFLICT (id) DO NOTHING',
          ['gutenberg:$category', category],
        );
        write(
          'INSERT INTO book_categories VALUES (?, ?) ON CONFLICT DO NOTHING',
          [work, 'gutenberg:$category'],
        );
      }
      for (final series in book.series) {
        write(
          'INSERT INTO book_series VALUES (?, ?, ?) ON CONFLICT DO NOTHING',
          [work, series.name, series.position],
        );
      }
    }
    db.execute('COMMIT');
  } on Object {
    db.execute('ROLLBACK');
    rethrow;
  } finally {
    for (final statement in statements.values) {
      statement.close();
    }
  }
  return (editions: parsed.length, joined: joined);
}

typedef _Book = ({
  String path,
  String title,
  String language,
  List<({String name, String heading})> authors,
  int? gutenberg,
  Set<int> cited,
  String? cover,
  String? summary,
  int? readingEase,
  String? description,
  int? wordCount,
  String? released,
  Set<String> subjects,
  Set<String> categories,
  List<({String name, int? position})> series,
});

const _dc = 'http://purl.org/dc/elements/1.1/';
final _path = RegExp(r'^[a-z0-9][a-z0-9_-]*(/[a-z0-9][a-z0-9_-]*)+$');
final _gutenbergSource = RegExp(
  r'^https?://(?:www\.)?gutenberg\.org/(?:ebooks|files)/([0-9]+)(?:[/.]|$)',
);
final _date = RegExp(r'^[0-9]{4}-[0-9]{2}-[0-9]{2}$');

/// The `YYYY-MM-DD` prefix of [value] when it is a real calendar date.
String? _calendarDate(String? value) {
  if (value == null || value.length < 10) return null;
  final day = value.substring(0, 10);
  final parsed = _date.hasMatch(day) ? DateTime.tryParse(day) : null;
  return parsed != null && parsed.toIso8601String().startsWith(day)
      ? day
      : null;
}

_Book _parse(StandardEbook book) {
  Never invalid(String what) =>
      throw FormatException('Invalid $what in ${book.repository}');
  final XmlElement metadata;
  try {
    metadata = XmlDocument.parse(
      book.opf,
    ).rootElement.childElements.firstWhere((e) => e.localName == 'metadata');
  } on Exception {
    invalid('OPF');
  }
  Iterable<XmlElement> dc(String name) => metadata.childElements.where(
    (e) =>
        e.name.qualified == 'dc:$name' ||
        (e.localName == name && e.namespaceUri == _dc),
  );
  Iterable<XmlElement> meta(String property, [String? id]) =>
      metadata.childElements.where(
        (e) =>
            e.localName == 'meta' &&
            e.getAttribute('property') == property &&
            (id == null || e.getAttribute('refines') == '#$id'),
      );
  String? text(Iterable<XmlElement> elements) {
    final value = elements.firstOrNull?.innerText.trim();
    return value == null || value.isEmpty ? null : value;
  }

  final identifier = text(
    dc('identifier').where((e) => e.getAttribute('id') == 'uid'),
  );
  if (identifier == null || !identifier.startsWith(_ebooks)) {
    invalid('identifier');
  }
  final path = identifier.substring(_ebooks.length);
  if (!_path.hasMatch(path)) invalid('identifier');
  final title = text(dc('title')) ?? invalid('title');
  final language =
      text(dc('language'))?.split('-').first.toLowerCase() ??
      invalid('language');
  final authors = [
    for (final creator in dc('creator'))
      if (creator.innerText.trim() case final name when name.isNotEmpty)
        (
          name: name,
          heading:
              text(meta('file-as', creator.getAttribute('id') ?? '')) ?? name,
        ),
  ];
  if (authors.isEmpty) invalid('authors');
  final gutenberg = {
    for (final source in dc('source'))
      if (_gutenbergSource.firstMatch(source.innerText.trim()) case final m?)
        int.parse(m[1]!),
  };
  final subjects = {
    for (final subject in dc('subject'))
      if (text(meta('authority', subject.getAttribute('id') ?? '')) == 'LCSH' &&
          subject.innerText.trim().isNotEmpty)
        // Standard Ebooks writes `Courtship--Fiction`; Gutenberg writes
        // `Courtship -- Fiction`. One form lets a joined book share subjects.
        // The separator is the run's last two hyphens: in `1890---Fiction`
        // the first belongs to an open-ended date.
        subject.innerText.trim().replaceAll(RegExp(r'\s*--(?!-)\s*'), ' -- '),
  };
  final released = text(dc('date'));
  final words = int.tryParse(text(meta('schema:wordCount')) ?? '');
  final ease = double.tryParse(text(meta('schema:educationalLevel')) ?? '');
  return (
    path: path,
    title: title,
    language: language,
    authors: authors,
    gutenberg: gutenberg.length == 1 ? gutenberg.single : null,
    cited: gutenberg,
    cover: book.cover,
    summary: text(meta('schema:abstract')),
    readingEase: ease?.isFinite ?? false ? ease!.round() : null,
    description: plainDescription(text(dc('description'))),
    wordCount: words != null && words > 0 ? words : null,
    released: _calendarDate(released),
    subjects: subjects,
    categories: {
      for (final genre in meta('schema:genre'))
        ?_genreCategories[genre.innerText.trim()],
    },
    series: [
      for (final collection in meta('belongs-to-collection'))
        if (collection.getAttribute('id') case final id?
            when text(meta('collection-type', id)) == 'series' &&
                collection.innerText.trim().isNotEmpty)
          (
            name: collection.innerText.trim(),
            position: switch (int.tryParse(
              text(meta('group-position', id)) ?? '',
            )) {
              final n? when n > 0 => n,
              _ => null,
            },
          ),
    ],
  );
}

/// The OPF's long description is escaped XHTML. Keep its text, one
/// paragraph per block element, separated by blank lines.
String? plainDescription(String? html) {
  if (html == null) return null;
  final XmlDocumentFragment fragment;
  try {
    fragment = XmlDocumentFragment.parse(
      html,
      entityMapping: const XmlDefaultEntityMapping.html5(),
    );
  } on XmlException {
    return null;
  }
  // Collapse source line breaks but keep deliberate no-break spaces.
  String clean(String text) =>
      text.replaceAll(RegExp(r'[ \t\r\n]+'), ' ').trim();
  final paragraphs = <String>[];
  final current = StringBuffer();
  void flush() {
    final paragraph = clean(current.toString());
    if (paragraph.isNotEmpty) paragraphs.add(paragraph);
    current.clear();
  }

  void walk(XmlNode node) {
    if (node is XmlText) {
      current.write(node.value);
    } else if (node is XmlCDATA) {
      current.write(node.value);
    } else if (node is XmlElement &&
        _blockElements.contains(node.localName.toLowerCase())) {
      flush();
      node.children.forEach(walk);
      flush();
    } else {
      node.children.forEach(walk);
    }
  }

  fragment.children.forEach(walk);
  flush();
  final text = paragraphs.join('\n\n');
  return text.isEmpty ? null : text;
}

const _blockElements = {
  'p', 'div', 'blockquote', 'li', 'ul', 'ol', 'dl', 'dt', 'dd', 'pre', //
  'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'section', 'table', 'tr', 'hr',
};
