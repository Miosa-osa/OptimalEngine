import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).parents[2]
sys.path.insert(0, str(ROOT / "benchmarks/scripts"))


def load_script(name):
    path = ROOT / "benchmarks/scripts" / name
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


COMPAT = load_script("truememory_compat.py")
DIAGNOSTICS = load_script("truememory_diagnostics.py")
RUNNER = load_script("truememory_engine_run.py")


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

    def test_locomo_evidence_normalizes_composites_and_typos(self):
        self.assertEqual(
            COMPAT.normalize_locomo_evidence(["D8:6; D9:17", "D:11:26", "D30:05", "D"]),
            ["D8:6", "D9:17", "D11:26", "D30:5"],
        )

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

    def test_beam_10m_adapter_flattens_plan_batches(self):
        fixture = [{
            "conversation_id": "beam-10m",
            "chat": [{"plan-1": [{"turns": [[{"role": "user", "content": "remember"}]]}]}],
            "probing_questions": "{'recall': [{'question': 'What?', 'answer': 'remember'}]}",
        }]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "beam.json"
            path.write_text(json.dumps(fixture))
            prepared = COMPAT.load_beam(path)
        self.assertEqual(len(prepared[0]["messages"]), 1)
        self.assertEqual(prepared[0]["messages"][0]["content"], "remember")

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
                    "retrieval_strategy": "engine_memory",
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

    def test_category_breakdown_reports_accuracy_and_interval(self):
        result = COMPAT.category_breakdown([
            {"category": "temporal", "correct": True},
            {"category": "temporal", "correct": False},
        ])
        self.assertEqual(result["temporal"]["accuracy"], 50.0)
        self.assertEqual(result["temporal"]["total"], 2)

    def test_bm25_ablation_and_oracle_address_integrity(self):
        prepared = [{
            "conversation_id": "c1",
            "messages": [
                {"content": "favorite color blue", "evidence_tag": "D1:1"},
                {"content": "unrelated weather", "evidence_tag": "D1:2"},
            ],
            "questions": [{"id": "q1", "question": "favorite color", "evidence": ["D1:1"]}],
        }]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "prepared.jsonl"
            path.write_text("\n".join(json.dumps(row) for row in prepared))
            result = DIAGNOSTICS.evaluate(path, [1, 2])
        self.assertEqual(result["oracle"]["address_integrity"], "PASS")
        self.assertEqual(result["ablations"][0]["evidence_recall"], 100.0)

    def test_strict_oracle_diagnostic_matches_question_ids(self):
        with tempfile.TemporaryDirectory() as directory:
            strict = Path(directory) / "strict.jsonl"
            oracle = Path(directory) / "oracle.jsonl"
            strict.write_text(json.dumps({"conversation_id": "q1", "messages": [{}, {}, {}]}) + "\n")
            oracle.write_text(json.dumps({"conversation_id": "q1", "messages": [{}]}) + "\n")
            result = DIAGNOSTICS.compare_strict_oracle(strict, oracle)
        self.assertEqual(result["matched_question_ids"], 1)
        self.assertEqual(result["message_reduction_percent"], 66.667)

    def test_oracle_retrieval_returns_only_gold_evidence(self):
        conversation = {"messages": [
            {"content": "gold", "evidence_tag": "D1:1"},
            {"content": "noise", "evidence_tag": "D1:2"},
        ]}
        memories, _latency = RUNNER.local_retrieve(
            "oracle", conversation, {"evidence": ["D1:1"]}, 100
        )
        self.assertEqual(len(memories), 1)
        self.assertIn("gold", memories[0]["content"])

    def test_paid_summary_marks_unknown_cost_without_prices(self):
        detail = {
            "id": "q1", "category": "recall", "correct": True,
            "evidence_found": 1, "evidence_total": 1, "retrieval_latency_s": 0.01,
            "answer_usage": {"prompt_tokens": 10, "completion_tokens": 2}, "judge_usage": [],
        }
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "prepared.jsonl"
            source.write_text("{}\n")
            result = RUNNER.summarize([detail], "locomo", 1, source, True)
        self.assertIsNone(result["estimated_cost_usd"])
        self.assertEqual(result["by_category"]["recall"]["accuracy"], 100.0)

    def test_coverage_query_variants_include_entities_and_clauses(self):
        variants = RUNNER.query_variants(
            "How do Alice and Bob use creative hobbies while handling stress?"
        )
        self.assertEqual(variants[0], "How do Alice and Bob use creative hobbies while handling stress?")
        self.assertIn("Alice", variants)
        self.assertIn("Bob", variants)
        self.assertIn("Bob use creative hobbies", variants)

    def test_round_robin_fusion_prevents_one_query_from_crowding_out_others(self):
        fused = RUNNER.round_robin_fuse(
            [
                [{"id": "alice-1"}, {"id": "alice-2"}, {"id": "alice-3"}],
                [{"id": "bob-1"}, {"id": "bob-2"}],
            ],
            4,
        )
        self.assertEqual([item["id"] for item in fused], ["alice-1", "bob-1", "alice-2", "bob-2"])

    def test_coverage_fusion_preserves_primary_ranking_before_expansion(self):
        original = [{"id": f"primary-{index}"} for index in range(10)]
        fused = RUNNER.coverage_fuse(original, [[{"id": "companion"}]], 10)
        self.assertEqual([item["id"] for item in fused[:8]], [f"primary-{index}" for index in range(8)])
        self.assertEqual(fused[8]["id"], "companion")

    def test_evidence_set_retrieval_runs_semantic_probes_and_fuses_coverage(self):
        def semantic(_url, _workspace, probe, _top_k, _model):
            return ([{"id": probe, "content": probe}], 0.01)

        with patch.object(RUNNER, "retrieve_semantic", side_effect=semantic):
            memories, latency = RUNNER.retrieve_evidence_set(
                "http://engine", "workspace-1", "How do Alice and Bob relax?", 10, "nomic"
            )

        identities = [memory["id"] for memory in memories]
        self.assertEqual(identities[0], "How do Alice and Bob relax?")
        self.assertIn("Alice", identities)
        self.assertEqual(len(identities), len(set(identities)))
        self.assertGreaterEqual(latency, 0)

    def test_semantic_retrieval_uses_scoped_hybrid_search(self):
        with patch.object(RUNNER, "get_json", return_value={"results": [{"id": "semantic"}]}) as request:
            memories, latency = RUNNER.retrieve_semantic(
                "http://engine", "workspace-1", "a paraphrased question", 20
            )

        self.assertEqual(memories, [{"id": "semantic"}])
        self.assertGreaterEqual(latency, 0)
        request.assert_called_once_with(
            "http://engine/api/search",
            {
                "tenant": "default",
                "workspace": "workspace-1",
                "type": "memory",
                "q": "a paraphrased question",
                "limit": 20,
            },
        )


if __name__ == "__main__":
    unittest.main()
