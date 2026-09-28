#!/usr/bin/env python3
"""Check independent 5A specification vectors, not a production renderer.

Uses only Python's standard library. No database, renderer, generated bridge,
network, screenshot, or fixture regeneration is involved. Consumers must test
their real implementation against the JSON values, not import these calculations.
"""

from __future__ import annotations

import copy
import hashlib
import json
import math
from pathlib import Path
import re
import unicodedata


ROOT = Path(__file__).resolve().parents[1]


def utf16_length(text: str) -> int:
    return len(text.encode("utf-16-le")) // 2


def resolved_zoom(book: dict | None, state: float | None, default: dict) -> dict:
    if book == {"kind": "inherit"}:
        return default
    return book or ({"kind": "manual", "scale": state} if state is not None else default)


def check_vectors(v: dict) -> None:
    assert v["version"] == 1
    scalar = v["scalar"]
    text = scalar["text"]
    assert len(text) == scalar["count"]
    assert utf16_length(text) == scalar["utf16_count"]
    # This literal fixture contains one combining sequence; this is not a
    # replacement for the renderer's full UAX #29 grapheme implementation.
    assert scalar["grapheme_boundaries"] == [0, 1, 2, 4, 5, 6, 7]
    assert unicodedata.combining(text[3]) != 0
    long = v["long"]
    long_text = (long["paragraph"] + long["separator"]) * long["repeat"]
    assert len(long_text) == long["scalar_count"] > 65536
    for case, source in [(scalar, text), (long, long_text)]:
        start, end = case["range"]
        assert source[start:end] == case["original"]
        assert unicodedata.normalize("NFC", source[start:end]) == case["normalized"]
        assert [utf16_length(source[:i]) for i in (start, end)] == case["utf16_range"]

    flow = v["reflow"]
    start, end = flow["range"]
    for key in ("a", "b"):
        intervals = flow[key]
        assert intervals[0][0] == 0 and intervals[-1][1] == 20
        assert all(a[1] == b[0] for a, b in zip(intervals, intervals[1:]))
        intersections = [
            [i, max(start, left), min(end, right)]
            for i, (left, right) in enumerate(intervals)
            if left < end and start < right
        ]
        assert intersections == flow[key + "_intersections"]
        for case in flow["locations"]:
            point = case["point"]
            candidates = [
                i for i, (left, right) in enumerate(intervals)
                if left <= point <= right
            ]
            index = candidates[0] if case["affinity"] == "upstream" else candidates[-1]
            assert index == case[key]

    mapping = v["mapping"]
    source = mapping["canonical"]
    assert source[slice(*mapping["image"])] == "cat"
    assert source[slice(*mapping["math"])] == "x+1"
    for hidden, expected in [
        ([mapping["image"], mapping["math"]], mapping["objects_copy"]),
        ([mapping["math"]], mapping["image_fallback_copy"]),
    ]:
        visible = "".join(
            char for i, char in enumerate(source)
            if not any(start <= i < end for start, end in hidden)
        )
        assert visible == expected
    # Only ASCII separators occur here; do not claim Python split implements
    # the whole versioned Rust quote-normalization whitespace profile.
    assert " ".join(source.split()) == mapping["normalized_canonical"]

    tiles = v["continuous"]
    rows, scale = tiles["rows"], tiles["scale"]
    assert rows[-1] == math.ceil(tiles["chapter_height"] * scale)
    assert rows[0] == 0 and all(a < b for a, b in zip(rows, rows[1:]))
    assert [row / scale for row in rows[:-1]] == tiles["origins"]
    assert [(b - a) / scale for a, b in zip(rows, rows[1:])] == tiles["heights"]
    assert math.isclose(tiles["chapter_height"] - tiles["origins"][-1], tiles["last_clip_height"])
    assert tiles["chapter_origin"] + tiles["chapter_height"] + tiles["spacing"] == tiles["next_chapter_origin"]

    for case in v["spreads"]:
        usable = (case["width"] - 20) / 2 - 40
        columns = 2 if case["width"] >= 720 and usable >= max(120, 12 * case["font"]) else 1
        assert columns == case["columns"]
    for case in v["progress"]:
        fraction = (case["offset"] or 0) / max(1, case["chapter_scalars"])
        if case["chapter_scalars"] == 0 and case.get("edge") == "end":
            fraction = 1
        assert (case["spine"] + fraction) / case["spines"] == case["expected"]
    for case in v["legacy_zoom"]:
        try:
            value = float(case["input"])
        except ValueError:
            value = math.nan
        if value == 0:
            kind = "fit-page"
        elif value == -1:
            kind = "fit-width"
        elif math.isfinite(value) and value > 0:
            kind = "manual"
            assert value == case["scale"]
        else:
            kind = "invalid"
        assert kind == case["kind"]
    for case in v["zoom_precedence"]:
        assert resolved_zoom(case["book"], case["legacy_state"], case["default"]) == case["expected"]
    for case in v["zoom_transitions"]:
        book, state = case["initial_book"], case["initial_state"]
        if case["action"] == "clear":
            book, state = {"kind": "inherit"}, 1.0
        elif case["action"] == "position":
            if book is None and state is None:
                book = {"kind": "inherit"}
            effective = resolved_zoom(book, state, case["default"])
            state = effective.get("scale", 1.0)
        else:
            assert case["action"] == "failed-clear"  # transaction is unchanged
        assert book == case["saved_book"] and state == case["saved_state"]
        assert resolved_zoom(book, state, case["default"]) == case["reopened"]
    assert v["legacy_state"] == [
        {"page": 2, "offset": None, "zoom": 1.75},
        {"page": 1, "offset": 72002, "zoom": 2.25},
    ]

    window = v["viewport_lookup"]
    for case in window["cases"]:
        matches = [d["id"] for d in window["descriptors"]
                   if d["top"] < case["bottom"] and case["top"] < d["bottom"]]
        if case["after"] is not None:
            matches = matches[matches.index(case["after"]) + 1:]
        selected = matches[:case["cap"]]
        assert selected == case["ids"]
        assert (selected[-1] if len(matches) > case["cap"] else None) == case["next"]
        assert (case["bottom"] >= window["extent"]) == case["end"]
    stale = window["stale_request"]
    assert stale["layout"] != window["layout"] and stale["expected"] == "StaleLayout"
    unknown = window["unknown_request"]
    assert unknown["work_remaining"] and unknown["top"] > unknown["known_prefix"]
    assert unknown["waiting"] is True and unknown["end"] is False

    pdf = v["pdf_geometry"]
    assert pdf["character_range"] is None and pdf["quote"] is None
    left, bottom, right, top = pdf["canonical_rect"]
    for layout in pdf["layouts"]:
        scale = layout["scale"]
        transformed = [left * scale, (pdf["page_height"] - top) * scale,
                       right * scale, (pdf["page_height"] - bottom) * scale]
        clip = layout["clip"]
        assert [max(transformed[0], clip[0]), max(transformed[1], clip[1]),
                min(transformed[2], clip[2]), min(transformed[3], clip[3])] == layout["expected"]

    context = v["context"]
    source = "x" * context["long_prefix_repeat"] + context["tail"]
    start, end = context["range"]
    assert source[start:end] == context["exact"]
    assert source[:start].strip()[-32:] == context["prefix"]
    assert source[end:].strip()[:32] == context["suffix"]
    cluster = unicodedata.normalize("NFC", context["boundary_grapheme"])
    assert len(cluster) == 2 and unicodedata.combining(cluster[1])
    assert context["ascii_repeat"] + len(cluster) > 32
    assert "a" * context["ascii_repeat"] == context["prefix_boundary_expected"]
    assert "b" * context["ascii_repeat"] == context["suffix_boundary_expected"]
    cap = context["cap_case"]
    assert cap["ignored_scalar"] == "\u00ad" and cap["repeat"] > cap["input_cap"]
    assert cap["expected"] == "ResourceLimit"


