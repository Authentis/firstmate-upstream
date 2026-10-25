#!/usr/bin/env python3
"""Router v3.1 admission-state CLI tests. Fixtures only; no external calls."""
import json
import os
import subprocess
import sys
import tempfile
import unittest

import yaml


BIN = os.path.dirname(os.path.abspath(__file__))
REFILL = os.path.join(BIN, "refill_lib_v2.py")
NOW = 2_000_000_000
DAY = 86_400


def fleet(simultaneous=5, daily=3):
    return {
        "models": {
            "free": {"id": "vendor/free-free", "family": "beam", "billing": "free"},
            "sol-plan": {"id": "openai-codex/gpt-6.1-sol", "family": "codex", "billing": "flat"},
            "cloud-free": {"id": "vendor/cloud-free", "family": "beam", "billing": "free"},
            "cloud-claude": {"id": "claude-sonnet-5-5", "family": "claude", "billing": "flat"},
        },
        "bindings": {
            "free@pi": {"model": "free", "provider": "vendor", "harness": "pi"},
            "sol-plan@pi": {"model": "sol-plan", "provider": "openai-codex", "harness": "pi", "effort": "high"},
            "cloud-free@pi": {"model": "cloud-free", "provider": "vendor", "harness": "pi", "cloud_capable": True},
            "cloud-claude@claude": {"model": "cloud-claude", "provider": "anthropic", "harness": "claude", "cloud_capable": True},
        },
        "roles": {
            "build": {"models": ["free@pi", "sol-plan@pi"]},
            "plan": {"models": ["sol-plan@pi"]},
            "cloud": {"models": ["cloud-free@pi", "cloud-claude@claude"]},
        },
        "pools": {
            "free@pi": {"period_days": 7, "scarce": False},
            "sol-plan@pi": {"period_days": 7, "scarce": False},
            "cloud-free@pi": {"period_days": 7, "scarce": False},
            "cloud-claude@claude": {"period_days": 7, "scarce": False},
        },
        "bans": [{"billing": "free", "live_data": True}],
        "catalogs": {"netcup": {"path": "state/catalog-netcup.json", "max_age_seconds": DAY}},
        "routing_state": {
            "cloud_simultaneous_max": simultaneous,
            "claude_cloud_per_day": daily,
            "cloud_claude_exception": False,
        },
    }


