#!/usr/bin/env bash
# CANDIDATE v3 (packet planning-unblock-worker-packet-4102; CF rounds 2026-10-15). Netcup owns application;
# activates only after source FE + qualified CF exact-diff PASS. Never installed or deployed by bosgame.
# Start a planning pass on bosgame (chief 1460, captain 2026-10-01: more planning passes, scheduled earlier; SO-18 leaf-supply rule).
# usage: bosgame-plan-send.sh <pass-number> [--dry-run]
# Sends ONE "[netcup SM]" message to the bosgame secondmate over `ssh -T bosgame-sm` (forced command: the message must start with "[netcup SM]").
# Records data/dos-planning<N>-bosgame-<MMDD>/message.txt, the marker state/dos-planning<N>-bosgame-<MMDD>.running (lane-refill counts these
# as live planning lanes; a marker older than 8 h is ignored), and a row in data/bosgame-lanes.tsv.
# The pass is tracker-only, ships through the netcup no-mistakes gate, and waits for netcup's GO (the cap of 6 counts it). Netcup lands the PR.
# Scope rule: this sender takes ONLY a proved explicit T1 partition (packet 4102 change 1): the work scope
# is DERIVED from verified row identities, never from caller prose. Anything else is refused, never sent.
set -eu
# Direct override 4049: only planning writers use Pi Sol medium; Claude stays off.
# The receiving owner must retain capacity, allowance, partition and review guards.
H=${FM_HOME:-/home/holu/fm-secondmate-upstream-20260907}   # CANDIDATE: honor the FM_HOME lane-refill already exports (same value in production); lets offline fixtures point at a stub home.
export FM_HOME=$H
ROUTER_BIN=${ROUTER_BIN:-$H/data/bin}; export ROUTER_BIN
FLEET_YAML=${FLEET_YAML:-$H/config/fleet.yaml}; export FLEET_YAML
[ -e "$H/data/router-off" ] && { echo "router-off"; exit 0; }
N=${1:?pass number}; shift
DRY=0; BINDING=${BINDING:-}; INCARNATION=${ROUTER_ADMIT_INCARNATION:-}
while [ $# -gt 0 ]; do case $1 in
  --dry-run) DRY=1;;
  --binding) shift; BINDING=${1:?--binding needs an id};;
  --incarnation) shift; INCARNATION=${1:?--incarnation needs an id};;
  *) echo "bosgame-plan-send: unknown argument: $1" >&2; exit 2;;
