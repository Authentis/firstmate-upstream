#!/usr/bin/env bash
# GNU-timeout host path (netcup): fm_run_timed picks `timeout`, which owns fm-timeout-status.*.
set -u
WT=/Users/lundi/.no-mistakes/worktrees/0d3d213d42f1/01M4FZH3B1FBNZBKNRFDAHCE08
S=/tmp/fmtest-1009
chmod +x "$S/gnubin/timeout"
LAB=$(mktemp -d /tmp/fm-lab.XXXXXX); "$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
mkdir -p "$LAB/projects/alpha-worktree"
printf '## In flight\n- [ ] ship-task - Ship Task (repo: alpha) (kind: ship) (since 2026-10-09)\n\n## Queued\n\n## Done\n' > "$LAB/data/backlog.md"
printf '%s\n' "window=firstmate:fm-ship-task" "worktree=$LAB/projects/alpha-worktree" "project=alpha" \
  "harness=claude" "kind=ship" "mode=ship" "yolo=off" > "$LAB/state/ship-task.meta"
leftovers() {
  find "$1" -maxdepth 1 \( -name 'fm-fleet-*' -o -name 'fm-timeout-status.*' -o -name 'fm-bash-timeout-command.*' \) \
    | sed "s|$1/||" | sort | tr '\n' ' '
}
for rev in base head; do
  if [ $rev = base ]; then B="$S/base/bin"; else B="$WT/bin"; fi
  echo "================ $rev (mechanism: $(PATH="$S/gnubin:$PATH"; . "$B/fm-timeout-lib.sh"; fm_timeout_mechanism)) ================"
  # A: library caller TERMed mid-run
  T="$S/run/gnu-$rev-lib"; mkdir -p "$T"
  ( . "$B/fm-timeout-lib.sh"; export TMPDIR="$T" PATH="$S/gnubin:$PATH"; fm_run_timed 4 sleep 41 ) 2>/dev/null & pid=$!
  sleep 1; kill -TERM $pid; wait $pid; rc=$?
  echo "[fm_run_timed TERM] rc=$rc leftovers=[$(leftovers "$T")]"
  sleep 5; echo "    after bound passed: leftovers=[$(leftovers "$T")] orphan-sleep41=$(pgrep -fx 'sleep 41' | wc -l | tr -d ' ')"
  pkill -fx 'sleep 41' 2>/dev/null
  # B: snapshot under a bounded caller, `timeout -k 1 2`-style: group TERM at 2s, group KILL at 3s
  T="$S/run/gnu-$rev-snap"; mkdir -p "$T"
  set -m
  env -u NO_MISTAKES_GATE -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \
    -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" TMPDIR="$T" PATH="$S/gnubin:$S/slowbin:$PATH" \
    FM_SNAPSHOT_CREW_STATE_TIMEOUT=20 "$B/fm-fleet-snapshot.sh" --json >/dev/null 2>&1 & pid=$!
  set +m
  sleep 2; kill -TERM -- -$pid 2>/dev/null; sleep 1; kill -KILL -- -$pid 2>/dev/null; wait $pid; rc=$?
  echo "[snapshot group TERM, KILL +1s] rc=$rc leftovers-now=[$(leftovers "$T")]"
  sleep 8; echo "    8s later: leftovers=[$(leftovers "$T")]"
  # C: snapshot TERM to its pid only while it waits on a foreground read, then KILL 1s later
  T="$S/run/gnu-$rev-snap-pid"; mkdir -p "$T"
  env -u NO_MISTAKES_GATE -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \
    -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" TMPDIR="$T" PATH="$S/gnubin:$S/slowbin:$PATH" \
    FM_SNAPSHOT_CREW_STATE_TIMEOUT=20 "$B/fm-fleet-snapshot.sh" --json >/dev/null 2>&1 & pid=$!
  sleep 2; kill -TERM $pid 2>/dev/null; sleep 1; kill -KILL $pid 2>/dev/null; wait $pid; rc=$?
  echo "[snapshot pid TERM, KILL +1s] rc=$rc leftovers-now=[$(leftovers "$T")]"
  sleep 8; echo "    8s later: leftovers=[$(leftovers "$T")]"
done
pkill -f "$S/slowbin/tmux" 2>/dev/null
rm -rf "$LAB"
