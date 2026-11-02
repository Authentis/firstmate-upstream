#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
BASE="$ROOT/.live-validation"
export PATH="$BASE/tools/root/usr/bin:$PATH"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_DATA_OVERRIDE FM_GATE_REFUSE_BYPASS FM_TEST_SEAM FM_LANE_CLOSE_TEARDOWN FM_REAPER_CPU_CMD FM_REAPER_CREW_STATE FM_REAPER_CONTROL TMUX TASKS_AXI_FILE TASKS_AXI_BACKEND
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=Lab GIT_AUTHOR_EMAIL=lab@example.invalid GIT_COMMITTER_NAME=Lab GIT_COMMITTER_EMAIL=lab@example.invalid
SOCKET="$BASE/s"
# All tmux invocations (including the real product) address this private socket.
mkdir -p "$BASE/bin"
printf '#!/usr/bin/env bash\nexec /usr/bin/tmux -f /dev/null -S %q "$@"\n' "$SOCKET" > "$BASE/bin/tmux"
chmod +x "$BASE/bin/tmux"
export PATH="$BASE/bin:$PATH"
cleanup() { tmux kill-server 2>/dev/null || true; for h in "$BASE"/home-*; do [ ! -d "$h" ] || rm -rf "$h"; done; }
trap cleanup EXIT
fail() { echo "FAIL: $*"; exit 1; }
check() { "$@" || fail "$*"; }
new_lane() {
  id=$1
  export FM_HOME="$BASE/home-$id"
  "$ROOT/bin/fm-lab-home.sh" create "$FM_HOME"
  proj="$FM_HOME/projects/repo"; wt="$FM_HOME/lane"
  git init -q -b main "$proj"
  printf 'initial\n' > "$proj/file"
  git -C "$proj" add file; git -C "$proj" commit -qm initial
  git init -q --bare "$FM_HOME/remote.git"
  git -C "$proj" remote add origin "$FM_HOME/remote.git"
  git -C "$proj" push -qu origin main
  git -C "$proj" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  export TREEHOUSE_ROOT="$FM_HOME/pool"
  wt=$(cd "$proj" && treehouse get --lease --no-fetch -b "fm/$id")
  echo "Real Treehouse allocated $wt"
  printf 'kind=ship\nmode=local-only\nproject=%s\nworktree=%s\nbranch=fm/%s\n' "$proj" "$wt" "$id" > "$FM_HOME/state/$id.meta"
  printf 'done [at=1000000000]: synthetic lab deliverable complete\n' > "$FM_HOME/state/$id.status"
  head=$(git -C "$wt" rev-parse HEAD)
  tmux has-session -t =lab 2>/dev/null || tmux new-session -d -s lab -n supervisor -x 120 -y 30 'sleep 300'
  tmux new-window -d -t lab: -n "fm-$id" sh
  printf 'window=lab:fm-%s\nendpoint_task_id=%s\nspawn_gen=live-%s\nharness=claude\n' "$id" "$id" "$id" >> "$FM_HOME/state/$id.meta"
  # Synthetic idle event through the actual public recovery writer, not a fake harness.
  "$ROOT/bin/fm-busy-event.sh" arm "$FM_HOME/state" "$id" --state idle --source fm-recovery --event synthetic-lab-idle
}
extra() { printf 'synthetic work %s\n' "$id" > "$wt/payload"; git -C "$wt" add payload; git -C "$wt" commit -qm payload; head=$(git -C "$wt" rev-parse HEAD); }
scan() {
  "$ROOT/bin/fm-crew-state.sh" "$id"
  local output
  output=$(FM_REAPER_NOW=$(($(date +%s) + 60)) FM_REAPER_FORCE=1 FM_REAPER_IDLE_SECS=0 FM_REAPER_QUIET_SECS=0 "$ROOT/bin/fm-lane-reaper.sh" scan)
  printf '%s\n' "$output"
  if [[ "$output" == *'teardown refused'* ]]; then
    echo 'Diagnostic: ordinary teardown refusal details:'
    "$ROOT/bin/fm-teardown.sh" "$id" || true
  fi
}
optin() { touch "$FM_HOME/config/lane-close-live"; }
count_bundles() { local files=("$FM_HOME/data/bundles/$id-close."*.bundle); [ -f "${files[0]}" ] || { echo 0; return; }; echo "${#files[@]}"; }
restore() {
  local f=$1 dest="$FM_HOME/restore-$RANDOM"
  git clone --bare -q "$f" "$dest"
  check test "$(git -C "$dest" rev-parse HEAD)" = "$head"
  git -C "$dest" fsck --full --strict
  echo "RESTORED independently: $head from ${f##*/}"
}

