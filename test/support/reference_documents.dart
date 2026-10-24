import 'dart:convert';
import 'dart:typed_data';

import 'epub_navigation_fixture.dart';

/// Authored internal references exercised through the real document engines.
Uint8List referenceEpub() => buildTestEpub(
  chapters: {
    'OPS/Text/chapter-1.xhtml':
        '<h1>A field guide to quiet places</h1>'
        '<p>Reading should leave room for a small detour. '
        '<a epub:type="noteref" href="chapter-2.xhtml#note-one">Footnote 1</a>'
        ' explains the name without interrupting the walk.</p>'
        '<p><a href="chapter-2.xhtml#observations">Field observations</a></p>'
        '<p><a href="chapter-2.xhtml#figure-one">Figure 1: The river bend</a></p>'
        '<p><a href="chapter-2.xhtml#table-one">Table 1: Walking distances</a></p>'
        '<p>Keep your place here while you look ahead.</p>',
    'OPS/Text/chapter-2.xhtml':
        '<h1 id="observations">Field observations</h1>'
        '<p>The path follows the river through the old orchard. '
        'At the bend, the water becomes still enough to mirror the trees.</p>'
        '<figure id="figure-one"><figcaption>Figure 1. The river bend</figcaption>'
        '<p>The orchard stands on the far bank.</p></figure>'
        '<table id="table-one"><caption>Table 1. Walking distances</caption>'
        '<tr><th>Route</th><th>Distance</th></tr>'
        '<tr><td>Orchard loop</td><td>3 km</td></tr></table>'
        '<aside epub:type="footnote" id="note-one">'
        '<p>1. Quiet is the old name for the sheltered bend, not an instruction '
        'to the traveller.</p></aside>',
  },
  nav:
      '<ol><li><a href="../Text/chapter-1.xhtml">A field guide</a></li>'
      '<li><a href="../Text/chapter-2.xhtml#observations">Field observations</a>'
      '</li></ol>',
);

/// Three pages with direct destinations, a named GoTo destination, and FitH.
/// A nonzero crop and rotation make geometry mistakes observable in tests.
Uint8List referencePdf({int rotation = 0, bool cropped = false}) {
  const width = 612;
  const height = 792;
  final box =
      '/MediaBox [0 0 $width $height] '
      '${cropped ? '/CropBox [20 30 600 780]' : ''} /Rotate $rotation';
  String stream(String text) =>
      '<< /Length ${ascii.encode(text).length} >>\n'
      'stream\n$text\nendstream';
  final objects = [
    '<< /Type /Catalog /Pages 2 0 R /Names << /Dests << /Names '
        '[(note-one) [5 0 R /XYZ 72 164 null]] >> >> >>',
    '<< /Type /Pages /Kids [3 0 R 5 0 R 7 0 R] /Count 3 >>',
    '<< /Type /Page /Parent 2 0 R $box /Resources << /Font << /F1 9 0 R >> >> '
        '/Contents 4 0 R /Annots [10 0 R 11 0 R 12 0 R 13 0 R] >>',
    stream(
      'BT /F1 24 Tf 72 700 Td (A field guide to quiet places) Tj '
      '/F1 15 Tf 0 -55 Td (Keep your place here while you look ahead.) Tj '
      '0 -65 Td (Contents: Field observations) Tj '
      '0 -50 Td (Footnote 1: Why quiet?) Tj '
      '0 -50 Td (Figure 1: The river bend) Tj '
      '0 -50 Td (Table 1: Walking distances) Tj ET',
    ),
    '<< /Type /Page /Parent 2 0 R $box /Resources << /Font << /F1 9 0 R >> >> '
        '/Contents 6 0 R >>',
    stream(
      'BT /F1 24 Tf 72 690 Td (Field observations) Tj '
      '/F1 15 Tf 0 -45 Td (The path follows the river through the old orchard.) Tj '
      '0 -28 Td (At the bend, the water mirrors the trees.) Tj '
      '/F1 19 Tf 0 -117 Td (Figure 1. The river bend) Tj '
      '/F1 15 Tf 0 -30 Td (The orchard stands on the far bank.) Tj '
      '/F1 19 Tf 0 -90 Td (Table 1. Walking distances) Tj '
      '/F1 15 Tf 0 -30 Td (Orchard loop: 3 km. Riverside path: 5 km.) Tj '
      '/F1 13 Tf 0 -186 Td (1. Quiet is the old name for the sheltered bend,) Tj '
      '0 -20 Td (not an instruction to the traveller.) Tj ET',
    ),
    '<< /Type /Page /Parent 2 0 R $box /Resources << /Font << /F1 9 0 R >> >> '
        '/Contents 8 0 R >>',
    stream('BT /F1 24 Tf 72 690 Td (The walk continues) Tj ET'),
    '<< /Type /Font /Subtype /Type1 /BaseFont /Times-Roman >>',
    '<< /Type /Annot /Subtype /Link /Rect [72 570 310 596] /Border [0 0 0] '
        '/Dest [5 0 R /XYZ 72 690 null] >>',
    '<< /Type /Annot /Subtype /Link /Rect [72 520 270 546] /Border [0 0 0] '
        '/A << /S /GoTo /D (note-one) >> >>',
    '<< /Type /Annot /Subtype /Link /Rect [72 470 290 496] /Border [0 0 0] '
        '/Dest [5 0 R /XYZ 72 500 null] >>',
    '<< /Type /Annot /Subtype /Link /Rect [72 420 310 446] /Border [0 0 0] '
        '/Dest [5 0 R /FitH 380] >>',
  ];
  final pdf = StringBuffer('%PDF-1.7\n');
  final offsets = <int>[];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(pdf.length);
    pdf.write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
  }
  final xref = pdf.length;
  pdf.write('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n');
  for (final offset in offsets) {
    pdf.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  pdf.write(
    'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\n'
    'startxref\n$xref\n%%EOF\n',
  );
  return Uint8List.fromList(ascii.encode(pdf.toString()));
}
