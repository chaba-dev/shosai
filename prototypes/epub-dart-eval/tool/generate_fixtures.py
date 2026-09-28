#!/usr/bin/env python3
"""Generate deterministic evaluation fixtures for the Dart EPUB prototype.

Usage (from the repository root):

    python3 prototypes/epub-dart-eval/tool/generate_fixtures.py

Writes `rich-chapter.epub` and `long-chapter.epub` next to this script's
`../fixtures/` directory plus a SHA256SUMS file. The generator mirrors the
conventions of `crates/shosai-core/tests/fixtures/epub-conformance/generate.py`:
fixed ZIP timestamps, stored entries, and a deterministic byte layout so the
recorded hashes are reproducible. It reuses the repository's admitted font
fixture (`crates/shosai-app/tests/fonts/epub/book-a.ttf`) as the embedded font.

`--check` re-generates into a temporary directory and compares hashes instead of
writing.
"""

from __future__ import annotations

import argparse
import hashlib
import struct
import sys
import tempfile
import zlib
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZIP_STORED, ZipFile, ZipInfo

ROOT = Path(__file__).resolve().parents[3]
FIXTURES = Path(__file__).resolve().parent.parent / "fixtures"
FONT_TTF = ROOT / "crates" / "shosai-app" / "tests" / "fonts" / "epub" / "book-a.ttf"
FIXED_DATE = (1980, 1, 1, 0, 0, 0)


def make_png(width: int, height: int, rgb: tuple[int, int, int]) -> bytes:
    """Build a deterministic RGB PNG without external image libraries."""

    def chunk(kind: bytes, payload: bytes) -> bytes:
        return (
            struct.pack(">I", len(payload))
            + kind
            + payload
            + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)
        )

    raw = b"".join(
        b"\x00" + bytes(rgb) * width for _ in range(height)
    )
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )


PNG = make_png(100, 100, (0x33, 0x66, 0x99))

LOREM = (
    "Shōsai keeps a stable logical reading position while the layout engine "
    "lays out this deliberately repetitive paragraph. Mixed punctuation, "
    "emphasized words, and enough text to wrap across several lines make the "
    "fixture useful for repeatable pagination measurements without importing "
    "copyrighted material. "
)


def xhtml(title: str, body: str, head: str = "", lang: str = "en") -> str:
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"
      xmlns:epub="http://www.idpf.org/2007/ops"
      xmlns:m="http://www.w3.org/1998/Math/MathML"
      xml:lang="{lang}">
  <head><title>{title}</title>{head}</head>
  <body>{body}</body>
</html>
"""


def zip_info(path: str, compression: int = ZIP_STORED) -> ZipInfo:
    info = ZipInfo(path, FIXED_DATE)
    info.compress_type = compression
    info.create_system = 0
    info.external_attr = 0o644 << 16
    return info


def rich_chapter() -> tuple[str, bytes]:
    body = """<main id="rich">
<h1 id="title">A Rich Chapter</h1>
<p id="intro">The <strong>first</strong> paragraph mixes <em>emphasis</em>,
<code>inline code</code>, and a <a id="internal-link" href="#tables">link to the
tables section</a>. It also carries a <a id="cross-link" href="chapter-2.xhtml#second">cross-chapter link</a>.</p>

<h2 id="lists">Lists</h2>
<ul id="unordered">
  <li id="item-one">First bullet with <strong>bold</strong> text</li>
  <li id="item-two">Second bullet</li>
  <li id="item-three">Third bullet</li>
</ul>
<ol id="ordered" start="3">
  <li id="ordered-one">Third item</li>
  <li id="ordered-two">Fourth item</li>
</ol>

<h2 id="quote">Quote and code</h2>
<blockquote id="blockquote"><p>A quoted paragraph that should be indented.</p></blockquote>
<pre id="code"><code class="language-dart">void main() {
  final x = 1;
  print('code block $x');
}</code></pre>

