#!/usr/bin/env python3
"""Compose the Browse artwork from actual members of an installed catalog.

Run through .agents/dev with a published catalog SQLite file and an owned cache
directory. Only two selected covers per category are fetched, never the entire
book collection. ImageMagick is supplied by the repository's Nix environment.
"""

import argparse
import concurrent.futures
import hashlib
import json
import pathlib
import re
import sqlite3
import subprocess
import urllib.request
import xml.etree.ElementTree as ET


ROOT = pathlib.Path(__file__).resolve().parents[1]
MIRROR = "https://gutenberg.pglaf.org/cache/epub"
USER_AGENT = "Shosai/0.1 (+https://github.com/chaba-dev/shosai/issues)"
# Match the chosen mock where its books belong to the actual category.
PREFERRED = {
    "Adventure": ["2701", "120"],
    "Children & Young Adult Reading": ["2591", "11"],
    "Classics of Literature": ["2701", "1342"],
    "Crime, Thrillers and Mystery": ["2554", "1661"],
    "Philosophy & Ethics": ["1998", "1497"],
    "Poetry": ["16328", "1322"],
    "Romance": ["1342", "1260"],
    "Science-Fiction & Fantasy": ["36", "35"],
}


def filename(category_id):
    return re.sub(r"[^a-zA-Z0-9]+", "-", category_id).lower() + ".png"


def selected_books(catalog):
    with sqlite3.connect(f"{catalog.resolve().as_uri()}?mode=ro", uri=True) as db:
        db.row_factory = sqlite3.Row
        result = []
        for category in db.execute("SELECT id,label FROM categories ORDER BY label COLLATE NOCASE"):
            candidates = db.execute("""SELECT b.id,b.title,e.cover_url FROM books b
                JOIN book_categories bc ON bc.book_id=b.id
                JOIN editions e ON e.book_id=b.id AND e.display_order=0
                WHERE bc.category_id=? AND e.source_id='gutenberg'
                ORDER BY b.id""", (category["id"],)).fetchall()
            preferred = [f"gutenberg:{id}" for id in PREFERRED.get(category["label"], [])]
            candidates.sort(key=lambda row: (
                preferred.index(row["id"]) if row["id"] in preferred else len(preferred),
                row["id"],
            ))
            if len(candidates) < 2:
                raise ValueError(f"Two Gutenberg member covers required: {category['id']}")
            books = []
            for row in candidates:
                match = re.fullmatch(r"gutenberg:([1-9][0-9]*)", row["id"])
                if not match:
                    raise ValueError(f"Invalid Gutenberg identity: {row['id']}")
                books.append({
                    "bookId": row["id"], "title": row["title"],
                    "gutenbergId": match[1], "catalogCoverUrl": row["cover_url"],
                })
            result.append({"id": category["id"], "label": category["label"],
                           "image": filename(category["id"]), "covers": books})
    if len({row["image"] for row in result}) != len(result):
        raise ValueError("Category artwork filenames collide")
    return result


def fetch(url, path, limit):
    if path.exists():
        return path.read_bytes()
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=30) as response:
        if response.status != 200:
            raise ValueError(f"HTTP {response.status}: {url}")
        content = response.read(limit + 1)
    if len(content) > limit:
        raise ValueError(f"Oversized source: {url}")
    path.write_bytes(content)
    return content