def check_negative_controls(v: dict) -> int:
    # Each plausible wrong interpretation must be rejected by the check above.
    mutations = [
        (("scalar", "utf16_range"), [1, 4]),          # scalars confused with UTF-16
        (("long", "original"), "ab日😀"),             # tile-local rather than global
        (("reflow", "b_intersections"), [[1, 8, 16]]),
        (("mapping", "objects_copy"), v["mapping"]["canonical"]),
        (("continuous", "next_chapter_origin"), 1085), # double chapter gap
        (("zoom_transitions", 1, "reopened"), {"kind": "manual", "scale": 1.0}),
        (("zoom_transitions", 4, "saved_book"), {"kind": "inherit"}),
        (("viewport_lookup", "cases", 1, "ids"), ["0:0", "0:1"]),
        (("pdf_geometry", "character_range"), [0, 1]),
        (("pdf_geometry", "layouts", 1, "expected"), [10, 150, 30, 180]),
        (("context", "prefix_boundary_expected"), "́" + "a" * 31),
        (("progress", 4, "expected"), 0.25),
    ]
    for path, wrong in mutations:
        mutated = copy.deepcopy(v)
        target = mutated
        for part in path[:-1]:
            target = target[part]
        target[path[-1]] = wrong
        try:
            check_vectors(mutated)
        except AssertionError:
            continue
        raise AssertionError(f"negative control not rejected: {path}")
    return len(mutations)


def check_documents() -> tuple[int, int]:
    plan = (ROOT / "docs/flutter-ui-restoration-plan.md").read_text()
    rows = re.findall(r"^- \[([ x])\] \*\*(\d[A-Z]) accepted", plan, re.M)
    assert len(rows) == 30
    accepted = sum(mark == "x" for mark, _ in rows)
    assert f"Delivery packages accepted: {accepted}/30" in plan
    stages = re.findall(r"\| (\d)\. [^\n]+\| (\d+)/(\d+) \| (TODO|IN PROGRESS|BLOCKED|DONE) \|", plan)
    assert len(stages) == 6
    for stage, count, total, status in stages:
        packages = [mark for mark, name in rows if name.startswith(stage)]
        assert len(packages) == int(total) and packages.count("x") == int(count)
        if status == "DONE":
            assert count == total
    for path in ["docs/flutter-renderer-persistence-contract.md", "docs/flutter-ui-restoration-plan.md"]:
        content = (ROOT / path).read_text()
        for link in re.findall(r"\]\(([^)]+)\)", content):
            if "://" not in link and not link.startswith("#"):
                assert (ROOT / path).parent.joinpath(link.split("#")[0]).exists(), link
        assert not any(line.rstrip() != line for line in content.splitlines())
    fixture_root = ROOT / "crates/shosai-core/tests/fixtures/epub-conformance"
    count = 0
    for line in (fixture_root / "SHA256SUMS").read_text().splitlines():
        digest, name = line.split(maxsplit=1)
        assert hashlib.sha256((fixture_root / name.lstrip("*")).read_bytes()).hexdigest() == digest
        count += 1
    return count, accepted


def main() -> None:
    vectors = json.loads((ROOT / "docs/renderer-contract-fixtures.json").read_text())
    check_vectors(vectors)
    mutations = check_negative_controls(vectors)
    fixtures, accepted = check_documents()
    print(f"5A contract checks passed: vectors, {mutations} negative controls, "
          f"{fixtures} conformance hashes, local links, 30 packages / {accepted} accepted.")
    print("No renderer, frontend/database round-trip, performance or visual pass is claimed.")


if __name__ == "__main__":
    main()
