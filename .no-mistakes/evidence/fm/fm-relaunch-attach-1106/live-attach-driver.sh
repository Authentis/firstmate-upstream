#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$PWD
LAB=$ROOT/.a
mkdir -p "$LAB"
bin/fm-lab-home.sh create "$LAB/h" >/dev/null
mkdir -p "$LAB/t" "$LAB/u"
export FM_HOME=$LAB/h HOME=$LAB/u TMUX_TMPDIR=$LAB/t FM_SPAWN_NO_GUARD=1 TREEHOUSE_ROOT=$LAB/pool
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE HERDR_ENV HERDR_PANE_ID HERDR_SESSION HERDR_SOCKET_PATH HERDR_TAB_ID HERDR_WORKSPACE_ID TMUX CLAUDE_CONFIG_DIR
cleanup() { tmux -L fm-lab kill-server 2>/dev/null || true; chmod -R u+w "$LAB" 2>/dev/null || true; cd "$ROOT"; rm -rf "$LAB"; }
trap cleanup EXIT
tmux -L fm-lab new-session -d -s attach -x 120 -y 35 -c "$ROOT"
export TMUX=$(tmux -L fm-lab display-message -p '#{socket_path}'),$(tmux -L fm-lab display-message -p '#{pid}'),0
printf 'claude\n' > "$FM_HOME/config/crew-harness"
touch "$FM_HOME/config/supervision-host"
P=$LAB/proj
git init -q -b main "$P"
printf 'baseline\n' > "$P/README"
git -C "$P" add README
git -C "$P" -c user.name=Lab -c user.email=lab@example.invalid commit -qm base
base=$(git -C "$P" rev-parse HEAD)
# Independent preserved history, never present in the operational project.
git clone -q "$P" "$LAB/saved"
git -C "$LAB/saved" checkout -qb fm/restore
printf 'history that must survive\n' > "$LAB/saved/preserved"
git -C "$LAB/saved" add preserved
git -C "$LAB/saved" -c user.name=Lab -c user.email=lab@example.invalid commit -qm preserved
head=$(git -C "$LAB/saved" rev-parse HEAD)
mkdir -p "$FM_HOME/data/bundles"
git -C "$LAB/saved" bundle create "$FM_HOME/data/bundles/preserved work.bundle" HEAD
brief() { mkdir -p "$FM_HOME/data/$1"; printf '# Task\n## Captain\x27s intent\nPreserve the attached branch and wait; do not modify files.\n## Firstmate spec\nWait for operator instruction.\n' > "$FM_HOME/data/$1/brief.md"; }
call() { printf '\n$ '; printf '%q ' "$@"; printf '\n'; set +e; "$@"; RC=$?; set -e; printf 'exit=%s\n' "$RC"; }
field() { awk -F= -v k="$2" '$1==k {sub(/^[^=]*=/, ""); print}' "$FM_HOME/state/$1.meta"; }
assert_rc() { [ "$RC" = "$1" ] || { echo "ASSERT expected exit $1"; exit 1; }; }
cd "$FM_HOME"
# Scenario 5: relative bundle path including a space, originless project.
id=lv-bundle-attach
brief "$id"
! git -C "$P" cat-file -e "$head^{commit}" 2>/dev/null
call "$ROOT/bin/fm-spawn.sh" "$id" "$P" --mode local-only --yolo off --harness claude --attach-branch "fm/$id" --attach-head "$head" --attach-bundle 'data/bundles/preserved work.bundle'
assert_rc 0
wt=$(field "$id" worktree)
[ "$(git -C "$wt" rev-parse HEAD)" = "$head" ]
[ "$(git -C "$wt" symbolic-ref --short HEAD)" = "fm/$id" ]
[ "$(cat "$wt/preserved")" = 'history that must survive' ]
printf 'Restored HEAD=%s branch=%s worktree=%s\n' "$head" "$(git -C "$wt" symbolic-ref --short HEAD)" "$wt"
cat "$wt/preserved"
sleep 2
tmux -L fm-lab capture-pane -p -t "attach:fm-$id"
tmux -L fm-lab kill-window -t "attach:fm-$id"
echo 'PASS originless relative bundle attach restores exact head and branch'
# Scenario 6: prelaunch failure restores pooled copy and deletes only new branch, retry works.
id=lv-attach-retry
brief "$id"
export CLAUDE_CONFIG_DIR=$LAB/failconfig
mkdir -p "$CLAUDE_CONFIG_DIR"
printf 'not json\n' > "$CLAUDE_CONFIG_DIR/.claude.json"
call "$ROOT/bin/fm-spawn.sh" "$id" "$P" --mode local-only --yolo off --harness claude --attach-branch "fm/$id" --attach-head "$head"
assert_rc 1
[ ! -e "$FM_HOME/state/$id.meta" ]
! git -C "$P" show-ref --verify --quiet "refs/heads/fm/$id"
# Fresh spawns retain their shell for diagnosis; close it before retrying.
git -C "$P" worktree list --porcelain
failedwt=$(git -C "$P" worktree list --porcelain | awk '/^worktree / {sub(/^worktree /, ""); p=$0} END {print p}')
[ "$(git -C "$failedwt" rev-parse HEAD)" = "$base" ]
! git -C "$failedwt" symbolic-ref -q HEAD
printf 'After failed attach: pooled HEAD=%s detached, task branch absent, record absent\n' "$(git -C "$failedwt" rev-parse HEAD)"
tmux -L fm-lab kill-window -t "attach:fm-$id" 2>/dev/null || true
rm "$CLAUDE_CONFIG_DIR/.claude.json"
call "$ROOT/bin/fm-spawn.sh" "$id" "$P" --mode local-only --yolo off --harness claude --attach-branch "fm/$id" --attach-head "$head"
assert_rc 0
wt=$(field "$id" worktree)
[ "$(git -C "$wt" rev-parse HEAD)" = "$head" ]
[ "$(git -C "$wt" symbolic-ref --short HEAD)" = "fm/$id" ]
printf 'Retry HEAD=%s branch=%s\n' "$(git -C "$wt" rev-parse HEAD)" "$(git -C "$wt" symbolic-ref --short HEAD)"
tmux -L fm-lab kill-window -t "attach:fm-$id"
echo 'PASS failed fresh attach rolls back checkout and created branch; retry succeeds'
# Scenario 7: origin has same branch elsewhere, hidden behind a narrow fetch refspec.
id=lv-origin-guard
brief "$id"
git clone -q --bare "$P" "$LAB/origin.git"
git -C "$P" remote add origin "file://$LAB/origin.git"
git -C "$P" config remote.origin.fetch '+refs/heads/main:refs/remotes/origin/main'
git --git-dir="$LAB/origin.git" update-ref "refs/heads/fm/$id" "$base"
refs=$(git -C "$P" for-each-ref --format='%(refname) %(objectname)' refs/heads)
call "$ROOT/bin/fm-spawn.sh" "$id" "$P" --mode local-only --yolo off --harness claude --attach-branch "fm/$id" --attach-head "$head"
assert_rc 1
[ ! -e "$FM_HOME/state/$id.meta" ]
[ "$(git -C "$P" for-each-ref --format='%(refname) %(objectname)' refs/heads)" = "$refs" ]
! tmux -L fm-lab list-windows -a -F '#{window_name}' | grep -Fx "fm-$id"
echo 'PASS conflicting origin branch refuses before endpoint, record or branch mutation'
echo 'ATTACH_SCENARIOS_DONE'
cd "$ROOT"