esac; shift; done
id="dos-planning$N-bosgame-$(date +%m%d)"
D=$H/data/$id
live=$(grep -L -x 'worktree=/tmp/claude-1000/pr-check-core' "$H"/state/dos-*.meta 2>/dev/null | sed 's#.*/##; s#\.meta##' | grep -v -E '^dos-bosgame|^dos-usage' | tr '\n' ' ')   # plan v2 leaf 3: land-task records (worktree=pr-check-core) are not live lanes, as lane-refill.sh:96
cloud=$(grep -o 'Cloud-built leaves in the SO-11 ledger.*' "$H/data/dos-planning23-sol-1001/supply-snapshot.md" 2>/dev/null | head -1 | cut -c1-900)
# chief 1628: BG_PLAN_OPUS=1 aims this pass at splitting open parents that lack FILES leaves
# Direct override 4049: planning writers use Pi Sol medium, only while supply is under 25;
# pass the current dispatchable supply count as BG_PLAN_SUPPLY or the send is refused.
case "${BG_PLAN_SUPPLY:-}" in ''|*[!0-9]*) echo "bosgame-plan-send: refused: set BG_PLAN_SUPPLY=<current leaf supply> (chief 204727)" >&2; exit 3;; esac
[ "$BG_PLAN_SUPPLY" -lt 25 ] || { echo "bosgame-plan-send: refused: leaf supply $BG_PLAN_SUPPLY is not under 25 (chief 204727)" >&2; exit 3; }
# CANDIDATE packet-4102 change 1 (v3, CF F1): trigger AND sender refuse an unproved/non-T1 partition.
# The work scope is DERIVED from verified row identities against the current netcup-owned T1 authority
# ($T1_AUTHORITY_FILE, default $H/data/t1-plan-authority.tsv):
#   <letter><TAB><row-id><TAB><parent-id>      member rows of one disjoint partition
#   EXCLUDE<TAB><identity><TAB><note>          excluded/protected identities (never work rows)
# The pass claims BG_T1_LETTER + BG_T1_ROWS (explicit row identities). The gate verifies: the authority
# is present; the letter owns member rows; every claimed row is a current member and not excluded;
# no claimed row is owned by another letter; no claimed row's parent is shared with another letter's
# rows (row AND parent disjointness, enforced here so direct sender calls cannot bypass the trigger).
# BG_SCOPE/SCOPE_OVERRIDE (override paths) may only NARROW: each must name at least one admitted member
# row, and no row-like token or excluded identity outside the admitted set may appear in any caller text
# (prose instructions like 'plan all T2 work' name no member row and are refused). Caller prose is NEVER
# transmitted: the message scope is derived from the admitted rows only.
# NETCUP-APPLY: the real T1 assignments live with the receiving owner; populate the authority file
# before activation. Until then every send is refused by default and no rows are ever invented.
T1_AUTH_FILE=${T1_AUTHORITY_FILE:-$H/data/t1-plan-authority.tsv}
[ -n "${BG_T1_LETTER:-}" ] || { echo "bosgame-plan-send: refused: set BG_T1_LETTER=<admitted partition letter> (packet 4102 change 1)" >&2; exit 3; }
[ -n "${BG_T1_ROWS:-}" ] || { echo "bosgame-plan-send: refused: set BG_T1_ROWS='<explicit row identities>' (packet 4102 change 1)" >&2; exit 3; }
[ -s "$T1_AUTH_FILE" ] || { echo "bosgame-plan-send: refused: no T1 authority at $T1_AUTH_FILE (packet 4102 change 1: unproved partitions are never sent)" >&2; exit 3; }
gate_out=$(BG_T1_SCOPE="${BG_T1_SCOPE:-}" BG_SCOPE="${BG_SCOPE:-}" SCOPE_OVERRIDE="${SCOPE_OVERRIDE:-}" \
  T1_ROWS="$BG_T1_ROWS" T1_LETTER="$BG_T1_LETTER" T1_AUTH="$T1_AUTH_FILE" python3 - <<'PY3GATE' || exit 3
import os, re, sys
auth, letter = os.environ['T1_AUTH'], os.environ['T1_LETTER']
claimed = os.environ['T1_ROWS'].split()
members, owner, owners, parent_of, parent_letters, excludes = set(), {}, {}, {}, {}, set()
try:
    for line in open(auth):
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        f = line.split('\t')
        if f[0] == 'EXCLUDE' and len(f) >= 2 and f[1]:
            excludes.add(f[1])
        elif len(f) >= 2 and f[0] and f[1]:
            owner[f[1]] = f[0]
            owners.setdefault(f[1], set()).add(f[0])
            par = f[2] if len(f) >= 3 else ''
            parent_of[f[1]] = par
            if f[0] == letter:
                members.add(f[1])
            if par:
                parent_letters.setdefault(par, set()).add(f[0])
except OSError as e:
    sys.exit('bosgame-plan-send: refused: cannot read T1 authority %s: %s' % (auth, e))
if not members:
    sys.exit('bosgame-plan-send: refused: letter %r owns no member row in %s' % (letter, auth))
bad = [r for r in claimed if r in excludes]
if bad:
    sys.exit('bosgame-plan-send: refused: claimed row(s) %s are excluded (never rescope protected/excluded identities)' % ','.join(bad))
bad = [r for r in claimed if r not in members]
if bad:
    sys.exit('bosgame-plan-send: refused: claimed row(s) %s are not current members of letter %s' % (','.join(bad), letter))
duped = [r for r in claimed if len(owners.get(r, ())) > 1]
if duped:
    sys.exit('bosgame-plan-send: refused: row(s) %s owned by multiple letters %s (no duplicate rows across partitions, any parent)'
             % (','.join(duped), ','.join(sorted({l for r in duped for l in owners[r]}))))
NAMED = ('exact46', 'PR3166', 'batch1', 'batches2-5', 'batches 2-5', '200/145')
tok = re.compile(r'[0-9]+\.[0-9][0-9.]*')
def check_text(label, text, must_name):
    for t in tok.findall(text):
        if t in excludes or t not in members:
            sys.exit('bosgame-plan-send: refused: %s names %s outside the admitted partition' % (label, t))
    for n in NAMED:
        if n in text:
            sys.exit('bosgame-plan-send: refused: %s names excluded identity %s' % (label, n))
    if must_name and not [t for t in tok.findall(text) if t in members]:
        sys.exit('bosgame-plan-send: refused: %s names no admitted member row (overrides narrow, never widen or instruct)' % label)
    return {t for t in tok.findall(text) if t in members}
effective = set(claimed)
check_text('BG_T1_SCOPE', os.environ.get('BG_T1_SCOPE') or '', False)
for label in ('BG_SCOPE', 'SCOPE_OVERRIDE'):
    text = os.environ.get(label) or ''
    if text:
        effective &= check_text(label, text, True)
if not effective:
    sys.exit('bosgame-plan-send: refused: overrides admit no rows (narrowing left nothing)')
for r in effective:
    if owner.get(r) != letter:
        sys.exit('bosgame-plan-send: refused: row %s is owned by letter %s, not %s' % (r, owner.get(r), letter))
    par = parent_of.get(r) or ''
    if par and len(parent_letters.get(par, ())) > 1:
        sys.exit('bosgame-plan-send: refused: parent %s of row %s is shared with letters %s (conflicting parent ownership)'
                 % (par, r, ','.join(sorted(parent_letters[par]))))
ordered = [r for r in claimed if r in effective]
print(' '.join(ordered))
print(' '.join(sorted({parent_of[r] for r in ordered if parent_of.get(r)})))
PY3GATE
)
ADMITTED_ROWS=$(printf '%s\n' "$gate_out" | sed -n '1p')
ADMITTED_PARENTS=$(printf '%s\n' "$gate_out" | sed -n '2p')
[ -n "$ADMITTED_ROWS" ] || { echo "bosgame-plan-send: refused: admission left no rows" >&2; exit 3; }
export BG_T1_LETTER ADMITTED_ROWS ADMITTED_PARENTS
mkdir -p "$D"
if [ -n "$BINDING" ]; then
  lane_info=$(python3 "$ROUTER_BIN/refill_lib_v2.py" binding-lane "$BINDING" 2>/dev/null) || { echo "bosgame-plan-send: refused: unresolvable binding $BINDING" >&2; exit 3; }
  IFS=$'\t' read -r b_harness b_model b_provider b_effort <<< "$lane_info"
  if [ -n "${BG_ADMIT_HARNESS:-}" ] && { [ "$BG_ADMIT_HARNESS" != "$b_harness" ] || [ "${BG_ADMIT_MODEL:-}" != "$b_model" ] || [ "${BG_ADMIT_PROVIDER:-}" != "$b_provider" ] || [ "${BG_ADMIT_EFFORT:-}" != "$b_effort" ]; }; then
    echo "bosgame-plan-send: refused: binding no longer matches admitted tuple" >&2; exit 3
  fi
  LANE="harness $b_harness, provider $b_provider, model $b_model, effort $b_effort; router binding $BINDING, incarnation ${INCARNATION:-missing}; remote final catalog recheck required immediately before launch"
