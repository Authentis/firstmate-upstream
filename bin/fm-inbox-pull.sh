#!/usr/bin/env bash
# fm-inbox-pull.sh - the ONE owner of the mid-turn inbox pull: which steering
# records a pi coordinator has not yet been told about, the cursor that keeps a
# notice to once per record, the throttle, the kill switch, the replay trip, and
# the liveness heartbeat. The pi extension .pi/extensions/fm-inbox-pull.ts is a
# thin trigger that runs this script; it restates none of these semantics.
#
# Why a pull exists: the doorbell (bin/fm-task-inbox-lib.sh) types one constant
# line into an idle composer and is skipped while the agent is busy, so a
# coordinator inside a long turn never hears a steer. The extension calls
# `peek` after every tool result and delivers the notice into the running turn.
#
# Usage: fm-inbox-pull.sh peek | commit | beat [--error <text>] | status
#   peek    Print one notice block for the records not yet noticed, or nothing.
#           The notice is the doorbell sentence followed by one
#           `inbox-pull-notice:<absolute record path>` line per record (at most
#           20; a `+N more` line when capped). Writes a pending marker and moves
#           no cursor; an uncommitted pending set is an open transaction that
#           every later peek replays unchanged until a commit consumes it.
#           Throttled: a call less than FM_INBOX_PULL_MIN_INTERVAL
#           seconds (default 30) after the previous scan prints nothing and
#           scans nothing, but still refreshes the heartbeat.
#   commit  Promote the pending marker to the cursor. The host calls it only
#           once the notice is inside a model request; without that call the
#           same records are noticed again by the next unthrottled peek.
#   beat    Refresh the heartbeat only (the extension's idle tick). With
#           --error, record the one-line error text in the heartbeat and log.
#   status  Print the heartbeat, cursor and scan state as key=value lines.
# peek, commit and beat always exit 0 and print nothing else on stdout or
# stderr: errors go to the log and the heartbeat's last_error, never the TUI.
# Usage errors exit 2.
#
# Scan set: every FM_INBOX_PULL_DIR entry (colon separated; fm-spawn.sh sets
# the mate's own steering inbox), every state/parent-route/*.inbox, and every
# line of config/inbox-pull-dirs (blank lines and # comments ignored; a relative
# entry is relative to FM_HOME). Symlinked and missing directories are skipped.
#
# State under <state>/inbox-pull/ (state is FM_STATE_OVERRIDE, else
# $FM_HOME/state):
#   cursor       schema=fm-inbox-pull-cursor.v1, then `floor<TAB>dir<TAB>seq`
#                (everything at or below is seen) and `seen<TAB>dir<TAB>seq`
#                lines. A missing record is pruned from `seen` at commit. A
#                cursor with any other first line is migrated, never replayed:
#                every record at or below the newest handled/ sequence of its
#                inbox becomes the floor.
#   pending      records the last peek named, awaiting commit
#   notices      one epoch per committed notice; more than
#                FM_INBOX_PULL_TRIP_MAX (default 20) in the last hour trips the
#                kill file instead of notifying (the replay safety net)
#   heartbeat    ts, seq, pid, host, last_check_ts, last_notified_seq,
#                last_notified_inbox, last_error, killed (atomic replace)
#   log          capped diagnostic log
# Kill switch: FM_INBOX_PULL=0 in the environment, or the file
# <state>/.inbox-pull-off (written by the trip, removed by the operator).
#
# Test seams: FM_INBOX_PULL_NOW (epoch), FM_INBOX_PULL_PID (heartbeat pid,
# default the caller's parent), FM_INBOX_PULL_LIMIT (notice cap, default 20).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PULL="$STATE/inbox-pull"
KILL_FILE="$STATE/.inbox-pull-off"
SCHEMA='schema=fm-inbox-pull-cursor.v1'
TAB=$(printf '\t')

CMD=${1-}
case "$CMD" in
  peek | commit | beat | status) ;;
  -h | --help) sed -n '2,/^set -u/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//' ; exit 0 ;;
  *) echo "usage: fm-inbox-pull.sh peek | commit | beat [--error <text>] | status" >&2; exit 2 ;;
esac
shift
BEAT_ERROR=''
if [ "$CMD" = beat ] && [ "${1-}" = --error ]; then
  BEAT_ERROR=${2-}
elif [ "$#" -gt 0 ]; then
  echo "usage: fm-inbox-pull.sh peek | commit | beat [--error <text>] | status" >&2
  exit 2
fi
[ "$CMD" = status ] || exec 2>/dev/null

