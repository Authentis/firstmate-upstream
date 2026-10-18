#!/usr/bin/env python3
"""Offline integration checks for Router v3.1 closure, GO, and remote helpers.

The tests deliberately inspect or execute only the build-copy entrypoints.  Runtime
fixtures keep FM_HOME, router state, transport stubs, and candidate data under the
test directory; no real router, model, ssh, or network command is invoked.
"""
import os
import re
import json
import subprocess
import tempfile
import unittest


HERE = os.path.dirname(os.path.abspath(__file__))


def src(name):
    with open(os.path.join(HERE, name), encoding="utf-8") as f:
        return f.read()


ENTRYPOINTS = (
    "closure-sweep.sh", "mkclose-template.sh", "go-slot.sh",
    "bosgame-plan-send.sh", "bosgame-leaf-send.sh", "cloud-pickup-send.sh",
)


class EntrypointIsolation(unittest.TestCase):
    def test_every_helper_is_fm_home_and_bundle_anchored(self):
        for name in ENTRYPOINTS:
            text = src(name)
            with self.subTest(name=name):
                self.assertRegex(text, r'FM_HOME:-|FM_HOME:?=')
                self.assertIn("ROUTER_BIN", text)
                self.assertNotIn("H=/home/holu/fm-secondmate-upstream-20260907", text)

    def test_global_router_off_precedes_mutation_and_transport(self):
        needles = ("mkdir ", "touch ", "fm-spawn.sh", "fm-control.sh", "bosgame-sm-send", "ssh -T")
        for name in ENTRYPOINTS:
            text = "\n".join(line for line in src(name).splitlines()
                             if not line.lstrip().startswith("#"))
            off = text.find("data/router-off")
            with self.subTest(name=name):
                self.assertGreaterEqual(off, 0)
                later = [text.find(n) for n in needles if text.find(n) >= 0]
                self.assertTrue(not later or off < min(later))

    def test_no_helper_deletes_state(self):
        for name in ENTRYPOINTS:
            with self.subTest(name=name):
                self.assertNotRegex(src(name), r'(^|[;&|]\s*)rm\s')
                self.assertNotIn("os.remove(", src(name))


class ClosureContract(unittest.TestCase):
    SWEEP = src("closure-sweep.sh")
    TEMPLATE = src("mkclose-template.sh")

    def test_batch_guards_and_real_classification_are_retained(self):
        self.assertIn("-mmin +50", self.SWEEP)
        self.assertIn("head -30", self.SWEEP)
        self.assertIn("closure-sweep.hold", self.SWEEP)
        self.assertIn("router_classify_task", self.SWEEP)
        self.assertRegex(self.SWEEP, r"WAIT|wait")
        self.assertIn("router_admit", self.SWEEP + self.TEMPLATE)
        self.assertIn("router_classify_task", self.TEMPLATE)
        self.assertNotIn("CLOSURE_REAL:-no", self.TEMPLATE)

    def test_stamp_and_accounting_follow_verified_receipt(self):
        verify = self.TEMPLATE.find("router_confirm_verified")
        confirm = self.TEMPLATE.find("ROUTER_CONFIRMED")
        stamp = self.SWEEP.find('touch "$S"')
        self.assertGreaterEqual(verify, 0)
        self.assertGreater(confirm, verify)
        self.assertGreaterEqual(stamp, 0)
        self.assertIn('if CLOSURE_TASK_ID="$id"', self.SWEEP)
        self.assertIn("ROUTER_CONFIRMED", self.TEMPLATE)
        self.assertIn('refill_lib_v2.py" note-start "$H/data/refill-starts.log"', self.TEMPLATE)
        self.assertIn("ROUTER_HELPER_ACCOUNTS", self.TEMPLATE)
        self.assertIn("router_ambiguous", self.TEMPLATE)

    def test_closure_launch_uses_admitted_argument_array(self):
        live = self.TEMPLATE[self.TEMPLATE.index('ROUTER_LIVE') :]
        self.assertIn('"${RA_ARGV[@]}"', live)
        self.assertIn("qwen-token-plan-individual/deepseek-v4-flash-0731", self.TEMPLATE,
                      "LIVE=0 must retain the legacy deferred closure tuple")
        self.assertIn("router_ambiguous", self.TEMPLATE)
        self.assertRegex(self.TEMPLATE, r'router_failure[^\n]*\$out')


class GoContract(unittest.TestCase):
    GO = src("go-slot.sh")

    def test_live_route_uses_admission_and_selected_tuple(self):
        self.assertIn("router_admit", self.GO)
        self.assertIn('"${RA_ARGV[@]}"', self.GO)
        live = self.GO[self.GO.index('if [ "${ROUTER_LIVE:-0}" = 1 ]'):]
        live = live[:live.index("else")]
        self.assertNotIn("rx ", live)
        self.assertIn("router_confirm", self.GO)
        self.assertIn("router_classify_task", self.GO)
        self.assertNotIn("ROUTER_GO_REAL:-no", self.GO)
        self.assertIn('os.environ["ROUTER_BIN"]', self.GO)
        self.assertNotIn('python3 "$H/data/bin/', self.GO)
        self.assertIn('refill_lib_v2.py" can-start', self.GO)
        self.assertIn('refill_lib_v2.py" note-start', self.GO)

    def test_existing_binding_check_is_nonrotating(self):
        self.assertIn("only_binding", self.GO)
        self.assertIn("same", self.GO)

    def test_unconfirmed_relaunch_keeps_reservation(self):
        self.assertIn("reservation kept", self.GO)
        self.assertIn("router_failure", self.GO)
        self.assertIn("router_ambiguous", self.GO)
        self.assertRegex(self.GO, r'router_failure[^\n]*\$out')
        self.assertIn("router_cancel", self.GO)


