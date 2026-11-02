#!/usr/bin/env bash
# fm-lane-reaper.sh - end the agent of an idle done or paused lane, keep its branch;
# close an idle done lane through a plain teardown once that is opted in.
#
# Usage:
#   fm-lane-reaper.sh scan [--live] [--close-live]
#
# A direct ship or scout lane is a candidate only when ALL of these hold:
#   idle-status   fm-crew-state.sh reads done or paused NOW (a lane with an open
#                 fix round reads working, so it is excluded here) AND the
#                 lane's own last status line carries one [at=<epoch>] tag
#                 before its first colon, at least FM_REAPER_IDLE_SECS
#                 (default 7200) old.
#   quiet         no file under the worktree (outside .git) written within
#                 FM_REAPER_QUIET_SECS (default 1800), and no process whose cwd
#                 is in the worktree using CPU. CPU needs history: a lane is
#                 quiet only once scans have observed it idle for the whole
#                 window (state/.lane-reaper-seen/). A failed probe is unmet.
#   clean         the worktree is on the lane branch, git status --porcelain is
#                 empty, and no merge/rebase/cherry-pick/revert is in progress.
#   pushed        nothing in `git log @{u}..` (an unreadable history is unmet);
#                 a branch with no upstream (a local-only lane) counts as
#                 pushed only when HEAD is already an ancestor of the default
#                 branch.
#
# Default is DRY-RUN: every lane gets one log line, `candidate <id>` or
# `spared <id>: <condition> unmet`, and nothing is ended. `--live` (or
# FM_REAPER_LIVE=1) is the explicit flip. A live candidate is re-evaluated
# immediately before it is ended ONLY through `fm-control.sh <id> exit`, which
# preserves the endpoint, worktree, branch, and every change, and is not ended
# again until its status line changes. Ending never removes a branch or
# worktree; only the close below tears a lane down, and only through teardown.
# Secondmates and remote lanes are skipped; a lane whose worktree is missing is
# reported as spared, never acted on.
#
# Close: a lane whose current and last status are done (not paused), that is
# idle, quiet, and clean as above, is a close candidate even with unpushed
# commits, and every dry-run scan logs `close <id>: would-close (<how kept>)`.
# Live closing is off unless bin/fm-lane-close-lib.sh's opt-in holds for this
# home (config/lane-close-live), `--close-live` is passed, or
# FM_REAPER_CLOSE_LIVE=1. A live close re-evaluates the lane, then keeps every
# commit no remote has: it writes data/bundles/<id>-close.bundle and verifies it
# holds HEAD (no verified bundle, no close), and plainly pushes HEAD to the
# branch's configured upstream unless that upstream is the no-mistakes mirror
# (never forced; a failed push refuses the close, bundle kept). It then runs
# fm-teardown.sh <id> without --force, whose landed-work test decides; a lane
# with no upstream closes only if that test accepts it. A refusal is logged once
# per status line and never forced; an unreadable history refuses the close.
# Each secondmate home's own watcher scans its lanes under its own opt-in.
# Every scan appends its lines to state/lane-reaper.log (dry-run and live, so a
# day of dry-run logs exists before the flip). Scans are throttled to once per
# FM_REAPER_SCAN_SECS (default 900) via state/.lane-reaper-last unless
# FM_REAPER_FORCE=1. The watcher poll runs this scan with the FM_REAPER_* seams
# scrubbed; it passes --live only when config/lane-reaper-live exists, which
# never turns on closing.
# Test seams: FM_REAPER_CPU_CMD <worktree> prints the max CPU percent of
# processes in the worktree; FM_REAPER_CONTROL and FM_REAPER_CREW_STATE
# override the two helpers; FM_REAPER_NOW overrides the epoch; the teardown
# seam is bin/fm-lane-close-lib.sh's.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
export FM_HOME
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONTROL="${FM_REAPER_CONTROL:-$SCRIPT_DIR/fm-control.sh}"
CREW_STATE="${FM_REAPER_CREW_STATE:-$SCRIPT_DIR/fm-crew-state.sh}"
IDLE_SECS=${FM_REAPER_IDLE_SECS:-7200}
QUIET_SECS=${FM_REAPER_QUIET_SECS:-1800}
SCAN_SECS=${FM_REAPER_SCAN_SECS:-900}
LOG="$STATE/lane-reaper.log"
SEEN="$STATE/.lane-reaper-seen"
BUNDLES="$FM_HOME/data/bundles"

