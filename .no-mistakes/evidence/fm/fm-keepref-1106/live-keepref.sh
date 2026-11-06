#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
EVIDENCE=~/.no-mistakes/evidence/01M6RMQHTQ4TBG5EEZT7668691
BASE="$ROOT/.test-tmp/live"
mkdir -p "$BASE"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=lab GIT_AUTHOR_EMAIL=lab@example.invalid GIT_COMMITTER_NAME=lab GIT_COMMITTER_EMAIL=lab@example.invalid
export TMPDIR="$ROOT/.test-tmp"
# Every subprocess uses an isolated HOME and no inherited fleet/task overrides.
run_case() (
  name=$1
  C="$BASE/$name"
  mkdir -p "$C"
  LAB=$(mktemp -d "$C/fm-lab.XXXXXX")
  bash bin/fm-lab-home.sh create "$LAB" >/dev/null
  export HOME="$LAB" FM_HOME="$LAB" TREEHOUSE_ROOT="$C/pool" XDG_CONFIG_HOME="$LAB/config" XDG_DATA_HOME="$LAB/data" XDG_CACHE_HOME="$LAB/cache"
  trap 'tmux -S "$ROOT/.test-tmp/live.sock" kill-server 2>/dev/null || true; rm -rf "$C"' EXIT
  printf 'manual\n' > "$LAB/config/backlog-backend"
  git init -q --bare --initial-branch=main "$C/origin.git"
  git clone -q "$C/origin.git" "$C/project" 2>/dev/null
  git -C "$C/project" commit -q --allow-empty -m baseline
  git -C "$C/project" push -q origin main
  old=$(git -C "$C/project" rev-parse HEAD)
  lease=$(cd "$C/project" && treehouse get --lease --json --no-fetch -b fm/keepref-live)
  printf 'allocation: %s\n' "$lease"
  wt=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["path"])' <<< "$lease")
  lid=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["lease_id"])' <<< "$lease")
  printf 'saved feature\n' > "$wt/feature.txt"
  git -C "$wt" add feature.txt
  git -C "$wt" commit -q -m feature
  tip=$(git -C "$wt" rev-parse HEAD)
  git -C "$wt" push -q origin HEAD:main
  git -C "$C/project" fetch -q origin
  export TMUX="$(tmux -S "$ROOT/.test-tmp/live.sock" new-session -d -s fm-lab-keepref -P -F '#{socket_path},#{pid},0' 'sleep 600')"
  tmux new-window -d -t fm-lab-keepref -n fm-keepref-live 'sleep 600'
  cat > "$LAB/state/keepref-live.meta" <<META
window=fm-lab-keepref:fm-keepref-live
endpoint_task_id=keepref-live
spawn_gen=keepref-live-generation
backend=tmux
worktree=$wt
project=$C/project
kind=ship
mode=local-only
lease_id=$lid
META
  touch "$LAB/state/.last-watcher-beat"
  base=refs/fm-keep/fm/keepref-live
  suffix="$base-${tip:0:8}"
  case "$name" in
    same) git -C "$C/project" update-ref "$base" "$tip" ;;
    collision|double-collision)
      git -C "$C/project" update-ref "$base" "$old"
      if [ "$name" = double-collision ]; then git -C "$C/project" update-ref "$suffix" "$old"; fi ;;
    unwritable) printf 'blocked\n' > "$C/project/.git/refs/fm-keep" ;;
    foreign-lease) printf 'lease_id=not-the-owner\n' > "$LAB/state/keepref-live.meta.new"; python3 - "$LAB/state/keepref-live.meta" <<'PY'
import sys
p=sys.argv[1]
s=open(p).read().splitlines()
open(p,'w').write('\n'.join('lease_id=not-the-owner' if l.startswith('lease_id=') else l for l in s)+'\n')
PY
      rm "$LAB/state/keepref-live.meta.new" ;;
    gone-pool) (cd "$C/project" && treehouse return --if-lease-id "$lid" "$wt") ;;
  esac
  printf 'BEFORE tip=%s previous=%s\n' "$tip" "$old"
  git -C "$C/project" for-each-ref --format='%(refname) %(objectname)' refs/heads/fm refs/fm-keep
  rc=0
  bash bin/fm-teardown.sh keepref-live > "$EVIDENCE/$name.stdout" 2> "$EVIDENCE/$name.stderr" || rc=$?
  printf 'teardown exit=%s\n' "$rc"
  printf '%s\n' '--- stdout ---'; cat "$EVIDENCE/$name.stdout"
  printf '%s\n' '--- stderr ---'; cat "$EVIDENCE/$name.stderr"
  printf '%s\n' '--- persisted refs ---'
  git -C "$C/project" for-each-ref --format='%(refname) %(objectname)' refs/heads/fm refs/fm-keep
  printf '%s\n' '--- pool ---'
  (cd "$C/project" && treehouse status --json)
  actual=$(git -C "$C/project" rev-parse --verify -q "$base" || true)
  branch=$(git -C "$C/project" rev-parse --verify -q refs/heads/fm/keepref-live || true)
  actual_suffix=$(git -C "$C/project" rev-parse --verify -q "$suffix" || true)
  case "$name" in
    landed|same) [ "$rc" = 0 ] && [ "$actual" = "$tip" ] && [ -z "$branch" ] ;;
    collision) [ "$rc" = 0 ] && [ "$actual" = "$old" ] && [ "$actual_suffix" = "$tip" ] && [ -z "$branch" ] ;;
    double-collision) [ "$rc" = 0 ] && [ "$actual" = "$old" ] && [ "$actual_suffix" = "$old" ] ;;
    unwritable) [ "$rc" = 0 ] && [ "$branch" = "$tip" ] && [ "$(grep -c 'could not record a keep ref for branch fm/keepref-live' "$EVIDENCE/$name.stderr")" = 1 ] ;;
    foreign-lease) [ "$rc" = 1 ] && [ "$branch" = "$tip" ] && [ -z "$actual" ] && [ -f "$LAB/state/keepref-live.meta" ] ;;
    gone-pool) [ "$rc" = 0 ] && [ "$branch" = "$tip" ] && [ -z "$actual" ] && git -C "$C/project" bundle verify "$LAB/data/bundles/keepref-live.bundle" ;;
  esac
)
failures=0
for name in landed same collision double-collision unwritable foreign-lease gone-pool; do
  echo "=== $name ==="
  if run_case "$name" > "$EVIDENCE/$name.log" 2>&1; then echo "$name: PASS"; else echo "$name: FAIL"; failures=$((failures+1)); fi
done
rm -rf "$BASE"
exit "$failures"
