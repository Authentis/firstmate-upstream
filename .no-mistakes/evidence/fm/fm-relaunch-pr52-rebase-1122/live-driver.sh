#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
E=~/.no-mistakes/evidence/01M813G90ZZFBTZENSQ77EDC2M
LAB="$ROOT/.l"
cleanup() {
 set +e
 TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab kill-server 2>/dev/null
 [ -z "${STOPPED:-}" ] || kill -CONT "$STOPPED" 2>/dev/null
 [ -z "${OTHER:-}" ] || tmux -S "$OTHER" kill-server 2>/dev/null
 [ "${1:-}" != --inner ] || return 0
 if mountpoint -q "$LAB/claude"; then python3 - "$LAB/claude" <<'PY'
import ctypes,sys
libc=ctypes.CDLL(None,use_errno=True)
assert libc.umount2(sys.argv[1].encode(),0)==0, ctypes.get_errno()
PY
 fi
 rm -rf "$LAB"
}
trap 'cleanup "${1:-}"' EXIT
if [ "${1:-}" != --inner ]; then
bin/fm-lab-home.sh create "$LAB"
mkdir -p "$LAB/tmux" "$LAB/user" "$LAB/claude" "$LAB/upper" "$LAB/work"
# The real CLI alone consumes the machine's existing login through a read-only
# lower layer. Every Claude config/session write goes to the disposable upper.
# The kernel grants mount capability in this private user namespace, even
# though the mount(8) utility rejects nonzero namespace UIDs before calling it.
python3 - "$LAB" <<'PY'
import ctypes,sys
lab=sys.argv[1]
libc=ctypes.CDLL(None,use_errno=True)
opts=f'lowerdir=~/.claude,upperdir={lab}/upper,workdir={lab}/work'.encode()
assert libc.mount(b'overlay',(lab+'/claude').encode(),b'overlay',0,opts)==0, ctypes.get_errno()
PY
# Preserve the normal UID for real CLIs while retaining the read-only-lower
# mount prepared by the outer namespace. Both PID namespaces are disposable.
rc=0
unshare --user --map-user=1000 --map-group=1000 --mount --pid --fork --mount-proc bash "$0" --inner || rc=$?
exit "$rc"
fi
export CLAUDE_CONFIG_DIR="$LAB/claude"
printf '{"hasCompletedOnboarding":true,"theme":"dark","numStartups":1}\n' > "$LAB/claude/.claude.json"
claude auth status | python3 -c 'import json,sys; x=json.load(sys.stdin); print("Existing real Claude login available in copy-on-write lab:",x.get("loggedIn")); assert x.get("loggedIn")'
export FM_HOME="$LAB" TMUX_TMPDIR="$LAB/tmux" HOME="$LAB/user"
unset FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TMUX FM_CONTROL_PROC_ROOT
export FM_CONTROL_LAUNCH_WAIT=35 FM_CONTROL_ABSENCE_DEADLINE=5
# Private primary CLI, never the operator's tmux server.
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -s primary -x 120 -y 35 -c "$PWD" -e FM_HOME="$LAB" claude
export TMUX="$(tmux -L fm-lab display-message -p '#{socket_path},#{pid},0')"
P="$LAB/project"; WT="$LAB/task"
mkdir -p "$P"
git init -q "$P"; git -C "$P" -c user.name=Lab -c user.email=lab@example.invalid commit --allow-empty -qm Initial
git -C "$P" worktree add -qb task "$WT"
printf 'preserve this unfinished work\n' > "$WT/unfinished.txt"
mkdir -p "$LAB/data/liveproof"
printf '# Task\n\n## Captain\x27s intent\nValidate terminal lifecycle safely.\n\n## Firstmate spec\nRemain idle. Do not run any tools, modify files, or contact any services. This task is only a terminal lifecycle validation.\n' > "$LAB/data/liveproof/brief.md"
cat > "$LAB/state/liveproof.meta" <<EOF
window=vanished:fm-liveproof
endpoint_task_id=liveproof
worktree=$WT
project=$P
harness=claude
kind=ship
branch=task
mode=no-mistakes
yolo=off
model=default
effort=default
EOF
printf 'original status sentinel\n' > "$LAB/state/liveproof.status"
cp "$LAB/state/liveproof.meta" "$LAB/original.meta"
cp "$WT/unfinished.txt" "$LAB/unfinished.before"
export SHELL=/bin/bash
printf '\n=== Destroyed server: exit must prove endpoint-gone ===\n'
"$ROOT/bin/fm-control.sh" liveproof exit
printf '\n=== Destroyed server: relaunch must create one replacement and preserve work ===\n'
set +e
"$ROOT/bin/fm-control.sh" liveproof relaunch --note 'Terminal vanished. Preserve unfinished.txt and remain idle; this is a disposable lifecycle check.'
rc=$?
set -e
printf 'relaunch exit=%s\n' "$rc"
[ "$rc" = 0 ] || { [ ! -f "$LAB/state/liveproof.control-relaunch" ] || head -80 "$LAB/state/liveproof.control-relaunch"; exit "$rc"; }
cat "$LAB/state/liveproof.meta"
cat "$LAB/state/liveproof.control-relaunch"
cmp "$WT/unfinished.txt" "$LAB/unfinished.before"
cat "$LAB/state/liveproof.status"
tmux -L fm-lab list-panes -a -F '#{session_name}:#{window_name} #{pane_current_command} #{pane_current_path}'
target=$(awk -F= '$1=="window" {print $2}' "$LAB/state/liveproof.meta")
tmux -L fm-lab capture-pane -p -t "$target" > "$E/replacement-pane.txt"
printf '\nReplacement alive, recorded worktree and unfinished bytes preserved.\n'
head_before=$(git -C "$WT" rev-parse HEAD)
branch_before=$(git -C "$WT" branch --show-current)
[ "$branch_before" = task ]
printf '\n=== Destroyed window on surviving server: reclaim once ===\n'
tmux -L fm-lab kill-window -t "$target"
"$ROOT/bin/fm-control.sh" liveproof relaunch --note 'Window vanished; preserve unfinished work and remain idle.'
[ "$(tmux -L fm-lab list-windows -a -F '#{window_name}' | grep -xc fm-liveproof)" = 1 ]
[ "$(git -C "$WT" rev-parse HEAD)" = "$head_before" ]
[ "$(git -C "$WT" branch --show-current)" = "$branch_before" ]
cmp "$WT/unfinished.txt" "$LAB/unfinished.before"
grep -Fx 'original status sentinel' "$LAB/state/liveproof.status"
sleep 6
tmux -L fm-lab capture-pane -p -t "$target" > "$E/replacement-pane.txt"
[ "$(tmux -L fm-lab display-message -p -t "$target" '#{pane_current_command}')" = claude ] || { cat "$E/replacement-pane.txt"; exit 1; }
printf 'Replacement CLI remains alive after six-second startup settling.\n'
printf 'One replacement; same HEAD, branch, worktree, status, unfinished bytes.\n'
tmux -L fm-lab kill-window -t "$target"
cp "$LAB/state/liveproof.meta" "$LAB/guard.meta"
cp "$LAB/data/liveproof/brief.md" "$LAB/guard.brief"
refuse() {
 local expected=$1; shift
 set +e
 out=$("$@" 2>&1); r=$?
 set -e
 printf '%s\nexit=%s\n' "$out" "$r"
 [ "$r" -ne 0 ]; [[ "$out" == *"$expected"* ]]
 cmp "$LAB/guard.meta" "$LAB/state/liveproof.meta"
 cmp "$LAB/guard.brief" "$LAB/data/liveproof/brief.md"
 cmp "$LAB/unfinished.before" "$WT/unfinished.txt"
 printf 'Refusal preserved metadata, instructions and unfinished bytes.\n'
}
OTHER="$LAB/other.sock"
tmux -S "$OTHER" new-session -d -s foreign -n fm-liveproof -x 120 -y 35 -c "$WT" claude
printf '\n=== Matching task on another real server: refuse, do not duplicate ===\n'
refuse 'still has a window named fm-liveproof' "$ROOT/bin/fm-control.sh" liveproof relaunch --note 'Must refuse while foreign endpoint exists.'
refuse 'still has a window named fm-liveproof' "$ROOT/bin/fm-spawn.sh" liveproof --relaunch --harness claude
printf '\n=== Renamed foreign pane remains in worktree: refuse by pane path ===\n'
tmux -S "$OTHER" rename-window -t foreign:0 unrelated
refuse 'working in the recorded worktree' "$ROOT/bin/fm-control.sh" liveproof relaunch --note 'Must refuse while renamed pane remains in worktree.'
printf '\n=== Renamed real CLI outside worktree still names task: refuse by process arguments ===\n'
# Give the previous worker its shutdown interval before replacing it.
tmux -S "$OTHER" kill-server
sleep 3
tmux -S "$OTHER" new-session -d -s foreign -n unrelated -x 120 -y 35 -c "$LAB" "claude --append-system-prompt 'Task liveproof; remain idle and do not run tools.'"
# Wait for the actual executable, not a shell about to exec it.
for i in $(seq 1 40); do
 cmd=$(tmux -S "$OTHER" display-message -p -t foreign:0 '#{pane_current_command}')
 [ "$cmd" != claude ] || break
 sleep .1
done
[ "$cmd" = claude ]
tmux -S "$OTHER" list-panes -a -F '#{window_name} #{pane_current_path} #{pane_current_command}'
ps -A -o pid= -o ppid= -o args= > "$E/process-guard-ps.txt"
refuse 'names the task in its arguments' "$ROOT/bin/fm-control.sh" liveproof relaunch --note 'Must refuse after both endpoint identity signals were changed.'
printf '\n=== Ambiguous unresponsive server: bounded refusal, no mutation ===\n'
tmux -S "$OTHER" respawn-pane -k -t foreign:0 -c "$LAB" 'sleep 300'
STOPPED=$(tmux -S "$OTHER" display-message -p '#{pid}')
kill -STOP "$STOPPED"
start=$SECONDS
refuse 'did not answer within the 5s deadline' "$ROOT/bin/fm-control.sh" liveproof relaunch --note 'Must refuse unreadable evidence.'
elapsed=$((SECONDS-start)); printf 'Refusal elapsed seconds=%s (budget 5 plus command overhead)\n' "$elapsed"
[ "$elapsed" -le 12 ]
kill -CONT "$STOPPED"; STOPPED=
printf '\nALL LIVE SCENARIOS PASSED\n'
