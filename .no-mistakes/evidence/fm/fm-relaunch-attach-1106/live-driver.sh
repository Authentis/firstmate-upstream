#!/usr/bin/env bash
set -eu
ROOT=$PWD
E=~/.no-mistakes/evidence/01M6RTM7V5Z7JB2E02FSDQSHK6
LAB=$ROOT/.live-attach-lab
mkdir -p "$LAB"
"$ROOT/bin/fm-lab-home.sh" create "$LAB"
mkdir -p "$LAB/tmux" "$LAB/user" "$LAB/wt"
# tmux canonicalizes TMUX_TMPDIR, and the gate worktree exceeds AF_UNIX's
# path limit. Its ephemeral private socket is toolchain scratch in /tmp.
export TMUX_TMPDIR=/tmp
SOCKET=/tmp/fm-lab-attach-$$
unset TMUX FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE HERDR_SESSION HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_TAB_ID CLAUDE_CONFIG_DIR
export FM_HOME=$LAB HOME=$LAB/user FM_SPAWN_NO_GUARD=1
CHILD=
cleanup() {
  [ -z "$CHILD" ] || { kill "$CHILD" 2>/dev/null || true; wait "$CHILD" 2>/dev/null || true; }
  tmux -S "$SOCKET" kill-server 2>/dev/null || true
  rm -f "$SOCKET"
  chmod -R u+w "$LAB" 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT
# The real tmux server uses only this private lab socket.
tmux -S "$SOCKET" -f /dev/null new-session -d -s primary -x 120 -y 35 -c "$ROOT"
export TMUX="$(tmux -S "$SOCKET" display-message -p '#{socket_path},#{pid},0')"
git init -q -b main "$LAB/project"
git -C "$LAB/project" -c user.name=Test -c user.email=test@example.invalid commit -qm base --allow-empty
git -C "$LAB/project" worktree add -q -b fm/live-recover "$LAB/wt/recover"
printf 'committed work\n' > "$LAB/wt/recover/work.txt"
git -C "$LAB/wt/recover" add work.txt
git -C "$LAB/wt/recover" -c user.name=Test -c user.email=test@example.invalid commit -qm preserved
printf 'unfinished work\n' >> "$LAB/wt/recover/work.txt"
mkdir -p "$LAB/data/live-recover"
printf '# Task\n## Captain\x27s intent\nPreserve committed and unfinished work.\n## Firstmate spec\nDo not edit files.\n' > "$LAB/data/live-recover/brief.md"
cat > "$LAB/state/live-recover.meta" <<EOF
window=destroyed:fm-live-recover
endpoint_task_id=live-recover
worktree=$LAB/wt/recover
project=$LAB/project
branch=fm/live-recover
harness=codex
kind=ship
mode=local-only
yolo=off
model=default
effort=default
EOF
touch "$LAB/config/supervision-host" "$LAB/state/.last-watcher-beat"
printf '\n=== Agent-free proof with actual ps, /proc, tmux ===\n'
. "$ROOT/bin/fm-control-lib.sh"
. "$ROOT/bin/fm-backend.sh"
fm_control_endpoint_absence_verdict tmux destroyed:fm-live-recover live-recover "$LAB/wt/recover"; echo
printf '\n=== exit on destroyed endpoint ===\n'
"$ROOT/bin/fm-control.sh" live-recover exit
printf '\n=== recorded recovery ===\n'
HEAD_BEFORE=$(git -C "$LAB/wt/recover" rev-parse HEAD)
HASH_BEFORE=$(sha256sum "$LAB/wt/recover/work.txt")
printf 'HEAD before: %s\ncontent before: %s\n' "$HEAD_BEFORE" "$HASH_BEFORE"
"$ROOT/bin/fm-control.sh" live-recover relaunch --note 'Continue preserved work; do not edit files.'
cat "$LAB/state/live-recover.meta"
git -C "$LAB/wt/recover" rev-parse HEAD
sha256sum "$LAB/wt/recover/work.txt"
tmux -S "$SOCKET" list-windows -a -F '#{session_name}:#{window_name} #{window_id} #{pane_current_path} #{pane_current_command}'
sleep 3
tmux -S "$SOCKET" capture-pane -p -t primary:fm-live-recover
[ "$(git -C "$LAB/wt/recover" rev-parse HEAD)" = "$HEAD_BEFORE" ]
[ "$(sha256sum "$LAB/wt/recover/work.txt")" = "$HASH_BEFORE" ]
[ "$(git -C "$LAB/wt/recover" symbolic-ref --short HEAD)" = fm/live-recover ]
[ "$(tmux list-windows -a -F '#{window_name}' | grep -cx fm-live-recover)" = 1 ]
printf 'RECOVERY: exact HEAD, branch and unfinished content preserved; one new endpoint\n'
tmux kill-window -t primary:fm-live-recover
# Reset only the synthetic record to exercise independent refusals.
printf 'window=destroyed:fm-live-recover\n' > "$LAB/address"
python3 - "$LAB/state/live-recover.meta" <<'PY'
import sys
p=sys.argv[1]
s=open(p).read().splitlines()
open(p,'w').write('\n'.join('window=destroyed:fm-live-recover' if x.startswith('window=') else x for x in s)+'\n')
PY
refuse() {
  local want=$1; shift
  local out rc
  set +e
  out=$("$@" 2>&1); rc=$?
  set -e
  printf '$ %q ' "$@"; printf '\n%s\nexit=%s\n' "$out" "$rc"
  [ "$rc" != 0 ]
  printf '%s\n' "$out" | grep -F -- "$want" >/dev/null
}
printf '\n=== refuse a surviving owner naming the task ===\n'
python3 -c 'import time; time.sleep(120)' live-recover & CHILD=$!
sleep 0.2
refuse 'names the task in its arguments' "$ROOT/bin/fm-control.sh" live-recover relaunch --note safe
kill "$CHILD"; wait "$CHILD" 2>/dev/null || true; CHILD=
printf '\n=== refuse a surviving owner in the recorded worktree ===\n'
(cd "$LAB/wt/recover" && exec sleep 120) & CHILD=$!
sleep 0.2
refuse 'working in the recorded worktree' "$ROOT/bin/fm-spawn.sh" live-recover --relaunch
kill "$CHILD"; wait "$CHILD" 2>/dev/null || true; CHILD=
printf '\n=== refuse same-name window in another session ===\n'
tmux new-session -d -s other -n fm-live-recover -c "$ROOT"
refuse 'still in the window inventory' "$ROOT/bin/fm-spawn.sh" live-recover --relaunch
tmux kill-session -t other
printf '\n=== refuse an unreadable non-allowlisted process directory ===\n'
python3 -c 'import ctypes,time; ctypes.CDLL(None).prctl(4,0); time.sleep(120)' & CHILD=$!
sleep 0.3
refuse 'working directory of process' "$ROOT/bin/fm-spawn.sh" live-recover --relaunch
kill "$CHILD"; wait "$CHILD" 2>/dev/null || true; CHILD=
printf '\n=== abort replacement before publication; retry ===\n'
cp "$LAB/state/live-recover.meta" "$LAB/old-meta"
printf 'not json\n' > "$HOME/.claude.json"
refuse 'could not pre-register Claude workspace trust' "$ROOT/bin/fm-control.sh" live-recover relaunch --harness claude --note retry-safe
cmp "$LAB/old-meta" "$LAB/state/live-recover.meta"
! tmux list-windows -a -F '#{window_name}' | grep -qx fm-live-recover
printf 'ABORT: original record unchanged and replacement window absent\n'
rm "$HOME/.claude.json"
"$ROOT/bin/fm-control.sh" live-recover relaunch --harness codex --note retry-success
[ "$(git -C "$LAB/wt/recover" rev-parse HEAD)" = "$HEAD_BEFORE" ]
[ "$(sha256sum "$LAB/wt/recover/work.txt")" = "$HASH_BEFORE" ]
tmux kill-window -t primary:fm-live-recover
printf 'RETRY: recovered without a stranded replacement window\n'

export TREEHOUSE_ROOT=$LAB/pool
# Every fresh task has an inert synthetic brief: no external task or gate.
brief() {
 mkdir -p "$LAB/data/$1"
 printf '# Task\n## Captain\x27s intent\nPreserve the supplied head; do not edit files.\n## Firstmate spec\nValidate local attach only.\n' > "$LAB/data/$1/brief.md"
}
field() { awk -F= -v k="$2" '$1==k {sub(/^[^=]*=/, ""); print}' "$LAB/state/$1.meta"; }
printf '\n=== originless attach to an existing exact branch ===\n'
brief live-existing
BASE=$(git -C "$LAB/project" rev-parse main)
git -C "$LAB/project" branch fm/live-existing "$BASE"
"$ROOT/bin/fm-spawn.sh" live-existing "$LAB/project" --harness codex --mode local-only --yolo off --attach-branch fm/live-existing --attach-head "$BASE"
WT=$(field live-existing worktree)
[ "$(git -C "$WT" rev-parse HEAD)" = "$BASE" ]
[ "$(git -C "$WT" symbolic-ref --short HEAD)" = fm/live-existing ]
cat "$LAB/state/live-existing.meta"
tmux kill-window -t primary:fm-live-existing
printf '\n=== relative bundle attach; preflight adversarial cases ===\n'
git clone -q --bare "$LAB/project" "$LAB/origin.git"
git -C "$LAB/project" remote add origin "$LAB/origin.git"
git -C "$LAB/project" config remote.origin.fetch '+refs/heads/main:refs/remotes/origin/main'
git clone -q "$LAB/origin.git" "$LAB/publisher"
git -C "$LAB/publisher" checkout -qb preserved
printf 'bundle-only work\n' > "$LAB/publisher/preserved.txt"
git -C "$LAB/publisher" add preserved.txt
git -C "$LAB/publisher" -c user.name=Test -c user.email=test@example.invalid commit -qm preserved-bundle
PRESERVED=$(git -C "$LAB/publisher" rev-parse HEAD)
mkdir -p "$LAB/data/bundles"
git -C "$LAB/publisher" bundle create "$LAB/data/bundles/saved work.bundle" HEAD
! git -C "$LAB/project" cat-file -e "$PRESERVED^{commit}" 2>/dev/null
brief live-bundle
refuse 'is not present in' "$ROOT/bin/fm-spawn.sh" live-bundle "$LAB/project" --harness codex --mode local-only --yolo off --attach-branch fm/live-bundle --attach-head "$PRESERVED"
refuse 'is not a head of bundle' "$ROOT/bin/fm-spawn.sh" live-bundle "$LAB/project" --harness codex --mode local-only --yolo off --attach-branch fm/live-bundle --attach-head 0123456789abcdef0123456789abcdef01234567 --attach-bundle "$LAB/data/bundles/saved work.bundle"
git -C "$LAB/project" push -q origin main:fm/live-bundle
git -C "$LAB/project" update-ref -d refs/remotes/origin/fm/live-bundle
refuse 'already exists on origin at' "$ROOT/bin/fm-spawn.sh" live-bundle "$LAB/project" --harness codex --mode local-only --yolo off --attach-branch fm/live-bundle --attach-head "$PRESERVED" --attach-bundle "$LAB/data/bundles/saved work.bundle"
[ ! -f "$LAB/state/live-bundle.meta" ]
git -C "$LAB/project" push -q origin :fm/live-bundle
(cd "$LAB" && "$ROOT/bin/fm-spawn.sh" live-bundle "$LAB/project" --harness codex --mode local-only --yolo off --attach-branch fm/live-bundle --attach-head "$PRESERVED" --attach-bundle 'data/bundles/saved work.bundle')
WT=$(field live-bundle worktree)
[ "$(git -C "$WT" rev-parse HEAD)" = "$PRESERVED" ]
[ "$(git -C "$WT" symbolic-ref --short HEAD)" = fm/live-bundle ]
printf 'Expected preserved HEAD: %s\nActual: ' "$PRESERVED"; git -C "$WT" rev-parse HEAD
cat "$WT/preserved.txt" "$LAB/state/live-bundle.meta"
tmux kill-window -t primary:fm-live-bundle
printf '\n=== fresh attach prelaunch abort restores pool and removes only new branch ===\n'
brief live-abort
printf 'not json\n' > "$HOME/.claude.json"
refuse 'could not pre-register Claude workspace trust' "$ROOT/bin/fm-spawn.sh" live-abort "$LAB/project" --harness claude --mode local-only --yolo off --attach-branch fm/live-abort --attach-head "$PRESERVED" --attach-bundle "$LAB/data/bundles/saved work.bundle"
[ ! -f "$LAB/state/live-abort.meta" ]
! git -C "$LAB/project" show-ref --verify --quiet refs/heads/fm/live-abort
printf 'ABORT: no task record or new attach branch remains\n'
ABORT_WT=$(git -C "$LAB/project" worktree list --porcelain | awk '/^worktree / {p=substr($0,10)} /^detached$/ {print p}')
[ -n "$ABORT_WT" ]
[ "$(git -C "$ABORT_WT" rev-parse HEAD)" = "$BASE" ]
[ -z "$(git -C "$ABORT_WT" status --porcelain)" ]
printf 'Restored detached pool HEAD: '; git -C "$ABORT_WT" rev-parse HEAD
rm "$HOME/.claude.json"
# Close an idle shell if the backend left one; durable-lease abort cleanup
# may already have closed the fresh endpoint.
if tmux list-windows -a -F '#{window_name}' | grep -qx fm-live-abort; then
 tmux kill-window -t primary:fm-live-abort
else
 printf 'ABORT: fresh endpoint already removed by product cleanup\n'
fi
"$ROOT/bin/fm-spawn.sh" live-abort "$LAB/project" --harness codex --mode local-only --yolo off --attach-branch fm/live-abort --attach-head "$PRESERVED" --attach-bundle "$LAB/data/bundles/saved work.bundle"
WT=$(field live-abort worktree)
[ "$(git -C "$WT" rev-parse HEAD)" = "$PRESERVED" ]
[ "$(git -C "$WT" symbolic-ref --short HEAD)" = fm/live-abort ]
[ "$WT" = "$ABORT_WT" ]
printf 'RETRY: reused the same restored slot; attached preserved HEAD %s on ' "$PRESERVED"; git -C "$WT" symbolic-ref --short HEAD
printf '\nALL LIVE LOCAL SCENARIOS COMPLETED\n'
