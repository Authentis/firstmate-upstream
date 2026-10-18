#!/usr/bin/env bash
# Retire finished ship lanes whose bound PR is merged or closed.
#
# One bounded pass over this home's state/<id>.meta records, meant to run from a
# host's existing periodic trigger (a receipt cron) right after merges and
# closes, so stale lane records stop being listed by anything that reads them.
# It is not a daemon and keeps no state of its own beyond the log.
#
# Usage: fm-lane-retire.sh [--dry-run]
#
# For each kind=ship record with a recorded GitHub pr= and a worktree:
#   - PR state comes from `gh pr view`; OPEN, unknown, or a lookup error leaves
#     the record untouched.
#   - A worktree with any tracked or untracked change is refused: a bundle only
#     captures commits, so retiring it would lose the edits.
#   - Commits beyond the lane's base (base_branch= or origin's default) are
#     bundled first into data/bundles/<id>.bundle and the bundle must verify.
#     No verified bundle, no retirement (SO-1: bundle unmerged work first).
#   - MERGED retires through a plain `bin/fm-teardown.sh <id>`, so its landed-work
#     gates still decide. CLOSED (never merged) retires through
#     `fm-teardown.sh <id> --force` only after the verified bundle above, which is
#     the standing SO-1 branch-retirement authority for finished lanes.
# Every action, including each refusal, is appended to data/lane-retire.log.
#
# Residual (accepted): the last PR-state and lane rechecks run immediately before
# teardown, but no check-then-act over the network is atomic, so a PR reopened or a
# commit made in that instant can still be retired. The safety property is
# recoverability: the verified bundle is always kept and every retirement is logged
# (intent line first). Ignored files are neither refused nor bundled, so a CLOSED
# lane's ignored build output is lost with its worktree.
# Restore a retired lane's commits from its bundle, in the project clone:
#   git fetch data/bundles/<id>.bundle HEAD:refs/heads/restore/<id>
# The log line naming <id> and its PR URL says which lane and PR it was.
#
# Kill switch: `touch config/lane-retire.off` (or FM_LANE_RETIRE=off) makes the
# pass exit 0 before reading anything. A second pass started while one runs exits 0.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="$FM_HOME/state"
LOG="$FM_HOME/data/lane-retire.log"
BUNDLES="$FM_HOME/data/bundles"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

TEARDOWN="$SCRIPT_DIR/fm-teardown.sh"
[ "${FM_TEST_SEAM:-}" != 1 ] || [ -z "${FM_LANE_RETIRE_TEARDOWN:-}" ] || TEARDOWN=$FM_LANE_RETIRE_TEARDOWN

DRY=0
case "${1:-}" in
  --dry-run) DRY=1 ;;
  -h | --help)
    sed -n '2,/^set -u$/s/^# \{0,1\}//p' "$0" | sed '$d'
    exit 0
    ;;
  '') ;;
  *)
    echo "usage: fm-lane-retire.sh [--dry-run]" >&2
    exit 2
    ;;
esac

[ "${FM_LANE_RETIRE:-on}" != off ] || exit 0
[ ! -e "$FM_HOME/config/lane-retire.off" ] || exit 0
[ -d "$STATE" ] || exit 0

log() {  # <action> <id> <detail>
  local line
  line="$(date -u +%Y-%m-%dT%H:%M:%SZ) $1 $2 $3"
  printf '%s\n' "$line"
  [ "$DRY" = 1 ] && return 0
  mkdir -p "$(dirname "$LOG")" 2>/dev/null && printf '%s\n' "$line" >> "$LOG" 2>/dev/null
}

LOCK="$STATE/.lane-retire.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  # A lock left by a dead pass must not wedge retirement forever.
  holder=$(cat "$LOCK/pid" 2>/dev/null || true)
  if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
    exit 0
  fi
  rm -rf "$LOCK"
  mkdir "$LOCK" 2>/dev/null || exit 0
fi
echo $$ > "$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT

pr_state() {  # <pr-url> -> merged|closed|open|unknown
  local out
  command -v gh >/dev/null 2>&1 || { echo unknown; return; }
  out=$(gh pr view "$1" --json state --jq .state 2>/dev/null) || { echo unknown; return; }
  case "$out" in
    MERGED) echo merged ;;
    CLOSED) echo closed ;;
    OPEN) echo open ;;
    *) echo unknown ;;
  esac
}

# Print the lane's base ref, or nothing when it cannot be resolved.
base_ref() {  # <worktree> <meta>
  local wt=$1 base head
  base=$(fm_meta_get "$2" base_branch)
  if [ -n "$base" ]; then
    printf 'origin/%s\n' "$base"
    return
  fi
  head=$(git -C "$wt" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null) || return 0
  printf '%s\n' "$head"
}

