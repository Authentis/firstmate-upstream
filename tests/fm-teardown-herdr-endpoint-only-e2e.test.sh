#!/usr/bin/env bash
# Real-Herdr regressions for finished task panes no cleanup could close.
#
# Two finished-task shapes kept idle Herdr panes open indefinitely:
# - a completed scout whose record no longer names an isolated copy, because
#   the copy was already removed after its pool slot was legitimately reused,
#   so the shared endpoint validator refused the ordinary cleanup outright;
# - a finished task whose record must stay (committed work not yet landed, or
#   no recorded copy at all), so the ordinary cleanup rightly refuses and the
#   pane had no owner that could close it on its own.
# Ordinary teardown now finishes the first shape, and teardown --endpoint-only
# closes only the pane of the second while keeping every record, the copy, the
# branch, and the backlog item. Every retention case must keep its pane: a live
# agent, an open decision, uncommitted changes, and an unfinished validation run.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"

herdr_forget_inherited_pane
fm_live_gate default-on FM_TEARDOWN_HERDR_ENDPOINT_ONLY_E2E herdr jq tasks-axi git

HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
[ -x "$HERDR_LAB_HELPER" ] || { echo "skip: live: Herdr lab helper not executable at $HERDR_LAB_HELPER"; exit 0; }

HERDR_ORIGINAL_PATH=$PATH
TMP_ROOT=$(fm_test_tmproot fm-teardown-herdr-endpoint-only-e2e)
FAKEBIN="$TMP_ROOT/fakebin"
HOME_DIR="$TMP_ROOT/home"
PROJECT="$TMP_ROOT/project"
BACKLOG="$HOME_DIR/data/backlog.md"
mkdir -p "$FAKEBIN" "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config" "$PROJECT"

HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-teardown-endpoint-only)
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

lab() { env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }
pane_present() { lab pane get "$1" >/dev/null 2>&1; }
row_state() { tasks-axi show "$1" --file "$BACKLOG" 2>/dev/null | sed -n 's/^  state: *//p' | head -1; }
run_fm() {  # <script> [args...]
  local script=$1
  shift
  env -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    HERDR_SESSION="$HERDR_LAB_SESSION" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    FM_BOOTSTRAP_NETWORK=skip PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" \
    "$ROOT/bin/$script" "$@"
}
fingerprint() {  # <task-id>: every durable record the endpoint-only close must keep
  cat "$HOME_DIR/state/$1.meta" "$HOME_DIR/state/$1.status" 2>/dev/null | cksum
}

git -C "$PROJECT" init -q -b main
git -C "$PROJECT" -c user.name=test -c user.email=test@example.invalid commit -q --allow-empty -m base

CREATE=$(lab workspace create --cwd "$PROJECT" --label endpoint-only-lab --no-focus) \
  || fail "could not create the lab workspace"
WS=$(printf '%s' "$CREATE" | jq -er '.result.workspace.workspace_id') \
  || fail "could not read the lab workspace id"
CONTROL=$(printf '%s' "$CREATE" | jq -er '.result.root_pane.pane_id') \
  || fail "could not read the lab control pane id"

printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$BACKLOG"
printf '%s\n' 'backend = "markdown"' '' '[markdown]' 'path = "data/backlog.md"' > "$HOME_DIR/.tasks.toml"

# new_task <id> <kind> [worktree]: an idle task pane in its own tab, a backlog
# item in flight, and the task record naming that pane; sets PANE.
new_task() {
  local id=$1 kind=$2 worktree=${3:-} tab_out tab
  tab_out=$(lab tab create --workspace "$WS" --cwd "$PROJECT" --label "fm-$id" --no-focus) \
    || fail "could not create the tab for $id"
  tab=$(printf '%s' "$tab_out" | jq -er '.result.tab.tab_id') || fail "could not read the tab id for $id"
  PANE=$(printf '%s' "$tab_out" | jq -er '.result.root_pane.pane_id // .result.pane.pane_id') \
    || fail "could not read the pane id for $id"
  tasks-axi add "$id" "item for $id" --kind "$kind" --file "$BACKLOG" >/dev/null
  tasks-axi start "$id" --file "$BACKLOG" >/dev/null
  fm_write_meta "$HOME_DIR/state/$id.meta" \
    "window=$HERDR_LAB_SESSION:$PANE" "backend=herdr" "endpoint_task_id=$id" \
    "herdr_session=$HERDR_LAB_SESSION" "herdr_workspace_id=$WS" \
    "herdr_tab_id=$tab" "herdr_pane_id=$PANE" \
    "project=$PROJECT" "kind=$kind" "mode=no-mistakes" "spawn_gen=spawn-$id"
  [ -z "$worktree" ] || printf 'worktree=%s\n' "$worktree" >> "$HOME_DIR/state/$id.meta"
  printf 'working [at=1]: started\n' > "$HOME_DIR/state/$id.status"
}

