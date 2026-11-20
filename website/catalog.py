#!/usr/bin/env python3
"""Validate and retain the current and previous static catalog snapshots."""

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import shutil
import sqlite3
import tempfile


MAX_FILE_BYTES = 24 * 1024 * 1024
TABLES = {
    "sources": "0",
    "books": "0",
    "authors": "0",
    "subjects": "0",
    "categories": "0",
    "editions": "0123456789abcdef",
    "book_authors": "0",
    "book_subjects": "0",
    "book_categories": "0",
}
ORDER_BY = {
    "editions": ("book_id", "display_order"),
    "book_authors": ("book_id", "position"),
    "book_subjects": ("subject_id", "book_id"),
    "book_categories": ("category_id", "book_id"),
}
# Publication format 2 restores these rows into catalog database schema 1.
# Keep this contract aligned with packages/shosai_core/lib/catalog.dart.
SCHEMA = """
PRAGMA foreign_keys = ON;
CREATE TABLE sources (
  id TEXT PRIMARY KEY CHECK(length(id) > 0), name TEXT NOT NULL,
  website TEXT NOT NULL, catalog_credit TEXT, support_url TEXT
) STRICT;
CREATE TABLE books (
  id TEXT PRIMARY KEY CHECK(length(id) > 0), title TEXT NOT NULL
) STRICT;
CREATE TABLE authors (
  id TEXT PRIMARY KEY CHECK(length(id) > 0), name TEXT NOT NULL,
  sort_name TEXT NOT NULL, name_reading TEXT
) STRICT;
CREATE TABLE subjects (
  id TEXT PRIMARY KEY CHECK(length(id) > 0), label TEXT NOT NULL
) STRICT;
CREATE TABLE categories (
  id TEXT PRIMARY KEY CHECK(length(id) > 0), label TEXT NOT NULL
) STRICT;
CREATE TABLE editions (
  source_id TEXT NOT NULL REFERENCES sources(id),
  source_edition_id TEXT NOT NULL,
  book_id TEXT NOT NULL REFERENCES books(id), title TEXT NOT NULL,
  variant_label TEXT NOT NULL CHECK(length(trim(variant_label)) > 0),
  display_order INTEGER NOT NULL CHECK(display_order >= 0),
  language TEXT NOT NULL, source_url TEXT NOT NULL, rights_line TEXT NOT NULL,
  acquisition_url TEXT NOT NULL, acquisition_format TEXT NOT NULL,
  size_bytes INTEGER CHECK(size_bytes > 0), cover_url TEXT,
  PRIMARY KEY(source_id, source_edition_id), UNIQUE(book_id, display_order)
) STRICT;
CREATE TABLE book_authors (
  book_id TEXT NOT NULL REFERENCES books(id),
  author_id TEXT NOT NULL REFERENCES authors(id),
  position INTEGER NOT NULL CHECK(position >= 0),
  PRIMARY KEY(book_id, position), UNIQUE(book_id, author_id)
) STRICT;
CREATE TABLE book_subjects (
  book_id TEXT NOT NULL REFERENCES books(id),
  subject_id TEXT NOT NULL REFERENCES subjects(id),
  PRIMARY KEY(subject_id, book_id)
) STRICT;
CREATE TABLE book_categories (
  book_id TEXT NOT NULL REFERENCES books(id),
  category_id TEXT NOT NULL REFERENCES categories(id),
  PRIMARY KEY(category_id, book_id)
) STRICT;
"""


def require(condition, message):
    if not condition:
        raise ValueError(message)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, f"Duplicate JSON key: {key}")
        result[key] = value
    return result


def invalid_constant(value):
    raise ValueError(f"Invalid JSON constant: {value}")


def read_json(path):
    require(0 < path.stat().st_size <= MAX_FILE_BYTES, f"Invalid file size: {path}")
    return json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=unique_object,
                      parse_constant=invalid_constant)


def inventory(root):
    files = set()
    for path in root.rglob("*"):
        require(not path.is_symlink(), f"Symlink in catalog: {path}")
        if path.is_file():
            files.add(path.relative_to(root).as_posix())
    return files