# 0 when nothing is at risk (no commits beyond base) or a verified bundle holds them.
bundle_lane() {  # <id> <worktree> <base> <head-sha>
  local id=$1 wt=$2 base=$3 head=$4 n file
  [ -n "$head" ] || return 1
  n=$(git -C "$wt" rev-list --count "$base..$head" 2>/dev/null) || return 1
  [ "$n" -gt 0 ] || return 0
  [ "$DRY" != 1 ] || return 0
  file="$BUNDLES/$id.bundle"
  mkdir -p "$BUNDLES" 2>/dev/null || return 1
  git -C "$wt" bundle create -q "$file.tmp" HEAD "^$base" >/dev/null 2>&1 \
    && git -C "$wt" bundle verify -q "$file.tmp" >/dev/null 2>&1 \
    && mv -f "$file.tmp" "$file" 2>/dev/null \
    && git -C "$wt" bundle verify -q "$file" >/dev/null 2>&1 \
    && git -C "$wt" bundle list-heads "$file" 2>/dev/null | grep -q "^$head HEAD" \
    || { rm -f "$file.tmp"; return 1; }
}

# Right before teardown: the record still names the lane that was inspected, the
# worktree is still clean, and HEAD is still the commit the bundle covers.
lane_unchanged() {  # <meta> <pr> <wt> <head>
  [ -f "$1" ] && [ "$(fm_meta_get "$1" pr)" = "$2" ] && [ "$(fm_meta_get "$1" worktree)" = "$3" ] \
    && [ "$(git -C "$3" rev-parse HEAD 2>/dev/null)" = "$4" ] \
    && [ -z "$(git -C "$3" status --porcelain --untracked-files=all 2>/dev/null)" ]
}

retired=0 kept=0
for meta in "$STATE"/*.meta; do
  [ -e "$meta" ] || continue
  id=$(basename "$meta" .meta)
  case "$id" in
    *[!A-Za-z0-9._-]* | '' | -*) continue ;;
  esac
  [ "$(fm_meta_get "$meta" kind)" = ship ] || continue
  pr=$(fm_meta_get "$meta" pr)
  [ -n "$pr" ] || continue
  if ! fm_pr_url_parse "$pr" || [ "$FM_PR_PROVIDER" != github ]; then
    continue
  fi
  wt=$(fm_meta_get "$meta" worktree)

  st=$(pr_state "$pr")
  case "$st" in
    merged | closed) ;;
    open) continue ;;
    *)
      log keep "$id" "PR state unreadable ($pr)"
      kept=$((kept + 1))
      continue
      ;;
  esac

  if [ -z "$wt" ] || [ ! -d "$wt" ]; then
    log keep "$id" "PR $st but worktree missing; reconcile by hand"
    kept=$((kept + 1))
    continue
  fi
  if [ -n "$(git -C "$wt" status --porcelain --untracked-files=all 2>/dev/null)" ]; then
    log refuse "$id" "PR $st but worktree has uncommitted changes"
    kept=$((kept + 1))
    continue
  fi
  base=$(base_ref "$wt" "$meta")
  if [ -z "$base" ]; then
    log refuse "$id" "PR $st but the lane's base ref cannot be resolved"
    kept=$((kept + 1))
    continue
  fi
  head0=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || head0=
  if ! bundle_lane "$id" "$wt" "$base" "$head0"; then
    log refuse "$id" "PR $st but no verified bundle of its commits"
    kept=$((kept + 1))
    continue
  fi

  if [ "$DRY" = 1 ]; then
    log would-retire "$id" "PR $st $pr"
    continue
  fi
  args=("$id")
  [ "$st" != closed ] || args+=(--force)
  if ! log intent "$id" "PR $st $pr"; then
    echo "fm-lane-retire: cannot write $LOG; refusing to retire $id" >&2
    kept=$((kept + 1))
    continue
  fi
  # Guard: the last reads before the destructive call (PR state first, then the lane), so any change since
  # inspection (record, head, edits, or a reopened PR) aborts. Residual: only teardown could close the final gap.
  [ "${FM_TEST_SEAM:-}" != 1 ] || [ -z "${FM_LANE_RETIRE_PRE_TEARDOWN_HOOK:-}" ] || "$FM_LANE_RETIRE_PRE_TEARDOWN_HOOK" "$id"
  if [ "$(pr_state "$pr")" != "$st" ]; then
    log abort "$id" "PR state changed from $st after inspection; retry next pass"
    kept=$((kept + 1))
    continue
  fi
  if ! lane_unchanged "$meta" "$pr" "$wt" "$head0"; then
    log abort "$id" "lane changed after inspection (record, head, or edits); retry next pass"
    kept=$((kept + 1))
    continue
  fi
  if "$TEARDOWN" "${args[@]}" >/dev/null 2>&1; then
    log retire "$id" "PR $st $pr" || echo "fm-lane-retire: WARNING: $id retired but the retire record could not be written to $LOG" >&2
    retired=$((retired + 1))
  else
    log refuse "$id" "PR $st but teardown refused (rc=$?); record kept"
    kept=$((kept + 1))
  fi
done

[ "$retired" -eq 0 ] && [ "$kept" -eq 0 ] || log summary pass "retired=$retired kept=$kept"
exit 0
