import pathlib
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "check_android_apk.py"

ABIS = ("armeabi-v7a", "arm64-v8a", "x86_64")
LIBRARIES = ("libflutter.so", "libapp.so", "libpdfium.so", "libsqlite3.so")


class CheckAndroidApkTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.apk = pathlib.Path(self.temporary.name) / "app-release.apk"

    def tearDown(self):
        self.temporary.cleanup()

    def _write_apk(self, skip=(), empty=()):
        with zipfile.ZipFile(self.apk, "w") as archive:
            archive.writestr("AndroidManifest.xml", b"manifest")
            for abi in ABIS:
                for library in LIBRARIES:
                    name = f"lib/{abi}/{library}"
                    if name in skip:
                        continue
                    archive.writestr(name, b"" if name in empty else b"\x7fELF")

    def _run(self):
        return subprocess.run(
            [sys.executable, str(SCRIPT), str(self.apk)],
            capture_output=True,
            text=True,
            check=False,
        )

    def test_a_universal_apk_passes(self):
        self._write_apk()
        result = self._run()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_an_apk_without_one_abi_fails(self):
        # The arm64-only filter this host used to carry.
        self._write_apk(
            skip={f"lib/{abi}/{lib}" for abi in ("armeabi-v7a", "x86_64") for lib in LIBRARIES}
        )
        result = self._run()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("lib/armeabi-v7a/libpdfium.so is missing", result.stderr)
        self.assertIn("lib/x86_64/libsqlite3.so is missing", result.stderr)
        self.assertNotIn("arm64-v8a", result.stderr)

    def test_one_missing_native_library_fails(self):
        self._write_apk(skip={"lib/x86_64/libpdfium.so"})
        result = self._run()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("lib/x86_64/libpdfium.so is missing", result.stderr)
        self.assertEqual(result.stderr.count("is missing"), 1)

    def test_an_empty_native_library_fails(self):
        self._write_apk(empty={"lib/armeabi-v7a/libsqlite3.so"})
        result = self._run()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("lib/armeabi-v7a/libsqlite3.so is missing or empty", result.stderr)


if __name__ == "__main__":
    unittest.main()
