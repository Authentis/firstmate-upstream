#!/usr/bin/env python3
"""Offline contract tests for the installed v3.1 planning runner."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

BIN = Path(__file__).resolve().parent
RUNNER = BIN / "fm-planning-runner.sh"


class PlanningRunner(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="planning-runner-")
        self.home = Path(self.temp.name) / "home"
        (self.home / "state").mkdir(parents=True)
        for args in (("init", "-q"), ("config", "user.email", "fixture@example.invalid"),
                     ("config", "user.name", "Fixture")):
            subprocess.run(["git", "-C", str(self.home), *args], check=True, capture_output=True)
        (self.home / "README").write_text("fixture\n")
        subprocess.run(["git", "-C", str(self.home), "add", "README"], check=True, capture_output=True)
        subprocess.run(["git", "-C", str(self.home), "commit", "-qm", "fixture"], check=True, capture_output=True)
        subprocess.run(["git", "-C", str(self.home), "update-ref", "refs/remotes/origin/main", "HEAD"], check=True, capture_output=True)
        self.pi = Path(self.temp.name) / "pi"
        self.pi.write_text("""#!/bin/sh
printf '%s\\n' "$*" > "$PI_ARGS"
if [ -n "${PI_USAGE:-}" ]; then
  while [ "$#" -gt 0 ]; do
    if [ "$1" = --session-dir ]; then mkdir -p "$2"; printf '{"message":{"usage":{"totalTokens":%s}}}\\n' "$PI_USAGE" > "$2/usage.jsonl"; break; fi
    shift
  done
