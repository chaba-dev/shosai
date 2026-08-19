#!/usr/bin/env python3
"""Generate tiny, redistribution-safe EPUB font-loading fixtures.

Requires fonttools with its woff and woff2 dependencies:
    python -m pip install -r crates/shosai-app/tests/fonts/requirements-epub-font-fixtures.txt
"""

from pathlib import Path

from fontTools.fontBuilder import FontBuilder
from fontTools.pens.t2CharStringPen import T2CharStringPen
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.ttLib import TTFont


OUTPUT = Path(__file__).parent / "epub"
FAMILY = "Shosai EPUB Fixture"
GLYPH_ORDER = [".notdef", "space", "A", "B"]
CHARACTER_MAP = {0x20: "space", 0x41: "A", 0x42: "B"}


def rectangle(pen, width: int) -> None:
    pen.moveTo((50, 0))
    pen.lineTo((width - 50, 0))
    pen.lineTo((width - 50, 700))
    pen.lineTo((50, 700))
    pen.closePath()


def names(label: str, family: str = FAMILY) -> dict[str, str]:
    return {
        "familyName": family,
        "styleName": "Regular",
        "uniqueFontIdentifier": f"Shosai-{label}",
        "fullName": f"{family} {label}",
        "psName": f"ShosaiEPUBFixture-{label}",
        "version": "Version 1.0",
    }


def configure_common(
    builder: FontBuilder, label: str, advance: int, family: str = FAMILY
) -> None:
    builder.setupGlyphOrder(GLYPH_ORDER)
    builder.setupCharacterMap(CHARACTER_MAP)
    builder.setupHorizontalMetrics(
        {glyph: (advance if glyph != "space" else 300, 0) for glyph in GLYPH_ORDER}
    )
    builder.setupHorizontalHeader(ascent=800, descent=-200)
    builder.setupNameTable(names(label, family))
    builder.setupOS2(
        sTypoAscender=800,
        sTypoDescender=-200,
        usWinAscent=800,
        usWinDescent=200,
    )
    builder.setupPost()


def build_ttf(
    path: Path, label: str, advance: int, family: str = FAMILY
) -> None:
    builder = FontBuilder(1000, isTTF=True)
    configure_common(builder, label, advance, family)
    glyphs = {}
    for glyph in GLYPH_ORDER:
        pen = TTGlyphPen(None)
        if glyph in {"A", "B"}:
            rectangle(pen, advance)
        glyphs[glyph] = pen.glyph()
    builder.setupGlyf(glyphs)
    builder.setupMaxp()
    builder.save(path)


def build_otf(path: Path, label: str, advance: int) -> None:
    builder = FontBuilder(1000, isTTF=False)
    configure_common(builder, label, advance)
    char_strings = {}
    for glyph in GLYPH_ORDER:
        pen = T2CharStringPen(advance, None)
        if glyph in {"A", "B"}:
            rectangle(pen, advance)
        char_strings[glyph] = pen.getCharString()
    builder.setupCFF(
        names(label)["psName"],
        {"FullName": names(label)["fullName"], "FamilyName": FAMILY, "Weight": "Regular"},
        char_strings,
        {},
    )
    builder.setupMaxp()
    builder.save(path)


def compress(source: Path, destination: Path, flavor: str) -> None:
    font = TTFont(source)
    font.flavor = flavor
    font.save(destination)


def main() -> None:
    OUTPUT.mkdir(exist_ok=True)
    book_a = OUTPUT / "book-a.ttf"
    build_ttf(book_a, "BookA", 600)
    build_otf(OUTPUT / "book-a.otf", "BookAOTF", 600)
    compress(book_a, OUTPUT / "book-a.woff", "woff")
    compress(book_a, OUTPUT / "book-a.woff2", "woff2")
    build_ttf(OUTPUT / "book-b.ttf", "BookB", 900)
    build_ttf(OUTPUT / "other-family.ttf", "OtherFamily", 600, "Other EPUB Fixture")


if __name__ == "__main__":
    main()
