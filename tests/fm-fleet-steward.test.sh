#!/usr/bin/env bash
# Behavioral tests for the durable ready-queue refresh and low-fleet steward.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STEWARD="$ROOT/bin/fm-fleet-steward.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet-steward)

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/config" "$home/data" "$home/state" "$home/project" "$home/systemd"
  printf '%s\n' "$home"
}

write_config() {
  local home=$1
  cat > "$home/config/fleet-steward.json" <<EOF
{
  "schema": "fm-fleet-steward.v1",
  "project_path": "$home/project",
  "repository": "example/decision-os",
  "capacity_log": "$home/capacity.log",
  "exclusions": [
    {"id": "held-row", "kind": "captain", "reason": "awaiting selection"},
    {"id": "deferred-row", "kind": "deferred", "reason": "explicitly deferred"}
  ]
}
EOF
}

make_refresh_tools() {
  local home=$1 bin
  bin="$home/tools"
  mkdir -p "$bin"
  cat > "$bin/br" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_CALLS"
cat "$FM_TEST_BR_JSON"
SH
  cat > "$bin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf 'gh-axi %s\n' "$*" >> "$FM_TEST_CALLS"
[ "${FM_TEST_GH_FAIL:-0}" = 0 ] || exit 1
cat "$FM_TEST_PRS_JSON"
SH
  cat > "$bin/git" <<'SH'
#!/usr/bin/env bash
printf 'git %s\n' "$*" >> "$FM_TEST_CALLS"
case " $* " in
  *' fetch origin main '*) exit 0 ;;
  *' log origin/main '*) cat "$FM_TEST_MAIN_LOG" ;;
  *) exit 2 ;;
esac
SH
  chmod 0755 "$bin/br" "$bin/gh-axi" "$bin/git"
  printf '%s\n' "$bin"
}

write_refresh_fixture() {
  local home=$1
  cat > "$home/br.json" <<'JSON'
[
  {"id":"ready-b","title":"Second safe task","priority":2,"issue_type":"task","status":"open","labels":[]},
  {"id":"ready-a","title":"First safe task","priority":1,"issue_type":"bug","status":"open","labels":["backend"]},
  {"id":"merged","title":"Prefix-safe merged task","priority":3,"issue_type":"task","status":"open","labels":[]},
  {"id":"main","title":"Prefix-safe main task","priority":4,"issue_type":"task","status":"open","labels":[]},
  {"id":"flight","title":"Substring-safe flight task","priority":5,"issue_type":"task","status":"open","labels":[]},
  {"id":"epic-row","title":"Epic","priority":0,"issue_type":"epic","status":"open","labels":[]},
  {"id":"gate-row","title":"Gate","priority":0,"issue_type":"task","status":"open","labels":["gate-operator"]},
  {"id":"label-deferred","title":"Deferred","priority":0,"issue_type":"task","status":"open","labels":["deferred"]},
  {"id":"held-row","title":"Held","priority":0,"issue_type":"task","status":"open","labels":[]},
  {"id":"deferred-row","title":"Deferred by registry","priority":0,"issue_type":"task","status":"open","labels":[]},
  {"id":"merged-row","title":"Already merged","priority":0,"issue_type":"task","status":"open","labels":[]},
  {"id":"main-row","title":"Already on main","priority":0,"issue_type":"task","status":"open","labels":[]},
  {"id":"inflight-row","title":"Already dispatched","priority":0,"issue_type":"task","status":"open","labels":[]}
]
JSON
  cat > "$home/prs.json" <<'EOF'
api_response:
  body: "feat\nfinish\nmerged-row\nfm\n"
  truncated: false
EOF
  printf 'fix: close work\n\nbr:main-row\n' > "$home/main.log"
  cat > "$home/state/inflight-row.meta" <<'EOF'
task=inflight-row
branch=fm/inflight-row-ship
EOF
  : > "$home/calls"
}

run_refresh() {
  local home=$1 tool_dir=$2
  env FM_HOME="$home" PATH="$tool_dir:$PATH" \
    FM_TEST_CALLS="$home/calls" FM_TEST_BR_JSON="$home/br.json" \
    FM_TEST_PRS_JSON="$home/prs.json" FM_TEST_MAIN_LOG="$home/main.log" \
    "$STEWARD" refresh
}

