#!/usr/bin/env bash
set -eu
H=${FM_HOME:-/home/holu/fm-secondmate-upstream-20260907}
export FM_HOME=$H
ROUTER_BIN=${ROUTER_BIN:-$H/data/bin}; export ROUTER_BIN
FLEET_YAML=${FLEET_YAML:-$H/config/fleet.yaml}; export FLEET_YAML
[ -e "$H/data/router-off" ] && { echo "router-off"; exit 0; }
. "$ROUTER_BIN/router-launch.sh"
id=${CLOSURE_TASK_ID:-dos-tracker-closures2-1002}
lst=$(awk '{printf "%s(#%s) ", $1, $2}' "$H/state/closure-sweep.list")
"$H/bin/fm-tasks-axi.sh" add "$id" "Close landed decision-os leaves, batch 2 (tracker-only)" >/dev/null 2>&1 || true
"$ROUTER_BIN/fm-brief-local.sh" "$id" decision-os --mode no-mistakes >/dev/null
python3 - "$H/data/$id/brief.md" "$lst" <<'PY'
import sys
p, lst = sys.argv[1:]
t = open(p).read()
intent = ("Open tracker leaves whose own lane branch already merged to main are still open and block other rows (chief 1668). Close each one the merged PR actually delivered, in the tracker, as one tracker-only PR.\n")
spec = ("- Tracker-only, one tracker commit, in your isolated worktree off origin/main (never the primary clone /home/holu/decision-os). TRACKER ISOLATION: before ANY br command export BEADS_DIR=$PWD/.beads, delete a stale .beads/redirect, confirm br info shows the database inside YOUR worktree; never run br against /home/holu/decision-os/.beads. Do not commit anything else.\n"
        "- Update a branch with git merge origin/main; never rebase; never force-push (SO-3: history rewrites are the captain's).\n"
        "- Candidates (leaf suffix after dos-product-v1-88cgo. -> merged PR in Authentis/decision-os; found by branch name, so verify): " + lst + "\n"
        "- For each: confirm the PR is merged to main, that its branch/title/body names THIS leaf as its own work, and that its diff covers the leaf's FILES and acceptance. Close it with a receipt (PR number + merge commit). If a PR was only a partial or earlier attempt, or was superseded, leave the leaf open and list it with the reason. Then close any parent epic whose children are now all closed, same receipt rule.\n"
        "- CLOSE RULES (chief 2512, SO-18 tree review sec. 4): exactly two mechanical kinds. (1) a leaf whose PR merged: re-check it against origin/main .beads/issues.jsonl and gh pr view; reason text exactly 'landed in #<n>'. (2) a parent with every child closed and none deferred or tombstoned: read the parent's own acceptance text and run br epic close-eligible --dry-run first (never without --dry-run), then close each eligible parent one by one with br close <id> (chief 2528). Also sweep the open parents whose children are all closed, within the same 30-close cap. NEVER touch rows labelled needs-captain, T1 rows (data/bin/t1-priority.txt), or rows updated in the last 24 h. At most 30 closes in this PR; list the rest as deferred to the next run. List every id that fails re-verification as skipped_by_sm with its reason. Put a close log (id, old status, evidence, command, result) in the PR body.\n"
        "- No other tracker edits, no code. Report counts closed, the open leftovers with reasons, and the closed ids.\n")
assert "{TASK}" in t and "{FIRSTMATE_SPEC}" in t
open(p, "w").write(t.replace("{TASK}", intent, 1).replace("{FIRSTMATE_SPEC}", spec, 1))
PY
live=${ROUTER_LIVE:-0}
if [ "$live" = 1 ]; then
  rows=$(python3 - "${ROUTER_PROJECT_DIR:-/home/holu/decision-os}/.beads/issues.jsonl" "$H/state/closure-sweep.list" 2>/dev/null <<'PY' || true
import json, sys
tracker, candidates = sys.argv[1:]
wanted = [line.split()[0] for line in open(candidates) if line.strip()]
found = {}
for line in open(tracker, encoding='utf-8'):
    row = json.loads(line)
    rid = str(row.get('id') or '')
    for token in wanted:
        if rid == token or rid.endswith('.' + token): found[token] = row
if len(found) != len(set(wanted)): raise SystemExit(2)
print('\n'.join(json.dumps(found[x], sort_keys=True) for x in wanted))
PY
)
  [ -n "$rows" ] || { echo "closure: WAIT: current task text/labels unavailable" >&2; exit 4; }
  labels=$(router_labels_from_rows "$rows") || { echo "closure: WAIT: current tracker labels unavailable or malformed" >&2; exit 4; }
  REAL=$(router_classify_task "$rows" "$labels") || { echo "closure: WAIT: classification failed" >&2; exit 4; }
  router_admit "$id" closure closure netcup "$REAL" || exit 4
  launch_args=("${RA_ARGV[@]}")
