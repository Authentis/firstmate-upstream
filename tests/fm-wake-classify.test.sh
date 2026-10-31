#!/usr/bin/env bash
# tests/fm-wake-classify.test.sh - pre-wake classification (bin/fm-wake-classify-lib.sh)
# through the library, the drain's --ack-routine-folded, and the real watcher:
# routine / non-urgent / urgent sorting, the watcher acknowledging routine rows
# itself with no turn, non-urgent rows batched into at most one digest per
# window, urgent wakes unchanged, no row lost or acknowledged twice, the
# config/wake-classify switch, and the wake-turn measurement line.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-wake-classify-tests)
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

make_classify_case() {  # <name>
  local dir
  dir=$(make_case "$1")
  mkdir -p "$dir/config"
  printf '%s\n' "$dir"
}

watch_bg() {  # <dir> [extra env assignments...]
  local dir=$1
  shift
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_CONFIG_OVERRIDE="$dir/config" FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_SECONDMATE_LIVENESS_SECS=99999999 FM_WAKE_FOLD_DIGEST_SECS=999999 \
    FM_WAKE_BATCH_SECS=999999 "$@" \
    "$WATCH" > "$dir/watch.out" 2> "$dir/watch.err" &
  WATCH_PID=$!
}

drain() {  # <dir> [drain args...]
  local dir=$1
  shift
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_CONFIG_OVERRIDE="$dir/config" \
    "$DRAIN" "$@" > "$dir/drain.out" 2> "$dir/drain.err"
}

# Run library code against a case home.
lib() {  # <dir> <bash-snippet> [args...]
  local dir=$1 snippet=$2
  shift 2
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_CONFIG_OVERRIDE="$dir/config" bash -c '
    root=$1; snippet=$2; shift 2
    . "$root/bin/fm-wake-lib.sh"
    . "$root/bin/fm-wake-fold-lib.sh"
    . "$root/bin/fm-wake-classify-lib.sh"
    eval "$snippet"
  ' _ "$ROOT" "$snippet" "$@"
}

fold_append() {  # <dir> <kind> <key> <payload> <class>
  lib "$1" 'fm_wake_fold_append "$@"' "$2" "$3" "$4" "$5"
}

batch_append() {  # <dir> <kind> <key> <payload>
  lib "$1" 'fm_wake_batch_append "$@"' "$2" "$3" "$4"
}

queue_rows() {  # <dir>
  awk 'END { print NR }' "$1/state/.wake-queue" 2>/dev/null || echo 0
}

register_check() {  # <dir> <id> <output> [exit-status]
  local file="$1/state/$2.check.sh"
  printf '#!/usr/bin/env bash\nprintf '"'"'%%s\\n'"'"' %q\n' "$3" > "$file"
  printf '\nexit %s\n' "${4:-0}" >> "$file"
  chmod 0700 "$file"
  FM_STATE_OVERRIDE="$1/state" "$ROOT/bin/fm-check-register.sh" "$2" >/dev/null \
    || fail "could not register check $2"
}

# Age every record line by <secs> so a row reads as having waited that long.
age_record() {  # <record-file> <secs>
  local tmp="$1.age"
  awk -F '\t' -v OFS='\t' -v d="$2" '{ $2 = $2 - d; print }' "$1" > "$tmp" && mv -f "$tmp" "$1"
}

measure_count() {  # <dir> <event>
  awk -F '\t' -v e="$2" '$2 == e { n++ } END { print n + 0 }' "$1/state/.wake-turns.log" 2>/dev/null || echo 0
}

# shellcheck disable=SC2016 # the snippet expands inside the library shell
batchable() {  # <dir> <check-path>
  lib "$1" 'fm_wake_check_batchable "$1"' "$2"
}

test_classifier_sorts_routine_nonurgent_urgent() {
  local dir out
  dir=$(make_classify_case sorting)
  check() {  # <expected> <kind> <key> <payload> [hint]
    out=$(lib "$dir" 'fm_wake_classify "$@"' "$2" "$3" "$4" "${5:-}")
    [ "$out" = "$1" ] || fail "classify $2 '$4' hint '${5:-}': expected $1, got $out"
  }
  check routine check x.check.sh 'check: x: same' fold:check-repeat
  check routine signal parent-replies.status 'signal: parent-replies.status' fold:own-outbound
  check nonurgent check tool-updates.check.sh 'check: tool-updates.check.sh: br update available' batch-check
  check nonurgent check fleet-drift.check.sh 'check: fleet-drift.check.sh: 2 homes behind origin' batch-check
  check urgent check validation-health.check.sh 'check: v: validation run stalled for 40 minutes' batch-check
  check urgent check main-red.check.sh 'check: m: main is RED' batch-check
  check urgent check x.check.sh 'check: x: captain asked about the gate' batch-check
  check urgent check x.check.sh 'check: x: Build FAILED on netcup' batch-check
  check urgent check x.check.sh 'check: x: deployment done' batch-check
  check urgent check x.check.sh 'check: x: review completed' batch-check
  check urgent check x.check.sh 'check: x: PR ready' batch-check
  check urgent check x.check.sh 'check: x: validation run stalling for 40 minutes' batch-check
  check urgent check x.check.sh 'check: x: sync completion reported' batch-check
  check urgent check x.check.sh 'check: x: 3 open decisions pending' batch-check
  check urgent check x.check.sh 'check: x: deploy blocking on gate, 2 blockers open' batch-check
  check urgent check x.check.sh 'check: x: ACTION REQUIRED: authentication expired; log in again' batch-check
  check urgent check x.check.sh 'check: x: credentials denied, quota exhausted' batch-check
  check urgent check x.check.sh 'check: x: critical vulnerability CVE-2026-1, patch now' batch-check
  check urgent check x.check.sh 'check: x: production rollout succeeded' batch-check
  check urgent check x.check.sh 'check: x: two homes unhealthy or offline' batch-check
  check nonurgent check x.check.sh 'check: x: download of dcg installed, update available' batch-check
  check urgent check x.check.sh 'check: x: update available' ''
  check urgent check x.check.sh 'check: x: update available' unknown-hint
  check nonurgent signal netcup.status 'signal: netcup.status' secondmate-progress
  check urgent stale default:w1:p2 'stale: default:w1:p2' secondmate-progress
  check urgent heartbeat heartbeat heartbeat batch-check
  check urgent signal task.status 'signal: task.status'
  check urgent bogus k p batch-check
  # A hint that does not match the row's kind never widens what may wait.
  check urgent signal task.status 'signal: task.status' batch-check
  check urgent check x.check.sh 'p' secondmate-progress
  check urgent check x.check.sh 'check: x: check incomplete' batch-check
  check urgent check x.check.sh $'check: x: request timed\nout' batch-check
  check urgent check x.check.sh 'check: x: registry invalid' batch-check
  out=$(FM_WAKE_URGENT_RE='(' lib "$dir" 'fm_wake_classify check k "check: update available" batch-check')
  [ "$out" = urgent ] || fail "a malformed FM_WAKE_URGENT_RE was read as no match: $out"
  out=$(FM_WAKE_URGENT_RE='needle' lib "$dir" 'fm_wake_classify check k "check: stalled" batch-check')
  [ "$out" = nonurgent ] || fail "FM_WAKE_URGENT_RE did not replace the default pattern: $out"
  # Only a named reporter check may be batched: mail, merge, and growth checks
  # are custom checks too and carry things the captain waits on.
  batchable "$dir" "/state/tool-updates.check.sh" || fail "the shipped tool-updates check is not batchable"
  batchable "$dir" "/state/mail.check.sh" && fail "an unlisted check was batchable"
  printf '# reporters\nfleet-drift.check.sh  # weekly\n\nsm-context\n' > "$dir/config/wake-batch-checks"
  batchable "$dir" "/state/fleet-drift.check.sh" || fail "a listed .check.sh name was not batchable"
  batchable "$dir" "/state/sm-context.check.sh" || fail "a listed bare id was not batchable"
  batchable "$dir" "/state/mail.check.sh" && fail "the config list widened to an unlisted check"
  pass "classifier sorts routine, non-urgent, and urgent rows, defaults everything unnamed to urgent, and batches only named reporter checks"
}

test_batch_record_is_durable_deduped_and_not_routine() {
  local dir state
  dir=$(make_classify_case batch-record)
  state="$dir/state"
  batch_append "$dir" check x.check.sh 'check: x: new text' || fail "could not batch a row"
  batch_append "$dir" check x.check.sh 'check: x: new text' || fail "could not re-batch an identical row"
  batch_append "$dir" check y.check.sh 'check: y: other' || fail "could not batch a second row"
  [ "$(queue_rows "$dir")" -eq 2 ] || fail "batch append did not dedupe an identical queued row: $(cat "$state/.wake-queue")"
  [ "$(awk 'END { print NR }' "$state/.wake-batch")" -eq 2 ] || fail "batch record does not name both rows"
  [ ! -s "$state/.wake-fold" ] || fail "a batched row leaked into the fold record"
  [ "$(measure_count "$dir" batched)" -eq 2 ] || fail "batched rows were not measured"

  drain "$dir" --ack-if-routine || fail "drain of batched rows failed"
  grep -q WAKE_ACK_REQUIRED "$dir/drain.err" || fail "a batched row was acknowledged as routine"
  grep -q '^ROUTINE:' "$dir/drain.out" && fail "a batched row drain printed ROUTINE"
  grep -q 'x.check.sh' "$dir/drain.out" || fail "the batched row was not presented"
  [ "$(queue_rows "$dir")" -eq 2 ] || fail "presenting batched rows consumed them"
  ack_drain_err "$state" "$dir/drain.err" >/dev/null 2>&1 || fail "could not acknowledge the batched rows"
  [ ! -s "$state/.wake-queue" ] || fail "acknowledging the batched rows left rows queued"
  pass "a batched row is durable, deduped, never routine, and consumed only by the ordinary acknowledgement"
}

