#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
E=~/.no-mistakes/evidence/01M6RW4TZXA24GYGX9TP9E0VN6
LAB=$ROOT/.b
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TMUX HERDR_ENV HERDR_SESSION HERDR_SOCKET_PATH
mkdir -p "$LAB"
"$ROOT/bin/fm-lab-home.sh" create "$LAB"
mkdir -p "$LAB/tmux" "$LAB/user" "$LAB/pool"
export FM_HOME=$LAB HOME=$LAB/user TREEHOUSE_ROOT=$LAB/pool TMUX_TMPDIR=$LAB/tmux
export XDG_CONFIG_HOME=$LAB/user/config XDG_DATA_HOME=$LAB/user/data XDG_CACHE_HOME=$LAB/user/cache CLAUDE_CONFIG_DIR=$LAB/user/claude
export FM_SPAWN_NO_GUARD=1
cleanup() {
 TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab kill-server 2>/dev/null || true
 chmod -R u+w "$LAB" 2>/dev/null || true
 rm -rf "$LAB"
}
trap cleanup EXIT
: > "$LAB/config/supervision-host"
printf 'claude\n' > "$LAB/config/crew-harness"
TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab -f /dev/null new-session -d -s lab -x 120 -y 35 -c "$ROOT"
export TMUX=$(tmux -L fm-lab display-message -p '#{socket_path},#{pid},0')
git init -q -b main "$LAB/project"
printf 'base\n' > "$LAB/project/base.txt"
git -C "$LAB/project" add .
git -C "$LAB/project" -c user.name=Lab -c user.email=lab@example.invalid commit -qm base
BASE=$(git -C "$LAB/project" rev-parse HEAD)
git clone -q --bare "$LAB/project" "$LAB/origin.git"
git -C "$LAB/project" remote add origin "$LAB/origin.git"
git clone -q "$LAB/origin.git" "$LAB/publisher"
git -C "$LAB/publisher" checkout -qb fm/lab-bundle
printf 'preserved bundle payload\n' > "$LAB/publisher/preserved.txt"
git -C "$LAB/publisher" add .
git -C "$LAB/publisher" -c user.name=Lab -c user.email=lab@example.invalid commit -qm preserved
HEAD=$(git -C "$LAB/publisher" rev-parse HEAD)
mkdir -p "$LAB/data/bundles" "$LAB/data/lab-bundle"
git -C "$LAB/publisher" bundle create -q "$LAB/data/bundles/preserved work.bundle" HEAD
! git -C "$LAB/project" cat-file -e "$HEAD^{commit}" 2>/dev/null
cat > "$LAB/data/lab-bundle/brief.md" <<EOF
# Task
## Captain's intent
Validate attach without modifying files.

## Firstmate spec
Preserve work.

## Constraints
- Ship branch: \`fm/lab-bundle\`
- Delivery: mode=no-mistakes yolo=off
EOF
# Preflight must refuse before acquiring a slot or moving refs.
echo '=== E: missing bundle head and divergent branch refuse untouched ==='
refs_before=$(git -C "$LAB/project" show-ref)
set +e
(cd "$LAB" && "$ROOT/bin/fm-spawn.sh" lab-bundle "$LAB/project" --mode no-mistakes --yolo off --attach-branch fm/lab-bundle --attach-head 0123456789abcdef0123456789abcdef01234567 --attach-bundle 'data/bundles/preserved work.bundle') > "$E/bundle-wrong-head.txt" 2>&1
rc=$?
set -e
cat "$E/bundle-wrong-head.txt"
[ "$rc" -ne 0 ]
grep -q 'is not a head of bundle' "$E/bundle-wrong-head.txt"
[ "$(git -C "$LAB/project" show-ref)" = "$refs_before" ]
[ ! -e "$LAB/state/lab-bundle.meta" ]
! tmux list-windows -a -F '#{window_name}' | grep -qx fm-lab-bundle
git -C "$LAB/project" branch fm/lab-bundle "$BASE"
set +e
(cd "$LAB" && "$ROOT/bin/fm-spawn.sh" lab-bundle "$LAB/project" --mode no-mistakes --yolo off --attach-branch fm/lab-bundle --attach-head "$HEAD" --attach-bundle 'data/bundles/preserved work.bundle') > "$E/bundle-branch-conflict.txt" 2>&1
rc=$?
set -e
cat "$E/bundle-branch-conflict.txt"
[ "$rc" -ne 0 ]
grep -q 'already exists at' "$E/bundle-branch-conflict.txt"
[ "$(git -C "$LAB/project" rev-parse fm/lab-bundle)" = "$BASE" ]
[ ! -e "$LAB/state/lab-bundle.meta" ]
git -C "$LAB/project" branch -D fm/lab-bundle
printf 'preflight refusals left metadata absent, no worker window, conflicting branch unchanged\n'
echo '=== F: relative bundle with spaces restores exact head in real Treehouse worktree ==='
(cd "$LAB" && "$ROOT/bin/fm-spawn.sh" lab-bundle "$LAB/project" --mode no-mistakes --yolo off --attach-branch fm/lab-bundle --attach-head "$HEAD" --attach-bundle 'data/bundles/preserved work.bundle') | tee "$E/bundle-spawn.txt"
WT=$(awk -F= '$1=="worktree" {print substr($0,10)}' "$LAB/state/lab-bundle.meta")
[ -n "$WT" ]
[ "$(git -C "$WT" rev-parse HEAD)" = "$HEAD" ]
[ "$(git -C "$WT" branch --show-current)" = fm/lab-bundle ]
grep -qx 'preserved bundle payload' "$WT/preserved.txt"
[ "$(git -C "$LAB/project" rev-parse main)" = "$BASE" ]
cat "$LAB/state/lab-bundle.meta" > "$E/bundle-meta.txt"
printf 'expected preserved HEAD=%s\nobserved HEAD=%s\nbranch=%s\nfile=%s\nprimary main unchanged=%s\n' "$HEAD" "$(git -C "$WT" rev-parse HEAD)" "$(git -C "$WT" branch --show-current)" "$(cat "$WT/preserved.txt")" "$(git -C "$LAB/project" rev-parse main)"
sleep 2
tmux capture-pane -p -t lab:fm-lab-bundle > "$E/bundle-pane.txt"
echo 'LIVE BUNDLE SCENARIOS COMPLETE'