else
  LANE="pi harness, provider openai-codex, model gpt-6.1-sol, effort high"
fi
if [ "${ROUTER_LIVE:-0}" = 1 ] && { [ -z "$BINDING" ] || [ -z "$INCARNATION" ]; }; then
  echo "bosgame-plan-send: refused: live route requires binding and incarnation" >&2; exit 3
fi
EXTRA=""
if [ "${BG_PLAN_OPUS:-0}" = 1 ]; then
  EXTRA="FOCUS FOR THIS PASS: split open PARENT items whose specs lack FILES leaves into S-sized spec-ready leaves (with FILES, named tests, SIZE), within your scope below."
fi
# pstack planning pilot (chief 1675/1700): append the method fragment to the pass text and record it, as mkplan.sh does for netcup lanes
FRAG="$H/data/planning-method-fragment.md"
if [ -s "$FRAG" ] && [ "${PLAN_METHOD:-1}" != 0 ]; then
  EXTRA="$EXTRA
$(cat "$FRAG")"
  printf 'pstack-planning-v1\n' > "$D/method"
fi
cat > "$D/message.txt" <<EOF
[netcup SM] New planning-pass task for you to dispatch (chief 1460, captain 2026-10-01). Task id: $id. One ship task, tracker-only, in a worktree of decision-os: $LANE, mode no-mistakes, yolo on. It ships ONE PR that only changes .beads/issues.jsonl, through the netcup no-mistakes gate, and you do not merge it (netcup SM lands it).

CAPTAIN'S INTENT (give the worker exactly this): Planning pass $N for decision-os under SO-18. Dispatchable free-ok leaf supply from origin/main is under the leaf-supply floor of 25 (counted as: open, free-ok, unassigned, no children, has FILES, unblocked, not already landed or in a lane). Find the remaining unspecced or under-split T1 work in the proved partition below and turn it into spec-ready leaves that free lanes can build.

