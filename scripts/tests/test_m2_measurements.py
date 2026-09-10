import importlib.util
import pathlib
import unittest


SCRIPT = pathlib.Path(__file__).parents[1] / "m2-measurements.py"
SPEC = importlib.util.spec_from_file_location("m2_measurements", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class M2MeasurementsTest(unittest.TestCase):
    def test_measurement_command_passes_device_as_a_separate_argument(self):
        command = MODULE.measurement_command(pathlib.Path("/repo"), "pixel-5a")

        self.assertEqual(command[command.index("-d") + 1], "pixel-5a")
        self.assertNotIn("-d=pixel-5a", command)
        self.assertIn("--no-dds", command)

    def test_nearest_rank_uses_the_observed_95th_sample(self):
        values = list(range(1, 51))
        self.assertEqual(MODULE.nearest_rank(values, 0.95), 48)

    def test_evaluation_measures_pointer_handling_through_overlay_submission(self):
        report = {
            "drag_frames": {
                "frame_build_times": [3_000] * 50,
                "frame_rasterizer_times": [20_000] * 50,
            },
            "m2": {
                "platform": "linux",
                "bridge_round_trip_ms": {"p95": 0.5},
                "visible_scene_dto_round_trip_ms": {"p95": 3.5},
                "drag_overlay_submission_ms": [3.0] * 49 + [20.0],
                "peak_rss_bytes": 256 * 1024 * 1024,
                "resource_cycle_rss_bytes": [200_000_000] * 20,
                "resource_cycle_rss_slope_bytes": -1,
            },
        }

        result = MODULE.evaluate(report)

        self.assertTrue(result["gates"]["drag_p95_at_most_8_ms"])
        self.assertFalse(result["gates"]["drag_max_at_most_16_7_ms"])
        self.assertFalse(result["passed"])

    def test_evaluation_rejects_retained_growth_across_rss_windows(self):
        report = {
            "drag_frames": {
                "frame_build_times": [1_000] * 50,
                "frame_rasterizer_times": [1_000] * 50,
            },
            "m2": {
                "platform": "android",
                "bridge_round_trip_ms": {"p95": 0.5},
                "visible_scene_dto_round_trip_ms": {"p95": 3.5},
                "drag_overlay_submission_ms": [1.0] * 50,
                "peak_rss_bytes": 256 * 1024 * 1024,
                "resource_cycle_rss_bytes": [200_000_000] * 15
                + [202_000_000] * 5,
                "resource_cycle_rss_slope_bytes": 1,
            },
        }

        result = MODULE.evaluate(report)

        self.assertFalse(result["gates"]["rss_has_no_positive_cycle_trend"])
        self.assertFalse(result["passed"])

    def test_parser_rejects_ambiguous_records(self):
        line = 'SHOSAI_M2_METRICS:1/1:{"m2": {}, "drag_frames": {}}'
        with self.assertRaisesRegex(ValueError, "inconsistent chunks"):
            MODULE.parse_report(f"{line}\n{line}\n")

    def test_parser_reassembles_out_of_order_chunks(self):
        output = "\n".join(
            [
                'I/flutter: SHOSAI_M2_METRICS:2/2:{},"drag_frames":{}}',
                'I/flutter: SHOSAI_M2_METRICS:1/2:{"m2":',
            ]
        )

        self.assertEqual(
            MODULE.parse_report(output), {"m2": {}, "drag_frames": {}}
        )

    def test_parser_rejects_missing_chunk(self):
        with self.assertRaisesRegex(ValueError, "complete"):
            MODULE.parse_report('SHOSAI_M2_METRICS:1/2:{"m2":')

    def test_successful_driver_exit_does_not_hide_test_failure(self):
        output = "00:05 +0 -1: Some tests failed.\nAll tests passed.\n"

        self.assertEqual(MODULE.effective_return_code(0, output), 1)


if __name__ == "__main__":
    unittest.main()
