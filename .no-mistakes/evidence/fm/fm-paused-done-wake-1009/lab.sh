#!/usr/bin/env bash
# Disposable lab driver for the paused-overdue wake scenarios.
set -u
WT=${WT_OVERRIDE:-/Users/lundi/.no-mistakes/worktrees/0d3d213d42f1/01M4ENXW8A7JBN417QMRZKMF6C}
LAB=/tmp/fmlab-pw
EV=/Users/lundi/.no-mistakes/evidence/01M4ENXW8A7JBN417QMRZKMF6C
mkdir -p "$EV"
TM() { env -u TMUX TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab "$@"; }
SOCK="$LAB/tmux/tmux-$(id -u)/fm-lab"
labenv() {
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    TMUX_TMPDIR="$LAB/tmux" TMUX="$SOCK,0,0" FM_HOME="$LAB" "$@"
}
age_file() {  # <secs-ago> <file>
  touch -t "$(date -r $(( $(date +%s) - $1 )) +%Y%m%d%H%M.%S)" "$2"
}
reset_state() {  # wipe watcher state between scenarios, keep the lab marker
  find "$LAB/state" -mindepth 1 -delete
}
start_lane() {  # <task> <status-line> <age>
  local task=$1
  TM kill-window -t "lab:fm-$task" 2>/dev/null || true
  TM new-window -d -t lab: -n "fm-$task" "env PS1='builder\$ ' bash --norc --noprofile -c 'printf \"PR https://example.test/pr/9 published\\n\"; exec bash --norc --noprofile -i'"
  printf "window=lab:fm-%s\nkind=ship\nworktree=$LAB/projects/parked-wt\n" "$task" > "$LAB/state/$task.meta"
  printf '%s\n' "$2" > "$LAB/state/$task.status"
  age_file "$3" "$LAB/state/$task.status"
}
run_watch() {  # <out> <secs> [extra env...] -> runs watcher in background, waits up to secs; prints rc
  local out=$1 secs=$2; shift 2
  ( cd "$WT" && labenv FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
      FM_STALE_ESCALATE_SECS=999 "$@" bin/fm-watch.sh > "$out" 2>"$out.err" ) &
  WPID=$!
  local i=0
  while [ "$i" -lt "$secs" ]; do
    kill -0 "$WPID" 2>/dev/null || { wait "$WPID"; echo "watcher exited rc=$? after ~${i}s"; return 0; }
    sleep 1; i=$((i+1))
  done
  echo "watcher still running after ${secs}s (no wake)"
  return 1
}
stop_watch() { pkill -P "$WPID" 2>/dev/null; kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; true; }
drain() {  # drain, print, then acknowledge as a supervisor would after handling
  local out ack
  out=$(cd "$WT" && labenv bin/fm-wake-drain.sh 2>&1); printf '%s\n' "$out"
  ack=$(printf '%s\n' "$out" | sed -n 's/.*run bin\/fm-wake-drain.sh \(--ack-through [0-9]* --recovery-generation [^ ]*\).*/\1/p' | head -1)
  # shellcheck disable=SC2086
  [ -z "$ack" ] || (cd "$WT" && labenv bin/fm-wake-drain.sh $ack >/dev/null 2>&1)
}
# Absorb the builder's own status-write signal the way the supervisor would, then
# age the line so the watcher next sees an idle lane whose paused: line is old.
settle_signal() {  # <task> <age> <evprefix>
  run_watch "$3-signal.out" 30 >/dev/null; stop_watch; drain > "$3-signal.drain" 2>&1
  age_file "$2" "$LAB/state/$1.status"
  run_watch "$3-signal2.out" 6 >/dev/null; stop_watch; drain >> "$3-signal.drain" 2>&1
}
# Restart the watcher across non-stale exits (signal / check wakes, drained and
# acked between runs) until it emits `stale: <window>` or <secs> elapse.
watch_for_stale() {  # <prefix> <secs> [env...] -> 0 stale seen, 1 quiet
  local p=$1 secs=$2 start i=0; shift 2; start=$(date +%s)
  while [ $(( $(date +%s) - start )) -lt "$secs" ]; do
    if run_watch "$p-run$i.out" $(( secs - ($(date +%s) - start) )) "$@" >/dev/null; then
      echo "  watcher run $i exited after $(( $(date +%s) - start ))s: $(tr '\n' ' ' < "$p-run$i.out")"
      drain > "$p-run$i.drain" 2>&1
      grep -q '^stale: ' "$p-run$i.out" && { sed 's/^/    drain> /' "$p-run$i.drain"; return 0; }
      i=$((i+1))
    else
      stop_watch; echo "  watcher run $i still running, no stale wake within ${secs}s total"; return 1
    fi
  done
  return 1
}
banner() { printf '\n===== %s =====\n' "$*"; }
show_lane() {  # <task>
  echo "status line: $(tail -1 "$LAB/state/$1.status")"
  echo "status age:  $(( $(date +%s) - $(stat -f %m "$LAB/state/$1.status") ))s"
  echo "pane:"; TM capture-pane -p -t "lab:fm-$1" | sed '/^$/d' | sed 's/^/  | /'
  echo "crew-state: $(cd "$WT" && labenv bin/fm-crew-state.sh "$1")"
}
