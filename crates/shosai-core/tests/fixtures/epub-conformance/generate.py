#!/usr/bin/env python3
"""Generate deterministic, redistribution-safe EPUB conformance fixtures."""

from __future__ import annotations

import argparse
import base64
import hashlib
import warnings
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZIP_STORED, ZipFile, ZipInfo


ROOT = Path(__file__).resolve().parent
FONT_ROOT = ROOT.parents[3] / "shosai-app" / "tests" / "fonts" / "epub"
FIXED_DATE = (1980, 1, 1, 0, 0, 0)
PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
)


def xhtml(title: str, body: str, head: str = "") -> str:
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"
      xmlns:epub="http://www.idpf.org/2007/ops"
      xmlns:m="http://www.w3.org/1998/Math/MathML"
      xml:lang="en">
  <head><title>{title}</title>{head}</head>
  <body>{body}</body>
</html>
"""


def chapter(title: str, body: str, head: str = "") -> tuple[str, bytes]:
    return title, xhtml(title, body, head).encode()


def resource(media_type: str, content: str | bytes) -> tuple[str, bytes]:
    return media_type, content.encode() if isinstance(content, str) else content


def books(large_resource_bytes: int) -> dict[str, dict]:
    css = """@font-face { font-family: Fixture; src: url('../Fonts/book-a.woff2') format('woff2'); }
