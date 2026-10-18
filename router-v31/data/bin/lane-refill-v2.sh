#!/usr/bin/env bash
# v2 (chief 4627): one can_start check, explicit live-data label, cached main snapshot. Old script kept beside it: lane-refill.sh.
# Lane refill, one flow (chief 1672). Run by the 10-minute timer and once per wake turn:  lane-refill.sh [--dry-run] [--cap N] [--no-plan]
#   1. SUPPLY   count live lanes and load, read origin/main's tracker, list dispatchable leaves (T1 closure first, then priority)   -> refill_lib_v2.py supply
#   2. GO       send the held GO to committed lanes while the gate (cap 6) has room
#   3. START    priority lanes, then planning (continuous while supply < 70), then leaves picked by FILES overlap (max 2 on the
#               SO-13 shared files) onto the host with room: netcup first, bosgame when netcup is full (bosgame never gets a netcup-only leaf)   -> refill_lib_v2.py pick
#   4. LAND     auto-land bosgame PRs, close landed leaves, keep 3 cloud workers, report parked gates and finished PR runs
# Limits: netcup lane cap 8, no new netcup start at load5 >= 8 or MemAvailable < 3 GB, at most 2 leaf starts a run, bosgame up to 12 working lanes.
# Leaves run on Sol high, planning on Sol xhigh (captain 10-02, Codex window until the 10-03 17:00Z reset). Pure steps and their tests: refill_lib_v2.py, test_refill.py.
set -u
H=${FM_HOME:-/home/holu/fm-secondmate-upstream-20260907}
export FM_HOME=$H
B=${ROUTER_BIN:-$H/data/bin}
export ROUTER_BIN=$B
PROJECT=${ROUTER_PROJECT_DIR:-/home/holu/decision-os}
export ROUTER_PROJECT_DIR=$PROJECT
# Pin the shared admission/receipt seam once for this invocation.  Every child
# inherits ROUTER_BIN/FLEET_YAML from the same bundle.
# shellcheck source=/dev/null
source "$B/router-launch.sh"
router_global_off && exit 0
# Preserve valid legacy IDs; bind overlong IDs to the full leaf, route and date.
leaf_task_id() {
  local candidate="dos-leaf-$(printf '%s' "$1" | tr . -)-$2-$3" digest
  if [ "${#candidate}" -le 64 ]; then printf '%s\n' "$candidate"; return; fi
  digest=$(printf '%s' "$candidate" | sha256sum) || return
  printf '%s-%s\n' "${candidate:0:47}" "${digest:0:16}"
}
W=${ROUTER_WORKDIR:-/tmp/claude-1000/lane-refill}; mkdir -p "$W"
CLONE=$W/clone; GATE_DB=/home/holu/.no-mistakes/state.sqlite
CAP=${NETCUP_CAP:-5}; DRY=0; PLAN=1; BOS_CAP=${BOS_CAP:-10}   # chief 2806 (SO-12): netcup live pool at most 2 (non-live leaves go to bosgame); was chief 2606 netcup 5, bosgame 10 working lanes (was 3/6 under chief 2571); backup lane-refill.sh.bak-20261009-2606   # chief 3904 live limit netcup cap 5 (was 2 per 2806); NETCUP_CAP=2 restores
# SO-16 route order (captain 14:1x, chief 2111): tier 1 interchangeable OpenCode Go and Command Code (alternated per lane via
# data/ds-route-next; droid DeepSeek is tier 1 too but runs by hand), tier 2 Qwen token plan (stop at 90% monthly), tier 3 OpenScale
# last. A route at its limit is marked data/ds-route-down-<go|cc|qwen|openscale>. ds_route sets nxt/tag/RX; returns 1 when all are down.
# chief 2244: Go slots counted and taken by data/bin/go-slot.sh (working lanes + reservations). chief 2230 (captain 10-07 10:2x, SO-16; reverses 2220): builders on DeepSeek 4.1 Flash - Go at most 2 live lanes, the rest straight to
# OpenScale ($10/day cap via openscale-spend.py); Codex Sol only for third same-theme FAILs, re-specs and planning.
ds_route(){ local n r; nxt=""; python3 "$B/openscale-spend.py" --enforce >/dev/null 2>&1; [ "${RAMHOLD:-0}" = 1 ] && return 1; EFF=high
  # chief 2244: the Go slot is taken through data/bin/go-slot.sh for the lane id in $1 (working Go lanes + reservations, counted under its own
  # short lock; dry runs only ask). Go while a slot is free, else OpenScale; Command Code only when both are marked down (chief 2246: no qwen).
  for n in go openscale cc; do [ -e "$H/data/ds-route-down-$n" ] && continue
    if [ "$n" = go ]; then if [ "$DRY" = 0 ]; then r=$(bash "$B/go-slot.sh" take "${1:?ds_route needs the lane id}" new); else r=$(bash "$B/go-slot.sh" route); fi; [ "$r" = go ] || continue; fi
    nxt=$n; break; done
  case $nxt in
    go) tag=dsgo; RX=(--harness opencode --model opencode-go/deepseek-v4.1-flash);;
    cc) tag=dscc; RX=(--harness commandcode --model deepseek/deepseek-v4.1-flash);;
    openscale) tag=dsos; RX=(--harness pi --model openscale/deepseek/deepseek-v4.1-flash);;
    *) return 1;;
  esac
  case $nxt in go|cc) [ "$DRY" = 0 ] && { [ "$nxt" = go ] && echo cc || echo go; } > "$H/data/ds-route-next";; esac
  return 0; }
while [ $# -gt 0 ]; do case $1 in --dry-run) DRY=1;; --no-plan) PLAN=0;; --cap) shift; CAP=$1;; esac; shift; done
exec 9>"$W/lock"; flock -n 9 || { echo "lane-refill: another run in progress"; exit 0; }
say() { echo "lane-refill: $*"; }
# chief 2640 + 2648 #4: read bosgame's own data/bosgame-snapshot.json over the read-only key at the TOP of the pass, so supply, ownership and
# reclaim all use this pass's copy. stdout and stderr go to separate files and the exit status is checked; a valid JSON (ts + lanes list)
# replaces the local copy, otherwise the old copy stays and refill_lib's 20-min age check decides. Backups lane-refill.sh.bak-20261009-2640/-2648-4
# pass-2 fix 1: the fetch and publish now run AFTER the run lock, into a per-run temp file, and publish via a temp file + atomic rename in the
# data directory. The old code fetched into one shared file name and cp'ed it over the shared snapshot BEFORE the lock: two concurrent runs
# published each other's partial JSON.
snapnew="$W/bosgame-snapshot.fetch.$$"; snaperr="$W/bosgame-snapshot.fetch.err.$$"; snapwhy=
if timeout 30 ssh -T -o ConnectTimeout=10 -o BatchMode=yes -o IdentitiesOnly=yes -i "$HOME/.ssh/bosgame_readonly_ed25519" lundi@100.126.95.9 'cat /home/lundi/fm-secondmate-dos/data/bosgame-snapshot.json' > "$snapnew" 2> "$snaperr"; then
  if python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); float(d["ts"]); assert isinstance(d["lanes"], list)' "$snapnew" 2>/dev/null; then
    snapdest="$H/data/bosgame-snapshot.json"; snaptmp=$(mktemp "$H/data/.bosgame-snapshot.json.XXXXXX") && cat "$snapnew" > "$snaptmp" && command mv -fT -- "$snaptmp" "$snapdest" \
      || { rm -f "$snaptmp"; snapwhy="publish to $snapdest failed"; say "WARNING bosgame snapshot publish failed"; }
  else snapwhy="fetch returned invalid JSON"; fi
else snapwhy="fetch failed rc=$?: $(head -c 120 "$snaperr" 2>/dev/null | tr '\n' ' ')"; fi
rm -f "$snapnew" "$snaperr"
# chief 2692/2700: letters held by any unfinished planning pass (refill_lib busy-partitions). Never silent: when the gh open-PR lookup
# or busy-partitions fails, every range counts busy and one line says planning is paused for this pass (to stderr, so it is logged, not captured).
busy_used() { local o
  if ! gh pr list --repo Authentis/decision-os --state open --limit 200 --json headRefName -q '.[].headRefName' > "$W/open-branches-2692.txt" 2>/dev/null; then
    rm -f "$W/open-branches-2692.txt"; say "PLANNING paused this pass: gh open-PR lookup failed, every range counts busy (chief 2700)" >&2; echo A B C1 C2 D; return; fi
  if o=$(python3 "$B/refill_lib_v2.py" busy-partitions "$H" "$H/data/bosgame-snapshot.json" "$W/open-branches-2692.txt" 2>&1); then echo "$o"
  else say "PLANNING paused this pass: busy-partitions failed ($(printf '%s' "$o" | tail -1 | cut -c1-120)), every range counts busy (chief 2700)" >&2; echo A B C1 C2 D; fi; }
# cc-realdata-1050 (corr 70a3c13631430787): one append-only line per leaf routing decision: time, lane, leaf, tier, reason, skipped-because
DLOG=$H/data/lane-refill.log
dlog() { [ "$DRY" = 0 ] || return 0; printf '%s\tlane=%s\tleaf=%s\ttier=%s\treason=%s\tskipped=%s\n' "$(date -u +%FT%TZ)" "$1" "$2" "$3" "$4" "${5:--}" >> "$DLOG"; }

# Router v3 is the final fail-closed model admission immediately before a leaf
# start. The can_start recheck in the caller stays first.
# pass-3 (S2): the picked binding is APPLIED, not only logged.
# pass-6 (review, chief ruling): the spawn route is resolved ONLY through the
# binding-lane CLI (the fleet.yaml bindings table). The binding-id TEXT is never parsed:
# the schema does not require an id's '@' suffix to equal its harness or provider, so
# '--harness <suffix> --model <suffix>/<prefix>' can name a route the bans and quota never
# checked. pass-7 (review): a pick that resolves to NO binding args (a bare model id, or a
# binding id that does not resolve through the table) is REFUSED - the caller skips the
# leaf/send and never falls through to the legacy route ladder unchecked.
# pass-8b (review): a LIVE-DATA leaf whose route_pick WAITS (no live-capable build row in the
# fleet table) is an explicit, loud skip - one line names the fix; the legacy Sonnet/Terra
# live ladder below is NEVER entered for it.
# role: build for leaves/start-first/resume/priority, plan for planning.
export ROUTER_LIVE=${ROUTER_LIVE:-1}

# Real credential classification is derived from the task material at every path.
# The optional second argument is the candidate row text when no brief exists yet.
task_live_data() {
  local task_="$1" text_="${2:-}" labels_="${3:-[]}" shown_="" real_=""
  [ -r "$H/data/$task_/brief.md" ] && real_="$real_ $(cat "$H/data/$task_/brief.md")"
  [ -x "$H/bin/fm-tasks-axi.sh" ] && shown_=$("$H/bin/fm-tasks-axi.sh" show "$task_" 2>/dev/null || true)
  real_="$text_ $real_ $shown_"
  [ -n "${real_//[[:space:]]/}" ] || { printf '%s\n' WAIT; return 75; }
  if [ "$labels_" = "[]" ] && printf '%s' "$shown_" | grep -qiE 'credentials[[:space:]]*:[[:space:]]*yes'; then labels_='["credentials:yes"]'; fi
  text_=$real_; [ -r "$H/state/$task_.meta" ] && text_="$text_ $(cat "$H/state/$task_.meta")"
  router_classify_task "$text_" "$labels_" || { printf '%s\n' WAIT; return 75; }
}

# Compatibility wrapper used by every local launch and remote sender.  Catalog,
# family and flag checks happen inside the locked Python admission, so the exact
# admitted tuple is copied once into an argv array and is never re-resolved here.
route_leaf() {
  local host_="$1" task_="$2" live_="$3" role_="${4:-build}" kind_="${5:-build}" only_="${6:-}"
  ROUTE_PICK=""; ROUTE_ARGS=""; ROUTE_ARGV=()
  ROUTE_BIND_HARNESS=""; ROUTE_BIND_MODEL=""; ROUTE_BIND_PROVIDER=""; ROUTE_BIND_EFFORT=""
  if [ "$DRY" = 1 ]; then return 0; fi
  # ROUTER_LIVE=0 remains a dispatching compatibility mode, never a kill
  # switch. Callers which were deferred before v3.1 keep their legacy tuple;
  # route_leaf is used by live v3.1 callers and always-routed ordinary builds.
  if [ -n "$only_" ]; then router_admit "$task_" "$kind_" "$role_" "$host_" "$live_" "$only_"
  else router_admit "$task_" "$kind_" "$role_" "$host_" "$live_"; fi
  if [ "$?" != 0 ]; then
    say "ROUTER WAIT $kind_/$role_ $task_ ($host_): ${RA_REASON:-admission refused}"
    dlog - "$task_" none "Router v3.1 WAIT" "${RA_REASON:-admission refused}"
    return 1
  fi
  ROUTE_PICK=$RA_BINDING; ROUTE_ARGV=("${RA_ARGV[@]}")
  ROUTE_ARGS="${ROUTE_ARGV[*]}"
  ROUTE_BIND_HARNESS=$RA_HARNESS; ROUTE_BIND_MODEL=$RA_MODEL
  ROUTE_BIND_PROVIDER=$RA_PROVIDER; ROUTE_BIND_EFFORT=$RA_EFFORT
  say "ROUTER $kind_/$role_ $task_ ($host_): $ROUTE_PICK - $RA_REASON"
}