test_refresh_filters_verified_nonwork_and_ranks_survivors() {
  local home tools queue
  home=$(make_home refresh)
  write_config "$home"
  write_refresh_fixture "$home"
  tools=$(make_refresh_tools "$home")

  run_refresh "$home" "$tools" >/dev/null \
    || fail "refresh failed: $(cat "$home/calls")"
  queue=$(cat "$home/data/next-up.md")

  assert_contains "$queue" '# Next up - generated' "generated queue header missing"
  assert_contains "$queue" '- READY ready-a | acceptance: First safe task | preconditions: br ready verified; origin/main and merged pull requests clear' "priority-one survivor missing its acceptance and preconditions"
  assert_contains "$queue" '- READY ready-b | acceptance: Second safe task | preconditions: br ready verified; origin/main and merged pull requests clear' "second survivor missing"
  assert_contains "$queue" '- READY merged | acceptance: Prefix-safe merged task | preconditions: br ready verified; origin/main and merged pull requests clear' "merged prefix was treated as an exact merged id"
  assert_contains "$queue" '- READY main | acceptance: Prefix-safe main task | preconditions: br ready verified; origin/main and merged pull requests clear' "main prefix was treated as an exact landed id"
  assert_contains "$queue" '- READY flight | acceptance: Substring-safe flight task | preconditions: br ready verified; origin/main and merged pull requests clear' "in-flight substring was treated as an exact task id"
  [ "$(grep -n '^- READY' "$home/data/next-up.md" | cut -d: -f2- | paste -sd '|' -)" = \
    '- READY ready-a | acceptance: First safe task | preconditions: br ready verified; origin/main and merged pull requests clear|- READY ready-b | acceptance: Second safe task | preconditions: br ready verified; origin/main and merged pull requests clear|- READY merged | acceptance: Prefix-safe merged task | preconditions: br ready verified; origin/main and merged pull requests clear|- READY main | acceptance: Prefix-safe main task | preconditions: br ready verified; origin/main and merged pull requests clear|- READY flight | acceptance: Substring-safe flight task | preconditions: br ready verified; origin/main and merged pull requests clear' ] \
    || fail "survivors were not ranked by priority then id: $queue"
  for excluded in epic-row gate-row label-deferred held-row deferred-row merged-row main-row inflight-row; do
    assert_not_contains "$queue" "$excluded" "excluded row $excluded survived refresh"
  done
  assert_contains "$(cat "$home/calls")" 'ready --json --no-auto-flush --no-auto-import' "refresh did not use the bounded read-only br ready form"
  assert_contains "$(cat "$home/calls")" 'git -C' "refresh did not verify the project checkout"
  assert_contains "$(cat "$home/calls")" 'fetch origin main' "refresh did not refresh origin/main"
  assert_contains "$(cat "$home/calls")" 'gh-axi api' "refresh did not use gh-axi for merged pull requests"
  assert_not_contains "$(cat "$home/calls")" '--slurp' "refresh passed an unsupported gh-axi flag"
  pass "refresh excludes held, gated, deferred, epic, in-flight, merged, and landed rows"
}

test_refresh_failure_preserves_last_known_good_queue() {
  local home tools before rc=0
  home=$(make_home refresh-fail)
  write_config "$home"
  write_refresh_fixture "$home"
  tools=$(make_refresh_tools "$home")
  printf 'last-known-good\n' > "$home/data/next-up.md"
  before=$(cat "$home/data/next-up.md")

  env FM_HOME="$home" PATH="$tools:$PATH" FM_TEST_GH_FAIL=1 \
    FM_TEST_CALLS="$home/calls" FM_TEST_BR_JSON="$home/br.json" \
    FM_TEST_PRS_JSON="$home/prs.json" FM_TEST_MAIN_LOG="$home/main.log" \
    "$STEWARD" refresh >/dev/null 2>&1 || rc=$?

  [ "$rc" -ne 0 ] || fail "refresh succeeded when merged-PR verification failed"
  [ "$(cat "$home/data/next-up.md")" = "$before" ] || fail "failed refresh replaced the last-known-good queue"
  pass "refresh fails closed without replacing the last-known-good queue"
}

write_capacity() {
  local home=$1 epoch=$2 productive=$3 uncertain=$4 timestamp
  timestamp=$(date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) \
    || timestamp=$(date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ)
  printf '%s lane-reaper: summary: considered=10 reaped=0 refused=0 productive=%s uncertain=%s free=0\n' \
    "$timestamp" "$productive" "$uncertain" > "$home/capacity.log"
}