def fetch_cover(book, cache):
    id = book["gutenbergId"]
    cover_url = f"{MIRROR}/{id}/pg{id}.cover.medium.jpg"
    rdf_url = f"{MIRROR}/{id}/pg{id}.rdf"
    rdf = fetch(rdf_url, cache / f"{id}.rdf", 512 * 1024)
    metadata = ET.fromstring(rdf)
    ebook = metadata.find("{http://www.gutenberg.org/2009/pgterms/}ebook")
    if ebook is None or ebook.attrib.get("{http://www.w3.org/1999/02/22-rdf-syntax-ns#}about") != f"ebooks/{id}":
        raise ValueError(f"RDF identity mismatch: {rdf_url}")
    rights = ebook.find("{http://purl.org/dc/terms/}rights")
    if rights is None or rights.text != "Public domain in the USA.":
        print(f"Skipped {book['bookId']}: {rights.text if rights is not None else 'No rights statement'}", flush=True)
        return None
    cover = fetch(cover_url, cache / f"{id}.jpg", 1024 * 1024)
    if not cover.startswith(b"\xff\xd8") or not cover.endswith(b"\xff\xd9"):
        raise ValueError(f"Not a complete JPEG cover: {cover_url}")
    result = {**book, "sourcePage": f"https://www.gutenberg.org/ebooks/{id}",
              "downloadUrl": cover_url, "coverSha256": hashlib.sha256(cover).hexdigest(),
              "rdfUrl": rdf_url, "rdfSha256": hashlib.sha256(rdf).hexdigest(),
              "rights": rights.text}
    print(f"Verified {book['bookId']}: JPEG {len(cover)} bytes, {rights.text}", flush=True)
    return result


def compose(covers, destination):
    # Transparent artwork; the card's existing palette supplies its background.
    # Both covers stay comparable in size, overlap, rotate in opposite directions
    # and crop at the lower/right card edge, as in the chosen design.
    command = ["magick", "-limit", "thread", "1", "-size", "480x272", "canvas:none"]
    for source, width, height, angle, x, y in (
        (covers[0], 110, 165, -12, 310, 118),
        (covers[1], 120, 180, 12, 358, 104),
    ):
        command += ["(", str(source), "-resize", f"{width}x{height}^",
                    "-gravity", "center", "-extent", f"{width}x{height}",
                    "-background", "none", "-rotate", str(angle),
                    "(", "+clone", "-background", "black", "-shadow", "30x3+2+4", ")",
                    "+swap", "-background", "none", "-layers", "merge", "+repage", ")",
                    "-gravity", "northwest", "-geometry", f"+{x}+{y}",
                    "-compose", "over", "-composite"]
    command += ["-depth", "8", "-strip", "-define", "png:compression-level=9",
                f"PNG32:{destination}"]
    subprocess.run(command, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("catalog", type=pathlib.Path)
    parser.add_argument("cache", type=pathlib.Path)
    parser.add_argument("--output", type=pathlib.Path,
                        default=ROOT / "assets/catalog/categories")
    args = parser.parse_args()
    categories = selected_books(args.catalog)
    args.cache.mkdir(parents=True, exist_ok=True)
    args.output.mkdir(parents=True, exist_ok=True)
    fetched = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
        while True:
            pending = {}
            for category in categories:
                usable = 0
                for book in category["covers"]:
                    id = book["bookId"]
                    if id not in fetched:
                        pending[id] = book
                        break
                    if fetched[id] is not None:
                        usable += 1
                    if usable == 2:
                        break
                else:
                    raise ValueError(f"Two public-domain member covers required: {category['id']}")
            if not pending:
                break
            fetched.update(zip(pending, executor.map(
                lambda book: fetch_cover(book, args.cache), pending.values(),
            )))
    for category in categories:
        category["covers"] = [fetched[book["bookId"]] for book in category["covers"]
                              if fetched.get(book["bookId"]) is not None][:2]
        destination = args.output / category["image"]
        compose([args.cache / f"{book['gutenbergId']}.jpg" for book in category["covers"]], destination)
        category["sha256"] = hashlib.sha256(destination.read_bytes()).hexdigest()
    manifest = {"catalogSha256": hashlib.sha256(args.catalog.read_bytes()).hexdigest(),
                "composition": {"width": 480, "height": 272, "background": "transparent"},
                "categories": categories}
    (args.output / "sources.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    unique = {book["bookId"] for category in categories for book in category["covers"]}
    print(f"Created {len(categories)} category images from {len(unique)} verified member covers.")


if __name__ == "__main__":
    main()
