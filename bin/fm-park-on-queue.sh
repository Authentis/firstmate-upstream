#!/usr/bin/env bash
# fm-park-on-queue.sh - stop a completed queue lane without tearing it down.
#
# Usage: fm-park-on-queue.sh <task-id>
#
# This is the transition hook for bin/fm-watch.sh.  With config/park-on-queue
# absent or set to `on`, a task whose latest declaration is `done:` or a
# `paused:` declaration saying `ready for validation` or `waiting for a gate
# go` is stopped through `bin/fm-control.sh <id> exit`.  Its worktree, branch,
# metadata, and status log remain in place.  The hook refuses to act while the
# status decision fold has an open needs-decision or blocked key, or while
# fm-crew-state.sh attributes an active no-mistakes run to the task.
#
# A later gate go is one ordinary control-plane relaunch plus a steer, for
# example: bin/fm-control.sh <id> relaunch --note 'gate go'; bin/fm-send.sh
# <id> 'gate go: continue with validation'.
#
# An eligible task that cannot be parked yet (validation still active, or a
# failed exit) leaves state/<id>.park-pending and the script exits 75; the
# watcher retries that marker until the task parks, stops being eligible, or
# opens a decision, so a consumed status line never loses the obligation.
#
# With config/park-on-queue set to `off`, an otherwise eligible task is not
# stopped and one non-eligible line is appended to its status log (once per
# status line) so the operator can see parking is disabled.
#
# Config:
#   config/park-on-queue  `on` (default) or `off`
#
# FM_PARK_CONTROL_BIN and FM_PARK_CREW_STATE_BIN are test seams only.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
CONTROL_BIN="${FM_PARK_CONTROL_BIN:-$SCRIPT_DIR/fm-control.sh}"
CREW_STATE_BIN="${FM_PARK_CREW_STATE_BIN:-$SCRIPT_DIR/fm-crew-state.sh}"

# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

id=${1:-}
case "$id" in
  ''|*[!A-Za-z0-9._-]*) echo "error: invalid task id" >&2; exit 2 ;;
esac
[ "$#" -eq 1 ] || { echo "usage: fm-park-on-queue.sh <task-id>" >&2; exit 2; }

enabled=on
if [ -e "$CONFIG/park-on-queue" ] || [ -L "$CONFIG/park-on-queue" ]; then
  [ -f "$CONFIG/park-on-queue" ] && [ ! -L "$CONFIG/park-on-queue" ] && [ -r "$CONFIG/park-on-queue" ] || {
    echo "error: config/park-on-queue must be a readable regular file" >&2
    exit 1
  }
  enabled=$(tr -d '[:space:]' < "$CONFIG/park-on-queue")
  case "$enabled" in
    on|off) ;;
    *) echo "error: config/park-on-queue must be on or off" >&2; exit 1 ;;
  esac
fi
status="$STATE/$id.status"
pending="$STATE/$id.park-pending"
defer_park() {
  : > "$pending"
}
[ -f "$status" ] && [ ! -L "$status" ] && [ -r "$status" ] || { rm -f "$pending"; exit 0; }
[ -n "$(status_open_decisions "$status")" ] && { rm -f "$pending"; exit 0; }

line=$(last_status_line "$status")
verb=$(status_line_verb "$line")
eligible=0
case "$verb" in
  done) eligible=1 ;;
  paused)
    note=$(status_line_note "$line" | tr '[:upper:]' '[:lower:]')
    case "$note" in
      *'ready for validation'*|*'waiting for gate go'*|*'waiting for a gate go'*) eligible=1 ;;
    esac
    ;;
esac
[ "$eligible" -eq 1 ] || { rm -f "$pending"; exit 0; }

if [ "$enabled" != on ]; then
  rm -f "$pending"
  marker=$(printf '%s' "$line" | cksum | cut -d' ' -f1)
  off_note="park-on-queue is off; task=$id status=$marker"
  if ! grep -Fq "$off_note" "$status"; then
    printf 'parking-disabled [at=%s]: %s\n' "$(date +%s)" "$off_note" >> "$status"
  fi
  exit 0
fi

crew_state=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$CREW_STATE_BIN" "$id" 2>/dev/null || true)
case "$crew_state" in
  'state: working'*'source: run-step'*|'state: parked'*'source: run-step'*)
    defer_park
    exit 75
    ;;
esac

# fm-control's gate-lab allowance deliberately accepts only its stock layout;
# the watcher supplies state/config overrides even when they name that layout.
# They are unnecessary for this control call because it receives the same home.
if ! control_error=$(env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE \
  -u FM_ROOT_OVERRIDE -u FM_DATA_OVERRIDE FM_HOME="$FM_HOME" \
  "$CONTROL_BIN" "$id" exit 2>&1); then
  defer_park
  printf 'error: fm-control exit failed for %s; parking will be retried: %s\n' "$id" "$control_error" >&2
  exit 75
fi
rm -f "$pending"
printf 'paused [at=%s]: parked on queue; use fm-control relaunch then steer the gate go\n' "$(date +%s)" >> "$status"
printf 'parked: %s\n' "$id"
