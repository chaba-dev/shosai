import 'dart:io';
import 'dart:typed_data';

import 'package:shosai_epub/shosai_epub.dart';
import 'package:test/test.dart';

/// Ports of production Rust parser assertions
/// (`crates/shosai-core/src/epub/render.rs` tests) plus fixture checks.
///
/// Every expectation marked "Rust:" is copied from the Rust test of the same
/// name. A ported case that deliberately differs is marked and asserted for the
/// prototype's documented behaviour instead.
void main() {
  NormalizedChapter parse(String xhtml) => normalizeChapter(
    xhtml: xhtml,
    chapterPath: 'OPS/chapter.xhtml',
    stylesheets: const [],
    limits: const EpubLimits(),
  );

  group('canonical stream and anchors', () {
    test('chapter anchors follow search text character offsets', () {
      final parsed = parse(
        '<html><body>\n'
        '  <p>before</p>\n'
        '  <section id="section"><p id="second">alpha '
        '<a name="middle"></a>beta <span id="target">gamma</span></p></section>\n'
        '  <p><span id="duplicate">first</span></p>\n'
        '  <p id="duplicate">second</p>\n'
        '  <p style="display:none" id="hidden">hidden</p>\n'
        '</body></html>',
      );
      // Rust: "before\nalpha beta gamma\nfirst\nsecond\n"
      expect(
        extractCanonicalText(parsed.nodes),
        'before\nalpha beta gamma\nfirst\nsecond\n',
      );
      expect(parsed.anchors['section'], 7);
      expect(parsed.anchors['second'], 7);
      expect(parsed.anchors['middle'], 13);
      expect(parsed.anchors['target'], 18);
      expect(parsed.anchors['duplicate'], 24);
      expect(parsed.anchors.containsKey('hidden'), isFalse);
    });

    test('chapter anchors cover headings lists and table cells', () {
      final parsed = parse(
        '<html><body>\n'
        '  <h1><span id="heading">title</span></h1>\n'
        '  <ul><li id="first-item">one</li><li><span id="second-item">two</span></li></ul>\n'
        '  <table><tr><td id="cell">cell</td><td>other</td></tr></table>\n'
        '</body></html>',
      );
      // Rust: "title\none\ntwo\n\ncell\tother\n\n"
      expect(
        extractCanonicalText(parsed.nodes),
        'title\none\ntwo\n\ncell\tother\n\n',
      );
      expect(parsed.anchors['heading'], 0);
      expect(parsed.anchors['first-item'], 6);
      expect(parsed.anchors['second-item'], 10);
      expect(parsed.anchors['cell'], 15);
    });

    test('chapter anchors include body empty markers and table descendants', () {
      final parsed = parse(
        '<html><body id="body-top">\n'
        '  <a id="empty-marker" name="legacy-marker"></a><p id="empty-paragraph"></p>\n'
        '  <p>before</p>\n'
        '  <table><caption id="caption"><span id="caption-child">cap</span></caption>\n'
        '    <tr id="row"><td><span id="cell-child">cell</span></td></tr>\n'
        '  </table>\n'
        '</body></html>',
      );
      // Rust: "before\ncap\ncell\n\n"
      expect(extractCanonicalText(parsed.nodes), 'before\ncap\ncell\n\n');
      for (final anchor in [
        'body-top',
        'empty-marker',
        'legacy-marker',
        'empty-paragraph',
      ]) {
        expect(parsed.anchors[anchor], 0, reason: anchor);
      }
      expect(parsed.anchors['caption'], 7);
      expect(parsed.anchors['caption-child'], 7);
      expect(parsed.anchors['row'], 11);
      expect(parsed.anchors['cell-child'], 11);
    });

    test('display-block math separators are a documented deviation', () {
      final parsed = parse(
        '<html xmlns:m="http://www.w3.org/1998/Math/MathML"><body>\n'
        '  <p>before <m:math id="formula" display="block"><m:mfrac><m:mi>a</m:mi>'
        '<m:mi>b</m:mi></m:mfrac></m:math> after <span id="tail">tail</span></p>\n'
        '</body></html>',
      );
      // Rust promotes block math to its own node and inserts separators,
      // producing "before \n(a)/(b)\n after tail\n" with formula=8, tail=23.
      // The prototype keeps inline math inside the paragraph and does not
      // promote separators (see README "documented deviations").
      expect(extractCanonicalText(parsed.nodes), 'before (a)/(b) after tail\n');
      expect(parsed.anchors['formula'], 7);
      expect(parsed.anchors['tail'], 21);
    }, skip: false);

    test('canonical builder output equals the direct extraction port', () {
      final parsed = parse(
        '<html><body><h1>Title</h1><p>one <strong>two</strong></p>'
        '<ul><li>a</li><li>b</li></ul>'
        '<figure><img src="i.png" alt="Alt text"/><figcaption>Cap</figcaption></figure>'
        '</body></html>',
      );
      expect(
        extractCanonicalText(parsed.nodes),
        'Title\none two\na\nb\n\nAlt text\nCap\n',
      );
    });
  });

  group('tables', () {
    test('cell separators and block starts match the Rust extraction', () {
      final parsed = parse(
        '<html><body><table><caption>Quarterly results</caption>'
        '<thead><tr><th scope="col">Quarter</th><th scope="col">Value</th></tr></thead>'
        '<tbody><tr><th scope="row" rowspan="2">First half</th>'
        '<td><a href="#spanning-table">Q1 link</a></td></tr>'
        '<tr><td><img src="../Images/pixel.png" alt="Q2 chart"/></td></tr>'
        '<tr><td colspan="2"><p>Nested cell paragraph</p></td></tr></tbody></table>'
        '</body></html>',
      );
      final text = extractCanonicalText(parsed.nodes);
      expect(text, contains('Quarter\tValue'));
      expect(text, contains('First half\tQ1 link'));
      expect(text, contains('Q2 chart'));
      final table = parsed.nodes.single as EpubTable;
      expect(
        table.caption.map((span) => span.text).join(),
        'Quarterly results',
      );
      expect(table.rowGroups.first.kind, EpubTableRowGroupKind.head);
      expect(table.rowGroups[1].rows[0].cells[0].rowSpan, 2);
      expect(table.rowGroups[1].rows[2].cells[0].columnSpan, 2);
      // A cell's first block never opens a separator; the Rust extraction adds
      // a newline only before subsequent blocks.
      expect(table.rowGroups[1].rows[2].cells[0].blockStarts, isEmpty);
    });
  });

  group('MathML fallback', () {
    test('fallbacks match the production bounded rendering', () {
      final parsed = parse(
        '<html xmlns:m="http://www.w3.org/1998/Math/MathML"><body><main>'
        '<p>Inline <m:math id="fraction" alttext="one half"><m:mfrac><m:mn>1</m:mn>'
        '<m:mn>2</m:mn></m:mfrac></m:math>.</p>'
        '<m:math id="display-root" display="block" alttext="cube root of x">'
        '<m:mroot><m:mi>x</m:mi><m:mn>3</m:mn></m:mroot></m:math>'
        '<m:math id="scripts"><m:msubsup><m:mi>x</m:mi><m:mn>1</m:mn><m:mn>2</m:mn>'
        '</m:msubsup></m:math>'
        '<m:math id="annotated"><m:semantics><m:mi>π</m:mi>'
        '<m:annotation encoding="application/x-tex">\\pi</m:annotation></m:semantics></m:math>'
        '</main></body></html>',
      );
      final text = extractCanonicalText(parsed.nodes);
      expect(text, contains('root(x, 3)'));
      expect(text, contains('x_1^2'));
      expect(text, contains('π'));
      expect(text, isNot(contains(r'\pi')));
    });
  });

  group('fixtures', () {
    final fixtureRoot = Directory(
      '../../../../crates/shosai-core/tests/fixtures/epub-conformance',
    );

    Uint8List fixture(String name) =>
        Uint8List.fromList(File('${fixtureRoot.path}/$name').readAsBytesSync());

    test('bidi fixture renders RTL paragraphs and preserves mixed text', () {
      final book = openEpubBytes(fixture('bidi.epub'));
      final chapter = book.chapters.single;
      expect(chapter.canonicalText, contains('שלום 123 English'));
      expect(chapter.canonicalText, contains('مَرْحَبًا 456 Latin'));
      expect(chapter.canonicalText, contains('日本語'));
      final paragraphs = chapter.blocks.whereType<EpubParagraph>().toList();
      final hebrew = paragraphs.firstWhere(
        (paragraph) => paragraph.spans.first.text.contains('שלום'),
      );
      expect(hebrew.nodeStyle.direction, EpubDirection.rtl);
    });

    test('table fixture keeps semantic rows, spans and captions', () {
      final book = openEpubBytes(fixture('table.epub'));
      final table = book.chapters.single.blocks.whereType<EpubTable>().first;
      expect(table.caption.isNotEmpty, isTrue);
      expect(table.rowGroups, isNotEmpty);
      expect(book.chapters.single.canonicalText, contains('Quarter\tValue'));
    });

    test('fonts fixture admits TTF/OTF and reports WOFF as unsupported', () {
      final book = openEpubBytes(fixture('fonts.epub'));
      expect(book.embeddedFonts.keys, contains('FixtureTtf'));
      expect(book.embeddedFonts.keys, contains('FixtureOtf'));
      expect(book.embeddedFonts.keys, isNot(contains('FixtureWoff2')));
      expect(book.warnings.any((warning) => warning.contains('WOFF')), isTrue);
    });

    test('nested-image fixture keeps block image alt text canonical', () {
      final book = openEpubBytes(fixture('nested-image.epub'));
      final text = book.chapters.single.canonicalText;
      expect(text, contains('Block image'));
      expect(text, contains('Figure image'));
      expect(text, contains('Fixture caption'));
      expect(text, contains('Cell image'));
      // The inline alt of an image inside a paragraph is not part of the
      // canonical stream, matching the Rust inline collector; only a
      // block-level image contributes its alt.
      expect(text, isNot(contains('Missing image fallback')));
      expect(text, isNot(contains('Nested diagram')));
    });

    test('malformed chapter markup rejects the document', () {
      // Rust: `malformed-markup` is a rejection fixture; the readable sibling
      // is only reachable when the malformed chapter is not in the spine.
      expect(
        () => openEpubBytes(fixture('malformed-markup.epub')),
        throwsA(isA<EpubFormatError>()),
      );
    });

    test('resource-limits fixture rejects an oversized SVG dimension', () {
      expect(
        () => openEpubBytes(fixture('resource-limits.epub')),
        throwsA(isA<EpubLimitError>()),
      );
    });

    test('duplicate archive entries are rejected', () {
      expect(
        () => openEpubBytes(fixture('duplicate-entries.epub')),
        throwsA(isA<EpubFormatError>()),
      );
    });

    test('conformance fixture parses all eight chapters', () {
      final book = openEpubBytes(fixture('conformance.epub'));
      expect(book.chapters.length, 8);
      expect(book.toc.length, 8);
      expect(book.chapters[2].canonicalText, contains('Quarter\tValue'));
      expect(book.chapters[4].canonicalText, contains('root(x, 3)'));
      expect(book.chapters[5].canonicalText, contains('日本語'));
    });
  });
}