fi
printf '%s' "${PI_OUTPUT:-}"
exit "${PI_EXIT:-0}"
""")
        self.pi.chmod(0o755)
        self.env = dict(os.environ, FM_PLANNING_PI=str(self.pi),
                        FM_PLANNING_FOREGROUND="1", PI_ARGS=str(Path(self.temp.name) / "pi.args"))

    def tearDown(self):
        self.temp.cleanup()

    def invoke(self, *args):
        return subprocess.run([str(RUNNER), *args], text=True, capture_output=True,
                              env=self.env, timeout=10)

    def start_args(self, task="plan-a"):
        request = self.home / "request.json"
        request.write_text('{"rows":["one"],"partition":"A"}\n')
        return ("--start", "--home", str(self.home), "--task", task,
                "--project", str(self.home), "--host", "netcup", "--request", str(request),
                "--max-tokens", "300000", "--result", str(self.home / "result.json"),
                "--incarnation", "inc-1", "--harness", "pi", "--model",
                "openai-codex/gpt-6.1-sol", "--effort", "high")

    def test_capabilities_are_honest_and_name_both_hosts(self):
        p = self.invoke("--capabilities")
        self.assertEqual(p.returncode, 0, p.stderr)
        got = json.loads(p.stdout)
        self.assertEqual(got["v"], 1)
        self.assertFalse(got["hard_token_cap"])
        self.assertEqual(got["hosts"], ["netcup", "bosgame"])
        self.assertEqual(got["budget_enforcement"], "wall-clock+accounting")

    def test_start_reserves_budget_and_calls_pi_with_sol_high(self):
        p = self.invoke(*self.start_args())
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("endpoint=planning-plan-a", p.stdout)
        self.assertIn("--model openai-codex/gpt-6.1-sol", Path(self.env["PI_ARGS"]).read_text())
        self.assertIn("--thinking high", Path(self.env["PI_ARGS"]).read_text())
        self.assertTrue((self.home / "data/plan-a/worktree/.git").exists())
        marker = self.home / "data/plan-a/worktree/.beads/isolated-tracker"
        self.assertEqual(marker.read_text(), str(marker.parent.resolve()) + "\n")
        ledger = json.loads((self.home / "state/planning-runner-v31.json").read_text())
        self.assertEqual(ledger["passes"][0]["reserved_tokens"], 300000)
        self.assertEqual((self.home / "state/plan-a.meta").read_text(), "window=planning-plan-a\n")

    def test_missing_pi_is_reported_by_check_without_starting(self):
        self.env["FM_PLANNING_PI"] = str(Path(self.temp.name) / "missing-pi")
        p = self.invoke("--check", "--home", str(self.home), "--host", "netcup", "--harness", "pi",
                     "--model", "openai-codex/gpt-6.1-sol", "--effort", "high", "--max-tokens", "300000")
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("binary missing", p.stdout)

    def test_fourth_reservation_is_refused_at_daily_cap(self):
        for n in range(3):
            p = self.invoke(*self.start_args(f"plan-{n}"))
            self.assertEqual(p.returncode, 0, p.stderr)
        p = self.invoke(*self.start_args("plan-3"))
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("daily token budget", p.stdout)

    def test_nested_pi_usage_overrun_is_retained_and_blocks_the_next_pass(self):
        self.env["PI_USAGE"] = "400001"
        p = self.invoke(*self.start_args("overrun"))
        self.assertEqual(p.returncode, 0, p.stderr)
        ledger = json.loads((self.home / "state/planning-runner-v31.json").read_text())
        self.assertEqual(ledger["passes"][0]["actual_tokens"], 400001)
        self.assertTrue(ledger["passes"][0]["overrun"])
        self.assertIn("pass token budget exceeded", (self.home / "state/planning-blocked.alert").read_text())
        p = self.invoke("--check", "--home", str(self.home), "--host", "netcup", "--harness", "pi",
                        "--model", "openai-codex/gpt-6.1-sol", "--effort", "high", "--max-tokens", "300000")
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("pass token budget exceeded", p.stdout)

    def test_muse_never_executes_locally_and_uses_ssh(self):
        ssh = Path(self.temp.name) / "ssh"
        ssh.write_text("#!/bin/sh\nprintf '%s\\n' \"$*\" > \"$SSH_ARGS\"\n")
        ssh.chmod(0o755)
        self.env["FM_PLANNING_SSH"] = str(ssh)
        self.env["SSH_ARGS"] = str(Path(self.temp.name) / "ssh.args")
        args = list(self.start_args("muse-plan")); args[args.index("netcup")] = "bosgame"
        args[args.index("pi")] = "muse"; args[args.index("openai-codex/gpt-6.1-sol")] = "muse-wonder"
        p = self.invoke(*args)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("bosgame", Path(self.env["SSH_ARGS"]).read_text())
        self.assertIn("BatchMode=yes", Path(self.env["SSH_ARGS"]).read_text())
        self.assertFalse(Path(self.env["PI_ARGS"]).exists())

    def test_quota_exit_writes_definitive_failure_marker(self):
        self.env["PI_EXIT"] = "1"; self.env["PI_OUTPUT"] = "quota exhausted"
        p = self.invoke(*self.start_args("quota"))
        self.assertEqual(p.returncode, 0, p.stderr)
        failure = json.loads((self.home / "data/quota/planning-failure.json").read_text())
        self.assertTrue(failure["definitive"])
        self.assertEqual(failure["reason"], "quota stop")

    def test_ssh_255_is_ambiguous_not_a_definitive_muse_failure(self):
        ssh = Path(self.temp.name) / "ssh-255"
        ssh.write_text("#!/bin/sh\nexit 255\n"); ssh.chmod(0o755)
        self.env["FM_PLANNING_SSH"] = str(ssh)
        args = list(self.start_args("muse-ambiguous")); args[args.index("netcup")] = "bosgame"
        args[args.index("pi")] = "muse"; args[args.index("openai-codex/gpt-6.1-sol")] = "muse-wonder"
        p = self.invoke(*args)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertFalse((self.home / "data/muse-ambiguous/planning-failure.json").exists())
        self.assertIn("transport ambiguous", (self.home / "data/muse-ambiguous/planning-blocked.json").read_text())

    def test_k3_uses_the_offline_provider_registry_alias(self):
        registry = Path(self.temp.name) / "models.json"
        registry.write_text(json.dumps({"kimi-coding": {"models": [{"id": "k3"}]}}))
        self.env["FM_PLANNING_MODEL_REGISTRY"] = str(registry)
        args = list(self.start_args("k3")); args[args.index("openai-codex/gpt-6.1-sol")] = "kimi-code/k3"
        p = self.invoke(*args)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("--model kimi-coding/k3", Path(self.env["PI_ARGS"]).read_text())


if __name__ == "__main__":
    unittest.main()
