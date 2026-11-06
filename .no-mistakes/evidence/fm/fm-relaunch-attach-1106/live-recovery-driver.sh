#!/usr/bin/env bash
set -eu
ROOT=$PWD
E=~/.no-mistakes/evidence/01M6RYKTPNQ9PK751MTJ97Z0ZR
LAB="$ROOT/.v"
mkdir -p "$LAB"
"$ROOT/bin/fm-lab-home.sh" create "$LAB"
mkdir -p "$LAB/tmux" "$LAB/user" "$LAB/tmp" "$LAB/codex"
export FM_HOME="$LAB" HOME="$LAB/user" TMPDIR="$LAB/tmp" CODEX_HOME="$LAB/codex" TMUX_TMPDIR="$LAB/tmux"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS HERDR_ENV HERDR_SESSION HERDR_PANE_ID TMUX TMUX_PANE
cleanup() { tmux -L fm-lab kill-server 2>/dev/null || true; }
trap cleanup EXIT
touch "$LAB/config/supervision-host"
tmux -f /dev/null -L fm-lab new-session -d -x 120 -y 40 -s primary -c "$ROOT"
export TMUX="$(tmux -L fm-lab display-message -p -t primary '#{socket_path}'),$(tmux -L fm-lab display-message -p -t primary '#{pid}'),0"
export TMUX_PANE=$(tmux -L fm-lab display-message -p -t primary '#{pane_id}')
# TMUX pins all product adapter calls to this lab socket.
git init -q -b main "$LAB/project"
printf 'base\n' > "$LAB/project/base.txt"
git -C "$LAB/project" add base.txt
git -C "$LAB/project" -c user.name=Lab -c user.email=lab@example.invalid commit -qm base
git -C "$LAB/project" worktree add -q -b fm/live-recover "$LAB/wt"
printf 'committed recovery work\n' > "$LAB/wt/work.txt"
git -C "$LAB/wt" add work.txt
git -C "$LAB/wt" -c user.name=Lab -c user.email=lab@example.invalid commit -qm preserved
printf 'unfinished recovery work\n' >> "$LAB/wt/work.txt"
mkdir -p "$LAB/data/live-recover"
printf '# Task\n## Captain\x27s intent\nRecover preserved work.\n\n## Firstmate spec\nDo not change files; this is a disposable validation lab.\n' > "$LAB/data/live-recover/brief.md"
printf 'window=gone-session:fm-live-recover\nendpoint_task_id=live-recover\nworktree=%s\nproject=%s\nharness=codex\nkind=ship\nmode=no-mistakes\nyolo=off\nmodel=default\neffort=default\nbranch=fm/live-recover\n' "$LAB/wt" "$LAB/project" > "$LAB/state/live-recover.meta"
cp "$LAB/state/live-recover.meta" "$LAB/before.meta"
git -C "$LAB/wt" rev-parse HEAD > "$LAB/before.head"
sha256sum "$LAB/wt/work.txt" > "$LAB/before.work"
set +e
"$ROOT/bin/fm-control.sh" live-recover relaunch --note 'Continue preserved work; local lifecycle validation only.' > "$E/recovery.log" 2>&1
rc=$?
set -e
printf 'control exit=%s\n' "$rc" | tee -a "$E/recovery.log"
cat "$E/recovery.log"
tmux -L fm-lab list-windows -a -F '#{session_name}:#{window_name} path=#{pane_current_path} command=#{pane_current_command}' | tee -a "$E/recovery.log"
cp "$LAB/state/live-recover.meta" "$E/recovery-meta.txt"
[ "$rc" = 0 ] || exit 1
[ "$(git -C "$LAB/wt" rev-parse HEAD)" = "$(cat "$LAB/before.head")" ]
sha256sum -c "$LAB/before.work" | tee -a "$E/recovery.log"
[ "$(git -C "$LAB/wt" branch --show-current)" = fm/live-recover ]
grep -Fxq 'window=primary:fm-live-recover' "$LAB/state/live-recover.meta"
grep -Fxq "worktree=$LAB/wt" "$LAB/state/live-recover.meta"
grep -Fxq "project=$LAB/project" "$LAB/state/live-recover.meta"
printf 'Preserved branch=%s; before HEAD=%s; after HEAD=%s\n' "$(git -C "$LAB/wt" branch --show-current)" "$(cat "$LAB/before.head")" "$(git -C "$LAB/wt" rev-parse HEAD)" | tee -a "$E/recovery.log"
printf 'Before file checksum: ' >> "$E/recovery.log"; cat "$LAB/before.work" >> "$E/recovery.log"
printf 'After file checksum: ' >> "$E/recovery.log"; sha256sum "$LAB/wt/work.txt" >> "$E/recovery.log"
git -C "$LAB/wt" status --short >> "$E/recovery.log"
sleep 3
tmux -L fm-lab capture-pane -p -t primary:fm-live-recover > "$E/recovery-pane.txt"
cat "$E/recovery-pane.txt"
