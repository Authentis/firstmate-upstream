#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
E=~/.no-mistakes/evidence/01M6RMBRQFE89P7GNGBSKBW5T8
LAB=$ROOT/.live-lab
SOCK=$ROOT/.ls
cleanup() { tmux -S "$SOCK" kill-server 2>/dev/null || true; tmux -S "$ROOT/.lh" kill-server 2>/dev/null || true; if [ -n "${HIDDEN_PID:-}" ]; then kill "$HIDDEN_PID" 2>/dev/null || true; wait "$HIDDEN_PID" 2>/dev/null || true; fi; chmod -R u+w "$LAB" 2>/dev/null || true; rm -rf "$LAB"; rm -f "$SOCK" "$ROOT/.lh"; rm -rf /tmp/fm-labrecover1106 /tmp/fm-labattach1106; }
trap cleanup EXIT
if [ -d "$LAB" ]; then chmod -R u+w "$LAB"; rm -rf "$LAB"; fi
mkdir -p "$LAB"
bin/fm-lab-home.sh create "$LAB/home"
mkdir -p "$LAB/user" "$LAB/tmp" "$LAB/home/data/labrecover1106" "$LAB/home/config"
touch "$LAB/home/config/supervision-host" "$LAB/home/state/.last-watcher-beat"
export FM_HOME=$LAB/home HOME=$LAB/user TMPDIR=$LAB/tmp FM_SPAWN_NO_GUARD=1
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
export TREEHOUSE_ROOT=$LAB/pool
# Private real tmux server, no default/fleet socket.
tmux -S "$SOCK" new-session -d -s primary -x 120 -y 40 -c "$ROOT"
export TMUX="$SOCK,$(tmux -S "$SOCK" display-message -p '#{pid}'),0"
git init -q -b main "$LAB/proj"
git -C "$LAB/proj" config user.name Lab
git -C "$LAB/proj" config user.email lab@example.invalid
printf 'base\n' > "$LAB/proj/work.txt"
git -C "$LAB/proj" add .; git -C "$LAB/proj" commit -qm base
git -C "$LAB/proj" worktree add -q -b fm/labrecover1106 "$LAB/wt"
printf 'uncommitted preserved\n' >> "$LAB/wt/work.txt"
printf 'untracked preserved\n' > "$LAB/wt/untracked.txt"
cat > "$LAB/home/data/labrecover1106/brief.md" <<'EOF'
# Task
## Captain's intent
Preserve work and await operator; do not change files.