test_batch_digest_honors_window_and_one_per_window() {
  local dir state out
  dir=$(make_classify_case batch-digest)
  state="$dir/state"
  batch_append "$dir" check x.check.sh 'check: x: new text' || fail "could not batch a row"
  out=$(FM_WAKE_BATCH_SECS=900 lib "$dir" 'fm_wake_batch_digest_due') && fail "a fresh batched row was due: $out"
  age_record "$state/.wake-batch" 880
  out=$(FM_WAKE_BATCH_SECS=900 lib "$dir" 'fm_wake_batch_digest_due') && fail "a row 880s old was due: $out"
  age_record "$state/.wake-batch" 30
  out=$(FM_WAKE_BATCH_SECS=900 lib "$dir" 'fm_wake_batch_digest_due') || fail "a row 910s old was not due"
  case "$out" in
    'check: wake digest: 1 batched non-urgent wake row(s) queued, oldest '*s) ;;
    *) fail "digest reason has the wrong shape: $out" ;;
  esac

  # One digest per window: after a digest wake is marked, an even older row
  # waits for the window to pass again.
  FM_WAKE_BATCH_SECS=900 lib "$dir" 'fm_wake_batch_digest_mark'
  age_record "$state/.wake-batch" 5000
  out=$(FM_WAKE_BATCH_SECS=900 lib "$dir" 'fm_wake_batch_digest_due') && fail "a second digest was due inside the window: $out"
  printf '%s\n' "$(($(date +%s) - 901))" > "$state/.wake-batch-last"
  out=$(FM_WAKE_BATCH_SECS=900 lib "$dir" 'fm_wake_batch_digest_due') || fail "the digest was not due after the window"

  # A record line whose row was acknowledged is stale and never due.
  : > "$state/.wake-queue"
  out=$(FM_WAKE_BATCH_SECS=900 lib "$dir" 'fm_wake_batch_digest_due') && fail "a digest was due for an acknowledged row: $out"
  [ ! -e "$state/.wake-batch" ] || fail "the stale batch record was not pruned"
  pass "the batch digest waits for the window, raises once per window, and never fires for an acknowledged row"
}

# Queue a routine folded row and age it. Echo nothing; the caller reads the files.
queue_aged_routine() {  # <dir> <key> <age-secs>
  fold_append "$1" check "$2" "check: $2: same" check-repeat || fail "could not queue a routine row"
  age_record "$1/state/.wake-fold" "$3"
}

test_ack_routine_folded_acks_only_aged_unclaimed_routine_rows() {
  local dir state
  dir=$(make_classify_case ack-routine)
  state="$dir/state"
  queue_aged_routine "$dir" a.check.sh 1000
  fold_append "$dir" check b.check.sh 'check: b: same' check-repeat || fail "could not queue a young routine row"
  append_wake "$state" stale 's:task' 'stale: s:task' || fail "could not queue a stale row"
  batch_append "$dir" check c.check.sh 'check: c: new' || fail "could not batch a row"
  age_record "$state/.wake-batch" 1000

  drain "$dir" --ack-routine-folded 900 || fail "routine acknowledgement failed"
  grep -q '^ROUTINE-ACKED: .* 1 routine folded wake row(s)' "$dir/drain.out" \
    || fail "routine acknowledgement did not report one row: $(cat "$dir/drain.out" "$dir/drain.err")"
  [ "$(queue_rows "$dir")" -eq 3 ] || fail "routine acknowledgement removed the wrong rows: $(cat "$state/.wake-queue")"
  grep -q 'a.check.sh' "$state/.wake-queue" && fail "the aged routine row stayed queued"
  grep -q 'b.check.sh' "$state/.wake-queue" || fail "a young routine row was removed"
  grep -q 's:task' "$state/.wake-queue" || fail "a stale row was removed"
  grep -q 'c.check.sh' "$state/.wake-queue" || fail "a batched row was removed"
  [ "$(measure_count "$dir" routine-ack)" -eq 1 ] || fail "the routine acknowledgement was not measured"

  # Replaying acknowledges nothing a second time.
  drain "$dir" --ack-routine-folded 900 || fail "replayed routine acknowledgement failed"
  grep -q '^ROUTINE-ACKED' "$dir/drain.out" && fail "a replay acknowledged a row again"
  [ "$(measure_count "$dir" routine-ack)" -eq 1 ] || fail "a replay was measured as a second acknowledgement"
  [ "$(queue_rows "$dir")" -eq 3 ] || fail "a replay changed the queue"
  pass "the watcher acknowledgement removes only aged routine rows, once, and leaves every other row queued"
}

test_ack_routine_folded_respects_claims_marker_and_switches() {
  local dir state token
  dir=$(make_classify_case ack-guards)
  state="$dir/state"

  # A row main was presented (claimed) is never taken from under its handling.
  queue_aged_routine "$dir" a.check.sh 1000
  drain "$dir" || fail "drain to claim rows failed"
  [ -s "$state/.main-eligible-rows" ] || fail "setup: the drain claimed no row"
  drain "$dir" --ack-routine-folded 900 || fail "acknowledgement over a claimed row failed"
  [ "$(queue_rows "$dir")" -eq 1 ] || fail "a presented, claimed row was removed by the watcher"
  ack_drain_err "$state" "$dir/drain.err" >/dev/null 2>&1 || true

  # A drain that died after claiming a row, before reaching handling, leaves the
  # row claimed under a downtime marker: the watcher must say so, not go silent.
  dir=$(make_classify_case ack-claimed-crash)
  state="$dir/state"
  queue_aged_routine "$dir" a.check.sh 1000
  printf '%s\n' "$(awk -F '\t' 'NR == 1 { print $2 }' "$state/.wake-queue")" > "$state/.main-eligible-rows"
  case "$(cat "$state/.watcher-down")" in pending:downtime:*) ;; *) fail "setup: no pending downtime marker" ;; esac
  drain "$dir" --ack-routine-folded 900 || fail "claimed-row acknowledgement failed"
  grep -q '^ROUTINE-HELD: an aged routine row is claimed' "$dir/drain.out" \
    || fail "an aged, claimed routine row did not report a hold: $(cat "$dir/drain.out")"
  [ "$(queue_rows "$dir")" -eq 1 ] || fail "a claimed row was removed"

  # A claimed aged row beside a removable one is still reported, so the
  # fallback is never skipped while fresh rows keep arriving.
  queue_aged_routine "$dir" b.check.sh 1000
  drain "$dir" --ack-routine-folded 900 || fail "mixed claimed-and-removable acknowledgement failed"
  grep -q '^ROUTINE-ACKED' "$dir/drain.out" || fail "the removable row was not acknowledged: $(cat "$dir/drain.out")"
  grep -q '^ROUTINE-HELD: an aged routine row is claimed' "$dir/drain.out" \
    || fail "a claimed aged row beside a removed one did not report a hold: $(cat "$dir/drain.out")"
  grep -q 'a.check.sh' "$state/.wake-queue" || fail "the claimed row was removed"

  # A handling episode in flight leaves every row queued and says so, so the
  # watcher falls back to the fold digest rather than going silent.
  dir=$(make_classify_case ack-handling)
  state="$dir/state"
  queue_aged_routine "$dir" a.check.sh 1000
  # shellcheck disable=SC2016 # the snippet expands inside the library shell
  lib "$dir" 'fm_recovery_marker_begin_handling "$STATE/.watcher-down"' || fail "could not open a handling episode"
  token=$(cat "$state/.watcher-down")
  drain "$dir" --ack-routine-folded 900 || fail "acknowledgement during handling failed"
  grep -q '^ROUTINE-HELD: a handling episode' "$dir/drain.out" || fail "a handling episode did not report a hold: $(cat "$dir/drain.out")"
  [ "$(queue_rows "$dir")" -eq 1 ] || fail "a row was removed during a handling episode"
  [ "$(cat "$state/.watcher-down")" = "$token" ] || fail "the handling episode marker changed"

  # Emptying the queue retires the downtime generation like an ordinary ack.
  dir=$(make_classify_case ack-marker)
  state="$dir/state"
  queue_aged_routine "$dir" a.check.sh 1000
  case "$(cat "$state/.watcher-down")" in pending:downtime:*) ;; *) fail "setup: no pending downtime marker" ;; esac
  drain "$dir" --ack-routine-folded 900 || fail "marker-retiring acknowledgement failed"
  [ ! -s "$state/.wake-queue" ] || fail "the queue kept the routine row"
  case "$(cat "$state/.watcher-down")" in acked:downtime:*) ;; *) fail "the downtime generation was not retired: $(cat "$state/.watcher-down")" ;; esac

  # Both switches restore the unacknowledged behavior.
  for sw in wake-classify wake-fold; do
    dir=$(make_classify_case "ack-off-$sw")
    state="$dir/state"
    queue_aged_routine "$dir" a.check.sh 1000
    printf 'off\n' > "$dir/config/$sw"
    drain "$dir" --ack-routine-folded 900 || fail "$sw=off acknowledgement failed"
    [ "$(queue_rows "$dir")" -eq 1 ] || fail "$sw=off still let the watcher acknowledge a row"
  done

  # It is the main actor's acknowledgement only.
  dir=$(make_classify_case ack-actor)
  queue_aged_routine "$dir" a.check.sh 1000
  FM_SUPERVISION_ACTOR=branch drain "$dir" --ack-routine-folded 900 && fail "a branch actor ran the watcher acknowledgement"
  [ "$(queue_rows "$dir")" -eq 1 ] || fail "a refused acknowledgement removed a row"
  drain "$dir" --ack-routine-folded nope && fail "a malformed age was accepted"
  pass "the watcher acknowledgement skips claimed rows and handling episodes, retires an emptied downtime generation, and honors both switches"
}

