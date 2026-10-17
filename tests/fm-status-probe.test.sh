#!/usr/bin/env bash
# tests/fm-status-probe.test.sh - bin/fm-status-probe.sh against real processes,
# real files, and fake gh and no-mistakes tools that answer from fixture files.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-status-probe)
PROBE="$ROOT/bin/fm-status-probe.sh"

# Sets HOME_DIR FAKE FAKEBIN for one isolated case.
make_case() {  # <name>
  local dir="$TMP_ROOT/$1"
  HOME_DIR="$dir/home"
  FAKE="$dir/fake"
  mkdir -p "$HOME_DIR/state/lanes" "$FAKE"
  FAKEBIN=$(fm_fakebin "$dir")
  cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view")
    f="$FAKE/pr-${3##*/}.json"
    [ -f "$f" ] || exit 1
    cat "$f"
    ;;
  "api repos/o/r") echo main ;;
  "api repos/o/r/compare/"*)
    id=${2#repos/o/r/compare/}
    id=${id%%...*}
    f="$FAKE/compare-$id"
    [ -f "$f" ] || exit 1
    cat "$f"
    ;;
  *) exit 1 ;;
esac
SH
  cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "$1 $2" = "axi status" ] && [ "${3:-}" = "--run" ]; then
  f="$FAKE/nm-run-$4"
  [ -f "$f" ] || exit 1
  cat "$f"
elif [ "$1 $2" = "axi status" ]; then
  cat "$FAKE/nm-list"
else
  exit 1
fi
SH
  chmod +x "$FAKEBIN/gh" "$FAKEBIN/no-mistakes"
  printf 'current_branch: main\nruns[0]{id,branch,status,head,pr}:\n' > "$FAKE/nm-list"
}

run_probe() {  # extra args...
  FAKE=$FAKE PATH="$FAKEBIN:$PATH" "$PROBE" run --home "$HOME_DIR" --stdout "$@"
}

pr_json() {  # <state> <merge-oid-or-empty> <base>
  local mc=null
  [ -z "$2" ] || mc="{\"oid\":\"$2\"}"
  printf '{"state":"%s","headRefOid":"headsha","mergeCommit":%s,"baseRefName":"%s"}\n' "$1" "$mc" "$3"
}

