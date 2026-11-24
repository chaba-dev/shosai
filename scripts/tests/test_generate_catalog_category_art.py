"""The artwork CLI must use actual, explicitly public-domain category members."""

import hashlib
import json
import pathlib
import sqlite3
import subprocess
import sys
import tempfile
import unittest


SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "generate-catalog-category-art.py"


class CatalogCategoryArtTest(unittest.TestCase):
    def test_cached_generation_excludes_copyrighted_members_and_checks_identity(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            catalog = root / "catalog.sqlite3"
            cache = root / "cache"
            cache.mkdir()
            with sqlite3.connect(catalog) as db:
                db.executescript("""
                    CREATE TABLE categories(id TEXT, label TEXT);
                    CREATE TABLE books(id TEXT, title TEXT);
                    CREATE TABLE book_categories(book_id TEXT, category_id TEXT);
                    CREATE TABLE editions(book_id TEXT, source_id TEXT,
                        display_order INTEGER, cover_url TEXT);
                    INSERT INTO categories VALUES ('gutenberg:Test/Category', 'Test category');
                """)
                for id in (1, 2, 3, 4, 5, 6, 7, 8):
                    book = f"gutenberg:{id}"
                    db.execute("INSERT INTO books VALUES (?,?)", (book, f"Book {id}"))
                    db.execute("INSERT INTO book_categories VALUES (?,?)",
                               (book, "gutenberg:Test/Category"))
                    db.execute("INSERT INTO editions VALUES (?, 'gutenberg', 0, ?)",
                               (book, f"https://www.gutenberg.org/cache/epub/{id}/pg{id}.cover.medium.jpg"))
                    rights = "Copyrighted." if id == 1 else "Public domain in the USA."
                    (cache / f"{id}.rdf").write_text(f"""
                        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                          xmlns:pg="http://www.gutenberg.org/2009/pgterms/"
                          xmlns:dct="http://purl.org/dc/terms/">
                          <pg:ebook rdf:about="ebooks/{id}"><dct:rights>{rights}</dct:rights></pg:ebook>
                        </rdf:RDF>
                    """, encoding="utf-8")
                    if id in (2, 3):
                        # Both vivid and pastel automatic jackets have a white
                        # title banner and a coloured rule above their pattern.
                        colour = "#00cc00" if id == 2 else "#ffccff"
                        subprocess.run([
                            "magick", "-size", "80x120", f"xc:{colour}",
                            "-fill", "white", "-draw", "rectangle 0,3 79,38",
                            str(cache / f"{id}.jpg"),
                        ], check=True)
                    elif id in (4, 5):
                        # A wide internal banner or an almost empty title page
                        # must not be stretched into a pretend book jacket.
                        subprocess.run([
                            "magick", "-size", "80x16" if id == 4 else "80x120",
                            "xc:white", "-fill", "black", "-draw", "rectangle 25,45 55,50",
                            str(cache / f"{id}.jpg"),
                        ], check=True)
                    else:
                        # Two volumes may reuse identical jacket pixels; the
                        # collage must continue to a different member cover.
                        colour_id = 6 if id == 7 else id
                        subprocess.run(["magick", "-size", "12x18", f"xc:rgb({colour_id*20},40,80)",
                                        str(cache / f"{id}.jpg")], check=True)
            output = root / "art"
            result = subprocess.run([sys.executable, str(SCRIPT), str(catalog), str(cache),
                                     "--output", str(output)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            manifest = json.loads((output / "sources.json").read_text())
            category, = manifest["categories"]
            self.assertEqual(category["id"], "gutenberg:Test/Category")
            self.assertEqual([book["bookId"] for book in category["covers"]],
                             ["gutenberg:6", "gutenberg:8"])
            image = output / "gutenberg-test-category.png"
            self.assertTrue(image.read_bytes().startswith(b"\x89PNG\r\n\x1a\n"))
            self.assertEqual(hashlib.sha256(image.read_bytes()).hexdigest(), category["sha256"])
            for book in category["covers"]:
                self.assertEqual(book["rights"], "Public domain in the USA.")
                self.assertEqual(book["coverSha256"], hashlib.sha256(
                    (cache / f"{book['gutenbergId']}.jpg").read_bytes()).hexdigest())

            # A cache or source with the wrong book identity must not produce art.
            rdf = cache / "6.rdf"
            rdf.write_text(rdf.read_text().replace('ebooks/6"', 'ebooks/99"'))
            invalid = root / "invalid"
            result = subprocess.run([sys.executable, str(SCRIPT), str(catalog), str(cache),
                                     "--output", str(invalid)], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("RDF identity mismatch", result.stderr)
            self.assertFalse(list(invalid.glob("*.png")))


if __name__ == "__main__":
    unittest.main()
