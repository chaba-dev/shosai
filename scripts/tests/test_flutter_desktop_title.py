import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]


class FlutterDesktopTitleTest(unittest.TestCase):
    def test_linux_window_has_a_title_and_no_client_side_title_strip(self):
        runner = (ROOT / "flutter/linux/runner/my_application.cc").read_text()

        # The window carries the application title, which is what the
        # compositor or window manager shows in the decoration it provides.
        self.assertIn('static const char kWindowTitle[] = "Shosai";', runner)
        self.assertIn("gtk_window_set_title(window, kWindowTitle);", runner)

        # The application draws no title strip of its own: the library header is
        # the top of the window content, and a GTK client-side decoration on
        # Wayland was a second, redundant strip above it.
        self.assertNotIn("gtk_header_bar_new", runner)
        self.assertNotIn("gtk_header_bar_set_title", runner)
        self.assertNotIn("gtk_window_set_titlebar", runner)

        # On Wayland GTK's client-side decoration stays off so the compositor
        # decorates the window and keeps drag, resize and close; on X11 the
        # window manager decorates the window instead.
        self.assertRegex(
            runner,
            re.compile(
                r"if \(!my_application_uses_x11\(window\)\) \{\s*"
                r"gtk_window_set_decorated\(window, FALSE\);\s*\}"
            ),
        )
        self.assertNotIn("gtk_window_set_decorated(window, TRUE)", runner)

    def test_macos_hides_the_window_title(self):
        window = (ROOT / "flutter/macos/Runner/MainFlutterWindow.swift").read_text()

        self.assertIn("titleVisibility = .hidden", window)


if __name__ == "__main__":
    unittest.main()
