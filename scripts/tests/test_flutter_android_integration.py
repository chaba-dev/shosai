import pathlib
import shutil
import subprocess
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]


class FlutterAndroidIntegrationTest(unittest.TestCase):
    def test_debug_manifest_is_committed_despite_global_debug_ignore(self):
        ignore = (ROOT / ".gitignore").read_text()
        manifest = ROOT / "flutter/android/app/src/debug/AndroidManifest.xml"

        self.assertIn("!flutter/android/app/src/debug/", ignore)
        self.assertIn("android.permission.INTERNET", manifest.read_text())

    def test_host_packages_every_abi(self):
        # SQLite and PDFium come from build hooks for every Android ABI, so
        # the host filters none (the arm64-only filter served the Rust core).
        build = (ROOT / "flutter/android/app/build.gradle.kts").read_text()
        properties = (ROOT / "flutter/android/gradle.properties").read_text()

        self.assertNotIn("abiFilters", build)
        self.assertNotIn("disable-abi-filtering", properties)

    @unittest.skipIf(shutil.which("git") is None, "git is not installed")
    def test_gradle_build_output_is_ignored(self):
        # Gradle writes reports/problems/problems-report.html here.
        report = "flutter/android/build/reports/problems/problems-report.html"
        result = subprocess.run(
            ["git", "check-ignore", "--no-index", "--quiet", report],
            cwd=ROOT,
            check=False,
        )

        self.assertEqual(result.returncode, 0, f"{report} is not ignored")


if __name__ == "__main__":
    unittest.main()
