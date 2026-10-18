#!/usr/bin/env bash
# tests/fm-inbox-pull.test.sh - bin/fm-inbox-pull.sh, the owner of the mid-turn
# inbox pull (the pi extension .pi/extensions/fm-inbox-pull.ts only triggers it).
#
#   1. A fresh peek names every unhandled record once; a handled record never.
#   2. The notice is committed in two phases: no commit, no cursor move; a
#      committed id is never named again, including after the owner is rerun.
#   3. The throttle is decided before any scan and still refreshes the heartbeat.
#   4. The kill switch (environment and file) silences peek and reports killed.
#   5. The replay trip writes the kill file once too many notices landed in an hour.
#   6. An unrecognised cursor schema is migrated without replaying handled work.
#   7. The scan set is parent-route inboxes plus FM_INBOX_PULL_DIR plus
#      config/inbox-pull-dirs, deduplicated, symlinks skipped.
#   8. Concurrent peeks print the notice at most once.
#   9. Silent contract: errors never reach stdout or stderr; exit is always 0;
#      beat --error lands in the heartbeat and the log.
#  10. A script at mode 664 still runs when invoked through its interpreter.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PULL="$ROOT/bin/fm-inbox-pull.sh"
TMP_ROOT=$(fm_test_tmproot fm-inbox-pull)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
CASE=0

new_home() {  # -> sets H (home) and S (state); one fresh home per case
  CASE=$((CASE + 1))
  H="$TMP_ROOT/h$CASE"
  S="$H/state"
  mkdir -p "$S/parent-route" "$H/config"
}

mk_msg() {  # <inbox-dir> <seq>
  mkdir -p "$1"
  printf 'schema=fm-task-inbox.v1\nat=2026-10-18T00:00:00Z\n--\nbody %s\n' "$2" > "$1/$(printf '%03d' "$2").msg"
}

# pull <epoch> <command...>: runs the owner in the current home; stdout in $out.
pull() {
  local at=$1
  shift
  out=$(FM_HOME="$H" FM_STATE_OVERRIDE="$S" FM_CONFIG_OVERRIDE="$H/config" FM_INBOX_PULL_NOW="$at" \
    FM_INBOX_PULL_PID=4242 bash "$PULL" "$@" 2>"$H/stderr")
  rc=$?
  [ "$rc" -eq 0 ] || fail "fm-inbox-pull.sh $* exited $rc"
  [ ! -s "$H/stderr" ] || fail "fm-inbox-pull.sh $* wrote to stderr: $(cat "$H/stderr")"
}

hb() {  # <key> -> heartbeat value
  sed -n "s/^$1=//p" "$S/inbox-pull/heartbeat"
}

count_notices() {  # <text> -> number of record lines in a notice
  printf '%s\n' "$1" | grep -c '^inbox-pull-notice:' || true
}

test_fresh_peek_names_unhandled_once() {
  new_home
  local box="$S/parent-route/chief.inbox"
  mk_msg "$box" 1
  mk_msg "$box" 2
  mkdir -p "$box/handled"
  mk_msg "$box/handled" 3
  rm -f "$box/handled/003.msg"
  printf 'x\n' > "$box/handled/004.msg"
  pull 1000 peek
  assert_contains "$out" "Firstmate instruction waiting" "peek prints the doorbell sentence"
  assert_not_contains "$out" ": Firstmate" "the shell no-op prefix is stripped"
  assert_contains "$out" "inbox-pull-notice:$box/001.msg" "peek names 001"
  assert_contains "$out" "inbox-pull-notice:$box/002.msg" "peek names 002"
  assert_not_contains "$out" "004.msg" "a handled record is never named"
  assert_equals 2 "$(count_notices "$out")" "exactly the two unhandled records"
  pass "peek names each unhandled record and no handled one"
}

