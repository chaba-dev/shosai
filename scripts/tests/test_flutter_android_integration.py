import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]


class FlutterAndroidIntegrationTest(unittest.TestCase):
    def test_debug_manifest_is_committed_despite_global_debug_ignore(self):
        ignore = (ROOT / ".gitignore").read_text()
        manifest = ROOT / "flutter/android/app/src/debug/AndroidManifest.xml"

        self.assertIn("!flutter/android/app/src/debug/", ignore)
        self.assertIn("android.permission.INTERNET", manifest.read_text())

    def test_host_rejects_abis_without_packaged_native_libraries(self):
        build = (ROOT / "flutter/android/app/build.gradle.kts").read_text()
        properties = (ROOT / "flutter/android/gradle.properties").read_text()

        self.assertIn('abiFilters.add("arm64-v8a")', build)
        self.assertIn("disable-abi-filtering=true", properties)


if __name__ == "__main__":
    unittest.main()
