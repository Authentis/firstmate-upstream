#!/usr/bin/env python3
"""Durable-record acceptance and anchored acknowledgement for the three remote senders.

A busy bosgame answers 'fm-ring: doorbell refused ... the steer stays durably recorded at .../N.msg'.
That steer is delivered (the doorbell rings later): the sender must accept it, never resend it, and
print its OWN positive line anchored ^(replied|sent). Fixture-only: transports are local stubs."""
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import test_bosgame_binding as tbb  # noqa: E402

ANCHORED = re.compile(r"^(replied|sent)", re.M)
BUSY = ("fm-ring: doorbell refused (secondmate busy); the steer stays durably recorded at "
        "/home/x/state/bosgame-sm.inbox/0042.msg\n")


def stub(path, text):
    with open(path, "w") as f:
        f.write(text)
    os.chmod(path, 0o755)


def counting_reply(log, body):
    return ('#!/usr/bin/env bash\ncat > /dev/null\necho x >> "%s"\ncat <<\'EOF_REPLY\'\n%s\nEOF_REPLY\n'
            % (log, body.rstrip("\n")))


def count(log):
    try:
        with open(log) as f:
            return len(f.read().split())
    except FileNotFoundError:
        return 0


class LeafSender(tbb.Harness):
    def stub_reply(self, body):
        stub(os.path.join(self.home, "data", "bin", "bosgame-sm-send.sh"), counting_reply(self.send_log, body))

    def delivered_rec(self):
        return os.path.join(self.home, "data", "dos-bosgame-9-9-9-1001", "delivered.rec")

    def test_durable_record_is_accepted_with_an_anchored_ack(self):
        self.stub_reply(BUSY)
        r = self.run_send()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertRegex(r.stdout, ANCHORED)
        with open(self.delivered_rec()) as f:
            self.assertEqual(f.read().strip(), "0042")
        self.assertFalse(os.path.exists(os.path.join(self.home, "data", "dos-bosgame-9-9-9-1001",
                                                     "reconcile-required.txt")))
        with open(os.path.join(self.home, "data", "bosgame-lanes.tsv")) as f:
            self.assertIn("\tsent\t", f.read())

    def test_durably_recorded_leaf_is_never_resent(self):
        self.stub_reply(BUSY)
        self.assertEqual(self.run_send().returncode, 0)
        before = count(self.send_log)
        r = self.run_send()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertRegex(r.stdout, ANCHORED)
        self.assertIn("0042.msg", r.stdout)
        self.assertEqual(count(self.send_log), before)

    def test_plain_positive_ack_still_delivers_and_prints_anchored_line(self):
        r = self.run_send()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertRegex(r.stdout, ANCHORED)
        self.assertFalse(os.path.exists(self.delivered_rec()))

    def test_negative_cases_are_not_delivered(self):
        for body in ("Connection closed by remote host\nsee log: durably recorded at /tmp/x/99.msg", "sent but fm-ring: doorbell refused", "message not sent",
                     "Connection closed by remote host", "replied error: rejected"):
            with self.subTest(body=body):
                self.stub_reply(body)
                r = self.run_send()
                self.assertNotEqual(r.returncode, 0)
                self.assertNotRegex(r.stdout, ANCHORED)
                self.assertFalse(os.path.exists(self.delivered_rec()))
                self.assertFalse(os.path.exists(os.path.join(self.home, "data", "bosgame-lanes.tsv")))


