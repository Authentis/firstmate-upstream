#!/usr/bin/env python3
"""pass-5 (chief): the bosgame sender applies the router's picked binding.

Fixture-only: bosgame-leaf-send.sh runs against a fake FM home (BOSGAME_LEAF_HOME) with a stubbed
overlap check and a stubbed bosgame-sm-send.sh (a real send is never attempted); binding-lane runs
against a fixture fleet.yaml. No network, no live home paths."""
import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SEND = os.path.join(HERE, "bosgame-leaf-send.sh")
LIB = os.path.join(HERE, "refill_lib_v2.py")
REFILL = os.path.join(HERE, "lane-refill-v2.sh")

FLEET = """
models:
  cat-jam: {family: free, billing: free}
  deep-v41: {family: deepseek, billing: free}
bindings:
  cat-jam@opencode: {model: cat-jam, provider: opencode, harness: opencode, weight: 1}
  cat-jam@north: {model: cat-jam, provider: north, harness: opencode, weight: 1}
  deep-v41@commandcode: {model: deep-v41, provider: commandcode, harness: commandcode, weight: 1, effort: high}
roles:
  build: {free: [cat-jam@opencode, cat-jam@north, deep-v41@commandcode]}
pools:
  cat-jam@opencode: {period_days: 1, scarce: false}
  cat-jam@north: {period_days: 1, scarce: false}
  deep-v41@commandcode: {period_days: 1, scarce: false}
bans: []
"""

CANDIDATES = [{
    "suf": "9.9.9", "id": "dos-product-v1-88cgo.9.9.9", "title": "leaf 9.9.9",
    "files": ["core/src/x.py"],
    "body": "SIZE: at most 200 changed lines\nFILES: core/src/x.py\nOWNER: core\n",
}]


def write_exec(path, text):
    with open(path, "w") as f:
        f.write(text)
    os.chmod(path, 0o755)


class Harness(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir="/tmp/claude-1000", prefix="router-test-")
        root = self.tmp.name
        self.home = os.path.join(root, "home")
        for d in (os.path.join(self.home, "data", "bin"),
                  os.path.join(self.home, "config")):
            os.makedirs(d)
        with open(os.path.join(self.home, "config", "fleet.yaml"), "w") as f:
            f.write(FLEET)
        self.cand = os.path.join(root, "candidates.json")
        with open(self.cand, "w") as f:
            json.dump(CANDIDATES, f)
        write_exec(os.path.join(self.home, "data", "bin", "lane-overlap-check.py"),
                   "#!/usr/bin/env python3\nimport sys; sys.exit(0)\n")
        # pass-9: the sender rechecks can_start before delivery; the fixture answers it (the real one reads
        # this machine's load/memory) and runs the real library for everything else
        write_exec(os.path.join(self.home, "data", "bin", "refill_lib_v2.py"),
                   'import os, sys\nif sys.argv[1] == "can-start":\n    print("2\\tfixture"); sys.exit(0)\n'
                   'os.execv(sys.executable, [sys.executable, %r] + sys.argv[1:])\n' % LIB)
        self.send_log = os.path.join(root, "sm-send.log")
        # a confirmed delivery prints the recognised bosgame acknowledgment ('replied') on
        # stdout AND records the send in the log
        write_exec(os.path.join(self.home, "data", "bin", "bosgame-sm-send.sh"),
                   '#!/usr/bin/env bash\necho "replied: leaf accepted" | tee -a "%s"\n' % self.send_log)
        self.restored_send = SEND

    def tearDown(self):
        self.tmp.cleanup()

    def run_send(self, *args, env_extra=None, restored=True):
        env = dict(os.environ, BOSGAME_LEAF_HOME=self.home, FM_HOME=self.home,
                   BOSGAME_CANDIDATES=self.cand,
                   BOSGAME_PACKET_LOCK=os.path.join(self.tmp.name, "daily_packet_run.lock"))
        env.pop("ROUTER_LIVE", None)   # ROUTER_LIVE is opt-in per test
        env.update(env_extra or {})
        argv = list(args)
        if "--binding" in argv and "--incarnation" not in argv:
            argv += ["--incarnation", "fixture-incarnation"]
        sender = self.restored_send if restored else SEND
        return subprocess.run(["bash", sender, "9.9.9", *argv], text=True,
                              capture_output=True, env=env, timeout=60)

    def message(self):
        with open(os.path.join(self.home, "data", "dos-bosgame-9-9-9-1001", "message.txt")) as f:
            return f.read()