test_unread_status_holds_the_watcher_acknowledgement() {
  local dir state
  dir=$(make_classify_case ack-held)
  state="$dir/state"
  queue_aged_routine "$dir" a.check.sh 1000
  printf 'note [at=%s]: answer for the captain\n' "$(date +%s)" > "$state/task.status"
  drain "$dir" --ack-routine-folded 900 || fail "held acknowledgement failed"
  grep -q '^ROUTINE-HELD:' "$dir/drain.out" || fail "unread status did not hold the acknowledgement: $(cat "$dir/drain.out")"
  [ "$(queue_rows "$dir")" -eq 1 ] || fail "a held acknowledgement removed the routine row"
  [ "$(measure_count "$dir" routine-ack)" -eq 0 ] || fail "a held acknowledgement was measured as an acknowledgement"

  # The watcher then falls back to the fold digest, so a presented drain
  # surfaces the unread line and only then acknowledges.
  watch_bg "$dir" FM_WAKE_FOLD_DIGEST_SECS=900
  wait_for_exit "$WATCH_PID" 100 || fail "the watcher did not fall back to the fold digest for unread status"
  WATCH_PID=
  grep -q '^check: wake digest: 1 folded routine wake row(s) queued' "$dir/watch.out" \
    || fail "the fallback digest was not raised: $(cat "$dir/watch.out")"
  pass "unread status holds the watcher acknowledgement and the fold digest wakes the model for it"
}

test_watcher_acks_routine_rows_without_a_turn() {
  local dir state
  dir=$(make_classify_case watch-routine)
  state="$dir/state"
  queue_aged_routine "$dir" a.check.sh 1000
  watch_bg "$dir" FM_WAKE_FOLD_DIGEST_SECS=900
  wait_poll_cycle "$state" "$WATCH_PID" || fail "the watcher woke for an aged routine row"
  wait_poll_cycle "$state" "$WATCH_PID" || fail "the watcher woke on a later cycle for a routine row"
  stop_watcher
  [ ! -s "$state/.wake-queue" ] || fail "the watcher left the aged routine row queued: $(cat "$state/.wake-queue")"
  [ ! -s "$dir/watch.out" ] || fail "the watcher printed a wake for a routine row: $(cat "$dir/watch.out")"
  [ "$(measure_count "$dir" routine-ack)" -eq 1 ] || fail "the watcher acknowledgement was not measured"
  [ "$(measure_count "$dir" turn)" -eq 0 ] || fail "a routine row was counted as a turn"

  # With classification off, the fold digest wakes for the routine row as before.
  dir=$(make_classify_case watch-routine-off)
  state="$dir/state"
  printf 'off\n' > "$dir/config/wake-classify"
  queue_aged_routine "$dir" a.check.sh 1000
  watch_bg "$dir" FM_WAKE_FOLD_DIGEST_SECS=900
  wait_for_exit "$WATCH_PID" 100 || fail "classification off did not wake the fold digest"
  WATCH_PID=
  grep -q '^check: wake digest: 1 folded routine wake row(s) queued' "$dir/watch.out" \
    || fail "classification off changed the digest reason: $(cat "$dir/watch.out")"
  [ "$(measure_count "$dir" turn)" -eq 1 ] || fail "the digest wake was not counted as a turn"
  pass "the watcher acknowledges aged routine rows itself with no wake, and classification off restores the fold digest"
}

test_watcher_batches_nonurgent_checks_and_wakes_urgent_ones() {
  local dir state
  dir=$(make_classify_case watch-checks)
  state="$dir/state"
  register_check "$dir" tool-updates 'tool updates: br update available'
  watch_bg "$dir" FM_CHECK_INTERVAL=0
  wait_poll_cycle "$state" "$WATCH_PID" || fail "a non-urgent check output woke at once"
  wait_poll_cycle "$state" "$WATCH_PID" || fail "a non-urgent check output woke on a later cycle"
  stop_watcher
  [ ! -s "$dir/watch.out" ] || fail "the watcher printed a wake for a non-urgent check: $(cat "$dir/watch.out")"
  grep -q 'br update available' "$state/.wake-queue" || fail "the non-urgent check output was not queued"
  grep -q $'\tnonurgent$' "$state/.wake-batch" || fail "the non-urgent row was not recorded as batched"
  [ "$(measure_count "$dir" turn)" -eq 0 ] || fail "a batched row was counted as a turn"

  # The same output again is a repeat of the row still queued: no second row,
  # no wake.
  watch_bg "$dir" FM_CHECK_INTERVAL=0
  wait_poll_cycle "$state" "$WATCH_PID" || fail "a repeated check output woke"
  wait_poll_cycle "$state" "$WATCH_PID" || fail "a repeated check output woke on a later cycle"
  stop_watcher
  [ "$(awk 'END { print NR }' "$state/.wake-batch")" -eq 1 ] || fail "a repeat was batched again"
  [ "$(queue_rows "$dir")" -eq 1 ] || fail "a repeat queued a second row: $(cat "$state/.wake-queue")"
  [ ! -s "$dir/watch.out" ] || fail "a repeat woke: $(cat "$dir/watch.out")"

  # An urgent-looking new output wakes at once and carries the batched row along.
  register_check "$dir" tool-updates 'tool updates: validation run stalled'
  watch_bg "$dir" FM_CHECK_INTERVAL=0
  wait_for_exit "$WATCH_PID" 100 || fail "an urgent check output did not wake at once"
  WATCH_PID=
  grep -q 'validation run stalled' "$dir/watch.out" || fail "the urgent wake did not carry its text"
  [ "$(queue_rows "$dir")" -eq 2 ] || fail "the batched row was not still queued beside the urgent wake"
  drain "$dir" || fail "drain after the urgent wake failed"
  grep -q 'validation run stalled' "$dir/drain.out" || fail "the urgent row was not presented"
  ack_drain_err "$state" "$dir/drain.err" >/dev/null 2>&1 || fail "could not acknowledge the urgent wake"
  [ ! -s "$state/.wake-queue" ] || fail "the acknowledgement left the batched row queued"
  pass "a non-urgent check batches without waking, a repeat adds nothing, and an urgent output wakes at once with the batch riding along"
}

test_watcher_wakes_for_a_custom_check_that_is_not_an_opted_in_reporter() {
  local dir state
  dir=$(make_classify_case watch-unlisted)
  state="$dir/state"
  register_check "$dir" mail 'new mail: br update available'
  watch_bg "$dir" FM_CHECK_INTERVAL=0
  wait_for_exit "$WATCH_PID" 100 || fail "an unlisted custom check was batched instead of waking"
  WATCH_PID=
  grep -q 'new mail' "$dir/watch.out" || fail "the unlisted check wake did not carry its text"
  [ ! -s "$state/.wake-batch" ] || fail "an unlisted check was recorded as batched"

  dir=$(make_classify_case watch-optin)
  state="$dir/state"
  printf 'sm-context\n' > "$dir/config/wake-batch-checks"
  register_check "$dir" sm-context 'sm context: 3 mates above 60 percent'
  watch_bg "$dir" FM_CHECK_INTERVAL=0
  wait_poll_cycle "$state" "$WATCH_PID" || fail "an opted-in check woke at once"
  wait_poll_cycle "$state" "$WATCH_PID" || fail "an opted-in check woke on a later cycle"
  stop_watcher
  [ ! -s "$dir/watch.out" ] || fail "an opted-in check printed a wake: $(cat "$dir/watch.out")"
  grep -q $'\tnonurgent$' "$state/.wake-batch" || fail "the opted-in check was not batched"
  pass "only an opted-in reporter check batches; any other custom check still wakes with its text"
}

test_watcher_delivers_one_batched_digest_per_window() {
  local dir state
  dir=$(make_classify_case watch-digest)
  state="$dir/state"
  batch_append "$dir" check x.check.sh 'check: x: new text' || fail "could not batch a row"
  age_record "$state/.wake-batch" 1000
  watch_bg "$dir" FM_WAKE_BATCH_SECS=900
  wait_for_exit "$WATCH_PID" 100 || fail "the batched digest did not wake after the window"
  WATCH_PID=
  grep -q '^check: wake digest: 1 batched non-urgent wake row(s) queued' "$dir/watch.out" \
    || fail "the batched digest reason was not printed: $(cat "$dir/watch.out")"
  [ "$(measure_count "$dir" turn)" -eq 1 ] || fail "the digest wake was not counted as one turn"
  [ -s "$state/.wake-batch-last" ] || fail "a delivered batched digest did not start its window"

  # The row is still queued (not yet handled): a second watcher inside the same
  # window must not raise a second digest.
  watch_bg "$dir" FM_WAKE_BATCH_SECS=900
  wait_poll_cycle "$state" "$WATCH_PID" || fail "a second digest woke inside the window"
  wait_poll_cycle "$state" "$WATCH_PID" || fail "a second digest woke on a later cycle"
  stop_watcher
  [ "$(measure_count "$dir" turn)" -eq 1 ] || fail "a second batched turn started inside one window"
  [ -s "$state/.wake-queue" ] || fail "the unhandled batched row was dropped"

  drain "$dir" --ack-if-routine || fail "digest drain failed"
  grep -q WAKE_ACK_REQUIRED "$dir/drain.err" || fail "the batched digest was acknowledged as routine"
  grep -q 'x.check.sh' "$dir/drain.out" || fail "the digest drain did not present the batched row"
  pass "the batched digest wakes once the oldest row is a window old and never twice in one window"
}