else
  # Compatibility mode keeps the pre-v3 deferred tuple.  It deliberately
  # cannot publish a v3 receipt, closure stamp, or start count.
  launch_args=(--harness pi --model qwen-token-plan-individual/deepseek-v4-flash-0731)
fi
if [ "$live" = 1 ]; then
  if [ -e "$H/data/closure-sweep.hold" ]; then
    echo "closure: WAIT: closure-sweep hold activated before launch" >&2
    router_cancel "$id" || true; exit 4
  fi
  cs_n=0; cs_why="can-start did not run"
  IFS=$'\t' read -r cs_n cs_why < <(python3 "$ROUTER_BIN/refill_lib_v2.py" can-start "$H/data/refill-starts.log" 2>/dev/null) || true
  case ${cs_n:-} in ''|*[!0-9]*) cs_n=0;; esac
  if [ "$cs_n" -le 0 ]; then
    echo "closure: WAIT: can-start allows no start (${cs_why:-no reason})" >&2
    router_cancel "$id" || true; exit 4
  fi
fi
router_prelaunch || { [ "$live" != 1 ] || router_cancel "$id"; exit 4; }
set +e
out=$("$H/bin/fm-spawn.sh" "$id" "${ROUTER_PROJECT_DIR:-/home/holu/decision-os}" --mode no-mistakes --yolo off "${launch_args[@]}" 2>&1)
rc=$?
set -e
printf '%s\n' "$out" | tail -2 | cut -c1-300
if [ "$live" != 1 ]; then
  [ "$rc" = 0 ] || exit "$rc"
  echo "closure: legacy deferred launch has no v3 receipt; stamp/count unchanged" >&2
  exit 4
fi
if [ "$rc" != 0 ]; then
  if [ "$rc" = 124 ] || printf ' %s ' "$out" | grep -qE ' (window|endpoint|session)=[^[:space:]]+'; then
    router_ambiguous "$id" "unverified-$RA_INCARNATION" || true
    exit 74
  else
    # State classifies 402/balance, 429, and quota evidence, then persists only
    # its sanitized reason; the raw provider text never enters the sidecar.
    router_failure "$id" "closure-sync-$RA_INCARNATION" "$rc" "$out" || true
  fi
  exit "$rc"
fi
router_confirm_verified "$id" "$out" || { router_ambiguous "$id" "unverified-$RA_INCARNATION" || true; exit 74; }
# The helper owns this confirmed start.  Its lane caller sets the flag and does
# not apply a second receipt delta; exporting it also documents the contract to
# nested helper code.
ROUTER_HELPER_ACCOUNTS=1; export ROUTER_HELPER_ACCOUNTS
python3 "$ROUTER_BIN/refill_lib_v2.py" note-start "$H/data/refill-starts.log" >/dev/null 2>&1 || {
  echo "closure: verified launch accounting failed; stopping helper" >&2
  exit 70
}
ROUTER_CONFIRMED=1; export ROUTER_CONFIRMED
if [ -n "${CLOSURE_RESULT_FILE:-}" ]; then
  case "$CLOSURE_RESULT_FILE" in
    "$H"/state/.closure-helper-verified-*)
      [ -n "${CLOSURE_RESULT_NONCE:-}" ] || exit 4
      printf '%s\t%s\tverified-accounted\n' "$id" "$CLOSURE_RESULT_NONCE" > "$CLOSURE_RESULT_FILE" || exit 4
      ;;
    *) echo "closure: refused invalid verified-result path" >&2; exit 4;;
  esac
fi
