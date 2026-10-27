#!/usr/bin/env python3
"""Regression coverage for planner ids accidentally queued as DeepSeek builds."""
import os
import subprocess
import tempfile
import unittest


ROOT = os.path.dirname(__file__)
LANE = os.path.join(ROOT, "lane-refill-v2.sh")
with open(LANE) as source_file:
    SOURCE = source_file.read()


def start_first_loop():
    begin = SOURCE.index("# 3-pre0.")
    end = SOURCE.index("# 3-pre. SO-16 resume", begin)
    text = SOURCE[begin:end]
    return text[text.index("for pid in "):]


class LegacyPlannerStartFirstGuards(unittest.TestCase):
    def run_case(self, task_id, live):
        test_root = os.path.join(os.path.dirname(ROOT), ".router-v31-testing")
        os.makedirs(test_root, exist_ok=True)
        fixture = tempfile.mkdtemp(prefix="legacy-planner-", dir=test_root)
        os.makedirs(os.path.join(fixture, "data", task_id))
        os.makedirs(os.path.join(fixture, "state"))
        with open(os.path.join(fixture, "data", "ds-start-first"), "w") as queue:
            queue.write(task_id + "\n")
        with open(os.path.join(fixture, "data", task_id, "brief.md"), "w") as brief:
            brief.write("planner pass\n")
        script = os.path.join(fixture, "case.sh")
        body = r'''set -u
H=$FIXTURE; PROJECT=/project; NM='--mode no-mistakes'; DRY=0
ROUTER_LIVE=$LIVE_CASE; nds=0; DS_CAP=4; sn=1; free=1; spawned=0
say() { printf '%s\n' "$*" >> "$FIXTURE/events"; }
fresh_gate() { :; }
task_live_data() { printf 'no\n'; }
ds_route() { printf 'deepseek\n' >> "$FIXTURE/admit.log"; nxt=deepseek; RX=(--bad); EFF=high; }
route_leaf() { printf 'router %s\n' "$*" >> "$FIXTURE/admit.log"; ROUTE_PICK=bad; }
spawn_retry() { printf 'spawn %s\n' "$*" >> "$FIXTURE/spawn.log"; }
spawn_routed() { printf 'spawn %s\n' "$*" >> "$FIXTURE/spawn.log"; }
one_start() { printf 'count\n' >> "$FIXTURE/spawn.log"; }
''' + start_first_loop()
        with open(script, "w") as script_file:
            script_file.write(body)
        result = subprocess.run(["bash", script], text=True, capture_output=True,
                                env=dict(os.environ, FIXTURE=fixture, LIVE_CASE=live))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(os.path.exists(os.path.join(fixture, "admit.log")))
        self.assertFalse(os.path.exists(os.path.join(fixture, "spawn.log")))
        with open(os.path.join(fixture, "data", "ds-start-first")) as queue:
            self.assertEqual(queue.read(), task_id + "\n")

    def test_planning_and_repoint_start_first_never_admit_or_spawn(self):
        for task_id in ("dos-planning-c1", "dos-repoint-split-c2"):
            for live in ("0", "1"):
                with self.subTest(task_id=task_id, live=live):
                    self.run_case(task_id, live)


if __name__ == "__main__":
    unittest.main()