test_classification_switched_off_still_delivers_a_recorded_batch() {
  local dir state
  dir=$(make_classify_case batch-switch-off)
  state="$dir/state"
  batch_append "$dir" check x.check.sh 'check: x: new text' || fail "could not batch a row"
  age_record "$state/.wake-batch" 1000
  printf 'off\n' > "$dir/config/wake-classify"
  watch_bg "$dir" FM_WAKE_BATCH_SECS=900
  wait_for_exit "$WATCH_PID" 100 || fail "a recorded batch stranded after classification went off"
  WATCH_PID=
  grep -q '^check: wake digest: 1 batched non-urgent wake row(s) queued' "$dir/watch.out" \
    || fail "the batch was not delivered through the digest: $(cat "$dir/watch.out")"
  pass "switching classification off still delivers an already-recorded batch"
}

test_watcher_batches_secondmate_progress_and_wakes_events() {
  local dir state
  dir=$(make_classify_case watch-secondmate)
  state="$dir/state"
  printf 'window=remote:mate\nkind=secondmate\nmode=secondmate\n' > "$state/mate.meta"
  printf 'working [at=%s]: reading the order\n' "$(date +%s)" > "$state/mate.status"
  watch_bg "$dir"
  wait_poll_cycle "$state" "$WATCH_PID" || fail "secondmate progress woke at once"
  wait_poll_cycle "$state" "$WATCH_PID" || fail "secondmate progress woke on a later cycle"
  stop_watcher
  [ ! -s "$dir/watch.out" ] || fail "a secondmate progress line printed a wake: $(cat "$dir/watch.out")"
  grep -q 'mate.status' "$state/.wake-queue" || fail "the secondmate progress row was not queued"
  grep -q $'\tnonurgent$' "$state/.wake-batch" || fail "the progress row was not recorded as batched"

  # A captain-relevant event on the same lane wakes at once.
  printf 'done [at=%s]: finished the order\n' "$(date +%s)" >> "$state/mate.status"
  watch_bg "$dir"
  wait_for_exit "$WATCH_PID" 100 || fail "a secondmate done line did not wake at once"
  WATCH_PID=
  grep -q "^signal:.*$state/mate.status" "$dir/watch.out" || fail "the done wake did not name the lane: $(cat "$dir/watch.out")"

  # A declared pause is progress too; an unknown verb is parent-directed and wakes.
  dir=$(make_classify_case watch-secondmate-paused)
  state="$dir/state"
  printf 'window=remote:mate\nkind=secondmate\nmode=secondmate\n' > "$state/mate.meta"
  printf 'paused [at=%s]: waiting on an external check\n' "$(date +%s)" > "$state/mate.status"
  watch_bg "$dir"
  wait_poll_cycle "$state" "$WATCH_PID" || fail "a secondmate paused line woke at once"
  wait_poll_cycle "$state" "$WATCH_PID" || fail "a secondmate paused line woke on a later cycle"
  stop_watcher
  grep -q $'\tnonurgent$' "$state/.wake-batch" || fail "a secondmate paused line was not batched"
  dir=$(make_classify_case watch-secondmate-unknown)
  state="$dir/state"
  printf 'window=remote:mate\nkind=secondmate\nmode=secondmate\n' > "$state/mate.meta"
  printf 'banana [at=%s]: something unrecognised\n' "$(date +%s)" > "$state/mate.status"
  watch_bg "$dir"
  wait_for_exit "$WATCH_PID" 100 || fail "a secondmate unknown-verb line was held back"
  WATCH_PID=
  [ ! -s "$state/.wake-batch" ] || fail "a secondmate unknown-verb line was batched"

  # A bare secondmate turn-end (no status event, no busy evidence) may be a
  # silent finish or a wedge, so it wakes at once.
  dir=$(make_classify_case watch-secondmate-turnend)
  state="$dir/state"
  printf 'window=remote:mate\nkind=secondmate\nmode=secondmate\n' > "$state/mate.meta"
  : > "$state/mate.turn-ended"
  watch_bg "$dir"
  wait_for_exit "$WATCH_PID" 100 || fail "a bare secondmate turn-end was held back"
  WATCH_PID=
  [ ! -s "$state/.wake-batch" ] || fail "a bare secondmate turn-end was batched"

  # A note: or corr= line from a secondmate is parent-directed content: it wakes.
  local marker
  for marker in 'note [at=1]: captain, need your call' 'working corr=abc [at=1]: reply'; do
    dir=$(make_classify_case watch-secondmate-note)
    state="$dir/state"
    printf 'window=remote:mate\nkind=secondmate\nmode=secondmate\n' > "$state/mate.meta"
    printf '%s\n' "$marker" > "$state/mate.status"
    watch_bg "$dir"
    wait_for_exit "$WATCH_PID" 100 || fail "secondmate line '$marker' was held back"
    WATCH_PID=
    [ ! -s "$state/.wake-batch" ] || fail "secondmate line '$marker' was batched"
  done

  # A worker (non-secondmate) progress line is not batched.
  dir=$(make_classify_case watch-worker)
  state="$dir/state"
  printf 'window=w\nkind=ship\n' > "$state/task.meta"
  printf 'working [at=%s]: reading the code\n' "$(date +%s)" > "$state/task.status"
  watch_bg "$dir"
  wait_for_exit "$WATCH_PID" 100 || fail "a worker progress line was held back"
  WATCH_PID=
  [ ! -s "$state/.wake-batch" ] || fail "a worker progress line was batched"
  pass "secondmate progress batches without waking while its events and every worker line still wake at once"
}

test_watcher_acknowledgement_refuses_unproven_recovery_state_and_pending_outcomes() {
  local dir state
  # An absent or malformed recovery marker is the ordinary drain's to adopt or refuse.
  dir=$(make_classify_case ack-marker-absent)
  state="$dir/state"
  queue_aged_routine "$dir" a.check.sh 1000
  rm -f "$state/.watcher-down"
  drain "$dir" --ack-routine-folded 900 || fail "absent-marker acknowledgement failed"
  grep -q '^ROUTINE-HELD:' "$dir/drain.out" || fail "an absent recovery marker did not hold: $(cat "$dir/drain.out")"
  [ "$(queue_rows "$dir")" -eq 1 ] || fail "an absent recovery marker let the watcher remove a row"
  printf 'garbage\n' > "$state/.watcher-down"
  drain "$dir" --ack-routine-folded 900 || fail "malformed-marker acknowledgement failed"
  grep -q '^ROUTINE-HELD:' "$dir/drain.out" || fail "a malformed recovery marker did not hold"
  [ "$(queue_rows "$dir")" -eq 1 ] || fail "a malformed recovery marker let the watcher remove a row"

  # A recorded captain outcome the drain would present holds the acknowledgement.
  command -v jq >/dev/null 2>&1 || { pass "(jq absent: the pending-outcome hold is not exercised) the watcher acknowledgement refuses an unproven recovery marker"; return 0; }
  dir=$(make_classify_case ack-outcome)
  state="$dir/state"
  queue_aged_routine "$dir" a.check.sh 1000
  : > "$dir/config/supervision-host"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$dir/config" FM_TEST_SEAM=1 FM_TEST_HARNESS=claude     "$ROOT/bin/fm-branch-outcome.sh" append --task t --verdict captain --summary 'PR ready' >/dev/null 2>&1     || fail "could not record a captain outcome"
  [ -s "$state/branch-outcomes.jsonl" ] || fail "setup: no outcome was recorded"
  FM_TEST_SEAM=1 FM_TEST_HARNESS=claude drain "$dir" --ack-routine-folded 900 || fail "pending-outcome acknowledgement failed"
  grep -q '^ROUTINE-HELD:' "$dir/drain.out" || fail "a pending captain outcome did not hold: $(cat "$dir/drain.out" "$dir/drain.err")"
  [ "$(queue_rows "$dir")" -eq 1 ] || fail "a pending captain outcome let the watcher remove a row"
  pass "the watcher acknowledgement refuses an absent or malformed recovery marker and a pending captain outcome"
}

