#!/usr/bin/env bash
# fm-lane-reaper.sh - end the agent of an idle done or paused lane, keep its branch.
#
# Usage:
#   fm-lane-reaper.sh scan [--live]
#
# A direct ship or scout lane is a candidate only when ALL of these hold:
#   idle-status   fm-crew-state.sh reads done or paused NOW (a lane with an open
#                 fix round reads working, so it is excluded here) AND the
#                 lane's own last status line carries [at=<epoch>] at least
#                 FM_REAPER_IDLE_SECS (default 7200) old.
#   quiet         no file under the worktree (outside .git) written, and no
#                 process whose cwd is in the worktree using CPU, within
#                 FM_REAPER_QUIET_SECS (default 1800).
#   clean         git status --porcelain is empty.
#   pushed        nothing in `git log @{u}..`; a branch with no upstream (a
#                 local-only lane) counts as pushed only when HEAD is already
#                 an ancestor of the default branch.
#
# Default is DRY-RUN: every lane gets one log line, `candidate <id>` or
# `spared <id>: <condition> unmet`, and nothing is ended. `--live` (or
# FM_REAPER_LIVE=1) is the explicit flip; each candidate is then ended ONLY
# through `fm-control.sh <id> exit`, which preserves the endpoint, worktree,
# branch, and every change. This script never removes a branch or worktree and
# never tears a lane down. Secondmates and remote lanes are skipped.
# Every scan appends its lines to state/lane-reaper.log (dry-run and live, so a
# day of dry-run logs exists before the flip). Scans are throttled to once per
# FM_REAPER_SCAN_SECS (default 900) via state/.lane-reaper-last unless
# FM_REAPER_FORCE=1. The watcher poll runs this scan; it passes --live only
# when config/lane-reaper-live exists.
# Test seams: FM_REAPER_CPU_CMD <worktree> prints the max CPU percent of
# processes in the worktree; FM_REAPER_CONTROL and FM_REAPER_CREW_STATE
# override the two helpers; FM_REAPER_NOW overrides the epoch.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONTROL="${FM_REAPER_CONTROL:-$SCRIPT_DIR/fm-control.sh}"
CREW_STATE="${FM_REAPER_CREW_STATE:-$SCRIPT_DIR/fm-crew-state.sh}"
IDLE_SECS=${FM_REAPER_IDLE_SECS:-7200}
QUIET_SECS=${FM_REAPER_QUIET_SECS:-1800}
SCAN_SECS=${FM_REAPER_SCAN_SECS:-900}
LOG="$STATE/lane-reaper.log"

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

mkdir -p "$STATE" 2>/dev/null
if [ "${FM_REAPER_FORCE:-0}" != 1 ] && [ -f "$STATE/.lane-reaper-last" ]; then
  last=$(cat "$STATE/.lane-reaper-last" 2>/dev/null)
  case "$last" in
    ''|*[!0-9]*) ;;
    *) [ $((NOW - last)) -ge "$SCAN_SECS" ] || exit 0 ;;
  esac
fi
printf '%s\n' "$NOW" > "$STATE/.lane-reaper-last" 2>/dev/null || true

meta_get() { sed -n "s/^$2=//p" "$1" | head -n1; }

cpu_busy() {  # <worktree>: max cpu percent of processes with cwd in worktree
  if [ -n "${FM_REAPER_CPU_CMD:-}" ]; then
    "$FM_REAPER_CPU_CMD" "$1"
    return
  fi
  local pids
  pids=$(lsof -a -d cwd -Fpn 2>/dev/null | awk -v wt="$1" '
    /^p/ {pid=substr($0,2)}
    /^n/ {n=substr($0,2); if (n==wt || index(n, wt "/")==1) print pid}' | paste -sd, -)
  [ -n "$pids" ] || { echo 0; return; }
  ps -o pcpu= -p "$pids" 2>/dev/null | sort -rn | head -n1 | tr -d ' '
}

# evaluate <id> <meta>: prints `candidate`, `skip:<why>`, or `<condition>:<detail>`
evaluate() {
  local id=$1 meta=$2 recent stamp ref wt kind last at cs cpu porcelain base
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
  at=$(printf '%s' "$last" | sed -n 's/.*\[at=\([0-9][0-9]*\)\].*/\1/p' | head -n1)
  [ -n "$at" ] || { echo "idle-status:no-status-timestamp"; return; }
  [ $((NOW - at)) -ge "$IDLE_SECS" ] || { echo "idle-status:only-$((NOW - at))s-old"; return; }

  stamp=$(date -r "$((NOW - QUIET_SECS))" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$((NOW - QUIET_SECS))" +%Y%m%d%H%M.%S) \
    && ref=$(mktemp "${TMPDIR:-/tmp}/fm-reaper-ref.XXXXXX") && touch -t "$stamp" "$ref" \
    && recent=$(find "$wt" -path "$wt/.git" -prune -o -type f -newer "$ref" -print -quit 2>/dev/null) \
    || { rm -f "${ref:-}"; echo "quiet:unreadable-worktree"; return; }
  rm -f "$ref"
  [ -z "$recent" ] || { echo "quiet:recent-file-write"; return; }
  cpu=$(cpu_busy "$wt")
  if awk -v c="${cpu:-0}" 'BEGIN{exit !(c+0 > 0.5)}'; then
    echo "quiet:process-cpu"; return
  fi

  if ! porcelain=$(git -C "$wt" status --porcelain 2>/dev/null) || [ -n "$porcelain" ]; then
    echo "clean:uncommitted-or-unreadable"; return
  fi

  if git -C "$wt" rev-parse --verify -q '@{u}' >/dev/null 2>&1; then
    [ -z "$(git -C "$wt" log '@{u}..' --oneline 2>/dev/null)" ] || { echo "pushed:unpushed-commits"; return; }
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
        if "$CONTROL" "$id" exit >/dev/null 2>&1; then res=ended; else res=exit-failed; fi
      else
        res=would-end
      fi
      line="$mode candidate $id: $res" ;;
    *) line="$mode spared $id: ${verdict%%:*} unmet (${verdict#*:})" ;;
  esac
  printf '[at=%s] %s\n' "$NOW" "$line" | tee -a "$LOG"
done
exit 0