test_two_phase_commit() {
  new_home
  local box="$S/parent-route/chief.inbox"
  mk_msg "$box" 1
  pull 1000 peek
  assert_equals 1 "$(count_notices "$out")" "first peek names the record"
  assert_present "$S/inbox-pull/pending" "peek leaves a pending marker"
  assert_absent "$S/inbox-pull/cursor" "peek moves no cursor"
  pull 1100 peek
  assert_equals 1 "$(count_notices "$out")" "without a commit the record is named again"
  pull 1101 commit
  assert_absent "$S/inbox-pull/pending" "commit consumes the pending marker"
  assert_present "$S/inbox-pull/cursor" "commit writes the cursor"
  assert_equals "$box" "$(hb last_notified_inbox)" "heartbeat names the inbox last notified"
  assert_equals 1 "$(hb last_notified_seq)" "heartbeat names the seq last notified"
  assert_equals 1 "$(wc -l < "$S/inbox-pull/notices" | tr -d ' ')" "commit appends to the notice history the trip counts"
  pull 1200 peek
  assert_equals "" "$out" "a committed record is never named again"
  mk_msg "$box" 2
  pull 1300 peek
  assert_equals 1 "$(count_notices "$out")" "only the new record is named"
  assert_contains "$out" "002.msg" "the new record is 002"
  pull 1301 commit
  pull 1400 peek
  assert_equals "" "$out" "both ids are now seen"
  pass "two-phase commit: no commit, no cursor; committed ids never repeat"
}

test_commit_without_pending_is_a_noop() {
  new_home
  pull 1000 commit
  assert_absent "$S/inbox-pull/cursor" "commit with nothing pending writes no cursor"
  assert_present "$S/inbox-pull/heartbeat" "commit still refreshes the heartbeat"
  pass "commit without a pending marker is a no-op"
}

test_throttle_before_scan_and_heartbeat() {
  new_home
  local box="$S/parent-route/chief.inbox"
  mk_msg "$box" 1
  pull 1000 peek
  pull 1001 commit
  mk_msg "$box" 2
  pull 1010 peek
  assert_equals "" "$out" "a peek inside the 30 s window prints nothing"
  assert_equals 1010 "$(hb ts)" "a throttled peek still refreshes the heartbeat"
  assert_equals 1000 "$(hb last_check_ts)" "a throttled peek does not count as a scan"
  assert_absent "$S/inbox-pull/pending" "a throttled peek writes no pending marker"
  pull 1029 peek
  assert_equals "" "$out" "29 s after the scan is still throttled"
  pull 1030 peek
  assert_contains "$out" "002.msg" "30 s after the scan the new record is named"
  # a clock that moved backwards must not silence the pull for ever
  pull 500 peek
  assert_contains "$out" "002.msg" "a backwards clock rescans"
  pass "throttle: decided before the scan, heartbeat refreshed, backwards clock safe"
}

test_heartbeat_fields() {
  new_home
  pull 1000 beat
  local f
  for f in ts seq pid host last_check_ts last_notified_seq last_error killed; do
    grep -q "^$f=" "$S/inbox-pull/heartbeat" || fail "heartbeat lacks $f"
  done
  assert_equals 1000 "$(hb ts)" "heartbeat ts"
  assert_equals 4242 "$(hb pid)" "heartbeat pid"
  assert_equals 0 "$(hb killed)" "heartbeat killed"
  local before
  before=$(hb seq)
  pull 1001 beat
  assert_equals $((before + 1)) "$(hb seq)" "seq counts invocations"
  pass "heartbeat carries every contract field"
}

