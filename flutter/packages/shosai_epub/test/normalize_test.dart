import 'dart:io';
import 'dart:typed_data';

import 'package:shosai_epub/shosai_epub.dart';
import 'package:test/test.dart';
import 'package:xml/xml.dart';

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

  /// The bounded MathML parse of [source], the way an XHTML chapter reaches it.
  EpubMath findMath(String source) =>
      parseMath(XmlDocument.parse(source).rootElement, const EpubLimits());

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

    test('display-block math is promoted with the production separators', () {
      final parsed = parse(
        '<html xmlns:m="http://www.w3.org/1998/Math/MathML"><body>\n'
        '  <p>before <m:math id="formula" display="block"><m:mfrac><m:mi>a</m:mi>'
        '<m:mi>b</m:mi></m:mfrac></m:math> after <span id="tail">tail</span></p>\n'
        '</body></html>',
      );
      // Rust: `paragraph_anchor_offsets_include_promoted_display_separators`
      // expects "before \n(a)/(b)\n after tail\n" with formula=8, tail=23.
      // Block math is its own node, the paragraph is split around it, and the
      // canonical stream keeps the generated separators.
      expect(
        extractCanonicalText(parsed.nodes),
        'before \n(a)/(b)\n after tail\n',
      );
      expect(parsed.anchors['formula'], 8);
      expect(parsed.anchors['tail'], 23);
    });

    test(
      'display-block math first in a paragraph keeps the production order',
      () {
        final parsed = parse(
          '<html xmlns:m="http://www.w3.org/1998/Math/MathML"><body>\n'
          '  <p id="lead"><m:math id="first" display="block"><m:msqrt>'
          '<m:mi>x</m:mi></m:msqrt></m:math>after</p>\n'
          '</body></html>',
        );
        expect(extractCanonicalText(parsed.nodes), 'sqrt(x)\nafter\n');
        expect(parsed.anchors['lead'], 0);
        expect(parsed.anchors['first'], 0);
      },
    );

    test('a leading-whitespace paragraph id survives collapsing', () {
      final parsed = parse(
        '<html xmlns:m="http://www.w3.org/1998/Math/MathML"><body>\n'
        '  <p id="lead"> <m:math id="formula" display="block"><m:mi>x</m:mi>'
        '</m:math>after</p>\n'
        '</body></html>',
      );
      // Rust records the paragraph id at the paragraph start (0) even though
      // the leading whitespace span is collapsed away.
      expect(extractCanonicalText(parsed.nodes), 'x\nafter\n');
      expect(parsed.anchors['lead'], 0);
      expect(parsed.anchors['formula'], 0);
    });

    test('a trailing empty marker resolves to the paragraph end', () {
      final parsed = parse(
        '<html><body><p>tail<a id="end"></a></p></body></html>',
      );
      // Rust keeps the marker's source offset: 4 scalars into "tail\n".
      expect(extractCanonicalText(parsed.nodes), 'tail\n');
      expect(parsed.anchors['end'], 4);
    });

    test('a trailing marker after promoted math resolves to the node end', () {
      final parsed = parse(
        '<html xmlns:m="http://www.w3.org/1998/Math/MathML"><body>'
        '<p><m:math display="block"><m:mi>x</m:mi></m:math>tail'
        '<a id="end"></a></p></body></html>',
      );
      // Rust: math node at 0, separator at 1, paragraph "tail" at 2-5, so the
      // trailing marker is 6 — the paragraph end, not the group start.
      expect(extractCanonicalText(parsed.nodes), 'x\ntail\n');
      expect(parsed.anchors['end'], 6);
    });

    test('pending anchors before a line break stay at the paragraph start', () {
      final parsed = parse(
        '<html><body><p id="lead"><a id="marker"></a><br/></p></body></html>',
      );
      // Rust records the paragraph id and the empty marker at their own
      // source offsets (0), not at the end of the emitted newline. The
      // canonical text of `<br/>` itself is a separate, pre-existing
      // difference and is not asserted here.
      expect(parsed.anchors['lead'], 0);
      expect(parsed.anchors['marker'], 0);
    });

    test('inline math stays inside its paragraph', () {
      final parsed = parse(
        '<html xmlns:m="http://www.w3.org/1998/Math/MathML"><body>\n'
        '  <p>value <m:math><m:mi>v</m:mi></m:math> stays inline</p>\n'
        '</body></html>',
      );
      expect(extractCanonicalText(parsed.nodes), 'value v stays inline\n');
    });

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

    test('display-block math inside a cell keeps this port whitespace', () {
      final parsed = parse(
        '<html xmlns:m="http://www.w3.org/1998/Math/MathML"><body><table><tr>'
        '<td><p>before <m:math display="block"><m:mfrac><m:mi>a</m:mi>'
        '<m:mi>b</m:mi></m:mfrac></m:math> after</p></td></tr></table>'
        '</body></html>',
      );
      // Known remaining difference, tracked in the package README: Rust's
      // table collector collapses each text run around display math
      // separately, so it produces "before\n(a)/(b)\nafter\n\n". This port
      // parses the cell paragraph with the chapter rules and keeps the
      // spaces. The separators and the surrounding blocks agree; the run
      // whitespace does not yet. Not accepted parity: the EPUB
      // content-service slice must resolve it before it routes reader content.
      expect(
        extractCanonicalText(parsed.nodes),
        'before \n(a)/(b)\n after\n\n',
      );
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

    // Rust: `crates/shosai-core/src/epub/math.rs`
    // `malformed_supported_constructs_use_source_order_fallback`. A malformed
    // supported construct falls back to its source-order children text; it is
    // not reported as unsupported, and its direct text is preserved.
    test('malformed supported constructs use source-order fallback', () {
      final fraction = findMath(
        '<math xmlns="http://www.w3.org/1998/Math/MathML">'
        '<mfrac>before<mi>a</mi><mi>b</mi>after</mfrac></math>',
      );
      expect(fraction.expression, isNull);
      expect(fraction.fallback, 'before a b after');

      final nestedToken = findMath(
        '<math xmlns="http://www.w3.org/1998/Math/MathML">'
        '<mi>before<mtext>inside</mtext>after</mi></math>',
      );
      expect(nestedToken.expression, isNull);
      expect(nestedToken.fallback, 'before inside after');

      final semanticsText = findMath(
        '<math xmlns="http://www.w3.org/1998/Math/MathML">'
        '<semantics>before<mi>x</mi>'
        '<annotation>ignored</annotation></semantics></math>',
      );
      expect(semanticsText.expression, isNull);
      expect(semanticsText.fallback, '[math expression omitted]');
    });

    // Rust: `malformed_supported_constructs_use_source_order_fallback` covers
    // the same rule for a construct with too few children. The conformance
    // fixture `mathml.epub` chapter 16 carries
    // `<m:mfrac id="malformed-fallback"><m:mn>1</m:mn></m:mfrac>`.
    test('an mfrac missing its denominator falls back to its child', () {
      final fraction = findMath(
        '<math xmlns="http://www.w3.org/1998/Math/MathML">'
        '<mfrac><mn>1</mn></mfrac></math>',
      );
      expect(fraction.expression, isNull);
      expect(fraction.fallback, '1');
    });

    // Rust: `crates/shosai-core/src/epub/math.rs` `trimmed_direct_text_bytes`
    // charges UTF-8 bytes, and the budget also counts the denominator's single
    // byte: 511 two-byte characters fill 1023 of the 1024 bytes and are
    // admitted, while 512 need 1025 and are refused. Counting UTF-16 units
    // would admit the 512-character node.
    test('the visible-text budget counts UTF-8 bytes', () {
      final accepted = findMath(
        '<math xmlns="http://www.w3.org/1998/Math/MathML">'
        '<mfrac><mn>${List.filled(511, 'π').join()}</mn><mn>2</mn></mfrac>'
        '</math>',
      );
      expect(accepted.expression, isNotNull);

      final refused = findMath(
        '<math xmlns="http://www.w3.org/1998/Math/MathML">'
        '<mfrac><mn>${List.filled(512, 'π').join()}</mn><mn>2</mn></mfrac>'
        '</math>',
      );
      expect(refused.expression, isNull);
      expect(refused.fallback, '[math expression omitted]');
    });

    // Rust: `bounded_math_model_retains_supported_structure_and_fallback`.
    test('fenced matrix uses production separators', () {
      final matrix = findMath(
        '<math display="block" xmlns="http://www.w3.org/1998/Math/MathML">'
        '<mfenced><mtable><mtr><mtd><mi>a</mi></mtd>'
        '<mtd><msqrt><mi>b</mi></msqrt></mtd></mtr></mtable></mfenced></math>',
      );
      expect(matrix.display, EpubMathDisplay.block);
      expect(matrix.expression, isNotNull);
      expect(matrix.fallback, '(a sqrt(b))');
    });

    // Rust: `unsupported_fallback_preserves_direct_text_in_source_order` and
    // the `menclose` arm of
    // `unsupported_and_malformed_math_keep_readable_bounded_fallback`. The
    // production fallback joins every row and cell with one space, so a
    // multi-row table has no row separator of its own.
    test(
      'unsupported constructs keep source order and join rows with one space',
      () {
        final unsupported = findMath(
          '<math xmlns="http://www.w3.org/1998/Math/MathML">'
          '<menclose>before<mtext>inside</mtext>after</menclose></math>',
        );
        expect(unsupported.expression, isNull);
        expect(unsupported.fallback, 'before inside after');

        final table = findMath(
          '<math xmlns="http://www.w3.org/1998/Math/MathML"><mtable>'
          '<mtr><mtd><mi>a</mi></mtd><mtd><mi>b</mi></mtd></mtr>'
          '<mtr><mtd><mi>c</mi></mtd><mtd><mi>d</mi></mtd></mtr>'
          '</mtable></math>',
        );
        expect(table.fallback, 'a b c d');
      },
    );
  });

  group('fixtures', () {
    // The package lives under flutter/packages in the repository, but tests
    // must not depend on their own nesting depth: search upward for the
    // committed conformance fixtures.
    final fixtureRoot = _findConformanceFixtures();

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

/// Locates the repository's committed EPUB conformance fixtures by walking up
/// from the test working directory, so the package can move without breaking
/// the fixture path.
Directory _findConformanceFixtures() {
  var directory = Directory.current.absolute;
  while (true) {
    final candidate = Directory(
      '${directory.path}/crates/shosai-core/tests/fixtures/epub-conformance',
    );
    if (candidate.existsSync()) return candidate;
    final parent = directory.parent;
    if (parent.path == directory.path) {
      throw StateError(
        'epub-conformance fixtures not found above ${Directory.current.path}',
      );
    }
    directory = parent;
  }
}
