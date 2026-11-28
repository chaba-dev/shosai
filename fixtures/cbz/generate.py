#!/usr/bin/env python3
"""Generate deterministic CBZ fixtures for the comic reader tests.

Usage (from the repository root):

    python3 fixtures/cbz/generate.py

Writes beside this script, plus a SHA256SUMS file:

- `sample-manga.cbz`: ten numbered pages named `page1.png` … `page10.png`,
  stored, so natural order differs from plain string order; page 5 is a wide
  two-page spread; a ComicInfo.xml with a title, writers, `LanguageISO` `ja`
  and `Manga` `YesAndRightToLeft`.
- `sample-comic.cbz`: the same pages deflated, in folders, without
  ComicInfo.xml, and with the `__MACOSX` and text entries archivers leave.

Every page is drawn by this script (a solid color and its number in a block
font), so the fixtures carry no third-party content. `--check` regenerates into
a temporary directory and compares hashes instead of writing.
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

FIXTURES = Path(__file__).resolve().parent
FIXED_DATE = (1980, 1, 1, 0, 0, 0)
NAMES = ("sample-manga.cbz", "sample-comic.cbz")

# 3x5 digit glyphs, one string per row.
DIGITS = {
    "0": ("###", "#.#", "#.#", "#.#", "###"),
    "1": (".#.", "##.", ".#.", ".#.", "###"),
    "2": ("###", "..#", "###", "#..", "###"),
    "3": ("###", "..#", "###", "..#", "###"),
    "4": ("#.#", "#.#", "###", "..#", "..#"),
    "5": ("###", "#..", "###", "..#", "###"),
    "6": ("###", "#..", "###", "#.#", "###"),
    "7": ("###", "..#", "..#", "..#", "..#"),
    "8": ("###", "#.#", "###", "#.#", "###"),
    "9": ("###", "#.#", "###", "..#", "###"),
}
COLORS = (
    (0xE8, 0x6A, 0x5C), (0xF2, 0xB1, 0x4C), (0xD9, 0xD2, 0x5B),
    (0x7F, 0xC4, 0x6E), (0x5C, 0xB8, 0xB2), (0x5A, 0x8F, 0xD8),
    (0x8C, 0x6F, 0xD1), (0xC9, 0x6D, 0xB8), (0xA8, 0x8B, 0x6E),
    (0x8A, 0x93, 0x9B),
)


def page_png(number: int) -> bytes:
    width, height = (600, 450) if number == 5 else (300, 450)
    background = COLORS[number - 1]
    text = str(number)
    scale = 24
    glyph_width = (len(text) * 4 - 1) * scale
    left = (width - glyph_width) // 2
    top = (height - 5 * scale) // 2
    rows = []
    for y in range(height):
        row = bytearray(bytes(background) * width)
        gy = (y - top) // scale
        if 0 <= y - top < 5 * scale:
            for index, digit in enumerate(text):
                for gx, cell in enumerate(DIGITS[digit][gy]):
                    if cell != "#":
                        continue
                    x0 = left + (index * 4 + gx) * scale
                    row[x0 * 3:(x0 + scale) * 3] = b"\x1a\x1a\x1a" * scale
        rows.append(b"\x00" + bytes(row))

    def chunk(kind: bytes, payload: bytes) -> bytes:
        return (
            struct.pack(">I", len(payload))
            + kind
            + payload
            + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)
        )

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", header)
        + chunk(b"IDAT", zlib.compress(b"".join(rows), 9))
        + chunk(b"IEND", b"")
    )


COMIC_INFO = """<?xml version="1.0" encoding="utf-8"?>
<ComicInfo xmlns:xsd="http://www.w3.org/2001/XMLSchema">
  <Title>Sample Manga</Title>
  <Series>Sample Series</Series>
  <Number>1</Number>
  <Writer>Test Author, Second Author</Writer>
  <LanguageISO>ja</LanguageISO>
  <Manga>YesAndRightToLeft</Manga>
</ComicInfo>
"""


def write(zip_file: ZipFile, name: str, data: bytes, method: int) -> None:
    info = ZipInfo(name, FIXED_DATE)
    info.compress_type = method
    info.external_attr = 0o644 << 16
    zip_file.writestr(info, data, compresslevel=9 if method == ZIP_DEFLATED else None)


def generate(directory: Path) -> None:
    pages = {number: page_png(number) for number in range(1, 11)}
    with ZipFile(directory / "sample-manga.cbz", "w") as manga:
        write(manga, "ComicInfo.xml", COMIC_INFO.encode(), ZIP_STORED)
        # Written in plain string order; the reader orders them naturally.
        for number in sorted(pages, key=str):
            write(manga, f"page{number}.png", pages[number], ZIP_STORED)
    with ZipFile(directory / "sample-comic.cbz", "w") as comic:
        write(comic, "Chapter 1/", b"", ZIP_STORED)
        for number in range(1, 6):
            write(comic, f"Chapter 1/{number:02}.png", pages[number], ZIP_DEFLATED)
        for number in range(6, 11):
            write(comic, f"Chapter 2/{number - 5}.png", pages[number], ZIP_DEFLATED)
        write(comic, "__MACOSX/Chapter 1/._01.png", b"\x00\x05\x16\x07", ZIP_STORED)
        write(comic, "Chapter 1/.DS_Store", b"\x00", ZIP_STORED)
        write(comic, "scan-notes.txt", b"Scanned by the fixture generator.\n", ZIP_STORED)


def sums(directory: Path) -> str:
    return "".join(
        f"{hashlib.sha256((directory / name).read_bytes()).hexdigest()}  {name}\n"
        for name in NAMES
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    arguments = parser.parse_args()
    if arguments.check:
        with tempfile.TemporaryDirectory() as temporary:
            generate(Path(temporary))
            expected = sums(Path(temporary))
        recorded = (FIXTURES / "SHA256SUMS").read_text()
        if expected != recorded or sums(FIXTURES) != recorded:
            print("CBZ fixtures differ from the generator; run make cbz-fixtures", file=sys.stderr)
            return 1
        return 0
    generate(FIXTURES)
    (FIXTURES / "SHA256SUMS").write_text(sums(FIXTURES))
    return 0


if __name__ == "__main__":
    sys.exit(main())
