#!/usr/bin/env python3
"""Delete development Shosai state without touching production/user files."""

import os
from pathlib import Path
import shutil
import sqlite3
import sys

DEVELOPMENT_APP_DIR = "shosai-dev"
MARKER_FILE = ".shosai-storage-profile"
DEVELOPMENT_PROFILE = "shosai-development-v1"


def data_directory() -> Path:
    if xdg_data_home := os.environ.get("XDG_DATA_HOME"):
        return Path(xdg_data_home) / DEVELOPMENT_APP_DIR
    home = Path(os.environ["HOME"])
    if sys.platform == "darwin":
        return home / "Library" / "Application Support" / DEVELOPMENT_APP_DIR
    return home / ".local" / "share" / DEVELOPMENT_APP_DIR


def is_within(path: Path, directory: Path) -> bool:
    try:
        path.resolve().relative_to(directory.resolve())
        return True
    except ValueError:
        return False


def owns_custom_directory(directory: Path) -> bool:
    marker = directory / MARKER_FILE
    try:
        return marker.is_file() and marker.read_text(encoding="utf-8").strip() == DEVELOPMENT_PROFILE
    except OSError:
        return False


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

    external = None
    if custom_managed_directory is not None and not is_within(custom_managed_directory, root):
        external = custom_managed_directory
        if external.exists() and not owns_custom_directory(external):
            print(
                f"Refusing to remove external managed directory {external}: "
                f"missing {MARKER_FILE} containing {DEVELOPMENT_PROFILE!r}.",
                file=sys.stderr,
            )
            return 1

    allowed_directories = [root] + ([external] if external is not None else [])
    unsafe_paths = [
        path for path in managed_paths if not any(is_within(path, owned) for owned in allowed_directories)
    ]
    if unsafe_paths:
        print("Refusing reset: managed database paths are outside development-owned storage:", file=sys.stderr)
        for path in unsafe_paths:
            print(f"  {path}", file=sys.stderr)
        return 1

    if external is not None:
        try:
            shutil.rmtree(external, ignore_errors=False)
        except FileNotFoundError:
            pass
        except OSError as error:
            failures.append(f"{external}: {error}")

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
