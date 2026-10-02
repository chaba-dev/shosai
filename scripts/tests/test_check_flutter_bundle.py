import gzip
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "check_flutter_bundle.py"

# The manifest keys exactly as the shipped pubspec declared them on the
# baseline the packaged-font defect was diagnosed on.
BROKEN_FONT_MANIFEST = (
    '[{"family":"Inter","fonts":[{"asset":"../assets/fonts/InterVariable.ttf"}]},'
    '{"family":"Noto Sans JP","fonts":'
    '[{"asset":"../assets/fonts/NotoSansJP-Variable.ttf"}]}]'
)

GOOD_FONT_MANIFEST = (
    '[{"family":"Inter","fonts":[{"asset":"fonts/InterVariable.ttf"}]},'
    '{"family":"Noto Sans JP","fonts":'
    '[{"asset":"fonts/NotoSansJP-Variable.ttf"}]},'
    '{"family":"MaterialIcons","fonts":'
    '[{"asset":"fonts/MaterialIcons-Regular.otf"}]}]'
)


def _write_manifest(root: pathlib.Path, manifest: str):
    assets = root / "data" / "flutter_assets"
    (assets / "fonts").mkdir(parents=True)
    (assets / "FontManifest.json").write_text(manifest, encoding="utf-8")
    return assets


def _write_inventory(root: pathlib.Path, faces: dict[str, str]):
    fonts = root / "assets" / "fonts"
    fonts.mkdir(parents=True)
    rows = "\n".join(
        f"| `{name}` | upstream | purpose | `{digest}` |"
        for name, digest in sorted(faces.items())
    )
    (fonts / "README.md").write_text(
        "| File | Source | Purpose | SHA-256 |\n| --- | --- | --- | --- |\n"
        + rows
        + "\n",
        encoding="utf-8",
    )


def _face_bytes(count: int) -> bytes:
    return b"fake-font-bytes-" + bytes(range(256)) * count


class CheckFlutterBundleTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary.name).resolve()
        self.inventory = self.root / "inventory"
        self.inter_digest = None
        self.noto_digest = None
        self._write_inventory_with_faces()

    def tearDown(self):
        self.temporary.cleanup()

    def _write_inventory_with_faces(self):
        import hashlib

        inter = _face_bytes(40)
        noto = _face_bytes(80)
        self.inter_digest = hashlib.sha256(inter).hexdigest()
        self.noto_digest = hashlib.sha256(noto).hexdigest()
        self._inventory = {
            "InterVariable.ttf": self.inter_digest,
            "NotoSansJP-Variable.ttf": self.noto_digest,
        }
        shutil.rmtree(self.inventory, ignore_errors=True)
        self.inventory.mkdir()
        # Write the face bytes the bundle fixture copies verbatim.
        (self.inventory / "faces").mkdir()
        (self.inventory / "faces" / "InterVariable.ttf").write_bytes(inter)
        (self.inventory / "faces" / "NotoSansJP-Variable.ttf").write_bytes(noto)
        _write_inventory(
            self.inventory,
            {
                "InterVariable.ttf": self.inter_digest,
                "NotoSansJP-Variable.ttf": self.noto_digest,
            },
        )

    def _write_bundle_with_faces(self, manifest: str):
        assets = _write_manifest(self.root, manifest)
        shutil.copy2(
            self.inventory / "faces" / "InterVariable.ttf",
            assets / "fonts" / "InterVariable.ttf",
        )
        shutil.copy2(
            self.inventory / "faces" / "NotoSansJP-Variable.ttf",
            assets / "fonts" / "NotoSansJP-Variable.ttf",
        )
        (assets / "fonts" / "MaterialIcons-Regular.otf").write_bytes(b"icons")
        # A NOTICES.Z whose text carries both redistributed licenses' stable
        # markers, so a "valid bundle" fixture also satisfies the notice check.
        notices = "\n".join(
            [
                "Copyright 2020 The Inter Project Authors",
                "Copyright 2014-2021 Adobe",
            ]
        )
        with gzip.open(assets / "NOTICES.Z", "wb") as handle:
            handle.write(notices.encode("utf-8"))
        return assets

    def _run(self, *roots: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--inventory",
                str(self.inventory),
                *roots,
            ],
            capture_output=True,
            text=True,
            check=False,
        )

    def test_the_shipped_baseline_manifest_fails(self):
        # Finding 1: keys escape the project, and the tool never places the
        # files in the bundle — this must fail, not pass.
        assets = _write_manifest(self.root, BROKEN_FONT_MANIFEST)
        shutil.copytree(
            self.inventory / "faces",
            assets / "data" / "assets" / "fonts",
        )
        result = self._run(str(self.root))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("escapes the bundle", result.stderr)

    def test_percent_encoded_traversal_fails(self):
        assets = _write_manifest(
            self.root,
            '[{"family":"Inter","fonts":[{"asset":"fonts/InterVariable.ttf"}]},'
            '{"family":"Noto Sans JP","fonts":'
            '[{"asset":"fonts/NotoSansJP-Variable.ttf"}]},'
            '{"family":"Escaped","fonts":[{"asset":"fonts%2f..%2f..%2foutside.ttf"}]}]',
        )
        shutil.copy2(
            self.inventory / "faces" / "InterVariable.ttf",
            assets / "fonts" / "InterVariable.ttf",
        )
        shutil.copy2(
            self.inventory / "faces" / "NotoSansJP-Variable.ttf",
            assets / "fonts" / "NotoSansJP-Variable.ttf",
        )
        (self.root / "data" / "outside.ttf").write_bytes(b"outside")
        result = self._run(str(self.root))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("escapes the bundle", result.stderr)

    def test_an_externally_pointing_face_symlink_fails(self):
        # A bundle whose font files are symlinks back into the checkout only
        # works in that checkout; the resolved file must stay inside.
        assets = self._write_bundle_with_faces(GOOD_FONT_MANIFEST)
        outside = self.root / "checkout" / "InterVariable.ttf"
        outside.parent.mkdir(parents=True)
        shutil.copy2(
            self.inventory / "faces" / "InterVariable.ttf",
            outside,
        )
        (assets / "fonts" / "InterVariable.ttf").unlink()
        (assets / "fonts" / "InterVariable.ttf").symlink_to(outside)
        result = self._run(str(self.root))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("escapes the bundle", result.stderr)

    def test_missing_license_notices_fail(self):
        assets = self._write_bundle_with_faces(GOOD_FONT_MANIFEST)
        with gzip.open(assets / "NOTICES.Z", "wb") as handle:
            # A valid gzip member whose text carries neither marker.
            handle.write(b"unrelated notices only")
        result = self._run(str(self.root))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing from the bundle's license notices", result.stderr)

    def test_a_valid_bundle_passes(self):
        self._write_bundle_with_faces(GOOD_FONT_MANIFEST)
        result = self._run(str(self.root))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_a_missing_face_file_fails(self):
        assets = _write_manifest(self.root, GOOD_FONT_MANIFEST)
        shutil.copy2(
            self.inventory / "faces" / "InterVariable.ttf",
            assets / "fonts" / "InterVariable.ttf",
        )
        result = self._run(str(assets))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("NotoSansJP-Variable.ttf", result.stderr)

    def test_a_checksum_mismatch_fails(self):
        assets = self._write_bundle_with_faces(GOOD_FONT_MANIFEST)
        (assets / "fonts" / "InterVariable.ttf").write_bytes(b"tampered")
        result = self._run(str(self.root))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not match the inventory checksum", result.stderr)

    def test_a_missing_manifest_fails(self):
        (self.root / "data" / "flutter_assets").mkdir(parents=True)
        result = self._run(str(self.root))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("FontManifest.json is missing", result.stderr)

    def test_percent_encoded_keys_resolve(self):
        assets = self._write_bundle_with_faces(
            '[{"family":"Encoded","fonts":[{"asset":"fonts/a%5Bb%5D.ttf"}]},'
            '{"family":"Inter","fonts":[{"asset":"fonts/InterVariable.ttf"}]},'
            '{"family":"Noto Sans JP","fonts":'
            '[{"asset":"fonts/NotoSansJP-Variable.ttf"}]}]',
        )
        (assets / "fonts" / "a[b].ttf").write_bytes(b"encoded")
        result = self._run(str(assets))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_a_swapped_family_mapping_fails(self):
        # The right files under the wrong family names swap the two faces'
        # glyphs; the engine's family->file mapping must be checked exactly.
        assets = self._write_bundle_with_faces(
            '[{"family":"Inter","fonts":'
            '[{"asset":"fonts/NotoSansJP-Variable.ttf"}]},'
            '{"family":"Noto Sans JP","fonts":'
            '[{"asset":"fonts/InterVariable.ttf"}]}]',
        )
        result = self._run(str(self.root))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must declare", result.stderr)

    def test_a_missing_engine_family_fails(self):
        # A face file present and checksummed still fails when its family is
        # not declared: the engine shapes by family name.
        assets = self._write_bundle_with_faces(
            '[{"family":"Inter","fonts":[{"asset":"fonts/InterVariable.ttf"}]}]',
        )
        result = self._run(str(self.root))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("the engine family 'Noto Sans JP' is missing", result.stderr)

    def test_a_discovered_assets_symlink_escaping_the_root_fails(self):
        # The assets directory itself must not be a symlink out of the scanned
        # bundle root: such a bundle only works where the symlink resolves.
        self._write_bundle_with_faces(GOOD_FONT_MANIFEST)
        outside_root = pathlib.Path(tempfile.mkdtemp()) / "flutter_assets"
        self.addCleanup(shutil.rmtree, str(outside_root.parent), True)
        (self.root / "data" / "flutter_assets").rename(outside_root)
        (self.root / "data" / "flutter_assets").symlink_to(outside_root)
        result = self._run(str(self.root))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("flutter_assets escapes the bundle root", result.stderr)


if __name__ == "__main__":
    unittest.main()