class BindingLaneCli(unittest.TestCase):
    def run_cli(self, home, *args):
        env = dict(os.environ, FM_HOME=home)
        return subprocess.run([sys.executable, LIB, "binding-lane", *args],
                              text=True, capture_output=True, env=env, timeout=60)

    def test_binding_lane_prints_harness_model_provider_effort(self):
        with tempfile.TemporaryDirectory() as home:
            os.mkdir(os.path.join(home, "config"))
            with open(os.path.join(home, "config", "fleet.yaml"), "w") as f:
                f.write(FLEET)
            r = self.run_cli(home, "cat-jam@opencode")
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(r.stdout, "opencode\tcat-jam\topencode\tmedium\n")
            # an explicit effort on the binding row wins over the medium default
            r = self.run_cli(home, "deep-v41@commandcode")
            self.assertEqual(r.stdout, "commandcode\tdeep-v41\tcommandcode\thigh\n")

    def test_binding_lane_unresolvable_fails_closed_with_empty_stdout(self):
        with tempfile.TemporaryDirectory() as home:
            os.mkdir(os.path.join(home, "config"))
            with open(os.path.join(home, "config", "fleet.yaml"), "w") as f:
                f.write(FLEET)
            r = self.run_cli(home, "nope@nowhere")
            self.assertNotEqual(r.returncode, 0)
            self.assertEqual(r.stdout, "")
            # a bare MODEL id is not a binding: also unresolvable here
            r = self.run_cli(home, "cat-jam")
            self.assertNotEqual(r.returncode, 0)
            self.assertEqual(r.stdout, "")


class SenderAppliesBinding(Harness):
    def test_binding_replaces_the_default_lane_text(self):
        r = self.run_send("--dry-run", "--binding", "cat-jam@opencode")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        msg = self.message()
        # pass-6 (review): the RESOLVED PROVIDER is part of the route text
        self.assertIn("a worker: harness opencode, model cat-jam, provider opencode, effort medium", msg)
        # none of the legacy marker-file routes leak into the message
        self.assertNotIn("Claude Code worker", msg)
        self.assertNotIn("Muse worker", msg)
        self.assertNotIn("Spark worker", msg)
        self.assertNotIn("claude-sonnet-5-5", msg)

    def test_same_model_and_harness_different_provider_changes_the_message(self):
        # pass-6 (review): bindings with the same model and harness but different providers must
        # NOT produce identical dispatch instructions.
        r = self.run_send("--dry-run", "--binding", "cat-jam@opencode")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        msg_opencode = self.message()
        r = self.run_send("--dry-run", "--binding", "cat-jam@north")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        msg_north = self.message()
        self.assertIn("provider opencode,", msg_opencode)
        self.assertIn("provider north,", msg_north)
        self.assertNotEqual(msg_opencode, msg_north)

    def test_binding_overrides_the_marker_file_branches(self):
        # even with BOTH legacy markers present, the routed binding wins
        os.makedirs(os.path.join(self.home, "data"), exist_ok=True)
        for marker in ("routine-muse.on", "bosgame-kimi.on", "claude-off"):
            open(os.path.join(self.home, "data", marker), "w").close()
        r = self.run_send("--dry-run", "--binding", "deep-v41@commandcode")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        msg = self.message()
        self.assertIn("a worker: harness commandcode, model deep-v41, provider commandcode, effort high", msg)
        self.assertNotIn("Muse worker", msg)
        self.assertNotIn("Spark worker", msg)

    def test_binding_env_var_form_matches_the_flag(self):
        r = self.run_send("--dry-run", env_extra={"BINDING": "cat-jam@opencode"})
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("a worker: harness opencode, model cat-jam, provider opencode, effort medium",
                      self.message())

    def test_binding_is_delivered_end_to_end_with_a_stub_sm(self):
        r = self.run_send("--binding", "cat-jam@opencode")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("a worker: harness opencode, model cat-jam, provider opencode, effort medium",
                      self.message())
        with open(self.send_log) as f:
            self.assertEqual(len(f.read().splitlines()), 1)   # exactly one send went out
        self.assertIn("\tsent\t", open(os.path.join(self.home, "data", "bosgame-lanes.tsv")).read())
        self.assertFalse(os.path.exists(os.path.join(
            self.home, "data", "dos-bosgame-9-9-9-1001", "reconcile-required.txt")))


