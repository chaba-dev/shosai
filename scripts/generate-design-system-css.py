#!/usr/bin/env python3
"""Generate the design system's CSS custom properties from its token file.

`docs/design-system/tokens.json` holds the Shōsai design system's tokens (see
`docs/design-system.md`). This script transcribes it into
`docs/design-system/tokens.css`, which the development viewer and every
component preview load, and can verify that the committed file still matches
the source (`--check`).

Usage:

    scripts/generate-design-system-css.py            # write tokens.css
    scripts/generate-design-system-css.py --check    # fail if tokens.css differs
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DESIGN_SYSTEM = REPO_ROOT / "docs" / "design-system"
TOKENS_PATH = DESIGN_SYSTEM / "tokens.json"
CSS_PATH = DESIGN_SYSTEM / "tokens.css"

HEADER = (
    "/* Shōsai design system tokens. Generated from docs/design-system/tokens.json\n"
    "   by scripts/generate-design-system-css.py; do not edit by hand. */\n"
)


class TokenError(Exception):
    """A token source or generation failure."""


def _value(value, theme: str, default_theme: str):
    """Returns a token's value in one theme, or None when it has none there."""
    if isinstance(value, str):
        return value if theme == default_theme else None
    if isinstance(value, dict):
        return value.get(theme)
    raise TokenError(f"unsupported token value {value!r}")


def _reference(value: str) -> str:
    """Turns a `{token}` reference into `var(--token)`."""
    if value.startswith("{") and value.endswith("}"):
        return f"var(--{value[1:-1]})"
    return value


def render(tokens: dict) -> str:
    themes = [theme["id"] for theme in tokens["color"]["themes"]]
    if not themes:
        raise TokenError("color.themes is empty")
    blocks = []

    # Colours and shadows change with the app theme. The first theme is also
    # the default, so a page without data-theme renders it.
    for index, theme in enumerate(themes):
        selector = f':root, [data-theme="{theme}"]' if index == 0 else f'[data-theme="{theme}"]'
        lines = []
        for group in ("color", "shadow"):
            for token in tokens[group]["tokens"]:
                value = _value(token["value"], theme, themes[0])
                if value is not None:
                    lines.append(f"  --{token['name']}: {_reference(value)};")
        blocks.append(selector + " {\n" + "\n".join(lines) + "\n}")

    # Space, radius and size tokens, and the three font roles.
    lines = []
    for group, entry in tokens.items():
        if group in ("color", "shadow", "type") or not isinstance(entry, dict):
            continue
        for token in entry.get("tokens", []):
            lines.append(f"  --{token['name']}: {token['value']};")
    for role, stack in tokens["type"]["families"].items():
        lines.append(f"  --font-{role}: {stack};")
    blocks.append(":root {\n" + "\n".join(lines) + "\n}")

    # Bundled faces, addressed from docs/design-system/ to the repository's
    # single copy under assets/fonts.
    for font in tokens["type"]["fonts"]:
        source = REPO_ROOT / font["file"]
        if not source.is_file():
            raise TokenError(f"font file {font['file']} does not exist")
        url = os.path.relpath(source, DESIGN_SYSTEM).replace(os.sep, "/")
        face = (
            f'font-family: "{font["family"]}"; src: url("{url}"); '
            f'font-weight: {font["weight"]}; font-style: {font.get("style", "normal")}; '
            "font-display: swap;"
        )
        if "unicodeRange" in font:
            face += f" unicode-range: {font['unicodeRange']};"
        blocks.append("@font-face { " + face + " }")

    # One class per text style.
    for group in tokens["type"]["groups"]:
        for style in group["styles"]:
            family = style.get("family", group["family"])
            css = (
                f"font-family: var(--font-{family}); font-size: {style['fontSize']}; "
                f"line-height: {style['lineHeight']}; font-weight: {style['fontWeight']};"
            )
            if "letterSpacing" in style:
                css += f" letter-spacing: {style['letterSpacing']};"
            blocks.append(f".{style['name']} {{ {css} }}")

    return HEADER + "\n".join(blocks) + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true", help="fail if tokens.css is out of date")
    args = parser.parse_args(argv)
    try:
        css = render(json.loads(TOKENS_PATH.read_text(encoding="utf-8")))
    except (TokenError, KeyError, json.JSONDecodeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    relative = CSS_PATH.relative_to(REPO_ROOT)
    if args.check:
        current = CSS_PATH.read_text(encoding="utf-8") if CSS_PATH.exists() else None
        if current != css:
            print(f"{relative} is out of date; run make design-system-css", file=sys.stderr)
            return 1
        return 0
    CSS_PATH.write_text(css, encoding="utf-8")
    print(f"wrote {relative}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