# shellcheck source=bin/fm-task-inbox-lib.sh
. "$SCRIPT_DIR/fm-task-inbox-lib.sh" 2>/dev/null || {
  mkdir -p "$PULL" 2>/dev/null && printf '%s inbox-pull: cannot load fm-task-inbox-lib.sh\n' "$(date +%s)" >> "$PULL/log"
  [ "$CMD" = status ] && exit 1
  exit 0
}

MIN_INTERVAL=${FM_INBOX_PULL_MIN_INTERVAL:-30}
TRIP_MAX=${FM_INBOX_PULL_TRIP_MAX:-20}
LIMIT=${FM_INBOX_PULL_LIMIT:-20}
case "$MIN_INTERVAL" in '' | *[!0-9]*) MIN_INTERVAL=30 ;; esac
case "$TRIP_MAX" in '' | *[!0-9]*) TRIP_MAX=20 ;; esac
case "$LIMIT" in '' | *[!0-9]*) LIMIT=20 ;; esac
[ "$LIMIT" -ge 1 ] || LIMIT=20

now() { printf '%s' "${FM_INBOX_PULL_NOW:-$(date +%s)}"; }
NOW=$(now)

log_line() {  # <text>
  local f="$PULL/log" tmp
  mkdir -p "$PULL" 2>/dev/null || return 0
  printf '%s %s\n' "$NOW" "$1" >> "$f" 2>/dev/null || return 0
  if [ "$(wc -c < "$f" 2>/dev/null || echo 0)" -gt 65536 ]; then
    tmp="$f.$$"
    tail -n 200 "$f" > "$tmp" 2>/dev/null && mv "$tmp" "$f" 2>/dev/null
    rm -f "$tmp" 2>/dev/null
  fi
  return 0
}

write_atomic() {  # <path> ; content on stdin
  local tmp="$1.$$"
  if cat > "$tmp" 2>/dev/null && mv "$tmp" "$1" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  return 1
}

# --- single-flight lock ------------------------------------------------------
LOCK="$PULL/.lock"
LOCKED=0
# Reclaim a dead owner's lock. Only a holder of the reclaim guard may remove a
# lock, and only after re-reading that it still carries the owner judged dead, so
# a lock freshly taken by a live invocation is never destroyed. A lock that only
# its owner or a guard holder removes cannot be replaced between that check and
# the removal. A guard abandoned by a killed reclaimer goes stale after a minute.
lock_reclaim() {  # <pid judged dead, or empty>
  local guard="$LOCK.reclaim"
  if [ -d "$guard" ] && [ -z "$(find "$guard" -maxdepth 0 -mmin -1 2>/dev/null)" ]; then
    rmdir "$guard" 2>/dev/null
  fi
  mkdir "$guard" 2>/dev/null || return 0
  if [ "$(cat "$LOCK/pid" 2>/dev/null)" = "$1" ]; then
    rm -r "$LOCK" 2>/dev/null
  fi
  rmdir "$guard" 2>/dev/null
  return 0
}
lock_acquire() {
  local pid
  for _ in 1 2; do
    if mkdir "$LOCK" 2>/dev/null; then
      printf '%s' "$$" > "$LOCK/pid" 2>/dev/null
      LOCKED=1
      return 0
    fi
    pid=$(cat "$LOCK/pid" 2>/dev/null)
    if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
      lock_reclaim "$pid"
      continue
    fi
    # an invocation lasts seconds: a lock older than five minutes belongs to a dead
    # owner whose pid was reused, however alive that pid looks
    if [ -n "$pid" ] && [ -z "$(find "$LOCK" -maxdepth 0 -mmin -5 2>/dev/null)" ]; then
      lock_reclaim "$pid"
      continue
    fi
    # a lock younger than the stale bound with a live or unknown owner: another
    # invocation is in flight, and the host must never wait on it.
    if [ -z "$pid" ] && [ -d "$LOCK" ] && [ -z "$(find "$LOCK" -maxdepth 0 -mmin -1 2>/dev/null)" ]; then
      lock_reclaim ""
      continue
    fi
    return 1
  done
  return 1
}
# shellcheck disable=SC2329 # invoked by the EXIT trap
lock_release() {
  [ "$LOCKED" -eq 1 ] || return 0
  # only a lock still carrying this invocation's token is ours to remove
  [ "$(cat "$LOCK/pid" 2>/dev/null)" != "$$" ] || rm -r "$LOCK" 2>/dev/null
  LOCKED=0
}
trap lock_release EXIT