<h2 id="figures">Figures</h2>
<figure id="figure-one">
  <img id="figure-image" src="../Images/sample.png" alt="Generated image alt sentinel"/>
  <figcaption id="figure-caption">Figure 1. A generated sample image.</figcaption>
</figure>
<p id="missing-image-paragraph"><img id="missing-image" src="../Images/missing.png" alt="Missing image fallback"/></p>

<h2 id="tables">Tables</h2>
<table id="spanning-table">
  <caption id="table-caption">Quarterly results</caption>
  <thead><tr><th scope="col">Quarter</th><th scope="col">Value</th><th scope="col">Note</th></tr></thead>
  <tbody>
    <tr><th scope="row" rowspan="2">First half</th><td>10</td><td><a id="table-link" href="#title">Top</a></td></tr>
    <tr><td colspan="2"><img id="cell-image" src="../Images/sample.png" alt="Q2 chart"/></td></tr>
    <tr><td>Third</td><td>30</td><td>Plain</td></tr>
  </tbody>
</table>

<h2 id="scripts">Scripts</h2>
<p id="japanese" lang="ja">日本語の段落です。これは評価用のサンプルテキストで、漢字とかなと英数字 Latin が混在しています。</p>
<p id="rtl" dir="rtl" lang="he">שלום 123 English עברית</p>
<p id="mixed">Latin العربية עברית 42 日本語 😀</p>

<h2 id="math">Math</h2>
<p id="inline-math">Inline <m:math id="fraction" alttext="one half"><m:mfrac><m:mn>1</m:mn><m:mn>2</m:mn></m:mfrac></m:math> fraction.</p>
<m:math id="display-root" display="block" alttext="cube root of x"><m:mroot><m:mi>x</m:mi><m:mn>3</m:mn></m:mroot></m:math>

<h2 id="styled">Styled text</h2>
<p id="styled-paragraph" class="lead" style="text-align: center">Centered and
<strong>bold</strong>, <em>italic</em>, <span class="small">smaller</span>, and
<span id="hidden" class="hidden">hidden sentinel</span> text.</p>
<p id="code-like" class="preformatted">line one
line two</p>
<hr id="rule"/>
</main>"""
    head = '<link rel="stylesheet" type="text/css" href="../Styles/book.css"/>'
    return "A Rich Chapter", xhtml("A Rich Chapter", body, head).encode()


def second_chapter() -> tuple[str, bytes]:
    body = """<main id="second"><h1 id="second">Second Chapter</h1>
<p id="second-paragraph">A short second chapter used by the cross-chapter link.</p></main>"""
    return "Second Chapter", xhtml("Second Chapter", body).encode()


def long_chapter(index: int, paragraphs: int, repeats: int) -> tuple[str, bytes]:
    body = [f'<main id="long-{index}"><h1 id="long-title-{index}">Long Chapter {index}</h1>']
    for paragraph in range(paragraphs):
        body.append(
            f'<p id="p-{index}-{paragraph}">{LOREM * repeats}'
            f"<strong>End of paragraph {paragraph + 1}.</strong></p>"
        )
    body.append("</main>")
    return f"Long Chapter {index}", xhtml(
        f"Long Chapter {index}", "\n".join(body)
    ).encode()


def write_book(path: Path, book_id: str, chapters: list[tuple[str, bytes]], resources: dict[str, tuple[str, bytes]]) -> None:
    manifest = [
        '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>'
    ]
    spine = []
    nav_items = []
    files: dict[str, bytes] = {}
    for index, (title, content) in enumerate(chapters, 1):
        name = f"Text/chapter-{index}.xhtml"
        item_id = f"chapter-{index}"
        manifest.append(
            f'<item id="{item_id}" href="{name}" media-type="application/xhtml+xml"/>'
        )
        spine.append(f'<itemref idref="{item_id}"/>')
        nav_items.append(f'<li><a href="{name}">{title}</a></li>')
        files[f"OEBPS/{name}"] = content
    for name, (media_type, content) in sorted(resources.items()):
        manifest.append(
            f'<item id="{"item-" + name.lower().replace("/", "-").replace(".", "-")}"'
            f' href="{name}" media-type="{media_type}"/>'
        )
        files[f"OEBPS/{name}"] = content
    nav = xhtml(
        f"{book_id} navigation",
        '<nav epub:type="toc" id="toc"><h1>Contents</h1><ol>'
        + "".join(nav_items)
        + "</ol></nav>",
    )
    opf = f"""<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="book-id">urn:uuid:shosai-dart-eval-{book_id}</dc:identifier>
    <dc:title>Shosai Dart evaluation: {book_id}</dc:title><dc:creator>Shosai contributors</dc:creator>
    <dc:language>en</dc:language><meta property="dcterms:modified">1980-01-01T00:00:00Z</meta>
  </metadata><manifest>{''.join(manifest)}</manifest><spine>{''.join(spine)}</spine>
