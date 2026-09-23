#!/usr/bin/env python3
"""Generate the Rust and Dart design-token modules from one tracked source.

`assets/theme/tokens.json` is the single tracked design-token source (plan
decision 2: "One tracked token source supplies both frontends"). This script
transcribes it into

* `crates/shosai-app/src/theme_tokens.rs` for the Iced application, and
* `flutter/lib/theme_tokens.dart` for the Flutter frontend,

and can verify that the committed files still match the source (`--check`).

The generated Rust module holds plain values; `crates/shosai-app/src/theme.rs`
converts them into `iced::Color` and keeps the public names. The generated Dart
module holds `dart:ui` colors directly, because the Flutter themes consume them
as colors.

Usage:

    scripts/generate-theme-tokens.py            # write both files
    scripts/generate-theme-tokens.py --check    # fail if either file differs
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
TOKENS_PATH = REPO_ROOT / "assets" / "theme" / "tokens.json"
RUST_PATH = REPO_ROOT / "crates" / "shosai-app" / "src" / "theme_tokens.rs"
DART_PATH = REPO_ROOT / "flutter" / "lib" / "theme_tokens.dart"

# The pinned Iced accent, and the historical #109 brown that plan decision 2
# rejects. Both are checked so a future edit cannot silently reintroduce the
# brown or drift the accent.
EXPECTED_ACCENT = "#4D5E86"
REJECTED_COLOR = "#8A6338"

_HEX_COLOR = re.compile(r"^#(?P<hex>[0-9A-Fa-f]{6}(?:[0-9A-Fa-f]{2})?)$")
_RGB_COLOR = re.compile(r"^rgb\((?P<r>[^,]+),(?P<g>[^,]+),(?P<b>[^)]+)\)$")
_RGBA_COLOR = re.compile(
    r"^rgba\((?P<rgb>#[0-9A-Fa-f]{6}|rgb\([^)]*\)),(?P<a>[^)]+)\)$"
)
_RGBA_FLOAT_COLOR = re.compile(
    r"^rgba\((?P<r>[^,]+),(?P<g>[^,]+),(?P<b>[^,]+),(?P<a>[^)]+)\)$"
)


class TokenError(Exception):
    """A token source or generation failure."""


@dataclass(frozen=True)
class Color:
    """One token color, in the representation the source declared."""

    # Channel form: "u8" for 0-255 integers, "f32" for 0.0-1.0 fractions.
    channels: str
    red: float
    green: float
    blue: float
    alpha: float


def _number(value: str, where: str) -> float:
    try:
        return float(value.strip())
    except ValueError as error:
        raise TokenError(f"{where}: {value!r} is not a number") from error


def parse_color(value: str, where: str) -> Color:
    """Parses one token color string.

    Supported forms mirror the reference specification's notation:

    * `#RRGGBB` and `#RRGGBBAA` — 8-bit channels
    * `rgb(0.1, 0.1, 0.1)` — fractional channels
    * `rgba(#RRGGBB, 0.5)` and `rgba(0.1, 0.1, 0.1, 0.5)`
    """
    if not isinstance(value, str):
        raise TokenError(f"{where}: color must be a string, got {value!r}")
    if match := _HEX_COLOR.match(value):
        digits = match.group("hex")
        red = int(digits[0:2], 16)
        green = int(digits[2:4], 16)
        blue = int(digits[4:6], 16)
        alpha = int(digits[6:8], 16) / 255.0 if len(digits) == 8 else 1.0
        return Color("u8", red, green, blue, alpha)
    if match := _RGBA_COLOR.match(value):
        base = parse_color(match.group("rgb"), where)
        alpha = _number(match.group("a"), where)
        return Color(base.channels, base.red, base.green, base.blue, alpha)
    if match := _RGB_COLOR.match(value):
        channels = [_number(match.group(name), where) for name in ("r", "g", "b")]
        _require_fraction(channels, where)
        return Color("f32", *channels, 1.0)
    if match := _RGBA_FLOAT_COLOR.match(value):
        channels = [_number(match.group(name), where) for name in ("r", "g", "b")]
        _require_fraction(channels, where)
        alpha = _number(match.group("a"), where)
        _require_fraction([alpha], where)
        return Color("f32", *channels, alpha)
    raise TokenError(f"{where}: {value!r} is not a supported color")


def _require_fraction(values: list[float], where: str) -> None:
    for value in values:
        if not 0.0 <= value <= 1.0:
            raise TokenError(f"{where}: fractional channel {value} is outside 0.0-1.0")


def _color_hex(color: Color) -> str:
    """The 8-bit hex form of a color, for invariant checks and messages.

    Fractional channels are rounded, so the same RGB value is rejected by the
    invariant checks however the token source spells it (as `#8A6338` or as
    `rgb(0.5412, 0.3882, 0.2196)`).
    """
    scale = 1.0 if color.channels == "u8" else 255.0
    digits = "".join(
        f"{round(channel * scale):02X}"
        for channel in (color.red, color.green, color.blue)
    )
    if color.alpha != 1.0:
        digits += f"{round(color.alpha * 255):02X}"
    return f"#{digits}"


def _rust_color(color: Color) -> tuple[str, str]:
    if color.channels == "u8":
        rgb = f"(0x{round(color.red):02X}, 0x{round(color.green):02X}, 0x{round(color.blue):02X})"
        type_name = "(u8, u8, u8)"
    else:
        rgb = f"({_float(color.red)}, {_float(color.green)}, {_float(color.blue)})"
        type_name = "(f32, f32, f32)"
    if color.alpha == 1.0:
        return rgb, type_name
    return f"({rgb}, {_float(color.alpha)})", f"({type_name}, f32)"


def _dart_color(color: Color) -> str:
    if color.channels == "u8":
        red = round(color.red)
        green = round(color.green)
        blue = round(color.blue)
        if color.alpha == 1.0:
            return f"Color(0xFF{red:02X}{green:02X}{blue:02X})"
        return f"Color.fromRGBO(0x{red:02X}, 0x{green:02X}, 0x{blue:02X}, {_float(color.alpha)})"
    return (
        "Color.from(alpha: {}, red: {}, green: {}, blue: {})".format(
            _float(color.alpha),
            _float(color.red),
            _float(color.green),
            _float(color.blue),
        )
    )


def _dart_member(name: str, value: str) -> list[str]:
    """One Dart constant, wrapped the way `dart format` wraps it.

    The generated file is committed, and CI checks it with
    `dart format --set-exit-if-changed`, so the generator has to emit the
    formatter's output. A declaration that fits the formatter's 80-column page
    stays on one line; otherwise the call's arguments are split one per line
    with a trailing comma, which is the formatter's only expansion for the
    constructors this file uses.
    """
    single = f"  static const {name} = {value};"
    if len(single) <= 80:
        return [single]
    open_paren = value.index("(")
    callee = value[:open_paren]
    arguments = value[open_paren + 1 : -1].split(", ")
    lines = [f"  static const {name} = {callee}("]
    lines.extend(f"    {argument}," for argument in arguments)
    lines.append("  );")
    return lines


def _dart_doc(path: str, authority: str) -> list[str]:
    """A wrapped Dart doc comment naming the token and its authority."""
    text = f"`{path}` — {authority}"
    lines: list[str] = []
    current = "  /// "
    for word in text.split():
        if len(current) > 4 and len(current) + len(word) + 1 > 78:
            lines.append(current.rstrip())
            current = "  /// "
        current += f"{word} "
    lines.append(current.rstrip())
    return lines


def _float(value: float) -> str:
    """A Dart/Rust float literal that keeps the source's exact value."""
    text = repr(float(value))
    if text.endswith(".0"):
        return text
    return text