run_check() {
  local home=$1 now=$2
  FM_HOME="$home" FM_FLEET_STEWARD_NOW="$now" "$STEWARD" check
}

test_refresh_missing_tool_writes_visible_failure_record() {
  local home tools rc=0

  home=$(make_home refresh-missing-tool)
  write_config "$home"
  write_refresh_fixture "$home"
  tools=$(make_refresh_tools "$home")
  rm -f -- "$tools/br"

  env FM_HOME="$home" PATH="$tools:/usr/bin:/bin" \
    FM_TEST_CALLS="$home/calls" FM_TEST_BR_JSON="$home/br.json" \
    FM_TEST_PRS_JSON="$home/prs.json" FM_TEST_MAIN_LOG="$home/main.log" \
    "$STEWARD" refresh >/dev/null 2>"$home/stderr" || rc=$?

  [ "$rc" -ne 0 ] || fail "refresh succeeded with a required tool missing"
  assert_contains "$(cat "$home/stderr")" 'required tool not found: br' "refresh did not name the missing tool"
  [ -f "$home/state/.fleet-steward-refresh-failure" ] \
    || fail "a missing required tool left no visible failure record"
  assert_contains "$(cat "$home/state/.fleet-steward-refresh-failure")" 'required tool not found: br' \
    "failure record did not name the missing tool"
  pass "a genuinely missing required tool fails nonzero and leaves a visible failure record"
}

test_refresh_succeeds_with_the_paths_the_armed_service_would_supply() {
  local home tools systemctl arming_path unit_path rc=0

  home=$(make_home refresh-minimal-path)
  write_config "$home"
  write_refresh_fixture "$home"
  tools=$(make_refresh_tools "$home")
  systemctl=$(make_systemctl "$home")
  arming_path="$tools:$PATH"

  FM_HOME="$home" FM_SYSTEMD_USER_DIR_OVERRIDE="$home/systemd" \
    FM_SYSTEMCTL="$systemctl" FM_TEST_SYSTEMCTL_LOG="$home/systemctl.log" \
    PATH="$arming_path" "$STEWARD" arm >/dev/null || fail "arm failed"
  unit_path=$(sed -n 's/^Environment=PATH=//p' "$home/systemd/next-up-refresh.service")
  [ -n "$unit_path" ] || fail "generated service unit carried no PATH environment line"

  # A bare login-shell PATH is what a user systemd unit sees without the fix;
  # it deliberately excludes the fake tool directory the fixture tools live in.
  env FM_HOME="$home" PATH="$unit_path" \
    FM_TEST_CALLS="$home/calls" FM_TEST_BR_JSON="$home/br.json" \
    FM_TEST_PRS_JSON="$home/prs.json" FM_TEST_MAIN_LOG="$home/main.log" \
    "$STEWARD" refresh >/dev/null 2>"$home/stderr" || rc=$?

  [ "$rc" -eq 0 ] || fail "refresh restricted to the armed unit's PATH failed: $(cat "$home/stderr")"
  [ ! -f "$home/state/.fleet-steward-refresh-failure" ] \
    || fail "a successful refresh left a stale failure record"
  pass "a refresh run with exactly the armed service unit's PATH still finds every required tool"
}

test_check_surfaces_a_new_refresh_failure_once() {
  local home out
  home=$(make_home refresh-failure-check)
  write_config "$home"
  printf 'fm-fleet-steward-refresh-failure.v1\nat=1000\nreason=required tool not found: br\n' \
    > "$home/state/.fleet-steward-refresh-failure"

  out=$(run_check "$home" 1000)
  assert_contains "$out" 'fleet-steward: refresh failed at=1000: required tool not found: br' \
    "check did not surface the refresh failure"

  out=$(run_check "$home" 1005)
  [ -z "$out" ] || fail "check re-reported an already-surfaced failure: $out"

  printf 'fm-fleet-steward-refresh-failure.v1\nat=2000\nreason=required tool not found: br\n' \
    > "$home/state/.fleet-steward-refresh-failure"
  out=$(run_check "$home" 2000)
  assert_contains "$out" 'fleet-steward: refresh failed at=2000' "check did not surface a newer refresh failure"
  pass "check surfaces each new refresh failure once and stays silent on a repeat poll"
}