SCOPE (T1-ONLY, letter $BG_T1_LETTER, derived from verified identities at send time; disjoint from every other lane): rows $ADMITTED_ROWS (parents $ADMITTED_PARENTS). Work ONLY these rows; do not touch anything outside them.
EXCLUSIONS (never rescope, never duplicate): protected200/145, the existing exact46 pass, its batch1 PR3166 and batches2-5. If this partition yields no safe disjoint rows, report that admission failure and stop; never invent rows.

RULES: (a) every field a leaf consumes must exist on origin/main in a named file and symbol; otherwise add a source leaf first and block on it. (b) exactly ONE open leaf creates each new file path; grep .beads/issues.jsonl and open PRs for the paths first (gh pr list). (c) do not duplicate a leaf another open bead or PR already covers. (d) a split must not drop a parent acceptance criterion: map each to a leaf or an explicit split-after remainder. (e) every leaf has a Negative acceptance test on the production path. (f) keep parent/child edges in br form; never add a blocks edge from a parent onto its own child (no-cycle rule); verify acyclic. (g) PR body: truly dispatchable count before and after, new leaves with labels, an ## Acceptance check section, ## Fix evidence per finding after any fix round. (h) never --yes; answer every review finding approve or fix; an ask-user finding is answered by netcup SM (post it to parent-replies, keyed). Never push to main, never rebase, never force-push; merge origin/main in before the gate run. (i) TRACKER (canonical single-writer netcup policy): use the worktree-local br storage (.beads/beads.db inside the worker's worktree). Before ANY tracker write, run scripts/br_worktree_storage.py verify-session from the worker's worktree and stop on refusal; do NOT create or follow a .beads/redirect to another clone's .beads and never touch another clone's .beads. Never commit tracker JSONL from a linked worktree, and never route around a guard refusal by rebuilding a local DB or by any other new waiver: no waiver applies to this pass. Only .beads/issues.jsonl may be in the commit; after br export restore any unrelated rows br normalized (compare with origin/main, keep main bytes for rows you did not change) and report the counts. (j) Do not run the full suite; the gate runs it. (k) SPEC QUALITY (chief 2078): every leaf spec must name its negative cases as acceptance tests (unknown, invalid, non-finite, empty, zero and negative inputs, each with its expected refusal or unknown result), list the exact FILES and README rows it may touch and nothing else, and fit 350 changed physical lines including tests and fixtures or be split now; re-check still-unstarted leaves against these three and fix any that fail.

$EXTRA

CURRENT CONTEXT (do not plan these; they are taken): netcup live lanes: $live
$cloud

