import pathlib
import shutil
import subprocess
import unittest
import xml.etree.ElementTree as ET


ROOT = pathlib.Path(__file__).resolve().parents[2]


class FlutterAndroidIntegrationTest(unittest.TestCase):
    def test_open_in_shosai_advertises_only_books_and_local_view_uris(self):
        android = "{http://schemas.android.com/apk/res/android}"
        manifest = ET.parse(ROOT / "android/app/src/main/AndroidManifest.xml")
        activity = manifest.find(".//activity[@" + android + "name='.MainActivity']")
        filters = {
            item.find("action").get(android + "name"): item
            for item in activity.findall("intent-filter")
        }
        for action in ("VIEW", "SEND"):
            item = filters["android.intent.action." + action]
            self.assertEqual(
                {data.get(android + "mimeType") for data in item.findall("data")}
                - {None},
                {"application/epub+zip", "application/pdf"},
            )
            self.assertEqual(
                {category.get(android + "name") for category in item.findall("category")},
                {"android.intent.category.DEFAULT"},
            )
        self.assertEqual(
            {data.get(android + "scheme") for data in filters[
                "android.intent.action.VIEW"].findall("data")} - {None},
            {"content", "file"},
        )

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

    def test_launcher_icon_is_adaptive_with_the_logo_mark(self):
        # Without an adaptive icon, Android 8+ launchers shrink the square PNG
        # into a white circle. Debug and profile builds invert the colours.
        android = "{http://schemas.android.com/apk/res/android}"
        resources = ROOT / "android/app/src"
        icon = ET.parse(resources / "main/res/mipmap-anydpi-v26/ic_launcher.xml")
        layers = {
            layer.tag: layer.get(android + "drawable") for layer in icon.getroot()
        }
        self.assertEqual(layers, {
            "background": "@color/ic_launcher_background",
            "foreground": "@drawable/ic_launcher_foreground",
            "monochrome": "@drawable/ic_launcher_foreground",
        })

        foreground = ET.parse(resources / "main/res/drawable/ic_launcher_foreground.xml")
        mark = ET.parse(ROOT / "assets/logo/shosai-mark.svg")
        svg_path = mark.find("{http://www.w3.org/2000/svg}path").get("d")
        self.assertIn(svg_path, [
            path.get(android + "pathData") for path in foreground.iter("path")
        ])

        def colours(source_set):
            values = ET.parse(resources / source_set / "res/values/ic_launcher.xml")
            return {c.get("name"): c.text.lower() for c in values.iter("color")}

        release, development = colours("main"), colours("dev")
        self.assertEqual(release, {
            "ic_launcher_background": "#f3e4cc",
            "ic_launcher_mark": "#2d3848",
        })
        self.assertEqual(development, {
            "ic_launcher_background": release["ic_launcher_mark"],
            "ic_launcher_mark": release["ic_launcher_background"],
        })

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
