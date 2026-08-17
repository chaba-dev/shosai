import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest


BENCHMARK_DIR = Path(__file__).resolve().parents[1]


def load_script(name: str):
    path = BENCHMARK_DIR / name
    spec = importlib.util.spec_from_file_location(path.stem, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


generator = load_script("generate-fixtures.py")
validator = load_script("validate-results.py")


class EpubPerfToolTests(unittest.TestCase):
    def test_generated_epubs_are_byte_reproducible(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for workload in ("text", "image"):
                first = root / f"first-{workload}.epub"
                second = root / f"second-{workload}.epub"
                generator.write_epub(first, workload)
                generator.write_epub(second, workload)
                self.assertEqual(
                    hashlib.sha256(first.read_bytes()).digest(),
                    hashlib.sha256(second.read_bytes()).digest(),
                )

    def complete_log(self, samples=50):
        lines = []
        for fixture, action, width in sorted(validator.expected_runs()):
            operation = validator.ACTION_OPERATION[action]
            lines.extend(
                [
                    f"perf-run fixture={fixture} action={action} width={width}",
                    f"perf-config profile=release fixture={fixture} samples={samples} action={action}",
                    f"perf-summary operation={operation} fixture={fixture} samples={samples} p50_ms=1 p95_ms=2",
                ]
            )
        return "\n".join(lines)

    def test_validator_accepts_the_complete_matrix(self):
        validator.validate(self.complete_log(), 50)

    def test_validator_rejects_a_missing_summary(self):
        lines = self.complete_log().splitlines()
        lines.pop(2)
        with self.assertRaisesRegex(ValueError, "expected one summary"):
            validator.validate("\n".join(lines), 50)

    def test_validator_rejects_the_wrong_sample_count(self):
        with self.assertRaisesRegex(ValueError, "sample count"):
            validator.validate(self.complete_log(samples=49), 50)

    def test_validator_rejects_reported_errors(self):
        with self.assertRaisesRegex(ValueError, "reported an error"):
            validator.validate(self.complete_log() + "\nperf-error fixture=sample.epub", 50)


if __name__ == "__main__":
    unittest.main()
