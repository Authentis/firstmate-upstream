#!/usr/bin/env python3
"""Fixture-only tests for Router v3. No network or external services."""
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


def config():
    return {
        "models": {
            "free-a": {"family": "free-a", "billing": "free", "pool": "free-a"},
            "free-b": {"family": "free-b", "billing": "free", "pool": "free-b"},
            "kimi-build": {"family": "kimi", "billing": "flat", "pool": "kimi"},
            "muse-top": {"family": "muse", "billing": "flat", "pool": "muse"},
            "claude-review": {"id": "claude-opus-5-5", "family": "claude", "billing": "flat", "pool": "claude", "effort": "high"},
            "codex-review": {"id": "gpt-6.1-sol", "family": "codex", "billing": "flat", "pool": "codex", "effort": "high"},
            "claude-cline": {"family": "claude", "via": "cline", "billing": "flat", "pool": "claude"},
            "tiny-haiku": {"family": "claude", "billing": "flat", "pool": "claude"},
            "kimi-k3": {"family": "kimi", "billing": "flat", "pool": "kimi"},
            "metered-x": {"family": "metered", "billing": "metered", "pool": "metered"},
        },
        "roles": {
            "build": {"free": ["free-a", "free-b"], "flat": ["claude-review"]},
            "manager": {"free": ["free-a", "free-b"], "flat": ["codex-review"]},
            "review": {"models": ["claude-review", "codex-review"]},
            "plan": {"models": ["muse-top", "codex-review"]},
            "t3": {"models": ["claude-review", "codex-review"]},
        },
        "pools": {
            "free-a": {"period_days": 1, "scarce": False},
            "free-b": {"period_days": 1, "scarce": False},
            "kimi": {"period_days": 7, "scarce": False},
            "claude": {"period_days": 7, "reserve": 30, "scarce": True},
            "codex": {"period_days": 7, "reserve": 30, "scarce": True},
            "muse": {"period_days": 7, "reserve": 30, "scarce": True},
            "metered": {"period_days": 1, "scarce": False},
        },
        "bans": [
            {"billing": "free", "live_data": True},
            {"family": "kimi", "live_data": True},
            {"family": "muse", "host": "netcup"},
            {"family": "claude", "via": "cline"},
            {"id_pattern": "(?:haiku|k3)"},
        ],
    }


def quota(**used):
    pools = {}
    for name in ("free-a", "free-b", "kimi", "claude", "codex", "muse", "metered"):
        pools[name] = {
            "used_pct": used.get(name, 0),
            "reset_at": NOW + (7 * DAY if name in {"claude", "codex", "muse", "kimi"} else DAY),
            "source": "test",
            "observed_at": NOW,
            "manual": False,
        }
    return {"pools": pools}


def state():
    return {"models": {}, "cursor": {}}


class Rotation(unittest.TestCase):
    def test_successive_free_picks_rotate(self):
        st = state()
        self.assertEqual(R.route_pick("build", "bosgame", "", False, NOW, config(), quota(), st)[0], "free-a")
        self.assertEqual(R.route_pick("build", "bosgame", "", False, NOW, config(), quota(), st)[0], "free-b")

    def test_benched_model_is_skipped_and_returns_after_30_minutes(self):
        st = {"models": {"free-a": {"until": NOW + 1800}}, "cursor": {}}
        self.assertEqual(R.route_pick("build", "bosgame", "", False, NOW, config(), quota(), st)[0], "free-b")
        st["cursor"]["build"] = 0
        self.assertEqual(R.route_pick("build", "bosgame", "", False, NOW + 1801, config(), quota(), st)[0], "free-a")


class FreeBeforePaid(unittest.TestCase):
    def test_free_model_wins_before_flat_plan(self):
        model, why = R.route_pick("build", "bosgame", "", False, NOW, config(), quota(), state())
        self.assertEqual(model, "free-a")
        self.assertIn("free", why)


class PremiumReserve(unittest.TestCase):
    def test_routine_role_denied_while_over_pace(self):
        cfg = config()
        cfg["roles"]["build"] = {"flat": ["claude-review"]}
        q = quota(claude=1)
        model, why = R.route_pick("build", "bosgame", "", False, NOW, cfg, q, state())
        self.assertIsNone(model)
        self.assertIn("reserve", why)

    def test_hard_role_and_hard_override_may_use_pool(self):
        # pass-3 (S11): the review role delegates to the writer-family reviewer policy and never
        # rotates over quota, so the hard-role reserve bypass is proven with the T3 role instead.
        q = quota(muse=99)
        self.assertEqual(R.route_pick("t3", "bosgame", "", False, NOW, config(), q, state())[0], "claude-review")
        q = quota(claude=99)
        cfg = config()
        cfg["roles"]["build"] = {"flat": ["claude-review"]}
        self.assertEqual(R.route_pick("build", "bosgame", "", False, NOW, cfg, q, state(), hard=True)[0], "claude-review")


class ReviewerFamilyExclusion(unittest.TestCase):
    def test_author_family_never_reviews(self):
        # pass-3 (S11): a Claude-built author gets the droid-local Sol reviewer, never its own
        # family and never a rotation pick from the review role table.
        model, why = R.route_pick("review", "bosgame", "claude", False, NOW, config(), quota(), state())
        self.assertEqual(model, "droid-local:gpt-6.1-sol")


class StaleAndUnknownQuota(unittest.TestCase):
    def test_stale_quota_skips_pool(self):
        q = quota()
        q["pools"]["free-a"]["observed_at"] = NOW - 6 * 3600 - 1
        self.assertEqual(R.route_pick("build", "bosgame", "", False, NOW, config(), q, state())[0], "free-b")

    def test_unknown_pool_is_skipped(self):
        q = quota()
        del q["pools"]["free-a"]
        self.assertEqual(R.route_pick("build", "bosgame", "", False, NOW, config(), q, state())[0], "free-b")


class ReserveTiming(unittest.TestCase):
    def test_routine_allowed_at_or_below_elapsed_reserve_pace(self):
        cfg = config()
        cfg["roles"]["build"] = {"flat": ["claude-review"]}
        q = quota(claude=35)
        q["pools"]["claude"]["reset_at"] = NOW + 3.5 * DAY
        self.assertEqual(R.route_pick("build", "bosgame", "", False, NOW, cfg, q, state())[0], "claude-review")

    def test_last_24_hours_opens_reserve(self):
        cfg = config()
        cfg["roles"]["build"] = {"flat": ["claude-review"]}
        q = quota(claude=99)
        q["pools"]["claude"]["reset_at"] = NOW + DAY
        self.assertEqual(R.route_pick("build", "bosgame", "", False, NOW, cfg, q, state())[0], "claude-review")


class BanRows(unittest.TestCase):
    def test_live_data_excludes_free_and_kimi(self):
        cfg = config()
        cfg["roles"]["build"] = {"free": ["free-a"], "flat": ["kimi-build", "codex-review"]}
        self.assertEqual(R.route_pick("build", "bosgame", "", True, NOW, cfg, quota(), state())[0], "codex-review")

    def test_muse_banned_on_netcup(self):
        self.assertEqual(R.route_pick("t3", "netcup", "", False, NOW, config(), quota(), state())[0], "claude-review")

    def test_claude_via_cline_and_haiku_k3_are_always_banned(self):
        cfg = config()
        cfg["roles"]["t3"] = {"models": ["claude-cline", "tiny-haiku", "kimi-k3"]}
        self.assertIsNone(R.route_pick("t3", "bosgame", "", False, NOW, cfg, quota(), state())[0])


class FailClosed(unittest.TestCase):
    def test_wait_when_nothing_is_eligible(self):
        cfg = config()
        cfg["roles"]["build"] = {"free": ["free-a"]}
        model, why = R.route_pick("build", "bosgame", "", False, NOW, cfg, {"pools": {}}, state())
        self.assertIsNone(model)
        self.assertTrue(why)

    def test_no_silent_paid_or_metered_fallback(self):
        cfg = config()
        cfg["roles"]["build"] = {"free": ["free-a"], "flat": ["claude-review"]}
        q = quota()
        del q["pools"]["free-a"]
        q["pools"]["claude"]["reset_at"] = NOW + DAY
        model, why = R.route_pick("build", "bosgame", "", False, NOW, cfg, q, state())
        self.assertEqual(model, "claude-review")
        self.assertIn("free-a: quota unknown", why)

        cfg["roles"]["build"] = {"free": ["free-a"]}
        self.assertIsNone(R.route_pick("build", "bosgame", "", False, NOW, cfg, {"pools": {}}, state())[0])

    def test_missing_fleet_yaml_cli_prints_wait(self):
        with tempfile.TemporaryDirectory() as home:
            env = dict(os.environ, FM_HOME=home, FLEET_YAML=os.path.join(home, "missing.yaml"))
            out = subprocess.run(
                [sys.executable, R.__file__, "route-pick", "build", "netcup", "", "no"],
                env=env, text=True, capture_output=True, check=True,
            ).stdout
            self.assertTrue(out.startswith("WAIT\t"), out)

    def test_invalid_fleet_yaml_cli_prints_wait(self):
        with tempfile.TemporaryDirectory() as home:
            config_dir = os.path.join(home, "config")
            os.mkdir(config_dir)
            fleet = os.path.join(config_dir, "fleet.yaml")
            with open(fleet, "w") as f:
                f.write("roles: [unterminated\n")
            env = dict(os.environ, FM_HOME=home, FLEET_YAML=fleet)
            out = subprocess.run(
                [sys.executable, R.__file__, "route-pick", "build", "netcup", "", "no"],
                env=env, text=True, capture_output=True, check=True,
            ).stdout
            self.assertTrue(out.startswith("WAIT\t"), out)