class RemoteProtocolContract(unittest.TestCase):
    PLAN = src("bosgame-plan-send.sh")
    LEAF = src("bosgame-leaf-send.sh")
    PICKUP = src("cloud-pickup-send.sh")

    def test_planning_delivery_uses_the_anchored_v3_acknowledgment(self):
        self.assertIn("^(replied|sent)", self.PLAN)
        self.assertNotIn("acceptance disabled pending owner receipt grammar", self.PLAN)
        self.assertNotIn("reconcile-required.txt", self.PLAN)
        self.assertIn("bosgame-lanes.tsv", self.PLAN)

    def test_planning_sender_records_an_anchored_positive_ack(self):
        with tempfile.TemporaryDirectory() as home:
            os.makedirs(os.path.join(home, "data"))
            os.makedirs(os.path.join(home, "state"))
            with open(os.path.join(home, "data", "t1-plan-authority.tsv"), "w", encoding="utf-8") as f:
                f.write("A\tparent-a\troot-a\n")
            sender = os.path.join(home, "send-ok.sh")
            with open(sender, "w", encoding="utf-8") as f:
                f.write("#!/usr/bin/env bash\nprintf 'replied accepted\n'\n")
            os.chmod(sender, 0o755)
            env = dict(os.environ, FM_HOME=home, T1_AUTHORITY_FILE=os.path.join(home, "data", "t1-plan-authority.tsv"), BOSGAME_SM_SEND=sender,
                       BG_PLAN_SUPPLY="1", BG_T1_LETTER="A", BG_T1_ROWS="parent-a")
            done = subprocess.run([os.path.join(HERE, "bosgame-plan-send.sh"), "7"],
                                  text=True, capture_output=True, env=env, timeout=15)
            self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
            task_dirs = [d for d in os.listdir(os.path.join(home, "data"))
                         if d.startswith("dos-planning7-bosgame-")]
            self.assertEqual(len(task_dirs), 1)
            task = task_dirs[0]
            self.assertTrue(os.path.exists(os.path.join(home, "state", task + ".running")))
            with open(os.path.join(home, "data", "bosgame-lanes.tsv"), encoding="utf-8") as f:
                ledger = f.read()
            self.assertIn(task, ledger)
            self.assertIn("\tsent\n", ledger)
            self.assertNotIn("reconcile", done.stdout + done.stderr)

    def test_planning_sender_rejects_error_marked_positive_ack(self):
        with tempfile.TemporaryDirectory() as home:
            os.makedirs(os.path.join(home, "data"))
            os.makedirs(os.path.join(home, "state"))
            with open(os.path.join(home, "data", "t1-plan-authority.tsv"), "w", encoding="utf-8") as f:
                f.write("A\tparent-a\troot-a\n")
            sender = os.path.join(home, "send-error.sh")
            with open(sender, "w", encoding="utf-8") as f:
                f.write("#!/usr/bin/env bash\nprintf 'sent error: rejected\n'\n")
            os.chmod(sender, 0o755)
            env = dict(os.environ, FM_HOME=home, T1_AUTHORITY_FILE=os.path.join(home, "data", "t1-plan-authority.tsv"), BOSGAME_SM_SEND=sender,
                       BG_PLAN_SUPPLY="1", BG_T1_LETTER="A", BG_T1_ROWS="parent-a")
            done = subprocess.run([os.path.join(HERE, "bosgame-plan-send.sh"), "8"],
                                  text=True, capture_output=True, env=env, timeout=15)
            self.assertNotEqual(done.returncode, 0)
            task_dirs = [d for d in os.listdir(os.path.join(home, "data"))
                         if d.startswith("dos-planning8-bosgame-")]
            self.assertEqual(len(task_dirs), 1)
            self.assertFalse(os.path.exists(os.path.join(home, "state", task_dirs[0] + ".running")))

    def test_remote_requests_carry_binding_and_incarnation(self):
        for name, text in (("plan", self.PLAN), ("leaf", self.LEAF), ("pickup", self.PICKUP)):
            with self.subTest(name=name):
                self.assertIn("binding", text.lower())
                self.assertIn("incarnation", text.lower())
                self.assertIn("remote final catalog recheck", text.lower())
                self.assertIn("BG_ADMIT_HARNESS", text)

    def test_leaf_and_pickup_use_anchored_positive_delivery_acknowledgments(self):
        for name, text in (("leaf", self.LEAF), ("pickup", self.PICKUP)):
            with self.subTest(name=name):
                self.assertRegex(text, r"grep -qE? '.*\^\(replied\|sent\)")
                self.assertNotIn("acceptance disabled pending owner receipt grammar", text)
                self.assertNotIn("reconcile-required.txt", text)

    def test_pickup_has_no_delegated_free_or_muse_picker(self):
        self.assertNotIn("per your free/Muse lane posture", self.PICKUP)
        self.assertIn("--binding", self.PICKUP)
        self.assertNotIn("|| true", self.PICKUP)


class RouterOffRuntime(unittest.TestCase):
    def test_switch_blocks_helpers_before_argument_parsing(self):
        root = tempfile.mkdtemp(prefix="v31-helper-off-", dir=os.environ.get("ROUTER_TEST_TMP", "/tmp/claude-1000/router-build/.router-v31-testing"))
        home = os.path.join(root, "home")
        os.makedirs(os.path.join(home, "data"))
        open(os.path.join(home, "data", "router-off"), "w").close()
        env = dict(os.environ, FM_HOME=home, ROUTER_BIN=HERE)
        for name in ENTRYPOINTS:
            r = subprocess.run(["bash", os.path.join(HERE, name)], env=env, text=True,
                               capture_output=True, timeout=10)
            with self.subTest(name=name):
                self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
                self.assertIn("router-off", r.stdout + r.stderr)


