#!/usr/bin/env python3
"""Run and validate the RFD 4 M2 profile-mode measurement slice."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import math
import pathlib
import subprocess
import sys
from collections.abc import Sequence


MARKER = "SHOSAI_M2_METRICS:"
RSS_WINDOW = 5
RSS_GROWTH_TOLERANCE_BYTES = 1024 * 1024


def nearest_rank(values: Sequence[float], percentile: float) -> float:
    if not values:
        raise ValueError("cannot calculate a percentile of no values")
    ordered = sorted(values)
    index = max(1, math.ceil(percentile * len(ordered))) - 1
    return ordered[index]


def median(values: Sequence[float]) -> float:
    ordered = sorted(values)
    middle = len(ordered) // 2
    if len(ordered) % 2:
        return float(ordered[middle])
    return (ordered[middle - 1] + ordered[middle]) / 2


def parse_report(output: str) -> dict[str, object]:
    lines = [line for line in output.splitlines() if MARKER in line]
    chunks: dict[int, str] = {}
    expected_count: int | None = None
    for line in lines:
        header, chunk = line.split(MARKER, 1)[1].split(":", 1)
        index_text, count_text = header.split("/", 1)
        index, count = int(index_text), int(count_text)
        if expected_count is None:
            expected_count = count
        if count != expected_count or not 1 <= index <= count or index in chunks:
            raise ValueError("measurement report has inconsistent chunks")
        chunks[index] = chunk
    if expected_count is None or len(chunks) != expected_count:
        raise ValueError(
            f"expected a complete {MARKER} record, found {len(chunks)} chunks"
        )
    return json.loads("".join(chunks[index] for index in range(1, expected_count + 1)))


def evaluate(report: dict[str, object]) -> dict[str, object]:
    m2 = report["m2"]
    frames = report["drag_frames"]
    if not isinstance(m2, dict) or not isinstance(frames, dict):
        raise ValueError("measurement report has invalid sections")
    build = frames["frame_build_times"]
    raster = frames["frame_rasterizer_times"]
    if not isinstance(build, list) or not isinstance(raster, list) or len(build) != len(raster):
        raise ValueError("frame timing vectors must have equal lengths")
    submission_ms = [float(value) / 1000 for value in build]
    rss = m2["resource_cycle_rss_bytes"]
    if not isinstance(rss, list) or len(rss) < RSS_WINDOW * 2:
        raise ValueError("resource cycle RSS requires two complete windows")
    rss_growth = median(rss[-RSS_WINDOW:]) - median(rss[:RSS_WINDOW])
    mobile = m2["platform"] in {"android", "ios"}
    gates = {
        "bridge_p95_at_most_1_ms": m2["bridge_round_trip_ms"]["p95"] <= 1,
        "scene_p95_at_most_4_ms": m2["visible_scene_dto_round_trip_ms"]["p95"] <= 4,
        "drag_p95_at_most_8_ms": nearest_rank(submission_ms, 0.95) <= 8,
        "drag_max_at_most_16_7_ms": max(submission_ms) <= 16.7,
        "rss_at_most_budget": m2["peak_rss_bytes"] <= (384 if mobile else 512) * 1024 * 1024,
        "rss_has_no_positive_cycle_trend": rss_growth <= RSS_GROWTH_TOLERANCE_BYTES,
    }
    return {
        "gates": gates,
        "drag_overlay_submission_ms": {
            "p50": nearest_rank(submission_ms, 0.50),
            "p95": nearest_rank(submission_ms, 0.95),
            "max": max(submission_ms),
        },
        "rss_window_median_growth_bytes": rss_growth,
        "rss_growth_tolerance_bytes": RSS_GROWTH_TOLERANCE_BYTES,
        "passed": all(gates.values()),
    }


def measurement_command(root: pathlib.Path, device: str) -> list[str]:
    return [
        str(root / ".agents" / "dev"),
        "flutter",
        "drive",
        "--driver=integration_test/driver.dart",
        "--target=integration_test/m2_metrics_test.dart",
        "-d",
        device,
        "--profile",
        "--no-dds",
    ]


def test_output_failed(output: str) -> bool:
    return "Some tests failed." in output


def effective_return_code(return_code: int, output: str) -> int:
    return return_code or int(test_output_failed(output))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--device", required=True, help="Flutter device ID")
    parser.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args()
    root = pathlib.Path(__file__).resolve().parent.parent
    process = subprocess.Popen(
        measurement_command(root, args.device),
        cwd=root / "flutter",
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    assert process.stdout is not None
    lines = []
    for line in process.stdout:
        print(line, end="")
        lines.append(line)
    return_code = process.wait()
    output = "".join(lines)
    if status := effective_return_code(return_code, output):
        return status
    report = parse_report(output)
    report["evaluation"] = evaluate(report)
    report["measured_at"] = dt.datetime.now(dt.UTC).isoformat()
    report["device_id"] = args.device
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    if not report["evaluation"]["passed"]:
        print(f"M2 measurement gates failed; see {args.output}", file=sys.stderr)
        return 1
    print(f"M2 measurement gates passed; wrote {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