# shellcheck source=bin/fm-lane-close-lib.sh
. "$SCRIPT_DIR/fm-lane-close-lib.sh"

USAGE="usage: fm-lane-reaper.sh scan [--live] [--close-live]"
[ "${1:-}" = scan ] || { echo "$USAGE" >&2; exit 2; }
shift
LIVE=${FM_REAPER_LIVE:-0}
CLOSE_LIVE=${FM_REAPER_CLOSE_LIVE:-0}
! fm_lane_close_live "$FM_HOME" || CLOSE_LIVE=1
for a in "$@"; do
  case "$a" in
    --live) LIVE=1 ;;
    --close-live) CLOSE_LIVE=1 ;;
    *) echo "$USAGE" >&2; exit 2 ;;
  esac
done

if [ -n "${FM_REAPER_NOW:-}" ]; then NOW=$FM_REAPER_NOW; else NOW=$(date +%s); fi

mkdir -p "$STATE" "$SEEN" 2>/dev/null
if [ "${FM_REAPER_FORCE:-0}" != 1 ] && [ -f "$STATE/.lane-reaper-last" ]; then
  last=$(cat "$STATE/.lane-reaper-last" 2>/dev/null)
  case "$last" in
    ''|*[!0-9]*) ;;
    *) [ $((NOW - last)) -ge "$SCAN_SECS" ] || exit 0 ;;
  esac
fi
printf '%s\n' "$NOW" > "$STATE/.lane-reaper-last" 2>/dev/null || true

meta_get() { sed -n "s/^$2=//p" "$1" | tail -n1; }

# cpu_busy <worktree>: max cpu percent in the worktree; non-zero when unknown.
cpu_busy() {
  local pids out
  if [ -n "${FM_REAPER_CPU_CMD:-}" ]; then
    out=$("$FM_REAPER_CPU_CMD" "$1") || return 1
  else
    command -v lsof >/dev/null 2>&1 || return 1
    pids=$(lsof -a -d cwd -Fpn 2>/dev/null | awk -v wt="$1" '
      /^p/ {pid=substr($0,2)}
      /^n/ {n=substr($0,2); if (n==wt || index(n, wt "/")==1) print pid}' | paste -sd, -)
    if [ -z "$pids" ]; then
      out=0
    else
      out=$(ps -o pcpu= -p "$pids" 2>/dev/null | sort -rn | head -n1 | tr -d ' ') || return 1
    fi
  fi
  case "$out" in ''|*[!0-9.]*) return 1 ;; esac
  printf '%s\n' "$out"
}

# quiet_history <id> busy|idle: busy stamps the last-busy time and is never
# quiet; idle is quiet only once first observed idle, and last busy, are both
# a full QUIET_SECS ago.
quiet_history() {
  local seen_idle last_busy
  if [ "$2" = busy ]; then
    printf '%s\n' "$NOW" > "$SEEN/$1.busy" 2>/dev/null
    return 1
  fi
  [ -f "$SEEN/$1.idle" ] || printf '%s\n' "$NOW" > "$SEEN/$1.idle" 2>/dev/null || return 1
  seen_idle=$(cat "$SEEN/$1.idle" 2>/dev/null)
  last_busy=$(cat "$SEEN/$1.busy" 2>/dev/null)
  last_busy=${last_busy:-0}
  case "$seen_idle$last_busy" in ''|*[!0-9]*) return 1 ;; esac
  [ $((NOW - seen_idle)) -ge "$QUIET_SECS" ] && [ $((NOW - last_busy)) -ge "$QUIET_SECS" ]
}

