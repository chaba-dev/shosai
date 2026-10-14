import 'dart:typed_data';

import 'package:archive/archive.dart';

/// A reader-navigation EPUB fixture built in memory.
///
/// The committed conformance corpus is the shared engine fixture set; this book
/// exists for reader-level navigation behavior the corpus does not cover: a
/// nested table of contents with a title-only part, fragment targets in the
/// same and another chapter, encoded and relative references, an unresolvable
/// anchor, and painted internal/external/refused links. Building it here keeps
/// the shared corpus (and its recorded counts) untouched.
Uint8List navigationEpub() {
  final chapters = <String, String>{
    'OPS/Text/chapter-1.xhtml':
        '<main>'
        '<h1 id="one-start">One</h1>'
        '<p>First chapter body with a '
        '<a href="#one-deep">same-chapter link</a>.</p>'
        '<p>Cross <a href="chapter-2.xhtml#two-target">cross-chapter link</a> '
        'and <a href="chapter%2D2.xhtml#two%20encoded">encoded link</a>.</p>'
        '<p>Allowed external <a href="https://example.invalid/book">https</a> '
        '<a href="http://example.invalid/book">http</a> '
        '<a href="mailto:reader@example.invalid">mail</a>.</p>'
        '<p>Refused <a href="file:///etc/passwd">file</a> '
        '<a href="data:text/plain,x">data</a> '
        '<a href="javascript:alert(1)">script</a> '
        '<a href="custom:blocked">custom</a>.</p>'
        '<p>Missing <a href="#nope">missing</a> and '
        '<a href="chapter-3.xhtml">next chapter</a>.</p>'
        '<h2 id="one-deep">Deep one</h2>'
        '<p>Text after the deep anchor.</p>'
        // Filler so the chapter spans several pages: a chapter-level row must
        // return to the chapter start, not keep the page the reader left.
        '${'<p>Filler paragraph.</p>' * 40}'
        '</main>',
    'OPS/Text/chapter-2.xhtml':
        '<main>'
        '<p>Second chapter body.</p>'
        '<h2 id="two-target">Target</h2>'
        '<p id="two encoded">Encoded target.</p>'
        '</main>',
    'OPS/Text/chapter-3.xhtml':
        '<main>'
        '<p>Third chapter body.</p>'
        '<h2 id="three-deep">Deep three</h2>'
        '</main>',
  };
  const nav =
      '<ol>'
      '<li><span>Part One</span><ol>'
      '<li><a href="../Text/chapter-1.xhtml">Chapter one</a></li>'
      '<li><a href="../Text/chapter-1.xhtml#one-deep">'
      'Chapter one deep</a></li>'
      '<li><a href="../Text/chapter-2.xhtml#two-target">'
      'Chapter two target</a></li>'
      '</ol></li>'
      '<li><a href="../Text/chapter-3.xhtml#three-deep">'
      'Chapter three deep</a></li>'
      '<li><a href="../Text/chapter-3.xhtml#missing">Missing anchor</a></li>'
      '<li><a href="../Text/%63hapter-3.xhtml#three-deep">Encoded path</a></li>'
      '</ol>';
  return _epub(chapters: chapters, nav: nav);
}

/// The title-only part heading the fixture keeps but never shows.
const navigationFixturePartTitle = 'Part One';

/// The unresolvable table-of-contents entry the fixture never shows.
const navigationFixtureMissingTitle = 'Missing anchor';

