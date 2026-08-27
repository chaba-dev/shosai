#!/usr/bin/env python3
"""Delete development Shosai state without touching production/user files."""

import os
from pathlib import Path
import secrets
import sqlite3
import stat
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


def open_owned_directory(directory: Path) -> tuple[int, int, os.stat_result]:
    parent_fd = os.open(directory.parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        directory_fd = os.open(
            directory.name,
            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
            dir_fd=parent_fd,
        )
        directory_stat = os.fstat(directory_fd)
        try:
            marker_fd = os.open(MARKER_FILE, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=directory_fd)
            try:
                marker_stat = os.fstat(marker_fd)
                if not stat.S_ISREG(marker_stat.st_mode):
                    raise OSError("storage marker is not a regular file")
                with os.fdopen(marker_fd, encoding="utf-8", closefd=False) as marker:
                    if marker.read().strip() != DEVELOPMENT_PROFILE:
                        raise OSError("storage marker belongs to a different profile")
            finally:
                os.close(marker_fd)
        except Exception:
            os.close(directory_fd)
            raise
        return parent_fd, directory_fd, directory_stat
    except Exception:
        os.close(parent_fd)
        raise


def remove_owned_directory(directory: Path) -> None:
    parent_fd, directory_fd, expected = open_owned_directory(directory)
    quarantine = f".{directory.name}.shosai-reset-{secrets.token_hex(8)}"
    try:
        os.rename(directory.name, quarantine, src_dir_fd=parent_fd, dst_dir_fd=parent_fd)
        moved = os.stat(quarantine, dir_fd=parent_fd, follow_symlinks=False)
        if (moved.st_dev, moved.st_ino) != (expected.st_dev, expected.st_ino):
            os.rename(quarantine, directory.name, src_dir_fd=parent_fd, dst_dir_fd=parent_fd)
            raise OSError("managed directory changed while reset was validating it")
        remove_directory_contents(directory_fd)
        os.rmdir(quarantine, dir_fd=parent_fd)
    finally:
        os.close(directory_fd)
        os.close(parent_fd)


def remove_directory_contents(directory_fd: int) -> None:
    for name in os.listdir(directory_fd):
        metadata = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
        if stat.S_ISDIR(metadata.st_mode):
            child_fd = os.open(
                name,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                dir_fd=directory_fd,
            )
            try:
                remove_directory_contents(child_fd)
            finally:
                os.close(child_fd)
            os.rmdir(name, dir_fd=directory_fd)
        else:
            os.unlink(name, dir_fd=directory_fd)


def unlink_managed_file(directory_fd: int, relative_path: Path) -> None:
    parts = relative_path.parts
    if not parts or any(part in ("", ".", "..") for part in parts):
        raise OSError("managed path is not a safe relative file path")
    current_fd = os.dup(directory_fd)
    try:
        for part in parts[:-1]:
            next_fd = os.open(
                part,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                dir_fd=current_fd,
            )
            os.close(current_fd)
            current_fd = next_fd
        metadata = os.stat(parts[-1], dir_fd=current_fd, follow_symlinks=False)
        if stat.S_ISDIR(metadata.st_mode):
            raise OSError("managed book path is a directory")
        os.unlink(parts[-1], dir_fd=current_fd)
    except FileNotFoundError:
        pass
    finally:
        os.close(current_fd)


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
    external_handle = None
    if custom_managed_directory is not None and not is_within(custom_managed_directory, root):
        external = custom_managed_directory
        if external.exists() or external.is_symlink():
            try:
                external_handle = open_owned_directory(external)
            except OSError as error:
                print(
                    f"Refusing to remove external managed directory {external}: {error}",
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
        if external_handle is not None:
            os.close(external_handle[1])
            os.close(external_handle[0])
        return 1

    if external is not None and external_handle is not None:
        parent_fd, directory_fd, _ = external_handle
        try:
            external_root = external.resolve()
            for path in managed_paths:
                try:
                    relative = path.resolve().relative_to(external_root)
                except ValueError:
                    continue
                try:
                    unlink_managed_file(directory_fd, relative)
                except OSError as error:
                    failures.append(f"{path}: {error}")
        finally:
            os.close(directory_fd)
            os.close(parent_fd)

    if root.exists() or root.is_symlink():
        try:
            remove_owned_directory(root)
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
