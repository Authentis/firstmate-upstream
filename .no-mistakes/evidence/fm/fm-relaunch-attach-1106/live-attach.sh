#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
E=~/.no-mistakes/evidence/01M6RW4TZXA24GYGX9TP9E0VN6
LAB=$ROOT/.l
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TMUX HERDR_ENV HERDR_SESSION HERDR_SOCKET_PATH
mkdir -p "$LAB"
"$ROOT/bin/fm-lab-home.sh" create "$LAB"
mkdir -p "$LAB/tmux" "$LAB/user" "$LAB/pool"
export FM_HOME=$LAB HOME=$LAB/user TREEHOUSE_ROOT=$LAB/pool TMUX_TMPDIR=$LAB/tmux
export XDG_CONFIG_HOME=$LAB/user/config XDG_DATA_HOME=$LAB/user/data XDG_CACHE_HOME=$LAB/user/cache
export CLAUDE_CONFIG_DIR=$LAB/user/claude
export FM_SPAWN_NO_GUARD=1 FM_CONTROL_LAUNCH_WAIT=3
cleanup() {
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab kill-server 2>/dev/null || true
  TMUX_TMPDIR="$LAB/tmux" tmux -L other kill-server 2>/dev/null || true
  chmod -R u+w "$LAB" 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT
: > "$LAB/config/supervision-host"
printf 'claude\n' > "$LAB/config/crew-harness"
TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab -f /dev/null new-session -d -s lab -x 120 -y 35 -c "$ROOT"
export TMUX=$(TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab display-message -p '#{socket_path},#{pid},0')
# A tiny real repository with preserved uncommitted work.
git init -q -b main "$LAB/project"
printf 'base\n' > "$LAB/project/base.txt"
git -C "$LAB/project" add .
git -C "$LAB/project" -c user.name=Lab -c user.email=lab@example.invalid commit -qm base
BASE=$(git -C "$LAB/project" rev-parse HEAD)
git -C "$LAB/project" worktree add -q -b fm/lab-recorded "$LAB/worker" HEAD
printf 'uncommitted recovery payload\n' > "$LAB/worker/dirty.txt"
brief() {
 mkdir -p "$LAB/data/$1"
 printf '# Task\n## Captain\047s intent\nValidate isolated attach. Do not modify files.\n\n## Firstmate spec\nKeep preserved work.\n\n## Ship branch\n%s\n' "$2" > "$LAB/data/$1/brief.md"
}
brief lab-recorded fm/lab-recorded
cat > "$LAB/state/lab-recorded.meta" <<EOF
window=gone-session:fm-lab-recorded
endpoint_task_id=lab-recorded
worktree=$LAB/worker
project=$LAB/project
harness=claude
kind=ship
mode=no-mistakes
yolo=off
branch=fm/lab-recorded
model=default
effort=default
EOF
cp "$LAB/state/lab-recorded.meta" "$LAB/meta-before"
echo '=== A: exit on absent endpoint, real process table and tmux ==='
"$ROOT/bin/fm-control.sh" lab-recorded exit | tee "$E/exit-absent.txt"
cmp "$LAB/meta-before" "$LAB/state/lab-recorded.meta"
echo '=== B: prelaunch trust failure removes only unused replacement; retry recovers ==='
printf 'not json\n' > "$CLAUDE_CONFIG_DIR.json"
# Trust registration uses CLAUDE_CONFIG_DIR/.claude.json or HOME/.claude.json; create both invalid stores.
mkdir -p "$CLAUDE_CONFIG_DIR"
printf 'not json\n' > "$HOME/.claude.json"
printf 'not json\n' > "$CLAUDE_CONFIG_DIR/.claude.json"
set +e
"$ROOT/bin/fm-spawn.sh" lab-recorded --relaunch > "$E/relaunch-failed.txt" 2>&1
rc=$?
set -e
cat "$E/relaunch-failed.txt"
printf 'exit=%s\n' "$rc"
[ "$rc" -ne 0 ]
grep -q 'could not pre-register Claude workspace trust' "$E/relaunch-failed.txt"
cmp "$LAB/meta-before" "$LAB/state/lab-recorded.meta"
! tmux list-windows -a -F '#{window_name}' | grep -qx fm-lab-recorded
printf 'replacement absent; metadata unchanged; preserved HEAD=%s branch=%s dirty=%s\n' "$(git -C "$LAB/worker" rev-parse HEAD)" "$(git -C "$LAB/worker" branch --show-current)" "$(cat "$LAB/worker/dirty.txt")"
rm -f "$HOME/.claude.json" "$CLAUDE_CONFIG_DIR/.claude.json" "$CLAUDE_CONFIG_DIR.json"
"$ROOT/bin/fm-control.sh" lab-recorded relaunch --note 'Continue preserved lab work without changing files.' | tee "$E/relaunch-retry.txt"
[ "$(git -C "$LAB/worker" rev-parse HEAD)" = "$BASE" ]
[ "$(git -C "$LAB/worker" branch --show-current)" = fm/lab-recorded ]
grep -qx 'uncommitted recovery payload' "$LAB/worker/dirty.txt"
grep -qx 'window=lab:fm-lab-recorded' "$LAB/state/lab-recorded.meta"
cat "$LAB/state/lab-recorded.meta" > "$E/recovered-meta.txt"
tmux capture-pane -p -t lab:fm-lab-recorded > "$E/recovered-pane.txt"
tmux kill-window -t lab:fm-lab-recorded
printf 'recovery verified: same branch, same HEAD, same dirty file, one rebound window\n'
echo '=== C: cannot duplicate a process in task worktree on another socket ==='
TMUX_TMPDIR="$LAB/tmux" tmux -L other -f /dev/null new-session -d -s hidden -n unrelated -c "$LAB/worker" -x 120 -y 35
cp "$LAB/meta-before" "$LAB/state/lab-recorded.meta"
set +e
"$ROOT/bin/fm-spawn.sh" lab-recorded --relaunch > "$E/guard-hidden-worker.txt" 2>&1
rc=$?
set -e
cat "$E/guard-hidden-worker.txt"
[ "$rc" -ne 0 ]
grep -Eq '(working in|names) the recorded worktree' "$E/guard-hidden-worker.txt"
cmp "$LAB/meta-before" "$LAB/state/lab-recorded.meta"
TMUX_TMPDIR="$LAB/tmux" tmux -L other kill-server
sleep 0.2
echo '=== D: same window name in another session refuses ==='
tmux new-session -d -s collision -n fm-lab-recorded -c "$ROOT"
set +e
"$ROOT/bin/fm-spawn.sh" lab-recorded --relaunch > "$E/guard-window.txt" 2>&1
rc=$?
set -e
cat "$E/guard-window.txt"
[ "$rc" -ne 0 ]
grep -q 'still in the window inventory' "$E/guard-window.txt"
cmp "$LAB/meta-before" "$LAB/state/lab-recorded.meta"
tmux kill-session -t collision
echo 'LIVE RECORDED SCENARIOS COMPLETE'