# --- heartbeat ---------------------------------------------------------------
HB_SEQ=0 HB_LAST_CHECK=0 HB_LAST_SEQ='' HB_LAST_INBOX='' HB_ERROR='' HB_KILLED=0
hb_load() {
  local k v
  [ -f "$PULL/heartbeat" ] || return 0
  while IFS='=' read -r k v; do
    case "$k" in
      seq) HB_SEQ=${v//[!0-9]/} ;;
      last_check_ts) HB_LAST_CHECK=${v//[!0-9]/} ;;
      last_notified_seq) HB_LAST_SEQ=$v ;;
      last_notified_inbox) HB_LAST_INBOX=$v ;;
      last_error) HB_ERROR=$v ;;
    esac
  done < "$PULL/heartbeat"
  [ -n "$HB_SEQ" ] || HB_SEQ=0
  [ -n "$HB_LAST_CHECK" ] || HB_LAST_CHECK=0
}
hb_write() {
  HB_SEQ=$((HB_SEQ + 1))
  {
    printf 'ts=%s\n' "$NOW"
    printf 'seq=%s\n' "$HB_SEQ"
    printf 'pid=%s\n' "${FM_INBOX_PULL_PID:-$PPID}"
    printf 'host=%s\n' "$(hostname -s 2>/dev/null || echo unknown)"
    printf 'last_check_ts=%s\n' "$HB_LAST_CHECK"
    printf 'last_notified_seq=%s\n' "$HB_LAST_SEQ"
    printf 'last_notified_inbox=%s\n' "$HB_LAST_INBOX"
    printf 'last_error=%s\n' "$HB_ERROR"
    printf 'killed=%s\n' "$HB_KILLED"
  } | write_atomic "$PULL/heartbeat" || log_line "cannot write heartbeat"
}
one_line() {  # collapse text to one bounded line
  printf '%s' "$1" | tr '\n\r\t' '   ' | cut -c1-300
}

is_killed() {
  [ "${FM_INBOX_PULL:-}" = 0 ] || [ -e "$KILL_FILE" ]
}

# --- scan set and cursor -----------------------------------------------------
canon_dir() {  # <dir> -> absolute physical path, or fail
  [ -d "$1" ] && [ ! -L "$1" ] || return 1
  (cd "$1" 2>/dev/null && pwd -P)
}

scan_dirs() {
  local entry d c cfg="$CONFIG/inbox-pull-dirs" IFS_SAVE=$IFS
  {
    if [ -n "${FM_INBOX_PULL_DIR:-}" ]; then
      IFS=:
      set -f
      # shellcheck disable=SC2086
      set -- $FM_INBOX_PULL_DIR
      set +f
      IFS=$IFS_SAVE
      for entry in "$@"; do [ -z "$entry" ] || printf '%s\n' "$entry"; done
    fi
    for d in "$STATE"/parent-route/*.inbox; do [ -e "$d" ] && printf '%s\n' "$d"; done
    if [ -f "$cfg" ]; then
      while IFS= read -r entry || [ -n "$entry" ]; do
        case "$entry" in '' | '#'*) continue ;; /*) printf '%s\n' "$entry" ;; *) printf '%s\n' "$FM_HOME/$entry" ;; esac
      done < "$cfg"
    fi
  } | while IFS= read -r d; do
    c=$(canon_dir "$d") && printf '%s\n' "$c"
  done | awk '!s[$0]++'
}

newest_handled() {  # <inbox-dir> -> highest handled sequence, or 0
  local f n best=0
  for f in "$1"/handled/*.msg; do
    [ -e "$f" ] || continue
    n=$(fm_task_inbox_seq_of "${f##*/}") || continue
    [ "$n" -le "$best" ] || best=$n
  done
  printf '%s' "$best"
}

FLOORS='' SEEN='' NOSAVE=0
cursor_load() {  # -> FLOORS/SEEN; migrates an unknown schema in place (never under NOSAVE)
  local dirs=$1 first kind d s
  FLOORS='' SEEN=''
  [ -f "$PULL/cursor" ] || return 0
  first=$(sed -n '1p' "$PULL/cursor" 2>/dev/null)
  if [ "$first" != "$SCHEMA" ]; then
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      s=$(newest_handled "$d")
      FLOORS="$FLOORS${FLOORS:+$'\n'}$d$TAB$s"
    done <<EOF
$dirs
EOF
    [ "$NOSAVE" -eq 1 ] && return 0
    cursor_save || return 1
    log_line "migrated an unrecognised cursor schema to v1; nothing replayed"
    return 0
  fi
  while IFS="$TAB" read -r kind d s; do
    case "$kind" in
      floor) FLOORS="$FLOORS${FLOORS:+$'\n'}$d$TAB$s" ;;
      seen) SEEN="$SEEN${SEEN:+$'\n'}$d$TAB$s" ;;
    esac
  done < <(sed '1d' "$PULL/cursor")
}
cursor_save() {
  {
    printf '%s\n' "$SCHEMA"
    [ -z "$FLOORS" ] || printf '%s\n' "$FLOORS" | sed "s/^/floor$TAB/"
    [ -z "$SEEN" ] || printf '%s\n' "$SEEN" | sed "s/^/seen$TAB/"
  } | write_atomic "$PULL/cursor"
}

