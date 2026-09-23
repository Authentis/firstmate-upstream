#!/usr/bin/env bash
# Real-Herdr regression: closing a task's agent retires its unused pane.
#
# The captain-visible failure: an agent closed through the supported exit verb
# left its Herdr pane open as an idle shell, because exit preserved every
# endpoint and nothing then handed the pane to the one owner able to close it
# safely (bin/fm-teardown.sh --endpoint-only). The pane stayed until someone
# remembered a second command, so closed agents accumulated visible panes.
#
# exit on a Herdr ship or scout now hands the stopped pane to that owner, so a
# proven closed, unused pane is gone afterward with the record, copy, branch,
# and backlog item kept. Every retention case keeps its pane: a live agent
# exit cannot prove stopped, unlanded work not yet preserved in any commit, an
# unfinished validation run, and an open decision.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"

herdr_forget_inherited_pane
fm_live_gate default-on FM_CONTROL_HERDR_EXIT_RETIRE_E2E herdr jq tasks-axi git

HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
[ -x "$HERDR_LAB_HELPER" ] || { echo "skip: live: Herdr lab helper not executable at $HERDR_LAB_HELPER"; exit 0; }

HERDR_ORIGINAL_PATH=$PATH
TMP_ROOT=$(fm_test_tmproot fm-control-herdr-exit-retire-e2e)
FAKEBIN="$TMP_ROOT/fakebin"
AGENT_BIN="$TMP_ROOT/agentbin"
HOME_DIR="$TMP_ROOT/home"
PROJECT="$TMP_ROOT/project"
BACKLOG="$HOME_DIR/data/backlog.md"
mkdir -p "$FAKEBIN" "$AGENT_BIN" "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config" "$PROJECT"

HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-control-exit-retire)
export HERDR_LAB_HELPER HERDR_LAB_SESSION HERDR_ORIGINAL_PATH

cleanup() {
  local status=$?
  env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=1
  fm_test_cleanup
  exit "$status"
}
trap cleanup EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"