test_fold_switched_off_after_queueing_still_delivers_through_the_digest() {
  local dir state
  dir=$(make_classify_case fold-off-after-queue)
  state="$dir/state"
  queue_aged_routine "$dir" a.check.sh 1000
  printf 'off\n' > "$dir/config/wake-fold"
  watch_bg "$dir" FM_WAKE_FOLD_DIGEST_SECS=900
  wait_for_exit "$WATCH_PID" 100 || fail "an aged folded row stranded after the fold switch went off"
  WATCH_PID=
  # With the fold off the re-arm owns the queued row (the fold digest otherwise
  # does); either way the model is woken and the row stays queued for the drain.
  grep -Eq '^check: (wake digest: 1 folded routine wake row\(s\) queued|rearm-resurface)' "$dir/watch.out" \
    || fail "the stranded row was not delivered by a wake: $(cat "$dir/watch.out")"
  [ "$(queue_rows "$dir")" -eq 1 ] || fail "the stranded row was dropped instead of delivered"
  pass "switching the fold off after a row was folded still delivers it through the digest"
}

test_measurement_rotation_keeps_in_window_turns() {
  local dir state now i
  dir=$(make_classify_case rotation)
  state="$dir/state"
  now=$(date +%s)
  {
    printf '%s\tturn\turgent\tsignal: kept\n' "$((now - 100))"
    i=0
    while [ "$i" -lt 40 ]; do
      printf '%s\tbatched\tnonurgent\tcheck %s\n' "$now" "$i"
      i=$((i + 1))
    done
    i=0
    while [ "$i" -lt 60 ]; do
      printf '%s\tturn\turgent\tin-window %s\n' "$((now - 50))" "$i"
      i=$((i + 1))
    done
    i=0
    while [ "$i" -lt 10 ]; do
      printf '%s\tturn\turgent\told\n' "$((now - 40000 - i))"
      i=$((i + 1))
    done
  } > "$state/.wake-turns.log"
  lib "$dir" 'FM_WAKE_MEASURE_MAX_LINES=45; fm_wake_measure batched nonurgent trigger'
  grep -q 'signal: kept' "$state/.wake-turns.log" || fail "rotation dropped an in-window turn"
  [ "$(grep -c 'in-window' "$state/.wake-turns.log")" -eq 60 ] || fail "rotation dropped in-window turns beyond the line cap"
  grep -q $'\told$' "$state/.wake-turns.log" && fail "rotation kept a record older than the window"
  pass "measurement rotation drops aged-out records first so an in-window turn is never undercounted"
}

test_changed_decision_set_holds_the_watcher_acknowledgement() {
  local dir state
  dir=$(make_classify_case ack-decisions)
  state="$dir/state"
  queue_aged_routine "$dir" a.check.sh 1000
  printf 'blocked [key=foo] [at=%s]: stuck on a choice\n' "$(date +%s)" > "$state/task.status"
  drain "$dir" --ack-routine-folded 900 || fail "decision-set acknowledgement failed"
  grep -q '^ROUTINE-HELD:' "$dir/drain.out" || fail "a never-presented open decision did not hold: $(cat "$dir/drain.out")"
  [ "$(queue_rows "$dir")" -eq 1 ] || fail "a never-presented open decision let the watcher remove a row"

  # A presented drain records the decision set; an unchanged set no longer holds.
  drain "$dir" --ack-if-routine || fail "presenting drain failed"
  grep -q '^OPEN DECISIONS' "$dir/drain.out" || fail "setup: the decision was not presented"
  ack_drain_err "$state" "$dir/drain.err" >/dev/null 2>&1 || fail "could not acknowledge the presented rows"
  queue_aged_routine "$dir" b.check.sh 1000
  drain "$dir" --ack-routine-folded 900 || fail "unchanged-set acknowledgement failed"
  grep -q '^ROUTINE-ACKED' "$dir/drain.out" || fail "a long-standing, already-presented decision blocked the acknowledgement: $(cat "$dir/drain.out")"

  # The decision resolving changes the set: the model must see it.
  queue_aged_routine "$dir" c.check.sh 1000
  printf 'resolved [key=foo] [at=%s]: chose the first option\n' "$(date +%s)" >> "$state/task.status"
  drain "$dir" --ack-routine-folded 900 || fail "changed-set acknowledgement failed"
  grep -q '^ROUTINE-HELD:' "$dir/drain.out" || fail "a changed decision set did not hold: $(cat "$dir/drain.out")"
  [ "$(queue_rows "$dir")" -eq 1 ] || fail "a changed decision set let the watcher remove a row"
  pass "the watcher acknowledgement holds for a decision set no presented drain has shown and proceeds once it has"
}

test_skipped_presentation_does_not_record_the_decision_fingerprint() {
  local dir state holder i
  dir=$(make_classify_case fp-skipped)
  state="$dir/state"
  printf 'blocked [key=foo] [at=%s]: stuck on a choice\n' "$(date +%s)" > "$state/task.status"
  append_wake "$state" signal task.status "signal: $state/task.status" || fail "could not queue a row"

  # A presentation that could not take its lock presents nothing, so the open
  # decision stays unseen and the watcher keeps holding.
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_lock_acquire_wait "$2"
    printf "ready\n" > "$3"
    exec sleep 30
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$state/.status-presentation-lock" "$dir/presentation.ready" &
  holder=$!
  i=0
  while [ "$i" -lt 100 ] && [ ! -s "$dir/presentation.ready" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$dir/presentation.ready" ] || { kill "$holder" 2>/dev/null || true; fail "presentation holder never acquired its lock"; }
  FM_STATUS_PRESENTATION_LOCK_TIMEOUT=1 drain "$dir" --ack-if-routine || { kill "$holder" 2>/dev/null || true; fail "skipped-presentation drain failed"; }
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  grep -q 'STATUS PRESENTATION SKIPPED' "$dir/drain.out" || fail "setup: the presentation was not skipped: $(cat "$dir/drain.out")"
  [ ! -e "$state/.wake-routine-fp" ] || fail "a skipped presentation recorded the decision fingerprint"
  ack_drain_err "$state" "$dir/drain.err" >/dev/null 2>&1 || fail "could not acknowledge the skipped-presentation drain"

  queue_aged_routine "$dir" a.check.sh 1000
  drain "$dir" --ack-routine-folded 900 || fail "post-skip acknowledgement failed"
  grep -q '^ROUTINE-HELD:' "$dir/drain.out" || fail "the watcher acknowledged past a decision no drain presented: $(cat "$dir/drain.out")"
  pass "a skipped presentation keeps the old decision fingerprint so the watcher still holds"
}

test_drain_prints_the_wake_turn_stats() {
  local dir state now
  dir=$(make_classify_case stats)
  state="$dir/state"
  now=$(date +%s)
  {
    printf '%s\tturn\turgent\tsignal: a\n' "$now"
    printf '%s\tturn\turgent\tsignal: b\n' "$now"
    printf '%s\tturn\tbatched-digest\tcheck: wake digest: x batched non-urgent\n' "$now"
    printf '%s\tturn\tfold-digest\tcheck: wake digest: y folded\n' "$now"
    printf '%s\troutine-ack\tcheck-repeat\tseq=1\n' "$now"
    printf '%s\tbatched\tnonurgent\tcheck x\n' "$now"
    printf '%s\tturn\turgent\told\n' "$((now - 30000))"
  } > "$state/.wake-turns.log"
  append_wake "$state" signal task.status "signal: $state/task.status" || fail "could not queue a row"
  drain "$dir" || fail "drain failed"
  grep -q '^WAKE TURN STATS (last 6h): turns=4 (urgent=2, batched-digest=1, fold-digest=1) routine-acked-by-watcher=1 batched-rows=1 secondmate-outcomes-deferred=0$' "$dir/drain.out" \
    || fail "the drain did not print the trailing-window stats: $(cat "$dir/drain.out")"
  pass "the drain prints wake-started turns, routine acknowledgements, and batched rows for the trailing six hours"
}

# Exercise the real parent-report producer, not hand-written relay rows.
test_report_producer_reduces_wake_turns() {
  local dir state mate mode i line turns expected
  for mode in default on; do
    dir=$(make_classify_case "producer-$mode"); state="$dir/state"; mate="$dir/mate"
    mkdir -p "$mate/state"
    printf 'mate\n' > "$mate/.fm-secondmate-home"
    printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$dir" > "$mate/.fm-secondmate-parent"
    printf 'window=remote:mate\nkind=secondmate\nmode=secondmate\n' > "$state/mate.meta"
    [ "$mode" = default ] || printf 'on\n' > "$dir/config/wake-relay-batch"
    for i in 1 2 3; do
      FM_HOME="$mate" FM_STATE_OVERRIDE="$mate/state" bash "$ROOT/bin/fm-secondmate-report.sh" \
        --relay-batch "done" 0123456789abcdef "routine report $i delivered" || fail 'relay producer failed'
      line=$(tail -1 "$state/mate.status")
      case "$line" in *'[relay-batch]'*'[corr=0123456789abcdef]'*) ;; *) fail 'producer omitted designation' ;; esac
      watch_bg "$dir"
      if [ "$mode" = on ]; then
        wait_poll_cycle "$state" "$WATCH_PID" || fail 'producer relay woke before digest'
        stop_watcher
      else
        wait_for_exit "$WATCH_PID" 100 || fail 'default producer relay did not wake'
        WATCH_PID=
        drain "$dir" || fail 'default producer drain failed'
        ack_drain_err "$state" "$dir/drain.err" >/dev/null 2>&1 || fail 'default producer ack failed'
      fi
    done
    if [ "$mode" = on ]; then
      [ "$(queue_rows "$dir")" -ge 1 ] || fail 'producer evidence vanished while held'
      age_record "$state/.wake-batch" 3600
      watch_bg "$dir"
      wait_for_exit "$WATCH_PID" 100 || fail 'producer digest did not wake at deadline'
      WATCH_PID=
      drain "$dir" || fail 'producer digest drain failed'
      for i in 1 2 3; do
        grep -q "routine report $i delivered" "$dir/drain.out" || fail "digest lost report $i"
      done
      ack_drain_err "$state" "$dir/drain.err" >/dev/null 2>&1 || fail 'producer digest ack failed'
    fi
    turns=$(measure_count "$dir" turn)
    expected=3; [ "$mode" = default ] || expected=1
    [ "$turns" -eq "$expected" ] || fail "$mode emitted $turns turns, expected $expected"
    [ ! -s "$state/.wake-queue" ] || fail 'producer acknowledgement left queued rows'
    [ "$(wc -l < "$state/mate.status")" -eq 3 ] || fail 'producer status evidence was lost'
    printf 'producer wake measurement: %s reports=3 turns=%s\n' "$mode" "$turns"
  done
  pass 'real parent-report producer reduces three immediate turns to one digest without losing evidence'
}