class FileCommands(unittest.TestCase):
    def test_route_bench_records_429_for_30_minutes(self):
        # chief 4661: the bench entry is per BINDING (route-bench accepts a binding id); a legacy
        # model-id mark lands in the same bindings table and applies to all bindings of that model.
        with tempfile.TemporaryDirectory() as home:
            state_dir = os.path.join(home, "state")
            os.mkdir(state_dir)
            env = dict(os.environ, FM_HOME=home, ROUTE_NOW=str(NOW))
            subprocess.run(
                [sys.executable, R.__file__, "route-bench", "cat-jam@opencode"],
                env=env, check=True,
            )
            with open(os.path.join(state_dir, "route-bench.json")) as f:
                doc = json.load(f)
            self.assertEqual(doc["bindings"]["cat-jam@opencode"], {
                "reason": "429", "until": NOW + 1800,
            })

    def _bench_home(self, home, with_quota=True, reset_at=None):
        """pass-5: a minimal fleet whose binding rows carry no pool key (pool == binding id)."""
        config_dir = os.path.join(home, "config")
        state_dir = os.path.join(home, "state")
        os.mkdir(config_dir)
        os.mkdir(state_dir)
        with open(os.path.join(config_dir, "fleet.yaml"), "w") as f:
            f.write("""
models:
  cat-jam: {family: free, billing: free}
bindings:
  cat-jam@opencode: {model: cat-jam, provider: opencode, harness: opencode, weight: 1}
  cat-jam@commandcode: {model: cat-jam, provider: commandcode, harness: commandcode, weight: 1}
roles:
  build: {free: [cat-jam@opencode, cat-jam@commandcode]}
pools:
  cat-jam@opencode: {period_days: 1, scarce: false}
  cat-jam@commandcode: {period_days: 1, scarce: false}
bans: []
""")
        if with_quota:
            pools = {}
            for name in ("cat-jam@opencode", "cat-jam@commandcode"):
                pools[name] = {"used_pct": 40, "reset_at": reset_at or (NOW + 2 * DAY),
                               "source": "test", "observed_at": NOW, "manual": False}
            with open(os.path.join(state_dir, "quota.json"), "w") as f:
                json.dump({"pools": pools}, f)
        return state_dir

    def test_route_bench_429_reason_benches_30_minutes_only(self):
        # pass-5: an explicit 429 reason benches 30 min and touches neither quota.json nor the
        # alert log (a rate limit is not a quota exhaustion).
        with tempfile.TemporaryDirectory() as home:
            state_dir = self._bench_home(home)
            env = dict(os.environ, FM_HOME=home, ROUTE_NOW=str(NOW))
            subprocess.run(
                [sys.executable, R.__file__, "route-bench", "cat-jam@opencode", "--reason", "429"],
                env=env, check=True,
            )
            with open(os.path.join(state_dir, "route-bench.json")) as f:
                doc = json.load(f)
            self.assertEqual(doc["bindings"]["cat-jam@opencode"], {
                "reason": "429", "until": NOW + 1800,
            })
            with open(os.path.join(state_dir, "quota.json")) as f:
                q = json.load(f)
            self.assertEqual(q["pools"]["cat-jam@opencode"]["used_pct"], 40)   # untouched
            self.assertFalse(os.path.exists(os.path.join(state_dir, "route-alerts.log")))

    def test_route_bench_402_uses_fixed_funds_window_without_mutating_quota(self):
        # v3.1: payment failures are independent of quota evidence. A 402 always benches for
        # exactly one day and leaves the observed quota document unchanged.
        with tempfile.TemporaryDirectory() as home:
            state_dir = self._bench_home(home, reset_at=NOW + int(1.5 * DAY))
            env = dict(os.environ, FM_HOME=home, ROUTE_NOW=str(NOW))
            subprocess.run(
                [sys.executable, R.__file__, "route-bench", "cat-jam@opencode", "--reason", "402"],
                env=env, check=True,
            )
            with open(os.path.join(state_dir, "route-bench.json")) as f:
                bench = json.load(f)
            self.assertEqual(bench["bindings"]["cat-jam@opencode"], {
                "reason": "funds", "until": NOW + DAY,
            })
            with open(os.path.join(state_dir, "quota.json")) as f:
                q = json.load(f)
            row = q["pools"]["cat-jam@opencode"]
            self.assertEqual(row["used_pct"], 40)
            self.assertEqual(row["source"], "test")
            self.assertEqual(row["reset_at"], NOW + int(1.5 * DAY))
            self.assertFalse(row["manual"])
            self.assertFalse(os.path.exists(os.path.join(state_dir, "route-alerts.log")))

    def test_route_bench_exhaustion_text_unknown_reset_benches_24h_and_alerts(self):
        # pass-5: exhaustion text ('insufficient credits', case-insensitive) with an unknown pool
        # reset benches 24 h AND appends one escalation line to state/route-alerts.log; the pool
        # row is still written exhausted with the fallback reset so routing stays fail-closed.
        with tempfile.TemporaryDirectory() as home:
            state_dir = self._bench_home(home, with_quota=False)   # no quota.json: reset unknown
            env = dict(os.environ, FM_HOME=home, ROUTE_NOW=str(NOW))
            subprocess.run(
                [sys.executable, R.__file__, "route-bench", "cat-jam@opencode",
                 "--reason", "Error: Insufficient Credits for this operation"],
                env=env, check=True,
            )
            with open(os.path.join(state_dir, "route-bench.json")) as f:
                bench = json.load(f)
            self.assertEqual(bench["bindings"]["cat-jam@opencode"]["until"], NOW + 24 * 3600)
            with open(os.path.join(state_dir, "route-alerts.log")) as f:
                lines = f.read().splitlines()
            self.assertEqual(len(lines), 1)
            self.assertIn("cat-jam@opencode", lines[0])
            self.assertIn("pool reset unknown", lines[0])
            with open(os.path.join(state_dir, "quota.json")) as f:
                q = json.load(f)
            row = q["pools"]["cat-jam@opencode"]
            self.assertEqual(row["used_pct"], 100)
            self.assertEqual(row["source"], "bench")
            self.assertEqual(row["reset_at"], NOW + 24 * 3600)   # the fallback window

    def test_route_bench_weekly_limit_text_is_exhaustion_with_known_reset(self):
        # pass-5: the classifier is case-insensitive and text-based ('Weekly Limit' has no status
        # code at all): with a known reset the bench runs until that reset.
        with tempfile.TemporaryDirectory() as home:
            state_dir = self._bench_home(home, reset_at=NOW + 3 * DAY)
            env = dict(os.environ, FM_HOME=home, ROUTE_NOW=str(NOW))
            subprocess.run(
                [sys.executable, R.__file__, "route-bench", "cat-jam@opencode",
                 "--reason", "Weekly Limit reached"],
                env=env, check=True,
            )
            with open(os.path.join(state_dir, "route-bench.json")) as f:
                bench = json.load(f)
            self.assertEqual(bench["bindings"]["cat-jam@opencode"]["until"], NOW + 3 * DAY)
            self.assertFalse(os.path.exists(os.path.join(state_dir, "route-alerts.log")))

    def test_route_bench_model_id_benches_every_binding_of_that_model(self):
        # pass-7 (M1): route-bench writes bench['bindings'][<id>] keyed by the id it was given, so
        # benching a bare MODEL id stores 'bindings'['cat-jam']; route_pick must honor that mark
        # for EVERY binding of the model until it expires.
        with tempfile.TemporaryDirectory() as home:
            state_dir = self._bench_home(home)
            env = dict(os.environ, FM_HOME=home, ROUTE_NOW=str(NOW))
            subprocess.run(
                [sys.executable, R.__file__, "route-bench", "cat-jam"],
                env=env, check=True,
            )
            with open(os.path.join(state_dir, "route-bench.json")) as f:
                doc = json.load(f)
            self.assertEqual(doc["bindings"]["cat-jam"], {"reason": "429", "until": NOW + 1800})
            out = subprocess.run(
                [sys.executable, R.__file__, "route-pick", "build", "bosgame", "", "no"],
                env=env, text=True, capture_output=True, check=True,
            ).stdout
            self.assertTrue(out.startswith("WAIT\t"), out)
            self.assertIn("cat-jam@opencode: benched until", out)
            self.assertIn("cat-jam@commandcode: benched until", out)
            # after the bench expires every binding of the model is routable again
            env_later = dict(env, ROUTE_NOW=str(NOW + 1801))
            pick = subprocess.run(
                [sys.executable, R.__file__, "route-pick", "build", "bosgame", "", "no"],
                env=env_later, text=True, capture_output=True, check=True,
            ).stdout.split("\t", 1)[0]
            self.assertEqual(pick, "cat-jam@opencode")

    def test_route_bench_exhaustion_benches_binding_and_others_stay_reachable(self):
        # pass-5: after a 402 bench, route_pick skips the benched binding and rotates to the other
        # binding; once the bench expires (past the pool reset), the first binding is back.
        with tempfile.TemporaryDirectory() as home:
            state_dir = self._bench_home(home, reset_at=NOW + int(1.5 * DAY))
            env = dict(os.environ, FM_HOME=home, ROUTE_NOW=str(NOW))
            subprocess.run(
                [sys.executable, R.__file__, "route-bench", "cat-jam@opencode", "--reason", "402"],
                env=env, check=True,
            )
            pick = subprocess.run(
                [sys.executable, R.__file__, "route-pick", "build", "bosgame", "", "no"],
                env=env, text=True, capture_output=True, check=True,
            ).stdout.split("\t", 1)[0]
            self.assertEqual(pick, "cat-jam@commandcode")
            # after the reset the pool is readable again (a fresh reading replaces the exhausted
            # 'bench' row) and the expired bench returns the first binding to rotation.
            with open(os.path.join(state_dir, "quota.json"), "w") as f:
                json.dump({"pools": {
                    name: {"used_pct": 40, "reset_at": NOW + 5 * DAY,
                           "source": "test", "observed_at": NOW + 2 * DAY, "manual": False}
                    for name in ("cat-jam@opencode", "cat-jam@commandcode")
                }}, f)
            env_later = dict(env, ROUTE_NOW=str(NOW + 2 * DAY))
            pick = subprocess.run(
                [sys.executable, R.__file__, "route-pick", "build", "bosgame", "", "no"],
                env=env_later, text=True, capture_output=True, check=True,
            ).stdout.split("\t", 1)[0]
            self.assertEqual(pick, "cat-jam@opencode")

    def test_quota_set_is_atomic_and_labels_manual(self):
        with tempfile.TemporaryDirectory() as home:
            state_dir = os.path.join(home, "state")
            os.mkdir(state_dir)
            path = os.path.join(state_dir, "quota.json")
            env = dict(os.environ, FM_HOME=home, QUOTA_JSON=path)
            subprocess.run(
                [sys.executable, R.__file__, "quota-set", "claude", "42.5", str(NOW + DAY), "console", "--manual"],
                env=env, check=True,
            )
            with open(path) as f:
                doc = json.load(f)
            self.assertEqual(doc["pools"]["claude"]["used_pct"], 42.5)
            self.assertTrue(doc["pools"]["claude"]["manual"])
            self.assertFalse(any(x.endswith(".tmp") for x in os.listdir(state_dir)))

    def test_concurrent_picks_under_lock_do_not_double_rotate(self):
        with tempfile.TemporaryDirectory() as home:
            state_dir = os.path.join(home, "state")
            config_dir = os.path.join(home, "config")
            os.mkdir(state_dir)
            os.mkdir(config_dir)
            fleet = os.path.join(config_dir, "fleet.yaml")
            with open(fleet, "w") as f:
                f.write("""
models:
  free-a: {family: free-a, billing: free, pool: free-a}
  free-b: {family: free-b, billing: free, pool: free-b}
roles:
  build: {free: [free-a, free-b], flat: []}
pools:
  free-a: {period_days: 1, scarce: false}
  free-b: {period_days: 1, scarce: false}
bans: []
""")
            q = {"pools": {
                "free-a": {"used_pct": 0, "reset_at": NOW + DAY, "source": "test", "observed_at": NOW, "manual": False},
                "free-b": {"used_pct": 0, "reset_at": NOW + DAY, "source": "test", "observed_at": NOW, "manual": False},
            }}
            quota_path = os.path.join(state_dir, "quota.json")
            with open(quota_path, "w") as f:
                f.write(json.dumps(q))
            env = dict(os.environ, FM_HOME=home, FLEET_YAML=fleet, QUOTA_JSON=quota_path,
                       ROUTE_NOW=str(NOW))
            cmd = [sys.executable, R.__file__, "route-pick", "build", "bosgame", "", "no"]
            ps = [subprocess.Popen(cmd, env=env, text=True, stdout=subprocess.PIPE) for _ in range(2)]
            picks = {p.communicate()[0].split("\t", 1)[0] for p in ps}
            self.assertEqual(picks, {"free-a", "free-b"})
            self.assertTrue(all(p.returncode == 0 for p in ps))

    def test_alerts_print_stale_and_near_exhaustion_lines(self):
        with tempfile.TemporaryDirectory() as home:
            state_dir = os.path.join(home, "state")
            config_dir = os.path.join(home, "config")
            os.mkdir(state_dir)
            os.mkdir(config_dir)
            with open(os.path.join(config_dir, "fleet.yaml"), "w") as f:
                f.write("pools:\n  claude: {period_days: 7}\n  codex: {period_days: 7}\n")
            with open(os.path.join(state_dir, "quota.json"), "w") as f:
                json.dump({"pools": {
                    "claude": {"used_pct": 91, "observed_at": NOW},
                    "codex": {"used_pct": 20, "observed_at": NOW - 6 * 3600 - 1},
                }}, f)
            env = dict(os.environ, FM_HOME=home, ROUTE_NOW=str(NOW))
            lines = subprocess.run(
                [sys.executable, R.__file__, "alerts"], env=env, text=True,
                capture_output=True, check=True,
            ).stdout.splitlines()
            self.assertIn("EXHAUSTION\tclaude\t91.0%", lines)
            self.assertTrue(any(line.startswith("STALE\tcodex\t") for line in lines))


