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

    def test_ebbwater_aa_rank_wins_and_matches_muse_alias(self):
        now = module.datetime(2026, 9, 28, tzinfo=module.timezone.utc).timestamp()
        html = '''
        var ZEN = [
          ["Muse Spark 1.3 Contributor Free",48,17,0,0,"free+trn"],
          ["MiMo-V2.6-Flash Free",38,60,0,0,"free"]
        ];
        /* Coding Agent Index badges */
        var AA_UPDATED = "2026-09-27T20:20:11Z";
        '''
        scores, updated = module.ebbwater_snapshot(html, now)
        candidates = [
            {
                "id": "muse-spark-1.3-contributor-free",
                "name": "Muse Spark 1.3 Free",
                "context": 100,
            },
            {"id": "mimo-v2.6-flash-free", "name": "MiMo-V2.6-Flash Free", "context": 200},
        ]
        selected, score = module.rank_candidates_by_aa(candidates, scores)
        self.assertEqual(selected["id"], "muse-spark-1.3-contributor-free")
        self.assertEqual(score["aa_index"], 48)
        self.assertEqual(updated, "2026-09-27T20:20:11Z")

    def test_stale_ebbwater_snapshot_is_rejected(self):
        now = module.datetime(2026, 10, 2, tzinfo=module.timezone.utc).timestamp()
        html = '''
        var ZEN = [["Model",40,1,0,0,"free"]];
        /* Coding Agent Index badges */
        var AA_UPDATED = "2026-09-27T20:20:11Z";
        '''
        with self.assertRaisesRegex(module.SelectionError, "stale"):
            module.ebbwater_snapshot(html, now)

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


if __name__ == "__main__":
    unittest.main()