test_report_producer_keeps_urgent_and_unknown_immediate() {
  local dir state mate variant verb note
  for variant in unmarked urgent unknown buried-unknown doc-urgent decision; do
    dir=$(make_classify_case "producer-$variant"); state="$dir/state"; mate="$dir/mate"
    mkdir -p "$mate/state"
    printf 'mate\n' > "$mate/.fm-secondmate-home"
    printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$dir" > "$mate/.fm-secondmate-parent"
    printf 'window=remote:mate\nkind=secondmate\nmode=secondmate\n' > "$state/mate.meta"
    printf 'on\n' > "$dir/config/wake-relay-batch"
    verb="done"; note='routine report delivered'
    case "$variant" in
      urgent) note='routine report delivered; database stalled' ;;
      unknown) verb=banana ;;
      buried-unknown) note=$'routine report delivered\nbanana: novel event' ;;
      decision) verb=needs-decision ;;
    esac
    case "$variant" in
      unmarked)
        FM_HOME="$mate" FM_STATE_OVERRIDE="$mate/state" bash "$ROOT/bin/fm-secondmate-report.sh" \
          "$verb" 0123456789abcdef "$note" || fail 'unmarked producer failed'
        grep -q '\[relay-batch\]' "$state/mate.status" && fail 'default producer added a designation'
        ;;
      doc-urgent)
        FM_HOME="$mate" FM_STATE_OVERRIDE="$mate/state" bash "$ROOT/bin/fm-secondmate-report.sh" \
          --doc --relay-batch "$verb" 0123456789abcdef data/blocked/report.md "$note" || fail 'doc producer failed'
        ;;
      *)
        FM_HOME="$mate" FM_STATE_OVERRIDE="$mate/state" bash "$ROOT/bin/fm-secondmate-report.sh" \
          --relay-batch "$verb" 0123456789abcdef "$note" || fail "$variant producer failed"
        ;;
    esac
    watch_bg "$dir"
    wait_for_exit "$WATCH_PID" 100 || fail "$variant producer content did not wake immediately"
    WATCH_PID=
    [ ! -s "$state/.wake-batch" ] || fail "$variant producer content was held"
    drain "$dir" || fail "$variant producer drain failed"
    grep -q '0123456789abcdef' "$dir/drain.out" || fail "$variant producer correlation was lost"
  done
  pass 'real producer leaves default rows unmarked and preserves urgent, unknown, decision and doc urgency wakes'
}

# A relay opts in both at the receiving home and on each status row.
test_relay_batch_optin_and_urgent_spans() {
  local dir state variant text
  for variant in default on progress buried unknown unmarked malformed urgent-body check failed decision binary mixed unreadable; do
    dir=$(make_classify_case "relay-$variant"); state="$dir/state"
    printf 'window=remote:mate\nkind=secondmate\nmode=secondmate\n' > "$state/mate.meta"
    [ "$variant" = default ] || printf 'on\n' > "$dir/config/wake-relay-batch"
    text='done [relay-batch] [corr=0123456789abcdef]: routine report delivered'
    case "$variant" in
      progress) text='working [relay-batch] [corr=0123456789abcdef]: routine report delivered' ;;
      buried) text="blocked: database unavailable"$'\n'"$text" ;;
      unknown) text="banana: novel event"$'\n'"$text" ;;
      unmarked) text='done [corr=0123456789abcdef]: routine report delivered' ;;
      malformed) text='done [relay-batch] [corr=bad]: routine report delivered' ;;
      urgent-body) text="$text; database stalled" ;;
      check) text="$text; check: service status" ;;
      failed) text="failed [relay-batch] [corr=0123456789abcdef]: routine report delivered" ;;
      decision) text="needs-decision [relay-batch] [corr=0123456789abcdef]: choose a route" ;;
      mixed) printf 'blocked: service unavailable\n' > "$state/other.status" ;;
      unreadable)
        printf '#!/usr/bin/env bash\nexit 1\n' > "$dir/fakebin/span-reader"
        chmod +x "$dir/fakebin/span-reader"
        ;;

    esac
    printf '%s\n' "$text" > "$state/mate.status"
    [ "$variant" != binary ] || printf '\000' >> "$state/mate.status"
    if [ "$variant" = unreadable ]; then
      watch_bg "$dir" "FM_STATUS_SPAN_READER=$dir/fakebin/span-reader"
    else
      watch_bg "$dir"
    fi
    if [ "$variant" = on ] || [ "$variant" = progress ]; then
      wait_poll_cycle "$state" "$WATCH_PID" || fail 'opted-in relay woke immediately'
      stop_watcher
      grep -q $'\trelay-batch$' "$state/.wake-batch" || fail 'relay did not use its named batch class'
      [ "$(queue_rows "$dir")" -eq 1 ] || fail 'relay was lost'
      # Restart keeps held evidence; rollback delivers it immediately.
      watch_bg "$dir"
      wait_poll_cycle "$state" "$WATCH_PID" || fail 'restart woke early'
      stop_watcher
      printf 'off\n' > "$dir/config/wake-relay-batch"
      watch_bg "$dir"
      wait_for_exit "$WATCH_PID" 100 || fail 'rollback stranded the relay'
      WATCH_PID=
      drain "$dir" || fail 'relay drain failed'
      grep -q 'routine report delivered' "$dir/drain.out" || fail 'drain lost relay evidence'
    else
      wait_for_exit "$WATCH_PID" 100 || fail "$variant relay did not wake immediately"
      WATCH_PID=
      [ ! -s "$state/.wake-batch" ] || fail "$variant relay was batched"
    fi
  done
  pass 'relay batching requires explicit opt-in and safe complete spans; rollback and restart preserve evidence'
}

test_relay_batch_hour_window() {
  local dir
  dir=$(make_classify_case relay-hour)
  printf 'on\n' > "$dir/config/wake-relay-batch"
  # shellcheck disable=SC2016 # The controlled clock runs inside the library shell.
  lib "$dir" '
    date() { printf "%s\n" "$clock"; }
    clock=100000
    fm_wake_batch_append signal mate.status "signal: mate" relay-batch || exit 1
    fm_wake_batch_append signal mate.status "signal: mate" relay-batch || exit 1
    fm_wake_fold_queue_all_folded || exit 6
    clock=103599
    ! fm_wake_batch_digest_due || exit 2
    clock=103600
    reason=$(fm_wake_batch_digest_due) || exit 3
    fm_wake_measure_turn "$reason"
    ! fm_wake_batch_digest_due || exit 4
    clock=107200
    fm_wake_batch_digest_due || exit 5
    printf "off\n" > "$FM_WAKE_CLASSIFY_CONFIG_DIR/wake-classify"
    clock=100001
    fm_wake_batch_digest_due || exit 7
  ' || fail 'relay did not honor the fixed 3600-second window and repeated digest bound'
  [ "$(queue_rows "$dir")" -eq 1 ] || fail 'digest removed its queued evidence'
  pass 'relay digest is due at 3600 seconds and retains queued evidence'
}

test_urgent_check_carries_held_relay() {
  local dir state
  dir=$(make_classify_case relay-urgent-check); state="$dir/state"
  printf 'on\n' > "$dir/config/wake-relay-batch"
  lib "$dir" 'fm_wake_batch_append signal mate.status "signal: mate relay evidence" relay-batch' || fail 'could not hold relay'
  register_check "$dir" mail 'new message: operator review'
  watch_bg "$dir" FM_CHECK_INTERVAL=0
  wait_for_exit "$WATCH_PID" 100 || fail 'check was delayed by relay batching'
  WATCH_PID=
  [ "$(queue_rows "$dir")" -eq 2 ] || fail 'urgent check lost held relay'
  drain "$dir" --ack-if-routine || fail 'mixed digest drain failed'
  grep -q 'mate relay evidence' "$dir/drain.out" || fail 'drain lost held evidence'
  grep -q 'new message' "$dir/drain.out" || fail 'drain lost urgent check'
  ack_drain_err "$state" "$dir/drain.err" >/dev/null 2>&1 || fail 'mixed acknowledgement failed'
  [ ! -s "$state/.wake-queue" ] || fail 'mixed acknowledgement left rows queued'
  pass 'urgent check wakes immediately with held relay evidence and ordinary acknowledgement loses no rows'
}