def manager_config():
    """chief 4655: manager never gets Codex Plus, routine Claude, Astra or Sol, on any host.
    pass-3 (M1): the Sol/Astra pattern is the ANCHORED form from fleet.yaml.example."""
    cfg = config()
    cfg["models"].update({
        "codex-plus": {"family": "codex", "billing": "flat", "pool": "codex"},
        "claude-opus": {"family": "claude", "billing": "flat", "pool": "claude"},
        "astra-1": {"family": "astra", "billing": "flat", "pool": "metered"},
        "gpt-6.1-sol": {"family": "openai", "billing": "flat", "pool": "codex"},
        "console-x": {"family": "openai", "billing": "flat", "pool": "metered"},
    })
    cfg["roles"]["manager"] = {"free": ["free-a"],
                               "flat": ["codex-plus", "claude-opus", "astra-1", "gpt-6.1-sol", "console-x"]}
    cfg["bans"] += [
        {"role": "manager", "family": "codex"},
        {"role": "manager", "family": "claude"},
        {"role": "manager", "id_pattern": "(?:astra|[-_/]sol(?:$|[-_.\\d]))"},
    ]
    return cfg


class ManagerRow(unittest.TestCase):
    def test_manager_never_returns_a_model_only_a_verdict(self):
        # pass-5 (chief): route_pick('manager') never returns a model id - not a free binding, not
        # a flat plan. An admissible row yields the literal verdict 'OK'; a free/Kimi rotation is
        # gone from the manager row entirely.
        cfg = manager_config()
        model, why = R.route_pick("manager", "bosgame", "", False, NOW, cfg, quota(), state())
        self.assertEqual(model, "OK")
        self.assertIn("manager admission OK", why)
        self.assertNotIn(model, cfg["models"])
        cfg2 = manager_config()
        cfg2["roles"]["manager"] = {"flat": ["kimi-build"]}
        model2, why2 = R.route_pick("manager", "bosgame", "", False, NOW, cfg2, quota(), state())
        self.assertEqual(model2, "OK")
        self.assertNotEqual(model2, "kimi-build")

    def test_manager_window_denial_gives_wait_not_a_model(self):
        # pass-5 (chief): a quota-window denial on every configured row is a WAIT verdict, never
        # a fallback model.
        cfg = manager_config()
        q = quota(codex=100, claude=100, muse=100, metered=100, kimi=100)
        q["pools"]["free-a"]["used_pct"] = 100
        q["pools"]["free-b"]["used_pct"] = 100
        model, why = R.route_pick("manager", "bosgame", "", False, NOW, cfg, q, state())
        self.assertIsNone(model)
        self.assertIn("manager admission WAIT", why)
        self.assertIn("quota", why)

    def test_manager_ban_denial_gives_wait_with_reasons(self):
        cfg = manager_config()
        cfg["roles"]["manager"] = {"flat": ["codex-plus", "claude-opus"]}
        model, why = R.route_pick("manager", "netcup", "", False, NOW, cfg, quota(), state())
        self.assertIsNone(model)
        self.assertIn("manager admission WAIT", why)
        self.assertIn("banned", why)

    def test_manager_never_codex_claude_astra_sol_on_any_host(self):
        for host in ("netcup", "bosgame"):
            cfg = manager_config()
            cfg["roles"]["manager"] = {"flat": ["codex-plus", "claude-opus", "astra-1", "gpt-6.1-sol"]}
            model, why = R.route_pick("manager", host, "", False, NOW, cfg, quota(), state())
            self.assertIsNone(model, host)
            self.assertTrue(why)

    def test_manager_sol_pattern_is_anchored_to_model_tokens(self):
        # pass-3 (M1) + pass-5: 'console-x' contains 'sol' but is NOT a Sol model, so its row is
        # ADMISSIBLE (verdict 'OK'); 'gpt-6.1-sol' and 'astra-1' ARE banned (verdict WAIT).
        # Only the anchored pattern distinguishes them, and the verdict is never a model id.
        cfg = manager_config()
        cfg["roles"]["manager"] = {"flat": ["console-x"]}
        model, why = R.route_pick("manager", "bosgame", "", False, NOW, cfg, quota(), state())
        self.assertEqual(model, "OK")
        self.assertIn("console-x", why)
        for banned in ("gpt-6.1-sol", "astra-1"):
            cfg = manager_config()
            cfg["roles"]["manager"] = {"flat": [banned]}
            model, why = R.route_pick("manager", "bosgame", "", False, NOW, cfg, quota(), state())
            self.assertIsNone(model, banned)
            self.assertIn("banned", why)

    def test_example_manager_pattern_bans_sol_and_astra_but_not_console(self):
        # pass-3 (M1) + pass-5: the SAME anchored pattern as the example file, against example-like
        # rows: console-x is admissible (verdict 'OK'), sol/astra rows are WAIT - never a model id.
        cfg = R._load_fleet(os.path.join(os.path.dirname(os.path.abspath(__file__)), "fleet.yaml.example"))
        self.assertIsNotNone(cfg)
        cfg["models"].update({
            "gpt-6.1-sol": {"family": "openai", "billing": "flat", "pool": "codex"},
            "astra-9": {"family": "astra", "billing": "flat", "pool": "metered"},
            "console-x": {"family": "openai", "billing": "flat", "pool": "codex"},
        })
        cfg["roles"]["manager"] = {"flat": ["console-x"]}
        q = quota()
        for name in cfg["pools"]:
            q["pools"].setdefault(name, dict(q["pools"]["metered"]))
        model, why = R.route_pick("manager", "netcup", "", False, NOW, cfg, q, state())
        self.assertEqual(model, "OK")
        self.assertIn("console-x", why)
        for banned in ("gpt-6.1-sol", "astra-9"):
            cfg["roles"]["manager"] = {"flat": [banned]}
            self.assertIsNone(R.route_pick("manager", "netcup", "", False, NOW, cfg, q, state())[0], banned)

    def test_example_manager_row_bans_hold_even_when_tampered(self):
        cfg = R._load_fleet(os.path.join(os.path.dirname(os.path.abspath(__file__)), "fleet.yaml.example"))
        self.assertIsNotNone(cfg)
        # pass-5 + pass-8b: a tampered manager row (the whole row replaced) carrying only banned
        # entries still fails closed - verdict WAIT on every host, never a model id. (claude-top
        # is no longer in the banned set on netcup - it is the captain-configured Sonnet row.)
        cfg["roles"]["manager"] = {"flat": ["codex-top", "gpt-6.1-sol"]}
        q = quota()
        for name in cfg["pools"]:
            q["pools"].setdefault(name, dict(q["pools"]["metered"]))
        for host in ("netcup", "bosgame"):
            model, why = R.route_pick("manager", host, "", False, NOW, cfg, q, state())
            self.assertIsNone(model)
            self.assertIn("manager admission WAIT", why)


EXAMPLE_FLEET = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fleet.yaml.example")


def example_quota(cfg):
    q = quota()
    for name in cfg["pools"]:
        q["pools"].setdefault(name, dict(q["pools"]["metered"]))
    return q


class ManagerSonnetRow(unittest.TestCase):
    """pass-8b (review): the example's claude-top manager row IS the captain-configured netcup SM
    (Sonnet), so the routine-Claude manager ban is scoped 'host: !netcup' (every host EXCEPT
    netcup). The netcup verdict then evaluates the Sonnet pool window; FM and bosgame keep the
    Muse row; Claude stays banned for managers on every other host. Manager stays verdict-only."""

    def setUp(self):
        self.cfg = R._load_fleet(EXAMPLE_FLEET)
        self.assertIsNotNone(self.cfg)
        self.q = example_quota(self.cfg)

    def test_netcup_manager_ok_when_sonnet_pool_in_window(self):
        model, why = R.route_pick("manager", "netcup", "", False, NOW, self.cfg, self.q, state())
        self.assertEqual(model, "OK")
        self.assertTrue(why.startswith("manager admission OK: claude-top"), why)
        self.assertNotIn(model, self.cfg["models"])   # a verdict, never a model id

    def test_netcup_manager_wait_when_sonnet_pool_exhausted(self):
        self.q["pools"]["claude"]["used_pct"] = 100
        model, why = R.route_pick("manager", "netcup", "", False, NOW, self.cfg, self.q, state())
        self.assertIsNone(model)
        self.assertIn("manager admission WAIT", why)
        self.assertIn("claude-top@claude: quota exhausted", why)

    def test_fm_and_bosgame_manager_ok_via_muse_row(self):
        for host in ("fm", "bosgame"):
            model, why = R.route_pick("manager", host, "", False, NOW, self.cfg, self.q, state())
            self.assertEqual(model, "OK", host)
            self.assertTrue(why.startswith("manager admission OK: muse-top"), why)
            self.assertIn("claude-top@claude: banned by fleet table", why)

    def test_claude_top_still_banned_for_manager_off_netcup(self):
        self.cfg["roles"]["manager"] = {"models": ["claude-top"]}
        for host in ("fm", "bosgame"):
            model, why = R.route_pick("manager", host, "", False, NOW, self.cfg, self.q, state())
            self.assertIsNone(model, host)
            self.assertIn("claude-top: banned by fleet table", why)

    def test_negated_host_ban_value(self):
        # the '!' prefix negates one scalar ban condition: family claude is banned on every host
        # except netcup, so the same row flips between eligible and banned by host alone.
        cfg = config()
        cfg["roles"]["build"] = {"flat": ["claude-review"]}
        cfg["bans"] = [{"family": "claude", "host": "!netcup"}]
        self.assertEqual(R.route_pick("build", "netcup", "", False, NOW, cfg, quota(), state())[0],
                         "claude-review")
        self.assertIsNone(R.route_pick("build", "bosgame", "", False, NOW, cfg, quota(), state())[0])


def bindings_config():
    """chief 4661: cat-jam and deepseek-v4.1-flash each bound on opencode and commandcode."""
    cfg = config()
    cfg["models"].update({
        "cat-jam": {"family": "free", "billing": "free"},
        "ds-flash": {"family": "deepseek", "billing": "free"},
    })
    cfg["bindings"] = {
        "cat-jam@opencode": {"model": "cat-jam", "provider": "opencode", "harness": "opencode", "weight": 1},
        "cat-jam@commandcode": {"model": "cat-jam", "provider": "commandcode", "harness": "commandcode", "weight": 1},
        "ds-flash@opencode": {"model": "ds-flash", "provider": "opencode", "harness": "opencode", "weight": 1},
        "ds-flash@commandcode": {"model": "ds-flash", "provider": "commandcode", "harness": "commandcode", "weight": 1},
    }
    for name in cfg["bindings"]:
        cfg["pools"][name] = {"period_days": 1, "scarce": False}
    cfg["roles"]["build"] = {"free": ["cat-jam@opencode", "cat-jam@commandcode"], "flat": ["kimi-build"]}
    return cfg


def bindings_quota(**used):
    q = quota()
    for name in ("cat-jam@opencode", "cat-jam@commandcode"):
        q["pools"][name] = {"used_pct": used.get(name, 0), "reset_at": NOW + DAY,
                            "source": "test", "observed_at": NOW, "manual": False}
    return q


