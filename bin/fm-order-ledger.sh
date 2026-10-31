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
# The ledger and its acknowledgements are the only record of an order: delivery
# keeps no state of its own. An order is pending until its own id is
# acknowledged. Acking one id never acknowledges another, whatever the numeric
# order, and acking twice is a no-op.
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
#       Secondmate side: refresh state/orders.pending and keep one wake queued
#       (key orders:pending) while any order is pending, every --interval seconds
#       (default 15) until stopped; --once does a single pass. The wake is added
#       only when none is queued, so delivery repeats until every order is
#       acknowledged and never stacks. Its text only points at `pending`, so a
#       wake that outlives the orders it named finds nothing pending. Run the
#       poll from whatever supervises the home; this script installs no timer.
#
# Every writer takes the home's ledger lock (fm-wake-lib.sh's owner-checked
# lock, so a dead owner is reclaimed by exactly one waiter and a signal releases
# only this process's own hold); FM_ORDER_LOCK_WAIT bounds the wait (default 30s).
# Ledger lines are published by writing the whole new file beside the old one and
# renaming, so a failed write never leaves a torn line.
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
LOCK="$STATE/.orders.lock"
WAKE_KEY="orders:pending"

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

# check_ledger_files: fail loudly, naming the file, when a ledger file cannot be
# trusted: a path that exists but is not a regular file (an acks path that is a
# directory would otherwise read as "no acknowledgements" and list every order as
# pending again), or a file with any line that is not a JSON object carrying a
# numeric id (a malformed acks file would otherwise hide or invent acknowledgements).
check_ledger_files() {
  local f
  for f in "$ORDERS" "$ACKS"; do
    if [ -e "$f" ] && [ ! -f "$f" ]; then
      printf 'fm-order-ledger: %s is not a regular file\n' "$f" >&2
      return 1
    fi
    [ -s "$f" ] || continue
    if ! jq -e -s 'all(.[]; type == "object" and (.id | type) == "number")' "$f" >/dev/null 2>&1; then
      printf 'fm-order-ledger: %s is malformed: every line must be a JSON object with a numeric id\n' "$f" >&2
      return 1
    fi
  done
}

# pending_lines: orders whose own id has no acknowledgement line. The lookup is
# linear in the acks per order, which is known and fine at ledger sizes in use.
pending_lines() {
  local acks=/dev/null
  check_ledger_files || return 1
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
  [ -e "$ORDERS" ] || return 0
  lock_acquire || exit 2
  out=$(pending_lines) || rc=$?
  lock_release
  [ "$rc" -eq 0 ] || die "cannot read the order ledger"
  [ -n "$out" ] || return 0
  if [ "$JSON" -eq 1 ]; then
    printf '%s\n' "$out"
  else
    printf '%s\n' "$out" | jq -r '"\(.id) \(.from) \(.text | gsub("\n"; " "))"' || die "cannot format the pending orders"
  fi
}

# publish_line <file> <line>: add one complete line to an append-only file by
# writing the whole new content beside it and renaming over it. A failed write
# leaves the old file untouched, so a torn line is never published.
publish_line() {
  local file=$1 line=$2 tmp
  if [ -e "$file" ] && [ ! -f "$file" ]; then
    printf 'fm-order-ledger: %s is not a regular file\n' "$file" >&2
    return 1
  fi
  tmp=$(mktemp "$file.XXXXXX") || return 1
  if ! { { [ ! -f "$file" ] || cat -- "$file"; } > "$tmp" && printf '%s\n' "$line" >> "$tmp" \
    && mv -f -- "$tmp" "$file"; }; then
    rm -f -- "$tmp"
    return 1
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
  check_ledger_files || exit 2
  last=0
  if [ -s "$ORDERS" ]; then
    last=$(jq -s 'map(.id) | max // 0' "$ORDERS" 2>/dev/null) || die "$ORDERS is not valid JSON lines"
  fi
  id=$((last + 1))
  ts=$(date +%s)
  line=$(jq -cn --argjson id "$id" --argjson ts "$ts" --arg from "$FROM" --arg text "$text" \
    '{id:$id,ts:$ts,from:$from,text:$text}') || die "could not encode the order"
  publish_line "$ORDERS" "$line" || die "could not append to $ORDERS"
  printf '%s\n' "$id"
}

cmd_ack() {
  local id ts rc=0
  [ "${#ARGS[@]}" -ge 1 ] || die "ack needs at least one line id"
  [ -f "$ORDERS" ] || die "no order ledger at $ORDERS"
  mkdir -p "$STATE" || die "cannot create $STATE"
  lock_acquire || exit 2
  check_ledger_files || exit 2
  ts=$(date +%s)
  for id in "${ARGS[@]}"; do
    case "$id" in
      ''|*[!0-9]*) printf 'fm-order-ledger: not a line id: %s\n' "$id" >&2; rc=2; continue ;;
    esac
    # Ids stay below 10^15 so bash and jq agree on them; longer digit strings
    # would wrap in bash arithmetic and could ack a different order.
    id=${id#"${id%%[!0]*}"}
    : "${id:=0}"
    if [ "${#id}" -gt 15 ]; then
      printf 'fm-order-ledger: line id out of range: %s\n' "$id" >&2
      rc=2
      continue
    fi
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
    publish_line "$ACKS" "$(printf '{"id":%s,"ts":%s}' "$id" "$ts")" || die "could not append to $ACKS"
    printf 'acked %s\n' "$id"
  done
  return "$rc"
}

# ensure_order_wake <count> <ids>: make sure the one pending wake is queued. A
# wake the secondmate consumed while orders are still pending is queued again,
# so delivery repeats until every order is acknowledged and never stacks.
ensure_order_wake() {
  local count=$1 ids=$2 status=0
  fm_lock_acquire_wait_max "$FM_WAKE_QUEUE_LOCK" "${FM_ORDER_LOCK_WAIT:-30}" || return 1
  if ! fm_wake_queued_keys_locked check | grep -qxF -- "$WAKE_KEY" \
    && ! fm_wake_append_locked check "$WAKE_KEY" "check: $count order(s) pending in state/orders.jsonl (ids $ids) - list them with bin/fm-order-ledger.sh pending and ack each by id with bin/fm-order-ledger.sh ack <id>"; then
    status=1
  fi
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  return "$status"
}

# poll_pass_locked: refresh the visible pending view and queue the wake while any
# order is pending. The view is replaced only by a complete, successful read of
# the ledger, so a failed read keeps the last good view instead of erasing it.
poll_pass_locked() {
  local tmp count ids
  tmp=$(mktemp "$STATE/.orders.pending.XXXXXX") || return 1
  if ! pending_lines > "$tmp" || ! mv -f -- "$tmp" "$PENDING_VIEW"; then
    rm -f -- "$tmp"
    return 1
  fi
  [ -s "$PENDING_VIEW" ] || return 0
  count=$(jq -s 'length' "$PENDING_VIEW") || return 1
  ids=$(jq -rs 'map(.id | tostring) | join(",")' "$PENDING_VIEW") || return 1
  ensure_order_wake "$count" "$ids"
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

case "$CMD" in
  append) cmd_append ;;
  pending) print_pending ;;
  ack) cmd_ack ;;
  poll) cmd_poll ;;
  *) die "unknown command: $CMD" ;;
esac