## Firstmate spec
This is an isolated local recovery check.
EOF
cat > "$LAB/home/state/labrecover1106.meta" <<EOF
window=gone-session:fm-labrecover1106
endpoint_task_id=labrecover1106
worktree=$LAB/wt
project=$LAB/proj
harness=codex
kind=ship
mode=local-only
yolo=off
branch=fm/labrecover1106
model=default
effort=default
EOF
cp "$LAB/home/state/labrecover1106.meta" "$LAB/before.meta"
git -C "$LAB/wt" diff > "$LAB/before.diff"
git -C "$LAB/wt" rev-parse HEAD > "$LAB/before.head"
refuse() {
  local label=$1 pattern=$2 rc
  set +e
  bin/fm-spawn.sh labrecover1106 --relaunch > "$E/guard-$label.log" 2>&1
  rc=$?
  set -e
  cat "$E/guard-$label.log"; echo "guard=$label exit=$rc"
  [ "$rc" -ne 0 ]; grep -F "$pattern" "$E/guard-$label.log"
  cmp "$LAB/before.meta" "$LAB/home/state/labrecover1106.meta"
  [ "$(tmux -S "$SOCK" list-windows -a -F '#{window_name}' | grep -c '^fm-labrecover1106$' || true)" = 0 ]
}
# Other socket, no matching arguments: only the actual worktree cwd betrays it.
tmux -S "$ROOT/.lh" new-session -d -s hidden -x 120 -y 40 -c "$ROOT"
tmux -S "$ROOT/.lh" new-window -t hidden -n worker -c "$LAB/wt"
sleep 0.5
refuse hidden-cwd 'working in the recorded worktree'
tmux -S "$ROOT/.lh" kill-window -t hidden:worker
# Other socket, outside the worktree: task token in process arguments must suffice.
tmux -S "$ROOT/.lh" new-window -t hidden -n worker -c "$ROOT" "bash -c 'exec -a fm-labrecover1106 sleep 180'"
sleep 0.5
refuse hidden-args 'names the task in its arguments'
tmux -S "$ROOT/.lh" kill-server
# Unknown hidden cwd must fail closed. prctl deliberately blocks /proc/cwd reads.
HIDDEN_CWD=$LAB/tmp python3 -c 'import os,ctypes,time; os.chdir(os.environ["HIDDEN_CWD"]); ctypes.CDLL(None).prctl(4,0); time.sleep(180)' &
HIDDEN_PID=$!
sleep 0.5
refuse hidden-unreadable 'could not be read'
kill "$HIDDEN_PID"; wait "$HIDDEN_PID" || true; HIDDEN_PID=
# A same-named window in another session of the addressed server must refuse.
tmux -S "$SOCK" new-session -d -s other -n fm-labrecover1106 -c "$ROOT"
set +e
bin/fm-spawn.sh labrecover1106 --relaunch > "$E/guard-window.log" 2>&1
rc=$?
set -e
cat "$E/guard-window.log"; echo "same_name_exit=$rc"; [ "$rc" -ne 0 ]
cmp "$LAB/before.meta" "$LAB/home/state/labrecover1106.meta"
tmux -S "$SOCK" kill-session -t other
echo 'LIVE_REFUSAL_GUARDS_PASS'
printf '\n=== Missing recorded endpoint: spawn --relaunch ===\n'
set +e
bin/fm-spawn.sh labrecover1106 --relaunch > "$E/live-recovery-spawn.log" 2>&1
rc=$?
set -e
cat "$E/live-recovery-spawn.log"; echo "spawn_exit=$rc"
[ "$rc" = 0 ]
cat "$LAB/home/state/labrecover1106.meta"
cmp "$LAB/before.diff" <(git -C "$LAB/wt" diff)
cmp "$LAB/before.head" <(git -C "$LAB/wt" rev-parse HEAD)
[ "$(git -C "$LAB/wt" branch --show-current)" = fm/labrecover1106 ]
[ "$(cat "$LAB/wt/untracked.txt")" = 'untracked preserved' ]
tmux -S "$SOCK" list-windows -a -F '#{session_name}:#{window_name} cwd=#{pane_current_path} command=#{pane_current_command}'
sleep 3
tmux -S "$SOCK" capture-pane -p -t primary:fm-labrecover1106 > "$E/live-recovery-pane.txt"
cat "$E/live-recovery-pane.txt"
echo 'RECOVERY_PRESERVATION_PASS'
# Control's public transaction must share the same missing-endpoint proof.
tmux -S "$SOCK" kill-window -t primary:fm-labrecover1106
cp "$LAB/before.meta" "$LAB/home/state/labrecover1106.meta"
set +e
FM_CONTROL_LAUNCH_WAIT=5 bin/fm-control.sh labrecover1106 relaunch --note 'Resume preserved lab work without editing it' > "$E/live-control-relaunch.log" 2>&1
rc=$?
set -e
cat "$E/live-control-relaunch.log"; echo "control_exit=$rc"; [ "$rc" = 0 ]
cat "$LAB/home/state/labrecover1106.control-relaunch"
cmp "$LAB/before.diff" <(git -C "$LAB/wt" diff)
[ "$(cat "$LAB/wt/untracked.txt")" = 'untracked preserved' ]
echo 'CONTROL_RECOVERY_PASS'
