#!/usr/bin/env bash
# Archive positively finished task records; never delete them.
# Usage: FM_HOME=/absolute/home fm-meta-archive.sh [--apply] [task-id ...]
#        FM_HOME=/absolute/home fm-meta-archive.sh --apply --restore /absolute/archive/batch
#        fm-meta-archive.sh --probe-gone task-id backend target
# Dry-run is the default and writes nothing. --apply moves state/<id>.* together
# into a fresh state/meta-archive/<batch> after writing and syncing its JSON
# manifest (original paths, fingerprints, reason, evidence, restore command).
# Every candidate must be older than 72 hours, not kind=secondmate, and have
# positive evidence: backlog state=done or a GitHub PR API state=closed.
# Missing/unreachable/unreadable evidence keeps the record. A missing backlog
# row is not closed evidence. Local endpoints must be positively absent.
# Remote endpoint records additionally require the configured owning host's
# --probe-gone response. The read-only probe currently supports tmux; other
# backends stay until an authoritative absence probe is implemented.
# Windowless pr= records are PR-poll registrations, not remote lanes: they need
# terminal GitHub evidence even if their backlog row is done, and no host probe.
# A record with any endpoint identity does not qualify for that exception.
# Apply holds task-set, control, metadata and PR publication locks, snapshots
# all sidecars, writes the manifest, then rechecks evidence and fingerprints
# immediately before moving. Symlinks, special files and hardlinks refuse.
# Partial/interrupted batches retain the manifest; --restore refuses conflicts
# and restores the archived subset without overwriting anything.
# Requires python3, jq and gh-axi for GitHub evidence; uses existing tasks-axi
# backlog reads. No worktrees or runtime endpoints are stopped or changed.
set -u
export LC_ALL=C
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
DATA=${FM_DATA_OVERRIDE:-$FM_HOME/data}
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-lock-lib.sh
. "$SCRIPT_DIR/fm-lock-lib.sh"
HELPER="$SCRIPT_DIR/fm-meta-archive-files.py"
LOCKS=()
release_locks() {
  local n
  for ((n=${#LOCKS[@]}-1; n>=0; n--)); do fm_lock_release "${LOCKS[n]}"; done
  LOCKS=()
}
trap release_locks EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
lock_one() {
  fm_lock_try_acquire "$1" || return 1
  LOCKS+=("$1")
}
# A successful complete tmux inventory is required; a failed target lookup alone
# cannot distinguish an absent endpoint from a broken/unreachable server.
endpoint_gone() {
  local backend=$1 target=$2 inventory line
  [ "$backend" = tmux ] || return 1
  case "$target" in
    *:*)
      [ -n "${target%%:*}" ] && [ -n "${target#*:}" ] || return 1
      case "${target#*:}" in *:*) return 1 ;; esac
      ;;
    %*) case "${target#%}" in ''|*[!0-9]*) return 1 ;; esac ;;
    *) return 1 ;;
  esac
  case "$target" in *[!A-Za-z0-9._:%-]*) return 1 ;; esac
  inventory=$(fm_run_timed 10 tmux list-panes -a -F '#{session_name}:#{window_index}|#{session_name}:#{window_name}|#{pane_id}') || return 1
  [ -n "$inventory" ] || return 1
  while IFS= read -r line; do
    case "|$line|" in *"|$target|"*) return 1 ;; esac
    case "$line" in *'|'*'|'*) ;; *) return 1 ;; esac
  done <<< "$inventory"
}
if [ "${1:-}" = --help ]; then
  awk 'NR > 1 && /^#/ {sub(/^# ?/, ""); print; next} NR > 1 {exit}' "$0"
  exit 0
fi
if [ "${1:-}" = --probe-gone ]; then
  [ "$#" = 4 ] && fm_pr_task_id_valid "$2" || exit 2
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || exit 1
  [ ! -e "$STATE/$2.meta" ] && [ ! -L "$STATE/$2.meta" ] || exit 1
  endpoint_gone "$3" "$4" || exit 1
  printf 'lane-gone:%s\n' "$2"
  exit 0
fi
[ -d "$STATE" ] && [ ! -L "$STATE" ] || { echo 'error: safe state directory required' >&2; exit 1; }
STATE=$(cd "$STATE" && pwd -P) || exit 1
APPLY=0
if [ "${1:-}" = --apply ]; then APPLY=1; shift; fi
if [ "${1:-}" = --restore ]; then
  [ "$#" = 2 ] || exit 2
  if [ "$APPLY" = 0 ]; then
    python3 "$HELPER" restore-check "$STATE" "$2"
    exit $?
  fi
  lock_one "$(fm_task_set_lock_path "$STATE")" || exit 1
  id=$(python3 "$HELPER" task-id "$STATE" "$2") || exit 1
  lock_one "$STATE/.control-$id.lock" \
    && lock_one "$(fm_meta_lock_path "$STATE/$id.meta")" \
    && lock_one "$STATE/.pr-poll-publish-$id.lock" || exit 1
  python3 "$HELPER" restore "$STATE" "$2"
  exit $?
