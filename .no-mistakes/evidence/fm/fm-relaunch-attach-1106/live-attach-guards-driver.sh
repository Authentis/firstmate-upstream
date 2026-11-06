#!/usr/bin/env bash
set -eu
ROOT=$PWD
E=~/.no-mistakes/evidence/01M6RYKTPNQ9PK751MTJ97Z0ZR
LAB="$ROOT/.v"
export FM_HOME="$LAB" HOME="$LAB/user" TMPDIR="$LAB/tmp" CODEX_HOME="$LAB/codex" TMUX_TMPDIR="$LAB/tmux" TREEHOUSE_ROOT="$LAB/pool"
export CLAUDE_CONFIG_DIR="$LAB/user" DISABLE_AUTOUPDATER=1
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS HERDR_ENV HERDR_SESSION HERDR_PANE_ID TMUX TMUX_PANE
trap 'tmux -L fm-lab kill-server 2>/dev/null || true' EXIT
tmux -f /dev/null -L fm-lab new-session -d -x 120 -y 40 -s primary -c "$ROOT"
export TMUX="$(tmux -L fm-lab display-message -p -t primary '#{socket_path}'),$(tmux -L fm-lab display-message -p -t primary '#{pid}'),0"
export TMUX_PANE=$(tmux -L fm-lab display-message -p -t primary '#{pane_id}')
head=$(git -C "$LAB/publisher" rev-parse HEAD)
base=$(git -C "$LAB/project" rev-parse main)
bundle="$LAB/data/bundles/saved work.bundle"
brief() {
  mkdir -p "$LAB/data/$1"
  printf '# Task\n## Captain\x27s intent\nRecover preserved work for %s.\n\n## Firstmate spec\nThis is a local lifecycle validation fixture. Do not edit or execute project files.\n\n## Setup\nShip branch: fm/%s\nDelivery contract: mode=no-mistakes\n' "$1" "$1" > "$LAB/data/$1/brief.md"
}
heads() { git -C "$LAB/project" for-each-ref --format='%(refname) %(objectname)' refs/heads | sort; }
windows() { tmux -L fm-lab list-windows -a -F '#{session_name}:#{window_name}' | sort; }
refuse() {
  local id=$1 expected=$2; shift 2
  brief "$id"
  heads > "$LAB/heads-before"
  windows > "$LAB/windows-before"
  printf '\n$ fm-spawn.sh %q project --mode no-mistakes --yolo off --harness codex --attach-branch %q ' "$id" "fm/$id" >> "$E/attach-refusals.log"
  printf '%q ' "$@" >> "$E/attach-refusals.log"; printf '\n' >> "$E/attach-refusals.log"
  set +e
  out=$("$ROOT/bin/fm-spawn.sh" "$id" "$LAB/project" --mode no-mistakes --yolo off --harness codex --backend tmux --attach-branch "fm/$id" "$@" 2>&1)
  rc=$?
  set -e
  printf '%s\nexit=%s\n' "$out" "$rc" >> "$E/attach-refusals.log"
  [ "$rc" != 0 ]; printf '%s' "$out" | grep -q "$expected"
  [ ! -e "$LAB/state/$id.meta" ]
  heads > "$LAB/heads-after"; cmp "$LAB/heads-before" "$LAB/heads-after"
  windows > "$LAB/windows-after"; cmp "$LAB/windows-before" "$LAB/windows-after"
  printf 'Verified: no task record, no new endpoint, no changed local branch refs.\n' >> "$E/attach-refusals.log"
}
# Specification oracle: invalid or conflicting inputs must never move a branch.
refuse live-badhead 'is not a head of bundle' --attach-head 0123456789abcdef0123456789abcdef01234567 --attach-bundle "$bundle"
refuse live-half 'needs both' --attach-head "$head" --attach-branch ''
git -C "$LAB/project" branch fm/live-conflict "$base"
refuse live-conflict 'already exists at' --attach-head "$head" --attach-bundle "$bundle"
# A branch on origin must not be hidden by a main-only fetch refspec.
git clone -q --bare "$LAB/project" "$LAB/origin.git"
git -C "$LAB/origin.git" update-ref refs/heads/fm/live-remote "$base"
git -C "$LAB/project" remote add origin "file://$LAB/origin.git"
git -C "$LAB/project" config remote.origin.fetch '+refs/heads/main:refs/remotes/origin/main'
refuse live-remote 'already exists on origin at' --attach-head "$head" --attach-bundle "$bundle"
git -C "$LAB/project" remote set-url origin "file://$LAB/absent-origin.git"
refuse live-unreachable 'could not ask origin' --attach-head "$head" --attach-bundle "$bundle"
git -C "$LAB/project" remote remove origin
# Force an actual late trust-store failure after branch checkout and restore.
brief live-rollback
git -C "$LAB/project" worktree list --porcelain > "$LAB/worktrees-before"
printf 'invalid json\n' > "$HOME/.claude.json"
set +e
"$ROOT/bin/fm-spawn.sh" live-rollback "$LAB/project" --mode no-mistakes --yolo off --harness claude --backend tmux --attach-branch fm/live-rollback --attach-head "$head" --attach-bundle "$bundle" > "$E/attach-rollback.log" 2>&1
rc=$?
set -e
printf 'trust-failure exit=%s\n' "$rc" >> "$E/attach-rollback.log"
[ "$rc" != 0 ]; grep -q 'could not pre-register Claude workspace trust' "$E/attach-rollback.log"
[ ! -e "$LAB/state/live-rollback.meta" ]
! git -C "$LAB/project" rev-parse --verify -q refs/heads/fm/live-rollback >/dev/null
wt=$(git -C "$LAB/project" worktree list --porcelain | awk '/^worktree / {sub(/^worktree /, ""); print}' | while IFS= read -r p; do if ! grep -Fxq "worktree $p" "$LAB/worktrees-before"; then printf '%s\n' "$p"; fi; done)
[ -n "$wt" ]; [ "$(git -C "$wt" rev-parse HEAD)" = "$base" ]
! git -C "$wt" symbolic-ref -q HEAD >/dev/null
printf 'Restored pooled copy: %s\nHEAD=%s; expected prior HEAD=%s; detached checkout; new branch absent; task record absent.\n' "$wt" "$(git -C "$wt" rev-parse HEAD)" "$base" >> "$E/attach-rollback.log"
rm "$HOME/.claude.json"
# A fresh-spawn abort may already remove its unused endpoint; only close one if it survived.
if tmux -L fm-lab list-windows -a -F '#{window_name}' | grep -qx fm-live-rollback; then
  tmux -L fm-lab kill-window -t primary:fm-live-rollback
