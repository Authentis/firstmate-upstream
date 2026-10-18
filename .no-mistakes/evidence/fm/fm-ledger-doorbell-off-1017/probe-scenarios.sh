#!/usr/bin/env bash
# Status probe scenarios against a disposable lab home. The real `no-mistakes`
# answers for the lab dir (not a repo); a second run swaps in a tiny stand-in
# no-mistakes only to show a healthy source, via the script's FM_PROBE_NM seam.
set -u
cd "$1" || exit 1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); bin/fm-lab-home.sh create "$LAB" >/dev/null
P() { FM_HOME="$LAB" bin/fm-status-probe.sh "$@"; }
step() { printf '\n$ %s\n' "$*"; }
mkdir -p "$LAB/state/lanes" "$LAB/tools"
sleep 600 & LIVE=$!
echo "log" > "$LAB/state/live.log"
echo "log" > "$LAB/state/old.log"; touch -t 202601010000 "$LAB/state/old.log"
printf 'pid=%s\nlog=state/live.log\n' "$LIVE" > "$LAB/state/lanes/lane-live.lane"
printf 'pid=%s\nlog=state/old.log\n' "$LIVE" > "$LAB/state/lanes/lane-stalled.lane"
printf 'pid=999999\nlog=state/live.log\n' > "$LAB/state/lanes/lane-dead.lane"
cat > "$LAB/tools/no-mistakes" <<'EOF'
#!/bin/sh
case "$*" in
  "axi status") printf 'runs[1]{id,branch,status,pr}:\n  r1,"fm/a,b",running,https://example.invalid/o/r/pull/1\n' ;;
  "axi status --run r1") printf 'gate:\n  step: test\n  status: awaiting_agent\n  awaiting_agent: 2m30s\n' ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$LAB/tools/no-mistakes"

step "read before any run -> unknown, exit 3"; P read --home "$LAB" | jq -c '{verdict,reason,prs,lanes}'; echo "rc=${PIPESTATUS[0]}"
step "run (real no-mistakes, lab is not a repo) then read"
P run --home "$LAB"; echo "run rc=$?"
P read --home "$LAB" | jq -c '{verdict,sources,gate_waits,lanes:(.lanes|map({id,state,pid_alive,fresh}))}'; echo "rc=${PIPESTATUS[0]}"
step "run with a healthy no-mistakes stand-in (FM_PROBE_NM) then read fresh"
FM_PROBE_NM="$LAB/tools/no-mistakes" P run --home "$LAB"; echo "run rc=$?"
P read --home "$LAB" | jq -c '{verdict,age_s,sources:(.sources|map_values(.ok)),gate_waits}'; echo "rc=${PIPESTATUS[0]}"
cp "$LAB/state/status.json" "$LAB/fresh.json"
step "stale data: status.json generated 1000s ago -> unknown, exit 3"
jq '.generated -= 1000' "$LAB/fresh.json" > "$LAB/state/status.json"
P read --home "$LAB" | jq -c '{verdict,reason,prs,lanes,gate_waits}'; echo "rc=${PIPESTATUS[0]}"
step "stale at the boundary: --max-age 60 on 61s-old data -> unknown"
jq '.generated -= 61' "$LAB/fresh.json" > "$LAB/state/status.json"
P read --home "$LAB" --max-age 60 | jq -c '{verdict,reason}'; echo "rc=${PIPESTATUS[0]}"
step "future-dated data (clock skew > 60s) -> unknown"
jq '.generated += 3600' "$LAB/fresh.json" > "$LAB/state/status.json"
P read --home "$LAB" | jq -c '{verdict}'; echo "rc=${PIPESTATUS[0]}"
step "garbage status.json -> unknown"
echo '{"schema":"other"}' > "$LAB/state/status.json"
P read --home "$LAB" | jq -c '{verdict,reason}'; echo "rc=${PIPESTATUS[0]}"
cp "$LAB/fresh.json" "$LAB/state/status.json"
SUM=$(shasum "$LAB/state/status.json")
step "misordered: --home H read -> refused, status.json untouched"
P --home "$LAB" read; echo "rc=$?"
step "typo flag: read --max_age 60 -> refused"
P read --home "$LAB" --max_age 60; echo "rc=$?"
[ "$SUM" = "$(shasum "$LAB/state/status.json")" ] && echo "status.json unchanged after refused calls"
kill "$LIVE"; rm -rf "$LAB"; echo; echo "lab removed"
