#!/usr/bin/env bash
# SO-11 cloud launcher v2 (chief 1665, 2026-10-02): keep 5 cloud Sonnet 5.5 workers RUNNING. Unlike cloud-refill.sh it makes NO br write and NO claim commit in the
# primary clone (those kept the primary tracker dirty and put claim commits on main); the ledger data/cloud-workers.tsv is the claim.
# Leaves come from lane-refill's candidates.json (open, spec-ready, unassigned, unlanded, not in a lane), offline ones only (not netcup_only), taken from the END of the
# clean list so they do not collide with the leaves lane-refill spawns from the front.
# usage: cloud-launch.sh [--dry-run] [--stale <leaf>]  (--stale marks a running ledger row finished)
set -u
H=${FM_HOME:-/home/holu/fm-secondmate-upstream-20260907}
export FM_HOME=$H
ROUTER_BIN=${ROUTER_BIN:-$H/data/bin}
export ROUTER_BIN
FLEET_YAML=${FLEET_YAML:-$H/config/fleet.yaml}
export FLEET_YAML
# shellcheck source=router-launch.sh
source "$ROUTER_BIN/router-launch.sh"
router_global_off && exit 0
D=${ROUTER_PROJECT_DIR:-/home/holu/decision-os}
W=${ROUTER_WORKDIR:-/tmp/claude-1000/lane-refill}
L=$H/data/cloud-workers.tsv
C=${ROUTER_CANDIDATES:-$W/candidates.json}
SPEND=${ROUTER_SPEND_LOG:-$H/data/cloud-spend.md}
START_LEDGER=${ROUTER_START_LEDGER:-$H/data/refill-starts.log}
START_POLICY=${ROUTER_START_POLICY:-$ROUTER_BIN/refill_lib_v2.py}
TARGET=${CLOUD_TARGET:-5}
cloud_start_gate() {
  local allowed why
  [ ! -e "$H/data/new-leaves.hold" ] || return 1
  IFS=$'\t' read -r allowed why _ < <(python3 "$START_POLICY" can-start "$START_LEDGER" 2>/dev/null) || return 1
  [[ ${allowed:-} =~ ^[0-9]+$ ]] && [ "$allowed" -gt 0 ]
}
cloud_note_start() {
  python3 "$START_POLICY" note-start "$START_LEDGER" >/dev/null 2>&1
}
if [ "${1:-}" = --stale ]; then
  stamp=$(date +%Y%m%d%H%M%S)
  cp "$L" "$L.bak-$stamp" || exit 1
  awk -v l="$2" 'BEGIN{OFS="\t"} $2==l && $4=="running" {$4="finished"} {print}' "$L" > "$L.new" && mv "$L.new" "$L"
  exit 0
fi
dry=0; [ "${1:-}" = --dry-run ] && dry=1
if [ "$dry" = 0 ]; then
  mkdir -p "$H/data"
  touch "$L"
  exec 7>"$L.lock"; flock -n 7 || { echo "cloud-launch: another launch is running"; exit 0; }
fi
# a cloud session never runs this long: rows older than 6 h count as finished so the refill keeps 3 running
if [ "$dry" = 0 ] && [ -s "$L" ]; then
  awk -v now="$(date +%s)" 'BEGIN{OFS="\t"} $4=="running" && now-$1>21600 {$4="finished"} {print}' "$L" > "$L.new" && mv "$L.new" "$L"
fi
# chief 1795: a session pushes its claude/* branch 1-15 min after launch and then is done; a running row whose leaf has a claude/* branch with no new commit for 20 min is finished
# (the 6 h age-out above stays as the backstop). cloud-branches.py is read-only (GitHub API, cached by sha).
CB=
if [ "${ROUTER_SKIP_CLOUD_MAINTENANCE:-0}" != 1 ]; then
  CB=$(timeout 200 python3 "$ROUTER_BIN/cloud-branches.py" 2>/dev/null || true)
