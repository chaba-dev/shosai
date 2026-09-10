import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]


class FlutterIosIntegrationTest(unittest.TestCase):
    def test_dart_loads_the_embedded_ios_framework(self):
        source = (ROOT / "flutter/lib/main.dart").read_text()

        self.assertIn("if (Platform.isIOS)", source)
        self.assertIn(
            "'shosai_flutter_bridge.framework/shosai_flutter_bridge'", source
        )

    def test_rust_builder_maps_device_and_simulator_architectures(self):
        script = (ROOT / "flutter/rust_builder/ios/build.sh").read_text()

        self.assertIn("ios-pdfium/8046b/release", script)
        self.assertIn("iphoneos)", script)
        self.assertIn("rust_target=aarch64-apple-ios", script)
        self.assertIn("rust_target=aarch64-apple-ios-sim", script)
        self.assertIn("rust_target=x86_64-apple-ios", script)
        self.assertIn("/usr/bin/lipo", script)
        self.assertIn("--crate-type staticlib", script)

    def test_pod_force_loads_rust_and_links_pdfium_dependencies(self):
        podspec = (
            ROOT
            / "flutter/rust_builder/ios/shosai_flutter_bridge.podspec"
        ).read_text()

        self.assertIn("-force_load ${BUILT_PRODUCTS_DIR}/libshosai_flutter_bridge.a", podspec)
        self.assertIn("-lc++ -lz", podspec)
        self.assertIn("spec.frameworks = 'CoreGraphics'", podspec)
        self.assertIn(":always_out_of_date => '1'", podspec)

    def test_ios_core_uses_static_pdfium(self):
        manifest = (ROOT / "crates/shosai-core/Cargo.toml").read_text()
        source = (ROOT / "crates/shosai-core/src/pdf.rs").read_text()

        self.assertIn("cfg(target_os = \"ios\")", manifest)
        self.assertIn('"static"', manifest)
        self.assertIn("Pdfium::bind_to_statically_linked_library()", source)


if __name__ == "__main__":
    unittest.main()
