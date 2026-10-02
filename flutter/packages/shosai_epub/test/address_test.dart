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
        expect(book.toc, hasLength(5));
        final part = book.toc.first;
        expect(part.title, 'Part One');
        expect(part.resource, isEmpty);
        expect(part.children, hasLength(2));
        expect(part.children.first.title, 'Section one');
        expect(part.children.first.resource, 'OPS/Text/chapter-1.xhtml');
        expect(part.children.first.fragment, 'section');
        expect(part.children.last.title, 'Missing anchor');

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

    test('an unusable nav href abandons the nav table of contents', () {
      // The production `parse_nav_ol` propagates one entry's resolution error
      // through `?`, so already-parsed siblings are discarded with it, and the
      // nav document is the last candidate: the book keeps no table of
      // contents. Skipping only the bad entry would keep the good siblings
      // where the retained reader shows none.
      final escape = openEpubBytes(
        _book(
          nav:
              '<nav><ol>'
              '<li><a href="../Text/chapter-1.xhtml#section">Good</a></li>'
              '<li><a href="../../../outside.xhtml">Escape</a></li>'
              '</ol></nav>',
          chapters: const {
            'OPS/Text/chapter-1.xhtml':
                '<main><p>First chapter body.</p>'
                '<h2 id="section">Section one</h2></main>',
          },
          ncx: null,
        ),
      );
      expect(escape.toc, isEmpty);
      expect(
        escape.warnings.any((warning) => warning.contains('outside.xhtml')),
        isTrue,
      );

      final foreign = openEpubBytes(
        _book(
          nav:
              '<nav><ol>'
              '<li><a href="../Text/chapter-1.xhtml#section">Good</a></li>'
              '<li><a href="https://example.invalid/book.xhtml">Foreign</a></li>'
              '</ol></nav>',
          chapters: const {
            'OPS/Text/chapter-1.xhtml':
                '<main><p>First chapter body.</p>'
                '<h2 id="section">Section one</h2></main>',
          },
          ncx: null,
        ),
      );
      expect(foreign.toc, isEmpty);
    });

    test('a reference that climbs inside the archive is not an error', () {
      // `../outside.xhtml` from the nav's own directory stays inside the
      // archive (`OPS/outside.xhtml`), so it resolves like any reference; the
      // entry survives and only its row is unoffered because the target is not
      // a spine item. Only a resolution error abandons the candidate.
      final book = openEpubBytes(
        _book(
          nav:
              '<nav><ol>'
              '<li><a href="../outside.xhtml">Climbs</a></li>'
              '<li><a href="../Text/chapter-1.xhtml#section">Good</a></li>'
              '</ol></nav>',
          chapters: const {
            'OPS/Text/chapter-1.xhtml':
                '<main><p>First chapter body.</p>'
                '<h2 id="section">Section one</h2></main>',
          },
          ncx: null,
        ),
      );
      expect(book.toc, hasLength(2));
      expect(book.toc.first.resource, 'OPS/outside.xhtml');
      expect(resolveTocLocations(book).single.title, 'Good');
    });

    test('an unusable nav href in a nested child abandons the whole nav', () {
      final book = openEpubBytes(
        _book(
          nav:
              '<nav><ol>'
              '<li><span>Part</span><ol>'
              '<li><a href="../Text/chapter-1.xhtml#section">Good</a></li>'
              '<li><a href="../Text/ch%2.xhtml">Bad escape</a></li>'
              '</ol></li>'
              '</ol></nav>',
          chapters: const {
            'OPS/Text/chapter-1.xhtml':
                '<main><p>First chapter body.</p>'
                '<h2 id="section">Section one</h2></main>',
          },
          ncx: null,
        ),
      );
      expect(book.toc, isEmpty);
    });

    test('an unusable NCX src abandons the NCX and falls back to the nav', () {
      final book = openEpubBytes(
        _book(
          nav:
              '<nav><ol><li><a href="../Text/chapter-1.xhtml#section">'
              'Nav Second</a></li></ol></nav>',
          ncx:
              '<ncx><navMap>'
              '<navPoint><navLabel><text>Good NCX</text></navLabel>'
              '<content src="Text/chapter-1.xhtml"/></navPoint>'
              '<navPoint><navLabel><text>Bad NCX</text></navLabel>'
              '<content src="../../outside.xhtml"/></navPoint>'
              '</navMap></ncx>',
          chapters: const {
            'OPS/Text/chapter-1.xhtml':
                '<main><p>First chapter body.</p>'
                '<h2 id="section">Section one</h2></main>',
          },
        ),
      );
      // The NCX candidate is abandoned whole — the parsed "Good NCX" point is
      // discarded with it — and the nav document supplies the entries.
      expect(book.toc.single.title, 'Nav Second');
      expect(
        book.warnings.any(
          (warning) =>
              warning.contains('unusable src') &&
              warning.contains('../outside.xhtml'),
        ),
        isTrue,
      );
    });

    test('an unusable NCX src without a nav document empties the TOC', () {
      final book = openEpubBytes(
        _book(
          nav: null,
          ncx:
              '<ncx><navMap><navPoint><navLabel><text>Bad NCX</text>'
              '</navLabel><content src="Text//chapter-1.xhtml"/></navPoint>'
              '</navMap></ncx>',
          chapters: const {
            'OPS/Text/chapter-1.xhtml': '<main><p>Body.</p></main>',
          },
        ),
      );
      expect(book.toc, isEmpty);
    });

    test('an unusable NCX src in a nested point abandons the whole NCX', () {
      final book = openEpubBytes(
        _book(
          nav:
              '<nav><ol><li><a href="../Text/chapter-1.xhtml#section">'
              'Nav Second</a></li></ol></nav>',
          ncx:
              '<ncx><navMap>'
              '<navPoint><navLabel><text>Part</text></navLabel>'
              '<content src="Text/chapter-1.xhtml"/>'
              '<navPoint><navLabel><text>Bad</text></navLabel>'
              '<content src="%2e%2e/outside.xhtml"/></navPoint>'
              '</navPoint>'
              '</navMap></ncx>',
          chapters: const {
            'OPS/Text/chapter-1.xhtml':
                '<main><p>First chapter body.</p>'
                '<h2 id="section">Section one</h2></main>',
          },
        ),
      );
      expect(book.toc.single.title, 'Nav Second');
    });

    test('missing content, src or href keeps an entry with an empty target', () {
      // The production `unwrap_or_default` keeps a navPoint without a
      // `<content>` element or src attribute, and a nav link without an href
      // attribute: an absent target is not a resolution error, so the entry
      // survives and only its Contents row is unoffered.
      final ncx = openEpubBytes(
        _book(
          nav: null,
          ncx:
              '<ncx><navMap>'
              '<navPoint><navLabel><text>No content</text></navLabel></navPoint>'
              '<navPoint><navLabel><text>No src</text></navLabel><content/>'
              '</navPoint>'
              '</navMap></ncx>',
          chapters: const {
            'OPS/Text/chapter-1.xhtml': '<main><p>Body.</p></main>',
          },
        ),
      );
      expect(ncx.toc, hasLength(2));
      expect(ncx.toc.first.title, 'No content');
      expect(ncx.toc.first.resource, isEmpty);
      expect(ncx.toc.last.title, 'No src');
      expect(ncx.toc.last.resource, isEmpty);
      expect(resolveTocLocations(ncx), isEmpty);

      final nav = openEpubBytes(
        _book(
          nav:
              '<nav><ol>'
              '<li><a>No href</a></li>'
              '<li><span>Span only</span></li>'
              '<li><a/></li>'
              '<li></li>'
              '</ol></nav>',
          chapters: const {
            'OPS/Text/chapter-1.xhtml': '<main><p>Body.</p></main>',
          },
          ncx: null,
        ),
      );
      // A titled link without an href attribute and a `<span>` heading keep
      // their empty targets; a link with neither a title nor a target, and an
      // empty `<li>`, are dropped by the production filter.
      expect(nav.toc, hasLength(2));
      expect(nav.toc.every((entry) => entry.resource.isEmpty), isTrue);
      expect(nav.toc.map((entry) => entry.title), ['No href', 'Span only']);
      expect(resolveTocLocations(nav), isEmpty);
    });

    test('bad entries in both candidates leave no table of contents', () {
      final book = openEpubBytes(
        _book(
          nav:
              '<nav><ol><li><a href="../../../outside.xhtml">Bad nav</a></li>'
              '</ol></nav>',
          ncx:
              '<ncx><navMap><navPoint><navLabel><text>Bad ncx</text>'
              '</navLabel><content src="../../outside.xhtml"/></navPoint>'
              '</navMap></ncx>',
          chapters: const {
            'OPS/Text/chapter-1.xhtml': '<main><p>Body.</p></main>',
          },
        ),
      );
      // The NCX is tried first, so its warning precedes the nav document's:
      // one warning per rejected candidate, in candidate order.
      expect(book.toc, isEmpty);
      expect(book.warnings.where((warning) => warning.contains('unusable')), [
        'NCX entry has an unusable src: ../../outside.xhtml',
        'nav entry has an unusable href: ../../../outside.xhtml',
      ]);
    });

    test('a nav title is the link text only when the first child is text', () {
      // The production `Node::text` returns an element's text only when the
      // first child node is text: a leading element or comment yields no link
      // title, so an otherwise empty entry is dropped by the production
      // filter instead of surviving on later text.
      final leading = openEpubBytes(
        _book(
          nav:
              '<nav><ol>'
              '<li><a href="../Text/chapter-1.xhtml#section">'
              '<em>One</em> Chapter</a></li>'
              '</ol></nav>',
          chapters: const {
            'OPS/Text/chapter-1.xhtml':
                '<main><p>First chapter body.</p>'
                '<h2 id="section">Section one</h2></main>',
          },
          ncx: null,
        ),
      );
      expect(leading.toc.single.title, isEmpty);

      final coalesced = openEpubBytes(
        _book(
          nav:
              '<nav><ol>'
              '<li><a href="../Text/chapter-1.xhtml#section">'
              'A<![CDATA[B]]>C</a></li>'
              '</ol></nav>',
          chapters: const {
            'OPS/Text/chapter-1.xhtml':
                '<main><p>First chapter body.</p>'
                '<h2 id="section">Section one</h2></main>',
          },
          ncx: null,
        ),
      );
      // The production parser coalesces the leading text/CDATA run into one
      // node, so the title is the whole run, not just its first chunk.
      expect(coalesced.toc.single.title, 'ABC');

      // The production link text exists when the element starts with a text
      // node even if that run is empty: the `<span>` fallback does not
      // trigger, so an otherwise empty entry is dropped, and a valid href
      // keeps the coalesced run as the title.
      final emptyRun = openEpubBytes(
        _book(
          nav:
              '<nav><ol>'
              '<li><a><![CDATA[]]></a><span>Fallback</span></li>'
              '<li><a href="../Text/chapter-1.xhtml#section">'
              '<![CDATA[]]>Fallback</a></li>'
              '</ol></nav>',
          chapters: const {
            'OPS/Text/chapter-1.xhtml':
                '<main><p>First chapter body.</p>'
                '<h2 id="section">Section one</h2></main>',
          },
          ncx: null,
        ),
      );
      expect(emptyRun.toc, hasLength(1));
      expect(emptyRun.toc.single.title, 'Fallback');
      expect(emptyRun.toc.single.resource, 'OPS/Text/chapter-1.xhtml');

      final comment = openEpubBytes(
        _book(
          nav:
              '<nav><ol>'
              '<li><a><!--note-->Later</a></li>'
              '</ol></nav>',
          chapters: const {
            'OPS/Text/chapter-1.xhtml': '<main><p>Body.</p></main>',
          },
          ncx: null,
        ),
      );
      // No title, no target and no children: the production filter drops it.
      expect(comment.toc, isEmpty);
    });

    test('a prefixed href or src attribute is the entry target', () {
      // The production `Node::attribute` matches by local name when called
      // without a namespace URI (the roxmltree 0.21 `attribute_node` rule), so
      // a declared-prefix attribute is the entry's target: a valid one
      // navigates, an unusable one abandons the candidate, and a namespace
      // declaration never is a target.
      final book = openEpubBytes(
        _book(
          nav:
              '<nav><ol>'
              '<li><a xmlns:x="urn:test" x:href="../Text/chapter-1.xhtml#section">'
              'Prefixed nav</a></li>'
              '</ol></nav>',
          ncx:
              '<ncx><navMap><navPoint><navLabel><text>Prefixed ncx</text>'
              '</navLabel><content xmlns:y="urn:test" y:src="Text/chapter-1.xhtml"/>'
              '</navPoint></navMap></ncx>',
          chapters: const {
            'OPS/Text/chapter-1.xhtml':
                '<main><p>First chapter body.</p>'
                '<h2 id="section">Section one</h2></main>',
          },
        ),
      );
      // The NCX wins and its prefixed src resolved like a plain one.
      expect(book.toc.single.title, 'Prefixed ncx');
      expect(book.toc.single.resource, 'OPS/Text/chapter-1.xhtml');
      expect(resolveTocLocations(book).single.title, 'Prefixed ncx');
      expect(book.warnings, isEmpty);

      final abort = openEpubBytes(
        _book(
          nav:
              '<nav><ol><li><a xmlns:x="urn:test" '
              'x:href="../../../outside.xhtml">Prefixed</a></li></ol></nav>',
          chapters: const {
            'OPS/Text/chapter-1.xhtml': '<main><p>Body.</p></main>',
          },
          ncx: null,
        ),
      );
      expect(abort.toc, isEmpty);
      expect(
        abort.warnings.any((warning) => warning.contains('outside.xhtml')),
        isTrue,
      );

      final declaration = openEpubBytes(
        _book(
          nav:
              '<nav><ol><li><a xmlns:href="urn:test">Decl only</a></li>'
              '</ol></nav>',
          chapters: const {
            'OPS/Text/chapter-1.xhtml': '<main><p>Body.</p></main>',
          },
          ncx: null,
        ),
      );
      expect(declaration.toc.single.title, 'Decl only');
      expect(declaration.toc.single.resource, isEmpty);
      expect(declaration.warnings, isEmpty);

      // A nav-only book exercises the nav's own prefixed lookup.
      final navOnly = openEpubBytes(
        _book(
          nav:
              '<nav><ol><li><a xmlns:x="urn:test" '
              'x:href="../Text/chapter-1.xhtml#section">Prefixed nav</a></li>'
              '</ol></nav>',
          ncx: null,
          chapters: const {
            'OPS/Text/chapter-1.xhtml':
                '<main><p>First chapter body.</p>'
                '<h2 id="section">Section one</h2></main>',
          },
        ),
      );
      expect(navOnly.toc.single.title, 'Prefixed nav');
      expect(navOnly.toc.single.resource, 'OPS/Text/chapter-1.xhtml');
      expect(navOnly.toc.single.fragment, 'section');

      // Two attributes with the same local name: the production `find` takes
      // the first in attribute order, whatever its prefix.
      final unprefixedFirst = openEpubBytes(
        _book(
          nav:
              '<nav><ol><li><a href="../Text/chapter-2.xhtml" '
              'xmlns:x="urn:test" '
              'x:href="../Text/chapter-1.xhtml#section">Both</a></li></ol></nav>',
          ncx: null,
          chapters: const {
            'OPS/Text/chapter-1.xhtml':
                '<main><p>First chapter body.</p>'
                '<h2 id="section">Section one</h2></main>',
            'OPS/Text/chapter-2.xhtml': '<main><p>Second chapter.</p></main>',
          },
        ),
      );
      expect(unprefixedFirst.toc.single.resource, 'OPS/Text/chapter-2.xhtml');

      final prefixedFirst = openEpubBytes(
        _book(
          nav:
              '<nav><ol><li><a xmlns:x="urn:test" '
              'x:href="../Text/chapter-1.xhtml#section" '
              'href="../Text/chapter-2.xhtml">Both</a></li></ol></nav>',
          ncx: null,
          chapters: const {
            'OPS/Text/chapter-1.xhtml':
                '<main><p>First chapter body.</p>'
                '<h2 id="section">Section one</h2></main>',
            'OPS/Text/chapter-2.xhtml': '<main><p>Second chapter.</p></main>',
          },
        ),
      );
      expect(prefixedFirst.toc.single.resource, 'OPS/Text/chapter-1.xhtml');
    });

    test('an empty href or src value is a resolution error, not an absence', () {
      // The production reads the attribute value and resolves it; only a
      // missing attribute takes the `unwrap_or_default` path. An empty value
      // fails resolution and abandons the candidate.
      final nav = openEpubBytes(
        _book(
          nav:
              '<nav><ol><li><a href="">Good title</a></li>'
              '<li><a href="../Text/chapter-1.xhtml">Good</a></li></ol></nav>',
          chapters: const {
            'OPS/Text/chapter-1.xhtml': '<main><p>Body.</p></main>',
          },
          ncx: null,
        ),
      );
      expect(nav.toc, isEmpty);

      final ncx = openEpubBytes(
        _book(
          nav:
              '<nav><ol><li><a href="../Text/chapter-1.xhtml">'
              'Nav Second</a></li></ol></nav>',
          ncx:
              '<ncx><navMap><navPoint><navLabel><text>Empty src</text>'
              '</navLabel><content src=""/></navPoint></navMap></ncx>',
          chapters: const {
            'OPS/Text/chapter-1.xhtml': '<main><p>Body.</p></main>',
          },
        ),
      );
      expect(ncx.toc.single.title, 'Nav Second');
    });

    test('a parent entry error is reported before a nested child error', () {
      // The production resolves the href/src before recursing into the nested
      // list, so the parent's rejected reference is the one that abandons the
      // candidate; the child is never parsed.
      final nav = openEpubBytes(
        _book(
          nav:
              '<nav><ol>'
              '<li><a href="../../../outside.xhtml">Bad parent</a><ol>'
              '<li><a href="../Text/ch%2.xhtml">Bad child</a></li>'
              '</ol></li>'
              '</ol></nav>',
          chapters: const {
            'OPS/Text/chapter-1.xhtml': '<main><p>Body.</p></main>',
          },
          ncx: null,
        ),
      );
      expect(nav.toc, isEmpty);
      expect(
        nav.warnings.where((warning) => warning.contains('unusable href')),
        hasLength(1),
      );
      expect(
        nav.warnings.any((warning) => warning.contains('../../../outside')),
        isTrue,
      );

      final ncx = openEpubBytes(
        _book(
          nav: null,
          ncx:
              '<ncx><navMap>'
              '<navPoint><navLabel><text>Bad parent</text></navLabel>'
              '<content src="../../outside.xhtml"/>'
              '<navPoint><navLabel><text>Bad child</text></navLabel>'
              '<content src="%2e%2e/outside.xhtml"/></navPoint>'
              '</navPoint>'
              '</navMap></ncx>',
          chapters: const {
            'OPS/Text/chapter-1.xhtml': '<main><p>Body.</p></main>',
          },
        ),
      );
      expect(ncx.toc, isEmpty);
      expect(
        ncx.warnings.where((warning) => warning.contains('unusable src')),
        hasLength(1),
      );
      expect(
        ncx.warnings.any((warning) => warning.contains('../../outside')),
        isTrue,
      );
    });

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

    test('an NCX beats a valid nav document when both are present', () {
      final book = openEpubBytes(
        _book(
          nav:
              '<nav><ol><li><a href="../Text/chapter-1.xhtml#section">'
              'Nav Second</a></li></ol></nav>',
          ncx:
              '<ncx><navMap><navPoint><navLabel><text>NCX First</text>'
              '</navLabel><content src="Text/chapter-1.xhtml"/></navPoint>'
              '</navMap></ncx>',
          chapters: const {
            'OPS/Text/chapter-1.xhtml':
                '<main><p>First chapter body.</p>'
                '<h2 id="section">Section one</h2></main>',
          },
        ),
      );
      // The production parser tries the NCX first: a book whose two navigation
      // documents disagree shows the NCX's table of contents. Production
      // resolves the NCX src as a plain relative reference from its own
      // directory, and so does this port.
      expect(book.toc.single.title, 'NCX First');
      expect(book.toc.single.resource, 'OPS/Text/chapter-1.xhtml');
      expect(book.toc.single.fragment, isNull);
    });

    test('a navMap with no points suppresses the nav fallback', () {
      final book = openEpubBytes(
        _book(
          nav:
              '<nav><ol><li><a href="../Text/chapter-1.xhtml">'
              'Nav Second</a></li></ol></nav>',
          ncx: '<ncx><navMap></navMap></ncx>',
          chapters: const {
            'OPS/Text/chapter-1.xhtml': '<main><p>Body.</p></main>',
          },
        ),
      );
      // Production `parse_ncx_toc` succeeds on an empty navMap and its caller
      // never falls back: an intentionally empty NCX must stay empty.
      expect(book.toc, isEmpty);
    });

    test('an NCX without a navMap falls back to the nav document', () {
      final book = openEpubBytes(
        _book(
          nav:
              '<nav><ol><li><a href="../Text/chapter-1.xhtml">'
              'Nav Second</a></li></ol></nav>',
          ncx: '<ncx><head/><docTitle><text>x</text></docTitle></ncx>',
          chapters: const {
            'OPS/Text/chapter-1.xhtml': '<main><p>Body.</p></main>',
          },
        ),
      );
      expect(book.toc.single.title, 'Nav Second');
    });

    test(
      'an unparseable NCX falls back to the nav document with a warning',
      () {
        final book = openEpubBytes(
          _book(
            nav:
                '<nav><ol><li><a href="../Text/chapter-1.xhtml">'
                'Nav Second</a></li></ol></nav>',
            ncx: '<not-ncx',
            chapters: const {
              'OPS/Text/chapter-1.xhtml': '<main><p>Body.</p></main>',
            },
          ),
        );
        // This port reads the NCX without the retained parser's strict UTF-8
        // and lexically-inspectable-XML gate, so a broken one opens with a
        // warning and the nav fallback (non-UTF-8 bytes that still parse stay
        // selected silently with replacement characters). The retained TOC
        // reader fails the whole book on that read instead; structural
        // mismatches that pass the inspection only fail the candidate's own
        // parse and fall through — a documented residual, tracked in the
        // package README.
        expect(book.toc.single.title, 'Nav Second');
        expect(
          book.warnings.any(
            (warning) => warning.contains('failed to parse EPUB NCX'),
          ),
          isTrue,
        );
      },
    );

    test('an NCX missing from the archive falls back to the nav document', () {
      final book = openEpubBytes(
        _book(
          nav:
              '<nav><ol><li><a href="../Text/chapter-1.xhtml">'
              'Nav Second</a></li></ol></nav>',
          ncx:
              '<ncx><navMap><navPoint><navLabel><text>NCX First</text>'
              '</navLabel><content src="Text/chapter-1.xhtml"/></navPoint>'
              '</navMap></ncx>',
          ncxHref: 'Text/missing.ncx',
          writeNcxFile: false,
          chapters: const {
            'OPS/Text/chapter-1.xhtml': '<main><p>Body.</p></main>',
          },
        ),
      );
      expect(book.toc.single.title, 'Nav Second');
    });

    test('an NCX with a foreign media type is ignored', () {
      // Production has no `.ncx` suffix rule: only the media type selects the
      // NCX. With the type changed and no nav-id item, both documents are
      // unused even though the NCX file parses.
      final withoutNav = openEpubBytes(
        _book(
          nav: null,
          ncx:
              '<ncx><navMap><navPoint><navLabel><text>NCX First</text>'
              '</navLabel><content src="Text/chapter-1.xhtml"/></navPoint>'
              '</navMap></ncx>',
          ncxMediaType: 'application/xml',
          chapters: const {
            'OPS/Text/chapter-1.xhtml': '<main><p>Body.</p></main>',
          },
        ),
      );
      expect(withoutNav.toc, isEmpty);

      final wrongNavId = openEpubBytes(
        _book(
          nav:
              '<nav><ol><li><a href="../Text/chapter-1.xhtml">'
              'Nav Second</a></li></ol></nav>',
          ncx:
              '<ncx><navMap><navPoint><navLabel><text>NCX First</text>'
              '</navLabel><content src="Text/chapter-1.xhtml"/></navPoint>'
              '</navMap></ncx>',
          navId: 'tocdoc',
          navProperties: 'nav',
          ncxMediaType: 'application/xml',
          chapters: const {
            'OPS/Text/chapter-1.xhtml': '<main><p>Body.</p></main>',
          },
        ),
      );
      // The nav id must contain the substring "nav"; "tocdoc" does not.
      expect(wrongNavId.toc, isEmpty);
    });

    test('the nav heuristic is the manifest id containing "nav"', () {
      // Production ignores `properties="nav"`; the case-sensitive substring
      // match on the id is the selector, in both directions.
      final idContainsNav = openEpubBytes(
        _book(
          nav:
              '<nav><ol><li><a href="../Text/chapter-1.xhtml">'
              'Nav Second</a></li></ol></nav>',
          navId: 'the-nav-doc',
          navProperties: '',
          chapters: const {
            'OPS/Text/chapter-1.xhtml': '<main><p>Body.</p></main>',
          },
        ),
      );
      expect(idContainsNav.toc.single.title, 'Nav Second');

      final idSubstring = openEpubBytes(
        _book(
          nav:
              '<nav><ol><li><a href="../Text/chapter-1.xhtml">'
              'Nav Second</a></li></ol></nav>',
          navId: 'xnavx',
          navProperties: '',
          chapters: const {
            'OPS/Text/chapter-1.xhtml': '<main><p>Body.</p></main>',
          },
        ),
      );
      expect(idSubstring.toc.single.title, 'Nav Second');
    });

    test('a broken nav document next to a valid NCX never overrides it', () {
      final book = openEpubBytes(
        _book(
          nav: '<broken',
          ncx:
              '<ncx><navMap><navPoint><navLabel><text>NCX First</text>'
              '</navLabel><content src="Text/chapter-1.xhtml"/></navPoint>'
              '</navMap></ncx>',
          chapters: const {
            'OPS/Text/chapter-1.xhtml': '<main><p>Body.</p></main>',
          },
        ),
      );
      // The NCX is tried first and succeeds, so the nav document is never
      // parsed.
      expect(book.toc.single.title, 'NCX First');
    });

    test('the first nav element in document order supplies the entries', () {
      final book = openEpubBytes(
        _book(
          nav:
              '<nav epub:type="landmarks"><ol>'
              '<li><a href="../Text/chapter-1.xhtml#land">Landmarks</a></li>'
              '</ol></nav>'
              '<nav epub:type="toc"><ol>'
              '<li><a href="../Text/chapter-1.xhtml#toc">Real Toc</a></li>'
              '</ol></nav>',
          chapters: const {
            'OPS/Text/chapter-1.xhtml': '<main><p>Body.</p></main>',
          },
        ),
      );
      // Production does not prefer a nav by `epub:type`; it takes the first
      // one in document order, so a landmarks nav ahead of the toc nav wins.
      expect(book.toc.single.title, 'Landmarks');
      expect(book.toc.single.fragment, 'land');
    });

    test('a nav ol nested in a wrapper element is still found', () {
      final book = openEpubBytes(
        _book(
          nav:
              '<nav><div><ol><li><a href="../Text/chapter-1.xhtml#deep">'
              'Deep</a></li></ol></div></nav>',
          chapters: const {
            'OPS/Text/chapter-1.xhtml': '<main><p>Body.</p></main>',
          },
        ),
      );
      expect(book.toc.single.title, 'Deep');
      expect(book.toc.single.fragment, 'deep');
    });

    test('a nav document without an ol resolves to nothing', () {
      final book = openEpubBytes(
        _book(
          nav: '<nav><div>nothing</div></nav>',
          chapters: const {
            'OPS/Text/chapter-1.xhtml': '<main><p>Body.</p></main>',
          },
        ),
      );
      expect(book.toc, isEmpty);
    });

    test('a book with neither candidate resolves to nothing', () {
      final book = openEpubBytes(
        _book(
          nav: null,
          ncx: null,
          chapters: const {
            'OPS/Text/chapter-1.xhtml': '<main><p>Body.</p></main>',
          },
        ),
      );
      expect(book.toc, isEmpty);
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
    '</ol></nav>';

/// One small EPUB archive with the supplied nav and/or NCX documents.
///
/// The extra knobs exist to pin the production TOC-source preference: the NCX
/// is selected by media type alone (no `.ncx` suffix rule) and the nav document
/// by the manifest id containing "nav" (case-sensitive substring), not by
/// `properties="nav"`.
Uint8List _book({
  String? nav,
  required Map<String, String> chapters,
  String? ncx,
  String navId = 'nav',
  String navProperties = 'nav',
  String ncxMediaType = 'application/x-dtbncx+xml',
  String ncxHref = 'toc.ncx',
  bool writeNcxFile = true,
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
      '<item id="$navId" href="Nav/toc.xhtml" '
          'media-type="application/xhtml+xml"'
          '${navProperties.isEmpty ? '' : ' properties="$navProperties"'}/>',
    if (ncx != null)
      '<item id="ncx" href="$ncxHref" '
          'media-type="$ncxMediaType"/>',
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
  if (ncx != null && writeNcxFile) {
    files['OPS/$ncxHref'] = '<?xml version="1.0"?>$ncx';
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
