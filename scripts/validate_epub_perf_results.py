#!/usr/bin/env python3
"""Validate that the EPUB performance matrix completed without partial results."""

import argparse
from pathlib import Path
import shlex


FIXTURES = ("large-text.epub", "large-image.epub")
WIDTHS = ("700", "1000")
ACTION_OPERATION = {
    "warm": "warm-page-turn",
    "chapter": "chapter-transition",
    "relayout": "relayout",
}


def fields(line: str) -> dict[str, str]:
    return dict(part.split("=", 1) for part in shlex.split(line)[1:] if "=" in part)


def expected_runs() -> set[tuple[str, str, str]]:
    expected = set()
    for width in WIDTHS:
        expected.add(("sample.epub", "chapter", width))
        expected.add(("sample.epub", "relayout", width))
        for fixture in FIXTURES:
            for action in ACTION_OPERATION:
                expected.add((fixture, action, width))
    return expected


def validate(content: str, requested_samples: int) -> None:
    runs: list[dict[str, object]] = []
    current: dict[str, object] | None = None

    for line in content.splitlines():
        if line.startswith("perf-run "):
            if current is not None:
                runs.append(current)
            current = {"run": fields(line), "configs": [], "summaries": []}
        elif line.startswith("perf-error"):
            raise ValueError(f"benchmark reported an error: {line}")
        elif current is not None and line.startswith("perf-config "):
            current["configs"].append(fields(line))
        elif current is not None and line.startswith("perf-summary "):
            current["summaries"].append(fields(line))
    if current is not None:
        runs.append(current)

    actual: set[tuple[str, str, str]] = set()
    for result in runs:
        run = result["run"]
        assert isinstance(run, dict)
        key = (run.get("fixture", ""), run.get("action", ""), run.get("width", ""))
        if key in actual:
            raise ValueError(f"duplicate benchmark run: {key}")
        actual.add(key)

        configs = result["configs"]
        summaries = result["summaries"]
        assert isinstance(configs, list) and isinstance(summaries, list)
        if len(configs) != 1:
            raise ValueError(f"expected one config for {key}, found {len(configs)}")
        if len(summaries) != 1:
            raise ValueError(f"expected one summary for {key}, found {len(summaries)}")

        expected_operation = ACTION_OPERATION.get(key[1])
        config = configs[0]
        summary = summaries[0]
        expected_samples = str(requested_samples)
        if config.get("fixture") != key[0] or config.get("action") != key[1]:
            raise ValueError(f"config does not match run {key}: {config}")
        if config.get("samples") != expected_samples:
            raise ValueError(f"config sample count does not match for {key}: {config}")
        if summary.get("fixture") != key[0] or summary.get("operation") != expected_operation:
            raise ValueError(f"summary does not match run {key}: {summary}")
        if summary.get("samples") != expected_samples:
            raise ValueError(f"summary sample count does not match for {key}: {summary}")

    expected = expected_runs()
    if actual != expected:
        missing = sorted(expected - actual)
        unexpected = sorted(actual - expected)
        raise ValueError(f"benchmark matrix mismatch; missing={missing}, unexpected={unexpected}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("log", type=Path)
    parser.add_argument("samples", type=int)
    args = parser.parse_args()
    try:
        validate(args.log.read_text(), args.samples)
    except ValueError as error:
        parser.error(str(error))
    print(f"validated {len(expected_runs())} EPUB performance summaries")


if __name__ == "__main__":
    main()