class SenderLegacyUnchanged(Harness):
    def test_no_binding_keeps_the_default_sonnet_opus_text(self):
        r = self.run_send("--dry-run")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        msg = self.message()
        self.assertIn("a Claude Code worker", msg)
        self.assertIn("claude-sonnet-5-5", msg)

    def test_no_binding_keeps_the_muse_and_spark_markers(self):
        os.makedirs(os.path.join(self.home, "data"), exist_ok=True)
        open(os.path.join(self.home, "data", "routine-muse.on"), "w").close()
        r = self.run_send("--dry-run")
        self.assertIn("a Muse worker", self.message())
        open(os.path.join(self.home, "data", "bosgame-kimi.on"), "w").close()
        r = self.run_send("--dry-run")
        self.assertIn("a Spark worker", self.message())


class SenderRefusesUnresolvableBinding(Harness):
    def test_unresolvable_binding_refuses_before_anything_is_sent(self):
        # NOT a dry run: a stub bosgame-sm-send.sh records every real send attempt.
        r = self.run_send("--binding", "nope@nowhere")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("REFUSED: unresolvable binding", r.stdout + r.stderr)
        self.assertFalse(os.path.exists(self.send_log), "nothing may be sent on a refusal")
        self.assertFalse(os.path.exists(os.path.join(
            self.home, "data", "dos-bosgame-9-9-9-1001", "message.txt")))
        self.assertFalse(os.path.exists(os.path.join(self.home, "data", "bosgame-lanes.tsv")))


class SenderFailsLoudly(Harness):
    """pass-6 (review): a delivery failure is loud - the sender's exit status is preserved, an
    empty reply or an unrecognised transport error fails the send, and NO 'sent' row reaches
    data/bosgame-lanes.tsv unless delivery is confirmed."""

    def stub_sender(self, text):
        write_exec(os.path.join(self.home, "data", "bin", "bosgame-sm-send.sh"), text)

    def ledger_text(self):
        path = os.path.join(self.home, "data", "bosgame-lanes.tsv")
        return open(path).read() if os.path.exists(path) else ""

    def test_sender_nonzero_exit_with_empty_output_fails_and_writes_no_sent_row(self):
        self.stub_sender("#!/usr/bin/env bash\nexit 1\n")
        r = self.run_send("--binding", "cat-jam@opencode")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("NOT delivered", r.stdout + r.stderr)
        self.assertNotIn("\tsent\t", self.ledger_text())
        # the attempt happened (message composed) but success was never recorded
        self.assertTrue(os.path.exists(os.path.join(self.home, "data", "dos-bosgame-9-9-9-1001", "message.txt")))
        self.assertFalse(os.path.exists(self.send_log))

    def test_senders_exit_status_is_preserved(self):
        self.stub_sender("#!/usr/bin/env bash\necho 'ssh transport died' >&2\nexit 7\n")
        r = self.run_send("--binding", "cat-jam@opencode")
        self.assertEqual(r.returncode, 7, r.stdout + r.stderr)
        self.assertIn("NOT delivered", r.stdout + r.stderr)
        self.assertNotIn("\tsent\t", self.ledger_text())

    def test_unrecognised_transport_error_fails_and_writes_no_sent_row(self):
        # rc 0 but an output no success path recognises ('gribble' is not an SM answer)
        self.stub_sender("#!/usr/bin/env bash\necho 'SM transport: gribble frobnicate unknown status'\nexit 0\n")
        r = self.run_send("--binding", "cat-jam@opencode")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("NOT delivered", r.stdout + r.stderr)
        self.assertNotIn("\tsent\t", self.ledger_text())

    def test_empty_reply_with_zero_exit_fails(self):
        self.stub_sender("#!/usr/bin/env bash\nexit 0\n")
        r = self.run_send("--binding", "cat-jam@opencode")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("NOT delivered", r.stdout + r.stderr)
        self.assertNotIn("\tsent\t", self.ledger_text())

    def test_anchored_replied_ack_delivers_without_a_receiver_receipt(self):
        r = self.run_send("--binding", "cat-jam@opencode")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("\tsent\t", self.ledger_text())
        self.assertFalse(os.path.exists(os.path.join(
            self.home, "data", "dos-bosgame-9-9-9-1001", "reconcile-required.txt")))

    def test_connection_closed_with_zero_exit_fails_and_writes_no_sent_row(self):
        # pass-7 (review): exit 0 with no delivery acknowledgment in the reply is a FAILURE, not a
        # delivery ('Connection closed by remote host' used to pass the blacklist).
        self.stub_sender("#!/usr/bin/env bash\necho 'Connection closed by remote host'\nexit 0\n")
        r = self.run_send("--binding", "cat-jam@opencode")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("NOT delivered", r.stdout + r.stderr)
        self.assertNotIn("\tsent\t", self.ledger_text())

    def test_negated_sent_is_not_a_delivery_acknowledgment(self):
        # pass-8 (review): 'message not sent' carries 'sent' but is NEGATED - success requires an
        # ANCHORED positive ack line (one STARTING with 'replied' or 'sent'), and a negated form
        # ('not sent', 'failed to send') fails the send with no 'sent' row.
        self.stub_sender("#!/usr/bin/env bash\necho 'message not sent'\nexit 0\n")
        r = self.run_send("--binding", "cat-jam@opencode")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("NOT delivered", r.stdout + r.stderr)
        self.assertNotIn("\tsent\t", self.ledger_text())

    def test_anchored_sent_line_delivers_without_a_receiver_receipt(self):
        self.stub_sender("#!/usr/bin/env bash\necho 'sent: leaf queued by the bosgame SM'\nexit 0\n")
        r = self.run_send("--binding", "cat-jam@opencode")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("\tsent\t", self.ledger_text())

    def test_error_after_line_five_fails_and_writes_no_sent_row(self):
        # pass-7 (review): the acknowledgment test reads the WHOLE reply; an ack-looking first
        # line must not hide an error marker after line 5 (the old blacklist read only head -5).
        self.stub_sender("#!/usr/bin/env bash\n"
                         "printf 'replied: queued\\nok\\nok\\nok\\nok\\nError: denied by bosgame SM\\n'\n"
                         "exit 0\n")
        r = self.run_send("--binding", "cat-jam@opencode")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("NOT delivered", r.stdout + r.stderr)
        self.assertNotIn("\tsent\t", self.ledger_text())