# Every Herdr call reaches only the lab through its guarded helper.
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@")
last=$((${#args[@]} - 1))
flag=$((last - 1))
if [ "${#args[@]}" -ge 2 ] \
  && [ "${args[$flag]}" = --session ] \
  && [ "${args[$last]}" = "$HERDR_LAB_SESSION" ]; then
  unset "args[$last]" "args[$flag]"
fi
set -- "${args[@]}"
for arg in "$@"; do
  case "$arg" in --session|--session=*) exit 9 ;; esac
done
exec env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
SH
# A validation run still under way on FM_TEST_NM_BRANCH; no run otherwise.
cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
[ -n "${FM_TEST_NM_BRANCH:-}" ] && [ "${1:-}" = axi ] && [ "${2:-}" = status ] || exit 1
printf 'run:\n  id: run-under-way\n  branch: %s\n  status: running\n' "$FM_TEST_NM_BRANCH"
SH
chmod +x "$FAKEBIN/herdr" "$FAKEBIN/no-mistakes"
# A real agent-named foreground process: the same process identity the Herdr
# adapter proves through pane process-info (tests/fm-control-herdr-smoke.test.sh).
ln -s "$(command -v sleep)" "$AGENT_BIN/claude"

lab() { env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }
pane_present() { lab pane get "$1" >/dev/null 2>&1; }
row_state() { tasks-axi show "$1" --file "$BACKLOG" 2>/dev/null | sed -n 's/^  state: *//p' | head -1; }
run_control() {  # <task-id> <verb> [VAR=value]
  local id=$1 verb=$2 extra=${3:-}
  (
    [ -z "$extra" ] || export "${extra?}"
    env -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
      HERDR_SESSION="$HERDR_LAB_SESSION" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
      FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=2 PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" \
      "$ROOT/bin/fm-control.sh" "$id" "$verb" 2>&1
  )
}
fingerprint() {  # <task-id>: every durable record the pane retirement must keep
  cat "$HOME_DIR/state/$1.meta" "$HOME_DIR/state/$1.status" 2>/dev/null | cksum
}
process_state() {  # <pane>
  lab pane process-info --pane "$1" 2>/dev/null \
    | jq -r '[.result.process_info.foreground_processes[]?.argv0 | tostring | split("/") | last] | join(",")'
}

git -C "$PROJECT" init -q -b main
git -C "$PROJECT" -c user.name=test -c user.email=test@example.invalid commit -q --allow-empty -m base

CREATE=$(lab workspace create --cwd "$PROJECT" --label exit-retire-lab --no-focus) \
  || fail "could not create the lab workspace"
WS=$(printf '%s' "$CREATE" | jq -er '.result.workspace.workspace_id') \
  || fail "could not read the lab workspace id"
CONTROL=$(printf '%s' "$CREATE" | jq -er '.result.root_pane.pane_id') \
  || fail "could not read the lab control pane id"

printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$BACKLOG"
printf '%s\n' 'backend = "markdown"' '' '[markdown]' 'path = "data/backlog.md"' > "$HOME_DIR/.tasks.toml"

# new_task <id>: an isolated copy on fm/<id> holding one committed change that
# has landed nowhere, a task pane in its own tab running in that copy, a
# backlog item in flight, and the task record; sets PANE and WT.
new_task() {
  local id=$1 tab_out tab
  WT="$TMP_ROOT/copies/$id"
  mkdir -p "$TMP_ROOT/copies"
  git -C "$PROJECT" worktree add -q -b "fm/$id" "$WT" main
  printf 'restore tip\n' > "$WT/work.txt"
  git -C "$WT" add work.txt
  git -C "$WT" -c user.name=test -c user.email=test@example.invalid commit -qm "unlanded work"
  tab_out=$(lab tab create --workspace "$WS" --cwd "$WT" --label "fm-$id" --no-focus) \
    || fail "could not create the tab for $id"
  tab=$(printf '%s' "$tab_out" | jq -er '.result.tab.tab_id') || fail "could not read the tab id for $id"
  PANE=$(printf '%s' "$tab_out" | jq -er '.result.root_pane.pane_id // .result.pane.pane_id') \
    || fail "could not read the pane id for $id"
  tasks-axi add "$id" "item for $id" --kind ship --file "$BACKLOG" >/dev/null
  tasks-axi start "$id" --file "$BACKLOG" >/dev/null
  fm_write_meta "$HOME_DIR/state/$id.meta" \
    "window=$HERDR_LAB_SESSION:$PANE" "backend=herdr" "endpoint_task_id=$id" \
    "herdr_session=$HERDR_LAB_SESSION" "herdr_workspace_id=$WS" \
    "herdr_tab_id=$tab" "herdr_pane_id=$PANE" "worktree=$WT" \
    "project=$PROJECT" "harness=claude" "kind=ship" "mode=no-mistakes" "spawn_gen=spawn-$id"
  printf 'working [at=1]: started\n' > "$HOME_DIR/state/$id.status"
}

# start_agent <pane>: a registered agent over a live agent-named process.
start_agent() {
  local pane=$1
  printf -v agent_q '%q' "$AGENT_BIN/claude"
  lab pane run "$pane" "$agent_q 900" >/dev/null || fail "could not start the agent process in $pane"
  for _ in $(seq 1 150); do
    case "$(process_state "$pane")" in *claude*) break ;; esac
    sleep 0.1
  done
  case "$(process_state "$pane")" in
    *claude*) ;;
    *) fail "the agent-named process never became the foreground of $pane" ;;
  esac
  lab pane report-agent "$pane" --source fm-exit-retire-e2e --agent fm-exit-retire-agent --state idle >/dev/null \
    || fail "could not register the agent on $pane"
}

# close_agent <pane>: the agent process ends and the pane falls back to its
# shell, while Herdr keeps the registration - the shape a closed agent leaves.
close_agent() {
  local pane=$1 pid
  pid=$(lab pane process-info --pane "$pane" 2>/dev/null \
    | jq -r '.result.process_info.foreground_processes[0].pid // empty')
  [ -n "$pid" ] || fail "could not read the agent process in $pane"
  kill "$pid" 2>/dev/null || fail "could not stop the agent process in $pane"
  for _ in $(seq 1 50); do
    case "$(process_state "$pane")" in *claude*) ;; *) return 0 ;; esac
    sleep 0.1
  done
  fail "the agent process in $pane did not end"
}

assert_pane_kept() {  # <id> <pane> <why> <expected text> [VAR=value]
  local id=$1 pane=$2 why=$3 expect=$4 extra=${5:-} before out
  before=$(fingerprint "$id")
  out=$(run_control "$id" exit "$extra") || fail "exit failed for a closed agent with $why: $out"
  case "$out" in
    "already-stopped $id"*) ;;
    *) fail "exit did not report the closed agent with $why as stopped: $out" ;;
  esac
  case "$out" in
    *"$expect"*) ;;
    *) fail "exit kept the pane of a task with $why for another reason, so this case proves nothing: $out" ;;
  esac
  pane_present "$pane" || fail "exit closed the pane of a task with $why: $out"
  [ "$(fingerprint "$id")" = "$before" ] || fail "exit changed the records of a task with $why: $out"
  [ "$(row_state "$id")" = in_flight ] || fail "exit moved the backlog item of a task with $why: $out"
  pass "live herdr: exit keeps the pane of a closed agent with $why"
}

