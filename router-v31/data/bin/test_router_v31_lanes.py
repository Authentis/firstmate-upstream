#!/usr/bin/env python3
"""Router v3.1 lane integration tripwires.

These tests deliberately inspect/extract the production shell.  Running the complete
refill script would contact the tracker and bosgame; fixtures must never do that.
"""
import os
import re
import subprocess
import tempfile
import time
import unittest


ROOT = os.path.dirname(__file__)
LANE = os.path.join(ROOT, "lane-refill-v2.sh")
with open(LANE) as source_file:
    SRC = source_file.read()


def block(start, end):
    a = SRC.index(start)
    return SRC[a:SRC.index(end, a)]


def function(name):
    match = re.search(r"^%s\(\) \{" % re.escape(name), SRC, re.M)
    if not match:
        raise AssertionError("missing shell function %s" % name)
    lines = SRC[match.start():].splitlines(True)
    depth = 0
    out = []
    for line in lines:
        out.append(line)
        depth += line.count("{") - line.count("}")
        if depth == 0:
            break
    return "".join(out)


class LaneEntrypoint(unittest.TestCase):
    def test_paths_are_fixture_safe_and_bundle_pinned(self):
        head = SRC[:SRC.index("leaf_task_id()")]
        self.assertIn('H=${FM_HOME:-/home/holu/fm-secondmate-upstream-20260907}', head)
        self.assertIn('B=${ROUTER_BIN:-$H/data/bin}', head)
        self.assertIn('W=${ROUTER_WORKDIR:-', SRC[:SRC.index("CLONE=")])
        self.assertIn('PROJECT=${ROUTER_PROJECT_DIR:-/home/holu/decision-os}', SRC)
        self.assertIn('source "$B/router-launch.sh"', head)
        self.assertIn('router_global_off && exit 0', head)

    def test_no_live_v31_path_is_deferred(self):
        self.assertNotIn("deferred to v3.1 (not routed)", SRC)
        for old in ("router_defer start-first", "router_defer resume", "router_defer priority",
                    "router_defer planning", "router_defer bosgame-planning",
                    "router_defer go-relaunch", "router_defer closure-cloud"):
            self.assertNotIn(old, SRC)
        self.assertIn("ROUTER_LIVE=${ROUTER_LIVE:-1}", SRC)


class AdmissionApplication(unittest.TestCase):
    def test_route_leaf_is_a_thin_shared_seam_wrapper(self):
        body = function("route_leaf")
        self.assertIn("router_admit", body)
        self.assertIn('ROUTE_ARGV=("${RA_ARGV[@]}")', body)
        self.assertNotIn("route-pick", body)
        self.assertNotIn("opencode models", body)

    def test_start_first_and_resume_apply_admitted_array(self):
        start = block('# 3-pre0.', '# 3-pre. SO-16 resume')
        resume = block('# 3-pre. SO-16 resume', '# chief 1739: failed starts')
        for text, kind in ((start, "start-first"), (resume, "resume")):
            self.assertIn('route_leaf netcup', text)
            self.assertIn(kind, text)
        self.assertIn('spawn_routed "$pid"', start)
        self.assertIn('relaunch_routed "$id"', resume)
        self.assertIn('[ "$ROUTER_LIVE" = 0 ]', start)
        self.assertIn('[ "$ROUTER_LIVE" = 0 ]', resume)
        self.assertIn("ds_route", start)
        self.assertIn("ds_route", resume)

    def test_priority_plan_and_scout_never_overwrite_selected_tuple(self):
        text = block('# 3a. priority lanes:', 'done < "$H/data/bin/priority-lanes.txt"')
        self.assertIn('route_leaf netcup "$pid"', text)
        self.assertIn('"${ROUTE_ARGV[@]}"', text)
        self.assertIn("$PLAN_ROUTE", text)
        self.assertIn("$SOL_HIGH", text)
        self.assertIn("ds_route", text)
        self.assertIn('kind" = scout', text)

    def test_netcup_planning_applies_exact_admitted_tuple(self):
        text = block('# 3b. planning runs', "# 3b'. no netcup room")
        self.assertIn('router-planning.sh', text)
        with open(os.path.join(ROOT, 'router-planning.sh')) as helper:
            source = helper.read()
        self.assertIn('route_leaf netcup "$task" "$live" plan plan sol-plan@pi', source)
        self.assertIn('"${ROUTE_ARGV[@]}"', source)

    def test_live_go_checks_existing_binding_without_rotation(self):
        text = block('# ---------------------------------------------------------------- 2. GO', '# 3-pre0.')
        self.assertIn('route_existing_binding', text)
        self.assertIn('route_leaf netcup "$id"', text)
        self.assertIn("relaunch_routed", text)
        check = function("route_existing_binding")
        self.assertIn("router_check", check)
        self.assertNotIn("router_admit", check)

    def test_ordinary_build_uses_admitted_array(self):
        text = block('# 3c. leaves:', '# ---------------------------------------------------------------- 4. LAND')
        self.assertIn('route_leaf netcup "$id"', text)
        self.assertIn('spawn_routed "$id" "$PROJECT" $NM "${ROUTE_ARGV[@]}"', text)
        self.assertNotIn('HX="$ROUTE_ARGS"', text)