# new_copy <id>: an isolated copy on fm/<id> holding one committed change that
# has landed nowhere; prints its path.
new_copy() {
  local id=$1 wt="$TMP_ROOT/copies/$1"
  mkdir -p "$TMP_ROOT/copies"
  git -C "$PROJECT" worktree add -q -b "fm/$id" "$wt" main
  printf 'restore tip\n' > "$wt/work.txt"
  git -C "$wt" add work.txt
  git -C "$wt" -c user.name=test -c user.email=test@example.invalid commit -qm "unlanded work"
  printf '%s\n' "$wt"
}

assert_endpoint_only_refused() {  # <id> <pane> <why> <expected refusal> [VAR=value]
  local id=$1 pane=$2 why=$3 expect=$4 extra=${5:-} before rc=0 out
  before=$(fingerprint "$id")
  out=$(
    [ -z "$extra" ] || export "${extra?}"
    run_fm fm-teardown.sh "$id" --endpoint-only 2>&1
  ) || rc=$?
  [ "$rc" -ne 0 ] || fail "--endpoint-only reported success for a task with $why: $out"
  case "$out" in
    *"$expect"*) ;;
    *) fail "--endpoint-only refused a task with $why for another reason, so this case proves nothing: $out" ;;
  esac
  pane_present "$pane" || fail "--endpoint-only closed the pane of a task with $why: $out"
  [ "$(fingerprint "$id")" = "$before" ] || fail "--endpoint-only changed the records of a task with $why: $out"
  [ "$(row_state "$id")" = in_flight ] || fail "--endpoint-only moved the backlog item of a task with $why: $out"
  pass "live herdr: --endpoint-only keeps the pane of a task with $why"
}

# 1. A completed scout whose record names no copy: ordinary cleanup finishes it.
SCOUT=scout-copy-gone
new_task "$SCOUT" scout
SCOUT_PANE=$PANE
printf 'decisions_reviewed=1\n' >> "$HOME_DIR/state/$SCOUT.meta"
mkdir -p "$HOME_DIR/data/$SCOUT"
printf '# Report\n\nFindings.\n' > "$HOME_DIR/data/$SCOUT/report.md"
out=$(run_fm fm-teardown.sh "$SCOUT" 2>&1) || fail "cleanup of a completed scout whose copy is gone refused: $out"
pane_present "$SCOUT_PANE" && fail "cleanup of a completed scout whose copy is gone left its pane open: $out"
pane_present "$CONTROL" || fail "the scout cleanup closed an unrelated pane"
assert_absent "$HOME_DIR/state/$SCOUT.meta" "the scout cleanup left its task record behind"
[ "$(row_state "$SCOUT")" = "done" ] || fail "the scout cleanup did not close its backlog item: $out"
pass "live herdr: ordinary cleanup closes a completed scout's pane when its copy is already gone"

# 2. A finished ship whose committed work has landed nowhere: ordinary cleanup
#    keeps everything, and --endpoint-only closes only the pane.
CUSTODY=ship-custody
CUSTODY_WT=$(new_copy "$CUSTODY")
new_task "$CUSTODY" ship "$CUSTODY_WT"
CUSTODY_PANE=$PANE
rc=0
out=$(run_fm fm-teardown.sh "$CUSTODY" 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail "ordinary cleanup discarded a copy holding unlanded work: $out"
case "$out" in
  *REFUSED*) ;;
  *) fail "ordinary cleanup of a copy holding unlanded work failed without a refusal: $out" ;;
