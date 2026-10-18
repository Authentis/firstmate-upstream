#!/usr/bin/env bash
# Route ONE dispatchable free-ok leaf to the bosgame secondmate (chief 1478, captain 10-01 ~14:1x: "route to bosgame").
# NOTE: bosgame truncates messages at 8000 chars; messages above that need a continuation (see 2026-10-01 resends).
# usage: bosgame-leaf-send.sh <leaf-suffix e.g. 10.17.6.4> [--dry-run] [--binding <binding-id>]
# pass-5 (chief): --binding <binding-id> (or BINDING=<id>) applies the ROUTER'S picked binding: it
# is resolved through the fleet.yaml bindings table (refill_lib_v2.py binding-lane) and the worker
# lane text becomes 'a worker: harness <h>, model <m>, effort <e>', overriding the marker-file
# branches (routine-muse.on, claude-off, bosgame-kimi.on). With no binding the script behaves
# exactly as before (legacy markers). An unresolvable binding is REFUSED before anything is sent.
# Test hooks (default to the live values): BOSGAME_LEAF_HOME (the FM home), BOSGAME_CANDIDATES,
# and FLEET_YAML/FM_HOME for binding-lane.
# Takes the leaf's own text from the lane-refill candidate list (/tmp/claude-1000/lane-refill/candidates.json, from origin/main), so run lane-refill.sh first.
# Sends ONE "[netcup SM]" message over `ssh -T bosgame-sm` (forced command), records data/dos-bosgame-<slug>-1001/message.txt and a
# row in data/bosgame-lanes.tsv (lane-refill reads that file so netcup never picks the same leaf), and does NOT touch any tracker.
# The bosgame SM applies the SO-5 ramp itself (load5 < 9, RAM > 8 GB) and answers with lanes working.
set -eu
H=${FM_HOME:-${BOSGAME_LEAF_HOME:-/home/holu/fm-secondmate-upstream-20260907}}
export FM_HOME=$H BOSGAME_LEAF_HOME=$H
ROUTER_BIN=${ROUTER_BIN:-$H/data/bin}; export ROUTER_BIN
FLEET_YAML=${FLEET_YAML:-$H/config/fleet.yaml}; export FLEET_YAML
[ -e "$H/data/router-off" ] && { echo "router-off"; exit 0; }
suf=${1:?leaf suffix}; DRY=0; BINDING=${BINDING:-}; INCARNATION=${ROUTER_ADMIT_INCARNATION:-}
shift
while [ $# -gt 0 ]; do
  case $1 in
    --dry-run) DRY=1 ;;
    --binding) shift; BINDING=${1:?--binding needs a binding id} ;;
    --incarnation) shift; INCARNATION=${1:?--incarnation needs an id} ;;
    *) echo "bosgame-leaf-send: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done
# pass-6b: while ROUTER_LIVE=1 (set by lane-refill-v2.sh) the send is admitted ONLY with a binding
# the router picked: a bare legacy send (no --binding) is REFUSED before anything is sent, so the
# legacy Sonnet/Opus/Spark branch can never run unrouted. ROUTER_LIVE unset keeps the legacy
# behavior (old callers and bare dry runs).
if [ "${ROUTER_LIVE:-0}" = 1 ] && [ -z "$BINDING" ]; then
  echo "bosgame-leaf-send: REFUSED: ROUTER_LIVE=1 and no --binding (a bare legacy route is not router-admitted); nothing sent"
  exit 1
