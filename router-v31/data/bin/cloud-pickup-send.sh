#!/usr/bin/env bash
# Route ONE finished SO-11 cloud leaf to the bosgame secondmate as a pickup lane (chief 1795, SO-5: bosgame checks work, within its coding cap).
# usage: cloud-pickup-send.sh <leaf-suffix e.g. 10.31.5> <claude/branch> [--dry-run]
# Message starts "[netcup SM]" (bosgame refuses anything else), stays under 8000 chars, records data/dos-bosgame-cloud-<slug>-1001/message.txt
# and a row in data/bosgame-lanes.tsv. Nothing touches a tracker.
set -eu
H=${FM_HOME:-/home/holu/fm-secondmate-upstream-20260907}; export FM_HOME=$H
ROUTER_BIN=${ROUTER_BIN:-$H/data/bin}; export ROUTER_BIN
FLEET_YAML=${FLEET_YAML:-$H/config/fleet.yaml}; export FLEET_YAML
[ -e "$H/data/router-off" ] && { echo "router-off"; exit 0; }
suf=${1:?leaf suffix}; br=${2:?claude branch}; shift 2
DRY=0; BINDING=${BINDING:-}; INCARNATION=${ROUTER_ADMIT_INCARNATION:-}
while [ $# -gt 0 ]; do case $1 in
  --dry-run) DRY=1;;
  --binding) shift; BINDING=${1:?--binding needs an id};;
  --incarnation) shift; INCARNATION=${1:?--incarnation needs an id};;
  *) echo "cloud-pickup-send: unknown argument: $1" >&2; exit 2;;
esac; shift; done
slug=$(printf '%s' "$suf" | tr . -); id="dos-bosgame-cloud-$slug-1001"; leaf="dos-product-v1-88cgo.$suf"
D=$H/data/$id
[ -n "$BINDING" ] && [ -n "$INCARNATION" ] || { echo "cloud-pickup-send: REFUSED: binding and incarnation are required" >&2; exit 3; }
lane_info=$(python3 "$ROUTER_BIN/refill_lib_v2.py" binding-lane "$BINDING" 2>/dev/null) || { echo "cloud-pickup-send: REFUSED: unresolvable binding $BINDING" >&2; exit 3; }
IFS=$'\t' read -r b_harness b_model b_provider b_effort <<< "$lane_info"
if [ -n "${BG_ADMIT_HARNESS:-}" ] || [ -n "${BG_ADMIT_MODEL:-}" ] || [ -n "${BG_ADMIT_PROVIDER:-}" ] || [ -n "${BG_ADMIT_EFFORT:-}" ]; then
  if [ "${BG_ADMIT_HARNESS:-}" != "$b_harness" ] || [ "${BG_ADMIT_MODEL:-}" != "$b_model" ] \
     || [ "${BG_ADMIT_PROVIDER:-}" != "$b_provider" ] || [ "${BG_ADMIT_EFFORT:-}" != "$b_effort" ]; then
    echo "cloud-pickup-send: REFUSED: binding no longer matches admitted tuple" >&2
    exit 3
  fi
fi
mkdir -p "$D"
PICKUP_BINDING="$BINDING" PICKUP_INCARNATION="$INCARNATION" PICKUP_LANE="harness $b_harness, model $b_model, provider $b_provider, effort $b_effort" \
python3 - "$suf" "$id" "$br" > "$D/message.txt" <<'PY'
import json, os, sys
suf, tid, br = sys.argv[1:]
leaf = "dos-product-v1-88cgo." + suf
body = ""
try:
    for x in json.load(open(os.environ.get('BOSGAME_CANDIDATES', '/tmp/claude-1000/lane-refill/candidates.json'))):
        if x['suf'] == suf:
            body = x['body']; break
except Exception:
    pass
