#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
E=~/.no-mistakes/evidence/01M829GRMXP9QRRPHXAHH0F1B6
BASE="$ROOT/.live-lab"
LAB="$BASE/h"
ORIGINAL_HOME=$HOME
ID=lv829
F="$BASE/f"
stopped=
cleanup() {
  set +e
  [ -z "$stopped" ] || kill -CONT "$stopped" 2>/dev/null
  env -u TMUX tmux -S "$F" kill-server 2>/dev/null
  [ -z "${TMUX_TMPDIR:-}" ] || env -u TMUX TMUX_TMPDIR="$TMUX_TMPDIR" tmux -L fm-lab kill-server 2>/dev/null
  mountpoint -q "$BASE/cc/.credentials.json" && umount "$BASE/cc/.credentials.json"
  rm -rf "$BASE"
  echo 'CLEANUP: private servers stopped, read-only login unmounted, disposable home and repositories removed'
}
trap cleanup EXIT
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TMUX HERDR_SESSION HERDR_ENV HERDR_PANE_ID HERDR_SOCKET_PATH
bin/fm-lab-home.sh create "$LAB"
mkdir -p "$LAB/tmux" "$BASE/cc" "$BASE/user" "$BASE/outside"
touch "$LAB/config/supervision-host"
printf 'auto\n' > "$LAB/config/claude-permission-mode"
touch "$BASE/cc/.credentials.json"
mount --bind "$ORIGINAL_HOME/.claude/.credentials.json" "$BASE/cc/.credentials.json"
mount -o remount,bind,ro "$BASE/cc/.credentials.json"
export HOME="$BASE/user" CLAUDE_CONFIG_DIR="$BASE/cc" FM_HOME="$LAB" TMUX_TMPDIR="$LAB/tmux" TMPDIR="$BASE" FM_SPAWN_NO_GUARD=1
export FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=10 FM_CONTROL_LAUNCH_WAIT=30
printf '{"hasCompletedOnboarding":true,"theme":"dark","numStartups":1}\n' > "$BASE/cc/.claude.json"
claude auth status | jq '{loggedIn,authMethod,apiProvider,storedClaudeAiLogin}'
git init -q "$BASE/p"
git -C "$BASE/p" -c user.name=Lab -c user.email=lab@example.invalid commit --allow-empty -qm seed
git -C "$BASE/p" worktree add -qb "fm/$ID" "$BASE/w"
printf 'preserve this unfinished work\n' > "$BASE/w/unfinished.txt"
mkdir -p "$LAB/data/$ID"
printf "# Task\n## Captain's intent\nDisposable lab validation. Do not use tools, spawn work, modify files, or call lifecycle commands. Reply LAB_READY and wait.\n## Firstmate spec\nThis is an isolated validation. Reply LAB_READY without using tools and then wait.\n" > "$LAB/data/$ID/brief.md"
cat > "$LAB/state/$ID.meta" <<EOF
window=vanished:fm-$ID
endpoint_task_id=$ID
worktree=$BASE/w
project=$BASE/p
harness=claude
kind=ship
mode=no-mistakes
yolo=off
branch=fm/$ID
tasktmp=$BASE/tasktmp
model=default
effort=default
EOF
cp "$LAB/state/$ID.meta" "$BASE/original.meta"
# The addressed private seat is not the foreign server the proof must discover.
env -u TMUX tmux -L fm-lab -f /dev/null new-session -d -s seat -n seat -c "$BASE/outside" -x 100 -y 32
export TMUX="$(env -u TMUX tmux -L fm-lab display-message -p '#{socket_path},#{pid}'),0"
control() {
  local label=$1 verb=$2; shift 2
  echo "=== $label: bin/fm-control.sh $ID $verb $* ==="
  local rc=0
  bin/fm-control.sh "$ID" "$verb" "$@" > "$E/$label.txt" 2>&1 || rc=$?
  cat "$E/$label.txt"
  echo "EXIT=$rc"
  return "$rc"
}
refuse() {
  local label=$1 match=$2 rc
  if control "$label" relaunch --note 'isolated guard validation'; then rc=0; else rc=$?; fi
  [ "$rc" -ne 0 ]
  grep -F "$match" "$E/$label.txt"
  cmp "$BASE/original.meta" "$LAB/state/$ID.meta"
  [ "$(tmux list-windows -a -F '#{window_name}' | grep -c "^fm-$ID$" || true)" = 0 ]
  echo 'ORACLE: nonzero refusal; durable record byte-identical; no replacement on addressed server'
}
# Give the synthetic record an actual endpoint, then destroy that server.
F="$BASE/old"
env -u TMUX tmux -S "$F" -f /dev/null new-session -d -s vanished -n "fm-$ID" -c "$BASE/w" -x 100 -y 32 'sleep 600'
tmux -S "$F" list-panes -a -F 'ORIGINAL_ENDPOINT=#{session_name}:#{window_name} CWD=#{pane_current_path}'
tmux -S "$F" kill-server
echo 'SETUP: original endpoint server destroyed; task copy and record retained'
F="$BASE/f"
# Window-name and pane-path evidence on a real, unaddressed server.
env -u TMUX tmux -S "$F" -f /dev/null new-session -d -s foreign -n "fm-$ID" -c "$BASE/w" -x 100 -y 32 'sleep 600'
refuse foreign-name 'still has a window named'
tmux -S "$F" rename-window -t foreign: renamed
refuse foreign-path 'working in the recorded worktree'
tmux -S "$F" kill-server
F="$BASE/f2"
# A synthetic live task process: real sleep with task-labelled argv, renamed
# window and cwd outside the worktree. No harness or backend implementation stub.
env -u TMUX tmux -S "$F" -f /dev/null new-session -d -s foreign -n renamed -c "$BASE/outside" -x 100 -y 32 "bash -c 'exec -a fm-$ID sleep 600'"
refuse foreign-process 'names the task in its arguments'
tmux -S "$F" list-panes -a -F 'WINDOW=#{window_name} CWD=#{pane_current_path} PID=#{pane_pid}'
tmux -S "$F" kill-server
F="$BASE/f3"
# Freeze a real foreign server to create unreadable endpoint evidence.
env -u TMUX tmux -S "$F" -f /dev/null new-session -d -s foreign -n unrelated -c "$BASE/outside" -x 100 -y 32 'sleep 600'
stopped=$(tmux -S "$F" display-message -p '#{pid}')
kill -STOP "$stopped"
start=$SECONDS
FM_CONTROL_ABSENCE_DEADLINE=2 refuse stopped-server 'did not answer within the 2s deadline'
elapsed=$((SECONDS-start))
echo "BOUNDED_REFUSAL_SECONDS=$elapsed"
[ "$elapsed" -lt 10 ]
kill -CONT "$stopped"
stopped=
tmux -S "$F" kill-server
# Fault injection at the external ps boundary, not a replacement product.
mkdir -p "$BASE/fault-bin"
printf '#!/bin/sh\nexit 1\n' > "$BASE/fault-bin/ps"
chmod +x "$BASE/fault-bin/ps"
PATH="$BASE/fault-bin:$PATH" refuse unreadable-process-table 'the process table could not be read'
# True endpoint loss: every private foreign server is gone. The same endpoint
# proof must now license an exit and one real replacement in the existing copy.
control gone-exit exit
grep -F 'endpoint-gone' "$E/gone-exit.txt"
cmp "$BASE/original.meta" "$LAB/state/$ID.meta"
control gone-relaunch relaunch --note 'The terminal vanished. Reply LAB_READY and wait; do not execute tools.'
cp "$LAB/state/$ID.meta" "$E/reclaimed.meta"
cp "$LAB/state/$ID.control-relaunch" "$E/relaunch-journal.txt"
endpoint=$(awk -F= '$1=="window" {print substr($0,8)}' "$LAB/state/$ID.meta")
[ "$endpoint" != "vanished:fm-$ID" ]
[ "$(awk -F= '$1=="worktree" {print substr($0,10)}' "$LAB/state/$ID.meta")" = "$BASE/w" ]
[ "$(git -C "$BASE/w" branch --show-current)" = "fm/$ID" ]
grep -qx 'preserve this unfinished work' "$BASE/w/unfinished.txt"
[ "$(tmux list-windows -a -F '#{window_name}' | grep -c "^fm-$ID$")" = 1 ]
for i in $(seq 1 90); do
  tmux capture-pane -p -t "$endpoint" -S -200 > "$E/replacement-pane.txt"
  grep -q 'LAB_READY' "$E/replacement-pane.txt" && break
  if grep -q 'Choose the text style' "$E/replacement-pane.txt"; then
    tmux send-keys -t "$endpoint" Enter
  elif grep -q 'Allow external CLAUDE.md file imports?' "$E/replacement-pane.txt"; then
    # Decline parent-repository imports; only the disposable task is needed.
    tmux send-keys -t "$endpoint" Enter
  elif grep -q 'Adding a new directory:' "$E/replacement-pane.txt" && grep -q 'Yes, add it' "$E/replacement-pane.txt"; then
    # Only session-scoped access to this disposable lab's generated inboxes.
    grep -qF "$BASE/" "$E/replacement-pane.txt"
    tmux send-keys -t "$endpoint" Down Enter
  fi
  sleep 1
done
cat "$E/replacement-pane.txt"
echo 'ORACLE: same task/branch/worktree and unfinished content, exactly one replacement window, actual Claude command'
tmux list-panes -a -F 'WINDOW=#{window_name} CWD=#{pane_current_path} COMMAND=#{pane_current_command}'
grep -q 'LAB_READY' "$E/replacement-pane.txt"
echo 'ALL LIVE SCENARIOS PASSED'