def _rust_name(path: list[str]) -> str:
    parts = []
    for segment in path:
        for word in re.findall(r"[A-Za-z0-9]+", segment):
            parts.extend(re.findall(r"[A-Z]+(?![a-z])|[A-Z][a-z0-9]*|[a-z0-9]+", word))
    return "_".join(part.upper() for part in parts)


def _dart_name(path: list[str]) -> str:
    parts = []
    for index, segment in enumerate(path):
        words = re.findall(r"[A-Za-z0-9]+", segment)
        for word_index, word in enumerate(words):
            if index == 0 and word_index == 0:
                parts.append(word.lower())
            elif word_index == 0:
                parts.append(word[:1].upper() + word[1:])
            else:
                parts.append(word[:1].upper() + word[1:])
    return "".join(parts)


def _rust_type(value: object, where: str) -> str:
    if isinstance(value, bool):
        raise TokenError(f"{where}: booleans are not design tokens")
    if isinstance(value, int):
        return "u32"
    if isinstance(value, float):
        return "f32"
    raise TokenError(f"{where}: unsupported token value {value!r}")


def _rust_literal(value: object, where: str) -> str:
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        return _float(value)
    raise TokenError(f"{where}: unsupported token value {value!r}")


def _dart_literal(value: object) -> str:
    if isinstance(value, int):
        return str(value)
    return _float(float(value))


