import importlib.util
import json
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[2]
SCRIPT = ROOT / "benchmarks" / "scripts" / "release_benchmark.py"
SPEC = importlib.util.spec_from_file_location("release_benchmark", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class ReleaseBenchmarkTest(unittest.TestCase):
    def test_manifest_has_exactly_twelve_unique_families(self):
        manifest = json.loads(
            (ROOT / "benchmarks/configs/release_suites.json").read_text(encoding="utf-8")
        )
        identifiers = [suite["id"] for suite in manifest["suites"]]
        self.assertEqual(len(identifiers), 12)
        self.assertEqual(len(set(identifiers)), 12)

    def test_parse_metrics_reads_exunit_summary(self):
        self.assertEqual(MODULE.parse_metrics("Finished\n9 tests, 0 failures\n")["tests"], 9)

    def test_scorecard_does_not_claim_unmeasured_optimality(self):
        report = {
            "generated_at": "now",
            "passed": True,
            "passed_suites": 1,
            "total_suites": 1,
            "suites": [
                {
                    "id": "one",
                    "name": "One",
                    "meaning": "A measured behavior.",
                    "passed": True,
                    "metrics": {"tests": 1},
                    "qualification": "regression",
                    "limitation": None,
                    "elapsed_seconds": 0.1,
                }
            ],
        }
        self.assertIn("does not make unmeasured workloads optimal", MODULE.markdown(report))


if __name__ == "__main__":
    unittest.main()
