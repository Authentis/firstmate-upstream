#!/usr/bin/env bash
# Sourced by lane-refill.  fm-planning-runner.sh is installed beside the router
# scripts.  It provides a bounded, accounting-backed planning launch contract.
router_planning_alert() {
  local reason=$1 host=${2:-none} model=${3:-none} now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  mkdir -p "$H/state"
  printf '%s reason=%s host=%s model=%s\n' "$now" "$reason" "$host" "$model" \
    >> "$H/state/planning-blocked.alert"
  say "PLANNING blocked: $reason (host=$host model=$model; see state/planning-blocked.alert)"
}

router_planning_reason() {
  local raw=$1 reason
  reason=$(printf '%s' "$raw" | tr '\r\n' ' ' | cut -c1-240)
  [ -n "$reason" ] || reason="unspecified planning runtime failure"
  printf '%s\n' "$reason"
}

router_planning_tick() {
  [ "$PLAN" = 1 ] || return 0
  [ "$DRY" = 0 ] || { say "PLANNING dry-run: controller/runner state unchanged"; return 0; }
  local request="$W/planning-request.json" task live caps binding out rc after_binding check_out check_reason controller_out controller_err
  local -a runner
  controller_err="$H/state/planning-controller-next.err"
  python3 "$B/router_planning_v31.py" next --home "$H" \
    --tracker "$CLONE/.beads/issues.jsonl" --candidates "$W/candidates.json" \
    --clone "$CLONE" --busy "$used" > "$request" 2>"$controller_err"; rc=$?
  controller_out=$(cat "$request")
  if [ "$rc" != 0 ]; then
    router_planning_alert "controller next failed: $(router_planning_reason "$(cat "$controller_err")")" none none
    say "PLANNING WAIT: $(cat "$request")"; return 0
  fi
  [ -s "$controller_err" ] && say "PLANNING controller: $(cat "$controller_err")"
  if ! python3 -c 'import json,sys; raise SystemExit(json.load(open(sys.argv[1])).get("action") != "START")' "$request"; then
    check_reason=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("reason", "controller WAIT"))' "$request" 2>/dev/null || printf 'controller WAIT')
    case "$check_reason" in
      *budget*|*quota*|*blocked*|*failure*) router_planning_alert "$check_reason" none none ;;
    esac
    say "PLANNING $(cat "$request")"; return 0
  fi
  fresh_gate
  [ "$sn" -gt 0 ] && [ "$pfree" -gt 0 ] && [ "$planw" -lt 3 ] || { router_planning_alert "capacity/hold" none none; say "PLANNING WAIT: capacity/hold"; return 0; }
  awk -v l="$load5" 'BEGIN{exit !(l < 8)}' || { router_planning_alert "host load" none none; say "PLANNING WAIT: host load"; return 0; }
  if [ -n "${FM_PLANNING_RUNNER:-}" ] && [ -x "$FM_PLANNING_RUNNER" ]; then
    runner=("$FM_PLANNING_RUNNER")
  elif [ -x "$B/fm-planning-runner.sh" ]; then
    runner=("$B/fm-planning-runner.sh")
  elif [ -x "$H/bin/fm-planning-runner.sh" ]; then
    runner=("$H/bin/fm-planning-runner.sh")
  elif [ -r "$B/router_planning_runner_v31.py" ]; then
    runner=(python3 "$B/router_planning_runner_v31.py")
  else
    runner=()
  fi
  if [ "${#runner[@]}" -eq 0 ]; then
    # Report every route we would have considered.  A missing local install is
    # actionable; a plain WAIT line hides a deployment fault.
    router_planning_alert "runner missing" netcup sol-plan@pi
    router_planning_alert "runner missing" bosgame muse-wonder-plan@muse
    router_planning_alert "runner missing" netcup kimi-k3-plan@pi
    return 0
  fi
  caps=$("${runner[@]}" --capabilities 2>&1) || {
    check_reason=$(router_planning_reason "$caps")
    router_planning_alert "runner capabilities unavailable: $check_reason" netcup sol-plan@pi
    router_planning_alert "runner capabilities unavailable: $check_reason" bosgame muse-wonder-plan@muse
    router_planning_alert "runner capabilities unavailable: $check_reason" netcup kimi-k3-plan@pi
    return 0
  }
  # hard_token_cap is intentionally not required: this runner enforces the
  # 300k/pass and 1M/day limits with wall-clock/accounting when the harness
  # cannot pass a native token cap.
  python3 -c 'import json,sys; x=json.loads(sys.argv[1]); assert x["v"] == 1 and {"netcup","bosgame"}.issubset(x["hosts"])' "$caps" 2>/dev/null || {
    router_planning_alert "runner capabilities invalid" none none; return 0; }
  task=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["task"])' "$request")
  after_binding=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("after_binding", ""))' "$request")
  live=$(python3 - "$request" "$CLONE/.beads/issues.jsonl" "$B" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[3])
