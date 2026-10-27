#!/usr/bin/env python3
"""Fixture-only Router v3.1 policy/state tests; no network or paid calls."""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import refill_lib_v2 as R


NOW = 2_000_000_000
DAY = 86400


def cfg():
    models = {
        "sol-plan": {"id": "openai-codex/gpt-6.1-sol", "family": "codex", "billing": "flat"},
        "muse-wonder-plan": {"id": "muse-wonder", "family": "muse", "billing": "flat"},
        "kimi-k3-plan": {"id": "kimi-code/k3", "family": "kimi", "billing": "flat"},
        "muse-x": {"id": "muse-spark", "family": "muse", "billing": "flat"},
        "free-x": {"id": "vendor/free-x", "family": "beam", "billing": "free"},
        "kimi-closure": {"id": "moonshot/kimi-k2", "family": "kimi", "billing": "flat"},
        "stealth-x": {"id": "vendor/x", "family": "beam", "billing": "flat", "stealth": True},
        "sonnet-cloud": {"id": "claude-sonnet-5-5", "family": "claude", "billing": "flat"},
    }
    bindings = {
        "sol-plan@pi": {"model": "sol-plan", "provider": "openai-codex", "harness": "pi", "effort": "high"},
        "muse-wonder-plan@muse": {"model": "muse-wonder-plan", "provider": "muse", "harness": "muse", "effort": "high"},
        "kimi-k3-plan@pi": {"model": "kimi-k3-plan", "provider": "kimi-code", "harness": "pi", "effort": "high"},
        "muse-x@pi": {"model": "muse-x", "provider": "muse", "harness": "pi"},
        "free-x@pi": {"model": "free-x", "provider": "vendor", "harness": "pi"},
        "kimi-closure@kimi": {"model": "kimi-closure", "provider": "moonshot", "harness": "kimi"},
        "stealth-x@pi": {"model": "stealth-x", "provider": "vendor", "harness": "pi"},
        "sonnet-cloud@claude": {"model": "sonnet-cloud", "provider": "anthropic", "harness": "claude", "cloud_capable": True},
    }
    pools = {name: {"period_days": 7, "scarce": False} for name in bindings}
    return {
        "models": models,
        "bindings": bindings,
        "roles": {
            "plan": {"models": ["sol-plan@pi", "muse-wonder-plan@muse", "kimi-k3-plan@pi"]},
            "closure": {"models": ["muse-x@pi", "kimi-closure@kimi"]},
            "cloud": {"models": ["sonnet-cloud@claude"]},
            "build": {"models": ["free-x@pi", "stealth-x@pi", "sol-plan@pi"]},
        },
        "pools": pools,
        "bans": [{"billing": "free", "live_data": True}, {"family": "kimi", "live_data": True}],
        "routing_state": {"funds_bench_seconds": DAY, "cloud_simultaneous_max": 5,
                          "claude_cloud_per_day": 3, "cloud_claude_exception": True},
    }


def quota(c):
    return {"pools": {name: {"used_pct": 0, "reset_at": NOW + DAY * 7,
                              "observed_at": NOW, "source": "test", "manual": False}
                       for name in c["pools"]}}


def catalog(c, host="netcup", age=0, overrides=None):
    rows = {}
    for binding in c["bindings"].values():
        model = c["models"][binding["model"]]
        actual = model["id"]
        key = actual if "/" in actual else binding["provider"] + "/" + actual
        rows[key] = {"cost": {"input": 1, "output": 1}}
    rows.update(overrides or {})
    return {host: {"host": host, "observed_at": NOW - age, "models": rows}}