# Read-only GO check: only_binding with advance_cursor=false in route-check.
route_existing_binding() {
  local task_="$1" role_="$2" live_="$3" binding_
  binding_=$(python3 - "$H/state/route-launches/$task_.json" "$H/state/$task_.meta" <<'PY'
import json, sys
try:
    print(json.load(open(sys.argv[1])).get("binding", ""))
except Exception:
    try:
        rows = dict(line.rstrip("\n").split("=", 1) for line in open(sys.argv[2]) if "=" in line)
        print(rows.get("binding", ""))
    except Exception:
        print("")
PY
)
  [ -n "$binding_" ] || { say "GO $task_ WAIT: existing binding is unknown"; return 1; }
  router_check "$task_" go "$role_" netcup "$live_" "$binding_" || {
    say "GO $task_ WAIT: existing binding $binding_ refused (${RA_REASON:-check failed})"; return 1; }
  ROUTE_PICK=$RA_BINDING; ROUTE_ARGV=("${RA_ARGV[@]}")
}

cancel_prior_admission() {
  local task_="$1" state_="" inc_=""
  [ "${DRY:-0}" = 0 ] || return 0
  IFS=$'\t' read -r state_ inc_ < <(
    python3 -c 'import json,sys; row=json.load(open(sys.argv[1])); print(row.get("state", ""), row.get("incarnation", ""), sep="\t")' \
      "$H/state/route-launches/$task_.json" 2>/dev/null || true
  )
  # Automated rearming is safe only after the caller has proved a confirmed
  # worker dead.  Admitted/ambiguous launches require explicit reconciliation.
  [ "$state_" = confirmed ] && [ -n "$inc_" ] || return 0
  python3 "$B/refill_lib_v2.py" route-cancel "$task_" "$inc_" >/dev/null 2>&1
}