class ClosureRuntime(unittest.TestCase):
    def fixture(self):
        root = tempfile.mkdtemp(prefix="v31-closure-", dir=os.environ.get(
            "ROUTER_TEST_TMP", "/tmp/claude-1000/router-build/.router-v31-testing"))
        home = os.path.join(root, "home")
        bindir = os.path.join(root, "bin")
        project = os.path.join(root, "project")
        for d in (os.path.join(home, "data"), os.path.join(home, "state"), bindir,
                  os.path.join(project, ".beads")):
            os.makedirs(d)
        with open(os.path.join(bindir, "router-launch.sh"), "w") as f:
            f.write('router_labels_from_rows(){ case "$1" in *credentials:yes*) printf "[\\\"credentials:yes\\\"]\\n";; *\"labels\"*) printf "[]\\n";; *) return 75;; esac; }\n'
                    'router_classify_task(){ case "$2" in *credentials:yes*) echo yes;; *) echo no;; esac; }\n')
        with open(os.path.join(bindir, "landed-leaf-sweep.py"), "w") as f:
            f.write("import os; print(os.environ.get('SWEEP_ROWS',''))\n")
        with open(os.path.join(bindir, "mkclose-template.sh"), "w") as f:
            f.write('#!/usr/bin/env bash\nif grep -q credential "$FM_HOME/state/closure-sweep.rows.jsonl"; then echo yes; else echo no; fi > "$FM_HOME/state/template-real"\n'
                    'wc -l < "$FM_HOME/state/closure-sweep.list" > "$FM_HOME/state/template-count"\n'
                    'exit "${TEMPLATE_RC:-1}"\n')
        os.chmod(os.path.join(bindir, "mkclose-template.sh"), 0o755)
        env = dict(os.environ, FM_HOME=home, ROUTER_BIN=bindir, ROUTER_PROJECT_DIR=project)
        return root, home, project, env

    def run_sweep(self, env):
        return subprocess.run(["bash", os.path.join(HERE, "closure-sweep.sh"), "--force"],
                              env=env, text=True, capture_output=True, timeout=20)

    def test_unknown_row_waits_without_stamp_or_launch(self):
        _, home, project, env = self.fixture()
        env["SWEEP_ROWS"] = "9.9.9 123"
        open(os.path.join(project, ".beads", "issues.jsonl"), "w").close()
        r = self.run_sweep(env)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("WAIT", r.stdout)
        self.assertFalse(os.path.exists(os.path.join(home, "state", "template-real")))
        self.assertFalse(os.path.exists(os.path.join(home, "state", ".closure-sweep.stamp")))

    def test_missing_labels_wait_without_template_launch(self):
        _, home, project, env = self.fixture()
        env["SWEEP_ROWS"] = "9.9.9 123"
        with open(os.path.join(project, ".beads", "issues.jsonl"), "w") as f:
            f.write(json.dumps({"id": "dos-product-v1-88cgo.9.9.9", "title": "portable"}) + "\n")
        r = self.run_sweep(env)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("WAIT: current tracker labels unavailable or malformed", r.stdout)
        self.assertFalse(os.path.exists(os.path.join(home, "state", "template-real")))
        self.assertFalse(os.path.exists(os.path.join(home, "state", ".closure-sweep.stamp")))

    def test_credentials_are_classified_and_batch_is_capped_without_accounting(self):
        _, home, project, env = self.fixture()
        rows = []
        for n in range(35):
            token = "9.9.%d" % n
            rows.append("%s %d" % (token, n))
        env["SWEEP_ROWS"] = "\n".join(rows)
        with open(os.path.join(project, ".beads", "issues.jsonl"), "w") as f:
            for n in range(35):
                f.write(json.dumps({"id": "dos-product-v1-88cgo.9.9.%d" % n,
                                    "title": "portable task", "labels": ["credentials:yes"]}) + "\n")
        r = self.run_sweep(env)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        with open(os.path.join(home, "state", "template-real")) as f:
            self.assertEqual(f.read().strip(), "yes")
        with open(os.path.join(home, "state", "template-count")) as f:
            self.assertEqual(f.read().strip(), "30")
        self.assertFalse(os.path.exists(os.path.join(home, "state", ".closure-sweep.stamp")),
                         "failed accounting must not advance the throttle")

    def test_hold_and_dry_run_do_not_invoke_template(self):
        for held in (True, False):
            with self.subTest(held=held):
                _, home, project, env = self.fixture()
                env["SWEEP_ROWS"] = "9.9.9 123"
                with open(os.path.join(project, ".beads", "issues.jsonl"), "w") as f:
                    f.write(json.dumps({"id": "dos-product-v1-88cgo.9.9.9", "title": "plain", "labels": []}) + "\n")
                if held:
                    open(os.path.join(home, "data", "closure-sweep.hold"), "w").close()
                    argv = ["bash", os.path.join(HERE, "closure-sweep.sh"), "--force"]
                else:
                    argv = ["bash", os.path.join(HERE, "closure-sweep.sh"), "--force", "--dry-run"]
                r = subprocess.run(argv, env=env, text=True, capture_output=True, timeout=20)
                self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
                self.assertFalse(os.path.exists(os.path.join(home, "state", "template-real")))

    def test_router_off_race_returning_zero_never_stamps_or_accounts(self):
        _, home, project, env = self.fixture()
        env["SWEEP_ROWS"] = "9.9.9 123"
        with open(os.path.join(project, ".beads", "issues.jsonl"), "w") as f:
            f.write(json.dumps({"id": "dos-product-v1-88cgo.9.9.9", "title": "plain", "labels": []}) + "\n")
        template = os.path.join(env["ROUTER_BIN"], "mkclose-template.sh")
        with open(template, "w") as f:
            f.write('#!/usr/bin/env bash\ntouch "$FM_HOME/data/router-off"\necho router-off\nexit 0\n')
        os.chmod(template, 0o755)
        r = self.run_sweep(env)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("stamp and count unchanged", r.stdout + r.stderr)
        self.assertFalse(os.path.exists(os.path.join(home, "state", ".closure-sweep.stamp")))
        self.assertFalse(os.path.exists(os.path.join(home, "data", "tree-closes.log")))
        self.assertFalse(any(name.startswith(".closure-helper-verified-")
                             for name in os.listdir(os.path.join(home, "state"))))

    def test_fatal_verified_account_failure_propagates_from_sweep(self):
        _, home, project, env = self.fixture()
        env.update(SWEEP_ROWS="9.9.9 123", TEMPLATE_RC="70")
        with open(os.path.join(project, ".beads", "issues.jsonl"), "w") as f:
            f.write(json.dumps({"id": "dos-product-v1-88cgo.9.9.9", "title": "plain", "labels": []}) + "\n")
        r = self.run_sweep(env)
        self.assertEqual(r.returncode, 70, r.stdout + r.stderr)
        self.assertIn("fatal verified-launch accounting failure", r.stdout + r.stderr)
        self.assertFalse(os.path.exists(os.path.join(home, "state", ".closure-sweep.stamp")))
        self.assertFalse(os.path.exists(os.path.join(home, "data", "tree-closes.log")))

    def test_ambiguous_launch_propagates_from_sweep(self):
        _, home, project, env = self.fixture()
        env.update(SWEEP_ROWS="9.9.9 123", TEMPLATE_RC="74")
        with open(os.path.join(project, ".beads", "issues.jsonl"), "w") as f:
            f.write(json.dumps({"id": "dos-product-v1-88cgo.9.9.9", "title": "plain", "labels": []}) + "\n")
        r = self.run_sweep(env)
        self.assertEqual(r.returncode, 74, r.stdout + r.stderr)
        self.assertIn("fatal ambiguous launch", r.stdout + r.stderr)
        self.assertFalse(os.path.exists(os.path.join(home, "state", ".closure-sweep.stamp")))

    def test_stamp_requires_matching_verified_accounted_result(self):
        _, home, project, env = self.fixture()
        env["SWEEP_ROWS"] = "9.9.9 123"
        with open(os.path.join(project, ".beads", "issues.jsonl"), "w") as f:
            f.write(json.dumps({"id": "dos-product-v1-88cgo.9.9.9", "title": "plain", "labels": []}) + "\n")
        template = os.path.join(env["ROUTER_BIN"], "mkclose-template.sh")
        with open(template, "w") as f:
            f.write('#!/usr/bin/env bash\nprintf "%s\\t%s\\tverified-accounted\\n" "$CLOSURE_TASK_ID" '
                    '"$CLOSURE_RESULT_NONCE" > "$CLOSURE_RESULT_FILE"\n')
        os.chmod(template, 0o755)
        r = self.run_sweep(env)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertTrue(os.path.exists(os.path.join(home, "state", ".closure-sweep.stamp")))
        with open(os.path.join(home, "data", "tree-closes.log")) as f:
            self.assertIn("closure-sweep spawned", f.read())


