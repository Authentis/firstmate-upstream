#!/usr/bin/env bash
# Live driver: runs the real bin/fm-fleet-snapshot.sh and fm_run_timed from the
# change's worktree against a disposable lab FM_HOME and a private TMPDIR.
set -u
set -m  # job control: background jobs keep default SIGINT, as a terminal Ctrl-C target would
WT=$1
cd "$WT" || exit 1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
bin/fm-lab-home.sh create "$LAB" >/dev/null
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-tmp.XXXXXX")
SHIM=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-shim.XXXXXX")
REAL_TMUX=$(command -v tmux)
# Slow every tmux query so a signal can land mid-run; then call real tmux.
printf '#!/usr/bin/env bash\nsleep "${SHIM_DELAY:-3}"\nexec %q "$@"\n' "$REAL_TMUX" > "$SHIM/tmux"; chmod +x "$SHIM/tmux"
cleanup(){ rm -rf "$LAB" "$T" "$SHIM"; }
trap cleanup EXIT
# Starts the real snapshot as the background job itself (exec), so $! is its pid.
snap(){  # <shim-delay>
  exec env -u NO_MISTAKES_GATE -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    FM_HOME="$LAB" TMPDIR="$T" TMUX_TMPDIR="$LAB/tmux-none" PATH="$SHIM:$PATH" SHIM_DELAY="$1" \
    bin/fm-fleet-snapshot.sh --json >/dev/null 2>/dev/null
}
clear_t(){ find "$T" -mindepth 1 -maxdepth 1 -exec rm -rf {} +; }
lst(){ (cd "$T" && ls -1A | grep -E '^fm-' | sort) | sed 's/^/    /'; }
wait_tmp(){ local i=0; while [ -z "$(ls -A "$T" | grep -E '^fm-fleet-')" ]; do i=$((i+1)); [ $i -lt 500 ] || return 1; sleep 0.02; done; }

echo "== S1: normal snapshot run leaves no temp paths =="
clear_t; ( snap 0 ); echo "  rc=$?"; echo "  TMPDIR after:"; lst; echo "  (end)"

for sig in TERM INT HUP; do
 echo "== S2-$sig: $sig mid-run while bash waits on a 3s foreground child =="
 clear_t
 ( snap 3 ) & pid=$!
 wait_tmp || echo "  never created temp"
 echo "  TMPDIR during run:"; lst
 s=$(date +%s); kill -$sig $pid; wait $pid 2>/dev/null; rc=$?; e=$(( $(date +%s)-s ))
 echo "  rc=$rc, exited ${e}s after the signal"; echo "  TMPDIR after $sig:"; lst; echo "  (end)"
done

echo "== S3: bounded caller TERM then KILL 1s later (timeout -k 1 shape), then the next run sweeps =="
clear_t
( snap 5 ) & pid=$!
wait_tmp; kill -TERM $pid; sleep 1; kill -KILL $pid 2>/dev/null; wait $pid 2>/dev/null; echo "  TERM+KILL rc=$?"
echo "  TMPDIR after TERM then KILL 1s later:"; lst
clear_t
( snap 5 ) & pid=$!
wait_tmp; kill -KILL $pid; wait $pid 2>/dev/null; echo "  bare KILL rc=$?"
echo "  TMPDIR after KILL (a KILLed process cannot trap, so leftovers are expected here):"; lst
for f in "$T"/fm-*; do [ -e "$f" ] && touch -t "$(date -v-2H +%Y%m%d%H%M)" "$f"; done
: > "$T/fm-timeout-status.FRESHLIVE"; : > "$T/other-tool.STALE"; touch -t 200001010000 "$T/other-tool.STALE"
: > "$T/fm-timeout-status.STALEOLD"; touch -t 200001010000 "$T/fm-timeout-status.STALEOLD"
mkdir "$T/fm-bash-timeout-command.STALEDIR"; touch -t 200001010000 "$T/fm-bash-timeout-command.STALEDIR"
echo "  aged the leftovers 2h, planted fresh/stale/foreign entries; before next run:"; (cd "$T" && ls -1A | sort | sed 's/^/    /')
( snap 0 ); echo "  next run rc=$?"
echo "  TMPDIR after next run:"; (cd "$T" && ls -1A | sort | sed 's/^/    /'); echo "  (end)"

echo "== S4: fm_run_timed TERM mid-run, external-timeout and bash runners =="
RUN=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-runner.XXXXXX")
# Stand-in for GNU timeout (absent on this macOS host): skips options, takes its own
# process group like GNU timeout without --foreground, bounds via perl alarm.
cat > "$RUN/timeout" <<'STUB'
#!/bin/sh
while [ "${1#-}" != "$1" ]; do case $1 in -k|-s) shift 2;; *) shift;; esac; done
secs=$1; shift
exec perl -e 'setpgrp(0,0); alarm shift; exec @ARGV' "$secs" "$@"
STUB
chmod +x "$RUN/timeout"
set +m  # real callers (e.g. fm-fleet-snapshot) run fm_run_timed without job control
for mech in timeout bash; do
 clear_t
 ( . bin/fm-timeout-lib.sh; export TMPDIR="$T" FM_TIMEOUT_MECHANISM_OVERRIDE=$mech; PATH="$RUN:$PATH" fm_run_timed 4 sleep 31 ) & pid=$!
 sleep 0.5; echo "  [$mech] during: [$(ls -A "$T" | tr '\n' ' ')]"
 kill -TERM $pid; wait $pid 2>/dev/null; rc=$?
 echo "  [$mech] rc=$rc  right after TERM: [$(ls -A "$T" | tr '\n' ' ')]  'sleep 31' procs: $(pgrep -f 'sleep 31' | wc -l | tr -d ' ')"
 sleep 4.5; echo "  [$mech] after the 4s bound would have fired: [$(ls -A "$T" | tr '\n' ' ')]  'sleep 31' procs: $(pgrep -f 'sleep 31' | wc -l | tr -d ' ')"
 pkill -f 'sleep 31' 2>/dev/null
done
rm -rf "$RUN"

echo "== S5: fm_run_timed normal completion restores the caller's TERM trap =="
( . bin/fm-timeout-lib.sh; export TMPDIR="$T" FM_TIMEOUT_MECHANISM_OVERRIDE=bash; trap 'echo "  caller-trap-ran"; exit 7' TERM; fm_run_timed 5 true; echo "  run rc=$? trap now: $(trap -p TERM)"; echo "  TMPDIR: [$(ls -A "$T" | tr '\n' ' ')]"; kill -TERM $BASHPID; sleep 1 ); echo "  subshell rc=$?"
