#!/usr/bin/env bash
set -euo pipefail
# Reuse fixture definitions, not the live scenarios, from the retained driver.
source <(awk '/^new_world optin$/ {exit} {print}' .test-tmp/live-close.sh)
new_world activation
printf '\n== Environment cannot grant close approval ==\n'
FM_REAPER_CLOSE_LIVE=1 scan
[ -f "$FM_HOME/state/finished.meta" ]
[ ! -d "$FM_HOME/data/bundles" ]
tmux -S "${TMUX%%,*}" has-session -t lab
printf '\n== Removed close CLI flag cannot grant approval ==\n'
rc=0
"$ROOT/bin/fm-lane-reaper.sh" scan --close-live || rc=$?
[ "$rc" -eq 2 ]
[ -f "$FM_HOME/state/finished.meta" ]
echo 'KEPT: neither environment variable nor removed CLI flag enabled close'
touch "$FM_HOME/config/lane-close-live"
printf 'paused [at=%s]: captain decision outstanding\n' "$(($(date +%s)-10800))" > "$FM_HOME/state/finished.status"
printf '\n== Opted-in paused lane is not finished ==\n'
"$ROOT/bin/fm-crew-state.sh" finished
scan
[ -f "$FM_HOME/state/finished.meta" ]
[ ! -d "$FM_HOME/data/bundles" ]
echo 'KEPT: paused task was not closed even with home opt-in'
printf 'done [at=%s]: head %s complete\n' "$(($(date +%s)-10800))" "$HEAD" > "$FM_HOME/state/finished.status"
mv "$WT" "$WT.moved"
printf '\n== Missing worktree is not assumed safe ==\n'
scan
[ -f "$FM_HOME/state/finished.meta" ]
[ -f "$WT.moved/payload.txt" ]
echo 'KEPT: missing-worktree task record and relocated data untouched'