test_kill_switch() {
  new_home
  local box="$S/parent-route/chief.inbox"
  mk_msg "$box" 1
  out=$(FM_INBOX_PULL=0 FM_HOME="$H" FM_STATE_OVERRIDE="$S" FM_CONFIG_OVERRIDE="$H/config" FM_INBOX_PULL_NOW=1000 bash "$PULL" peek 2>&1)
  assert_equals "" "$out" "FM_INBOX_PULL=0 silences peek"
  assert_equals 1 "$(hb killed)" "the heartbeat reports the env kill"
  printf 'off\n' > "$S/.inbox-pull-off"
  pull 1100 peek
  assert_equals "" "$out" "the kill file silences peek"
  assert_equals 1 "$(hb killed)" "the heartbeat reports the file kill"
  rm -f "$S/.inbox-pull-off"
  pull 1200 peek
  assert_contains "$out" "001.msg" "removing the kill file resumes the pull"
  assert_equals 0 "$(hb killed)" "the heartbeat clears killed"
  pass "kill switch: env and file, resumable"
}

test_replay_trip() {
  new_home
  local box="$S/parent-route/chief.inbox" i t=1000
  mk_msg "$box" 1
  # 21 committed notices inside the last hour, spaced beyond the throttle
  mkdir -p "$S/inbox-pull"
  for i in $(seq 1 21); do printf '%s\n' $((9000 + i)) >> "$S/inbox-pull/notices"; done
  pull 9100 peek
  assert_equals "" "$out" "a tripped pull prints nothing"
  assert_present "$S/.inbox-pull-off" "the trip writes the kill file"
  grep -q 'tripped' "$S/.inbox-pull-off" || fail "the kill file carries a note"
  assert_equals 1 "$(hb killed)" "the heartbeat reports the trip"
  assert_contains "$(hb last_error)" "replay trip" "the heartbeat names the trip"
  assert_grep "replay trip" "$S/inbox-pull/log" "the trip is logged"
  pull $((t + 20000)) peek
  assert_equals "" "$out" "the pull stays off until an operator removes the file"
  pass "replay trip: more than 20 notices an hour writes the kill file"
}

test_trip_boundary_and_limit_clamp() {
  new_home
  local box="$S/parent-route/chief.inbox" i
  mk_msg "$box" 1
  mkdir -p "$S/inbox-pull"
  for i in $(seq 1 20); do printf '%s\n' $((9000 + i)) >> "$S/inbox-pull/notices"; done
  pull 9100 peek
  assert_contains "$out" "001.msg" "exactly 20 notices an hour still notify"
  assert_absent "$S/.inbox-pull-off" "exactly 20 notices an hour do not trip"
  new_home
  mk_msg "$S/parent-route/chief.inbox" 1
  out=$(FM_INBOX_PULL_LIMIT=0 FM_HOME="$H" FM_STATE_OVERRIDE="$S" FM_CONFIG_OVERRIDE="$H/config" FM_INBOX_PULL_NOW=1000 bash "$PULL" peek)
  assert_contains "$out" "001.msg" "a zero limit is clamped, not honoured"
  new_home
  mk_msg "$H/we*ird.inbox" 1
  out=$(FM_INBOX_PULL_DIR="$H/we*ird.inbox" FM_HOME="$H" FM_STATE_OVERRIDE="$S" FM_CONFIG_OVERRIDE="$H/config" FM_INBOX_PULL_NOW=1000 bash "$PULL" peek)
  assert_contains "$out" "we*ird.inbox/001.msg" "a glob character in an inbox path is not expanded"
  pass "trip boundary is exactly 20; a zero limit is clamped; glob characters in paths survive"
}

test_unknown_cursor_schema_migrates_without_replay() {
  new_home
  local box="$S/parent-route/chief.inbox"
  mk_msg "$box" 1
  mk_msg "$box" 2
  mkdir -p "$box/handled" "$S/inbox-pull"
  printf 'x\n' > "$box/handled/007.msg"
  mk_msg "$box" 9
  printf 'schema=fm-inbox-pull-cursor.v0\n%s 1\n' "$box" > "$S/inbox-pull/cursor"
  pull 1000 peek
  assert_not_contains "$out" "001.msg" "a record below the newest handled seq is not replayed"
  assert_not_contains "$out" "002.msg" "a record below the newest handled seq is not replayed (2)"
  assert_contains "$out" "009.msg" "a record above the newest handled seq is still noticed"
  assert_equals "schema=fm-inbox-pull-cursor.v1" "$(sed -n 1p "$S/inbox-pull/cursor")" "the cursor is rewritten as v1"
  printf 'garbage\n' > "$S/inbox-pull/cursor"
  pull 1100 peek
  assert_not_contains "$out" "001.msg" "an unreadable cursor never replays old records"
  pass "an unknown cursor schema is migrated, never replayed"
}

