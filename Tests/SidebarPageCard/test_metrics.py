import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path

from summarize_metrics import summarize


class MetricSummaryTests(unittest.TestCase):
    def run_summary(self, before, after):
        with tempfile.TemporaryDirectory() as directory:
            arguments = []
            for label, metrics in (("before", before), ("after", after)):
                path = Path(directory) / f"{label}.json"
                path.write_text(json.dumps([{"testRuns": [{"device": {"deviceName": "not-for-report"}, "metrics": metrics}]}]))
                arguments.append(f"{label}={path}")
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                summarize(arguments)
            return output.getvalue()

    def test_cpu_is_normalized_to_one_cycle_and_metadata_is_omitted(self):
        def metric(values):
            return {"identifier": "com.apple.dt.XCTMetric_CPU-com.openui.openui.time",
                    "unitOfMeasurement": "s", "measurements": values}
        output = self.run_summary([metric([2, 2])], [metric([1, 1])])
        self.assertIn("1000.00 ± 0.00 | 500.00 ± 0.00 | -50.0%", output)
        self.assertNotIn("not-for-report", output)
        self.assertIn("2 measured blocks", output)

    def test_memory_uses_decimal_megabytes_without_dividing_by_cycles(self):
        metric = {"identifier": "com.apple.dt.XCTMetric_Memory-com.openui.openui.physical_peak",
                  "unitOfMeasurement": "kB", "measurements": [80000]}
        output = self.run_summary([metric], [metric])
        self.assertIn("80.00 | 80.00 | +0.0%", output)

    def test_unexpected_units_are_rejected(self):
        metric = {"identifier": "com.apple.dt.XCTMetric_CPU-com.openui.openui.time",
                  "unitOfMeasurement": "ms", "measurements": [2]}
        with self.assertRaisesRegex(AssertionError, "Unexpected metric unit"):
            self.run_summary([metric], [metric])

    def test_absent_hitch_samples_do_not_become_zero_hitches(self):
        output = self.run_summary([], [])
        self.assertNotIn("| App CPU", output)
        self.assertNotIn("hitch", output.lower())


if __name__ == "__main__":
    unittest.main()