# recent_write <worktree>: prints a file written within QUIET_SECS; non-zero when unreadable.
recent_write() {
  local stamp ref out rc
  stamp=$(date -r "$((NOW - QUIET_SECS))" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$((NOW - QUIET_SECS))" +%Y%m%d%H%M.%S) || return 1
  ref=$(mktemp "${TMPDIR:-/tmp}/fm-reaper-ref.XXXXXX") || return 1
  if touch -t "$stamp" "$ref"; then
    out=$(find -L "$1" -path "$1/.git" -prune -o -type f -newer "$ref" -print -quit 2>/dev/null); rc=$?
  else
    rc=1
  fi
  rm -f "$ref"
  printf '%s' "$out"
  return "$rc"
}

# evaluate <id> <meta>: prints `candidate`, `skip:<why>`, or `<condition>:<detail>`
evaluate() {
  local id=$1 meta=$2 recent wt kind last at cs cpu porcelain base want branch unpushed op
  kind=$(meta_get "$meta" kind)
  case "$kind" in ship|scout) ;; *) echo "skip:kind"; return ;; esac
  [ -z "$(meta_get "$meta" remote_host)" ] || { echo "skip:remote"; return; }
  wt=$(meta_get "$meta" worktree)
  [ -n "$wt" ] && [ -d "$wt" ] || { echo "worktree:missing"; return; }

  cs=$("$CREW_STATE" "$id" 2>/dev/null | head -n1)
  case "$cs" in
    "state: done"*|"state: paused"*) ;;
    *) echo "idle-status:current-state-not-done-or-paused"; return ;;
  esac
  last=$(tail -n1 "$STATE/$id.status" 2>/dev/null)
  case "$last" in done*|paused*) ;; *) echo "idle-status:last-status-not-done-or-paused"; return ;; esac
  at=$(printf '%s' "$last" | sed -n 's/^[^:]*\[at=\([0-9]\{1,12\}\)\][^:]*:.*/\1/p')
  [ -n "$at" ] || { echo "idle-status:no-status-timestamp"; return; }
  [ $((NOW - at)) -ge "$IDLE_SECS" ] || { echo "idle-status:only-$((NOW - at))s-old"; return; }

  recent=$(recent_write "$wt") || { echo "quiet:unreadable-worktree"; return; }
  [ -z "$recent" ] || { echo "quiet:recent-file-write"; return; }
  if cpu=$(cpu_busy "$wt"); then
    if awk -v c="$cpu" 'BEGIN{exit !(c+0 > 0.5)}'; then
      quiet_history "$id" busy
      echo "quiet:process-cpu"; return
    fi
    quiet_history "$id" idle || { echo "quiet:cpu-window-not-yet-observed"; return; }
  else
    echo "quiet:cpu-probe-failed"; return
  fi

  want=$(meta_get "$meta" branch)
  branch=$(git -C "$wt" symbolic-ref -q --short HEAD 2>/dev/null)
  [ -z "$want" ] || [ "$branch" = "$want" ] || { echo "clean:head-not-lane-branch"; return; }
  if ! porcelain=$(git -C "$wt" status --porcelain 2>/dev/null) || [ -n "$porcelain" ]; then
    echo "clean:uncommitted-or-unreadable"; return
  fi
  for op in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply; do
    [ ! -e "$(git -C "$wt" rev-parse --git-path "$op" 2>/dev/null)" ] \
      || { echo "clean:operation-in-progress"; return; }
  done

  if git -C "$wt" rev-parse --verify -q '@{u}' >/dev/null 2>&1; then
    unpushed=$(git -C "$wt" log '@{u}..' --oneline 2>/dev/null) || { echo "pushed:history-unreadable"; return; }
    [ -z "$unpushed" ] || { echo "pushed:unpushed-commits"; return; }
  else
    base=$(git -C "$wt" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)
    if [ -z "$base" ]; then
      if git -C "$wt" rev-parse --verify -q main >/dev/null 2>&1; then base=main; else base=master; fi
    fi
    git -C "$wt" merge-base --is-ancestor HEAD "$base" 2>/dev/null \
      || { echo "pushed:no-upstream-and-not-in-$base"; return; }
  fi
  echo candidate
}

# close_kind <id> <verdict>: prints how a close candidate keeps its commits
# (pushed, push, or bundle); non-zero when the lane is not a close candidate.
close_kind() {
  local cs
  case "$2" in
    candidate | pushed:unpushed-commits | pushed:no-upstream-*) ;;
    *) return 1 ;;
  esac
  cs=$("$CREW_STATE" "$1" 2>/dev/null | head -n1)
  case "$cs" in "state: done"*) ;; *) return 1 ;; esac
  case "$(tail -n1 "$STATE/$1.status" 2>/dev/null)" in done*) ;; *) return 1 ;; esac
  case "$2" in
    candidate) echo pushed ;;
    pushed:unpushed-commits) echo push ;;
    *) echo bundle ;;
  esac
}

