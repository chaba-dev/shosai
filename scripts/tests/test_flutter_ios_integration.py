import pathlib
import unittest
import xml.etree.ElementTree as ET


ROOT = pathlib.Path(__file__).resolve().parents[2]


class FlutterIosIntegrationTest(unittest.TestCase):
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