class ClosureTemplateRuntime(unittest.TestCase):
    def fixture(self, live, confirm=True, accounting_rc=0, labels="[]"):
        root = tempfile.mkdtemp(prefix="v31-mkclose-", dir=os.environ.get(
            "ROUTER_TEST_TMP", "/tmp/claude-1000/router-build/.router-v31-testing"))
        home = os.path.join(root, "home")
        bindir = os.path.join(root, "router-bin")
        project = os.path.join(root, "project")
        for d in (os.path.join(home, "data"), os.path.join(home, "state"),
                  os.path.join(home, "bin"), os.path.join(project, ".beads"), bindir):
            os.makedirs(d)
        with open(os.path.join(home, "state", "closure-sweep.list"), "w") as f:
            f.write("9.9.9 123\n")
        row = '{"id":"dos-product-v1-88cgo.9.9.9","title":"portable"'
        if labels is not None:
            row += ',"labels":' + labels
        row += '}\n'
        with open(os.path.join(home, "state", "closure-sweep.rows.jsonl"), "w") as f:
            f.write(row)
        with open(os.path.join(project, ".beads", "issues.jsonl"), "w") as f:
            f.write(row)
        with open(os.path.join(bindir, "router-launch.sh"), "w") as f:
            f.write('router_labels_from_rows(){ case "$1" in *credentials:yes*) printf "[\\\"credentials:yes\\\"]\\n";; *\"labels\"*) printf "[]\\n";; *) return 75;; esac; }\n'
                    'router_classify_task(){ printf "%%s\\n" "$2" > "$FM_HOME/state/classified-labels"; case "$2" in *credentials:yes*) echo yes;; *) echo no;; esac; }\n'
                    'router_admit(){ echo admit > "$FM_HOME/state/admit"; RA_INCARNATION=inc; RA_ARGV=(--harness pi --model admitted/model); }\n'
                    'router_prelaunch(){ echo prelaunch >> "$FM_HOME/state/events"; }\n'
                    'router_confirm_verified(){ echo confirm >> "$FM_HOME/state/events"; %s; }\n'
                    'router_ambiguous(){ echo ambiguous >> "$FM_HOME/state/events"; '
                    'mkdir -p "$FM_HOME/state/route-launches"; printf \'{"pending":true,"state":"ambiguous"}\\n\' '
                    '> "$FM_HOME/state/route-launches/$1.json"; }\n'
                    'router_failure(){ echo "failure:$3:$4" >> "$FM_HOME/state/events"; }\n'
                    'router_cancel(){ echo cancel >> "$FM_HOME/state/events"; }\n' % (":" if confirm else "return 75"))
        with open(os.path.join(bindir, "fm-brief-local.sh"), "w") as f:
            f.write('#!/usr/bin/env bash\nmkdir -p "$FM_HOME/data/$1"\nprintf "{TASK}\\n{FIRSTMATE_SPEC}\\n" > "$FM_HOME/data/$1/brief.md"\n')
        with open(os.path.join(bindir, "refill_lib_v2.py"), "w") as f:
            f.write('#!/usr/bin/env python3\nimport os,sys\n'
                    'if sys.argv[1] == "can-start": print(os.environ.get("CAN_START","1")+"\\tfixture"); sys.exit(0)\n'
                    'open(os.path.join(os.environ["FM_HOME"],"state","events"),"a").write("account\\n")\n'
                    'sys.exit(%d)\n' % accounting_rc)
        for path in (os.path.join(bindir, "fm-brief-local.sh"), os.path.join(bindir, "refill_lib_v2.py")):
            os.chmod(path, 0o755)
        with open(os.path.join(home, "bin", "fm-tasks-axi.sh"), "w") as f:
            f.write('#!/usr/bin/env bash\nexit 0\n')
        with open(os.path.join(home, "bin", "fm-spawn.sh"), "w") as f:
            f.write('#!/usr/bin/env bash\nprintf "%s\\n" "$*" > "$FM_HOME/state/spawn-args"\n'
                    'if [ "${SPAWN_RC:-0}" = 0 ]; then echo "window=real-window"; else echo "launcher timed out"; fi\n'
                    'exit "${SPAWN_RC:-0}"\n')
        for name in ("fm-tasks-axi.sh", "fm-spawn.sh"):
            os.chmod(os.path.join(home, "bin", name), 0o755)
        env = dict(os.environ, FM_HOME=home, ROUTER_BIN=bindir,
                   ROUTER_PROJECT_DIR=project, ROUTER_LIVE=str(live), ROUTER_HELPER_ACCOUNTS="1")
        return home, env

    def run_template(self, env):
        return subprocess.run(["bash", os.path.join(HERE, "mkclose-template.sh")], env=env,
                              text=True, capture_output=True, timeout=20)

    def test_live_zero_uses_legacy_tuple_without_v3_receipt_or_accounting(self):
        home, env = self.fixture(0)
        r = self.run_template(env)
        self.assertNotEqual(r.returncode, 0, r.stdout + r.stderr)
        with open(os.path.join(home, "state", "spawn-args")) as f:
            args = f.read()
        self.assertIn("qwen-token-plan-individual/deepseek-v4-flash-0731", args)
        with open(os.path.join(home, "state", "events")) as f:
            self.assertEqual(f.read().splitlines(), ["prelaunch"])

    def test_live_one_confirms_then_accounts_and_account_failure_is_closed(self):
        home, env = self.fixture(1, confirm=True, accounting_rc=5)
        r = self.run_template(env)
        self.assertEqual(r.returncode, 70)
        with open(os.path.join(home, "state", "events")) as f:
            self.assertEqual(f.read().splitlines(), ["prelaunch", "confirm", "account"])

    def test_live_label_only_credentials_reach_template_classifier(self):
        home, env = self.fixture(1, labels='["credentials:yes"]')
        r = self.run_template(env)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        with open(os.path.join(home, "state", "classified-labels")) as f:
            self.assertEqual(f.read().strip(), '["credentials:yes"]')
        self.assertTrue(os.path.exists(os.path.join(home, "state", "admit")))
        self.assertTrue(os.path.exists(os.path.join(home, "state", "spawn-args")))

    def test_live_missing_labels_waits_before_template_admission_or_spawn(self):
        home, env = self.fixture(1, labels=None)
        r = self.run_template(env)
        self.assertEqual(r.returncode, 4, r.stdout + r.stderr)
        self.assertIn("WAIT: current tracker labels unavailable or malformed", r.stderr)
        self.assertFalse(os.path.exists(os.path.join(home, "state", "admit")))
        self.assertFalse(os.path.exists(os.path.join(home, "state", "spawn-args")))

    def test_live_one_unverified_is_ambiguous_and_never_accounted(self):
        home, env = self.fixture(1, confirm=False)
        r = self.run_template(env)
        self.assertEqual(r.returncode, 74)
        with open(os.path.join(home, "state", "events")) as f:
            self.assertEqual(f.read().splitlines(), ["prelaunch", "confirm", "ambiguous"])
        with open(os.path.join(home, "state", "route-launches", "dos-tracker-closures2-1002.json")) as f:
            self.assertEqual(json.load(f), {"pending": True, "state": "ambiguous"})

    def test_live_one_timeout_without_endpoint_is_ambiguous(self):
        home, env = self.fixture(1)
        env["SPAWN_RC"] = "124"
        r = self.run_template(env)
        self.assertEqual(r.returncode, 74)
        with open(os.path.join(home, "state", "events")) as f:
            self.assertEqual(f.read().splitlines(), ["prelaunch", "ambiguous"])
        self.assertFalse(os.path.exists(os.path.join(home, "state", "account")))

    def test_live_one_rechecks_capacity_and_hold_before_spawn(self):
        for held in (False, True):
            with self.subTest(held=held):
                home, env = self.fixture(1)
                if held:
                    open(os.path.join(home, "data", "closure-sweep.hold"), "w").close()
                else:
                    env["CAN_START"] = "0"
                r = self.run_template(env)
                self.assertNotEqual(r.returncode, 0)
                self.assertFalse(os.path.exists(os.path.join(home, "state", "spawn-args")))
                self.assertFalse(os.path.exists(os.path.join(home, "state", "account")))
                with open(os.path.join(home, "state", "events")) as f:
                    self.assertEqual(f.read().splitlines(), ["cancel"])


