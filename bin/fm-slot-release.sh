#!/usr/bin/env bash
# Make a retired Treehouse pool slot leasable again, branch always kept.
# Usage: fm-slot-release.sh <task-id|slot-path> [--lease-id <id>]
#        fm-slot-release.sh --sweep [<project-dir>...]
#
# Release mode runs the one retire owner (fm_treehouse_slot_retire in
# bin/fm-wake-lib.sh) for a slot whose agent is already gone: the landed-work
# gate first, then `treehouse return` (HEAD detaches, the branch ref is kept),
# then release of the task's own claim. It prints exactly one result word and
# exits 0 only for `released`:
#   released | kept:dirty | kept:unlanded | kept:reassigned | failed
# A task id is resolved through its record in this home's state directory
# (worktree= and lease_id=); a path needs a readable claim naming the task.
# Any other retire flow, such as a lane reaper that ends an agent without a
# teardown, calls this command rather than ending the agent and stopping.
# Exit: 0 released, 1 anything else, 2 usage.
#
# Sweep mode repairs slots already stranded (typically a pane killed hard
# before any retire ran): for each project clone under this home's projects/
# directory (or the directories named), it lists the pool with
# `treehouse status --json` and acts only on a slot that is
#   - `available` (no process or lease holds it) yet still holds a branch, and
#   - without a live claim (none, or one whose task record is gone), and
#   - clean, and its work pushed to a real remote or already in the default
#     branch (the retire owner's gate decides this; a dirty or unlanded slot
#     is kept and reported, never reset).
# Each slot acted on appends "<epoch> <project> <slot> <branch> <result>" to
# state/slot-sweep.log, and a kept or failed slot prints one actionable
# "SLOT_SWEEP: <slot>: <result> (<branch>)" line. A released slot is silent.
# A project whose Treehouse allocation lock is busy is skipped until the next
# sweep. The empty file config/slot-sweep-disable switches the sweep off
# entirely (release mode is unaffected); sweep exits 0 whatever it found.
# Callers: bin/fm-bootstrap.sh at session start and the watcher's heartbeat.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

usage() {
  echo "usage: fm-slot-release.sh <task-id|slot-path> [--lease-id <id>] | --sweep [<project-dir>...]" >&2
  exit 2
}

# Run the retire owner for one slot under the project's allocation lock, so no
# spawn can claim the slot between the gate and the claim release.
#   Returns the owner's status, 2 when the lock path cannot be resolved, 3 when
#   the lock is busy, and 4 when the optional recheck (run under the lock) says
#   the slot is no longer what the caller saw.
retire_locked() {  # <project> <worktree> <task-id> [lease-id] [recheck-fn]
  local project=$1 worktree=$2 id=$3 lease=${4:-} recheck=${5:-} lock rc
  lock=$(fm_treehouse_project_lock_path "$project") || return 2
  fm_lock_try_acquire "$lock" || return 3
  rc=0
  if [ -n "$recheck" ] && ! "$recheck" "$project" "$worktree" "$id"; then
    rc=4
  else
    fm_treehouse_slot_retire "$worktree" "$id" "$lease" || rc=$?
  fi
  fm_lock_release "$lock" || true
  return "$rc"
}

# The sweep decided on an unlocked read, so a spawn may have leased the slot and
# claimed it - even under a reused task id - before the lock was taken. Trust
# nothing carried over: under the lock the slot must still read available on the
# same branch, and its claim must again be free, which a live task record for a
# reused id is not.
sweep_recheck() {  # <project> <worktree> <task-id>
  local project=$1 worktree=$2 row
  row=$( cd "$project" && treehouse status --json 2>/dev/null </dev/null \
    | jq -r --arg p "$worktree" '.[]? | select(.path == $p) | [.status, (.branch // "")] | @tsv' ) || return 1
  [ "$row" = "$(printf 'available\t%s' "$SWEEP_BRANCH")" ] || return 1
  fm_treehouse_slot_claim_custody "$worktree" ""
  [ "$FM_TREEHOUSE_SLOT_CLAIM" = free ]
}

