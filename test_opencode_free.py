import importlib.machinery
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).with_name("opencode-free")
loader = importlib.machinery.SourceFileLoader("opencode_free", str(SCRIPT))
spec = importlib.util.spec_from_loader(loader.name, loader)
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)


def aa_model(name, slug=None, coding=None, agentic=None, intelligence=None):
    evaluations = {}
    if coding is not None:
        evaluations["artificial_analysis_coding_index"] = coding
    if agentic is not None:
        evaluations["artificial_analysis_agentic_index"] = agentic
    if intelligence is not None:
        evaluations["artificial_analysis_intelligence_index"] = intelligence
    return {"name": name, "slug": slug or name, "evaluations": evaluations}


def aa_payload(models, has_more=False, version=4.3):
    return json.dumps(
        {
            "tier": "free",
            "intelligence_index_version": version,
            "pagination": {
                "page": 1,
                "page_size": 200,
                "total_pages": 2 if has_more else 1,
                "has_more": has_more,
            },
            "data": models,
        }
    )


class LauncherTests(unittest.TestCase):
    def test_filters_paid_and_non_tool_models(self):
        catalog = {
            "opencode": {
                "models": {
                    "free-coder": {"cost": {"input": 0, "output": 0}, "tool_call": True},
                    "paid": {"cost": {"input": 0.1, "output": 1}, "tool_call": True},
                    "no-tools": {"cost": {"input": 0, "output": 0}, "tool_call": False},
                    "jev-1-free": {"cost": {"input": 0, "output": 0}, "tool_call": True},
                }
            }
        }
        self.assertEqual([item["id"] for item in module.free_candidates(catalog)], ["free-coder"])

    def test_usage_rank_matches_free_suffix(self):
        html = (
            '$R[1]={model:"space-bunny",provider:"unknown",tokens:38936,change:null,rank:1},'
            '$R[2]={model:"muse-spark-1.3-contributor",provider:"meta",tokens:35515,change:-4,rank:3}'
        )
        scores = module.usage_scores(html)
        candidates = [
            {"id": "space-bunny-free", "name": "Space Bunny", "context": 100},
            {"id": "muse-spark-1.3-contributor-free", "name": "Muse", "context": 200},
        ]
        selected, basis = module.rank_candidates_by_usage(candidates, scores)
        self.assertEqual(selected["id"], "space-bunny-free")
        self.assertIn("weekly usage", basis)

    def test_aa_api_reports_coverage_and_unscored(self):
        """A clean ranking must still disclose models the publisher skipped."""
        catalog = json.dumps(
            {
                "opencode": {
                    "models": {
                        "muse-free": {"cost": {"input": 0, "output": 0}, "tool_call": True, "name": "Muse"},
                        "space-bunny-free": {"cost": {"input": 0, "output": 0}, "tool_call": True, "name": "Bunny"},
                    }
                }
            }
        )
        payload = aa_payload([aa_model("Muse", coding=75)])
        with mock.patch.object(module, "fetch_text", side_effect=[catalog, payload]):
            with mock.patch.dict(module.os.environ, {"ARTIFICIAL_ANALYSIS_API_KEY": "k"}, clear=False):
                selection = module.refresh_selection(module.time.time())
        self.assertEqual(selection["ranking_source"], "aa-api")
        self.assertEqual(selection["model"], "opencode/muse-free")
        # The unscored-but-popular model must be named, not silently dropped.
        self.assertEqual(selection["unscored_ids"], ["space-bunny-free"])
        self.assertEqual(selection["candidate_count"], 2)
        self.assertEqual(selection["benchmarked_count"], 1)

    def test_aa_api_coverage_omits_models_lacking_the_ranking_index(self):
        """Coverage counts every scored model, not only the ranked subset."""
        payload = aa_payload(
            [
                aa_model("Coding Only", coding=70),
                aa_model("Intelligence Only", intelligence=90),
            ]
        )
        with mock.patch.object(module, "fetch_text", return_value=payload):
            with mock.patch.dict(module.os.environ, {"ARTIFICIAL_ANALYSIS_API_KEY": "k"}, clear=False):
                scores, _ = module.aa_index_snapshot()
        candidates = [
            {"id": "coding-only", "name": "Coding Only", "context": 100},
            {"id": "intelligence-only", "name": "Intelligence Only", "context": 100},
        ]
        _, score = module.rank_candidates_by_aa(candidates, scores)
        # Both are scored by AA; only one carries the coding index used to rank.
        self.assertEqual(score["scored_count"], 1)
        self.assertEqual(score["benchmarked_count"], 2)
        self.assertEqual(score["unscored_ids"], [])

    def test_aa_matching_preserves_variants_and_exact_names(self):
        models = [
            aa_model("MiMo V2.6", coding=99),
            aa_model("MiMo V2.6 Flash", coding=38),
            aa_model("Competitor", coding=50),
        ]
        with mock.patch.object(module, "aa_index_payload", return_value={
            "models": models, "intelligence_index_version": 4.3
        }):
            scores, _ = module.aa_index_snapshot()
        candidate = {"id": "mimo-v2.6-flash-free", "name": "MiMo V2.6 Flash Free", "context": 200}
        self.assertEqual(module.aa_score_for(candidate, scores)["aa_name"], "MiMo V2.6 Flash")
        selected, score = module.rank_candidates_by_aa(
            [candidate, {"id": "competitor", "name": "Competitor", "context": 100}], scores
        )
        self.assertEqual(selected["id"], "competitor")
        self.assertEqual(score["aa_index"], 50)
        for variant in ("flash", "lightning", "tiny"):
            with self.subTest(variant=variant):
                self.assertIsNone(module.aa_score_for(
                    {"id": f"mimo-v2.6-{variant}-free", "name": f"MiMo V2.6 {variant} Free"},
                    {"mimov26": scores["mimov26"]},
                ))

    def test_aa_matching_prefers_exact_name_over_stripped_id(self):
        candidate = {"id": "muse-contributor-free", "name": "Publisher Name"}
        exact = {"aa_name": "Publisher Name"}
        self.assertIs(module.aa_score_for(candidate, {
            "muse": {"aa_name": "Muse"}, "publishername": exact
        }), exact)

    def test_aa_matching_prefers_contributor_before_base(self):
        contributor = {"aa_name": "Muse Contributor"}
        candidate = {"id": "muse-contributor-free", "name": "Muse Free"}
        self.assertIs(module.aa_score_for(candidate, {
            "musecontributor": contributor, "muse": {"aa_name": "Muse"}
        }), contributor)

    def test_aa_api_reports_publisher_name(self):
        """aa_name is the benchmark publisher's name, not the Zen display name."""
        payload = aa_payload([aa_model("Muse Spark 1.3 Contributor", coding=48)])
        with mock.patch.object(module, "fetch_text", return_value=payload):
            with mock.patch.dict(module.os.environ, {"ARTIFICIAL_ANALYSIS_API_KEY": "k"}, clear=False):
                scores, _ = module.aa_index_snapshot()
        candidates = [{"id": "muse-spark-1.3-contributor-free", "name": "Muse Spark 1.3 Free", "context": 100}]
        _, score = module.rank_candidates_by_aa(candidates, scores)
        self.assertEqual(score["aa_name"], "Muse Spark 1.3 Contributor")

    def test_aa_api_rank_wins_and_strips_zen_suffixes(self):
        """The '-contributor-free' tier matches the publisher's plain name."""
        payload = aa_payload(
            [
                aa_model("Muse Spark 1.3 Contributor", coding=48),
                aa_model("MiMo-V2.6-Flash", coding=38),
            ]
        )
        with mock.patch.object(module, "fetch_text", return_value=payload) as fetch:
            with mock.patch.dict(module.os.environ, {"ARTIFICIAL_ANALYSIS_API_KEY": "k"}, clear=False):
                scores, version = module.aa_index_snapshot()
        self.assertEqual(fetch.call_args.kwargs["headers"]["x-api-key"], "k")
        self.assertEqual(version, 4.3)
        candidates = [
            {"id": "muse-spark-1.3-contributor-free", "name": "Muse Spark 1.3 Free", "context": 100},
            {"id": "mimo-v2.6-flash-free", "name": "MiMo-V2.6-Flash Free", "context": 200},
        ]
        selected, score = module.rank_candidates_by_aa(candidates, scores)
        self.assertEqual(selected["id"], "muse-spark-1.3-contributor-free")
        self.assertEqual(score["aa_index"], 48)
        self.assertEqual(score["aa_field"], "artificial_analysis_coding_index")

    def test_aa_api_requires_key(self):
        with mock.patch.dict(module.os.environ, {}, clear=False):
            module.os.environ.pop("ARTIFICIAL_ANALYSIS_API_KEY", None)
            with self.assertRaisesRegex(module.SelectionError, "ARTIFICIAL_ANALYSIS_API_KEY"):
                module.aa_api_key()

    def test_aa_api_follows_pagination(self):
        first = aa_payload([aa_model("A", coding=1)], has_more=True)
        second = aa_payload([aa_model("B", coding=2)], has_more=False)
        with mock.patch.object(module, "fetch_text", side_effect=[first, second]) as fetch:
            with mock.patch.dict(module.os.environ, {"ARTIFICIAL_ANALYSIS_API_KEY": "k"}, clear=False):
                payload = module.aa_index_payload()
        self.assertEqual(len(payload["models"]), 2)
        self.assertEqual(fetch.call_count, 2)
        self.assertIn("page=2", fetch.call_args.args[0])

    def test_aa_api_does_not_mix_index_scales(self):
        """A coding-index score must never be compared against an intelligence one."""
        payload = aa_payload(
            [
                aa_model("High Coding", coding=90, intelligence=10),
                aa_model("High Intelligence", intelligence=95),
            ]
        )
        with mock.patch.object(module, "fetch_text", return_value=payload):
            with mock.patch.dict(module.os.environ, {"ARTIFICIAL_ANALYSIS_API_KEY": "k"}, clear=False):
                scores, _ = module.aa_index_snapshot()
        candidates = [
            {"id": "high-coding", "name": "High Coding", "context": 100},
            {"id": "high-intelligence", "name": "High Intelligence", "context": 100},
        ]
        selected, score = module.rank_candidates_by_aa(candidates, scores)
        # 95 on the intelligence index must not beat 90 on the preferred coding index.
        self.assertEqual(selected["id"], "high-coding")
        self.assertEqual(score["aa_index"], 90)
        self.assertEqual(score["aa_field"], "artificial_analysis_coding_index")

    def test_aa_api_falls_back_to_next_index_field(self):
        payload = aa_payload([aa_model("Only Intelligence", intelligence=42)])
        with mock.patch.object(module, "fetch_text", return_value=payload):
            with mock.patch.dict(module.os.environ, {"ARTIFICIAL_ANALYSIS_API_KEY": "k"}, clear=False):
                scores, _ = module.aa_index_snapshot()
        candidates = [{"id": "only-intelligence", "name": "Only Intelligence", "context": 100}]
        selected, score = module.rank_candidates_by_aa(candidates, scores)
        self.assertEqual(selected["id"], "only-intelligence")
        self.assertEqual(score["aa_field"], "artificial_analysis_intelligence_index")

    def test_aa_api_failure_degrades_to_usage_fallback(self):
        catalog = json.dumps(
            {
                "opencode": {
                    "models": {
                        "free-coder": {
                            "cost": {"input": 0, "output": 0},
                            "tool_call": True,
                            "name": "Free Coder",
                        }
                    }
                }
            }
        )
        with mock.patch.object(module, "fetch_text", side_effect=[catalog, OSError("boom"), ""]):
            with mock.patch.dict(module.os.environ, {"ARTIFICIAL_ANALYSIS_API_KEY": "k"}, clear=False):
                selection = module.refresh_selection(module.time.time())
        self.assertEqual(selection["ranking_source"], "fallback")
        self.assertIn("boom", selection["fallback_reason"])
        self.assertEqual(selection["model"], "opencode/free-coder")

    def test_resume_and_commands_pass_through(self):
        self.assertTrue(module.is_resume(["--continue"]))
        self.assertTrue(module.is_resume(["-s", "session-id"]))
        self.assertFalse(module.is_resume(["--prompt", "hello"]))
        self.assertTrue(module.is_noninteractive_command(["auth", "list"]))
        self.assertTrue(module.is_noninteractive_command(["run", "hello"]))
        self.assertTrue(module.is_noninteractive_command(["--version"]))
        self.assertFalse(module.is_noninteractive_command(["--prompt", "hello"]))

    def test_config_content_preserves_existing_values(self):
        existing = json.dumps({"permissions": [{"action": "shell", "effect": "ask"}]})
        with mock.patch.dict(module.os.environ, {"OPENCODE_CONFIG_CONTENT": existing}, clear=False):
            value = json.loads(module.config_content_with_model("opencode/free-coder"))
        self.assertEqual(value["model"], "opencode/free-coder")
        self.assertEqual(value["permissions"][0]["effect"], "ask")

    def test_real_binary_comes_from_portable_config(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            binary = root / "real-opencode"
            binary.write_text("fixture", encoding="utf-8")
            config_dir = root / "opencode-smart-launcher"
            config_dir.mkdir()
            (config_dir / "config.json").write_text(
                json.dumps({"real_binary": str(binary)}), encoding="utf-8"
            )
            with mock.patch.dict(module.os.environ, {"XDG_CONFIG_HOME": temp}, clear=False):
                with mock.patch.object(module.shutil, "which", return_value=None):
                    self.assertEqual(module.find_real_binary(), str(binary.resolve()))

    def test_target_directory_uses_positional_directory(self):
        with mock.patch.object(module.Path, "cwd", return_value=Path("/fallback")):
            self.assertEqual(module.target_directory(["--prompt", "hello", "/tmp/project"]), "/tmp/project")
            self.assertEqual(module.target_directory([]), "/fallback")

    def test_creates_session_with_explicit_model(self):
        response = {
            "data": {
                "id": "ses_test",
                "model": {"providerID": "opencode", "id": "muse-free"},
            }
        }
        completed = module.subprocess.CompletedProcess([], 0, stdout=json.dumps(response), stderr="")
        with mock.patch.object(module.subprocess, "run", return_value=completed) as run:
            session_id = module.create_explicit_session(
                "/real/opencode", "opencode/muse-free", "/tmp/project"
            )
        self.assertEqual(session_id, "ses_test")
        command = run.call_args.args[0]
        self.assertEqual(command[:3], ["/real/opencode", "api", "session.create"])
        payload = json.loads(command[-1])
        self.assertEqual(payload["model"], {"providerID": "opencode", "id": "muse-free"})
        self.assertEqual(payload["location"]["directory"], "/tmp/project")

    def test_fresh_cache_avoids_network(self):
        with tempfile.TemporaryDirectory() as temp:
            with mock.patch.dict(module.os.environ, {"XDG_CACHE_HOME": temp}, clear=False):
                module.write_cache(
                    {
                        "schema": 1,
                        "model": "opencode/free-coder",
                        "name": "Free Coder",
                        "basis": "test",
                        "ranking_source": "aa-api",
                        "candidate_count": 1,
                        "selected_at": module.time.time(),
                    }
                )
                with mock.patch.object(module, "refresh_selection") as refresh:
                    selected = module.select_model()
                refresh.assert_not_called()
                self.assertEqual(selected["model"], "opencode/free-coder")
                self.assertEqual(selected["cache"], "fresh")

    def test_fallback_cache_uses_short_ttl(self):
        value = {
            "model": "opencode/free-coder",
            "ranking_source": "fallback",
            "selected_at": module.time.time() - 2 * 60 * 60,
        }
        self.assertFalse(module.cache_is_fresh(value, module.time.time()))

    def test_legacy_cache_refreshes_and_is_not_reused_on_failure(self):
        legacy = {
            "schema": 1, "model": "opencode/legacy", "name": "Legacy",
            "basis": "Ebbwater AA Index", "ranking_source": "ebbwater-aa",
            "aa_index": 40, "selected_at": module.time.time(),
        }
        refreshed = {**legacy, "model": "opencode/current", "ranking_source": "aa-api"}
        with tempfile.TemporaryDirectory() as temp:
            with mock.patch.dict(module.os.environ, {"XDG_CACHE_HOME": temp}, clear=False):
                module.write_cache(legacy)
                with mock.patch.object(module, "refresh_selection", return_value=refreshed) as refresh:
                    selected = module.select_model()
                refresh.assert_called_once()
                self.assertEqual(selected["model"], "opencode/current")
                self.assertEqual(selected["cache"], "refreshed")
                module.write_cache(legacy)
                with mock.patch.object(module, "refresh_selection", side_effect=module.SelectionError("offline")):
                    with self.assertRaisesRegex(module.SelectionError, "offline"):
                        module.select_model()


if __name__ == "__main__":
    unittest.main()
