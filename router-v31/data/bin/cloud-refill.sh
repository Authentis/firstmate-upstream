#!/usr/bin/env bash
# SO-11 cloud refill (chief 1287, captain 2026-09-28 22:27): keep 5 cloud Sonnet 5.5 workers running (chief 1337, captain 2026-09-29: was 3).
# Run once per wake-handling turn: cloud-refill.sh [--dry-run]
# Ledger: data/cloud-workers.tsv  <launched-epoch> <leaf> <session> <state: running|finished>
# A worker counts as finished once a claude/* branch naming its leaf has stayed quiet (the
# cloud-workers check reports quiet:<ref>) - mark it with: cloud-refill.sh --finish <leaf>
# Eligible: br ready leaves (no children, unassigned) whose title/body do not touch book data,
# live DB, market data, secrets, Claude-only or private data (SO-16 list excluded).
# Budget: captain reading 228 USD at 09-28 20:37 +04, ~1.85 USD per session measured (12 for 22 USD).
# Stops launching when the estimated balance is under $20.
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
W=${ROUTER_WORKDIR:-/tmp/claude-1000/cloud-refill}
C=${ROUTER_CANDIDATES:-${ROUTER_WORKDIR:-/tmp/claude-1000/lane-refill}/candidates.json}
L=$H/data/cloud-workers.tsv
S=$W
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
if [ "${1:-}" = --finish ]; then
  stamp=$(date +%Y%m%d%H%M%S)
  cp "$L" "$L.bak-$stamp" || exit 1
  awk -v l="$2" 'BEGIN{OFS="\t"} $2==l && $4=="running" {$4="finished"} {print}' "$L" > "$L.new" && mv "$L.new" "$L"
  exit 0
fi
dry=0; [ "${1:-}" = --dry-run ] && dry=1
if [ "$dry" = 0 ]; then
  mkdir -p "$S" "$H/data"
  touch "$L"
  exec 7>"$L.lock"; flock -n 7 || { echo "cloud-refill: another cloud helper is running"; exit 0; }
fi
running=$(awk '$4=="running"' "$L" 2>/dev/null | wc -l)
# chief 2293: the balance comes from the LATEST captain reading in data/cloud-balance.readings ("<epoch> <usd> <note>", one per line,
# appended whenever the captain gives a reading), minus ~1.85 USD per launch since that reading. No readings file -> the old 09-29 reading.
rd=$(grep -E '^[0-9]+ [0-9.]+' "$H/data/cloud-balance.readings" 2>/dev/null | sort -n | tail -1)
r_t=${rd%% *}; r_usd=$(printf '%s' "$rd" | awk '{print $2}')
[ -n "$rd" ] || { r_t=1790693820; r_usd=208; }
since=$(awk -v t="$r_t" '$1 > t' "$L" 2>/dev/null | wc -l)
balance=$(awk -v r="$r_usd" -v n="$since" 'BEGIN{printf "%.0f", r - 1.85*n}')
echo "cloud-refill: balance source: captain reading $r_usd USD at $(date -d "@$r_t" '+%F %H:%M %Z'), $since launches since"
echo "cloud-refill: running=$running est_balance_usd=$balance"
# SO-11 pickup step (captain via chief 1372): finished cloud leaves still open with no pickup lane brief get a PICKUP NEEDED line, worked BEFORE any new leaf.
for fl in $(awk '$4=="finished"{print $2}' "$L" 2>/dev/null | sort -u); do
  st=$(cd "$D" && br show "$fl" 2>/dev/null | sed -n '1p' | grep -o '\[● P[0-9] · [A-Z_]*\]' | sed 's/.*· //; s/\]//')
  [ "$st" = "CLOSED" ] && continue
  ls "$H"/data/dos-cloud-*/brief.md 2>/dev/null | xargs grep -l "$fl" >/dev/null 2>&1 || echo "PICKUP NEEDED: $fl (status ${st:-?}, no dos-cloud-* pickup brief)"
done
[ "$balance" -lt 20 ] && { echo "cloud-refill: balance under \$20, no launch"; exit 0; }
today0=$(TZ=Asia/Dubai date -d "$(TZ=Asia/Dubai date +%F) 00:00" +%s)
today=$(awk -v t="$today0" '$1>=t' "$L" 2>/dev/null | wc -l)
need=$((TARGET - running))
[ "$need" -gt $((16 - today)) ] && need=$((16 - today))
[ "$need" -le 0 ] && exit 0
[ -s "$C" ] || { echo "cloud-refill: no candidates.json (run lane-refill first)"; exit 0; }
# 2026-10-01 chief 1454: never claim (br write) on a DB that lacks rows origin/main has; a stale-DB export once dropped 54 open leaves (commit e39893d23).
if [ "$dry" = 0 ]; then
  "$ROUTER_BIN/tracker-sync-guard.sh" pre || { echo "cloud-refill: tracker guard refused, no claim and no launch this run"; exit 0; }
