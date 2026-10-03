#!/usr/bin/env bash
# tests/fm-inbox-ack.test.sh - bin/fm-inbox-ack.sh, the worker's one command for
# acknowledging steering-inbox messages (bin/fm-task-inbox-lib.sh owns the inbox).
#
#   1. Acknowledging a sequence moves its record into handled/ byte-exact and
#      leaves every other record pending.
#   2. Acknowledging is idempotent: a sequence already in handled/ succeeds, a
#      sequence in neither place fails, and several sequences are all attempted.
#   3. --all-handled-through acknowledges every pending record at or below the
#      bound and none above it; an empty inbox is a success.
#   4. The doorbell ladder, escalation, and retry records naming an acknowledged
#      message are cleared, while records naming another message survive.
#   5. Refusals: an invalid task id, a path-escaping id, a malformed sequence, an
#      absent inbox, a symlinked inbox or handled/, and a handled/ copy that would
#      be overwritten all fail without moving anything outside the inbox.
#   6. The state directory comes from FM_STATE_OVERRIDE, else $FM_HOME/state.
#   7. Worker and secondmate scaffolds instruct this command, not a raw move.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ACK="$ROOT/bin/fm-inbox-ack.sh"
TMP_ROOT=$(fm_test_tmproot fm-inbox-ack)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

# Build a task inbox with records 001..<count>, each with a distinct body.
make_inbox() {  # <state> <task> <count>
  local state=$1 task=$2 count=$3 i
  mkdir -p "$state/$task.inbox"
  for i in $(seq 1 "$count"); do
    printf 'schema=fm-task-inbox.v1\n--\nbody %s\n' "$i" > "$state/$task.inbox/$(printf '%03d' "$i").msg"
  done
}

ack() {  # <state> <args...>; runs the script, captures stdout+stderr in $out, status in $rc
  local state=$1
  shift
  out=$(FM_STATE_OVERRIDE="$state" "$ACK" "$@" 2>&1)
  rc=$?
}

test_ack_moves_one_record_and_leaves_the_rest() {
  local state="$TMP_ROOT/one/state" out rc
  make_inbox "$state" t1 3
  ack "$state" t1 2
  expect_code 0 "$rc" "acknowledging a pending sequence"
  assert_contains "$out" "handled 002.msg" "the acknowledgement was not reported"
  assert_absent "$state/t1.inbox/002.msg" "the acknowledged record stayed in the inbox"
  assert_equals $'schema=fm-task-inbox.v1\n--\nbody 2' "$(cat "$state/t1.inbox/handled/002.msg")" \
    "the handled copy is not byte-exact"
  assert_present "$state/t1.inbox/001.msg" "an unrelated record left the inbox"
  assert_present "$state/t1.inbox/003.msg" "an unrelated record left the inbox"
  pass "fm-inbox-ack: moves exactly the named record into handled/"
}

test_ack_accepts_padded_and_msg_forms() {
  local state="$TMP_ROOT/forms/state" out rc
  make_inbox "$state" t1 3
  ack "$state" t1 001 3.msg
  expect_code 0 "$rc" "padded and .msg sequence forms"
  assert_present "$state/t1.inbox/handled/001.msg" "001 was not acknowledged"
  assert_present "$state/t1.inbox/handled/003.msg" "3.msg was not acknowledged"
  assert_present "$state/t1.inbox/002.msg" "002 must stay pending"
  pass "fm-inbox-ack: accepts 001 and 3.msg forms for several sequences in one call"
}

test_ack_is_idempotent_and_reports_missing() {
  local state="$TMP_ROOT/idem/state" out rc
  make_inbox "$state" t1 2
  ack "$state" t1 1
  expect_code 0 "$rc" "first acknowledgement"
  ack "$state" t1 1
  expect_code 0 "$rc" "re-acknowledging an already handled sequence"
  assert_contains "$out" "already 001.msg" "an already handled sequence was not reported as such"
  ack "$state" t1 9
  expect_code 1 "$rc" "a sequence in neither place"
  assert_contains "$out" "no steering message 9" "the missing sequence was not named"
  ack "$state" t1 9 2
  expect_code 1 "$rc" "a failing sequence among several"
  assert_present "$state/t1.inbox/handled/002.msg" "a later valid sequence was skipped after a failure"
  pass "fm-inbox-ack: already handled succeeds, missing fails, and every sequence is attempted"
}

