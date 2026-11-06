#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD; D="$ROOT/.live-validation/attach"; mkdir -p "$D"
export HOME="$D/user" CLAUDE_CONFIG_DIR="$D/user/claude" XDG_CONFIG_HOME="$D/user/config" XDG_DATA_HOME="$D/user/data" XDG_CACHE_HOME="$D/user/cache" TMPDIR="$D/tmp" TREEHOUSE_ROOT="$D/pool"
mkdir -p "$HOME" "$CLAUDE_CONFIG_DIR" "$TMPDIR"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE HERDR_ENV HERDR_PANE_ID HERDR_SESSION HERDR_SOCKET_PATH HERDR_TAB_ID HERDR_WORKSPACE_ID
export FM_HOME="$D/home"
"$ROOT/bin/fm-lab-home.sh" create "$FM_HOME"
mkdir -p "$FM_HOME/tmux"; touch "$FM_HOME/config/supervision-host" "$FM_HOME/state/.last-watcher-beat"
SOCK=.live-validation/socket/a
export TMUX="$SOCK,0,0"
cleanup() { cd "$ROOT"; tmux -S "$SOCK" kill-server 2>/dev/null || true; }
trap cleanup EXIT
tmux -S "$SOCK" new-session -d -s fm-lab-attach -n primary -x 100 -y 30 -c "$ROOT"
git init -qb main "$D/project"
printf 'base\n' > "$D/project/base.txt"
git -C "$D/project" add base.txt
git -C "$D/project" -c user.name=Lab -c user.email=lab@example.invalid commit -qm base
BASE=$(git -C "$D/project" rev-parse HEAD)
git clone -q --bare "$D/project" "$D/origin.git"
git -C "$D/project" remote add origin "$D/origin.git"
git clone -q "$D/origin.git" "$D/publisher"
git -C "$D/publisher" checkout -qb saved
printf 'history recovered from bundle\n' > "$D/publisher/preserved.txt"
git -C "$D/publisher" add preserved.txt
git -C "$D/publisher" -c user.name=Lab -c user.email=lab@example.invalid commit -qm preserved
HEAD_SAVED=$(git -C "$D/publisher" rev-parse HEAD)
mkdir -p "$FM_HOME/data/bundles"
git -C "$D/publisher" bundle create -q "$FM_HOME/data/bundles/saved work.bundle" HEAD
! git -C "$D/project" cat-file -e "$HEAD_SAVED^{commit}" 2>/dev/null
brief() {
 mkdir -p "$FM_HOME/data/$1"
 printf "# Task\n## Captain's intent\nResume the saved branch without losing any work.\n\n## Firstmate spec\nUse the preserved head and keep its branch identity.\n\n# Setup\nShip branch: fm/%s\nDelivery contract: mode=no-mistakes\n" "$1" > "$FM_HOME/data/$1/brief.md"
}
spawn() { "$ROOT/bin/fm-spawn.sh" "$1" "$D/project" --harness claude --mode no-mistakes --yolo off "${@:2}"; }
refuse() {
 local id=$1 expected=$2; shift 2
 brief "$id"; local out rc before
 before=$(git -C "$D/project" for-each-ref --format='%(refname) %(objectname)')
 set +e; out=$(spawn "$id" "$@" 2>&1); rc=$?; set -e
 printf '%s\nexit=%s\n' "$out" "$rc"
 test "$rc" != 0; [[ "$out" == *"$expected"* ]]; test ! -f "$FM_HOME/state/$id.meta"
 test "$(git -C "$D/project" for-each-ref --format='%(refname) %(objectname)')" = "$before"
}
printf '\n=== Wrong bundle head refuses without an endpoint ===\n'
refuse badhead 'is not a head of bundle' --attach-branch fm/badhead --attach-head 0123456789abcdef0123456789abcdef01234567 --attach-bundle "$FM_HOME/data/bundles/saved work.bundle"
printf '\n=== Existing branch at another commit refuses without moving it ===\n'
git -C "$D/project" branch fm/conflict "$BASE"
refuse conflict 'already exists at' --attach-branch fm/conflict --attach-head "$HEAD_SAVED" --attach-bundle "$FM_HOME/data/bundles/saved work.bundle"
printf '\n=== Origin branch conflict is visible even with narrow fetch refspec ===\n'
git -C "$D/publisher" push -q origin "$BASE:refs/heads/fm/remote-conflict"
git -C "$D/project" config remote.origin.fetch '+refs/heads/main:refs/remotes/origin/main'
refuse remote-conflict 'already exists on origin at' --attach-branch fm/remote-conflict --attach-head "$HEAD_SAVED" --attach-bundle "$FM_HOME/data/bundles/saved work.bundle"
test "$(tmux -S "$SOCK" list-windows -a -F '#{window_name}' | wc -l)" = 1
printf '\n=== Relative bundle with spaces restores exact branch and commit ===\n'
brief bundle-restore
# The caller changes directory, so address the same private socket by a short proc cwd alias.
# This /proc path is only an address for the socket already under the worktree.
export TMUX="/proc/$$/cwd/$SOCK,0,0"
(cd "$FM_HOME"; spawn bundle-restore --attach-branch fm/bundle-restore --attach-head "$HEAD_SAVED" --attach-bundle 'data/bundles/saved work.bundle')
cat "$FM_HOME/state/bundle-restore.meta"
WT=$(awk -F= '$1=="worktree"{print $2}' "$FM_HOME/state/bundle-restore.meta")
test "$(git -C "$WT" rev-parse HEAD)" = "$HEAD_SAVED"
test "$(git -C "$WT" branch --show-current)" = fm/bundle-restore
cat "$WT/preserved.txt"
sleep 3
printf '\n=== Real Claude started on restored branch (disposable HOME, no authentication claimed) ===\n'
tmux -S "$SOCK" capture-pane -p -t fm-lab-attach:fm-bundle-restore
# Stop this lab worker before deliberately damaging the shared lab trust store.
tmux -S "$SOCK" kill-window -t fm-lab-attach:fm-bundle-restore
# Recordless rollback after checkout: real malformed isolated trust store.
printf '\n=== Failed fresh attach restores detached checkout and removes only its new branch ===\n'
brief rollback
printf 'invalid json\n' > "$CLAUDE_CONFIG_DIR/.claude.json"
set +e; out=$(spawn rollback --attach-branch fm/rollback --attach-head "$HEAD_SAVED" --attach-bundle "$FM_HOME/data/bundles/saved work.bundle" 2>&1); rc=$?; set -e
printf '%s\nexit=%s\n' "$out" "$rc"; test "$rc" != 0; [[ "$out" == *'could not pre-register Claude workspace trust'* ]]
test ! -f "$FM_HOME/state/rollback.meta"
! git -C "$D/project" rev-parse --verify -q refs/heads/fm/rollback
# Find only the real worktrees owned by this disposable project.
git -C "$D/project" worktree list --porcelain
ROLLBACK_WT=$(git -C "$D/project" worktree list --porcelain | awk '/^worktree /{p=substr($0,10)} /^detached$/{print p}')
test -n "$ROLLBACK_WT"; test "$(git -C "$ROLLBACK_WT" rev-parse HEAD)" = "$BASE"
! git -C "$ROLLBACK_WT" symbolic-ref -q HEAD
rm "$CLAUDE_CONFIG_DIR/.claude.json"
# An unused fresh-spawn window is explicitly operator-owned cleanup.
if tmux -S "$SOCK" list-windows -a -F '#{window_name}' | grep -qx fm-rollback; then
 tmux -S "$SOCK" kill-window -t fm-lab-attach:fm-rollback
