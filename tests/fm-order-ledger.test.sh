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

test_timer_runs_the_poll_every_minute() {
  local out dir="$TMP_ROOT/timer-units"
  make_case timer
  out=$("$LEDGER" timer print --home "$HOME_DIR") || fail "timer print failed"
  assert_contains "$out" "$HOME_DIR" "unit names the home"
  case "$out" in
    *StartInterval*) assert_contains "$out" "<integer>60</integer>" "launchd 60 second interval" ;;
    *) assert_contains "$out" "OnUnitActiveSec=60" "systemd 60 second interval" ;;
  esac
  mkdir -p "$dir"
  FM_TIMER_DIR=$dir FM_TIMER_NOLOAD=1 "$LEDGER" timer install --home "$HOME_DIR" || fail "install"
  [ -n "$(ls "$dir")" ] || fail "install wrote no unit"
  FM_TIMER_DIR=$dir FM_TIMER_NOLOAD=1 "$LEDGER" timer remove --home "$HOME_DIR" || fail "remove"
  assert_equals "" "$(ls "$dir")" "remove deletes the units"
  pass "the poll timer is scoped to one home and runs every 60 seconds"
}

test_ids_rise_by_one_and_each_order_is_one_line
test_concurrent_appends_never_share_an_id
test_ack_advances_only_the_acked_line_id
test_ack_refuses_an_unknown_id
test_poll_surfaces_pending_orders_with_no_terminal_ring
test_an_unacked_order_survives_a_failed_announcement
test_timer_runs_the_poll_every_minute