echo '=== 1: default-off close; reaper-live and legacy environment cannot activate it ==='
new_lane off
extra
# no upstream and unmerged; still a close candidate, not an agent-ending candidate.
touch "$FM_HOME/config/lane-reaper-live"
off_output=$(FM_REAPER_CLOSE_LIVE=1 scan)
printf '%s\n' "$off_output"
[[ "$off_output" == *'dry-run close off: would-close'* ]] || fail 'not an eligible dry-run candidate'
check test -f "$FM_HOME/state/off.meta"
check test -d "$wt"
check test "$(count_bundles)" = 0
echo 'PASS default-off retained lane and produced no backup/teardown'

echo '=== 2: pushed clean done lane ordinary teardown ==='
new_lane pushed
extra
git -C "$wt" push -qu origin HEAD
optin
scan
check test ! -f "$FM_HOME/state/pushed.meta"
check test -d "$wt"
check test "$(git -C "$wt" symbolic-ref -q --short HEAD || true)" != "fm/$id"
check test "$(git -C "$FM_HOME/remote.git" rev-parse fm/pushed)" = "$head"
echo "PASS pushed lane removed, remote retains $head"

echo '=== 3: failed upstream push is preserved; same-status scan retries after recovery ==='
new_lane retry
git -C "$wt" push -qu origin HEAD
extra
optin
git -C "$wt" remote set-url origin "$FM_HOME/unavailable.git"
scan
check test -f "$FM_HOME/state/retry.meta"
check test "$(count_bundles)" = 1
bundle=("$FM_HOME/data/bundles/retry-close."*.bundle)
restore "${bundle[0]}"
scan
check test "$(count_bundles)" = 1
git -C "$wt" remote set-url origin "$FM_HOME/remote.git"
scan
check test ! -f "$FM_HOME/state/retry.meta"
check test -d "$wt"
check test "$(git -C "$wt" symbolic-ref -q --short HEAD || true)" != "fm/$id"
check test "$(git -C "$FM_HOME/remote.git" rev-parse fm/retry)" = "$head"
echo 'PASS push refusal retained one restorable bundle; unchanged done status retried and closed'

echo '=== 4: unlanded no-upstream lane retries without duplicate backups; corrupted payload replaced ==='
new_lane reuse
extra
optin
scan
check test -f "$FM_HOME/state/reuse.meta"
check test "$(count_bundles)" = 1
bundle=("$FM_HOME/data/bundles/reuse-close."*.bundle)
restore "${bundle[0]}"
scan
check test "$(count_bundles)" = 1
python3 - "${bundle[0]}" <<'PY'
import sys
p=sys.argv[1]
b=open(p,'rb').read(); header=b[:b.index(b'\n\n')+2]
open(p,'wb').write(header+b'PACK')
PY
git -C "$wt" bundle verify "${bundle[0]}"
if git clone --bare -q "${bundle[0]}" "$FM_HOME/broken"; then fail 'damaged payload restored'; fi
scan
check test "$(count_bundles)" = 2
for f in "$FM_HOME/data/bundles/reuse-close."*.bundle; do [ "$f" = "${bundle[0]}" ] || restore "$f"; done
scan
check test "$(count_bundles)" = 2
check test -f "$FM_HOME/state/reuse.meta"
echo 'PASS ordinary teardown keeps unlanded work; retries reuse valid backups and replace a valid-header truncated pack'

echo '=== 5: validation mirror is not real-remote preservation ==='
new_lane mirror
extra
git -C "$wt" remote rename origin no-mistakes
git -C "$wt" push -qu no-mistakes HEAD
optin
scan
check test -f "$FM_HOME/state/mirror.meta"
check test "$(count_bundles)" = 1
bundle=("$FM_HOME/data/bundles/mirror-close."*.bundle)
restore "${bundle[0]}"
echo 'PASS mirror-only work bundled and ordinary teardown refused unlanded lane'

