#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
EVIDENCE=~/.no-mistakes/evidence/01M6F40MVYZWJ9MMXV2MDX9421
BASE="$ROOT/.validation/live"
mkdir -p "$BASE/bin"
REAL_TMUX=$(command -v tmux)
printf '#!/usr/bin/env bash\ncd %q\nexec %q -f /dev/null -S .validation/live/socket "$@"\n' "$ROOT" "$REAL_TMUX" > "$BASE/bin/tmux"
chmod +x "$BASE/bin/tmux"
export PATH="$BASE/bin:$ROOT/.validation/tools/lsof/usr/bin:$PATH"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=Validation GIT_AUTHOR_EMAIL=validation@example.invalid GIT_COMMITTER_NAME=Validation GIT_COMMITTER_EMAIL=validation@example.invalid
unset TASKS_AXI_FILE TASKS_AXI_BACKEND
unset TMUX FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS FM_TEST_SEAM FM_LANE_CLOSE_TEARDOWN FM_REAPER_CPU_CMD FM_REAPER_CREW_STATE FM_REAPER_CONTROL FM_REAPER_NOW FM_REAPER_FORCE FM_REAPER_LIVE FM_TASK_ID
cleanup() { tmux kill-server >/dev/null 2>&1 || true; rm -rf "$BASE"; }
trap cleanup EXIT
check() { if ! eval "$1"; then echo "ASSERTION FAILED: $1"; exit 1; fi; }
world() {
  H="$BASE/$1"; export FM_HOME="$H"
  "$ROOT/bin/fm-lab-home.sh" create "$H"
  P="$H/projects/repo"
  export TREEHOUSE_ROOT="$H/pool"
  git init -q --bare "$H/remote.git"
  git init -q -b main "$P"
  printf 'base\n' > "$P/file"; git -C "$P" add .; git -C "$P" commit -qm base
  git -C "$P" remote add origin "$H/remote.git"; git -C "$P" push -qu origin main
  git -C "$H/remote.git" symbolic-ref HEAD refs/heads/main
  git -C "$P" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  (cd "$P" && treehouse get --lease --json --lease-holder fm-test --base main --no-fetch -b fm/test) > "$H/lease.json"
  cat "$H/lease.json"
  W=$(jq -er .path "$H/lease.json")
  LEASE=$(jq -er .lease_id "$H/lease.json")
  printf 'lane payload %s\n' "$1" > "$W/payload"; git -C "$W" add .; git -C "$W" commit -qm payload
  HEAD_SAVED=$(git -C "$W" rev-parse HEAD)
  tmux new-session -d -s "fm-lab-$1" -n supervisor -x 120 -y 32 sh
  tmux new-window -d -t "fm-lab-$1:" -n fm-test sh
  printf 'kind=ship\nmode=local-only\nworktree=%s\nproject=%s\nbranch=fm/test\nbackend=tmux\nharness=claude\nwindow=fm-lab-%s:fm-test\n' "$W" "$P" "$1" > "$H/state/test.meta"
  printf 'lease_id=%s\n' "$LEASE" >> "$H/state/test.meta"
  # Synthetic lifecycle event through the production event API, not a fake
  # crew-state/teardown executable. This exercises local closing, not an LLM.
  "$ROOT/bin/fm-busy-event.sh" arm "$H/state" test --state idle --source fm-recovery --event synthetic-turn-end
  printf 'done [at=%s]: ready in branch fm/test\n' "$(($(date +%s)-10800))" > "$H/state/test.status"
  mkdir -p "$H/state/.lane-reaper-seen"
  printf '%s\n' "$(($(date +%s)-7200))" > "$H/state/.lane-reaper-seen/test.idle"
  age
}
age() { find "$W" -type f ! -name .git -exec touch -d '3 hours ago' {} +; }
scan() {
  rm -f "$H/state/.lane-reaper-last"
  "$ROOT/bin/fm-crew-state.sh" test
  "$ROOT/bin/fm-lane-reaper.sh" scan | tee "$H/last-output"
}
optin() { touch "$H/config/lane-close-live"; }
closed() {
  if [ -e "$H/state/test.meta" ]; then
    echo 'DIAGNOSTIC: direct ordinary teardown for unexpectedly retained lane:'
    "$ROOT/bin/fm-teardown.sh" test || true
    echo 'ASSERTION FAILED: expected automatic close'; exit 1
  fi
  check '[ -z "$(git -C "$W" status --porcelain)" ]'
  printf 'Returned slot current branch: '; git -C "$W" rev-parse --abbrev-ref HEAD
  (cd "$P" && treehouse status --json) | tee "$H/pool-after.json"
  check 'jq -e "length == 1 and all(.[]; .status == \"available\" and .lease_id == \"\")" "$H/pool-after.json" >/dev/null'
  check '! git -C "$P" show-ref --verify --quiet refs/heads/fm/test'
}
kept() { check '[ -f "$H/state/test.meta" ]'; check '[ -d "$W" ]'; }
bundle_count() { find "$H/data/bundles" -maxdepth 1 -name '*.bundle' | wc -l; }
restore() {
  local f found=0
  rm -rf "$H/restored"
  for f in "$H/data/bundles/"*.bundle; do
    if git clone -q --bare "$f" "$H/restored" 2>/dev/null; then
      if [ "$(git -C "$H/restored" rev-parse HEAD)" = "$HEAD_SAVED" ] && git -C "$H/restored" fsck --full --strict; then
        printf 'Standalone restore HEAD=%s payload=' "$HEAD_SAVED"; git -C "$H/restored" show HEAD:payload
        found=1; break
      fi
    fi
    rm -rf "$H/restored"
  done
  check '[ "$found" = 1 ]'
}

