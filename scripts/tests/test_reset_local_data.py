import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest


REPOSITORY = Path(__file__).resolve().parents[2]
RESET_SCRIPT = REPOSITORY / "scripts" / "reset-local-data.py"
MARKER = ".shosai-storage-profile"
PROFILE = "shosai-development-v1"


def create_database(root: Path, rows=(), custom: Path | None = None) -> None:
    root.mkdir(parents=True)
    (root / MARKER).write_text(PROFILE)
    database = sqlite3.connect(root / "shosai.db")
    database.execute("CREATE TABLE books (file_path TEXT, storage_kind TEXT NOT NULL)")
    database.execute("CREATE TABLE preferences (key TEXT, value TEXT)")
    database.executemany("INSERT INTO books VALUES (?, ?)", rows)
    if custom is not None:
        database.execute(
            "INSERT INTO preferences VALUES ('library.managed_books_dir', ?)",
            (str(custom),),
        )
    database.commit()
    database.close()


def run_reset(data_home: Path) -> subprocess.CompletedProcess[str]:
    environment = os.environ.copy()
    environment["XDG_DATA_HOME"] = str(data_home)
    return subprocess.run(
        [sys.executable, str(RESET_SCRIPT)],
        env=environment,
        capture_output=True,
        text=True,
        check=False,
    )


class ResetLocalDataTests(unittest.TestCase):
    def test_dev_reset_recursively_removes_dev_root_and_preserves_production(self):
        with tempfile.TemporaryDirectory() as directory:
            data_home = Path(directory) / "data"
            production = data_home / "shosai"
            development = data_home / "shosai-dev"
            (production / "books").mkdir(parents=True)
            (production / "books" / "production.epub").write_bytes(b"production")
            (development / "nested").mkdir(parents=True)
            (development / "nested" / "sentinel").write_text("dev")
            (development / MARKER).write_text(PROFILE)

            result = run_reset(data_home)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(development.exists())
            self.assertTrue((production / "books" / "production.epub").exists())

    def test_unmarked_development_root_is_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            data_home = Path(directory) / "data"
            development = data_home / "shosai-dev"
            development.mkdir(parents=True)
            sentinel = development / "sentinel"
            sentinel.write_text("keep")

            result = run_reset(data_home)

            self.assertNotEqual(result.returncode, 0)
            self.assertTrue(sentinel.exists())

    def test_managed_copies_are_removed_without_recursively_deleting_custom_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            data_home = temporary / "data"
            development = data_home / "shosai-dev"
            custom = temporary / "custom-library"
            custom.mkdir()
            (custom / MARKER).write_text(PROFILE)
            managed = custom / "managed.epub"
            managed.write_bytes(b"managed")
            sentinel = custom / "unrelated.txt"
            sentinel.write_text("keep")
            referenced = temporary / "original.epub"
            referenced.write_bytes(b"original")
            create_database(
                development,
                [(str(managed), "managed"), (str(referenced), "referenced")],
                custom,
            )

            result = run_reset(data_home)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(development.exists())
            self.assertTrue(custom.exists())
            self.assertFalse(managed.exists())
            self.assertTrue(sentinel.exists())
            self.assertTrue(referenced.exists())

    def test_missing_or_wrong_marker_preserves_same_named_custom_directory(self):
        for marker_value in (None, "production"):
            with self.subTest(marker_value=marker_value), tempfile.TemporaryDirectory() as directory:
                temporary = Path(directory)
                data_home = temporary / "data"
                development = data_home / "shosai-dev"
                custom = temporary / "parent" / "Shosai"
                custom.mkdir(parents=True)
                sentinel = custom / "sentinel"
                sentinel.write_text("keep")
                if marker_value is not None:
                    (custom / MARKER).write_text(marker_value)
                create_database(development, custom=custom)

                result = run_reset(data_home)

                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Refusing", result.stderr)
                self.assertTrue(sentinel.exists())
                self.assertTrue(development.exists())

    @unittest.skipUnless(hasattr(os, "symlink"), "requires symlinks")
    def test_symlinked_marker_cannot_claim_an_unrelated_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            data_home = temporary / "data"
            development = data_home / "shosai-dev"
            custom = temporary / "unrelated"
            custom.mkdir()
            sentinel = custom / "sentinel"
            sentinel.write_text("keep")
            profile = temporary / "profile"
            profile.write_text(PROFILE)
            (custom / MARKER).symlink_to(profile)
            create_database(development, custom=custom)

            result = run_reset(data_home)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Refusing", result.stderr)
            self.assertTrue(sentinel.exists())
            self.assertTrue(development.exists())

    @unittest.skipUnless(hasattr(os, "symlink"), "requires symlinks")
    def test_symlinked_directory_is_never_removed(self):
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            data_home = temporary / "data"
            development = data_home / "shosai-dev"
            unrelated = temporary / "unrelated"
            unrelated.mkdir()
            sentinel = unrelated / "sentinel"
            sentinel.write_text("keep")
            custom = temporary / "custom-library"
            custom.symlink_to(unrelated, target_is_directory=True)
            create_database(development, custom=custom)

            result = run_reset(data_home)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Refusing", result.stderr)
            self.assertTrue(sentinel.exists())
            self.assertTrue(development.exists())

    def test_out_of_scope_managed_row_cannot_delete_arbitrary_file(self):
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            data_home = temporary / "data"
            development = data_home / "shosai-dev"
            sentinel = temporary / "sentinel.epub"
            sentinel.write_bytes(b"keep")
            create_database(development, [(str(sentinel), "managed")])

            result = run_reset(data_home)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("outside development-owned storage", result.stderr)
            self.assertTrue(sentinel.exists())
            self.assertTrue(development.exists())


if __name__ == "__main__":
    unittest.main()