class PickupSender(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = os.path.join(self.tmp.name, "home")
        os.makedirs(os.path.join(self.home, "data"))
        os.makedirs(os.path.join(self.home, "config"))
        with open(os.path.join(self.home, "config", "fleet.yaml"), "w") as f:
            f.write(tbb.FLEET)
        self.cand = os.path.join(self.tmp.name, "candidates.json")
        with open(self.cand, "w") as f:
            json.dump(tbb.CANDIDATES, f)
        self.log = os.path.join(self.tmp.name, "sends.log")
        self.sender = os.path.join(self.tmp.name, "sm-send.sh")
        self.d = os.path.join(self.home, "data", "dos-bosgame-cloud-9-9-9-1001")

    def tearDown(self):
        self.tmp.cleanup()

    def reply(self, body):
        stub(self.sender, counting_reply(self.log, body))

    def run_pickup(self):
        env = dict(os.environ, FM_HOME=self.home, ROUTER_BIN=HERE, BOSGAME_SM_SEND=self.sender,
                   BOSGAME_CANDIDATES=self.cand)
        return subprocess.run(["bash", os.path.join(HERE, "cloud-pickup-send.sh"), "9.9.9", "claude/x",
                               "--binding", "cat-jam@opencode", "--incarnation", "inc"],
                              text=True, capture_output=True, env=env, timeout=60)

    def test_durable_record_is_accepted_and_not_resent(self):
        self.reply(BUSY)
        r = self.run_pickup()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertRegex(r.stdout, ANCHORED)
        with open(os.path.join(self.d, "delivered.rec")) as f:
            self.assertEqual(f.read().strip(), "0042")
        self.assertFalse(os.path.exists(os.path.join(self.d, "reconcile-required.txt")))
        before = count(self.log)
        r = self.run_pickup()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertRegex(r.stdout, ANCHORED)
        self.assertEqual(count(self.log), before)

    def test_plain_positive_ack_prints_anchored_line(self):
        self.reply("replied: pickup accepted")
        r = self.run_pickup()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertRegex(r.stdout, ANCHORED)

    def test_negative_cases_are_not_delivered(self):
        for body in ("Connection closed by remote host\nsee log: durably recorded at /tmp/x/99.msg", "message not sent", "Connection closed by remote host",
                     "sent but fm-ring: doorbell refused", "replied error: rejected"):
            with self.subTest(body=body):
                self.reply(body)
                r = self.run_pickup()
                self.assertNotEqual(r.returncode, 0)
                self.assertNotRegex(r.stdout, ANCHORED)
                self.assertFalse(os.path.exists(os.path.join(self.d, "delivered.rec")))


class PlanSender(unittest.TestCase):
    def fresh_home(self):
        home = tempfile.mkdtemp()
        os.makedirs(os.path.join(home, "data"))
        os.makedirs(os.path.join(home, "state"))
        auth = os.path.join(home, "data", "t1-plan-authority.tsv")
        with open(auth, "w") as f:
            f.write("A\tparent-a\troot-a\n")
        return home

    def run_plan(self, home, n, sender):
        env = dict(os.environ, FM_HOME=home, T1_AUTHORITY_FILE=os.path.join(home, "data", "t1-plan-authority.tsv"),
                   BOSGAME_SM_SEND=sender, BG_PLAN_SUPPLY="1", BG_T1_LETTER="A", BG_T1_ROWS="parent-a")
        return subprocess.run([os.path.join(HERE, "bosgame-plan-send.sh"), str(n)],
                              text=True, capture_output=True, env=env, timeout=30)

    def reply_sender(self, home, name, body):
        path = os.path.join(home, name)
        stub(path, counting_reply(os.path.join(home, "sends.log"), body))
        return path

    def task_dir(self, home, n):
        names = [d for d in os.listdir(os.path.join(home, "data")) if d.startswith("dos-planning%s-bosgame-" % n)]
        self.assertEqual(len(names), 1)
        return os.path.join(home, "data", names[0])

    def test_durable_record_is_accepted_not_resent(self):
        home = self.fresh_home()
        r = self.run_plan(home, 5, self.reply_sender(home, "send.sh", BUSY))
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertRegex(r.stdout, ANCHORED)
        d = self.task_dir(home, 5)
        with open(os.path.join(d, "delivered.rec")) as f:
            self.assertEqual(f.read().strip(), "0042")
        self.assertFalse(os.path.exists(os.path.join(d, "reconcile-required.txt")))
        self.assertTrue(os.path.exists(os.path.join(home, "state", os.path.basename(d) + ".running")))
        before = count(os.path.join(home, "sends.log"))
        r2 = self.run_plan(home, 5, self.reply_sender(home, "send2.sh", "replied again"))
        self.assertEqual(r2.returncode, 0, r2.stdout + r2.stderr)
        self.assertRegex(r2.stdout, ANCHORED)
        self.assertEqual(count(os.path.join(home, "sends.log")), before)

    def test_plain_ack_prints_anchored_line(self):
        home = self.fresh_home()
        r = self.run_plan(home, 6, self.reply_sender(home, "send.sh", "replied accepted"))
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertRegex(r.stdout, ANCHORED)

    def test_negative_cases_are_not_delivered(self):
        for n, body in ((14, "Connection closed by remote host\nsee log: durably recorded at /tmp/x/99.msg"), (11, "message not sent"), (12, "Connection closed by remote host"),
                        (13, "sent but fm-ring: doorbell refused")):
            with self.subTest(body=body):
                home = self.fresh_home()
                r = self.run_plan(home, n, self.reply_sender(home, "send.sh", body))
                self.assertNotEqual(r.returncode, 0)
                self.assertNotRegex(r.stdout, ANCHORED)
                self.assertFalse(os.path.exists(os.path.join(self.task_dir(home, n), "delivered.rec")))


if __name__ == "__main__":
    unittest.main()