test_scan_set() {
  new_home
  local own="$H/own.inbox" cfgbox="$H/cfgbox" rel="$H/relbox"
  mk_msg "$S/parent-route/chief.inbox" 1
  mk_msg "$own" 1
  mk_msg "$cfgbox" 1
  mk_msg "$rel" 1
  printf '# comment\n\n%s\nrelbox\n%s\n' "$cfgbox" "$S/parent-route/chief.inbox" > "$H/config/inbox-pull-dirs"
  ln -s "$own" "$H/linked.inbox"
  out=$(FM_INBOX_PULL_DIR="$own:$H/linked.inbox:$H/missing" FM_HOME="$H" FM_STATE_OVERRIDE="$S" FM_CONFIG_OVERRIDE="$H/config" FM_INBOX_PULL_NOW=1000 bash "$PULL" peek)
  assert_contains "$out" "inbox-pull-notice:$S/parent-route/chief.inbox/001.msg" "parent-route inbox scanned"
  assert_contains "$out" "inbox-pull-notice:$own/001.msg" "FM_INBOX_PULL_DIR scanned"
  assert_contains "$out" "inbox-pull-notice:$cfgbox/001.msg" "config/inbox-pull-dirs absolute entry scanned"
  assert_contains "$out" "inbox-pull-notice:$rel/001.msg" "config/inbox-pull-dirs relative entry scanned"
  assert_not_contains "$out" "linked.inbox" "a symlinked inbox is skipped"
  assert_equals 4 "$(count_notices "$out")" "each inbox once despite duplicate listings"
  pass "scan set: parent-route, environment, config; deduplicated; symlinks skipped"
}

test_notice_cap() {
  new_home
  local box="$S/parent-route/chief.inbox" i
  for i in $(seq 1 25); do mk_msg "$box" "$i"; done
  pull 1000 peek
  assert_equals 20 "$(count_notices "$out")" "a notice names at most 20 records"
  assert_contains "$out" "+5 more waiting" "the remainder is counted"
  pull 1001 commit
  pull 1100 peek
  assert_equals 5 "$(count_notices "$out")" "the remaining records are named next"
  pass "notice cap: 20 per notice, the rest follow"
}

test_concurrent_peeks_notice_once() {
  new_home
  local box="$S/parent-route/chief.inbox" i
  mk_msg "$box" 1
  for i in 1 2 3 4 5 6; do
    (
      FM_HOME="$H" FM_STATE_OVERRIDE="$S" FM_CONFIG_OVERRIDE="$H/config" FM_INBOX_PULL_NOW=1000 \
        bash "$PULL" peek > "$H/out.$i" 2>/dev/null
    ) &
  done
  wait
  local total=0
  for i in 1 2 3 4 5 6; do
    total=$((total + $(grep -c '^inbox-pull-notice:' "$H/out.$i" || true)))
  done
  assert_equals 1 "$total" "six simultaneous peeks name the record exactly once"
  assert_absent "$S/inbox-pull/.lock" "the lock is released"
  pass "concurrent peeks print the notice at most once"
}

test_stale_lock_is_recovered() {
  new_home
  mk_msg "$S/parent-route/chief.inbox" 1
  mkdir -p "$S/inbox-pull/.lock"
  printf '99999999' > "$S/inbox-pull/.lock/pid"
  pull 1000 peek
  assert_contains "$out" "001.msg" "a lock left by a dead process does not block the pull"
  pass "a stale lock is recovered"
}