class GoReservationRuntime(unittest.TestCase):
    def live_fixture(self, can_start, confirm):
        root = tempfile.mkdtemp(prefix="v31-go-live-", dir=os.environ.get(
            "ROUTER_TEST_TMP", "/tmp/claude-1000/router-build/.router-v31-testing"))
        home, bindir = os.path.join(root, "home"), os.path.join(root, "bin")
        for d in (os.path.join(home, "data", "bin"), os.path.join(home, "data", "dos-go-test"),
                  os.path.join(home, "state"), os.path.join(home, "bin"), bindir): os.makedirs(d)
        with open(os.path.join(home, "data", "dos-go-test", "brief.md"), "w") as f: f.write("plain task\n")
        with open(os.path.join(bindir, "router-launch.sh"), "w") as f:
            f.write('router_labels_from_rows(){ printf "[]\\n"; }\nrouter_classify_task(){ echo no; }\nrouter_admit(){ RA_INCARNATION=inc; RA_ARGV=(--harness pi --model admitted/model); }\n'
                    'router_prelaunch(){ :; }\nrouter_confirm_verified(){ %s; }\n'
                    'router_ambiguous(){ echo ambiguous > "$FM_HOME/state/router-event"; }\n'
                    'router_failure(){ echo failure > "$FM_HOME/state/router-event"; }\n'
                    'router_cancel(){ echo cancel > "$FM_HOME/state/cancel"; }\nrouter_check(){ :; }\n' % (":" if confirm else "return 75"))
        with open(os.path.join(bindir, "refill_lib_v2.py"), "w") as f:
            f.write('#!/usr/bin/env python3\nimport os,re,sys\nAGENT=re.compile(r"agent-never")\ndef is_working(*a): return False\n'
                    'if __name__ == "__main__":\n'
                    '  if sys.argv[1] == "can-start": print("%d\\tfixture")\n'
                    '  elif sys.argv[1] == "note-start": open(os.path.join(os.environ["FM_HOME"],"state","account"),"w").write("1")\n' % can_start)
        os.chmod(os.path.join(bindir, "refill_lib_v2.py"), 0o755)
        os.symlink(os.path.join(HERE, "refill_lib.py"), os.path.join(bindir, "refill_lib.py"))
        for name in ("openscale-spend.py", "go-spend.py"):
            with open(os.path.join(bindir, name), "w") as f: f.write("#!/usr/bin/env python3\n")
            os.chmod(os.path.join(bindir, name), 0o755)
        with open(os.path.join(home, "bin", "fm-spawn.sh"), "w") as f:
            f.write('#!/usr/bin/env bash\necho called > "$FM_HOME/state/spawn"\n'
                    'if [ "${SPAWN_RC:-0}" = 0 ]; then echo window=fixture-window; else echo timed-out; fi\n'
                    'exit "${SPAWN_RC:-0}"\n')
        os.chmod(os.path.join(home, "bin", "fm-spawn.sh"), 0o755)
        return home, dict(os.environ, FM_HOME=home, ROUTER_BIN=bindir, GO_CAP="1", ROUTER_LIVE="1")

    def test_live_cap_zero_blocks_launch_and_confirmed_start_accounts(self):
        script = os.path.join(HERE, "go-slot.sh")
        home, env = self.live_fixture(0, True)
        blocked = subprocess.run(["bash", script, "spawn", "dos-go-test", "/project"], env=env,
                                 text=True, capture_output=True, timeout=20)
        self.assertNotEqual(blocked.returncode, 0)
        self.assertFalse(os.path.exists(os.path.join(home, "state", "spawn")))
        self.assertTrue(os.path.exists(os.path.join(home, "state", "cancel")))
        home, env = self.live_fixture(1, True)
        started = subprocess.run(["bash", script, "spawn", "dos-go-test", "/project"], env=env,
                                 text=True, capture_output=True, timeout=20)
        self.assertEqual(started.returncode, 0, started.stdout + started.stderr)
        self.assertTrue(os.path.exists(os.path.join(home, "state", "spawn")))
        self.assertTrue(os.path.exists(os.path.join(home, "state", "account")))

    def test_live_timeout_without_endpoint_is_ambiguous_and_keeps_reservation(self):
        home, env = self.live_fixture(1, True)
        env["SPAWN_RC"] = "124"
        r = subprocess.run(["bash", os.path.join(HERE, "go-slot.sh"), "spawn", "dos-go-test", "/project"],
                           env=env, text=True, capture_output=True, timeout=20)
        self.assertEqual(r.returncode, 124)
        with open(os.path.join(home, "state", "router-event")) as f:
            self.assertEqual(f.read().strip(), "ambiguous")
        self.assertTrue(os.path.exists(os.path.join(home, "data", "go-slot.res", "dos-go-test")))

    def test_same_reuses_and_release_backs_up_reservation(self):
        root = tempfile.mkdtemp(prefix="v31-go-", dir=os.environ.get(
            "ROUTER_TEST_TMP", "/tmp/claude-1000/router-build/.router-v31-testing"))
        home = os.path.join(root, "home")
        bindir = os.path.join(root, "bin")
        for d in (os.path.join(home, "data", "bin"), os.path.join(home, "state"), bindir):
            os.makedirs(d)
        for name in ("router-launch.sh", "refill_lib.py", "refill_lib_v2.py"):
            os.symlink(os.path.join(HERE, name), os.path.join(bindir, name))
        os.symlink(os.path.join(HERE, "refill_lib.py"),
                   os.path.join(home, "data", "bin", "refill_lib.py"))
        os.symlink(os.path.join(HERE, "refill_lib_v2.py"),
                   os.path.join(home, "data", "bin", "refill_lib_v2.py"))
        for name in ("openscale-spend.py", "go-spend.py"):
            with open(os.path.join(home, "data", "bin-placeholder-" + name), "w") as f:
                f.write("")
            with open(os.path.join(bindir, name), "w") as f:
                f.write("#!/usr/bin/env python3\n")
            os.chmod(os.path.join(bindir, name), 0o755)
        # go-slot's legacy spend paths are under FM_HOME/data/bin.
        os.symlink(os.path.join(bindir, "openscale-spend.py"), os.path.join(home, "data", "bin", "openscale-spend.py"))
        os.symlink(os.path.join(bindir, "go-spend.py"), os.path.join(home, "data", "bin", "go-spend.py"))
        env = dict(os.environ, FM_HOME=home, ROUTER_BIN=bindir, GO_CAP="1")
        script = os.path.join(HERE, "go-slot.sh")
        first = subprocess.run(["bash", script, "take", "dos-test", "new"], env=env,
                               text=True, capture_output=True, timeout=20)
        same = subprocess.run(["bash", script, "take", "dos-test", "same"], env=env,
                              text=True, capture_output=True, timeout=20)
        released = subprocess.run(["bash", script, "release", "dos-test"], env=env,
                                  text=True, capture_output=True, timeout=20)
        count = subprocess.run(["bash", script, "count"], env=env,
                               text=True, capture_output=True, timeout=20)
        self.assertEqual(first.stdout.strip(), "go", first.stdout + first.stderr)
        self.assertEqual(same.stdout.strip(), "go", same.stdout + same.stderr)
        self.assertEqual(released.returncode, 0, released.stdout + released.stderr)
        self.assertEqual(count.stdout.strip(), "0", count.stdout + count.stderr)
        res = os.path.join(home, "data", "go-slot.res")
        self.assertFalse(os.path.exists(os.path.join(res, "dos-test")))
        self.assertTrue(any(x.startswith("dos-test.bak-") for x in os.listdir(res)))

    def test_live_spawn_unverified_is_ambiguous_and_keeps_reservation(self):
        root = tempfile.mkdtemp(prefix="v31-go-ambiguous-", dir=os.environ.get(
            "ROUTER_TEST_TMP", "/tmp/claude-1000/router-build/.router-v31-testing"))
        home = os.path.join(root, "home")
        bindir = os.path.join(root, "bin")
        for d in (os.path.join(home, "data", "bin"), os.path.join(home, "state"),
                  os.path.join(home, "bin"), bindir):
            os.makedirs(d)
        os.symlink(os.path.join(HERE, "refill_lib.py"), os.path.join(home, "data", "bin", "refill_lib.py"))
        os.symlink(os.path.join(HERE, "refill_lib_v2.py"), os.path.join(home, "data", "bin", "refill_lib_v2.py"))
        with open(os.path.join(bindir, "router-launch.sh"), "w") as f:
            f.write('router_labels_from_rows(){ printf "[]\\n"; }\nrouter_classify_task(){ echo no; }\n'
                    'router_admit(){ RA_INCARNATION=go-inc; RA_ARGV=(--harness pi --model admitted/model); }\n'
                    'router_prelaunch(){ :; }\nrouter_confirm_verified(){ return 75; }\n'
                    'router_ambiguous(){ echo ambiguous > "$FM_HOME/state/router-event"; '
                    'mkdir -p "$FM_HOME/state/route-launches"; printf \'{"pending":true,"state":"ambiguous"}\\n\' '
                    '> "$FM_HOME/state/route-launches/$1.json"; }\n'
                    'router_failure(){ echo failure > "$FM_HOME/state/router-event"; }\n'
                    'router_cancel(){ :; }\nrouter_check(){ :; }\n')
        with open(os.path.join(bindir, "refill_lib_v2.py"), "w") as f:
            f.write('#!/usr/bin/env python3\nimport re,sys\nAGENT=re.compile(r"agent-never")\n'
                    'def is_working(*a): return False\n'
                    'if __name__ == "__main__" and len(sys.argv)>1:\n'
                    ' print("1\\tok") if sys.argv[1] == "can-start" else None\n')
        os.chmod(os.path.join(bindir, "refill_lib_v2.py"), 0o755)
        os.symlink(os.path.join(HERE, "refill_lib.py"), os.path.join(bindir, "refill_lib.py"))
        for name in ("openscale-spend.py", "go-spend.py"):
            path = os.path.join(home, "data", "bin", name)
            with open(path, "w") as f:
                f.write("#!/usr/bin/env python3\n")
            os.chmod(path, 0o755)
        with open(os.path.join(home, "bin", "fm-spawn.sh"), "w") as f:
            f.write('#!/usr/bin/env bash\necho "window=maybe-live"\n')
        os.chmod(os.path.join(home, "bin", "fm-spawn.sh"), 0o755)
        os.makedirs(os.path.join(home, "data", "dos-go-test"))
        with open(os.path.join(home, "data", "dos-go-test", "brief.md"), "w") as f:
            f.write("plain task\n")
        env = dict(os.environ, FM_HOME=home, ROUTER_BIN=bindir, GO_CAP="1", ROUTER_LIVE="1")
        r = subprocess.run(["bash", os.path.join(HERE, "go-slot.sh"), "spawn", "dos-go-test", "/project"],
                           env=env, text=True, capture_output=True, timeout=20)
        self.assertNotEqual(r.returncode, 0)
        with open(os.path.join(home, "state", "router-event")) as f:
            self.assertEqual(f.read().strip(), "ambiguous")
        self.assertTrue(os.path.exists(os.path.join(home, "data", "go-slot.res", "dos-go-test")),
                        "maybe-live spawn must retain the reservation")
        with open(os.path.join(home, "state", "route-launches", "dos-go-test.json")) as f:
            sidecar = json.load(f)
        self.assertEqual(sidecar, {"pending": True, "state": "ambiguous"})