body = body[:4500] if body else "(leaf text not in the dispatchable list; read the leaf from the decision-os tracker file .beads/issues.jsonl on origin/main)"
print(f"""[netcup SM] Pickup task for you to dispatch (chief 1795). Task id: {tid}. Router binding: {os.environ['PICKUP_BINDING']}. Router incarnation: {os.environ['PICKUP_INCARNATION']}. One ship task in a worktree of decision-os: {os.environ['PICKUP_LANE']}, mode no-mistakes, yolo on. Before launch, perform the remote final catalog recheck for this exact binding. Apply your ramp and coding cap first.

CAPTAIN'S INTENT (give the worker exactly this): Tracker leaf {leaf} was already built by a cloud worker and pushed to origin branch {br} (one commit naming the leaf). Take that work through the normal gate and ship it as a PR for this leaf; the leaf text below is the acceptance contract.

RULES: (a) start from current origin/main on the ship branch, then git fetch origin {br} and cherry-pick its commit; do not edit .beads/ or any tracker row. (b) cloud work is unreviewed: read it critically; verify every ACCEPTANCE and NEGATIVE line has a passing test, fix gaps tests-first, stay inside the leaf's FILES and SIZE cap (plus the one core/README.md package-map row the repo invariant test requires). (c) fixture-only: no real DB, network, real book, credentials or private data. (d) run only the targeted tests plus core/tests/skills/test_protocol_packages.py if core/skills is touched. (e) when committed, start validation yourself; ask-user findings about no live-validatable surface are answered by the SM; put an Acceptance check section in the PR body. (f) when the PR is ready, tell me the PR URL; I land it after the cross-family review.

LEAF TEXT:
{body}""")
PY
wc -c "$D/message.txt" | awk '{print "message bytes:",$1}'
if [ "$DRY" = 1 ]; then echo "cloud-pickup-send: dry-run, nothing sent ($id)"; exit 0; fi
# chief 4906: a pickup whose steer bosgame already recorded durably is not resent.
if [ -s "$D/delivered.rec" ]; then echo "sent $id (already durably recorded as $(cat "$D/delivered.rec" 2>/dev/null | tr -cd 0-9).msg; not resent)"; exit 0; fi
exec 200>"$D/send.lock"; flock -w 120 200 || { echo "cloud-pickup-send: NOT delivered: lock busy" >&2; exit 1; }
if [ -s "$D/delivered.rec" ]; then echo "sent $id (already durably recorded as $(cat "$D/delivered.rec" 2>/dev/null | tr -cd 0-9).msg; not resent)"; exit 0; fi
seq=$(($(cat "$D/attempt-seq" 2>/dev/null || echo 0) + 1)); printf '%s\n' "$seq" > "$D/attempt-seq"
printf '%s\t%s\t%s\t%s\n' "$seq" "$(date +%s)" "$BINDING" "$INCARNATION" > "$D/attempt-$seq.tsv"
set +e
if [ -n "${BOSGAME_SM_SEND:-}" ]; then "$BOSGAME_SM_SEND" < "$D/message.txt" > "$D/reply-$seq.txt" 2>&1; rc=$?
else timeout 60 ssh -T -o ConnectTimeout=15 bosgame-sm < "$D/message.txt" > "$D/reply-$seq.txt" 2>&1; rc=$?; fi
set -e
out=$(head -c 400 "$D/reply-$seq.txt" | tr '\n' ' '); echo "cloud-pickup-send: bosgame replied (rc=$rc): $out"
if [ "$rc" != 0 ]; then
  echo "cloud-pickup-send: NOT delivered ($id): bosgame transport exited $rc" >&2
  exit "$rc"
fi
if [ ! -s "$D/reply-$seq.txt" ]; then
  echo "cloud-pickup-send: NOT delivered ($id): empty reply" >&2
  exit 1
fi
# chief 4906: a busy bosgame answers "fm-ring: doorbell refused ... the steer stays durably recorded at .../N.msg".
# That steer IS delivered (recorded as N.msg; the doorbell only rings later): it counts as delivered and is never resent.
rec=$(sed -nE 's/.*doorbell refused.*steer stays durably recorded at [^ ]*\/([0-9]+)\.msg.*/\1/p' "$D/reply-$seq.txt" | head -1)
if [ -n "$rec" ]; then
  printf '%s\n' "$rec" > "$D/delivered.rec"
  echo "cloud-pickup-send: bosgame recorded the steer durably as $rec.msg (doorbell busy); counting it delivered"
else
  if ! grep -qE '^(replied|sent)' "$D/reply-$seq.txt"; then
    echo "cloud-pickup-send: NOT delivered ($id): no positive delivery acknowledgment in the reply" >&2
    exit 1
  fi
  if grep -qiE 'must start|not sent|error|denied|refused|fail|unknown|timeout' "$D/reply-$seq.txt"; then
    echo "cloud-pickup-send: NOT delivered ($id): error marker in the reply" >&2
    exit 1
  fi
fi
if ! printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$leaf" sent "cloud pickup routed to bosgame (chief 1795)" 2>/dev/null >> "$H/data/bosgame-lanes.tsv"; then
  echo "cloud-pickup-send: WARNING: sent, but the data/bosgame-lanes.tsv append failed ($id); the start still counts - add the row by hand so netcup does not pick this leaf"
fi
echo "sent $id"