fi
# pass-5: resolve the routed binding BEFORE anything is sent; an unresolvable binding refuses the
# send outright (the bosgame SM must never receive a message naming a route that does not exist).
if [ -n "$BINDING" ]; then
  if lane_info=$(python3 "$ROUTER_BIN/refill_lib_v2.py" binding-lane "$BINDING" 2>/dev/null); then
    IFS=$'\t' read -r b_harness b_model b_provider b_effort <<< "$lane_info"
    # pass-8 (review): the router passes the binding resolution it ADMITTED (BG_ADMIT_* env, set
    # by lane-refill-v2.sh). fleet.yaml is re-read here after selection released its lock, so a
    # mid-flight edit can resolve this binding differently from the one whose bans and quota
    # passed: a fresh resolution that does not match the admitted route is REFUSED - a different
    # model/provider must never launch on the admitted route.
    if [ -n "${BG_ADMIT_HARNESS:-}" ] || [ -n "${BG_ADMIT_MODEL:-}" ] || [ -n "${BG_ADMIT_PROVIDER:-}" ]; then
      if [ "${BG_ADMIT_HARNESS:-}" != "$b_harness" ] || [ "${BG_ADMIT_MODEL:-}" != "$b_model" ] \
         || [ "${BG_ADMIT_PROVIDER:-}" != "$b_provider" ] || [ "${BG_ADMIT_EFFORT:-}" != "$b_effort" ]; then
        echo "bosgame-leaf-send: REFUSED: binding '$BINDING' no longer resolves to the admitted route"\
             " (admitted harness ${BG_ADMIT_HARNESS:-?}, model ${BG_ADMIT_MODEL:-?}, provider ${BG_ADMIT_PROVIDER:-?}, effort ${BG_ADMIT_EFFORT:-?};"\
             " fleet.yaml now gives harness $b_harness, model $b_model, provider $b_provider, effort $b_effort); nothing sent"
        exit 1
      fi
    fi
    if [ -n "${b_harness:-}" ] && [ -n "${b_model:-}" ] && [ -n "${b_provider:-}" ] && [ -n "${b_effort:-}" ]; then
      # pass-6 (review): the RESOLVED PROVIDER is part of the route (bindings with the same model
      # and harness but different providers must not produce identical instructions).
      LANE_OVERRIDE="a worker: harness $b_harness, model $b_model, provider $b_provider, effort $b_effort"
    else
      echo "bosgame-leaf-send: REFUSED: unresolvable binding '$BINDING' (empty binding-lane resolution); nothing sent"
      exit 1
    fi
  else
    echo "bosgame-leaf-send: REFUSED: unresolvable binding '$BINDING' (not in the fleet.yaml bindings table); nothing sent"
    exit 1
  fi
fi
slug=$(printf '%s' "$suf" | tr . -)
id="dos-bosgame-$slug-1001"
# chief 1490 (captain 10-01 "guard overlap"): refuse a leaf whose FILES overlap a live lane on either host (README excepted).
# FORCE_LIVE_PATHS="core/x.py" forces an overlap for the --dry-run proof.
if [ "$DRY" != 1 ]; then unset FORCE_LIVE_PATHS; fi
if ovl=$(python3 "$H/data/bin/lane-overlap-check.py" "$suf" 2>&1); then :; else rc=$?
  if [ "$rc" = 3 ]; then echo "bosgame-leaf-send: REFUSED $suf, FILES overlap a live lane: $ovl"; exit 3; fi
  echo "bosgame-leaf-send: overlap check could not run: $ovl"; exit 1
fi
D=$H/data/$id; mkdir -p "$D"
BOSGAME_LEAF_LANE=${LANE_OVERRIDE:-} ROUTER_REMOTE_BINDING=${BINDING:-legacy} ROUTER_REMOTE_INCARNATION=${INCARNATION:-legacy} python3 - "$suf" "$id" > "$D/message.txt" <<'PY'
import json, sys, os
suf, tid = sys.argv[1:]
c = [x for x in json.load(open(os.environ.get('BOSGAME_CANDIDATES', '/tmp/claude-1000/lane-refill/candidates.json'))) if x['suf'] == suf]
if not c:
    sys.exit(f"leaf {suf} is not in the current dispatchable list")
c = c[0]
lane_override = os.environ.get('BOSGAME_LEAF_LANE', '')
lane = ("a Claude Code worker (chief 2507, 2026-10-09): claude-sonnet-5-5 effort medium when the leaf is 300 changed lines or fewer or of unknown size, claude-opus-5-5 effort medium when it is over 300 (chief 2765, captain 10-10: no Haiku for coding or reviews); every fix round runs on claude-opus-5-5 effort medium; no Sol")
# chief 165932 (2026-10-10, freeze exception, SO-5): while data/routine-muse.on exists, a routine leaf (300 changed lines or fewer,
# or unknown size) goes to a Muse worker on bosgame, with Sonnet as the fallback; over 300 keeps Opus. Kill switch: remove the marker.
import re
_home = os.environ.get('BOSGAME_LEAF_HOME', '/home/holu/fm-secondmate-upstream-20260907')
_m = re.search(r'SIZE:[^\n]*?(?:at most |maximum |<= ?|≤ ?|~ ?|about |approx\.? )(\d+) changed', c['body'])
_size = int(_m.group(1)) if _m else None
if lane_override:
    # pass-5: the router's binding replaces the marker-file branches entirely
    lane = lane_override
