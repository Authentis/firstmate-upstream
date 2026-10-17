#!/usr/bin/env bash
# tests/fm-order-ledger.test.sh - bin/fm-order-ledger.sh against real files and
# the real wake queue, with a fakebin that records any terminal-ring tool call.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-order-ledger)
LEDGER="$ROOT/bin/fm-order-ledger.sh"

# Sets HOME_DIR RINGS FAKEBIN for one isolated case.
make_case() {  # <name>
  local dir="$TMP_ROOT/$1" tool
  HOME_DIR="$dir/home"
  RINGS="$dir/rings.log"
  mkdir -p "$HOME_DIR/state"
  : > "$RINGS"
  FAKEBIN=$(fm_fakebin "$dir")
  for tool in tmux herdr cmux zellij; do
    printf '#!/usr/bin/env bash\necho "%s $*" >> "%s"\nexit 1\n' "$tool" "$RINGS" > "$FAKEBIN/$tool"
    chmod +x "$FAKEBIN/$tool"
  done
}

ledger() {
  PATH="$FAKEBIN:$PATH" "$LEDGER" "$@" --home "$HOME_DIR"
}

test_ids_rise_by_one_and_each_order_is_one_line() {
  local a b c
  make_case ids
  a=$(ledger append first order) || fail "append 1"
  b=$(ledger append --from chief 'second
with a newline') || fail "append 2"
  c=$(printf 'from stdin' | ledger append -) || fail "append 3"
  assert_equals "1 2 3" "$a $b $c" "ids"
  assert_equals "3" "$(wc -l < "$HOME_DIR/state/orders.jsonl" | tr -d ' ')" "one physical line per order"
  assert_equals "chief" "$(sed -n 2p "$HOME_DIR/state/orders.jsonl" | jq -r .from)" "sender recorded"
  assert_equals "second
with a newline" "$(sed -n 2p "$HOME_DIR/state/orders.jsonl" | jq -r .text)" "text round-trips"
  pass "orders append as single JSON lines with ids that rise by one"
}

test_concurrent_appends_never_share_an_id() {
  local i ids
  make_case concurrent
  for i in 1 2 3 4 5 6; do
    ledger append "order $i" >/dev/null &
  done
  wait
  ids=$(jq -r .id "$HOME_DIR/state/orders.jsonl" | sort -n | tr '\n' ' ')
  assert_equals "1 2 3 4 5 6 " "$ids" "ids under concurrent appends"
  pass "concurrent appends take distinct monotonic ids"
}

test_ack_advances_only_the_acked_line_id() {
  local out
  make_case ack
  ledger append one >/dev/null
  ledger append two >/dev/null
  ledger append three >/dev/null
  ledger ack 2 >/dev/null || fail "ack 2"
  out=$(ledger pending | awk '{print $1}' | tr '\n' ' ')
  assert_equals "1 3 " "$out" "pending after acking only 2"
  ledger ack 1 >/dev/null || fail "ack 1"
  out=$(ledger pending | awk '{print $1}' | tr '\n' ' ')
  assert_equals "3 " "$out" "pending after acking 1"
  out=$(ledger ack 2) || fail "re-ack"
  assert_contains "$out" "already acked 2" "acking twice is a no-op"
  assert_equals "2" "$(wc -l < "$HOME_DIR/state/orders.acks.jsonl" | tr -d ' ')" "a repeated ack adds no line"
  pass "an ack removes exactly the acked id from pending, in any order"
}

test_ack_refuses_an_unknown_id() {
  local rc=0
  make_case unknown
  ledger append one >/dev/null
  ledger ack 9 >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "ack of an id with no order"
  assert_absent "$HOME_DIR/state/orders.acks.jsonl" "no ack line for an unknown id"
  ledger ack abc >/dev/null 2>&1 && fail "a non-numeric id was accepted"
  assert_equals "1" "$(ledger pending | wc -l | tr -d ' ')" "the order stays pending"
  pass "acking an id with no order line is refused and changes nothing"
}

test_poll_surfaces_pending_orders_with_no_terminal_ring() {
  local queue
  make_case poll
  ledger append 'do the thing' >/dev/null
  ledger append 'and the other' >/dev/null
  ledger poll --once || fail "poll failed"
  assert_equals "2" "$(wc -l < "$HOME_DIR/state/orders.pending" | tr -d ' ')" "pending view"
  queue=$(cat "$HOME_DIR/state/.wake-queue" 2>/dev/null || true)
  assert_contains "$queue" "orders:1" "wake for order 1"
  assert_contains "$queue" "orders:2" "wake for order 2"
  ledger poll --once || fail "second poll failed"
  assert_equals "2" "$(grep -c 'orders:' "$HOME_DIR/state/.wake-queue")" "an order is announced once"
  ledger ack 1 >/dev/null
  ledger poll --once || fail "third poll failed"
  assert_equals "1" "$(wc -l < "$HOME_DIR/state/orders.pending" | tr -d ' ')" "pending view after ack"
  assert_equals "" "$(cat "$RINGS")" "no terminal tool was called anywhere in the path"
  pass "a poll shows pending orders and queues one wake each without any doorbell"
}

test_an_unacked_order_survives_a_failed_announcement() {
  make_case failwake
  ledger append kept >/dev/null
  chmod 500 "$HOME_DIR/state"
  ledger poll --once >/dev/null 2>&1
  chmod 700 "$HOME_DIR/state"
  assert_equals "1 firstmate kept" "$(ledger pending)" "the order is still pending"
  ledger poll --once || fail "poll after the failure"
  assert_contains "$(cat "$HOME_DIR/state/.wake-queue")" "orders:1" "the order is announced on a later poll"
  pass "an order is never lost or silenced when one poll cannot announce it"
}

test_timer_runs_the_poll_every_15_seconds() {
  local out dir="$TMP_ROOT/timer-units"
  make_case timer
  out=$("$LEDGER" timer print --home "$HOME_DIR") || fail "timer print failed"
  assert_contains "$out" "$HOME_DIR" "unit names the home"
  case "$out" in
    *StartInterval*) assert_contains "$out" "<integer>15</integer>" "launchd 15 second interval" ;;
    *) assert_contains "$out" "OnUnitActiveSec=15" "systemd 15 second interval" ;;
  esac
  mkdir -p "$dir"
  FM_TIMER_DIR=$dir FM_TIMER_NOLOAD=1 "$LEDGER" timer install --home "$HOME_DIR" || fail "install"
  [ -n "$(ls "$dir")" ] || fail "install wrote no unit"
  FM_TIMER_DIR=$dir FM_TIMER_NOLOAD=1 "$LEDGER" timer remove --home "$HOME_DIR" || fail "remove"
  assert_equals "" "$(ls "$dir")" "remove deletes the units"
  pass "the poll timer is scoped to one home and runs every 15 seconds"
}

