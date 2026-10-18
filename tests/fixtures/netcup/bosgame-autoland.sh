#!/usr/bin/env bash
# Auto-land bosgame-built PRs (chief 1661, SO-7): any open, non-draft, MERGEABLE Authentis/decision-os PR on any head branch that either
# matches fm/dos-bosgame-*, fm/dos-repoint-split-bosgame-* or fm/dos-planning*-bosgame-*, or carries a repo-bound bosgame gate receipt for its exact
# head plus an exact-head cross-family PASS (any-branch widening; same predicates as netcup-land.sh), whose body carries the no-mistakes appendix
# (the pipeline published it), and that is at least 10 min old, is landed through netcup-land.sh via a local task record (same as scratchpad landpr.sh).
# netcup-land.sh re-checks the gate receipt and the cross-family verdict for the head and only then calls fm-pr-merge.sh.
# usage: bosgame-autoland.sh [--dry-run]
set -u
# chief 4570/4586 floor: a lone review PASS under 30 s never lands a PR. floor_ok passes when the exact-head record ran >= 30 s, or a second-family
# record data/xreview/<pr>-fam2.md for the same exact head says VERDICT: PASS. Kill switch: data/floor-rule.off.
floor_ok() {
  [ -e "$H/data/floor-rule.off" ] && return 0
  local pr=$1 head=$2 f s
  f="$H/data/xreview/$pr.md"
  s=$(sed -n 's/^at=[0-9]* secs=\([0-9]*\) .*/\1/p' "$f" 2>/dev/null | head -1)
  [ "${s:-0}" -ge 30 ] 2>/dev/null && return 0
  f="$H/data/xreview/$pr-fam2.md"
  if [ -e "$f" ] && grep -q "head=$head" "$f" 2>/dev/null && grep -q '^VERDICT: PASS' "$f"; then return 0; fi
  echo "bosgame-autoland: PR $pr floor: lone review under 30 s and no second-family exact-head PASS (chief 4570)" >&2
  floor_autoqueue "$pr" "$head"
  return 1
}
# Review-floor auto-queue (mech B): a refused lone sub-30 s PASS queues the second-family exact-head review itself, on the first
# non-GPT family that is free. At most 2 automatic queues per exact head (state/.floor-n-<pr>-<head>-<family>, one stamp per try, so a
# family is never retried for the same head); the open queue is state/.floor-q-<pr> = "<head> <family>". floor_sweep cancels a queue whose
# head moved (the old head's review is never repeated; the new head earns its own 2 only if it again hits the floor). Families, preference
# order, one per line or space separated: data/floor-families (default "muse grok"; never a GPT family and never the primary reviewer's family, which is Kimi). Kill switch: data/floor-autoqueue.off.
# Queue/cancel commands are data/bin/xreview.sh --family/--cancel; FLOOR_QUEUE_CMD / FLOOR_CANCEL_CMD override them (tests stub them).
floor_families() { local f; f=$(cat "$H/data/floor-families" 2>/dev/null); printf '%s\n' ${f:-muse grok} | grep -viE '^(gpt|openai|codex|sol|kimi)' ; }
floor_family_busy() { local q; for q in "$H"/state/.floor-q-*; do [ -e "$q" ] && [ "$(awk '{print $2}' "$q")" = "$1" ] && return 0; done; return 1; }
FLOOR_CANCELLED=""
FLOOR_LOCK_HELD=0
# every mutation of the queue records (sweep, reserve, launch, rollback) runs under one flock on fd 8 (netcup-land.sh already relies on flock);
# the kernel drops the lock when its holder exits or is killed, so a dead pass can never wedge queueing or cancelling, and nothing is ever stolen
floor_lock_take() { exec 8>"$H/state/.floor-lock" && flock -w "${FLOOR_LOCK_WAIT:-10}" 8 && FLOOR_LOCK_HELD=1 || { exec 8>&-; return 1; }; }
floor_lock_drop() { FLOOR_LOCK_HELD=0; exec 8>&-; }
# current head of a PR; FLOOR_HEAD_CMD overrides the forge lookup (tests stub it)
floor_current_head() { ${FLOOR_HEAD_CMD:-gh pr view --repo Authentis/decision-os --json headRefOid -q .headRefOid} "$1" 2>/dev/null; }
floor_sweep() {
  local pr=$1 rc
  [ -e "$H/state/.floor-q-$pr" ] || return 0
  [ "$FLOOR_LOCK_HELD" = 1 ] && { floor_sweep_locked "$@"; return; }
  floor_lock_take || { echo "bosgame-autoland: PR $pr floor: queue lock busy; sweep waits for the next pass" >&2; return 0; }
  floor_sweep_locked "$@"; rc=$?
  floor_lock_drop; return "$rc"
}
floor_sweep_locked() {
  local pr=$1 head=${2:-} q="$H/state/.floor-q-$1" qh qf
  [ -e "$q" ] || return 0
  [ -e "$q" ] || return 0
  read -r qh qf < "$q"
  if [ -e "$H/data/xreview/$pr-fam2.md" ] && ! [ "$q" -nt "$H/data/xreview/$pr-fam2.md" ] && grep -q "head=$qh" "$H/data/xreview/$pr-fam2.md" 2>/dev/null && grep -q '^VERDICT:' "$H/data/xreview/$pr-fam2.md"; then rm -f "$q"; return 0; fi
  [ -n "$head" ] || head=$(floor_current_head "$pr") || return 0
  [ -n "$head" ] && [ "$head" != "$qh" ] || return 0
  # a failed cancel keeps the record so the next pass retries it; a moved head is never re-queued here
  ${FLOOR_CANCEL_CMD:-bash $H/data/bin/xreview.sh --cancel} "$pr" "$qf" "$qh" >/dev/null 2>&1 || { echo "bosgame-autoland: PR $pr floor review of ${qh:0:8} ($qf) cancel failed; will retry" >&2; return 0; }
  rm -f "$q"; FLOOR_CANCELLED="$FLOOR_CANCELLED $pr"; echo "bosgame-autoland: PR $pr head moved ${qh:0:8} -> ${head:0:8}; cancelled queued $qf floor review" >&2
  return 1
}
floor_autoqueue() {
  local rc
  floor_lock_take || { echo "bosgame-autoland: PR $1 floor: queue lock busy; trying again next pass" >&2; return 0; }
  floor_autoqueue_locked "$@"; rc=$?
  floor_lock_drop; return "$rc"
}
floor_autoqueue_locked() {
  local pr=$1 head=$2 q="$H/state/.floor-q-$1" n=0 fam t cur
  [ -e "$H/data/floor-autoqueue.off" ] || [ "${DRY:-0}" = 1 ] && return 0
  case "$FLOOR_CANCELLED " in *" $pr "*) return 0;; esac   # cancelled earlier this pass: the new head waits for a later pass
  floor_sweep "$pr" "$head" || return 0   # a cancel ends this call; the new head is judged on a later pass
  # the head this pass captured may have moved (and been cancelled by another pass) while waiting for the lock: never queue a superseded head
  # an empty or failed lookup is not proof the head is unchanged, so nothing is queued until the next pass can confirm it
  cur=$(floor_current_head "$pr"); [ "$cur" = "$head" ] || { echo "bosgame-autoland: PR $pr floor: head not confirmed as ${head:0:8} (forge says '${cur:0:8}'); not queued" >&2; return 0; }
  [ -e "$q" ] && { echo "bosgame-autoland: PR $pr floor: second-family review already queued ($(cut -d' ' -f2 "$q"))" >&2; return 0; }
  for t in "$H/state/.floor-n-$pr-$head"-*; do [ -e "$t" ] && n=$((n + 1)); done
  [ "$n" -lt 2 ] || { echo "bosgame-autoland: PR $pr floor: 2 automatic second-family queues already used for head ${head:0:8}" >&2; return 0; }
  while read -r fam; do
    [ -n "$fam" ] && [ ! -e "$H/state/.floor-n-$pr-$head-$fam" ] && ! floor_family_busy "$fam" || continue
    # the record is written before the launch so a review that finishes early is still newer than it; a failed launch rolls it back
    printf '%s %s\n' "$head" "$fam" > "$q"; : > "$H/state/.floor-n-$pr-$head-$fam"
    ${FLOOR_QUEUE_CMD:-bash $H/data/bin/xreview.sh --family} "$fam" "$pr" "$head" "$H/data/xreview/$pr-fam2.md" </dev/null >/dev/null 2>&1 8>&- \
      || { rm -f "$q" "$H/state/.floor-n-$pr-$head-$fam"; continue; }
    echo "bosgame-autoland: PR $pr floor: queued $fam second-family review for head ${head:0:8} ($((n + 1)) of 2)" >&2; return 0
  done < <(floor_families)
  echo "bosgame-autoland: PR $pr floor: no free non-GPT family to queue" >&2
}
[ "${BOSGAME_AUTOLAND_SOURCE_ONLY:-}" = 1 ] && return 0   # tests source the functions above
H=/home/holu/fm-secondmate-upstream-20260907
export FM_HOME=$H
DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1
# main 2286: pause switch; while data/bosgame-autoland.pause exists nothing is landed (dry runs still list)
if [ "$DRY" = 0 ] && [ -e "$H/data/bosgame-autoland.pause" ]; then echo "bosgame-autoland: PAUSED (data/bosgame-autoland.pause, main 2286)"; exit 0; fi
# chief 1708: the hold (cross-family review wanted) no longer blocks landing; instead each PR is reviewed by netcup's Kimi k3 (xreview.sh) and lands only on a PASS for its current head.
XGATE=0; [ -e "$H/data/bosgame-autoland.hold" ] && XGATE=1
# chief 1809: tracker-only conflicts (GitHub ignores the br merge driver) are fixed first by merging origin/main; other conflicts stay for the lane
# chief 2539 (b): at most one fix attempt per PR head; stamp state/.tcf-<pr>-<head8> and skip while it exists (a new head gets a new try)
if [ "$DRY" = 0 ]; then gh pr list --repo Authentis/decision-os --state open --limit 60 --json number,headRefName,headRefOid,mergeable -q '.[] | select(.mergeable=="CONFLICTING" and (.headRefName|startswith("fm/dos-"))) | "\(.number) \(.headRefOid[0:8])"' 2>/dev/null | while read -r _n _h; do
  [ -n "$_h" ] || continue
  if [ -e "$H/state/.tcf-$_n-$_h" ]; then echo "tracker-conflict-fix: PR $_n head $_h already tried, skipped"; continue; fi
  bash "$H/data/bin/tracker-conflict-fix.sh" "$_n" 2>&1 | tail -1; touch "$H/state/.tcf-$_n-$_h"
