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
[ "$enabled" = on ] || exit 0

status="$STATE/$id.status"
[ -f "$status" ] && [ ! -L "$status" ] && [ -r "$status" ] || exit 0
[ -n "$(status_open_decisions "$status")" ] && exit 0

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
[ "$eligible" -eq 1 ] || exit 0

crew_state=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$CREW_STATE_BIN" "$id" 2>/dev/null || true)
case "$crew_state" in
  'state: working'*'source: run-step'*|'state: parked'*'source: run-step'*) exit 0 ;;
esac

FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$CONTROL_BIN" "$id" exit >/dev/null
printf 'paused [at=%s]: parked on queue; use fm-control relaunch then steer the gate go\n' "$(date +%s)" >> "$status"
printf 'parked: %s\n' "$id"