# chief 125246: true when a --harness/--model/--provider value names Meta or Muse (case-insensitive).
eu_meta_args() {
  local a=("$@") i=0 v
  while [ $i -lt ${#a[@]} ]; do
    case "${a[$i]}" in
      --harness|--model|--provider) v=$(printf '%s' "${a[$((i+1))]:-}" | tr '[:upper:]' '[:lower:]')
        case "$v" in opencode/muse-spark-1.3-contributor-free) ;; meta|meta/*|*/meta/*|*muse*) return 0;; esac ;;   # chief 05:05 (corr=d4556de4514a4559): LIFT for opencode free Muse Spark 1.3, routine non-live leaves; the paid meta route stays refused
    esac
    i=$((i+1))
  done
  return 1
}
# fm-spawn refuses while another Treehouse allocation runs: wait 20 s and retry up to 3 times
# chief 141934: serial landed-task cleanups hold the Treehouse project lock for minutes (12:09-12:14 three returns), so the
# retry is bounded by wall clock (LANE_RACE_MAX_S, default 420 s) instead of 5 tries. Kill switch: data/lane-refill-racewait.off
# restores the old 5-try rule.
spawn_retry() {
  local out rc try=1 attempt=0 race_end=$(( $(date +%s) + ${LANE_RACE_MAX_S:-420} ))
  # chief 3872(c): a leaf with a RUNNING cloud-ledger row is never started as a fleet lane (claim-guard.sh)
  if out=$(bash "$B/claim-guard.sh" fleet-start "$1"); then :; else say "$out"; return 77; fi
  # chief 125246 (FM 3466): netcup is an EU host; a lane whose --harness, --model or --provider value is a meta/ model, a Muse model,
  # harness muse or provider meta is refused before fm-spawn (only those values are matched, not task ids or paths).
  if [ -e "${LANE_EU_HOST_FILE:-$HOME/.no-mistakes/eu-host}" ] && eu_meta_args "$@"; then
    say "REFUSED spawning $1: meta/Muse route on EU host netcup (chief 125246)"; return 78
  fi
  while :; do
    if [ "$DRY" = 0 ]; then   # pass-7: re-check can_start before EVERY actual spawn attempt; the caller's loop-level check precedes route probing, task setup and a possible 25 s reclaim SSH, so the first attempt must re-read the gate too
      fresh_gate
      if [ "$sn" -le 0 ]; then
        say "spawn held: can_start allows no start now ($swhy); giving up on $1 this pass"
        [ "$attempt" -gt 0 ] && { printf '%s\n' "$out" | tail -2 | cut -c1-300; return "$rc"; }
        return 77
      fi
      # pass-8 (review): the netcup-only hold is rechecked immediately before EVERY spawn attempt:
      # it stops netcup starts only (bosgame sends continue), so it lives here rather than in
      # fresh_gate. A hold activated during setup or a race-wait sleep stops this launch.
      if [ -e "$H/data/netcup-leaves.hold" ]; then
        say "spawn held: data/netcup-leaves.hold appeared before the launch of $1; no spawn"
        return 77
      fi
    fi
    attempt=$((attempt+1))
    # chief 4740: every router-launched opencode worker gets the gbrain-MCP-off shim first on PATH (beam-free rejects >128 tools); another prefix wins
    spp="$SPAWN_PATH_PREFIX"; case " $* " in *" --harness opencode "*) [ -z "$spp" ] && spp="$B/opencode-nomcp";; esac
    if ! router_prelaunch; then return 75; fi
    out=$(PATH="${spp:+$spp:}$PATH" "$H/bin/fm-spawn.sh" "$@" 2>&1); rc=$?
    if printf '%s' "$out" | grep -q 'refusing to race it'; then
      if [ -e "$H/data/lane-refill-racewait.off" ]; then
        [ "$try" -le 5 ] && { sleep $(( 5 + RANDOM % 16 )); try=$((try+1)); continue; }   # chief 2508 #3: up to 5 retries, 5-20 s jitter
      elif [ "$(date +%s)" -lt "$race_end" ]; then
        local sl=$(( ${LANE_RACE_MIN_S:-5} + RANDOM % ${LANE_RACE_SPREAD_S:-16} )) rem=$(( race_end - $(date +%s) ))
        [ "$sl" -gt "$rem" ] && sl=$rem   # never sleep past the deadline, so no spawn starts after it
        if [ "$sl" -gt 0 ]; then sleep "$sl"; [ "$(date +%s)" -le "$race_end" ] && { try=$((try+1)); continue; }; fi   # recheck after the sleep: no spawn after the deadline
      fi
      say "spawn race: lock still held after $try attempt(s)"
    fi
    printf '%s\n' "$out" | tail -2 | cut -c1-300
    printf '%s' "$out" | grep -q 'refusing to race it' && say "GAVE UP spawning $1 (Treehouse allocation race)"
    [ "$rc" != 0 ] && printf '%s ' "$@" | grep -q 'opencode-go/' && bash "$B/go-slot.sh" release "$1"   # chief 2244 #3: failed launch frees its Go slot
    return $rc
  done
}
# chief 4369 B: the $0 model for leaf $suf from the last free-route-ping (data/free-route-models); empty = no usable $0 model.
# A recorded failure (data/cc-failed/<leaf>) or a hard flag (data/hard-leaf/<leaf>) allows Muse Spark, never on the EU host.
fm_free_model() { local eu=0 f=0 hd=0; [ -e "${LANE_EU_HOST_FILE:-$HOME/.no-mistakes/eu-host}" ] && eu=1; [ -e "$H/data/cc-failed/$suf" ] && f=1; [ -e "$H/data/hard-leaf/$suf" ] && hd=1
  python3 "$B/refill_lib_v2.py" free-model "$H/data/free-route-models" "$(( ${nwork:-0} + ${spawned:-0} ))" "$eu" "$f" "$hd" 2>/dev/null; }
SOL_HIGH="--harness codex --model gpt-6.1-sol --effort high"
SOL_XHIGH="--harness codex --model gpt-6.1-sol --effort xhigh"
# chief 164802 (2026-10-10 usage cut): while data/codex-review-only exists, Codex does exact-head reviews only;
# the Sol planning, xhigh and scout routes go to Claude Opus instead. Remove the marker to restore Sol.
SOL_SCOUT="--harness codex --model gpt-6.1-sol --effort medium"
if [ -e "$H/data/codex-review-only" ]; then
  SOL_HIGH="--harness claude --model claude-opus-5-5 --effort high"; SOL_XHIGH="--harness claude --model claude-opus-5-5 --effort xhigh"
  SOL_SCOUT="--harness claude --model claude-opus-5-5 --effort medium"
fi
# chief 083644 (night pause): while data/claude-off exists no refill step picks a Claude model: the Sol fallbacks, builder tiers and
# the Sonnet tier-3 go to Kimi K2.7 (kimi-code/kimi-k2.7-code, never K3), planning and cloud launches skip, and Claude lanes get no GO
# or relaunch. Kill switch: remove data/claude-off at the Claude reset.
CLAUDE_OFF=0; { [ -e "$H/data/claude-off" ] || [ "${FM_CLAUDE_OFF:-0}" = 1 ]; } && CLAUDE_OFF=1   # FM_CLAUDE_OFF=1: dry-run proof before the marker exists
KIMI27="--harness pi --model kimi-code/kimi-k2.7-code --effort low"
if [ "$CLAUDE_OFF" = 1 ]; then
  case $SOL_HIGH in *"harness claude"*) SOL_HIGH=$KIMI27;; esac; case $SOL_XHIGH in *"harness claude"*) SOL_XHIGH=$KIMI27;; esac
  case $SOL_SCOUT in *"harness claude"*) SOL_SCOUT=$KIMI27;; esac
fi
# Direct planning override 4049: writers only; all non-Claude route guards remain.
PLAN_ROUTE="--harness pi --model openai-codex/gpt-6.1-sol --effort high"   # chief 4385: planners run on Grok 4.7 high (kill switch data/plan-grok.off keeps Sol medium)
NM="--mode no-mistakes --yolo off"

# ---------------------------------------------------------------- 1. SUPPLY
live=(); nds=0; planning=0; planw=0; nwork=0; kimi=0; wplan=""; nfree=0; ncc=0; nson=0; ncj=0
for m in "$H"/state/dos-*.meta; do
  id=$(basename "$m" .meta)
  case $id in dos-bosgame*|dos-usage*|*.bad-leafid) continue;; esac
  grep -q '^kind=ship' "$m" || continue
  grep -qx 'worktree=/tmp/claude-1000/pr-check-core' "$m" && continue   # chief 12:1x: land-task records (pr-poll reads them) are not lanes
  st=$("$H/bin/fm-crew-state.sh" "$id" 2>/dev/null | head -1)
  case $st in *"worktree gone"*|*"backend target gone"*|*"no metadata"*) continue;; esac
  live+=("$id")
  case $id in dos-planning*-bosgame-*) ;; dos-planning*|dos-repoint-split-*) planning=$((planning+1)); wplan="$wplan $id";; esac   # chief 2508: every live planning lane counts toward PLAN_CAP (a paused planner still owns its partition)
  # the cap counts WORKING lanes only (SO-5, chief 1681): done/paused/blocked/needs-decision lanes wait without a cap slot
  last=$(grep -a '\[at=' "$H/state/$id.status" 2>/dev/null | tail -1)
  # chief 1737: live agent = a process whose cwd is inside the lane's worktree (checked once per lane, same rule for every count)
  wtp=$(sed -n 's/^worktree=//p' "$H/state/$id.meta" | head -1); alive=0
  [ -n "$wtp" ] && alive=$(python3 "$B/refill_lib_v2.py" alive "$wtp")   # chief 1739 #1: an agent process, not a leftover shell
  [ "$(python3 "$B/refill_lib_v2.py" working "$st" "$last" "$alive")" = 1 ] || continue
  case $id in dos-planning*-bosgame-*) ;; dos-planning*|dos-repoint-split-*) planw=$((planw+1));; esac   # chief 2648 #2: the planning cap counts WORKING planners only (gate-parked ones still reserve their partition)
  nwork=$((nwork+1))
  grep -q "deepseek-v4.1-flash" "$m" && nds=$((nds+1))   # chief 2344: DS_CAP counts only WORKING DeepSeek lanes (same predicate as working=)
  if grep -q -E '^harness=(pi|opencode)$' "$H/state/$id.meta"; then case $id in *-free-*) nfree=$((nfree+1));; *) kimi=$((kimi+1));; esac; fi   # chief 1797: free-route lanes counted apart from Kimi
  case $id in *-cc-*) ncc=$((ncc+1));; *-sonnet-*) nson=$((nson+1));; *-catjam-*) ncj=$((ncj+1));; esac   # chief 1802: Command Code and Sonnet leaf lanes counted per tier
done
# chief 2344 (ruling on the 10-07 blocker; SO-5 10-07): DS_CAP counts only DeepSeek lanes that pass the working= predicate above
# (counted in that loop). Lanes in the gate, paused, waiting to land, or finished with an idle agent no longer hold a slot; the RAM
# guards (5 GB MemAvailable floor, one start per pass over 6 GiB swap) still limit starts. Replaces the SO-16 / chief 2114 count.
say "DeepSeek lanes $nds/${DS_CAP:-4}"
nlive=$nwork
free=$((CAP - nlive)); [ "$free" -lt 0 ] && free=0
# gate load: runs parked in the ci merge monitor (PR open, no agent work) do not count
# main 2442: ci:awaiting_approval is the same parked state (green PR waiting to land), so it is excluded too
gate=$(sqlite3 -readonly "$GATE_DB" "select count(*) from runs r where r.status in ('running','fixing') and not exists (select 1 from step_results s where s.run_id=r.id and s.step_name='ci' and s.status in ('running','awaiting_approval'))" 2>/dev/null || echo 9)
mem=$(awk '/MemAvailable/{printf "%d", $2/1048576}' /proc/meminfo)
load5=$(awk '{print $2}' /proc/loadavg)
say "working=$nlive (of ${#live[@]} lanes held) cap=$CAP free=$free planning=$planning gate=$gate/6 mem=${mem}GB load5=$load5"
# chief 1718 (SO-6): planning lanes are tracker-only, so they keep their slots until load5 12; every other start still stops at load5 8
pfree=$free   # chief 4627: the load/memory limits are now the single can_start check below
# chief 1813 (captain SO-5, fleet reconciliation first): while data/new-leaves.hold exists no new leaf, planning, priority or pickup lane starts; running lanes and fix rounds finish
if [ -e "$H/data/new-leaves.hold" ]; then say "HOLD: data/new-leaves.hold present, no new lanes (chief 1813)"; free=0; pfree=0; PLAN=0; bsends=0; hold_all=1; fi
# v4: leaf starts of every route (opencode and Command Code included) hold at load5 >= 8 (supersedes chief load-2145's >= 10; memory floor, load1 and new-leaves.hold unchanged)
lfree=$((CAP - nlive)); [ "$lfree" -lt 0 ] && lfree=0
[ -e "$H/data/new-leaves.hold" ] && lfree=0
# chief 3852 (07:0x): while the product daily packet run holds data/local/daily_packet_run.lock (flock -n probe, shared, released at once) or
# swap-in active (chief 3855), no new lane of any route starts and no GO is admitted; running lanes finish their step. The packet run itself is never touched.
pk_busy=0; pk_lock="$PROJECT/data/local/daily_packet_run.lock"
if [ -e "$pk_lock" ] && ! flock -n -s "$pk_lock" true 2>/dev/null; then pk_busy=1; pk_why="daily packet run holds its lock"; fi
# chief 3855 release rule: resident swap alone does not hold; active swap-in does (vmstat si averaged over 3 s > 2000 KB/s)
if [ "$pk_busy" = 1 ]; then say "HOLD: $pk_why (chief 3852): no new lane starts, no GO admitted"; free=0; pfree=0; lfree=0; PLAN=0; bsends=0; hold_all=1; fi
# chief 4627 (1): ONE start check replaces the load5/load1/MemAvailable, RAM-hold and swap guards. can_start() lives in refill_lib_v2.py:
# start only when load5 < 6, MemAvailable >= 4 GB, and at most 2 starts per minute (ledger data/refill-starts.log, one epoch per start).
# Old guards: lane-refill.sh (kept beside this file). The packet-run lock, new-leaves.hold and netcup-leaves.hold below are explicit holds, not load guards.
IFS=$'\t' read -r sn swhy _ < <(python3 "$B/refill_lib_v2.py" can-start "$H/data/refill-starts.log")
sn=${sn:-0}
# pass-2 fix 5: an all-starts hold (new-leaves.hold, packet-run lock) clears the shared start budget for the WHOLE pass and is never
# re-derived: fresh_gate/one_start only lower sn, so no bosgame send or netcup start can slip past the hold after bsends is initialised below.
[ "${hold_all:-0}" = 1 ] && { sn=0; swhy="$swhy; explicit hold stops every start this pass"; }
say "can_start: $sn start(s) allowed ($swhy)"
[ "$free" -gt "$sn" ] && free=$sn; [ "$lfree" -gt "$sn" ] && lfree=$sn; [ "$pfree" -gt "$sn" ] && pfree=$sn
fresh_gate(){   # re-read can_start right now (load5, MemAvailable, starts in the last minute) and never raise the budget; clamps every free counter
  local fresh
  IFS=$'\t' read -r fresh _ < <(python3 "$B/refill_lib_v2.py" can-start "$H/data/refill-starts.log")
  [ "${fresh:-0}" -lt "$sn" ] && sn=${fresh:-0}
  # pass-8 (review): the ALL-STARTS explicit holds are rechecked here, immediately before every
  # spawn attempt (fresh_gate runs inside spawn_retry's per-attempt loop and before every launch):
  # a new-leaves hold or the packet-run lock activated during setup or the retry wait zeroes the
  # budget, so no launch and no bosgame send slips past it.
  if [ -e "$H/data/new-leaves.hold" ] || { [ -n "${pk_lock:-}" ] && [ -e "$pk_lock" ] && ! flock -n -s "$pk_lock" true 2>/dev/null; }; then
    sn=0; swhy="${swhy}; explicit hold active before launch"
  fi
  [ "$free" -gt "$sn" ] && free=$sn; [ "$lfree" -gt "$sn" ] && lfree=$sn; [ "$pfree" -gt "$sn" ] && pfree=$sn
  return 0
}
one_start(){   # every start (leaf, planning, priority, bosgame send/planning) calls this: record it and take one from the budget; the next launch re-checks via fresh_gate
  # pass-2 fix 6: note-start now writes atomically and reports failure; a start that cannot be recorded exhausts the start budget
  # (the can_start ledger is the only proof a start happened, so no further start is safe) and the failure is logged, not swallowed.
  # pass-3 (S5): returns 1 when the recording failed, so a caller that already started something
  # (a verified GO relaunch) can stop instead of marking the GO as sent.
  local ok=0
  if [ "$DRY" = 0 ]; then
    if ! python3 "$B/refill_lib_v2.py" note-start "$H/data/refill-starts.log" >/dev/null 2>&1; then
      say "start ledger write FAILED: treating the start budget as exhausted this pass (no further starts)"
      sn=0
      ok=1
    fi
  fi
  sn=$((sn-1)); [ "$sn" -lt 0 ] && sn=0
  [ "$DRY" = 0 ] && fresh_gate
  [ "$free" -gt "$sn" ] && free=$sn; [ "$lfree" -gt "$sn" ] && lfree=$sn; [ "$pfree" -gt "$sn" ] && pfree=$sn
  return $ok
}

# Launch one already-admitted tuple.  A successful process exit is insufficient:
# the fresh endpoint must be alive and route-confirm must durably append its receipt
# before any counter or queue is changed.
spawn_routed() {
  local task_="$1" rc_ out_ class_ status_; shift
  if ! router_prelaunch; then router_cancel "$task_"; return 1; fi
  if out_=$(spawn_retry "$task_" "$@"); then
    printf '%s\n' "$out_"
    if router_confirm_verified "$task_" "$out_"; then one_start || return 1; return 0; fi
    # A zero-exit launcher with no independently verified endpoint is ambiguous:
    # retain the pending reservation so another pass cannot double-launch it.
    router_ambiguous "$task_" "unverified-$RA_INCARNATION" || return 1
    say "AMBIGUOUS launch $task_: zero exit without a fresh live endpoint; admission retained"
  else
    rc_=$?; [ "$rc_" = 75 ] && { router_cancel "$task_"; return 1; }; class_=launcher_error; status_=$rc_
    if [ "$rc_" = 124 ]; then
      router_ambiguous "$task_" "unverified-$RA_INCARNATION" || return 1
      say "AMBIGUOUS launch $task_: launcher timed out; admission retained for reconciliation"
      return 1
    fi
    if printf '%s' "$out_" | grep -qE '(^|[[:space:]])(window|endpoint)=[^[:space:]]+'; then
      router_ambiguous "$task_" "unverified-$RA_INCARNATION" || return 1
      say "AMBIGUOUS launch $task_: launcher failed after reporting an endpoint"
      return 1
    fi
    if printf '%s' "$out_" | grep -qiE '(^|[[:space:]])((http([ /_-]*status)?|status|code)[ :=_-]*)?402([[:space:][:punct:]]|$)'; then class_=funds_402; status_=402
    elif printf '%s' "$out_" | grep -qiE '(^|[[:space:]])((http([ /_-]*status)?|status|code)[ :=_-]*)?429([[:space:][:punct:]]|$)'; then class_=rate_limit; status_=429; fi
    router_failure "$task_" "sync-$(date +%s)" "$status_" "$class_" "$out_"
  fi
  return 1
}

relaunch_routed() {
  local task_="$1" rc_ out_ class_ status_
  if ! router_prelaunch; then router_cancel "$task_"; return 1; fi
  if out_=$(timeout 300 "$H/bin/fm-control.sh" "$task_" relaunch "${ROUTE_ARGV[@]}" \
      --note "check your inbox for the GO before starting the gate" 2>&1); then
    printf '%s\n' "$out_" | tail -2
    if router_confirm_verified "$task_" "$out_"; then one_start || return 1; return 0; fi
    router_ambiguous "$task_" "unverified-$RA_INCARNATION" || return 1
    say "AMBIGUOUS relaunch $task_: zero exit without a fresh live endpoint; admission retained"
  else
    rc_=$?; class_=launcher_error; status_=$rc_
    if [ "$rc_" = 124 ]; then
      router_ambiguous "$task_" "unverified-$RA_INCARNATION" || return 1
      say "AMBIGUOUS relaunch $task_: launcher timed out; admission retained for reconciliation"
      return 1
    fi
    if printf '%s' "$out_" | grep -qE '(^|[[:space:]])(window|endpoint)=[^[:space:]]+'; then
      router_ambiguous "$task_" "unverified-$RA_INCARNATION" || return 1
      say "AMBIGUOUS relaunch $task_: launcher failed after reporting an endpoint"
      return 1
    fi
    if printf '%s' "$out_" | grep -qiE '(^|[[:space:]])((http([ /_-]*status)?|status|code)[ :=_-]*)?402([[:space:][:punct:]]|$)'; then class_=funds_402; status_=402
    elif printf '%s' "$out_" | grep -qiE '(^|[[:space:]])((http([ /_-]*status)?|status|code)[ :=_-]*)?429([[:space:][:punct:]]|$)'; then class_=rate_limit; status_=429; fi
    router_failure "$task_" "sync-$(date +%s)" "$status_" "$class_" "$out_"
  fi
  return 1
}

# Helpers may launch zero or several workers.  Each helper must gate, verify,
# confirm and account each individual worker before starting its next one.  The
# parent only supplies the contract flag and never guesses from aggregate exit
# status or a racy receipt-file delta.
run_routed_helper() {
  local kind_="$1" helper_="$2"
  ROUTER_PARENT_KIND="$kind_" ROUTER_HELPER_ACCOUNTS=1 bash "$helper_" || {
    say "$kind_ helper failed or refused an unaccounted launch"; return 1; }
}
# corr 1f03f0f8e7565125 (2026-10-05): data/netcup-leaves.hold stops new NETCUP starts only (free routes exhausted); bosgame sends continue
if [ -e "$H/data/netcup-leaves.hold" ]; then say "HOLD: data/netcup-leaves.hold present, no new netcup lanes ($(head -1 "$H/data/netcup-leaves.hold"))"; free=0; pfree=0; lfree=0; fi

URL=$(git -C "$PROJECT" remote get-url origin)
[ -d "$CLONE/.git" ] || git clone -q --no-checkout "$URL" "$CLONE" 2>/dev/null
git -C "$CLONE" fetch -q origin main 2>/dev/null
git -C "$CLONE" checkout -q --detach origin/main 2>/dev/null
# chief 4627 (3): one cached snapshot per pass. The commit log (4000 commits) and the merged-PR list are read once and reused while origin/main is
# unchanged and the snapshot is under 10 minutes old (no per-pass git log / gh pr list when nothing moved); a changed main sha refreshes both.
msha=$(git -C "$CLONE" rev-parse origin/main 2>/dev/null)
if [ -n "$msha" ] && [ -s "$W/main-messages.txt" ] && [ "$(cat "$W/main-snap.sha" 2>/dev/null)" = "$msha" ] && [ $(( $(date +%s) - $(stat -c %Y "$W/main-messages.txt") )) -lt 600 ]; then
  say "main snapshot cached ($msha)"
else
  rm -f "$W/main-snap.sha"   # a failed refresh below must not leave a key that vouches for a partial snapshot
  glog_ok=0; gpr_ok=0
  git -C "$CLONE" log origin/main -n 4000 --format='%s%x1f%b%x1e' > "$W/main-raw.log" 2>/dev/null && [ -s "$W/main-raw.log" ] && glog_ok=1
  (cd /tmp && gh pr list --repo Authentis/decision-os --state merged --limit 150 --json title,body,headRefName --jq '.[]|.headRefName+"\u001f"+.title+"\u001f"+.body+"\u001e"' > "$W/main-raw.prs" 2>/dev/null) && gpr_ok=1
  { cat "$W/main-raw.log" 2>/dev/null; echo "@@PRS@@"; cat "$W/main-raw.prs" 2>/dev/null; } > "$W/main-raw.txt"
  python3 "$B/refill_lib_v2.py" landed "$W/main-raw.txt" > "$W/main-messages.txt"
  if [ "$glog_ok" = 1 ] && [ "$gpr_ok" = 1 ]; then printf '%s\n' "$msha" > "$W/main-snap.sha"; else say "main snapshot refresh incomplete (git log ok=$glog_ok, merged-PR list ok=$gpr_ok): used for this pass only, refetched next pass"; fi
fi
# only briefs of tasks with a live meta count as already dispatched (a torn-down lane must not hide its leaf)
: > "$W/all-briefs.txt"
for b in "$H"/data/dos-*/brief.md; do t=$(basename "$(dirname "$b")"); [ -f "$H/state/$t.meta" ] && cat "$b" >> "$W/all-briefs.txt"; done
# main 2297: only RUNNING cloud workers block their leaf; finished/retired ledger rows and bosgame routing history no longer do
# (open/merged PRs and data/bosgame-owned.txt cover those). A new brief names the earlier attempt and its archive (cloud-pickup/brief step).
awk -F'\t' '$4=="running"' "$H/data/cloud-workers.tsv" 2>/dev/null >> "$W/all-briefs.txt"
# main 2371: cached PR list (GraphQL quota): full fetch at most hourly, otherwise only PRs updated since the last pass; rate limit logged in data/prs-cache.log
python3 "$B/prs-cache.py" "$W/prs.json" 2>/dev/null || : > "$W/prs.json"
[ -s "$W/prs.json" ] || say "PR list unavailable: supply falls back to the legacy text rules this pass"
# main 2304: --limit 4000 truncates silently once the repo passes 4000 PRs; warn loudly when the fetch comes back exactly full
[ "$(python3 -c "import json,sys;print(len(json.load(open(sys.argv[1]))))" "$W/prs.json" 2>/dev/null)" = 4000 ] && say "WARNING: PR fetch returned exactly 4000 (the --limit): older PRs are missing from landed/open evidence; raise the limit"
python3 "$B/refill_lib_v2.py" open-prs > "$W/open-prs.txt" 2>/dev/null
{ bash "$B/lane-live-paths.sh" netcup; bash "$B/lane-live-paths.sh" bosgame; } 2>/dev/null | awk '{print $3}' > "$W/live-paths.txt"
python3 "$B/t1-closure.py" write > "$W/t1-closure.out" 2>&1 || true     # T1 closure leaves go first (chief 1670)
python3 "$B/refill_lib_v2.py" supply "$CLONE/.beads/issues.jsonl" "$W/main-messages.txt" "$W/all-briefs.txt" "$PROJECT/.beads/issues.jsonl" "$W/live-paths.txt" "$H/data/bin/t1-priority.txt" "$( [ -s "$W/prs.json" ] && echo "$W/prs.json")" > "$W/candidates.json"
# chief 2752 #3: captain-held leaves (one suffix per line in data/refill-captain-held.txt) never become refill candidates
if [ -s "$H/data/refill-captain-held.txt" ]; then python3 - "$W/candidates.json" "$H/data/refill-captain-held.txt" <<'PY'
import json, sys
held = {l.split('#')[0].strip() for l in open(sys.argv[2])} - {''}
c = json.load(open(sys.argv[1])); k = [x for x in c if x['suf'] not in held]
if len(k) != len(c): json.dump(k, open(sys.argv[1], 'w'))
PY
fi
supply=$(python3 -c "import json;print(len(json.load(open('$W/candidates.json'))))")
clean=$(python3 -c "import json;print(sum(1 for c in json.load(open('$W/candidates.json')) if not c['overlap']))")
say "supply=$supply dispatchable leaves ($clean without FILES overlap with live lanes)"
[ "$DRY" = 0 ] && { printf '%s\n' "$supply" > "$W/dispatchable.count.tmp"; cat "$W/dispatchable.count.tmp" > "$H/state/dispatchable.count"; rm -f "$W/dispatchable.count.tmp"; }
# chief 4645/4646: one vertical-candidates refresh per pass, written atomically (temp + rename in $H/data). lane_claimable.py does not
# exist, so v-candidates.py derives claimability from br dependency/status data (see its header comment). A failed refresh keeps the
# old file; consumers gate on its age via 'v-candidates.py check'.
if [ "$DRY" = 0 ]; then
  if ! python3 "$B/v-candidates.py" write "$H/data/v-candidates.json" > "$W/v-candidates.log" 2>&1; then
    say "v-candidates refresh FAILED (see $W/v-candidates.log); the previous data/v-candidates.json stays in place"
  fi
fi

# ---------------------------------------------------------------- 2. GO for committed lanes
# go-fix-1400 (c): oldest done-time first, no planning-first override
GOTXT='GO: the gate has room. Start validation now: /no-mistakes (axi run, literal --intent, your leaf only) on your committed head. Never --yes. Report the PR when CI is green.'
mapfile -t ordered < <(for id in "${live[@]}"; do a_=$(grep -a '\[at=' "$H/state/$id.status" 2>/dev/null | tail -1 | grep -o 'at=[0-9]*' | head -1 | cut -d= -f2); echo "${a_:-0} $id"; done | sort -n | awk '{print $2}')
for id in "${ordered[@]}"; do
  last=$(grep -a '\[at=' "$H/state/$id.status" | tail -1)
  case $last in done*committed*|done*implemented*|done*implementation\ handoff*|*ready*waiting*GO*|*waiting\ for\ GO*|*[Aa]waiting*GO*|*[Ww]aiting*GO*|*[Hh]andoff\ commit*) ;; *) continue;; esac
  case $last in *"PR http"*) continue;; esac
  at=$(printf '%s' "$last" | grep -o 'at=[0-9]*' | head -1 | cut -d= -f2)
  mk="$W/go-$id-$at"; [ -e "$mk" ] && continue
  wt=$(grep '^worktree=' "$H/state/$id.meta" | cut -d= -f2)
  br=$(git -C "$wt" branch --show-current 2>/dev/null)
  ran=$(sqlite3 -readonly "$GATE_DB" "select count(*) from runs where branch='$br' and created_at>$at" 2>/dev/null || echo 0)
  [ "${ran:-0}" -gt 0 ] && continue
  if [ "$CLAUDE_OFF" = 1 ] && grep -q '^harness=claude' "$H/state/$id.meta"; then say "GO for $id held: data/claude-off (Claude lane, no GO or relaunch)"; continue; fi
  if [ "$gate" -lt 6 ] && [ "${load5%%.*}" -lt 14 ] && [ "${mem:-0}" -ge 3 ] && [ "$pk_busy" != 1 ]; then   # go-load-1500: admitting finished work is held only by the gate cap, a freeze guard (load5 14) and memory; new starts keep load5 < 8
    # go-fix-1400 (a): fm-send to an ended agent only writes a recovery record, so check the agent first; a dead one is relaunched with the GO
    alive=""; [ -n "$wt" ] && alive=$(python3 "$B/refill_lib_v2.py" alive "$wt" 2>/dev/null)
    # go-fix-1400 (3): only a currently OPEN *-go key, from the same fold fm-send.sh uses; none open = no --resolve-key
    gokey=$( . "$H/bin/fm-classify-lib.sh" 2>/dev/null && status_open_decisions "$H/state/$id.status" 2>/dev/null | grep -ao '\[key=[^]]*-go\]' | tail -1 | sed 's/^\[key=//; s/\]$//')
    sendgo() {   # (1)(2): GOTXT goes out exactly once via fm-send; marker and gate+1 only when it returns 0
      if "$H/bin/fm-send.sh" "$id" ${gokey:+--resolve-key "$gokey"} "$GOTXT" >/dev/null 2>&1; then : > "$mk"; gate=$((gate+1)); rm -f "$W/goattempts-$id-$at"
      else say "GO send to $id FAILED (not marked, retried next run)"; fi
    }
    case $alive in
      1) gorole=build; case $id in dos-planning*|dos-repoint-split-*) gorole=plan;; esac
         if [ "$ROUTER_LIVE" != 0 ] || [ "$gorole" = plan ]; then
           golive=$(task_live_data "$id")
           route_existing_binding "$id" "$gorole" "$golive" || continue
         fi
         if grep -q '^model=opencode-go/' "$H/state/$id.meta"; then   # chief 2259 #1: a live Go worker resuming on GO takes a Go slot first
           if [ "$DRY" = 0 ]; then r_=$(bash "$B/go-slot.sh" take "$id" same); else r_=$(bash "$B/go-slot.sh" route); fi
           [ "$r_" = go ] || { say "GO for $id deferred: Go full (live Go worker, not rerouted)"; continue; }
         fi
         say "GO -> $id (committed, agent alive, no run yet, gate $gate/6)"
         if [ "$DRY" = 0 ]; then sendgo; else gate=$((gate+1)); fi ;;   # (d): a simulated GO counts against the cap
      0) case $id in dos-planning*|dos-repoint-split-*) say "GO $id WAIT: reconcile planning usage before relaunch"; continue;; esac
         af="$W/goattempts-$id-$at"; n=$(cat "$af" 2>/dev/null || echo 0)
         if [ "$n" -ge 3 ]; then say "GO relaunch of $id failed 3 times"; continue; fi   # (4): bounded retries per id+done-time
         [ "$DRY" = 0 ] && fresh_gate
         # pass-3 (S6): a relaunch is a NETCUP start, so the host capacity/hold counters gate it
         # too - netcup-leaves.hold zeroes free/pfree/lfree but leaves sn positive, and checking
         # sn alone let a GO relaunch slip past the hold. free is already clamped by sn.
         if [ "$free" -le 0 ]; then say "GO relaunch of $id held: netcup host cap reached or an explicit hold is active (free=0; $swhy)"; continue; fi
         say "GO -> $id by relaunch (committed, agent ended, attempt $((n+1))/3, gate $gate/6)"
         if [ "$DRY" = 0 ]; then
           if [ -e "${LANE_EU_HOST_FILE:-$HOME/.no-mistakes/eu-host}" ] && grep -qiE '^(harness|model)=.*(muse|meta/)|^harness=meta$' "$H/state/$id.meta" && ! grep -qxF 'model=opencode/muse-spark-1.3-contributor-free' "$H/state/$id.meta"; then
             say "REFUSED GO relaunch of $id: meta/Muse route on EU host netcup (chief 125246)"; continue; fi
           echo $((n+1)) > "$af"
           if [ "$ROUTER_LIVE" = 0 ]; then
             if grep -q '^model=opencode-go/' "$H/state/$id.meta"; then rl=(bash "$B/go-slot.sh" relaunch "$id"); else rl=("$H/bin/fm-control.sh" "$id" relaunch); fi
             if router_prelaunch && timeout 300 "${rl[@]}" --note "check your inbox for the GO before starting the gate" >/dev/null 2>&1; then
               if one_start; then sendgo
               else say "GO relaunch of $id verified but its start could not be recorded: GO not marked and no further starts this pass"; fi
             else say "GO relaunch of $id NOT verified (attempt $((n+1))/3, not marked)"; fi
           else
             gorole=build; case $id in dos-planning*|dos-repoint-split-*) gorole=plan;; esac
             golive=$(task_live_data "$id")
             cancel_prior_admission "$id"
             route_leaf netcup "$id" "$golive" "$gorole" go || { say "GO relaunch $id WAIT (kept unmarked)"; continue; }
             # v3.1 relaunches confirm their exact admitted tuple before accounting.
             if relaunch_routed "$id"; then sendgo
             else say "GO relaunch of $id NOT verified (attempt $((n+1))/3, not marked)"; fi
           fi
         else gate=$((gate+1)); fi ;;
      *) say "GO skipped for $id: agent liveness unknown (worktree '${wt:-none}')";;
    esac
  else
    if [ "$gate" -ge 6 ]; then say "$id committed but the gate is full ($gate/6): GO held"
    else say "$id committed but load5 $load5 >= 14 or MemAvailable ${mem}GB < 3: GO held (gate $gate/6 has room)"; fi   # chief 1745: print the real reason
  fi
