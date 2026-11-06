#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$PWD
E=~/.no-mistakes/evidence/01M6RPFXHTW1NQSVW9CCG0410C
LAB=$ROOT/.l
mkdir -p "$LAB"
bin/fm-lab-home.sh create "$LAB/h" >/dev/null
mkdir -p "$LAB/t" "$LAB/u"
export FM_HOME=$LAB/h HOME=$LAB/u TMUX_TMPDIR=$LAB/t
export FM_SPAWN_NO_GUARD=1 TREEHOUSE_ROOT=$LAB/pool
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE HERDR_ENV HERDR_PANE_ID HERDR_SESSION HERDR_SOCKET_PATH HERDR_TAB_ID HERDR_WORKSPACE_ID TMUX CLAUDE_CONFIG_DIR
cleanup() {
  tmux -L fm-lab kill-server 2>/dev/null || true
  tmux -L fm-foreign kill-server 2>/dev/null || true
  chmod -R u+w "$LAB" 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT
# Each real tmux pane has a non-zero 120x35 grid.
tmux -L fm-lab new-session -d -s recover -x 120 -y 35 -c "$ROOT"
export TMUX=$(tmux -L fm-lab display-message -p '#{socket_path}'),$(tmux -L fm-lab display-message -p '#{pid}'),0
export FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=5 FM_CONTROL_LAUNCH_WAIT=15
printf 'claude\n' > "$FM_HOME/config/crew-harness"
touch "$FM_HOME/config/supervision-host"
git init -q -b main "$LAB/proj"
printf 'baseline\n' > "$LAB/proj/README"
git -C "$LAB/proj" add README
git -C "$LAB/proj" -c user.name=Lab -c user.email=lab@example.invalid commit -qm base
P=$LAB/proj
mkrecord() {
 local id=$1 endpoint=$2
 git -C "$P" worktree add -qb "fm/$id" "$LAB/$id" HEAD
 mkdir -p "$FM_HOME/data/$id"
 printf '# Task\n## Captain\x27s intent\nPreserve local work; do not call tools or modify files.\n## Firstmate spec\nWait for the operator.\n' > "$FM_HOME/data/$id/brief.md"
 printf 'window=%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\nharness=claude\nkind=ship\nmode=local-only\nyolo=off\nmodel=default\neffort=default\n' "$endpoint" "$id" "$LAB/$id" "$P" > "$FM_HOME/state/$id.meta"
}
call() { printf '\n$ '; printf '%q ' "$@"; printf '\n'; set +e; "$@"; RC=$?; set -e; printf 'exit=%s\n' "$RC"; }
field() { awk -F= -v k="$2" '$1==k {sub(/^[^=]*=/, ""); print}' "$FM_HOME/state/$1.meta"; }
assert_rc() { [ "$RC" = "$1" ] || { echo "ASSERT expected exit $1"; exit 1; }; }
# Scenario 1: missing window; preserves committed and dirty state, endpoint rebounds.
id=lv-record-window
mkrecord "$id" recover:fm-$id
printf 'committed work\n' > "$LAB/$id/saved"
git -C "$LAB/$id" add saved
git -C "$LAB/$id" -c user.name=Lab -c user.email=lab@example.invalid commit -qm saved
printf 'dirty tracked\n' >> "$LAB/$id/README"
printf 'untracked\n' > "$LAB/$id/untracked"
head=$(git -C "$LAB/$id" rev-parse HEAD)
before=$(git -C "$LAB/$id" diff; sha256sum "$LAB/$id/untracked")
call bin/fm-control.sh "$id" relaunch --note 'Recover preserved work without starting another task.'
assert_rc 0
[ "$(field "$id" worktree)" = "$LAB/$id" ]
[ "$(git -C "$LAB/$id" rev-parse HEAD)" = "$head" ]
[ "$(git -C "$LAB/$id" symbolic-ref --short HEAD)" = "fm/$id" ]
[ "$(git -C "$LAB/$id" diff; sha256sum "$LAB/$id/untracked")" = "$before" ]
printf 'recorded HEAD=%s branch=%s worktree=%s endpoint=%s\n' "$head" "$(git -C "$LAB/$id" symbolic-ref --short HEAD)" "$(field "$id" worktree)" "$(field "$id" window)"
sleep 2
tmux -L fm-lab capture-pane -p -t "recover:fm-$id"
tmux -L fm-lab kill-window -t "recover:fm-$id"
echo 'PASS missing-window relaunch preserves committed, dirty and untracked work'
# Scenario 2: missing session, abort before publication, cleanup, immediate retry.
id=lv-record-session
mkrecord "$id" destroyed:fm-$id
old=$(sha256sum "$FM_HOME/state/$id.meta")
export CLAUDE_CONFIG_DIR=$LAB/failconfig
mkdir -p "$CLAUDE_CONFIG_DIR"
printf 'not json\n' > "$CLAUDE_CONFIG_DIR/.claude.json"
call bin/fm-spawn.sh "$id" --relaunch
assert_rc 1
[ "$(sha256sum "$FM_HOME/state/$id.meta")" = "$old" ]
! tmux -L fm-lab list-windows -a -F '#{window_name}' | grep -Fx "fm-$id"
echo 'Failed trust registration left old record unchanged and removed its unused replacement window'
rm "$CLAUDE_CONFIG_DIR/.claude.json"
call bin/fm-control.sh "$id" relaunch --note 'Retry after fixing disposable trust store.'
assert_rc 0
[ "$(field "$id" window)" = "recover:fm-$id" ]
printf 'new endpoint=%s\n' "$(field "$id" window)"
tmux -L fm-lab kill-window -t "recover:fm-$id"
echo 'PASS missing-session cleanup and retry'
# Scenario 3: a same-named window elsewhere on this server blocks duplicate spawn.
id=lv-window-guard
mkrecord "$id" missing:fm-$id
tmux -L fm-lab new-session -d -s elsewhere -n "fm-$id" -x 120 -y 35 -c "$ROOT"
old=$(sha256sum "$FM_HOME/state/$id.meta")
call bin/fm-control.sh "$id" relaunch --note 'Must refuse duplicate ownership.'
assert_rc 1
[ "$(sha256sum "$FM_HOME/state/$id.meta")" = "$old" ]
tmux -L fm-lab kill-session -t elsewhere
echo 'PASS same-named foreign-session window refuses without changing record'
# Scenario 4: a process on an unaddressed real tmux socket owns worktree/task.
id=lv-process-guard
mkrecord "$id" vanished:fm-$id
old=$(sha256sum "$FM_HOME/state/$id.meta")
tmux -L fm-foreign new-session -d -s foreign -x 120 -y 35 -c "$ROOT" 'exec bash --noprofile --norc'
tmux -L fm-foreign send-keys -t foreign "cd '$LAB/$id'; exec sleep 300" Enter
sleep 0.3
call bin/fm-control.sh "$id" relaunch --note 'Must refuse surviving owner on another socket.'
assert_rc 1
[ "$(sha256sum "$FM_HOME/state/$id.meta")" = "$old" ]
tmux -L fm-foreign kill-server
# Same process with neutral cwd but task-id as an argument.
tmux -L fm-foreign new-session -d -s foreign -x 120 -y 35 -c "$ROOT" "bash -c 'sleep 300 & wait' $id"
call bin/fm-spawn.sh "$id" --relaunch
assert_rc 1
[ "$(sha256sum "$FM_HOME/state/$id.meta")" = "$old" ]
tmux -L fm-foreign kill-server
echo 'PASS live processes on an unseen socket refuse by cwd and task token'
echo 'RECORDED_SCENARIOS_DONE'