GATE: commit when ready, then STOP and post 'done awaiting GO' (with the commit sha and the dispatchable before/after counts) to your parent-replies for netcup SM. Do not start /no-mistakes until netcup SM sends GO (netcup's validation cap of 6 counts this run). After GO the worker drives the gate itself and posts the PR URL when checks pass; findings it cannot disposition go back to netcup SM as keyed needs-decision lines.
EOF
# chief 221016 (5e) / FM 3249 (e): the GO wait above is stale; the pass stops without a gate run only when it has 0 new leaves and
# 0 repairs (N1 #9), otherwise it drives its own gate. Kill switch data/plan-send-go-stop.on restores the old GATE text.
# Backup: bosgame-plan-send.sh.bak-20261011-3259e
if [ ! -e "$H/data/plan-send-go-stop.on" ]; then
  python3 - "$D/message.txt" <<'PY3'
import sys
p = sys.argv[1]
t = open(p).read()
lines = t.split('\n')
idx = [i for i, l in enumerate(lines) if l.startswith('GATE: commit when ready, then STOP and post ')]
if len(idx) != 1:
    sys.exit('bosgame-plan-send: GATE paragraph not found exactly once (%d); message left unsent' % len(idx))
lines[idx[0]] = ("GATE: commit when ready. If the pass adds 0 new leaves and makes 0 repairs, STOP without a gate run and post "
                 "'done no-op' (with the dispatchable before/after counts) to your parent-replies for netcup SM. Otherwise "
                 "start /no-mistakes yourself, drive the gate and post the PR URL when checks pass; findings you cannot "
                 "disposition go back to netcup SM as keyed needs-decision lines.")
open(p, 'w').write('\n'.join(lines))
PY3
  [ $? = 0 ] || exit 4
fi
wc -c "$D/message.txt" | awk '{print "message bytes:",$1}'
if [ "$DRY" = 1 ]; then echo "bosgame-plan-send: dry-run, nothing sent ($id)"; exit 0; fi
# The per-id check/persist/send lifecycle is serialized on $D/send.lock (the
# existing mechanism also used by lane-refill): concurrent same-id invocations
# cannot double-persist, double-transmit, or overwrite each other's evidence.
exec 200>"$D/send.lock"
flock -w 120 200 || { echo "bosgame-plan-send: NOT delivered ($id): send lock contended" >&2; exit 1; }
if [ -s "$D/delivered.rec" ]; then echo "sent $id (already durably recorded as $(cat "$D/delivered.rec" 2>/dev/null | tr -cd 0-9).msg; not resent)"; exit 0; fi
SEND_BIN=${BOSGAME_SM_SEND:-$H/data/bin/bosgame-sm-send.sh}   # CANDIDATE test hook (default is the production transport)
# The attempted request identity is persisted before transport for diagnostics.
seq=$(($(cat "$D/attempt-seq" 2>/dev/null || echo 0) + 1)); printf '%s\n' "$seq" > "$D/attempt-seq"
msghash=$(sha256sum "$D/message.txt" | cut -d' ' -f1)
scopehash=$(printf '%s|%s' "$BG_T1_LETTER" "$ADMITTED_ROWS" | sha256sum | cut -d' ' -f1)
printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$seq" "$(date +%s)" "$id" "$msghash" "$BG_T1_LETTER" "$scopehash" > "$D/attempt-$seq.tsv"
if "$SEND_BIN" < "$D/message.txt" > "$D/reply-$seq.txt" 2>&1; then rc=0; else rc=$?; fi
out=$(head -c 400 "$D/reply-$seq.txt" | tr '\n' ' ')
echo "bosgame-plan-send: bosgame replied (rc=$rc, attempt $seq): $out"
# Prior evidence is never overwritten: reply-N.txt/result-N.txt are per-attempt records.
result() { printf '%s\t%s\t%s\n' "$(date +%s)" "$1" "$2" > "$D/result-$seq.txt"; }
fail_delivery() {
  result failed "$1 (attempt $seq)"
  echo "bosgame-plan-send: NOT delivered ($id): $1 (attempt $seq)" >&2
  exit 1
}

# v3 transport contract: delivery is the anchored positive acknowledgement from
# the transport, provided the reply contains no explicit error marker.  A future
# receiver receipt verifier may observe this outcome, but is intentionally not a
# delivery gate and does not create a reconciliation state.
if [ "$rc" != 0 ]; then fail_delivery "transport rc=$rc"; fi
if [ -z "$(tr -d '[:space:]' < "$D/reply-$seq.txt")" ]; then fail_delivery "empty transport reply"; fi
# chief 4906: a busy bosgame answers "fm-ring: doorbell refused ... the steer stays durably recorded at .../N.msg".
# That steer IS delivered (recorded as N.msg; the doorbell only rings later): it counts as delivered and is never resent.
rec=$(sed -nE 's/.*doorbell refused.*steer stays durably recorded at [^ ]*\/([0-9]+)\.msg.*/\1/p' "$D/reply-$seq.txt" | head -1)
if [ -n "$rec" ]; then
  printf '%s\n' "$rec" > "$D/delivered.rec"
else
  if ! grep -qE '^(replied|sent)' "$D/reply-$seq.txt"; then fail_delivery "missing positive acknowledgement"; fi
  if grep -qiE 'must start|not sent|error|denied|refused|fail|unknown|timeout' "$D/reply-$seq.txt"; then
    fail_delivery "transport error marker"
  fi
fi

# Record local accounting after the transport has delivered.  An accounting
# warning must not change the delivery result: it can be repaired locally while
# the remote message remains delivered.
result delivered "positive acknowledgement (attempt $seq)"
exec 201>"$H/state/$id.running.lock"
if flock -w 60 201; then
  if ! printf '%s\n' "$(date +%s)" > "$H/state/$id.running"; then
    echo "bosgame-plan-send: WARNING ($id): could not write running marker after delivery" >&2
  fi
  if ! printf '%s\t%s\t%s\n' "$(date +%s)" "$id" "sent" >> "$H/data/bosgame-lanes.tsv"; then
    echo "bosgame-plan-send: WARNING ($id): could not append bosgame lane ledger after delivery" >&2
  fi
  exec 201>&-
else
  echo "bosgame-plan-send: WARNING ($id): marker lock contended after delivery" >&2
fi
echo "bosgame-plan-send: delivered ($id), attempt $seq"
echo "sent $id"
