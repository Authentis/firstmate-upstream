#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
D="$ROOT/.live-validation"
LAB="$D/home"
export FM_HOME="$LAB"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE HERDR_ENV HERDR_PANE_ID HERDR_SESSION HERDR_SOCKET_PATH HERDR_TAB_ID HERDR_WORKSPACE_ID
export HOME="$D/user" CLAUDE_CONFIG_DIR="$D/user/claude" TMPDIR="$D/tmp"
mkdir -p "$HOME" "$CLAUDE_CONFIG_DIR" "$TMPDIR"
bin/fm-lab-home.sh create "$LAB"
mkdir -p "$LAB/tmux"; touch "$LAB/config/supervision-host"
SOCK=.live-validation/socket/s
cleanup() { tmux -S "$SOCK" kill-server 2>/dev/null || true; }
trap cleanup EXIT
export TMUX="$SOCK,0,0"
tmux -S "$SOCK" new-session -d -s fm-lab-recover -n primary -x 100 -y 30 -c "$ROOT"
git init -q "$D/project"
git -C "$D/project" -c user.name=Lab -c user.email=lab@example.invalid commit --allow-empty -qm initial
git -C "$D/project" worktree add -qb fm/recover "$D/worker"
printf 'committed preserved\n' > "$D/worker/saved.txt"
git -C "$D/worker" add saved.txt
git -C "$D/worker" -c user.name=Lab -c user.email=lab@example.invalid commit -qm saved
printf 'dirty preserved\n' >> "$D/worker/saved.txt"
printf 'untracked preserved\n' > "$D/worker/untracked.txt"
mkdir -p "$LAB/data/recover"
printf "# Task\n## Captain's intent\nPreserve all existing work.\n\n## Firstmate spec\nContinue the existing task.\n" > "$LAB/data/recover/brief.md"
cat > "$LAB/state/recover.meta" <<EOF
window=vanished:fm-recover
endpoint_task_id=recover
worktree=$D/worker
project=$D/project
harness=claude
kind=ship
mode=no-mistakes
yolo=off
tasktmp=$D/tasktmp
model=default
effort=default
branch=fm/recover
EOF
printf '\n=== missing endpoint exit proof ===\n'
bin/fm-control.sh recover exit
printf '\n=== missing endpoint relaunch ===\n'
before=$(git -C "$D/worker" rev-parse HEAD)
bin/fm-control.sh recover relaunch --note 'Resume saved commits and unfinished files.'
printf '\n=== durable record and preserved work ===\n'
cat "$LAB/state/recover.meta"
git -C "$D/worker" status --short
cat "$D/worker/saved.txt" "$D/worker/untracked.txt"
test "$(git -C "$D/worker" rev-parse HEAD)" = "$before"
test "$(git -C "$D/worker" branch --show-current)" = fm/recover
printf '\n=== actual terminal ===\n'
target=$(awk -F= '$1=="window"{print $2}' "$LAB/state/recover.meta")
tmux -S "$SOCK" capture-pane -p -t "$target"