class Bindings(unittest.TestCase):
    def test_rotation_runs_across_bindings(self):
        cfg = bindings_config()
        st = state()
        self.assertEqual(R.route_pick("build", "bosgame", "", False, NOW, cfg, bindings_quota(), st)[0], "cat-jam@opencode")
        self.assertEqual(R.route_pick("build", "bosgame", "", False, NOW, cfg, bindings_quota(), st)[0], "cat-jam@commandcode")

    def test_weighted_rotation_walks_the_expanded_list(self):
        # pass-3 (M3/S9): weights [2,1] must yield A,A,B,A,A,B... The old cursor stored the FIRST
        # index of the picked entry in the expanded list, so it collapsed and B starved.
        cfg = bindings_config()
        cfg["bindings"]["cat-jam@opencode"]["weight"] = 2
        st = state()
        seq = [R.route_pick("build", "bosgame", "", False, NOW, cfg, bindings_quota(), st)[0]
               for _ in range(6)]
        self.assertEqual(seq, ["cat-jam@opencode", "cat-jam@opencode", "cat-jam@commandcode",
                               "cat-jam@opencode", "cat-jam@opencode", "cat-jam@commandcode"])

    def test_benching_one_binding_leaves_the_other_reachable(self):
        cfg = bindings_config()
        st = {"bindings": {"cat-jam@opencode": {"until": NOW + 1800}}, "cursor": {}}
        self.assertEqual(R.route_pick("build", "bosgame", "", False, NOW, cfg, bindings_quota(), st)[0], "cat-jam@commandcode")

    def test_bench_and_quota_are_per_binding(self):
        cfg = bindings_config()
        st = {"bindings": {"cat-jam@opencode": {"until": NOW + 1800}}, "cursor": {}}
        q = bindings_quota(**{"cat-jam@commandcode": 100})
        model, why = R.route_pick("build", "bosgame", "", False, NOW, cfg, q, st)
        self.assertEqual(model, "kimi-build")   # both bindings out -> flat plan, no silent free fallback
        self.assertIn("benched", why)
        self.assertIn("quota exhausted", why)

    def test_legacy_model_keyed_bench_applies_to_all_bindings_of_the_model(self):
        cfg = bindings_config()
        st = {"models": {"cat-jam": {"until": NOW + 1800}}, "cursor": {}}
        self.assertEqual(R.route_pick("build", "bosgame", "", False, NOW, cfg, bindings_quota(), st)[0], "kimi-build")

    def test_expired_binding_mark_does_not_mask_an_active_model_mark(self):
        # pass-8 (review): BOTH marks are evaluated INDEPENDENTLY - an expired binding-specific
        # bench must not mask an active model-wide mark (the old 'first mark wins' chain let a
        # stale binding mark hide a live model mark). A model mark benches EVERY binding of the
        # model, so the pick must fall through to the flat tier while it is active.
        cfg = bindings_config()
        st = {"bindings": {"cat-jam@opencode": {"until": NOW - 10}},
              "models": {"cat-jam": {"until": NOW + 1800}}, "cursor": {}}
        model, why = R.route_pick("build", "bosgame", "", False, NOW, cfg, bindings_quota(), st)
        self.assertEqual(model, "kimi-build")
        self.assertNotIn("cat-jam", model)
        self.assertIn("benched", why)
        # once the model mark expires too, the binding is reachable again
        st = {"bindings": {"cat-jam@opencode": {"until": NOW - 10}},
              "models": {"cat-jam": {"until": NOW - 10}}, "cursor": {}}
        self.assertEqual(R.route_pick("build", "bosgame", "", False, NOW + 20, cfg, bindings_quota(), st)[0],
                         "cat-jam@opencode")

    def test_id_pattern_is_matched_against_the_binding_id_too(self):
        # pass-3 (M2): a binding like foo-k3@opencode on model cat-jam must NOT bypass the haiku|k3
        # ban - the pattern is tested against the model id AND the binding id (and provider/harness).
        cfg = config()
        cfg["models"]["cat-jam"] = {"family": "free", "billing": "free"}
        cfg["bindings"] = {"foo-k3@opencode": {"model": "cat-jam", "provider": "opencode",
                                               "harness": "opencode", "weight": 1}}
        cfg["pools"]["foo-k3@opencode"] = {"period_days": 1, "scarce": False}
        cfg["roles"]["build"] = {"free": ["foo-k3@opencode"]}
        model, why = R.route_pick("build", "bosgame", "", False, NOW, cfg, quota(), state())
        self.assertIsNone(model)
        self.assertIn("K3 is reserved", why)

    def test_example_bindings_are_routable(self):
        cfg = R._load_fleet(os.path.join(os.path.dirname(os.path.abspath(__file__)), "fleet.yaml.example"))
        q = quota()
        for name in cfg["pools"]:
            q["pools"].setdefault(name, dict(q["pools"]["metered"]))
        pick = R.route_pick("build", "netcup", "", False, NOW, cfg, q, state())[0]
        self.assertIn(pick, cfg["bindings"], pick)


class OpencodeGoPool(unittest.TestCase):
    def go_config(self):
        cfg = config()
        cfg["models"]["opencode-go/deepseek-v4.1-flash"] = {"family": "openai", "billing": "metered", "pool": "opencode-go"}
        cfg["pools"]["opencode-go"] = {"period_days": 30, "scarce": False}
        cfg["bans"] += [{"id_pattern": "^opencode-go/", "hard": False}]
        return cfg

    def go_quota(self):
        q = quota()
        q["pools"]["opencode-go"] = {"used_pct": 74, "reset_at": NOW + int(19.8 * DAY),
                                     "source": "opencode go plan console", "observed_at": NOW, "manual": True}
        return q

    def test_opencode_go_never_returned_for_build_or_manager(self):
        for role in ("build", "manager"):
            cfg = self.go_config()
            cfg["roles"][role] = {"metered": ["opencode-go/deepseek-v4.1-flash"]}
            model, why = R.route_pick(role, "bosgame", "", False, NOW, cfg, self.go_quota(), state())
            self.assertIsNone(model, role)
            self.assertIn("metered", why)

    def test_metered_rows_are_never_eligible_even_for_hard_roles(self):
        # pass-3 (S7): Router v3 has NO metered tier at all - an explicit metered table returns
        # WAIT even on a hard role with a hard=True pick.
        cfg = self.go_config()
        cfg["roles"]["t3"] = {"metered": ["opencode-go/deepseek-v4.1-flash"]}
        model, why = R.route_pick("t3", "netcup", "", False, NOW, cfg, self.go_quota(), state())
        self.assertIsNone(model)
        self.assertIn("metered rows are never eligible", why)
        cfg["roles"]["build"] = {"metered": ["opencode-go/deepseek-v4.1-flash"]}
        model, why = R.route_pick("build", "netcup", "", False, NOW, cfg, self.go_quota(), state(), hard=True)
        self.assertIsNone(model)
        self.assertIn("metered rows are never eligible", why)

    def test_t3_named_models_survive_alongside_a_metered_key(self):
        # pass-3 (S8): a role carrying BOTH 'models' and a tier key keeps its named models; the
        # metered row is refused with a reason but does not suppress the list. With the named
        # models quota-exhausted the refusal reason for the metered row must appear.
        cfg = self.go_config()
        cfg["roles"]["t3"] = {"models": ["claude-review", "codex-review"],
                              "metered": ["opencode-go/deepseek-v4.1-flash"]}
        # named models survive alongside the metered key: the first pick is a named model
        self.assertEqual(R.route_pick("t3", "bosgame", "", False, NOW, cfg, self.go_quota(), state())[0],
                         "claude-review")
        # with the named models quota-exhausted the refusal reason for the metered row must appear
        q = self.go_quota()
        q["pools"]["claude"]["used_pct"] = 100
        q["pools"]["codex"]["used_pct"] = 100
        model, why = R.route_pick("t3", "bosgame", "", False, NOW, cfg, q, state())
        self.assertIsNone(model)
        self.assertIn("metered rows are never eligible", why)

    def test_free_bindings_win_over_kimi(self):
        cfg = bindings_config()
        cfg["bans"] += [{"id_pattern": "^opencode-go/", "hard": False}]
        model, why = R.route_pick("build", "bosgame", "", False, NOW, cfg, bindings_quota(), state())
        self.assertEqual(model, "cat-jam@opencode")
        self.assertIn("free tier", why)

    def test_quota_example_labels_opencode_go_manual(self):
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "quota.json.example")
        with open(path) as f:
            doc = json.load(f)
        row = doc["pools"]["opencode-go"]
        self.assertEqual(row["used_pct"], 74)
        self.assertTrue(row["manual"])
        self.assertEqual(row["windows"], {"monthly_pct": 74, "weekly_pct": 49, "rolling_pct": 19, "days_left": 19.8})


class GateStep(unittest.TestCase):
    def gate_config(self):
        cfg = config()
        cfg["bans"] += [{"role": "gate-step", "family": "codex", "hard": False}]
        cfg["roles"]["gate-step"] = {"flat": ["kimi-build", "codex-review"]}
        return cfg

    def test_fixer_test_lint_doc_steps_go_to_kimi(self):
        self.assertEqual(R.route_pick("gate-step", "netcup", "", False, NOW, self.gate_config(), quota(), state())[0], "kimi-build")

    def test_codex_denied_for_routine_gate_step(self):
        q = quota(kimi=100)
        model, why = R.route_pick("gate-step", "netcup", "", False, NOW, self.gate_config(), q, state())
        self.assertIsNone(model)
        self.assertIn("banned", why)

    def test_codex_allowed_for_hard_t3_runs(self):
        cfg = self.gate_config()
        cfg["roles"]["gate-step"] = {"flat": ["codex-review"]}
        self.assertEqual(R.route_pick("gate-step", "netcup", "", False, NOW, cfg, quota(), state(), hard=True)[0], "codex-review")


