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

Uint8List _epub({
  required Map<String, String> chapters,
  required String nav,
  String? ncx,
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
        '<html xmlns="http://www.w3.org/1999/xhtml"><body>'
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
