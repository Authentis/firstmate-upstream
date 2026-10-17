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
if [ "$1" = api ]; then
  if [ "$2" = --hostname ]; then
    echo "$3" >> "$FAKE/api-hosts.log"
    set -- api "${@:4}"
  else
    echo NOHOST >> "$FAKE/api-hosts.log"
  fi
fi
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

test_units_run_inside_the_home_and_escape_xml_text() {
  local out
  out=$(bash -c '. "$1"; fm_timer_render launchd lbl 5 "$2" "$3"' _ "$ROOT/bin/fm-periodic-timer-lib.sh" '/h/a&b<c>' '/bin/x&y') \
    || fail "launchd render failed"
  assert_contains "$out" "<key>WorkingDirectory</key><string>/h/a&amp;b&lt;c&gt;</string>" "launchd job runs inside the home"
  assert_contains "$out" "<key>FM_HOME</key><string>/h/a&amp;b&lt;c&gt;</string>" "ampersands and angle brackets are escaped once"
  assert_contains "$out" "<string>/bin/x&amp;y</string>" "an argument is escaped too"
  assert_not_contains "$out" "&amp;amp;" "nothing is escaped twice"
  out=$(bash -c '. "$1"; fm_timer_render systemd lbl 5 "$2" /bin/x' _ "$ROOT/bin/fm-periodic-timer-lib.sh" '/h/with 5%') \
    || fail "systemd render failed"
  assert_contains "$out" "WorkingDirectory=/h/with 5%%" "systemd job runs inside the home, % escaped"
  pass "both unit kinds run inside the home, and the launchd XML escapes & < > exactly once"
}

test_a_run_table_missing_a_required_column_is_not_trusted() {
  local out table
  make_case needcols
  for table in 'runs[1]{id,branch,head,pr}:\n  "RUNA",fm/a,abc,""' \
               'runs[1]{id,branch,status,head}:\n  "RUNA",fm/a,running,abc' \
               'runs[1]{branch,status,head,pr}:\n  fm/a,running,abc,""' \
               'count: 0 of 0 total'; do
    printf 'current_branch: main\n%b\n' "$table" > "$FAKE/nm-list"
    out=$(run_probe) || fail "probe failed"
    assert_equals "false" "$(printf '%s' "$out" | jq -r '.sources.no_mistakes.ok')" "a table without the expected columns is not read as complete: $table"
  done
  pass "a run table without its id, branch, status, and pr columns, or without a table at all, marks the source not ok"
}

