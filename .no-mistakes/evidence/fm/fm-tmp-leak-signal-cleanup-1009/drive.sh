#!/usr/bin/env bash
# Live driver: real bin/fm-fleet-snapshot.sh and bin/fm-timeout-lib.sh, before (base) vs after (head).
set -u
WT=/Users/lundi/.no-mistakes/worktrees/0d3d213d42f1/01M4FZH3B1FBNZBKNRFDAHCE08
S=/tmp/fmtest-1009
rm -rf "$S/base" "$S/run"; mkdir -p "$S/base" "$S/run" "$S/slowbin"
git -C "$WT" archive 21ad1ab9 | tar -x -C "$S/base"
printf '#!/usr/bin/env bash\nsleep 4\n' > "$S/slowbin/tmux"; chmod +x "$S/slowbin/tmux"
LAB=$(mktemp -d /tmp/fm-lab.XXXXXX); "$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
echo "lab home: $LAB"
# Seed one in-flight ship task so the snapshot really consults tmux (slow stub) for it.
mkdir -p "$LAB/projects/alpha-worktree"
printf '## In flight\n- [ ] ship-task - Ship Task (repo: alpha) (kind: ship) (since 2026-10-09)\n\n## Queued\n\n## Done\n' > "$LAB/data/backlog.md"
printf '%s\n' "window=firstmate:fm-ship-task" "worktree=$LAB/projects/alpha-worktree" "project=alpha" \
  "harness=claude" "kind=ship" "mode=ship" "yolo=off" > "$LAB/state/ship-task.meta"
printf 'working: lab\n' > "$LAB/state/ship-task.status"
now() { perl -MTime::HiRes=time -e 'printf "%.2f",time'; }
leftovers() {
  find "$1" -maxdepth 1 \( -name 'fm-fleet-*' -o -name 'fm-timeout-status.*' -o -name 'fm-bash-timeout-command.*' \) \
    | sed "s|$1/||" | sort | tr '\n' ' '
}
waitfor() {
  local i=0
  while [ -z "$(find "$1" -maxdepth 1 -name 'fm-fleet-*' -newer "$S/run" 2>/dev/null)" ]; do
    i=$((i+1)); [ $i -lt 400 ] || return 1; sleep 0.02
  done
}
run_snap() {
  exec env -u NO_MISTAKES_GATE -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
    -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" "$@"
}