fi
printf '\n=== Retrying failed attach reuses its restored clean slot ===\n'
spawn rollback --attach-branch fm/rollback --attach-head "$HEAD_SAVED" --attach-bundle "$FM_HOME/data/bundles/saved work.bundle"
WT2=$(awk -F= '$1=="worktree"{print $2}' "$FM_HOME/state/rollback.meta")
test "$WT2" = "$ROLLBACK_WT"
test "$(git -C "$WT2" rev-parse HEAD)" = "$HEAD_SAVED"
test "$(git -C "$WT2" branch --show-current)" = fm/rollback
printf 'retry worktree=%s\nHEAD=%s\nbranch=%s\n' "$WT2" "$(git -C "$WT2" rev-parse HEAD)" "$(git -C "$WT2" branch --show-current)"
printf '\n=== Originless project checks out existing branch without re-cutting it ===\n'
git -C "$D/project" remote remove origin
git -C "$D/project" branch fm/existing "$BASE"
brief existing
spawn existing --attach-branch fm/existing --attach-head "$BASE"
WT3=$(awk -F= '$1=="worktree"{print $2}' "$FM_HOME/state/existing.meta")
test "$(git -C "$WT3" rev-parse HEAD)" = "$BASE"; test "$(git -C "$WT3" branch --show-current)" = fm/existing
printf 'worktree=%s\nHEAD=%s\nbranch=%s\n' "$WT3" "$(git -C "$WT3" rev-parse HEAD)" "$(git -C "$WT3" branch --show-current)"
sleep 3
printf '\n=== Real Claude terminal for existing branch attachment (unauthenticated disposable HOME) ===\n'
tmux -S "$SOCK" capture-pane -p -t fm-lab-attach:fm-existing
printf '\n=== All attach, conflict, and rollback checks passed ===\n'
