#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
E=~/.no-mistakes/evidence/01M66J43JFVBFMC5S2DQNZTSTE
mkdir -p "$E" .live
SCENARIO=${1:-missing}
LAB="$PWD/.live/home"
bin/fm-lab-home.sh create "$LAB"
export FM_HOME="$LAB" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=Lab GIT_AUTHOR_EMAIL=lab@example.invalid GIT_COMMITTER_NAME=Lab GIT_COMMITTER_EMAIL=lab@example.invalid
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
export TMUX_TMPDIR="$PWD/.live"
mkdir -p "$TMUX_TMPDIR"
cleanup() { tmux -L fm-lab kill-server 2>/dev/null || true; rm -rf "$ROOT/.live"; }
trap cleanup EXIT
# Private server and disposable project; no harness primary is needed to call the teardown CLI.
tmux -L fm-lab new-session -d -s firstmate -x 100 -y 30 'sleep 600'
export TMUX="$TMUX_TMPDIR/tmux-$(id -u)/fm-lab,0,0"
P="$LAB/projects/project"
git init -q --bare --initial-branch=main "$LAB/origin.git"
git clone -q "$LAB/origin.git" "$P"
printf 'baseline\n' > "$P/readme"
git -C "$P" add readme
git -C "$P" commit -qm baseline
git -C "$P" push -q origin main
export TREEHOUSE_ROOT="$LAB/pool"
cd "$P"
treehouse get --lease --json --no-fetch -b fm/task-live > "$LAB/lease.json"
WT=$(jq -r .path "$LAB/lease.json")
LEASE=$(jq -r .lease_id "$LAB/lease.json")
printf 'lane\n' > "$WT/feature"
git -C "$WT" add feature
git -C "$WT" commit -qm lane
case "$SCENARIO" in *unpushed*) ;; *) git -C "$WT" push -q origin fm/task-live ;; esac
HEAD=$(git -C "$WT" rev-parse HEAD)
cd "$ROOT"
cat > "$LAB/state/task-live.meta" <<EOF
window=firstmate:fm-task-live
endpoint_task_id=task-live
worktree=$WT
project=$P
kind=ship
mode=local-only
spawn_gen=lab-live
lease_id=$LEASE
EOF
touch "$LAB/state/.last-watcher-beat"
echo '=== allocated real treehouse slot ==='
cat "$LAB/lease.json"
echo "=== scenario $SCENARIO ==="
FLAG=
case "$SCENARIO" in
 missing|dirty-force|unpushed-force|missing-copy)
  export TREEHOUSE_ROOT="$LAB/empty-pool"
  mkdir -p "$TREEHOUSE_ROOT"
  ;;
 null|null-dirty-force|null-unpushed-force|foreign-force)
  echo '=== real treehouse lease release ==='
  (cd "$P" && treehouse return --force --if-lease-id "$LEASE" "$WT")
  git -C "$WT" checkout -q fm/task-live
  if [ "$SCENARIO" = foreign-force ]; then
   (cd "$P" && treehouse lease 1 --json)
  fi
  ;;
esac
case "$SCENARIO" in
 dirty-force|null-dirty-force) printf 'do not delete\n' > "$WT/sentinel"; FLAG=--force ;;
 unpushed-force|null-unpushed-force|foreign-force) FLAG=--force ;;
 missing-copy) mv "$WT" "$WT.absent" ;;
esac
(cd "$P" && treehouse status --json)
set +e
bash "${TEARDOWN_CLI:-bin/fm-teardown.sh}" task-live ${FLAG:+"$FLAG"}
RC=$?
set -e
echo "TEARDOWN_EXIT=$RC"
echo "RECORD_PRESENT=$([ -f "$LAB/state/task-live.meta" ] && echo yes || echo no)"
if [ -d "$WT" ]; then echo "HEAD=$(git -C "$WT" rev-parse HEAD) BRANCH=$(git -C "$WT" symbolic-ref --short HEAD)"; fi
if [ -f "$LAB/data/bundles/task-live.bundle" ]; then
 git -C "$P" bundle verify "$LAB/data/bundles/task-live.bundle"
 git bundle list-heads "$LAB/data/bundles/task-live.bundle"
fi
case "$SCENARIO" in
 missing|null)
  [ "$RC" = 0 ]
  [ ! -f "$LAB/state/task-live.meta" ]
  [ -f "$LAB/data/bundles/task-live.bundle" ]
  ;;
 *)
  [ "$RC" = 1 ]
  [ -f "$LAB/state/task-live.meta" ]
  [ ! -f "$LAB/data/bundles/task-live.bundle" ]
  ;;
esac
if [ -d "$WT" ]; then
 [ "$(git -C "$WT" rev-parse HEAD)" = "$HEAD" ]
 [ "$(git -C "$WT" symbolic-ref --short HEAD)" = fm/task-live ]
fi
case "$SCENARIO" in *dirty*) [ "$(< "$WT/sentinel")" = 'do not delete' ] ;; esac
echo "SCENARIO_VERIFIED=$SCENARIO"