fi
for id in "$@"; do fm_pr_task_id_valid "$id" || { echo 'error: invalid task id' >&2; exit 2; }; done
if [ "$#" = 0 ]; then
  shopt -s nullglob
  METAS=("$STATE"/*.meta)
else
  METAS=()
  for id in "$@"; do METAS+=("$STATE/$id.meta"); done
fi
# Sets REASON and EVIDENCE; unknown always returns nonzero.
eligible() {
  local meta=$1 id=$2 now mtime kind pr host target backend response parsed poll=0 key value
  REASON='' EVIDENCE=''
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  kind=$(fm_meta_get "$meta" kind)
  [ "$kind" != secondmate ] && ! grep -q '^kind=secondmate$' "$meta" || return 1
  now=$(date +%s)
  mtime=$(fm_lock_path_mtime "$meta") || return 1
  case "$mtime" in ''|*[!0-9]*) return 1 ;; esac
  [ "$((now-mtime))" -gt 259200 ] || return 1
  pr=$(fm_meta_get "$meta" pr)
  host=$(fm_meta_get "$meta" remote_host)
  target=$(fm_backend_target_of_meta "$meta")
  backend=$(fm_backend_of_meta "$meta")
  if [ -n "$pr" ] && [ -z "$target" ]; then
    poll=1
    for key in window terminal remote_target herdr_session herdr_pane_id herdr_workspace_id orca_agent_id zellij_tab_id cmux_workspace_id cmux_surface_id; do
      value=$(fm_meta_get "$meta" "$key")
      [ -z "$value" ] || poll=0
    done
  fi
  if [ -n "$pr" ] && fm_pr_url_parse "$pr" && [ "$FM_PR_PROVIDER" = github ] && [ "$FM_PR_HOST" = github.com ]; then
    response=$(fm_run_timed 20 gh-axi api "repos/$FM_PR_PATH/pulls/$FM_PR_NUMBER" --full --jq '{url: .html_url, state: .state, merged: .merged, closed_at: .closed_at}') || response=
    parsed=$(printf '%s' "$response" | python3 "$HELPER" github-response "$FM_PR_URL" 2>/dev/null) || parsed=
    if [ -n "$parsed" ]; then
      REASON=terminal-github-pr
      EVIDENCE=$parsed
    fi
  fi
  if [ "$poll" = 1 ]; then
    [ "$REASON" = terminal-github-pr ] || return 1
    EVIDENCE=$(jq -cn --argjson pr "$EVIDENCE" '{pr:$pr, endpoint:"windowless-pr-poll-registration"}')
    return 0
  fi
  if [ -z "$REASON" ] && fm_backlog_row_probe "$DATA" "$id" >/dev/null 2>&1 && [ "$FM_BACKLOG_ROW_STATE" = 'done no no' ]; then
    REASON=closed-backlog-task
    EVIDENCE=$(jq -cn --arg id "$id" '{task:$id, backlog_state:"done"}')
  fi
  [ -n "$REASON" ] || return 1
  if [ -n "$host" ]; then
    [ -n "$target" ] || return 1
    response=$(fm_run_timed 20 "$SCRIPT_DIR/fm-on.sh" "$host" fm-meta-archive.sh --probe-gone "$id" "$backend" "$target") || return 1
    [ "$response" = "lane-gone:$id" ] || return 1
    EVIDENCE=$(jq -cn --argjson end "$EVIDENCE" --arg host "$host" --arg response "$response" '{end:$end, owner:$host, owner_response:$response}')
  elif [ -n "$target" ]; then
    endpoint_gone "$backend" "$target" || return 1
    EVIDENCE=$(jq -cn --argjson end "$EVIDENCE" --arg target "$target" '{end:$end, endpoint_gone:$target}')
  else
    # Endpoint fields that cannot be resolved must not look windowless.
    for key in window terminal remote_target herdr_session herdr_pane_id herdr_workspace_id orca_agent_id zellij_tab_id cmux_workspace_id cmux_surface_id; do
      [ -z "$(fm_meta_get "$meta" "$key")" ] || return 1
    done
  fi
}
FAILED=0
for meta in "${METAS[@]}"; do
  id=${meta##*/}; id=${id%.meta}
  fm_pr_task_id_valid "$id" || continue
  if [ "$APPLY" = 1 ]; then
    if ! lock_one "$(fm_task_set_lock_path "$STATE")" \
      || ! lock_one "$STATE/.control-$id.lock" \
      || ! lock_one "$(fm_meta_lock_path "$meta")" \
      || ! lock_one "$STATE/.pr-poll-publish-$id.lock"; then
      printf 'keep %s: lifecycle lock held\n' "$id"
      release_locks; continue
    fi
  fi
  if ! eligible "$meta" "$id"; then
    printf 'keep %s: no trustworthy terminal/age/endpoint evidence\n' "$id"
    release_locks; continue
  fi
  snapshot=$(python3 "$HELPER" snapshot "$STATE" "$id") || { printf 'keep %s: unsafe sidecars\n' "$id"; release_locks; continue; }
  if [ "$APPLY" = 0 ]; then
    printf 'would archive %s: %s evidence=%s\n' "$id" "$REASON" "$EVIDENCE"
    continue
  fi
  batch=$(printf '%s' "$snapshot" | python3 "$HELPER" prepare "$STATE" "$id" "$REASON" "$EVIDENCE" "$SCRIPT_DIR/fm-meta-archive.sh") || { FAILED=1; release_locks; continue; }
  printf 'manifest %s/manifest.json\n' "$batch"
  printf 'restore: FM_HOME=%q FM_STATE_OVERRIDE=%q bash %q --apply --restore %q\n' "$FM_HOME" "$STATE" "$0" "$batch"
  # The prepared manifest is durable before the final evidence read or move.
  if ! eligible "$meta" "$id"; then
    printf 'keep %s: evidence changed during revalidation\n' "$id"
  elif ! printf '%s' "$snapshot" | python3 "$HELPER" move "$STATE" "$id" "$batch" "$REASON" "$EVIDENCE"; then
    printf 'error: archive of %s incomplete; consult manifest\n' "$id" >&2
    FAILED=1
  else
    printf 'archived %s in %s\n' "$id" "$batch"
  fi
  release_locks
done
exit "$FAILED"