echo '=== 6: dirty, paused, young and recently-written lanes stay intact ==='
new_lane guards
optin
printf 'untracked valuable bytes\n' > "$wt/untracked"
scan
check test -f "$FM_HOME/state/guards.meta"
check test "$(< "$wt/untracked")" = 'untracked valuable bytes'
rm "$wt/untracked"
printf 'paused [at=1000000000]: waiting\n' > "$FM_HOME/state/guards.status"
scan
check test -f "$FM_HOME/state/guards.meta"
printf 'done [at=%s]: just finished\n' "$(date +%s)" > "$FM_HOME/state/guards.status"
FM_REAPER_FORCE=1 FM_REAPER_QUIET_SECS=0 "$ROOT/bin/fm-lane-reaper.sh" scan
check test -f "$FM_HOME/state/guards.meta"
printf 'done [at=1000000000]: finished\n' > "$FM_HOME/state/guards.status"
FM_REAPER_FORCE=1 FM_REAPER_IDLE_SECS=0 "$ROOT/bin/fm-lane-reaper.sh" scan
check test -f "$FM_HOME/state/guards.meta"
echo 'PASS safety guards retain lane and dirty bytes'

echo '=== 7: real local merge proof preserves local-only HEAD then tears down; opt-out retains ==='
new_lane mergeoff
extra
"$ROOT/bin/fm-merge-local.sh" mergeoff
check test -f "$FM_HOME/state/mergeoff.meta"
check test "$(git -C "$proj" rev-parse main)" = "$head"
new_lane mergeon
extra
optin
"$ROOT/bin/fm-merge-local.sh" mergeon
check test ! -f "$FM_HOME/state/mergeon.meta"
check test -d "$wt"
check test "$(git -C "$wt" symbolic-ref -q --short HEAD || true)" != "fm/$id"
check test "$(git -C "$proj" rev-parse main)" = "$head"
bundle=("$FM_HOME/data/bundles/mergeon-close."*.bundle)
restore "${bundle[0]}"
echo 'PASS merge immediately closes only opted-in home after preserving unpublished local main'

echo '=== 8: successful windowless legacy teardown must not close another homes same-name window ==='
new_lane unowned
printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$FM_HOME/data/backlog.md"
tasks-axi add unowned 'synthetic legacy task' --kind ship --file "$FM_HOME/data/backlog.md"
tasks-axi start unowned --file "$FM_HOME/data/backlog.md"
# Model a supported legacy record with no endpoint or incarnation.
python3 - "$FM_HOME/state/unowned.meta" <<'PY'
import sys
p=sys.argv[1]
lines=open(p).readlines()
open(p,'w').writelines(l for l in lines if not l.startswith(('window=','spawn_gen=','endpoint_task_id=')))
PY
optin
tmux new-session -d -s firstmate -n supervisor -x 120 -y 30 'sleep 300'
tmux new-window -d -t firstmate: -n fm-unowned sh
before=$(tmux display-message -p -t '=firstmate:=fm-unowned' '#{window_id}')
"$ROOT/bin/fm-merge-local.sh" unowned
check test ! -f "$FM_HOME/state/unowned.meta"
check test -d "$wt"
check test "$(git -C "$wt" symbolic-ref -q --short HEAD || true)" != "fm/$id"
after=$(tmux display-message -p -t '=firstmate:=fm-unowned' '#{window_id}')
check test "$before" = "$after"
tmux list-windows -t =firstmate -F '#{window_id} #{window_name} #{pane_current_command}'
echo 'PASS unowned same-name window survives actual automatic teardown unchanged'
# Drive the same cleanup component on mismatched and exact recorded endpoints.
. "$ROOT/bin/fm-lane-close-lib.sh"
printf 'window=firstmate:other\nbackend=tmux\n' > "$FM_HOME/state/mismatch.meta"
fm_lane_close_window "$(fm_lane_close_window_session "$FM_HOME/state/mismatch.meta" unowned)" unowned
check test "$(tmux display-message -p -t '=firstmate:=fm-unowned' '#{window_id}')" = "$before"
tmux new-window -d -t firstmate: -n fm-idle sh
tmux new-window -d -t firstmate: -n fm-busy "sh -c 'sleep 300; exit 0'"
sleep 0.2
echo 'Before exact endpoint cleanup:'
tmux list-windows -t =firstmate -F '#{window_id} #{window_name} #{pane_current_command}'
fm_lane_close_window firstmate idle
if fm_lane_close_window firstmate busy; then fail 'busy child window reported closed'; fi
if tmux list-windows -t =firstmate -F '#{window_name}' | grep -qxF fm-idle; then fail 'idle window remains'; fi
check tmux display-message -p -t '=firstmate:=fm-busy' '#{window_id}'
echo 'After exact endpoint cleanup:'
tmux list-windows -t =firstmate -F '#{window_id} #{window_name} #{pane_current_command}'
echo 'PASS mismatched endpoint is not guessed; exact idle window closes and child-process window survives'
tmux kill-server

echo 'ALL LIVE CLOSE SCENARIOS PASSED'