floor_of() {  # <dir>
  printf '%s\n' "$FLOORS" | awk -F"$TAB" -v d="$1" '$1 == d { print $2; found = 1 } END { if (!found) print 0 }' | head -n 1
}

unseen_records() {  # <dirs> -> "dir<TAB>seq<TAB>path", oldest first per inbox
  local d f n fl
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    fl=$(floor_of "$d")
    for f in "$d"/*.msg; do
      [ -f "$f" ] || continue
      n=$(fm_task_inbox_seq_of "${f##*/}") || continue
      [ "$n" -gt "$fl" ] || continue
      [ ! -e "$d/handled/${f##*/}" ] || continue
      if [ -n "$SEEN" ] && printf '%s\n' "$SEEN" | grep -Fxq "$d$TAB$n"; then continue; fi
      printf '%s\t%s\t%s\n' "$d" "$n" "$f"
    done
  done <<EOF
$1
EOF
}

record_exists() {  # <inbox-dir> <seq>
  local f
  for f in "$1"/*.msg; do
    [ -f "$f" ] || continue
    [ "$(fm_task_inbox_seq_of "${f##*/}" 2>/dev/null)" = "$2" ] && return 0
  done
  return 1
}

# --- commands ----------------------------------------------------------------
cmd_peek() {
  local dirs rows total shown first notice held

  hb_load
  HB_KILLED=0
  if is_killed; then
    HB_KILLED=1
    hb_write
    return 0
  fi
  # throttle: decided before any directory scan. A clock that moved backwards
  # (last scan in the future) rescans rather than staying silent for ever.
  if [ "$HB_LAST_CHECK" -le "$NOW" ] && [ $((NOW - HB_LAST_CHECK)) -lt "$MIN_INTERVAL" ] && [ "$HB_LAST_CHECK" -gt 0 ]; then
    hb_write
    return 0
  fi
  if [ -f "$PULL/notices" ]; then
    local recent
    recent=$(awk -v cut=$((NOW - 3600)) '$1 + 0 > cut { n++ } END { print n + 0 }' "$PULL/notices" 2>/dev/null)
    if [ "${recent:-0}" -gt "$TRIP_MAX" ]; then
      printf 'tripped at %s: %s notices in the last hour (limit %s); remove this file to re-enable\n' "$NOW" "$recent" "$TRIP_MAX" > "$KILL_FILE" 2>/dev/null
      log_line "replay trip: $recent notices in the last hour exceeded $TRIP_MAX; wrote $KILL_FILE"
      HB_KILLED=1
      HB_ERROR="replay trip: $recent notices in the last hour"
      hb_write
      return 0
    fi
  fi

  dirs=$(scan_dirs)
  cursor_load "$dirs" || { HB_ERROR="cursor migration failed"; log_line "$HB_ERROR"; hb_write; return 0; }
  HB_LAST_CHECK=$NOW
  HB_ERROR=''
  rows=$(unseen_records "$dirs" | sort -t "$TAB" -k1,1 -k2,2n)
  if [ -z "$rows" ]; then
    rm -f "$PULL/pending" 2>/dev/null
    hb_write
    return 0
  fi
  total=$(printf '%s\n' "$rows" | wc -l | tr -d ' ')
  # An uncommitted pending set is an open transaction: replay exactly it (minus
  # records that vanished) until a commit consumes it, so a second peek can never
  # overwrite the set a first caller is about to commit.
  held=''
  if [ -s "$PULL/pending" ]; then
    held=$(printf '%s\n' "$rows" | awk -F"$TAB" 'NR == FNR { p[$1 FS $2] = 1; next } ($1 FS $2) in p' "$PULL/pending" -)
  fi
  if [ -n "$held" ]; then
    rows=$held
  else
    rows=$(printf '%s\n' "$rows" | head -n "$LIMIT")
  fi
  shown=$(printf '%s\n' "$rows" | wc -l | tr -d ' ')
  if ! printf '%s\n' "$rows" | cut -f1,2 | write_atomic "$PULL/pending"; then
    HB_ERROR="cannot write pending marker"
    log_line "$HB_ERROR"
    hb_write
    return 0
  fi
  first=$(printf '%s\n' "$rows" | head -n 1 | cut -f3)
  notice=$(fm_task_inbox_doorbell_line "$first") || notice=": Firstmate instruction waiting in a steering inbox."
  hb_write
  printf '%s\n' "${notice#: }"
  printf '%s\n' "$rows" | cut -f3 | sed 's/^/inbox-pull-notice:/'
  [ "$total" -le "$shown" ] || printf '+%s more waiting\n' "$((total - shown))"
}

