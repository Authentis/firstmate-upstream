#!/usr/bin/env python3
"""Regression tests for the v3.1 remote-delivery admission seam.

These are source-contract tests: exercising the full refill entrypoint would use
networked tracker and host probes.  They prove the guard runs before admission
or sender state can be created, and that an admitted router id cannot fall into
the legacy launch ladder.
"""
import os
import pathlib
import subprocess
import tempfile
import unittest


BIN = pathlib.Path("/tmp/claude-1000/router-build/data/bin")
LEAF = (BIN / "bosgame-leaf-send.sh").read_text()
PICKUP = (BIN / "cloud-pickup-send.sh").read_text()
REFILL = (BIN / "lane-refill-v2.sh").read_text()
RETAINED = BIN.parent.parent / ".router-v31-testing"


def shell_function(source, name):
    start = source.index(name + "() {")
    lines = source[start:].splitlines(True)
    depth = 0
    kept = []
    for line in lines:
        kept.append(line)
        depth += line.count("{") - line.count("}")
        if depth == 0:
            return "".join(kept)
    raise AssertionError("unterminated function " + name)


def run_extracted(body):
    """Run a production block in a retained fixture with all actions stubbed."""
    RETAINED.mkdir(exist_ok=True)
    root = pathlib.Path(tempfile.mkdtemp(prefix="delivery-", dir=RETAINED))
    script = root / "case.sh"
    script.write_text(body)
    script.chmod(0o755)
    return root, subprocess.run(["bash", str(script)], text=True,
                                capture_output=True, timeout=10,
                                env=dict(os.environ, FIXTURE=str(root)))


class RemoteDeliveryContractTests(unittest.TestCase):
    def test_leaf_and_pickup_acknowledgments_are_anchored_and_receipt_free(self):
        for text in (LEAF, PICKUP):
            self.assertIn("^(replied|sent)", text)
            self.assertNotIn("bosgame_receiver_receipts_ready", text)
            self.assertNotIn("reconcile-required.txt", text)
            self.assertNotIn("acceptance disabled pending owner receipt grammar", text)

    def test_caller_requires_the_senders_anchored_ack_not_just_exit_zero(self):
        leaves = REFILL[REFILL.index("if [ \"$host\" = bosgame ]"):REFILL.index("# v6:")]
        self.assertIn("grep -qE '^(replied|sent)'", leaves)
        self.assertLess(leaves.index("grep -qE '^(replied|sent)'"), leaves.index("BOSGAME SEND DELIVERED"))

    def test_bosgame_admission_reaches_sender_without_receipt_gate(self):
        leaves = REFILL[REFILL.index("if [ \"$host\" = bosgame ]"):REFILL.index("# v6:")]
        self.assertIn("route_leaf bosgame", leaves)
        self.assertNotIn("receiver receipt grammar", leaves)
        self.assertIn("BOSGAME SEND DELIVERED", leaves)

    def test_empty_router_argv_cancels_before_legacy_id_is_computed(self):
        leaves = REFILL[REFILL.index("ldate=$(date +%m%d); id=$(leaf_task_id \"$suf\" router"):
                       REFILL.index("# codemode smoke test")]
        self.assertIn('router_cancel "$id"', leaves)
        self.assertLess(leaves.index('router_cancel "$id"'),
                        leaves.index('id=$(leaf_task_id "$suf" "$tag"'))

    def test_extracted_empty_argv_cancels_the_admitted_router_id(self):
        start = REFILL.index('ldate=$(date +%m%d); id=$(leaf_task_id "$suf" router')
        end = REFILL.index('  if [ "$islive" = yes ]', start)
        admission = REFILL[start:end]
        leaf_id = shell_function(REFILL, "leaf_task_id")
        root, result = run_extracted("""#!/usr/bin/env bash
set -u
suf=1.2.3
islive=no
ROUTE_ARGS=
ROUTE_PICK=bare-model
route_leaf() { echo "$1:$2" >> "$FIXTURE/admissions"; return 0; }
router_cancel() { printf '%s\\n' "$1" >> "$FIXTURE/cancels"; }
say() { :; }
dlog() { :; }
""" + leaf_id + "\n" + "printf 'x\\n' | while read -r ignored; do\n" + admission + "\ndone\n",
                                             )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        admitted = (root / "admissions").read_text().strip().split(":", 1)[1]
        cancelled = (root / "cancels").read_text().strip()
        self.assertEqual(admitted, cancelled)
        self.assertIn("-router-", cancelled)


if __name__ == "__main__":
    unittest.main()
