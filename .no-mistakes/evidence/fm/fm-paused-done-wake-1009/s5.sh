#!/usr/bin/env bash
# S5: overdue paused: line while the crew's gate run is live -> quiet; the run
# then ends with the pane frozen -> wakes.  Crew liveness comes from
# FM_CREW_STATE_BIN (the product's own override seam) pointed at a stub whose
# verdict this script flips; no real no-mistakes run is started from the gate.
. /tmp/fmlab-pw-drv/lab.sh
P=$1
STUB=/tmp/fmlab-pw-drv/crew-state-stub.sh
VERDICT=/tmp/fmlab-pw-drv/crew-verdict
printf 'state: working · source: run-step · validating (running)\n' > "$VERDICT"
reset_state
start_lane parked 'paused: own pipeline run' 600
sleep 1
banner "$P young lane, gate run live (code: $WT)"
show_lane parked
echo "crew verdict fed to the watcher: $(cat "$VERDICT")"
watch_for_stale "$EV/$P-A" 40 FM_CREW_STATE_BIN="$STUB" && echo "RESULT A: stale wake" || echo "RESULT A: no stale wake"
banner "$P line pushed past 2h, gate run still live, 75s window"
age_file 7300 "$LAB/state/parked.status"
show_lane parked
watch_for_stale "$EV/$P-B" 75 FM_CREW_STATE_BIN="$STUB" && echo "RESULT B: stale wake while run live" || echo "RESULT B: no stale wake while the gate run is live"
banner "$P gate run ends; pane stays frozen; 90s window"
printf 'state: paused · source: status-log · run ended\n' > "$VERDICT"
echo "crew verdict fed to the watcher: $(cat "$VERDICT")"
TM capture-pane -p -t lab:fm-parked | sed '/^$/d' | sed 's/^/  | /'
watch_for_stale "$EV/$P-C" 90 FM_CREW_STATE_BIN="$STUB" && echo "RESULT C: stale wake after the run ended" || echo "RESULT C: no stale wake after the run ended"