cmd_commit() {
  local dirs d n kept='' last
  hb_load
  HB_KILLED=0
  is_killed && HB_KILLED=1
  if [ ! -s "$PULL/pending" ]; then
    hb_write
    return 0
  fi
  dirs=$(scan_dirs)
  cursor_load "$dirs" || { HB_ERROR="cursor migration failed"; log_line "$HB_ERROR"; hb_write; return 0; }
  while IFS="$TAB" read -r d n; do
    [ -n "$d" ] && [ -n "$n" ] || continue
    SEEN="$SEEN${SEEN:+$'\n'}$d$TAB$n"
    last="$d$TAB$n"
  done < "$PULL/pending"
  # prune: a seen record that left the inbox root (acknowledged) is below the
  # handled/ history that nothing re-notices, so the cursor stays small.
  while IFS="$TAB" read -r d n; do
    [ -n "$d" ] || continue
    record_exists "$d" "$n" || continue
    kept="$kept${kept:+$'\n'}$d$TAB$n"
  done < <(printf '%s\n' "$SEEN" | sort -u)
  SEEN=$kept
  if ! cursor_save; then
    HB_ERROR="cannot write cursor"
    log_line "$HB_ERROR"
    hb_write
    return 0
  fi
  rm -f "$PULL/pending" 2>/dev/null
  { awk -v cut=$((NOW - 3600)) '$1 + 0 > cut' "$PULL/notices" 2>/dev/null; printf '%s\n' "$NOW"; } | write_atomic "$PULL/notices" || log_line "cannot write notice history"
  if [ -n "${last:-}" ]; then
    HB_LAST_SEQ=${last#*"$TAB"}
    HB_LAST_INBOX=${last%%"$TAB"*}
  fi
  hb_write
}

cmd_beat() {
  hb_load
  HB_KILLED=0
  is_killed && HB_KILLED=1
  if [ -n "$BEAT_ERROR" ]; then
    HB_ERROR=$(one_line "$BEAT_ERROR")
    log_line "extension error: $HB_ERROR"
  fi
  hb_write
}

cmd_status() {
  local dirs rows pending=0
  NOSAVE=1
  hb_load
  dirs=$(scan_dirs)
  cursor_load "$dirs" >/dev/null 2>&1
  rows=$(unseen_records "$dirs")
  [ ! -s "$PULL/pending" ] || pending=$(wc -l < "$PULL/pending" | tr -d ' ')
  if [ -f "$PULL/heartbeat" ]; then cat "$PULL/heartbeat"; else echo "heartbeat=absent"; fi
  printf 'killed_now=%s\n' "$(is_killed && echo 1 || echo 0)"
  printf 'cursor=%s\n' "$([ -f "$PULL/cursor" ] && sed -n '1p' "$PULL/cursor" || echo absent)"
  printf 'pending=%s\n' "$pending"
  printf 'unseen_now=%s\n' "$(printf '%s' "$rows" | grep -c . || true)"
  printf 'scan_dirs=%s\n' "$(printf '%s' "$dirs" | tr '\n' ':')"
}

if [ "$CMD" = status ]; then
  cmd_status
  exit 0
fi
mkdir -p "$PULL" 2>/dev/null || exit 0
# A peek or commit must not be lost to a concurrent beat or peek: wait briefly
# for the lock. A beat may simply yield.
attempts=1
[ "$CMD" = beat ] || attempts=15
while ! lock_acquire; do
  attempts=$((attempts - 1))
  [ "$attempts" -gt 0 ] || exit 0
  sleep 0.2
done
case "$CMD" in
  peek) cmd_peek ;;
  commit) cmd_commit ;;
  beat) cmd_beat ;;
esac || log_line "$CMD failed"
exit 0