test_arm_writes_the_arming_shells_path_into_the_service_unit() {
  local home systemctl custom_path
  home=$(make_home arm-path)
  write_config "$home"
  systemctl=$(make_systemctl "$home")
  custom_path="/custom/tool/dir:$PATH"

  FM_HOME="$home" FM_SYSTEMD_USER_DIR_OVERRIDE="$home/systemd" \
    FM_SYSTEMCTL="$systemctl" FM_TEST_SYSTEMCTL_LOG="$home/systemctl.log" \
    PATH="$custom_path" "$STEWARD" arm >/dev/null || fail "arm failed"

  assert_contains "$(cat "$home/systemd/next-up-refresh.service")" "Environment=PATH=$custom_path" \
    "service unit did not carry the arming shell's own PATH"
  pass "arm writes the arming shell's own PATH into the generated service unit"
}

test_check_requires_fifteen_persistent_minutes_and_emits_once() {
  local home out
  home=$(make_home grace)
  write_config "$home"
  printf '%s\n' '# Next up - generated' '- READY work-1 | acceptance: Work | preconditions: none' > "$home/data/next-up.md"

  write_capacity "$home" 1000 5 0
  out=$(run_check "$home" 1000)
  [ -z "$out" ] || fail "first low sample woke immediately: $out"
  write_capacity "$home" 1899 5 0
  out=$(run_check "$home" 1899)
  [ -z "$out" ] || fail "low episode woke before fifteen minutes: $out"
  write_capacity "$home" 1900 5 0
  out=$(run_check "$home" 1900)
  assert_contains "$out" 'fleet-steward: productive=5 ready=1' "persistent low episode did not wake with counts"
  assert_contains "$out" 'action=finish-then-refill' "wake omitted its lifecycle action"
  out=$(run_check "$home" 2000)
  [ -z "$out" ] || fail "same low episode woke more than once: $out"

  write_capacity "$home" 2100 6 0
  out=$(run_check "$home" 2100)
  [ -z "$out" ] || fail "healthy fleet emitted a wake: $out"
  write_capacity "$home" 2200 5 0
  run_check "$home" 2200 >/dev/null
  write_capacity "$home" 3100 5 0
  out=$(run_check "$home" 3100)
  assert_contains "$out" 'fleet-steward: productive=5 ready=1' "a new persistent episode did not wake"
  pass "check persists low capacity for fifteen minutes and emits once per episode"
}

test_check_resets_for_no_ready_work_and_suppresses_uncertainty() {
  local home out
  home=$(make_home reset)
  write_config "$home"
  printf '%s\n' '# Next up - generated' '- READY work-1 | acceptance: Work | preconditions: none' > "$home/data/next-up.md"
  write_capacity "$home" 1000 5 1
  out=$(run_check "$home" 1000)
  [ -z "$out" ] || fail "uncertain capacity emitted a wake: $out"
  [ ! -e "$home/state/.fleet-steward-low" ] || fail "uncertain capacity retained a low episode"

  write_capacity "$home" 1100 5 0
  run_check "$home" 1100 >/dev/null
  printf '# Next up - generated\n' > "$home/data/next-up.md"
  write_capacity "$home" 2000 5 0
  out=$(run_check "$home" 2000)
  [ -z "$out" ] || fail "empty ready queue emitted a wake: $out"
  [ ! -e "$home/state/.fleet-steward-low" ] || fail "empty ready queue retained a low episode"
  pass "check resets when capacity is uncertain or no ready work remains"
}

make_systemctl() {
  local home=$1 bin
  bin="$home/systemctl-bin"
  mkdir -p "$bin"
cat > "$bin/systemctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_SYSTEMCTL_LOG"
[ "${FM_TEST_SYSTEMCTL_FAIL_ENABLE:-0}" = 0 ] || case " $* " in
  *' enable --now next-up-refresh.timer '*) exit 1 ;;
esac
exit 0
SH
  chmod 0755 "$bin/systemctl"
  printf '%s\n' "$bin/systemctl"
}

