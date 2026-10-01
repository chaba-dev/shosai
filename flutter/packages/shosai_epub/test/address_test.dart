import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:shosai_epub/shosai_epub.dart';
import 'package:test/test.dart';

/// Archive-path, internal-link and table-of-contents resolution.
///
/// The expected values are derived from the production implementation
/// (`crates/shosai-core/src/epub/resource.rs`, `parser.rs`): its own tests pin
/// `resolve_location(0, "#same") == (0, 7)`, `resolve_location(0,
/// "two.xhtml#cross%20target") == (1, 12)`, `resolve_location(0, "#missing") ==
/// None`, `resolve_location(0, "../../outside.xhtml#same") == None`, the nested
/// nav shape (`Part` with an empty target and one child) and
/// `epub_toc_locations(&sample.epub)`. A case that cannot be resolved stays
/// unresolved rather than falling back to a fabricated target.
void main() {
  group('reference resolution', () {
    test('resolves a relative reference and its fragment', () {
      expect(resolveEpubReference('OPS/Text', 'chapter-1.xhtml#section'), (
        path: 'OPS/Text/chapter-1.xhtml',
        fragment: 'section',
      ));
      expect(resolveEpubReference('OPS/Nav', '../Text/chapter-2.xhtml'), (
        path: 'OPS/Text/chapter-2.xhtml',
        fragment: null,
      ));
      expect(resolveEpubReference('OPS/Nav', '/OPS/Text/chapter-2.xhtml#top'), (
        path: 'OPS/Text/chapter-2.xhtml',
        fragment: 'top',
      ));
    });

    test('decodes encoded components and fragments exactly once', () {
      expect(resolveEpubReference('', '%63hapter%2D1.xhtml#encoded%20target'), (
        path: 'chapter-1.xhtml',
        fragment: 'encoded target',
      ));
      // A literal percent in the source id decodes once, so a doubly encoded
      // fragment keeps its literal escape.
      expect(resolveEpubReference('OPS/Text', 'chapter.xhtml#literal%2520id'), (
        path: 'OPS/Text/chapter.xhtml',
        fragment: 'literal%20id',
      ));
      expect(decodeEpubFragment('caf%C3%A9'), 'café');
      expect(decodeEpubComponent('caf%C3%A9'), 'café');
    });

    test('keeps a literal non-ASCII component and space', () {
      expect(resolveEpubReference('OPS', 'Text/my chapter.xhtml'), (
        path: 'OPS/Text/my chapter.xhtml',
        fragment: null,
      ));
      expect(resolveEpubReference('OPS', 'Text/日本.xhtml'), (
        path: 'OPS/Text/日本.xhtml',
        fragment: null,
      ));
    });

    test('rejects an encoded separator or dot segment', () {
      for (final reference in [
        'Text%2Fchapter.xhtml',
        'Text%2fchapter.xhtml',
        'Text/%2E%2E/chapter.xhtml',
        'Text/%2e/chapter.xhtml',
        'Text%5Cchapter.xhtml',
      ]) {
        expect(
          () => resolveEpubReference('OPS', reference),
          throwsA(isA<EpubPathError>()),
          reason: '$reference must not smuggle a path boundary',
        );
      }
    });

    test('rejects empty segments, a trailing slash and the archive root', () {
      for (final reference in [
        'Text//chapter.xhtml',
        'Text/chapter.xhtml/',
        '/',
        '',
      ]) {
        expect(
          () => resolveEpubReference('OPS', reference),
          throwsA(isA<EpubPathError>()),
          reason: '$reference must not resolve',
        );
      }
    });

    test('rejects a query, multiple fragments and a foreign origin', () {
      for (final reference in [
        'chapter.xhtml?page=2',
        'chapter.xhtml#a#b',
        'chapter.xhtml#a?b',
        'https://example.invalid/book.xhtml',
        '//example.invalid/book.xhtml',
        '1abc:chapter.xhtml',
      ]) {
        expect(
          () => resolveEpubReference('OPS', reference),
          throwsA(isA<EpubPathError>()),
          reason: '$reference must not resolve',
        );
      }
      // A colon after a slash is a path character, not a scheme: the retained
      // classifier keeps `Text/foo:bar.xhtml` internal.
      expect(resolveEpubReference('OPS', 'Text/foo:bar.xhtml'), (
        path: 'OPS/Text/foo:bar.xhtml',
        fragment: null,
      ));
    });

    test('rejects an invalid base directory', () {
      // The production resolver validates the base like a canonical archive
      // path before resolving against it.
      for (final base in ['OPS/../Text', 'OPS//Text', '/OPS', 'OPS/']) {
        expect(
          () => resolveEpubReference(base, 'chapter.xhtml'),
          throwsA(isA<EpubPathError>()),
          reason: '$base is not a canonical base directory',
        );
      }
      // An empty base resolves from the archive root, like the production
      // resolver.
      expect(resolveEpubReference('', 'OPS/Text/chapter.xhtml'), (
        path: 'OPS/Text/chapter.xhtml',
        fragment: null,
      ));
    });

    test('rejects an escape above the archive root', () {
      expect(
        () => resolveEpubReference('OPS', '../../outside.xhtml'),
        throwsA(isA<EpubPathError>()),
      );
      expect(
        () => resolveEpubReference('', '../outside.xhtml'),
        throwsA(isA<EpubPathError>()),
      );
      // `..` inside the archive is ordinary resolution; a reference that
      // climbs past its own directory but stays inside the archive resolves
      // (and is then only useful if it names a spine item).
      expect(resolveEpubReference('OPS/Text/deep', '../chapter.xhtml'), (
        path: 'OPS/Text/chapter.xhtml',
        fragment: null,
      ));
      expect(resolveEpubReference('OPS/Text', '../../outside.xhtml'), (
        path: 'outside.xhtml',
        fragment: null,
      ));
    });

    test('rejects malformed escapes and invalid UTF-8', () {
      for (final reference in ['Text/ch%2.xhtml', 'Text/ch%zz.xhtml']) {
        expect(
          () => resolveEpubReference('OPS', reference),
          throwsA(isA<EpubPathError>()),
        );
      }
      expect(
        () => resolveEpubReference('OPS', 'Text/%FF.xhtml'),
        throwsA(isA<EpubPathError>()),
      );
      expect(() => decodeEpubFragment('%FF'), throwsA(isA<EpubPathError>()));
    });

    test('rejects a control character in a path or fragment', () {
      expect(
        () => resolveEpubReference('OPS', 'Text/ch%01apter.xhtml'),
        throwsA(isA<EpubPathError>()),
      );
      expect(() => decodeEpubFragment('a%00b'), throwsA(isA<EpubPathError>()));
      expect(
        () => decodeEpubFragment('a%7Fb'),
        throwsA(isA<EpubPathError>()),
        reason: 'DEL is a control character',
      );
      expect(
        () => decodeEpubFragment('a%C2%85b'),
        throwsA(isA<EpubPathError>()),
        reason: 'C1 controls are control characters',
      );
    });
  });

  group('internal links', () {
    final book = openEpubBytes(
      _book(
        nav: _nestedNav,
        chapters: const {
          'OPS/Text/chapter-1.xhtml':
              '<main><p>First chapter body.</p>'
              '<h2 id="section">Section one</h2><p>More text.</p></main>',
          'OPS/Text/chapter-2.xhtml':
              '<main><p>Second chapter.</p>'
              '<h2 id="encoded target">Encoded</h2></main>',
        },
        ncx: null,
      ),
    );

    test('resolves a same-chapter fragment against the current document', () {
      final target = resolveBookLink(
        book: book,
        fromResource: 'OPS/Text/chapter-1.xhtml',
        href: '#section',
      );
      expect(target, isNotNull);
      expect(target!.hasFragment, isTrue);
      expect(target.point.spine, 0);
      expect(target.point.scalar, 20);
    });

    test(
      'resolves a cross-chapter fragment relative to the current document',
      () {
        final target = resolveBookLink(
          book: book,
          fromResource: 'OPS/Text/chapter-1.xhtml',
          href: 'chapter-2.xhtml#encoded%20target',
        );
        expect(target, isNotNull);
        expect(target!.hasFragment, isTrue);
        expect(target.point.spine, 1);
        expect(target.point.scalar, 16);
      },
    );

    test('a fragment-less target resolves to the chapter start', () {
      final target = resolveBookLink(
        book: book,
        fromResource: 'OPS/Text/chapter-1.xhtml',
        href: 'chapter-2.xhtml',
      );
      expect(target, isNotNull);
      expect(target!.hasFragment, isFalse);
      expect(target.point.spine, 1);
      expect(target.point.scalar, 0);
    });

    test('an unknown or empty fragment resolves to nothing', () {
      for (final href in ['#missing', '#', 'chapter-2.xhtml#missing', '']) {
        expect(
          resolveBookLink(
            book: book,
            fromResource: 'OPS/Text/chapter-1.xhtml',
            href: href,
          ),
          isNull,
          reason: '$href must not fabricate a target',
        );
      }
    });

    test('an empty fragment never resolves, even with an empty anchor key', () {
      // The anchor map must never carry an empty key (the parser filters empty
      // names), but a resolution must not depend on that: an empty fragment is
      // not a target even if a map does carry one.
      final poisoned = _book(
        nav:
            '<nav><ol>'
            '<li><a href="../Text/chapter-1.xhtml#">Empty fragment</a></li>'
            '</ol></nav>',
        chapters: const {
          'OPS/Text/chapter-1.xhtml': '<main><p>First chapter body.</p></main>',
        },
        ncx: null,
      );
      final parsed = openEpubBytes(poisoned);
      expect(parsed.chapters.single.anchors.containsKey(''), isFalse);
      expect(
        resolveInternalLink(
          book: parsed,
          resource: 'OPS/Text/chapter-1.xhtml',
          fragment: '',
        ),
        isNull,
      );
      expect(resolveTocLocations(parsed), isEmpty);
      // A hand-built book whose anchor map does carry an empty key is still
      // unresolvable: the reader never navigates `#`.
      final injected = EpubBook(
        title: 'Injected',
        author: null,
        language: null,
        spine: const ['OPS/Text/chapter-1.xhtml'],
        toc: const [],
        resources: const {},
        chapters: [
          EpubChapter(
            spine: 0,
            resource: 'OPS/Text/chapter-1.xhtml',
            title: '',
            blocks: const [],
            canonicalText: 'First chapter body.\n',
            anchors: const {'': 5},
            scalarCount: 20,
          ),
        ],
        embeddedFonts: const {},
        warnings: const [],
      );
      expect(
        resolveInternalLink(
          book: injected,
          resource: 'OPS/Text/chapter-1.xhtml',
          fragment: '',
        ),
        isNull,
      );
    });

    test('an escaping, foreign or non-spine target resolves to nothing', () {
      for (final href in [
        '../../outside.xhtml#section',
        'https://example.invalid/book.xhtml',
        '//example.invalid/book.xhtml',
        'images/cover.png',
      ]) {
        expect(
          resolveBookLink(
            book: book,
            fromResource: 'OPS/Text/chapter-1.xhtml',
            href: href,
          ),
          isNull,
          reason: '$href must not resolve',
        );
      }
    });
  });

  group('table of contents', () {
    test(
      'keeps nested parts, skips unresolved entries and decodes targets',
      () {
        final book = openEpubBytes(
          _book(
            nav: _nestedNav,
            chapters: const {
              'OPS/Text/chapter-1.xhtml':
                  '<main><p>First chapter body.</p>'
                  '<h2 id="section">Section one</h2><p>More text.</p></main>',
              'OPS/Text/chapter-2.xhtml':
                  '<main><p>Second chapter.</p>'
                  '<h2 id="encoded target">Encoded</h2></main>',
            },
            ncx: null,
          ),
        );

        // The authored tree keeps the part heading and its nested list.
        expect(book.toc, hasLength(6));
        final part = book.toc.first;
        expect(part.title, 'Part One');
        expect(part.resource, isEmpty);
        expect(part.children, hasLength(2));
        expect(part.children.first.title, 'Section one');
        expect(part.children.first.resource, 'OPS/Text/chapter-1.xhtml');
        expect(part.children.first.fragment, 'section');
        expect(part.children.last.title, 'Missing anchor');
        expect(
          book.warnings.any((warning) => warning.contains('outside.xhtml')),
          isTrue,
        );

        // Only entries that resolve to a durable location become rows; a part
        // heading without a target is skipped while its child keeps depth 1.
        expect(
          resolveTocLocations(book),
          [
            (depth: 1, title: 'Section one', spine: 0, offset: 20),
            (depth: 0, title: 'Encoded target', spine: 1, offset: 16),
            (depth: 0, title: 'No fragment', spine: 1, offset: null),
            (depth: 0, title: 'Encoded path', spine: 0, offset: 20),
          ].map(_location),
        );
      },
    );

    test('a nav title takes the link text, not a nested element', () {
      final book = openEpubBytes(
        _book(
          nav:
              '<nav><ol>'
              '<li><a href="../Text/chapter-1.xhtml#section">Chapter '
              '<em>One</em></a></li>'
              '</ol></nav>',
          chapters: const {
            'OPS/Text/chapter-1.xhtml':
                '<main><p>First chapter body.</p>'
                '<h2 id="section">Section one</h2></main>',
          },
          ncx: null,
        ),
      );
      expect(book.toc.single.title, 'Chapter');
    });

    test('a CDATA nav title is text to the parser', () {
      final book = openEpubBytes(
        _book(
          nav:
              '<nav><ol>'
              '<li><a href="../Text/chapter-1.xhtml#section">'
              '<![CDATA[Chapter one]]></a></li>'
              '</ol></nav>',
          chapters: const {
            'OPS/Text/chapter-1.xhtml':
                '<main><p>First chapter body.</p>'
                '<h2 id="section">Section one</h2></main>',
          },
          ncx: null,
        ),
      );
      expect(book.toc.single.title, 'Chapter one');
    });

    test('an NCX keeps a part navPoint with its nested children', () {
      final book = openEpubBytes(
        _book(
          nav: null,
          ncx:
              '<ncx><navMap>'
              '<navPoint><navLabel><text>Part</text></navLabel>'
              '<content src="Text/chapter-1.xhtml"/>'
              '<navPoint><navLabel><text>Section</text></navLabel>'
              '<content src="Text/chapter-1.xhtml#section"/></navPoint>'
              '</navPoint>'
              '</navMap></ncx>',
          chapters: const {
            'OPS/Text/chapter-1.xhtml':
                '<main><p>First chapter body.</p>'
                '<h2 id="section">Section one</h2></main>',
          },
        ),
      );
      expect(book.toc, hasLength(1));
      expect(book.toc.single.title, 'Part');
      expect(book.toc.single.resource, 'OPS/Text/chapter-1.xhtml');
      expect(book.toc.single.children, hasLength(1));
      expect(resolveTocLocations(book), [
        _location((depth: 0, title: 'Part', spine: 0, offset: null)),
        _location((depth: 1, title: 'Section', spine: 0, offset: 20)),
      ]);
    });

    test('the committed sample resolves to the retained locations', () {
      // `crates/shosai-app` pins `epub_toc_locations(&sample.epub)` to
      // `[(0, "Chapter 1: Introduction", 0, 0), (0, "Chapter 2: Getting
      // Started", 1, 0)]`; a fragment-less entry's offset is the chapter start.
      final fixtures = _findFixtures();
      final book = openEpubBytes(
        Uint8List.fromList(
          File('${fixtures.path}/sample.epub').readAsBytesSync(),
        ),
      );
      expect(resolveTocLocations(book), [
        _location((
          depth: 0,
          title: 'Chapter 1: Introduction',
          spine: 0,
          offset: null,
        )),
        _location((
          depth: 0,
          title: 'Chapter 2: Getting Started',
          spine: 1,
          offset: null,
        )),
      ]);
    });
  });
}

