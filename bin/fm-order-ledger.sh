#!/usr/bin/env bash
# fm-order-ledger.sh - one polled order ledger per secondmate home.
#
# Orders reach a secondmate through a file it polls, never through a terminal
# doorbell, so a failed ring can no longer hide an order. The ledger lives in
# the secondmate's own state directory:
#   state/orders.jsonl        append-only; one JSON object per line
#                             {"id":<n>,"ts":<epoch>,"from":"<name>","text":"<order>"}
#                             with ids that start at 1 and rise by exactly 1.
#   state/orders.acks.jsonl   append-only acknowledgements {"id":<n>,"ts":<epoch>}.
#   state/orders.pending      the current pending lines, rewritten by every poll;
#                             a poll that cannot read the ledger keeps the old view.
#   state/orders.outbox       append-only announcement outbox: `<id> queued` once
#                             that order's own wake has been appended.
# An order is pending until its own id is acknowledged. Acking one id never
# acknowledges another, whatever the numeric order, and acking twice is a no-op.
#
# Usage:
#   fm-order-ledger.sh append [--home <dir>] [--from <name>] [--] <text>...
#   fm-order-ledger.sh append [--home <dir>] [--from <name>] -     (text from stdin)
#       Append one order and print its id.
#   fm-order-ledger.sh pending [--home <dir>] [--json]
#       Print every unacknowledged order (default: `<id> <from> <text>`).
#   fm-order-ledger.sh ack [--home <dir>] <id>...
#       Acknowledge the named line ids; an id with no order line is refused.
#   fm-order-ledger.sh poll [--home <dir>] [--once] [--interval <seconds>]
#       Secondmate side: refresh state/orders.pending and queue one wake per
#       newly seen pending order, every --interval seconds (default 15) until
#       stopped; --once does a single pass.
#   fm-order-ledger.sh timer install|remove|print [--home <dir>]
#       Run `poll --once` every 15 seconds from the host's launchd or systemd.
#
# Every writer takes the home's ledger lock (fm-wake-lib.sh's owner-checked
# lock, so a dead owner is reclaimed by exactly one waiter and a signal releases
# only this process's own hold); FM_ORDER_LOCK_WAIT bounds the wait (default 30s).
# A poll holds it for the whole pass and queues each wake together with its
# outbox line under the wake-queue lock; the proof an order was announced is
# keyed to that order alone.
#
# --home selects the secondmate home (default FM_HOME, else this checkout).
# To order a remote secondmate, run `append` in its home through bin/fm-on.sh.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

usage() {
  sed -n '2,/^set -u$/s/^# \{0,1\}//p' "$0" | sed '$d'
}

die() {
  printf 'fm-order-ledger: %s\n' "$*" >&2
  exit 2
}

command -v jq >/dev/null 2>&1 || die "jq is required"

CMD=${1:-}
case "$CMD" in
  -h|--help|help) usage; exit 0 ;;
  "") usage; exit 2 ;;
esac
shift

HOME_DIR=${FM_HOME:-$FM_ROOT}
FROM=firstmate
ONCE=0
INTERVAL=${FM_ORDER_POLL_INTERVAL:-15}
JSON=0
ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --home) [ "$#" -ge 2 ] || die "--home needs a directory"; HOME_DIR=$2; shift 2 ;;
    --from) [ "$#" -ge 2 ] || die "--from needs a name"; FROM=$2; shift 2 ;;
    --interval) [ "$#" -ge 2 ] || die "--interval needs seconds"; INTERVAL=$2; shift 2 ;;
    --once) ONCE=1; shift ;;
    --json) JSON=1; shift ;;
    --) shift; ARGS+=("$@"); break ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
case "$INTERVAL" in ''|*[!0-9]*) die "--interval must be whole seconds" ;; esac
[ "$INTERVAL" -ge 1 ] || die "--interval must be at least 1"

STATE="$HOME_DIR/state"
ORDERS="$STATE/orders.jsonl"
ACKS="$STATE/orders.acks.jsonl"
PENDING_VIEW="$STATE/orders.pending"
OUTBOX="$STATE/orders.outbox"
LOCK="$STATE/.orders.lock"

