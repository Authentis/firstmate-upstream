#!/usr/bin/env python3
"""Offline integration tests for Router v3.1 direct cloud launchers."""
import json
import fcntl
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest

import yaml


ROOT = pathlib.Path("/tmp/claude-1000/router-build")
BIN = ROOT / "data/bin"


class CloudFixture:
    def __init__(self):
        self.root = pathlib.Path(tempfile.mkdtemp(prefix="router-v31-cloud-", dir=str(ROOT / ".router-v31-testing")))
        self.home = self.root / "home"
        self.bin = self.home / "data/bin"
        self.work = self.root / "work"
        self.project = self.root / "project"
        self.stub = self.root / "stub"
        for path in (self.bin, self.work, self.project, self.stub, self.home / "state"):
            path.mkdir(parents=True, exist_ok=True)
        for name in ("cloud-launch.sh", "cloud-refill.sh", "cloud-pickup-netcup.sh"):
            shutil.copy2(BIN / name, self.bin / name)
        (self.home / "data/cloud-workers.tsv").write_text("")
        (self.home / "data/cloud-balance.readings").write_text("1890000000 200 fixture\n")
        (self.work / "candidates.json").write_text(json.dumps([
            {"id": "dos-product-v1-88cgo.20.1", "body": "fixture-only parser change", "labels": ["free-ok"], "overlap": False, "netcup_only": False},
            {"id": "dos-product-v1-88cgo.20.2", "body": "second fixture-only change", "labels": ["free-ok"], "overlap": False, "netcup_only": False},
        ]))
        self._write_stubs()

    def _write(self, path, text, executable=False):
        path.write_text(text)
        if executable:
            path.chmod(0o755)

    def _write_stubs(self):
        self._write(self.bin / "router-launch.sh", r'''#!/usr/bin/env bash
router_global_off(){ if [ -e "$FM_HOME/data/router-off" ]; then echo router-off; return 0; fi; return 1; }
router_prelaunch(){ if [ -e "$FM_HOME/data/router-off" ] || [ -e "$FM_HOME/prelaunch-deny" ] || [ "${STUB_PRELAUNCH_DENY:-0}" = 1 ]; then echo router-off; return 75; fi; return 0; }
router_classify_task(){ case "$*" in *credential*|*token*) printf yes;; *) printf no;; esac; }
router_admit(){
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" >> "$FM_HOME/admit.log"
  n=$(wc -l < "$FM_HOME/admit.log")
  if [ "${STUB_REFUSE_LIVE:-0}" = 1 ] && [ "$5" = yes ]; then return 75; fi
  if [ "${STUB_ADMIT_WAIT_AFTER:-0}" -gt 0 ] && [ "$n" -gt "$STUB_ADMIT_WAIT_AFTER" ]; then return 75; fi
  RA_BINDING=${STUB_BINDING:-sonnet-cloud@claude}; RA_REASON=fixture; RA_HARNESS=${STUB_HARNESS:-claude}
  RA_MODEL=${STUB_MODEL:-claude-sonnet-5-5}; RA_PROVIDER=${STUB_PROVIDER:-anthropic}; RA_EFFORT=${STUB_EFFORT:-medium}
  RA_INCARNATION="inc-$n"; RA_EXHAUSTED_JSON='[]'; RA_ARGV=(claude --model "$RA_MODEL" --effort "$RA_EFFORT")
  return 0
}
router_confirm(){ printf 'confirm\t%s\t%s\t%s\n' "$1" "$RA_INCARNATION" "$2" >> "$FM_HOME/events.log"; [ "${STUB_CONFIRM_FAIL:-0}" != 1 ]; }
router_ambiguous(){ printf 'ambiguous\t%s\t%s\t%s\n' "$1" "$RA_INCARNATION" "$2" >> "$FM_HOME/events.log"; }
router_failure(){ printf 'failure\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$FM_HOME/events.log"; }
router_cancel(){ printf 'cancel\t%s\t%s\n' "$1" "$2" >> "$FM_HOME/events.log"; }
''', True)
        self._write(self.stub / "start-policy.py", r'''#!/usr/bin/env python3
import os, pathlib, sys, time
ledger = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else None
if sys.argv[1] == "can-start":
    print(f"{os.environ.get('STUB_CAN_START', '2')}\tfixture")
elif sys.argv[1] == "note-start":
    if os.environ.get("STUB_NOTE_START_FAIL") == "1": raise SystemExit(1)
    ledger.parent.mkdir(parents=True, exist_ok=True)
    with ledger.open("a") as f: f.write(str(int(time.time())) + "\n")
else:
    raise SystemExit(2)
''', True)
        self._write(self.bin / "claim-guard.sh", "#!/usr/bin/env bash\nexit ${STUB_CLAIM_FAIL:-0}\n", True)
        self._write(self.bin / "tracker-sync-guard.sh", "#!/usr/bin/env bash\nexit 0\n", True)
        self._write(self.stub / "claude-fixture", r'''#!/usr/bin/env bash
printf 'call\n' >> "$FM_HOME/claude-calls.log"
printf '%s\n' "$*" >> "$FM_HOME/claude.log"
printf '%s\n' "${FAKE_CLAUDE_OUTPUT:-session_FIXTURE123}"
exit "${FAKE_CLAUDE_RC:-0}"
''', True)
        self._write(self.stub / "br", r'''#!/usr/bin/env bash
case "$1" in
  ready) printf '[{"id":"dos-product-v1-88cgo.20.1","labels":["free-ok"]},{"id":"dos-product-v1-88cgo.20.2","labels":["free-ok"]}]\n';;
  show) printf '[● P2 · OPEN] fixture\nLabels: free-ok\n\nfixture-only parser change\nDependencies:\n';;
esac
exit 0
''', True)
        self._write(self.stub / "git", "#!/usr/bin/env bash\ncase \"$*\" in *branch\\ --show-current*) echo main;; *rev-parse*) echo same;; esac\nexit 0\n", True)
        self._write(self.stub / "gh", "#!/usr/bin/env bash\nexit 0\n", True)

    def env(self, **extra):
        env = os.environ.copy()
        env.update({
            "FM_HOME": str(self.home), "ROUTER_BIN": str(self.bin),
            "ROUTER_WORKDIR": str(self.work), "ROUTER_PROJECT_DIR": str(self.project),
            "ROUTER_CANDIDATES": str(self.work / "candidates.json"),
            "ROUTER_SPEND_LOG": str(self.home / "data/cloud-spend.md"),
            "ROUTER_CLOUD_COMMAND": str(self.stub / "claude-fixture"),
            "ROUTER_START_POLICY": str(self.stub / "start-policy.py"),
            "ROUTER_SKIP_CLOUD_MAINTENANCE": "1", "PATH": str(self.stub) + os.pathsep + env["PATH"],
            "CLOUD_TARGET": "1", "ROUTER_LIVE": "1",
        })
        env.update({key: str(value) for key, value in extra.items()})
        return env

    def run(self, name, *args, **extra):
        return subprocess.run(["bash", str(self.bin / name), *args], env=self.env(**extra),
                              text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=20)

    def ledger(self):
        return (self.home / "data/cloud-workers.tsv").read_text()

    def enable_real_seam(self):
        for name in ("router-launch.sh", "refill_lib_v2.py", "router_state_v31.py"):
            shutil.copy2(BIN / name, self.bin / name)
        (self.home / "config").mkdir(parents=True, exist_ok=True)
        fleet = {
            "models": {
                "cloud-claude": {"id": "claude-sonnet-5-5", "family": "claude", "billing": "flat"},
            },
            "bindings": {
                "cloud-claude@claude": {"model": "cloud-claude", "provider": "anthropic",
                                         "harness": "claude", "cloud_capable": True},
            },
            "roles": {"cloud": {"models": ["cloud-claude@claude"]}},
            "pools": {"cloud-claude@claude": {"period_days": 7, "scarce": False}},
            "bans": [],
            "catalogs": {"netcup": {"path": "state/catalog-netcup.json", "max_age_seconds": 86400}},
            "routing_state": {"bench": "state/route-bench.json", "cloud_simultaneous_max": 5,
                              "claude_cloud_per_day": 3, "cloud_claude_exception": True},
        }
        (self.home / "config/fleet.yaml").write_text(yaml.safe_dump(fleet))
        (self.home / "state/quota.json").write_text(json.dumps({
            "pools": {"cloud-claude@claude": {"used_pct": 0, "reset_at": 2_000_604_800,
                                                  "observed_at": 2_000_000_000,
                                                  "source": "fixture", "manual": False}}
        }))
        (self.home / "state/catalog-netcup.json").write_text(json.dumps({
            "host": "netcup", "observed_at": 2_000_000_000,
            "models": {"anthropic/claude-sonnet-5-5": {"cost": {"input": 1, "output": 1}}},
        }))


