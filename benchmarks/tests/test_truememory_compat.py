import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[2]


def load_script(name):
    path = ROOT / "benchmarks/scripts" / name
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


COMPAT = load_script("truememory_compat.py")


class TrueMemoryCompatTest(unittest.TestCase):
    def test_protocol_is_pinned_and_matches_published_sizes(self):
        protocol = COMPAT.load_protocol()
        self.assertEqual(len(protocol["upstream"]["commit"]), 40)
        self.assertEqual(protocol["benchmarks"]["locomo"]["questions"], 1540)
        self.assertEqual(protocol["benchmarks"]["beam_1m"]["questions"], 700)
        self.assertEqual(protocol["provider"]["judge_runs"], 3)

    def test_locomo_adapter_excludes_adversarial_category_five(self):
        fixture = [
            {
                "sample_id": "sample",
                "conversation": {
                    "speaker_a": "A",
                    "speaker_b": "B",
                    "session_1_date_time": "1:00 PM on 10 May, 2024",
                    "session_1": [{"speaker": "A", "text": "I went yesterday."}],
                },
                "qa": [
                    {"question": "When?", "answer": "May 9", "evidence": ["D1:1"], "category": 3},
                    {"question": "Trap?", "answer": "none", "evidence": [], "category": 5},
                ],
            }
        ]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "locomo.json"
            path.write_text(json.dumps(fixture))
            prepared = COMPAT.load_locomo(path)
        self.assertEqual(len(prepared[0]["questions"]), 1)
        self.assertEqual(prepared[0]["messages"][0]["evidence_tag"], "D1:1")
        self.assertIn("May 09, 2024", prepared[0]["messages"][0]["content"])

    def test_wilson_interval_contains_observed_accuracy(self):
        lower, upper = COMPAT.wilson(93, 100)
        self.assertLess(lower, 93)
        self.assertGreater(upper, 93)

    def test_prompt_loader_reads_literals_without_importing_upstream_code(self):
        source = 'ANSWER_PROMPT = "A {context} {question}"\nJUDGE_USR = "J {gold} {generated}"\n'
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "upstream.py"
            path.write_text(source)
            prompts = COMPAT.protocol_prompts(path)
        self.assertEqual(prompts["ANSWER_PROMPT"], "A {context} {question}")

    def test_beam_adapter_preserves_all_questions_and_sessions(self):
        fixture = [{
            "conversation_id": "beam-1",
            "chat": [[{"role": "user", "content": "Remember blue", "time_anchor": "2024-01-01"}]],
            "probing_questions": "{'recall': [{'question': 'What color?', 'ideal_response': 'blue'}]}",
        }]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "beam.json"
            path.write_text(json.dumps(fixture))
            prepared = COMPAT.load_beam(path)
        self.assertEqual(prepared[0]["questions"][0]["gold"], "blue")
        self.assertEqual(prepared[0]["messages"][0]["session"], "session_0")

    def test_aggregate_reports_three_run_variance(self):
        protocol = COMPAT.load_protocol()
        protocol["benchmarks"]["locomo"]["questions"] = 1
        with tempfile.TemporaryDirectory() as directory:
            paths = []
            for index, correct in enumerate((90, 92, 94), start=1):
                path = Path(directory) / f"run{index}.json"
                path.write_text(json.dumps({
                    "benchmark": "locomo", "protocol": protocol["version"], "run": index,
                    "mode": "matched_answer_judge", "answer_evaluation_state": "COMPLETE",
                    "source_sha256": "same", "total_questions": 1,
                    "total_correct": 1 if correct > 91 else 0,
                    "details": [{"id": "q1", "correct": correct > 91}],
                }))
                paths.append(path)
            result = COMPAT.aggregate(paths, protocol)
        self.assertEqual(result["runs"], 3)
        self.assertEqual(result["mean_accuracy"], 66.667)
        self.assertGreater(result["standard_deviation"], 0)

    def test_aggregate_rejects_partial_runs(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "run1.json"
            path.write_text(json.dumps({"benchmark": "locomo", "run": 1}))
            with self.assertRaises(ValueError):
                COMPAT.aggregate([path])


if __name__ == "__main__":
    unittest.main()