class SenderAdmittedBinding(Harness):
    """pass-8 (review): the router passes the binding resolution it ADMITTED (BG_ADMIT_*); when the
    sender's fresh binding-lane re-read no longer matches (fleet.yaml edited between selection and
    send), the send is REFUSED before anything goes out."""

    def stub_lane(self, harness, model, provider, effort="medium"):
        write_exec(os.path.join(self.home, "data", "bin", "refill_lib_v2.py"),
                   "#!/usr/bin/env python3\nimport sys\nprint('2\\tfixture' if sys.argv[1] == 'can-start' else %r)\n"
                   % "\t".join((harness, model, provider, effort)))

    def ledger_text(self):
        path = os.path.join(self.home, "data", "bosgame-lanes.tsv")
        return open(path).read() if os.path.exists(path) else ""

    def test_changed_binding_resolution_refuses_before_anything_is_sent(self):
        # admission resolved cat-jam@north; by send time fleet.yaml resolves opencode: mismatch
        self.stub_lane("opencode", "cat-jam", "opencode")
        r = self.run_send("--binding", "cat-jam@north",
                          env_extra={"BG_ADMIT_HARNESS": "opencode", "BG_ADMIT_MODEL": "cat-jam",
                                     "BG_ADMIT_PROVIDER": "north", "BG_ADMIT_EFFORT": "medium"})
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("REFUSED", r.stdout + r.stderr)
        self.assertIn("admitted", r.stdout + r.stderr)
        self.assertFalse(os.path.exists(self.send_log), "nothing may be sent on a refusal")
        self.assertFalse(os.path.exists(os.path.join(self.home, "data", "bosgame-lanes.tsv")))

    def test_matching_admitted_binding_delivers_on_positive_acknowledgment(self):
        self.stub_lane("opencode", "cat-jam", "opencode")
        r = self.run_send("--binding", "cat-jam@opencode",
                          env_extra={"BG_ADMIT_HARNESS": "opencode", "BG_ADMIT_MODEL": "cat-jam",
                                     "BG_ADMIT_PROVIDER": "opencode", "BG_ADMIT_EFFORT": "medium"})
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("\tsent\t", self.ledger_text())


