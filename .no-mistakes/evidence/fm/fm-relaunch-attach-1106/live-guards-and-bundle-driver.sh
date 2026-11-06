#!/usr/bin/env bash
set -eu
ROOT=$PWD
E=~/.no-mistakes/evidence/01M6RYKTPNQ9PK751MTJ97Z0ZR
LAB="$ROOT/.v"
export FM_HOME="$LAB" HOME="$LAB/user" TMPDIR="$LAB/tmp" CODEX_HOME="$LAB/codex" TMUX_TMPDIR="$LAB/tmux" TREEHOUSE_ROOT="$LAB/pool"
export CLAUDE_CONFIG_DIR="$LAB/user" DISABLE_AUTOUPDATER=1
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS HERDR_ENV HERDR_SESSION HERDR_PANE_ID TMUX TMUX_PANE
hidden=
cleanup() {
  [ -z "$hidden" ] || { kill "$hidden" 2>/dev/null || true; wait "$hidden" 2>/dev/null || true; }
  tmux -L fm-other kill-server 2>/dev/null || true
  tmux -L fm-lab kill-server 2>/dev/null || true
}
trap cleanup EXIT
tmux -f /dev/null -L fm-lab new-session -d -x 120 -y 40 -s primary -c "$ROOT"
export TMUX="$(tmux -L fm-lab display-message -p -t primary '#{socket_path}'),$(tmux -L fm-lab display-message -p -t primary '#{pid}'),0"
export TMUX_PANE=$(tmux -L fm-lab display-message -p -t primary '#{pane_id}')
touch "$LAB/state/.last-watcher-beat"
brief() {
  mkdir -p "$LAB/data/$1"
  printf '# Task\n## Captain\x27s intent\nRecover preserved work for %s.\n\n## Firstmate spec\nThis is a local lifecycle validation fixture. Do not edit or execute any project files.\n\n## Setup\nShip branch: fm/%s\nDelivery contract: mode=no-mistakes\n' "$1" "$1" > "$LAB/data/$1/brief.md"
}
seed() {
  local id=$1
  if [ ! -d "$LAB/$id" ]; then git -C "$LAB/project" worktree add -q -b "fm/$id" "$LAB/$id" main; fi
  brief "$id"
  printf 'window=gone-session:fm-%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\nharness=codex\nkind=ship\nmode=no-mistakes\nyolo=off\nmodel=default\neffort=default\nbranch=fm/%s\n' "$id" "$id" "$LAB/$id" "$LAB/project" "$id" > "$LAB/state/$id.meta"
}
run() {
  local log=$1; shift
  printf '\n$ %q ' "$1" >> "$E/$log"; printf '%q ' "${@:2}" >> "$E/$log"; printf '\n' >> "$E/$log"
  set +e
  "$@" >> "$E/$log" 2>&1
  RC=$?
  set -e
  printf 'exit=%s\n' "$RC" >> "$E/$log"
}
unchanged() { sha256sum -c "$LAB/checks" >> "$E/$1"; }
# Gone exit is observational, not a rebind or a teardown.
seed live-exit
sha256sum "$LAB/state/live-exit.meta" "$LAB/data/live-exit/brief.md" > "$LAB/checks"
run gone-exit.log "$ROOT/bin/fm-control.sh" live-exit exit
[ "$RC" = 0 ]; unchanged gone-exit.log
! tmux -L fm-lab list-windows -a -F '#{window_name}' | grep -qx fm-live-exit
# An agent on another socket must be refused by cwd evidence, then argv evidence.
seed live-guard
sha256sum "$LAB/state/live-guard.meta" "$LAB/data/live-guard/brief.md" > "$LAB/checks"
tmux -f /dev/null -L fm-other new-session -d -x 120 -y 40 -s foreign -n owner -c "$ROOT"
tmux -L fm-other send-keys -t foreign "cd '$LAB/live-guard'; exec sleep 300" Enter
sleep 1
run foreign-owner.log "$ROOT/bin/fm-control.sh" live-guard relaunch --note 'Must refuse foreign cwd owner.'
[ "$RC" != 0 ]; grep -q 'working in the recorded worktree' "$E/foreign-owner.log"; unchanged foreign-owner.log
run foreign-owner.log "$ROOT/bin/fm-control.sh" live-guard exit
[ "$RC" != 0 ]; unchanged foreign-owner.log
tmux -L fm-other kill-server
# Keep argv owner outside the worktree so this specifically tests task-token evidence.
tmux -f /dev/null -L fm-other new-session -d -x 120 -y 40 -s foreign -n owner -c "$ROOT" "bash -c 'exec -a fm-live-guard sleep 300'"
sleep 1
run foreign-owner.log "$ROOT/bin/fm-control.sh" live-guard relaunch --note 'Must refuse foreign argv owner.'
[ "$RC" != 0 ]; grep -q 'names the task in its arguments' "$E/foreign-owner.log"; unchanged foreign-owner.log
tmux -L fm-other kill-server
# Same name on another session of the addressed socket is not absence.
tmux -L fm-lab new-session -d -s neighbor -n fm-live-guard -c "$ROOT"
run name-collision.log "$ROOT/bin/fm-control.sh" live-guard relaunch --note 'Must refuse duplicate label.'
[ "$RC" != 0 ]; grep -q 'still in the window inventory' "$E/name-collision.log"; unchanged name-collision.log
tmux -L fm-lab kill-session -t neighbor
# A real undumpable, non-allowlisted process must fail closed.
python3 -c 'import ctypes,time; assert ctypes.CDLL(None).prctl(4,0)==0; time.sleep(300)' &
hidden=$!
sleep 1
printf 'undumpable process pid=%s; cwd read follows\n' "$hidden" > "$E/unreadable-process.log"
if readlink "/proc/$hidden/cwd" >> "$E/unreadable-process.log" 2>&1; then echo 'setup failed: cwd readable' >&2; exit 1; fi
run unreadable-process.log "$ROOT/bin/fm-control.sh" live-guard relaunch --note 'Must refuse unreadable process.'
[ "$RC" != 0 ]; grep -q "working directory of process $hidden could not be read" "$E/unreadable-process.log"; unchanged unreadable-process.log
kill "$hidden"; wait "$hidden" 2>/dev/null || true; hidden=
# Post-create pre-publication failure must remove only the replacement, allowing retry.
seed live-retry
sha256sum "$LAB/state/live-retry.meta" > "$LAB/checks"
printf 'invalid json\n' > "$HOME/.claude.json"
run retry-cleanup.log "$ROOT/bin/fm-control.sh" live-retry relaunch --harness claude --note 'Trust failure must clean replacement.'
[ "$RC" != 0 ]; grep -q 'could not pre-register Claude workspace trust' "$E/retry-cleanup.log"; unchanged retry-cleanup.log
if tmux -L fm-lab list-windows -a -F '#{window_name}' | grep -qx fm-live-retry; then echo 'replacement leaked' >&2; exit 1; fi
printf 'unused replacement absent after trust refusal\n' >> "$E/retry-cleanup.log"
rm "$HOME/.claude.json"
run retry-cleanup.log "$ROOT/bin/fm-control.sh" live-retry relaunch --note 'Retry on original codex harness.'
[ "$RC" = 0 ]
tmux -L fm-lab list-windows -a -F '#{session_name}:#{window_name} command=#{pane_current_command} path=#{pane_current_path}' >> "$E/retry-cleanup.log"
cp "$LAB/state/live-retry.meta" "$E/retry-meta.txt"
tmux -L fm-lab kill-window -t primary:fm-live-retry
# Build an unpublished preserved commit and a relative bundle containing spaces.
git clone -q "$LAB/project" "$LAB/publisher"
git -C "$LAB/publisher" checkout -qb fm/live-bundle main
printf 'unpublished preserved bundle work\n' > "$LAB/publisher/preserved.txt"
git -C "$LAB/publisher" add preserved.txt
git -C "$LAB/publisher" -c user.name=Lab -c user.email=lab@example.invalid commit -qm preserved-bundle
head=$(git -C "$LAB/publisher" rev-parse HEAD)
mkdir -p "$LAB/data/bundles"
git -C "$LAB/publisher" bundle create "$LAB/data/bundles/saved work.bundle" HEAD
brief live-bundle
(cd "$LAB" && "$ROOT/bin/fm-spawn.sh" live-bundle "$LAB/project" --mode no-mistakes --yolo off --harness codex --backend tmux --attach-branch fm/live-bundle --attach-head "$head" --attach-bundle 'data/bundles/saved work.bundle') > "$E/bundle-attach.log" 2>&1
printf 'spawn exit=0\nexpected head=%s\n' "$head" >> "$E/bundle-attach.log"
wt=$(awk -F= '$1=="worktree" {print substr($0,10)}' "$LAB/state/live-bundle.meta")
[ "$(git -C "$wt" rev-parse HEAD)" = "$head" ]; [ "$(git -C "$wt" branch --show-current)" = fm/live-bundle ]
[ "$(cat "$wt/preserved.txt")" = 'unpublished preserved bundle work' ]
git -C "$wt" show --stat HEAD >> "$E/bundle-attach.log"
cp "$LAB/state/live-bundle.meta" "$E/bundle-meta.txt"
sleep 3
tmux -L fm-lab capture-pane -p -t primary:fm-live-bundle > "$E/bundle-pane.txt"
tmux -L fm-lab kill-window -t primary:fm-live-bundle
printf 'All requested live-more assertions passed.\n'
