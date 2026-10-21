"""Tests for the shared design-token generator.

The generator is the bridge between `assets/theme/tokens.json` (the single
tracked design-token source) and the generated Dart module. These tests cover
the color grammar, the invariants the token source must hold, the deterministic
output, and the `--check` gate that keeps the committed file in sync.
"""

import importlib.util
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest


REPOSITORY = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = REPOSITORY / "scripts" / "generate-theme-tokens.py"
TOKENS = REPOSITORY / "assets" / "theme" / "tokens.json"
DESIGN_SYSTEM_TOKENS = REPOSITORY / "docs" / "design-system" / "tokens.json"
DART_OUTPUT = REPOSITORY / "flutter" / "lib" / "theme_tokens.dart"


def load_generator():
    spec = importlib.util.spec_from_file_location("generate_theme_tokens", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    # `dataclasses` resolves annotations through `sys.modules[cls.__module__]`,
    # so the module has to be registered before it is executed.
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class ColorGrammarTest(unittest.TestCase):
    def setUp(self):
        self.generator = load_generator()

    def test_opaque_hex_is_eight_bit(self):
        color = self.generator.parse_color("#4D5E86", "test")
        self.assertEqual(color.channels, "u8")
        self.assertEqual((color.red, color.green, color.blue), (0x4D, 0x5E, 0x86))
        self.assertEqual(color.alpha, 1.0)
        self.assertEqual(self.generator._color_hex(color), "#4D5E86")

    def test_hex_with_alpha_keeps_the_alpha_channel(self):
        color = self.generator.parse_color("#21201E29", "test")
        self.assertAlmostEqual(color.alpha, 0x29 / 255.0)
        self.assertEqual(self.generator._color_hex(color), "#21201E29")

    def test_fractional_rgb_is_preserved_exactly(self):
        color = self.generator.parse_color("rgb(0.1, 0.1, 0.1)", "test")
        self.assertEqual(color.channels, "f32")
        self.assertEqual((color.red, color.green, color.blue), (0.1, 0.1, 0.1))
        self.assertEqual(
            self.generator._dart_color(color),
            "Color.from(alpha: 1.0, red: 0.1, green: 0.1, blue: 0.1)",
        )

    def test_rgba_over_hex_keeps_the_fractional_alpha(self):
        color = self.generator.parse_color("rgba(#21201E, 0.16)", "test")
        self.assertEqual(color.channels, "u8")
        self.assertEqual(color.alpha, 0.16)
        self.assertEqual(
            self.generator._dart_color(color),
            "Color.fromRGBO(0x21, 0x20, 0x1E, 0.16)",
        )

    def test_fractional_rgba_is_preserved(self):
        color = self.generator.parse_color("rgba(0.12, 0.12, 0.14, 0.5)", "test")
        self.assertEqual(color.channels, "f32")
        self.assertEqual(color.alpha, 0.5)
        self.assertEqual(
            self.generator._dart_color(color),
            "Color.from(alpha: 0.5, red: 0.12, green: 0.12, blue: 0.14)",
        )

    def test_out_of_range_fractional_channels_are_refused(self):
        with self.assertRaises(self.generator.TokenError):
            self.generator.parse_color("rgb(1.5, 0.0, 0.0)", "test")

    def test_unsupported_notation_is_refused(self):
        for value in ("red", "#FFF", "hsl(0, 0%, 0%)", "rgb(1,2)"):
            with self.subTest(value=value):
                with self.assertRaises(self.generator.TokenError):
                    self.generator.parse_color(value, "test")


class NameMappingTest(unittest.TestCase):
    def setUp(self):
        self.generator = load_generator()

    def test_dart_names_are_camel_case(self):
        self.assertEqual(
            self.generator._dart_name(["app", "surfaceMuted"]), "appSurfaceMuted"
        )
        self.assertEqual(
            self.generator._dart_name(["reader", "sepia", "tableHeaderBorder"]),
            "readerSepiaTableHeaderBorder",
        )
        self.assertEqual(self.generator._dart_name(["type", "size", "26"]), "typeSize26")

    def test_the_canonical_hex_form_rounds_fractional_channels(self):
        color = self.generator.parse_color("rgb(0.5412, 0.3882, 0.2196)", "test")
        self.assertEqual(self.generator._color_hex(color).upper(), "#8A6338")


class TokenSourceTest(unittest.TestCase):
    def setUp(self):
        self.generator = load_generator()
        self.document = json.loads(TOKENS.read_text(encoding="utf-8"))

    def test_the_source_validates(self):
        tokens = self.generator.collect(
            self.document, self.document["meta"]["authority"]
        )
        self.generator.validate(tokens, self.document)
        self.assertGreater(len(tokens), 100)

    def test_the_accent_is_the_design_system_slate(self):
        colors = self.generator.token_colors(
            self.generator.collect(
                self.document, self.document["meta"]["authority"]
            )
        )
        self.assertEqual(self.generator._color_hex(colors["app.accent"]), "#2B3A5C")
        self.assertEqual(
            self.generator._color_hex(colors["color.light.accent"]), "#2B3A5C"
        )

    def test_references_resolve_to_the_referenced_value(self):
        tokens = self.generator.collect(
            self.document, self.document["meta"]["authority"]
        )
        by_path = {token.dotted: token for token in tokens}
        background = by_path["app.background"]
        self.assertEqual(background.reference, "color.light.canvas")
        self.assertEqual(background.value, by_path["color.light.canvas"].value)
        # A chain resolves to its end: controlRaised -> surface.
        raised = by_path["color.light.controlRaised"]
        self.assertEqual(raised.value, by_path["color.light.surface"].value)

    def test_a_missing_reference_fails(self):
        document = json.loads(json.dumps(self.document))
        document["app"]["background"] = "{color.light.nothing}"
        with self.assertRaises(self.generator.TokenError):
            self.generator.collect(document, document["meta"]["authority"])

    def test_a_reference_cycle_fails(self):
        document = json.loads(json.dumps(self.document))
        document["color"]["light"]["canvas"] = "{app.background}"
        with self.assertRaises(self.generator.TokenError):
            self.generator.collect(document, document["meta"]["authority"])

    def test_the_colors_are_the_design_system_tokens(self):
        """Every design-system color is transcribed under its own name."""
        design = json.loads(DESIGN_SYSTEM_TOKENS.read_text(encoding="utf-8"))
        colors = self.generator.token_colors(
            self.generator.collect(
                self.document, self.document["meta"]["authority"]
            )
        )

        def camel(name):
            first, *rest = name.split("-")
            return first + "".join(word[:1].upper() + word[1:] for word in rest)

        def canonical(value, theme):
            if value.startswith("{"):
                target = next(
                    token
                    for token in design["color"]["tokens"]
                    if token["name"] == value[1:-1]
                )
                target_value = target["value"]
                if isinstance(target_value, dict):
                    target_value = target_value[theme]
                return canonical(target_value, theme)
            if value.startswith("rgba("):
                red, green, blue, alpha = (
                    part.strip() for part in value[5:-1].split(",")
                )
                return (
                    f"#{int(red):02X}{int(green):02X}{int(blue):02X}"
                    f"{round(float(alpha) * 255):02X}"
                )
            return value.upper()

        for token in design["color"]["tokens"]:
            value = token["value"]
            themes = ("light", "dark") if isinstance(value, dict) else (None,)
            for theme in themes:
                path = (
                    f"color.{theme}.{camel(token['name'])}"
                    if theme
                    else f"color.{camel(token['name'])}"
                )
                expected = canonical(value[theme] if theme else value, theme)
                with self.subTest(path=path):
                    self.assertIn(path, colors)
                    self.assertEqual(
                        self.generator._color_hex(colors[path]).upper(), expected
                    )

    def test_the_metrics_are_the_design_system_tokens(self):
        design = json.loads(DESIGN_SYSTEM_TOKENS.read_text(encoding="utf-8"))

        def pixels(value):
            return float(value.removesuffix("px").removesuffix("em"))

        for token in design["spacing"]["tokens"]:
            number = token["name"].removeprefix("space-")
            self.assertEqual(self.document["space"][number], pixels(token["value"]))
        for token in design["radius"]["tokens"]:
            key = token["name"].removeprefix("radius-")
            self.assertEqual(self.document["radius"][key], pixels(token["value"]))
        for token in design["size"]["tokens"]:
            first, *rest = token["name"].split("-")
            key = first + "".join(word.capitalize() for word in rest)
            self.assertEqual(self.document["size"][key], pixels(token["value"]))

    def test_the_historical_brown_is_not_a_token_value(self):
        tokens = self.generator.collect(
            self.document, self.document["meta"]["authority"]
        )
        for name, color in self.generator.token_colors(tokens).items():
            self.assertNotEqual(
                self.generator._color_hex(color).upper(),
                "#8A6338",
                f"{name} reintroduces the rejected #109 brown",
            )

    def test_a_changed_accent_fails_validation(self):
        document = json.loads(json.dumps(self.document))
        document["app"]["accent"] = "#8A6338"
        tokens = self.generator.collect(document, document["meta"]["authority"])
        with self.assertRaises(self.generator.TokenError):
            self.generator.validate(tokens, document)

    def test_a_reader_palette_missing_a_role_fails_validation(self):
        document = json.loads(json.dumps(self.document))
        del document["reader"]["dark"]["link"]
        tokens = self.generator.collect(document, document["meta"]["authority"])
        with self.assertRaises(self.generator.TokenError):
            self.generator.validate(tokens, document)

    def test_authority_uses_the_longest_matching_prefix(self):
        authority = self.document["meta"]["authority"]
        self.assertEqual(
            self.generator.authority_for(("app", "background"), authority),
            authority["app"],
        )
        self.assertEqual(
            self.generator.authority_for(("app", "dark", "background"), authority),
            authority["app.dark"],
        )
        self.assertEqual(
            self.generator.authority_for(("reader", "light", "text"), authority),
            authority["reader"],
        )
        self.assertEqual(
            self.generator.authority_for(("reader", "selection", "dragFill"), authority),
            authority["reader.selection"],
        )
        self.assertEqual(
            self.generator.authority_for(("reader", "annotation", "green"), authority),
            authority["reader.annotation"],
        )
        self.assertEqual(
            self.generator.authority_for(("radius", "small"), authority),
            authority["radius"],
        )

    def test_design_system_values_are_not_generated_as_iced(self):
        dart = self.generator.generate()[DART_OUTPUT]
        lines = dart.splitlines()
        index = next(
            index
            for index, line in enumerate(lines)
            if "static const appDarkBackground" in line
        )
        documentation = []
        while lines[index - 1].startswith("  ///"):
            index -= 1
            documentation.insert(0, lines[index].removeprefix("  ///").strip())
        authority = " ".join(documentation)
        self.assertIn("`app.dark.background` — Design system dark theme", authority)
        self.assertNotIn("Iced", authority)

    def test_dart_documentation_names_each_token_and_its_authority(self):
        dart = self.generator.generate()[DART_OUTPUT]
        self.assertIn("/// `app.dark.background` — Design system dark theme", dart)
        self.assertIn("/// `reader.selection.dragFill` — Design system", dart)
        self.assertIn("/// `app.accent` — Design system light theme", dart)
        self.assertIn("/// `layout.library.gridMinColumn` — Iced", dart)
        for line in dart.splitlines():
            self.assertLessEqual(len(line), 80, line)

    def test_the_brown_is_rejected_in_any_color_notation(self):
        for notation in ("#8A6338", "rgb(0.5412, 0.3882, 0.2196)"):
            with self.subTest(notation=notation):
                document = json.loads(json.dumps(self.document))
                document["app"]["accent"] = notation
                tokens = self.generator.collect(document, document["meta"]["authority"])
                with self.assertRaises(self.generator.TokenError):
                    self.generator.validate(tokens, document)

    def test_a_family_without_the_flutter_name_fails_validation(self):
        document = json.loads(json.dumps(self.document))
        del document["type"]["family"]["ui"]["latin"]["flutter"]
        tokens = self.generator.collect(document, document["meta"]["authority"])
        with self.assertRaises(self.generator.TokenError):
            self.generator.validate(tokens, document)


class GeneratedFileTest(unittest.TestCase):
    def setUp(self):
        self.generator = load_generator()
        self.generated = self.generator.generate()

    def test_generation_is_deterministic(self):
        self.assertEqual(self.generated, self.generator.generate())

    def test_the_committed_files_match_the_source(self):
        for path, content in self.generated.items():
            self.assertTrue(path.exists(), f"{path} is missing")
            self.assertEqual(
                path.read_text(encoding="utf-8"),
                content,
                f"{path} is stale; run make theme-tokens",
            )

    def test_check_mode_accepts_the_committed_files(self):
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--check"],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("match", result.stdout)

    def test_check_mode_rejects_a_stale_file(self):
        original = self.generator.DART_PATH
        with tempfile.TemporaryDirectory() as temporary:
            stale = pathlib.Path(temporary) / "theme_tokens.dart"
            stale.write_text("// stale\n", encoding="utf-8")
            self.generator.DART_PATH = stale
            try:
                self.assertEqual(self.generator.main(["--check"]), 1)
            finally:
                self.generator.DART_PATH = original

    def test_only_the_dart_module_is_generated(self):
        self.assertEqual(list(self.generated), [self.generator.DART_PATH])

    def test_dart_output_uses_colors(self):
        dart = self.generated[DART_OUTPUT]
        self.assertIn("static const colorLightAccent = Color(0xFF2B3A5C);", dart)
        # A reference names the referenced constant instead of repeating it.
        self.assertIn("static const appAccent = colorLightAccent;", dart)
        self.assertIn("import 'dart:ui' show Color;", dart)
        # The generated module is a transcription: no theme value may be
        # written as a literal in the sources that consume it.
        self.assertNotIn("withOpacity", dart)

    def test_dart_output_fits_the_formatter_page(self):
        dart = self.generated[DART_OUTPUT]
        for line in dart.splitlines():
            self.assertLessEqual(len(line), 80, line)


class MakefileTest(unittest.TestCase):
    def test_the_token_targets_exist(self):
        makefile = (REPOSITORY / "Makefile").read_text(encoding="utf-8")
        self.assertIn("check-theme-tokens:", makefile)
        self.assertIn("theme-tokens:", makefile)
        self.assertIn("scripts/generate-theme-tokens.py", makefile)


if __name__ == "__main__":
    unittest.main()
