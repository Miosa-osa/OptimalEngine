import importlib.util
import unittest
import json
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "scripts" / "system_benchmark.py"
SPEC = importlib.util.spec_from_file_location("system_benchmark", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class SystemBenchmarkTest(unittest.TestCase):
    def test_percentile_uses_nearest_rank(self):
        self.assertEqual(MODULE.percentile([1, 2, 3, 4, 5], 0.50), 3)
        self.assertEqual(MODULE.percentile([1, 2, 3, 4, 5], 0.95), 5)

    def test_summary_uses_successful_latency_and_keeps_error_gate_separate(self):
        rows = [
            {"ok": True, "latency_ms": 10, "bytes": 100},
            {"ok": False, "latency_ms": 50, "bytes": 0},
        ]
        result = MODULE.summarize(rows, 1.0, {"p95_ms": 40, "error_rate": 0.1})
        self.assertTrue(result["gates"]["p95_ms"])
        self.assertFalse(result["gates"]["error_rate"])
        self.assertFalse(result["passed"])
        self.assertEqual("successful requests only", result["latency_ms"]["population"])

    def test_governed_reconstructive_request_selects_strategy(self):
        request = MODULE.request_for(
            "http://engine",
            "rag-governed-reconstructive",
            "What changed?",
            "bench",
        )
        payload = json.loads(request.data)

        self.assertTrue(payload["context_package"])
        self.assertEqual("reconstructive", payload["strategy"])


if __name__ == "__main__":
    unittest.main()
