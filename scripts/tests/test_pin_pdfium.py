import importlib.util
import io
import pathlib
import sys
import tarfile
import tempfile
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[2]
TOOL = ROOT / "flutter/third_party/pdfium_dart/tool/pin_pdfium.py"


def _load_tool():
    spec = importlib.util.spec_from_file_location("pin_pdfium", TOOL)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _tgz(files: dict[str, str]) -> bytes:
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w:gz") as archive:
        for name, text in files.items():
            data = text.encode("utf-8")
            info = tarfile.TarInfo(name)
            info.size = len(data)
            archive.addfile(info, io.BytesIO(data))
    return buffer.getvalue()


class _Response(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class PinPdfiumTest(unittest.TestCase):
    def setUp(self):
        self.tool = _load_tool()
        self.temporary = tempfile.TemporaryDirectory()
        self.package = pathlib.Path(self.temporary.name)
        (self.package / "hook").mkdir()
        (self.package / "LICENSE").write_text("MIT License\n")
        self.archives = self.package / "hook" / "pdfium_archives.dart"
        self.notices = self.package / "NOTICES"
        self.archives.write_text("old pins\n")
        self.notices.write_text("old notices\n")
        self.tool.PACKAGE = self.package

    def tearDown(self):
        self.temporary.cleanup()

    def _run(self, files: dict[str, str]) -> int:
        archive = _tgz(files)
        with (
            mock.patch.object(
                self.tool.urllib.request,
                "urlopen",
                side_effect=lambda url: _Response(archive),
            ),
            mock.patch.object(sys, "argv", ["pin_pdfium.py", "chromium/9999"]),
            mock.patch.object(sys, "stderr", io.StringIO()),
        ):
            return self.tool.main()

    def test_a_release_without_pdfiums_license_changes_neither_output(self):
        result = self._run(
            {"LICENSE": "pdfium-binaries", "licenses/zlib.txt": "zlib"}
        )

        self.assertEqual(result, 1)
        self.assertEqual(self.archives.read_text(), "old pins\n")
        self.assertEqual(self.notices.read_text(), "old notices\n")

    def test_a_complete_release_rewrites_both_outputs(self):
        result = self._run(
            {
                "LICENSE": "pdfium-binaries",
                "licenses/pdfium.txt": "Copyright 2014 The PDFium Authors",
                "licenses/zlib.txt": "zlib",
            }
        )

        self.assertEqual(result, 0)
        self.assertIn("chromium%2F9999", self.archives.read_text())
        notices = self.notices.read_text()
        for name in ("pdfium_dart", "pdfium", "pdfium-binaries", "zlib"):
            self.assertIn(f"\n{name}\n\n", "\n" + notices)


if __name__ == "__main__":
    unittest.main()