# hold_lock <seconds> [lock-name]: a separate process that owns a lock in the
# home's state directory (the ledger lock unless another name is given).
hold_lock() {
  : > "$TMP_ROOT/held.out"
  FM_HOME=$HOME_DIR bash -c '. "$1"; fm_lock_acquire_wait "$2"; echo held; sleep "$3"' \
    _ "$ROOT/bin/fm-wake-lib.sh" "$HOME_DIR/state/${2:-.orders.lock}" "$1" > "$TMP_ROOT/held.out" &
  HOLDER=$!
  local n=0
  until grep -q held "$TMP_ROOT/held.out" 2>/dev/null; do
    n=$((n + 1))
    [ "$n" -le 100 ] || fail "the lock holder never started"
    sleep 0.1
  done
}

test_waiters_on_a_dead_owners_lock_never_share_an_id() {
  local round i dead ids
  make_case deadlock
  for round in 1 2 3 4 5; do
    sleep 0 &
    dead=$!
    wait "$dead"
    rm -rf "$HOME_DIR/state/.orders.lock"
    mkdir "$HOME_DIR/state/.orders.lock"
    printf '%s\n' "$dead" > "$HOME_DIR/state/.orders.lock/pid"
    for i in 1 2 3 4 5 6; do
      ledger append "round $round order $i" >/dev/null &
    done
    wait
  done
  ids=$(jq -r .id "$HOME_DIR/state/orders.jsonl" | sort -n | uniq -d | tr '\n' ' ')
  assert_equals "" "$ids" "duplicate ids after waiters raced to reclaim a dead owner's lock"
  assert_equals "30" "$(wc -l < "$HOME_DIR/state/orders.jsonl" | tr -d ' ')" "every append landed"
  assert_equals "30" "$(jq -r .id "$HOME_DIR/state/orders.jsonl" | sort -n | tail -n1)" "ids rose by exactly one"
  pass "waiters racing to reclaim a dead owner's lock never duplicate an order id"
}

