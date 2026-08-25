import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest
import zipfile


REPOSITORY = Path(__file__).resolve().parents[2]
CHECKER = REPOSITORY / "scripts" / "check-macos-package.sh"


class MacosPackageCheckerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.archive = self.root / "Shosai-1.0.0-macos-aarch64.zip"
        self._write_archive()
        self._write_tool("lipo", "printf 'arm64\\n'")
        self._write_tool("plutil", ":")
        self._write_tool("codesign", ":")
        self._write_tool(
            "PlistBuddy",
            """
case "$2" in
  *CFBundleIdentifier*) printf 'io.github.chaba2.shosai\\n' ;;
  *CFBundleExecutable*|*CFBundleIconFile*) printf 'Shosai\\n' ;;
  *CFBundleShortVersionString*|*CFBundleVersion*) printf '1.0.0\\n' ;;
  *LSMinimumSystemVersion*) printf '%s\\n' "${FAKE_DECLARED_MINIMUM:-13.0}" ;;
  *) exit 1 ;;
esac
""",
        )
        self._write_tool(
            "ditto",
            'python3 - "$3" "$4" <<\'PY\'\n'
            "import os, pathlib, sys, zipfile\n"
            "with zipfile.ZipFile(sys.argv[1]) as archive:\n"
            "    archive.extractall(sys.argv[2])\n"
            "root = pathlib.Path(sys.argv[2]) / 'Shosai.app/Contents'\n"
            "for path in [root / 'MacOS/Shosai', root / 'Frameworks/libpdfium.dylib']:\n"
            "    path.chmod(path.stat().st_mode | 0o111)\n"
            "PY",
        )
        self._write_tool(
            "otool",
            """
if [[ $1 == -l ]]; then
  case "$2" in
    */libpdfium.dylib) minimum=${FAKE_PDFIUM_MINOS:-13.0} ;;
    *) minimum=${FAKE_BINARY_MINOS:-13.0} ;;
  esac
  cat <<EOF
Load command 1
      cmd LC_BUILD_VERSION
  cmdsize 32
 platform 1
    minos $minimum
      sdk 14.4
   ntools 1
EOF
else
  printf '%s:\\n' "$2"
  case "$2" in
    */libpdfium.dylib)
      printf '\\t./libpdfium.dylib (compatibility version 0.0.0, current version 0.0.0)\\n'
      dependency=${FAKE_PDFIUM_DEPENDENCY:-}
      ;;
    *) dependency=${FAKE_BINARY_DEPENDENCY:-} ;;
  esac
  [[ -z $dependency ]] || printf '\\t%s (compatibility version 1.0.0, current version 1.0.0)\\n' "$dependency"
fi
""",
        )

    def tearDown(self):
        self.temporary.cleanup()

    def test_rejects_binary_newer_than_declared_minimum(self):
        result = self._check(FAKE_BINARY_MINOS="14.0")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requires macOS 14.0 but package declares 13.0", result.stderr)

    def test_rejects_pdfium_newer_than_declared_minimum(self):
        result = self._check(FAKE_PDFIUM_MINOS="14.0")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn(
            "PDFium library requires macOS 14.0 but package declares 13.0",
            result.stderr,
        )

    def test_rejects_nix_store_dependency(self):
        result = self._check(
            FAKE_BINARY_DEPENDENCY="/nix/store/example-libiconv/lib/libiconv.2.dylib"
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("non-portable Mach-O dependency", result.stderr)
        self.assertIn("/nix/store/example-libiconv", result.stderr)

    def test_accepts_declared_target_and_portable_dependencies(self):
        result = self._check(
            FAKE_DECLARED_MINIMUM="13.0",
            FAKE_PDFIUM_MINOS="13.0",
            FAKE_BINARY_DEPENDENCY="/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit",
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Validated", result.stdout)

    def test_accepts_relative_dylib_install_name(self):
        result = self._check()

        self.assertEqual(result.returncode, 0, result.stderr)

    def _check(self, **environment):
        path = f"{self.bin}{os.pathsep}{os.environ['PATH']}"
        return subprocess.run(
            [str(CHECKER), "1.0.0", "aarch64", str(self.archive)],
            cwd=REPOSITORY,
            env={
                **os.environ,
                "PATH": path,
                "PLIST_BUDDY": str(self.bin / "PlistBuddy"),
                **environment,
            },
            capture_output=True,
            text=True,
            check=False,
        )

    def _write_archive(self):
        files = {
            "Shosai.app/Contents/MacOS/Shosai": b"binary",
            "Shosai.app/Contents/Frameworks/libpdfium.dylib": b"pdfium",
            "Shosai.app/Contents/Resources/LICENSE": b"license",
            "Shosai.app/Contents/Resources/INTER-LICENSE": b"license",
            "Shosai.app/Contents/Resources/PDFIUM-LICENSE": b"license",
            "Shosai.app/Contents/Resources/Shosai.icns": b"icon",
            "Shosai.app/Contents/Info.plist": b"plist",
        }
        with zipfile.ZipFile(self.archive, "w") as archive:
            for name, contents in files.items():
                metadata = zipfile.ZipInfo(name)
                metadata.external_attr = (0o755 if "/MacOS/" in name or name.endswith(".dylib") else 0o644) << 16
                archive.writestr(metadata, contents)

    def _write_tool(self, name, body):
        path = self.bin / name
        path.write_text(f"#!/usr/bin/env bash\nset -euo pipefail\n{body}\n")
        path.chmod(path.stat().st_mode | stat.S_IXUSR)


if __name__ == "__main__":
    unittest.main()