done

# ---------------------------------------------------------------- 3. START
spawned=0; attempts=0   # chief 1739
[ "$DRY" = 0 ] && fresh_gate   # chief 4627 (1): the first check ran before the snapshot fetch and GO relaunches; read it again before launching
# 3-pre0. data/ds-start-first: briefed ship ids (one per line) that take the next DeepSeek slot ahead of resumes (captain-approved work, e.g. chief 2093 docs plan A)
for pid in $(cat "$H/data/ds-start-first" 2>/dev/null); do
  case $pid in dos-planning*|dos-repoint-split-*) say "START-FIRST $pid WAIT: planning/repoint passes are owned by the budget/yield controller"; continue;; esac
  [ "$nds" -lt "${DS_CAP:-4}" ] || break
  [ "$DRY" = 0 ] && fresh_gate
  [ "$sn" -gt 0 ] || { say "DeepSeek start waits: can_start allows no start now"; break; }   # chief 4627 (1)
  [ "$free" -gt 0 ] || { say "DeepSeek start waits: netcup host cap reached or an explicit hold is active (free=0)"; break; }   # pass-2 fix 3: start-first honors the same host cap/holds as every other netcup start
  # pass-3 (S3): every launch path runs the same router admission; a WAIT (e.g. fleet.yaml
  # missing -> route_pick fails closed) means no launch, never a hard-coded fallback.
  [ -e "$H/state/$pid.meta" ] && { say "START-FIRST $pid already has metadata; kept queued until a verified live worker is observed"; continue; }
  [ -e "$H/data/$pid/brief.md" ] || continue
  if [ "$ROUTER_LIVE" = 0 ]; then
    ds_route "$pid" || { say "START-FIRST $pid waits: every DeepSeek route marked down"; continue; }
    say "START-FIRST $pid on DeepSeek route $nxt (legacy ROUTER_LIVE=0)"
    if [ "$DRY" = 0 ]; then
      spawn_retry "$pid" "$PROJECT" $NM "${RX[@]}" --effort "$EFF" || { say "START FAILED $pid (kept queued)"; continue; }
      [ -e "$H/state/$pid.meta" ] || { say "START FAILED $pid (no verified metadata, kept queued)"; continue; }
      one_start || { say "START $pid verified but accounting failed (kept queued)"; continue; }
    fi
  else
    live_=$(task_live_data "$pid")
    route_leaf netcup "$pid" "$live_" build start-first || { say "START-FIRST $pid held: router v3.1 admission refused"; continue; }
    say "START-FIRST $pid on admitted binding $ROUTE_PICK"
    if [ "$DRY" = 0 ] && ! spawn_routed "$pid" "$PROJECT" $NM "${ROUTE_ARGV[@]}"; then say "START FAILED $pid (kept queued)"; continue; fi
  fi
  [ "$DRY" = 0 ] && sed -i "/^$pid\$/d" "$H/data/ds-start-first"
  nds=$((nds+1)); spawned=$((spawned+1)); [ "$free" -gt 0 ] && free=$((free-1))
