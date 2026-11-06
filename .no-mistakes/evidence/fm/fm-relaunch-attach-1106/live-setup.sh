#!/usr/bin/env bash
set -eu
ROOT=$PWD
LAB="$ROOT/.l"
bin/fm-lab-home.sh create "$LAB"
mkdir -p "$LAB/tmux" "$LAB/user" "$LAB/data/recover1106"
touch "$LAB/config/supervision-host"
git init -q "$LAB/projects/demo"
git -C "$LAB/projects/demo" config user.name 'Live lab'
git -C "$LAB/projects/demo" config user.email 'lab@example.invalid'
printf 'initial\n' > "$LAB/projects/demo/task.txt"
git -C "$LAB/projects/demo" add task.txt
git -C "$LAB/projects/demo" commit -qm initial
git -C "$LAB/projects/demo" worktree add -qb preserved1106 "$LAB/worker"
printf 'committed work\n' >> "$LAB/worker/task.txt"
git -C "$LAB/worker" commit -qam preserved
printf 'unfinished work\n' >> "$LAB/worker/task.txt"
printf 'staged work\n' > "$LAB/worker/staged.txt"
git -C "$LAB/worker" add staged.txt
printf 'untracked work\n' > "$LAB/worker/untracked.txt"
printf '# Task\n## Captain intent\nPreserve existing work. This is a disposable validation lab. Do not change any files or run tools; wait for instructions.\n## Firstmate spec\nWait.\n' > "$LAB/data/recover1106/brief.md"
printf 'window=vanished1106:fm-recover1106\nendpoint_task_id=recover1106\nworktree=%s/worker\nproject=%s/projects/demo\nharness=claude\nkind=ship\nmode=local-only\nyolo=off\ntasktmp=%s/tasktmp\nmodel=default\neffort=default\n' "$LAB" "$LAB" "$LAB" > "$LAB/state/recover1106.meta"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -s primary -x 120 -y 35 -c "$ROOT" -e FM_HOME="$LAB" -e HOME="$LAB/user" -e CLAUDE_CONFIG_DIR="$LAB/user/.claude" claude
TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab display-message -p -t primary '#{socket_path}' > "$LAB/socket"
