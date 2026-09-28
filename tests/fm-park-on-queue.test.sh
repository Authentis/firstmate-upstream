#!/usr/bin/env bash
# Behavioral tests for queue parking through the control plane.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PARK="$ROOT/bin/fm-park-on-queue.sh"
TMP_ROOT=$(fm_test_tmproot fm-park-on-queue)

make_case() {
  local name=$1 home bin
  home="$TMP_ROOT/$name/home"
  bin="$TMP_ROOT/$name/bin"
  mkdir -p "$home/config" "$home/state" "$bin"
  cat > "$bin/crew-state" <<'SH'
#!/usr/bin/env bash
printf 'state: done · source: status-log · no active validation\n'
SH
  cat > "$bin/control" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_CONTROL_LOG"
SH
  chmod 0755 "$bin/crew-state" "$bin/control"
  printf '%s|%s|%s\n' "$home" "$bin" "$TMP_ROOT/$name/control.log"
}

run_park() {
  local home=$1 bin=$2 log=$3 id=$4
  FM_HOME="$home" FM_PARK_CREW_STATE_BIN="$bin/crew-state" \
    FM_PARK_CONTROL_BIN="$bin/control" FM_TEST_CONTROL_LOG="$log" "$PARK" "$id"
}

test_done_parks_through_fm_control_and_keeps_status() {
  local rec home bin log out
  rec=$(make_case 'done')
  IFS='|' read -r home bin log <<EOF
$rec
EOF
  printf 'done [at=1]: implementation committed\n' > "$home/state/lab-done.status"

  out=$(run_park "$home" "$bin" "$log" lab-done)
  [ "$out" = 'parked: lab-done' ] || fail "done queue transition did not park: $out"
  [ "$(cat "$log")" = 'lab-done exit' ] || fail "queue parking did not use fm-control exit"
  assert_contains "$(cat "$home/state/lab-done.status")" 'paused [at=' \
    "parking did not append a durable status event"
  pass "done queue transition parks through fm-control exit and preserves the task log"
}

test_open_decision_prevents_parking() {
  local rec home bin log out
  rec=$(make_case decision)
  IFS='|' read -r home bin log <<EOF
$rec
EOF
  cat > "$home/state/lab-held.status" <<'EOF'
needs-decision [at=1] [key=choice]: select a path
done [at=2]: implementation committed
EOF

  out=$(run_park "$home" "$bin" "$log" lab-held)
  [ -z "$out" ] || fail "open decision should suppress parking, got: $out"
  [ ! -e "$log" ] || fail "queue parking exited a task with an open decision"
  pass "open needs-decision or blocked records keep the task running"
}

test_ready_pause_parks_but_active_validation_does_not() {
  local rec home bin log out
  rec=$(make_case paused)
  IFS='|' read -r home bin log <<EOF
$rec
EOF
  printf 'paused [at=1]: ready for validation\n' > "$home/state/lab-paused.status"
  out=$(run_park "$home" "$bin" "$log" lab-paused)
  [ "$out" = 'parked: lab-paused' ] || fail "ready-for-validation pause did not park"

  cat > "$bin/crew-active" <<'SH'
#!/usr/bin/env bash
printf 'state: working · source: run-step · validation running\n'
SH
  chmod 0755 "$bin/crew-active"
  printf 'done [at=2]: implementation committed\n' > "$home/state/lab-active.status"
  out=$(FM_HOME="$home" FM_PARK_CREW_STATE_BIN="$bin/crew-active" \
    FM_PARK_CONTROL_BIN="$bin/control" FM_TEST_CONTROL_LOG="$log" "$PARK" lab-active)
  [ -z "$out" ] || fail "active validation should suppress parking, got: $out"
  [ "$(wc -l < "$log" | tr -d ' ')" = 1 ] || fail "active validation was sent an exit"
  pass "ready pauses park only when no validation run is active"
}

test_off_switch_leaves_the_lane_running_and_records_it_in_status() {
  local rec home bin log out
  rec=$(make_case off)
  IFS='|' read -r home bin log <<EOF
$rec
EOF
  printf 'off\n' > "$home/config/park-on-queue"
  printf 'done [at=1]: implementation committed\n' > "$home/state/lab-off.status"
  out=$(run_park "$home" "$bin" "$log" lab-off)
  [ -z "$out" ] || fail "park-on-queue=off should not park, got: $out"
  [ ! -e "$log" ] || fail "park-on-queue=off still sent an exit"
  run_park "$home" "$bin" "$log" lab-off >/dev/null
  assert_contains "$(cat "$home/state/lab-off.status")" 'park-on-queue is off; task=lab-off' \
    "off switch left no task-status event"
  [ "$(grep -c 'park-on-queue is off; task=lab-off' "$home/state/lab-off.status")" = 1 ] \
    || fail "off event repeated for one status line"
  pass "park-on-queue=off records one task-status event per status line"
}

