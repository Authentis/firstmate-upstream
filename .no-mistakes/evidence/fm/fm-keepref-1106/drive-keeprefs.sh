#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
EVIDENCE=~/.no-mistakes/evidence/01M6RMQHTQ4TBG5EEZT7668691
SCRATCH="$ROOT/.keepref-live"
TREEHOUSE=$(command -v treehouse)
mkdir -p "$SCRATCH/tools"
ln -sf "$TREEHOUSE" "$SCRATCH/tools/treehouse"
export PATH="$SCRATCH/tools:/usr/bin:/bin"
# Every command is real; omit forge/pipeline clients so synthetic local repos
# cannot reach operator accounts or control any pipeline.
unset FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=lab GIT_AUTHOR_EMAIL=lab@example.invalid GIT_COMMITTER_NAME=lab GIT_COMMITTER_EMAIL=lab@example.invalid
export TMUX="$SCRATCH/s,0,0"
cleanup() { tmux -S "$SCRATCH/s" kill-server 2>/dev/null || true; rm -rf "$SCRATCH"; }
trap cleanup EXIT
tmux -S "$SCRATCH/s" new-session -d -s lab -x 100 -y 30 -c "$ROOT" 'sleep 1800'
run_case() {
  local name=$1 c="$SCRATCH/$1" tip other lease wt keep suffix rc
  mkdir -p "$c"
  bash bin/fm-lab-home.sh create "$c/home"
  mkdir -p "$c/home/user" "$c/home/tmp"
  export HOME="$c/home/user" TMPDIR="$c/home/tmp" FM_HOME="$c/home"
  printf 'manual\n' > "$FM_HOME/config/backlog-backend"
  git init -q --bare --initial-branch=main "$c/origin.git"
  git clone -q "$c/origin.git" "$c/project"
  git -C "$c/project" commit -q --allow-empty -m baseline
  git -C "$c/project" push -q origin main
  git -C "$c/project" remote set-head origin main
  export TREEHOUSE_ROOT="$c/pool"
  (cd "$c/project" && treehouse get --lease --json --no-fetch -b fm/keepref-live) > "$c/lease.json"
  cat "$c/lease.json"
  wt=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["path"])' "$c/lease.json")
  lease=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["lease_id"])' "$c/lease.json")
  other=$(git -C "$wt" rev-parse HEAD)
  printf '%s\n' "$name" > "$wt/work.txt"
  git -C "$wt" add work.txt
  git -C "$wt" commit -q -m "landed $name"
  tip=$(git -C "$wt" rev-parse HEAD)
  git -C "$wt" push -q origin HEAD:main
  git -C "$c/project" fetch -q origin
  keep=refs/fm-keep/fm/keepref-live
  suffix="$keep-${tip:0:8}"
  case "$name" in
    reuse-main) git -C "$wt" update-ref "$keep" "$tip" ;;
    suffix-free) git -C "$wt" update-ref "$keep" "$other" ;;
    reuse-suffix) git -C "$wt" update-ref "$keep" "$other"; git -C "$wt" update-ref "$suffix" "$tip" ;;
    double-collision) git -C "$wt" update-ref "$keep" "$other"; git -C "$wt" update-ref "$suffix" "$other" ;;
    unwritable) printf 'block\n' > "$c/project/.git/refs/fm-keep" ;;
  esac
  tmux -S "$SCRATCH/s" new-window -d -t lab -n fm-keepref-live -c "$ROOT" 'sleep 1800'
  printf 'window=lab:fm-keepref-live\nbackend=tmux\nendpoint_task_id=keepref-live\nworktree=%s\nproject=%s\nkind=ship\nmode=local-only\nspawn_gen=lab-keepref\nlease_id=%s\n' "$wt" "$c/project" "$lease" > "$FM_HOME/state/keepref-live.meta"
  touch "$FM_HOME/state/.last-watcher-beat"
  printf 'CASE=%s TIP=%s OTHER=%s\nBEFORE\n' "$name" "$tip" "$other"
  git -C "$wt" for-each-ref --format='%(refname) %(objectname)' refs/fm-keep refs/heads/fm/
  rc=0
  timeout 90 bash "$ROOT/bin/fm-teardown.sh" keepref-live > "$c/out" 2> "$c/err" || rc=$?
  printf 'TEARDOWN_EXIT=%s\n' "$rc"
  cat "$c/out" "$c/err"
  printf 'AFTER\n'
  git -C "$c/project" for-each-ref --format='%(refname) %(objectname)' refs/fm-keep refs/heads/fm/
  (cd "$c/project" && treehouse status --json)
  [ "$rc" = 0 ]
  case "$name" in
    free|reuse-main) [ "$(git -C "$c/project" rev-parse "$keep")" = "$tip" ] ;;
    suffix-free|reuse-suffix) [ "$(git -C "$c/project" rev-parse "$keep")" = "$other" ]; [ "$(git -C "$c/project" rev-parse "$suffix")" = "$tip" ] ;;
    double-collision) [ "$(git -C "$c/project" rev-parse "$keep")" = "$other" ]; [ "$(git -C "$c/project" rev-parse "$suffix")" = "$other" ] ;;
  esac
  case "$name" in
    double-collision|unwritable)
      [ "$(git -C "$c/project" rev-parse refs/heads/fm/keepref-live)" = "$tip" ]
      [ "$(grep -c 'could not record a keep ref for branch fm/keepref-live' "$c/err")" = 1 ] ;;
    *) ! git -C "$c/project" show-ref --verify --quiet refs/heads/fm/keepref-live ;;
  esac
  [ ! -e "$FM_HOME/state/keepref-live.meta" ]
  printf 'Verified retention contract and task retirement for %s\n' "$name"
  rm -rf "$c"
}
for scenario in free reuse-main suffix-free reuse-suffix double-collision unwritable; do
  run_case "$scenario" > "$EVIDENCE/$scenario.log" 2>&1
done