# Real registered cloud checks and the real delivered-wake journal provide the
# provenance. No hand-written history or classifier source assertions.
test_cloud_quiet_repeats_use_delivered_heads_and_visible_ack_counter() {
  local dir state first second
  dir=$(make_classify_case cloud-repeat); state="$dir/state"
  first='quiet:refs/heads/claude/one@012345678'
  second='quiet:refs/heads/claude/two@abcdef012'
  register_check "$dir" cloud-workers-0926 "cloud-branch: $first $second"
  watch_bg "$dir" FM_CHECK_INTERVAL=0
  wait_for_exit "$WATCH_PID" 100 || fail 'first quiet heads did not wake'
  WATCH_PID=
  grep -F "cloud-branch: $first $second" "$dir/watch.out" >/dev/null || fail 'first quiet wake missing'
  grep -F "cloud-branch: $first $second" "$state/.watch-deliveries.log" >/dev/null || fail 'no durable delivery proof'
  drain "$dir" || fail 'cloud first drain failed'
  ack_drain_err "$state" "$dir/drain.err" >/dev/null 2>&1 || fail 'cloud first ack failed'

  # A different grouping/order still carries only heads already delivered.
  register_check "$dir" cloud-workers-0926 "cloud-branch: $second $first"
  watch_bg "$dir" FM_CHECK_INTERVAL=0
  wait_poll_cycle "$state" "$WATCH_PID" || fail "known heads in a new order woke: $(cat "$dir/watch.out" "$dir/watch.err")"
  stop_watcher
  [ ! -s "$dir/watch.out" ] || fail 'cloud repeat printed a model wake'
  [ "$(queue_rows "$dir")" -eq 1 ] || fail 'cloud repeat was not durably queued'
  grep -q $'\tcheck-repeat$' "$state/.wake-fold" || fail 'cloud repeat has no fold audit record'
  age_record "$state/.wake-fold" 1000
  watch_bg "$dir" FM_WAKE_FOLD_DIGEST_SECS=900
  wait_poll_cycle "$state" "$WATCH_PID" || fail 'aged cloud repeat woke instead of auto-acking'
  stop_watcher
  [ ! -s "$state/.wake-queue" ] || fail 'watcher did not auto-ack cloud repeat'
  [ "$(measure_count "$dir" routine-ack)" -eq 1 ] || fail 'cloud auto-ack not counted exactly once'
  append_wake "$state" check audit 'check: audit stats' || fail 'could not queue audit wake'
  drain "$dir" || fail 'cloud stats drain failed'
  grep -q 'routine-acked-by-watcher=1' "$dir/drain.out" || fail 'cloud ack counter is not visible in drain'
  ack_drain_err "$state" "$dir/drain.err" >/dev/null 2>&1 || fail 'cloud audit ack failed'
  # A failed check is actionable even when it prints previously delivered heads.
  register_check "$dir" cloud-workers-0926 "cloud-branch: $first $second" 1
  watch_bg "$dir" FM_CHECK_INTERVAL=0
  wait_for_exit "$WATCH_PID" 100 || fail 'failed quiet cloud check was silenced'
  WATCH_PID=
  grep -q 'check failed (exit 1)' "$dir/watch.out" || fail 'cloud failure is absent from its durable reason'
  watch_bg "$dir"
  wait_for_exit "$WATCH_PID" 100 || fail 'failed cloud check rearm was suppressed'
  WATCH_PID=
  grep -qx 'check: rearm-resurface' "$dir/watch.out" || fail 'cloud failure did not retain its recovery wake'
  drain "$dir" || fail 'cloud failure drain failed'
  ack_drain_err "$state" "$dir/drain.err" >/dev/null 2>&1 || fail 'cloud failure ack failed'
  # The portable timeout fallback must preserve signal deaths as failures,
  # even after a check has printed an otherwise routine, already-seen head.
  printf '%s\n' '#!/usr/bin/env bash' \
    "printf '%s\\n' 'cloud-branch: $first $second'" \
    'kill -TERM "$$"' > "$state/cloud-workers-0926.check.sh"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-check-register.sh" cloud-workers-0926 >/dev/null \
    || fail 'could not register signal-terminated cloud check'
  watch_bg "$dir" FM_CHECK_INTERVAL=0 FM_CHECK_FORCE_FALLBACK=1
  wait_for_exit "$WATCH_PID" 100 || fail 'signal-terminated quiet cloud check was silenced'
  WATCH_PID=
  grep -q 'check failed (exit 143)' "$dir/watch.out" || fail "cloud signal death lost its failure status: $(cat "$dir/watch.out" "$dir/watch.err")"
  [ ! -s "$state/.wake-fold" ] || fail 'signal-terminated cloud output was folded'
  drain "$dir" || fail 'cloud signal failure drain failed'
  grep -q WAKE_ACK_REQUIRED "$dir/drain.err" || fail 'cloud signal failure was auto-acked'
  ack_drain_err "$state" "$dir/drain.err" >/dev/null 2>&1 || fail 'cloud signal failure ack failed'
  pass 'known quiet cloud heads fold and auto-ack visibly; nonzero and fallback signal exits still wake'
}

test_cloud_unknown_and_actionable_outputs_always_wake() {
  local dir state output attempt
  for output in \
    'cloud-branch: new:refs/heads/claude/new-task' \
    'cloud-branch: quiet:refs/heads/claude/new-head@987654321' \
    'cloud-branch: quiet:refs/heads/claude/one@012345678 new:refs/heads/claude/new-task' \
    'cloud-branch: quiet:refs/heads/claude/one@012345678 FAILED' \
    'cloud-branch: quiet:refs/heads/claude/one@012345678 note: please decide' \
    'cloud-branch: quiet:refs/heads/claude/one@01234567' \
    $'cloud-branch: quiet:refs/heads/claude/one@012345678\nneeds-decision: choose'; do
    dir=$(make_classify_case cloud-actionable); state="$dir/state"
    register_check "$dir" cloud-workers-0926 "$output"
    # An identical new:/failure/malformed output must also bypass the old
    # generic check-repeat memory on the second cycle.
    for attempt in 1 2; do
      watch_bg "$dir" FM_CHECK_INTERVAL=0
      wait_for_exit "$WATCH_PID" 100 || fail "cloud output was delayed on attempt $attempt: $output"
      WATCH_PID=
      grep -q '^check: .*cloud-workers-0926.check.sh:' "$dir/watch.out" || fail 'cloud actionable reason missing'
      [ ! -s "$state/.wake-fold" ] || fail 'actionable cloud output was folded'
      drain "$dir" || fail 'cloud actionable drain failed'
      grep -q WAKE_ACK_REQUIRED "$dir/drain.err" || fail 'cloud actionable was auto-acked'
      ack_drain_err "$state" "$dir/drain.err" >/dev/null 2>&1 || fail 'cloud actionable ack failed'
      # First-time quiet wakes on its first appearance; once delivered it is
      # routine, so do not require a second immediate wake for that case.
      case "$output" in 'cloud-branch: quiet:refs/heads/claude/new-head@987654321') break ;; esac
    done
  done
  pass 'first quiet heads, new announcements, failures, notes, and malformed cloud output keep waking'
}

test_cloud_rearm_suppresses_only_proven_routine_queues() {
  local dir state mode output
  for mode in routine mixed no-proof off; do
    dir=$(make_classify_case "cloud-rearm-$mode"); state="$dir/state"
    output='cloud-branch: quiet:refs/heads/claude/one@012345678'
    register_check "$dir" cloud-workers-0926 "$output"
    watch_bg "$dir" FM_CHECK_INTERVAL=0
    wait_for_exit "$WATCH_PID" 100 || fail 'cloud setup did not wake'
    WATCH_PID=
    # Leave the delivered check queued, as a lost acknowledgement does.
    case "$mode" in
      mixed) append_wake "$state" stale missing 'stale: missing' || fail 'mixed stale setup failed' ;;
      no-proof) rm -f "$state/.watch-deliveries.log" ;;
      off) printf 'off\n' > "$dir/config/wake-classify" ;;
    esac
    watch_bg "$dir"
    if [ "$mode" = routine ]; then
      wait_poll_cycle "$state" "$WATCH_PID" || fail 'already-delivered routine cloud queue resurfaced'
      stop_watcher
      [ ! -s "$dir/watch.out" ] || fail 'routine rearm printed a wake'
      grep -q $'\tcheck-repeat$' "$state/.wake-fold" || fail 'routine rearm has no durable fold record'
      [ "$(queue_rows "$dir")" -eq 1 ] || fail 'routine rearm lost the row before acknowledgement'
    else
      wait_for_exit "$WATCH_PID" 100 || fail "$mode rearm was incorrectly suppressed"
      WATCH_PID=
      grep -qx 'check: rearm-resurface' "$dir/watch.out" || fail "$mode did not keep the original rearm reason"
      [ -s "$state/.wake-queue" ] || fail "$mode lost durable rows"
    fi
  done
  pass 'rearm suppresses proven quiet cloud repeats, while mixed stale queues, absent delivery proof, and classification off still wake'
}

test_cloud_quiet_repeats_use_delivered_heads_and_visible_ack_counter
test_cloud_unknown_and_actionable_outputs_always_wake
test_cloud_rearm_suppresses_only_proven_routine_queues

test_report_producer_reduces_wake_turns
test_report_producer_keeps_urgent_and_unknown_immediate
test_relay_batch_optin_and_urgent_spans
test_relay_batch_hour_window
test_urgent_check_carries_held_relay