def validate_snapshot(root):
    require(root.is_dir() and not root.is_symlink(), f"Missing snapshot: {root}")
    manifest = read_json(root / "manifest.json")
    require(type(manifest) is dict, "Manifest must be an object")
    require(type(manifest.get("formatVersion")) is int
            and manifest["formatVersion"] == 2, "Unsupported catalog format")
    date = manifest.get("builtAt")
    require(isinstance(date, str) and date.endswith("Z"), "Invalid catalog date")
    instant = datetime.fromisoformat(date)
    precision = "milliseconds" if instant.microsecond % 1000 == 0 else "microseconds"
    require(instant.tzinfo == timezone.utc
            and instant.isoformat(timespec=precision).replace("+00:00", "Z") == date,
            "Invalid catalog date")
    counts = manifest.get("sourceCounts")
    require(type(counts) is dict and counts, "Missing source counts")
    require(all(isinstance(key, str) and key and type(count) is int and count > 0
                for key, count in counts.items()), "Invalid source counts")
    expected = {f"{table}/{part}.json" for table, parts in TABLES.items() for part in parts}
    files = manifest.get("files")
    require(type(files) is dict and set(files) == expected, "Incomplete catalog inventory")
    require(inventory(root) == expected | {"manifest.json"}, "Unexpected or missing catalog files")

    db = sqlite3.connect(":memory:")
    try:
        db.executescript(SCHEMA)
        for table, parts in TABLES.items():
            fields = list(db.execute(f"PRAGMA table_info({table})"))
            columns = [row[1] for row in fields]
            placeholders = ",".join("?" for _ in columns)
            for part in parts:
                name = f"{table}/{part}.json"
                metadata = files[name]
                require(type(metadata) is dict, f"Invalid inventory entry: {name}")
                size = metadata.get("sizeBytes")
                digest = metadata.get("sha256")
                require(type(size) is int and 0 < size <= MAX_FILE_BYTES,
                        f"Invalid file size: {name}")
                require(isinstance(digest, str) and re.fullmatch("[0-9a-f]{64}", digest),
                        f"Invalid checksum: {name}")
                require((root / name).stat().st_size == size, f"Size mismatch: {name}")
                data = (root / name).read_bytes()
                require(len(data) == size, f"Size mismatch: {name}")
                require(hashlib.sha256(data).hexdigest() == digest, f"Checksum mismatch: {name}")
                rows = json.loads(data.decode("utf-8"), object_pairs_hook=unique_object,
                                  parse_constant=invalid_constant)
                require(type(rows) is list, f"Expected row array: {name}")
                lines = data.decode("utf-8").split("\n")
                require(lines[0] == "[" and lines[-2:] == ["]", ""],
                        f"Invalid partition layout: {name}")
                require(len(lines) == len(rows) + 3 if rows else lines == ["[", "", "]", ""],
                        f"Expected one row per line: {name}")
                previous_key = None
                for position, row in enumerate(rows):
                    line = lines[position + 1]
                    if position < len(rows) - 1:
                        require(line.endswith(","), f"Missing row separator: {name}")
                        line = line[:-1]
                    require(json.loads(line, object_pairs_hook=unique_object,
                                       parse_constant=invalid_constant) == row,
                            f"Expected one row per line: {name}")
                    require(type(row) is dict and set(row) == set(columns),
                            f"Invalid row columns: {name}")
                    for field in fields:
                        value = row[field[1]]
                        expected_type = str if field[2] == "TEXT" else int
                        require(value is None or type(value) is expected_type,
                                f"Invalid column type: {name}: {field[1]}")
                    key = tuple(row[column] for column in ORDER_BY.get(table, ("id",)))
                    require(all(value is not None for value in key),
                            f"Null ordering key: {name}")
                    require(previous_key is None or previous_key < key,
                            f"Unsorted partition: {name}")
                    previous_key = key
                    if table == "editions":
                        work = row["book_id"]
                        require(isinstance(work, str), "Invalid work ID")
                        require(hashlib.sha256(work.encode()).hexdigest()[0] == part,
                                f"Wrong edition partition: {name}")
                    db.execute(f"INSERT INTO {table} VALUES ({placeholders})",
                               [row[column] for column in columns])
        actual = dict(db.execute("SELECT source_id, COUNT(*) FROM editions GROUP BY source_id"))
        require(actual == counts, "Source counts do not match editions")
        require(not db.execute("""SELECT 1 FROM books b WHERE NOT EXISTS
                    (SELECT 1 FROM editions e WHERE e.book_id = b.id) LIMIT 1""").fetchone(),
                "Book has no edition")
        require(not db.execute("PRAGMA foreign_key_check").fetchall(), "Orphan catalog rows")
    finally:
        db.close()

    # Dates are descriptive, not content identities. No-op refreshes reuse the revision.
    identity = {key: manifest[key] for key in ("formatVersion", "sourceCounts", "files")}
    encoded = json.dumps(identity, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()


def validate(root):
    require(root.is_dir() and not root.is_symlink(), f"Missing catalog: {root}")
    index = read_json(root / "revisions.json")
    require(type(index) is dict and set(index) == {"formatVersion", "current", "previous"},
            "Invalid revision index")
    require(type(index["formatVersion"]) is int and index["formatVersion"] == 1,
            "Unsupported revision index")
    current, previous = index["current"], index["previous"]
    require(current != previous, "Current and previous revisions must differ")
    revisions = [current] + ([] if previous is None else [previous])
    require(all(isinstance(revision, str) and re.fullmatch("[0-9a-f]{64}", revision)
                for revision in revisions), "Invalid revision ID")
    expected = {"revisions.json"}
    for slot in ("current", "previous"):
        revision = index[slot]
        if revision is None:
            require(not (root / slot).exists(), f"Unindexed snapshot: {slot}")
            continue
        require(validate_snapshot(root / slot) == revision,
                f"Revision identity mismatch: {slot}")
        expected |= {f"{slot}/{name}" for name in inventory(root / slot)}
    require(inventory(root) == expected, "Unexpected catalog files")
    return index


def promote(snapshot, root):
    revision = validate_snapshot(snapshot)
    index = validate(root) if root.exists() else None
    if index and index["current"] == revision:
        return revision
    root.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".catalog-", dir=root.parent) as temporary:
        staging = Path(temporary)
        replacement = staging / "new"
        shutil.copytree(snapshot, replacement / "current")
        if index:
            shutil.copytree(root / "current", replacement / "previous")
        next_index = {"formatVersion": 1, "current": revision,
                      "previous": index["current"] if index else None}
        pointer = replacement / "revisions.json"
        pointer.write_text(json.dumps(next_index, indent=2) + "\n", encoding="utf-8")
        validate(replacement)
        # Never put the only backup under TemporaryDirectory: unwinding after
        # SIGINT (or a failed recovery) must not delete the installed snapshots.
        backup = None
        try:
            if index:
                backup = Path(tempfile.mkdtemp(prefix=".catalog-backup-", dir=root.parent))
                root.rename(backup / "catalog")
            replacement.rename(root)
        except BaseException:
            if backup and (backup / "catalog").exists() and not root.exists():
                (backup / "catalog").rename(root)
            raise
        finally:
            if backup and not (backup / "catalog").exists():
                backup.rmdir()
        if backup:
            shutil.rmtree(backup)
    return revision


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    check = commands.add_parser("validate")
    check.add_argument("catalog", type=Path)
    install = commands.add_parser("promote")
    install.add_argument("snapshot", type=Path)
    install.add_argument("catalog", type=Path)
    args = parser.parse_args()
    try:
        if args.command == "validate":
            index = validate(args.catalog)
            print(f"Validated catalog: current={index['current']}, previous={index['previous']}")
        else:
            print(f"Promoted catalog revision: {promote(args.snapshot, args.catalog)}")
    except (ValueError, OSError, sqlite3.Error, TypeError) as error:
        parser.exit(1, f"Catalog validation failed: {error}\n")


if __name__ == "__main__":
    main()