test_all_handled_through() {
  local state="$TMP_ROOT/through/state" out rc
  make_inbox "$state" t1 5
  ack "$state" t1 --all-handled-through 3
  expect_code 0 "$rc" "--all-handled-through 3"
  for n in 001 002 003; do
    assert_present "$state/t1.inbox/handled/$n.msg" "$n was not acknowledged by the bound"
  done
  assert_present "$state/t1.inbox/004.msg" "a record above the bound was acknowledged"
  assert_present "$state/t1.inbox/005.msg" "a record above the bound was acknowledged"
  ack "$state" t1 --all-handled-through 3
  expect_code 0 "$rc" "--all-handled-through over an already handled run"
  ack "$state" t1 --all-handled-through 9
  expect_code 0 "$rc" "--all-handled-through past the newest record"
  assert_absent "$state/t1.inbox/005.msg" "the bound past the newest did not acknowledge it"
  ack "$state" t1 --all-handled-through 9
  expect_code 0 "$rc" "--all-handled-through on an empty inbox"
  pass "fm-inbox-ack: --all-handled-through acknowledges the pending run at or below the bound"
}

test_ack_clears_the_doorbell_records_naming_it() {
  local state="$TMP_ROOT/ladder/state" out rc
  make_inbox "$state" t1 2
  printf '001.msg\t2\t1700000000\n' > "$state/t1.inbox/.ring-state"
  printf '001.msg\n' > "$state/t1.inbox/.escalated"
  printf '001.msg\n' > "$state/t1.inbox/.retry-ring"
  ack "$state" t1 1
  expect_code 0 "$rc" "acknowledging the message the ladder tracks"
  for f in .ring-state .escalated .retry-ring; do
    assert_absent "$state/t1.inbox/$f" "$f still names the acknowledged message"
  done

  printf '002.msg\t1\t1700000000\n' > "$state/t1.inbox/.ring-state"
  printf '002.msg\n' > "$state/t1.inbox/.escalated"
  printf '002.msg\n' > "$state/t1.inbox/.retry-ring"
  make_inbox "$state" t1 3
  ack "$state" t1 3
  expect_code 0 "$rc" "acknowledging a message the ladder does not track"
  for f in .ring-state .escalated .retry-ring; do
    assert_present "$state/t1.inbox/$f" "$f for another message was cleared"
  done
  pass "fm-inbox-ack: clears ring, escalation, and retry records naming the message and no others"
}

test_ack_stops_the_ladder() {
  local state="$TMP_ROOT/due/state" action
  make_inbox "$state" t1 1
  touch -t 200001010000 "$state/t1.inbox/001.msg"
  action=$(FM_STATE_OVERRIDE="$state" FM_TASK_INBOX_GRACE_SECS=1 bash -c \
    '. "$1"; fm_task_inbox_due_action "$2" t1' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$state")
  case "$action" in ring*) : ;; *) fail "the aged unhandled record should be due a ring, got: $action" ;; esac
  ack "$state" t1 1
  action=$(FM_STATE_OVERRIDE="$state" FM_TASK_INBOX_GRACE_SECS=1 bash -c \
    '. "$1"; fm_task_inbox_due_action "$2" t1' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$state")
  assert_equals quiet "$action" "an acknowledged record is still due a doorbell action"
  pass "fm-inbox-ack: the watcher's ladder goes quiet once the record is acknowledged"
}

