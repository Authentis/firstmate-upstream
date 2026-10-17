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
#   state/orders.pending      the current pending lines, rewritten by every poll.
#   state/orders.announced    ids a poll has already turned into a wake.
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
#       newly seen pending order, every --interval seconds (default 60) until
#       stopped; --once does a single pass.
#   fm-order-ledger.sh timer install|remove|print [--home <dir>]
#       Run `poll --once` every 60 seconds from the host's launchd or systemd.
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
INTERVAL=${FM_ORDER_POLL_INTERVAL:-60}
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
ANNOUNCED="$STATE/orders.announced"
LOCK="$STATE/.orders.lock"

lock_acquire() {
  local tries=0 owner
  while ! mkdir "$LOCK" 2>/dev/null; do
    owner=$(cat "$LOCK/pid" 2>/dev/null || true)
    if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
      rm -rf -- "$LOCK"
      continue
    fi
    tries=$((tries + 1))
    [ "$tries" -le 100 ] || die "ledger lock is held by $owner"
    sleep 0.1
  done
  printf '%s\n' "$$" > "$LOCK/pid"
}

lock_release() {
  rm -rf -- "$LOCK"
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

print_pending() {
  if [ "$JSON" -eq 1 ]; then
    pending_lines
  else
    pending_lines | jq -r '"\(.id) \(.from) \(.text | gsub("\n"; " "))"'
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
  lock_acquire
  trap lock_release EXIT HUP INT TERM
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
  lock_acquire
  trap lock_release EXIT HUP INT TERM
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

# poll_pass: refresh the visible pending view and queue a wake per new order.
poll_pass() {
  local tmp line id from text wake_lib="$FM_ROOT/bin/fm-wake-lib.sh"
  mkdir -p "$STATE" || return 1
  tmp=$(mktemp "$STATE/.orders.pending.XXXXXX") || return 1
  pending_lines > "$tmp"
  mv -f -- "$tmp" "$PENDING_VIEW"
  [ -s "$PENDING_VIEW" ] || return 0
  [ -r "$wake_lib" ] || return 0
  while IFS= read -r line; do
    id=$(printf '%s' "$line" | jq -r '.id')
    if [ -f "$ANNOUNCED" ] && grep -qx "$id" "$ANNOUNCED"; then
      continue
    fi
    from=$(printf '%s' "$line" | jq -r '.from')
    text=$(printf '%s' "$line" | jq -r '.text | gsub("\n"; " ") | .[0:160]')
    if (
      FM_HOME=$HOME_DIR
      # shellcheck disable=SC1090,SC1091
      . "$wake_lib"
      fm_wake_append check "orders:$id" "check: order $id from $from pending in state/orders.jsonl - $text; ack with bin/fm-order-ledger.sh ack $id"
    ); then
      printf '%s\n' "$id" >> "$ANNOUNCED"
    fi
  done < "$PENDING_VIEW"
}

cmd_poll() {
  if [ "$ONCE" -eq 1 ]; then
    poll_pass
    return
  fi
  trap 'exit 0' HUP INT TERM
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
    install) fm_timer_install order-poll 60 "$HOME_DIR" "$SCRIPT_DIR/fm-order-ledger.sh" poll --home "$HOME_DIR" --once ;;
    remove) fm_timer_remove order-poll "$HOME_DIR" ;;
    print) fm_timer_render "$(fm_timer_kind)" "$(fm_timer_label order-poll "$HOME_DIR")" 60 "$HOME_DIR" \
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