done
# 3-pre. SO-16 resume first (chief 2087): free-model lanes stalled on the OpenCode Zen cap are relaunched in their own worktree
#  on the next DeepSeek route before any new leaf starts from supply, within DS_CAP. Finished lanes are skipped.
for m in $(sed 's#^#'"$H"'/state/#; s#$#.meta#' "$H/data/ds-resume-queue" 2>/dev/null) "$H"/state/dos-leaf-*-free-*.meta; do
  [ -e "$m" ] || continue; id=$(basename "$m" .meta)
  case $id in dos-planning*|dos-repoint-split-*) say "RESUME $id WAIT: reconcile planning usage with the controller"; continue;; esac
  # data/ds-resume-queue: parked DeepSeek lanes held over DS_CAP, resumed first (one id per line, removed once relaunched)
  inq=0; if grep -qx "$id" "$H/data/ds-resume-queue" 2>/dev/null; then inq=1; else grep -q '^harness=opencode$' "$m" || continue; fi
  [ "$nds" -lt "${DS_CAP:-4}" ] || break
  [ "$DRY" = 0 ] && fresh_gate
  [ "$sn" -gt 0 ] || { say "DeepSeek start waits: can_start allows no start now"; break; }   # chief 4627 (1)
  [ "$free" -gt 0 ] || { say "DeepSeek resume waits: netcup host cap reached or an explicit hold is active (free=0)"; break; }   # pass-2 fix 3: the resume path honors the same host cap/holds
  st=$("$H/bin/fm-crew-state.sh" "$id" 2>/dev/null | head -1)
  case $st in *"worktree gone"*|*"no metadata"*|*"state: done"*) continue;; esac
  tail -1 "$H/state/$id.status" 2>/dev/null | grep -q -E '^(done|resolved)' && continue
  wtp=$(sed -n 's/^worktree=//p' "$m" | head -1); alive=unknown
  [ -n "$wtp" ] && alive=$(python3 "$B/refill_lib_v2.py" alive "$wtp" 2>/dev/null || echo unknown)
  case $alive in 1) say "RESUME $id held: existing worker is alive"; continue;; 0) [ "$ROUTER_LIVE" = 0 ] || cancel_prior_admission "$id";;
    *) say "RESUME $id held: worker liveness is unknown"; continue;; esac
  if [ "$ROUTER_LIVE" = 0 ]; then
    ds_route "$id" || { say "RESUME $id waits: every DeepSeek route marked down"; continue; }
    say "RESUME $id on DeepSeek route $nxt (legacy ROUTER_LIVE=0)"
    if [ "$DRY" = 0 ]; then
      router_prelaunch || { say "RESUME $id held by router-off"; continue; }
      rout=$(timeout 300 "$H/bin/fm-control.sh" "$id" relaunch "${RX[@]}" --effort "$EFF" --note "Resumed on DeepSeek V4.1 Flash (SO-16) after the free-model usage cap. Your worktree holds your earlier work and commits: read git log and git status, then continue the brief from where it stopped. Check your steering inbox for any unread instruction first." 2>&1 | tail -1 | cut -c1-250); say "$rout"
      case $rout in relaunched*|*endpoint=*) :;; *) [ "$nxt" = go ] && bash "$B/go-slot.sh" release "$id"; say "RESUME FAILED $id (kept queued)"; continue;; esac
      one_start || { say "RESUME $id verified but accounting failed (kept queued)"; continue; }
    fi
  else
    live_=$(task_live_data "$id")
    route_leaf netcup "$id" "$live_" build resume || { say "RESUME $id held: router v3.1 admission refused (kept queued)"; continue; }
    say "RESUME $id on admitted binding $ROUTE_PICK"
    if [ "$DRY" = 0 ] && ! relaunch_routed "$id"; then say "RESUME FAILED $id (kept queued)"; continue; fi
  fi
  [ "$DRY" = 0 ] && [ "$inq" = 1 ] && sed -i "/^$id\$/d" "$H/data/ds-resume-queue"
  if [ "$ROUTER_LIVE" = 0 ]; then dlog "$id" "-" "ds$nxt" "resume stalled lane" "legacy ROUTER_LIVE=0"
  else dlog "$id" "-" router "resume stalled lane" "$ROUTE_PICK"; fi
  nds=$((nds+1)); spawned=$((spawned+1)); [ "$free" -gt 0 ] && free=$((free-1))
done
# chief 1739: failed starts do not use the start budget, so attempts are capped separately (3 a run)
# 3a-pre. drop finished items from the priority list (chief 1706/1707: spawn refuses done items every run and floods the journal)
if [ "$DRY" = 0 ]; then
  "$H/bin/fm-tasks-axi.sh" list --state done 2>/dev/null | awk -F, '/^  [a-z]/ {gsub(/^ +/,"",$1); print $1}' > /tmp/claude-1000/lane-refill/done-ids.txt || true
  if [ -s /tmp/claude-1000/lane-refill/done-ids.txt ]; then
    grep -vxFf /tmp/claude-1000/lane-refill/done-ids.txt "$H/data/bin/priority-lanes.txt" > /tmp/claude-1000/lane-refill/prio.new || true
    cat /tmp/claude-1000/lane-refill/prio.new > "$H/data/bin/priority-lanes.txt"   # chief 1739 #10: also when every item is done (empty list)
  fi
fi
# chief 1717: with fewer than 2 planning lanes in the fleet and supply under 70, planning takes the next free slots before any priority leaf or leaf pick
# chief 1739 #7: the planning hold is applied BEFORE planning demand is computed
if [ -e "$H/data/planning-hold.flag" ]; then
  y=$(sort -n "$H/data/planning-yields.tsv" 2>/dev/null | tail -2 | awk '{s+=$2; n++} END{print (n>=2 ? s : 99)}')
  [ "$y" -lt 5 ] && { PLAN=0; say "PLANNING SKIPPED (last 2 passes yielded $y leaves, hold flag set)"; }
fi
# chief 2648 #2: a .running marker counts only while bosgame's fresh snapshot shows that pass working (done or absent lanes are ignored)
bmark=$(python3 "$B/refill_lib_v2.py" bosgame-plan-live "$H/data/bosgame-snapshot.json" $(find "$H/state" -maxdepth 1 -name 'dos-planning*-bosgame-*.running' -mmin -150 2>/dev/null) 2>/dev/null)
# chief 2667: a planning pass owns its partition only while it is still working; a finished pass (last status line done or
# cancelled) releases it even while its PR waits for review or landing (the rows are written; landing needs no partition)
part_owned() { case $(tail -1 "$H/state/$1.status" 2>/dev/null) in done*|cancelled*) return 1;; esac; cat "$H/data/$1/partition" 2>/dev/null; }
# a paused or gate-parked planner is not in $wplan (working only) yet still owns its partition: read every unfinished planning lane
used=$( { for pid_ in $(ls "$H"/state/dos-planning*.meta 2>/dev/null | sed 's#.*/##; s#\.meta##' | grep -v -- '-bosgame-'); do part_owned "$pid_"; done
         for r_ in $bmark; do cat "$H/data/$(basename "$r_" .running)/partition" 2>/dev/null; done; } | tr '\n' ' ')
# chief 2692: also every range with a sent-not-started, working, paused, gated or landing (open PR) pass, netcup or bosgame
used="$used $(busy_used)"   # chief 1739 #4: working netcup lanes and live bosgame passes reserve a partition, finished ones do not
# chief 2670: data/partitions-exhausted lists letters with no plannable rows left (one per line); no pass starts on them
part=$(python3 "$B/refill_lib_v2.py" partition $used C1 C2 $(awk -v n="$(date +%s)" 'NF && (NF < 2 || n - $2 < 86400) {print $1}' "$H/data/partitions-exhausted" 2>/dev/null))   # chief 2656/2669: C1 (11.10-11.18) and C2 (11.19+) are bosgame's, never a netcup pass
bp0=$(printf '%s\n' $bmark | grep -c . )
# chief 2648 #2: while supply < 25, up to 3 concurrent passes across both hosts (working netcup planners + live bosgame passes), no 45-min cooldown
# chief 2671: a netcup planner counts toward the cap until it is done (paused for compact, a decision or a fix still counts);
# only a finished pass whose PR waits on review or landing does not. Recount from every unfinished netcup planning lane.
planw=0; for pid_ in $(ls "$H"/state/dos-planning*.meta 2>/dev/null | sed 's#.*/##; s#\.meta##' | grep -v -- '-bosgame-'); do
  case $(tail -1 "$H/state/$pid_.status" 2>/dev/null) in done*|cancelled*) ;; *) planw=$((planw+1));; esac; done
# 3b. planning runs through the chief 4894/4895 feedback controller.
# It owns below-25 -> 50 hysteresis, row eligibility, tokens and landed yield.
source "$B/router-planning.sh"
router_planning_tick || exit 1
# 3b'. no netcup room: unavailable bosgame receiver is an explicit pre-admit WAIT.


