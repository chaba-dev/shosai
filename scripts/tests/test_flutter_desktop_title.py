import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]


class FlutterDesktopTitleTest(unittest.TestCase):
    def test_linux_window_and_header_bar_carry_the_application_title(self):
        runner = (ROOT / "flutter/linux/runner/my_application.cc").read_text()

        # The window and the header bar both carry the application title. The
        # header bar is what holds the drag and close controls on Wayland and
        # on X11/GNOME, so it stays and is titled; an empty title left the
        # native strip blank and the compositor without a window name.
        self.assertIn('static const char kWindowTitle[] = "Shosai";', runner)
        self.assertRegex(
            runner,
            re.compile(
                r"gtk_header_bar_set_title\(header_bar, kWindowTitle\);\s*"
                r"gtk_window_set_titlebar\(window, GTK_WIDGET\(header_bar\)\);\s*"
                r"}\s*gtk_window_set_title\(window, kWindowTitle\);"
            ),
        )
        self.assertNotIn('gtk_window_set_title(window, "");', runner)

    def test_macos_hides_the_window_title(self):
        window = (ROOT / "flutter/macos/Runner/MainFlutterWindow.swift").read_text()

        self.assertIn("titleVisibility = .hidden", window)


if __name__ == "__main__":
    unittest.main()