test_refusals() {
  local state="$TMP_ROOT/refuse/state" out rc outside="$TMP_ROOT/refuse/outside"
  make_inbox "$state" t1 2
  mkdir -p "$outside"
  ack "$state" '../t1' 1
  expect_code 2 "$rc" "a path-escaping task id"
  ack "$state" '.hidden' 1
  expect_code 2 "$rc" "a dotted task id"
  ack "$state" 't 1' 1
  expect_code 2 "$rc" "a task id with a space"
  ack "$state" t1 abc
  expect_code 2 "$rc" "a non-numeric sequence"
  ack "$state" t1 '../002'
  expect_code 2 "$rc" "a path-like sequence"
  ack "$state" t1
  expect_code 2 "$rc" "a missing sequence"
  ack "$state" t1 --all-handled-through
  expect_code 2 "$rc" "--all-handled-through without a bound"
  ack "$state" nosuch 1
  expect_code 1 "$rc" "a task with no inbox"
  assert_contains "$out" "no steering inbox" "the absent inbox was not named"
  assert_present "$state/t1.inbox/001.msg" "a refused call moved a record"

  # A symlinked handled/ must not carry a record out of the inbox.
  ln -s "$outside" "$state/t1.inbox/handled"
  ack "$state" t1 1
  expect_code 1 "$rc" "a symlinked handled/"
  assert_present "$state/t1.inbox/001.msg" "the record left through a symlinked handled/"
  [ -z "$(ls -A "$outside")" ] || fail "a record escaped through a symlinked handled/"
  rm "$state/t1.inbox/handled"

  # A symlinked inbox must not be followed.
  mkdir -p "$TMP_ROOT/refuse/real.inbox"
  : > "$TMP_ROOT/refuse/real.inbox/001.msg"
  ln -s "$TMP_ROOT/refuse/real.inbox" "$state/t2.inbox"
  ack "$state" t2 1
  expect_code 1 "$rc" "a symlinked inbox"
  assert_present "$TMP_ROOT/refuse/real.inbox/001.msg" "a record moved through a symlinked inbox"
  ack "$state" t2 --all-handled-through 1
  expect_code 1 "$rc" "a symlinked inbox under --all-handled-through"

  # A symlinked record must not be moved.
  : > "$outside/target.msg"
  rm -f "$state/t1.inbox/002.msg"
  ln -s "$outside/target.msg" "$state/t1.inbox/002.msg"
  ack "$state" t1 2
  expect_code 1 "$rc" "a symlinked record"
  assert_present "$outside/target.msg" "a symlinked record's target was touched"

  # A handled/ copy is never overwritten.
  make_inbox "$state" t3 1
  mkdir -p "$state/t3.inbox/handled"
  printf 'earlier\n' > "$state/t3.inbox/handled/001.msg"
  ack "$state" t3 1
  expect_code 1 "$rc" "a record colliding with a handled copy"
  assert_equals earlier "$(cat "$state/t3.inbox/handled/001.msg")" "the handled copy was overwritten"
  assert_present "$state/t3.inbox/001.msg" "the colliding pending record was lost"
  pass "fm-inbox-ack: refuses invalid ids, bad sequences, symlinked paths, and overwrites"
}

test_state_resolution() {
  local home="$TMP_ROOT/home" out rc
  make_inbox "$home/state" t1 1
  out=$(env -u FM_STATE_OVERRIDE FM_HOME="$home" "$ACK" t1 1 2>&1); rc=$?
  expect_code 0 "$rc" "resolving the inbox from FM_HOME"
  assert_present "$home/state/t1.inbox/handled/001.msg" "FM_HOME/state was not the inbox root"
  pass "fm-inbox-ack: the inbox comes from the active home's state directory"
}

test_scaffolds_instruct_the_command() {
  local home="$TMP_ROOT/brief-home" id brief
  mkdir -p "$home/data" "$home/config"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" ack-ship some-proj --mode no-mistakes >/dev/null 2>&1 \
    || fail "fm-brief.sh ship scaffold exited non-zero"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" ack-scout some-proj --scout >/dev/null 2>&1 \
    || fail "fm-brief.sh scout scaffold exited non-zero"
  FM_SECONDMATE_CHARTER='Supervise the alpha domain.' \
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" ack-sm --secondmate --no-projects >/dev/null 2>&1 \
    || fail "fm-brief.sh secondmate scaffold exited non-zero"
  for id in ack-ship ack-scout ack-sm; do
    brief="$home/data/$id/brief.md"
    assert_grep "bin/fm-inbox-ack.sh' '$id' <seq>" "$brief" "$id: the scaffold does not instruct the acknowledge command"
    assert_grep "never move the files by hand" "$brief" "$id: the scaffold still allows a raw move"
    assert_no_grep "by moving it" "$brief" "$id: the scaffold still instructs a raw move"
  done
  pass "fm-brief: worker and secondmate scaffolds instruct fm-inbox-ack.sh instead of a raw move"
}

test_ack_moves_one_record_and_leaves_the_rest
test_ack_accepts_padded_and_msg_forms
test_ack_is_idempotent_and_reports_missing
test_all_handled_through
test_ack_clears_the_doorbell_records_naming_it
test_ack_stops_the_ladder
test_refusals
test_state_resolution
test_scaffolds_instruct_the_command