test_deferred_parking_is_retried_until_it_succeeds() {
  local rec home bin log out
  rec=$(make_case retry)
  IFS='|' read -r home bin log <<EOF
$rec
EOF
  cat > "$bin/crew-active" <<'SH'
#!/usr/bin/env bash
printf 'state: working · source: run-step · validation running\n'
SH
  chmod 0755 "$bin/crew-active"
  printf 'done [at=1]: implementation committed\n' > "$home/state/lab-retry.status"
  for _ in $(seq 1 20); do
    FM_HOME="$home" FM_PARK_CREW_STATE_BIN="$bin/crew-active" FM_PARK_CONTROL_BIN="$bin/control" \
      FM_TEST_CONTROL_LOG="$log" "$PARK" lab-retry >/dev/null \
      && fail "active validation should defer with a nonzero exit"
  done
  [ -e "$home/state/lab-retry.park-pending" ] || fail "deferred parking lost its retry obligation"
  [ ! -e "$log" ] || fail "deferred parking sent an exit"

  out=$(run_park "$home" "$bin" "$log" lab-retry)
  [ "$out" = 'parked: lab-retry' ] || fail "retry after validation ended did not park: $out"
  [ ! -e "$home/state/lab-retry.park-pending" ] || fail "successful park kept the retry obligation"
  pass "parking deferred by active validation is retried and clears once parked"
}

test_gate_lab_queue_parking_reaches_fm_control() {
  local home bin out rc
  home=$(env -u FM_GATE_REFUSE_BYPASS NO_MISTAKES_GATE=1 \
    "$ROOT/bin/fm-lab-home.sh" create "$TMP_ROOT/gate-lab") \
    || fail "could not create disposable gate lab"
  bin="$home/bin"
  mkdir -p "$bin"
  cat > "$bin/crew-state" <<'SH'
#!/usr/bin/env bash
printf 'state: done · source: status-log · no active validation\n'
SH
  chmod 0755 "$bin/crew-state"
  printf 'done [at=1]: implementation committed\n' > "$home/state/lab-gate.status"

  out=$(env -u FM_GATE_REFUSE_BYPASS NO_MISTAKES_GATE=1 FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_PARK_CREW_STATE_BIN="$bin/crew-state" "$PARK" lab-gate 2>&1); rc=$?
  [ "$rc" -eq 75 ] || fail "unconfigured lab control should defer parking, got $rc: $out"
  assert_contains "$out" "no task 'lab-gate'" \
    "queue parking did not reach fm-control through the permitted lab layout"
  pass "gate-lab queue parking reaches fm-control without an override refusal"
}

test_failed_exit_keeps_a_retry_obligation() {
  local rec home bin log
  rec=$(make_case failexit)
  IFS='|' read -r home bin log <<EOF
$rec
EOF
  printf '#!/usr/bin/env bash\nexit 1\n' > "$bin/control-fail"
  chmod 0755 "$bin/control-fail"
  printf 'done [at=1]: implementation committed\n' > "$home/state/lab-fail.status"
  FM_HOME="$home" FM_PARK_CREW_STATE_BIN="$bin/crew-state" FM_PARK_CONTROL_BIN="$bin/control-fail" \
    "$PARK" lab-fail >/dev/null 2>&1 && fail "failed exit should return nonzero"
  [ -e "$home/state/lab-fail.park-pending" ] || fail "failed exit left no retry obligation"
  printf 'working [at=2]: resumed\n' >> "$home/state/lab-fail.status"
  run_park "$home" "$bin" "$log" lab-fail >/dev/null
  [ ! -e "$home/state/lab-fail.park-pending" ] || fail "an ineligible task kept its retry obligation"
  pass "a failed exit is retried and dropped once the task is no longer eligible"
}

test_done_parks_through_fm_control_and_keeps_status
test_open_decision_prevents_parking
test_ready_pause_parks_but_active_validation_does_not
test_off_switch_leaves_the_lane_running_and_records_it_in_status
test_deferred_parking_is_retried_until_it_succeeds
test_gate_lab_queue_parking_reaches_fm_control
test_failed_exit_keeps_a_retry_obligation

echo "# all fm-park-on-queue tests passed"
