import importlib.util
import random
import unittest
from pathlib import Path


SCRIPTS = Path(__file__).parents[1] / "scripts"


def load_script(name: str):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


generator = load_script("generate_behavioral_memory_dataset")
judge = load_script("judge_results")


class BehavioralBenchmarkTest(unittest.TestCase):
    def test_cases_are_isolated_by_project(self):
        first, first_question = generator.build_case(
            0, "delayed_recall", 100, random.Random(1)
        )
        second, second_question = generator.build_case(
            1, "delayed_recall", 100, random.Random(1)
        )

        self.assertNotEqual(first[0]["project"], second[0]["project"])
        self.assertIn(first[0]["project"], first_question["question"])
        self.assertIn(second[0]["project"], second_question["question"])

    def test_behavioral_judge_accepts_current_fact_without_stale_fact(self):
        vote = judge.behavioral_exact_vote(
            {
                "answer": "Priya is the current owner.",
                "required_terms": ["Priya"],
                "forbidden_terms": ["Alice"],
            }
        )

        self.assertEqual("correct", vote["label"])

    def test_behavioral_judge_rejects_stale_fact_leak(self):
        vote = judge.behavioral_exact_vote(
            {
                "answer": "Alice was owner, then Priya became owner.",
                "required_terms": ["Priya"],
                "forbidden_terms": ["Alice"],
            }
        )

        self.assertEqual("incorrect", vote["label"])

    def test_behavioral_judge_scores_explicit_abstention(self):
        vote = judge.behavioral_exact_vote(
            {"answer": "Insufficient evidence to answer.", "expected_abstention": True}
        )

        self.assertEqual("correct", vote["label"])


if __name__ == "__main__":
    unittest.main()