class RouterLiveFailsClosed(Harness):
    """pass-6b: while ROUTER_LIVE=1 the sender refuses a bare legacy send (no --binding) BEFORE
    anything is sent; a routed binding still sends and is applied."""

    def test_router_live_without_binding_refuses_before_anything_is_sent(self):
        r = self.run_send(env_extra={"ROUTER_LIVE": "1"})   # no --binding
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("REFUSED", r.stdout + r.stderr)
        self.assertFalse(os.path.exists(self.send_log), "nothing may be sent on a refusal")
        self.assertFalse(os.path.exists(os.path.join(self.home, "data", "bosgame-lanes.tsv")))
        # refused before the message was even composed: the legacy Sonnet/Opus/Spark branch never ran
        self.assertFalse(os.path.exists(os.path.join(self.home, "data", "dos-bosgame-9-9-9-1001")))

    def test_router_live_refusal_covers_dry_run_too(self):
        r = self.run_send("--dry-run", env_extra={"ROUTER_LIVE": "1"})
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("REFUSED", r.stdout + r.stderr)

    def test_router_live_with_binding_applies_it_and_delivers_on_positive_ack(self):
        r = self.run_send("--binding", "cat-jam@opencode", env_extra={"ROUTER_LIVE": "1"})
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        with open(self.send_log) as f:
            self.assertEqual(len(f.read().splitlines()), 1)   # exactly one send went out
        self.assertIn("a worker: harness opencode, model cat-jam, provider opencode, effort medium",
                      self.message())

    def test_router_live_unset_delivers_on_positive_acknowledgment(self):
        r = self.run_send(restored=False)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertTrue(os.path.exists(os.path.join(
            self.home, "data", "dos-bosgame-9-9-9-1001", "message.txt")))
        self.assertTrue(os.path.exists(self.send_log))


class RouterLiveExported(unittest.TestCase):
    """pass-7 (M2): lane-refill-v2.sh must EXPORT ROUTER_LIVE, so the bosgame sender it invokes
    (bosgame-leaf-send.sh's 'refuse when ROUTER_LIVE=1 and no --binding' guard) sees the value.
    The script's own ROUTER_LIVE line is executed in a fresh bash and a stub child prints what it
    observes in its environment."""

    SRC = open(REFILL).read()

    def test_router_live_line_is_exported_and_a_stub_child_observes_it(self):
        import re
        m = re.search(r"^(export ROUTER_LIVE=.*)$", self.SRC, re.M)
        self.assertIsNotNone(
            m, "lane-refill-v2.sh must set ROUTER_LIVE with export so children inherit it")
        with tempfile.TemporaryDirectory(dir="/tmp/claude-1000", prefix="router-test-") as d:
            child = os.path.join(d, "child.sh")
            write_exec(child, '#!/usr/bin/env bash\nprintf "%s" "${ROUTER_LIVE:-unset}"\n')
            for want, live in (("1", None), ("0", "0")):
                env = dict(os.environ)
                env.pop("ROUTER_LIVE", None)
                if live is not None:
                    env["ROUTER_LIVE"] = live
                r = subprocess.run(
                    ["bash", "-c", '%s\nexec "$1"' % m.group(1), "bash", child],
                    env=env, text=True, capture_output=True, check=True)
                self.assertEqual(r.stdout, want,
                                 "stub child must observe ROUTER_LIVE=%s from the script" % want)


class LaneRefillBosgameFailsClosed(unittest.TestCase):
    """pass-6b: the 3c-bosgame block in lane-refill-v2.sh fails closed on a bare-model router
    pick (no '@' binding) and is LOUD when the sender output is empty or unrecognised."""

    SRC = open(REFILL).read()

    def _bosgame_block(self):
        start = self.SRC.index('if [ "$host" = bosgame ]; then')
        return self.SRC[start:self.SRC.index('# v6: every netcup leaf start', start)]

    def test_bare_model_pick_refuses_before_the_sender_runs(self):
        blk = self._bosgame_block()
        refuse_i = blk.index("ROUTER: bosgame send refused: bare-model pick")
        send_i = blk.index('bosgame-leaf-send.sh" "$suf"')
        self.assertLess(refuse_i, send_i, "the refusal must come before the sender call")
        # the refusal branch skips the pick (continue) and is journaled, between case and sender
        self.assertIn("continue", blk[refuse_i:send_i])
        self.assertIn("dlog", blk[refuse_i:send_i], "the refusal is journaled")
        # a binding pick (an '@' id) is still handed to the sender
        self.assertIn('BG_EXTRA="--binding $ROUTE_PICK"', blk)
        self.assertIn('"$suf" $BG_EXTRA', blk)

    def test_failed_send_is_loud_and_positive_delivery_spends_one_start(self):
        blk = self._bosgame_block()
        self.assertIn("BOSGAME SEND FAILED $suf", blk)
        self.assertIn('bsnip="no output"', blk)
        self.assertIn("BOSGAME SEND DELIVERED", blk)
        self.assertIn("one_start", blk)