test_a_signalled_append_stops_and_leaves_another_writers_lock() {
  local pid rc=0 owner
  make_case signal
  hold_lock 30
  "$LEDGER" append waiting --home "$HOME_DIR" >/dev/null 2>&1 &
  pid=$!
  sleep 1
  kill -0 "$pid" 2>/dev/null || fail "the append ended before it was signalled"
  assert_contains "$(ps -o command= -p "$pid")" "fm-order-ledger.sh" "the signalled process is the ledger script itself"
  kill -TERM "$pid"
  wait "$pid" || rc=$?
  assert_equals "143" "$rc" "a signalled append exits"
  assert_absent "$HOME_DIR/state/orders.jsonl" "a signalled append writes nothing"
  owner=$(cat "$HOME_DIR/state/.orders.lock/pid" 2>/dev/null || true)
  assert_equals "$HOLDER" "$owner" "the other writer still owns its lock"
  kill "$HOLDER" 2>/dev/null
  wait "$HOLDER" 2>/dev/null
  pass "a signalled append exits without writing and without deleting another writer's lock"
}

# A poll owns the ledger lock while it waits for the wake-queue lock, so a signal
# there must release the ledger lock it holds instead of leaving it behind.
test_a_signalled_poll_releases_the_ledger_lock_it_holds() {
  local pid rc=0
  make_case pollsignal
  ledger append pending >/dev/null
  hold_lock 30 .wake-queue.lock
  "$LEDGER" poll --once --home "$HOME_DIR" >/dev/null 2>&1 &
  pid=$!
  sleep 1
  kill -0 "$pid" 2>/dev/null || fail "the poll ended before it was signalled"
  [ -e "$HOME_DIR/state/.orders.lock" ] || fail "the poll does not hold the ledger lock while it waits"
  kill -TERM "$pid"
  wait "$pid" || rc=$?
  assert_equals "143" "$rc" "a signalled poll exits"
  kill "$HOLDER" 2>/dev/null
  wait "$HOLDER" 2>/dev/null
  assert_equals "2" "$(FM_ORDER_LOCK_WAIT=5 ledger append next)" "the ledger lock is free for the next writer"
  pass "a poll signalled while it holds the ledger lock exits and releases it"
}

test_a_held_lock_times_out_with_the_owner_named() {
  local rc=0 err
  make_case timeout
  hold_lock 30
  err=$(FM_ORDER_LOCK_WAIT=1 ledger append blocked 2>&1) || rc=$?
  kill "$HOLDER" 2>/dev/null
  wait "$HOLDER" 2>/dev/null
  expect_code 2 "$rc" "append behind a held lock"
  assert_contains "$err" "$HOLDER" "the holder is named"
  assert_absent "$HOME_DIR/state/orders.jsonl" "nothing is written without the lock"
  pass "an append that cannot take the lock refuses and names the owner"
}

test_concurrent_polls_announce_each_order_once() {
  local i
  make_case polls
  ledger append a >/dev/null
  ledger append b >/dev/null
  ledger append c >/dev/null
  for i in 1 2 3 4 5 6; do
    ledger poll --once &
  done
  wait
  assert_equals "3" "$(grep -c 'orders:' "$HOME_DIR/state/.wake-queue")" "wake rows after six racing polls"
  pass "racing polls queue exactly one wake per order"
}

test_a_failed_read_keeps_the_last_good_pending_view() {
  local rc=0 before
  make_case badread
  ledger append one >/dev/null
  ledger append two >/dev/null
  ledger poll --once || fail "first poll"
  before=$(cat "$HOME_DIR/state/orders.pending")
  printf '{not json\n' >> "$HOME_DIR/state/orders.jsonl"
  ledger poll --once >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "a poll over a corrupt ledger reported success"
  assert_equals "$before" "$(cat "$HOME_DIR/state/orders.pending")" "the pending view survives a failed read"
  assert_equals "" "$(find "$HOME_DIR/state" -name '.orders.pending.*')" "no partial view is left behind"
  pass "a poll that cannot read the ledger keeps the last good pending view"
}

