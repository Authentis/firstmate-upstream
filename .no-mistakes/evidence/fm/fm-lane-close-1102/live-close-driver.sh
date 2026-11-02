#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
BASE="$PWD/.test-tmp/live"
mkdir -p "$BASE"
export PATH="$PWD/.test-tmp/tools/usr/bin:/usr/bin:/bin"
export TMPDIR="$PWD/.test-tmp"
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=advice.detachedHead GIT_CONFIG_VALUE_0=false
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=Lab GIT_AUTHOR_EMAIL=lab@example.test GIT_COMMITTER_NAME=Lab GIT_COMMITTER_EMAIL=lab@example.test
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_TEST_SEAM FM_GATE_REFUSE_BYPASS FM_LANE_CLOSE_TEARDOWN FM_REAPER_CREW_STATE FM_REAPER_CPU_CMD FM_REAPER_CONTROL
export TMUX="$BASE/s,1,0" FM_CREW_STATE_NO_FORGE=1
cleanup() { for sock in "$BASE"/s-*; do tmux -S "$sock" kill-server 2>/dev/null || true; done; rm -rf "$BASE"; }
trap cleanup EXIT
new_world() {
 local name=$1
 export FM_HOME="$BASE/$name"
 "$ROOT/bin/fm-lab-home.sh" create "$FM_HOME"
 export TREEHOUSE_ROOT="$FM_HOME/pool"
 git init -q --bare --initial-branch=main "$FM_HOME/origin.git"
 git clone -q "$FM_HOME/origin.git" "$FM_HOME/project" 2>/dev/null
 git -C "$FM_HOME/project" commit -q --allow-empty -m baseline
 git -C "$FM_HOME/project" push -q -u origin main
 WT=$(cd "$FM_HOME/project" && treehouse get --lease --no-fetch --base main -b fm/finished)
 echo durable-payload > "$WT/payload.txt"
 git -C "$WT" add payload.txt
 git -C "$WT" commit -q -m finished
 HEAD=$(git -C "$WT" rev-parse HEAD)
 cat > "$FM_HOME/state/finished.meta" <<EOF
kind=ship
worktree=$WT
project=$FM_HOME/project
branch=fm/finished
mode=local-only
harness=claude
window=lab:fm-finished
endpoint_task_id=finished
spawn_gen=lab-finished
EOF
 # Local default branch is authoritative completion for a local-only ship.
 if [ "${2:-landed}" = landed ]; then git -C "$FM_HOME/project" merge -q --ff-only fm/finished; fi
 export TMUX="$BASE/s-$name,1,0"
 tmux -S "$BASE/s-$name" new-session -d -s lab -n fm-finished -c "$ROOT" 'sleep 3600'
 "$ROOT/bin/fm-busy-event.sh" arm "$FM_HOME/state" finished --state idle --source fm-recovery --event lab-settled
 printf 'done [at=%s]: head %s complete\n' "$(($(date +%s)-10800))" "$HEAD" > "$FM_HOME/state/finished.status"
 touch -d '3 hours ago' "$WT/payload.txt"
 mkdir -p "$FM_HOME/state/.lane-reaper-seen"
 echo "$(($(date +%s)-7200))" > "$FM_HOME/state/.lane-reaper-seen/finished.idle"
}
scan() { FM_REAPER_FORCE=1 "$ROOT/bin/fm-lane-reaper.sh" scan; }
new_world optin
printf '\n== Actual crew state ==\n'
"$ROOT/bin/fm-crew-state.sh" finished
printf '\n== Closing default OFF ==\n'
scan
[ -f "$FM_HOME/state/finished.meta" ]
[ ! -d "$FM_HOME/data/bundles" ]
touch "$FM_HOME/config/lane-close-live"
printf '\n== Actual teardown after opt-in ==\n'
scan
if [ -f "$FM_HOME/state/finished.meta" ]; then
 echo 'Direct teardown diagnostic:'
 "$ROOT/bin/fm-teardown.sh" finished
 exit 1