/// The canonical-parity chapter the slice-5 render checks display.
///
/// Its stream is pinned against the retained parser by the probe run recorded
/// with slice 5: `a middle tail.\nbefore\nCell link to the cell.\n\tAlpha bold
/// tail\nbefore\n(a)/(b)\nafter\tAnchor cell\n\nAfter the table.\n`, with
/// `x`=21, `lead`=22, `empty-cell`=45 and `cell-anchor`=83.
const canonicalParityChapterBody =
    '<main>\n'
    '<p>a <em>mid<br/>dle</em> tail.</p>\n'
    '<p>before<br/><a id="x"/></p>\n'
    '<p id="lead">Cell <a href="#cell-anchor">link</a> to the cell.</p>\n'
    '<table>\n'
    '<tr><td id="empty-cell">   </td><td>Alpha <b>  bold  </b> tail</td></tr>\n'
    '<tr><td>before <m:math display="block"><m:mfrac><m:mi>a</m:mi>'
    '<m:mi>b</m:mi></m:mfrac></m:math> after</td>'
    '<td id="cell-anchor">Anchor cell</td></tr>\n'
    '</table>\n'
    '<p>After the table.</p>\n'
    '</main>';

/// A canonical-parity EPUB built in memory.
///
/// The book exists for reader-level checks of the slice-5 canonical closures:
/// a `<br/>` paragraph, a whitespace-only and an inline-only cell, display
/// math inside an inline cell, and — deliberately — an NCX whose entries
/// disagree with the nav document's, so the Contents panel's source is
/// observable. Building it here keeps the shared corpus untouched.
Uint8List canonicalParityEpub() {
  return _epub(
    chapters: const {'OPS/Text/chapter-1.xhtml': canonicalParityChapterBody},
    nav: '<ol><li><a href="../Text/chapter-1.xhtml">Nav One</a></li></ol>',
    ncx:
        '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">'
        '<navMap>'
        '<navPoint id="n1"><navLabel><text>NCX One</text></navLabel>'
        '<content src="Text/chapter-1.xhtml"/></navPoint>'
        '<navPoint id="n2"><navLabel><text>NCX Two</text></navLabel>'
        '<content src="Text/chapter-1.xhtml#cell-anchor"/></navPoint>'
        '</navMap></ncx>',
    chapterNamespaces: const {'m': 'http://www.w3.org/1998/Math/MathML'},
  );
}

/// An admission-boundary EPUB built in memory.
///
/// The book exists for the reader-level check that a chapter the engine
/// refuses at admission — a cell anchor walk nested past the port's depth
/// ceiling — keeps the whole book on the retained renderer. The spans carry no
/// text, so the canonical stream is the same at every nesting depth the engine
/// accepts: a shallow variant's engine stream is a valid retained stream for
/// the deep variant, and the only difference between the routing control and
/// the fallback case is the depth overrun. Building it here keeps the shared
/// corpus untouched.
Uint8List admissionEpub({required int spanNesting}) {
  var nested = '<a id="t"/>';
  for (var i = 0; i < spanNesting; i += 1) {
    nested = '<span>$nested</span>';
  }
  return _epub(
    chapters: {
      'OPS/Text/chapter-1.xhtml':
          '<table><tr><td>$nested</td></tr></table><p>After the cell.</p>',
    },
    nav: '<ol><li><a href="../Text/chapter-1.xhtml">Admission</a></li></ol>',
  );
}

/// A CRLF-in-code-block EPUB built in memory.
///
/// The book exists for the routing gate's canonical-parity closure: authors
/// (and common toolchains) write preformatted code blocks with CRLF line
/// endings, and the retained parser's canonical stream normalizes each CRLF to
/// U+000A while the Dart engine's canonical stream keeps U+000D U+000A inside
/// `<pre>`/`<code>` content. The whole chapter then fails the gate's
/// canonical-parity comparison and stays on the retained renderer. The prose is
/// this fixture's own; the structure is the minimal form observed in real
/// books. Building it here keeps the shared corpus untouched.
Uint8List crlfPreEpub() {
  const body =
      '<main>'
      '<p>Opening paragraph with a <em>short emphasis</em> span.</p>'
      '<pre><code>first command --flag\n'
      'second command --other-flag\n'
      'third command</code></pre>'
      '<p>Closing paragraph after the block.</p>'
      '</main>';
  // Insert the CRLF pairs the preformatted block is about: the Dart string
  // above carries plain LF joins for readability; the real-world form has a
  // CRLF-terminated every line inside the code block.
  final crlfBody = body.replaceAll('\n', '\r\n');
  return _epub(
    chapters: {'OPS/Text/chapter-1.xhtml': crlfBody},
    nav: '<ol><li><a href="../Text/chapter-1.xhtml">CRLF</a></li></ol>',
  );
}