test_silent_contract_and_error_channel() {
  new_home
  # an unwritable state root must be silent and exit 0
  out=$(FM_HOME="$H" FM_STATE_OVERRIDE="/dev/null/nope" FM_CONFIG_OVERRIDE="$H/config" bash "$PULL" peek 2>&1)
  expect_code 0 $? "unwritable state exits 0"
  assert_equals "" "$out" "unwritable state prints nothing"
  pull 1000 beat --error "boom: extension failed
second line"
  assert_equals "boom: extension failed second line" "$(hb last_error)" "beat --error lands in the heartbeat as one line"
  assert_grep "extension error: boom" "$S/inbox-pull/log" "beat --error lands in the log"
  mk_msg "$S/parent-route/chief.inbox" 1
  pull 1100 peek
  assert_equals "" "$(hb last_error)" "a successful scan clears last_error"
  out=$(bash "$PULL" bogus 2>&1)
  expect_code 2 $? "an unknown command is a usage error"
  pass "silent contract: errors to heartbeat and log, exit 0"
}

test_mode_664_runs_through_its_interpreter() {
  new_home
  local copy="$TMP_ROOT/copy664"
  mkdir -p "$copy/bin"
  cp "$ROOT"/bin/fm-inbox-pull.sh "$ROOT"/bin/fm-task-inbox-lib.sh "$ROOT"/bin/fm-wake-lib.sh "$ROOT"/bin/fm-backend.sh "$copy/bin/"
  cp -R "$ROOT"/bin/backends "$copy/bin/backends" 2>/dev/null || true
  chmod 664 "$copy/bin/fm-inbox-pull.sh"
  mk_msg "$S/parent-route/chief.inbox" 1
  out=$(FM_ROOT_OVERRIDE="$copy" FM_HOME="$H" FM_STATE_OVERRIDE="$S" FM_CONFIG_OVERRIDE="$H/config" FM_INBOX_PULL_NOW=1000 bash "$copy/bin/fm-inbox-pull.sh" peek 2>&1)
  assert_contains "$out" "001.msg" "a mode-664 owner delivers when run through bash"
  pass "a mode-664 owner runs through its interpreter"
}

test_pending_is_an_open_transaction() {
  new_home
  local box="$S/parent-route/chief.inbox"
  mk_msg "$box" 1
  pull 1000 peek
  mk_msg "$box" 2
  pull 1100 peek
  assert_contains "$out" "001.msg" "a second peek replays the open set"
  assert_not_contains "$out" "002.msg" "a second peek cannot swap the open set for newer records"
  pull 1101 commit
  pull 1200 peek
  assert_contains "$out" "002.msg" "the newer record is named once the first set is committed"
  assert_not_contains "$out" "001.msg" "the committed record is not named again"
  pass "an uncommitted pending set is replayed, never overwritten"
}

test_commit_is_bound_to_its_transaction() {
  new_home
  local box="$S/parent-route/chief.inbox" txn
  mk_msg "$box" 1
  pull 1000 peek
  txn=$(printf '%s\n' "$out" | sed -n 's/^inbox-pull-txn://p')
  [ -n "$txn" ] || fail "the notice carries a transaction id"
  pull 1100 peek
  assert_equals "$txn" "$(printf '%s\n' "$out" | sed -n 's/^inbox-pull-txn://p')" "a replay keeps the transaction id"
  assert_not_contains "$out" "more waiting" "a replay does not advertise records it does not name"
  pull 1101 commit --txn "stale-$txn"
  assert_absent "$S/inbox-pull/cursor" "a commit for another transaction consumes nothing"
  assert_present "$S/inbox-pull/pending" "the open set survives a mismatched commit"
  pull 1102 commit --txn "$txn"
  assert_present "$S/inbox-pull/cursor" "the matching commit promotes the set"
  pass "a commit is bound to the transaction its notice carried"
}