class LaneRefillSenderExitStatus(unittest.TestCase):
    """pass-8 (review): the caller CAPTURES the sender's exit status. A stub sender that prints a
    preliminary 'replied' line and then exits non-zero (e.g. its ledger append failed) is a FAILED
    send: loud, and one_start is never reached."""

    SRC = open(REFILL).read()

    def _bosgame_block(self):
        start = self.SRC.index('if [ "$host" = bosgame ]; then')
        return self.SRC[start:self.SRC.index('# v6: every netcup leaf start', start)]

    def test_sender_nonzero_exit_is_a_failed_send_before_one_start(self):
        blk = self._bosgame_block()
        send_line = next(l for l in blk.splitlines()
                         if l.lstrip().startswith("bsfull=") and "bosgame-leaf-send.sh" in l)
        self.assertNotIn("|| true", send_line,
                         "the sender's exit status must be captured, not folded away")
        self.assertIn("bs_rc=$?", blk)
        # The rc check precedes positive delivery accounting; a nonzero sender
        # exit never reaches one_start.
        rc_i = blk.index("bs_rc=$?")
        rc_check = blk.index('[ "$bs_rc" != 0 ]')
        success_i = blk.index("BOSGAME SEND DELIVERED")
        self.assertLess(rc_i, rc_check)
        self.assertLess(rc_check, success_i)
        self.assertIn("BOSGAME SEND FAILED", blk[rc_check:success_i])
        self.assertNotIn("one_start", blk[rc_check:success_i])


class LaneRefillFreshGateRechecksHolds(unittest.TestCase):
    """pass-8 (review): fresh_gate rechecks the explicit holds (new-leaves.hold, netcup-leaves.hold,
    packet-run lock) immediately before every spawn attempt - a hold activated during setup or the
    retry wait stops the launch."""

    SRC = open(REFILL).read()

    def _fn_body(self, name):
        import re
        m = re.search(r"^%s\(\)\s*\{(.*?)\n\}" % re.escape(name), self.SRC, re.M | re.S)
        self.assertIsNotNone(m, "%s must exist" % name)
        return m.group(1)

    def test_fresh_gate_rechecks_the_all_starts_holds(self):
        body = self._fn_body("fresh_gate")
        self.assertIn("new-leaves.hold", body)
        self.assertIn("pk_lock", body)   # the packet-run lock probe
        # the recheck zeroes the start budget, so no spawn slips past it
        self.assertIn("sn=0", body)

    def test_spawn_retry_rechecks_the_netcup_hold_before_fm_spawn(self):
        body = self._fn_body("spawn_retry")
        hold_i = body.index("netcup-leaves.hold")
        spawn_i = body.index('fm-spawn.sh" "$@"')
        self.assertLess(hold_i, spawn_i, "the netcup hold probe must precede the spawn attempt")


class LaneRefillPassesThePick(unittest.TestCase):
    """pass-5: lane-refill-v2.sh hands the router's picked binding to the bosgame sender."""

    SRC = open(REFILL).read()

    def test_bosgame_send_carries_the_picked_binding(self):
        blk = self.SRC[self.SRC.index('if [ "$host" = bosgame ]; then'):
                       self.SRC.index('# v6: every netcup leaf start')]
        self.assertIn('case ${ROUTE_PICK:-} in', blk)
        self.assertIn('BG_EXTRA="--binding $ROUTE_PICK"', blk)
        send_line = next(l for l in blk.splitlines()
                         if l.lstrip().startswith("bsfull=") and "bosgame-leaf-send.sh" in l)
        self.assertIn('"$suf" $BG_EXTRA', send_line)
        # only binding picks (an '@' id) are passed; a bare model pick keeps the legacy send
        self.assertIn("*@*) BG_EXTRA=", blk)


if __name__ == "__main__":
    unittest.main()
