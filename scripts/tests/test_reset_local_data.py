import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest


REPOSITORY = Path(__file__).resolve().parents[2]
RESET_SCRIPT = REPOSITORY / "scripts" / "reset-local-data.py"


class ResetLocalDataTests(unittest.TestCase):
    def test_removes_managed_copies_but_preserves_referenced_books(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            data_home = temporary / "data"
            shosai_data = data_home / "shosai"
            shosai_data.mkdir(parents=True)
            managed = temporary / "custom-library" / "managed.epub"
            managed.parent.mkdir()
            managed.write_bytes(b"managed")
            custom_managed_directory = temporary / "library-parent" / "Shosai"
            custom_managed_directory.mkdir(parents=True)
            (custom_managed_directory / ".orphan.tmp").write_bytes(b"orphan")
            referenced = temporary / "originals" / "referenced.epub"
            referenced.parent.mkdir()
            referenced.write_bytes(b"referenced")

            database = sqlite3.connect(shosai_data / "shosai.db")
            database.execute(
                "CREATE TABLE books (file_path TEXT, storage_kind TEXT NOT NULL)"
            )
            database.execute("CREATE TABLE preferences (key TEXT, value TEXT)")
            database.executemany(
                "INSERT INTO books VALUES (?, ?)",
                [(str(managed), "managed"), (str(referenced), "referenced")],
            )
            database.execute(
                "INSERT INTO preferences VALUES (?, ?)",
                ("library.managed_books_dir", str(custom_managed_directory)),
            )
            database.commit()
            database.close()

            environment = os.environ.copy()
            environment["XDG_DATA_HOME"] = str(data_home)
            result = subprocess.run(
                [sys.executable, str(RESET_SCRIPT)],
                env=environment,
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(shosai_data.exists())
            self.assertFalse(managed.exists())
            self.assertFalse(custom_managed_directory.exists())
            self.assertTrue(referenced.exists())


if __name__ == "__main__":
    unittest.main()
