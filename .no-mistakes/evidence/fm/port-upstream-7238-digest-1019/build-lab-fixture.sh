#!/usr/bin/env bash
# Build the disposable lab-home fixture for the session-start digest scenarios.
# Usage: build-lab-fixture.sh <worktree> <lab-dir>
set -eu
WT=$1 H=$2
"$WT/bin/fm-lab-home.sh" create "$H" >/dev/null
mkdir -p "$H/tmux"
w() { f=$1; shift; printf '%s\n' "$@" > "$f"; }

# Lane 1: live endpoint, multi-line status with continuation prose + trailing blank.
w "$H/state/lane-alive.meta" 'window=fm-sess:live' 'kind=ship' 'mode=no-mistakes' 'yolo=off' 'spawn_gen=7' 'busy_gen=3'
printf 'working: setup done\nworking: rebased onto main\nneeds-decision: [key=db] pick the migration strategy\n  option A: online copy\n  option B: offline window\n\n' \
  > "$H/state/lane-alive.status"
# Lane 2: scout with no window recorded.
w "$H/state/lane-scout.meta" 'kind=scout' 'spawn_gen=2'
printf 'working: reading docs\npaused: waiting on validation\n' > "$H/state/lane-scout.status"
# Lane 3: thin record (no kind, no mode), live endpoint, no status file.
w "$H/state/lane-thin.meta" 'window=fm-sess:live'
# Lane 4: dead endpoint with a 900-char last status line (must be capped).
w "$H/state/lane-dead.meta" 'window=fm-sess:gone' 'kind=ship' 'mode=direct'
LONG=$(printf 'Z%.0s' $(seq 1 900))
printf 'working: step1\nworking: %s\n' "$LONG" > "$H/state/lane-dead.status"
# Lane 5: dead endpoint, no status file -> collapsed to a count.
w "$H/state/lane-collapsed.meta" 'window=fm-sess:gone2' 'kind=ship' 'mode=direct'
# Orphan status log (no meta): 13 lines, last one 900+ chars.
for i in $(seq 1 12); do echo "working: orphan step $i"; done > "$H/state/orphan-x.status"
printf 'working: orphan long %s\n' "$LONG" >> "$H/state/orphan-x.status"

R=$(printf 'r%.0s' $(seq 1 1200))
E=$(printf 'e%.0s' $(seq 1 200))
cat > "$H/data/backlog.md" <<EOF
# Backlog

## In flight
- [ ] lane-alive - Alive lane work (repo: firstmate) (kind: ship) (since 2026-10-20) (hold: $R) (hold-kind: captain) (hold-until: 2026-11-01)

## Queued
- [ ] short-held - Short held (repo: firstmate) (kind: ship) (hold: captain choice pending) (hold-kind: captain)
- [ ] exact-200 - Exact two hundred (repo: firstmate) (kind: ship) (hold: $E) (hold-kind: captain)
- [ ] plain-1 - Plain queued (repo: firstmate) (kind: ship)
EOF
echo "lab ready: $H"
