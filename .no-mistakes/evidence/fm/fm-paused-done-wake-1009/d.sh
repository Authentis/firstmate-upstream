#!/usr/bin/env bash
# Away mode: real bin/fm-supervise-daemon.sh with state/.afk set, supervisor
# target = a lab `cat` pane (typed digests are only echoed, never executed).
# $1 = evidence prefix, $2 = mode: none | live
. /tmp/fmlab-pw-drv/lab.sh
P=$1 MODE=$2
STUB=/tmp/fmlab-pw-drv/crew-state-stub.sh
VERDICT=/tmp/fmlab-pw-drv/crew-verdict
reset_state
TM kill-window -t lab:sup 2>/dev/null || true
TM new-window -d -t lab: -n sup "cat"
start_lane parked 'paused: PR https://example.test/pr/9 published, parked' 600
touch "$LAB/state/.afk"
extra=()
if [ "$MODE" = live ]; then
  printf 'state: working · source: run-step · validating (running)\n' > "$VERDICT"
  extra=(FM_CREW_STATE_BIN="$STUB")
fi
start_daemon() {
  ( cd "$WT" && labenv FM_SUPERVISOR_TARGET=lab:sup FM_SUPERVISOR_BACKEND=tmux FM_ESCALATE_BATCH_SECS=0 \
      FM_HOUSEKEEPING_TICK=3 FM_POLL=2 FM_HEARTBEAT=999999 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT_SCAN_SECS=999999 \
      FM_WEDGE_ALARM_EXEC=discard "${extra[@]}" bin/fm-supervise-daemon.sh > "$EV/$P-daemon.out" 2>&1 ) &
  DPID=$!
}
stop_daemon() { pkill -TERM -P "$DPID" 2>/dev/null; sleep 1; pkill -P "$DPID" 2>/dev/null; kill "$DPID" 2>/dev/null; wait "$DPID" 2>/dev/null; true; }
count() { grep -c "no live gate run" "$LAB/state/.subsuper-escalations" "$LAB/state/.subsuper-digests"/* 2>/dev/null | awk -F: '{s+=$NF} END{print s+0}'; }
sup_hits() { TM capture-pane -p -S -2000 -t lab:sup | grep -c "no live gate run"; }
banner "$P away mode, young paused: line (code: $WT, crew mode: $MODE)"
show_lane parked
start_daemon
sleep 25
echo "after 25s on the young line: 'no live gate run' escalations buffered for the supervisor: $(count)"
banner "$P status line pushed past 2h"
age_file 7300 "$LAB/state/parked.status"
show_lane parked
sleep 40
echo "after 40s overdue: 'no live gate run' escalations buffered for the supervisor: $(count)"
if [ "$MODE" = live ]; then
  banner "$P gate run ends (crew verdict flips to paused/status-log)"
  printf 'state: paused · source: status-log · run ended\n' > "$VERDICT"
  sleep 40
  echo "after 40s with the run ended: 'no live gate run' escalations buffered for the supervisor: $(count)"
fi
sleep 20
echo "20s later (must not repeat): 'no live gate run' escalations buffered for the supervisor: $(count)"
stop_daemon
banner "$P buffered supervisor escalations (state/.subsuper-escalations)"; cat "$LAB/state/.subsuper-escalations" 2>/dev/null | sed "s/^/  > /"

banner "$P daemon log tail"
grep -v "inject deferred" "$LAB/state/.supervise-daemon.log" | tail -20
