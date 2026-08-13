import argparse
import importlib.util
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch


SCRIPT = Path(__file__).parents[1] / "scripts" / "seed_memory_corpus.py"
SPEC = importlib.util.spec_from_file_location("seed_memory_corpus", SCRIPT)
seeder = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(seeder)


class SeedMemoryCorpusTest(unittest.TestCase):
    def setUp(self):
        self.args = argparse.Namespace(
            workspace="bench",
            audience="default",
            benchmark="behavioral-v2",
            engine_url="http://engine",
            promote=False,
            promote_governed=False,
            reviewer="benchmark:reviewer",
        )

    @patch.object(seeder, "post_json")
    def test_update_targets_previous_memory_in_conversation(self, post_json):
        post_json.side_effect = [{"id": "mem-v1"}, {"id": "mem-v2"}]
        state = {}
        base = {
            "conversation_id": "case-1",
            "workspace": "bench",
            "project": "Northstar",
            "domain": "knowledge_update",
            "slug": "case-1",
        }

        seeder.seed_row(
            self.args,
            {**base, "content": "Alice owns it.", "operation": "create"},
            state,
            {},
        )
        result = seeder.seed_row(
            self.args,
            {**base, "content": "Priya owns it.", "operation": "update"},
            state,
            {},
        )

        self.assertEqual("mem-v2", state["case-1"])
        self.assertEqual("mem-v1", result["previous_memory_id"])
        self.assertEqual(
            "http://engine/api/memory/mem-v1/update",
            post_json.call_args_list[1].args[0],
        )

    @patch.object(seeder, "post_json")
    def test_update_without_prior_version_fails_closed(self, post_json):
        with self.assertRaisesRegex(ValueError, "no prior memory"):
            seeder.seed_row(
                self.args,
                {
                    "conversation_id": "missing",
                    "workspace": "bench",
                    "project": "Northstar",
                    "domain": "knowledge_update",
                    "slug": "missing",
                    "content": "Priya owns it.",
                    "operation": "update",
                },
                {},
                {},
            )

        post_json.assert_not_called()

    @patch.object(seeder.time, "sleep")
    @patch.object(seeder.urllib.request, "urlopen")
    def test_rate_limit_honors_retry_after(self, urlopen, sleep):
        error = seeder.urllib.error.HTTPError(
            "http://engine",
            429,
            "rate limited",
            {},
            None,
        )
        error.read = lambda: b'{"retry_after_ms":250}'
        response = MagicMock()
        response.__enter__.return_value.read.return_value = b'{"id":"mem-1"}'
        urlopen.side_effect = [error, response]

        result = seeder.post_json("http://engine", {"content": "test"})

        self.assertEqual("mem-1", result["id"])
        sleep.assert_called_once_with(0.25)

    @patch.object(seeder, "get_json")
    @patch.object(seeder, "post_json")
    def test_governed_update_supersedes_previous_fact(self, post_json, get_json):
        self.args.promote_governed = True
        get_json.side_effect = [
            {"claims": [{"id": "claim-v1", "metadata": {"versioned_memory_id": "mem-v1"}}]},
            {"claims": [{"id": "claim-v2", "metadata": {"versioned_memory_id": "mem-v2"}}]},
        ]
        post_json.side_effect = [
            {"id": "mem-v1", "metadata": {}},
            {
                "claim": {"id": "claim-v1"},
                "fact": {"id": "fact-v1"},
                "memory_object": {"id": "object-v1"},
            },
            {"id": "mem-v2", "metadata": {}},
            {
                "claim": {"id": "claim-v2"},
                "fact": {"id": "fact-v2"},
                "memory_object": {"id": "object-v2"},
            },
        ]
        memories = {}
        facts = {}
        base = {
            "conversation_id": "case-1",
            "workspace": "bench",
            "project": "Northstar",
            "domain": "knowledge_update",
            "slug": "case-1",
        }

        seeder.seed_row(
            self.args,
            {**base, "content": "Alice owns it.", "operation": "create"},
            memories,
            facts,
        )
        result = seeder.seed_row(
            self.args,
            {**base, "content": "Priya owns it.", "operation": "update"},
            memories,
            facts,
        )

        promotion = post_json.call_args_list[3].args[1]
        self.assertEqual("fact-v1", promotion["supersedes_fact_id"])
        self.assertEqual("fact-v2", result["fact_id"])


if __name__ == "__main__":
    unittest.main()