import refill_lib_v2 as R
req=json.load(open(sys.argv[1])); rows={r['id']:r for r in map(json.loads, open(sys.argv[2]))}
selected=[rows[i] for i in req['rows']]
assert selected and all(isinstance(r.get('labels'),list) and all(isinstance(x,str) for x in r['labels']) for r in selected)
print('yes' if any(R.cred_label(r['labels']) or R.cred_match(str(r.get('title',''))+' '+str(r.get('description',''))) for r in selected) else 'no')
PY
) || { router_planning_alert "missing task labels" none none; say "PLANNING WAIT: missing task labels"; return 0; }
  # Route and check availability before the controller reserves 300k.  Failed
  # checks have not launched a pass, so their admission can safely be cancelled
  # before trying the next member of the fixed cross-host chain.
  local selected=0 candidate_host candidate_binding candidate_index skip_until="$after_binding"
  # The first chain member is the exact historical call:
  # route_leaf netcup "$task" "$live" plan plan sol-plan@pi
  for candidate_index in 1 2 3; do
    case "$candidate_index" in
      1) candidate_host=netcup; candidate_binding=sol-plan@pi ;;
      2) candidate_host=bosgame; candidate_binding=muse-wonder-plan@muse ;;
      3) candidate_host=netcup; candidate_binding=kimi-k3-plan@pi ;;
    esac
    if [ -n "$skip_until" ]; then
      [ "$candidate_binding" = "$skip_until" ] || continue
      skip_until=
      continue
    fi
    if ! route_leaf "$candidate_host" "$task" "$live" plan plan "$candidate_binding"; then
      router_planning_alert "route admission unavailable" "$candidate_host" "$candidate_binding"
      continue
    fi
    check_out=$("${runner[@]}" --check --host "$RA_HOST" --harness "$RA_HARNESS" --model "$RA_MODEL" \
      --effort high --max-tokens 300000 --home "$H" 2>&1); rc=$?
    if [ "$rc" != 0 ]; then
      check_reason=$(printf '%s' "$check_out" | tr '\r\n' ' ' | cut -c1-240)
      [ -n "$check_reason" ] || check_reason="runner check exit $rc"
      router_planning_alert "$check_reason" "$RA_HOST" "$RA_MODEL"
      router_cancel "$task"
      continue
    fi
    selected=2
    break
  done
  if [ "$selected" != 2 ]; then
    router_planning_alert "planning model chain exhausted" none "${after_binding:-none}"
    return 0
  fi
  router_prelaunch || { router_cancel "$task"; router_planning_alert "prelaunch unavailable" "$RA_HOST" "$RA_MODEL"; return 0; }
  controller_err="$H/state/planning-controller-reserve.err"
  python3 "$B/router_planning_v31.py" reserve --home "$H" --request "$request" \
    --binding "$RA_BINDING" --model "$RA_MODEL" --host "$RA_HOST" --incarnation "$RA_INCARNATION" \
    > /dev/null 2>"$controller_err"; rc=$?
  if [ "$rc" != 0 ]; then
    router_cancel "$task"; router_planning_alert "reservation failed: $(router_planning_reason "$(cat "$controller_err")")" "$RA_HOST" "$RA_MODEL"; say "PLANNING WAIT: reservation failed"; return 0
  fi
  mkdir -p "$H/data/$task"
  # Keep the immutable request and the ownership record beside this task.
  cp -- "$request" "$H/data/$task/planning-request.json"
  request="$H/data/$task/planning-request.json"
  python3 - "$request" "$H/data/$task" <<'PYREQ'