# 3a. priority lanes: pre-briefed tasks, one id per line in priority-lanes.txt (second column "scout" = read-only knowledge task)
while read -r pid kind; do
  [ "$DRY" = 0 ] && fresh_gate
  [ -z "$pid" ] || [ "$free" -le 0 ] && continue
  [ "$spawned" -ge 2 ] && continue          # at most 2 starts a run, priority lanes included (10-02: 14 starts in an hour pushed load5 to 12)
  [ -e "$H/state/$pid.meta" ] || [ ! -e "$H/data/$pid/brief.md" ] && continue
  "$H/bin/fm-tasks-axi.sh" show "$pid" 2>/dev/null | grep -q "^  state: done" && { say "skip PRIORITY $pid: backlog item already done"; continue; }   # chief 3929: a done item is skipped, not dispatched into a spawn refusal
  # pass-3 (S3): priority lanes (planning writers included) pass the same router admission; a WAIT
  # means no launch. The chief-mandated route constants (PLAN_ROUTE/Sol tiers) still govern WHICH
  # model the spawn carries - admission only decides WHETHER the launch may happen.
  [ "$attempts" -ge 3 ] && continue; attempts=$((attempts+1))
  if [[ "$pid" == dos-planning* || "$pid" == dos-repoint-split-* ]] && [ "$kind" != scout ]; then
    say "PRIORITY $pid WAIT: planning passes are owned by the budget/yield controller"; continue
  fi
  say "spawn PRIORITY $pid"
  if [ "$ROUTER_LIVE" = 0 ]; then
    legacy_args=(); legacy_prefix=($NM)
    if [[ "$pid" == dos-planning* || "$pid" == dos-repoint-split-* ]] && [ "$kind" != scout ]; then legacy_args=($PLAN_ROUTE)
    elif [ "$kind" = scout ]; then legacy_prefix=(--scout); legacy_args=($SOL_SCOUT)
    elif [ "$kind" = xhigh ]; then legacy_args=($SOL_XHIGH)
    elif [ "$kind" = codex ]; then legacy_args=($SOL_HIGH)
    elif [[ "$pid" == dos-planning* || "$pid" == dos-repoint-split-* ]]; then legacy_args=($SOL_HIGH)
    else
      [ "$nds" -lt "${DS_CAP:-4}" ] || { say "PRIORITY $pid waits (DS_CAP full)"; continue; }
      ds_route "$pid" || { say "PRIORITY $pid waits: every DeepSeek route marked down"; continue; }
      legacy_args=("${RX[@]}" --effort "$EFF"); nds=$((nds+1))
    fi
    if [ "$DRY" = 0 ]; then
      spawn_retry "$pid" "$PROJECT" "${legacy_prefix[@]}" "${legacy_args[@]}" || { say "START FAILED $pid (budget not used, retried next run)"; continue; }
      [ -e "$H/state/$pid.meta" ] || { say "START FAILED $pid (no verified metadata, retried next run)"; continue; }
      one_start || { say "START $pid verified but accounting failed"; continue; }
    fi
  else
    prole=build; case $pid in dos-planning*|dos-repoint-split-*) [ "$kind" = scout ] || prole=plan;; esac
    live_=$(task_live_data "$pid")
    route_leaf netcup "$pid" "$live_" "$prole" priority || { say "PRIORITY $pid held: router v3.1 admission refused"; continue; }
    pargs=($NM); [ "$kind" = scout ] && pargs=(--scout)
    if [ "$DRY" = 0 ] && ! spawn_routed "$pid" "$PROJECT" "${pargs[@]}" "${ROUTE_ARGV[@]}"; then say "START FAILED $pid (budget not used, retried next run)"; continue; fi
  fi
  free=$((free-1)); spawned=$((spawned+1))
done < "$H/data/bin/priority-lanes.txt"

# 3c. leaves: netcup while it has room, then bosgame (up to 2 sends) while it is under its lane cap
bos=$(python3 "$B/refill_lib_v2.py" bosgame-snapshot "$H/data/bosgame-snapshot.json" 2>/dev/null || echo none)
bosfromsnap=1; [ "$bos" = none ] && bosfromsnap=0
if [ "$bos" = none ]; then
  if [ -e "$H/data/bosgame-snapshot.required" ]; then bos=99; say "BOSGAME: no fresh snapshot, no starts there (chief 1739 #3)"
  else bos=$(python3 "$B/refill_lib_v2.py" bosgame-live "$H/data/bosgame-lanes.tsv" 2>/dev/null || echo 99); say "BOSGAME SNAPSHOT STALE: bosgame snapshot stale or unreadable (${snapwhy:-local copy older than 20 min}); falling back to the ledger estimate=$bos (chief 2640)"; fi
fi
case $bos in ""|*[!0-9]*) bos=99;; esac
if [ "$bos" != 99 ] && [ "${bosfromsnap:-0}" = 1 ]; then
  bpend=$(python3 "$B/refill_lib_v2.py" bosgame-pending-sends "$H/data/bosgame-snapshot.json" "$H/data/bosgame-lanes.tsv" 2>/dev/null || echo 0)
  case $bpend in ""|*[!0-9]*) bpend=0;; esac
  [ "$bpend" -gt 0 ] && say "bosgame: $bpend sends under 45 min with no lane yet count as live (chief 2648 #5)"; bos=$((bos + bpend))
fi
say "bosgame live lanes=$bos (route when < $BOS_CAP)"
bgu=$(python3 "$B/refill_lib_v2.py" bosgame-gate-unknown "$H/data/bosgame-snapshot.json" 2>/dev/null || echo none); [ "$bgu" != 0 ] && [ "$bgu" != none ] && say "bosgame gate evidence UNKNOWN for $bgu waiting lanes (no gate flag in the snapshot): $([ -e "$H/data/bosgame-unknown-bound.off" ] && echo "NOT counted (data/bosgame-unknown-bound.off set)" || echo "counted in full as a conservative bound in the live count above"); never inferred from the display string"
nslots=$(( lfree < 2 ? lfree : 2 )); [ "$nslots" -lt 0 ] && nslots=0
# chief 1108 (captain 11:0x, 2026-10-16): netcup builds non-live free_ok leaves itself on Cat Jam, at most NETCUP_CJ_CAP (3) live Cat Jam lanes, only while load5 < 7 and a host slot is free.
# Kill switch: data/netcup-catjam.off (or NETCUP_CJ_CAP=0). The picks are tagged catjam below and never fall back to a paid route.
CJCAP=${NETCUP_CJ_CAP:-3}; case $CJCAP in ""|*[!0-9]*) CJCAP=0;; esac; [ "$CJCAP" -gt 3 ] && CJCAP=3   # hard max 3 whatever the env says
CJ=0; REFILL_NETCUP_FREE=0; export REFILL_NETCUP_FREE
if [ ! -e "$H/data/netcup-catjam.off" ] && [ "$CJCAP" -gt 0 ] && [ "${load5%%.*}" -lt 7 ]; then
  CJ=1; REFILL_NETCUP_FREE=1; cjroom=$(( $CJCAP - ncj )); [ "$cjroom" -lt 0 ] && cjroom=0
  [ "$cjroom" -eq 0 ] && REFILL_NETCUP_FREE=0   # cap full: no free_ok netcup picks; the shared nslots budget (offline_ok leaves) is untouched, and the launch guard below enforces the cap
fi   # chief 1736: netcup leaves have their own 2 starts a run; priority pickups do not use them
# pass-2 fix 5 (cont.): never re-initialise bsends past an all-starts hold; the hold keeps bsends at 0 for the whole pass.
bsends=0; [ "${hold_all:-0}" != 1 ] && [ "$bos" -lt "$BOS_CAP" ] && bsends=${BOS_SENDS:-6}   # chief 1722: up to 4 a run (bosgame SM holds load5 < 9 and RAM > 8 GB itself); never past the cap
[ "$bsends" -gt $((BOS_CAP - bos)) ] && bsends=$((BOS_CAP - bos))
[ "$bsends" -lt 0 ] && bsends=0
# chief 2516 step 4 WIP cap: no new leaf while netcup gate-waiting lanes + open FAIL PRs with no fix lane exceed WIP_CAP (15),
# or the oldest gate-waiting lane is older than WIP_AGE (3 h). Resumes, priority lanes and planning are not held. WIP_CAP=0 disables.
# chief 2532: the leaf hold counts gate-waiting lanes + fix rounds in flight; FAIL PRs without a round no longer hold leaves (they drive fix rounds)
read -r wgw wfail wold wfix < <(python3 "$B/wip-count.py" "$H" "$W/prs.json" "$(date +%s)" "${live[@]}" 2>/dev/null || echo "0 0 0 0")
say "WIP: gate-waiting=$wgw fix-rounds-in-flight=${wfix:-0} (FAIL-no-fix=$wfail, not counted) oldest-gate-wait=$(( ${wold:-0} / 60 ))m (cap ${WIP_CAP:-15}, age $(( ${WIP_AGE:-10800} / 3600 ))h)"
if [ "${WIP_CAP:-15}" -gt 0 ] && { [ $(( ${wgw:-0} + ${wfix:-0} )) -gt "${WIP_CAP:-15}" ] || [ "${wold:-0}" -gt "${WIP_AGE:-10800}" ]; }; then
  say "WIP HOLD: no new leaves this run (netcup and bosgame)"; nslots=0; bsends=0