class Paths(unittest.TestCase):
    def test_fm_path_anchors_and_rejects_escape(self):
        with tempfile.TemporaryDirectory() as home, tempfile.TemporaryDirectory() as outside:
            self.assertEqual(R.fm_path("state/x", home), os.path.join(home, "state/x"))
            for bad in ("../x", "state/../x", outside):
                with self.assertRaises(ValueError):
                    R.fm_path(bad, home)
            os.symlink(outside, os.path.join(home, "link"))
            with self.assertRaises(ValueError):
                R.fm_path("link/x", home)

    def test_route_paths_honors_configured_relative_bench(self):
        with tempfile.TemporaryDirectory() as home:
            os.makedirs(os.path.join(home, "config"))
            import yaml
            with open(os.path.join(home, "config/fleet.yaml"), "w") as f:
                yaml.safe_dump({"routing_state": {"bench": "state/custom-bench.json"}}, f)
            with mock.patch.dict(os.environ, {"FM_HOME": home}, clear=False):
                os.environ.pop("FLEET_YAML", None)
                os.environ.pop("BENCH_JSON", None)
                self.assertEqual(R._route_paths()["bench"],
                                 os.path.join(home, "state/custom-bench.json"))

    def test_route_paths_rejects_configured_and_explicit_escapes_without_fallback(self):
        with tempfile.TemporaryDirectory() as home, tempfile.TemporaryDirectory() as outside:
            os.makedirs(os.path.join(home, "config"))
            import yaml
            with open(os.path.join(home, "config/fleet.yaml"), "w") as f:
                yaml.safe_dump({"routing_state": {"bench": "state/../escaped.json"}}, f)
            env = {"FM_HOME": home, "FLEET_YAML": outside + "/fleet.yaml",
                   "QUOTA_JSON": outside + "/quota.json", "BENCH_JSON": outside + "/bench.json"}
            with mock.patch.dict(os.environ, env, clear=False):
                paths = R._route_paths()
                self.assertIsNone(paths["fleet"])
                self.assertIsNone(paths["quota"])
                self.assertIsNone(paths["bench"])
            with mock.patch.dict(os.environ, {"FM_HOME": home}, clear=False):
                for key in ("FLEET_YAML", "QUOTA_JSON", "BENCH_JSON"):
                    os.environ.pop(key, None)
                self.assertIsNone(R._route_paths()["bench"])


