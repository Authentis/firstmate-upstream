#!/usr/bin/env bash
# Drive the real bin/fm-session-start.sh against a disposable lab home.
# usage: drive-digest.sh <worktree> <backend: tasks-axi|manual> <outfile> [extra args]
set -u
WT=$1 BACKEND=$2 OUT=$3; shift 3
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
mkdir -p "$LAB/tmux"
export TMUX_TMPDIR="$LAB/tmux"
unset TMUX
tmux new-session -d -s fm-sess -n live 'sleep 600'
[ "$BACKEND" = manual ] && echo manual > "$LAB/config/backlog-backend"
long=$(printf 'r%.0s' $(seq 1 300))
cat > "$LAB/data/backlog.md" <<EOF
# Backlog

## In flight
- [ ] lane-a - Healthy lane (repo: firstmate) (kind: ship) (since 2026-10-20)
  BODY-LINE-SHOULD-NOT-PRINT

## Queued
- [ ] long-held - Long held work (repo: firstmate) (kind: ship) (hold: ${long}TAIL-MARKER) (hold-kind: captain) (hold-until: 2026-11-01)
- [ ] short-held - Short held work (repo: firstmate) (kind: ship) (hold: captain choice pending) (hold-kind: captain)
- [ ] plain-1 - Plain queued (repo: firstmate) (kind: ship)

## Done
- [x] landed - DONE-ROW (repo: firstmate) (kind: ship)
EOF
# lane-a: alive, full record, multi-line status history ending in a long line + blank
printf 'window=fm-sess:live\nkind=ship\nmode=pr\nproject=firstmate\n' > "$LAB/state/lane-a.meta"
for i in 1 2 3 4 5 6 7 8; do echo "2026-10-25T10:0$i working: OLD-EVENT-$i" >> "$LAB/state/lane-a.status"; done
printf '2026-10-25T10:09 done: LAST-EVENT-A %s\n\n' "$(printf 'x%.0s' $(seq 1 400))" >> "$LAB/state/lane-a.status"
# lane-b: scout without window (missing window; scout needs no mode)
printf 'kind=scout\nspawn_gen=2\n' > "$LAB/state/lane-b.meta"
echo "2026-10-25T09:00 scouting: LAST-EVENT-B" > "$LAB/state/lane-b.status"
# lane-c: live window, missing kind and mode, no status file
printf 'window=fm-sess:live\nspawn_gen=4\n' > "$LAB/state/lane-c.meta"
# lane-d: dead endpoint, no status -> collapsed to a count
printf 'window=fm-sess:gone\nkind=ship\nmode=pr\n' > "$LAB/state/lane-d.meta"
# orphan log: 12 lines, last one very long
for i in $(seq 1 11); do echo "orphan line $i ORPHAN-$i" >> "$LAB/state/orphan-x.status"; done
printf 'orphan final %s\n' "$(printf 'y%.0s' $(seq 1 500))" >> "$LAB/state/orphan-x.status"
cd "$WT" || exit 1
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  FM_HOME="$LAB" "$WT/bin/fm-session-start.sh" "$@" > "$OUT" 2>"$OUT.stderr"
rc=$?
echo "exit=$rc" >> "$OUT.stderr"
tmux kill-server 2>/dev/null
rm -rf "$LAB"
exit $rc
