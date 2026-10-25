#!/usr/bin/env bash
# Route ONE finished SO-11 cloud leaf to a NETCUP pickup lane (chief 1810, captain: bosgame implementation is stopped, BOS_CAP 0).
# usage: cloud-pickup-netcup.sh <leaf-suffix e.g. 10.31.5> <claude/branch> [--dry-run]
# Scaffolds a ship brief (same intent and rules as cloud-pickup-send.sh), adds the backlog item and appends the task to data/bin/priority-lanes.txt;
# lane-refill.sh starts it inside the netcup cap (<= 3, no BUILD at load5 >= 8) on Codex Terra medium (no Sol for leaves, chief 1802).
# One lane per leaf: an existing brief for this task id means it is already routed.
set -eu
H=${FM_HOME:-/home/holu/fm-secondmate-upstream-20260907}
export FM_HOME=$H
ROUTER_BIN=${ROUTER_BIN:-$H/data/bin}
export ROUTER_BIN
FLEET_YAML=${FLEET_YAML:-$H/config/fleet.yaml}
export FLEET_YAML
# shellcheck source=router-launch.sh
source "$ROUTER_BIN/router-launch.sh"
router_global_off && exit 0
suf=${1:?leaf suffix}; br=${2:?claude branch}; DRY=0; [ "${3:-}" = "--dry-run" ] && DRY=1
slug=$(printf '%s' "$suf" | tr . -); id="dos-netcup-cloud-$slug-1003"; leaf="dos-product-v1-88cgo.$suf"
[ -e "$H/data/$id/brief.md" ] && { echo "cloud-pickup-netcup: already routed $id"; exit 0; }
[ -s "$H/data/dos-bosgame-cloud-$slug-1001/message.txt" ] && { echo "cloud-pickup-netcup: $leaf was already sent to bosgame (chief 1795); not routed twice"; exit 0; }
[ -e "$H/data/new-leaves.hold" ] && { echo "cloud-pickup-netcup: data/new-leaves.hold present (chief 1813); pickup of $leaf deferred"; exit 0; }
[ "$DRY" = 1 ] && { echo "cloud-pickup-netcup: dry-run, would route $leaf ($br) as $id"; exit 0; }
"$ROUTER_BIN/fm-brief-local.sh" "$id" decision-os --mode no-mistakes >/dev/null
python3 - "$suf" "$br" "$H/data/$id/brief.md" <<'PY'
import json, os, sys
suf, br, p = sys.argv[1:]
leaf = "dos-product-v1-88cgo." + suf
body = ""
try:
    candidates = os.environ.get('ROUTER_CANDIDATES', os.path.join(os.environ.get('ROUTER_WORKDIR', '/tmp/claude-1000/lane-refill'), 'candidates.json'))
    for x in json.load(open(candidates)):
        if x['suf'] == suf:
            body = x['body']; break
except Exception:
    pass
body = body[:6000] if body else "(leaf text not in the dispatchable list; read the leaf from the decision-os tracker file .beads/issues.jsonl on origin/main)"
intent = (f"Tracker leaf {leaf} was already built by a cloud worker and pushed to origin branch {br} (one commit naming the leaf). "
          f"Take that work through the normal gate and ship it as a PR for this leaf; the leaf text below is the acceptance contract.\n\nLEAF TEXT:\n{body}\n")
spec = (f"- Start from current origin/main on your ship branch, then git fetch origin {br} and cherry-pick its commit; do not edit .beads/ or any tracker row.\n"
        "- The cloud work is unreviewed: read it critically; every ACCEPTANCE and NEGATIVE line needs a passing test; fix gaps tests-first and stay inside the leaf's FILES (plus the one core/README.md package-map row the repo invariant test requires).\n"
        "- Fixture-only: no real DB, network, real book, credentials or private data. Run the full suite only via bash scripts/gate_test.sh; locally run targeted tests.\n"
        "- Commit when ready, then start validation yourself; put an Acceptance check section in the PR body.\n")
t = open(p).read()
assert "{TASK}" in t and "{FIRSTMATE_SPEC}" in t
open(p, "w").write(t.replace("{TASK}", intent, 1).replace("{FIRSTMATE_SPEC}", spec, 1))
PY
"$H/bin/fm-tasks-axi.sh" add "$id" "Pick up cloud leaf $suf (netcup lane)" --kind ship >/dev/null 2>&1 || true
echo "$id" >> "$H/data/bin/priority-lanes.txt"
echo "cloud-pickup-netcup: routed $id"