class CloudLaunchTests(unittest.TestCase):
    def setUp(self):
        self.f = CloudFixture()

    def test_global_off_blocks_every_owned_entrypoint_before_writes(self):
        (self.f.home / "data/router-off").write_text("paused\n")
        before = self.f.ledger()
        for script, args in (("cloud-launch.sh", ()), ("cloud-refill.sh", ()),
                             ("cloud-pickup-netcup.sh", ("20.1", "claude/topic", "--dry-run"))):
            result = self.f.run(script, *args)
            self.assertEqual(result.returncode, 0, result.stdout)
            self.assertIn("router-off", result.stdout)
        self.assertEqual(self.f.ledger(), before)
        self.assertFalse((self.f.home / "admit.log").exists())

    def test_dry_runs_are_read_only_and_do_not_admit_or_invoke_claude(self):
        before = {p.relative_to(self.f.home): p.read_bytes() for p in self.f.home.rglob("*") if p.is_file()}
        for script in ("cloud-launch.sh", "cloud-refill.sh"):
            result = self.f.run(script, "--dry-run")
            self.assertEqual(result.returncode, 0, result.stdout)
            self.assertIn("would launch", result.stdout)
        after = {p.relative_to(self.f.home): p.read_bytes() for p in self.f.home.rglob("*") if p.is_file()}
        self.assertEqual(before, after)
        self.assertFalse((self.f.home / "claude.log").exists())

    def test_cloud_launch_admits_actual_text_uses_native_claude_and_confirms_before_ledger(self):
        result = self.f.run("cloud-launch.sh")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertRegex(self.f.ledger(), r"20\.2\tsession_FIXTURE123\trunning")
        self.assertIn("confirm\tdos-product-v1-88cgo.20.2\tinc-1\tsession_FIXTURE123", (self.f.home / "events.log").read_text())
        argv = (self.f.home / "claude.log").read_text()
        self.assertIn("--model claude-sonnet-5-5", argv)
        self.assertIn("--cloud", argv)
        self.assertNotIn("anthropic/claude", argv)
        self.assertIn("\tno\n", (self.f.home / "admit.log").read_text())

    def test_credentials_are_classified_from_body_and_refusal_never_launches(self):
        candidates = json.loads((self.f.work / "candidates.json").read_text())
        candidates[-1]["body"] = "read the credential token"
        (self.f.work / "candidates.json").write_text(json.dumps(candidates))
        result = self.f.run("cloud-launch.sh", STUB_REFUSE_LIVE=1)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("\tyes\n", (self.f.home / "admit.log").read_text())
        self.assertFalse((self.f.home / "claude.log").exists())
        self.assertEqual(self.f.ledger(), "")

    def test_credentials_are_classified_from_actual_labels(self):
        candidates = json.loads((self.f.work / "candidates.json").read_text())
        candidates[-1]["labels"] = ["free-ok", "credentials:yes"]
        (self.f.work / "candidates.json").write_text(json.dumps(candidates))
        result = self.f.run("cloud-launch.sh", STUB_REFUSE_LIVE=1)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("\tyes\n", (self.f.home / "admit.log").read_text())
        self.assertFalse((self.f.home / "claude.log").exists())

    def test_missing_task_text_waits_without_admission(self):
        candidates = json.loads((self.f.work / "candidates.json").read_text())
        candidates[-1]["body"] = ""
        (self.f.work / "candidates.json").write_text(json.dumps(candidates))
        result = self.f.run("cloud-launch.sh")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("malformed task text", result.stdout)
        self.assertFalse((self.f.home / "admit.log").exists())
        self.assertFalse((self.f.home / "claude.log").exists())

    def test_incompatible_admitted_tuple_is_cancelled_without_launch(self):
        result = self.f.run("cloud-launch.sh", STUB_HARNESS="kimi", STUB_MODEL="kimi-k2.7-code")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("incompatible", result.stdout)
        self.assertIn("cancel", (self.f.home / "events.log").read_text())
        self.assertFalse((self.f.home / "claude.log").exists())

    def test_router_off_race_is_rechecked_after_admission_before_launch(self):
        result = self.f.run("cloud-launch.sh", STUB_PRELAUNCH_DENY=1)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("router-off before launch", result.stdout)
        self.assertTrue((self.f.home / "admit.log").exists())
        self.assertIn("cancel", (self.f.home / "events.log").read_text())
        self.assertFalse((self.f.home / "claude.log").exists())
        self.assertEqual(self.f.ledger(), "")

    def test_router_live_zero_still_requires_admission_and_confirmed_receipt(self):
        result = self.f.run("cloud-launch.sh", ROUTER_LIVE=0)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("launched", result.stdout)
        self.assertIn("\tcloud\tcloud\tnetcup\tno", (self.f.home / "admit.log").read_text())
        self.assertIn("confirm\tdos-product-v1-88cgo.20.2\tinc-1\tsession_FIXTURE123",
                      (self.f.home / "events.log").read_text())
        self.assertIn("session_FIXTURE123", self.f.ledger())

    def test_no_session_is_ambiguous_and_creates_no_ledger_row(self):
        result = self.f.run("cloud-launch.sh", FAKE_CLAUDE_OUTPUT="launch failed")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("launch failed", result.stdout)
        events = (self.f.home / "events.log").read_text()
        self.assertIn("ambiguous", events)
        self.assertNotIn("failure", events)
        self.assertEqual(self.f.ledger(), "")

    def test_session_receipt_requires_one_anchored_native_output_line(self):
        for output in ("started session_FAKE in background", "session_ONE\nsession_TWO"):
            with self.subTest(output=output):
                f = CloudFixture()
                result = f.run("cloud-launch.sh", FAKE_CLAUDE_OUTPUT=output)
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertIn("launch failed", result.stdout)
                self.assertIn("ambiguous", (f.home / "events.log").read_text())
                self.assertEqual(f.ledger(), "")
                self.assertFalse((f.home / "data/cloud-spend.md").exists())

    def test_explicit_funds_refusal_uses_failure_bench_not_ambiguous(self):
        result = self.f.run("cloud-launch.sh", FAKE_CLAUDE_OUTPUT="402 insufficient balance",
                            FAKE_CLAUDE_RC=1)
        self.assertEqual(result.returncode, 0, result.stdout)
        events = (self.f.home / "events.log").read_text()
        self.assertIn("failure", events)
        self.assertNotIn("ambiguous", events)

    def test_plain_synchronous_nonzero_without_session_reports_failure(self):
        result = self.f.run("cloud-launch.sh", FAKE_CLAUDE_OUTPUT="request rejected", FAKE_CLAUDE_RC=1)
        self.assertEqual(result.returncode, 0, result.stdout)
        events = (self.f.home / "events.log").read_text()
        self.assertIn("failure", events)
        self.assertNotIn("ambiguous", events)

    def test_uncertain_nonzero_exit_keeps_ambiguous_reservation(self):
        for output in ("session_MAYBELIVE", "transport interrupted"):
            with self.subTest(output=output):
                f = CloudFixture()
                result = f.run("cloud-launch.sh", FAKE_CLAUDE_OUTPUT=output, FAKE_CLAUDE_RC=124)
                self.assertEqual(result.returncode, 0, result.stdout)
                events = (f.home / "events.log").read_text()
                self.assertIn("ambiguous", events)
                self.assertNotIn("failure", events)
                self.assertEqual(f.ledger(), "")

    def test_confirmation_failure_stops_multi_launch_without_accounting(self):
        result = self.f.run("cloud-launch.sh", CLOUD_TARGET=2, STUB_CONFIRM_FAIL=1)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("accounting failed", result.stdout)
        self.assertEqual(len((self.f.home / "claude-calls.log").read_text().splitlines()), 1)
        self.assertEqual(self.f.ledger(), "")
        self.assertFalse((self.f.home / "data/cloud-spend.md").exists())
        events = (self.f.home / "events.log").read_text()
        self.assertIn("ambiguous\tdos-product-v1-88cgo.20.2\tinc-1\tsession_FIXTURE123", events)
        self.assertNotIn("cancel", events)

    def test_fresh_start_gate_blocks_launch_and_releases_reservation(self):
        result = self.f.run("cloud-launch.sh", STUB_CAN_START=0)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("start gate", result.stdout)
        self.assertFalse((self.f.home / "claude.log").exists())
        self.assertEqual(self.f.ledger(), "")
        self.assertIn("cancel", (self.f.home / "events.log").read_text())

    def test_start_accounting_failure_stops_after_confirm_without_legacy_ledger(self):
        result = self.f.run("cloud-launch.sh", CLOUD_TARGET=2, STUB_NOTE_START_FAIL=1)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("start accounting failed", result.stdout)
        self.assertEqual(len((self.f.home / "claude-calls.log").read_text().splitlines()), 1)
        self.assertIn("confirm", (self.f.home / "events.log").read_text())
        self.assertEqual(self.f.ledger(), "")
        self.assertFalse((self.f.home / "data/cloud-spend.md").exists())

    def test_admission_budget_wait_stops_multi_launch_immediately(self):
        result = self.f.run("cloud-launch.sh", CLOUD_TARGET=2, STUB_ADMIT_WAIT_AFTER=1)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(len((self.f.home / "claude-calls.log").read_text().splitlines()), 1)
        self.assertEqual(len((self.f.home / "admit.log").read_text().splitlines()), 2)
        self.assertEqual(len(self.f.ledger().splitlines()), 1)

    def test_hold_and_capacity_refusal_do_not_admit(self):
        (self.f.home / "data/cloud-launch.hold").write_text("hold\n")
        self.assertEqual(self.f.run("cloud-launch.sh").returncode, 0)
        self.assertFalse((self.f.home / "admit.log").exists())
        (self.f.home / "data/cloud-launch.hold").rename(self.f.home / "data/cloud-launch.hold.bak-test")
        rows = "".join(f"189000000{i}\tt{i}\tsession_{i}\trunning\n" for i in range(5))
        (self.f.home / "data/cloud-workers.tsv").write_text(rows)
        self.assertEqual(self.f.run("cloud-launch.sh", CLOUD_TARGET=5).returncode, 0)
        self.assertFalse((self.f.home / "admit.log").exists())

    def test_both_cloud_helpers_share_one_ledger_lock(self):
        lock_path = self.f.home / "data/cloud-workers.tsv.lock"
        with lock_path.open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            for script in ("cloud-launch.sh", "cloud-refill.sh"):
                result = self.f.run(script)
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertIn("another", result.stdout)
        self.assertFalse((self.f.home / "admit.log").exists())
        self.assertFalse((self.f.home / "claude.log").exists())

    def test_cloud_refill_has_its_own_admission_launch_confirmation_path(self):
        result = self.f.run("cloud-refill.sh")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("cloud-refill: launched", result.stdout)
        self.assertIn("\tcloud\tcloud\tnetcup\tno", (self.f.home / "admit.log").read_text())
        self.assertIn("--model claude-sonnet-5-5", (self.f.home / "claude.log").read_text())
        self.assertIn("running", self.f.ledger())

    def test_cloud_refill_router_live_zero_still_requires_admission_and_confirmed_receipt(self):
        result = self.f.run("cloud-refill.sh", ROUTER_LIVE=0)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("cloud-refill: launched", result.stdout)
        self.assertIn("\tcloud\tcloud\tnetcup\tno", (self.f.home / "admit.log").read_text())
        self.assertIn("confirm\tdos-product-v1-88cgo.20.1\tinc-1\tsession_FIXTURE123",
                      (self.f.home / "events.log").read_text())
        self.assertIn("session_FIXTURE123", self.f.ledger())

    def test_cloud_refill_preserves_ambiguous_session_on_confirm_failure(self):
        result = self.f.run("cloud-refill.sh", STUB_CONFIRM_FAIL=1)
        self.assertEqual(result.returncode, 0, result.stdout)
        events = (self.f.home / "events.log").read_text()
        self.assertIn("ambiguous", events)
        self.assertNotIn("cancel", events)
        self.assertEqual(self.f.ledger(), "")

    def test_cloud_launch_uses_real_router_seam_and_state_receipt(self):
        self.f.enable_real_seam()
        result = self.f.run("cloud-launch.sh", ROUTE_NOW=2_000_000_000)
        self.assertEqual(result.returncode, 0, result.stdout)
        receipts = self.f.home / "state/route-launches/receipts.jsonl"
        self.assertTrue(receipts.exists(), result.stdout)
        rows = [json.loads(line) for line in receipts.read_text().splitlines()]
        self.assertEqual(len(rows), 1)
        self.assertEqual((rows[0]["task"], rows[0]["session"], rows[0]["binding"]),
                         ("dos-product-v1-88cgo.20.2", "session_FIXTURE123", "cloud-claude@claude"))
        sidecar = json.loads((self.f.home / "state/route-launches/dos-product-v1-88cgo.20.2.json").read_text())
        self.assertEqual((sidecar["state"], sidecar["pending"]), ("confirmed", False))
        self.assertIn("session_FIXTURE123", self.f.ledger())

    def test_real_state_keeps_unverified_zero_exit_as_pending_ambiguous(self):
        self.f.enable_real_seam()
        result = self.f.run("cloud-launch.sh", ROUTE_NOW=2_000_000_000,
                            FAKE_CLAUDE_OUTPUT="provider accepted request")
        self.assertEqual(result.returncode, 0, result.stdout)
        sidecar = json.loads((self.f.home / "state/route-launches/dos-product-v1-88cgo.20.2.json").read_text())
        self.assertEqual((sidecar["state"], sidecar["pending"]), ("ambiguous", True))
        self.assertEqual(sidecar["session"], "unverified-" + sidecar["incarnation"])
        self.assertFalse((self.f.home / "state/route-launches/receipts.jsonl").exists())
        self.assertEqual(self.f.ledger(), "")


if __name__ == "__main__":
    unittest.main(verbosity=2)