fi
"$ROOT/bin/fm-spawn.sh" live-rollback "$LAB/project" --mode no-mistakes --yolo off --harness codex --backend tmux --attach-branch fm/live-rollback --attach-head "$head" --attach-bundle "$bundle" >> "$E/attach-rollback.log" 2>&1
wt=$(awk -F= '$1=="worktree" {print substr($0,10)}' "$LAB/state/live-rollback.meta")
[ "$(git -C "$wt" rev-parse HEAD)" = "$head" ]; [ "$(git -C "$wt" branch --show-current)" = fm/live-rollback ]
printf 'Retry exit=0; branch=%s; HEAD=%s\n' "$(git -C "$wt" branch --show-current)" "$(git -C "$wt" rev-parse HEAD)" >> "$E/attach-rollback.log"
tmux -L fm-lab kill-window -t primary:fm-live-rollback
# Existing matching branch is adopted, never cut again or moved.
brief live-existing
git -C "$LAB/project" branch fm/live-existing "$head"
heads > "$LAB/heads-before"
"$ROOT/bin/fm-spawn.sh" live-existing "$LAB/project" --mode no-mistakes --yolo off --harness codex --backend tmux --attach-branch fm/live-existing --attach-head "$head" > "$E/attach-existing.log" 2>&1
wt=$(awk -F= '$1=="worktree" {print substr($0,10)}' "$LAB/state/live-existing.meta")
[ "$(git -C "$wt" rev-parse HEAD)" = "$head" ]; [ "$(git -C "$wt" branch --show-current)" = fm/live-existing ]
heads > "$LAB/heads-after"; cmp "$LAB/heads-before" "$LAB/heads-after"
printf 'Existing-branch attach exit=0; branch=%s; HEAD=%s; all branch refs unchanged.\n' "$(git -C "$wt" branch --show-current)" "$(git -C "$wt" rev-parse HEAD)" >> "$E/attach-existing.log"
printf 'All attach guard and rollback assertions passed.\n'
