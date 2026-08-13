import importlib.util
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "scripts" / "benchmark_history.py"
SPEC = importlib.util.spec_from_file_location("benchmark_history", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class BenchmarkHistoryTest(unittest.TestCase):
    def test_detects_pass_to_fail_regression(self):
        baseline = {"suites": [{"id": "memory", "passed": True}]}
        current = {"suites": [{"id": "memory", "passed": False}]}
        self.assertEqual(MODULE.compare(current, baseline)[0]["suite"], "memory")

    def test_new_suite_does_not_fake_a_regression(self):
        self.assertEqual(
            MODULE.compare({"suites": [{"id": "new", "passed": False}]}, {"suites": []}),
            [],
        )

    def test_history_is_append_only(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "history.jsonl"
            MODULE.append_history(path, {"commit": "one"})
            MODULE.append_history(path, {"commit": "two"})
            self.assertEqual(len(path.read_text().splitlines()), 2)


if __name__ == "__main__":
    unittest.main()