class CatalogPolicy(unittest.TestCase):
    def test_catalog_cost_is_strict_numeric_and_exact_free_suffix(self):
        c = cfg(); b = c["bindings"]["free-x@pi"]; m = c["models"]["free-x"]
        for costs in ({"input": 0, "output": 0}, {"input": 0.0, "output": 0.0}):
            cats = {"netcup": {"host": "netcup", "observed_at": NOW,
                                "models": {"vendor/free-x": {"cost": costs}}}}
            self.assertTrue(R.route_catalog_ok(b, m, "netcup", cats, NOW)[0])
        for costs in ({"input": True, "output": 0}, {"input": "0", "output": 0},
                      {"input": None, "output": 0}, {"input": 0}):
            cats = {"netcup": {"host": "netcup", "observed_at": NOW,
                                "models": {"vendor/free-x": {"cost": costs}}}}
            self.assertFalse(R.route_catalog_ok(b, m, "netcup", cats, NOW)[0], costs)
        m2 = dict(m, id="vendor/free-x-free")
        cats = {"netcup": {"host": "netcup", "observed_at": NOW,
                            "models": {"vendor/free-x-free": {}}}}
        self.assertTrue(R.route_catalog_ok(b, m2, "netcup", cats, NOW)[0])
        self.assertFalse(R.route_catalog_ok(b, dict(m, id="vendor/free-x-free-v2"), "netcup", cats, NOW)[0])

    def test_wrong_host_stale_missing_and_invalid_catalog_fail_closed(self):
        c = cfg(); b = c["bindings"]["sol-plan@pi"]; m = c["models"]["sol-plan"]
        for cats in ({}, {"netcup": {"host": "bosgame", "observed_at": NOW, "models": {m["id"]: {}}}},
                     catalog(c, age=86401), {"netcup": {"host": "netcup", "observed_at": NOW, "models": []}}):
            self.assertFalse(R.route_catalog_ok(b, m, "netcup", cats, NOW)[0])

    def test_bare_catalog_key_cannot_stand_in_for_provider_evidence(self):
        c = cfg(); b = c["bindings"]["muse-wonder-plan@muse"]; m = c["models"]["muse-wonder-plan"]
        cats = {"bosgame": {"host": "bosgame", "observed_at": NOW,
                             "models": {"muse-wonder": {}}}}
        self.assertFalse(R.route_catalog_ok(b, m, "bosgame", cats, NOW)[0])
        cats["bosgame"]["models"]["muse/muse-wonder"] = {}
        self.assertTrue(R.route_catalog_ok(b, m, "bosgame", cats, NOW)[0])

    def test_selection_falls_through_and_plan_chain_is_code_enforced(self):
        c = cfg(); q = quota(c); cats = catalog(c)
        cats["netcup"]["models"].pop("openai-codex/gpt-6.1-sol")
        self.assertEqual(R.route_pick("plan", "netcup", "", False, NOW, c, q, {}, catalogs=cats)[0], "kimi-k3-plan@pi")
        c["roles"]["plan"]["models"].insert(0, "muse-x@pi")
        self.assertEqual(R.route_pick("plan", "netcup", "", False, NOW, c, q, {}, catalogs=catalog(c))[0], "sol-plan@pi")
        c["models"]["muse-x"].update(id="vendor/unknown", family="beam")
        self.assertEqual(R.route_pick("plan", "bosgame", "", False, NOW, c, q, {}, catalogs=catalog(c, "bosgame"))[0], "muse-wonder-plan@muse")

    def test_netcup_muse_composer_ban_all_roles_and_bosgame_nonplan_exception(self):
        c = cfg(); q = quota(c); cats = catalog(c)
        for family in ("muse", "composer"):
            c["models"]["muse-x"]["family"] = family
            for role in ("closure", "build"):
                c["roles"][role] = {"models": ["muse-x@pi"]}
                self.assertIsNone(R.route_pick(role, "netcup", "", False, NOW, c, q, {}, catalogs=cats)[0])
                self.assertEqual(R.route_pick(role, "bosgame", "", False, NOW, c, q, {}, catalogs=catalog(c, "bosgame"))[0], "muse-x@pi")
        c["models"]["muse-x"].update(id="vendor/safe", family="beam")
        c["bindings"]["muse-x@pi"]["family"] = "composer"
        self.assertIsNone(R.route_pick("build", "netcup", "", False, NOW, c, q, {},
                                       catalogs=catalog(c))[0])

    def test_credentials_reject_free_kimi_and_documented_stealth_surfaces(self):
        c = cfg(); q = quota(c); cats = catalog(c, "bosgame")
        c["roles"]["build"] = {"models": ["free-x@pi", "kimi-closure@kimi", "stealth-x@pi", "sol-plan@pi"]}
        pick, why = R.route_pick("build", "bosgame", "", True, NOW, c, q, {}, catalogs=cats)
        self.assertEqual(pick, "sol-plan@pi")
        self.assertIn("stealth", why)

    def test_only_binding_check_does_not_advance_cursor(self):
        c = cfg(); q = quota(c); st = {"models": {}, "bindings": {}, "cursor": {"build": 7}}
        pick, _ = R.route_pick("build", "netcup", "", False, NOW, c, q, st,
                               catalogs=catalog(c), only_binding="sol-plan@pi", advance_cursor=False)
        self.assertEqual(pick, "sol-plan@pi")
        self.assertEqual(st["cursor"]["build"], 7)

    def test_old_fixture_without_catalogs_remains_compatible(self):
        c = cfg(); q = quota(c)
        self.assertEqual(R.route_pick("plan", "netcup", "", False, NOW, c, q, {})[0], "sol-plan@pi")


class BenchPolicy(unittest.TestCase):
    def test_funds_classifier_and_fixed_window(self):
        self.assertTrue(R.route_funds_stall(402, ""))
        self.assertTrue(R.route_funds_stall(None, "INSUFFICIENT BALANCE"))
        self.assertFalse(R.route_funds_stall(429, "rate limit"))
        c = cfg(); q = quota(c)
        q["pools"]["sol-plan@pi"]["reset_at"] = NOW + 9 * DAY
        bench, q2, alerts = R.route_bench_apply("sol-plan@pi", "Insufficient balance", NOW, c, q, {})
        self.assertEqual(bench["bindings"]["sol-plan@pi"]["until"], NOW + DAY)
        self.assertEqual(bench["bindings"]["sol-plan@pi"]["reason"], "funds")
        self.assertEqual(q2["pools"]["sol-plan@pi"]["used_pct"], 0)
        self.assertEqual(alerts, [])
        normalized, _, _ = R.route_bench_apply("sol-plan@pi", "funds", NOW, c, q, {})
        self.assertEqual(normalized["bindings"]["sol-plan@pi"]["until"], NOW + DAY)
        self.assertEqual(normalized["bindings"]["sol-plan@pi"]["reason"], "funds")
        q2["pools"]["sol-plan@pi"]["observed_at"] = NOW + DAY
        q2["pools"]["sol-plan@pi"]["reset_at"] = NOW + 8 * DAY
        self.assertEqual(R.route_pick("plan", "netcup", "", False, NOW + DAY, c, q2, bench,
                                      catalogs=catalog(c))[0], "sol-plan@pi")

    def test_429_and_nonfunds_exhaustion_are_preserved(self):
        c = cfg(); q = quota(c)
        bench, q2, _ = R.route_bench_apply("sol-plan@pi", "429", NOW, c, q, {})
        self.assertEqual(bench["bindings"]["sol-plan@pi"]["until"], NOW + 1800)
        self.assertEqual(q2["pools"]["sol-plan@pi"]["used_pct"], 0)
        bench, q2, _ = R.route_bench_apply("sol-plan@pi", "weekly limit", NOW, c, q, {})
        self.assertEqual(bench["bindings"]["sol-plan@pi"]["until"], NOW + 7 * DAY)
        self.assertEqual(q2["pools"]["sol-plan@pi"]["used_pct"], 100)


