import pathlib
import shutil
import subprocess
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]


class FlutterAndroidIntegrationTest(unittest.TestCase):
    def test_development_icon_overlay_covers_debug_and_profile(self):
        build = (ROOT / "android/app/build.gradle.kts").read_text()
        self.assertIn('if (name == "debug" || name == "profile")', build)
        self.assertIn('res.srcDir("src/dev/res")', build)
        resources = ROOT / "android/app/src"
        release = sorted((resources / "main/res").glob("mipmap-*/ic_launcher.png"))
        self.assertEqual(len(release), 5)
        for light in release:
            dark = resources / "dev/res" / light.relative_to(resources / "main/res")
            self.assertNotEqual(dark.read_bytes(), light.read_bytes())

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
