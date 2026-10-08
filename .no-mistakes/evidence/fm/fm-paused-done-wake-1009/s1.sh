#!/usr/bin/env bash
# S1: overdue paused: lane, no live gate run -> watcher wakes the supervisor.
. /tmp/fmlab-pw-drv/lab.sh
reset_state
start_lane parked 'paused: PR https://example.test/pr/9 published, parked' 0
sleep 1
settle_signal parked 7300 "$EV/s1"
banner "S1 lane before the watcher run"
show_lane parked
banner "S1 real bin/fm-watch.sh run (FM_PAUSED_NO_GATE_SECS default 7200)"
run_watch "$EV/s1-watch.out" 90
echo "watcher stdout:"; sed 's/^/  > /' "$EV/s1-watch.out"
echo "wake drain:"; drain | sed 's/^/  > /'
stop_watch
