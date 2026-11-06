#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
L=$ROOT/.live
LAB=$L/home
bin/fm-lab-home.sh create "$LAB"
mkdir -p "$L/user" "$L/project" "$L/wtparent"
git init -q -b main "$L/project"
printf 'base\n' > "$L/project/README.md"
git -C "$L/project" add .
git -C "$L/project" -c user.name=Lab -c user.email=lab@example.invalid commit -qm base
for id in gateattach11 gateattach12 gateattach13; do
 git -C "$L/project" worktree add -q -b "fm/$id" "$L/wtparent/$id" main
 printf 'saved committed work\n' > "$L/wtparent/$id/saved.txt"
 git -C "$L/wtparent/$id" add .
 git -C "$L/wtparent/$id" -c user.name=Lab -c user.email=lab@example.invalid commit -qm preserved
 printf 'unfinished changes\n' >> "$L/wtparent/$id/saved.txt"
 mkdir -p "$LAB/data/$id"
 printf '# Task\n## Captain intent\nPreserve saved work and report state. Do not modify files.\n' > "$LAB/data/$id/brief.md"
 printf 'window=gone-session:fm-%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\nharness=codex\nkind=ship\nmode=local-only\nyolo=off\nbranch=fm/%s\nmodel=default\neffort=default\n' "$id" "$id" "$L/wtparent/$id" "$L/project" "$id" > "$LAB/state/$id.meta"
done
HOME="$L/user" tmux -S "$L/s" -f /dev/null new-session -d -s lab -x 120 -y 35 -c "$ROOT" 'bash --noprofile --norc'
HOME="$L/user" tmux -S "$L/s" show-environment -g
