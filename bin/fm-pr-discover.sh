#!/usr/bin/env bash
# fm-pr-discover.sh - bounded discovery of a task's PR that was never recorded.
#
# Usage:
#   fm-pr-discover.sh scan
#
# A worker can open a PR and never report it, so its task record gets no pr=
# line and no merge poll is armed. This scan finds ship tasks in this home whose
# record has a branch= but no pr=, asks the forge once per candidate whether that
# branch has an open or merged pull request, and records it through
# bin/fm-pr-check.sh, the single owner of pr= and the static merge poll. Every
# fm-pr-check.sh refusal (draft, head not reachable, bad URL) leaves the record
# untouched. Nothing here arms a poll, writes meta, or merges by itself.
#
# It is an adjunct to the existing watcher poll loop (bin/fm-watch.sh calls it
# next to bin/fm-inactive-reconcile.sh), not a watcher of its own. It is cheap by
# construction:
#   - a scan runs at most once per FM_PR_DISCOVER_SECS (default 600, valid
#     60..3600), gated by the mtime of state/.pr-discover;
#   - a scan visits at most FM_PR_DISCOVER_MAX candidates (default 4, valid
#     1..20) and resumes after the last one it visited (the cursor lives in
#     that same marker) so a long candidate list is covered over several scans;
#   - each candidate costs one `gh pr list` bounded by FM_PR_DISCOVER_QUERY_SECS
#     (default 20, valid 1..60) plus, only when a PR is found, one registration
#     through fm-pr-check.sh (which makes its own gh reads) bounded by
#     FM_PR_DISCOVER_CHECK_SECS (default 30, valid 1..120), and the whole scan
#     stops starting new work once FM_PR_DISCOVER_BUDGET_SECS (default 45,
#     valid 5..180) have elapsed, so a stalled forge call can never hold the
#     watcher: every call is cut off at the lesser of its own bound and what
#     is left of the budget;
#   - only GitHub is queried: `gh pr list --head <branch> --state all` run from
#     the project clone. A task with no branch=, a scout, a secondmate, a
#     local-only task, a task whose project is gone, or a record that already
#     has pr= is skipped without a query. A closed-unmerged PR and a PR from a
#     fork are ignored, as is a merged PR created before the task's spawn
#     (its spawn_first= epoch, kept across relaunch; a record without it
#     falls back to the epoch in spawn_gen=), which belongs to an earlier task that
#     reused the id; an open PR is preferred over a merged one.
# Output: one `recorded <task-id> <pr-url>` line per recorded PR, nothing else
# when quiet. Exit status is 0 on every ordinary path, including a missing gh.
set -u
export LC_ALL=C

SCRIPT_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
MARKER="$STATE/.pr-discover"
PR_CHECK="$SCRIPT_DIR/fm-pr-check.sh"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

[ "${1:-}" = scan ] && [ "$#" -eq 1 ] || {
  echo "usage: fm-pr-discover.sh scan" >&2
  exit 2
}

bounded_int() { # <name> <value> <min> <max>
  case "$2" in ''|*[!0-9]*) echo "fm-pr-discover: $1 must be a whole number from $3 to $4" >&2; exit 2 ;; esac
  if [ "$2" -lt "$3" ] || [ "$2" -gt "$4" ]; then
    echo "fm-pr-discover: $1 must be a whole number from $3 to $4" >&2
    exit 2
  fi
}
SECS=${FM_PR_DISCOVER_SECS:-600}
MAX=${FM_PR_DISCOVER_MAX:-4}
QUERY_SECS=${FM_PR_DISCOVER_QUERY_SECS:-20}
bounded_int FM_PR_DISCOVER_SECS "$SECS" 60 3600
bounded_int FM_PR_DISCOVER_MAX "$MAX" 1 20
CHECK_SECS=${FM_PR_DISCOVER_CHECK_SECS:-30}
BUDGET_SECS=${FM_PR_DISCOVER_BUDGET_SECS:-45}
bounded_int FM_PR_DISCOVER_QUERY_SECS "$QUERY_SECS" 1 60
bounded_int FM_PR_DISCOVER_CHECK_SECS "$CHECK_SECS" 1 120
bounded_int FM_PR_DISCOVER_BUDGET_SECS "$BUDGET_SECS" 5 180

if [ "$(uname)" = Darwin ]; then
  file_mtime() { /usr/bin/stat -f %m "$1" 2>/dev/null; }
else
  file_mtime() { stat -c %Y "$1" 2>/dev/null; }
fi

command -v gh >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || exit 0
[ -d "$STATE" ] || exit 0

now=$(date +%s)
if [ -f "$MARKER" ] && [ ! -L "$MARKER" ]; then
  last=$(file_mtime "$MARKER") || last=0
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  [ $((now - last)) -ge "$SECS" ] || exit 0
fi

meta_get() { grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true; }

cursor=
[ ! -f "$MARKER" ] || cursor=$(grep '^cursor=' "$MARKER" 2>/dev/null | tail -1 | cut -d= -f2- || true)