class ReviewerRouting(unittest.TestCase):
    def test_openai_built_authors_get_the_off_host_muse_marker(self):
        for fam in ("codex", "gpt-6.1-sol", "gpt-5.6-sol", "openai"):
            self.assertEqual(R.route_reviewer(fam), "muse-spark-1.3-contributor-via-firstmate", fam)

    def test_muse_and_claude_built_authors_get_droid_sol(self):
        self.assertEqual(R.route_reviewer("muse"), "droid:gpt-6.1-sol")
        self.assertEqual(R.route_reviewer("claude"), "droid-local:gpt-6.1-sol")

    def test_other_families_get_droid_sol_not_wait(self):
        # pass-3 (S12): Kimi, free-model, DeepSeek and unknown/empty families still get the droid Sol
        # reviewer - never WAIT just because the writer family is unusual.
        for fam in ("kimi", "deepseek", "gemini", "free", ""):
            self.assertEqual(R.route_reviewer(fam), "droid:gpt-6.1-sol", fam)

    def test_live_data_never_gets_a_free_or_kimi_reviewer(self):
        # pass-3 (M5): live data is threaded into the reviewer policy; for every writer family the
        # pick is one of the approved markers (never a free or Kimi reviewer).
        for fam in ("codex", "gpt-6.1-sol", "muse", "claude", "kimi", "deepseek", "", "unknown"):
            pick = R.route_reviewer(fam, live_data=True)
            self.assertIn(pick, ("muse-spark-1.3-contributor-via-firstmate",
                                 "droid:gpt-6.1-sol", "droid-local:gpt-6.1-sol"), fam)

    def test_route_pick_review_delegates_for_every_family(self):
        # pass-3 (S11): route_pick('review') delegates to the writer-family policy for EVERY family
        # (an OpenAI author can never receive codex-top by rotation; a netcup author never Grok).
        expected = {
            "codex": "muse-spark-1.3-contributor-via-firstmate",
            "gpt-6.1-sol": "muse-spark-1.3-contributor-via-firstmate",
            "gpt-5.6-sol": "muse-spark-1.3-contributor-via-firstmate",
            "openai": "muse-spark-1.3-contributor-via-firstmate",
            "muse": "droid:gpt-6.1-sol",
            "claude": "droid-local:gpt-6.1-sol",
            "kimi": "droid:gpt-6.1-sol",
            "deepseek": "droid:gpt-6.1-sol",
            "gemini": "droid:gpt-6.1-sol",
            "": "droid:gpt-6.1-sol",
        }
        for fam, want in expected.items():
            for live in (False, True):
                model, why = R.route_pick("review", "netcup", fam, live, NOW, config(), quota(), state())
                self.assertEqual(model, want, (fam, live))
                self.assertIn("writer family", why)

    def test_route_pick_review_never_returns_role_table_models(self):
        # pass-3 (S11): even with a tempting review role table and full quotas, the review pick is
        # the family marker - never codex-top/muse-top/grok-top from the table.
        model, _ = R.route_pick("review", "bosgame", "codex", False, NOW, config(), quota(), state())
        self.assertEqual(model, "muse-spark-1.3-contributor-via-firstmate")

    def test_route_reviewer_script_prints_pick_and_threads_live_data(self):
        here = os.path.dirname(os.path.abspath(__file__))
        out = subprocess.run([os.path.join(here, "route-reviewer.sh"), "codex", "no"],
                             text=True, capture_output=True, check=True).stdout
        self.assertTrue(out.startswith("muse-spark-1.3-contributor-via-firstmate\t"), out)
        # pass-3 (M5): the script's live_data argument reaches the policy (was dropped before).
        out = subprocess.run([os.path.join(here, "route-reviewer.sh"), "codex", "yes"],
                             text=True, capture_output=True, check=True).stdout
        self.assertTrue(out.startswith("muse-spark-1.3-contributor-via-firstmate\t"), out)
        out = subprocess.run([os.path.join(here, "route-reviewer.sh"), "kimi", "yes"],
                             text=True, capture_output=True, check=True).stdout
        self.assertTrue(out.startswith("droid:gpt-6.1-sol\t"), out)
        bad = subprocess.run([os.path.join(here, "route-reviewer.sh"), "codex", "maybe"],
                             text=True, capture_output=True)
        self.assertEqual(bad.returncode, 2)

    def test_never_claude_free_or_kimi_as_reviewer(self):
        # pass-3 (S11): the delegation is structural - even when the review role table lists only
        # banned families, the pick is the droid marker, never a Claude/free/Kimi reviewer.
        cfg = config()
        cfg["models"]["free-x"] = {"family": "free-x", "billing": "free", "pool": "free-a"}
        cfg["models"]["kimi-x"] = {"family": "kimi", "billing": "flat", "pool": "kimi"}
        cfg["roles"]["review"] = {"models": ["claude-review", "free-x", "kimi-x"]}
        cfg["bans"] += [{"role": "review", "family": "claude"},
                        {"role": "review", "billing": "free"},
                        {"role": "review", "family": "kimi"}]
        self.assertEqual(R.route_pick("review", "netcup", "claude", False, NOW, cfg, quota(), state())[0],
                         "droid-local:gpt-6.1-sol")
        self.assertEqual(R.route_pick("review", "netcup", "kimi", False, NOW, cfg, quota(), state())[0],
                         "droid:gpt-6.1-sol")


class BindingHarnessBan(unittest.TestCase):
    def test_cline_harness_on_the_binding_bans_a_claude_model(self):
        # pass-3 (S10): the Claude-via-Cline ban must evaluate the RESOLVED BINDING's harness, not
        # only the model row's via: a Claude model bound on a cline harness is banned even when the
        # model row says via: claude.
        cfg = config()
        cfg["models"]["claude-top"] = {"id": "claude-opus-5-5", "family": "claude", "billing": "flat", "pool": "claude", "via": "claude", "effort": "high"}
        cfg["bindings"] = {"claude-top@cline": {"model": "claude-top", "provider": "cline",
                                                "harness": "cline", "weight": 1}}
        cfg["roles"]["t3"] = {"models": ["claude-top@cline"]}
        model, why = R.route_pick("t3", "bosgame", "", False, NOW, cfg, quota(), state())
        self.assertIsNone(model)
        self.assertIn("banned", why)

    def test_missing_harness_defaults_to_the_provider_before_bans(self):
        # pass-8 (review): binding-lane defaults a missing harness to the provider; ban
        # evaluation must see the SAME normalized binding - a Claude binding with provider cline
        # and no harness launches through cline and is denied by the Claude-via-Cline ban.
        cfg = config()
        cfg["models"]["claude-top"] = {"id": "claude-opus-5-5", "family": "claude", "billing": "flat", "pool": "claude", "via": "claude", "effort": "high"}
        cfg["bindings"] = {"claude-top@cline": {"model": "claude-top", "provider": "cline", "weight": 1}}
        cfg["pools"]["claude-top@cline"] = {"period_days": 7, "reserve": 30, "scarce": True}
        cfg["roles"]["t3"] = {"models": ["claude-top@cline"]}
        q = quota()
        q["pools"]["claude-top@cline"] = {"used_pct": 0, "reset_at": NOW + 7 * DAY,
                                          "source": "test", "observed_at": NOW, "manual": False}
        model, why = R.route_pick("t3", "bosgame", "", False, NOW, cfg, q, state())
        self.assertIsNone(model)
        self.assertIn("banned", why)

    def test_missing_harness_with_a_benign_provider_stays_reachable(self):
        # the same defaulting, benign side: provider droid and no harness is not the cline ban
        cfg = config()
        cfg["models"]["claude-top"] = {"id": "claude-opus-5-5", "family": "claude", "billing": "flat", "pool": "claude", "via": "claude", "effort": "high"}
        cfg["bindings"] = {"claude-top@droid": {"model": "claude-top", "provider": "droid", "weight": 1}}
        cfg["pools"]["claude-top@droid"] = {"period_days": 7, "reserve": 30, "scarce": True}
        cfg["roles"]["t3"] = {"models": ["claude-top@droid"]}
        q = quota()
        q["pools"]["claude-top@droid"] = {"used_pct": 0, "reset_at": NOW + 7 * DAY,
                                          "source": "test", "observed_at": NOW, "manual": False}
        self.assertEqual(R.route_pick("t3", "bosgame", "", False, NOW, cfg, q, state())[0],
                         "claude-top@droid")

    def test_binding_lane_cli_defaults_missing_harness_to_the_provider(self):
        # the sender-visible half of the shared normalization: a row with no harness resolves
        # with the provider as its harness
        fleet = """
models:
  cat-jam: {family: free, billing: free}
bindings:
  cat-jam@north: {model: cat-jam, provider: north, weight: 1}
"""
        with tempfile.TemporaryDirectory() as home:
            os.mkdir(os.path.join(home, "config"))
            with open(os.path.join(home, "config", "fleet.yaml"), "w") as f:
                f.write(fleet)
            r = subprocess.run([sys.executable, R.__file__, "binding-lane", "cat-jam@north"],
                               text=True, capture_output=True,
                               env=dict(os.environ, FM_HOME=home), timeout=60)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(r.stdout, "north\tcat-jam\tnorth\tmedium\n")

    def test_same_model_on_a_non_cline_binding_stays_reachable(self):
        cfg = config()
        cfg["models"]["claude-top"] = {"id": "claude-opus-5-5", "family": "claude", "billing": "flat", "pool": "claude", "via": "claude", "effort": "high"}
        cfg["bindings"] = {"claude-top@droid": {"model": "claude-top", "provider": "droid",
                                                "harness": "droid", "weight": 1}}
        cfg["pools"]["claude-top@droid"] = {"period_days": 7, "reserve": 30, "scarce": True}
        cfg["roles"]["t3"] = {"models": ["claude-top@droid"]}
        q = quota()
        q["pools"]["claude-top@droid"] = {"used_pct": 0, "reset_at": NOW + 7 * DAY,
                                          "source": "test", "observed_at": NOW, "manual": False}
        self.assertEqual(R.route_pick("t3", "bosgame", "", False, NOW, cfg, q, state())[0],
                         "claude-top@droid")


class QuotaExampleDoc(unittest.TestCase):
    def test_readme_key_is_ignored_and_placeholders_fail_closed(self):
        # pass-3 (M4): the example carries a loud '_readme' the reader ignores, and its reset_at /
        # observed_at are clearly marked placeholder STRINGS: copied verbatim, the pool is refused
        # as 'quota unknown' (never a permanent stale -> WAIT loop from 0/0 timestamps).
        here = os.path.dirname(os.path.abspath(__file__))
        with open(os.path.join(here, "quota.json.example")) as f:
            doc = json.load(f)
        self.assertIn("_readme", doc)
        cfg = R._load_fleet(os.path.join(here, "fleet.yaml.example"))
        row = doc["pools"]["opencode-go"]
        # The quota document's legacy placeholder must still fail closed when
        # applied to a current fleet pool; the v3.1 example has no opencode-go pool.
        ok, why = R._route_quota_ok("kimi", cfg["pools"]["kimi"], row, "t3", NOW, True)
        self.assertFalse(ok)
        self.assertEqual(why, "quota unknown")
        # the reader ignores _readme: a normal pick is unaffected by the extra key
        q = quota()
        q["_readme"] = doc["_readme"]
        cfg2 = config()
        cfg2["roles"]["build"] = {"free": ["free-a"]}
        self.assertEqual(R.route_pick("build", "bosgame", "", False, NOW, cfg2, q, state())[0], "free-a")


SHELL_SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "lane-refill-v2.sh")


def shell_function(name):
    """Extract one function's source from lane-refill-v2.sh so tests exercise the real script text."""
    lines = open(SHELL_SRC).read().splitlines()
    out, on = [], False
    for line in lines:
        if not on and re.match(r"^%s\(\)\s*\{" % re.escape(name), line):
            on = True
        if on:
            out.append(line)
            if line == "}":
                break
    assert on, "function %s not found in lane-refill-v2.sh" % name
    return "\n".join(out) + "\n"


import re  # noqa: E402


class NoteStartAtomic(unittest.TestCase):
    """pass-2 fix 6 (python side): atomic ledger write, failure reported."""

    def test_note_start_writes_via_replace_and_returns_true(self):
        with tempfile.TemporaryDirectory() as d:
            f = os.path.join(d, "starts.log")
            open(f, "w").write("\n".join(["1"] * 80) + "\n")
            before = set(os.listdir(d))
            self.assertTrue(R.note_start(f))
            lines = open(f).read().split()
            self.assertEqual(len(lines), 50)
            self.assertLess(time_mod.time() - int(lines[-1]), 5)
            self.assertEqual(set(os.listdir(d)), before)   # no temp file left behind

    def test_note_start_reports_failure_instead_of_truncating(self):
        with tempfile.TemporaryDirectory() as d:
            f = os.path.join(d, "starts.log")
            open(f, "w").write("12345\n")
            # root bypasses chmod, so permission bits cannot force this failure; inject it
            # instead: the final atomic os.replace raises an OSError however privileged the user.
            with mock.patch.object(R.os, "replace", side_effect=OSError(30, "Read-only file system")):
                self.assertFalse(R.note_start(f))
            self.assertEqual(open(f).read(), "12345\n")   # untouched on failure

    def test_note_start_cli_exit_codes(self):
        with tempfile.TemporaryDirectory() as d:
            ok = subprocess.run([sys.executable, R.__file__, "note-start", os.path.join(d, "a.log")])
            self.assertEqual(ok.returncode, 0)
            # a ledger whose parent path is a REGULAR FILE cannot be written at any privilege
            # (root bypasses chmod but not ENOTDIR), so the CLI exits 1 even when run as root.
            blocker = os.path.join(d, "blocker")
            open(blocker, "w").close()
            bad = subprocess.run([sys.executable, R.__file__, "note-start", os.path.join(blocker, "b.log")])
            self.assertEqual(bad.returncode, 1)