# The wake library owns the portable owner-checked lock, and the wake queue the
# ledger announces into lives in the same home.
load_wake_lib() {
  local lib="$FM_ROOT/bin/fm-wake-lib.sh"
  command -v fm_lock_try_acquire >/dev/null 2>&1 && return 0
  [ -r "$lib" ] || { printf 'fm-order-ledger: missing %s\n' "$lib" >&2; return 1; }
  mkdir -p "$STATE" || return 1
  export FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE"
  unset FM_WAKE_QUEUE FM_WAKE_QUEUE_LOCK
  # shellcheck disable=SC1090,SC1091
  . "$lib"
}

lock_release() {
  fm_lock_release "$LOCK"
}

# lock_acquire: take the ledger lock, or return 1 with the reason on stderr.
# A signal exits through the EXIT trap, which releases only a hold this process
# owns, so an interrupted writer never keeps writing unlocked and never removes
# another writer's lock.
lock_acquire() {
  load_wake_lib || return 1
  [ -d "$STATE" ] && [ -w "$STATE" ] || { printf 'fm-order-ledger: %s is not writable\n' "$STATE" >&2; return 1; }
  trap lock_release EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  if ! fm_lock_acquire_wait_max "$LOCK" "${FM_ORDER_LOCK_WAIT:-30}"; then
    printf 'fm-order-ledger: ledger lock is held by %s\n' "${FM_LOCK_HELD_PID:-another process}" >&2
    return 1
  fi
}

# pending_lines: orders whose own id has no acknowledgement line.
pending_lines() {
  local acks=/dev/null
  [ -f "$ORDERS" ] || return 0
  [ -f "$ACKS" ] && acks=$ACKS
  jq -c --slurpfile acks "$acks" \
    'select(.id != null) | select(.id as $i | ($acks | map(.id) | index($i)) == null)' "$ORDERS"
}

order_exists() {  # <id>
  [ -n "$(jq -c --argjson id "$1" 'select(.id == $id)' "$ORDERS" 2>/dev/null)" ]
}

is_acked() {  # <id>
  [ -f "$ACKS" ] && [ -n "$(jq -c --argjson id "$1" 'select(.id == $id)' "$ACKS" 2>/dev/null)" ]
}

# print_pending: read under the ledger lock, so a concurrent append is never
# seen half-written, and fail rather than print a partial list.
print_pending() {
  local out rc=0
  [ -f "$ORDERS" ] || return 0
  lock_acquire || exit 2
  out=$(pending_lines) || rc=$?
  lock_release
  [ "$rc" -eq 0 ] || die "cannot read $ORDERS"
  [ -n "$out" ] || return 0
  if [ "$JSON" -eq 1 ]; then
    printf '%s\n' "$out"
  else
    printf '%s\n' "$out" | jq -r '"\(.id) \(.from) \(.text | gsub("\n"; " "))"' || die "cannot format the pending orders"
  fi
}

cmd_append() {
  local text last id ts line
  if [ "${#ARGS[@]}" -eq 1 ] && [ "${ARGS[0]}" = "-" ]; then
    text=$(cat)
  else
    text="${ARGS[*]}"
  fi
  [ -n "$text" ] || die "append needs the order text"
  mkdir -p "$STATE" || die "cannot create $STATE"
  lock_acquire || exit 2
  last=0
  if [ -s "$ORDERS" ]; then
    last=$(jq -s 'map(.id) | max // 0' "$ORDERS" 2>/dev/null) || die "$ORDERS is not valid JSON lines"
  fi
  id=$((last + 1))
  ts=$(date +%s)
  line=$(jq -cn --argjson id "$id" --argjson ts "$ts" --arg from "$FROM" --arg text "$text" \
    '{id:$id,ts:$ts,from:$from,text:$text}') || die "could not encode the order"
  printf '%s\n' "$line" >> "$ORDERS" || die "could not append to $ORDERS"
  printf '%s\n' "$id"
}

