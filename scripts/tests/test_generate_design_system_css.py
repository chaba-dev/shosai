"""Tests for the design system CSS generator.

`docs/design-system/tokens.json` is the design system's token source and
`docs/design-system/tokens.css` is generated from it for the development viewer
and the component previews. These tests keep the committed CSS in sync and
check that every preview the viewer lists exists and loads the shared styles.
"""

import importlib.util
import json
import pathlib
import re
import subprocess
import sys
import unittest


REPOSITORY = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = REPOSITORY / "scripts" / "generate-design-system-css.py"
DESIGN_SYSTEM = REPOSITORY / "docs" / "design-system"
TOKENS = DESIGN_SYSTEM / "tokens.json"


def load_generator():
    spec = importlib.util.spec_from_file_location("generate_design_system_css", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class DesignSystemCssTest(unittest.TestCase):
    def setUp(self):
        self.generator = load_generator()
        self.tokens = json.loads(TOKENS.read_text(encoding="utf-8"))

    def test_committed_css_matches_the_token_source(self):
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--check"], capture_output=True, text=True
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_every_theme_defines_every_colour(self):
        css = self.generator.render(self.tokens)
        for theme in self.tokens["color"]["themes"]:
            block = re.search(
                r'\[data-theme="%s"\] \{(.*?)\n\}' % theme["id"], css, re.S
            )
            self.assertIsNotNone(block, theme["id"])
            for token in self.tokens["color"]["tokens"]:
                if isinstance(token["value"], dict):
                    self.assertIn(f"--{token['name']}:", block.group(1), token["name"])

    def test_references_become_custom_properties(self):
        self.assertEqual(self.generator._reference("{surface}"), "var(--surface)")
        self.assertEqual(self.generator._reference("#4d5e86"), "#4d5e86")

    def test_fonts_resolve_to_the_tracked_copies(self):
        css = self.generator.render(self.tokens)
        for url in re.findall(r'url\("([^"]+)"\)', css):
            self.assertTrue((DESIGN_SYSTEM / url).resolve().is_file(), url)

    def test_missing_font_is_rejected(self):
        tokens = json.loads(json.dumps(self.tokens))
        tokens["type"]["fonts"][0]["file"] = "assets/fonts/Missing.ttf"
        with self.assertRaises(self.generator.TokenError):
            self.generator.render(tokens)

    def test_viewer_lists_existing_previews_that_load_the_shared_styles(self):
        viewer = (DESIGN_SYSTEM / "index.html").read_text(encoding="utf-8")
        listed = set(re.findall(r"\['[^']+', '(\w+)', \d+", viewer)) | {"Cover"}
        previews = {path.stem for path in (DESIGN_SYSTEM / "components").glob("*.html")}
        self.assertEqual(listed, previews)
        for name in previews:
            html = (DESIGN_SYSTEM / "components" / f"{name}.html").read_text(encoding="utf-8")
            self.assertIn('href="../tokens.css"', html, name)
            self.assertIn('href="../components.css"', html, name)


if __name__ == "__main__":
    unittest.main()
