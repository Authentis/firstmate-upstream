#!/usr/bin/env bash
# fm-pending-reply.sh - owner commands for parent pending-reply records.
#
# The records, their phases, and the retirement contract are owned by
# bin/fm-pending-reply-lib.sh; this is only its operator entry point.
#
# Usage:
#   FM_HOME=<home> fm-pending-reply.sh list <task-id>
#   FM_HOME=<home> fm-pending-reply.sh retire <task-id> --reason <text> [--dry-run]
#
# list    Print one tab-separated line per live record of <task-id>:
#         corr, phase, created epoch, request summary. Read-only.
# retire  Retire every unsettled live record of exactly <task-id> on the
#         owner's decision that those requests are obsolete. Resolved and
#         already-retired records and every other task's records are never
#         touched, and a record whose recovery repost is in flight is refused.
#         A retired record can never be reposted, escalated, or reopened, so a
#         later reply-mirror repair cannot release a burst of stale reposts.
#         Each retirement keeps the full record, closes any escalation decision
#         it opened, and appends one line to
#         state/pending-replies/archive/retired.log. --dry-run lists what would
#         be retired and changes nothing.
#
# FM_HOME must be explicit so the command never acts on another home. Exit 0
# on success, 1 when any record was refused or failed, 2 on usage errors.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '7,9p' "${BASH_SOURCE[0]}" | sed 's/^# *//' >&2
  exit 2
}

if [ -z "${FM_HOME:-}" ]; then
  echo "error: FM_HOME is not set; fm-pending-reply refuses to guess a firstmate home" >&2
  exit 2
fi
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
[ -d "$STATE" ] || { echo "error: state dir '$STATE' is missing" >&2; exit 2; }

# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"

# Live records of <task-id>, one path per line.
task_records() {  # <task-id>
  local rec dir
  dir=$(fm_pending_reply_dir "$STATE")
  [ -d "$dir" ] || return 0
  for rec in "$dir"/*; do
    [ -f "$rec" ] && [ ! -L "$rec" ] || continue
    _fm_pending_reply_load "$rec" || continue
    [ "$_FPR_TASK" = "$1" ] || continue
    printf '%s\n' "$rec"
  done
}

cmd_list() {
  local task=${1:-} rec
  [ -n "$task" ] && [ "$#" -eq 1 ] || usage
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    _fm_pending_reply_load "$rec" || continue
    printf '%s\t%s\t%s\t%s\n' "${_FPR_CORR:-${rec##*/}}" "$_FPR_PHASE" "$_FPR_CREATED" \
      "$(fm_pending_reply_get "$rec" request_summary)"
  done <<EOF
$(task_records "$task")
EOF
}

cmd_retire() {
  local task=${1:-} reason='' dry=0 rec corr rc status=0 retired=0 skipped=0 refused=0
  [ -n "$task" ] || usage
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --reason) [ "$#" -ge 2 ] || usage; reason=$2; shift 2 ;;
      --dry-run) dry=1; shift ;;
      *) usage ;;
    esac
  done
  [ -n "$reason" ] || { echo "error: retire requires --reason <text>" >&2; exit 2; }
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    _fm_pending_reply_load "$rec" || continue
    corr=${_FPR_CORR:-${rec##*/}}
    case "$_FPR_PHASE" in resolved|retired) skipped=$((skipped + 1)); continue ;; esac
    if [ "$dry" = 1 ]; then
      printf 'would-retire\t%s\t%s\n' "$corr" "$_FPR_PHASE"
      continue
    fi
    rc=0
    fm_pending_reply_retire "$STATE" "$corr" "$reason" || rc=$?
    case "$rc" in
      0) retired=$((retired + 1)); printf 'retired\t%s\t%s\n' "$corr" "$_FPR_PHASE" ;;
      3) skipped=$((skipped + 1)) ;;
      *) refused=$((refused + 1)); status=1; printf 'refused\t%s\t%s\n' "$corr" "$_FPR_PHASE" >&2 ;;
    esac
  done <<EOF
$(task_records "$task")
EOF
  printf 'summary: task=%s retired=%s settled-untouched=%s refused=%s%s\n' \
    "$task" "$retired" "$skipped" "$refused" "$([ "$dry" = 1 ] && printf ' (dry run)')"
  return "$status"
}

case "${1:-}" in
  list) shift; cmd_list "$@" ;;
  retire) shift; cmd_retire "$@" ;;
  *) usage ;;
esac
