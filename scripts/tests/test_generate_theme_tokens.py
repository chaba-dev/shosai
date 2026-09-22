"""Tests for the shared design-token generator.

The generator is the bridge between `assets/theme/tokens.json` (the single
tracked design-token source) and the two generated modules. These tests cover
the color grammar, the invariants the token source must hold, the deterministic
output, and the `--check` gate that keeps the committed files in sync.
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
RUST_OUTPUT = REPOSITORY / "crates" / "shosai-app" / "src" / "theme_tokens.rs"
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
        self.assertEqual(self.generator._rust_color(color)[0], "(0.1, 0.1, 0.1)")

    def test_rgba_over_hex_keeps_the_fractional_alpha(self):
        color = self.generator.parse_color("rgba(#21201E, 0.16)", "test")
        self.assertEqual(color.channels, "u8")
        self.assertEqual(color.alpha, 0.16)
        self.assertEqual(
            self.generator._rust_color(color),
            ("((0x21, 0x20, 0x1E), 0.16)", "((u8, u8, u8), f32)"),
        )
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

    def test_rust_names_split_camel_case_and_numbers(self):
        self.assertEqual(
            self.generator._rust_name(["app", "surfaceMuted"]), "APP_SURFACE_MUTED"
        )
        self.assertEqual(
            self.generator._rust_name(["reader", "light", "tableHeaderBackground"]),
            "READER_LIGHT_TABLE_HEADER_BACKGROUND",
        )
        self.assertEqual(self.generator._rust_name(["type", "size", "26"]), "TYPE_SIZE_26")

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

    def test_the_accent_is_the_iced_value(self):
        colors = self.generator.token_colors(
            self.generator.collect(
                self.document, self.document["meta"]["authority"]
            )
        )
        self.assertEqual(self.generator._color_hex(colors["app.accent"]), "#4D5E86")

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

    def test_retained_values_are_not_generated_as_iced(self):
        rust = self.generator.generate()[RUST_OUTPUT]
        dark_line = next(
            line
            for line in rust.splitlines()
            if line.startswith("pub const APP_DARK_BACKGROUND")
        )
        authority_line = rust.splitlines()[
            rust.splitlines().index(dark_line) - 1
        ]
        self.assertIn("Retained Flutter", authority_line)
        self.assertNotIn("Iced (crates/shosai-app", authority_line)

    def test_dart_documentation_names_each_token_and_its_authority(self):
        dart = self.generator.generate()[DART_OUTPUT]
        self.assertIn("/// `app.dark.background` — Retained Flutter", dart)
        self.assertIn("/// `reader.selection.dragFill` — Retained Flutter", dart)
        self.assertIn("/// `app.accent` — Iced", dart)
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

    def test_a_family_without_both_product_names_fails_validation(self):
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
        original = self.generator.RUST_PATH
        with tempfile.TemporaryDirectory() as temporary:
            stale = pathlib.Path(temporary) / "theme_tokens.rs"
            stale.write_text("// stale\n", encoding="utf-8")
            self.generator.RUST_PATH = stale
            try:
                self.assertEqual(self.generator.main(["--check"]), 1)
            finally:
                self.generator.RUST_PATH = original

    def test_rust_output_uses_plain_values_and_dart_output_uses_colors(self):
        rust = self.generated[RUST_OUTPUT]
        dart = self.generated[DART_OUTPUT]
        self.assertIn("pub const APP_ACCENT: (u8, u8, u8) = (0x4D, 0x5E, 0x86);", rust)
        self.assertIn("static const appAccent = Color(0xFF4D5E86);", dart)
        self.assertIn("#![allow(dead_code)]", rust)
        self.assertIn("import 'dart:ui' show Color;", dart)
        # The generated modules are transcriptions: no theme value may be
        # written as a literal in the sources that consume them.
        self.assertNotIn("Color::from_rgb8(0x", rust)
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