class ShellFixSource(unittest.TestCase):
    """pass-2 fixes 1/3/4/5: structural anchors in lane-refill-v2.sh (regression tripwires)."""

    SRC = open(SHELL_SRC).read()

    def test_snapshot_publish_is_locked_and_atomic(self):
        lock_i = self.SRC.index("flock -n 9")
        publish_i = self.SRC.index('mv -fT -- "$snaptmp" "$snapdest"')
        self.assertGreater(publish_i, lock_i, "snapshot publish must run after the run lock")
        self.assertIn('mktemp "$H/data/.bosgame-snapshot.json.', self.SRC)
        self.assertIn("bosgame-snapshot.fetch.$$", self.SRC)   # per-run temp names, not one shared file
        self.assertNotIn('cp "$snapnew" "$H/data/bosgame-snapshot.json"', self.SRC)

    def _block(self, start_marker, end_marker="done"):
        start = self.SRC.index(start_marker)
        return self.SRC[start:self.SRC.index(end_marker, start)]

    def test_start_first_honors_cap_and_holds_and_counts_only_success(self):
        blk = self._block('for pid in $(cat "$H/data/ds-start-first"')
        cap_i = blk.index('[ "$free" -gt 0 ] ||')          # pass-2 fix 3
        spawn_i = blk.index('spawn_routed "$pid"')
        fail_i = blk.index("START FAILED $pid")             # pass-2 fix 4
        count_i = blk.index("nds=$((nds+1))")
        self.assertLess(cap_i, spawn_i)
        self.assertLess(fail_i, count_i, "a failed spawn must not spend the budget")
        self.assertIn('[ "$free" -gt 0 ] && free=$((free-1))', blk)

    def test_resume_honors_cap_and_holds(self):
        blk = self._block('for m in $(sed', end_marker="done\n# chief 1739:")
        self.assertIn('[ "$free" -gt 0 ] ||', blk)          # pass-2 fix 3 on the resume path
        self.assertIn('[ "$free" -gt 0 ] && free=$((free-1))', blk)

    def test_holds_clear_the_budget_for_the_whole_pass(self):
        self.assertGreaterEqual(self.SRC.count("hold_all=1"), 2)   # new-leaves.hold + packet lock
        sn_i = self.SRC.index('[ "${hold_all:-0}" = 1 ] && { sn=0;')
        bs_i = self.SRC.index('bsends=0; [ "${hold_all:-0}" != 1 ]')
        self.assertLess(sn_i, bs_i, "the hold must clear sn before bsends is initialised")
        self.assertNotIn('bsends=0; [ "$bos" -lt "$BOS_CAP" ]', self.SRC, "bsends re-init must respect holds")

    # ---- pass-3 structural tripwires (S2/S3/S4/S5/S6) ----

    def test_every_launch_path_runs_router_admission(self):
        # Leaves, bosgame sends, start-first, resume and priority all pass through
        # route_leaf; planning is delegated to the dedicated feedback controller.
        self.assertGreaterEqual(self.SRC.count("route_leaf netcup"), 5)
        self.assertGreaterEqual(self.SRC.count("route_leaf bosgame"), 1)
        self.assertIn('route_leaf netcup "$pid" "$live_" "$prole" priority', self.SRC)
        self.assertIn('source "$B/router-planning.sh"', self.SRC)
        self.assertIn('router_planning_tick || exit 1', self.SRC)

    def test_leaf_router_pick_replaces_the_legacy_tier_route(self):
        # pass-3 (S2): the picked binding is applied to the netcup leaf spawn (tag=router branch),
        # and the admission runs BEFORE the legacy tier ladder.
        ladder_i = self.SRC.index('if [ "$islive" = yes ]; then   # chief 4556')
        admit_i = self.SRC.index('route_leaf netcup "$id" "$islive" build build || continue')
        self.assertLess(admit_i, ladder_i, "router admission must run before the tier ladder")
        self.assertIn('tag=router; why="Router v3.1 pick $ROUTE_PICK"', self.SRC)
        # pass-6: the router-pick route carries its own effort from the bindings table; the leaf
        # branch consumes ROUTE_ARGS verbatim (no second --effort).

    def test_bosgame_send_applies_the_picked_binding(self):
        # pass-5 (chief): the bosgame send receives the picked binding via --binding (resolved by
        # bosgame-leaf-send.sh through the fleet table; an unresolvable binding refuses the send),
        # and admission (route_leaf WAIT => no send) runs before the send line.
        self.assertIn('--binding', self.SRC)
        blk = self.SRC[self.SRC.index('if [ "$host" = bosgame ]; then'):self.SRC.index('dlog - "$suf" bosgame')]
        self.assertIn('route_leaf bosgame "$suf" "$pick_live" build build || continue', blk)
        admit_i = blk.index('route_leaf bosgame "$suf" "$pick_live" build build || continue')
        send_i = blk.index('bosgame-leaf-send.sh')
        self.assertLess(admit_i, send_i, "router admission must run before the bosgame send")
        self.assertIn('BG_EXTRA="--binding $ROUTE_PICK"', blk)
        self.assertIn('unresolvable binding refuses', blk)

    def test_go_relaunch_attempts_first_and_records_after_success(self):
        # pass-3 (S5) + pass-6: the ROUTER_LIVE defer is the first thing in the dead-agent branch
        # (a relaunch is a launch: under the live router it never starts), one_start runs only
        # after a verified relaunch, and a failed recording stops the pass without marking the GO.
        start = self.SRC.index('0) case $id in dos-planning*|dos-repoint-split-*)')
        blk = self.SRC[start:self.SRC.index('*) say "GO skipped', start)]
        cancel_i = blk.index('cancel_prior_admission "$id"')
        admit_i = blk.index('route_leaf netcup "$id"')
        relaunch_i = blk.index('relaunch_routed "$id"')
        send_i = blk.index('sendgo', relaunch_i)
        self.assertLess(cancel_i, admit_i)
        self.assertLess(admit_i, relaunch_i)
        self.assertLess(relaunch_i, send_i)

    def test_go_relaunch_honors_host_capacity_and_holds(self):
        # pass-3 (S6): the relaunch gate checks the netcup capacity/hold counter (free), not only sn
        # - netcup-leaves.hold zeroes free but leaves sn positive.
        self.assertIn('if [ "$free" -le 0 ]; then say "GO relaunch of $id held', self.SRC)

    def test_final_phase_helpers_are_gated_and_counted(self):
        # pass-3 (S4): closure-sweep and cloud-launch are gated on sn and hold_all, and their starts
        # are recorded with one_start only after success.
        blk = self.SRC[self.SRC.index('# ----'):] if '# ----' in self.SRC else self.SRC[self.SRC.index('4. LAND and close'):]
        cs_i = blk.index('run_routed_helper closure "$B/closure-sweep.sh"')
        cl_i = blk.index('run_routed_helper cloud "$B/cloud-launch.sh"')
        self.assertIn('[ "$sn" -gt 0 ]; then run_routed_helper closure', blk)
        self.assertIn('[ "$CLAUDE_OFF" = 0 ] && [ "$sn" -gt 0 ]; then run_routed_helper cloud', blk)
        self.assertIn('"${hold_all:-0}" != 1', blk)
        helper = shell_function("run_routed_helper")
        self.assertIn('ROUTER_HELPER_ACCOUNTS=1', helper)
        self.assertNotIn('wc -l', helper)


def write_stub(path, text):
    with open(path, "w") as f:
        f.write(text)
    os.chmod(path, 0o755)