class PickupRuntime(unittest.TestCase):
    def test_admitted_tuple_mismatch_refuses_before_transport(self):
        root = tempfile.mkdtemp(prefix="v31-pickup-mismatch-", dir=os.environ.get(
            "ROUTER_TEST_TMP", "/tmp/claude-1000/router-build/.router-v31-testing"))
        home = os.path.join(root, "home")
        os.makedirs(os.path.join(home, "data")); os.makedirs(os.path.join(home, "config"))
        fleet = ("models:\n  remote: {id: provider/model, family: safe, billing: flat}\n"
                 "bindings:\n  remote@pi: {model: remote, provider: provider, harness: pi, effort: high}\n"
                 "roles:\n  build: {models: [remote@pi]}\npools: {}\nbans: []\n")
        with open(os.path.join(home, "config", "fleet.yaml"), "w") as f:
            f.write(fleet)
        sender = os.path.join(root, "sender.sh")
        with open(sender, "w") as f:
            f.write('#!/usr/bin/env bash\necho called > "$FM_HOME/state-called"\n')
        os.chmod(sender, 0o755)
        env = dict(os.environ, FM_HOME=home, ROUTER_BIN=HERE,
                   FLEET_YAML=os.path.join(home, "config", "fleet.yaml"), BOSGAME_SM_SEND=sender,
                   BG_ADMIT_HARNESS="opencode", BG_ADMIT_MODEL="wrong/model",
                   BG_ADMIT_PROVIDER="provider", BG_ADMIT_EFFORT="high")
        cmd = ["bash", os.path.join(HERE, "cloud-pickup-send.sh"), "9.9.9", "claude/branch",
               "--binding", "remote@pi", "--incarnation", "fixture-inc"]
        r = subprocess.run(cmd, env=env, text=True, capture_output=True, timeout=20)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("binding no longer matches admitted tuple", r.stdout + r.stderr)
        self.assertFalse(os.path.exists(os.path.join(home, "state-called")))

    def test_positive_acknowledgment_delivers_without_receipt_reconciliation(self):
        root = tempfile.mkdtemp(prefix="v31-pickup-", dir=os.environ.get(
            "ROUTER_TEST_TMP", "/tmp/claude-1000/router-build/.router-v31-testing"))
        home = os.path.join(root, "home")
        os.makedirs(os.path.join(home, "data"))
        os.makedirs(os.path.join(home, "config"))
        fleet = ("models:\n  remote: {id: provider/model, family: safe, billing: flat}\n"
                 "bindings:\n  remote@pi: {model: remote, provider: provider, harness: pi, effort: high}\n"
                 "roles:\n  build: {models: [remote@pi]}\npools: {}\nbans: []\n")
        with open(os.path.join(home, "config", "fleet.yaml"), "w") as f:
            f.write(fleet)
        candidates = os.path.join(root, "candidates.json")
        with open(candidates, "w") as f:
            json.dump([{"suf": "9.9.9", "body": "plain"}], f)
        sender = os.path.join(root, "sender.sh")
        with open(sender, "w") as f:
            f.write('#!/usr/bin/env bash\necho "sent: queued"\necho x >> "$SEND_CALLS"\n')
        os.chmod(sender, 0o755)
        calls = os.path.join(root, "calls")
        env = dict(os.environ, FM_HOME=home, ROUTER_BIN=HERE,
                   FLEET_YAML=os.path.join(home, "config", "fleet.yaml"),
                   BOSGAME_CANDIDATES=candidates, BOSGAME_SM_SEND=sender,
                   SEND_CALLS=calls)
        cmd = ["bash", os.path.join(HERE, "cloud-pickup-send.sh"), "9.9.9", "claude/branch",
               "--binding", "remote@pi", "--incarnation", "fixture-inc"]
        first = subprocess.run(cmd, env=env, text=True, capture_output=True, timeout=20)
        second = subprocess.run(cmd, env=env, text=True, capture_output=True, timeout=20)
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        self.assertIn("sent dos-bosgame-cloud-9-9-9-1001", first.stdout + first.stderr)
        self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
        self.assertEqual(open(calls).read().splitlines(), ["x", "x"])
        self.assertTrue(os.path.exists(os.path.join(
            home, "data", "dos-bosgame-cloud-9-9-9-1001", "attempt-seq")))
        self.assertFalse(os.path.exists(os.path.join(
            home, "data", "dos-bosgame-cloud-9-9-9-1001", "reconcile-required.txt")))
        self.assertIn("\tsent\t", open(os.path.join(home, "data", "bosgame-lanes.tsv")).read())


if __name__ == "__main__":
    unittest.main()