test_arm_registers_home_check_and_installs_thirty_minute_timer() {
  local home systemctl
  home=$(make_home arm)
  write_config "$home"
  systemctl=$(make_systemctl "$home")

  FM_HOME="$home" FM_SYSTEMD_USER_DIR_OVERRIDE="$home/systemd" \
    FM_SYSTEMCTL="$systemctl" FM_TEST_SYSTEMCTL_LOG="$home/systemctl.log" \
    "$STEWARD" arm >/dev/null || fail "arm failed"

  [ -x "$home/state/fleet-steward.check.sh" ] || fail "arm did not install the home-local check shim"
  [ -f "$home/state/fleet-steward.check-trust" ] || fail "arm did not register the home-local check"
  assert_contains "$(cat "$home/state/fleet-steward.check.sh")" "export FM_HOME=$home" "check shim does not bind this home"
  assert_contains "$(cat "$home/systemd/next-up-refresh.timer")" 'OnUnitActiveSec=30min' "timer is not thirty minutes"
  assert_contains "$(cat "$home/systemd/next-up-refresh.timer")" 'Persistent=true' "timer is not persistent"
  assert_contains "$(cat "$home/systemd/next-up-refresh.service")" 'fm-fleet-steward.sh refresh' "service does not regenerate next-up"
  assert_contains "$(cat "$home/systemctl.log")" '--user daemon-reload' "arm did not reload user units"
  assert_contains "$(cat "$home/systemctl.log")" '--user enable --now next-up-refresh.timer' "arm did not enable the timer"
  if command -v systemd-analyze >/dev/null 2>&1; then
    systemd-analyze --user verify \
      "$home/systemd/next-up-refresh.service" "$home/systemd/next-up-refresh.timer" \
      > "$home/systemd-analyze.log" 2>&1 \
      || fail "systemd rejected the generated units: $(cat "$home/systemd-analyze.log")"
  fi
  pass "arm registers the check in its own home and installs the persistent timer"
}

test_arm_rolls_back_when_timer_enable_fails() {
  local home systemctl rc=0
  home=$(make_home arm-rollback)
  write_config "$home"
  systemctl=$(make_systemctl "$home")

  FM_HOME="$home" FM_SYSTEMD_USER_DIR_OVERRIDE="$home/systemd" \
    FM_SYSTEMCTL="$systemctl" FM_TEST_SYSTEMCTL_LOG="$home/systemctl.log" \
    FM_TEST_SYSTEMCTL_FAIL_ENABLE=1 "$STEWARD" arm >/dev/null 2>&1 || rc=$?

  [ "$rc" -ne 0 ] || fail "arm succeeded when timer enable failed"
  [ ! -e "$home/state/fleet-steward.check.sh" ] || fail "failed arm left the check shim installed"
  [ ! -e "$home/state/fleet-steward.check-trust" ] || fail "failed arm left the check registered"
  [ ! -e "$home/systemd/next-up-refresh.service" ] || fail "failed arm left the service installed"
  [ ! -e "$home/systemd/next-up-refresh.timer" ] || fail "failed arm left the timer installed"
  assert_contains "$(cat "$home/systemctl.log")" '--user disable --now next-up-refresh.timer' "rollback did not disable the timer"
  pass "arm rolls back the check and timer when enable fails"
}

test_exempt_records_exact_refusal_without_losing_siblings() {
  local home detail json
  home=$(make_home exempt)
  cat > "$home/state/steward-exemptions.json" <<'JSON'
{"schema":"fm-steward-exemptions.v1","exemptions":[{"task_id":"existing-task","reason":"existing","set_by":"operator","reviewed_date":"2026-09-01","expires_on":"2026-10-01","state":"blocked","detail":"still external","hold_identity":{"source":"backlog","kind":"external","reason":"existing"}}]}
JSON
  detail="$home/refusal.txt"
  printf 'teardown refused: unlanded work remains\n' > "$detail"

  if FM_HOME="$home" FM_FLEET_STEWARD_TODAY=2026-09-20 \
    "$STEWARD" exempt refused-task --state 'done' --detail-file "$detail" >/dev/null 2>&1; then
    fail "exempt must refuse a state that no longer matches the reconciled state"
  fi
  [ "$(jq '.exemptions | length' "$home/state/steward-exemptions.json")" = 1 ] \
    || fail "a refused exempt must not write a row"

  FM_HOME="$home" FM_FLEET_STEWARD_TODAY=2026-09-20 \
    "$STEWARD" exempt refused-task --state 'unknown' --detail-file "$detail" >/dev/null \
    || fail "exempt command failed"
  json=$(cat "$home/state/steward-exemptions.json")
  printf '%s\n' "$json" | jq -e '
    .schema == "fm-steward-exemptions.v1"
    and (.exemptions | length) == 2
    and any(.exemptions[]; .task_id == "existing-task" and .detail == "still external")
    and any(.exemptions[];
      .task_id == "refused-task"
      and .state == "unknown"
      and .detail == "no metadata for refused-task"
      and .refusal == "teardown refused: unlanded work remains"
      and (.reason | contains("teardown refused: unlanded work remains"))
      and .reviewed_date == "2026-09-20"
      and .hold_identity == {source:"child-state",kind:null,reason:"no metadata for refused-task"})
  ' >/dev/null || fail "exempt did not preserve the sibling and bind the reconciled state: $json"
  pass "exempt binds a teardown refusal to the exact reconciled state without losing siblings"
}

