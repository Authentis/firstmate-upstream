#!/usr/bin/env python3
"""Regression coverage for label-only credential evidence in v3.1 launch paths."""
import os
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parent
ROUTER = ROOT / "router-launch.sh"
RETAINED = ROOT.parent.parent / ".router-v31-testing"
CALLERS = {
    "closure-sweep": ROOT / "closure-sweep.sh",
    "mkclose-template": ROOT / "mkclose-template.sh",
    "go-slot": ROOT / "go-slot.sh",
}


def source_router_helper(rows):
    """Run only the shared labels extractor from the real production shell."""
    command = (
        "source \"$1\"; router_labels_from_rows \"$2\""
    )
    return subprocess.run(
        ["bash", "-c", command, "labels-test", str(ROUTER), rows],
        text=True,
        capture_output=True,
        env=dict(os.environ, FM_HOME=tempfile.gettempdir()),
        timeout=5,
    )


class LabelEvidence(unittest.TestCase):
    def test_label_only_credentials_are_aggregated_from_each_current_row(self):
        result = source_router_helper(
            '{"id":"leaf-a","title":"portable","labels":["credentials:yes"]}\n'
            '{"id":"leaf-b","title":"portable","labels":[]}\n'
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), '["credentials:yes"]')

    def test_label_only_credentials_reach_the_real_classifier_as_live_data(self):
        rows = '{"id":"leaf-a","title":"portable","labels":["credentials:yes"]}\n'
        result = subprocess.run(
            ["bash", "-c",
             'source "$1"; labels=$(router_labels_from_rows "$2") || exit $?; '
             'router_classify_task "portable fixture" "$labels"',
             "labels-classify", str(ROUTER), rows],
            text=True,
            capture_output=True,
            env=dict(os.environ, FM_HOME=tempfile.gettempdir()),
            timeout=5,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "yes")

    def test_missing_or_malformed_label_evidence_fails_closed(self):
        for rows in (
            '{"id":"leaf-a","title":"portable"}\n',
            '{"id":"leaf-a","labels":"credentials:yes"}\n',
            'not-json\n',
        ):
            with self.subTest(rows=rows):
                result = source_router_helper(rows)
                self.assertNotEqual(result.returncode, 0)

    def test_go_slot_missing_labels_waits_before_reserving_or_launching(self):
        RETAINED.mkdir(exist_ok=True)
        root = pathlib.Path(tempfile.mkdtemp(prefix="labels-go-", dir=RETAINED))
        home = root / "fm-home"
        project = root / "project"
        (home / "data").mkdir(parents=True)
        (home / "state").mkdir()
        tracker = project / ".beads" / "issues.jsonl"
        tracker.parent.mkdir(parents=True)
        tracker.write_text('{"id":"leaf-a","title":"portable task"}\n')
        result = subprocess.run(
            ["bash", str(CALLERS["go-slot"]), "spawn", "leaf-a", "/fixture"],
            text=True,
            capture_output=True,
            env=dict(os.environ, FM_HOME=str(home), ROUTER_BIN=str(ROOT),
                     ROUTER_PROJECT_DIR=str(project), ROUTER_LIVE="1"),
            timeout=8,
        )
        self.assertEqual(result.returncode, 4, result.stdout + result.stderr)
        self.assertIn("WAIT: current tracker labels unavailable or malformed", result.stderr)
        self.assertFalse((home / "data" / "go-slot.res" / "leaf-a").exists())

    def test_all_live_callers_wait_before_admission_or_launch_when_labels_unknown(self):
        for name, path in CALLERS.items():
            text = path.read_text()
            with self.subTest(caller=name):
                self.assertIn('router_labels_from_rows', text)
                self.assertNotIn('router_classify_task "$rows" "[]"', text)
                self.assertNotIn('router_classify_task "$task_text" "[]"', text)
                labels_at = text.index('router_labels_from_rows')
                classify_at = text.index('router_classify_task', labels_at)
                self.assertLess(labels_at, classify_at)
                wait_at = text.rfind('WAIT:', 0, classify_at)
                self.assertNotEqual(wait_at, -1)
                for side_effect in ('router_admit', '"$H/bin/fm-spawn.sh"', '"$H/bin/fm-control.sh"'):
                    pos = text.find(side_effect)
                    if pos != -1:
                        self.assertLess(classify_at, pos)


if __name__ == "__main__":
    unittest.main(verbosity=2)