class ReceiptsAndQueues(unittest.TestCase):
    def test_spawn_verification_confirms_before_count(self):
        body = function("spawn_routed")
        self.assertIn("spawn_retry", body)
        self.assertIn("router_confirm_verified", body)
        self.assertIn('router_confirm_verified "$task_" "$out_"', body)
        self.assertLess(body.index("router_confirm_verified"), body.index("one_start"))
        self.assertIn("router_failure", body)

    def test_closure_and_cloud_are_split_and_count_receipts(self):
        tail = SRC[SRC.index('# ---------------------------------------------------------------- 4. LAND'):]
        self.assertIn('run_routed_helper closure', tail)
        self.assertIn('run_routed_helper cloud', tail)
        self.assertNotIn('router_defer closure-cloud', tail)

    def test_failed_or_waiting_admission_cannot_remove_queues(self):
        start = block('# 3-pre0.', '# 3-pre. SO-16 resume')
        resume = block('# 3-pre. SO-16 resume', '# chief 1739: failed starts')
        self.assertLess(start.index("route_leaf"), start.index('sed -i'))
        self.assertLess(resume.index("route_leaf"), resume.index('sed -i'))
        self.assertIn("spawn_routed", start)
        self.assertIn("relaunch_routed", resume)


class LaneRuntime(unittest.TestCase):
    """Execute the extracted shared path with every external action stubbed."""

    def run_case(self, kind, admit="ok", launch="ok", account="ok", dry="0", live="1"):
        stamp = "%s-%s-%s-%s-%s-%s" % (kind, admit, launch, account, dry, time.time_ns())
        fixture = os.path.join(os.path.dirname(os.path.dirname(ROOT)), ".router-v31-testing", "lane-" + stamp)
        os.makedirs(fixture, exist_ok=True)
        queue = os.path.join(fixture, "queue")
        with open(queue, "w") as f:
            f.write("task\n")
        script = os.path.join(fixture, "case.sh")
        body = r'''set -u
DRY=$DRY_CASE
ROUTER_LIVE=$LIVE_CASE
H=$FIXTURE
B=$FIXTURE
RA_REASON=
RA_BINDING=
RA_HARNESS=
RA_MODEL=
RA_PROVIDER=
RA_EFFORT=
RA_INCARNATION=
RA_ARGV=()
say() { :; }
dlog() { :; }
router_admit() {
  printf '%s\n' "$*" >> "$FIXTURE/admit.log"
  [ "$ADMIT_CASE" = ok ] || { RA_REASON=$ADMIT_CASE; return 75; }
  RA_BINDING=chosen@pi; RA_REASON=chosen; RA_HARNESS=pi
  RA_MODEL=gpt-6.1-sol; RA_PROVIDER=openai-codex; RA_EFFORT=high; RA_INCARNATION=inc1
  RA_ARGV=(--harness pi --model openai-codex/gpt-6.1-sol --effort high)
}
router_prelaunch() { [ "$LAUNCH_CASE" != hold ]; }
router_cancel() { printf 'cancel\n' >> "$FIXTURE/events"; }
spawn_retry() {
  printf '%s\n' "$*" > "$FIXTURE/argv"
  [ "$LAUNCH_CASE" != fail ] || { printf 'quota exceeded: 429 usage limit\n'; return 9; }
  [ "$LAUNCH_CASE" != nonfunds ] || { printf 'weekly quota exceeded; balance available\n'; return 1; }
  [ "$LAUNCH_CASE" != id402 ] || { printf 'failed task id=job-402-retry\n'; return 1; }
  [ "$LAUNCH_CASE" != failendpoint ] || { printf 'timeout endpoint=real-pane\n'; return 124; }
  [ "$LAUNCH_CASE" != timeout ] || return 124
  printf 'spawned task harness=pi window=real-pane worktree=/fixture\n'
}
router_confirm_verified() {
  [ "$LAUNCH_CASE" != noendpoint ]
}
router_ambiguous() { printf 'ambiguous:%s\n' "$*" >> "$FIXTURE/events"; }
router_failure() { printf 'failure:%s\n' "$*" >> "$FIXTURE/events"; }
one_start() { [ "$ACCOUNT_CASE" = ok ] && printf 'count\n' >> "$FIXTURE/events"; }
''' + function("route_leaf") + function("spawn_routed") + r'''
if route_leaf netcup task yes build "$KIND_CASE" && \
   { [ "$DRY" = 1 ] || spawn_routed task /project --flag scout "${ROUTE_ARGV[@]}"; }; then
  if [ "$DRY" = 0 ]; then sed -i '/^task$/d' "$QUEUE"; fi
fi
'''
        with open(script, "w") as f:
            f.write(body)
        env = dict(os.environ, FIXTURE=fixture, QUEUE=queue, KIND_CASE=kind,
                   ADMIT_CASE=admit, LAUNCH_CASE=launch, ACCOUNT_CASE=account,
                   DRY_CASE=dry, LIVE_CASE=live)
        result = subprocess.run(["bash", script], text=True, capture_output=True, env=env)
        with open(queue) as f:
            queued = bool(f.read().strip())
        return result, fixture, queued

    def test_all_launch_kinds_apply_selected_tuple_in_both_live_modes(self):
        for kind in ("plan", "resume", "go", "priority", "start-first", "build"):
            for live in ("0", "1"):
                result, fixture, queued = self.run_case(kind, live=live)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertFalse(queued, (kind, live))
                with open(os.path.join(fixture, "argv")) as argv_file:
                    argv = argv_file.read()
                self.assertIn("--harness pi --model openai-codex/gpt-6.1-sol --effort high", argv)

    def test_wait_hold_launch_failure_endpoint_failure_and_account_failure_retain_queue(self):
        cases = (("catalog WAIT", "ok", "ok"), ("ok", "hold", "ok"),
                 ("ok", "fail", "ok"), ("ok", "noendpoint", "ok"),
                 ("ok", "ok", "fail"))
        for admit, launch, account in cases:
            result, _, queued = self.run_case("build", admit, launch, account)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(queued, (admit, launch, account))

    def test_failure_classification_keeps_quota_and_ambiguous_endpoint_distinct(self):
        _, quota_fixture, _ = self.run_case("build", launch="fail")
        with open(os.path.join(quota_fixture, "events")) as events:
            self.assertIn(" 429 rate_limit", events.read())
        _, endpoint_fixture, _ = self.run_case("build", launch="failendpoint")
        with open(os.path.join(endpoint_fixture, "events")) as events:
            value = events.read()
        self.assertIn("ambiguous:", value)
        self.assertNotIn("failure:", value)

    def test_available_balance_text_is_not_canonicalized_as_funds_402(self):
        _, fixture, queued = self.run_case("build", launch="nonfunds")
        self.assertTrue(queued)
        with open(os.path.join(fixture, "events")) as events:
            value = events.read()
        self.assertIn(" 1 launcher_error weekly quota exceeded; balance available", value)
        self.assertNotIn(" 402 ", value)
        _, id_fixture, _ = self.run_case("build", launch="id402")
        with open(os.path.join(id_fixture, "events")) as events:
            id_value = events.read()
        self.assertIn(" 1 launcher_error failed task id=job-402-retry", id_value)
        self.assertNotIn(" 402 funds_402", id_value)

    def test_spawn_timeout_without_endpoint_is_ambiguous_and_retains_queue(self):
        _, fixture, queued = self.run_case("build", launch="timeout")
        self.assertTrue(queued)
        with open(os.path.join(fixture, "events")) as events:
            value = events.read()
        self.assertIn("ambiguous:task unverified-inc1", value)
        self.assertNotIn("failure:", value)
        self.assertNotIn("count", value)

    def test_relaunch_timeout_without_endpoint_is_ambiguous(self):
        fixture = os.path.join(os.path.dirname(os.path.dirname(ROOT)), ".router-v31-testing",
                               "relaunch-timeout-%s" % time.time_ns())
        os.makedirs(os.path.join(fixture, "bin"), exist_ok=True)
        control = os.path.join(fixture, "bin", "fm-control.sh")
        with open(control, "w") as stub:
            stub.write("#!/usr/bin/env bash\nexit 124\n")
        os.chmod(control, 0o755)
        script = os.path.join(fixture, "case.sh")
        body = r'''set -u
H=$FIXTURE; ROUTE_ARGV=(--harness pi --model openai-codex/gpt-6.1-sol); RA_INCARNATION=inc-timeout
say() { :; }; router_prelaunch() { :; }; router_cancel() { printf 'cancel\n' >> "$FIXTURE/events"; }
router_confirm_verified() { return 1; }; one_start() { printf 'count\n' >> "$FIXTURE/events"; }
router_ambiguous() { printf 'ambiguous:%s\n' "$*" >> "$FIXTURE/events"; }
router_failure() { printf 'failure:%s\n' "$*" >> "$FIXTURE/events"; }
''' + function("relaunch_routed") + r'''
relaunch_routed task && exit 9
exit 0
'''
        with open(script, "w") as script_file:
            script_file.write(body)
        result = subprocess.run(["bash", script], text=True, capture_output=True,
                                env=dict(os.environ, FIXTURE=fixture))
        self.assertEqual(result.returncode, 0, result.stderr)
        with open(os.path.join(fixture, "events")) as events:
            value = events.read()
        self.assertIn("ambiguous:task unverified-inc-timeout", value)
        self.assertNotIn("failure:", value)
        self.assertNotIn("count", value)

    def test_dry_run_neither_admits_launches_counts_nor_removes_queue(self):
        result, fixture, queued = self.run_case("priority", dry="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(queued)
        self.assertFalse(os.path.exists(os.path.join(fixture, "admit.log")))
        self.assertFalse(os.path.exists(os.path.join(fixture, "argv")))


class ActualCallsiteRuntime(unittest.TestCase):
    """Run the production start-first loop, with every external boundary stubbed."""

    def run_start_first(self, admit="ok", launch="ok", account="ok", dry="0",
                        live="1", slots="1", free="1"):
        fixture = os.path.join(os.path.dirname(os.path.dirname(ROOT)), ".router-v31-testing",
                               "actual-start-%s-%s-%s-%s-%s-%s" %
                               (admit.replace(" ", "_"), launch, account, dry, live, time.time_ns()))
        os.makedirs(os.path.join(fixture, "data", "task",), exist_ok=True)
        os.makedirs(os.path.join(fixture, "state"), exist_ok=True)
        queue = os.path.join(fixture, "data", "ds-start-first")
        with open(queue, "w") as queue_file:
            queue_file.write("task\n")
        with open(os.path.join(fixture, "data", "task", "brief.md"), "w") as brief:
            brief.write("ordinary offline build\n")
        actual = block('# 3-pre0.', '# 3-pre. SO-16 resume')
        actual = actual[actual.index('for pid in '):]
        script = os.path.join(fixture, "actual.sh")
        body = r'''set -u
H=$FIXTURE; B=$FIXTURE; PROJECT=/project; NM='--mode no-mistakes --yolo off'
DRY=$DRY_CASE; ROUTER_LIVE=$LIVE_CASE; nds=0; DS_CAP=4; sn=$SLOTS_CASE
free=$FREE_CASE; spawned=0; SPAWN_PATH_PREFIX=; RA_REASON=; RA_INCARNATION=inc1
RA_BINDING=; RA_HARNESS=; RA_MODEL=; RA_PROVIDER=; RA_EFFORT=; RA_ARGV=()
say() { :; }; dlog() { :; }; fresh_gate() { sn=$SLOTS_CASE; }
task_live_data() { printf 'no\n'; }
router_admit() {
  printf '%s\n' "$*" >> "$FIXTURE/admit.log"
  [ "$ADMIT_CASE" = ok ] || { RA_REASON=$ADMIT_CASE; return 75; }
  RA_BINDING=chosen@pi; RA_REASON=chosen; RA_HARNESS=pi; RA_MODEL=gpt-6.1-sol
  RA_PROVIDER=openai-codex; RA_EFFORT=high
  RA_ARGV=(--harness pi --model openai-codex/gpt-6.1-sol --effort high)
}
router_prelaunch() { [ "$LAUNCH_CASE" != hold ]; }
router_cancel() { :; }
router_ambiguous() { printf 'ambiguous\n' >> "$FIXTURE/events"; }
spawn_retry() {
  printf '%s\n' "$*" > "$FIXTURE/argv"
  [ "$LAUNCH_CASE" != fail ] || return 9
  : > "$FIXTURE/state/task.meta"
  printf 'spawned window=real-pane\n'
}
router_confirm_verified() { [ "$LAUNCH_CASE" != noendpoint ]; }
router_failure() { :; }
one_start() { [ "$ACCOUNT_CASE" = ok ] && printf 'count\n' >> "$FIXTURE/events"; }
ds_route() { nxt=go; EFF=high; RX=(--harness opencode --model opencode-go/deepseek-v4.1-flash); }
''' + function("route_leaf") + function("spawn_routed") + actual
        with open(script, "w") as script_file:
            script_file.write(body)
        env = dict(os.environ, FIXTURE=fixture, ADMIT_CASE=admit, LAUNCH_CASE=launch,
                   ACCOUNT_CASE=account, DRY_CASE=dry, LIVE_CASE=live,
                   SLOTS_CASE=slots, FREE_CASE=free)
        result = subprocess.run(["bash", script], text=True, capture_output=True, env=env)
        with open(queue) as queue_file:
            queued = bool(queue_file.read().strip())
        return result, fixture, queued

    def test_actual_start_first_success_applies_tuple_and_consumes_queue(self):
        for live in ("0", "1"):
            result, fixture, queued = self.run_start_first(live=live)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(queued)
            with open(os.path.join(fixture, "argv")) as argv_file:
                argv = argv_file.read()
            if live == "1":
                self.assertIn("--harness pi --model openai-codex/gpt-6.1-sol --effort high", argv)
            else:
                self.assertIn("--harness opencode --model opencode-go/deepseek-v4.1-flash --effort high", argv)
                admit_log = os.path.join(fixture, "admit.log")
                self.assertFalse(os.path.exists(admit_log) and open(admit_log).read().strip())

    def test_actual_start_first_wait_hold_fail_ambiguous_account_dry_and_cap_keep_queue(self):
        cases = (
            dict(admit="WAIT"), dict(launch="hold"), dict(launch="fail"),
            dict(launch="noendpoint"), dict(account="fail"), dict(dry="1"),
            dict(slots="0"), dict(free="0"),
        )
        for case in cases:
            result, _, queued = self.run_start_first(**case)
            self.assertEqual(result.returncode, 0, (case, result.stderr))
            self.assertTrue(queued, case)

    def run_priority(self, task="task", kind="scout", admit="ok", account="ok", live="1"):
        fixture = os.path.join(os.path.dirname(os.path.dirname(ROOT)), ".router-v31-testing",
                               "actual-priority-%s-%s-%s-live%s" % (task, kind or "build", account, live))
        os.makedirs(os.path.join(fixture, "data", "bin"), exist_ok=True)
        os.makedirs(os.path.join(fixture, "data", "task"), exist_ok=True)
        os.makedirs(os.path.join(fixture, "state"), exist_ok=True)
        os.makedirs(os.path.join(fixture, "bin"), exist_ok=True)
        with open(os.path.join(fixture, "data", "bin", "priority-lanes.txt"), "w") as queue:
            queue.write("%s %s\n" % (task, kind))
        os.makedirs(os.path.join(fixture, "data", task), exist_ok=True)
        with open(os.path.join(fixture, "data", task, "brief.md"), "w") as brief:
            brief.write("read only offline research\n")
        task_cli = os.path.join(fixture, "bin", "fm-tasks-axi.sh")
        with open(task_cli, "w") as cli:
            cli.write("#!/usr/bin/env bash\nexit 0\n")
        os.chmod(task_cli, 0o755)
        actual = block('# 3a. priority lanes:', 'done < "$H/data/bin/priority-lanes.txt"')
        actual = actual[actual.index('while read -r pid kind; do'):]
        script = os.path.join(fixture, "actual-priority.sh")
        body = r'''set -u
H=$FIXTURE; B=$FIXTURE; PROJECT=/project; NM='--mode no-mistakes --yolo off'
DRY=0; ROUTER_LIVE=$LIVE_CASE; free=1; spawned=0; attempts=0; PLANWANT=0; pfree=1; sn=1; nds=0; DS_CAP=4
PLAN_ROUTE='--harness pi --model xai/grok-4.7 --effort high'; SOL_SCOUT='--harness codex --model gpt-6.1-sol --effort medium'; SOL_XHIGH='--harness codex --model gpt-6.1-sol --effort xhigh'; SOL_HIGH='--harness codex --model gpt-6.1-sol --effort high'
SPAWN_PATH_PREFIX=; RA_REASON=; RA_INCARNATION=inc1; RA_BINDING=; RA_ARGV=()
say() { :; }; dlog() { :; }; fresh_gate() { sn=1; }; task_live_data() { printf 'no\n'; }
router_admit() { printf '%s\n' "$*" > "$FIXTURE/admit.log"; [ "$ADMIT_CASE" = ok ] || { RA_REASON=WAIT; return 75; }; RA_BINDING=chosen@pi; RA_REASON=chosen; RA_HARNESS=pi; RA_MODEL=gpt-6.1-sol; RA_PROVIDER=openai-codex; RA_EFFORT=high; RA_ARGV=(--harness pi --model openai-codex/gpt-6.1-sol --effort high); }
router_prelaunch() { :; }; router_cancel() { :; }; router_ambiguous() { :; }
spawn_retry() { printf '%s\n' "$*" > "$FIXTURE/argv"; : > "$FIXTURE/state/$1.meta"; printf 'spawned window=real-pane\n'; }
ds_route() { nxt=go; EFF=high; RX=(--harness opencode --model opencode-go/deepseek-v4.1-flash); }
router_confirm_verified() { :; }; router_failure() { :; }; one_start() { [ "$ACCOUNT_CASE" = ok ] && printf 'count\n' >> "$FIXTURE/events"; }
''' + function("route_leaf") + function("spawn_routed") + actual + '\ndone < "$H/data/bin/priority-lanes.txt"\n'
        with open(script, "w") as script_file:
            script_file.write(body)
        result = subprocess.run(["bash", script], text=True, capture_output=True,
                                env=dict(os.environ, FIXTURE=fixture, ADMIT_CASE=admit,
                                         ACCOUNT_CASE=account, LIVE_CASE=live))
        return result, fixture

    def test_actual_priority_build_plan_and_scout_apply_role_flags_and_tuple(self):
        for task, kind, role, flag in (("task", "", "build", "--mode no-mistakes"),
                                        ("dos-planning42", "", "plan", "--mode no-mistakes"),
                                        ("task-scout", "scout", "build", "--scout")):
            result, fixture = self.run_priority(task, kind)
            self.assertEqual(result.returncode, 0, result.stderr)
            with open(os.path.join(fixture, "argv")) as argv_file:
                argv = argv_file.read()
            self.assertIn(flag, argv)
            self.assertIn("--harness pi --model openai-codex/gpt-6.1-sol --effort high", argv)
            with open(os.path.join(fixture, "admit.log")) as admit_file:
                self.assertIn(" priority %s" % role, " " + admit_file.read())

    def test_actual_priority_wait_and_account_failure_do_not_increment_success(self):
        for kwargs in (dict(admit="WAIT"), dict(account="fail")):
            result, fixture = self.run_priority(**kwargs)
            self.assertEqual(result.returncode, 0, result.stderr)
            events = os.path.join(fixture, "events")
            self.assertFalse(os.path.exists(events) and open(events).read().strip(), kwargs)

    def test_actual_priority_live_zero_preserves_legacy_routes(self):
        for task, kind, expected in (("dos-planning42", "", "xai/grok-4.7"),
                                     ("task-scout", "scout", "--scout --harness codex"),
                                     ("task-x", "xhigh", "--effort xhigh"),
                                     ("task-c", "codex", "--effort high"),
                                     ("task-build", "", "opencode-go/deepseek-v4.1-flash")):
            result, fixture = self.run_priority(task, kind, live="0")
            self.assertEqual(result.returncode, 0, result.stderr)
            with open(os.path.join(fixture, "argv")) as argv_file:
                self.assertIn(expected, argv_file.read())

    def run_resume(self, admit="ok", account="ok", live="1", sidecar="confirmed", dry="0"):
        fixture = os.path.join(os.path.dirname(os.path.dirname(ROOT)), ".router-v31-testing",
                               "actual-resume-%s-%s-live%s-%s-%s" %
                               (admit, account, live, sidecar, time.time_ns()))
        os.makedirs(os.path.join(fixture, "data"), exist_ok=True)
        os.makedirs(os.path.join(fixture, "state"), exist_ok=True)
        os.makedirs(os.path.join(fixture, "state", "route-launches"), exist_ok=True)
        os.makedirs(os.path.join(fixture, "bin"), exist_ok=True)
        worktree = os.path.join(fixture, "worktree"); os.makedirs(worktree, exist_ok=True)
        with open(os.path.join(fixture, "data", "ds-resume-queue"), "w") as queue:
            queue.write("task\n")
        with open(os.path.join(fixture, "state", "task.meta"), "w") as meta:
            meta.write("worktree=%s\nharness=opencode\n" % worktree)
        with open(os.path.join(fixture, "state", "task.status"), "w") as status:
            status.write("paused\n")
        with open(os.path.join(fixture, "state", "route-launches", "task.json"), "w") as route:
            route.write('{"state":"%s","incarnation":"inc-old"}\n' % sidecar)
        for name, content in (("fm-crew-state.sh", "#!/usr/bin/env bash\necho 'state: ended'\n"),
                              ("fm-control.sh", "#!/usr/bin/env bash\nprintf '%s\\n' \"$*\" > \"$(dirname \"$0\")/../argv\"\nprintf 'relaunched endpoint=real-pane\\n'\n")):
            path = os.path.join(fixture, "bin", name)
            with open(path, "w") as stub: stub.write(content)
            os.chmod(path, 0o755)
        actual = block('# 3-pre. SO-16 resume', '# chief 1739: failed starts')
        actual = actual[actual.index('for m in '):]
        script = os.path.join(fixture, "actual-resume.sh")
        body = r'''set -u
H=$FIXTURE; B=$FIXTURE; PROJECT=/project; DRY=$DRY_CASE; ROUTER_LIVE=$LIVE_CASE; nds=0; DS_CAP=4; EFF=high; nxt=go; RX=()
sn=1; free=1; spawned=0; ROUTE_ARGV=(); RA_REASON=; RA_INCARNATION=inc1; RA_ARGV=()
say() { :; }; dlog() { :; }; fresh_gate() { sn=1; }; task_live_data() { printf 'no\n'; }
router_admit() { printf 'admit\n' >> "$FIXTURE/events"; { [ "$SIDECAR_CASE" != ambiguous ] && [ "$ADMIT_CASE" = ok ]; } || { RA_REASON=WAIT; return 75; }; RA_BINDING=chosen@pi; RA_REASON=chosen; RA_HARNESS=pi; RA_MODEL=gpt-6.1-sol; RA_PROVIDER=openai-codex; RA_EFFORT=high; RA_ARGV=(--harness pi --model openai-codex/gpt-6.1-sol --effort high); }
router_prelaunch() { :; }; router_cancel() { :; }; router_ambiguous() { :; }
router_confirm_verified() { :; }; router_failure() { :; }
one_start() { [ "$ACCOUNT_CASE" = ok ] && printf 'count\n' >> "$FIXTURE/events"; }
ds_route() { nxt=go; EFF=high; RX=(--harness opencode --model opencode-go/deepseek-v4.1-flash); }
python3() { case " $* " in *' alive '*) printf '0\n';; *' route-cancel '*) printf 'cancel:%s %s\n' "${@: -2}" >> "$FIXTURE/events";; *) command python3 "$@";; esac; }
''' + function("cancel_prior_admission") + function("route_leaf") + function("relaunch_routed") + actual
        with open(script, "w") as script_file: script_file.write(body)
        result = subprocess.run(["bash", script], text=True, capture_output=True,
                                env=dict(os.environ, FIXTURE=fixture, ADMIT_CASE=admit,
                                         ACCOUNT_CASE=account, LIVE_CASE=live,
                                         SIDECAR_CASE=sidecar, DRY_CASE=dry))
        with open(os.path.join(fixture, "data", "ds-resume-queue")) as queue:
            queued = bool(queue.read().strip())
        return result, fixture, queued

    def test_actual_resume_cancels_dead_incarnation_and_removes_only_after_account(self):
        result, fixture, queued = self.run_resume()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(queued)
        with open(os.path.join(fixture, "events")) as events:
            value = events.read()
        self.assertIn("cancel:task inc-old", value)
        self.assertIn("admit", value)
        self.assertIn("count", value)
        for kwargs in (dict(admit="WAIT"), dict(account="fail")):
            result, _, queued = self.run_resume(**kwargs)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(queued, kwargs)

    def test_actual_resume_ambiguous_sidecar_is_not_cancelled_or_relaunched(self):
        result, fixture, queued = self.run_resume(sidecar="ambiguous")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(queued)
        with open(os.path.join(fixture, "events")) as events:
            value = events.read()
        self.assertIn("admit", value)
        self.assertNotIn("cancel:", value)
        self.assertNotIn("count", value)
        self.assertFalse(os.path.exists(os.path.join(fixture, "argv")))

    def test_actual_resume_dry_run_does_not_cancel_confirmed_sidecar(self):
        result, fixture, queued = self.run_resume(dry="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(queued)
        sidecar = os.path.join(fixture, "state", "route-launches", "task.json")
        with open(sidecar) as route:
            self.assertEqual(route.read(), '{"state":"confirmed","incarnation":"inc-old"}\n')
        events_path = os.path.join(fixture, "events")
        self.assertFalse(os.path.exists(events_path) and
                         "cancel:" in open(events_path).read())
        self.assertFalse(os.path.exists(os.path.join(fixture, "argv")))

    def test_actual_resume_live_zero_uses_deepseek_tuple_without_admission(self):
        result, fixture, queued = self.run_resume(live="0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(queued)
        with open(os.path.join(fixture, "argv")) as argv_file:
            argv = argv_file.read()
        self.assertIn("--harness opencode --model opencode-go/deepseek-v4.1-flash", argv)
        self.assertIn("--effort high", argv)
        with open(os.path.join(fixture, "events")) as events:
            self.assertNotIn("cancel-old", events.read())

    def run_plan(self, admit="ok", account="ok", live="1"):
        from test_router_v31_planning_shell import run_plan
        return run_plan(admit=admit, account=account, live=live)

    def test_actual_plan_uses_plan_role_and_counts_only_verified_accounted_start(self):
        result, fixture = self.run_plan()
        self.assertEqual(result.returncode, 0, result.stderr)
        with open(os.path.join(fixture, "admit.log")) as admit_file:
            self.assertIn(" plan plan netcup", " " + admit_file.read())
        with open(os.path.join(fixture, "argv")) as argv_file:
            self.assertIn("--harness pi --model openai-codex/gpt-6.1-sol --effort high",
                          argv_file.read())
        self.assertTrue(os.path.exists(os.path.join(fixture, "events")))
        for kwargs in (dict(admit="WAIT"), dict(account="fail")):
            result, failed_fixture = self.run_plan(**kwargs)
            self.assertEqual(result.returncode, 1 if kwargs.get("account") == "fail" else 0, result.stderr)
            events = os.path.join(failed_fixture, "events")
            self.assertFalse(os.path.exists(events) and open(events).read().strip(), kwargs)

        result, legacy = self.run_plan(live="0")
        self.assertEqual(result.returncode, 0, result.stderr)
        with open(os.path.join(legacy, "argv")) as argv_file:
            self.assertIn("--harness pi --model openai-codex/gpt-6.1-sol --effort high", argv_file.read())

    def test_actual_live_go_checks_binding_without_admit_or_new_receipt(self):
        for live in ("1", "0"):
            self._assert_actual_live_go(live)

    def test_actual_dead_go_keeps_ambiguous_admission_for_reconciliation(self):
        fixture = os.path.join(os.path.dirname(os.path.dirname(ROOT)), ".router-v31-testing",
                               "actual-dead-go-ambiguous-%s" % time.time_ns())
        os.makedirs(os.path.join(fixture, "state", "route-launches"), exist_ok=True)
        with open(os.path.join(fixture, "state", "route-launches", "task.json"), "w") as sidecar:
            sidecar.write('{"state":"ambiguous","incarnation":"inc-old"}\n')
        go = block('# ---------------------------------------------------------------- 2. GO', '# 3-pre0.')
        start = go.index('case $alive in')
        end = go.index('\n    esac\n  else', start) + len('\n    esac')
        actual = go[start:end]
        script = os.path.join(fixture, "actual-dead-go.sh")
        body = r'''set -u
H=$FIXTURE; B=$FIXTURE; W=$FIXTURE; id=task; alive=0; gorole=build; golive=no; ROUTER_LIVE=1
DRY=0; gate=0; at=1; free=1; sn=1; swhy=available; GOTXT=GO; mk=$FIXTURE/go-marker
ROUTE_ARGV=(); RA_ARGV=(); RA_REASON=; RA_INCARNATION=inc-new
say() { :; }; dlog() { :; }; fresh_gate() { sn=1; }; task_live_data() { printf 'no\n'; }
router_admit() { printf 'admit\n' >> "$FIXTURE/events"; RA_REASON=WAIT; return 75; }
python3() { case " $* " in *' route-cancel '*) printf 'cancel:%s %s\n' "${@: -2}" >> "$FIXTURE/events";; *) command python3 "$@";; esac; }
sendgo() { printf 'sent\n' >> "$FIXTURE/events"; : > "$mk"; }
for __once in 1; do
''' + function("cancel_prior_admission") + function("route_leaf") + actual + '\ndone\n'
        with open(script, "w") as script_file:
            script_file.write(body)
        result = subprocess.run(["bash", script], text=True, capture_output=True,
                                env=dict(os.environ, FIXTURE=fixture))
        self.assertEqual(result.returncode, 0, result.stderr)
        with open(os.path.join(fixture, "events")) as events:
            value = events.read()
        self.assertIn("admit", value)
        self.assertNotIn("cancel:", value)
        self.assertNotIn("sent", value)
        self.assertFalse(os.path.exists(os.path.join(fixture, "go-marker")))

    def _assert_actual_live_go(self, live):
        fixture = os.path.join(os.path.dirname(os.path.dirname(ROOT)), ".router-v31-testing",
                               "actual-live-go-%s-%s" % (live, os.getpid()))
        os.makedirs(os.path.join(fixture, "state", "route-launches"), exist_ok=True)
        os.makedirs(os.path.join(fixture, "state"), exist_ok=True)
        with open(os.path.join(fixture, "state", "route-launches", "task.json"), "w") as sidecar:
            sidecar.write('{"binding":"chosen@pi"}\n')
        with open(os.path.join(fixture, "state", "task.meta"), "w") as meta:
            meta.write("model=openai-codex/gpt-6.1-sol\n")
        go = block('# ---------------------------------------------------------------- 2. GO', '# 3-pre0.')
        start = go.index('case $alive in')
        end = go.index('\n    esac\n  else', start) + len('\n    esac')
        actual = go[start:end]
        script = os.path.join(fixture, "actual-go.sh")
        body = r'''set -u
H=$FIXTURE; B=$FIXTURE; W=$FIXTURE; id=task; alive=1; gorole=build; golive=no; ROUTER_LIVE=$LIVE_CASE
DRY=0; gate=0; gokey=; GOTXT=GO; mk=$FIXTURE/go-marker; ROUTE_ARGV=(); RA_ARGV=()
say() { :; }; task_live_data() { printf 'no\n'; }
router_check() { printf '%s\n' "$*" > "$FIXTURE/check.log"; RA_BINDING=chosen@pi; RA_ARGV=(--harness pi --model openai-codex/gpt-6.1-sol); }
router_admit() { printf 'BAD-admit\n' > "$FIXTURE/admit.log"; return 75; }
sendgo() { printf 'sent\n' > "$FIXTURE/send.log"; : > "$mk"; gate=$((gate+1)); }
''' + function("route_existing_binding") + actual
        with open(script, "w") as script_file: script_file.write(body)
        result = subprocess.run(["bash", script], text=True, capture_output=True,
                                env=dict(os.environ, FIXTURE=fixture, LIVE_CASE=live))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(os.path.exists(os.path.join(fixture, "send.log")))
        self.assertFalse(os.path.exists(os.path.join(fixture, "admit.log")))
        self.assertFalse(os.path.exists(os.path.join(fixture, "events")))
        check_log = os.path.join(fixture, "check.log")
        if live == "1":
            with open(check_log) as check_file:
                self.assertIn("task go build netcup no chosen@pi", check_file.read())
        else:
            self.assertFalse(os.path.exists(check_log))


if __name__ == "__main__":
    unittest.main()
