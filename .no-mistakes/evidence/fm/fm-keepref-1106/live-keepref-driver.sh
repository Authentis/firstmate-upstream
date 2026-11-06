#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
EVIDENCE=~/.no-mistakes/evidence/01M6RSSCXTJFX6B4EZ3RAGAEGQ
SOCKET="$ROOT/.validation/t"
export TMPDIR="$ROOT/.validation/tmp"
export GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=user.name GIT_CONFIG_VALUE_0=Lab GIT_CONFIG_KEY_1=user.email GIT_CONFIG_VALUE_1=lab@example.invalid
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
cleanup() {
  tmux -S "$SOCKET" kill-server 2>/dev/null || true
  rm -rf "$ROOT/.validation/live"
}
trap cleanup EXIT
mkdir -p "$ROOT/.validation/live"
tmux -S "$SOCKET" new-session -d -s fm-lab-keepref -n anchor -c "$ROOT" 'sleep 1800'
export TMUX
a=$(tmux -S "$SOCKET" display-message -p '#{socket_path},#{pid},0')
TMUX=$a
for scenario in landed reuse suffix double-collision unwritable detached; do
  LAB="$ROOT/.validation/live/$scenario"
  bash bin/fm-lab-home.sh create "$LAB" >/dev/null
  export FM_HOME="$LAB" HOME="$LAB" TREEHOUSE_ROOT="$LAB/pool"
  mkdir -p "$LAB/tmp"
  export TMPDIR="$LAB/tmp"
  git init -q --bare "$LAB/origin.git"
  git -C "$LAB/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$LAB/origin.git" "$LAB/projects/project" 2>/dev/null
  PROJ="$LAB/projects/project"
  git -C "$PROJ" commit -q --allow-empty -m baseline
  OTHER=$(git -C "$PROJ" rev-parse HEAD)
  git -C "$PROJ" push -q origin main
  (cd "$PROJ" && treehouse get --lease --json --no-fetch -b fm/live-task) > "$LAB/allocation.json"
  WT=$(jq -r .path "$LAB/allocation.json")
  LEASE=$(jq -r .lease_id "$LAB/allocation.json")
  test -d "$WT"
  git -C "$WT" commit -q --allow-empty -m retained-tip
  TIP=$(git -C "$WT" rev-parse HEAD)
  # Synthetic local origin contains the exact landed tip, independent oracle.
  git -C "$WT" push -q origin HEAD:main
  git -C "$PROJ" fetch -q origin
  KEEP=refs/fm-keep/fm/live-task
  SUFFIX="$KEEP-${TIP:0:8}"
  case "$scenario" in
    reuse) git -C "$PROJ" update-ref "$KEEP" "$TIP" ;;
    suffix) git -C "$PROJ" update-ref "$KEEP" "$OTHER" ;;
    double-collision)
      git -C "$PROJ" update-ref "$KEEP" "$OTHER"
      git -C "$PROJ" update-ref "$SUFFIX" "$OTHER" ;;
    unwritable) printf 'block\n' > "$PROJ/.git/refs/fm-keep" ;;
    detached) git -C "$WT" checkout -q --detach; git -C "$PROJ" branch -D fm/live-task >/dev/null ;;
  esac
  tmux -S "$SOCKET" new-window -d -t fm-lab-keepref -n fm-live-task -c "$ROOT" 'sleep 1800'
  printf '%s\n' 'window=fm-lab-keepref:fm-live-task' 'endpoint_task_id=live-task' "worktree=$WT" "project=$PROJ" 'kind=ship' 'mode=local-only' 'backend=tmux' "lease_id=$LEASE" 'spawn_gen=keepref-live' > "$LAB/state/live-task.meta"
  touch "$LAB/state/.last-watcher-beat"
  LOG="$EVIDENCE/live-$scenario.log"
  {
    printf 'Scenario: %s; real fm-teardown + Treehouse + tmux + Git; synthetic local origin\n' "$scenario"
    printf 'tip=%s\nprevious=%s\nlease=%s\n' "$TIP" "$OTHER" "$LEASE"
    printf '\nBEFORE refs:\n'
    git -C "$PROJ" for-each-ref --format='%(refname) %(objectname)' refs/fm-keep refs/heads/fm
    printf '\nBEFORE pool:\n'
    (cd "$PROJ" && treehouse status --json)
  } > "$LOG"
  rc=0
  bash "$ROOT/bin/fm-teardown.sh" live-task >> "$LOG" 2>&1 || rc=$?
  {
    printf '\nteardown exit=%s\nAFTER refs:\n' "$rc"
    git -C "$PROJ" for-each-ref --format='%(refname) %(objectname)' refs/fm-keep refs/heads/fm
    printf '\nAFTER pool:\n'
    (cd "$PROJ" && treehouse status --json)
  } >> "$LOG"
  test "$rc" = 0 || { printf 'FAIL %s: teardown exit %s\n' "$scenario" "$rc"; exit 1; }
  case "$scenario" in
    landed|reuse)
      test "$(git -C "$PROJ" rev-parse "$KEEP")" = "$TIP"
      ! git -C "$PROJ" show-ref --verify --quiet refs/heads/fm/live-task ;;
    suffix)
      test "$(git -C "$PROJ" rev-parse "$KEEP")" = "$OTHER"
      test "$(git -C "$PROJ" rev-parse "$SUFFIX")" = "$TIP"
      ! git -C "$PROJ" show-ref --verify --quiet refs/heads/fm/live-task ;;
    double-collision)
      test "$(git -C "$PROJ" rev-parse "$KEEP")" = "$OTHER"
      test "$(git -C "$PROJ" rev-parse "$SUFFIX")" = "$OTHER"
      test "$(git -C "$PROJ" rev-parse refs/heads/fm/live-task)" = "$TIP"
      test "$(grep -c 'could not record a keep ref for branch fm/live-task' "$LOG")" = 1 ;;
    unwritable)
      test "$(git -C "$PROJ" rev-parse refs/heads/fm/live-task)" = "$TIP"
      test "$(grep -c 'could not record a keep ref for branch fm/live-task' "$LOG")" = 1 ;;
    detached) test -z "$(git -C "$PROJ" for-each-ref --format='%(refname)' refs/fm-keep)" ;;
  esac
  test ! -f "$LAB/state/live-task.meta"
  (cd "$PROJ" && treehouse status --json) | jq -e 'all(.[]; .status == "available")' >/dev/null
  printf '\nVerified: retention contract; task record removed; real pool returned available.\n' >> "$LOG"
  printf 'PASS %s\n' "$scenario"
  rm -rf "$LAB"
  export TMPDIR="$ROOT/.validation/tmp"
done