fi
HELD='10\.15\.1$|10\.15\.2\.3|10\.3\.2|11\.11\.6\.1|11\.2\.4\.1|11\.5\.1|11\.5\.2|11\.11\.4\.[45]$'
BAD='backfill|daily run|universe|ingest|book|holding|live store|live db|postgres|database_url|market data|eodhd|secret|credential|token|claude-only|private|mnpi|account'
launched=0
FREEOK=$(cd "$D" && br ready --limit 500 --json 2>/dev/null | python3 -c 'import json,sys
try: rows=json.load(sys.stdin)
except Exception: rows=[]
print("\n".join(str(x.get("id")) for x in rows if "free-ok" in (x.get("labels") or [])))')
# 2026-09-30: draw from lane-refill's dispatchable list (open, unassigned, free-ok, unlanded); br ready hides child leaves whose parent is open.
for id in $(python3 - "$C" <<'PY'
import json, sys
print(" ".join(str(x.get("id")) for x in json.load(open(sys.argv[1])) if x.get("id")))
PY
); do
  [ "$launched" -ge "$need" ] && break
  echo "$id" | grep -qE "$HELD" && continue
  grep -q "	$id	" "$L" && continue
  # 2026-09-30: only leaves lane-refill lists as dispatchable (free-ok, not landed per merged PR bodies, unassigned) and with no netcup/bosgame lane dir;
  # run lane-refill first so candidates.json is fresh. Without it the tracker's ready queue hands out landed work (12.7.7 landed via PR 1074 but is still OPEN).
  python3 - "$C" "$id" <<'PY' >/dev/null 2>&1 || continue
import json, sys
raise SystemExit(0 if any(x.get("id") == sys.argv[2] for x in json.load(open(sys.argv[1]))) else 1)
PY
  ls -d "$H"/data/dos-leaf-"$(printf '%s' "${id#dos-product-v1-88cgo.}" | tr . -)"-* >/dev/null 2>&1 && continue
  # the tracker's ready queue can hand out already-landed work: skip a leaf main already names
  git -C "$D" log origin/main --oneline --grep="$id\b" -E -n 1 2>/dev/null | grep -q . && continue
  (cd "$D" && br show "$id" 2>/dev/null | grep -qE '^ *<- .*\(parent-child\)') && continue  # has children: not a leaf
  if ! body=$(python3 - "$C" "$id" <<'PY'
import json, sys
row = next(x for x in json.load(open(sys.argv[1])) if x.get("id") == sys.argv[2])
body = row.get("body")
if not isinstance(body, str) or not body.strip(): raise SystemExit(2)
print(body)
PY
); then echo "cloud-refill: malformed task text for $id"; break; fi
  if ! labels_json=$(python3 - "$C" "$id" <<'PY'
import json, sys
row = next(x for x in json.load(open(sys.argv[1])) if x.get("id") == sys.argv[2])
labels = row.get("labels", [])
if not isinstance(labels, list) or any(not isinstance(x, str) for x in labels): raise SystemExit(2)
print(json.dumps(labels, separators=(",", ":")))
PY
); then echo "cloud-refill: malformed task labels for $id"; break; fi
  # free-ok = planner-certified fixture-only, no book or private data, no network (SO-18); its body names those as guards
  if ! printf '%s\n' "$FREEOK" | grep -qx "$id"; then
    printf '%s' "$body" | sed 's/no real book in tests//Ig; s/no live store//Ig; s/no live DB//Ig' | grep -qiE "$BAD" && continue
  fi
  # never hand a decision bead or an unspecced leaf to a cloud worker (10.9.3.3.8 and dos-yz02z were launched/claimed 2026-09-29)
  printf '%s\n' "$body" | grep -qE 'DECISION NEEDED|needs-spec|Not free-ok|DECISION \(product\)|Not a code task' && continue
  (cd "$D" && br show "$id" 2>/dev/null | grep -qiE '^Labels:.*(needs-spec|decision)') && continue
  suf=${id#dos-product-v1-88cgo.}
  if [ "$dry" = 1 ]; then echo "would launch $id"; launched=$((launched+1)); continue; fi
  live=$(router_classify_task "$body" "$labels_json") || { echo "cloud-refill: classification failed for $id"; break; }
  if ! router_admit "$id" cloud cloud netcup "$live"; then
    echo "cloud-refill: WAIT for $id"
    break
  fi
  if [ "$RA_HARNESS" != claude ] || [ "$RA_MODEL" != claude-sonnet-5-5 ] || { [ "$RA_PROVIDER" != anthropic ] && [ "$RA_PROVIDER" != claude ]; }; then
    echo "cloud-refill: incompatible cloud binding $RA_BINDING ($RA_HARNESS $RA_MODEL)"
    router_cancel "$id" "$RA_INCARNATION" >/dev/null 2>&1 || true
    break
  fi
  g=$(bash "$ROUTER_BIN/claim-guard.sh" cloud-refill "$id") || {
    echo "cloud-refill: $g"; router_cancel "$id" "$RA_INCARNATION" >/dev/null 2>&1 || true; continue;
  }
  if ! (cd "$D" && br update "$id" --claim >/dev/null 2>&1 && br comments add "$id" "claimed by netcup SM for an SO-11 cloud Sonnet 5.5 worker (refill, chief 1287)" >/dev/null); then
    router_cancel "$id" "$RA_INCARNATION" >/dev/null 2>&1 || true
    echo "cloud-refill: claim failed for $id"
    continue
  fi
  if ! cloud_start_gate; then
    router_cancel "$id" "$RA_INCARNATION" >/dev/null 2>&1 || true
    (cd "$D" && br update "$id" --status open --assignee "" >/dev/null 2>&1) || true
    echo "cloud-refill: start gate held for $id"
    break
  fi
  TASK="In the Authentis/decision-os repo, build tracker leaf $id exactly as written below. Rules: tests first for every acceptance line including negatives; fixture-first; no network, no database, no real book, no credentials. Do not edit .beads/ (the tracker). Run only the targeted test files for your change. Commit on one claude/* branch and push it; do not open a PR (netcup gates and opens it). Name the leaf id in the commit message.

LEAF:
${body}"
  cloud_cmd=${ROUTER_CLOUD_COMMAND:-claude}
  if ! router_prelaunch; then
    router_cancel "$id" "$RA_INCARNATION" >/dev/null 2>&1 || true
    (cd "$D" && br update "$id" --status open --assignee "" >/dev/null 2>&1) || true
    echo "cloud-refill: router-off before launch"
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
    status=$launch_rc; reason='launch failure'; refused=0; uncertain=0; ambiguous_launch=0
    if printf '%s' "$out" | grep -qi 'insufficient balance'; then reason='insufficient balance'; refused=1; fi
    if printf '%s' "$out" | grep -qE '(^|[^0-9])402([^0-9]|$)'; then status=402; refused=1; fi
    if printf '%s' "$out" | grep -qE '(^|[^0-9])429([^0-9]|$)'; then status=429; refused=1; fi
    if [ "$launch_rc" -eq 0 ] || [ -n "$sess" ] || [ "$launch_rc" -eq 124 ]; then uncertain=1; fi
    if [ "$refused" = 1 ] || [ "$uncertain" = 0 ]; then
      router_failure "$id" "sync-$RA_INCARNATION" "$status" "$reason" >/dev/null 2>&1 || true
    else
      ambiguous_session=${sess:-unverified-$RA_INCARNATION}
      router_ambiguous "$id" "$ambiguous_session" >/dev/null 2>&1 || true
      ambiguous_launch=1
    fi
    [ "$ambiguous_launch" = 1 ] || (cd "$D" && br update "$id" --status open --assignee "" >/dev/null 2>&1) || true
    echo "cloud-refill: launch failed for $id"
    break
  fi
  if ! router_confirm "$id" "$sess"; then
    router_ambiguous "$id" "$sess" >/dev/null 2>&1 || true
    (cd "$D" && br update "$id" --status open --assignee "" >/dev/null 2>&1) || true
    echo "cloud-refill: accounting failed for $id"
    break
  fi
  if ! cloud_note_start; then
    echo "cloud-refill: start accounting failed for $id"
    break
  fi
  printf '%s\t%s\t%s\trunning\n' "$(date +%s)" "$id" "$sess" >> "$L" || { echo "cloud-refill: ledger write failed for $id"; break; }
  printf '%s | cloud-worker | %s (%s) | ~1.85 | launched (SM refill, Sonnet 5.5)\n' "$(TZ=Asia/Dubai date '+%F %H:%M')" "$id" "$sess" >> "$SPEND" || { echo "cloud-refill: spend accounting failed for $id"; break; }
  echo "cloud-refill: launched $id $sess"
  launched=$((launched+1))
done
if [ "$launched" -gt 0 ] && [ "$dry" = 0 ]; then
  # only commit tracker claims when the primary clone is on main (2026-09-29: it sat on a preserve/* branch and six claim commits landed there)
  [ "$(git -C "$D" branch --show-current)" = main ] || { echo "cloud-refill: primary clone not on main, tracker claims left uncommitted"; exit 0; }
  # 2026-09-30: a claim commit must stay an ancestor of origin/main, or serving-catchup refuses ("main is not an ancestor"). Only commit when
  # serving main equals a freshly fetched origin/main; if the push then fails, undo the commit (keeps the file change, which catch-up treats as derived state).
  # 2026-10-01 chief 1454: re-check the EXPORTED jsonl against origin/main right before git add; refuse (leave the file uncommitted) if any origin row would vanish.
  "$ROUTER_BIN/tracker-sync-guard.sh" post || { echo "cloud-refill: tracker guard refused the claim commit; claims left uncommitted"; exit 0; }
  (cd "$D" && git fetch -q origin main && [ "$(git rev-parse main)" = "$(git rev-parse origin/main)" ] \
    && git add .beads/issues.jsonl && git commit -qm "tracker: claim leaves for SO-11 cloud refill" \
    && git push -q origin main) >/dev/null 2>&1 || echo "cloud-refill: claim commit/push incomplete; retained for operator recovery"
fi
exit 0