fi
printf 'Observable: task metadata retired; backup restore follows\n'
for bundle in "$FM_HOME/data/bundles/"*.bundle; do
 git clone -q "$bundle" "$FM_HOME/restored"
done
[ "$(git -C "$FM_HOME/restored" rev-parse HEAD)" = "$HEAD" ]
[ "$(cat "$FM_HOME/restored/payload.txt")" = durable-payload ]
echo 'RESTORED: exact pre-close HEAD and payload.txt from standalone bundle'
new_world dirty
touch "$FM_HOME/config/lane-close-live"
echo uncommitted >> "$WT/payload.txt"
touch -d '3 hours ago' "$WT/payload.txt"
printf '\n== Adversarial dirty lane ==\n'
scan
[ -f "$FM_HOME/state/finished.meta" ]
grep -q uncommitted "$WT/payload.txt"
echo 'KEPT: task record and uncommitted payload'

count_bundles() { find "$FM_HOME/data/bundles" -maxdepth 1 -name '*.bundle' | wc -l; }
new_world retry unlanded
# No-mistakes handoff statuses are accepted without a named-head publication
# gate; this checks closing safety for locally finished but unlanded work.
sed -i 's/mode=local-only/mode=no-mistakes/' "$FM_HOME/state/finished.meta"
touch "$FM_HOME/config/lane-close-live"
printf '\n== Refused close retries reuse one restorable archive ==\n'
"$ROOT/bin/fm-crew-state.sh" finished
scan
[ -f "$FM_HOME/state/finished.meta" ]
[ "$(count_bundles)" -eq 1 ]
scan
[ -f "$FM_HOME/state/finished.meta" ]
[ "$(count_bundles)" -eq 1 ]
echo 'RETRY: record retained and one archive after two refused closes'
for bundle in "$FM_HOME/data/bundles/"*.bundle; do break; done
python3 - "$bundle" <<'CORRUPT'
import sys
p=sys.argv[1]
b=open(p,'rb').read()
open(p,'wb').write(b[:b.index(b'\n\n')+2]+b'PACK')
CORRUPT
printf '\n== Header-valid payload corruption ==\n'
git -C "$WT" bundle verify "$bundle"
git bundle list-heads "$bundle"
if git clone --bare -q "$bundle" "$FM_HOME/broken-restore"; then
 echo 'ERROR: corrupt archive restored'; exit 1
else
 echo 'Confirmed: original payload cannot restore despite a valid header'
fi
scan
[ "$(count_bundles)" -eq 2 ]
for replacement in "$FM_HOME/data/bundles/"*.bundle; do
 [ "$replacement" != "$bundle" ] || continue
 git clone -q "$replacement" "$FM_HOME/replacement"
done
[ "$(git -C "$FM_HOME/replacement" rev-parse HEAD)" = "$HEAD" ]
[ "$(cat "$FM_HOME/replacement/payload.txt")" = durable-payload ]
scan
[ "$(count_bundles)" -eq 2 ]
echo 'REPLACED: damaged payload rejected; replacement restored exact HEAD and data; next retry reused replacement'

new_world pushfail
touch "$FM_HOME/config/lane-close-live"
git -C "$WT" branch --set-upstream-to=origin/main fm/finished
printf '#!/bin/sh\nexit 1\n' > "$FM_HOME/origin.git/hooks/pre-receive"
chmod +x "$FM_HOME/origin.git/hooks/pre-receive"
printf '\n== Real upstream rejects push, then recovers ==\n'
scan
[ -f "$FM_HOME/state/finished.meta" ]
[ "$(count_bundles)" -eq 1 ]
scan
[ -f "$FM_HOME/state/finished.meta" ]
[ "$(count_bundles)" -eq 1 ]
rm "$FM_HOME/origin.git/hooks/pre-receive"
scan
[ ! -f "$FM_HOME/state/finished.meta" ]
[ "$(git -C "$FM_HOME/origin.git" rev-parse main)" = "$HEAD" ]
echo 'RECOVERED: unchanged done status retried, remote main now equals saved HEAD, task retired'