# 1. The captain-visible symptom: an agent in an isolated task's pane closes,
#    the supported exit completes, and the pane must be gone afterward.
DONE=ship-agent-closed
new_task "$DONE"
DONE_PANE=$PANE
DONE_WT=$WT
start_agent "$DONE_PANE"
close_agent "$DONE_PANE"
BEFORE=$(fingerprint "$DONE")
BRANCH_TIP=$(git -C "$PROJECT" rev-parse "fm/$DONE")
out=$(run_control "$DONE" exit) || fail "exit failed for a closed agent: $out"
case "$out" in
  "already-stopped $DONE"*) ;;
  *) fail "exit did not report the closed agent as stopped: $out" ;;
esac
pane_present "$DONE_PANE" && fail "a closed agent's pane is still open after exit: $out"
pane_present "$CONTROL" || fail "exit closed an unrelated pane"
[ "$(fingerprint "$DONE")" = "$BEFORE" ] || fail "retiring the pane changed the task's records"
[ -f "$DONE_WT/work.txt" ] || fail "retiring the pane touched the isolated copy"
[ "$(git -C "$PROJECT" rev-parse "fm/$DONE")" = "$BRANCH_TIP" ] || fail "retiring the pane moved the task branch"
[ "$(row_state "$DONE")" = in_flight ] || fail "retiring the pane moved the backlog item"
pass "live herdr: exit retires a closed agent's unused pane and keeps the record, copy, branch, and backlog item"
out=$(run_control "$DONE" exit) || fail "a repeated exit failed once the pane was gone: $out"
case "$out" in
  "endpoint-gone $DONE"*) ;;
  *) fail "a repeated exit did not report the retired pane as gone: $out" ;;
esac
[ "$(fingerprint "$DONE")" = "$BEFORE" ] || fail "a repeated exit changed the task's records"
pass "live herdr: exit stays idempotent once the pane is retired"

# 2. Retention: a live agent exit cannot prove stopped keeps its pane.
LIVE=ship-live-agent
new_task "$LIVE"
LIVE_PANE=$PANE
start_agent "$LIVE_PANE"
BEFORE=$(fingerprint "$LIVE")
rc=0
out=$(run_control "$LIVE" exit) || rc=$?
[ "$rc" -ne 0 ] || fail "exit claimed to stop an agent whose composer is not proven empty: $out"
case "$out" in
  *"not proven empty"*) ;;
  *) fail "exit refused the live agent for another reason, so this case proves nothing: $out" ;;
esac
pane_present "$LIVE_PANE" || fail "exit closed the pane of a live agent: $out"
[ "$(fingerprint "$LIVE")" = "$BEFORE" ] || fail "exit changed the records of a live agent"
pass "live herdr: a live agent's pane survives an exit that cannot prove it stopped"

# 3. Retention: unlanded work not yet preserved in any commit.
UNIQUE=ship-unlanded-uncommitted
new_task "$UNIQUE"
UNIQUE_PANE=$PANE
printf 'only copy\n' > "$WT/draft.txt"
start_agent "$UNIQUE_PANE"
close_agent "$UNIQUE_PANE"
assert_pane_kept "$UNIQUE" "$UNIQUE_PANE" "unlanded uncommitted work" "has uncommitted changes"

# 4. Retention: an unfinished validation run on the task branch.
VALIDATE=ship-validating
new_task "$VALIDATE"
VALIDATE_PANE=$PANE
start_agent "$VALIDATE_PANE"
close_agent "$VALIDATE_PANE"
assert_pane_kept "$VALIDATE" "$VALIDATE_PANE" "an unfinished validation run" \
  "validation run on fm/$VALIDATE has not finished" "FM_TEST_NM_BRANCH=fm/$VALIDATE"

# 5. Retention: an open decision.
DECIDE=ship-open-decision
new_task "$DECIDE"
DECIDE_PANE=$PANE
printf 'needs-decision [key=choose-path] [at=2]: choose the restore path\n' >> "$HOME_DIR/state/$DECIDE.status"
start_agent "$DECIDE_PANE"
close_agent "$DECIDE_PANE"
assert_pane_kept "$DECIDE" "$DECIDE_PANE" "an open decision" "choose-path"