class CliState(unittest.TestCase):
    def make_home(self, home):
        os.makedirs(os.path.join(home, "config")); os.makedirs(os.path.join(home, "state"))
        c = cfg()
        with open(os.path.join(home, "config/fleet.yaml"), "w") as f:
            import yaml
            yaml.safe_dump(c, f)
        with open(os.path.join(home, "state/quota.json"), "w") as f: json.dump(quota(c), f)
        with open(os.path.join(home, "state/catalog-netcup.json"), "w") as f: json.dump(catalog(c)["netcup"], f)
        c["catalogs"] = {"netcup": {"path": "state/catalog-netcup.json", "max_age_seconds": DAY}}
        with open(os.path.join(home, "config/fleet.yaml"), "w") as f:
            import yaml
            yaml.safe_dump(c, f)
        return dict(os.environ, FM_HOME=home, ROUTE_NOW=str(NOW))

    def run_cli(self, env, *args, check=True):
        return subprocess.run([sys.executable, R.__file__, *args], env=env, text=True,
                              capture_output=True, check=check)

    def test_admit_confirm_receipt_is_idempotent_and_daily_charged_once(self):
        with tempfile.TemporaryDirectory() as home:
            env = self.make_home(home)
            out = self.run_cli(env, "route-admit", "task-1", "plan", "plan", "netcup", "no").stdout.strip().split("\t")
            self.assertEqual(len(out), 8)
            incarnation = out[6]
            self.run_cli(env, "route-confirm", "task-1", incarnation, "session-1")
            self.run_cli(env, "route-confirm", "task-1", incarnation, "session-1")
            with open(os.path.join(home, "state/route-launches/receipts.jsonl")) as f:
                self.assertEqual(len(f.read().splitlines()), 1)

    def test_failure_dedup_sanitizes_and_releases_pending(self):
        with tempfile.TemporaryDirectory() as home:
            env = self.make_home(home)
            out = self.run_cli(env, "route-admit", "task-2", "plan", "plan", "netcup", "no").stdout.strip().split("\t")
            binding, incarnation = out[0], out[6]
            for _ in range(2):
                self.run_cli(env, "route-failure", "task-2", incarnation, "evt-1", "402", "token=SECRET insufficient balance")
            with open(os.path.join(home, "state/route-bench.json")) as f: bench = json.load(f)
            self.assertEqual(bench["bindings"][binding]["until"], NOW + DAY)
            with open(os.path.join(home, "state/route-launches/task-2.json")) as f: sidecar = json.load(f)
            self.assertNotIn("SECRET", json.dumps(sidecar))
            self.assertEqual(sidecar["last_failure_event"], {"id": "evt-1", "incarnation": incarnation})
            self.assertFalse(sidecar["pending"])

    def test_classify_uses_existing_credential_classifier(self):
        with tempfile.TemporaryDirectory() as home:
            env = dict(os.environ, FM_HOME=home)
            self.assertEqual(self.run_cli(env, "route-classify", "requires-credentials").stdout.strip(), "yes")
            self.assertEqual(self.run_cli(env, "route-classify", "No credentials. fixture only").stdout.strip(), "no")
            self.assertEqual(self.run_cli(env, "route-classify", check=False).returncode, 2)


if __name__ == "__main__":
    unittest.main()