import json, sys
from pathlib import Path
r=json.load(open(sys.argv[1])); d=Path(sys.argv[2])
(d/'partition').write_text(r['partition']+'\n')
(d/'claim-rows').write_text('\n'.join(r['rows'])+'\n')
PYREQ
  fresh_gate
  if [ "$sn" -le 0 ] || ! router_prelaunch; then
    if python3 "$B/router_planning_v31.py" fail --home "$H" --task "$task" \
      --incarnation "$RA_INCARNATION" --reason "shutdown/capacity before launch" --tokens 0 >/dev/null; then
      router_cancel "$task"
      router_planning_alert "shutdown/capacity before launch" "$RA_HOST" "$RA_MODEL"
    else
      router_planning_alert "shutdown/capacity release failed" "$RA_HOST" "$RA_MODEL"
      router_ambiguous "$task" "planning-prelaunch-release-failed-$RA_INCARNATION" || return 1
      say "PLANNING WAIT: shutdown/capacity reservation retained for reconciliation"
    fi
    return 0
  fi
  # Runner starts one scoped tracker-only pass and returns immediately with a
  # fresh endpoint. It writes usage/failure evidence asynchronously; the
  # controller separately validates the landed planning-result trailer.
  out=$("${runner[@]}" --start --task "$task" --project "$CLONE" --host "$RA_HOST" \
    --request "$request" --max-tokens 300000 \
    --incarnation "$RA_INCARNATION" --home "$H" "${ROUTE_ARGV[@]}" 2>&1); rc=$?
  local alive_runner="${runner[0]}"
  if [ "${#runner[@]}" -gt 1 ]; then
    alive_runner="$H/state/planning-runner-alive.sh"
    printf '%s\n' '#!/usr/bin/env bash' "exec python3 '$B/router_planning_runner_v31.py' \"\$@\"" > "$alive_runner"
    chmod 700 "$alive_runner"
  fi
  if [ "$rc" = 0 ] && ROUTER_ALIVE_CMD="$alive_runner" FM_PLANNING_HOME="$H" router_confirm_verified "$task" "$out"; then
    one_start || return 1
    free=$((free>0 ? free-1 : 0)); pfree=$((pfree-1)); planw=$((planw+1))
    say "PLANNING verified $task ($RA_MODEL; token budget 300000)"
  elif [ "$rc" = 75 ]; then
    # Exit 75 is the runner's explicit proof that no endpoint was started;
    # release this controller reservation before trying the next chain member.
    if python3 "$B/router_planning_v31.py" fail --home "$H" --task "$task" \
      --incarnation "$RA_INCARNATION" --reason "runner refused before launch" --tokens 0 >/dev/null; then
      router_cancel "$task"
      router_planning_alert "runner refused before launch" "$RA_HOST" "$RA_MODEL"
      if [ "${PLANNING_CHAIN_DEPTH:-0}" -lt 3 ]; then
        PLANNING_CHAIN_DEPTH=$((${PLANNING_CHAIN_DEPTH:-0}+1)) router_planning_tick
      fi
    else
      router_ambiguous "$task" "planning-release-failed-$RA_INCARNATION" || return 1
      router_planning_alert "runner refusal release failed" "$RA_HOST" "$RA_MODEL"
      say "PLANNING WAIT: runner refusal could not release reservation; reconciliation required"
    fi
  else
    router_ambiguous "$task" "planning-unverified-$RA_INCARNATION" || return 1
    router_planning_alert "unverified runner launch: $(router_planning_reason "$out")" "$RA_HOST" "$RA_MODEL"
    say "PLANNING WAIT: unverified runner launch; admission and token reservation retained for chief reconciliation"
  fi
}
