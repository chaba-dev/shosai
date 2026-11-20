import hashlib
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import catalog


SCRIPT = Path(__file__).with_name("catalog.py")


def partition(rows):
    return "[\n" + ",\n".join("  " + json.dumps(row) for row in rows) + "\n]\n"


def snapshot(root, title="Pride and Prejudice"):
    root.mkdir()
    rows = {f"{table}/0.json": [] for table in (
        "sources", "books", "authors", "subjects", "categories",
        "book_authors", "book_subjects", "book_categories",
    )}
    rows.update({f"editions/{part}.json": [] for part in "0123456789abcdef"})
    rows["sources/0.json"] = [{
        "id": "gutenberg", "name": "Project Gutenberg",
        "website": "https://www.gutenberg.org/", "catalog_credit": None,
        "support_url": None,
    }]
    rows["books/0.json"] = [{"id": "gutenberg:1342", "title": title}]
    rows["editions/7.json"] = [{
        "source_id": "gutenberg", "source_edition_id": "1342:a",
        "book_id": "gutenberg:1342", "title": title,
        "variant_label": "Without images", "display_order": 0, "language": "en",
        "source_url": "https://www.gutenberg.org/ebooks/1342",
        "rights_line": "Public domain in the USA",
        "acquisition_url": "https://example.invalid/1342.epub",
        "acquisition_format": "epub", "size_bytes": None, "cover_url": None,
    }]
    for name, data in rows.items():
        path = root / name
        path.parent.mkdir(exist_ok=True)
        path.write_text(partition(data), encoding="utf-8")
    manifest = {
        "formatVersion": 2, "builtAt": "2026-11-20T00:00:00.000Z",
        "sourceCounts": {"gutenberg": 1}, "files": {},
    }
    for name in rows:
        data = (root / name).read_bytes()
        manifest["files"][name] = {
            "sizeBytes": len(data), "sha256": hashlib.sha256(data).hexdigest(),
        }
    (root / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
    return root


def rewrite(root, name, data):
    path = root / name
    path.write_text(data if isinstance(data, str) else partition(data), encoding="utf-8")
    manifest = catalog.read_json(root / "manifest.json")
    raw = path.read_bytes()
    manifest["files"][name] = {
        "sizeBytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest(),
    }
    (root / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")


def contents(root):
    return {path.relative_to(root).as_posix(): path.read_bytes()
            for path in root.rglob("*") if path.is_file()}


class CatalogTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)

    def test_promotions_keep_two_revisions_and_no_op_or_reversion_work(self):
        published = self.root / "published"
        first = catalog.promote(snapshot(self.root / "a"), published)
        self.assertEqual(catalog.validate(published)["previous"], None)
        second = catalog.promote(snapshot(self.root / "b", "Second"), published)
        before = contents(published)
        # A changed timestamp must not create a content revision.
        manifest_path = self.root / "b" / "manifest.json"
        manifest = catalog.read_json(manifest_path)
        manifest["builtAt"] = "2026-11-21T00:00:00.000Z"
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        self.assertEqual(catalog.promote(self.root / "b", published), second)
        self.assertEqual(contents(published), before)
        catalog.promote(self.root / "a", published)
        self.assertEqual(catalog.validate(published), {
            "formatVersion": 1, "current": first, "previous": second,
        })
        third = catalog.promote(snapshot(self.root / "c", "Third"), published)
        self.assertEqual(catalog.validate(published), {
            "formatVersion": 1, "current": third, "previous": first,
        })
        self.assertEqual({path.name for path in published.iterdir()}, {
            "current", "previous", "revisions.json",
        })

    def test_bad_checksum_cannot_replace_a_working_catalog(self):
        published = self.root / "published"
        catalog.promote(snapshot(self.root / "a"), published)
        before = contents(published)
        broken = snapshot(self.root / "broken", "Broken")
        path = broken / "books/0.json"
        path.write_bytes(path.read_bytes().replace(b"Broken", b"Borken"))
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "promote", str(broken), str(published)],
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(contents(published), before)
        self.assertIsNotNone(catalog.validate(published))

    def test_interrupted_promotion_preserves_both_installed_snapshots(self):
        published = self.root / "published"
        catalog.promote(snapshot(self.root / "a"), published)
        catalog.promote(snapshot(self.root / "b", "Second"), published)
        third = snapshot(self.root / "c", "Third")
        before = contents(published)
        rename = Path.rename

        def interrupted_rename(path, target):
            result = rename(path, target)
            if path == published:
                raise KeyboardInterrupt
            return result

        with mock.patch.object(Path, "rename", interrupted_rename):
            with self.assertRaises(KeyboardInterrupt):
                catalog.promote(third, published)
        self.assertEqual(contents(published), before)
        catalog.validate(published)

    def test_ordered_single_line_rows_are_required(self):
        exported = snapshot(self.root / "snapshot")
        authors = [
            {"id": key, "name": key, "sort_name": key, "name_reading": None}
            for key in ("a", "z")
        ]
        rewrite(exported, "authors/0.json", authors)
        catalog.validate_snapshot(exported)
        for invalid in (list(reversed(authors)), json.dumps(authors) + "\n"):
            with self.subTest(invalid=invalid):
                rewrite(exported, "authors/0.json", invalid)
                with self.assertRaises(ValueError):
                    catalog.validate_snapshot(exported)

    def test_ordering_of_editions_uses_numeric_display_order(self):
        exported = snapshot(self.root / "snapshot")
        edition = catalog.read_json(exported / "editions/7.json")[0]
        editions = [dict(edition, source_edition_id="later-id", display_order=2),
                    dict(edition, source_edition_id="earlier-id", display_order=10)]
        manifest_path = exported / "manifest.json"
        manifest = catalog.read_json(manifest_path)
        manifest["sourceCounts"]["gutenberg"] = 2
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        rewrite(exported, "editions/7.json", editions)
        catalog.validate_snapshot(exported)
        rewrite(exported, "editions/7.json", list(reversed(editions)))
        with self.assertRaises(ValueError):
            catalog.validate_snapshot(exported)

    def test_metadata_files_obey_the_same_asset_size_limit(self):
        published = self.root / "published"
        catalog.promote(snapshot(self.root / "a"), published)
        for path in (published / "current/manifest.json", published / "revisions.json"):
            with self.subTest(path=path):
                original = path.read_bytes()
                try:
                    path.write_bytes(original + b" " * (catalog.MAX_FILE_BYTES - len(original)))
                    catalog.validate(published)
                    with path.open("ab") as output:
                        output.write(b" ")
                    with self.assertRaisesRegex(ValueError, "Invalid file size"):
                        catalog.validate(published)
                finally:
                    path.write_bytes(original)

    def test_hashed_but_invalid_data_is_rejected(self):
        for problem in (
            "orphan", "duplicate", "count", "version", "type", "partition", "non_json", "date",
        ):
            with self.subTest(problem=problem):
                broken = snapshot(self.root / problem)
                edition = catalog.read_json(broken / "editions/7.json")[0]
                if problem == "orphan":
                    rewrite(broken, "books/0.json", [])
                elif problem == "duplicate":
                    rewrite(broken, "editions/7.json", [edition, edition])
                elif problem == "type":
                    edition["display_order"] = "0"
                    rewrite(broken, "editions/7.json", [edition])
                elif problem == "partition":
                    rewrite(broken, "editions/7.json", [])
                    rewrite(broken, "editions/8.json", [edition])
                else:
                    path = broken / "manifest.json"
                    manifest = catalog.read_json(path)
                    if problem == "version":
                        manifest["formatVersion"] = 3
                    elif problem == "non_json":
                        manifest["unexpected"] = float("nan")
                    elif problem == "date":
                        manifest["builtAt"] = "2026-11-20T00:00:00Z"
                    else:
                        manifest["sourceCounts"]["gutenberg"] = 2
                    path.write_text(json.dumps(manifest), encoding="utf-8")
                with self.assertRaises((ValueError, sqlite3.Error)):
                    catalog.validate_snapshot(broken)

    def test_missing_published_file_or_corrupt_previous_revision_fails(self):
        published = self.root / "published"
        catalog.promote(snapshot(self.root / "a"), published)
        catalog.promote(snapshot(self.root / "b", "Second"), published)
        (published / "previous" / "books/0.json").unlink()
        with self.assertRaises(ValueError):
            catalog.validate(published)


if __name__ == "__main__":
    unittest.main()