cmd_ack() {
  local id ts rc=0
  [ "${#ARGS[@]}" -ge 1 ] || die "ack needs at least one line id"
  [ -f "$ORDERS" ] || die "no order ledger at $ORDERS"
  mkdir -p "$STATE" || die "cannot create $STATE"
  lock_acquire || exit 2
  ts=$(date +%s)
  for id in "${ARGS[@]}"; do
    case "$id" in
      ''|*[!0-9]*) printf 'fm-order-ledger: not a line id: %s\n' "$id" >&2; rc=2; continue ;;
    esac
    id=$((10#$id))
    if ! order_exists "$id"; then
      printf 'fm-order-ledger: no order line with id %s\n' "$id" >&2
      rc=2
      continue
    fi
    if is_acked "$id"; then
      printf 'already acked %s\n' "$id"
      continue
    fi
    printf '{"id":%s,"ts":%s}\n' "$id" "$ts" >> "$ACKS" || die "could not append to $ACKS"
    printf 'acked %s\n' "$id"
  done
  return "$rc"
}

# announce_order <id> <from> <text>: queue the wake for an order once.
# Under the wake-queue lock the wake is appended and then the order's outbox
# line is written, so a `queued` line proves this order's own wake was appended
# (a wake consumed since is never queued again). With no line, the order's own
# key in the queue proves a wake that was appended before the line could be
# written; with neither, the order was never queued and is queued now. Nothing
# about other producers or the queue's global sequence is used as proof, so an
# order is never skipped because something else advanced the queue.
announce_order() {
  local id=$1 from=$2 text=$3 status=0
  fm_lock_acquire_wait_max "$FM_WAKE_QUEUE_LOCK" "${FM_ORDER_LOCK_WAIT:-30}" || return 1
  if [ -f "$OUTBOX" ] && awk -v id="$id" '$1 == id && $2 == "queued" { found = 1 } END { exit !found }' "$OUTBOX"; then
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
    return 0
  fi
  if ! fm_wake_queued_keys_locked check | grep -qxF -- "orders:$id" \
    && ! fm_wake_append_locked check "orders:$id" "check: order $id from $from pending in state/orders.jsonl - $text; ack with bin/fm-order-ledger.sh ack $id"; then
    status=1
  fi
  if [ "$status" -eq 0 ]; then
    printf '%s queued\n' "$id" >> "$OUTBOX" || status=1
  fi
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  return "$status"
}

# poll_pass_locked: refresh the visible pending view and queue a wake per new
# order. The view is replaced only by a complete, successful read of the ledger,
# so a failed read keeps the last good view instead of erasing it.
poll_pass_locked() {
  local tmp line id from text rc=0
  tmp=$(mktemp "$STATE/.orders.pending.XXXXXX") || return 1
  if ! pending_lines > "$tmp" || ! mv -f -- "$tmp" "$PENDING_VIEW"; then
    rm -f -- "$tmp"
    return 1
  fi
  [ -s "$PENDING_VIEW" ] || return 0
  while IFS= read -r line; do
    id=$(printf '%s' "$line" | jq -r '.id') || { rc=1; continue; }
    from=$(printf '%s' "$line" | jq -r '.from') || { rc=1; continue; }
    text=$(printf '%s' "$line" | jq -r '.text | gsub("\n"; " ") | .[0:160]') || { rc=1; continue; }
    announce_order "$id" "$from" "$text" || rc=1
  done < "$PENDING_VIEW"
  return "$rc"
}

poll_pass() {
  local rc=0
  lock_acquire || return 1
  poll_pass_locked || rc=$?
  lock_release
  return "$rc"
}

cmd_poll() {
  if [ "$ONCE" -eq 1 ]; then
    poll_pass
    return
  fi
  while :; do
    poll_pass || printf 'fm-order-ledger: poll pass failed\n' >&2
    sleep "$INTERVAL"
  done
}

cmd_timer() {
  local sub=${ARGS[0]:-}
  # shellcheck source=bin/fm-periodic-timer-lib.sh
  . "$SCRIPT_DIR/fm-periodic-timer-lib.sh"
  case "$sub" in
    install) fm_timer_install order-poll 15 "$HOME_DIR" "$SCRIPT_DIR/fm-order-ledger.sh" poll --home "$HOME_DIR" --once ;;
    remove) fm_timer_remove order-poll "$HOME_DIR" ;;
    print) fm_timer_render "$(fm_timer_kind)" "$(fm_timer_label order-poll "$HOME_DIR")" 15 "$HOME_DIR" \
      "$SCRIPT_DIR/fm-order-ledger.sh" poll --home "$HOME_DIR" --once ;;
    *) die "timer needs install, remove, or print" ;;
  esac
}

case "$CMD" in
  append) cmd_append ;;
  pending) print_pending ;;
  ack) cmd_ack ;;
  poll) cmd_poll ;;
  timer) cmd_timer ;;
  *) die "unknown command: $CMD" ;;
esac
