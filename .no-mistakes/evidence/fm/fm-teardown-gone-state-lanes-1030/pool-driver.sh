#!/usr/bin/env bash
set -eu
ROOT=$PWD L=$PWD/.test-live
WT=$L/pool/.treehouse/project-414bee/1/project
export FM_HOME=$L/home FM_ROOT_OVERRIDE=$ROOT FM_STATE_OVERRIDE=$L/home/state FM_CONFIG_OVERRIDE=$L/home/config TMUX="$ROOT/.t,0,0"
unset FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS FM_TEST_SEAM TASKS_AXI_FILE TASKS_AXI_BACKEND
export TREEHOUSE_ROOT=$L/pool
# Publish real lane-only work (not in origin/main), so the happy path must recognize a pushed branch.
printf 'published lane work\n' > "$WT/shipped.txt"
git -C "$WT" add shipped.txt
git -C "$WT" -c user.name=lab -c user.email=lab@example.invalid commit -qm 'published lane work'
git -C "$WT" push -q origin fm/lab
# A real clean return clears the disposable slot's lease. Re-check out the saved branch.
treehouse return "$WT"
git -C "$WT" checkout -q fm/lab
for scenario in missing-lease dirty-force unpushed-force foreign-force gone-listing gone-dirty-force gone-unpushed-force; do
 echo "=== $scenario: real teardown, Treehouse and Git, disposable local origin ==="
 export TREEHOUSE_ROOT=$L/pool
 if [ "$scenario" = foreign-force ]; then (cd "$L/project" && treehouse lease 1 --json); fi
 case "$scenario" in gone-*) export TREEHOUSE_ROOT=$L/empty-pool ;; esac
 (cd "$L/project" && treehouse status --json)
 printf '%s\n' "endpoint_task_id=live-lane" "project=$L/project" "worktree=$WT" "kind=ship" "mode=local-only" "window=fm-lab-tests:fm-live-lane" "spawn_gen=s12345.1.1" "lease_id=8b2a06b0022c0063f2abb4c5dc7b4628" > "$FM_STATE_OVERRIDE/live-lane.meta"
 case "$scenario" in
 *dirty-force) printf 'must survive\n' > "$WT/scratch" ;;
 *unpushed-force) printf 'not pushed\n' > "$WT/feature"; git -C "$WT" add feature; git -C "$WT" -c user.name=lab -c user.email=lab@example.invalid commit -qm unpushed ;;
 esac
 head=$(git -C "$WT" rev-parse HEAD)
 rc=0; bin/fm-teardown.sh live-lane --force || rc=$?
 echo "exit=$rc"
 case "$scenario" in
 missing-lease|gone-listing)
 test "$rc" = 0; test ! -f "$FM_STATE_OVERRIDE/live-lane.meta"
 bundle=$(ls -t "$L/home/data/bundles/"live-lane*.bundle | head -1)
 git -C "$WT" bundle verify "$bundle"
 git bundle list-heads "$bundle" | grep "^$head "
 ;;
 *) test "$rc" = 1; test -f "$FM_STATE_OVERRIDE/live-lane.meta" ;;
 esac
 test "$(git -C "$WT" symbolic-ref --short HEAD)" = fm/lab
 test "$(git -C "$WT" rev-parse HEAD)" = "$head"
 echo 'copy branch and HEAD retained'
 case "$scenario" in
 *dirty-force) test "$(< "$WT/scratch")" = 'must survive'; rm "$WT/scratch"; echo 'untracked work retained despite --force' ;;
 *unpushed-force) git -C "$WT" reset -q --hard origin/fm/lab; echo 'unpushed work retained despite --force (fixture reset after assertion)' ;;
 esac
done