test_merged_requires_a_merge_commit_on_main() {
  local out
  make_case merged
  pr_json MERGED mc1 main > "$FAKE/pr-1.json"
  echo ahead > "$FAKE/compare-mc1"
  pr_json CLOSED "" main > "$FAKE/pr-2.json"
  pr_json MERGED mc3 main > "$FAKE/pr-3.json"
  echo diverged > "$FAKE/compare-mc3"
  pr_json MERGED mc4 release > "$FAKE/pr-4.json"
  echo ahead > "$FAKE/compare-mc4"
  pr_json OPEN "" main > "$FAKE/pr-5.json"
  pr_json MERGED mc6 main > "$FAKE/pr-6.json"
  out=$(run_probe \
    --pr https://github.com/o/r/pull/1 --pr https://github.com/o/r/pull/2 \
    --pr https://github.com/o/r/pull/3 --pr https://github.com/o/r/pull/4 \
    --pr https://github.com/o/r/pull/5 --pr https://github.com/o/r/pull/6) \
    || fail "probe failed: $out"
  assert_equals "true" "$(printf '%s' "$out" | jq -r '.prs[] | select(.url|endswith("/1")) | .merged')" "merge commit reachable from main"
  assert_equals "false" "$(printf '%s' "$out" | jq -r '.prs[] | select(.url|endswith("/2")) | .merged')" "closed-unmerged PR"
  assert_equals "false" "$(printf '%s' "$out" | jq -r '.prs[] | select(.url|endswith("/3")) | .merged')" "merge commit not on main"
  assert_equals "false" "$(printf '%s' "$out" | jq -r '.prs[] | select(.url|endswith("/4")) | .merged')" "merged into a non-default branch"
  assert_equals "false" "$(printf '%s' "$out" | jq -r '.prs[] | select(.url|endswith("/5")) | .merged')" "open PR"
  assert_equals "null" "$(printf '%s' "$out" | jq -r '.prs[] | select(.url|endswith("/6")) | .merged')" "unprovable merge"
  assert_equals "false" "$(printf '%s' "$out" | jq -r '.sources.gh.ok')" "an unprovable PR marks the gh source incomplete"
  assert_equals "mc1" "$(printf '%s' "$out" | jq -r '.prs[] | select(.url|endswith("/1")) | .merge_commit')" "merge commit is recorded"
  pass "merged is true only with a merge commit proven on the default branch; closed-unmerged reads unmerged"
}

test_gate_result_comes_from_the_matching_run() {
  local out
  make_case gate
  pr_json OPEN "" main > "$FAKE/pr-7.json"
  cat > "$FAKE/nm-list" <<'EOF'
current_branch: main
runs[2]{id,branch,status,head,pr}:
  "RUN2",fm/b,completed,abc,"https://github.com/o/r/pull/7"
  "RUN1",fm/a,running,def,""
EOF
  out=$(run_probe --pr https://github.com/o/r/pull/7) || fail "probe failed"
  assert_equals "completed" "$(printf '%s' "$out" | jq -r '.prs[0].gate')" "gate result"
  pass "a PR carries the status of the no-mistakes run that names its url"
}

test_lane_freshness_uses_pid_and_mtime() {
  local out live_pid dead_pid
  make_case lanes
  sleep 30 &
  live_pid=$!
  sleep 0 &
  dead_pid=$!
  wait "$dead_pid"
  : > "$HOME_DIR/state/fresh.log"
  : > "$HOME_DIR/state/old.log"
  touch -t 202001010000 "$HOME_DIR/state/old.log"
  printf 'pid=%s\nlog=%s\n' "$live_pid" "$HOME_DIR/state/fresh.log" > "$HOME_DIR/state/lanes/live-fresh.lane"
  printf 'pid=%s\nlog=%s\n' "$live_pid" "$HOME_DIR/state/old.log" > "$HOME_DIR/state/lanes/live-old.lane"
  printf 'pid=%s\nlog=%s\n' "$dead_pid" "$HOME_DIR/state/fresh.log" > "$HOME_DIR/state/lanes/dead-fresh.lane"
  printf 'log=%s\n' "$HOME_DIR/state/fresh.log" > "$HOME_DIR/state/lanes/nopid.lane"
  printf 'pid=%s\nlog=%s/missing.log\n' "$live_pid" "$HOME_DIR/state" > "$HOME_DIR/state/lanes/nolog.lane"
  printf 'harness=claude\npid=%s\nlog=%s\n' "$live_pid" "$HOME_DIR/state/fresh.log" > "$HOME_DIR/state/task-1.meta"
  out=$(run_probe) || { kill "$live_pid" 2>/dev/null; fail "probe failed"; }
  kill "$live_pid" 2>/dev/null
  wait "$live_pid" 2>/dev/null
  assert_equals "live" "$(printf '%s' "$out" | jq -r '.lanes[] | select(.id=="live-fresh") | .state')" "alive pid with a fresh log"
  assert_equals "stalled" "$(printf '%s' "$out" | jq -r '.lanes[] | select(.id=="live-old") | .state')" "alive pid with a stale log"
  assert_equals "false" "$(printf '%s' "$out" | jq -r '.lanes[] | select(.id=="live-old") | .fresh')" "stale log is not fresh"
  assert_equals "dead" "$(printf '%s' "$out" | jq -r '.lanes[] | select(.id=="dead-fresh") | .state')" "dead pid with a fresh log"
  assert_equals "true" "$(printf '%s' "$out" | jq -r '.lanes[] | select(.id=="dead-fresh") | .fresh')" "the fresh log alone is reported, not trusted"
  assert_equals "dead" "$(printf '%s' "$out" | jq -r '.lanes[] | select(.id=="nopid") | .state')" "no pid"
  assert_equals "stalled" "$(printf '%s' "$out" | jq -r '.lanes[] | select(.id=="nolog") | .state')" "alive pid with no log file"
  assert_equals "null" "$(printf '%s' "$out" | jq -r '.lanes[] | select(.id=="nolog") | .log_age_s')" "missing log has no age"
  assert_equals "live" "$(printf '%s' "$out" | jq -r '.lanes[] | select(.id=="task-1") | .state')" "a task meta carrying pid and log is a lane"
  pass "a lane is live only when its pid is alive and its log mtime is under 5 minutes"
}

test_gate_waits_are_parsed_from_the_run_status() {
  local out
  make_case waits
  cat > "$FAKE/nm-list" <<'EOF'
current_branch: main
runs[2]{id,branch,status,head,pr}:
  "RUNA",fm/a,running,abc,""
  "RUNB",fm/b,running,def,""
  "RUNC",fm/c,completed,fed,""
EOF
  cat > "$FAKE/nm-run-RUNA" <<'EOF'
current_branch: main
other_branch_run:
  id: "RUNA"
  status: running
  awaiting_agent: parked 1h2m
  steps[1]{step,status,findings,duration_ms}:
    ci,awaiting_approval,1,5
gate:
  step: ci
  status: awaiting_approval
  summary: 1 CI checks failing
EOF
  cat > "$FAKE/nm-run-RUNB" <<'EOF'
current_branch: main
other_branch_run:
  id: "RUNB"
  status: running
  steps[1]{step,status,findings,duration_ms}:
    test,running,0,5
EOF
  out=$(run_probe) || fail "probe failed"
  assert_equals "1" "$(printf '%s' "$out" | jq '.gate_waits | length')" "only the run parked at a gate"
  assert_equals "RUNA ci awaiting_approval 3720" \
    "$(printf '%s' "$out" | jq -r '.gate_waits[0] | "\(.run_id) \(.step) \(.gate_status) \(.age_s)"')" "gate wait fields"
  assert_equals "parked 1h2m" "$(printf '%s' "$out" | jq -r '.gate_waits[0].age')" "age text"
  pass "gate waits come from the status of each running run and skip runs not parked at a gate"
}

test_failed_sources_are_reported_not_hidden() {
  local out
  make_case nosrc
  rm -f "$FAKEBIN/no-mistakes"
  out=$(FAKE=$FAKE PATH="$FAKEBIN:/usr/bin:/bin" "$PROBE" run --home "$HOME_DIR" --stdout) || fail "probe failed"
  assert_equals "false" "$(printf '%s' "$out" | jq -r '.sources.no_mistakes.ok')" "missing no-mistakes"
  assert_equals "0" "$(printf '%s' "$out" | jq '.gate_waits | length')" "no gate waits without the source"
  pass "an unavailable source is recorded as not ok instead of reading as an empty section"
}

test_status_json_is_published_atomically() {
  local out
  make_case publish
  FAKE=$FAKE PATH="$FAKEBIN:$PATH" "$PROBE" run --home "$HOME_DIR" || fail "probe failed"
  assert_present "$HOME_DIR/state/status.json" "status.json"
  assert_equals "fm-status-probe.v1" "$(jq -r .schema "$HOME_DIR/state/status.json")" "schema"
  out=$(find "$HOME_DIR/state" -name 'status.json.*')
  assert_equals "" "$out" "no temporary file is left beside status.json"
  pass "a run replaces state/status.json and leaves no temporary file"
}

test_timer_units_name_the_home_and_interval() {
  local out dir="$TMP_ROOT/timer-units"
  make_case timer
  out=$("$PROBE" timer print --home "$HOME_DIR") || fail "timer print failed"
  assert_contains "$out" "$HOME_DIR" "unit names the home"
  case "$out" in
    *StartInterval*) assert_contains "$out" "<integer>300</integer>" "launchd 5-minute interval" ;;
    *) assert_contains "$out" "OnUnitActiveSec=300" "systemd 5-minute interval" ;;
  esac
  mkdir -p "$dir"
  FM_TIMER_DIR=$dir FM_TIMER_NOLOAD=1 "$PROBE" timer install --home "$HOME_DIR" || fail "timer install failed"
  [ -n "$(ls "$dir")" ] || fail "install wrote no unit"
  FM_TIMER_DIR=$dir FM_TIMER_NOLOAD=1 "$PROBE" timer remove --home "$HOME_DIR" || fail "timer remove failed"
  assert_equals "" "$(ls "$dir")" "remove deletes the units"
  pass "the timer is scoped to one home, runs every 5 minutes, and installs and removes cleanly"
}

test_merged_requires_a_merge_commit_on_main
test_gate_result_comes_from_the_matching_run
test_lane_freshness_uses_pid_and_mtime
test_gate_waits_are_parsed_from_the_run_status
test_failed_sources_are_reported_not_hidden
test_status_json_is_published_atomically
test_timer_units_name_the_home_and_interval