fi
if [ -n "$CB" ]; then
  for suf in $(printf '%s\n' "$CB" | awk -F'\t' '$4>=20 && $5!="" {print $5}' | sort -u); do
    leaf="dos-product-v1-88cgo.$suf"
    if awk -v l="$leaf" '$2==l && $4=="running"{f=1} END{exit !f}' "$L"; then
      awk -v l="$leaf" 'BEGIN{OFS="\t"} $2==l && $4=="running" {$4="finished"} {print}' "$L" > "$L.new" && mv "$L.new" "$L"
      echo "cloud-launch: $leaf finished (branch pushed, quiet 20 min)"
    fi
  done
  # chief 1810 (captain: bosgame implementation stopped, BOS_CAP 0): pickup for finished leaves whose branch has no delivery trace goes to a NETCUP
  # priority lane (cap <= 3, no BUILD at load5 >= 8, handled by lane-refill.sh); oldest first. At most 2 queued-but-unstarted pickups at a time.
  # chief 2325 (4 finished pickups waited all day behind 8 stale queue entries): an unstarted entry counts as queued only when its brief is
  # younger than 2 h and its leaf has not landed (merged PR on a branch naming the leaf) and is not live elsewhere (sent to or owned by
  # bosgame, or a live netcup lane). Round 3 (chief 2337): each skipped entry is retired from priority-lanes.txt into a dated file, with its reason.
  MPR=$(gh pr list -R Authentis/decision-os --state merged --limit 400 --json headRefName -q '.[].headRefName' 2>/dev/null)
  # chief 2337 P2: a netcup lane for <slug> is live only with an agent process in its worktree AND a working last status (refill_lib's own
  # predicates, as go-slot.sh uses); a retained .meta of a finished or dead lane is not ownership.
  live_lane(){ local m wt st
    for m in "$H"/state/dos-*-"$1"-*.meta; do [ -e "$m" ] || continue
      wt=$(grep -m1 '^worktree=' "$m" | cut -d= -f2); [ -n "$wt" ] || continue
      [ "$(python3 "$ROUTER_BIN/refill_lib.py" alive "$wt" 2>/dev/null)" = 1 ] || continue
      st=$(grep -v '^[[:space:]]*$' "${m%.meta}.status" 2>/dev/null | tail -1)
      [ "$(python3 "$ROUTER_BIN/refill_lib.py" working '' "$st" 1 2>/dev/null)" = 1 ] && return 0
    done; return 1; }
  queued=0
  for t in $(cat "$H/data/bin/priority-lanes.txt" 2>/dev/null); do
    case $t in dos-netcup-cloud-*) ;; *) continue;; esac
    [ -e "$H/state/$t.meta" ] && continue
    slug=${t#dos-netcup-cloud-}; slug=${slug%-1003}; suf=$(printf '%s' "$slug" | tr - .)
    bf="$H/data/$t/brief.md"; age=$(( $(date +%s) - $(stat -c %Y "$bf" 2>/dev/null || echo 0) ))
    if [ "$age" -gt 7200 ]; then why="queued $((age/60)) min ago (> 2 h)"
    elif printf '%s\n' "$MPR" | grep -qE "(^|-)$slug(-1[0-9]{3}|-r[0-9]|$)"; then why="leaf landed (merged PR branch names $slug)"
    elif [ -s "$H/data/dos-bosgame-cloud-$slug-1001/message.txt" ] || grep -qx "dos-product-v1-88cgo.$suf" "$H/data/bosgame-owned.txt" 2>/dev/null; then why="live on bosgame (sent or bosgame-owned)"
    elif live_lane "$slug"; then why="live netcup lane for $slug"   # chief 2337 P2: agent process + working status, not a .meta
    else queued=$((queued+1)); continue; fi
    # chief 2337 P1 #3: a skipped entry is retired at once (moved to a dated file), so ghosts never pile up behind queued=0
    if [ "$dry" = 1 ]; then echo "cloud-launch: would retire $t from priority-lanes.txt: $why"; continue; fi   # chief 2340 #4: dry run writes nothing
    # chief 2350 #2: the archive append must succeed before removal; "retired" is printed only after the rewrite succeeded
    echo "$t $(date +%s) $why" >> "$H/data/bin/priority-lanes.retired-$(date +%Y%m%d).txt" || { echo "cloud-launch: NOT retired $t (archive write failed)"; continue; }
    python3 - "$H/data/bin/priority-lanes.txt" "$t" <<'PY' || { echo "cloud-launch: NOT retired $t (queue rewrite failed; the archived line stays as the record)"; continue; }
import os, sys
p, t = sys.argv[1], sys.argv[2]
ls = open(p).read().splitlines(True)
keep = [l for l in ls if l.strip() != t]
if len(keep) != len(ls):
    open(p + '.tmp', 'w').writelines(keep); os.replace(p + '.tmp', p)
PY
    echo "cloud-launch: retired $t from priority-lanes.txt: $why"
  done
  printf '%s\n' "$CB" | awk -F'\t' '$6=="open" && $4>=20 {print $5"\t"$1}' | while IFS=$'\t' read -r suf br; do
    [ "$queued" -ge 2 ] && { echo "cloud-launch: pickup $suf waits (2 netcup pickups already queued)"; continue; }
    [ "$dry" = 1 ] && { echo "cloud-launch: would route pickup $suf ($br) to a netcup lane"; queued=$((queued+1)); continue; }   # chief 2350 #3: cap first, count simulated pickups
    bash "$ROUTER_BIN/cloud-pickup-netcup.sh" "$suf" "$br" 2>&1 | tail -1 | sed 's/^/cloud-launch: /'
    queued=$((queued+1))
  done
fi
# chief 2566 (1): no new cloud launch while data/cloud-launch.hold exists (until launches claim their leaf); pickup routing above still runs
[ -e "$H/data/cloud-launch.hold" ] && { echo "cloud-launch: paused by data/cloud-launch.hold (chief 2566), no launch"; exit 0; }
running=$(awk '$4=="running"' "$L" 2>/dev/null | wc -l)
need=$((TARGET - running))
# chief 1796 (captain 10-03): budget $10/day = 16 launches a day (~$0.63 a leaf); count today's (Asia/Dubai day) ledger rows and stop at 16.
# Balance: captain reading $170 of $250 at 1791005943 (2026-10-03T05:39Z), minus ~$0.63 per launch since; floor $20.
today0=$(TZ=Asia/Dubai date -d "$(TZ=Asia/Dubai date +%F) 00:00" +%s)
today=$(awk -v t="$today0" '$1>=t' "$L" 2>/dev/null | wc -l)
# chief 3882: the balance comes from the latest captain reading in data/cloud-balance.readings (epoch, USD, note), minus ~$0.63 per launch since it
# (the old fixed $170 @ 1791005943 baseline is the fallback when the file has no readable line).
rd=$(awk 'NF>=2 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9.]+$/ {l=$0} END{print l}' "$H/data/cloud-balance.readings" 2>/dev/null)
rt=$(printf '%s' "$rd" | awk '{print $1}'); rb=$(printf '%s' "$rd" | awk '{print $2}')
[ -n "$rt" ] || { rt=1791005943; rb=170; }
balance=$(awk -v n="$(awk -v t="$rt" '$1>t' "$L" 2>/dev/null | wc -l)" -v b="$rb" 'BEGIN{printf "%.0f", b-0.63*n}')
[ "$need" -gt $((16 - today)) ] && need=$((16 - today)); [ "$need" -lt 0 ] && need=0
[ "$balance" -lt 20 ] && need=0
echo "cloud-launch: running=$running target=$TARGET need=$need launched_today=$today/16 est_balance_usd=$balance"
[ "$need" -le 0 ] && exit 0
[ -s "$C" ] || { echo "cloud-launch: no candidates.json (run lane-refill first)"; exit 0; }
HELD='10\.15\.1$|10\.15\.2\.3|10\.3\.2|11\.11\.6\.1|11\.2\.4\.1|11\.5\.1|11\.5\.2|11\.11\.4\.[45]$'
launched=0
for id in $(python3 - "$C" <<'PY'
import json, sys
c = [x for x in json.load(open(sys.argv[1]))
     if not x.get('overlap') and not x.get('netcup_only')]
print(' '.join(str(x['id']) for x in reversed(c) if x.get('id')))
PY
); do
  [ "$launched" -ge "$need" ] && break
  echo "$id" | grep -qE "$HELD" && continue
  grep -q "	$id	" "$L" && continue
  suf=${id#dos-product-v1-88cgo.}
  ls -d "$H"/data/dos-leaf-"$(printf '%s' "$suf" | tr . -)"-* >/dev/null 2>&1 && continue
  if ! body=$(python3 - "$C" "$id" <<'PY'
import json, sys
row = next(x for x in json.load(open(sys.argv[1])) if x.get("id") == sys.argv[2])
body = row.get("body")
if not isinstance(body, str) or not body.strip(): raise SystemExit(2)
print(body)
PY
); then echo "cloud-launch: malformed task text for $id"; break; fi
  if ! labels_json=$(python3 - "$C" "$id" <<'PY'
import json, sys
row = next(x for x in json.load(open(sys.argv[1])) if x.get("id") == sys.argv[2])
labels = row.get("labels", [])
if not isinstance(labels, list) or any(not isinstance(x, str) for x in labels): raise SystemExit(2)
print(json.dumps(labels, separators=(",", ":")))
PY
); then echo "cloud-launch: malformed task labels for $id"; break; fi
  # chief 3872(c): a leaf a fleet lane (or bosgame) already holds is never launched in the cloud (claim-guard.sh)
  g=$(bash "$ROUTER_BIN/claim-guard.sh" cloud-launch "$id") || { echo "cloud-launch: $g"; continue; }
  if [ "$dry" = 1 ]; then echo "cloud-launch: would launch $id"; launched=$((launched+1)); continue; fi
  live=$(router_classify_task "$body" "$labels_json") || { echo "cloud-launch: classification failed for $id"; break; }
  if ! router_admit "$id" cloud cloud netcup "$live"; then
    echo "cloud-launch: WAIT for $id"
    break
  fi
  if [ "$RA_HARNESS" != claude ] || [ "$RA_MODEL" != claude-sonnet-5-5 ] || { [ "$RA_PROVIDER" != anthropic ] && [ "$RA_PROVIDER" != claude ]; }; then
    echo "cloud-launch: incompatible cloud binding $RA_BINDING ($RA_HARNESS $RA_MODEL)"
    router_cancel "$id" "$RA_INCARNATION" >/dev/null 2>&1 || true
    break
  fi
  if ! cloud_start_gate; then
    router_cancel "$id" "$RA_INCARNATION" >/dev/null 2>&1 || true
    echo "cloud-launch: start gate held for $id"
    break
  fi
  TASK="In the Authentis/decision-os repo, build tracker leaf $id exactly as written below. Rules: tests first for every acceptance line including negatives; fixture-first; no network, no database, no real book, no credentials. Do not edit .beads/ (the tracker). Run only the targeted test files for your change. Commit on one claude/* branch and push it; do not open a PR (netcup gates and opens it). Name the leaf id in the commit message.

LEAF:
$body"
  cloud_cmd=${ROUTER_CLOUD_COMMAND:-claude}
  if ! router_prelaunch; then
    router_cancel "$id" "$RA_INCARNATION" >/dev/null 2>&1 || true
    echo "cloud-launch: router-off before launch"
    break
  fi
  if out=$(cd "$D" && timeout "${ROUTER_CLOUD_TIMEOUT:-120}" "$cloud_cmd" --model "$RA_MODEL" --effort "${RA_EFFORT:-medium}" --cloud "$TASK" 2>&1); then
    launch_rc=0
  else
    launch_rc=$?
  fi
  out=$(printf '%s' "$out" | tr -d '\r')
  session_lines=$(printf '%s\n' "$out" | grep -xE 'session_[A-Za-z0-9]+' || true)
  session_count=$(printf '%s\n' "$session_lines" | awk 'NF{n++} END{print n+0}')
  [ "$session_count" -eq 1 ] && sess=$session_lines || sess=
  if [ "$launch_rc" -ne 0 ] || [ -z "$sess" ]; then
    status=$launch_rc; reason='launch failure'; refused=0; uncertain=0
    if printf '%s' "$out" | grep -qi 'insufficient balance'; then reason='insufficient balance'; refused=1; fi
    if printf '%s' "$out" | grep -qE '(^|[^0-9])402([^0-9]|$)'; then status=402; refused=1; fi
    if printf '%s' "$out" | grep -qE '(^|[^0-9])429([^0-9]|$)'; then status=429; refused=1; fi
    if [ "$launch_rc" -eq 0 ] || [ -n "$sess" ] || [ "$launch_rc" -eq 124 ]; then uncertain=1; fi
    if [ "$refused" = 1 ] || [ "$uncertain" = 0 ]; then
      router_failure "$id" "sync-$RA_INCARNATION" "$status" "$reason" >/dev/null 2>&1 || true
    else
      ambiguous_session=${sess:-unverified-$RA_INCARNATION}
      router_ambiguous "$id" "$ambiguous_session" >/dev/null 2>&1 || true
    fi
    echo "cloud-launch: launch failed for $id"
    break
  fi
  if ! router_confirm "$id" "$sess"; then
    router_ambiguous "$id" "$sess" >/dev/null 2>&1 || true
    echo "cloud-launch: accounting failed for $id"
    break
  fi
  if ! cloud_note_start; then
    echo "cloud-launch: start accounting failed for $id"
    break
  fi
  printf '%s\t%s\t%s\trunning\n' "$(date +%s)" "$id" "$sess" >> "$L" || { echo "cloud-launch: ledger write failed for $id"; break; }
  printf '%s | cloud-worker | %s (%s) | ~0.63 | launched (SM cloud-launch, Sonnet 5.5)\n' "$(TZ=Asia/Dubai date '+%F %H:%M')" "$id" "$sess" >> "$SPEND" || { echo "cloud-launch: spend accounting failed for $id"; break; }
  echo "cloud-launch: launched $id $sess"
  launched=$((launched+1))
done
exit 0