slot_project() {  # <worktree> -> the project clone that owns the slot's pool
  local common
  common=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  case "$common" in
    */.git) printf '%s\n' "${common%/.git}" ;;
    *) printf '%s\n' "$common" ;;
  esac
}

release_one() {  # <task-id|path> [lease-id]
  local arg=$1 lease=${2:-} id worktree project rc
  if [ -d "$arg" ]; then
    worktree=$arg
    fm_treehouse_slot_owner_state "$worktree" ""
    id=$FM_TREEHOUSE_SLOT_OWNER_ID
    [ -n "$id" ] || { echo failed; echo "error: no readable claim at $worktree names a task; pass the task id" >&2; return 1; }
  else
    case "$arg" in ''|*[!A-Za-z0-9._-]*|.|..) usage ;; esac
    id=$arg
    worktree=$(fm_meta_get "$STATE/$id.meta" worktree)
    [ -n "$lease" ] || lease=$(fm_meta_get "$STATE/$id.meta" lease_id)
    [ -n "$worktree" ] && [ -d "$worktree" ] || { echo failed; echo "error: task $id has no existing worktree on record" >&2; return 1; }
  fi
  project=$(slot_project "$worktree") || { echo failed; return 1; }
  fm_treehouse_pool_slot "$project" "$worktree" || { echo failed; echo "error: $worktree is not a Treehouse pool slot of $project" >&2; return 1; }
  rc=0
  retire_locked "$project" "$worktree" "$id" "$lease" || rc=$?
  case "$rc" in
    2|3) echo failed; echo "error: cannot take the Treehouse allocation lock for $project" >&2; return 1 ;;
  esac
  echo "$FM_TREEHOUSE_SLOT_RETIRE_RESULT"
  return "$rc"
}

sweep_project() {  # <project-dir>
  local project=$1 rows row slot branch rc result
  command -v treehouse >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || return 0
  rows=$( cd "$project" && treehouse status --json 2>/dev/null </dev/null \
    | jq -r '.[]? | select(.status == "available" and (.branch // "") != "") | [.path, .branch] | @tsv' ) || return 0
  while IFS=$'\t' read -r slot branch; do
    [ -n "$slot" ] || continue
    fm_treehouse_pool_slot "$project" "$slot" || continue
    fm_treehouse_slot_claim_custody "$slot" ""
    [ "$FM_TREEHOUSE_SLOT_CLAIM" = free ] || continue
    row=${FM_TREEHOUSE_SLOT_OWNER_ID:-sweep}
    rc=0
    SWEEP_BRANCH=$branch
    retire_locked "$project" "$slot" "$row" "" sweep_recheck || rc=$?
    case "$rc" in
      2|3) return 0 ;;
      4) continue ;;
    esac
    result=$FM_TREEHOUSE_SLOT_RETIRE_RESULT
    mkdir -p "$STATE" 2>/dev/null || true
    printf '%s %s %s %s %s\n' "$(date +%s)" "$project" "$slot" "$branch" "$result" >> "$STATE/slot-sweep.log" 2>/dev/null || true
    [ "$result" = released ] || echo "SLOT_SWEEP: $slot: $result ($branch)"
  done <<EOF
$rows
EOF
}

sweep() {
  local dir
  if [ -e "$FM_HOME/config/slot-sweep-disable" ]; then
    return 0
  fi
  if [ "$#" -eq 0 ]; then
    [ -d "$PROJECTS" ] || return 0
    for dir in "$PROJECTS"/*/; do
      [ -d "${dir}.git" ] || [ -f "${dir}.git" ] || continue
      sweep_project "${dir%/}"
    done
  else
    for dir in "$@"; do
      sweep_project "$dir"
    done
  fi
  return 0
}

case "${1-}" in
  -h|--help|'') usage ;;
  --sweep) shift; sweep "$@" ;;
  *)
    target=$1
    shift
    lease=
    if [ "${1-}" = --lease-id ]; then
      [ "$#" -eq 2 ] || usage
      lease=$2
      shift 2
    fi
    [ "$#" -eq 0 ] || usage
    rc=0
    release_one "$target" "$lease" || rc=$?
    exit "$rc"
    ;;
esac
