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

    test('a trailing heading marker resolves to the heading end', () {
      final parsed = parse(
        '<html><body><h1>Text<a id="tail"></a></h1></body></html>',
      );
      // Rust records the marker at its own source offset — 4 scalars into
      // "Text\n", the heading end, not its start. A fragment target must not
      // silently point at the heading's beginning.
      expect(extractCanonicalText(parsed.nodes), 'Text\n');
      expect(parsed.anchors['tail'], 4);
    });

    test('a trailing inline-block marker resolves to the block end', () {
      final parsed = parse(
        '<html><body><span>Text<a id="tail"></a></span></body></html>',
      );
      expect(extractCanonicalText(parsed.nodes), 'Text\n');
      expect(parsed.anchors['tail'], 4);
    });

    test('a trailing caption marker resolves to the caption end', () {
      final parsed = parse(
        '<html><body><figure><img src="i.png" alt="Alt"/>'
        '<figcaption>Cap<a id="tail"></a></figcaption></figure></body></html>',
      );
      // Rust: the image alt is 0-3, its separator 3, the caption 4-7, so the
      // trailing caption marker is 7 — the caption end, not the image start.
      expect(extractCanonicalText(parsed.nodes), 'Alt\nCap\n');
      expect(parsed.anchors['tail'], 7);
    });

    test(
      'a collapsed figure records its image ancestors and image anchors',
      () {
        final parsed = parse(
          '<html><body><figure><a id="image-wrapper">'
          '<img id="image" src="i.png" alt="Diagram"/></a>'
          '<figcaption>Caption</figcaption></figure>'
          '<div id="unrelated">After</div></body></html>',
        );
        // Rust: the wrapper and the image resolve at the image's start; the
        // unrelated sibling does not.
        expect(extractCanonicalText(parsed.nodes), 'Diagram\nCaption\nAfter\n');
        expect(parsed.anchors['image-wrapper'], 0);
        expect(parsed.anchors['image'], 0);
        expect(parsed.anchors['unrelated'], isNot(0));
      },
    );

    test('an empty anchor name never becomes an anchor', () {
      final parsed = parse(
        '<html><body><p>Text</p><a id=""></a></body></html>',
      );
      // Rust's `record_anchor_name` skips an empty name, so `#` can never
      // resolve to the chapter end.
      expect(parsed.anchors.containsKey(''), isFalse);
      expect(parsed.anchors.isEmpty, isTrue);
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

    test('a trailing marker in a list item resolves to the item end', () {
      // Rust: `parse_list_items` records a marker after the item's last text at
      // the item's own offset — before the generated item newline, not at the
      // list's start.
      final single = parse(
        '<html><body><ul><li>Text<a id="x"/></li></ul></body></html>',
      );
      expect(extractCanonicalText(single.nodes), 'Text\n\n');
      expect(single.anchors['x'], 4);

      final first = parse(
        '<html><body><ul><li>a<a id="x"/></li><li>b</li></ul></body></html>',
      );
      expect(extractCanonicalText(first.nodes), 'a\nb\n\n');
      expect(first.anchors['x'], 1);

      final second = parse(
        '<html><body><ul><li>a</li><li>b<a id="y"/></li></ul></body></html>',
      );
      expect(extractCanonicalText(second.nodes), 'a\nb\n\n');
      expect(second.anchors['y'], 3);

      final spaced = parse(
        '<html><body><ul><li>Text <a id="x"/></li></ul></body></html>',
      );
      // The trailing space collapses away, so the marker still resolves at the
      // collapsed item end.
      expect(spaced.anchors['x'], 4);
    });

    test('an empty list item contributes no anchors', () {
      final empty = parse(
        '<html><body><ul><li id="e"></li><li>b</li></ul></body></html>',
      );
      // Rust records an item's own and nested anchors only when the item
      // produced spans; an empty item is not a target.
      expect(extractCanonicalText(empty.nodes), 'b\n\n');
      expect(empty.anchors, isEmpty);

      final onlyEmpty = parse(
        '<html><body><ul><li id="e"></li></ul><p>After</p></body></html>',
      );
      expect(onlyEmpty.anchors, isEmpty);

      final between = parse(
        '<html><body><ul><li>a</li><a id="x"/><li>b</li></ul></body></html>',
      );
      // A marker between items is not an item and is not recorded.
      expect(between.anchors, isEmpty);
    });

    test('an empty item with a marker keeps only the outer anchors', () {
      // The whitespace span consumes the list's id, the marker adds its own,
      // and the collapse re-appends the carried id after it; restoring a
      // snapshot (not truncating by length) keeps `u` and drops `x`, like the
      // production item guard.
      final first = parse(
        '<html><body><ul id="u"><li> <a id="x"/></li><li>b</li></ul>'
        '</body></html>',
      );
      expect(extractCanonicalText(first.nodes), 'b\n\n');
      expect(first.anchors, {'u': 0});

      final only = parse(
        '<html><body><ul id="u"><li> <a id="x"/></li></ul><p>After</p>'
        '</body></html>',
      );
      expect(only.anchors, {'u': 0});
    });

    test('nav uses the production inline path', () {
      // The retained parser falls through to its inline collector for `nav`,
      // so the canonical stream joins the paragraphs and a trailing marker
      // resolves before the generated separator.
      final blocks = parse(
        '<html><body><nav id="n"><p id="p">A</p><p>B</p></nav></body></html>',
      );
      expect(extractCanonicalText(blocks.nodes), 'AB\n');
      expect(blocks.anchors, {'n': 0, 'p': 0});

      final trailing = parse(
        '<html><body><nav><p>A</p><a id="x"/></nav><p>After</p></body></html>',
      );
      expect(extractCanonicalText(trailing.nodes), 'A\nAfter\n');
      expect(trailing.anchors['x'], 1);

      final leading = parse(
        '<html><body><nav id="n"><a id="x"/>A</nav></body></html>',
      );
      expect(leading.anchors, {'n': 0, 'x': 0});

      final empty = parse(
        '<html><body><nav id="n"><a id="x"/></nav><p>After</p></body></html>',
      );
      // An empty nav emits nothing; its anchors resolve at the next position,
      // where the production parser recorded them.
      expect(empty.anchors, {'n': 0, 'x': 0});
    });

    test('a trailing marker after blockquote content resolves to its end', () {
      final parsed = parse(
        '<html><body><blockquote><p>Text</p><a id="x"/></blockquote>'
        '</body></html>',
      );
      // Rust: the marker is recorded after the paragraph's emitted text, so it
      // is 5 scalars into "Text\n", the blockquote's end.
      expect(extractCanonicalText(parsed.nodes), 'Text\n\n');
      expect(parsed.anchors['x'], 5);

      final withSibling = parse(
        '<html><body><blockquote><p>Text</p><a id="x"/></blockquote>'
        '<p>Next</p></body></html>',
      );
      expect(withSibling.anchors['x'], 5);
    });

    test('an empty blockquote keeps its own anchors and drops its content', () {
      final parsed = parse(
        '<html><body><blockquote id="q"><a id="x"/></blockquote>'
        '<p>After</p></body></html>',
      );
      // Rust records the blockquote's own id at its start but never merges the
      // anchors of a blockquote it does not emit, so `#x` must not become a
      // target.
      expect(extractCanonicalText(parsed.nodes), 'After\n');
      expect(parsed.anchors['q'], 0);
      expect(parsed.anchors.containsKey('x'), isFalse);

      // The whitespace variant reorders the pending list (the collapse carries
      // the blockquote's id behind the marker); the snapshot restore still
      // keeps the outer id and drops the marker.
      final whitespace = parse(
        '<html><body><blockquote id="q"><span id="s"> <a id="x"/></span>'
        '</blockquote><p>After</p></body></html>',
      );
      expect(extractCanonicalText(whitespace.nodes), 'After\n');
      expect(whitespace.anchors, {'q': 0});
    });

    test('an inline-display container keeps its own and trailing markers', () {
      final parsed = parse(
        '<html><body><div style="display:inline" id="start">Text'
        '<a id="tail"/></div></body></html>',
      );
      // Rust walks these containers as block children even when their display
      // is inline: the container id is at 0 and the trailing marker at the
      // container's end (5), not at its start.
      expect(extractCanonicalText(parsed.nodes), 'Text\n');
      expect(parsed.anchors['start'], 0);
      expect(parsed.anchors['tail'], 5);

      final withSibling = parse(
        '<html><body><div style="display:inline" id="start">Text'
        '<a id="tail"/></div><p>Next</p></body></html>',
      );
      expect(withSibling.anchors['tail'], 5);

      final nestedBlocks = parse(
        '<html><body><div style="display:inline" id="start"><p>Text</p>'
        '<a id="tail"/></div></body></html>',
      );
      expect(nestedBlocks.anchors['start'], 0);
      expect(nestedBlocks.anchors['tail'], 5);

      final blockChild = parse(
        '<html><body><div id="d" style="display:inline"><p>Text</p></div>'
        '</body></html>',
      );
      expect(blockChild.anchors['d'], 0);
    });

    test('a collapsed figure records the caption element anchor', () {
      final parsed = parse(
        '<html><body><figure><img src="i.png" alt="Alt"/>'
        '<figcaption id="caption">Cap</figcaption></figure></body></html>',
      );
      // Rust records the caption element at `caption_offset` (the alt length
      // plus its separator), 4 scalars into "Alt\nCap\n".
      expect(parsed.anchors['caption'], 4);

      final emptyCaption = parse(
        '<html><body><figure><img src="i.png" alt="Alt"/>'
        '<figcaption id="caption"></figcaption></figure></body></html>',
      );
      // An empty caption emits no separator, so the caption id resolves at the
      // alt end.
      expect(extractCanonicalText(emptyCaption.nodes), 'Alt\n');
      expect(emptyCaption.anchors['caption'], 3);

      final leading = parse(
        '<html><body><figure><img src="i.png" alt="Alt"/>'
        '<figcaption id="caption"><a id="lead"/>Cap</figcaption></figure>'
        '</body></html>',
      );
      expect(leading.anchors['caption'], 4);
      expect(leading.anchors['lead'], 4);

      // A nested marker in an empty caption is discarded with the empty run
      // (the production caption collector clears it); only the caption
      // element's own anchor remains, at the alt end.
      final emptyWithMarker = parse(
        '<html><body><figure><img src="i.png" alt="Alt"/>'
        '<figcaption id="caption"><a id="x"/></figcaption></figure>'
        '</body></html>',
      );
      expect(extractCanonicalText(emptyWithMarker.nodes), 'Alt\n');
      expect(emptyWithMarker.anchors, {'caption': 3});

      final whitespaceWithMarker = parse(
        '<html><body><figure><img src="i.png" alt="Alt"/>'
        '<figcaption id="caption"> <a id="x"/></figcaption></figure>'
        '</body></html>',
      );
      expect(whitespaceWithMarker.anchors, {'caption': 3});
    });

    test('a caption collects its runs like the production collector', () {
      // Port of the Rust test
      // `semantic_caption_collects_mixed_inline_and_block_runs_in_source_order`:
      // each block child is its own run, non-empty runs are joined by a
      // generated newline, and the run-local anchors keep their own offsets.
      final mixed = parse(
        '<html><body><figure><img src="figure.png" alt="Diagram"/>'
        '<figcaption>Lead <strong id="bold">bold</strong>'
        '<p id="block">Block <em id="italic">italic</em></p>'
        '<span id="tail">tail</span></figcaption></figure></body></html>',
      );
      expect(
        extractCanonicalText(mixed.nodes),
        'Diagram\nLead bold\nBlock italic\ntail\n',
      );
      expect(mixed.anchors['bold'], 13);
      expect(mixed.anchors['block'], 18);
      expect(mixed.anchors['italic'], 24);
      expect(mixed.anchors['tail'], 31);

      final twoBlocks = parse(
        '<html><body><figure><img src="i.png" alt="Alt"/>'
        '<figcaption><p>A</p><p>B</p></figcaption></figure></body></html>',
      );
      // Two block runs are joined by one generated newline.
      expect(extractCanonicalText(twoBlocks.nodes), 'Alt\nA\nB\n');

      final emptyMiddle = parse(
        '<html><body><figure><img src="i.png" alt="Alt"/>'
        '<figcaption><p>A</p><p id="x"></p><p>B</p></figcaption></figure>'
        '</body></html>',
      );
      // An empty run contributes neither text nor an extra separator.
      expect(extractCanonicalText(emptyMiddle.nodes), 'Alt\nA\nB\n');
      expect(emptyMiddle.anchors, isEmpty);
    });

    test('an empty caption run drops the anchors it recorded', () {
      final emptyFirst = parse(
        '<html><body><figure><img src="i.png" alt="Alt"/>'
        '<figcaption id="c"><p id="x"></p><p>Cap</p></figcaption></figure>'
        '</body></html>',
      );
      // Rust clears an empty run's anchors, so `x` is not a target even though
      // a later run emits text; the caption element's own anchor stays.
      expect(extractCanonicalText(emptyFirst.nodes), 'Alt\nCap\n');
      expect(emptyFirst.anchors, {'c': 4});

      final emptyLast = parse(
        '<html><body><figure><img src="i.png" alt="Alt"/>'
        '<figcaption id="c"><p>Cap</p><a id="x"/></figcaption></figure>'
        '</body></html>',
      );
      expect(emptyLast.anchors, {'c': 4});

      final blockThenMarker = parse(
        '<html><body><figure><img src="i.png" alt="Alt"/>'
        '<figcaption><p>Cap</p><a id="x"/></figcaption></figure>'
        '</body></html>',
      );
      expect(extractCanonicalText(blockThenMarker.nodes), 'Alt\nCap\n');
      expect(blockThenMarker.anchors, isEmpty);
    });

    test('a standalone caption collects its runs too', () {
      final runs = parse(
        '<html><body><figcaption id="c"><p id="x"></p><p>Cap</p></figcaption>'
        '</body></html>',
      );
      expect(extractCanonicalText(runs.nodes), 'Cap\n');
      expect(runs.anchors, {'c': 0});

      final emptyLast = parse(
        '<html><body><figcaption id="c"><p>Cap</p><a id="x"/></figcaption>'
        '</body></html>',
      );
      expect(extractCanonicalText(emptyLast.nodes), 'Cap\n');
      expect(emptyLast.anchors, {'c': 0});
    });

    test('a non-collapsed figure keeps its trailing markers pending', () {
      final withSibling = parse(
        '<html><body><figure><p>A</p><a id="x"/></figure>'
        '<p>After</p></body></html>',
      );
      // The production figure arm keeps the child walk's offsets, so the
      // marker is 2 — after the paragraph's generated newline, not the
      // figure's start.
      expect(extractCanonicalText(withSibling.nodes), 'A\nAfter\n');
      expect(withSibling.anchors['x'], 2);

      final atEnd = parse(
        '<html><body><figure><p>A</p><a id="x"/></figure></body></html>',
      );
      expect(extractCanonicalText(atEnd.nodes), 'A\n');
      expect(atEnd.anchors['x'], 2);

      final twoChildren = parse(
        '<html><body><figure><p>A</p><p>B</p><a id="x"/></figure>'
        '<p>After</p></body></html>',
      );
      expect(extractCanonicalText(twoChildren.nodes), 'A\nB\nAfter\n');
      expect(twoChildren.anchors['x'], 4);

      final leading = parse(
        '<html><body><figure id="f"><p>A</p></figure></body></html>',
      );
      expect(leading.anchors['f'], 0);

      final empty = parse(
        '<html><body><figure id="f"><a id="x"/></figure><p>After</p>'
        '</body></html>',
      );
      // An empty figure emits nothing; both anchors resolve where it would
      // begin.
      expect(empty.anchors, {'f': 0, 'x': 0});

      final inBlockquote = parse(
        '<html><body><blockquote><figure><p>A</p><a id="x"/></figure>'
        '</blockquote><p>After</p></body></html>',
      );
      expect(extractCanonicalText(inBlockquote.nodes), 'A\n\nAfter\n');
      expect(inBlockquote.anchors['x'], 2);

      final inCell = parse(
        '<html><body><table><tr><td><figure><p>A</p><a id="x"/></figure>'
        '</td></tr></table></body></html>',
      );
      expect(extractCanonicalText(inCell.nodes), 'A\n\n');
      expect(inCell.anchors['x'], 2);

      final inCellWithSibling = parse(
        '<html><body><table><tr><td><figure><p>A</p><a id="x"/></figure>'
        '<p>B</p></td></tr></table></body></html>',
      );
      expect(extractCanonicalText(inCellWithSibling.nodes), 'A\nB\n\n');
      expect(inCellWithSibling.anchors['x'], 2);

      final captionElement = parse(
        '<html><body><figure id="f"><p>A</p><figcaption id="c">Cap'
        '</figcaption></figure><p>After</p></body></html>',
      );
      expect(extractCanonicalText(captionElement.nodes), 'A\nCap\nAfter\n');
      expect(captionElement.anchors['f'], 0);
      expect(captionElement.anchors['c'], 2);
    });

    test('a marker after a trimmed trailing space keeps its raw offset', () {
      // The production boundary map resolves anchors through raw positions:
      // when the trailing space of the last normal span is removed, an anchor
      // recorded at or after it stays one scalar to the right of its collapsed
      // position (clamped to the collapsed length), even inside a span.
      final single = parse(
        '<html><body><p>A <span id="x" style="white-space: pre">B</span></p>'
        '</body></html>',
      );
      expect(extractCanonicalText(single.nodes), 'AB\n');
      expect(single.anchors['x'], 2);

      final two = parse(
        '<html><body><p>A <span id="x" style="white-space:pre">B</span>'
        '<span id="y" style="white-space:pre">C</span></p></body></html>',
      );
      expect(extractCanonicalText(two.nodes), 'ABC\n');
      expect(two.anchors['x'], 2);
      expect(two.anchors['y'], 3);

      final inside = parse(
        '<html><body><p>A <span id="x" style="white-space:pre">BC</span></p>'
        '</body></html>',
      );
      // The mapped position falls inside the surviving span.
      expect(extractCanonicalText(inside.nodes), 'ABC\n');
      expect(inside.anchors['x'], 2);

      final nested = parse(
        '<html><body><p>A <span style="white-space:pre"><em id="x">B</em>C'
        '</span></p></body></html>',
      );
      expect(nested.anchors['x'], 2);

      final trailing = parse(
        '<html><body><p>A <span style="white-space:pre">B</span>'
        '<a id="x"/></p></body></html>',
      );
      expect(trailing.anchors['x'], 2);

      final withSibling = parse(
        '<html><body><p>A <span style="white-space:pre">B</span>'
        '<a id="x"/></p><p>After</p></body></html>',
      );
      expect(extractCanonicalText(withSibling.nodes), 'AB\nAfter\n');
      expect(withSibling.anchors['x'], 2);

      final beforeTrim = parse(
        '<html><body><p>A<span id="y"> </span>'
        '<span id="x" style="white-space:pre">B</span></p></body></html>',
      );
      // A marker before the removed space is not shifted.
      expect(beforeTrim.anchors['x'], 2);
      expect(beforeTrim.anchors['y'], 1);

      final collapsedRun = parse(
        '<html><body><p>A   <span id="x" style="white-space:pre">BC</span>'
        '</p></body></html>',
      );
      expect(collapsedRun.anchors['x'], 2);

      final astral = parse(
        '<html><body><p>A <span id="x" style="white-space:pre">\u{1F600}B'
        '</span></p></body></html>',
      );
      // Canonical positions are scalars, so the astral character counts once.
      expect(extractCanonicalText(astral.nodes), 'A\u{1F600}B\n');
      expect(astral.anchors['x'], 2);

      final heading = parse(
        '<html><body><h1>A <span id="x" style="white-space:pre">B</span>'
        '</h1></body></html>',
      );
      expect(heading.anchors['x'], 2);

      final item = parse(
        '<html><body><ul><li>A <span id="x" style="white-space:pre">B'
        '</span></li></ul></body></html>',
      );
      expect(extractCanonicalText(item.nodes), 'AB\n\n');
      expect(item.anchors['x'], 2);

      final caption = parse(
        '<html><body><figure><img src="i.png" alt="Alt"/>'
        '<figcaption>A <span id="x" style="white-space:pre">B</span>'
        '</figcaption></figure></body></html>',
      );
      expect(extractCanonicalText(caption.nodes), 'Alt\nAB\n');
      expect(caption.anchors['x'], 6);

      final leading = parse(
        '<html><body><p> <span id="x" style="white-space:pre">B</span></p>'
        '</body></html>',
      );
      // No normal span is trimmed, so the marker keeps its collapsed position.
      expect(leading.anchors['x'], 0);

      final preservedPrefix = parse(
        '<html><body><p><span id="x" style="white-space:pre"> B</span></p>'
        '</body></html>',
      );
      expect(extractCanonicalText(preservedPrefix.nodes), ' B\n');
      expect(preservedPrefix.anchors['x'], 0);
    });

    test('a mapped end anchor survives merging and trailing markers', () {
      final merged = parse(
        '<html><body><p>A <span style="white-space:pre">B<span id="x">C</span>'
        '</span></p></body></html>',
      );
      // The mapped position is the end of "C"; merging the preserved spans
      // must not drop it.
      expect(extractCanonicalText(merged.nodes), 'ABC\n');
      expect(merged.anchors['x'], 3);

      final mergedDuplicate = parse(
        '<html><body><p>A <span style="white-space:pre">B<span id="x">C</span>'
        '</span></p><p id="x">After</p></body></html>',
      );
      // A later duplicate must not publish the later position.
      expect(mergedDuplicate.anchors['x'], 3);

      final trailing = parse(
        '<html><body><ul><li>A <span id="x" style="white-space:pre">B</span>'
        '<a id="y"/></li></ul></body></html>',
      );
      // The item's trailing marker joins the mapped end anchor instead of
      // replacing it.
      expect(extractCanonicalText(trailing.nodes), 'AB\n\n');
      expect(trailing.anchors['x'], 2);
      expect(trailing.anchors['y'], 2);

      final caption = parse(
        '<html><body><figure><img src="i.png" alt="Alt"/>'
        '<figcaption>A <span id="x" style="white-space:pre">B</span>'
        '<a id="y"/></figcaption></figure></body></html>',
      );
      expect(extractCanonicalText(caption.nodes), 'Alt\nAB\n');
      expect(caption.anchors['x'], 6);
      expect(caption.anchors['y'], 6);

      final tableCaption = parse(
        '<html><body><table><caption>A '
        '<span id="x" style="white-space:pre">B</span><a id="y"/></caption>'
        '<tr><td>z</td></tr></table></body></html>',
      );
      expect(extractCanonicalText(tableCaption.nodes), 'AB\nz\n\n');
      expect(tableCaption.anchors['x'], 2);
      expect(tableCaption.anchors['y'], 2);

      final twoEnds = parse(
        '<html><body><p>A <span style="white-space:pre">B<span id="x">C</span>'
        '<span id="y">D</span></span></p></body></html>',
      );
      expect(extractCanonicalText(twoEnds.nodes), 'ABCD\n');
      expect(twoEnds.anchors['x'], 3);
      expect(twoEnds.anchors['y'], 4);
    });

    test('an owner anchor keeps its provenance against a duplicate', () {
      // The paragraph's own id is pending before its content, so the
      // descendant with the same id must not redefine where it was recorded.
      final paragraph = parse(
        '<html><body><p id="x">A <span id="x" style="white-space:pre">B'
        '</span></p></body></html>',
      );
      expect(extractCanonicalText(paragraph.nodes), 'AB\n');
      expect(paragraph.anchors['x'], 0);

      final item = parse(
        '<html><body><ul><li id="x">A '
        '<span id="x" style="white-space:pre">B</span></li></ul></body></html>',
      );
      expect(extractCanonicalText(item.nodes), 'AB\n\n');
      expect(item.anchors['x'], 0);
    });

    test('a computed-style code block drops its descendants anchors', () {
      // The production block walker treats monospace + preserved whitespace as
      // a code block whatever the tag, and only the element's own anchors stay
      // recorded at its start.
      final samp = parse(
        '<html><body><samp style="white-space:pre">A<a id="x"/>B</samp>'
        '</body></html>',
      );
      expect(extractCanonicalText(samp.nodes), 'AB\n');
      expect(samp.nodes.single, isA<EpubCodeBlock>());
      expect(samp.anchors, isEmpty);

      final duplicate = parse(
        '<html><body><samp style="white-space:pre">A<a id="x"/>B</samp>'
        '<p id="x">After</p></body></html>',
      );
      // The dropped descendant marker must not suppress the later real anchor.
      expect(extractCanonicalText(duplicate.nodes), 'AB\nAfter\n');
      expect(duplicate.anchors['x'], 3);

      final generic = parse(
        '<html><body><span style="font-family:monospace;white-space:pre">'
        'A<a id="x"/>B</span></body></html>',
      );
      expect(generic.anchors, isEmpty);

      final named = parse(
        '<html><body><span style="font-family:\'Courier Mono\';'
        'white-space:pre">A<a id="x"/>B</span></body></html>',
      );
      expect(named.anchors, isEmpty);

      final div = parse(
        '<html><body><div style="font-family:monospace;white-space:pre">'
        'A<a id="x"/>B</div><p>After</p></body></html>',
      );
      expect(extractCanonicalText(div.nodes), 'AB\nAfter\n');
      expect(div.anchors, isEmpty);

      final paragraph = parse(
        '<html><body><p style="font-family:monospace;white-space:pre">'
        'A<a id="x"/>B</p></body></html>',
      );
      expect(paragraph.anchors, isEmpty);

      final serif = parse(
        '<html><body><span style="font-family:serif;white-space:pre">'
        'A<a id="x"/>B</span></body></html>',
      );
      // A non-monospace family is not a code block, so the marker stays.
      expect(extractCanonicalText(serif.nodes), 'AB\n');
      expect(serif.anchors['x'], 1);

      final owner = parse(
        '<html><body><samp id="s" style="white-space:pre">A<a id="x"/>B</samp>'
        '</body></html>',
      );
      // The element's own anchor is kept at its start.
      expect(owner.anchors, {'s': 0});

      final empty = parse(
        '<html><body><samp style="white-space:pre"> </samp>'
        '<p id="x">After</p></body></html>',
      );
      // Whitespace-only content is not a code block and keeps the fallback.
      expect(extractCanonicalText(empty.nodes), ' \nAfter\n');
      expect(empty.anchors['x'], 2);
    });

    test('an inline-only cell keeps the production inline semantics', () {
      // The production table-cell content collector never applies the block
      // walker's code-block conversion, and an inline-only cell's anchors come
      // from the inline collector, so a monospace preserved-whitespace span in
      // a cell keeps its descendant marker.
      final inline = parse(
        '<html><body><table><tr><td><span '
        'style="font-family:monospace;white-space:pre">A<a id="x"/>B</span>'
        '</td></tr></table></body></html>',
      );
      expect(extractCanonicalText(inline.nodes), 'AB\n\n');
      expect(inline.anchors['x'], 1);

      final duplicate = parse(
        '<html><body><table><tr><td><span '
        'style="font-family:monospace;white-space:pre">A<a id="x"/>B</span>'
        '</td></tr></table><p id="x">After</p></body></html>',
      );
      expect(extractCanonicalText(duplicate.nodes), 'AB\n\nAfter\n');
      expect(duplicate.anchors['x'], 1);

      // A cell with block children keeps the block walk, which the production
      // anchor pass does use: the conversion applies to the block child.
      final block = parse(
        '<html><body><table><tr><td><p '
        'style="font-family:monospace;white-space:pre">A<a id="x"/>B</p>'
        '</td></tr></table><p id="x">After</p></body></html>',
      );
      expect(extractCanonicalText(block.nodes), 'AB\n\nAfter\n');
      expect(block.anchors['x'], 4);
    });

    test('white-space keywords follow the production preserving set', () {
      // `pre-line` is not preserving (and overrides an inherited role);
      // `break-spaces` is.
      final preLine = parse(
        '<html><body><span style="font-family:monospace;white-space:pre-line">'
        'A<a id="x"/>B</span><p id="x">After</p></body></html>',
      );
      expect(extractCanonicalText(preLine.nodes), 'AB\nAfter\n');
      expect(preLine.anchors['x'], 1);

      final breakSpaces = parse(
        '<html><body><span '
        'style="font-family:monospace;white-space:break-spaces">'
        'A<a id="x"/>B</span><p id="x">After</p></body></html>',
      );
      expect(extractCanonicalText(breakSpaces.nodes), 'AB\nAfter\n');
      expect(breakSpaces.anchors['x'], 3);
    });

    test('font-family escapes and importance follow the production parser', () {
      // A CSS escape decodes before the monospace role is derived.
      final escaped = parse(
        '<html><body><span style="font-family:\'\\4d ono\';white-space:pre">'
        'A<a id="x"/>B</span><p id="x">After</p></body></html>',
      );
      expect(extractCanonicalText(escaped.nodes), 'AB\nAfter\n');
      expect(escaped.anchors['x'], 3);

      final familyName = parse(
        '<html><body><span style="font-family:\'\\4d ono\'">text</span>'
        '</body></html>',
      );
      // The decoded family name reaches the span, not the raw escape.
      final span = (familyName.nodes.single as EpubParagraph).spans.single;
      expect(span.fontFamily, 'Mono');

      // `!` with whitespace before `important` is important in both
      // declarations, so the later monospace declaration wins.
      final importance = parse(
        '<html><body><span style="font-family:serif!important;'
        'font-family:monospace ! important;white-space:pre">A<a id="x"/>B'
        '</span><p id="x">After</p></body></html>',
      );
      expect(extractCanonicalText(importance.nodes), 'AB\nAfter\n');
      expect(importance.anchors['x'], 3);

      // A comment is not family text, so it cannot derive a monospace role.
      final comment = parse(
        '<html><body><span style="font-family:serif /* mono */;'
        'white-space:pre">A<a id="x"/>B</span><p id="x">After</p>'
        '</body></html>',
      );
      expect(comment.anchors['x'], 1);

      // A trailing comment and an escaped `important` identifier are both
      // recognized.
      final commentedImportant = parse(
        '<html><body><span style="font-family:serif!important;'
        'font-family:monospace!important/**/;white-space:pre">A<a id="x"/>B'
        '</span><p id="x">After</p></body></html>',
      );
      expect(commentedImportant.anchors['x'], 3);

      final escapedImportant = parse(
        '<html><body><span style="font-family:serif!important;'
        'font-family:monospace !\\69mportant;white-space:pre">A<a id="x"/>B'
        '</span><p id="x">After</p></body></html>',
      );
      expect(escapedImportant.anchors['x'], 3);

      // A quoted generic-looking name is a named family, not the generic role.
      final quotedGeneric = parse(
        '<html><body><span style="font-family:\'math\'">text</span>'
        '</body></html>',
      );
      expect(
        (quotedGeneric.nodes.single as EpubParagraph).spans.single.fontFamily,
        'math',
      );
    });

    test('a quoted family does not continue across a raw newline inline', () {
      // The production inline parser terminates the quoted value at a raw
      // newline, so the declaration derives no monospace role; the stylesheet
      // parser continues the line and does.
      final inline = parse(
        '<html><body><span style="font-family:\'mo\\\nno\';white-space:pre">'
        'A<a id="x"/>B</span><p id="x">After</p></body></html>',
      );
      expect(inline.anchors['x'], 1);

      final stylesheet = normalizeChapter(
        xhtml:
            '<html><body><span>A<a id="x"/>B</span><p id="x">After</p>'
            '</body></html>',
        chapterPath: 'OPS/chapter.xhtml',
        stylesheets: [
          CssStylesheet.parse(
            'span{font-family:\'mo\\\nno\';white-space:pre}',
            const EpubLimits(),
          ),
        ],
        limits: const EpubLimits(),
      );
      expect(stylesheet.anchors['x'], 3);
    });

    test('CSS comment and declaration boundaries follow the tokenizer', () {
      // A `;` inside a quoted family does not end the declaration, so the
      // family keeps its `mono` and the span stays a code block.
      final quotedSemicolon = parse(
        '<html><body><span style="font-family:\'a;mono\';white-space:pre">'
        'A<a id="x"/>B</span><p id="x">After</p></body></html>',
      );
      expect(quotedSemicolon.anchors['x'], 3);

      // A comment separates tokens: `mo/**/no` is one family named "mo no",
      // not the family `mono`.
      final inlineComment = parse(
        '<html><body><span style="font-family:mo/**/no;white-space:pre">'
        'A<a id="x"/>B</span><p id="x">After</p></body></html>',
      );
      expect(inlineComment.anchors['x'], 1);

      // A comment marker inside a quoted family is string content, so the
      // family is `/*mono*/` and the span is a code block.
      final stylesheet = normalizeChapter(
        xhtml:
            '<html><body><span>A<a id="x"/>B</span><p id="x">After</p>'
            '</body></html>',
        chapterPath: 'OPS/chapter.xhtml',
        stylesheets: [
          CssStylesheet.parse(
            "span{font-family:'/*mono*/';white-space:pre}",
            const EpubLimits(),
          ),
        ],
        limits: const EpubLimits(),
      );
      expect(stylesheet.anchors['x'], 3);

      // The same boundary rule applies to a stylesheet's declarations.
      final sheetComment = normalizeChapter(
        xhtml:
            '<html><body><span>A<a id="x"/>B</span><p id="x">After</p>'
            '</body></html>',
        chapterPath: 'OPS/chapter.xhtml',
        stylesheets: [
          CssStylesheet.parse(
            'span{font-family:mo/**/no;white-space:pre}',
            const EpubLimits(),
          ),
        ],
        limits: const EpubLimits(),
      );
      expect(sheetComment.anchors['x'], 1);

      // An unterminated quoted value keeps its family text but not its
      // `!important` flag, and the trailing `white-space:pre` stays inside the
      // string, so the span is never a code block on its own.
      final unterminated = parse(
        '<html><body><span style="font-family:\'mono!important;white-space:pre">'
        'A<a id="x"/>B</span><p id="x">After</p></body></html>',
      );
      expect(unterminated.anchors['x'], 1);

      // A quoted `;` in a stylesheet declaration is string content too.
      final sheetQuotedSemicolon = normalizeChapter(
        xhtml:
            '<html><body><span>A<a id="x"/>B</span><p id="x">After</p>'
            '</body></html>',
        chapterPath: 'OPS/chapter.xhtml',
        stylesheets: [
          CssStylesheet.parse(
            "span{font-family:'a;mono';white-space:pre}",
            const EpubLimits(),
          ),
        ],
        limits: const EpubLimits(),
      );
      expect(sheetQuotedSemicolon.anchors['x'], 3);

      // A quoted string in a rule body is one token: braces inside it are
      // content, so the rule's real `}` still closes it, and an escaped quote
      // does not end the string. The production parser keeps the family, so
      // the span is a code block in each case.
      for (final value in ["'/*{*/mono'", "'a}b;mono'", r"'a\'}mono'"]) {
        final quotedBrace = normalizeChapter(
          xhtml:
              '<html><body><span>A<a id="x"/>B</span><p id="x">After</p>'
              '</body></html>',
          chapterPath: 'OPS/chapter.xhtml',
          stylesheets: [
            CssStylesheet.parse(
              'span{font-family:$value;white-space:pre}',
              const EpubLimits(),
            ),
          ],
          limits: const EpubLimits(),
        );
        expect(quotedBrace.anchors['x'], 3, reason: value);
      }

      // A quoted brace in a selector is string content too: the unsupported
      // selector is skipped, but the rules after it must survive.
      final selectorBrace = normalizeChapter(
        xhtml:
            '<html><body><span>A<a id="x"/>B</span><p id="x">After</p>'
            '</body></html>',
        chapterPath: 'OPS/chapter.xhtml',
        stylesheets: [
          CssStylesheet.parse(
            'span[title="{"]{color:red} span{font-family:mono;white-space:pre}',
            const EpubLimits(),
          ),
        ],
        limits: const EpubLimits(),
      );
      expect(selectorBrace.anchors['x'], 3);

      // The standard chapter against one stylesheet, for the sheet cases below.
      NormalizedChapter againstSheet(String sheet) => normalizeChapter(
        xhtml:
            '<html><body><span>A<a id="x"/>B</span><p id="x">After</p>'
            '</body></html>',
        chapterPath: 'OPS/chapter.xhtml',
        stylesheets: [CssStylesheet.parse(sheet, const EpubLimits())],
        limits: const EpubLimits(),
      );

      // An escaped quote outside a string is content: it must not open a
      // string, so the rules after it survive.
      expect(
        againstSheet(
          r'span[title=a\"b]{color:red} span{font-family:mono;white-space:pre}',
        ).anchors['x'],
        3,
      );
      expect(
        againstSheet(
          r'@media screen { span[title=a\"b]{color:red} } '
          r'span{font-family:mono;white-space:pre}',
        ).anchors['x'],
        3,
      );
      // A comment after an escaped quote is still a comment.
      expect(
        againstSheet(
          r'span{font-family:a\"b} /* c */ '
          r'span{font-family:mono;white-space:pre}',
        ).anchors['x'],
        3,
      );
      // An escaped `;` stays in its declaration, so the family is `a;mono`.
      expect(
        againstSheet(r'span{font-family:a\;mono;white-space:pre}').anchors['x'],
        3,
      );

      // An unterminated quoted value keeps its family text but never its
      // `!important` flag: the family derives monospace when nothing important
      // competes, and a stylesheet's `!important` family wins when one does —
      // like the production parser, which drops the flag, not the declaration.
      NormalizedChapter inlineAgainst(String style, String sheet) =>
          normalizeChapter(
            xhtml:
                '<html><body><span style="$style">A<a id="x"/>B</span>'
                '<p id="x">After</p></body></html>',
            chapterPath: 'OPS/chapter.xhtml',
            stylesheets: [CssStylesheet.parse(sheet, const EpubLimits())],
            limits: const EpubLimits(),
          );
      expect(
        inlineAgainst(
          "font-family:'mono!important",
          'span{font-family:serif;white-space:pre}',
        ).anchors['x'],
        3,
      );
      expect(
        inlineAgainst(
          "font-family:'mono!important",
          'span{font-family:serif!important;white-space:pre}',
        ).anchors['x'],
        1,
      );
      // An escaped `!` is identifier content, so the declaration is not
      // important and the sheet's important monospace family wins.
      expect(
        inlineAgainst(
          r'font-family:a\!important',
          'span{font-family:mono!important;white-space:pre}',
        ).anchors['x'],
        3,
      );
    });

    test('an inline-only cell collects anchors through the inline walk', () {
      // The retained inline-cell anchor stream is the inline collector, so the
      // block walker's code-block and list-item rules do not apply to the
      // cell's descendants.
      final code = parse(
        '<html><body><table><tr><td><code>A<a id="x"/>B</code></td></tr>'
        '</table></body></html>',
      );
      expect(extractCanonicalText(code.nodes), 'AB\n\n');
      expect(code.anchors['x'], 1);

      final codeDuplicate = parse(
        '<html><body><table><tr><td><code>A<a id="x"/>B</code></td></tr>'
        '</table><p id="x">After</p></body></html>',
      );
      expect(extractCanonicalText(codeDuplicate.nodes), 'AB\n\nAfter\n');
      expect(codeDuplicate.anchors['x'], 1);

      final inlineList = parse(
        '<html><body><table><tr><td>'
        '<ul style="display:inline"><li id="x"/></ul><span>AB</span>'
        '</td></tr></table><p id="x">After</p></body></html>',
      );
      // The empty item's anchor is kept at the cell start, like the inline
      // collector, not discarded by the block list rule.
      expect(extractCanonicalText(inlineList.nodes), 'AB\n\nAfter\n');
      expect(inlineList.anchors['x'], 0);

      final link = parse(
        '<html><body><table><tr><td><a id="x">link</a></td></tr></table>'
        '</body></html>',
      );
      expect(link.anchors['x'], 0);

      final mixed = parse(
        '<html><body><table><tr><td>one <span>two</span></td></tr></table>'
        '</body></html>',
      );
      // Text and inline children join into one paragraph, like the retained
      // inline collector.
      expect(extractCanonicalText(mixed.nodes), 'one two\n\n');

      final spanAnchor = parse(
        '<html><body><table><tr><td><span id="s">cell</span></td></tr>'
        '</table></body></html>',
      );
      expect(spanAnchor.anchors['s'], 0);
    });

    test('an inline-only cell with media drops unverifiable anchors', () {
      // The retained anchor stream for such a cell ignores image alt text and
      // treats MathML as spans, so it cannot be reproduced from the rendered
      // content: the cell keeps its content and drops the descendant anchors
      // instead of publishing an offset it cannot verify.
      final image = parse(
        '<html><body><table><tr><td id="c">'
        '<img src="i.png" alt="Alt"/><a id="x"/>B</td></tr></table>'
        '</body></html>',
      );
      expect(extractCanonicalText(image.nodes), contains('Alt'));
      expect(image.anchors['c'], 0);
      expect(image.anchors.containsKey('x'), isFalse);

      final trailing = parse(
        '<html><body><table><tr><td><img src="i.png" alt="Alt"/>B'
        '<a id="x"/></td></tr></table></body></html>',
      );
      expect(trailing.anchors.containsKey('x'), isFalse);

      final math = parse(
        '<html xmlns:m="http://www.w3.org/1998/Math/MathML"><body>'
        '<table><tr><td><m:math><m:mi>x</m:mi></m:math><a id="x"/>B</td></tr>'
        '</table></body></html>',
      );
      expect(math.anchors.containsKey('x'), isFalse);
    });

    test('a media-cell name is not republished by a duplicate', () {
      // The suppressed walk reserves the name for the whole chapter: a later
      // or earlier duplicate must not become the target the retained parser
      // would not have chosen, so the name is dropped even where another
      // element carries it.
      final laterDuplicate = parse(
        '<html><body><table><tr><td><img src="i.png" alt="Alt"/>'
        '<a id="x"/></td></tr></table><p id="x">After</p></body></html>',
      );
      expect(extractCanonicalText(laterDuplicate.nodes), contains('After'));
      expect(laterDuplicate.anchors.containsKey('x'), isFalse);

      final earlierDuplicate = parse(
        '<html><body><p id="x">Before</p><table><tr><td>'
        '<img src="i.png" alt="Alt"/><a id="x"/></td></tr></table>'
        '</body></html>',
      );
      expect(extractCanonicalText(earlierDuplicate.nodes), contains('Before'));
      expect(earlierDuplicate.anchors.containsKey('x'), isFalse);

      // A name the suppressed walk never saw is untouched.
      final sibling = parse(
        '<html><body><table><tr><td><img src="i.png" alt="Alt"/>'
        '<a id="y"/></td></tr></table><p id="x">After</p></body></html>',
      );
      expect(sibling.anchors.containsKey('y'), isFalse);
      expect(sibling.anchors['x'], isNotNull);

      // A duplicate that emits no content is recorded by the chapter-end
      // fallback, which must not republish a suppressed name either.
      final unresolvedDuplicate = parse(
        '<html><body><table><tr><td><img src="i.png" alt="Alt"/>'
        '<a id="x"/></td></tr></table><a id="x"/></body></html>',
      );
      expect(unresolvedDuplicate.anchors.containsKey('x'), isFalse);
    });

    test('an empty standalone figcaption drops its nested anchors', () {
      final parsed = parse(
        '<html><body><figcaption id="c"><a id="x"/></figcaption>'
        '<p>After</p></body></html>',
      );
      // The production caption-run collector discards the anchors of a run
      // that emits nothing; the caption element's own anchor resolves where the
      // empty figcaption would begin.
      expect(extractCanonicalText(parsed.nodes), 'After\n');
      expect(parsed.anchors, {'c': 0});

      final whitespace = parse(
        '<html><body><figcaption id="c"> <a id="x"/></figcaption>'
        '<p>After</p></body></html>',
      );
      expect(whitespace.anchors, {'c': 0});
    });

    test('an unemitted table drops its caption anchors', () {
      final parsed = parse(
        '<html><body><table id="t"><caption id="c"></caption></table>'
        '<p>After</p></body></html>',
      );
      // Rust only computes table anchors for a table it emits, so the caption
      // id is not a target; the table's own id stays at its start.
      expect(extractCanonicalText(parsed.nodes), 'After\n');
      expect(parsed.anchors['t'], 0);
      expect(parsed.anchors.containsKey('c'), isFalse);

      final whitespace = parse(
        '<html><body><table id="t"><caption id="c"> <a id="x"/></caption>'
        '</table><p>After</p></body></html>',
      );
      expect(extractCanonicalText(whitespace.nodes), 'After\n');
      expect(whitespace.anchors, {'t': 0});
    });

    test('anchor admission counts UTF-8 bytes and control characters', () {
      String nameOf(String name) =>
          '<html><body><p id="$name">Text</p></body></html>';
      // 341 three-byte characters are 1,023 bytes and admitted; 342 are 1,026
      // and refused, exactly like the production 1,024-byte limit. Counting
      // UTF-16 units would admit all of them.
      expect(parse(nameOf('あ' * 341)).anchors.length, 1);
      expect(parse(nameOf('あ' * 342)).anchors, isEmpty);
      // A name of exactly 1,024 bytes is admitted.
      expect(parse(nameOf('${'あ' * 341}b')).anchors.length, 1);
      // C1 controls (Unicode category Cc) are refused like C0 controls.
      expect(parse(nameOf('a\u0085b')).anchors, isEmpty);
      expect(parse(nameOf('a\u007fb')).anchors, isEmpty);
    });

    test('the anchor ceiling also bounds unresolved markers', () {
      final markers = StringBuffer('<html><body><p>Text</p>');
      for (var index = 0; index < 4100; index++) {
        markers.write('<a id="u$index"></a>');
      }
      markers.write('</body></html>');
      final parsed = parse(markers.toString());
      // Rust's `record_anchor_name` stops admitting names once the chapter has
      // 4,096 anchors, including the unresolved ones.
      expect(parsed.anchors.length, 4096);
      expect(parsed.anchors['u0'], 5);
      expect(parsed.anchors.containsKey('u4099'), isFalse);
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

    test(
      'a trailing marker after inline cell content resolves to the cell end',
      () {
        final parsed = parse(
          '<html><body><table><tr><td>Text<a id="x"/></td></tr></table>'
          '</body></html>',
        );
        // Rust: an inline cell's trailing marker is recorded at the cell's own
        // text offset, 4 scalars into "Text\n\n" — the cell end, not the table
        // start.
        expect(extractCanonicalText(parsed.nodes), 'Text\n\n');
        expect(parsed.anchors['x'], 4);
      },
    );

    test('a trailing marker after block cell content uses the block offset', () {
      final single = parse(
        '<html><body><table><tr><td><p>Text</p><a id="x"/></td></tr></table>'
        '</body></html>',
      );
      // Rust's per-block accounting counts one generated newline per emitted
      // block, so the marker is one scalar past the cell text (5).
      expect(extractCanonicalText(single.nodes), 'Text\n\n');
      expect(single.anchors['x'], 5);

      final multi = parse(
        '<html><body><table><tr><td><p>a</p><p>b</p><a id="x"/></td></tr>'
        '</table></body></html>',
      );
      expect(extractCanonicalText(multi.nodes), 'a\nb\n\n');
      expect(multi.anchors['x'], 4);

      final notLastCell = parse(
        '<html><body><table><tr><td><p>a</p><a id="x"/></td>'
        '<td>Other<a id="y"/></td></tr></table></body></html>',
      );
      // The block cell's marker lands on the next cell's start (2); the inline
      // cell's lands at its own text end (7).
      expect(extractCanonicalText(notLastCell.nodes), 'a\tOther\n\n');
      expect(notLastCell.anchors['x'], 2);
      expect(notLastCell.anchors['y'], 7);

      final emptyBlock = parse(
        '<html><body><table><tr><td><p></p><a id="x"/></td></tr></table>'
        '</body></html>',
      );
      // An empty block emits no node and therefore no newline: the marker is at
      // the cell start.
      expect(emptyBlock.anchors['x'], 0);

      final hiddenBlock = parse(
        '<html><body><table><tr><td><p style="display:none">h</p><p>a</p>'
        '<a id="x"/></td></tr></table></body></html>',
      );
      expect(hiddenBlock.anchors['x'], 2);
    });

    test('a table caption trailing marker resolves at the caption end', () {
      final withRow = parse(
        '<html><body><table><caption>Cap<a id="x"/></caption>'
        '<tr><td>A</td></tr></table></body></html>',
      );
      // Rust records the caption's own inline offsets before it advances past
      // the caption separator, so the marker is 3 — the caption end, not the
      // first cell's start (4).
      expect(extractCanonicalText(withRow.nodes), 'Cap\nA\n\n');
      expect(withRow.anchors['x'], 3);

      final captionOnly = parse(
        '<html><body><table><caption>Cap<a id="x"/></caption></table>'
        '</body></html>',
      );
      // With no rows the table is still emitted (the caption has text), and
      // the marker must not fall back to the table start.
      expect(extractCanonicalText(captionOnly.nodes), 'Cap\n\n');
      expect(captionOnly.anchors['x'], 3);

      final multi = parse(
        '<html><body><table><caption>Cap<a id="x"/>More<a id="y"/></caption>'
        '<tr><td>A</td></tr></table></body></html>',
      );
      // A marker before further caption text keeps its own offset (3); only the
      // trailing one resolves at the caption end (7).
      expect(extractCanonicalText(multi.nodes), 'CapMore\nA\n\n');
      expect(multi.anchors['x'], 3);
      expect(multi.anchors['y'], 7);

      final emptyCaption = parse(
        '<html><body><table><caption id="c"><a id="x"/></caption>'
        '<tr><td>A</td></tr></table></body></html>',
      );
      // An empty table caption is different from an empty figure caption: the
      // production table collector records its nested anchors at offset 0.
      expect(emptyCaption.anchors, {'c': 0, 'x': 0});
    });

    test('cell and row anchors resolve at their own offsets', () {
      final emptyCell = parse(
        '<html><body><table><tr><td id="e"></td><td>b</td></tr></table>'
        '</body></html>',
      );
      // Rust records the empty cell's id at the offset where the cell begins —
      // the tab position (0) — not at the next cell's content.
      expect(extractCanonicalText(emptyCell.nodes), '\tb\n\n');
      expect(emptyCell.anchors['e'], 0);

      final onlyCell = parse(
        '<html><body><table><tr><td id="e"></td></tr></table></body></html>',
      );
      expect(onlyCell.anchors['e'], 0);

      final rowAndCell = parse(
        '<html><body><table><tr id="r"><td id="c">b</td></tr></table>'
        '</body></html>',
      );
      expect(rowAndCell.anchors['r'], 0);
      expect(rowAndCell.anchors['c'], 0);

      final hidden = parse(
        '<html><body><table><tr id="r"><td style="display:none">x</td></tr>'
        '<tr><td>y</td></tr></table></body></html>',
      );
      // A row with no visible cells is not emitted, so its anchors are dropped.
      expect(extractCanonicalText(hidden.nodes), 'y\n\n');
      expect(hidden.anchors, isEmpty);

      final hiddenCell = parse(
        '<html><body><table><tr><td id="h" style="display:none">x</td>'
        '<td id="v">b</td></tr></table></body></html>',
      );
      expect(extractCanonicalText(hiddenCell.nodes), 'b\n\n');
      expect(hiddenCell.anchors['v'], 0);
      expect(hiddenCell.anchors.containsKey('h'), isFalse);
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
