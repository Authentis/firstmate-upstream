#!/usr/bin/env python3
"""Offline contract tests for the Router v3.1 sourceable launch seam."""
import json
import os
import pathlib
import subprocess
import time
import unittest
import uuid


ROOT = pathlib.Path("/tmp/claude-1000/router-build")
SEAM = ROOT / "data/bin/router-launch.sh"
REVIEWER = ROOT / "data/bin/route-reviewer.sh"
TEST_ROOT = ROOT / ".router-v31-testing/seam-cases"


class LaunchSeamTests(unittest.TestCase):
    def setUp(self):
        self.case = TEST_ROOT / uuid.uuid4().hex
        self.home = self.case / "home"
        self.bin = self.home / "data/bin"
        self.state = self.home / "state"
        self.bin.mkdir(parents=True)
        self.state.mkdir(parents=True)
        self.calls = self.case / "calls.jsonl"
        self.policy = self.case / "policy.py"
        self.policy.write_text(
            """#!/usr/bin/env python3
import json, os, sys
with open(os.environ['CALLS'], 'a') as f:
    f.write(json.dumps(sys.argv[1:]) + '\\n')
cmd = sys.argv[1]
if cmd in ('route-admit', 'route-check'):
    if os.environ.get('REFUSE_LIVE') and sys.argv[6] == 'yes':
        print('WAIT\\t' + os.environ['REFUSE_LIVE'] + ' refuses credentials\\t\\t\\t\\t\\t\\t[]')
        raise SystemExit(0)
    print(os.environ.get('ADMIT_LINE', 'WAIT\\tfixture wait\\t\\t\\t\\t\\t\\t[]'))
    raise SystemExit(int(os.environ.get('POLICY_RC', '0')))
if cmd == 'route-classify':
    text = ' '.join(sys.argv[2:]).lower()
    print('yes' if ('credential' in text and 'no credential' not in text) or 'credentials:yes' in text else 'no')
    raise SystemExit(0)
raise SystemExit(int(os.environ.get('POLICY_RC', '0')))
"""
        )
        self.policy.chmod(0o755)
        self.alive = self.case / "alive"
        self.alive.write_text("#!/usr/bin/env bash\nprintf '%s\\n' \"${ALIVE_RESULT:-alive}\"\n")
        self.alive.chmod(0o755)

    def run_bash(self, body, **extra):
        env = {
            **os.environ,
            "FM_HOME": str(self.home),
            "ROUTER_BIN": str(self.bin),
            "ROUTER_POLICY": str(self.policy),
            "ROUTER_ALIVE_CMD": str(self.alive),
            "CALLS": str(self.calls),
            **extra,
        }
        return subprocess.run(
            ["bash", "-c", f"source {SEAM!s}\n{body}"],
            text=True, capture_output=True, env=env,
        )

    def calls_read(self):
        if not self.calls.exists():
            return []
        return [json.loads(x) for x in self.calls.read_text().splitlines()]

    def test_admit_parses_exact_tuple_and_builds_pi_argv_without_double_prefix(self):
        line = "sol-plan@pi\teligible\tpi\topenai-codex/gpt-6.1-sol\topenai-codex\thigh\tinc-1\t[]"
        got = self.run_bash(
            "router_admit task-1 plan plan netcup no\n"
            "printf '<%s>\\n' \"$RA_BINDING|$RA_MODEL|$RA_INCARNATION\" \"${RA_ARGV[*]}\"",
            ADMIT_LINE=line,
        )
        self.assertEqual(got.returncode, 0, got.stderr)
        self.assertEqual(got.stdout.splitlines(), [
            "<sol-plan@pi|openai-codex/gpt-6.1-sol|inc-1>",
            "<--harness pi --model openai-codex/gpt-6.1-sol --effort high>",
        ])

    def test_native_claude_model_is_not_provider_prefixed(self):
        line = "opus-plan@claude\tlast resort\tclaude\tclaude-opus-5-5\tanthropic\thigh\tinc-2\t[]"
        got = self.run_bash("router_admit t plan plan netcup no && printf '%s\\n' \"${RA_ARGV[*]}\"", ADMIT_LINE=line)
        self.assertEqual(got.returncode, 0, got.stderr)
        self.assertEqual(got.stdout, "--harness claude --model claude-opus-5-5 --effort high\n")

    def test_pi_and_opencode_prefix_provider_only_for_bare_model(self):
        for harness in ("pi", "opencode", "muse"):
            with self.subTest(harness=harness):
                line = f"b@{harness}\tok\t{harness}\tm\tp\tmedium\tinc\t[]"
                got = self.run_bash("router_admit t build build netcup no && printf '%s\\n' \"${RA_ARGV[*]}\"", ADMIT_LINE=line)
                self.assertEqual(got.returncode, 0, got.stderr)
                expected = "p/m" if harness in ("pi", "opencode") else "m"
                self.assertEqual(got.stdout, f"--harness {harness} --model {expected} --effort medium\n")

    def test_wait_malformed_tuple_unknown_harness_and_unsafe_fields_fail_closed(self):
        cases = [
            "WAIT\tno route\t\t\t\t\t\t[]",
            "too\tfew\tfields",
            "b@weird\tok\tweird\tm\tp\thigh\tinc\t[]",
            "b@pi\tok\tpi\tm\tp\thigh\tbad incarnation\t[]",
            "b@pi\tok\tpi\tm\tp\thigh\tinc\tnot-json",
        ]
        for line in cases:
            with self.subTest(line=line):
                got = self.run_bash("router_admit t build build netcup no", ADMIT_LINE=line)
                self.assertEqual(got.returncode, 75)
                self.assertEqual(got.stdout, "")
                self.assertEqual(self.run_bash(
                    "router_admit t build build netcup no || :; printf '%s|%s\\n' \"$RA_BINDING\" \"${#RA_ARGV[@]}\"",
                    ADMIT_LINE=line,
                ).stdout, "|0\n")
        waited = self.run_bash(
            "router_admit t build build netcup no || printf '%s|%s\\n' \"$RA_REASON\" \"$RA_EXHAUSTED_JSON\"",
            ADMIT_LINE="WAIT\tall candidates benched\t\t\t\t\t\t[{\"binding\":\"b@pi\"}]",
        )
        self.assertEqual(waited.stdout, 'all candidates benched|[{"binding":"b@pi"}]\n')

    def test_policy_refusal_is_catchable_by_set_e_callers(self):
        got = self.run_bash(
            "set -e\n"
            "if router_admit t build build netcup no; then exit 9; fi\n"
            "printf '%s\\n' retained",
            POLICY_RC="2",
        )
        self.assertEqual(got.returncode, 0, got.stderr)
        self.assertEqual(got.stdout, "retained\n")

    def test_admit_and_check_use_closed_positional_cli(self):
        line = "b@pi\tok\tpi\tp/m\tp\thigh\tinc\t[]"
        got = self.run_bash(
            "router_admit task build build netcup yes b@pi\n"
            "router_check task go build netcup yes b@pi",
            ADMIT_LINE=line,
        )
        self.assertEqual(got.returncode, 0, got.stderr)
        self.assertEqual(self.calls_read(), [
            ["route-admit", "task", "build", "build", "netcup", "yes", "b@pi"],
            ["route-check", "task", "go", "build", "netcup", "yes", "b@pi"],
        ])

    def test_global_off_and_prelaunch_recheck(self):
        got = self.run_bash("router_global_off; printf 'rc=%s\\n' $?\nrouter_prelaunch; printf 'pre=%s\\n' $?")
        self.assertEqual(got.stdout, "rc=1\npre=0\n")
        (self.home / "data/router-off").write_text("pause\n")
        got = self.run_bash("router_global_off; printf 'rc=%s\\n' $?\nrouter_prelaunch; printf 'pre=%s\\n' $?")
        self.assertEqual(got.stdout, "router-off\nrc=0\nrouter-off\npre=75\n")

    def test_verified_session_requires_changed_fresh_meta_endpoint_and_alive_probe(self):
        meta = self.state / "task.meta"
        meta.write_text("endpoint_task_id=stale\nwindow=old-window\nworktree=/x\n")
        old = int(time.time()) - 20
        os.utime(meta, (old, old))
        line = "b@pi\tok\tpi\tp/m\tp\thigh\tinc\t[]"
        got = self.run_bash(
            "router_admit task build build netcup no\n"
            "router_verify_session task 'spawned task window=old-window'",
            ADMIT_LINE=line,
        )
        self.assertEqual(got.returncode, 75)

        # endpoint_task_id is synthetic and cannot serve as a verified session.
        got = self.run_bash(
            "router_admit synthetic build build netcup no\n"
            "printf '%s\\n' 'endpoint_task_id=synthetic' > \"$FM_HOME/state/synthetic.meta\"\n"
            "router_verify_session synthetic 'spawned synthetic window=synthetic'",
            ADMIT_LINE=line,
        )
        self.assertEqual(got.returncode, 75)

        # A launch must republish metadata after admission and stdout must name
        # the same real endpoint; a task record alone is not proof.
        got = self.run_bash(
            "router_admit task build build netcup no\n"
            "printf '%s\\n' 'endpoint_task_id=task' 'window=session-2' 'worktree=/x' > \"$FM_HOME/state/task.meta\"\n"
            "router_verify_session task 'spawned task window=session-2 worktree=/x' && printf '%s\\n' \"$RV_SESSION\"",
            ADMIT_LINE=line,
        )
        self.assertEqual(got.returncode, 0, got.stderr)
        self.assertEqual(got.stdout, "session-2\n")

        # fm-crew-state's canonical state row may be wrapped with context by a
        # caller.  Accept exactly one positive state row anywhere in stdout.
        got = self.run_bash(
            "router_admit wrapped build build netcup no\n"
            "printf '%s\\n' 'endpoint_task_id=wrapped' 'window=session-wrapped' > \"$FM_HOME/state/wrapped.meta\"\n"
            "router_verify_session wrapped 'spawned wrapped window=session-wrapped'",
            ADMIT_LINE=line,
            ALIVE_RESULT="Task: wrapped\nProject: /worktree\nstate: working · source: pane · agent process alive",
        )
        self.assertEqual(got.returncode, 0, got.stderr)

        # Multiple state rows are contradictory evidence, even if one is a
        # positive row.  A single non-live row is also not endpoint proof.
        got = self.run_bash(
            "router_admit contradictory build build netcup no\n"
            "printf '%s\\n' 'window=session-contradictory' > \"$FM_HOME/state/contradictory.meta\"\n"
            "router_verify_session contradictory 'spawned contradictory window=session-contradictory'",
            ADMIT_LINE=line,
            ALIVE_RESULT="state: working · source: pane\nstate: unknown · source: none",
        )
        self.assertEqual(got.returncode, 75)
        got = self.run_bash(
            "router_admit unknown build build netcup no\n"
            "printf '%s\\n' 'window=session-unknown' > \"$FM_HOME/state/unknown.meta\"\n"
            "router_verify_session unknown 'spawned unknown window=session-unknown'",
            ADMIT_LINE=line,
            ALIVE_RESULT="Task: unknown\nstate: unknown · source: none · no metadata",
        )
        self.assertEqual(got.returncode, 75)
        got = self.run_bash(
            "router_admit mismatch build build netcup no\n"
            "printf '%s\\n' 'window=session-real' > \"$FM_HOME/state/mismatch.meta\"\n"
            "router_verify_session mismatch 'spawned mismatch window=session-other'",
            ADMIT_LINE=line,
        )
        self.assertEqual(got.returncode, 75)
        got = self.run_bash(
            "router_admit task build build netcup no\n"
            "printf '%s\\n' 'endpoint_task_id=task' 'window=session-3' > \"$FM_HOME/state/task.meta\"\n"
            "router_verify_session task 'spawned task window=session-3'",
            ADMIT_LINE=line, ALIVE_RESULT="dead",
        )
        self.assertEqual(got.returncode, 75)

    def test_confirm_only_after_verification_and_accounting_failure_propagates(self):
        line = "b@pi\tok\tpi\tp/m\tp\thigh\tinc-9\t[]"
        got = self.run_bash(
            "router_admit task build build netcup no\n"
            "printf '%s\\n' endpoint_task_id=task window=session-9 > \"$FM_HOME/state/task.meta\"\n"
            "router_confirm_verified task 'spawned task window=session-9'",
            ADMIT_LINE=line,
        )
        self.assertEqual(got.returncode, 0, got.stderr)
        self.assertEqual(self.calls_read()[-1], ["route-confirm", "task", "inc-9", "session-9"])
        got = self.run_bash(
            "router_admit task2 build build netcup no\n"
            "printf '%s\\n' endpoint_task_id=task2 window=session-x > \"$FM_HOME/state/task2.meta\"\n"
            "router_confirm_verified task2 'spawned task2 window=session-x'",
            ADMIT_LINE=line, POLICY_RC="2",
        )
        self.assertEqual(got.returncode, 75)

    def test_ambiguous_session_is_persisted_against_current_incarnation(self):
        line = "b@pi\tok\tpi\tp/m\tp\thigh\tinc-amb\t[]"
        got = self.run_bash(
            "router_admit task build build netcup no\n"
            "router_ambiguous task session-amb",
            ADMIT_LINE=line,
        )
        self.assertEqual(got.returncode, 0, got.stderr)
        self.assertEqual(self.calls_read()[-1], ["route-ambiguous", "task", "inc-amb", "session-amb"])
        refused = self.run_bash(
            "router_admit task build build netcup no\n"
            "router_ambiguous other 'unsafe session'",
            ADMIT_LINE=line,
        )
        self.assertEqual(refused.returncode, 75)

    def test_failure_cancel_and_classification_are_argument_safe(self):
        line = "b@pi\tok\tpi\tp/m\tp\thigh\tinc-a\t[]"
        got = self.run_bash(
            "router_admit task build build netcup no\n"
            "router_failure task event-a 402 'Insufficient BALANCE; $(touch /bad)'\n"
            "router_cancel task\n"
            "printf '%s,%s,%s,%s\\n' \"$(router_classify_task 'credentials:yes')\" "
            "\"$(router_classify_task 'no credential needed')\" \"$(router_classify_task 'api credential')\" "
            "\"$(router_classify_task 'ordinary task' '[\"credentials:yes\"]')\"",
            ADMIT_LINE=line,
        )
        self.assertEqual(got.returncode, 0, got.stderr)
        self.assertEqual(got.stdout, "yes,no,yes,yes\n")
        self.assertEqual(self.calls_read()[1:3], [
            ["route-failure", "task", "inc-a", "event-a", "402", "Insufficient BALANCE; $(touch /bad)"],
            ["route-cancel", "task", "inc-a"],
        ])

    def test_every_kind_threads_real_credential_classification_to_family_bans(self):
        accepted = "b@pi\tok\tpi\tp/m\tp\thigh\tinc\t[]"
        for family in ("free", "kimi", "stealth"):
            with self.subTest(family=family):
                got = self.run_bash(
                    "for item in 'plan:plan' 'resume:build' 'closure:closure' 'cloud:cloud' "
                    "'go:build' 'priority:build' 'start-first:build' 'build:build'; do\n"
                    "  kind=${item%%:*}; role=${item#*:}\n"
                    "  live=$(router_classify_task 'api credential required' '[]') || exit 91\n"
                    "  if router_admit \"task-$kind\" \"$kind\" \"$role\" netcup \"$live\"; then exit 92; fi\n"
                    "  printf '%s:%s\\n' \"$kind\" \"$RA_REASON\"\n"
                    "done\n"
                    "live=$(router_classify_task 'no credential needed' '[]')\n"
                    "router_admit safe-build build build netcup \"$live\"",
                    ADMIT_LINE=accepted, REFUSE_LIVE=family,
                )
                self.assertEqual(got.returncode, 0, got.stderr)
                lines = got.stdout.splitlines()
                self.assertEqual(len(lines), 8)
                self.assertTrue(all(x.endswith(f"{family} refuses credentials") for x in lines))
                calls = [x for x in self.calls_read() if x[0] == "route-admit"]
                self.assertEqual([x[5] for x in calls[:8]], ["yes"] * 8)
                self.assertEqual(calls[-1][5], "no")

    def test_bundle_variables_are_pinned_once_and_reviewer_honors_off(self):
        defaulted = self.run_bash("printf '%s\\n' \"$ROUTER_BUNDLE_ROOT\"")
        self.assertEqual(defaulted.stdout, f"{self.home}\n")
        got = self.run_bash(
            "printf '%s|%s|%s\\n' \"$ROUTER_BUNDLE_ROOT\" \"$ROUTER_BIN\" \"$FLEET_YAML\"",
            ROUTER_BUNDLE_ROOT=str(self.case / "bundle"),
            FLEET_YAML=str(self.case / "fleet.yaml"),
        )
        self.assertEqual(got.stdout, f"{self.case / 'bundle'}|{self.bin}|{self.case / 'fleet.yaml'}\n")
        text = REVIEWER.read_text()
        self.assertIn("router_global_off && exit 0", text)
        self.assertIn("ROUTER_BIN", text)
        self.assertIn('$ROUTER_BIN/../..', text)
        self.assertNotIn('B=$(cd "$(dirname "$0")"', text)
        (self.home / "data/router-off").write_text("paused\n")
        stopped = subprocess.run(
            ["bash", str(REVIEWER), "codex", "no"], text=True, capture_output=True,
            env={**os.environ, "FM_HOME": str(self.home), "ROUTER_BIN": str(ROOT / "data/bin")},
        )
        self.assertEqual(stopped.returncode, 0, stopped.stderr)
        self.assertEqual(stopped.stdout, "router-off\n")


if __name__ == "__main__":
    unittest.main(verbosity=2)
