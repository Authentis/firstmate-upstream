#!/usr/bin/env bash
# S2+S4: young paused: line stays quiet (absorbed on the pause cadence), then the
# same frozen pane's line crosses the 2h limit -> must wake.  $1 = evidence prefix.
. /tmp/fmlab-pw-drv/lab.sh
P=$1
reset_state
start_lane parked 'paused: PR https://example.test/pr/9 published, parked' 600
sleep 1
banner "$P young lane (code: $WT)"
show_lane parked
banner "$P phase A: watcher on the young (<2h) paused: line, 60s window"
watch_for_stale "$EV/$P-A" 60 && echo "RESULT A: stale wake for a young line" || echo "RESULT A: no stale wake for the young paused: line"
key=lab_fm-parked
echo "pause-cadence flag .paused-$key present: $([ -e "$LAB/state/.paused-$key" ] && echo yes || echo no)"
echo "absorbed hash .stale-$key present: $([ -e "$LAB/state/.stale-$key" ] && echo yes || echo no)"
banner "$P phase B: same frozen pane, status line pushed past 2h, 90s window"
age_file 7300 "$LAB/state/parked.status"
show_lane parked
watch_for_stale "$EV/$P-B" 90 && echo "RESULT B: stale wake for the overdue line" || echo "RESULT B: no stale wake for the overdue line"
