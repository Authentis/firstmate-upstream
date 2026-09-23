#!/usr/bin/env bash
# Real-Herdr regression for the stale task pane no lifecycle owner could close.
#
# A cleanup whose Herdr pane close did not happen keeps the task record, the
# only thing naming that pane, while its recorded backlog close stays pending.
# Session start used to replay that close past the still-present record and
# delete it, leaving an idle task pane that no record named, so neither
# teardown nor any other supported lifecycle owner could ever close it again.
# This drives the real teardown and session start against a real pane in an
# isolated Herdr lab: the record must survive session start while the pane is
# open, and the ordinary rerun must close the pane and land the close.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"

herdr_forget_inherited_pane
fm_live_gate default-on FM_TEARDOWN_HERDR_RESTART_E2E herdr jq tasks-axi

HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
[ -x "$HERDR_LAB_HELPER" ] || { echo "skip: live: Herdr lab helper not executable at $HERDR_LAB_HELPER"; exit 0; }

HERDR_ORIGINAL_PATH=$PATH
TMP_ROOT=$(fm_test_tmproot fm-teardown-herdr-restart-e2e)
FAKEBIN="$TMP_ROOT/fakebin"
HOME_DIR="$TMP_ROOT/home"
PROJECT="$TMP_ROOT/project"
ID=herdr-restart-task
BACKLOG="$HOME_DIR/data/backlog.md"
mkdir -p "$FAKEBIN" "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config" "$PROJECT"

HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-teardown-restart)
export HERDR_LAB_HELPER HERDR_LAB_SESSION HERDR_ORIGINAL_PATH

cleanup() {
  local status=$?
  env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=1
  fm_test_cleanup
  exit "$status"
}
trap cleanup EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"

# Every Herdr call reaches only the lab through its guarded helper. A set
# FM_TEST_BLOCK_PANE_CLOSE makes the pane close request fail the way a refused
# or failed close does, leaving the real pane open.
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
if [ -n "${FM_TEST_BLOCK_PANE_CLOSE:-}" ] && [ "${1:-}" = pane ] && [ "${2:-}" = close ]; then
  echo "pane close blocked by the test" >&2
  exit 1
fi
exec env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
SH
chmod +x "$FAKEBIN/herdr"

lab() { env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }
pane_present() { lab pane get "$1" >/dev/null 2>&1; }
row_state() { tasks-axi show "$ID" --file "$BACKLOG" 2>/dev/null | sed -n 's/^  state: *//p' | head -1; }
run_fm() {  # <script> [args...]
  local script=$1
  shift
  env -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    HERDR_SESSION="$HERDR_LAB_SESSION" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    FM_BOOTSTRAP_NETWORK=skip PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" \
    "$ROOT/bin/$script" "$@"
}

# The lab's root pane stands in for the supervisor; the task gets its own tab,
# an idle shell like every stale task pane the fleet accumulated.
CREATE=$(lab workspace create --cwd "$PROJECT" --label restart-lab --no-focus) \
  || fail "could not create the lab workspace"
WS=$(printf '%s' "$CREATE" | jq -er '.result.workspace.workspace_id') \
  || fail "could not read the lab workspace id"
CONTROL=$(printf '%s' "$CREATE" | jq -er '.result.root_pane.pane_id') \
  || fail "could not read the lab control pane id"
TAB_OUT=$(lab tab create --workspace "$WS" --cwd "$PROJECT" --label "fm-$ID" --no-focus) \
  || fail "could not create the task tab"
TAB=$(printf '%s' "$TAB_OUT" | jq -er '.result.tab.tab_id') || fail "could not read the task tab id"
PANE=$(printf '%s' "$TAB_OUT" | jq -er '.result.root_pane.pane_id // .result.pane.pane_id') \
  || fail "could not read the task pane id"

printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$BACKLOG"
printf '%s\n' 'backend = "markdown"' '' '[markdown]' 'path = "data/backlog.md"' > "$HOME_DIR/.tasks.toml"
tasks-axi add "$ID" "item for $ID" --kind ship --file "$BACKLOG" >/dev/null
tasks-axi start "$ID" --file "$BACKLOG" >/dev/null
fm_write_meta "$HOME_DIR/state/$ID.meta" \
  "window=$HERDR_LAB_SESSION:$PANE" "backend=herdr" "endpoint_task_id=$ID" \
  "herdr_session=$HERDR_LAB_SESSION" "herdr_workspace_id=$WS" \
  "herdr_tab_id=$TAB" "herdr_pane_id=$PANE" \
  "worktree=$TMP_ROOT/absent-worktree" "project=$TMP_ROOT/absent-project" \
  "kind=ship" "mode=no-mistakes" "spawn_gen=spawn-$ID"

# 1. The cleanup cannot close the pane: it keeps the record and its recorded close.
rc=0
out=$(FM_TEST_BLOCK_PANE_CLOSE=1 run_fm fm-teardown.sh "$ID" 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail "teardown reported success though the pane close was blocked: $out"
pane_present "$PANE" || fail "the task pane closed despite the blocked close, so this case proves nothing"
assert_present "$HOME_DIR/state/$ID.meta" "the refused cleanup removed the record naming the open pane"
assert_present "$HOME_DIR/state/$ID.backlog-close" \
  "the case never reached the recorded close, so it cannot prove the restart hazard"
pass "live herdr: a cleanup that could not close the task pane keeps its record and recorded close"

# 2. Session start keeps the record while the pane is still open.
out=$(run_fm fm-bootstrap.sh 2>&1) || true
pane_present "$PANE" || fail "the task pane disappeared at session start, so this case proves nothing"
assert_present "$HOME_DIR/state/$ID.meta" \
  "session start removed the only record naming a still-open Herdr task pane: $out"
[ "$(row_state)" = in_flight ] || fail "session start closed the item while its pane was still open: $out"
case "$out" in
  *"rerun bin/fm-teardown.sh $ID"*) ;;
  *) fail "session start did not name the rerun that closes the pane: $out" ;;
esac
pass "live herdr: session start keeps the record of a still-open task pane and names the rerun"

# 3. The ordinary rerun closes the real pane and lands the close.
out=$(run_fm fm-teardown.sh "$ID" 2>&1) || fail "the rerun after session start failed: $out"
pane_present "$PANE" && fail "the rerun left the task pane open: $out"
pane_present "$CONTROL" || fail "the rerun closed an unrelated pane"
assert_absent "$HOME_DIR/state/$ID.meta" "the rerun left the task record behind"
assert_absent "$HOME_DIR/state/$ID.backlog-close" "the rerun left the recorded close behind"
[ "$(row_state)" = "done" ] || fail "the rerun did not land the recorded close: $out"
pass "live herdr: the rerun closes the task pane and lands the close"