esac
pane_present "$CUSTODY_PANE" || fail "the refused cleanup closed the pane, so this case proves nothing"
BEFORE=$(fingerprint "$CUSTODY")
BRANCH_TIP=$(git -C "$PROJECT" rev-parse "fm/$CUSTODY")
out=$(run_fm fm-teardown.sh "$CUSTODY" --endpoint-only 2>&1) || fail "--endpoint-only refused a finished task under custody: $out"
pane_present "$CUSTODY_PANE" && fail "--endpoint-only left the finished task's pane open: $out"
pane_present "$CONTROL" || fail "--endpoint-only closed an unrelated pane"
[ "$(fingerprint "$CUSTODY")" = "$BEFORE" ] || fail "--endpoint-only changed the task's records"
[ -f "$CUSTODY_WT/work.txt" ] || fail "--endpoint-only touched the isolated copy"
[ "$(git -C "$PROJECT" rev-parse "fm/$CUSTODY")" = "$BRANCH_TIP" ] || fail "--endpoint-only moved the task branch"
[ "$(row_state "$CUSTODY")" = in_flight ] || fail "--endpoint-only moved the backlog item"
pass "live herdr: --endpoint-only closes a finished pane and keeps the record, copy, branch, and backlog item"
out=$(run_fm fm-teardown.sh "$CUSTODY" --endpoint-only 2>&1) || fail "a repeated --endpoint-only failed on an already-gone pane: $out"
[ "$(fingerprint "$CUSTODY")" = "$BEFORE" ] || fail "a repeated --endpoint-only changed the task's records"
pass "live herdr: --endpoint-only is idempotent once the pane is gone"

# 3. A finished ship whose record names no copy: ordinary cleanup still refuses,
#    and --endpoint-only closes only the pane.
NOCOPY=ship-copy-gone
new_task "$NOCOPY" ship
NOCOPY_PANE=$PANE
rc=0
out=$(run_fm fm-teardown.sh "$NOCOPY" 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail "ordinary cleanup removed a ship record that names no copy: $out"
case "$out" in
  *"worktree identity"*) ;;
  *) fail "ordinary cleanup of a ship record that names no copy refused for another reason: $out" ;;
esac
pane_present "$NOCOPY_PANE" || fail "the refused cleanup closed the pane, so this case proves nothing"
BEFORE=$(fingerprint "$NOCOPY")
out=$(run_fm fm-teardown.sh "$NOCOPY" --endpoint-only 2>&1) || fail "--endpoint-only refused a finished task whose copy is gone: $out"
pane_present "$NOCOPY_PANE" && fail "--endpoint-only left the pane of a task whose copy is gone open: $out"
[ "$(fingerprint "$NOCOPY")" = "$BEFORE" ] || fail "--endpoint-only changed the records of a task whose copy is gone"
pass "live herdr: --endpoint-only closes the pane of a finished task whose copy is already gone"

# 4. Retention: a live agent.
LIVE=ship-live-agent
new_task "$LIVE" ship "$(new_copy "$LIVE")"
LIVE_PANE=$PANE
lab pane run "$LIVE_PANE" "sleep 600" >/dev/null || fail "could not start a foreground process in the live pane"
lab pane report-agent "$LIVE_PANE" --source fm-endpoint-only-e2e --agent fm-endpoint-only-agent --state working >/dev/null \
  || fail "could not register a live agent on the pane"
assert_endpoint_only_refused "$LIVE" "$LIVE_PANE" "a live agent" "still reads 'alive'"

# 5. Retention: an open decision.
DECIDE=ship-open-decision
new_task "$DECIDE" ship "$(new_copy "$DECIDE")"
DECIDE_PANE=$PANE
printf 'needs-decision [key=choose-path] [at=2]: choose the restore path\n' >> "$HOME_DIR/state/$DECIDE.status"
assert_endpoint_only_refused "$DECIDE" "$DECIDE_PANE" "an open decision" "choose-path"

# 6. Retention: uncommitted changes.
DIRTY=ship-uncommitted
DIRTY_WT=$(new_copy "$DIRTY")
new_task "$DIRTY" ship "$DIRTY_WT"
DIRTY_PANE=$PANE
printf 'not committed\n' >> "$DIRTY_WT/work.txt"
assert_endpoint_only_refused "$DIRTY" "$DIRTY_PANE" "uncommitted changes" "has uncommitted changes"

# 7. Retention: an unfinished validation run on the task branch.
VALIDATE=ship-validating
new_task "$VALIDATE" ship "$(new_copy "$VALIDATE")"
VALIDATE_PANE=$PANE
assert_endpoint_only_refused "$VALIDATE" "$VALIDATE_PANE" "an unfinished validation run" \
  "validation run on fm/$VALIDATE has not finished" "FM_TEST_NM_BRANCH=fm/$VALIDATE"