EpubTocLocation _location(
  ({int depth, String title, int spine, int? offset}) row,
) => EpubTocLocation(
  depth: row.depth,
  title: row.title,
  spine: row.spine,
  offset: row.offset,
);

const _nestedNav =
    '<nav><ol>'
    '<li><span>Part One</span><ol>'
    '<li><a href="../Text/chapter-1.xhtml#section">Section one</a></li>'
    '<li><a href="../Text/chapter-2.xhtml#missing">Missing anchor</a></li>'
    '</ol></li>'
    '<li><a href="../Text/chapter-2.xhtml#encoded%20target">'
    'Encoded target</a></li>'
    '<li><a href="../Text/chapter-2.xhtml#">Empty fragment</a></li>'
    '<li><a href="../Text/chapter-2.xhtml">No fragment</a></li>'
    '<li><a href="../Text/%63hapter-1.xhtml#section">Encoded path</a></li>'
    '<li><a href="../../../outside.xhtml">Escape</a></li>'
    '</ol></nav>';

/// One small EPUB archive with the supplied nav and/or NCX documents.
Uint8List _book({
  required String? nav,
  required Map<String, String> chapters,
  required String? ncx,
}) {
  final files = <String, String>{
    'mimetype': 'application/epub+zip',
    'META-INF/container.xml':
        '<?xml version="1.0"?>'
        '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" '
        'version="1.0"><rootfiles><rootfile full-path="OPS/package.opf" '
        'media-type="application/oebps-package+xml"/></rootfiles></container>',
  };
  final manifest = <String>[
    if (nav != null)
      '<item id="nav" href="Nav/toc.xhtml" '
          'media-type="application/xhtml+xml" properties="nav"/>',
    if (ncx != null)
      '<item id="ncx" href="toc.ncx" '
          'media-type="application/x-dtbncx+xml"/>',
  ];
  final spine = <String>[];
  var index = 1;
  for (final path in chapters.keys) {
    final name = path.substring(path.lastIndexOf('/') + 1);
    manifest.add(
      '<item id="chapter-$index" href="Text/$name" '
      'media-type="application/xhtml+xml"/>',
    );
    spine.add('<itemref idref="chapter-$index"/>');
    files[path] =
        '<?xml version="1.0"?>'
        '<html xmlns="http://www.w3.org/1999/xhtml"><body>'
        '${chapters[path]}</body></html>';
    index += 1;
  }
  files['OPS/package.opf'] =
      '<?xml version="1.0"?>'
      '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" '
      'unique-identifier="id"><metadata '
      'xmlns:dc="http://purl.org/dc/elements/1.1/">'
      '<dc:identifier id="id">address-test</dc:identifier>'
      '<dc:title>Address Test</dc:title><dc:language>en</dc:language>'
      '</metadata><manifest>${manifest.join()}</manifest>'
      '<spine>${spine.join()}</spine></package>';
  if (nav != null) {
    files['OPS/Nav/toc.xhtml'] =
        '<?xml version="1.0"?>'
        '<html xmlns="http://www.w3.org/1999/xhtml" '
        'xmlns:epub="http://www.idpf.org/2007/ops"><body>'
        '${nav.replaceFirst('<nav>', '<nav epub:type="toc">')}'
        '</body></html>';
  }
  if (ncx != null) {
    files['OPS/toc.ncx'] = '<?xml version="1.0"?>$ncx';
  }

  final archive = Archive();
  for (final entry in files.entries) {
    final bytes = Uint8List.fromList(entry.value.codeUnits);
    archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

/// Locates the repository's committed document fixtures by walking up from the
/// test working directory.
Directory _findFixtures() {
  var directory = Directory.current.absolute;
  while (true) {
    final candidate = Directory(
      '${directory.path}/crates/shosai-core/tests/fixtures',
    );
    if (candidate.existsSync()) return candidate;
    final parent = directory.parent;
    if (parent.path == directory.path) {
      throw StateError(
        'document fixtures not found above ${Directory.current.path}',
      );
    }
    directory = parent;
  }
}