@dataclass(frozen=True)
class Token:
    path: tuple[str, ...]
    authority: str
    value: object

    @property
    def dotted(self) -> str:
        return ".".join(self.path)


def authority_for(path: tuple[str, ...], authority: dict[str, str]) -> str:
    """The authority of [path], from the longest matching key prefix.

    `app.dark` overrides `app`, and `reader.selection` overrides `reader`, so a
    generated constant cannot claim Iced for a retained-Flutter value.
    """
    dotted = ".".join(path)
    matches = [
        key
        for key in authority
        if dotted == key or dotted.startswith(f"{key}.")
    ]
    if not matches:
        return "unspecified"
    return authority[max(matches, key=len)]


def collect(tokens: dict, authority: dict[str, str]) -> list[Token]:
    """Flattens the token document, keeping the source's order."""
    collected: list[Token] = []

    def walk(node: object, path: list[str]) -> None:
        if isinstance(node, dict):
            for key, child in node.items():
                if key.startswith("_"):
                    continue
                walk(child, path + [key])
            return
        collected.append(Token(tuple(path), authority_for(tuple(path), authority), node))

    for section in ("app", "reader", "radius", "type", "layout"):
        if section not in tokens:
            raise TokenError(f"the token source is missing the {section!r} section")
        walk(tokens[section], [section])
    return collected


def token_colors(tokens: list[Token]) -> dict[str, Color]:
    """Every color token, parsed."""
    colors: dict[str, Color] = {}
    for token in tokens:
        if isinstance(token.value, str) and not token.value.startswith(
            ("#", "rgb(", "rgba(")
        ):
            continue
        if isinstance(token.value, str):
            colors[token.dotted] = parse_color(token.value, token.dotted)
    return colors


def validate(tokens: list[Token], document: dict) -> None:
    """Checks the invariants the token source must always hold."""
    for key in ("version", "meta"):
        if key not in document:
            raise TokenError(f"the token source is missing {key!r}")
    for key in ("reference_revision", "specification", "authority"):
        if key not in document["meta"]:
            raise TokenError(f"the token source meta is missing {key!r}")

    colors = token_colors(tokens)
    accent = colors.get("app.accent")
    if accent is None or _color_hex(accent).upper() != EXPECTED_ACCENT.upper():
        raise TokenError(
            f"app.accent must stay {EXPECTED_ACCENT} (plan decision 2); got "
            f"{None if accent is None else _color_hex(accent)}"
        )
    for name, color in colors.items():
        if _color_hex(color).upper().startswith(REJECTED_COLOR.upper()):
            raise TokenError(
                f"{name} is the rejected #109 brown {REJECTED_COLOR}; plan "
                "decision 2 requires the Iced accent instead"
            )

    reader_roles = {
        "background",
        "text",
        "link",
        "searchHighlight",
        "searchCurrent",
        "tableHeaderBackground",
        "tableHeaderBorder",
    }
    for theme in ("light", "dark", "sepia"):
        found = {token.path[-1] for token in tokens if token.path[:2] == ("reader", theme)}
        if found != reader_roles:
            raise TokenError(
                f"reader.{theme} must define exactly {sorted(reader_roles)}; got "
                f"{sorted(found)}"
            )

    for token in tokens:
        if token.path[:2] == ("type", "family") and token.path[-1] not in (
            "iced",
            "flutter",
        ):
            raise TokenError(
                f"{token.dotted}: font families are recorded per product with "
                "'iced' and 'flutter' keys"
            )
    family_paths = {
        token.path[:-1] for token in tokens if token.path[:2] == ("type", "family")
    }
    for path in family_paths:
        products = {
            token.path[-1] for token in tokens if token.path[:-1] == path
        }
        if products != {"iced", "flutter"}:
            raise TokenError(
                f"{'.'.join(path)} must record both the 'iced' and 'flutter' "
                f"family names; got {sorted(products)}"
            )