test_handled_twin_and_read_only_status() {
  new_home
  local box="$S/parent-route/chief.inbox"
  mk_msg "$box" 1
  mkdir -p "$box/handled"
  cp "$box/001.msg" "$box/handled/001.msg"
  pull 1000 peek
  assert_equals "" "$out" "a root record whose twin sits in handled/ is never named"
  mkdir -p "$S/inbox-pull"
  printf 'schema=fm-inbox-pull-cursor.v0\n' > "$S/inbox-pull/cursor"
  FM_HOME="$H" FM_STATE_OVERRIDE="$S" FM_CONFIG_OVERRIDE="$H/config" bash "$PULL" status >/dev/null
  assert_equals "schema=fm-inbox-pull-cursor.v0" "$(sed -n 1p "$S/inbox-pull/cursor")" "status never rewrites the cursor"
  mk_msg "$box" 2
  cp "$box/002.msg" "$box/2.msg"
  cp "$box/002.msg" "$box/handled/2.msg"
  mk_msg "$box" 3
  cp "$box/003.msg" "$box/3.msg"
  pull 1100 peek
  assert_not_contains "$out" "002.msg" "a handled twin with a differently padded name suppresses the record"
  assert_equals 1 "$(printf '%s\n' "$out" | grep -c '/00\?3.msg\|/3.msg')" "two names for one sequence collapse to one line"
  pass "handled/ twins are never named and status is read-only"
}

test_stale_lock_race_names_once() {
  new_home
  mk_msg "$S/parent-route/chief.inbox" 1
  mkdir -p "$S/inbox-pull/.lock"
  printf '99999999' > "$S/inbox-pull/.lock/pid"
  local i total=0
  for i in 1 2 3 4 5 6 7 8; do
    (
      FM_HOME="$H" FM_STATE_OVERRIDE="$S" FM_CONFIG_OVERRIDE="$H/config" FM_INBOX_PULL_NOW=1000 \
        bash "$PULL" peek > "$H/race.$i" 2>/dev/null
    ) &
  done
  wait
  for i in 1 2 3 4 5 6 7 8; do
    total=$((total + $(grep -c '^inbox-pull-notice:' "$H/race.$i" || true)))
  done
  assert_equals 1 "$total" "eight peeks racing to reclaim a dead lock name the record exactly once"
  pass "a dead lock is reclaimed by exactly one contender"
}

test_status_reports_state() {
  new_home
  mk_msg "$S/parent-route/chief.inbox" 1
  pull 1000 peek
  out=$(FM_HOME="$H" FM_STATE_OVERRIDE="$S" FM_CONFIG_OVERRIDE="$H/config" bash "$PULL" status)
  assert_contains "$out" "pending=1" "status reports the pending record"
  assert_contains "$out" "unseen_now=1" "status reports the unseen record"
  assert_contains "$out" "killed_now=0" "status reports the kill state"
  assert_contains "$out" "scan_dirs=$S/parent-route/chief.inbox" "status reports the scan set"
  pass "status reports heartbeat, cursor and scan state"
}

test_fresh_peek_names_unhandled_once
test_two_phase_commit
test_commit_without_pending_is_a_noop
test_throttle_before_scan_and_heartbeat
test_heartbeat_fields
test_kill_switch
test_replay_trip
test_trip_boundary_and_limit_clamp
test_unknown_cursor_schema_migrates_without_replay
test_scan_set
test_notice_cap
test_concurrent_peeks_notice_once
test_stale_lock_is_recovered
test_silent_contract_and_error_channel
test_mode_664_runs_through_its_interpreter
test_pending_is_an_open_transaction
test_commit_is_bound_to_its_transaction
test_handled_twin_and_read_only_status
test_stale_lock_race_names_once
test_status_reports_state