class ShellFixRuntime(unittest.TestCase):
    """pass-2 fixes 2 and 6 (shell side): functions extracted from the real script, run with stubs."""

    def sandbox(self, tmp, can_start_out="5\tok", note_rc=0, race_times=2):
        root = os.path.join(tmp, "sb")
        home = os.path.join(root, "home")
        stubs = os.path.join(root, "stubs")
        for d in (os.path.join(home, "bin"), os.path.join(home, "data", "bin"), stubs):
            os.makedirs(d)
        log = os.path.join(root, "spawn.log")
        write_stub(os.path.join(stubs, "python3"), "#!/usr/bin/env bash\n"
                   "for a in \"$@\"; do\n"
                   "  case \"$a\" in\n"
                   "    can-start) printf '%b\\n' \"${CAN_START_OUT:-5\\tok}\"; exit 0;;\n"
                   "    note-start) exit \"${NOTE_RC:-0}\";;\n"
                   "  esac\n"
                   "done\nexit 0\n")
        write_stub(os.path.join(stubs, "sleep"), "#!/usr/bin/env bash\nexit 0\n")
        write_stub(os.path.join(stubs, "date"), "#!/usr/bin/env bash\n"
                   "n=$(cat \"${DATE_COUNT_FILE}\" 2>/dev/null || echo 0); echo $((n+1)) > \"${DATE_COUNT_FILE}\"\n"
                   "echo $(( 1700000000 + 30 * n ))\n")
        write_stub(os.path.join(home, "data", "bin", "claim-guard.sh"), "#!/usr/bin/env bash\nexit 0\n")
        write_stub(os.path.join(home, "bin", "fm-spawn.sh"), "#!/usr/bin/env bash\n"
                   "n=$(cat \"${SPAWN_LOG}.n\" 2>/dev/null || echo 0); echo $((n+1)) > \"${SPAWN_LOG}.n\"\n"
                   "echo \"$1\" >> \"${SPAWN_LOG}\"\n"
                   "if [ \"$n\" -lt \"${RACE_TIMES:-2}\" ]; then echo 'refusing to race it'; exit 75; fi\n"
                   "exit 0\n")
        return root, home, stubs, log

    def run_shell(self, tmp, body, env_extra=None):
        script = os.path.join(tmp, "t.sh")
        with open(script, "w") as f:
            f.write(body)
        env = dict(os.environ)
        env.update(env_extra or {})
        return subprocess.run(["bash", script], text=True, capture_output=True, env=env, timeout=60)

    def test_spawn_retry_rechecks_can_start_before_every_attempt(self):
        with tempfile.TemporaryDirectory(dir="/tmp/claude-1000", prefix="router-test-") as tmp:
            root, home, stubs, log = self.sandbox(tmp)
            body = (
                "set -u\n"
                "H=%s; B=$H/data/bin\n" % home +
                "DRY=0; sn=5; free=2; lfree=2; pfree=2; swhy=ok; SPAWN_PATH_PREFIX=''\n"
                "LANE_EU_HOST_FILE=/nonexistent.eu-host\n"
                "say() { echo \"lane-refill: $*\"; }\n"
                "router_prelaunch() { return 0; }\n"
                + shell_function("fresh_gate") + shell_function("spawn_retry") +
                "spawn_retry dos-test-1 /repo --mode no-mistakes >/dev/null 2>&1\n"
                "rc=$?; calls=0; [ -f '%s' ] && calls=$(wc -l < '%s'); echo \"rc=$rc calls=$calls\"\n" % (log, log)
            )
            # pass-7: can_start allowing nothing holds even the FIRST attempt now (the caller's
            # loop-level check precedes route probing, task setup and a possible 25 s reclaim
            # SSH): no spawn attempt at all.
            r = self.run_shell(tmp, body, {"PATH": stubs + ":" + os.environ["PATH"],
                                           "CAN_START_OUT": "0\tload5 9.0 >= 6",
                                           "SPAWN_LOG": log, "DATE_COUNT_FILE": os.path.join(root, "date.count")})
            self.assertIn("rc=77 calls=0", r.stdout, r.stdout + r.stderr)
            # can_start keeps allowing: the retry loop actually retries (several attempts, then the deadline).
            r = self.run_shell(tmp, body, {"PATH": stubs + ":" + os.environ["PATH"],
                                           "CAN_START_OUT": "5\tok", "RACE_TIMES": "10",
                                           "SPAWN_LOG": log, "DATE_COUNT_FILE": os.path.join(root, "date.count")})
            calls = int(r.stdout.strip().split("calls=")[1])
            self.assertGreaterEqual(calls, 4, r.stdout + r.stderr)

    def test_spawn_retry_rechecks_can_start_before_the_first_attempt(self):
        # pass-7 (review): a stub that flips the gate between the caller's loop-level check and
        # the spawn (route probing / task setup / a 25 s reclaim SSH can raise load) must hold
        # even the first spawn attempt.
        with tempfile.TemporaryDirectory(dir="/tmp/claude-1000", prefix="router-test-") as tmp:
            root, home, stubs, log = self.sandbox(tmp)
            open(log, "w").close()
            counter = os.path.join(root, "canstart.count")
            # the caller's loop-level check already ran (gate open); the FIRST can-start read
            # inside spawn_retry (the new pre-spawn recheck) sees load already crossed.
            write_stub(os.path.join(stubs, "python3"), "#!/usr/bin/env bash\n"
                       "for a in \"$@\"; do\n"
                       "  case \"$a\" in\n"
                       "    can-start) n=$(cat '%s' 2>/dev/null || echo 0); echo $((n+1)) > '%s'\n" % (counter, counter) +
                       "      if [ \"$n\" = 0 ]; then printf '0\\tload5 crossed 6\\n'; else printf '5\\tok\\n'; fi; exit 0;;\n"
                       "    note-start) exit \"${NOTE_RC:-0}\";;\n"
                       "  esac\n"
                       "done\nexit 0\n")
            body = (
                "set -u\n"
                "H=%s; B=$H/data/bin\n" % home +
                "DRY=0; sn=5; free=2; lfree=2; pfree=2; swhy=ok; SPAWN_PATH_PREFIX=''\n"
                "LANE_EU_HOST_FILE=/nonexistent.eu-host\n"
                "say() { echo \"lane-refill: $*\"; }\n"
                "router_prelaunch() { return 0; }\n"
                + shell_function("fresh_gate") + shell_function("spawn_retry") +
                "spawn_retry dos-test-1 /repo --mode no-mistakes; echo \"rc=$?\"\n"
                "echo \"calls=$(wc -l < '%s')\"\n" % log
            )
            r = self.run_shell(tmp, body, {"PATH": stubs + ":" + os.environ["PATH"],
                                           "SPAWN_LOG": log, "DATE_COUNT_FILE": os.path.join(root, "date.count")})
            self.assertIn("rc=77", r.stdout, r.stdout + r.stderr)
            self.assertIn("calls=0", r.stdout, r.stdout + r.stderr)
            self.assertIn("spawn held", r.stdout, r.stdout + r.stderr)

    def test_one_start_exhausts_budget_when_the_ledger_write_fails(self):
        with tempfile.TemporaryDirectory(dir="/tmp/claude-1000", prefix="router-test-") as tmp:
            root, home, stubs, log = self.sandbox(tmp)
            body = (
                "set -u\n"
                "H=%s; B=$H/data/bin\n" % home +
                "DRY=0; sn=3; free=2; lfree=2; pfree=2; swhy=ok\n"
                "say() { echo \"lane-refill: $*\"; }\n"
                + shell_function("fresh_gate") + shell_function("one_start") +
                "one_start >/dev/null 2>&1; echo \"after_success=$sn rc=$?\"\n"
                "NOTE_RC=1\n"
                "one_start; echo \"after_failure=$sn rc=$?\"\n"
            )
            r = self.run_shell(tmp, body, {"PATH": stubs + ":" + os.environ["PATH"],
                                           "NOTE_RC": "0",
                                           "DATE_COUNT_FILE": os.path.join(root, "date.count")})
            self.assertIn("after_success=2 rc=0", r.stdout, r.stdout + r.stderr)
            # pass-3 (S5): a failed recording now ALSO returns nonzero, so a caller that already
            # started something can stop instead of proceeding.
            self.assertIn("after_failure=0 rc=1", r.stdout, r.stdout + r.stderr)
            self.assertIn("start ledger write FAILED", r.stdout, r.stdout + r.stderr)


class RouterLeafRuntime(unittest.TestCase):
    """pass-3 (S2) + pass-6: route_leaf APPLIES the picked binding as spawn route args (resolved
    ONLY through the binding-lane CLI), refuses on WAIT, and warns on a bare model pick. Functions
    extracted from the real script; route-pick is stubbed, binding-lane runs for real against a
    fixture fleet.yaml."""

    FLEET = """
models:
  cat-jam: {family: free, billing: free}
bindings:
  cat-jam@opencode: {model: cat-jam, provider: opencode, harness: opencode, weight: 1}
  odd@zzz: {model: cat-jam, provider: north, harness: weirdh, weight: 1, effort: high}
roles:
  build: {free: [cat-jam@opencode, odd@zzz]}
pools:
  cat-jam@opencode: {period_days: 1, scarce: false}
  odd@zzz: {period_days: 1, scarce: false}
bans: []
"""

    def run_route_leaf(self, tmp, pick_out, live="no", fleet_text=None, quota_doc=None):
        root = os.path.join(tmp, "sb")
        home = os.path.join(root, "home")
        stubs = os.path.join(root, "stubs")
        for d in (os.path.join(home, "data"), stubs):
            os.makedirs(d)
        fleet = os.path.join(home, "fleet.yaml")
        with open(fleet, "w") as f:
            f.write(self.FLEET if fleet_text is None else fleet_text)
        quota_json = os.path.join(home, "quota.json")
        if quota_doc is not None:
            with open(quota_json, "w") as f:
                json.dump(quota_doc, f)
        # route-pick is stubbed (PICK_OUT) unless PICK_OUT is empty, in which case it delegates to
        # the real CLI against the fixture fleet (live=yes runs the true example-table admission);
        # binding-lane always delegates, so a binding whose id text differs from its table values
        # can only be resolved through the table.
        write_stub(os.path.join(stubs, "python3"), "#!/usr/bin/env bash\n"
                   "for a in \"$@\"; do\n"
                   "  case \"$a\" in\n"
                   "    route-pick) if [ -n \"${PICK_OUT}\" ]; then printf '%%b\\n' \"${PICK_OUT}\"; exit 0; fi\n"
                   "                FLEET_YAML='%s' QUOTA_JSON='%s' FM_HOME='%s' ROUTE_NOW='%s' exec '%s' '%s' \"${@:2}\";;\n"
                   % (fleet, quota_json, home, NOW, sys.executable, R.__file__) +
                   "    binding-lane) FLEET_YAML='%s' exec '%s' '%s' \"${@:2}\";;\n"
                   % (fleet, sys.executable, R.__file__) +
                   "  esac\n"
                   "done\nexit 0\n")
        body = (
            "set -u\n"
            "H=%s; B=$H/data/bin\n" % home +
            "DRY=0; DLOG=%s/lane-refill.log\n" % root +
            "ROUTE_PICK=''; ROUTE_ARGS=''; RA_REASON=''; RA_BINDING=''; RA_ARGV=()\n"
            "say() { echo \"say: $*\"; }\n"
            "dlog() { :; }\n"
            "router_admit() {\n"
            "  local row; row=$(printf '%b' \"$PICK_OUT\")\n"
            "  case $row in ''|WAIT*) RA_REASON='no eligible model'; return 75;; esac\n"
            "  IFS=$'\\t' read -r RA_BINDING RA_REASON RA_HARNESS RA_MODEL RA_PROVIDER RA_EFFORT <<< \"$row\"\n"
            "  [ -n \"${RA_PROVIDER:-}\" ] && [ -n \"${RA_HARNESS:-}\" ] || { RA_BINDING=; RA_REASON='unresolved binding'; return 75; }\n"
            "  RA_ARGV=(--harness \"$RA_HARNESS\" --model \"$RA_PROVIDER/$RA_MODEL\" --effort \"$RA_EFFORT\")\n"
            "}\n"
            + shell_function("route_leaf") +
            "route_leaf netcup 1.2 \"$LIVE\" build; echo \"rc=$? pick=$ROUTE_PICK args=$ROUTE_ARGS\"\n"
        )
        script = os.path.join(tmp, "t.sh")
        with open(script, "w") as f:
            f.write(body)
        env = dict(os.environ, PATH=stubs + ":" + os.environ["PATH"], PICK_OUT=pick_out, LIVE=live)
        return subprocess.run(["bash", script], text=True, capture_output=True, env=env, timeout=60)

    def test_binding_pick_is_applied_as_spawn_route_args(self):
        with tempfile.TemporaryDirectory(dir="/tmp/claude-1000", prefix="router-test-") as tmp:
            r = self.run_route_leaf(tmp, "cat-jam@opencode\\tfree tier; quota available\\topencode\\tcat-jam\\topencode\\tmedium")
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertIn("rc=0 pick=cat-jam@opencode "
                          "args=--harness opencode --model opencode/cat-jam --effort medium",
                          r.stdout, r.stdout + r.stderr)

    def test_binding_pick_resolves_through_binding_lane_not_the_id_text(self):
        # pass-6 (review): the id 'odd@zzz' would parse as harness zzz / model zzz/odd; the table
        # says harness weirdh, provider north, effort high - the TABLE must win. pass-9: route-pick now
        # returns the admitted lane columns under its lock, so the spawn route comes from those columns.
        with tempfile.TemporaryDirectory(dir="/tmp/claude-1000", prefix="router-test-") as tmp:
            r = self.run_route_leaf(tmp, "odd@zzz\\tfree tier; quota available\\tweirdh\\tcat-jam\\tnorth\\thigh")
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertIn("rc=0 pick=odd@zzz "
                          "args=--harness weirdh --model north/cat-jam --effort high",
                          r.stdout, r.stdout + r.stderr)

    def test_route_leaf_never_parses_the_binding_id_text(self):
        src = shell_function("route_leaf")
        self.assertNotIn('binding-lane', src)   # pass-9: no second fleet.yaml resolution
        self.assertNotIn('${picked_##*@}', src)
        self.assertNotIn('${picked_%@*}', src)

    def test_wait_means_no_launch(self):
        with tempfile.TemporaryDirectory(dir="/tmp/claude-1000", prefix="router-test-") as tmp:
            r = self.run_route_leaf(tmp, "WAIT\\tno eligible model")
            self.assertIn("rc=1", r.stdout, r.stdout + r.stderr)
            self.assertIn("args=", r.stdout)
            self.assertIn("ROUTER WAIT", r.stdout)

    def test_bare_model_pick_is_refused(self):
        # pass-7 (review): a bare-model pick carries no binding row, so the leaf/send is REFUSED
        # (route_leaf returns 1, the pick is cleared) instead of falling through to the legacy
        # route ladder unchecked.
        with tempfile.TemporaryDirectory(dir="/tmp/claude-1000", prefix="router-test-") as tmp:
            r = self.run_route_leaf(tmp, "kimi-build\\tflat plan; quota available")
            self.assertIn("rc=1", r.stdout, r.stdout + r.stderr)
            self.assertIn("pick= args=", r.stdout, r.stdout + r.stderr)
            self.assertIn("ROUTER WAIT", r.stdout, r.stdout + r.stderr)


    def test_live_leaf_wait_logs_no_eligible_route_line(self):
        # pass-8b (review): a LIVE leaf against the EXAMPLE fleet table has ZERO eligible build
        # rows (every free binding and Kimi is live-banned), so route_pick WAITS; the admission
        # logs ONE explicit line naming the fix, the leaf is skipped (route_leaf returns 1, no
        # route args), and the legacy Sonnet/Terra ladder is never entered.
        with tempfile.TemporaryDirectory(dir="/tmp/claude-1000", prefix="router-test-") as tmp:
            cfg = R._load_fleet(EXAMPLE_FLEET)
            r = self.run_route_leaf(tmp, "", live="yes",
                                    fleet_text=open(EXAMPLE_FLEET).read(), quota_doc=example_quota(cfg))
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertIn("rc=1 pick= args=", r.stdout, r.stdout + r.stderr)
            self.assertIn("ROUTER WAIT", r.stdout, r.stdout + r.stderr)

    def test_pick_cli_runs(self):
        # pass-3 (S1): the 'pick' CLI actually runs - the route-reviewer handler's local named
        # 'pick' shadowed pick() and raised UnboundLocalError.
        with tempfile.TemporaryDirectory(dir="/tmp/claude-1000", prefix="router-test-") as tmp:
            cands = os.path.join(tmp, "candidates.json")
            live = os.path.join(tmp, "live-paths.txt")
            open(live, "w").close()
            rows = [dict(id="dos-product-v1-88cgo.1.1", suf="1.1", prio=2, unblocks=0, est=60,
                         files=["core/src/a.py"], overlap=[], t1=False, bosgame_only=False,
                         netcup_only=False, netcup_label=False, free_ok=True, offline_ok=True,
                         title="leaf 1.1", body="x")]
            with open(cands, "w") as f:
                json.dump(rows, f)
            r = subprocess.run([sys.executable, R.__file__, "pick", cands, live, "2", "1"],
                               text=True, capture_output=True)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn("netcup 1.1", r.stdout)