</package>
"""
    files["META-INF/container.xml"] = b"""<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>
"""
    files["OEBPS/package.opf"] = opf.encode()
    files["OEBPS/nav.xhtml"] = nav.encode()
    with ZipFile(path, "w") as archive:
        archive.writestr(zip_info("mimetype", ZIP_STORED), b"application/epub+zip")
        for name, content in sorted(files.items()):
            archive.writestr(zip_info(name, ZIP_DEFLATED), content)


def books() -> dict[str, dict]:
    css = """@font-face { font-family: FixtureBook; src: url('../Fonts/book-a.ttf') format('truetype'); }
body { font-size: 1rem; }
.lead { font-size: 1.1em; }
.small { font-size: 0.85em; }
.hidden { display: none; }
.preformatted { white-space: pre; font-family: monospace; }
#quote p { margin-left: 2em; }
h2 { text-align: left; }
"""
    image = ("image/png", PNG)
    return {
        "rich-chapter": {
            "chapters": [rich_chapter(), second_chapter()],
            "resources": {
                "Styles/book.css": ("text/css", css.encode()),
                "Images/sample.png": image,
                "Fonts/book-a.ttf": ("font/ttf", FONT_TTF.read_bytes()),
            },
        },
        # ~100k scalars in the middle chapter: the contract's 90k-scalar case.
        "long-chapter": {
            "chapters": [
                long_chapter(1, paragraphs=8, repeats=4),
                long_chapter(2, paragraphs=110, repeats=3),
                long_chapter(3, paragraphs=8, repeats=4),
            ],
            "resources": {
                "Styles/book.css": ("text/css", b"body { font-size: 1rem; }\n"),
            },
        },
        # ~600k scalars: an explicitly reported stress case beyond the contract.
        "long-chapter-stress": {
            "chapters": [
                long_chapter(1, paragraphs=110, repeats=18),
            ],
            "resources": {
                "Styles/book.css": ("text/css", b"body { font-size: 1rem; }\n"),
            },
        },
    }


def generate(output: Path) -> list[tuple[str, str]]:
    output.mkdir(parents=True, exist_ok=True)
    hashes: list[tuple[str, str]] = []
    for book_id, spec in books().items():
        path = output / f"{book_id}.epub"
        write_book(path, book_id, spec["chapters"], spec["resources"])
        hashes.append((hashlib.sha256(path.read_bytes()).hexdigest(), path.name))
    (output / "SHA256SUMS").write_bytes(
        ("\n".join(f"{digest}  {name}" for digest, name in hashes) + "\n").encode()
    )
    return hashes


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=FIXTURES)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    if args.check:
        with tempfile.TemporaryDirectory() as directory:
            generated = generate(Path(directory))
            recorded = {
                line.split()[1]: line.split()[0]
                for line in (FIXTURES / "SHA256SUMS").read_text().splitlines()
                if line.strip()
            }
            ok = True
            for digest, name in generated:
                if recorded.get(name) != digest:
                    print(f"mismatch: {name}: {digest} != {recorded.get(name)}")
                    ok = False
            return 0 if ok else 1
    hashes = generate(args.output)
    for digest, name in hashes:
        print(f"{digest}  {name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