# The automatic park trigger parks every ship the snapshot classifies
# parked_preserved, reports each outcome, and leaves every other task alone.
test_park_preserved_parks_exactly_the_preserved_ships() {
  local home out rc
  home=$(make_home park-preserved)
  cat > "$home/snapshot.sh" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{"schema":"fm-fleet-snapshot.v1","tasks":[
 {"id":"frozen-a","kind":"ship","capacity":{"class":"parked_preserved"}},
 {"id":"live-b","kind":"ship","capacity":{"class":"live_worker"}},
 {"id":"scout-c","kind":"scout","capacity":{"class":"parked_preserved"}},
 {"id":"landed-d","kind":"ship","capacity":{"class":"parked_preserved"}},
 {"id":"refuses-e","kind":"ship","capacity":{"class":"parked_preserved"}},
 {"id":"working-f","kind":"ship","capacity":{"class":"productive"}}]}
JSON
SH
  cat > "$home/teardown.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$home/teardown.calls"
case "\$1" in
  frozen-a) echo "park frozen-a complete (window w, worktree x released)" ;;
  landed-d) echo "teardown landed-d complete (window w, worktree x)" ;;
  refuses-e) echo "REFUSED: cannot park task refuses-e: its worker endpoint reads 'alive'. Nothing was changed." >&2; exit 1 ;;
esac
SH
  chmod 0755 "$home/snapshot.sh" "$home/teardown.sh"

  rc=0
  out=$(FM_HOME="$home" FM_FLEET_STEWARD_SNAPSHOT_BIN="$home/snapshot.sh" \
    FM_FLEET_STEWARD_TEARDOWN_BIN="$home/teardown.sh" "$STEWARD" park-preserved 2>&1) || rc=$?
  expect_code 1 "$rc" "park-preserved: a refused park must fail the pass"
  [ "$(cat "$home/teardown.calls")" = "$(printf '%s\n' 'frozen-a --park' 'landed-d --park' 'refuses-e --park')" ] \
    || fail "park-preserved: parked the wrong tasks: $(cat "$home/teardown.calls")"
  assert_contains "$out" "parked: frozen-a" "park-preserved: no parked line"
  assert_contains "$out" "landed: landed-d" "park-preserved: landed hand-off not reported"
  assert_contains "$out" "park refused: refuses-e: REFUSED: cannot park task refuses-e" "park-preserved: refusal not reported"

  printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$home/snapshot.sh"
  rc=0
  out=$(FM_HOME="$home" FM_FLEET_STEWARD_SNAPSHOT_BIN="$home/snapshot.sh" \
    FM_FLEET_STEWARD_TEARDOWN_BIN="$home/teardown.sh" "$STEWARD" park-preserved 2>&1) || rc=$?
  expect_code 1 "$rc" "park-preserved: an unreadable snapshot must fail rather than park nothing silently"
  pass "park-preserved parks exactly the preserved ship tasks and reports every outcome"
}

make_backlog_home() {
  local home=$1
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$home/data/backlog.md"
  printf '%s\n' 'backend = "markdown"' '' '[markdown]' 'path = "data/backlog.md"' > "$home/.tasks.toml"
}

write_park_receipt() {  # <home> <id> <parked_at>
  mkdir -p "$1/data/$2/park"
  printf '%s\n' "task=$2" "branch=fm/$2" "head=0123456789abcdef0123456789abcdef01234567" "parked_at=$3" \
    > "$1/data/$2/park/receipt"
}

