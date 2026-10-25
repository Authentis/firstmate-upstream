#!/usr/bin/env bash
# Close-on-landing (chief 1668 item 2): hourly, find open leaves whose own branch merged and, when >= 3 are waiting and no closure lane is live,
# spawn one tracker-only closure lane (Sol high) with the list. lane-refill calls this each pass; the stamp keeps it to once per 50 min. --force skips the stamp; --dry-run lists only.
set -u
H=${FM_HOME:-/home/holu/fm-secondmate-upstream-20260907}
export FM_HOME=$H
ROUTER_BIN=${ROUTER_BIN:-$H/data/bin}; export ROUTER_BIN
FLEET_YAML=${FLEET_YAML:-$H/config/fleet.yaml}; export FLEET_YAML
[ -e "$H/data/router-off" ] && { echo "router-off"; exit 0; }
. "$ROUTER_BIN/router-launch.sh"
[ -e "$H/data/closure-sweep.hold" ] && { echo "closure-sweep: held (data/closure-sweep.hold)"; exit 0; }
S=$H/state/.closure-sweep.stamp
DRY=0; FORCE=0
for a in "$@"; do case $a in --dry-run) DRY=1;; --force) FORCE=1;; esac; done
if [ "$FORCE" = 0 ] && [ -e "$S" ] && [ -z "$(find "$S" -mmin +50 2>/dev/null)" ]; then exit 0; fi   # chief 2512 (SO-18 tree review, 2026-10-09): hourly again on a Claude Sonnet lane (was once a day under chief 2054)
# chief 2534: a live closure lane no longer blocks the hourly batch; the new batch skips every id a live closure lane holds
# (its data/<id>/brief.md and state/closure-sweep.list snapshot), so batches never overlap. Backup: closure-sweep.sh.bak-20261009-2534
held=""
for m in "$H"/state/dos-tracker-closures*.meta; do
  [ -e "$m" ] || continue
  held="$held $(grep -oE '[0-9]+(\.[0-9]+)+\(#' "$H/data/$(basename "$m" .meta)/brief.md" 2>/dev/null | sed 's/(#$//' | tr '\n' ' ')"
  echo "closure-sweep: closure lane $(basename "$m" .meta) is live; its ids are excluded from this batch"
done
out=$(python3 "$ROUTER_BIN/landed-leaf-sweep.py") || { echo "closure-sweep: sweep failed"; exit 0; }
if [ -n "${held// }" ]; then out=$(printf '%s\n' "$out" | awk -v h="$held" 'BEGIN{n=split(h,a," ");for(i=1;i<=n;i++)x[a[i]]=1} !($1 in x)'); fi
out=$(printf '%s\n' "$out" | grep . | head -30)   # chief 2528/2534: at most 30 closes per batch
n=$(printf '%s' "$out" | grep -c . || true)
echo "closure-sweep: $n landed-but-open leaves"
[ "$n" -ge 1 ] || exit 0   # chief 2512: threshold >= 1
[ "$DRY" = 1 ] && { printf '%s\n' "$out" | head -40; exit 0; }
# Re-read the current tracker rows for every candidate.  A missing or malformed
# row is unknown and therefore WAIT; credentials are passed to admission so the
# Kimi/free/stealth bans apply to the entire batch.
PROJECT_DIR=${ROUTER_PROJECT_DIR:-/home/holu/decision-os}
rows=$(CLOSURE_ROWS_INPUT="$out" python3 - "$PROJECT_DIR/.beads/issues.jsonl" 2>/dev/null <<'PY'
import json, os, sys
path = sys.argv[1]
wanted = [line.split()[0] for line in os.environ['CLOSURE_ROWS_INPUT'].splitlines() if line.strip()]
found = {}
for line in open(path, encoding='utf-8'):
    row = json.loads(line)
    rid = str(row.get('id') or '')
    for token in wanted:
        if rid == token or rid.endswith('.' + token):
            found[token] = row
if len(found) != len(set(wanted)):
    raise SystemExit(2)
print('\n'.join(json.dumps(found[x], sort_keys=True) for x in wanted))
PY
) || {
  echo "closure-sweep: WAIT: current tracker text unavailable for one or more rows"; exit 0;
}
labels=$(router_labels_from_rows "$rows") || {
  echo "closure-sweep: WAIT: current tracker labels unavailable or malformed"; exit 0;
}
REAL=$(router_classify_task "$rows" "$labels") || {
  echo "closure-sweep: WAIT: task classification failed"; exit 0;
}
printf '%s\n' "$out" > "$H/state/closure-sweep.list"
printf '%s\n' "$rows" > "$H/state/closure-sweep.rows.jsonl"
suffix=$(date +%m%d%H%M)   # chief 1745: unique per run (the hour-only id collided on a second run in the same hour)
id="dos-tracker-closures-sweep-$suffix"
nonce="$(date +%s%N)-$$"
verified_result="$H/state/.closure-helper-verified-$id-$nonce"
if CLOSURE_TASK_ID="$id" CLOSURE_RESULT_FILE="$verified_result" CLOSURE_RESULT_NONCE="$nonce" \
   bash "$ROUTER_BIN/mkclose-template.sh"; then
  printf -v expected '%s\t%s\tverified-accounted' "$id" "$nonce"
  if [ ! -f "$verified_result" ] || [ "$(cat "$verified_result" 2>/dev/null)" != "$expected" ]; then
    if [ -e "$H/data/router-off" ]; then
      echo "closure-sweep: router-off activated; stamp and count unchanged"
      exit 0
    fi
    echo "closure-sweep: fatal verified-launch accounting failure: helper returned without verified accounting evidence; stamp and count unchanged" >&2
    exit 70
  fi
  # mkclose-template only succeeds after router_verify + router_confirm.
  touch "$S"
  echo "$(date -u +%FT%TZ) closure-sweep spawned $id with $(grep -c . "$H/state/closure-sweep.list") ids" >> "$H/data/tree-closes.log"
else
  helper_rc=$?
  if [ "$helper_rc" = 70 ]; then
    echo "closure-sweep: fatal verified-launch accounting failure; stamp and count unchanged" >&2
    exit 70
  fi
  if [ "$helper_rc" = 74 ]; then
    echo "closure-sweep: fatal ambiguous launch; reconciliation required before further starts" >&2
    exit 74
  fi
  echo "closure-sweep: WAIT/failed launch; stamp and count unchanged"
  exit 0
fi