test_a_consumed_wake_for_a_pending_order_is_queued_again_until_acked() {
  make_case consumed
  ledger append one >/dev/null
  ledger poll --once || fail "first poll"
  assert_equals "1" "$(grep -c 'orders:1' "$HOME_DIR/state/.wake-queue")" "the wake is queued"
  ledger poll --once || fail "second poll"
  assert_equals "1" "$(grep -c 'orders:1' "$HOME_DIR/state/.wake-queue")" "a queued wake is never stacked"
  : > "$HOME_DIR/state/.wake-queue"
  ledger poll --once || fail "poll after the wake was consumed"
  assert_equals "1" "$(grep -c 'orders:1' "$HOME_DIR/state/.wake-queue")" "a consumed wake for a still-pending order is delivered again"
  ledger ack 1 >/dev/null
  : > "$HOME_DIR/state/.wake-queue"
  ledger poll --once || fail "poll after the ack"
  assert_equals "0" "$(grep -c 'orders:1' "$HOME_DIR/state/.wake-queue")" "an acknowledged order is never delivered again"
  assert_equals "" "$(find "$HOME_DIR/state" \( -iname '*outbox*' -o -iname '*announced*' \))" "delivery keeps no record of its own"
  pass "delivery repeats for a pending order until it is acked, never stacks, and keeps no state besides the ledger"
}

test_another_producer_advancing_the_queue_never_skips_an_order() {
  make_case otherproducer
  ledger append one >/dev/null
  printf '40\n' > "$HOME_DIR/state/.wake-queue.seq"
  ledger poll --once || fail "poll"
  assert_contains "$(cat "$HOME_DIR/state/.wake-queue")" "orders:1" "the order is queued although the queue sequence moved on"
  pass "an order never queued is queued even when another producer advanced the wake sequence"
}


test_a_failed_pending_read_is_an_error_not_an_empty_list() {
  local rc=0 out
  make_case pendingfail
  ledger append one >/dev/null
  printf '{not json\n' >> "$HOME_DIR/state/orders.jsonl"
  out=$(ledger pending 2>/dev/null) || rc=$?
  [ "$rc" -ne 0 ] || fail "pending reported success over a corrupt ledger"
  assert_equals "" "$out" "no partial list is printed"
  pass "pending fails rather than printing a partial list when the ledger cannot be read"
}

test_a_torn_last_line_is_set_aside_before_the_next_write() {
  local out
  make_case torn
  ledger append first >/dev/null
  printf '{"id":2,"ts":17' >> "$HOME_DIR/state/orders.jsonl"
  out=$(ledger append second 2>/dev/null) || fail "append after a torn tail"
  assert_equals "2" "$out" "the torn line never became an order, so its id is reused"
  assert_equals "2" "$(jq -s 'length' "$HOME_DIR/state/orders.jsonl")" "the ledger is whole JSON lines again"
  assert_equals '{"id":2,"ts":17' "$(cat "$HOME_DIR/state/orders.jsonl.torn")" "the torn text is kept aside"
  pass "a torn last line is set aside and the next append publishes a complete ledger"
}

test_a_failed_publish_leaves_the_ledger_untouched() {
  local rc=0 before
  make_case publishfail
  ledger append first >/dev/null
  before=$(cat "$HOME_DIR/state/orders.jsonl")
  chmod 500 "$HOME_DIR/state"
  ledger append second >/dev/null 2>&1 || rc=$?
  chmod 700 "$HOME_DIR/state"
  if [ "$(id -u)" != 0 ]; then
    [ "$rc" -ne 0 ] || fail "an append that could not publish reported success"
  fi
  assert_equals "$before" "$(cat "$HOME_DIR/state/orders.jsonl")" "the ledger is unchanged"
  assert_equals "" "$(find "$HOME_DIR/state" -name 'orders.jsonl.*')" "no partial copy is left behind"
  pass "an append that cannot be published leaves the ledger as it was"
}

test_ack_ids_are_range_checked_before_arithmetic() {
  local rc=0
  make_case idrange
  ledger append one >/dev/null
  ledger ack 18446744073709551617 >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "an id that would wrap to 1 in bash arithmetic"
  assert_absent "$HOME_DIR/state/orders.acks.jsonl" "no order was acked by a wrapped id"
  rc=0
  ledger ack 99999999999999999999999 >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "a very long id"
  ledger ack 0000000000000000001 >/dev/null 2>&1 || fail "leading zeros on a small id"
  assert_equals "" "$(ledger pending)" "an id with leading zeros acks that order"
  pass "ack refuses ids too large for bash arithmetic and never acks a different order"
}