else:
    if os.path.exists(_home + '/data/routine-muse.on') and (_size is None or _size <= 300):
        lane = ("a Muse worker (chief 165932, SO-5 routine tier): harness opencode, model opencode/muse-spark-1.3-contributor-free, effort high; "
                "if Muse refuses the task or its run fails, relaunch it once on claude-sonnet-5-5 effort medium and say so in your reply; "
                "every fix round runs on claude-opus-5-5 effort medium; no Sol, no Haiku, never K3")
    # chief 083644: while data/claude-off exists every bosgame send names Kimi K2.7 only (no Claude, never K3); kill switch: remove the marker
    # chief 092957 (Preservation mix): data/bosgame-kimi.on keeps bosgame sends on Kimi K2.7 after the claude-off marker is retired; kill switch: remove it
    if os.path.exists(_home + '/data/claude-off') or os.path.exists(_home + '/data/bosgame-kimi.on'):
        lane = ("a Spark worker (chief 3858, FM ruling: Kimi is spent until 10-16; coding leaves = Spark medium, high for harder): harness pi, model=muse-spark-1.3-contributor, effort medium (high for harder leaves); "
                "fix rounds also on muse-spark-1.3-contributor; NO Kimi, no Claude model of any kind, no Sol, no Haiku, never K3")
print(f"""[netcup SM] New leaf task for you to dispatch (chief 1478/1480, captain 10-01 "route to bosgame"). Task id: {tid}. Router binding: {os.environ['ROUTER_REMOTE_BINDING']}. Router incarnation: {os.environ['ROUTER_REMOTE_INCARNATION']}. One ship task in a worktree of decision-os: {lane}, mode no-mistakes, yolo on. Perform the remote final catalog recheck for this exact binding immediately before launch. Apply your ramp first: start it only if bosgame load5 < 9 and free RAM > 8 GB; otherwise tell netcup SM and do not start it. It ships ONE PR through the no-mistakes gate on bosgame; you do not merge it, netcup SM lands it.

CAPTAIN'S INTENT (give the worker exactly this): Build decision-os tracker leaf {c['id']} ({c['title']}). The leaf text below is the acceptance contract; make every ACCEPTANCE and NEGATIVE line pass on the production path with tests, stay inside the leaf's FILES and its SIZE cap, and do not widen it.

RULES: (a) fixture-only: no real DB, Claude, network, real book or private data. (b) do not edit .beads/ or any tracker row; only the leaf's FILES (plus the one core/README.md package-map row the repo invariant test requires, which you keep if the pipeline adds it). (c) merge origin/main into the branch before the gate run; never rebase, never force-push, never push to main. (d) answer every review finding approve or fix; an ask-user finding goes to netcup SM as a keyed needs-decision line in your parent-replies, never answered by the worker. Never --yes. (e) do not run the full suite; the gate runs it. (f) when committed, run the gate yourself (bosgame has its own gate) and post the PR URL when checks pass, with 'done' for netcup SM.

{('SHARED FILE (SO-13): another lane may edit a shared file of this leaf (vocab.py, judgment.py or instruments.py); merge origin/main before the gate and keep your additions append-only.' + chr(10) + chr(10)) if any(f in ('core/src/dos/contract/vocab.py','core/src/dos/models/judgment.py','core/src/dos/models/instruments.py') for f in c['files']) else ''}LEAF TEXT:
{c['body']}""")
PY
wc -c "$D/message.txt" | awk '{print "message bytes:",$1}'
if [ "$DRY" = 1 ]; then echo "bosgame-leaf-send: dry-run, nothing sent ($id)"; exit 0; fi
# chief 4906 dedupe: a leaf whose steer bosgame already recorded durably is not resent.
if [ -s "$D/delivered.rec" ]; then echo "sent $id (already durably recorded as $(cat "$D/delivered.rec" 2>/dev/null | tr -cd 0-9).msg; not resent)"; exit 0; fi
# pass-6 (review): delivery failures are LOUD, never swallowed. The sender's exit status is
# preserved (no pipe whose status 'head' would mask, no '|| true'), an empty reply or an
# unrecognised transport error is a failure, and NO 'sent' row reaches data/bosgame-lanes.tsv
# unless delivery is confirmed.
# pass-9 (review): can_start and the ALL-STARTS explicit holds are rechecked RIGHT BEFORE delivery
# (the caller's fresh_gate ran before route-pick, the binding resolution and the overlap check): a
# new-leaves hold, the packet-run lock or a can_start of 0 activated in between refuses the send
# with nothing delivered. netcup-leaves.hold stops netcup starts only and does not apply here.
# Test hook: BOSGAME_PACKET_LOCK (defaults to the live packet-run lock lane-refill-v2.sh probes).
pk_lock=${BOSGAME_PACKET_LOCK:-/home/holu/decision-os/data/local/daily_packet_run.lock}
if [ -e "$H/data/new-leaves.hold" ]; then
  echo "bosgame-leaf-send: REFUSED $suf: data/new-leaves.hold is active; nothing sent"
  exit 4
