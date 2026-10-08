#!/usr/bin/env bash
# S3: overdue paused: line naming an `until` time still ahead -> stays quiet,
# after the same young-absorb sequence as S4.  $1 = evidence prefix.
. /tmp/fmlab-pw-drv/lab.sh
P=$1
future=$(date -u -r $(( $(date +%s) + 86400 )) +%Y-%m-%dT%H:%MZ)
reset_state
start_lane parked "paused: waiting on upstream release until $future" 600
sleep 1
banner "$P young lane with future until (code: $WT)"
show_lane parked
watch_for_stale "$EV/$P-A" 45 && echo "RESULT A: stale wake" || echo "RESULT A: no stale wake"
banner "$P status line pushed past 2h, until still ahead, 90s window"
age_file 7300 "$LAB/state/parked.status"
show_lane parked
watch_for_stale "$EV/$P-B" 90 && echo "RESULT B: stale wake for an overdue line with a future until" || echo "RESULT B: no stale wake (future until keeps it quiet)"
