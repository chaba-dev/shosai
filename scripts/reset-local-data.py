#!/usr/bin/env python3
"""Delete local Shosai state without deleting referenced original books."""

import os
from pathlib import Path
import shutil
import sqlite3
import sys


def data_directory() -> Path:
    if xdg_data_home := os.environ.get("XDG_DATA_HOME"):
        return Path(xdg_data_home) / "shosai"
    home = Path(os.environ["HOME"])
    if sys.platform == "darwin":
        return home / "Library" / "Application Support" / "shosai"
    return home / ".local" / "share" / "shosai"


def managed_book_data(database: Path) -> tuple[list[Path], Path | None]:
    if not database.exists():
        return [], None
    connection = sqlite3.connect(f"file:{database}?mode=ro", uri=True)
    try:
        columns = {
            row[1] for row in connection.execute("PRAGMA table_info(books)").fetchall()
        }
        paths = []
        if {"file_path", "storage_kind"}.issubset(columns):
            paths = [
                Path(row[0])
                for row in connection.execute(
                    "SELECT file_path FROM books WHERE storage_kind = 'managed'"
                )
            ]
        preference = connection.execute(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'preferences'"
        ).fetchone()
        if preference is None:
            return paths, None
        row = connection.execute(
            "SELECT value FROM preferences WHERE key = 'library.managed_books_dir'"
        ).fetchone()
        return paths, Path(row[0]) if row else None
    finally:
        connection.close()


def main() -> int:
    root = data_directory()
    database = root / "shosai.db"
    failures = []

    try:
        managed_paths, custom_managed_directory = managed_book_data(database)
    except sqlite3.Error as error:
        print(f"Could not read {database}: {error}", file=sys.stderr)
        print("Quit Shosai before running make reset.", file=sys.stderr)
        return 1

    for path in managed_paths:
        try:
            if path.is_dir() and not path.is_symlink():
                raise IsADirectoryError("managed book path is a directory")
            path.unlink(missing_ok=True)
        except OSError as error:
            failures.append(f"{path}: {error}")

    if (
        custom_managed_directory is not None
        and custom_managed_directory.name == "Shosai"
        and custom_managed_directory != root
    ):
        try:
            shutil.rmtree(custom_managed_directory, ignore_errors=False)
        except FileNotFoundError:
            pass
        except OSError as error:
            failures.append(f"{custom_managed_directory}: {error}")

    try:
        shutil.rmtree(root, ignore_errors=False)
    except FileNotFoundError:
        pass
    except OSError as error:
        failures.append(f"{root}: {error}")

    if failures:
        print("Shosai could not remove all local data:", file=sys.stderr)
        for failure in failures:
            print(f"  {failure}", file=sys.stderr)
        return 1

    print(f"Reset Shosai local data at {root}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