new_world mirror
git -C "$WT" remote rename origin no-mistakes
git -C "$WT" push -q -u no-mistakes fm/finished
touch "$FM_HOME/config/lane-close-live"
printf '\n== Validation mirror is not durable remote evidence ==\n'
scan
[ ! -f "$FM_HOME/state/finished.meta" ]
[ "$(count_bundles)" -eq 1 ]
for bundle in "$FM_HOME/data/bundles/"*.bundle; do git clone -q "$bundle" "$FM_HOME/restored"; done
[ "$(git -C "$FM_HOME/restored" rev-parse HEAD)" = "$HEAD" ]
echo 'PRESERVED: mirror-only HEAD independently restored after real teardown'

new_world merge-on unlanded
touch "$FM_HOME/config/lane-close-live"
printf '\n== Local merge immediately performs preserved teardown ==\n'
"$ROOT/bin/fm-merge-local.sh" finished
[ ! -f "$FM_HOME/state/finished.meta" ]
[ "$(git -C "$FM_HOME/project" rev-parse main)" = "$HEAD" ]
for bundle in "$FM_HOME/data/bundles/"*.bundle; do git clone -q "$bundle" "$FM_HOME/restored"; done
[ "$(git -C "$FM_HOME/restored" rev-parse HEAD)" = "$HEAD" ]
echo 'LANDED AND CLOSED: local main fast-forwarded, metadata retired, original HEAD independently restored'

new_world merge-off unlanded
printf '\n== Local merge with live closing disabled ==\n'
"$ROOT/bin/fm-merge-local.sh" finished
[ -f "$FM_HOME/state/finished.meta" ]
[ "$(git -C "$FM_HOME/project" rev-parse main)" = "$HEAD" ]
[ ! -d "$FM_HOME/data/bundles" ]
echo 'LANDED ONLY: local main advanced; task, endpoint, and copy remain without close approval'

new_world pushed
git -C "$WT" push -q -u origin fm/finished
touch "$FM_HOME/config/lane-close-live"
printf '\n== Real remote already holds HEAD ==\n'
scan
[ ! -f "$FM_HOME/state/finished.meta" ]
[ ! -d "$FM_HOME/data/bundles" ]
[ "$(git -C "$FM_HOME/origin.git" rev-parse fm/finished)" = "$HEAD" ]
echo 'CLOSED: real remote retains original HEAD; no redundant bundle needed'

new_world mergeblocked unlanded
touch "$FM_HOME/config/lane-close-live"
: > "$FM_HOME/data/bundles"
printf '\n== After-merge preservation storage unavailable ==\n'
"$ROOT/bin/fm-merge-local.sh" finished
[ -f "$FM_HOME/state/finished.meta" ]
[ "$(git -C "$WT" rev-parse HEAD)" = "$HEAD" ]
[ "$(git -C "$FM_HOME/project" rev-parse main)" = "$HEAD" ]
tmux -S "${TMUX%%,*}" has-session -t lab
echo 'REFUSED SAFELY: merge landed but task, worktree HEAD, and endpoint retained without a backup'

new_world mergedirty unlanded
touch "$FM_HOME/config/lane-close-live"
echo unsaved >> "$WT/payload.txt"
printf '\n== After-merge teardown still refuses dirty lane ==\n'
"$ROOT/bin/fm-merge-local.sh" finished
[ -f "$FM_HOME/state/finished.meta" ]
grep -q unsaved "$WT/payload.txt"
[ "$(git -C "$FM_HOME/project" rev-parse main)" = "$HEAD" ]
tmux -S "${TMUX%%,*}" has-session -t lab
echo 'REFUSED SAFELY: merge remains successful, uncommitted edits and live endpoint retained'