def render_rust(tokens: list[Token], document: dict) -> str:
    lines = [
        "//! Generated design tokens for the Iced application.",
        "//!",
        "//! Source: `assets/theme/tokens.json`, the single tracked design-token",
        "//! source, generated by `scripts/generate-theme-tokens.py`. Do not edit",
        "//! this file by hand; run `make theme-tokens` after changing the JSON.",
        "//!",
        f"//! Values are transcribed from the pinned Iced reference",
        f"//! `{document['meta']['reference_revision']}` and specified in",
        "//! `docs/flutter-ui-reference-spec.md` §3. `crate::theme` converts these",
        "//! plain values into `iced::Color` and re-exports the public names.",
        "",
        "// A token table: some values have no consumer until a later package maps",
        "// one, and an unconsumed token is not dead code.",
        "#![allow(dead_code)]",
        "",
    ]
    seen_sections: list[str] = []
    for token in tokens:
        section = token.path[0]
        if section not in seen_sections:
            seen_sections.append(section)
            lines += [
                "// ---------------------------------------------------------------------------",
                f"// {section}",
                "// ---------------------------------------------------------------------------",
                "",
            ]
        value = token.value
        if isinstance(value, str) and not value.startswith(("#", "rgb(", "rgba(")):
            lines.append(f'/// `{token.dotted}` — {token.authority}')
            lines.append(f'pub const {_rust_name(list(token.path))}: &str = "{value}";')
            lines.append("")
            continue
        if isinstance(value, str):
            literal, type_name = _rust_color(parse_color(value, token.dotted))
            lines.append(f"/// `{token.dotted}` — {token.authority}")
            lines.append(
                f"pub const {_rust_name(list(token.path))}: {type_name} = {literal};"
            )
            lines.append("")
            continue
        lines.append(f"/// `{token.dotted}` — {token.authority}")
        lines.append(
            f"pub const {_rust_name(list(token.path))}: "
            f"{_rust_type(value, token.dotted)} = {_rust_literal(value, token.dotted)};"
        )
        lines.append("")
    return "\n".join(lines).rstrip("\n") + "\n"


def render_dart(tokens: list[Token], document: dict) -> str:
    lines = [
        "// Generated design tokens for the Flutter frontend.",
        "//",
        "// Source: `assets/theme/tokens.json`, the single tracked design-token",
        "// source, generated by `scripts/generate-theme-tokens.py`. Do not edit",
        "// this file by hand; run `make theme-tokens` after changing the JSON.",
        "//",
        f"// Values are transcribed from the pinned Iced reference",
        f"// `{document['meta']['reference_revision']}` and specified in",
        "// `docs/flutter-ui-reference-spec.md` §3.",
        "",
        "import 'dart:ui' show Color;",
        "",
        "/// The shared design tokens, mapped from the pinned Iced reference.",
        "abstract final class ShosaiTokens {",
    ]
    seen_sections: list[str] = []
    for token in tokens:
        section = token.path[0]
        if section not in seen_sections:
            seen_sections.append(section)
            lines.append(
                f"  // -------------------------------------------------------------------------"
            )
            lines.append(f"  // {section}")
            lines.append(
                "  // -------------------------------------------------------------------------"
            )
        value = token.value
        name = _dart_name(list(token.path))
        lines.extend(_dart_doc(token.dotted, token.authority))
        if isinstance(value, str) and not value.startswith(("#", "rgb(", "rgba(")):
            lines.extend(_dart_member(name, f"'{value}'"))
        elif isinstance(value, str):
            lines.extend(
                _dart_member(name, _dart_color(parse_color(value, token.dotted)))
            )
        else:
            lines.extend(_dart_member(name, _dart_literal(value)))
        lines.append("")
    if lines and lines[-1] == "":
        lines.pop()  # `dart format` has no blank line before the closing brace
    lines.append("}")
    return "\n".join(lines).rstrip("\n") + "\n"


def display(path: Path) -> str:
    """The path as it is reported, relative to the repository when possible."""
    try:
        return str(path.relative_to(REPO_ROOT))
    except ValueError:
        return str(path)


def generate() -> dict[Path, str]:
    try:
        document = json.loads(TOKENS_PATH.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise TokenError(f"{TOKENS_PATH} does not exist") from error
    except json.JSONDecodeError as error:
        raise TokenError(f"{TOKENS_PATH} is not valid JSON: {error}") from error
    tokens = collect(document, document["meta"]["authority"])
    validate(tokens, document)
    return {
        RUST_PATH: render_rust(tokens, document),
        DART_PATH: render_dart(tokens, document),
    }


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="verify the committed generated files match the token source",
    )
    arguments = parser.parse_args(argv)
    try:
        generated = generate()
    except TokenError as error:
        print(f"theme tokens: {error}", file=sys.stderr)
        return 1

    if arguments.check:
        stale = [
            path
            for path, content in generated.items()
            if not path.exists() or path.read_text(encoding="utf-8") != content
        ]
        if stale:
            for path in stale:
                print(
                    f"theme tokens: {display(path)} is stale; run "
                    "`make theme-tokens`",
                    file=sys.stderr,
                )
            return 1
        print("theme tokens: generated files match assets/theme/tokens.json")
        return 0

    for path, content in generated.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
        print(f"theme tokens: wrote {display(path)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