body { color: #202020; font-size: 1rem; }
p { color: #303030; }
.chapter .important { color: #2468ac !important; }
.chapter p.important { color: #13579b; }
.inherited { font-style: italic; }
section > p.inherited { text-decoration: underline; }
.source-order { color: #111111; }
.source-order { color: #222222; }
.hidden { display: none; }
"""
    nested_image = chapter(
        "Nested images",
        """<main id="nested-images">
<h1>Nested images</h1>
<img id="block-image" src="../Images/pixel.png" alt="Block image"/>
<p id="paragraph-image">Before <img src="../Images/pixel.png" alt="Nested diagram"/> after</p>
<figure id="figure"><img src="../Images/pixel.png" alt="Figure image"/><figcaption>Fixture caption</figcaption></figure>
<p><img id="missing-image" src="../Images/missing.png" alt="Missing image fallback"/></p>
<table><tr><td><img id="cell-image" src="../Images/pixel.png" alt="Cell image"/></td></tr></table>
</main>""",
    )
    cascade = chapter(
        "CSS cascade",
        """<main class="chapter" id="cascade"><p id="specific" class="important" style="font-weight: 700">Specificity</p>
<section class="inherited"><p id="inherited">Inherited style</p></section>
<p class="hidden">Hidden sentinel</p><p id="relative">Relative lengths</p></main>""",
        '<link rel="stylesheet" type="text/css" href="../Styles/book.css"/>',
    )
    table = chapter(
        "Tables",
        """<main id="tables"><table id="spanning-table"><caption>Quarterly results</caption>
<thead><tr><th scope="col">Quarter</th><th scope="col">Value</th></tr></thead>
<tbody><tr><th scope="row" rowspan="2">First half</th><td><a href="#spanning-table">Q1 link</a></td></tr>
<tr><td><img src="../Images/pixel.png" alt="Q2 chart"/></td></tr>
<tr><td colspan="2"><p>Nested cell paragraph</p></td></tr></tbody></table>
<table id="wide-table"><tr><td>One</td><td>Two</td><td>Three</td><td>Four</td><td>Five</td></tr></table></main>""",
    )
    fonts = chapter(
        "Embedded fonts",
        """<main id="fonts"><p class="woff">WOFF AB</p><p class="woff2">WOFF2 AB</p>
<p class="ttf">TTF AB</p><p class="otf">OTF AB</p><p class="missing">Missing font fallback</p>
<p class="corrupt">Corrupt font fallback</p></main>""",
        '<link rel="stylesheet" type="text/css" href="../Styles/fonts.css"/>',
    )
    mathml = chapter(
        "MathML",
        """<main id="math"><p>Inline <m:math id="fraction" alttext="one half"><m:mfrac><m:mn>1</m:mn><m:mn>2</m:mn></m:mfrac></m:math>.</p>
<m:math id="display-root" display="block" alttext="cube root of x"><m:mroot><m:mi>x</m:mi><m:mn>3</m:mn></m:mroot></m:math>
<m:math id="scripts"><m:msubsup><m:mi>x</m:mi><m:mn>1</m:mn><m:mn>2</m:mn></m:msubsup></m:math>
<m:math id="operator"><m:mi>x</m:mi><m:mo>+</m:mo><m:mn>1</m:mn></m:math>
<m:math id="matrix" display="block"><m:mtable><m:mtr><m:mtd><m:mn>1</m:mn></m:mtd><m:mtd><m:mn>0</m:mn></m:mtd></m:mtr></m:mtable></m:math>
<m:math id="annotated"><m:semantics><m:mi>π</m:mi><m:annotation encoding="application/x-tex">\\pi</m:annotation></m:semantics></m:math>
<m:math id="malformed-fallback" alttext="malformed fraction"><m:mfrac><m:mn>1</m:mn></m:mfrac></m:math></main>""",
    )
    bidi = chapter(
        "Bidirectional text",
        """<main id="bidi"><p id="hebrew" dir="rtl" lang="he">שלום 123 English</p>
<p id="arabic" dir="rtl" lang="ar">مَرْحَبًا 456 Latin</p>
<ul dir="rtl"><li>פריט A1</li><li>عنصر B2</li></ul>
<p id="mixed">Latin العربية עברית 42 é 日本語 😀</p></main>""",
    )
    links = chapter(
        "Links",
        """<main id="links"><h1 id="local">Links</h1><a id="same" href="#local">Same chapter</a>
<a id="cross" href="chapter-2.xhtml#target">Cross chapter</a>
<a id="encoded" href="chapter%2D2.xhtml#percent-target">Encoded path</a>
<a id="https" href="https://example.invalid/book">HTTPS</a><a id="http" href="http://example.invalid/book">HTTP</a>
<a id="mail" href="mailto:reader@example.invalid">Mail</a><a id="unsupported" href="custom:blocked">Unsupported</a></main>""",
    )
    conformance_links = (
        links[0],
        links[1]
        .replace(b"chapter-2.xhtml", b"chapter-8.xhtml")
        .replace(b"chapter%2D2.xhtml", b"chapter%2D8.xhtml"),
    )
    links_second = chapter(
        "Link targets",
        '<main><h1 id="target">Cross target</h1><p id="percent-target">Percent target</p></main>',
    )
    malformed_bad = (
        "Malformed chapter",
        b'<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml"><body><p>Unclosed sentinel</body></html>',
    )
    deep_nesting = (
        '<div id="deep-nesting">' + "<div>" * 16 + "Deep sentinel" + "</div>" * 16 + "</div>"
    )
    malformed_good = chapter(
        "Readable sibling",
        f'<main id="readable-sibling"><p>Readable sibling sentinel</p>{deep_nesting}</main>',
        '<link rel="stylesheet" type="text/css" href="../Styles/malformed.css"/>',
    )
    canonical = chapter(
        "Canonical paths",
        """<main id="canonical"><a id="dot" href="./chapter-2.xhtml#target">Dot segment</a>
<a id="parent" href="../Text/chapter-2.xhtml#target">Parent segment</a>
<a id="encoded-traversal" href="%2e%2e/secret.xhtml">Encoded traversal</a>
<a id="query" href="sibling.xhtml?query=blocked#target">Query</a>
<a id="absolute" href="/outside.xhtml">Absolute</a>
<a id="foreign" href="https://example.invalid/outside.xhtml">Foreign</a>
<img id="case-variant" src="../Images/PIXEL.png" alt="Case variant"/></main>""",
    )
    remote = chapter(
        "Remote content",
        """<main id="remote"><img src="https://example.invalid/image.png" alt="Remote image"/>
<iframe src="https://example.invalid/frame"></iframe><object data="https://example.invalid/object"></object>
<script src="https://example.invalid/script.js"></script><form action="https://example.invalid/post"><button>Submit</button></form>
<a download="book.bin" href="https://example.invalid/download">Download</a>
<a target="_blank" href="https://example.invalid/popup">Popup</a>
<a id="redirect" href="https://example.invalid/redirect">Redirect</a></main>""",
        '<link rel="stylesheet" type="text/css" href="../Styles/remote.css"/>',
    )
    limits = chapter(
        "Resource limits",
        """<main id="resource-limits"><img src="../Images/huge.svg" alt="Huge declared image"/>
<p class="large">Highly compressed resource marker</p><p class="bad-font">Malformed font marker</p></main>""",
        '<link rel="stylesheet" type="text/css" href="../Styles/limits.css"/>',
    )
    image_resources = {"Images/pixel.png": resource("image/png", PNG)}
    font_css = """@font-face { font-family: FixtureWoff; src: url('../Fonts/book-a.woff') format('woff'); }
@font-face { font-family: FixtureWoff2; src: url('../Fonts/book-a.woff2') format('woff2'); }
@font-face { font-family: FixtureTtf; src: url('../Fonts/book-a.ttf') format('truetype'); }
@font-face { font-family: FixtureOtf; src: url('../Fonts/book-a.otf') format('opentype'); }
@font-face { font-family: FixtureTtf; src: url('../Fonts/book-a.ttf') format('truetype'); font-weight: 700; }
@font-face { font-family: FixtureTtf; src: url('../Fonts/book-a.ttf') format('truetype'); font-style: italic; }
@font-face { font-family: MissingFixture; src: url('../Fonts/missing.woff2') format('woff2'); }
@font-face { font-family: CorruptFixture; src: url('../Fonts/corrupt.woff2') format('woff2'); }
.woff { font-family: FixtureWoff; } .woff2 { font-family: FixtureWoff2; }
.ttf { font-family: FixtureTtf; } .otf { font-family: FixtureOtf; }
.missing { font-family: MissingFixture, serif; } .corrupt { font-family: CorruptFixture, serif; }
"""
    font_resources = {
        "Styles/fonts.css": resource("text/css", font_css),
        "Fonts/book-a.woff": resource("font/woff", (FONT_ROOT / "book-a.woff").read_bytes()),
        "Fonts/book-a.woff2": resource("font/woff2", (FONT_ROOT / "book-a.woff2").read_bytes()),
        "Fonts/book-a.ttf": resource("font/ttf", (FONT_ROOT / "book-a.ttf").read_bytes()),
        "Fonts/book-a.otf": resource("font/otf", (FONT_ROOT / "book-a.otf").read_bytes()),
        "Fonts/corrupt.woff2": resource("font/woff2", b"not a font"),
    }
    isolation_resources = {
        "Styles/fonts.css": resource(
            "text/css",
            "@font-face { font-family: FixtureTtf; src: url('../Fonts/book-b.ttf') format('truetype'); } .ttf { font-family: FixtureTtf; }",
        ),
        "Fonts/book-b.ttf": resource("font/ttf", (FONT_ROOT / "book-b.ttf").read_bytes()),
    }
    isolation_font = chapter(
        "Isolated embedded font",
        '<main id="fonts-isolation"><p class="ttf">Book B AB</p></main>',
        '<link rel="stylesheet" type="text/css" href="../Styles/fonts.css"/>',
    )
    missing_spine = chapter("Missing spine resource", "<p>This file is intentionally absent.</p>")
    duplicate = chapter("Duplicate archive entry", "<p>Duplicate path sentinel.</p>")
    cases = {
        "nested-image": {"chapters": [nested_image], "resources": image_resources},
        "css-cascade": {
            "chapters": [cascade],
            "resources": {"Styles/book.css": resource("text/css", css)},
        },
        "table": {"chapters": [table], "resources": image_resources},
        "fonts": {"chapters": [fonts], "resources": font_resources},
        "fonts-isolation": {"chapters": [isolation_font], "resources": isolation_resources},
        "mathml": {"chapters": [mathml], "chapter_properties": {1: ["mathml"]}},
        "bidi": {"chapters": [bidi]},
        "links": {"chapters": [links, links_second]},
        "malformed-markup": {
            "chapters": [malformed_bad, malformed_good],
            "resources": {
                "Styles/malformed.css": resource(
                    "text/css", "p { color: red; broken declaration } @media ( {"
                )
            },
        },
        "canonical-paths": {
            "chapters": [canonical, links_second],
            "resources": image_resources,
        },
        "remote-content": {
            "chapters": [remote],
            "chapter_properties": {1: ["remote-resources", "scripted"]},
            "resources": {
                "Styles/remote.css": resource(
                    "text/css",
                    "@import url('https://example.invalid/import.css'); @font-face { font-family: Remote; src: url('https://example.invalid/font.woff2'); } body { background: url('https://example.invalid/background.png'); }",
                )
            },
        },
        "resource-limits": {
            "chapters": [limits],
            "resources": {
                "Styles/limits.css": resource(
                    "text/css", "@font-face { font-family: Bad; src: url('../Fonts/corrupt.ttf'); } .large { background: url('../Data/compression.txt'); }"
                ),
                "Images/huge.svg": resource(
                    "image/svg+xml", '<svg xmlns="http://www.w3.org/2000/svg" width="100000" height="100000"><rect width="100%" height="100%"/></svg>'
                ),
                "Fonts/corrupt.ttf": resource("font/ttf", b"malformed font sentinel"),
                "Fonts/oversized.ttf": resource("font/ttf", b"F" * large_resource_bytes),
                "Data/compression.txt": resource("text/plain", b"A" * large_resource_bytes),
            },
        },
    }
    cases["conformance"] = {
        "chapters": [
            nested_image,
            cascade,
            table,
            fonts,
            mathml,
            bidi,
            conformance_links,
            links_second,
        ],
        "chapter_properties": {5: ["mathml"]},
        "resources": image_resources
        | {"Styles/book.css": resource("text/css", css)}
        | font_resources,
    }
    cases["missing-spine-resource"] = {
        "chapters": [missing_spine],
        "omit_chapter_files": {1},
    }
    cases["duplicate-entries"] = {
        "chapters": [duplicate],
        "duplicate_entry": "OEBPS/Text/chapter-1.xhtml",
    }
    return cases


def media_id(path: str) -> str:
    return "item-" + path.lower().replace("/", "-").replace(".", "-")


def zip_info(path: str, compression: int = ZIP_STORED) -> ZipInfo:
    info = ZipInfo(path, FIXED_DATE)
    info.compress_type = compression
    info.create_system = 0
    info.external_attr = 0o644 << 16
    return info


def write_book(
    path: Path, book_id: str, spec: dict, compress_stress_resource: bool
) -> None:
    chapters = spec["chapters"]
    resources = spec.get("resources", {})
    manifest = [
        '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>'
    ]
    spine = []
    nav_items = []
    files: dict[str, bytes] = {}
    for index, (title, content) in enumerate(chapters, 1):
        name = f"Text/chapter-{index}.xhtml"
        item_id = f"chapter-{index}"
        properties = " ".join(spec.get("chapter_properties", {}).get(index, []))
        properties_attribute = f' properties="{properties}"' if properties else ""
        manifest.append(
            f'<item id="{item_id}" href="{name}" media-type="application/xhtml+xml"{properties_attribute}/>'
        )
        spine.append(f'<itemref idref="{item_id}"/>')
        nav_items.append(f'<li><a href="{name}">{title}</a></li>')
        if index not in spec.get("omit_chapter_files", set()):
            files[f"OEBPS/{name}"] = content
    for name, (media_type, content) in sorted(resources.items()):
        manifest.append(
            f'<item id="{media_id(name)}" href="{name}" media-type="{media_type}"/>'
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
    <dc:identifier id="book-id">urn:uuid:shosai-conformance-{book_id}</dc:identifier>
    <dc:title>Shosai Conformance: {book_id}</dc:title><dc:creator>Shosai contributors</dc:creator>
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
            compression = (
                ZIP_DEFLATED
                if compress_stress_resource
                and book_id == "resource-limits"
                and name == "OEBPS/Data/compression.txt"
                else ZIP_STORED
            )
            archive.writestr(zip_info(name, compression), content)
        if duplicate_entry := spec.get("duplicate_entry"):
            with warnings.catch_warnings():
                warnings.simplefilter("ignore", UserWarning)
                archive.writestr(zip_info(duplicate_entry), files[duplicate_entry])


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=ROOT)
    parser.add_argument("--large-resource-bytes", type=int, default=1024 * 1024)
    parser.add_argument(
        "--compress-stress-resource",
        action="store_true",
        help="deflate the resource-limits payload for a compression-ratio test",
    )
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    hashes = []
    for book_id, spec in books(args.large_resource_bytes).items():
        output = args.output / f"{book_id}.epub"
        write_book(output, book_id, spec, args.compress_stress_resource)
        hashes.append(f"{hashlib.sha256(output.read_bytes()).hexdigest()}  {output.name}")
    (args.output / "SHA256SUMS").write_bytes(
        ("\n".join(hashes) + "\n").encode("ascii")
    )


if __name__ == "__main__":
    main()