import time as time_mod  # noqa: E402


class RouterLiveGateSource(unittest.TestCase):
    """v3.1 replaces the temporary live-mode deferrals with the shared admission seam."""

    SRC = open(SHELL_SRC).read()
    def test_switch_defaults_live_but_no_longer_defers_launch_paths(self):
        self.assertIn("ROUTER_LIVE=${ROUTER_LIVE:-1}", self.SRC)
        self.assertNotIn("router_defer", self.SRC)
        self.assertIn('source "$B/router-launch.sh"', self.SRC)
        self.assertIn('router_global_off && exit 0', self.SRC)

    def test_routed_paths_are_not_gated(self):
        # ordinary refill leaf starts and bosgame sends stay routed through route_pick/route_leaf
        leaf = self.SRC[self.SRC.index("# 3c. leaves:"):self.SRC.index("# ----", self.SRC.index("# 3c. leaves:"))]
        self.assertNotIn("router_defer", leaf)
        self.assertIn('route_leaf netcup "$id" "$islive" build build', leaf)
        self.assertIn('route_leaf bosgame "$suf" "$pick_live" build build || continue', leaf)
        self.assertIn("bosgame-leaf-send.sh", leaf)


class RouterLiveSwitchRuntime(unittest.TestCase):
    """Both switch values dispatch; zero preserves the former deferred tuples."""

    def test_both_values_are_covered_by_actual_callsite_runtime(self):
        src = open(os.path.join(os.path.dirname(SHELL_SRC), "test_router_v31_lanes.py")).read()
        self.assertIn('for live in ("0", "1")', src)
        self.assertIn("test_actual_priority_live_zero_preserves_legacy_routes", src)
        self.assertIn("test_actual_resume_live_zero_uses_deepseek_tuple_without_admission", src)
        self.assertIn("--model xai/grok-4.7", src)


class BareModelPickRefusedSource(unittest.TestCase):
    """v3.1 consumes only the admitted tuple returned by the shared seam."""

    SRC = open(SHELL_SRC).read()

    def test_route_leaf_refuses_a_pick_with_no_binding_args(self):
        src = shell_function("route_leaf")
        self.assertIn("router_admit", src)
        self.assertIn('ROUTE_ARGV=("${RA_ARGV[@]}")', src)
        self.assertNotIn("binding-lane", src)
        self.assertIn("return 1", src)

    def test_leaf_legacy_ladder_never_runs_before_admission(self):
        admit = 'route_leaf netcup "$id" "$islive" build build || continue'
        admit_i = self.SRC.index(admit)
        ladder_i = self.SRC.index('if [ "$islive" = yes ]; then   # chief 4556')
        self.assertLess(admit_i, ladder_i,
                        "router admission (which now refuses bare picks) precedes the legacy ladder")


class ProviderQualifiedBan(unittest.TestCase):
    """pass-7 (review): a ban id_pattern is also evaluated against the EFFECTIVE launch id
    '<provider>/<model>' (and '<harness>/<model>') of the resolved binding. A binding with model
    ds-flash on provider opencode-go constructs the launch id 'opencode-go/ds-flash', which the
    '^opencode-go/' routine-build ban must catch."""

    def cfg(self):
        cfg = config()
        cfg["models"]["ds-flash"] = {"family": "deepseek", "billing": "free"}
        cfg["bindings"] = {"ds-flash@opencode": {"model": "ds-flash", "provider": "opencode-go",
                                                  "harness": "opencode", "weight": 1}}
        cfg["pools"]["ds-flash@opencode"] = {"period_days": 1, "scarce": False}
        cfg["roles"]["build"] = {"free": ["ds-flash@opencode"]}
        cfg["bans"] += [{"id_pattern": "^opencode-go/", "hard": False}]
        return cfg

    def quota(self):
        q = quota()
        q["pools"]["ds-flash@opencode"] = {"used_pct": 0, "reset_at": NOW + DAY,
                                            "source": "test", "observed_at": NOW, "manual": False}
        return q

    def test_provider_qualified_binding_denied_for_routine_build(self):
        model, why = R.route_pick("build", "bosgame", "", False, NOW,
                                  self.cfg(), self.quota(), state())
        self.assertIsNone(model)
        self.assertIn("banned", why)

    def test_provider_qualified_binding_denied_for_manager_verdict(self):
        cfg = self.cfg()
        cfg["roles"]["manager"] = {"flat": ["ds-flash@opencode"]}
        model, why = R.route_pick("manager", "bosgame", "", False, NOW,
                                  cfg, self.quota(), state())
        self.assertIsNone(model)
        self.assertIn("manager admission WAIT", why)
        self.assertIn("banned", why)

    def test_hard_pick_is_not_banned_by_the_routine_row(self):
        # the ban row carries hard: false, so a hard role pick the table allows still routes
        model, why = R.route_pick("build", "bosgame", "", False, NOW,
                                  self.cfg(), self.quota(), state(), hard=True)
        self.assertEqual(model, "ds-flash@opencode")
        cfg = self.cfg()
        cfg["roles"]["manager"] = {"flat": ["ds-flash@opencode"]}
        model, why = R.route_pick("manager", "bosgame", "", False, NOW,
                                  cfg, self.quota(), state(), hard=True)
        self.assertEqual(model, "OK")


class SharedPoolResolver(unittest.TestCase):
    """pass-6 (review): ONE pool resolver shared by selection (route_pick), route-bench and the
    quota writes. route-bench must exhaust the SAME pool row selection reads."""

    def test_binding_row_pool_wins_else_the_binding_id(self):
        self.assertEqual(R.route_binding_pool("b@x", {"model": "m", "pool": "p1"}), "p1")
        self.assertEqual(R.route_binding_pool("b@x", {"model": "m"}), "b@x")
        self.assertEqual(R.route_binding_pool("b@x", {"model": "m", "pool": ""}), "b@x")
        self.assertEqual(R.route_binding_pool("b@x", None), "b@x")

    def test_selection_uses_the_same_resolver(self):
        # the resolver is the only pool source in route_pick's resolution loop
        src = open(R.__file__).read()
        self.assertIn("pool_name = route_binding_pool(entry, binding)", src)
        self.assertIn("pool = route_binding_pool(binding_id, row or {})", src)

    def test_example_cat_jam_exhaustion_marks_the_pool_selection_reads(self):
        # pass-6: fleet modeled on fleet.yaml.example - the MODEL row carries pool 'cat-jam', which
        # is not a pools-table key. Exhausting cat-jam@opencode must write the binding pool row
        # selection reads ('cat-jam@opencode') with that row's real reset - never a guessed 24 h
        # and never an unrelated 'cat-jam' row - and selection must then see the same exhaustion.
        with tempfile.TemporaryDirectory(dir="/tmp/claude-1000", prefix="router-test-") as home:
            config_dir = os.path.join(home, "config")
            state_dir = os.path.join(home, "state")
            os.mkdir(config_dir)
            os.mkdir(state_dir)
            with open(os.path.join(config_dir, "fleet.yaml"), "w") as f:
                f.write("""
models:
  cat-jam: {family: free, billing: free, pool: cat-jam}
bindings:
  cat-jam@opencode: {model: cat-jam, provider: opencode, harness: opencode, weight: 1}
  cat-jam@commandcode: {model: cat-jam, provider: commandcode, harness: commandcode, weight: 1}
roles:
  build: {free: [cat-jam@opencode, cat-jam@commandcode]}
pools:
  cat-jam@opencode: {period_days: 1, scarce: false}
  cat-jam@commandcode: {period_days: 1, scarce: false}
bans: []
""")
            pools = {name: {"used_pct": 40, "reset_at": NOW + 2 * DAY, "source": "test",
                            "observed_at": NOW, "manual": False}
                     for name in ("cat-jam@opencode", "cat-jam@commandcode")}
            with open(os.path.join(state_dir, "quota.json"), "w") as f:
                json.dump({"pools": pools}, f)
            env = dict(os.environ, FM_HOME=home, ROUTE_NOW=str(NOW))
            subprocess.run([sys.executable, R.__file__, "route-bench", "cat-jam@opencode",
                            "--reason", "402"], env=env, check=True)
            with open(os.path.join(state_dir, "route-bench.json")) as f:
                bench = json.load(f)
            # Payment failures use the fixed one-day funds window and do not rewrite quota.
            self.assertEqual(bench["bindings"]["cat-jam@opencode"]["until"], NOW + DAY)
            with open(os.path.join(state_dir, "quota.json")) as f:
                q = json.load(f)
            row = q["pools"]["cat-jam@opencode"]
            self.assertEqual(row["used_pct"], 40)
            self.assertEqual(row["source"], "test")
            self.assertEqual(row["reset_at"], NOW + 2 * DAY)
            self.assertNotIn("cat-jam", q["pools"])            # the unrelated model-pool row is never created
            self.assertFalse(os.path.exists(os.path.join(state_dir, "route-alerts.log")))
            # selection reads the SAME row: the exhausted+benched binding is skipped and the
            # sibling binding rotates in - proof both sides resolve one pool.
            pick = subprocess.run([sys.executable, R.__file__, "route-pick", "build", "bosgame", "", "no"],
                                  env=env, text=True, capture_output=True, check=True).stdout.split("\t", 1)[0]
            self.assertEqual(pick, "cat-jam@commandcode")


if __name__ == "__main__":
    unittest.main()
