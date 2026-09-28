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

test_done_parks_through_fm_control_and_keeps_status
test_open_decision_prevents_parking
test_ready_pause_parks_but_active_validation_does_not

echo "# all fm-park-on-queue tests passed"