# keep_commits <id> <worktree>: 0 when every commit of HEAD is on a remote, or a
# verified bundle at data/bundles/<id>-close.bundle now holds HEAD.
keep_commits() {
  local id=$1 wt=$2 head n file
  head=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || return 1
  n=$(git -C "$wt" rev-list --count HEAD --not --remotes 2>/dev/null) || return 1
  [ "$n" -gt 0 ] || return 0
  file="$BUNDLES/$id-close.bundle"
  mkdir -p "$BUNDLES" 2>/dev/null || return 1
  if git -C "$wt" bundle create -q "$file.tmp" HEAD --not --remotes >/dev/null 2>&1 \
    && git -C "$wt" bundle verify -q "$file.tmp" >/dev/null 2>&1 \
    && mv -f "$file.tmp" "$file" 2>/dev/null \
    && git -C "$wt" bundle list-heads "$file" 2>/dev/null | grep -q "^$head HEAD"; then
    return 0
  fi
  rm -f "$file.tmp"
  return 1
}

# push_upstream <worktree>: plain push of HEAD to the branch's upstream; 0 when
# pushed or when the upstream is the no-mistakes mirror (kept by the bundle only).
push_upstream() {
  local wt=$1 branch remote merge
  branch=$(git -C "$wt" symbolic-ref -q --short HEAD 2>/dev/null) || return 1
  remote=$(git -C "$wt" config "branch.$branch.remote" 2>/dev/null) || return 1
  merge=$(git -C "$wt" config "branch.$branch.merge" 2>/dev/null) || return 1
  [ "$remote" != no-mistakes ] || return 0
  git -C "$wt" push -q "$remote" "HEAD:$merge" >/dev/null 2>&1
}

# close_lane <id> <meta>: re-evaluates, keeps the commits, tears down; prints the result.
close_lane() {
  local id=$1 meta=$2 how wt rc=0
  how=$(close_kind "$id" "$(evaluate "$id" "$meta")") || { echo spared-on-recheck; return; }
  wt=$(meta_get "$meta" worktree)
  keep_commits "$id" "$wt" || { echo "refused: no verified bundle of its commits"; return; }
  if [ "$how" = push ] && ! push_upstream "$wt"; then
    echo "refused: push to upstream failed; bundle kept"; return
  fi
  "$(fm_lane_close_teardown)" "$id" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0 | 4) echo closed ;;
    *) echo "refused: teardown refused (rc=$rc)" ;;
  esac
}

mode=dry-run
[ "$LIVE" = 1 ] && mode=live
close_mode=dry-run
[ "$CLOSE_LIVE" = 1 ] && close_mode=live
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  id=$(basename "$meta" .meta)
  verdict=$(evaluate "$id" "$meta")
  if how=$(close_kind "$id" "$verdict"); then
    lastline=$(tail -n1 "$STATE/$id.status" 2>/dev/null)
    if [ "$CLOSE_LIVE" != 1 ]; then
      printf '[at=%s] %s\n' "$NOW" "dry-run close $id: would-close ($how)" | tee -a "$LOG"
    elif [ "$(cat "$SEEN/$id.close" 2>/dev/null)" != "$lastline" ]; then
      res=$(close_lane "$id" "$meta")
      printf '[at=%s] %s\n' "$NOW" "$close_mode close $id: $res" | tee -a "$LOG"
      [ "$res" != closed ] || continue
      printf '%s\n' "$lastline" > "$SEEN/$id.close"
    fi
  fi
  case "$verdict" in
    skip:*) continue ;;
    candidate)
      if [ "$LIVE" = 1 ]; then
        mark="$SEEN/$id.ended"
        lastline=$(tail -n1 "$STATE/$id.status" 2>/dev/null)
        if [ "$(cat "$mark" 2>/dev/null)" = "$lastline" ]; then
          continue
        elif [ "$(evaluate "$id" "$meta")" != candidate ]; then
          res=spared-on-recheck
        elif "$CONTROL" "$id" exit >/dev/null 2>&1; then
          res=ended
          printf '%s\n' "$lastline" > "$mark"
        else
          res=exit-failed
        fi
      else
        res=would-end
      fi
      line="$mode candidate $id: $res" ;;
    *) line="$mode spared $id: ${verdict%%:*} unmet (${verdict#*:})" ;;
  esac
  printf '[at=%s] %s\n' "$NOW" "$line" | tee -a "$LOG"
done
exit 0