echo '=== 1 default-off reaper and merge ==='
world off
git -C "$W" push -qu origin fm/test
# Neither the unrelated ending opt-in nor obsolete env activation enables closing.
touch "$H/config/lane-reaper-live"
FM_REAPER_CLOSE_LIVE=1 scan
kept
"$ROOT/bin/fm-merge-local.sh" test
kept
check '[ ! -d "$H/data/bundles" ]'
echo 'OBSERVED: dry-run only; worktree and record survive both entrypoints.'

echo '=== 2 pushed and unpushed done lanes close ==='
world pushed; git -C "$W" push -qu origin fm/test; optin; scan; closed
check '[ ! -d "$H/data/bundles" ]'
echo 'OBSERVED: pushed clean lane record removed and pool slot returned through ordinary teardown.'
world unpushed; git -C "$W" push -qu origin fm/test
echo extra >> "$W/payload"; git -C "$W" commit -qam extra; HEAD_SAVED=$(git -C "$W" rev-parse HEAD); age
optin; scan; closed
check '[ "$(git -C "$H/remote.git" rev-parse fm/test)" = "$HEAD_SAVED" ]'
restore
echo 'OBSERVED: upstream contains exact final HEAD; bundle restores after lane record/branch removal and pool return.'

echo '=== 3 dirty and non-done lanes remain ==='
world dirty; git -C "$W" push -qu origin fm/test; optin
printf 'do not lose\n' > "$W/untracked"; age; scan; kept
check '[ "$(cat "$W/untracked")" = "do not lose" ]'
"$ROOT/bin/fm-teardown.sh" test > "$H/dirty-teardown" 2>&1 && { echo 'dirty teardown unexpectedly succeeded'; exit 1; } || rc=$?
printf 'Direct ordinary teardown rc=%s\n' "$rc"; cat "$H/dirty-teardown"; kept
world paused; git -C "$W" push -qu origin fm/test; optin
printf 'paused [at=%s]: waiting\n' "$(($(date +%s)-10800))" > "$H/state/test.status"; scan; kept
printf 'working [at=%s]: active work\n' "$(date +%s)" > "$H/state/test.status"; scan; kept
echo 'OBSERVED: no dirty, paused, or working lane closed.'