class StateCli(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = self.tmp.name
        os.makedirs(os.path.join(self.home, "config"))
        os.makedirs(os.path.join(self.home, "state"))
        os.makedirs(os.path.join(self.home, "data"))
        cfg = fleet()
        with open(os.path.join(self.home, "config/fleet.yaml"), "w") as f:
            yaml.safe_dump(cfg, f)
        quota = {"pools": {name: {"used_pct": 0, "reset_at": NOW + 7 * DAY,
                                    "observed_at": NOW, "source": "fixture", "manual": False}
                            for name in cfg["pools"]}}
        with open(os.path.join(self.home, "state/quota.json"), "w") as f:
            json.dump(quota, f)
        rows = {model["id"]: {"cost": {"input": 0, "output": 0}}
                for model in cfg["models"].values()}
        rows["anthropic/claude-sonnet-5-5"] = rows.pop("claude-sonnet-5-5")
        with open(os.path.join(self.home, "state/catalog-netcup.json"), "w") as f:
            json.dump({"host": "netcup", "observed_at": NOW, "models": rows}, f)
        self.env = dict(os.environ, FM_HOME=self.home, ROUTE_NOW=str(NOW))

    def tearDown(self):
        self.tmp.cleanup()

    def cli(self, *args, check=True, env=None):
        return subprocess.run([sys.executable, REFILL, *args], env=env or self.env,
                              text=True, capture_output=True, check=check)

    def admit(self, task, kind="build", role="build", live="no", only=None, env=None):
        args = ["route-admit", task, kind, role, "netcup", live]
        if only is not None:
            args.append(only)
        result = self.cli(*args, env=env)
        fields = result.stdout.strip().split("\t")
        self.assertEqual(len(fields), 8, result.stdout + result.stderr)
        return fields

    def sidecar(self, task):
        with open(os.path.join(self.home, "state/route-launches", task + ".json")) as f:
            return json.load(f)

    def snapshot_home(self):
        result = {}
        for root, _, files in os.walk(self.home):
            for name in files:
                path = os.path.join(root, name)
                with open(path, "rb") as f:
                    result[os.path.relpath(path, self.home)] = f.read()
        return result

    def bench(self):
        with open(os.path.join(self.home, "state/route-bench.json")) as f:
            return json.load(f)

    def receipts(self):
        path = os.path.join(self.home, "state/route-launches/receipts.jsonl")
        if not os.path.exists(path):
            return []
        with open(path) as f:
            return [json.loads(line) for line in f if line.strip()]

    def test_admission_sidecar_and_confirm_are_idempotent(self):
        fields = self.admit("leaf-1")
        self.assertEqual(fields[:6], ["free@pi", fields[1], "pi", "vendor/free-free", "vendor", "medium"])
        self.assertEqual(json.loads(fields[7]), [])
        incarnation = fields[6]
        sidecar = self.sidecar("leaf-1")
        self.assertEqual((sidecar["binding"], sidecar["role"], sidecar["kind"], sidecar["host"]),
                         ("free@pi", "build", "build", "netcup"))
        self.assertTrue(sidecar["pending"])
        repeat = self.admit("leaf-1")
        self.assertEqual(repeat[6], incarnation)
        self.cli("route-confirm", "leaf-1", incarnation, "session-1")
        self.cli("route-confirm", "leaf-1", incarnation, "session-1")
        self.assertEqual(len(self.receipts()), 1)
        self.assertFalse(self.sidecar("leaf-1")["pending"])
        bad = self.cli("route-confirm", "leaf-1", incarnation, "different-session", check=False)
        self.assertEqual(bad.returncode, 2)
        self.assertEqual(len(self.receipts()), 1)
        self.assertEqual(self.admit("leaf-1")[0], "WAIT")

    def test_confirm_recovers_after_receipt_append_before_sidecar_update(self):
        fields = self.admit("leaf-crash")
        sidecar = self.sidecar("leaf-crash")
        receipt = {key: sidecar[key] for key in
                   ("task", "kind", "binding", "host", "incarnation", "admitted_at")}
        receipt.update(v=1, verified_at=NOW, session="crash-session")
        path = os.path.join(self.home, "state/route-launches/receipts.jsonl")
        with open(path, "w") as f:
            f.write(json.dumps(receipt) + "\n")
        self.cli("route-confirm", "leaf-crash", fields[6], "crash-session")
        self.assertEqual(len(self.receipts()), 1)
        self.assertEqual(self.sidecar("leaf-crash")["state"], "confirmed")

    def test_cloud_confirm_fails_closed_before_receipt_on_invalid_daily_limit(self):
        fields = self.admit("cloud-limit-config", kind="cloud", role="cloud")
        cfg = fleet()
        cfg["routing_state"]["claude_cloud_per_day"] = "invalid"
        with open(os.path.join(self.home, "config/fleet.yaml"), "w") as f:
            yaml.safe_dump(cfg, f)
        result = self.cli("route-confirm", "cloud-limit-config", fields[6],
                          "limit-session", check=False)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.receipts(), [])
        self.assertTrue(self.sidecar("cloud-limit-config")["pending"])

    def test_cancel_releases_pending_without_bench(self):
        fields = self.admit("leaf-cancel")
        self.cli("route-cancel", "leaf-cancel", fields[6])
        self.assertFalse(self.sidecar("leaf-cancel")["pending"])
        self.assertEqual(self.bench().get("bindings", {}), {})

    def test_route_check_is_exact_tuple_and_has_zero_state_mutation(self):
        before = self.snapshot_home()
        result = self.cli("route-check", "live-go", "go", "build", "netcup", "no", "sol-plan@pi")
        fields = result.stdout.strip().split("\t")
        self.assertEqual(len(fields), 8)
        self.assertEqual((fields[0], fields[2], fields[3], fields[6]),
                         ("sol-plan@pi", "pi", "openai-codex/gpt-6.1-sol", "CHECK"))
        self.assertEqual(self.snapshot_home(), before)
        self.assertFalse(os.path.exists(os.path.join(self.home, "state/route-launches/live-go.json")))

    def test_invalid_explicit_state_paths_fail_closed_without_fallback(self):
        for index, name in enumerate(("FLEET_YAML", "QUOTA_JSON", "BENCH_JSON")):
            with self.subTest(name=name):
                env = dict(self.env, **{name: "../outside-router-home"})
                fields = self.admit("bad-path-%d" % index, env=env)
                self.assertEqual(fields[0], "WAIT")
                self.assertIn(name, fields[1])
                self.assertFalse(os.path.exists(os.path.join(
                    self.home, "state/route-launches/bad-path-%d.json" % index)))

    def test_existing_malformed_task_sidecar_fails_closed_without_overwrite(self):
        launches = os.path.join(self.home, "state/route-launches")
        os.makedirs(launches)
        path = os.path.join(launches, "broken-task.json")
        original = b'{"v":1,"pending":'
        with open(path, "wb") as f:
            f.write(original)
        fields = self.admit("broken-task")
        self.assertEqual(fields[0], "WAIT")
        self.assertIn("sidecar", fields[1])
        with open(path, "rb") as f:
            self.assertEqual(f.read(), original)

    def test_malformed_cloud_sidecar_fails_closed_without_state_change(self):
        launches = os.path.join(self.home, "state/route-launches")
        os.makedirs(launches)
        path = os.path.join(launches, "dangling-cloud.json")
        sidecar = {
            "v": 1, "task": "dangling-cloud", "kind": "cloud", "role": "cloud",
            "host": "netcup", "binding": "cloud-free@pi", "harness": "pi",
            "model": "vendor/cloud-free", "provider": "vendor", "effort": "medium",
            "incarnation": "dangling-inc", "admitted_at": float("nan"),
            "pending": True, "state": "admitted",
        }
        with open(path, "w") as f:
            json.dump(sidecar, f)
        with open(path, "rb") as f:
            before = f.read()
        fields = self.admit("new-cloud", kind="cloud", role="cloud")
        self.assertEqual(fields[0], "WAIT")
        self.assertIn("sidecar", fields[1])
        with open(path, "rb") as f:
            self.assertEqual(f.read(), before)
        self.assertFalse(os.path.exists(os.path.join(launches, "new-cloud.json")))
        self.assertFalse(os.path.exists(os.path.join(self.home, "state/route-bench.json")))

    def test_existing_malformed_bench_fails_closed_without_reset(self):
        path = os.path.join(self.home, "state/route-bench.json")
        original = b'["not", "a", "bench"]'
        with open(path, "wb") as f:
            f.write(original)
        checked = self.cli("route-check", "bad-bench-check", "build", "build",
                           "netcup", "no")
        self.assertEqual(checked.stdout.split("\t", 1)[0], "WAIT")
        admitted = self.admit("bad-bench-admit")
        self.assertEqual(admitted[0], "WAIT")
        self.assertIn("bench", admitted[1])
        with open(path, "rb") as f:
            self.assertEqual(f.read(), original)

    def test_valid_explicit_bench_path_is_honored(self):
        custom = os.path.join(self.home, "state/custom-bench.json")
        with open(custom, "w") as f:
            json.dump({"models": {}, "cursor": {}, "bindings": {
                "free@pi": {"until": NOW + DAY, "reason": "429"}}}, f)
        env = dict(self.env, BENCH_JSON="state/custom-bench.json")
        result = self.cli("route-check", "custom-bench", "build", "build",
                          "netcup", "no", env=env)
        self.assertEqual(result.stdout.split("\t", 1)[0], "sol-plan@pi")
        self.assertFalse(os.path.exists(os.path.join(self.home, "state/route-bench.json")))

    def test_configured_bench_path_is_honored_and_escape_fails_closed(self):
        cfg = fleet()
        cfg["routing_state"]["bench"] = "state/configured-bench.json"
        with open(os.path.join(self.home, "config/fleet.yaml"), "w") as f:
            yaml.safe_dump(cfg, f)
        with open(os.path.join(self.home, "state/configured-bench.json"), "w") as f:
            json.dump({"models": {}, "cursor": {}, "bindings": {
                "free@pi": {"until": NOW + DAY, "reason": "429"}}}, f)
        checked = self.cli("route-check", "configured-bench", "build", "build",
                           "netcup", "no")
        self.assertEqual(checked.stdout.split("\t", 1)[0], "sol-plan@pi")
        cfg["routing_state"]["bench"] = "../outside-router-home"
        with open(os.path.join(self.home, "config/fleet.yaml"), "w") as f:
            yaml.safe_dump(cfg, f)
        refused = self.admit("configured-bench-escape")
        self.assertEqual(refused[0], "WAIT")
        self.assertIn("bench", refused[1].lower())
        self.assertFalse(os.path.exists(os.path.join(
            self.home, "state/route-launches/configured-bench-escape.json")))

    def test_failure_is_sanitized_deduplicated_and_stale_incarnation_ignored(self):
        fields = self.admit("leaf-fail", role="plan", kind="plan")
        incarnation = fields[6]
        self.cli("route-failure", "leaf-fail", incarnation, "event-1", "402",
                 "token=SUPERSECRET INSUFFICIENT BALANCE")
        first = self.bench()["bindings"]["sol-plan@pi"]["until"]
        later = dict(self.env, ROUTE_NOW=str(NOW + 100))
        self.cli("route-failure", "leaf-fail", incarnation, "event-1", "402",
                 "api_key=ANOTHER insufficient balance", env=later)
        self.cli("route-failure", "leaf-fail", "stale-inc", "event-2", "429", "rate", env=later)
        self.assertEqual(self.bench()["bindings"]["sol-plan@pi"]["until"], first)
        self.assertEqual(first, NOW + DAY)
        encoded = json.dumps(self.sidecar("leaf-fail"))
        self.assertNotIn("SUPERSECRET", encoded)
        self.assertNotIn("ANOTHER", encoded)
        self.assertEqual(self.sidecar("leaf-fail")["last_failure_event"],
                         {"id": "event-1", "incarnation": incarnation})

    def test_nonfunds_exhaustion_uses_pool_reset_and_marks_quota_used(self):
        fields = self.admit("leaf-exhaust", role="plan", kind="plan")
        self.cli("route-failure", "leaf-exhaust", fields[6], "event-exhaust", "500",
                 "weekly limit reached api_key=SECRET")
        record = self.bench()["bindings"]["sol-plan@pi"]
        self.assertEqual(record["reason"], "exhaustion")
        self.assertEqual(record["until"], NOW + 7 * DAY)
        with open(os.path.join(self.home, "state/quota.json")) as f:
            quota = json.load(f)
        self.assertEqual(quota["pools"]["sol-plan@pi"]["used_pct"], 100)
        self.assertNotIn("SECRET", json.dumps(self.sidecar("leaf-exhaust")))

    def test_watcher_nonfunds_exhaustion_uses_pool_reset(self):
        self.admit("leaf-watch-exhaust", role="plan", kind="plan")
        with open(os.path.join(self.home, "state/leaf-watch-exhaust.status"), "w") as f:
            f.write("provider error: usage limit reached token=SECRET\n")
        self.assertEqual(self.admit("leaf-after-exhaust", role="plan", kind="plan")[0], "WAIT")
        record = self.bench()["bindings"]["sol-plan@pi"]
        self.assertEqual((record["reason"], record["until"]),
                         ("exhaustion", NOW + 7 * DAY))
        with open(os.path.join(self.home, "state/quota.json")) as f:
            quota = json.load(f)
        self.assertEqual(quota["pools"]["sol-plan@pi"]["used_pct"], 100)
        self.assertNotIn("SECRET", json.dumps(self.sidecar("leaf-watch-exhaust")))

    def test_failure_event_identity_does_not_age_out_and_replay(self):
        fields = self.admit("leaf-events", role="plan", kind="plan")
        path = os.path.join(self.home, "state/route-launches/leaf-events.json")
        sidecar = self.sidecar("leaf-events")
        sidecar["queued_events"] = [
            {"id": "event-%d" % i, "status": "429", "message": "rate limit"}
            for i in range(65)
        ] + [{"id": "event-0", "status": "429", "message": "rate limit"}]
        with open(path, "w") as f:
            json.dump(sidecar, f)
        self.admit("event-trigger")
        sidecar = self.sidecar("leaf-events")
        self.assertEqual(len(sidecar["processed_failure_events"]), 65)
        self.assertEqual(sidecar["last_failure_event"]["id"], "event-64")
        self.assertNotIn("queued_events", sidecar)

    def test_watcher_status_is_observed_once_before_next_pick(self):
        first = self.admit("leaf-watch", role="plan", kind="plan")
        status = os.path.join(self.home, "state/leaf-watch.status")
        with open(status, "w") as f:
            f.write("provider returned 402 insufficient balance token=SECRET\n")
        second = self.admit("leaf-next", role="plan", kind="plan")
        self.assertEqual(second[0], "WAIT")
        until = self.bench()["bindings"]["sol-plan@pi"]["until"]
        later = dict(self.env, ROUTE_NOW=str(NOW + 10))
        self.admit("leaf-next-2", role="plan", kind="plan", env=later)
        self.assertEqual(self.bench()["bindings"]["sol-plan@pi"]["until"], until)
        self.assertNotIn("SECRET", json.dumps(self.sidecar("leaf-watch")))
        self.assertFalse(self.sidecar("leaf-watch")["pending"])

    def test_old_status_is_baselined_and_not_replayed_into_new_incarnation(self):
        status = os.path.join(self.home, "state/leaf-old.status")
        with open(status, "w") as f:
            f.write("old worker 402 insufficient balance token=OLD\n")
        fields = self.admit("leaf-old", role="plan", kind="plan")
        self.assertEqual(fields[0], "sol-plan@pi")
        self.assertFalse(os.path.exists(os.path.join(self.home, "state/route-bench.json")) and
                         self.bench().get("bindings"))
        with open(status, "w") as f:
            f.write("new worker 429\n")
        self.assertEqual(self.admit("leaf-after-old", role="plan", kind="plan")[0], "WAIT")
        self.assertEqual(self.bench()["bindings"]["sol-plan@pi"]["until"], NOW + 1800)

    def test_confirmed_worker_async_failure_is_observed(self):
        fields = self.admit("cloud-async", kind="cloud", role="cloud")
        self.cli("route-confirm", "cloud-async", fields[6], "async-session")
        with open(os.path.join(self.home, "state/cloud-async.status"), "w") as f:
            f.write("provider: INSUFFICIENT BALANCE\n")
        self.admit("ordinary-trigger")
        self.assertEqual(self.sidecar("cloud-async")["state"], "failed")
        self.assertEqual(self.bench()["bindings"][fields[0]]["until"], NOW + DAY)

    def test_stale_pending_expires_but_ambiguous_reservation_does_not(self):
        cfg = fleet(simultaneous=1, daily=9)
        cfg["roles"]["cloud"] = {"models": ["cloud-free@pi"]}
        cfg["routing_state"]["pending_reservation_seconds"] = 30
        with open(os.path.join(self.home, "config/fleet.yaml"), "w") as f:
            yaml.safe_dump(cfg, f)
        first = self.admit("cloud-ambiguous", kind="cloud", role="cloud")
        self.cli("route-ambiguous", "cloud-ambiguous", first[6], "maybe-live-session")
        ambiguous = self.sidecar("cloud-ambiguous")
        self.assertEqual((ambiguous["pending"], ambiguous["state"], ambiguous["session"]),
                         (True, "ambiguous", "maybe-live-session"))
        self.cli("route-ambiguous", "cloud-ambiguous", first[6], "maybe-live-session")
        conflict = self.cli("route-ambiguous", "cloud-ambiguous", first[6],
                            "different-session", check=False)
        self.assertEqual(conflict.returncode, 2)
        later = dict(self.env, ROUTE_NOW=str(NOW + 30))
        self.assertEqual(self.admit("cloud-ambiguous", kind="cloud", role="cloud", env=later)[0], "WAIT")
        self.assertEqual(self.admit("cloud-blocked", kind="cloud", role="cloud", env=later)[0], "WAIT")
        self.cli("route-cancel", "cloud-ambiguous", first[6])
        expiring = self.admit("cloud-stale", kind="cloud", role="cloud")
        self.assertEqual(expiring[0], "cloud-free@pi")
        self.assertEqual(self.admit("cloud-new", kind="cloud", role="cloud", env=later)[0], "cloud-free@pi")
        self.assertEqual(self.sidecar("cloud-stale")["state"], "expired")

    def test_simultaneous_limit_reserves_under_one_lock(self):
        cfg = fleet(simultaneous=2, daily=9)
        cfg["roles"]["cloud"] = {"models": ["cloud-free@pi"]}
        with open(os.path.join(self.home, "config/fleet.yaml"), "w") as f:
            yaml.safe_dump(cfg, f)
        procs = [subprocess.Popen([sys.executable, REFILL, "route-admit", "cloud-%d" % i,
                                  "cloud", "cloud", "netcup", "no"], env=self.env,
                                 text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                 for i in range(4)]
        outputs = [p.communicate(timeout=10)[0].split("\t", 1)[0] for p in procs]
        self.assertEqual(outputs.count("cloud-free@pi"), 2)
        self.assertEqual(outputs.count("WAIT"), 2)

    def test_daily_verified_limit_and_running_ledger_union_deduplicate_sessions(self):
        cfg = fleet(simultaneous=5, daily=2)
        cfg["roles"]["cloud"] = {"models": ["cloud-free@pi"]}
        with open(os.path.join(self.home, "config/fleet.yaml"), "w") as f:
            yaml.safe_dump(cfg, f)
        one = self.admit("cloud-one", kind="cloud", role="cloud")
        self.cli("route-confirm", "cloud-one", one[6], "sess-one")
        self.assertEqual(self.bench()["cloud_daily"]["sessions"], ["sess-one"])
        with open(os.path.join(self.home, "data/cloud-workers.tsv"), "w") as f:
            f.write("%d\tcloud-one\tsess-one\trunning\n" % NOW)
        two = self.admit("cloud-two", kind="cloud", role="cloud")
        self.cli("route-confirm", "cloud-two", two[6], "sess-two")
        self.cli("route-cancel", "cloud-one", one[6])
        self.cli("route-cancel", "cloud-two", two[6])
        self.assertEqual(self.admit("cloud-three", kind="cloud", role="cloud")[0], "WAIT")

    def test_malformed_existing_cloud_ledger_fails_closed(self):
        with open(os.path.join(self.home, "data/cloud-workers.tsv"), "w") as f:
            f.write("malformed row\n")
        result = self.admit("cloud-bad-ledger", kind="cloud", role="cloud")
        self.assertEqual(result[0], "WAIT")
        self.assertIn("ledger", result[1])

    def test_nonfinite_cloud_ledger_epoch_fails_closed(self):
        with open(os.path.join(self.home, "data/cloud-workers.tsv"), "w") as f:
            f.write("nan\tcloud-old\told-session\trunning\n")
        result = self.admit("cloud-nan-ledger", kind="cloud", role="cloud")
        self.assertEqual(result[0], "WAIT")
        self.assertIn("ledger", result[1])

    def test_malformed_existing_receipt_ledger_fails_closed(self):
        os.makedirs(os.path.join(self.home, "state/route-launches"))
        with open(os.path.join(self.home, "state/route-launches/receipts.jsonl"), "w") as f:
            f.write(json.dumps({"v": 1, "task": "old", "kind": "cloud",
                                "binding": "cloud-free@pi", "host": "netcup",
                                "incarnation": "old-inc", "admitted_at": NOW,
                                "verified_at": "not-an-epoch", "session": "old-session"}) + "\n")
        result = self.admit("cloud-bad-receipt", kind="cloud", role="cloud")
        self.assertEqual(result[0], "WAIT")
        self.assertIn("receipt", result[1])

    def test_finished_ledger_row_releases_confirmed_simultaneous_slot(self):
        cfg = fleet(simultaneous=1, daily=9)
        cfg["roles"]["cloud"] = {"models": ["cloud-free@pi"]}
        with open(os.path.join(self.home, "config/fleet.yaml"), "w") as f:
            yaml.safe_dump(cfg, f)
        first = self.admit("cloud-finished", kind="cloud", role="cloud")
        self.cli("route-confirm", "cloud-finished", first[6], "done-session")
        with open(os.path.join(self.home, "data/cloud-workers.tsv"), "w") as f:
            f.write("%d\tcloud-finished\tdone-session\tfinished\n" % NOW)
        self.assertEqual(self.admit("cloud-replacement", kind="cloud", role="cloud")[0], "cloud-free@pi")

    def test_claude_requires_same_call_exhaustion_or_explicit_exception(self):
        cfg = fleet()
        with open(os.path.join(self.home, "config/fleet.yaml"), "w") as f:
            yaml.safe_dump(cfg, f)
        fields = self.admit("cloud-proof", kind="cloud", role="cloud", only="cloud-claude@claude")
        self.assertEqual(fields[0], "WAIT")
        self.cli("route-failure", "missing", "inc", "e", "402", "insufficient balance")
        # Bench the non-Claude candidate through a real reserved incarnation.
        free = self.admit("cloud-free", kind="cloud", role="cloud", only="cloud-free@pi")
        self.cli("route-failure", "cloud-free", free[6], "funds", "402", "insufficient balance")
        fields = self.admit("cloud-proof-2", kind="cloud", role="cloud", only="cloud-claude@claude")
        self.assertEqual(fields[0], "cloud-claude@claude")
        proof = json.loads(fields[7])
        self.assertEqual(proof[0]["binding"], "cloud-free@pi")
        self.assertIn("benched", proof[0]["reason"])

    def test_claude_off_and_path_traversal_refuse_without_writes(self):
        cfg = fleet()
        cfg["routing_state"]["cloud_claude_exception"] = True
        cfg["roles"]["cloud"] = {"models": ["cloud-claude@claude"]}
        with open(os.path.join(self.home, "config/fleet.yaml"), "w") as f:
            yaml.safe_dump(cfg, f)
        open(os.path.join(self.home, "data/claude-off"), "w").close()
        self.assertEqual(self.admit("cloud-off", kind="cloud", role="cloud")[0], "WAIT")
        for task in ("../escape", "a/b", ".."):
            result = self.cli("route-admit", task, "build", "build", "netcup", "no", check=False)
            self.assertEqual(result.returncode, 2)
        self.assertFalse(os.path.exists(os.path.dirname(self.home) + "/escape.json"))

    def test_repeat_admission_revalidates_router_off(self):
        self.admit("leaf-recheck")
        open(os.path.join(self.home, "data/router-off"), "w").close()
        self.assertEqual(self.admit("leaf-recheck")[0], "WAIT")

    def test_classify_requires_text_and_delegates_to_cred_match(self):
        self.assertEqual(self.cli("route-classify", "requires-credentials").stdout.strip(), "yes")
        self.assertEqual(self.cli("route-classify", "--labels-json", '["credentials: yes"]',
                                  "--text", "portable fixture").stdout.strip(), "yes")
        self.assertEqual(self.cli("route-classify", "--labels-json", '["credentials: no"]',
                                  "--text", "portable fixture").stdout.strip(), "no")
        self.assertEqual(self.cli("route-classify", "--labels-json", '["credentials: no"]',
                                  "--text", "uses api_key").stdout.strip(), "yes")
        self.assertEqual(self.cli("route-classify", "No credentials. fixture only").stdout.strip(), "no")
        missing = self.cli("route-classify", check=False)
        self.assertEqual(missing.returncode, 2)
        self.assertTrue(missing.stdout.startswith("WAIT\t"))


if __name__ == "__main__":
    unittest.main()