# Candidates in id order, starting after the cursor and wrapping around once.
candidates=()
wrapped=()
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] && [ ! -L "$meta" ] || continue
  id=$(basename "$meta" .meta)
  fm_pr_task_id_valid "$id" || continue
  case "$(meta_get "$meta" kind)" in ''|ship) ;; *) continue ;; esac
  [ "$(meta_get "$meta" mode)" != local-only ] || continue
  [ -n "$(meta_get "$meta" branch)" ] || continue
  [ -z "$(meta_get "$meta" pr)" ] || continue
  if [ -n "$cursor" ] && ! [[ "$id" > "$cursor" ]]; then
    wrapped+=("$id")
  else
    candidates+=("$id")
  fi
done
candidates+=("${wrapped[@]+"${wrapped[@]}"}")

# bound_for <own-bound>: the lesser of the bound and the budget left, or empty
# (and failure) when the budget is spent.
deadline=$(( $(date +%s) + BUDGET_SECS ))
bound_for() {
  local left=$(( deadline - $(date +%s) ))
  [ "$left" -ge 1 ] || return 1
  [ "$1" -le "$left" ] && printf '%s\n' "$1" || printf '%s\n' "$left"
}

# A registration cut off after fm-pr-check.sh published pr= but before it armed
# the merge poll would leave pr= and no poll for good, because a task that has
# pr= is never a candidate. With the registration process gone, take pr= back
# off the record (only when it is still the PR just registered and no poll is
# armed) so the next scan registers it again. A lock that cannot be taken in a
# moment leaves the record alone.
rollback_unarmed_pr() { # <task-id> <pr-url>
  local meta="$STATE/$1.meta" lock tmp line
  [ ! -e "$STATE/$1.check.sh" ] || return 0
  [ "$(meta_get "$meta" pr)" = "$2" ] || return 0
  lock=$(fm_meta_lock_path "$meta") || return 0
  fm_lock_acquire_wait_max "$lock" 2 || return 0
  tmp=$(mktemp "$STATE/.pr-discover-meta.XXXXXX") || { fm_lock_release "$lock" || true; return 0; }
  if [ ! -e "$STATE/$1.check.sh" ] && [ -f "$meta" ] && [ ! -L "$meta" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in pr=*|pr_head=*) ;; *) printf '%s\n' "$line" >> "$tmp" ;; esac
    done < "$meta"
    if chmod 0600 "$tmp"; then
      mv -f -- "$tmp" "$meta" || rm -f -- "$tmp"
    else
      rm -f -- "$tmp"
    fi
  else
    rm -f -- "$tmp"
  fi
  fm_lock_release "$lock" || true
}

queried=0
stopped=0
prev_visited=$cursor
last_visited=$cursor
for id in "${candidates[@]+"${candidates[@]}"}"; do
  if [ "$queried" -ge "$MAX" ] || ! bound_for "$QUERY_SECS" >/dev/null; then
    stopped=1
    break
  fi
  meta="$STATE/$id.meta"
  branch=$(meta_get "$meta" branch)
  project=$(meta_get "$meta" project)
  base=$(meta_get "$meta" base_branch)
  since=$(meta_get "$meta" spawn_first)
  if [ -z "$since" ]; then
    since=$(meta_get "$meta" spawn_gen)
    since=${since#s}
    since=${since%%.*}
  fi
  case "$since" in ''|*[!0-9]*) since=0 ;; esac
  [ -d "$project" ] || { last_visited=$id; continue; }
  queried=$((queried + 1))
  prev_visited=$last_visited
  last_visited=$id
  out=$(cd "$project" && fm_run_timed "$(bound_for "$QUERY_SECS")" gh pr list --head "$branch" --state all --limit 5 \
    --json url,state,headRefName,baseRefName,isCrossRepository,createdAt 2>/dev/null) || continue
  url=$(printf '%s\n' "$out" | jq -r --arg b "$branch" --arg base "$base" --argjson since "$since" '
    [ .[] | select(.headRefName == $b and (.isCrossRepository | not)
        and (.state == "OPEN"
          or (.state == "MERGED" and (((.createdAt // "") | fromdateiso8601?) // 0) >= $since))
        and ($base == "" or .baseRefName == $base)) ]
    | (map(select(.state == "OPEN")) + map(select(.state == "MERGED")))
    | (.[0].url // empty)' 2>/dev/null) || continue
  [ -n "$url" ] && fm_pr_url_parse "$url" && [ "$FM_PR_PROVIDER" = github ] || continue
  # Re-read the record: the worker or firstmate may have recorded it meanwhile.
  [ -z "$(meta_get "$meta" pr)" ] || continue
  if ! check_bound=$(bound_for "$CHECK_SECS"); then
    # Found but out of budget: leave it as the next scan's first candidate.
    last_visited=$prev_visited
    stopped=1
    break
  fi
  if fm_run_timed "$check_bound" "$PR_CHECK" "$id" "$FM_PR_URL" >/dev/null 2>&1; then
    printf 'recorded %s %s\n' "$id" "$FM_PR_URL"
  else
    rollback_unarmed_pr "$id" "$FM_PR_URL"
  fi
done

# Only a scan that walked the whole list restarts from the top next time; one
# stopped by its count or time budget resumes after the last candidate visited.
if [ "$stopped" = 0 ]; then
  last_visited=
fi
marker_tmp=$(mktemp "$STATE/.pr-discover.XXXXXX") || exit 0
if printf 'cursor=%s\n' "$last_visited" > "$marker_tmp"; then
  mv -f -- "$marker_tmp" "$MARKER" || rm -f -- "$marker_tmp"
else
  rm -f -- "$marker_tmp"
fi
exit 0