echo '=== 4 unlanded retries, same-HEAD reuse, corruption, new HEAD ==='
world retry; optin; scan; kept
check '[ "$(bundle_count)" = 1 ]'; restore
scan; kept; check '[ "$(bundle_count)" = 1 ]'
first=$(find "$H/data/bundles" -name '*.bundle' -print -quit)
python3 - "$first" <<'PY'
import sys
p=sys.argv[1]
b=open(p,'rb').read(); end=b.index(b'\n\n')+2
open(p,'wb').write(b[:end]+b'PACK')
PY
git -C "$W" bundle verify "$first"
if git clone -q --bare "$first" "$H/broken" 2> "$H/corrupt-error"; then echo 'corrupt pack restored unexpectedly'; exit 1; fi
cat "$H/corrupt-error"
scan; kept; check '[ "$(bundle_count)" = 2 ]'; restore
scan; kept; check '[ "$(bundle_count)" = 2 ]'
echo newer >> "$W/payload"; git -C "$W" commit -qam newer; HEAD_SAVED=$(git -C "$W" rev-parse HEAD); age
scan; kept; check '[ "$(bundle_count)" = 3 ]'; restore
git -C "$P" merge -q --ff-only fm/test
scan; closed; check '[ "$(bundle_count)" = 3 ]'; restore
echo 'OBSERVED: repeated refusal retries without duplicate bundles; damaged pack replaced; changed HEAD saved; later landing closes.'

echo '=== 5 upstream outage then recovery ==='
world outage; git -C "$W" push -qu origin fm/test
echo late >> "$W/payload"; git -C "$W" commit -qam late; HEAD_SAVED=$(git -C "$W" rev-parse HEAD); age
mv "$H/remote.git" "$H/offline.git"; optin
scan; kept; check '[ "$(bundle_count)" = 1 ]'; restore
scan; kept; check '[ "$(bundle_count)" = 1 ]'
mv "$H/offline.git" "$H/remote.git"
scan; closed; check '[ "$(git -C "$H/remote.git" rev-parse fm/test)" = "$HEAD_SAVED" ]'; restore
echo 'OBSERVED: failed push keeps lane and backup; unchanged done status retries after recovery and closes.'

echo '=== 6 mirror-only refs do not replace independent backup ==='
world mirror
# Retain origin's base-only identity so Treehouse still finds the original pool;
# only the validation mirror receives the lane's new commit.
git init -q --bare "$H/mirror.git"
git -C "$W" remote add no-mistakes "$H/mirror.git"
git -C "$W" push -qu no-mistakes fm/test
optin; scan; kept; check '[ "$(bundle_count)" = 1 ]'; restore
git -C "$P" merge -q --ff-only fm/test
scan; closed; restore
echo 'OBSERVED: mirror-only commit gets standalone backup; unlanded work refused; landed local work closes safely.'

echo '=== 7 immediate local merge close and preservation failure ==='
world merge; optin
"$ROOT/bin/fm-merge-local.sh" test
closed; check '[ "$(git -C "$P" rev-parse main)" = "$HEAD_SAVED" ]'; restore
world preserve-fails; optin; touch "$H/data/bundles"
"$ROOT/bin/fm-merge-local.sh" test
kept; check '[ "$(git -C "$P" rev-parse main)" = "$HEAD_SAVED" ]'
echo 'OBSERVED: merge success survives failed preservation, but teardown is withheld.'

echo '=== 8 windowless teardown does not claim another same-name window ==='
world windowless; git -C "$W" push -qu origin fm/test; optin
# Legacy windowless teardown requires an owned backlog row to validate and close.
printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$H/data/backlog.md"
printf 'backend = "markdown"\n[markdown]\npath = "data/backlog.md"\n' > "$H/.tasks.toml"
tasks-axi add test 'windowless teardown lab' --kind ship --file "$H/data/backlog.md"
tasks-axi start test --file "$H/data/backlog.md"
# The real crew-state correctly refuses to infer done with no recorded endpoint;
# drive this legacy windowless case through the after-merge consumer instead.
python3 - "$H/state/test.meta" <<'PY'
import sys
p=sys.argv[1]; lines=open(p).readlines(); open(p,'w').writelines(x for x in lines if not x.startswith('window='))
PY
# firstmate is merely a name on this isolated private socket, not the fleet.
tmux new-session -d -s firstmate -n supervisor -x 120 -y 32 sh
tmux new-window -d -t firstmate: -n fm-test sh
tmux list-windows -t =firstmate -F '#{window_id} #{window_name} #{pane_current_command}'
"$ROOT/bin/fm-merge-local.sh" test; closed
tmux list-windows -t =firstmate -F '#{window_id} #{window_name} #{pane_current_command}' | tee "$H/windows"
check 'grep -q " fm-test sh$" "$H/windows"'
echo 'OBSERVED: windowless lane record removed and pool slot returned; unrelated idle same-name window retained.'

echo 'ALL LIVE CLOSE SCENARIOS COMPLETED'