fi
# chief 2644 (SO-6 pacing, until the chief says otherwise): bosgame first while its live lanes < BOS_FIRST_UNDER (5), then netcup. Backup .bak-20261009-2644
bfirst=$(( ${BOS_FIRST_UNDER:-5} - bos )); [ "$bfirst" -lt 0 ] && bfirst=0; [ "$bfirst" -gt "$bsends" ] && bfirst=$bsends
bfree=$(python3 -c "import json;print(sum(1 for c in json.load(open('$W/candidates.json')) if not c['netcup_only'] and not c['overlap']))")   # chief 2752 #2
[ "$bfirst" -gt 0 ] && say "ROUTE: bosgame first for up to $bfirst leaves (bosgame live $bos < ${BOS_FIRST_UNDER:-5}, chief 2644); bosgame-eligible (free-ok, no overlap) candidates: $bfree"
[ "$bsends" -gt 0 ] && [ "$bfree" = 0 ] && say "bosgame: 0 free-ok leaves to send (every candidate is netcup_only: no free-ok label, SO-16), so nothing goes to bosgame this run"
# chief 4556/4557: live-data (netcup_only) leaves start on netcup, at most 2 at a time (ids kept in data/live-lane-ids.txt while their lane record exists). Kill switch: data/netcup-live.off
LIVE_RUN=0; if [ -s "$H/data/live-lane-ids.txt" ]; then while read -r lid; do [ -e "$H/state/$lid.meta" ] && LIVE_RUN=$((LIVE_RUN+1)); done < "$H/data/live-lane-ids.txt"; fi
export REFILL_LIVE_ROOM=$(( 2 - LIVE_RUN < 0 ? 0 : 2 - LIVE_RUN )); [ -e "$H/data/netcup-live.off" ] && REFILL_LIVE_ROOM=0; export REFILL_NETCUP_LIVE=1
# chief 4627 (1): every start, netcup or bosgame, spends the one can_start budget (load5 < 6, MemAvailable >= 4 GB, 2 per minute); netcup slots take it first
[ "$nslots" -gt "$sn" ] && nslots=$sn
[ "$bsends" -gt "$sn" ] && bsends=$sn   # the shared budget is spent pick by pick: fresh_gate/one_start in the loop below stop the pass when it runs out
[ "$bsends" -lt 0 ] && bsends=0
python3 "$B/refill_lib_v2.py" pick "$W/candidates.json" "$W/live-paths.txt" "$nslots" "$bsends" "$bfirst" > "$W/picks.txt"
while read -r host suf title; do
  [ -z "$host" ] && continue
  row_text=$(python3 -c 'import json,sys; c=[x for x in json.load(open(sys.argv[2])) if x["suf"]==sys.argv[1]]; print(" ".join(str(c[0].get(k,"")) for k in ("title","body")) if c else "")' "$suf" "$W/candidates.json" 2>/dev/null)
  row_labels=$(python3 -c 'import json,sys; c=[x for x in json.load(open(sys.argv[2])) if x["suf"]==sys.argv[1]]; print(json.dumps(c[0].get("labels",[]),separators=(",",":")) if c else "[]")' "$suf" "$W/candidates.json" 2>/dev/null)
  pick_live=$(router_classify_task "$row_text" "$row_labels" || echo WAIT)
  [ "$pick_live" = WAIT ] && { say "pick $suf ($host) waits: credential classification unavailable"; continue; }
  [ "$DRY" = 0 ] && fresh_gate
  if [ "$sn" -le 0 ] && [ "$DRY" = 0 ]; then say "pick $suf ($host) waits: can_start allows no start now"; continue; fi   # chief 4627 (1)
  if [ "$host" = bosgame ]; then
    route_leaf bosgame "$suf" "$pick_live" build build || continue
    # pass-5 (chief): the picked BINDING is applied to the send itself: bosgame-leaf-send.sh
    # resolves it through the fleet.yaml bindings table and names 'harness <h>, model <m>, effort
    # <e>' in the message, overriding its marker-file branches. An unresolvable binding refuses
    # the send before anything goes out.
    # pass-6b: a bare-model pick (no '@') carries no binding row, so the router's route cannot be
    # applied to the send; the send FAILS CLOSED here (no sender call, no start counted) instead
    # of letting bosgame-leaf-send.sh run its legacy Sonnet/Opus/Spark branch unrouted.
    BG_EXTRA=""
    case ${ROUTE_PICK:-} in
      *@*) BG_EXTRA="--binding $ROUTE_PICK" ;;
      *)
        if [ -n "${ROUTE_PICK:-}" ]; then
          say "ROUTER: bosgame send refused: bare-model pick $ROUTE_PICK has no binding"
          dlog - "$suf" none "Router v3 bare-model pick" "bosgame send refused: pick has no binding"
          continue
        fi ;;
    esac
    say "-> bosgame: leaf $suf${ROUTE_PICK:+ (router pick $ROUTE_PICK)}"
    dlog - "$suf" bosgame "netcup has no leaf slot, bosgame under cap $BOS_CAP"
    if [ "$DRY" = 0 ]; then
      # pass-8 (review): the sender's EXIT STATUS is captured (no '|| true'): a sender that
      # prints a preliminary 'bosgame replied' line and then fails (e.g. its ledger append)
      # exits non-zero, and that is a FAILED send - the start budget is never spent on it. The
      # ADMITTED binding resolution is passed alongside --binding so the sender can verify its
      # fresh fleet.yaml re-read matches the route whose bans and quota passed.
      # shellcheck disable=SC2086 -- BG_EXTRA is exactly one flag plus one word (a binding id)
      bs_rc=0
      bsfull=$(BG_ADMIT_HARNESS="$ROUTE_BIND_HARNESS" BG_ADMIT_MODEL="$ROUTE_BIND_MODEL" BG_ADMIT_PROVIDER="$ROUTE_BIND_PROVIDER" BG_ADMIT_EFFORT="$ROUTE_BIND_EFFORT" ROUTER_ADMIT_INCARNATION="$RA_INCARNATION" bash "$B/bosgame-leaf-send.sh" "$suf" $BG_EXTRA --incarnation "$RA_INCARNATION" 2>&1) || bs_rc=$?
      bsout=$(printf '%s\n' "$bsfull" | grep -E "REFUSED|replied|sent|NOT" | cut -c1-250); [ -n "$bsout" ] && printf '%s\n' "$bsout"
      # Only an anchored positive acknowledgment is delivery.  Receipt
      # verification may be added as observation later; it never gates this.
      if [ "$bs_rc" != 0 ]; then
        bsnip=$(printf '%s' "$bsfull" | head -c 200); [ -n "$bsnip" ] || bsnip="no output"
        say "BOSGAME SEND FAILED $suf (rc=$bs_rc): $bsnip"
      elif ! printf '%s\n' "$bsfull" | grep -qE '^(replied|sent)'; then
        bsnip=$(printf '%s' "$bsfull" | head -c 200); [ -n "$bsnip" ] || bsnip="no output"
        say "BOSGAME SEND FAILED $suf (rc=0 but no anchored sent/replied line): $bsnip"
      else
        bsnip=$(printf '%s' "$bsfull" | head -c 200); [ -n "$bsnip" ] || bsnip="no output"
        say "BOSGAME SEND DELIVERED $suf: $bsnip"
        router_confirm "$suf" "bosgame-$RA_INCARNATION" || say "BOSGAME DELIVERY ACCOUNTING FAILED $suf: delivery remains sent"
        one_start || say "BOSGAME DELIVERY START ACCOUNTING FAILED $suf: delivery remains sent"
      fi
    fi
    continue
  fi
  # v6: every netcup leaf start needs a host slot whatever its tier (Codex v4/v5 FAIL: priority/planning starts consume free after lfree was taken, and the DeepSeek/cc/free tiers are exempt from the free<=0 check below)
  if [ "$free" -le 0 ]; then dlog - "$suf" none "netcup CAP $CAP full" "free=0 after earlier starts this run"; say "leaf $suf: waits (netcup CAP $CAP full after earlier starts)"; continue; fi
  # chief 1802 (captain 10-03, SO-5, replaces chief 1797's free-first and the Sol/Kimi leaf lanes): leaf workers in this order, first tier with room wins:
  #  (1) free: pi cline-pass/deepseek-v4-pro (data/free-route-ok under 3 h, refreshed by free-route-ping.sh; FREE_CAP 2, the route allows no parallel bursts)
  #  (2) Command Code GOAT deepseek/deepseek-v4.1-flash (CC_CAP 3)
  #  (3) Codex Terra gpt-5.6-terra medium, with one Claude Sonnet 5.5 medium lane at a time (SONNET_CAP 1, Claude budget is tight); both within their plan lines
  # No Sol or Opus for leaves. Tier 1 (free) takes only fixture-only leaves; tier 2 (cc) also takes real-data leaves since cc-realdata-1050 (captain 10-04); Sonnet only after a cc failure (data/cc-failed/<leaf>).
  # opencode free models are dead headless (2026-10-03). Kimi is out (weekly limit 403, data/kimi-leaf-hold). Every lane counts inside the netcup cap.
  fok=$(cat "$H/data/free-route-ok" 2>/dev/null || echo 0); [ $(( $(date +%s) - ${fok:-0} )) -gt 7200 ] && [ "$DRY" = 0 ] && { bash "$B/free-route-ping.sh" >/dev/null 2>&1; fok=$(cat "$H/data/free-route-ok" 2>/dev/null || echo 0); }
  fq=$(python3 - "$suf" "$W/candidates.json" <<'PY'
import json, sys
c = [x for x in json.load(open(sys.argv[2])) if x['suf'] == sys.argv[1]]
print(1 if c and not c[0].get('netcup_only') and (c[0]['est'] <= 400 or c[0]['est'] >= 999) else 0)
PY
)
  fage=$(( $(date +%s) - ${fok:-0} ))
  if [ "${fq:-0}" != 1 ]; then fwhy="free: leaf is netcup_only or est outside the free range"
  elif [ "$nfree" -ge "${FREE_CAP:-5}" ]; then fwhy="free: FREE_CAP ${FREE_CAP:-5} full"
  elif [ "$fage" -gt 10800 ]; then fwhy="free: route not confirmed for ${fage}s"
  else fwhy=-; fi
  # SO-16 (captain 09:2x 2026-10-06, chief 2086): netcup leaves run only on DeepSeek V4.1 Flash, 2-3 lanes (DS_CAP), thinking high,
  #  alternating per new lane between the Qwen token plan (pi) and Command Code; a route with a quota error is marked
  #  data/ds-route-down-<qwen|cc> and its lanes go to the other route. Qwen stops at 90% monthly; Command Code may pass 85%.
  # chief 2765 (captain 10-10 09:5x, SO-5; replaces chief 2508's Haiku tier): no Haiku for coding. Sonnet 5.5 medium for est <= 300 lines and
  #  unknown size, Opus 5.5 medium over 300 (fix rounds stay Opus). CLAUDE_ROUTE=0 restores the DeepSeek/free tiers below. Backup .bak-20261010-2765
  # leaf size = "at most N changed physical lines" in its SIZE line (the est field is minutes, not lines); 999 = unknown
  cest=$(python3 -c 'import json,re,sys; c=[x for x in json.load(open(sys.argv[2])) if x["suf"]==sys.argv[1]]; m=re.search(r"SIZE:[^\n]*?at most (\d+) changed", c[0]["body"]) if c else None; print(m.group(1) if m else 999)' "$suf" "$W/candidates.json" 2>/dev/null || echo 999)
  # v4 free-first: the proven free pool (data/free-route-ok under 3 h, FREE_CAP) is tried before every other tier; the tiers below are unchanged
  cjleaf=$(python3 -c 'import json,sys; c=[x for x in json.load(open(sys.argv[2])) if x["suf"]==sys.argv[1]]; print(1 if c and c[0].get("free_ok") and not c[0].get("netcup_only") and c[0].get("offline_ok") is not True else 0)' "$suf" "$W/candidates.json" 2>/dev/null || echo 0)
  ffoff=0; [ -e "$H/data/free-first.off" ] && ffoff=1   # snapshot the kill switch once for this leaf
  fmodel=$(fm_free_model || true)   # read once: the eligibility test and the launch use the same value
  readarray -t classrow < <(python3 - "$suf" "$W/candidates.json" <<'PY'
import json, sys
c = [x for x in json.load(open(sys.argv[2])) if x["suf"] == sys.argv[1]]
row = c[0] if c else {}
print(" ".join(str(row.get(k, "")) for k in ("title", "body")))
print(json.dumps(row.get("labels", []), separators=(",", ":")))
PY
)
  islive=$(router_classify_task "${classrow[0]:-}" "${classrow[1]:-[]}" || echo WAIT)
  [ "$islive" = WAIT ] && { say "leaf $suf: credential classification unavailable: WAIT"; continue; }
  ldate=$(date +%m%d); id=$(leaf_task_id "$suf" router "$ldate") || continue
  # The admission is keyed by the actual launch id and receives real task text/labels.
  route_leaf netcup "$id" "$islive" build build || continue
  if [ -n "$ROUTE_ARGS" ]; then
    # pass-3 (S2): the picked binding is APPLIED to the spawn arguments - it replaces the legacy
    # tier route entirely (the ladder below is skipped). Effort is not part of the router schema;
    # the leaf default medium is used.
    tag=router; why="Router v3.1 pick $ROUTE_PICK"
  else
    # A live router admission was keyed by the router incarnation above.  It
    # must never fall through to a legacy tier id, which would leave that
    # admission outstanding.  A valid v3.1 pick always supplies argv.
    router_cancel "$id" || true
    say "ROUTER WAIT build $id: admitted pick had no launch argv; cancelled before legacy tier selection"
    dlog - "$suf" none "Router v3.1 malformed pick" "admission cancelled; no legacy-id launch"
    continue
  fi
  if [ "$islive" = yes ]; then   # chief 4556: live data = Sonnet, then Codex when Claude is off; no free or Kimi models on live data
    if [ "$CLAUDE_OFF" = 1 ]; then tag=terra; HX="--harness codex --model gpt-5.6-terra --effort medium"; else tag=sonnet; HX="--harness claude --model claude-sonnet-5-5 --effort medium"; fi
    why="chief 4556 live-data (netcup_only) leaf, live lanes $LIVE_RUN/2"
  elif [ "$CJ" = 1 ] && [ "${cjleaf:-0}" = 1 ]; then
    if [ "$ncj" -ge "$CJCAP" ]; then dlog - "$suf" none "waits for a Cat Jam slot" "NETCUP_CJ_CAP $CJCAP full"; say "leaf $suf: waits (Cat Jam lanes $ncj/$CJCAP)"; continue; fi
    tag=catjam; HX="--harness opencode --model opencode-go/cat-jam-free --effort ${CJ_EFFORT:-medium}"; ncj=$((ncj+1)); why="chief 1108: non-live free_ok leaf on netcup, Cat Jam lanes $((ncj-1))/$CJCAP, load5 $load5"
  elif [ "${fq:-0}" = 1 ] && [ "$free" -gt 0 ] && [ "$nfree" -lt "${FREE_CAP:-5}" ] && [ "$fage" -le 10800 ] && { { [ "$ffoff" = 1 ] && [ ! -e "${LANE_EU_HOST_FILE:-$HOME/.no-mistakes/eu-host}" ]; } || { [ "$ffoff" = 0 ] && [ -n "$fmodel" ]; }; }; then tag=free
    if [ "$ffoff" = 1 ]; then HX="--harness opencode --model opencode/muse-spark-1.3-contributor-free --effort ${FREE_EFFORT:-medium}"   # kill switch: the old fixed route
    else HX="--harness opencode --model opencode/$fmodel --effort ${FREE_EFFORT:-medium}"; fi   # chief 4369 B: verified $0 models first, Muse only on failure or a hard flag, never on the EU host
    nfree=$((nfree+1)); why="fixture-only leaf, free route ok, free lanes $((nfree-1))/${FREE_CAP:-5}"
  elif [ "${CLAUDE_ROUTE:-1}" = 1 ] && { [ "$CLAUDE_OFF" = 0 ] || [ ! -e "$H/data/kimi-refill-off" ]; }; then
    # chief 2603: one-shot K2.8 trial - while data/kimi-trial-next exists, the next small (<= 300 lines) builder leaf goes to Kimi K2.8
    # (kimi-code/kimi-for-coding = "K2.8 Preview", never K3) in place of a Claude lane; the live run consumes the file (-> kimi-trial-used)
    if [ ! -e "$H/data/kimi-refill-off" ] && [ "${cest:-999}" -le 300 ]; then tag=kimi; KTRIAL=1; HX="--harness pi --model kimi-code/kimi-for-coding --effort high"   # chief 4485/4486 (captain 10-17): free models first, then Kimi K2.8 builds, Muse last; Kimi never reviews   # K2.8 Preview supports low/high/max only
      [ "$DRY" = 0 ] && [ -e "$H/data/kimi-trial-next" ] && mv "$H/data/kimi-trial-next" "$H/data/kimi-trial-used"
    elif [ "$CLAUDE_OFF" = 1 ]; then tag=kimi; KTRIAL=1; HX=$KIMI27   # chief 083644: Kimi K2.7, plain (outside the codemode pilot)
    elif [ "${cest:-999}" -le 300 ]; then tag=sonnet; HX="--harness claude --model claude-sonnet-5-5 --effort medium"
    elif [ "${cest:-999}" -lt 999 ]; then tag=opus; HX="--harness claude --model claude-opus-5-5 --effort medium"
    else tag=sonnet; HX="--harness claude --model claude-sonnet-5-5 --effort medium"; fi
    why="SO-5 Claude route, est ${cest:-999} lines"
  elif [ "${DS_ROUTES:-1}" = 1 ]; then
    if [ "$nds" -ge "${DS_CAP:-4}" ]; then dlog - "$suf" none "waits for a DeepSeek slot" "DS_CAP ${DS_CAP:-4} full"; say "leaf $suf: waits (DS_CAP ${DS_CAP:-4} full)"; continue; fi
    [ "$attempts" -ge 3 ] && { dlog - "$suf" none "start attempts 3 used this run" "-"; continue; }   # chief 2259 #6: budget before any Go reservation
    ldate=$(date +%m%d); GID=$(leaf_task_id "$suf" dsgo "$ldate") || continue   # main 2251: one date for the reserved and the spawned id
    if ! ds_route "$GID"; then dlog - "$suf" none "every DeepSeek route down" "quota markers"; say "leaf $suf: every DeepSeek route marked down"; continue; fi
    HX="${RX[*]} --effort $EFF"
    nds=$((nds+1)); why="SO-16 DeepSeek route $nxt, ds lanes $((nds-1))/${DS_CAP:-4}"
  elif [ ! -e "$H/data/cc-failed/$suf" ] && [ "$ncc" -lt "${CC_CAP:-6}" ]; then tag=free; FR=(mimo-v2.6-flash-free ling-3.1-flash-free); HX="--harness opencode --model opencode/${FR[$(( (nwork + spawned) % 2 ))]} --effort medium"   # 2026-10-05: Muse capped, LongCat rate-limits; spread across free models   # chief 1990: CC kept for gate steps only
    : ; ncc=$((ncc+1)); why="cc lanes $((ncc-1))/${CC_CAP:-6}, no cc failure recorded"   # chief cc-realdata-1050 (captain 10-04 YES, SO-16): cc takes real-data (netcup_only) leaves too; CC_CAP 6
  elif [ ! -e "$H/data/cc-failed/$suf" ]; then dlog - "$suf" none "waits for a cc slot" "$fwhy; cc: CC_CAP ${CC_CAP:-6} full; sonnet: only after a cc failure"; say "leaf $suf: cc lane waits (CC_CAP ${CC_CAP:-6} full; Sonnet only after a cc failure, mark data/cc-failed/$suf)"; continue
  elif [ "$CLAUDE_OFF" = 1 ]; then
    if [ -e "$H/data/kimi-refill-off" ]; then say "leaf $suf: waits for eligible non-Claude route; Kimi excluded until reset"; continue; fi
    tag=kimi; KTRIAL=1; HX=$KIMI27; why="cc failed earlier on this leaf; data/claude-off: Kimi K2.7 in place of Sonnet"
  elif [ "${TIER3:-sonnet}" = sonnet ] || { [ "$nson" -lt "${SONNET_CAP:-1}" ] && [ $(( ${nwork:-0} % 2 )) -eq 1 ]; }; then tag=sonnet; HX="--harness claude --model claude-sonnet-5-5 --effort medium"; nson=$((nson+1)); why="cc failed earlier on this leaf (data/cc-failed)"   # chief 2050 (Codex burn 1.4x): tier 3 is Claude Sonnet 5.5 medium until TIER3=terra is set
  else tag=terra; HX="--harness codex --model gpt-5.6-terra --effort medium"; why="cc failed earlier, Sonnet cap or turn not available"; fi
  if [ "$tag" != free ] && [ "$tag" != cc ] && [ "$tag" != dsq ] && [ "$tag" != dscc ] && [ "$tag" != dsos ] && [ "$tag" != dsgo ] && [ "$free" -le 0 ]; then dlog - "$suf" none "$tag lane waits" "$fwhy; $tag: load5 $load5 >= 8 holds Codex/Claude starts"; say "leaf $suf: $tag lane waits (load5 $load5 >= 8 holds Codex/Claude starts, chief load-2145)"; [ "$tag" = sonnet ] && nson=$((nson-1)); continue; fi
  id=$(leaf_task_id "$suf" "$tag" "${ldate:-$(date +%m%d)}") || continue
  [ -n "${GID:-}" ] && [ "$GID" != "$id" ] && bash "$B/go-slot.sh" release "$GID"; GID=""   # main 2251: a Go slot reserved under the guessed id is freed when the lane spawns under another id
  # codemode smoke test (chief 1714): alternate Kimi leaf lanes, odd = pi codemode via the per-spawn shim, even = plain; ledger data/codemode-pilot.tsv
  SPAWN_PATH_PREFIX=""; cmode=""
  if [ "$tag" = kimi ] && [ "${KTRIAL:-0}" != 1 ]; then   # chief 2603: the K2.8 trial lane runs plain, outside the codemode pilot
    n=$(grep -c . "$H/data/codemode-pilot.tsv" 2>/dev/null || true); n=${n:-0}
    if [ $((n % 2)) -eq 0 ]; then cmode=codemode; SPAWN_PATH_PREFIX="$B/pi-codemode"; else cmode=plain; fi
    [ "$DRY" = 0 ] && printf '%s\t%s\t%s\n' "$id" "$cmode" "$(date +%s)" >> "$H/data/codemode-pilot.tsv"
  fi
  # chief 2654: leaves that need the EODHD key (captain's credential call) are listed in data/eodhd-blocked.leaves (one suffix per line) and never start
  if grep -qxF "$suf" "$H/data/eodhd-blocked.leaves" 2>/dev/null; then dlog "$id" "$suf" "$tag" "needs EODHD key" "skipped: EODHD key (captain), chief 2654"; continue; fi
  # chief 2631: a leaf whose lane id already has a finished backlog item (done, cancelled or released) is skipped, not respawned:
  # fm-spawn refuses it ("not dispatchable in state done") and the refusal repeated every run (10.278, 10.223). Logged once per id.
  bst=$("$H/bin/fm-tasks-axi.sh" show "$id" 2>/dev/null | awk '$1=="state:"{print $2; exit}')
  # Refuse an occupied shortened ID unless its durable title names this leaf.
  if [ "$id" != "dos-leaf-$(printf '%s' "$suf" | tr . -)-$tag-${ldate:-$(date +%m%d)}" ] && [ -n "$bst" ] && ! "$H/bin/fm-tasks-axi.sh" show "$id" 2>/dev/null | grep -Fq "Build leaf $suf ($tag lane)"; then
    say "ID COLLISION $id: existing task does not name leaf $suf; refusing start"
    continue
  fi
  case "$bst" in done|cancelled|released)
    if [ ! -e "$H/state/.refill-skip-$id" ]; then dlog "$id" "$suf" "$tag" "lane record $bst" "skipped: backlog item finished (chief 2631)"; say "leaf $suf: skipped, lane $id backlog item is $bst"; [ "$DRY" = 0 ] && : > "$H/state/.refill-skip-$id"; fi
    continue;; esac
  [ "$attempts" -ge 3 ] && { dlog "$id" "$suf" "$tag" "$why" "start attempts 3 used this run"; continue; }
  attempts=$((attempts+1))
  dlog "$id" "$suf" "$tag" "$why" "$fwhy"
  say "spawn $id  leaf $suf  $title  [$tag]"
  if [ "$DRY" = 0 ]; then
    "$H/bin/fm-tasks-axi.sh" add "$id" "Build leaf $suf ($tag lane)" --kind ship >/dev/null 2>&1
    "$B/fm-brief-local.sh" "$id" decision-os --mode no-mistakes >/dev/null 2>&1
    python3 "$B/refill_lib_v2.py" brief "$H/data/$id/brief.md" "$W/candidates.json" "$suf"
    # chief 2643 + 2648 #4: a bosgame send over 4 h old with no lane in this pass's fresh snapshot is reclaimable (decided from its own 'sent'
    # row age). bosgame's SM is told BEFORE the spawn; if the notice fails, this reclaim is skipped this pass and retried next pass.
    case $suf in *.*) full="dos-product-v1-88cgo.$suf";; *) full="$suf";; esac; rcl=0
    if python3 "$B/refill_lib_v2.py" bosgame-reclaimable 2>/dev/null | grep -qxF "$full"; then
      if printf '%s\n' "[netcup SM] chief 2643 reclaim: leaf $suf was sent to you over 4 h ago and your fresh snapshot lists no lane for it, so netcup is starting it now as $id. Do not start it." | timeout 60 ssh -T -o ConnectTimeout=20 bosgame-sm > "$W/reclaim-notice.out" 2>&1; then
        rcl=1; say "reclaim: bosgame SM told about leaf $suf"
      else say "reclaim skipped this pass: bosgame SM notice failed for leaf $suf ($(head -c 100 "$W/reclaim-notice.out" | tr '\n' ' '))"; continue; fi
    fi
    if [ "$tag" = router ]; then
      spawn_routed "$id" "$PROJECT" $NM "${ROUTE_ARGV[@]}" || { SPAWN_PATH_PREFIX=""; continue; }
    else
      spawn_retry "$id" "$PROJECT" $NM $HX || { SPAWN_PATH_PREFIX=""; continue; }
    fi
    SPAWN_PATH_PREFIX=""
    [ "$islive" = yes ] && [ -e "$H/state/$id.meta" ] && printf '%s\n' "$id" >> "$H/data/live-lane-ids.txt"
    if [ "$rcl" = 1 ]; then
      if [ -e "$H/state/$id.meta" ]; then printf '%s\t%s\tnot-started\treclaimed by netcup lane %s (chief 2643: fresh bosgame snapshot listed no lane; SM told)\n' "$(date +%s)" "$full" "$id" >> "$H/data/bosgame-lanes.tsv"; say "reclaimed bosgame send: leaf $suf -> $id (bosgame SM told)"
      else say "WARNING reclaim of $suf announced to bosgame SM but the netcup spawn failed; bosgame may start it"; fi
    fi
    # leaf lanes get their own tracker DB, never the primary's (every lane br write re-exported the primary JSONL)
    wt=$(sed -n 's/^worktree=//p' "$H/state/$id.meta" 2>/dev/null | head -1)
    if [ -n "$wt" ] && [ -d "$wt/.beads" ]; then
      rm -f "$wt/.beads/redirect"
      ( cd "$wt" && BEADS_DIR="$wt/.beads" nice -n 10 ionice -c3 timeout 150 br sync --import-only >/dev/null 2>&1 ) || say "WARNING local tracker import failed in $wt"
    fi
  fi
  if [ "$DRY" = 0 ] && [ ! -e "$H/state/$id.meta" ]; then say "START FAILED $id (budget not used, retried next run)"; dlog "$id" "$suf" "$tag" "start failed" "spawn did not create the lane"; [ "$tag" = free ] && { rm -f "$H/data/free-route-ok"; nfree=${FREE_CAP:-5}; say "free tier start failed: marker cleared, tier 2/3 take the next picks (chief 2020)"; }; continue; fi   # chief 1739 #5
  [ "$free" -gt 0 ] && free=$((free-1)); lfree=$((lfree-1)); spawned=$((spawned+1)); [ "$tag" = router ] || one_start
