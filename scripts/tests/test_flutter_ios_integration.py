import json
import pathlib
import re
import struct
import unittest
import xml.etree.ElementTree as ET


ROOT = pathlib.Path(__file__).resolve().parents[2]


class FlutterIosIntegrationTest(unittest.TestCase):
    def test_apple_build_modes_select_complete_icon_catalogs(self):
        for platform in ("ios", "macos"):
            with self.subTest(platform=platform):
                project = (ROOT / platform / "Runner.xcodeproj/project.pbxproj").read_text()
                icons = []
                for mode, settings in re.findall(
                    r'/\* (Debug|Profile|Release) \*/ = \{(.*?)\n\t\t\};', project, re.S
                ):
                    icon = re.search(r'ASSETCATALOG_COMPILER_APPICON_NAME = (\w+);', settings)
                    if icon:
                        icons.append((mode, icon[1]))
                self.assertCountEqual(icons, [
                    ("Debug", "AppIconDev"), ("Profile", "AppIconDev"),
                    ("Release", "AppIcon"),
                ])
                for name in ("AppIcon", "AppIconDev"):
                    catalog = ROOT / platform / f"Runner/Assets.xcassets/{name}.appiconset"
                    for image in json.loads((catalog / "Contents.json").read_text())["images"]:
                        png = (catalog / image["filename"]).read_bytes()
                        size = round(float(image["size"].split("x")[0]) * float(image["scale"][:-1]))
                        self.assertEqual(png[:8], b"\x89PNG\r\n\x1a\n")
                        self.assertEqual(struct.unpack(">II", png[16:24]), (size, size))
        self.assertEqual(
            (ROOT / "ios/Runner/Assets.xcassets/AppIconDev.appiconset/Icon-App-1024x1024@1x.png").read_bytes(),
            (ROOT / "assets/shosai-dev-icon.png").read_bytes(),
        )

    def test_initial_ios_controller_enables_native_state_restoration(self):
        storyboard = ET.parse(
            ROOT / "ios/Runner/Base.lproj/Main.storyboard"
        ).getroot()
        initial_controller_id = storyboard.attrib["initialViewController"]
        initial_controller = storyboard.find(
            f".//viewController[@id='{initial_controller_id}']"
        )

        self.assertIsNotNone(initial_controller)
        self.assertEqual(
            initial_controller.attrib.get("customClass"), "FlutterViewController"
        )
        self.assertEqual(
            initial_controller.attrib.get("restorationIdentifier"), "shosai-reader"
        )


if __name__ == "__main__":
    unittest.main()
