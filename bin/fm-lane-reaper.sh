#!/usr/bin/env bash
# fm-lane-reaper.sh - end the agent of an idle done or paused lane, keep its branch.
#
# Usage:
#   fm-lane-reaper.sh scan [--live]
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
# again until its status line changes. This script never removes a branch or
# worktree and never tears a lane down. Secondmates and remote lanes are skipped.
# Every scan appends its lines to state/lane-reaper.log (dry-run and live, so a
# day of dry-run logs exists before the flip). Scans are throttled to once per
# FM_REAPER_SCAN_SECS (default 900) via state/.lane-reaper-last unless
# FM_REAPER_FORCE=1. The watcher poll runs this scan with the FM_REAPER_* seams
# scrubbed; it passes --live only when config/lane-reaper-live exists.
# Test seams: FM_REAPER_CPU_CMD <worktree> prints the max CPU percent of
# processes in the worktree; FM_REAPER_CONTROL and FM_REAPER_CREW_STATE
# override the two helpers; FM_REAPER_NOW overrides the epoch.
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

USAGE="usage: fm-lane-reaper.sh scan [--live]"
[ "${1:-}" = scan ] || { echo "$USAGE" >&2; exit 2; }
shift
LIVE=${FM_REAPER_LIVE:-0}
for a in "$@"; do
  case "$a" in
    --live) LIVE=1 ;;
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
  [ -n "$wt" ] && [ -d "$wt" ] || { echo "skip:no-worktree"; return; }

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

mode=dry-run
[ "$LIVE" = 1 ] && mode=live
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  id=$(basename "$meta" .meta)
  verdict=$(evaluate "$id" "$meta")
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
