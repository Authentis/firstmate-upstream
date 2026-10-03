#!/usr/bin/env bash
# Acknowledge a task's steering-inbox messages: move each into the task's
# handled/ directory and clear the doorbell retry and escalation records that
# name it, so the doorbell stops ringing.
# Usage: fm-inbox-ack.sh <task-id> <seq>...
#        fm-inbox-ack.sh <task-id> --all-handled-through <seq>
#   <seq> is the number of a message (727 acknowledges 727.msg); a trailing
#   ".msg" is accepted. --all-handled-through acknowledges every pending message
#   numbered at or below <seq>. Acknowledging a message already in handled/ is a
#   success, and one that is in neither place is an error; with several
#   sequences every one is attempted and the exit is nonzero if any failed. A
#   task id that is not a valid task id is refused.
# The inbox is state/<task-id>.inbox under this home's state directory
# (FM_STATE_OVERRIDE, else $FM_HOME/state; FM_HOME defaults to the firstmate
# root this script lives in), or state/parent-route/<task-id>.inbox for a
# secondmate's own inbox; fm_task_inbox_state_for picks between them, so no
# override is needed for either. The mechanics, the refusal of symlinked inbox
# paths, and the bookkeeping cleanup live in bin/fm-task-inbox-lib.sh
# (fm_task_inbox_acknowledge); this script is the one command workers use in
# place of a raw move, which command guards refuse. Exit: 0 all acknowledged,
# 1 a message failed, 2 usage.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$SCRIPT_DIR/fm-task-inbox-lib.sh"

usage() {
  echo "usage: fm-inbox-ack.sh <task-id> <seq>... | <task-id> --all-handled-through <seq>" >&2
  exit 2
}

case "${1-}" in -h|--help) usage ;; esac
[ "$#" -ge 2 ] || usage
ID=$1
shift
if ! fm_pr_task_id_valid "$ID"; then
  echo "error: invalid task id" >&2
  exit 2
fi
STATE=$(fm_task_inbox_state_for "$STATE" "$ID")

seq_arg() {  # <arg> -> digits on stdout, or fail
  local a=${1%.msg}
  case "$a" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$a"
}

rc=0
if [ "$1" = --all-handled-through ]; then
  [ "$#" -eq 2 ] || usage
  limit=$(seq_arg "$2") || usage
  limit=$((10#$limit))
  DIR=$(fm_task_inbox_dir "$STATE" "$ID")
  if [ -L "$DIR" ] || [ ! -d "$DIR" ]; then
    echo "error: no steering inbox for task $ID" >&2
    exit 1
  fi
  for f in "$DIR"/*.msg; do
    [ -e "$f" ] || continue
    n=$(fm_task_inbox_seq_of "${f##*/}") || continue
    [ "$n" -le "$limit" ] || continue
    fm_task_inbox_acknowledge "$STATE" "$ID" "$n" || rc=1
  done
else
  seqs=()
  for a in "$@"; do
    s=$(seq_arg "$a") || { echo "error: not a sequence number: $a" >&2; usage; }
    seqs+=("$s")
  done
  for s in "${seqs[@]}"; do
    fm_task_inbox_acknowledge "$STATE" "$ID" "$s" || rc=1
  done
fi
exit "$rc"