for rev in base head; do
  if [ $rev = base ]; then B="$S/base/bin"; else B="$WT/bin"; fi
  echo "================ $rev ================"
  # 1 normal completion
  T="$S/run/$rev-normal"; mkdir -p "$T"
  ( TMPDIR="$T" run_snap "$B/fm-fleet-snapshot.sh" --json ) > "$S/run/$rev-normal.json" 2>"$S/run/$rev-normal.err"; rc=$?
  echo "[normal] rc=$rc schema=$(grep -o '"schema": *"[^"]*"' "$S/run/$rev-normal.json" | head -1) leftovers=[$(leftovers "$T")]"
  # 2 TERM to the snapshot pid mid-run (bash waiting on a slow foreground child)
  T="$S/run/$rev-term"; mkdir -p "$T"; touch "$S/run"
  TMPDIR="$T" PATH="$S/slowbin:$PATH" run_snap "$B/fm-fleet-snapshot.sh" --json >/dev/null 2>&1 & pid=$!
  waitfor "$T"; sleep 0.3; t0=$(now)
  kill -TERM $pid; wait $pid; rc=$?; t1=$(now)
  echo "[TERM pid] rc=$rc exit-latency=$(echo "$t1 - $t0" | bc)s leftovers-now=[$(leftovers "$T")]"
  sleep 5; echo "[TERM pid] leftovers after 5s=[$(leftovers "$T")]"
  # 3 bounded caller like `timeout -k 1 2`: TERM to the whole group at 2s, KILL to the group 1s later
  T="$S/run/$rev-bounded"; mkdir -p "$T"; touch "$S/run"
  set -m
  TMPDIR="$T" PATH="$S/slowbin:$PATH" run_snap "$B/fm-fleet-snapshot.sh" --json >/dev/null 2>&1 & pid=$!
  set +m
  sleep 2; kill -TERM -- -$pid 2>/dev/null; sleep 1; kill -KILL -- -$pid 2>/dev/null; wait $pid; rc=$?
  echo "[group TERM, KILL +1s] rc=$rc leftovers=[$(leftovers "$T")]"
  # 4 SIGKILL mid-run leaves paths; next run sweeps the >60min-old ones of its own prefixes only
  T="$S/run/$rev-kill"; mkdir -p "$T"; touch "$S/run"
  TMPDIR="$T" PATH="$S/slowbin:$PATH" run_snap "$B/fm-fleet-snapshot.sh" --json >/dev/null 2>&1 & pid=$!
  waitfor "$T"; sleep 0.5; kill -KILL $pid; wait $pid 2>/dev/null
  sleep 4.5
  echo "[KILL] leftovers=[$(leftovers "$T")]"
  for p in "$T"/fm-fleet-* "$T"/fm-timeout-status.*; do [ -e "$p" ] && touch -t 202610090000 "$p"; done
  mkdir "$T/fm-fleet-snapshot.FRESHLIVE"; mkdir "$T/other-tool.OLD"; touch -t 202610090000 "$T/other-tool.OLD"
  ( TMPDIR="$T" run_snap "$B/fm-fleet-snapshot.sh" --json ) >/dev/null 2>&1; rc=$?
  kept=REMOVED; [ -e "$T/other-tool.OLD" ] && kept=kept
  echo "[next run after KILL, stale backdated] rc=$rc leftovers=[$(leftovers "$T")] other-tool.OLD=$kept"
  # 5 fm_run_timed TERM mid-run, both mechanisms; watched past the 6s bound
  for mech in "" bash; do
    T="$S/run/$rev-lib-${mech:-default}"; mkdir -p "$T"
    ( . "$B/fm-timeout-lib.sh"; export TMPDIR="$T" FM_TIMEOUT_MECHANISM_OVERRIDE="$mech"; fm_run_timed 6 sleep 37 ) 2>/dev/null & pid=$!
    sleep 1; kill -TERM $pid; wait $pid; rc=$?
    m=$( . "$B/fm-timeout-lib.sh"; FM_TIMEOUT_MECHANISM_OVERRIDE="$mech" fm_timeout_mechanism )
    echo "[fm_run_timed mech=$m] TERM rc=$rc leftovers=[$(leftovers "$T")]"
    sleep 6.5
    echo "    after bound passed: leftovers=[$(leftovers "$T")] orphan-watchdog-sleep6=$(pgrep -fx 'sleep 6' | wc -l | tr -d ' ') orphan-sleep37=$(pgrep -fx 'sleep 37' | wc -l | tr -d ' ')"
    pkill -fx 'sleep 37' 2>/dev/null; pkill -fx 'sleep 6' 2>/dev/null
  done
done
echo "================ head: normal-path contract ================"
(
  . "$WT/bin/fm-timeout-lib.sh"; export TMPDIR="$S/run/contract"; mkdir -p "$TMPDIR"
  trap 'echo caller-term' TERM
  out=$(fm_run_timed 5 sh -c 'echo hi; exit 7'); rc=$?
  echo "status passthrough rc=$rc out=$out caller-trap-after=[$(trap -p TERM)] leftovers=[$(leftovers "$TMPDIR")]"
  fm_run_timed 1 sleep 5; echo "bound fires rc=$? leftovers=[$(leftovers "$TMPDIR")]"
)
rm -rf "$LAB"; gone=no; [ -e "$LAB" ] || gone=yes; echo "lab removed: $gone"
