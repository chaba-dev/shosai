import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]


class FlutterDesktopTitleTest(unittest.TestCase):
    def test_linux_window_title_and_decoration_policy(self):
        runner = (ROOT / "flutter/linux/runner/my_application.cc").read_text()

        # The window carries the application title, which is what the
        # compositor or window manager shows in whatever decoration it provides.
        self.assertIn('static const char kWindowTitle[] = "Shosai";', runner)
        self.assertIn("gtk_window_set_title(window, kWindowTitle);", runner)

        # The application draws no title strip of its own: the library header is
        # the top of the window content, and a GTK client-side decoration on
        # Wayland was a second, redundant strip above it.
        self.assertNotIn("gtk_header_bar_new", runner)
        self.assertNotIn("gtk_header_bar_set_title", runner)
        self.assertNotIn("gtk_window_set_titlebar", runner)

        # The decoration decision is the platform's: on Wayland GTK's
        # client-side decoration stays off, so the compositor's own decoration
        # policy and window management (move, resize, close) apply; on X11 the
        # window manager decorates the window instead.
        self.assertEqual(runner.count("gtk_window_set_decorated("), 1)
        self.assertRegex(
            runner,
            re.compile(
                r"if \(!my_application_uses_x11\(window\)\) \{\s*"
                r"gtk_window_set_decorated\(window, FALSE\);\s*\}"
            ),
        )
        self.assertNotIn("gtk_window_set_decorated(window, TRUE)", runner)

        # The check is the runtime backend check, not a window manager name
        # heuristic, and a window without X11 support is not X11.
        self.assertRegex(
            runner,
            re.compile(
                r"static gboolean my_application_uses_x11\(GtkWindow\* window\)"
                r" \{\s*"
                r"#ifdef GDK_WINDOWING_X11\s*"
                r"return GDK_IS_X11_SCREEN\(gtk_window_get_screen\(window\)\);"
                r"\s*"
                r"#else\s*"
                r"return FALSE;\s*"
                r"#endif\s*\}"
            ),
        )

    def test_macos_hides_the_window_title(self):
        window = (ROOT / "flutter/macos/Runner/MainFlutterWindow.swift").read_text()

        self.assertIn("titleVisibility = .hidden", window)


if __name__ == "__main__":
    unittest.main()