fi
if [ -e "$pk_lock" ] && ! flock -n -s "$pk_lock" true 2>/dev/null; then
  echo "bosgame-leaf-send: REFUSED $suf: the packet run holds $pk_lock; nothing sent"
  exit 4
fi
cs_n=0; cs_why="can-start did not run"
IFS=$'\t' read -r cs_n cs_why < <(python3 "$H/data/bin/refill_lib_v2.py" can-start "$H/data/refill-starts.log" 2>/dev/null) || true
case ${cs_n:-} in ''|*[!0-9]*) cs_n=0 ;; esac
if [ "$cs_n" -le 0 ]; then
  echo "bosgame-leaf-send: REFUSED $suf: can_start allows no start now (${cs_why:-no reason}); nothing sent"
  exit 4
fi
exec 200>"$D/send.lock"; flock -w 120 200 || { echo "bosgame-leaf-send: NOT delivered ($id): send lock busy" >&2; exit 1; }
if [ -s "$D/delivered.rec" ]; then echo "sent $id (already durably recorded as $(cat "$D/delivered.rec" 2>/dev/null | tr -cd 0-9).msg; not resent)"; exit 0; fi
seq=$(($(cat "$D/attempt-seq" 2>/dev/null || echo 0) + 1)); printf '%s\n' "$seq" > "$D/attempt-seq"
printf '%s\t%s\t%s\t%s\n' "$seq" "$(date +%s)" "$BINDING" "$INCARNATION" > "$D/attempt-$seq.tsv"
send_rc=0
send_out=$(bash "$ROUTER_BIN/bosgame-sm-send.sh" < "$D/message.txt" 2>&1) || send_rc=$?
printf '%s\n' "$send_out" > "$D/reply-$seq.txt"
echo "bosgame-leaf-send: bosgame replied (rc=$send_rc): $send_out"
if [ "$send_rc" != 0 ]; then
  echo "bosgame-leaf-send: NOT delivered ($id): bosgame-sm-send exited $send_rc" >&2
  exit "$send_rc"
fi
if [ -z "${send_out//[[:space:]]/}" ]; then
  echo "bosgame-leaf-send: NOT delivered ($id): empty reply" >&2
  exit 1
fi
# Delivery is the v3 transport contract: an anchored positive acknowledgement
# line, with no error marker anywhere in the complete reply.  A future receipt
# verifier may observe this delivery, but it must never replace or block it.
# chief 4906: a busy bosgame answers "fm-ring: doorbell refused ... the steer stays durably recorded at .../N.msg". That steer IS delivered
# (recorded as N.msg; the doorbell only rings later), so it counts as delivered and is never resent (marker $D/delivered.rec).
rec=$(printf '%s\n' "$send_out" | sed -nE 's/.*doorbell refused.*durably recorded at [^ ]*\/([0-9]+)\.msg.*/\1/p' | head -1)
if [ -n "$rec" ]; then
  printf '%s\n' "$rec" > "$D/delivered.rec"
  echo "bosgame-leaf-send: bosgame recorded the steer durably as $rec.msg (doorbell busy); counting it delivered"
elif ! printf '%s\n' "$send_out" | grep -qE '^(replied|sent)'; then
  echo "bosgame-leaf-send: NOT delivered ($id): no positive delivery acknowledgment in the reply" >&2
  exit 1
fi
if [ -z "$rec" ] && printf '%s\n' "$send_out" | grep -qiE 'must start|not sent|error|denied|refused|fail|unknown|timeout'; then
  echo "bosgame-leaf-send: NOT delivered ($id): error marker in the reply" >&2
  exit 1
fi
if ! printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$( case $suf in dos-*) printf %s "$suf";; *) printf %s "dos-product-v1-88cgo.$suf";; esac )" sent "leaf routed to bosgame (chief 1478)" 2>/dev/null >> "$H/data/bosgame-lanes.tsv"; then
  echo "bosgame-leaf-send: WARNING: sent, but the data/bosgame-lanes.tsv append failed ($id); the start still counts - add the row by hand so netcup does not pick this leaf"
fi
echo "sent $id"
