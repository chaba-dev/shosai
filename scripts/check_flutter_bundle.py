#!/usr/bin/env python3
"""Verify that a built Flutter bundle actually contains the declared fonts.

`pubspec.yaml`'s `flutter: fonts:` entries must resolve to files *inside* the
Flutter project. A key that escapes the project (for example
`../assets/fonts/InterVariable.ttf`) is recorded in `FontManifest.json` and the
asset manifest but the tool never places the file in the built bundle, so the
engine cannot load the family and `rootBundle.load` fails — the 2026-10-02
corpus pass' finding 1, which made the packaged EPUB routing gate refuse every
chapter.

Usage:

    python3 scripts/check_flutter_bundle.py <bundle-root>...

Each `<bundle-root>` is a directory tree that contains one or more
`flutter_assets` directories (a `flutter build linux` bundle's `data`
directory, a macOS `.app`, or the `flutter_assets` directory itself). For every
one found, this check verifies that every font asset in `FontManifest.json`:

- is project-relative (no `..`, no absolute path),
- resolves to an existing, non-empty regular file inside `flutter_assets`
  (manifest keys may be percent-encoded),
- for the two bundled document faces, matches the SHA-256 recorded in the
  font inventory (`assets/fonts/README.md`), and
- maps each bundled family name to its expected face file, so a manifest that
  swapped the two families' files cannot validate.

Exit codes: 0 when every bundle validates, 1 otherwise.
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import sys
import urllib.parse
import zlib
from pathlib import Path

# The bundled document faces the EPUB routing gate reads through rootBundle.
# Their inventory rows (with the checksums) live in assets/fonts/README.md.
BUNDLED_FACES = (
    ("fonts/InterVariable.ttf", "InterVariable.ttf"),
    ("fonts/NotoSansJP-Variable.ttf", "NotoSansJP-Variable.ttf"),
)

# The engine's family-name -> face-file mapping. The routing gate and the
# whole interface shape text by family name; a manifest that declared the
# right files under the wrong family names would swap the two faces' glyphs.
EXPECTED_FAMILY_ASSETS = {
    "Inter": "fonts/InterVariable.ttf",
    "Noto Sans JP": "fonts/NotoSansJP-Variable.ttf",
}

# Stable text each redistributed license contributes to the bundle's
# NOTICES.Z, so the check stays meaningful without pinning full license texts.
NOTICE_MARKERS = {
    "InterVariable.ttf": (
        "The Inter Project Authors",
        "the Inter license",
    ),
    "NotoSansJP-Variable.ttf": (
        "Copyright 2014-2021 Adobe",
        "the Noto Sans JP license",
    ),
}


def _inventory_face_hashes(inventory_root: Path) -> dict[str, str]:
    """Parse the face checksums out of the font inventory README."""
    readme = inventory_root / "assets" / "fonts" / "README.md"
    if not readme.is_file():
        raise SystemExit(f"font inventory not found: {readme}")
    hashes: dict[str, str] = {}
    for line in readme.read_text(encoding="utf-8").splitlines():
        cells = [
            cell.strip().strip("`")
            for cell in line.strip().strip("|").split("|")
        ]
        # A table row is `| file | source | purpose | sha-256 |`; header and
        # separator rows carry no checksum-looking cell.
        for cell in cells:
            if len(cell) == 64 and all(c in "0123456789abcdef" for c in cell):
                hashes[cells[0].replace("`", "")] = cell
                break
    return hashes


def _check_asset_key(assets: Path, key: str) -> tuple[Path | None, str | None]:
    """Check one FontManifest asset key.

    Returns exactly one of: the *resolved* file path (success — the
    validation and the checksum must look at the same file), or a failure
    description.
    """
    if key.startswith("/") or ".." in Path(key).parts:
        return None, f"font asset key escapes the bundle: {key!r}"
    root = assets.resolve()
    for candidate in (key, urllib.parse.unquote(key)):
        target = assets / candidate
        # A symlink (or an encoded `..`) must not point outside the bundle:
        # such a bundle only works in the checkout it was built from.
        resolved = target.resolve()
        if not resolved.is_relative_to(root):
            return None, f"font asset key escapes the bundle: {key!r}"
        if resolved.is_file() and resolved.stat().st_size > 0:
            return resolved, None
    return None, f"font asset file is missing from the bundle: {key!r}"


def _check_flutter_assets(assets: Path, faces: dict[str, str]) -> list[str]:
    manifest = assets / "FontManifest.json"
    if not manifest.is_file():
        return [f"FontManifest.json is missing from {assets}"]
    try:
        families = json.loads(manifest.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        return [f"FontManifest.json is unreadable in {assets}: {error}"]
    if not isinstance(families, list):
        return [f"FontManifest.json has an unexpected shape in {assets}"]

    failures: list[str] = []
    face_files: dict[str, Path] = {}
    family_assets: dict[str, list[str]] = {}
    for family in families:
        if not isinstance(family, dict) or not isinstance(
            family.get("fonts"), list
        ):
            failures.append(f"malformed font family entry in {manifest}")
            continue
        name = family.get("family")
        for face in family["fonts"]:
            if not isinstance(face, dict) or not isinstance(
                face.get("asset"), str
            ):
                failures.append(f"malformed font asset entry in {manifest}")
                continue
            key = face["asset"]
            if isinstance(name, str):
                family_assets.setdefault(name, []).append(key)
            resolved, failure = _check_asset_key(assets, key)
            if resolved is not None:
                # A symlink target is resolved by the file read; a key equal
                # to one of the bundled faces' paths marks the face present.
                if key in {key for key, _ in BUNDLED_FACES}:
                    face_files[key] = resolved
            else:
                failures.append(failure)
    for family_name, asset_key in EXPECTED_FAMILY_ASSETS.items():
        declared = family_assets.get(family_name)
        if declared is None:
            failures.append(
                f"the engine family {family_name!r} is missing from {manifest}"
            )
        elif asset_key not in declared:
            failures.append(
                f"the engine family {family_name!r} must declare "
                f"{asset_key!r}, got {sorted(declared)!r} in {manifest}"
            )
    for key, filename in BUNDLED_FACES:
        if key not in face_files:
            failures.append(
                f"bundled face {filename} is not declared in {manifest}"
            )
            continue
        actual = hashlib.sha256(face_files[key].read_bytes()).hexdigest()
        expected = faces.get(filename)
        if expected is None:
            failures.append(
                f"font inventory has no checksum for {filename}"
            )
        elif actual != expected:
            failures.append(
                f"bundled face {key} sha256 {actual} does not match the "
                f"inventory checksum {expected}"
            )
    failures.extend(_check_notices(assets, faces))
    return failures


def _check_notices(assets: Path, faces: dict[str, str]) -> list[str]:
    """Verify the bundle's license notices carry the redistributed fonts.

    Both bundled faces' licenses require the copyright notice and license text
    to accompany redistribution; Flutter collects them into `NOTICES.Z` only
    when `pubspec.yaml` declares them under `licenses:`.
    """
    notices = assets / "NOTICES.Z"
    if not notices.is_file():
        return [f"NOTICES.Z is missing from {assets}"]
    try:
        with gzip.open(notices, "rb") as handle:
            text = handle.read().decode("utf-8", errors="replace")
    except (OSError, UnicodeDecodeError, EOFError, zlib.error) as error:
        return [f"NOTICES.Z is unreadable in {assets}: {error}"]
    failures: list[str] = []
    for _, filename in BUNDLED_FACES:
        license_name = NOTICE_MARKERS.get(filename)
        if license_name is None:
            continue
        marker, description = license_name
        if marker not in text:
            failures.append(
                f"{description} ({filename}) is missing from the bundle's "
                f"license notices"
            )
    return failures


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "roots",
        nargs="+",
        help="bundle directories, build outputs or .app trees to check",
    )
    parser.add_argument(
        "--inventory",
        default=str(Path(__file__).resolve().parents[1]),
        help="repository root holding assets/fonts/README.md (default: the "
        "checkout this script lives in)",
    )
    arguments = parser.parse_args()
    faces = _inventory_face_hashes(Path(arguments.inventory))

    failures: list[str] = []
    bundles = 0
    for root in arguments.roots:
        root_path = Path(root)
        if not root_path.exists():
            failures.append(f"bundle root does not exist: {root}")
            continue
        if root_path.name == "flutter_assets":
            found = [root_path]
        else:
            found = list(root_path.rglob("flutter_assets"))
        if not found:
            failures.append(f"no flutter_assets directory under {root}")
            continue
        root_resolved = root_path.resolve()
        for assets in found:
            # A discovered assets directory that is itself a symlink escaping
            # the scanned root would make the bundle depend on external files
            # (it would only validate inside the checkout that built it).
            if not assets.resolve().is_relative_to(root_resolved):
                failures.append(
                    f"flutter_assets escapes the bundle root: {assets}"
                )
                continue
            bundles += 1
            for failure in _check_flutter_assets(assets, faces):
                failures.append(f"{assets}: {failure}")

    if failures:
        for failure in failures:
            print(f"flutter-bundle-check: {failure}", file=sys.stderr)
        print(
            f"flutter-bundle-check: {len(failures)} failure(s) across "
            f"{bundles} bundle(s)",
            file=sys.stderr,
        )
        return 1
    print(f"flutter-bundle-check: {bundles} bundle(s) validated")
    return 0


if __name__ == "__main__":
    sys.exit(main())