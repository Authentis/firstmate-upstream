#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
E=~/.no-mistakes/evidence/01M6RMBRQFE89P7GNGBSKBW5T8
LAB=$ROOT/.attach-lab
SOCK=$ROOT/.as
cleanup() { tmux -S "$SOCK" kill-server 2>/dev/null || true; chmod -R u+w "$LAB" 2>/dev/null || true; rm -rf "$LAB"; rm -f "$SOCK"; rm -rf /tmp/fm-labattach1106; }
trap cleanup EXIT
mkdir -p "$LAB"; bin/fm-lab-home.sh create "$LAB/home"
mkdir -p "$LAB/user" "$LAB/tmp" "$LAB/home/data/labattach1106" "$LAB/home/config" "$LAB/home/data/bundles"
touch "$LAB/home/config/supervision-host" "$LAB/home/state/.last-watcher-beat"
export FM_HOME=$LAB/home HOME=$LAB/user TMPDIR=$LAB/tmp FM_SPAWN_NO_GUARD=1 TREEHOUSE_ROOT=$LAB/pool
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
# Initialize real local Git origin, operational project and separate publisher.
git init -q -b main "$LAB/proj"
git -C "$LAB/proj" config user.name Lab; git -C "$LAB/proj" config user.email lab@example.invalid
printf 'base\n' > "$LAB/proj/base.txt"
git -C "$LAB/proj" add .; git -C "$LAB/proj" commit -qm base
BASE=$(git -C "$LAB/proj" rev-parse HEAD)
git clone -q --bare "$LAB/proj" "$LAB/origin.git"
git -C "$LAB/proj" remote add origin "file://$LAB/origin.git"
git clone -q "file://$LAB/origin.git" "$LAB/publisher"
git -C "$LAB/publisher" config user.name Lab; git -C "$LAB/publisher" config user.email lab@example.invalid
git -C "$LAB/publisher" checkout -q -b fm/labattach1106
printf 'bundle-only preserved work\n' > "$LAB/publisher/preserved.txt"
git -C "$LAB/publisher" add .; git -C "$LAB/publisher" commit -qm preserved
HEAD=$(git -C "$LAB/publisher" rev-parse HEAD)
git -C "$LAB/publisher" bundle create -q "$LAB/home/data/bundles/preserved work.bundle" HEAD
! git -C "$LAB/proj" cat-file -e "$HEAD^{commit}" 2>/dev/null
cat > "$LAB/home/data/labattach1106/brief.md" <<'EOF'
# Task
## Captain's intent
Resume preserved work on fm/labattach1106 without changing files.

## Firstmate spec
Ship branch: fm/labattach1106
Mode: local-only
Observe this lab only and await operator input.
EOF
tmux -S "$SOCK" new-session -d -s primary -x 120 -y 40 -c "$ROOT"
export TMUX="$SOCK,$(tmux -S "$SOCK" display-message -p '#{pid}'),0"
# Narrow refspec: the conflicting branch exists only on origin, never tracked locally.
git -C "$LAB/proj" config remote.origin.fetch '+refs/heads/main:refs/remotes/origin/main'
git -C "$LAB/publisher" push -q origin "${BASE}:refs/heads/fm/labattach1106"
BEFORE=$(git -C "$LAB/proj" for-each-ref --format='%(refname) %(objectname)' refs/heads)
spawn() { (cd "$LAB/home" && "$ROOT/bin/fm-spawn.sh" labattach1106 "$LAB/proj" --harness codex --backend tmux --mode local-only --yolo off --attach-branch fm/labattach1106 --attach-head "$HEAD" --attach-bundle 'data/bundles/preserved work.bundle'); }
printf '\n=== Origin conflict hidden by narrow refspec ===\n'
set +e
spawn > "$E/live-origin-conflict.log" 2>&1
rc=$?
set -e
cat "$E/live-origin-conflict.log"; echo "origin_conflict_exit=$rc"; [ "$rc" -ne 0 ]
grep -F 'already exists on origin at' "$E/live-origin-conflict.log"
[ ! -e "$LAB/home/state/labattach1106.meta" ]
[ "$BEFORE" = "$(git -C "$LAB/proj" for-each-ref --format='%(refname) %(objectname)' refs/heads)" ]
! git -C "$LAB/proj" rev-parse --verify refs/remotes/origin/fm/labattach1106 2>/dev/null
[ "$(tmux -S "$SOCK" list-windows -a -F '#{window_name}' | grep -c '^fm-labattach1106$' || true)" = 0 ]
echo 'NARROW_ORIGIN_GUARD_PASS'
git -C "$LAB/publisher" push -q origin :refs/heads/fm/labattach1106
printf '\n=== Fresh attach from operational-home-relative bundle ===\n'
set +e
spawn > "$E/live-bundle-attach.log" 2>&1
rc=$?
set -e
cat "$E/live-bundle-attach.log"; echo "bundle_attach_exit=$rc"; [ "$rc" = 0 ]
cat "$LAB/home/state/labattach1106.meta"
WT=$(awk -F= '$1=="worktree" {print substr($0,10)}' "$LAB/home/state/labattach1106.meta")
[ "$(git -C "$WT" rev-parse HEAD)" = "$HEAD" ]
[ "$(git -C "$WT" branch --show-current)" = fm/labattach1106 ]
[ "$(cat "$WT/preserved.txt")" = 'bundle-only preserved work' ]
[ "$(git -C "$LAB/proj" rev-parse main)" = "$BASE" ]
printf 'expected_head=%s\nactual_head=%s\nbranch=%s\npreserved_file=%s\nprimary_main_unchanged=%s\n' "$HEAD" "$(git -C "$WT" rev-parse HEAD)" "$(git -C "$WT" branch --show-current)" "$(cat "$WT/preserved.txt")" "$BASE"
tmux -S "$SOCK" list-windows -a -F '#{session_name}:#{window_name} cwd=#{pane_current_path} command=#{pane_current_command}'
sleep 2
tmux -S "$SOCK" capture-pane -p -t primary:fm-labattach1106 > "$E/live-attach-pane.txt"
cat "$E/live-attach-pane.txt"
echo 'RELATIVE_BUNDLE_ATTACH_PASS'
