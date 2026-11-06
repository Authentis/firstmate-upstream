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

# Fail the real Claude trust registration after a replacement window is allocated.
python3 - "$LAB/home/state/labrecover1106.meta" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); p.write_text(p.read_text().replace('harness=codex','harness=claude'))
PY
cp "$LAB/home/state/labrecover1106.meta" "$LAB/failed-before.meta"
printf '{broken-json\n' > "$HOME/.claude.json"
set +e
bin/fm-spawn.sh labrecover1106 --relaunch > "$E/live-abort-cleanup.log" 2>&1
rc=$?
set -e
cat "$E/live-abort-cleanup.log"; echo "prepublication_failure_exit=$rc"; [ "$rc" -ne 0 ]
cmp "$LAB/failed-before.meta" "$LAB/home/state/labrecover1106.meta"
[ "$(tmux -S "$SOCK" list-windows -a -F '#{window_name}' | grep -c '^fm-labrecover1106$' || true)" = 0 ]
[ "$(tmux -S "$SOCK" list-windows -a -F '#{window_name}' | wc -l)" = 1 ]
echo 'ABORT_REMOVED_ONLY_REPLACEMENT_AND_KEPT_OLD_META'
# Repair only the lab setup; retry from the exact old endpoint record.
rm "$HOME/.claude.json"
cp "$LAB/before.meta" "$LAB/home/state/labrecover1106.meta"
set +e
bin/fm-control.sh labrecover1106 relaunch --note 'Retry after isolated trust failure' > "$E/live-abort-retry.log" 2>&1
rc=$?
set -e
cat "$E/live-abort-retry.log"; echo "retry_exit=$rc"; [ "$rc" = 0 ]
cat "$LAB/home/state/labrecover1106.control-relaunch"
cmp "$LAB/before.diff" <(git -C "$LAB/wt" diff)
[ "$(cat "$LAB/wt/untracked.txt")" = 'untracked preserved' ]
echo 'ABORT_CLEANUP_RETRY_PASS'