done < "$W/picks.txt"
[ "$free" -gt 0 ] && [ "$spawned" -eq 0 ] && say "$free slot(s) free but no eligible leaf (supply $supply, clean $clean)"

# ---------------------------------------------------------------- 4. LAND and close
# chief 2515: landing moved out of refill to pr-land.timer (5-min oneshot, flock -n /tmp/pr-land.lock) so slow xreviews never delay spawns
if [ "$DRY" = 1 ]; then echo "lane-refill: landing runs in pr-land.timer (bosgame-autoland.sh), not here"
else
  [ "$CLAUDE_OFF" = 1 ] && say "cloud launches skipped: data/claude-off (cloud workers run on Claude)"
  # pass-3 (S4): the launch-producing closure and cloud helpers are gated on the shared start budget
  # (fresh sn) and the all-starts holds (hold_all), and each start they make is recorded with
  # one_start only AFTER the helper succeeds - before this they ran ungated and uncounted.
  if [ "${hold_all:-0}" != 1 ]; then
    fresh_gate
    if [ "$sn" -gt 0 ]; then run_routed_helper closure "$B/closure-sweep.sh" || { sn=0; hold_all=1; }
    else say "closure sweep held this pass (no start budget left)"; fi
    [ "${hold_all:-0}" = 1 ] || fresh_gate
    if [ "${hold_all:-0}" != 1 ] && [ "$CLAUDE_OFF" = 0 ] && [ "$sn" -gt 0 ]; then run_routed_helper cloud "$B/cloud-launch.sh" || { sn=0; hold_all=1; }
    else say "cloud launches held this pass (no start budget left or data/claude-off)"; fi
  fi
  bash "$B/lane-release.sh" --live 2>&1 | sed 's/^/lane-refill: /'  # chief 2611 SO-8: release merged idle lanes (rescue ref, manifest, teardown no flags)
fi
# gate reports for me: runs waiting on a response, PRs in the ci monitor, and recent failed runs
Q() { sqlite3 -readonly "$GATE_DB" "$1" 2>/dev/null | sed 's/^/lane-refill: /'; }
Q "select 'PARKED-GATE '||r.branch||' '||s.step_name||':'||s.status from runs r join step_results s on s.run_id=r.id where r.status in ('running','fixing') and s.status in ('awaiting_approval','fix_review')"
Q "select 'CI-MONITOR (PR open, land it if green) '||r.branch from runs r join step_results s on s.run_id=r.id where r.status='running' and s.step_name='ci' and s.status='running'"
Q "select 'FAILED-RUN (worker may be idle; steer recover+wait GO) '||r.branch||' '||r.id||' '||coalesce((select step_name from step_results s where s.run_id=r.id and s.status='failed' limit 1),'') from runs r where r.status='failed' and r.branch like 'fm/dos-%' and r.updated_at>strftime('%s','now')-5400 and r.created_at=(select max(created_at) from runs x where x.branch=r.branch)"
python3 "$B/pilot-ledger-fill.py" | sed 's/^/pilot-ledger: /' || true
bash "$B/pilot-tag.sh" 2>&1 || true
exit 0
