#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
E=~/.no-mistakes/evidence/01M66J43JFVBFMC5S2DQNZTSTE
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS TASKS_AXI_FILE TASKS_AXI_BACKEND
export TMUX="$E/unused-private-socket,0,0"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=Lab GIT_AUTHOR_EMAIL=lab@example.invalid GIT_COMMITTER_NAME=Lab GIT_COMMITTER_EMAIL=lab@example.invalid
cleanup() { rm -rf "$ROOT/.live-test"; }
trap cleanup EXIT
for scenario in gone-clean null-clean null-force gone-dirty-force null-dirty-force gone-unpushed-force null-unpushed-force foreign-force missing-listed missing-listed-force missing-gone missing-gone-force; do
 LAB="$ROOT/.live-test/$scenario"
 bin/fm-lab-home.sh create "$LAB" >/dev/null
 export FM_HOME="$LAB" TREEHOUSE_ROOT="$LAB/pool"
 git init -q --bare -b main "$LAB/origin.git"
 git clone -q "$LAB/origin.git" "$LAB/project" 2>/dev/null
 git -C "$LAB/project" commit -q --allow-empty -m seed
 git -C "$LAB/project" push -q origin main
 git -C "$LAB/project" remote set-head origin main
 allocation=$(cd "$LAB/project" && treehouse get --lease --json --no-fetch -b fm/task-x1 2>"$E/$scenario-treehouse.log")
 WT=$(jq -r .path <<< "$allocation")
 lease=$(jq -r .lease_id <<< "$allocation")
 printf 'lane work\n' > "$WT/feature.txt"
 git -C "$WT" add feature.txt
 git -C "$WT" commit -qm work
 head=$(git -C "$WT" rev-parse HEAD)
 if [[ $scenario != *unpushed* ]]; then git -C "$WT" push -q origin fm/task-x1; fi
 case "$scenario" in
 null-*|foreign-*)
   (cd "$LAB/project" && treehouse return --force --if-lease-id "$lease" "$WT") >>"$E/$scenario-treehouse.log" 2>&1
   git -C "$WT" checkout -q fm/task-x1
   if [[ $scenario == foreign-* ]]; then (cd "$LAB/project" && treehouse lease 1 --json) >>"$E/$scenario-treehouse.log" 2>&1; fi
 ;;
 esac
 case "$scenario" in gone-*|missing-gone*) export TREEHOUSE_ROOT="$LAB/abandoned-root" ;; esac
 [[ $scenario != *dirty* ]] || printf 'dirty\n' >> "$WT/feature.txt"
 printf 'window=leftover:fm-task-x1\nendpoint_task_id=task-x1\nworktree=%s\nproject=%s\nkind=ship\nmode=local-only\nspawn_gen=lab-test\nlease_id=%s\n' "$WT" "$LAB/project" "$lease" > "$LAB/state/task-x1.meta"
 cp "$LAB/state/task-x1.meta" "$LAB/original.meta"
 touch "$LAB/state/.last-watcher-beat"
 if [[ $scenario == missing-* ]]; then mv "$WT" "$LAB/moved-copy"; fi
 (cd "$LAB/project" && treehouse status --json) >"$E/$scenario-inventory.json" 2>>"$E/$scenario-treehouse.log"
 flags=(); [[ $scenario != *force ]] || flags=(--force)
 rc=0
 bin/fm-teardown.sh task-x1 "${flags[@]}" >"$E/$scenario.log" 2>&1 || rc=$?
 printf '\nObserved teardown exit: %s\nOriginal head: %s\n' "$rc" "$head" >>"$E/$scenario.log"
 case "$scenario" in
 gone-clean|null-clean|null-force)
   test "$rc" = 0
   test ! -e "$LAB/state/task-x1.meta"
   test "$(git -C "$WT" rev-parse HEAD)" = "$head"
   test "$(git -C "$WT" symbolic-ref HEAD)" = refs/heads/fm/task-x1
   test -z "$(git -C "$WT" status --porcelain)"
   git -C "$LAB/project" bundle verify "$LAB/data/bundles/task-x1.bundle" >>"$E/$scenario.log" 2>&1
   git -C "$LAB/project" bundle list-heads "$LAB/data/bundles/task-x1.bundle" >>"$E/$scenario.log"
   printf 'Observed: task record removed; copy clean, original branch and HEAD intact; bundle verified.\n' >>"$E/$scenario.log"
 ;;
 *)
   test "$rc" = 1
   cmp "$LAB/original.meta" "$LAB/state/task-x1.meta"
   test ! -e "$LAB/data/bundles/task-x1.bundle"
   check=$WT; [[ $scenario != missing-* ]] || check="$LAB/moved-copy"
   test "$(git -C "$check" rev-parse HEAD)" = "$head"
   printf 'Observed: refusal retained byte-identical task metadata and original HEAD; no backup fabricated.\n' >>"$E/$scenario.log"
 ;;
 esac
 printf '%s: validated\n' "$scenario"
 rm -rf "$LAB"
done
