import pathlib
import shutil
import subprocess
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]


class FlutterAndroidIntegrationTest(unittest.TestCase):
    def test_debug_manifest_allows_network_access(self):
        manifest = ROOT / "android/app/src/debug/AndroidManifest.xml"

        self.assertIn("android.permission.INTERNET", manifest.read_text())

    def test_host_packages_every_abi(self):
        # SQLite and PDFium come from build hooks for every Android ABI, so
        # the host filters none (the arm64-only filter served the Rust core).
        build = (ROOT / "android/app/build.gradle.kts").read_text()
        properties = (ROOT / "android/gradle.properties").read_text()

        self.assertNotIn("abiFilters", build)
        self.assertNotIn("disable-abi-filtering", properties)

    @unittest.skipIf(shutil.which("git") is None, "git is not installed")
    def test_gradle_build_output_is_ignored(self):
        # Gradle writes reports/problems/problems-report.html here.
        report = "android/build/reports/problems/problems-report.html"
        result = subprocess.run(
            ["git", "check-ignore", "--no-index", "--quiet", report],
            cwd=ROOT,
            check=False,
        )

        self.assertEqual(result.returncode, 0, f"{report} is not ignored")


if __name__ == "__main__":
    unittest.main()