done; fi
# chief 14:34 (RED): since 12:26 every pass crashed on an empty GraphQL list (rate limit). prlist prints a valid JSON list or nothing:
# GraphQL gh pr list first; when it fails or is not a JSON list, the REST fallback (gh api, core quota) rebuilds the same fields.
# When both fail the pass is skipped and logged (exit 0): never crash, never land on partial data. Kill switch: data/autoland-rest.off
# (GraphQL only, still skip-not-crash).
prlist() {
  local o
  local grc=0
  o=$(gh pr list --repo Authentis/decision-os --state open --limit 60 --json number,headRefName,isDraft,mergeable,createdAt,updatedAt,body 2>/dev/null) || grc=$?
  if [ "$grc" = 0 ] && printf '%s' "$o" | python3 -c 'import json,sys; sys.exit(0 if isinstance(json.load(sys.stdin), list) else 1)' 2>/dev/null; then printf '%s' "$o"; return 0; fi
  [ -e "$H/data/autoland-rest.off" ] && return 1
  o=$(python3 -c '
import json, subprocess, sys
def api(path):
    r = subprocess.run(["gh", "api", path], capture_output=True, text=True, timeout=60)
    if r.returncode != 0:
        sys.exit(1)
    return json.loads(r.stdout)
pulls = api("repos/Authentis/decision-os/pulls?state=open&per_page=60")
if not isinstance(pulls, list):
    sys.exit(1)
out = []
for p in pulls:
    m = "UNKNOWN"
    if not p.get("draft"):
        d = api("repos/Authentis/decision-os/pulls/%d" % p["number"])
        m = {True: "MERGEABLE", False: "CONFLICTING"}.get(d.get("mergeable"), "UNKNOWN")
    out.append({"number": p["number"], "headRefName": p["head"]["ref"], "isDraft": bool(p.get("draft")), "mergeable": m,
                "createdAt": p["created_at"], "updatedAt": p["updated_at"], "body": p.get("body") or ""})
print(json.dumps(out))
' 2>/dev/null) || return 1
  [ -n "$o" ] || return 1
  echo "bosgame-autoland: GraphQL PR list failed; using the REST list ($(printf '%s' "$o" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))') open PRs)" >&2
  printf '%s' "$o"
}
if ! PRS=$(prlist); then echo "bosgame-autoland: gh pr list failed or empty (GraphQL and REST), pass skipped, retry next cycle"; exit 0; fi
# any-branch widening: postrev_ok copied verbatim from netcup-land.sh; keep the two in sync.
postrev_ok() {
  [ -e "$H/data/postrev-rule.off" ] && { echo "post-review rule off (data/postrev-rule.off)"; return 1; }
  local cj cmp files mdl aso nf AG=/tmp/claude-1000/lane-refill/clone; local -a fl
  cj=$(gh api "repos/Authentis/decision-os/compare/$1...$2" 2>/dev/null) || cj=""
  cmp=$(printf '%s' "$cj" | jq -r '.status // empty' 2>/dev/null)
  files=$(printf '%s' "$cj" | jq -r '.files[]?.filename' 2>/dev/null)
  [ -n "$cj" ] && [ -n "$cmp" ] && [ -n "$files" ] || { echo "compare-failed"; return 1; }
  [ "$cmp" = ahead ] || { echo "not-descended($cmp)"; return 1; }
  # Codex 3259 r1 #1: compare lists at most 300 files; a list that may be truncated is refused
  nf=$(printf '%s' "$cj" | jq -r '.files | length' 2>/dev/null)
  [[ $nf =~ ^[0-9]+$ ]] && [ "$nf" -lt 300 ] || { echo "compare-file-list-possibly-truncated($nf)"; return 1; }
  mapfile -t fl < <(printf '%s' "$cj" | jq -r '.files[].filename' 2>/dev/null)
  [ "${#fl[@]}" = "$nf" ] || { echo "file-list-mismatch"; return 1; }
  # Codex 3259 r2: a rename hides its source path (deploy.sh -> deploy.md), so any renamed, copied or removed file is refused
  printf '%s' "$cj" | jq -e '[.files[] | select(.status != "modified" and .status != "added" and .status != "changed")] | length == 0' >/dev/null 2>&1 \
    || { echo "post-review-commit-renames-copies-or-removes-files"; return 1; }
  mdl=$(printf '%s' "$cj" | jq -r '[.files[] | select(.filename | endswith(".md")) | .changes] | add // 0' 2>/dev/null)
  [[ $mdl =~ ^[0-9]+$ ]] || { echo "md-line-count-unreadable"; return 1; }
  [ "$mdl" -le 5 ] || { echo "md-changes-$mdl-lines-over-5"; return 1; }
  git -C "$AG" fetch -q origin "+refs/pull/$pr/head:refs/remotes/origin/pr-$pr" 2>/dev/null || true
  aso=$(python3 "$H/data/bin/ast-same.py" "$AG" "$1" "$2" "${fl[@]}" 2>&1) ||   # Codex 3259 r1 #2: quoted array, no word splitting
 { echo "post-review-commits-touch-code(${1:0:8}..${2:0:8}; $aso)"; return 1; }
  echo "post-review ${1:0:8}..${2:0:8} AST-identical .py / md ${mdl} lines: $aso"; return 0
}
# any-branch widening: repo-bound receipt pre-check with the same validation predicates as netcup-land.sh;
# this selector reports ok without the lander's downstream gate-resolution flag. Keep predicates in sync.
# Sets BG_WHY; returns 0 only when this PR may take the bosgame-receipt path.
# Never invents proof from branch text or origin_host: only a validating receipt (or a gate-pushed head accepted by
# postrev_ok) passes.
bg_receipt_ok() {
  local pr=$1 head=$2 rf pro
  rf=$(mktemp /tmp/claude-1000/autoland-bosreceipt.XXXXXX) || { BG_WHY="could not stage the receipt read"; return 1; }
  timeout 30 ssh -T -o ConnectTimeout=10 -o BatchMode=yes -o IdentitiesOnly=yes -i "$HOME/.ssh/bosgame_readonly_ed25519" lundi@100.126.95.9 \
    "cat /home/lundi/fm-secondmate-dos/data/gate-receipts/$pr.json" > "$rf" 2>/dev/null
  BG_WHY=$(python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("no readable bosgame gate receipt"); sys.exit()
# Codex 3213 r1: bosgame receipts now always carry repo; a missing field is refused
if d.get("repo") != "Authentis/decision-os": print("receipt names repo %r, not Authentis/decision-os" % d.get("repo")); sys.exit()
if str(d.get("pr")) != sys.argv[1]: print("receipt is for PR %s" % d.get("pr")); sys.exit()
# FM 3213: bosgame receipts carry review_verdict and final_head_matches_push; gate_outcome stays "running" on no-CI repos and is not read
# chief 010413 (A) (FM 3335/3339, 2026-10-12): review_verdict "pass-with-approved-warnings" (bosgame writer: every approved finding is a
# WARNING; an approved ERROR stays "fail", SO-19) counts as pass ONLY together with the netcup exact-head cross-family PASS read from
# argv[4] = data/xreview/<pr>.md: the file must be exactly one record - one "at=" line holding the only head= token in the file, equal
# to this head, and one VERDICT line after it, exactly "VERDICT: PASS". argv[4] is empty while data/apw-rule.off exists (kill switch).
# Backup: netcup-land.sh.bak-20261012-apw
def xpass(path, head):
    try:
        lines = open(path).read().splitlines()
    except Exception:
        return False
    at = [i for i, l in enumerate(lines) if l.startswith("at=")]
    heads = [t for l in lines for t in l.split() if t.startswith("head=")]
    verd = [i for i, l in enumerate(lines) if l.startswith("VERDICT")]
    return (len(at) == 1 and heads == ["head=" + head] and "head=" + head in lines[at[0]].split()
            and len(verd) == 1 and verd[0] > at[0] and lines[verd[0]] == "VERDICT: PASS")
apw = d.get("review_verdict") == "pass-with-approved-warnings" and sys.argv[4] != "" and xpass(sys.argv[4], sys.argv[2])
# Approved gate-pushed final-head path: the exact final head has an independent netcup PASS.
# This alone bypasses the old receipt head and post-review AST-only checks; other paths stay unchanged.
gatepushed_xpass = (d.get("gate_last_pushed_sha") == sys.argv[2] and d.get("pr_head_sha") == sys.argv[2]
                   and d.get("final_head_matches_push") is True
                   and (d.get("review_verdict") == "pass" or apw)
                   and xpass(sys.argv[5], sys.argv[2]))
if gatepushed_xpass: print("ok"); sys.exit()
if d.get("head_sha") != sys.argv[2]: print("receipt head %s is not this head" % str(d.get("head_sha"))[:8]); sys.exit()
if d.get("review_verdict") != "pass" and not apw: print("receipt review_verdict is %r, not pass%s" % (d.get("review_verdict"), " (pass-with-approved-warnings needs the netcup exact-head PASS record; rule on)" if d.get("review_verdict") == "pass-with-approved-warnings" else "")); sys.exit()
# chief 2826 ruling (FM 3327, 2026-10-12): a no-push head counts as matching ONLY when reviewed_head == pr_head == head AND the receipt
# shows the push step completed with nothing to push (push_step_status "completed" + push_nothing_to_push true); a bare null
# gate_last_pushed_sha is not proof. Kill switch: data/nopush-rule.off. Backup: netcup-land.sh.bak-20261012-nopush
nopush = (sys.argv[3] == "on" and d.get("final_head_matches_push") is False and d.get("gate_last_pushed_sha") is None
          and d.get("reviewed_head_sha") == sys.argv[2] and d.get("pr_head_sha") == sys.argv[2]
          and d.get("push_step_status") == "completed" and d.get("push_nothing_to_push") is True)
if d.get("final_head_matches_push") is not True and not nopush: print("receipt final_head_matches_push is %r, not true (no-push rule needs push_step_status completed + push_nothing_to_push true)" % d.get("final_head_matches_push")); sys.exit()
# chief 221016 (2): a gate-authored post-review commit (the gate itself pushed this head after reviewing an earlier one) is
# handed to postrev_ok; anything else with a reviewed head other than this head is refused.
rv = d.get("reviewed_head_sha")
if rv is not None and rv != sys.argv[2]:
    if d.get("gate_last_pushed_sha") == sys.argv[2] and d.get("pr_head_sha") == sys.argv[2] and isinstance(rv, str) and len(rv) == 40:
        print("postreview " + rv); sys.exit()
    print("receipt reviewed head %s is not this head and the gate did not push this head" % str(rv)[:8]); sys.exit()
print("ok")' "$pr" "$head" "$([ -e "$H/data/nopush-rule.off" ] && echo off || echo on)" "$([ -e "$H/data/apw-rule.off" ] || echo "$H/data/xreview/$pr.md")" "$H/data/xreview/$pr.md" < "$rf" 2>/dev/null)
  rm -f "$rf"
  if [ "${BG_WHY%% *}" = postreview ]; then
    if pro=$(postrev_ok "${BG_WHY#postreview }" "$head"); then BG_WHY=ok
    else BG_WHY="post-review commit refused: $pro"; return 1; fi; fi
  [ "$BG_WHY" = ok ]
}
printf '%s' "$PRS" | python3 -c '
import json, sys, time, datetime, re
out = []
for p in json.load(sys.stdin):
    b = p["headRefName"]
    prefix = bool(b.startswith("fm/dos-bosgame-") or b.startswith("fm/dos-repoint-split-bosgame-") or re.match(r"fm/dos-planning[^/]*-bosgame-", b))  # chief 2630
    # Branch text never establishes repository ownership: every non-prefix branch requires
    # the repo/PR/current-head receipt and exact-head cross-family proof below.
    if p["mergeable"] == "UNKNOWN" and not p["isDraft"]:   # chief 2515: UNKNOWN = poke once (gh computes mergeability on view) and retry next cycle
        import subprocess; subprocess.run(["gh", "pr", "view", str(p["number"]), "--repo", "Authentis/decision-os", "--json", "mergeable"], capture_output=True)
        print("bosgame-autoland: PR %s mergeable UNKNOWN, poked; retry next cycle" % p["number"], file=sys.stderr); continue
    if p["isDraft"] or p["mergeable"] != "MERGEABLE" or "no-mistakes-pr-appendix" not in (p.get("body") or ""): continue
    t = datetime.datetime.strptime(p["updatedAt"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc).timestamp()
    if time.time() - t < 600: continue
    out.append((p["number"], b, prefix))
# chief 2646: planning PRs land first (they are supply); supply < 10 is the usual state, so they always go first. Backup .bak-20261009-2646
for n, b, _ in sorted(out, key=lambda x: (not x[1].startswith("fm/dos-planning"), not x[2])):
    print(n, b)
' | { exec 3<&0 </dev/null   # chief 14:34: the loop reads the PR list on fd 3; body commands (netcup-land, xreview, gh) get /dev/null so they cannot eat the list
# before eligibility filtering, so a draft or freshly pushed PR still gets its old-head review cancelled
if [ "$DRY" = 0 ]; then for _q in "$H"/state/.floor-q-*; do [ -e "$_q" ] && floor_sweep "${_q##*.floor-q-}"; done; fi
while read -r pr branch <&3; do
  bos_prefix=0
  [[ $branch =~ ^fm/dos-bosgame-|^fm/dos-repoint-split-bosgame-|^fm/dos-planning[^/]*-bosgame- ]] && bos_prefix=1
  if [ "$bos_prefix" = 1 ]; then
    slug=${branch#fm/dos-bosgame-}; slug=${slug#fm/dos-repoint-split-bosgame-}
    case $branch in fm/dos-planning*-bosgame-*) slug=${branch#fm/dos-}; slug=${slug%%-bosgame-*};; esac  # chief 2630: id dos-bosgame-planningNNN-land-1001
    slug=$(printf '%s' "$slug" | sed -E 's/-[0-9]{4}(-r[0-9]+)?$//')
    [ "$branch" = "fm/dos-repoint-split-bosgame-1001" ] && slug=repoint-split
    id="dos-bosgame-$slug-land-1001"
  else
    # any-branch widening: a non-prefix branch lands through autoland only with a repo-bound bosgame receipt for the
    # exact head (same predicates as netcup-land.sh) plus an exact-head cross-family PASS. Anything else is skipped here,
    # so a receipt-less branch can never fall through to the netcup path inside netcup-land.sh. The task id carries no
    # branch text (never slash-containing, never a guessed dos-bosgame- id that could hit the legacy interim); the record
    # stays grounded in the forge URL, the current branch, the current full head and the receipt source via the .meta below.
    # A hold is checked before any receipt or review work, same predicate as the loop's hold check below.
    if [ -e "$H/data/land-hold-$pr" ] && [ ! -e "$H/data/autoland-holdcheck.off" ]; then echo "bosgame-autoland: PR $pr on land hold (data/land-hold-$pr); not landing"; continue; fi
    head=$(gh pr view "$pr" --repo Authentis/decision-os --json headRefOid -q .headRefOid)
    if ! bg_receipt_ok "$pr" "$head"; then echo "bosgame-autoland: PR $pr ($branch) not landed: $BG_WHY"; continue; fi
    xf="$H/data/xreview/$pr.md"
    { grep -q "head=$head" "$xf" 2>/dev/null && grep -q '^VERDICT:' "$xf"; } || { [ "$DRY" = 1 ] || bash "$H/data/bin/xreview.sh" "$pr" >/dev/null 2>&1; }
    if ! grep -q "head=$head" "$xf" 2>/dev/null || ! grep -q '^VERDICT: PASS' "$xf" || ! floor_ok "$pr" "$head"; then echo "bosgame-autoland: PR $pr ($branch) not landed: no cross-family PASS for head ${head:0:8} (see $xf)"; continue; fi
    echo "bosgame-autoland: PR $pr ($branch) receipt-validated ($BG_WHY) with exact-head cross-family PASS"
    id="bg-receipt-pr$pr-land-1001"
  fi
  # chief 15:42 (PR 2898 landed against a HOLD): a chief HOLD is data/land-hold-<pr>; while that file exists (any head) autoland never
  # lands the PR. Lifting a hold = renaming the file (as before). Kill switch: data/autoland-holdcheck.off.
  if [ -e "$H/data/land-hold-$pr" ] && [ ! -e "$H/data/autoland-holdcheck.off" ]; then echo "bosgame-autoland: PR $pr on land hold (data/land-hold-$pr); not landing"; continue; fi
  echo "bosgame-autoland: PR $pr ($branch) eligible"
  [ "$DRY" = 1 ] && continue
  head=$(gh pr view "$pr" --repo Authentis/decision-os --json headRefOid -q .headRefOid)
  # chief 2809 (pilot Q2 stage 0): while data/bosgame-lead-pilot.on exists, bosgame's receipt (gpt-6.1-sol, exact head, pass) replaces the
  # netcup review gate; any mismatch rolls the pilot back (the marker is renamed) and this PR takes the old double review below.
  pilot=$(bash "$H/data/bin/bosgame-lead-pilot.sh" "$pr" "$head" 2>&1); prc=$?; [ "$prc" = 2 ] || echo "bosgame-autoland: PR $pr $pilot"
  if [ "$prc" = 0 ]; then : > "$H/state/.pilot-pass-$pr-$head"; XG=0; else XG=$XGATE; fi
  if [ "$XG" = 1 ]; then
    xf="$H/data/xreview/$pr.md"
    { grep -q "head=$head" "$xf" 2>/dev/null && grep -q '^VERDICT:' "$xf"; } || bash "$H/data/bin/xreview.sh" "$pr" >/dev/null 2>&1
    # chief 1788: bosgame lanes cannot read netcup's data/xreview, so a FAIL for this head is posted once as a PR comment (the lane reads the PR)
    if grep -q "head=$head" "$xf" 2>/dev/null && grep -q '^VERDICT: FAIL' "$xf" && [ ! -e "$H/state/.xreview-commented-$pr-${head:0:8}" ]; then
      { echo "Cross-family review FAILED for head ${head:0:8}. Fix these and push; the review re-runs on the new head."; echo; grep -E '^(VERDICT|FINDING)' "$xf"; } > "$H/state/.xreview-comment-$pr.txt"
      gh pr comment "$pr" --repo Authentis/decision-os --body-file "$H/state/.xreview-comment-$pr.txt" >/dev/null 2>&1 && : > "$H/state/.xreview-commented-$pr-${head:0:8}"
    fi
    # chief 2620: an idle bosgame lane never reads its PR, so the comment alone does not reopen it. Send each FAIL verdict once per head to
    # bosgame-sm (its SM reopens the lane), stamped state/.xreview-sent-<pr>-<head8>; an error reply leaves no stamp so the next pass retries.
    if grep -q "head=$head" "$xf" 2>/dev/null && grep -q '^VERDICT: FAIL' "$xf" && [ ! -e "$H/state/.xreview-sent-$pr-${head:0:8}" ] && [ "$DRY" = 0 ]; then
      sout=$( { echo "[netcup SM] SO-19 cross-family review FAIL on your PR https://github.com/Authentis/decision-os/pull/$pr (head ${head:0:8}). Reopen its lane this cycle: fix every finding below on the same branch, push with no force, run the gate on the new head, approve ci at once. Netcup re-reviews the new head automatically. Verdict file, verbatim:"; echo; cat "$xf"; } | bash /home/holu/fm-secondmate-upstream-20260907/data/bin/bosgame-sm-send.sh 2>&1 | head -3)
      case $sout in *[Ee]rror*|*denied*|*refused*|*"must start"*) echo "bosgame-autoland: PR $pr FAIL send to bosgame NOT delivered: $(echo "$sout" | head -1)";;
        *) : > "$H/state/.xreview-sent-$pr-${head:0:8}"; echo "bosgame-autoland: PR $pr FAIL for ${head:0:8} sent to bosgame (chief 2620)";; esac
    fi
    # chief 1810/1806 (SO-19 repeat-stop): a recorded waiver file data/xreview-waiver-<pr> naming this head's first 8 chars lets a FAIL land (findings go to a follow-up leaf)
    if grep -q "head=$head" "$xf" 2>/dev/null && grep -q '^VERDICT: FAIL' "$xf" && grep -q "${head:0:8}" "$H/data/xreview-waiver-$pr" 2>/dev/null; then echo "bosgame-autoland: PR $pr review FAIL waived for head ${head:0:8} (see data/xreview-waiver-$pr)"; else
    if ! grep -q "head=$head" "$xf" 2>/dev/null || ! grep -q '^VERDICT: PASS' "$xf" || ! floor_ok "$pr" "$head"; then echo "bosgame-autoland: PR $pr not landed: no cross-family PASS for head $head (see $xf)"; continue; fi; fi
    echo "bosgame-autoland: PR $pr cross-family PASS for head $head (reviewer in $xf)"
  fi
  if [ "$bos_prefix" = 1 ]; then
    printf '%s\n' "endpoint_task_id=$id" "project=/home/holu/decision-os" "kind=ship" "mode=no-mistakes" "yolo=off" "branch=$branch" "origin_host=bosgame" "worktree=/tmp/claude-1000/pr-check-core" "pr=https://github.com/Authentis/decision-os/pull/$pr" "pr_head=$head" > "$H/state/$id.meta"
  else
    printf '%s\n' "endpoint_task_id=$id" "project=/home/holu/decision-os" "kind=ship" "mode=no-mistakes" "yolo=off" "branch=$branch" "origin_host=bosgame" "record_only=yes" "gate_receipt_source=bosgame:data/gate-receipts/$pr.json" "pr=https://github.com/Authentis/decision-os/pull/$pr" "pr_head=$head" > "$H/state/$id.meta"
  fi
  # main 2276 (PR 1883 auto-landed 36 commits behind main with no merge test): land through netcup-land.sh, which re-checks the gate and
  # cross-family verdict for this head, runs the merge-result tests and invariants on main+head, and only then calls fm-pr-merge.sh.
  bash "$H/data/bin/netcup-land.sh" "$id" "https://github.com/Authentis/decision-os/pull/$pr" 2>&1 | grep -v '^WARNING' | tail -3 | cut -c1-220 | sed 's/^/bosgame-autoland: /'
  # chief 1709: once the forge confirms the merge, tell bosgame so it tears the task down (its pool leaks otherwise)
  if [ "$(gh pr view "$pr" --repo Authentis/decision-os --json state -q .state 2>/dev/null)" = MERGED ]; then
    [ -e "$H/state/.pilot-pass-$pr-$head" ] && printf '%s pr=%s head=%s landed latency_s=%s\n' "$(date +%s)" "$pr" "$head" "$(( $(date +%s) - $(gh pr view "$pr" --repo Authentis/decision-os --json createdAt -q .createdAt | xargs -I{} date -d {} +%s) ))" >> "$H/data/bosgame-lead-pilot.log"
    bash "$H/data/bin/bosgame-landed-notify.sh" "$pr" "$branch" >/dev/null 2>&1 && echo "bosgame-autoland: told bosgame PR $pr landed (task ${branch#fm/})" || echo "bosgame-autoland: could not notify bosgame for PR $pr"
  fi
done; }
exit 0