/// A page-anchor EPUB built in memory.
///
/// The book exists for the reader-level page-step contract over table rows
/// whose cells carry no mapped canonical content (empty cells are common in
/// real books' layout tables): the chapter puts such a table mid-way, after
/// nonzero text, and keeps filler on both sides so it spans several pages.
/// The shapes are the ones the anchored fix must discriminate: a leading
/// empty cell, an interior empty cell, a trailing empty cell, a fully empty
/// row, a cell-less row, and a run of empty rows. Building it here keeps the
/// shared corpus untouched.
Uint8List pageAnchorEpub() {
  final filler = <String>[
    for (var index = 0; index < 40; index += 1)
      '<p>Leading filler paragraph $index for the anchor fixture.</p>',
  ].join();
  final trailing = <String>[
    for (var index = 0; index < 40; index += 1)
      '<p>Trailing filler paragraph $index for the anchor fixture.</p>',
  ].join();
  final emptyRows = <String>[
    // Enough rows that a page break falls inside the run, so a page's
    // canonical start is owned by a fully empty row — the anchor the durable
    // restore contract is about.
    for (var index = 0; index < 60; index += 1) '<tr><td></td></tr>',
  ].join();
  final body =
      '<main>'
      '$filler'
      '<table>'
      '<tr><td></td><td>Leading empty cell row.</td></tr>'
      '<tr><td>Interior left.</td><td></td><td>Interior right.</td></tr>'
      '<tr><td>Trailing text.</td><td></td></tr>'
      '<tr><td></td><td></td></tr>'
      '<tr></tr>'
      '<tr><td>After the empty shapes.</td><td>More after.</td></tr>'
      '$emptyRows'
      '<tr><td>Final row of the table.</td></tr>'
      '</table>'
      '$trailing'
      '</main>';
  return _epub(
    chapters: {
      'OPS/Text/chapter-1.xhtml': body,
      'OPS/Text/chapter-2.xhtml':
          '<main><p>Second chapter body for the anchor fixture.</p></main>',
    },
    nav:
        '<ol>'
        '<li><a href="../Text/chapter-1.xhtml">Anchor chapter</a></li>'
        '<li><a href="../Text/chapter-2.xhtml">Second chapter</a></li>'
        '</ol>',
  );
}

Uint8List _epub({
  required Map<String, String> chapters,
  required String nav,
  String? ncx,
  Map<String, String> chapterNamespaces = const {},
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
    '<item id="nav" href="Nav/toc.xhtml" '
        'media-type="application/xhtml+xml" properties="nav"/>',
    if (ncx != null)
      '<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>',
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
        '<html xmlns="http://www.w3.org/1999/xhtml"'
        '${chapterNamespaces.entries.map((entry) => ' xmlns:${entry.key}="${entry.value}"').join()}'
        '><body>'
        '${chapters[path]}</body></html>';
    index += 1;
  }
  files['OPS/package.opf'] =
      '<?xml version="1.0"?>'
      '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" '
      'unique-identifier="id"><metadata '
      'xmlns:dc="http://purl.org/dc/elements/1.1/">'
      '<dc:identifier id="id">reader-navigation</dc:identifier>'
      '<dc:title>Reader Navigation</dc:title><dc:language>en</dc:language>'
      '</metadata><manifest>${manifest.join()}</manifest>'
      '<spine>${spine.join()}</spine></package>';
  files['OPS/Nav/toc.xhtml'] =
      '<?xml version="1.0"?>'
      '<html xmlns="http://www.w3.org/1999/xhtml" '
      'xmlns:epub="http://www.idpf.org/2007/ops"><body>'
      '<nav epub:type="toc">$nav</nav></body></html>';
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