test_a_wake_queue_write_failure_leaves_the_order_to_be_announced_later() {
  local rc=0
  make_case wakefail
  ledger append one >/dev/null
  mkdir "$HOME_DIR/state/.wake-queue"
  ledger poll --once >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "a poll that could not queue the wake reported success"
  assert_equals "1 firstmate one" "$(ledger pending)" "the order is still pending"
  rmdir "$HOME_DIR/state/.wake-queue"
  ledger poll --once || fail "poll once the queue is writable"
  assert_equals "1" "$(grep -c 'orders:1' "$HOME_DIR/state/.wake-queue")" "the wake is queued on the later poll"
  pass "a real wake-queue write failure fails the poll and the order is announced on a later one"
}

# Two secondmate homes, each polled by a real process, with every terminal tool
# failing and recorded. A stand-in secondmate acts on the wake it finds and acks.
test_a_replay_with_the_doorbell_off_is_acked_within_60_seconds_on_both_homes() {
  local name start now elapsed worst=0 i dir
  local -a pollers=() responders=()
  make_case replay
  dir="$TMP_ROOT/replay-homes"
  for name in bosgame netcup; do
    mkdir -p "$dir/$name/state"
    "$LEDGER" append --home "$dir/$name" --from firstmate "replay one for $name" >/dev/null
    "$LEDGER" append --home "$dir/$name" --from firstmate "replay two for $name" >/dev/null
  done
  start=$(date +%s)
  for name in bosgame netcup; do
    PATH="$FAKEBIN:$PATH" "$LEDGER" poll --home "$dir/$name" --interval 1 &
    pollers+=("$!")
    (
      while :; do
        # shellcheck disable=SC2013 # the values are numeric order ids
        for i in $(awk -F'\t' '$4 ~ /^orders:/ { sub(/^orders:/, "", $4); print $4 }' "$dir/$name/state/.wake-queue" 2>/dev/null); do
          "$LEDGER" ack --home "$dir/$name" "$i" >/dev/null 2>&1
        done
        sleep 0.5
      done
    ) &
    responders+=("$!")
  done
  for name in bosgame netcup; do
    i=0
    until [ -z "$("$LEDGER" pending --home "$dir/$name")" ] && [ -s "$dir/$name/state/orders.acks.jsonl" ]; do
      i=$((i + 1))
      [ "$i" -le 120 ] || break
      sleep 0.5
    done
    now=$(date +%s)
    elapsed=$((now - start))
    [ "$elapsed" -le "$worst" ] || worst=$elapsed
    assert_equals "" "$("$LEDGER" pending --home "$dir/$name")" "$name has no pending order"
    assert_equals "2" "$(wc -l < "$dir/$name/state/orders.acks.jsonl" | tr -d ' ')" "$name acked both orders"
  done
  kill "${pollers[@]}" "${responders[@]}" 2>/dev/null
  wait "${pollers[@]}" "${responders[@]}" 2>/dev/null
  [ "$worst" -le 60 ] || fail "the replay took ${worst}s, over 60"
  assert_equals "" "$(cat "$RINGS")" "no terminal tool was called with the doorbell off"
  pass "a replay with the doorbell off is acked on both secondmate homes in ${worst}s"
}

test_ids_rise_by_one_and_each_order_is_one_line
test_waiters_on_a_dead_owners_lock_never_share_an_id
test_a_signalled_append_stops_and_leaves_another_writers_lock
test_a_signalled_poll_releases_the_ledger_lock_it_holds
test_a_consumed_wake_for_a_pending_order_is_queued_again_until_acked
test_another_producer_advancing_the_queue_never_skips_an_order
test_a_failed_pending_read_is_an_error_not_an_empty_list
test_a_torn_last_line_is_set_aside_before_the_next_write
test_a_failed_publish_leaves_the_ledger_untouched
test_ack_ids_are_range_checked_before_arithmetic
test_a_wake_queue_write_failure_leaves_the_order_to_be_announced_later
test_a_held_lock_times_out_with_the_owner_named
test_concurrent_polls_announce_each_order_once
test_a_failed_read_keeps_the_last_good_pending_view
test_a_replay_with_the_doorbell_off_is_acked_within_60_seconds_on_both_homes
test_concurrent_appends_never_share_an_id
test_ack_advances_only_the_acked_line_id
test_ack_refuses_an_unknown_id
test_poll_surfaces_pending_orders_with_no_terminal_ring
test_an_unacked_order_survives_a_failed_announcement
test_timer_runs_the_poll_every_15_seconds