# One batched captain question at most every 14 days, listing only parked
# items at least 14 days old whose work is still open and not resumed.
test_parked_review_asks_once_per_fourteen_days() {
  local home out now day=86400 backlog review
  home=$(make_home parked-review)
  make_backlog_home "$home"
  backlog="$home/data/backlog.md"
  now=$((1790000000))
  for id in old-a old-b young-c resumed-d closed-e; do
    tasks-axi add "$id" "work $id" --kind ship --file "$backlog" >/dev/null
  done
  tasks-axi "done" closed-e --file "$backlog" >/dev/null
  write_park_receipt "$home" old-a $((now - 20 * day))
  write_park_receipt "$home" old-b $((now - 15 * day))
  write_park_receipt "$home" young-c $((now - 3 * day))
  write_park_receipt "$home" resumed-d $((now - 30 * day))
  write_park_receipt "$home" closed-e $((now - 30 * day))
  printf 'kind=ship\n' > "$home/state/resumed-d.meta"

  out=$(FM_HOME="$home" FM_FLEET_STEWARD_NOW=$now "$STEWARD" parked-review 2>&1) \
    || fail "parked-review: the first review failed: $out"
  assert_contains "$out" "old-a: parked 20 days" "parked-review: an old item is missing"
  assert_contains "$out" "old-b: parked 15 days" "parked-review: an old item is missing"
  assert_not_contains "$out" "young-c" "parked-review: a young item was asked about"
  assert_not_contains "$out" "resumed-d" "parked-review: a resumed item was asked about"
  assert_not_contains "$out" "closed-e" "parked-review: a closed item was asked about"
  review=$(printf '%s\n' "$out" | sed -n 's/^parked-review: //p')
  [ -n "$review" ] || fail "parked-review: no review id was printed: $out"
  FM_HOME="$home" "$ROOT/bin/fm-captain-hold.sh" open "$review" \
    || fail "parked-review: the review $review is not held for the captain"
  tasks-axi show "$review" --full --file "$backlog" | grep -Fq "old-a: parked 20 days" \
    || fail "parked-review: the held review does not list the parked items"
  assert_present "$home/state/.fleet-steward-parked-review" "parked-review: the last-asked record was not written"

  out=$(FM_HOME="$home" FM_FLEET_STEWARD_NOW=$((now + 13 * day)) "$STEWARD" parked-review 2>&1) \
    || fail "parked-review: a quiet pass failed: $out"
  [ -z "$out" ] || fail "parked-review: asked again within 14 days: $out"
  out=$(FM_HOME="$home" FM_FLEET_STEWARD_NOW=$((now + 14 * day)) "$STEWARD" parked-review 2>&1) \
    || fail "parked-review: the next review failed: $out"
  assert_contains "$out" "young-c: parked 17 days" "parked-review: the next review missed an item that aged in"
  for id in old-a old-b young-c; do
    [ -f "$home/data/$id/park/receipt" ] || fail "parked-review: parked work $id was dropped"
    [ "$(tasks-axi show "$id" --file "$backlog" | sed -n 's/^  state: *//p')" = queued ] \
      || fail "parked-review: parked item $id was closed"
  done
  pass "parked-review raises one held captain question per 14 days and never drops parked work"
}

test_parked_review_is_silent_without_old_parked_work() {
  local home out
  home=$(make_home parked-review-quiet)
  make_backlog_home "$home"
  tasks-axi add fresh-a "work" --kind ship --file "$home/data/backlog.md" >/dev/null
  write_park_receipt "$home" fresh-a 1790000000
  out=$(FM_HOME="$home" FM_FLEET_STEWARD_NOW=1790086400 "$STEWARD" parked-review 2>&1) \
    || fail "parked-review-quiet: failed: $out"
  [ -z "$out" ] || fail "parked-review-quiet: asked with nothing old: $out"
  assert_absent "$home/state/.fleet-steward-parked-review" "parked-review-quiet: recorded an ask that never happened"
  pass "parked-review stays silent and records nothing when no parked work is old enough"
}

test_refresh_filters_verified_nonwork_and_ranks_survivors
test_refresh_failure_preserves_last_known_good_queue
test_refresh_missing_tool_writes_visible_failure_record
test_refresh_succeeds_with_the_paths_the_armed_service_would_supply
test_check_surfaces_a_new_refresh_failure_once
test_arm_writes_the_arming_shells_path_into_the_service_unit
test_check_requires_fifteen_persistent_minutes_and_emits_once
test_check_resets_for_no_ready_work_and_suppresses_uncertainty
test_arm_registers_home_check_and_installs_thirty_minute_timer
test_arm_rolls_back_when_timer_enable_fails
test_exempt_records_exact_refusal_without_losing_siblings
test_park_preserved_parks_exactly_the_preserved_ships
test_parked_review_asks_once_per_fourteen_days
test_parked_review_is_silent_without_old_parked_work