test_secondmate_routine_outcomes_natural_drain() {
  local dir state variant line
  for variant in child-pr merged orphan resolved open decision note blocked unknown-key malformed mixed multi-corr binary bad-store; do
    dir=$(make_classify_case "secondmate-outcome-$variant"); state="$dir/state"
    printf 'window=remote:mate\nkind=secondmate\nmode=secondmate\n' > "$state/mate.meta"
    line='done [key=child-pr-123]: child PR is green'
    case "$variant" in
      merged) line='done [key=merged-123]: child landed' ;;
      bad-store)
        printf 'not a directory\n' > "$state/pending-replies"
        line='working corr=0123456789abcdef: unknown reply store'
        ;;
      orphan) line='working corr=0123456789abcdef: supervising children' ;;
      resolved|open)
        mkdir -p "$state/pending-replies"
        printf 'phase=%s\n' "$([ "$variant" = resolved ] && echo resolved || echo awaiting_report)" > "$state/pending-replies/0123456789abcdef"
        line='paused [corr=0123456789abcdef]: waiting on child CI'
        ;;
      multi-corr)
        mkdir -p "$state/pending-replies"
        printf 'phase=awaiting_report\n' > "$state/pending-replies/fedcba9876543210"
        line='working corr=0123456789abcdef corr=fedcba9876543210: two replies'
        ;;
      decision) line='needs-decision [key=child-pr-123]: choose a route' ;;
      note) line='note: a ruling needs attention' ;;
      blocked) line='blocked [key=unknown]: dependency unavailable' ;;
      unknown-key) line='done [key=unknown]: unknown outcome' ;;
      malformed) line='working corr=bad: unknown reply' ;;
      mixed) line="$line"$'\n''needs-decision: choose a route' ;;
    esac
    printf '%s\n' "$line" > "$state/mate.status"
    [ "$variant" != binary ] || printf '\000' >> "$state/mate.status"
    watch_bg "$dir" FM_WAKE_BATCH_SECS=0
    case "$variant" in
      child-pr|merged|orphan|resolved)
        wait_poll_cycle "$state" "$WATCH_PID" || fail "$variant woke immediately"
        wait_poll_cycle "$state" "$WATCH_PID" || fail "$variant started an age-only digest turn"
        stop_watcher
        [ "$(queue_rows "$dir")" -eq 1 ] || fail "$variant did not remain durable"
        grep -q $'\tsecondmate-outcome$' "$state/.wake-batch" || fail "$variant lost its batch class"
        drain "$dir" --ack-if-routine || fail "$variant natural drain failed"
        grep -q 'secondmate-outcomes-deferred=1' "$dir/drain.out" || fail "$variant counter invisible"
        grep -F "${line##*: }" "$dir/drain.out" >/dev/null || fail "$variant evidence absent from drain"
        grep -q WAKE_ACK_REQUIRED "$dir/drain.err" || fail "$variant silently acknowledged"
        ;;
      *)
        wait_for_exit "$WATCH_PID" 100 || fail "$variant did not wake"
        WATCH_PID=
        [ ! -s "$state/.wake-batch" ] || fail "$variant was batched"
        ;;
    esac
  done
  pass 'known secondmate outcomes wait durably for a natural drain with a counter; requests, unknowns and mixed spans wake'
}

test_classifier_sorts_routine_nonurgent_urgent
test_batch_record_is_durable_deduped_and_not_routine
test_batch_digest_honors_window_and_one_per_window
test_ack_routine_folded_acks_only_aged_unclaimed_routine_rows
test_ack_routine_folded_respects_claims_marker_and_switches
test_unread_status_holds_the_watcher_acknowledgement
test_watcher_acks_routine_rows_without_a_turn
test_watcher_batches_nonurgent_checks_and_wakes_urgent_ones
test_watcher_wakes_for_a_custom_check_that_is_not_an_opted_in_reporter
test_watcher_delivers_one_batched_digest_per_window
test_classification_switched_off_still_delivers_a_recorded_batch
test_watcher_batches_secondmate_progress_and_wakes_events
test_secondmate_routine_outcomes_natural_drain
test_watcher_acknowledgement_refuses_unproven_recovery_state_and_pending_outcomes
test_fold_switched_off_after_queueing_still_delivers_through_the_digest
test_measurement_rotation_keeps_in_window_turns
test_changed_decision_set_holds_the_watcher_acknowledgement
test_skipped_presentation_does_not_record_the_decision_fingerprint
test_drain_prints_the_wake_turn_stats

# A progress row already queued for this file must not swallow an outcome's class.
test_secondmate_outcome_after_progress_and_natural_trigger() {
  local dir state
  dir=$(make_classify_case secondmate-outcome-after-progress); state="$dir/state"
  printf 'window=remote:mate\nkind=secondmate\nmode=secondmate\n' > "$state/mate.meta"
  batch_append "$dir" signal mate.status "signal: $state/mate.status" || fail 'could not seed progress'
  printf 'done [key=child-pr-123]: child ready for review\n' > "$state/mate.status"
  watch_bg "$dir"
  wait_poll_cycle "$state" "$WATCH_PID" || fail 'outcome after progress woke early'
  stop_watcher
  [ "$(queue_rows "$dir")" -eq 2 ] || fail 'progress swallowed the outcome row'
  grep -q $'\tsecondmate-outcome$' "$state/.wake-batch" || fail 'progress swallowed the outcome class'

  # A real check failure delivers both held rows, including after watcher restart.
  register_check "$dir" service 'failed: service health check'
  watch_bg "$dir" FM_CHECK_INTERVAL=0
  wait_for_exit "$WATCH_PID" 100 || fail 'check failure was delayed by held outcome'
  WATCH_PID=
  drain "$dir" --ack-if-routine || fail 'natural-trigger drain failed'
  grep -q 'child ready for review' "$dir/drain.out" || fail 'natural drain lost outcome'
  grep -q 'failed: service health check' "$dir/drain.out" || fail 'natural drain lost failure'
  grep -q 'secondmate-outcomes-deferred=1' "$dir/drain.out" || fail 'natural drain lost counter'
  ack_drain_err "$state" "$dir/drain.err" >/dev/null 2>&1 || fail 'ordinary acknowledgement failed'
  [ ! -s "$state/.wake-queue" ] || fail 'ordinary acknowledgement left rows queued'
  pass 'a queued progress row preserves the later outcome counter and a check failure naturally drains both after restart'
}
test_secondmate_outcome_after_progress_and_natural_trigger

test_secondmate_simultaneous_outcome_and_progress() {
  local dir state id
  dir=$(make_classify_case secondmate-simultaneous-outcome-progress); state="$dir/state"
  for id in outcome progress; do
    printf 'window=remote:%s\nkind=secondmate\nmode=secondmate\n' "$id" > "$state/$id.meta"
  done
  printf 'done [key=child-pr-123]: child ready for review\n' > "$state/outcome.status"
  printf 'working: supervising ordinary work\n' > "$state/progress.status"
  watch_bg "$dir"
  wait_poll_cycle "$state" "$WATCH_PID" || fail 'simultaneous routine files woke immediately'
  stop_watcher
  [ "$(queue_rows "$dir")" -eq 2 ] || fail 'simultaneous files lost a queued row'
  [ "$(awk -F '\t' '$3 == "secondmate-outcome" { n++ } END { print n + 0 }' "$state/.wake-batch")" -eq 1 ] \
    || fail 'ordinary progress inherited the simultaneous outcome class'
  awk -F '\t' '
    FNR == NR { classes[$1] = $3; next }
    $4 == "outcome.status" && classes[$2] == "secondmate-outcome" { outcome++ }
    $4 == "progress.status" && classes[$2] == "nonurgent" { progress++ }
    END { exit outcome == 1 && progress == 1 ? 0 : 1 }
  ' "$state/.wake-batch" "$state/.wake-queue" || fail 'simultaneous files did not retain their own batch classes'
  drain "$dir" --ack-if-routine || fail 'simultaneous files drain failed'
  grep -q 'secondmate-outcomes-deferred=1' "$dir/drain.out" || fail 'simultaneous outcome counter was inflated'
  grep -q 'supervising ordinary work' "$dir/drain.out" || fail 'simultaneous progress evidence was lost'
  grep -q WAKE_ACK_REQUIRED "$dir/drain.err" || fail 'simultaneous rows were silently acknowledged'

  # Age both rows: ordinary progress must still cause the normal digest,
  # carrying the outcome without counting progress as another outcome.
  age_record "$state/.wake-batch" 1000
  watch_bg "$dir" FM_WAKE_BATCH_SECS=900
  wait_for_exit "$WATCH_PID" 100 || fail 'ordinary progress lost age-based delivery beside an outcome'
  WATCH_PID=
  grep -q '^check: wake digest:' "$dir/watch.out" || fail 'ordinary progress did not start the normal digest'
  [ "$(queue_rows "$dir")" -eq 2 ] || fail 'age-based delivery dropped a simultaneous row'
  drain "$dir" --ack-if-routine || fail 'aged simultaneous files drain failed'
  grep -q 'secondmate-outcomes-deferred=1' "$dir/drain.out" || fail 'aged digest inflated the outcome counter'
  ack_drain_err "$state" "$dir/drain.err" >/dev/null 2>&1 || fail 'simultaneous rows acknowledgement failed'
  [ ! -s "$state/.wake-queue" ] || fail 'simultaneous rows remained after explicit acknowledgement'
  pass 'simultaneous outcome and progress retain separate classes, one outcome count and normal progress age delivery'
}
test_secondmate_simultaneous_outcome_and_progress