test_a_signalled_probe_stops_and_cleans_up() {
  local pid rc=0 scratch="$TMP_ROOT/sigscratch"
  make_case signal
  mkdir -p "$scratch"
  cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
sleep 30
SH
  FAKE=$FAKE TMPDIR=$scratch PATH="$FAKEBIN:$PATH" "$PROBE" run --home "$HOME_DIR" >/dev/null 2>&1 &
  pid=$!
  sleep 1
  kill -0 "$pid" 2>/dev/null || fail "the probe ended before it was signalled"
  kill -TERM "$pid"
  wait "$pid" || rc=$?
  assert_equals "143" "$rc" "a signalled probe exits"
  assert_absent "$HOME_DIR/state/status.json" "a signalled probe publishes nothing"
  assert_equals "" "$(find "$scratch" -mindepth 1 -maxdepth 1)" "its scratch directory is removed"
  pass "a signalled probe exits with the signal status and removes its scratch directory"
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

test_a_merged_pr_without_a_readable_merge_commit_is_unknown() {
  local out
  make_case nomc
  pr_json MERGED "" main > "$FAKE/pr-1.json"
  out=$(run_probe --pr https://github.com/o/r/pull/1) || fail "probe failed"
  assert_equals "null" "$(printf '%s' "$out" | jq -r '.prs[0].merged')" "merged state with no merge commit"
  assert_equals "MERGED" "$(printf '%s' "$out" | jq -r '.prs[0].state')" "the forge's word is still reported"
  assert_equals "false" "$(printf '%s' "$out" | jq -r '.sources.gh.ok')" "the source is incomplete"
  assert_contains "$(printf '%s' "$out" | jq -r '.sources.gh.error')" "pull/1" "the error names the PR"
  pass "a merged PR whose merge commit cannot be read is unknown and marks the forge source incomplete"
}

test_the_forge_host_reaches_every_api_query() {
  local out
  make_case host
  pr_json MERGED mc1 main > "$FAKE/pr-1.json"
  echo ahead > "$FAKE/compare-mc1"
  out=$(run_probe --pr https://git.example.com/o/r/pull/1) || fail "probe failed"
  assert_equals "true" "$(printf '%s' "$out" | jq -r '.prs[0].merged')" "merged on the named host"
  assert_equals "git.example.com git.example.com" "$(tr '\n' ' ' < "$FAKE/api-hosts.log" | sed 's/ $//')" "both api queries carry the host"
  pass "both forge API queries are sent to the PR's own host"
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
runs[3]{id,branch,status,head,pr}:
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

test_one_unreadable_pr_does_not_stop_the_remaining_queries() {
  local out
  make_case partial
  pr_json MERGED mc1 main > "$FAKE/pr-1.json"
  echo ahead > "$FAKE/compare-mc1"
  pr_json MERGED mc3 main > "$FAKE/pr-3.json"
  echo ahead > "$FAKE/compare-mc3"
  out=$(run_probe \
    --pr https://github.com/o/r/pull/1 --pr https://github.com/o/r/pull/2 \
    --pr https://github.com/o/r/pull/3) || fail "probe failed"
  assert_equals "true" "$(printf '%s' "$out" | jq -r '.prs[] | select(.url|endswith("/1")) | .merged')" "PR before the failure"
  assert_equals "null" "$(printf '%s' "$out" | jq -r '.prs[] | select(.url|endswith("/2")) | .merged')" "the unreadable PR"
  assert_equals "true" "$(printf '%s' "$out" | jq -r '.prs[] | select(.url|endswith("/3")) | .merged')" "PR after the failure is still queried"
  assert_equals "mc3" "$(printf '%s' "$out" | jq -r '.prs[] | select(.url|endswith("/3")) | .merge_commit')" "its merge commit is read"
  assert_equals "false" "$(printf '%s' "$out" | jq -r '.sources.gh.ok')" "the source is incomplete"
  assert_contains "$(printf '%s' "$out" | jq -r '.sources.gh.error')" "pull/2" "the error names the unreadable PR"
  pass "one unreadable PR marks the forge source incomplete but every later PR is still queried"
}

test_an_unreadable_running_run_marks_the_source_not_ok() {
  local out
  make_case unread
  cat > "$FAKE/nm-list" <<'EOF'
current_branch: main
runs[2]{id,branch,status,head,pr}:
  "RUNA",fm/a,running,abc,""
  "RUNB",fm/b,running,def,""
EOF
  cat > "$FAKE/nm-run-RUNB" <<'EOF'
current_branch: main
gate:
  step: ci
  status: awaiting_approval
EOF
  out=$(run_probe) || fail "probe failed"
  assert_equals "false" "$(printf '%s' "$out" | jq -r '.sources.no_mistakes.ok')" "a skipped run query is not hidden"
  assert_contains "$(printf '%s' "$out" | jq -r '.sources.no_mistakes.error')" "RUNA" "the error names the unread run"
  assert_equals "RUNB" "$(printf '%s' "$out" | jq -r '.gate_waits[0].run_id')" "the readable run is still reported"
  pass "a running run whose status cannot be read marks the no-mistakes source not ok"
}

write_status() {  # <generated-epoch> [gh-ok] [nm-ok]
  jq -n --argjson g "$1" --argjson gh "${2:-true}" --argjson nm "${3:-true}" \
    '{schema:"fm-status-probe.v1",generated:$g,host:"h",fm_home:"x",
      sources:{gh:{ok:$gh,error:null},no_mistakes:{ok:$nm,error:null}},
      prs:[{url:"u",merged:true,gate:"completed"}],lanes:[{id:"l",state:"live"}],gate_waits:[{run_id:"r"}]}' \
    > "$HOME_DIR/state/status.json"
}

test_read_reports_unknown_on_stale_or_missing_data() {
  local out rc=0 now
  make_case stale
  now=$(date +%s)
  out=$("$PROBE" read --home "$HOME_DIR") || rc=$?
  expect_code 3 "$rc" "no status.json"
  assert_equals "unknown" "$(printf '%s' "$out" | jq -r .verdict)" "missing file verdict"
  assert_equals "unknown" "$(printf '%s' "$out" | jq -r .prs)" "missing file pr section"

  write_status "$((now - 10))"
  out=$("$PROBE" read --home "$HOME_DIR") || fail "a fresh file was refused"
  assert_equals "fresh" "$(printf '%s' "$out" | jq -r .verdict)" "fresh verdict"
  assert_equals "true" "$(printf '%s' "$out" | jq -r '.prs[0].merged')" "fresh values pass through"

  write_status "$((now - 2000))"
  rc=0
  out=$("$PROBE" read --home "$HOME_DIR") || rc=$?
  expect_code 3 "$rc" "stale status.json"
  assert_equals "unknown" "$(printf '%s' "$out" | jq -r .verdict)" "stale verdict"
  assert_equals "unknown unknown unknown" \
    "$(printf '%s' "$out" | jq -r '"\(.prs) \(.lanes) \(.gate_waits)"')" "every section reads unknown on stale data"
  assert_contains "$(printf '%s' "$out" | jq -r .reason)" "limit is 900s" "the reason names the limit"

  rc=0
  out=$("$PROBE" read --home "$HOME_DIR" --max-age 5000) || rc=$?
  expect_code 0 "$rc" "a looser limit accepts the same file"

  write_status "$((now + 5000))"
  rc=0
  "$PROBE" read --home "$HOME_DIR" >/dev/null || rc=$?
  expect_code 3 "$rc" "a timestamp from the future"

  printf 'not json' > "$HOME_DIR/state/status.json"
  rc=0
  out=$("$PROBE" read --home "$HOME_DIR") || rc=$?
  expect_code 3 "$rc" "corrupt file"
  assert_equals "unknown" "$(printf '%s' "$out" | jq -r .verdict)" "corrupt verdict"
  pass "read reports unknown, not the old values, for stale, future, missing, or corrupt status.json"
}

test_read_marks_a_section_unknown_when_its_source_is_not_ok() {
  local out
  make_case srcunknown
  write_status "$(date +%s)" false true
  out=$("$PROBE" read --home "$HOME_DIR") || fail "fresh file was refused"
  assert_equals "unknown" "$(printf '%s' "$out" | jq -r .prs)" "prs without the forge"
  assert_equals "live" "$(printf '%s' "$out" | jq -r '.lanes[0].state')" "lanes do not depend on the forge"
  assert_equals "r" "$(printf '%s' "$out" | jq -r '.gate_waits[0].run_id')" "gate waits still read"
  write_status "$(date +%s)" true false
  out=$("$PROBE" read --home "$HOME_DIR") || fail "fresh file was refused"
  assert_equals "unknown" "$(printf '%s' "$out" | jq -r .gate_waits)" "gate waits without no-mistakes"
  write_status "$(date +%s)" true false
  out=$("$PROBE" read --home "$HOME_DIR") || fail "fresh file was refused"
  assert_equals "unknown" "$(printf '%s' "$out" | jq -r '.prs[0].gate')" "a PR's gate without no-mistakes"
  assert_equals "true" "$(printf '%s' "$out" | jq -r '.prs[0].merged')" "the forge's merged field still reads"
  write_status "$(date +%s)"
  out=$("$PROBE" read --home "$HOME_DIR") || fail "fresh file was refused"
  assert_equals "completed" "$(printf '%s' "$out" | jq -r '.prs[0].gate')" "the gate reads when both sources answered"
  pass "a fresh file still reads unknown for a section whose source did not answer"
}

test_timer_units_carry_a_path_and_are_written_whole() {
  local out dir="$TMP_ROOT/timer-write" rc=0
  out=$(FM_TIMER_PATH=/opt/tools/bin:/usr/bin bash -c '. "$1"; fm_timer_render launchd lbl 5 /h /bin/x' _ "$ROOT/bin/fm-periodic-timer-lib.sh") \
    || fail "launchd render failed"
  assert_contains "$out" "<key>PATH</key><string>/opt/tools/bin:/usr/bin</string>" "launchd job gets a PATH"
  assert_contains "$out" "<key>FM_HOME</key><string>/h</string>" "launchd job keeps FM_HOME"
  out=$(FM_TIMER_PATH=/opt/tools/bin:/usr/bin bash -c '. "$1"; fm_timer_render systemd lbl 5 /h /bin/x' _ "$ROOT/bin/fm-periodic-timer-lib.sh") \
    || fail "systemd render failed"
  assert_contains "$out" 'Environment="PATH=/opt/tools/bin:/usr/bin"' "systemd job gets a PATH"
  # shellcheck disable=SC2016 # "$1" must reach the child shell unexpanded
  out=$(PATH=/custom/bin:/usr/bin "$BASH" -c '. "$1"; fm_timer_render launchd lbl 5 /h /bin/x' _ "$ROOT/bin/fm-periodic-timer-lib.sh") \
    || fail "default render failed"
  assert_contains "$out" "<string>/custom/bin:/usr/bin:/opt/homebrew/bin:" "the installer's PATH comes first"

  make_case timerwrite
  mkdir -p "$dir"
  FM_TIMER_DIR=$dir FM_TIMER_NOLOAD=1 "$PROBE" timer install --home "$HOME_DIR" || fail "install"
  out=$(find "$dir" -type f | head -n1)
  printf 'sentinel\n' > "$out"
  chmod 500 "$dir"
  FM_TIMER_DIR=$dir FM_TIMER_NOLOAD=1 "$PROBE" timer install --home "$HOME_DIR" >/dev/null 2>&1 || rc=$?
  chmod 700 "$dir"
  if [ "$(id -u)" != 0 ]; then
    [ "$rc" -ne 0 ] || fail "an install that could not write reported success"
    assert_equals "sentinel" "$(cat "$out")" "the installed unit is not truncated by a failed write"
  fi
  FM_TIMER_DIR=$dir FM_TIMER_NOLOAD=1 "$PROBE" timer install --home "$HOME_DIR" || fail "reinstall"
  assert_equals "" "$(find "$dir" -name '*.??????' ! -name '*.plist' ! -name '*.service' ! -name '*.timer')" "no temporary unit file remains"
  pass "timer jobs get a PATH, and a unit is written whole or the install fails with the old unit intact"
}

test_systemd_exec_words_are_quoted_for_systemd() {
  local out line
  out=$(bash -c '. "$1"; fm_timer_render systemd lbl 5 "/h/with space" "/bin/x y" "a\"b" "p%q" "\$HOME" "plain"' _ "$ROOT/bin/fm-periodic-timer-lib.sh") \
    || fail "render failed"
  line=$(printf '%s\n' "$out" | sed -n 's/^ExecStart=//p')
  # shellcheck disable=SC2016 # the expected text holds literal $$ for systemd
  assert_equals '"/bin/x y" "a\"b" "p%%q" "$$HOME" "plain" ' "$line" "systemd-quoted ExecStart words"
  assert_contains "$out" 'Environment="FM_HOME=/h/with space"' "quoted environment assignment"
  out=$(bash -c '. "$1"; fm_timer_render systemd lbl 5 "$2" "/bin/a"' _ "$ROOT/bin/fm-periodic-timer-lib.sh" '/h/$x%y') \
    || fail "render failed"
  # shellcheck disable=SC2016 # the expected text holds a literal $
  assert_contains "$out" 'Environment="FM_HOME=/h/$x%%y"' "Environment keeps $ literal and escapes %"
  out=$(bash -c '. "$1"; fm_timer_render systemd lbl 5 /h "$2" "$3"' _ "$ROOT/bin/fm-periodic-timer-lib.sh" '/srv/fm$copy/bin/x' 'a$b') \
    || fail "render failed"
  line=$(printf '%s\n' "$out" | sed -n 's/^ExecStart=//p')
  # shellcheck disable=SC2016 # the expected text holds literal $ for systemd
  assert_equals '"/srv/fm$copy/bin/x" "a$$b" ' "$line" "the executable path keeps its dollar, later arguments double it"
  pass "the systemd unit quotes spaces, quotes, % and \$ the way systemd reads them"
}

test_a_relative_home_is_made_absolute_in_the_unit() {
  local rel abs outrel outabs
  make_case relhome
  abs="$HOME_DIR"
  rel=$(cd "$TMP_ROOT/relhome" && "$PROBE" timer print --home home) || fail "relative print failed"
  abs=$("$PROBE" timer print --home "$abs") || fail "absolute print failed"
  outrel=$rel
  outabs=$abs
  assert_equals "$outabs" "$outrel" "a relative --home renders the same unit as the absolute path"
  assert_contains "$outrel" "$HOME_DIR" "the unit names the absolute home"
  assert_not_contains "$outrel" "--home home" "no relative path reaches the unit"
  pass "a relative --home becomes an absolute path before the label is hashed and the unit rendered"
}

test_run_rows_decode_branches_with_commas_and_quotes() {
  local out
  make_case decode
  cat > "$FAKE/nm-list" <<'EOT'
current_branch: main
runs[2]{id,branch,status,head,pr}:
  "RUNQ","fm/a,b \"x\" \\y",running,abc,"https://github.com/o/r/pull/9"
  "RUNZ",fm/plain,completed,def,""
EOT
  cat > "$FAKE/nm-run-RUNQ" <<'EOT'
current_branch: main
gate:
  step: ci
  status: awaiting_approval
EOT
  pr_json OPEN "" main > "$FAKE/pr-9.json"
  out=$(run_probe --pr https://github.com/o/r/pull/9) || fail "probe failed"
  assert_equals "true" "$(printf '%s' "$out" | jq -r '.sources.no_mistakes.ok')" "the table decoded"
  assert_equals 'fm/a,b "x" \y' "$(printf '%s' "$out" | jq -r '.gate_waits[0].branch')" "the branch is one field, unescaped"
  assert_equals "RUNQ" "$(printf '%s' "$out" | jq -r '.gate_waits[0].run_id')" "its run is not hidden"
  assert_equals "running" "$(printf '%s' "$out" | jq -r '.prs[0].gate')" "the PR column still matches its run"
  pass "a branch name holding a comma, quotes, or a backslash decodes as one field and its run is reported"
}

test_a_run_table_that_cannot_be_decoded_marks_the_source_not_ok() {
  local out table
  make_case baddecode
  for table in 'runs[1]{id,branch,status,head,pr}:\n  "RUNA","fm/open,running,abc,""' \
               'runs[1]{id,branch,status,head,pr}:\n  "RUNA",fm/a,running,abc' \
               'runs[2]{id,branch,status,head,pr}:\n  "RUNA",fm/a,running,abc,""'; do
    printf 'current_branch: main\n%b\n' "$table" > "$FAKE/nm-list"
    out=$(run_probe) || fail "probe failed"
    assert_equals "false" "$(printf '%s' "$out" | jq -r '.sources.no_mistakes.ok')" "an undecodable table is not read as complete"
    assert_contains "$(printf '%s' "$out" | jq -r '.sources.no_mistakes.error')" "decode" "the error says why"
  done
  pass "an unterminated quote, a short row, or a wrong row count marks the no-mistakes source not ok"
}

test_units_run_inside_the_home_and_escape_xml_text
test_a_run_table_missing_a_required_column_is_not_trusted
test_a_signalled_probe_stops_and_cleans_up
test_run_rows_decode_branches_with_commas_and_quotes
test_a_run_table_that_cannot_be_decoded_marks_the_source_not_ok
test_merged_requires_a_merge_commit_on_main
test_a_merged_pr_without_a_readable_merge_commit_is_unknown
test_the_forge_host_reaches_every_api_query
test_one_unreadable_pr_does_not_stop_the_remaining_queries
test_an_unreadable_running_run_marks_the_source_not_ok
test_read_reports_unknown_on_stale_or_missing_data
test_read_marks_a_section_unknown_when_its_source_is_not_ok
test_systemd_exec_words_are_quoted_for_systemd
test_timer_units_carry_a_path_and_are_written_whole
test_a_relative_home_is_made_absolute_in_the_unit
test_gate_result_comes_from_the_matching_run
test_lane_freshness_uses_pid_and_mtime
test_gate_waits_are_parsed_from_the_run_status
test_failed_sources_are_reported_not_hidden
test_status_json_is_published_atomically
test_timer_units_name_the_home_and_interval
