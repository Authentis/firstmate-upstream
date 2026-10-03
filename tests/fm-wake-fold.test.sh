#!/usr/bin/env bash
# tests/fm-wake-fold.test.sh - the wake fold (bin/fm-wake-fold-lib.sh) through
# the real watcher and drain: each fold class queues durably without waking,
# the digest delivers folded rows on its bound, the drain's --ack-if-routine
# acknowledges a routine presentation in one call, and every class the fold must
# never touch - decisions, failures, done, blocked, needs-decision, captain
# notes, unfolded recovery rows - still wakes at once with the fold on.
# config/wake-fold=off and an away record each restore the unfolded behavior.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-wake-fold-tests)
WATCH_PID=

file_mtime() {
  if [ "$(uname)" = Darwin ]; then stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi
}

# 0 once <pid>'s watcher has finished a whole poll cycle, 1 if it exited first.
wait_poll_cycle() {  # <state> <pid>
  local state=$1 pid=$2 beat first now i=0
  beat="$state/.last-watcher-beat"
  rm -f "$beat"
  first=""
  while [ "$i" -lt 300 ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    first=$(file_mtime "$beat")
    [ -n "$first" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  while [ "$i" -lt 300 ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    now=$(file_mtime "$beat")
    [ -n "$now" ] && [ "$now" != "$first" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

stop_watcher() {
  [ -n "$WATCH_PID" ] || return 0
  kill -TERM "$WATCH_PID" 2>/dev/null || true
  wait "$WATCH_PID" 2>/dev/null || true
  WATCH_PID=
}

# A case home whose state, config, and fakebin live under one directory.
make_fold_case() {  # <name> [secondmate]
  local dir
  dir=$(make_case "$1")
  mkdir -p "$dir/config"
  if [ "${2:-}" = secondmate ]; then
    printf 'schema=fm-secondmate-parent.v1\nroute=remote\n' > "$dir/.fm-secondmate-parent"
    printf 'mate\n' > "$dir/.fm-secondmate-home"
  fi
  printf '%s\n' "$dir"
}

watch_fold_bg() {  # <dir> [extra env assignments...]
  local dir=$1
  shift
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_CONFIG_OVERRIDE="$dir/config" FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_SECONDMATE_LIVENESS_SECS=99999999 FM_WAKE_FOLD_DIGEST_SECS=999999 "$@" \
    "$WATCH" > "$dir/watch.out" 2> "$dir/watch.err" &
  WATCH_PID=$!
}

drain() {  # <dir> [drain args...]
  local dir=$1
  shift
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_CONFIG_OVERRIDE="$dir/config" \
    "$DRAIN" "$@" > "$dir/drain.out" 2> "$dir/drain.err"
}

fold_append() {  # <dir> <kind> <key> <payload> <class>
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" FM_CONFIG_OVERRIDE="$1/config" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    . "$1/bin/fm-wake-fold-lib.sh"
    fm_wake_fold_append "$2" "$3" "$4" "$5"
  ' _ "$ROOT" "$2" "$3" "$4" "$5"
}

queue_rows() {  # <dir>
  awk 'END { print NR }' "$1/state/.wake-queue" 2>/dev/null || echo 0
}

register_check() {  # <dir> <id> <output>
  local file="$1/state/$2.check.sh"
  printf '#!/usr/bin/env bash\nprintf '"'"'%%s\\n'"'"' %q\n' "$3" > "$file"
  chmod 0700 "$file"
  FM_STATE_OVERRIDE="$1/state" "$ROOT/bin/fm-check-register.sh" "$2" >/dev/null \
    || fail "could not register check $2"
}

test_own_outbound_signal_folds_and_digest_delivers() {
  local dir state
  dir=$(make_fold_case own-outbound secondmate)
  state="$dir/state"
  printf 'done [at=%s]: reported the finished lane to the parent\n' "$(date +%s)" > "$state/parent-replies.status"
  watch_fold_bg "$dir"
  wait_poll_cycle "$state" "$WATCH_PID" || fail "watcher woke on its own outbound parent-channel report"
  wait_poll_cycle "$state" "$WATCH_PID" || fail "watcher woke on a folded row's re-arm"
  stop_watcher
  [ "$(queue_rows "$dir")" -eq 1 ] || fail "own outbound report was not queued durably as one row"
  grep -q $'\town-outbound$' "$state/.wake-fold" || fail "own outbound row was not recorded as folded"
  grep -q 'folded own outbound parent-channel signal' "$state/.watch-triage.log" \
    || fail "fold was not logged"

  watch_fold_bg "$dir" FM_WAKE_FOLD_DIGEST_SECS=1
  wait_for_exit "$WATCH_PID" 100 || fail "digest did not wake for the folded row"
  WATCH_PID=
  grep -q '^check: wake digest: 1 folded routine wake row(s) queued' "$dir/watch.out" \
    || fail "digest reason was not printed: $(cat "$dir/watch.out")"

  drain "$dir" --ack-if-routine || fail "routine drain failed"
  grep -q '^ROUTINE: nothing presented needs handling' "$dir/drain.out" \
    || fail "routine drain did not acknowledge: $(cat "$dir/drain.out" "$dir/drain.err")"
  grep -q 'parent-replies.status' "$dir/drain.out" || fail "routine drain did not present the folded row"
  grep -q WAKE_ACK_REQUIRED "$dir/drain.err" && fail "routine drain still asked for an acknowledgement"
  [ ! -s "$state/.wake-queue" ] || fail "routine acknowledgement left rows queued"
  pass "own outbound parent-channel report folds, the digest delivers it, and one drain call acknowledges it"
}

test_worker_terminal_events_never_fold() {
  local verb dir state
  for verb in needs-decision failed 'done' blocked; do
    dir=$(make_fold_case "never-$verb" secondmate)
    state="$dir/state"
    printf 'done [at=%s]: own report\n' "$(date +%s)" > "$state/parent-replies.status"
    printf '%s [at=%s]: worker event\n' "$verb" "$(date +%s)" > "$state/task.status"
    watch_fold_bg "$dir"
    wait_for_exit "$WATCH_PID" 100 || fail "worker $verb did not wake at once with the fold on"
    WATCH_PID=
    grep -q "^signal:.*$state/task.status" "$dir/watch.out" || fail "worker $verb wake did not name its status file"
    grep -q 'parent-replies.status' "$dir/watch.out" && fail "own report rode in the $verb wake reason instead of folding"
    drain "$dir" --ack-if-routine || fail "drain after worker $verb failed"
    grep -q WAKE_ACK_REQUIRED "$dir/drain.err" || fail "worker $verb drain was acknowledged as routine"
    grep -q '^ROUTINE:' "$dir/drain.out" && fail "worker $verb drain printed ROUTINE"
  done
  pass "needs-decision, failed, done, and blocked worker lines wake at once and are never acknowledged as routine"
}

test_check_repeat_folds_and_new_text_wakes() {
  local dir state
  dir=$(make_fold_case check-repeat)
  state="$dir/state"
  register_check "$dir" tool-updates 'tool updates: br update available'
  watch_fold_bg "$dir" FM_CHECK_INTERVAL=0
  wait_for_exit "$WATCH_PID" 100 || fail "first check output did not wake"
  WATCH_PID=
  grep -q 'tool updates: br update available' "$dir/watch.out" || fail "first check output was not the wake"
  drain "$dir" || fail "drain after first check failed"
  ack_drain_err "$state" "$dir/drain.err" >/dev/null 2>&1 || fail "could not acknowledge the first check"

  watch_fold_bg "$dir" FM_CHECK_INTERVAL=0
  wait_poll_cycle "$state" "$WATCH_PID" || fail "an identical check output woke again"
  wait_poll_cycle "$state" "$WATCH_PID" || fail "an identical check output woke on a later cycle"
  stop_watcher
  grep -q $'\tcheck-repeat$' "$state/.wake-fold" || fail "identical check output was not recorded as folded"

  register_check "$dir" tool-updates 'tool updates: dcg update available'
  watch_fold_bg "$dir" FM_CHECK_INTERVAL=0
  wait_for_exit "$WATCH_PID" 100 || fail "changed check output did not wake"
  WATCH_PID=
  grep -q 'tool updates: dcg update available' "$dir/watch.out" || fail "changed check output was not the wake"
  [ "$(queue_rows "$dir")" -eq 2 ] || fail "the folded repeat was not still queued beside the real wake"
  drain "$dir" --ack-if-routine || fail "drain after changed check failed"
  grep -q WAKE_ACK_REQUIRED "$dir/drain.err" || fail "a changed check output was acknowledged as routine"
  ack_drain_err "$state" "$dir/drain.err" >/dev/null 2>&1 || fail "could not acknowledge the changed check"
  [ ! -s "$state/.wake-queue" ] || fail "the real wake's acknowledgement did not also consume the folded repeat"
  pass "an identical check output folds, new check text wakes at once, and the folded repeat rides along"
}

test_rearm_folds_only_when_every_row_is_folded() {
  local dir state
  dir=$(make_fold_case rearm secondmate)
  state="$dir/state"
  fold_append "$dir" signal parent-replies.status "signal: $state/parent-replies.status" own-outbound \
    || fail "could not queue a folded row"
  watch_fold_bg "$dir"
  wait_poll_cycle "$state" "$WATCH_PID" || fail "a re-arm whose queue is only folded rows woke"
  grep -q 'folded rearm-resurface' "$state/.watch-triage.log" || fail "folded re-arm was not logged"

  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-inbox.sh" note -- 'please look at the decision-os gate' >/dev/null 2>&1 \
    || fail "could not leave a captain inbox note"
  wait_for_exit "$WATCH_PID" 100 || fail "a captain inbox note queued beside a folded row did not wake"
  WATCH_PID=
  grep -qx 'check: rearm-resurface' "$dir/watch.out" || fail "captain note did not resurface: $(cat "$dir/watch.out")"
  drain "$dir" --ack-if-routine || fail "drain after the captain note failed"
  grep -q 'captain inbox note' "$dir/drain.out" || fail "captain note was not presented"
  grep -q WAKE_ACK_REQUIRED "$dir/drain.err" || fail "a captain note was acknowledged as routine"
  pass "a re-arm folds only while every queued row is folded; a captain note beside them wakes at once"
}

test_recovery_with_unfolded_or_no_rows_still_wakes() {
  local dir state
  dir=$(make_fold_case rearm-unfolded)
  state="$dir/state"
  fold_append "$dir" check "$state/x.check.sh" "check: $state/x.check.sh: same" check-repeat \
    || fail "could not queue a folded row"
  append_wake "$state" stale 's:fm-task' 'stale: s:fm-task' || fail "could not queue a stale row"
  watch_fold_bg "$dir"
  wait_for_exit "$WATCH_PID" 100 || fail "an unfolded queued row did not re-arm"
  WATCH_PID=
  grep -qx 'check: rearm-resurface' "$dir/watch.out" || fail "unfolded recovery did not print the re-arm"
  drain "$dir" || fail "drain after the unfolded re-arm failed"
  ack_drain_err "$state" "$dir/drain.err" >/dev/null 2>&1 || fail "could not acknowledge the unfolded re-arm"

  dir=$(make_fold_case rearm-empty)
  state="$dir/state"
  append_wake "$state" stale 's:fm-task' 'stale: s:fm-task' || fail "could not queue a stale row"
  drain "$dir" || fail "drain of the empty-episode setup failed"
  ack_drain_err "$state" "$dir/drain.err" >/dev/null 2>&1 || fail "could not acknowledge the setup row"
  FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_recovery_marker_publish "$2/.watcher-down" downtime' \
    _ "$ROOT/bin/fm-wake-lib.sh" "$state" || fail "could not open a downtime episode"
  watch_fold_bg "$dir"
  wait_for_exit "$WATCH_PID" 100 || fail "an empty-queue recovery episode did not re-arm"
  WATCH_PID=
  grep -qx 'check: rearm-resurface' "$dir/watch.out" || fail "empty-queue recovery did not print the re-arm"
  pass "recovery with any unfolded row, or with an empty queue, still re-arms at once"
}

test_routine_drain_needs_unchanged_open_decisions() {
  local dir state
  dir=$(make_fold_case routine-decisions)
  state="$dir/state"
  printf 'needs-decision [key=pick] [at=%s]: pick a gate\n' "$(date +%s)" > "$state/task.status"
  fold_append "$dir" check "$state/x.check.sh" "check: $state/x.check.sh: same" check-repeat \
    || fail "could not queue a folded row"
  drain "$dir" --ack-if-routine || fail "first routine-mode drain failed"
  grep -q '^OPEN DECISIONS' "$dir/drain.out" || fail "open decision was not presented"
  grep -q WAKE_ACK_REQUIRED "$dir/drain.err" || fail "a newly presented open decision was acknowledged as routine"
  [ -s "$state/.wake-queue" ] || fail "a non-routine drain consumed rows"

  drain "$dir" --ack-if-routine || fail "second routine-mode drain failed"
  grep -q '^ROUTINE:' "$dir/drain.out" || fail "an unchanged, already-shown open decision blocked the routine acknowledgement"
  grep -q '^OPEN DECISIONS' "$dir/drain.out" || fail "the routine drain hid the still-open decision"
  [ ! -s "$state/.wake-queue" ] || fail "routine acknowledgement left rows queued"

  fold_append "$dir" check "$state/x.check.sh" "check: $state/x.check.sh: same" check-repeat \
    || fail "could not queue a folded row"
  append_wake "$state" signal task.status "signal: $state/task.status" || fail "could not queue a signal row"
  drain "$dir" --ack-if-routine || fail "mixed routine-mode drain failed"
  grep -q WAKE_ACK_REQUIRED "$dir/drain.err" || fail "a mixed queue was acknowledged as routine"
  [ "$(queue_rows "$dir")" -eq 2 ] || fail "a mixed routine-mode drain consumed rows"
  pass "the one-call acknowledgement needs only folded rows and an open-decision set already shown"
}

test_switch_off_and_away_restore_unfolded_waking() {
  local dir state mode
  for mode in switch-off away; do
    dir=$(make_fold_case "restore-$mode" secondmate)
    state="$dir/state"
    case "$mode" in
      switch-off) printf 'off\n' > "$dir/config/wake-fold" ;;
      away) : > "$state/.afk" ;;
    esac
    printf 'done [at=%s]: reported to the parent\n' "$(date +%s)" > "$state/parent-replies.status"
    watch_fold_bg "$dir"
    wait_for_exit "$WATCH_PID" 100 || fail "$mode: own outbound report did not wake"
    WATCH_PID=
    grep -q "^signal:.*parent-replies.status" "$dir/watch.out" || fail "$mode: own outbound report was not the wake"
    [ ! -s "$state/.wake-fold" ] || fail "$mode: a row was recorded as folded"
  done

  dir=$(make_fold_case restore-drain)
  state="$dir/state"
  fold_append "$dir" check "$state/x.check.sh" "check: $state/x.check.sh: same" check-repeat \
    || fail "could not queue a folded row"
  printf 'off\n' > "$dir/config/wake-fold"
  drain "$dir" --ack-if-routine || fail "switched-off routine-mode drain failed"
  grep -q WAKE_ACK_REQUIRED "$dir/drain.err" || fail "switched-off drain acknowledged by itself"
  grep -q '^ROUTINE:' "$dir/drain.out" && fail "switched-off drain printed ROUTINE"
  pass "config/wake-fold=off and an away record each restore immediate waking and a plain drain"
}

test_own_outbound_signal_folds_and_digest_delivers
test_worker_terminal_events_never_fold
test_check_repeat_folds_and_new_text_wakes
test_rearm_folds_only_when_every_row_is_folded
test_recovery_with_unfolded_or_no_rows_still_wakes
test_routine_drain_needs_unchanged_open_decisions
test_switch_off_and_away_restore_unfolded_waking
