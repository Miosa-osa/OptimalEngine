import importlib.util
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "scripts" / "security_benchmark.py"
SPEC = importlib.util.spec_from_file_location("security_benchmark", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class SecurityBenchmarkTest(unittest.TestCase):
    def test_parse_counts_uses_last_exunit_summary(self):
        output = "1 test, 1 failure\nFinished\n42 tests, 0 failures\n"
        self.assertEqual(MODULE.parse_counts(output), (42, 0))

    def test_parse_counts_fails_closed_when_summary_is_missing(self):
        self.assertEqual(MODULE.parse_counts("process crashed"), (None, None))


if __name__ == "__main__":
    unittest.main()
