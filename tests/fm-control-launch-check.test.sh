#!/usr/bin/env bash
# fm-control.sh launch-check: is the CURRENT launch incarnation a working agent,
# and if not, one relaunch on the next eligible route, then an explicit failure.
#
# Hermetic, like tests/fm-control-relaunch.test.sh (stubbed tmux, no real
# agent). The cases pin the behavior the bosgame audit exposed - launches that
# died at a model error or never took a turn were counted as building:
#   1. A running adapter turn under this exact incarnation plus a live agent,
#      once the window has passed, is building, and the verdict is recorded so
#      a repeat acts on nothing.
#   2. The launch seed alone, or any turn, is pending inside the window; after
#      it the seed alone, a turn that already ended, or a turn recorded under
#      an older incarnation is a failure, which fm-crew-state reports as
#      failed. A done declaration after the launch is completed and a
#      decision declaration is held, neither building nor relaunched; a
#      working declaration or worktree commit only forbids a relaunch, and an
#      attributed no-mistakes run holds custody.
#   3. A dead agent fails at once; with a fallback it relaunches exactly once
#      onto the first eligible route, and a second failure is final.
#   4. An invalid fallback model, or one whose catalog listing is unavailable,
#      empty, or timed out, is skipped by its harness catalog, and when no
#      route is eligible the failure is explicit.
#   5. A harness with no adapter turn source is unproven and untouched, and a
#      secondmate is refused.
# shellcheck disable=SC2030,SC2031 # Cases scope PATH and listing knobs to one subshell on purpose.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CONTROL="$ROOT/bin/fm-control.sh"
BUSY_EVENT="$ROOT/bin/fm-busy-event.sh"
TMP_ROOT=$(fm_test_tmproot fm-control-launch-check)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
TASK_TMPS=()

launch_check_cleanup() {
  local d
  for d in "${TASK_TMPS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
  chmod -R u+w "$TMP_ROOT" 2>/dev/null || true
  rm -rf "$TMP_ROOT"
}
trap launch_check_cleanup EXIT


# The same lifecycle-modelling tmux stub as tests/fm-control.test.sh: the
# harness's exit command stops the agent, and a launch-brief literal starts the
# harness named in `becomes`.
make_tmux_stub() {  # <dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      case "$payload" in
        ". '"*"'") staged=${payload#". '"}; staged=${staged%"'"}; [ ! -f "$staged" ] || payload=$(cat "$staged") ;;
      esac
      printf '%s\n' "$payload" >> "$D/literal"
      case "$payload" in
        /exit|/quit)
          printf 'zsh' > "$D/command"
          [ -z "${FM_FAKE_EXIT_TRANSPORT_FAIL_AFTER_STOP:-}" ] || exit 1
          ;;
        *'encode launch-brief'* | *'Firstmate operational input waiting: read'*)
          cat "$D/becomes" > "$D/command"
          [ -z "${FM_FAKE_LAUNCH_TRANSPORT_FAIL_AFTER_START:-}" ] || exit 1
          ;;
      esac
    else
      printf '%s\n' "$payload" >> "$D/keys"
      case "$payload" in
        'export GOTMPDIR='*)
          if [ -n "${FM_FAKE_TRACE_PREPARE:-}" ]; then
            : > "$FM_FAKE_TRACE_PREPARE"
            while [ ! -e "$FM_FAKE_TRACE_RELEASE" ]; do /bin/sleep 0.01; done
          fi
          ;;
        'export TRACEPARENT='*)
          [ -z "${FM_FAKE_TRACE_EXPORTED:-}" ] || : > "$FM_FAKE_TRACE_EXPORTED"
          ;;
      esac
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) cat "$D/command"; printf '\n'; exit 0 ;;
        *pane_current_path*)
          if [ -n "${FM_FAKE_CWD_RACE_READY:-}" ]; then
            : > "$FM_FAKE_CWD_RACE_READY"
            /bin/sleep 1
          fi
          cat "$D/cwd"; printf '\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    [ -z "${FM_FAKE_COMPOSER_READ_FAIL:-}" ] || exit 1
    if [ -s "$D/composer" ]; then
      printf '╭────╮\n│ %s  │\n╰────╯\n' "$(cat "$D/composer")"
    else
      printf '╭────╮\n│    │\n╰────╯\n'
    fi
    exit 0 ;;
  list-windows)
    # The three shapes real tmux answers a per-session inventory with. The
    # first two are DEFINITIVE and classify `missing`; the third is not and
    # classifies `unreadable`.
    if [ -f "$D/server-dead" ]; then
      echo 'no server running on /tmp/tmux-1000/default' >&2
      exit 1
    fi
    if [ -f "$D/session-missing" ]; then
      echo "can't find session: $(cat "$D/session-name")" >&2
      exit 1
    fi
    if [ -f "$D/inventory-broken" ]; then
      echo 'lost server' >&2
      exit 1
    fi
    [ -f "$D/windows" ] && cat "$D/windows"; exit 0 ;;
  new-session)
    # Nothing in the relaunch path may ever create a session; recording the
    # call is how a refusal test proves that.
    shift
    ses=
    while [ $# -gt 0 ]; do
      case "$1" in
        -s) ses=${2:-}; shift 2 ;;
        *) shift ;;
      esac
    done
    printf '%s\n' "$ses" >> "$D/created-sessions"
    exit 0 ;;
  new-window)
    # Model the one thing an endpoint re-creation depends on: the window now
    # appears in the session inventory, so the very next agent-state read stops
    # answering `missing`. Echo a stable window id the way the real -P -F does.
    shift
    name=
    while [ $# -gt 0 ]; do
      case "$1" in
        -n) name=${2:-}; shift 2 ;;
        -c|-t) shift 2 ;;
        *) shift ;;
      esac
    done
    printf '%s\n' "$name" >> "$D/windows"
    printf '%s\n' "$name" >> "$D/created-windows"
    printf '@9\n'
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
[ -z "${FM_FAKE_LOCK_WAITING:-}" ] || : > "$FM_FAKE_LOCK_WAITING"
exit 0
SH
  chmod +x "$fb/sleep"
  # The current-state owner's verdict (FM_CREW_STATE_BIN): no run is attributed
  # unless a case writes the line it should report to fake/crew-state.
  cat > "$fb/fm-crew-state" <<'SH'
#!/usr/bin/env bash
if [ -f "$FM_FAKE_DIR/crew-state" ]; then cat "$FM_FAKE_DIR/crew-state"; else echo 'state: unknown · source: none'; fi
SH
  chmod +x "$fb/fm-crew-state"
}

# new_case <name> <id> [harness] -> a case dir with a ship task whose agent is
# <harness>, launched <age> seconds ago (default 600) on incarnation s<epoch>.1.
new_case() {
  local id=$2 harness=${3:-claude} age=${4:-600} dir="$TMP_ROOT/$1-$RANDOM" wt proj launch_at
  mkdir -p "$dir/home/state" "$dir/home/data/$id" "$dir/fake"
  : > "$dir/fake/literal"
  : > "$dir/fake/keys"
  printf '%s' "$harness" > "$dir/fake/command"
  printf '%s' "$harness" > "$dir/fake/becomes"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  printf '%s' fmses > "$dir/fake/session-name"
  make_tmux_stub "$dir"
  proj="$dir/proj"
  wt="$dir/wt"
  fm_git_worktree "$proj" "$wt" "task-$id" >/dev/null
  printf '%s' "$wt" > "$dir/fake/cwd"
  cat > "$dir/home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise the launch check for $id.

## Firstmate spec
Nothing beyond the launch.
EOF
  launch_at=$(( $(date +%s) - age ))
  {
    echo "window=fmses:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=$harness"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=on"
    echo "tasktmp=/tmp/fm-$id"
    echo "model=default"
    echo "effort=medium"
    echo "spawn_gen=s$launch_at.1"
    echo "spawn_first=$launch_at"
  } > "$dir/home/state/$id.meta"
  TASK_TMPS+=("/tmp/fm-$id")
  printf '%s\n' "$dir"
}

# arm <case-dir> <id>: arm the busy contract the way fm-spawn does and record
# the gen in the task record; prints the gen.
arm() {
  local gen
  gen=$("$BUSY_EVENT" arm "$1/home/state" "$2") || fail "could not arm $2"
  printf 'busy_gen=%s\n' "$gen" >> "$1/home/state/$2.meta"
  printf '%s' "$gen"
}

run_check() {  # <case-dir> <id> [args...]
  local dir=$1 id=$2
  shift 2
  mkdir -p "$dir/user-home"
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
    -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' \
    FM_SPAWN_NO_GUARD=1 GROK_HOME="$dir/grokhome" \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state" \
    "$CONTROL" "$id" launch-check "$@" 2>&1
}

meta_field() {  # <case-dir> <id> <key>
  grep "^$3=" "$1/home/state/$2.meta" | tail -1 | cut -d= -f2-
}

status_lines() {  # <case-dir> <id>
  cat "$1/home/state/$2.status" 2>/dev/null || true
}

launches() {  # <case-dir>
  grep -c 'Firstmate operational input waiting: read' "$1/fake/literal" || true
}

# --- 1. building ----------------------------------------------------------------

test_adapter_turn_under_this_incarnation_is_building_and_recorded() {
  local dir gen out rc
  dir=$(new_case building lc1 claude)
  gen=$(arm "$dir" lc1)
  "$BUSY_EVENT" apply "$dir/home/state" lc1 busy --gen "$gen" --source claude-hook --event UserPromptSubmit \
    || fail "the adapter event should apply"
  out=$(run_check "$dir" lc1); rc=$?
  expect_code 0 "$rc" "a live agent with an adapter turn is building"$'\n'"$out"
  assert_contains "$out" "launch-check building lc1" "the verdict should be named"
  assert_contains "$out" "claude-hook turn under this incarnation" "the evidence should name the adapter turn"
  grep -qx "verdict=building s$(meta_field "$dir" lc1 spawn_first).1" "$dir/home/state/lc1.launch-check" \
    || fail "the building verdict should be recorded against the incarnation"
  printf 'zsh' > "$dir/fake/command"
  out=$(run_check "$dir" lc1); rc=$?
  expect_code 0 "$rc" "a recorded verdict is reprinted, not re-judged"$'\n'"$out"
  assert_contains "$out" "recorded for this incarnation" "the repeat should say it is the recorded verdict"
  [ -z "$(status_lines "$dir" lc1)" ] || fail "a building launch must not write a status line"
  pass "launch-check: a live agent with an adapter turn under this incarnation is building, recorded once"
}

# --- 2. pending, then no turn ------------------------------------------------------

test_launch_seed_alone_is_pending_then_failed() {
  local dir out rc
  dir=$(new_case seed lc2 claude 10)
  arm "$dir" lc2 >/dev/null
  out=$(run_check "$dir" lc2); rc=$?
  expect_code 3 "$rc" "the fm-spawn seed alone inside the window is pending"$'\n'"$out"
  assert_contains "$out" "launch-check pending lc2" "the pending verdict should be named"
  [ ! -e "$dir/home/state/lc2.launch-check" ] || fail "pending must record nothing"
  out=$(run_check "$dir" lc2 --window 5); rc=$?
  expect_code 4 "$rc" "the seed alone past the window is a failure"$'\n'"$out"
  assert_contains "$out" "no running claude-hook turn 5s after launch" "the failure should name the missing turn"
  assert_contains "$(status_lines "$dir" lc2)" "failed [at=" "the failure should be a stamped failed: status line"
  assert_contains "$(status_lines "$dir" lc2)" "not building" "the status line should say it is not building"
  [ "$(launches "$dir")" = 0 ] || fail "no fallback means no relaunch"
  pass "launch-check: the launch seed alone is pending inside the window and an explicit failure after it"
}

test_turn_from_an_older_incarnation_never_counts() {
  local dir old out rc
  dir=$(new_case stale lc3 claude)
  old=$("$BUSY_EVENT" arm "$dir/home/state" lc3)
  "$BUSY_EVENT" apply "$dir/home/state" lc3 busy --gen "$old" --source claude-hook --event UserPromptSubmit
  printf 'busy_gen=%s\n' "g-other-incarnation" >> "$dir/home/state/lc3.meta"
  out=$(run_check "$dir" lc3); rc=$?
  expect_code 4 "$rc" "a turn bound to another incarnation is not this launch's turn"$'\n'"$out"
  assert_contains "$out" "no running claude-hook turn" "the failure should name the missing turn"
  pass "launch-check: an adapter turn recorded under a different incarnation never proves this launch"
}

test_ended_adapter_turn_is_not_building() {
  local dir gen out rc
  dir=$(new_case ended lc10 claude)
  gen=$(arm "$dir" lc10)
  "$BUSY_EVENT" apply "$dir/home/state" lc10 busy --gen "$gen" --source claude-hook --event UserPromptSubmit \
    || fail "the adapter turn should apply"
  "$BUSY_EVENT" apply "$dir/home/state" lc10 idle --gen "$gen" --source claude-hook --event StopFailure \
    || fail "the adapter's turn end should apply"
  out=$(run_check "$dir" lc10); rc=$?
  expect_code 4 "$rc" "a turn that already ended under this incarnation is not a working agent"$'\n'"$out"
  assert_contains "$out" "no running claude-hook turn" "the failure should name the missing running turn"
  assert_contains "$(status_lines "$dir" lc10)" "not building" "the failure is an explicit status line"
  pass "launch-check: an adapter turn that already ended (StopFailure) never reads building"
}

test_adapter_turn_inside_window_is_pending_until_window() {
  local dir gen out rc
  dir=$(new_case early lc11 claude 10)
  gen=$(arm "$dir" lc11)
  "$BUSY_EVENT" apply "$dir/home/state" lc11 busy --gen "$gen" --source claude-hook --event UserPromptSubmit \
    || fail "the adapter turn should apply"
  out=$(run_check "$dir" lc11); rc=$?
  expect_code 3 "$rc" "a turn seen inside the window is not yet certified"$'\n'"$out"
  assert_contains "$out" "launch-check pending lc11" "the verdict should be pending"
  [ ! -e "$dir/home/state/lc11.launch-check" ] || fail "pending must record nothing"
  out=$(run_check "$dir" lc11 --window 5); rc=$?
  expect_code 0 "$rc" "a turn still running once the window has passed is building"$'\n'"$out"
  assert_contains "$out" "launch-check building lc11" "the verdict should be building"
  pass "launch-check: a turn seen inside the window is pending, and building only once the window has passed"
}

test_failed_launch_reads_failed_in_crew_state() {
  local dir out rc
  dir=$(new_case crewstate lc12 claude)
  sed 's/^kind=ship$/kind=scout/' "$dir/home/state/lc12.meta" > "$dir/meta.tmp"
  cat "$dir/meta.tmp" > "$dir/home/state/lc12.meta"
  arm "$dir" lc12 >/dev/null
  out=$(run_check "$dir" lc12); rc=$?
  expect_code 4 "$rc" "the launch seed alone past the window is a failure"$'\n'"$out"
  out=$(env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
    -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" HOME="$dir/user-home" \
    "$ROOT/bin/fm-crew-state.sh" lc12 2>&1)
  assert_contains "$out" "state: failed" "a launch the check failed must not read working from its launch seed"
  pass "launch-check: a failed launch reads failed in fm-crew-state, not working from the untouched launch seed"
}

test_worker_declaration_after_launch_proves_it() {
  local dir out rc launch_at
  dir=$(new_case declared lc13 claude)
  arm "$dir" lc13 >/dev/null
  printf 'zsh' > "$dir/fake/command"
  launch_at=$(meta_field "$dir" lc13 spawn_first)
  printf 'done [at=%s]: an earlier dispatch finished\n' "$((launch_at - 100))" > "$dir/home/state/lc13.status"
  out=$(run_check "$dir" lc13 --window 5 --fallback claude/claude-sonnet-5-5); rc=$?
  expect_code 3 "$rc" "a declaration stamped before this launch proves nothing, so the dead launch relaunches"$'\n'"$out"
  [ "$(launches "$dir")" = 1 ] || fail "the dead launch should relaunch once, got $(launches "$dir")"

  dir=$(new_case declared2 lc14 claude)
  arm "$dir" lc14 >/dev/null
  printf 'zsh' > "$dir/fake/command"
  printf 'done [at=%s]: report written\n' "$(date +%s)" > "$dir/home/state/lc14.status"
  out=$(run_check "$dir" lc14 --fallback claude/claude-sonnet-5-5); rc=$?
  expect_code 0 "$rc" "a worker that declared done after this launch and exited completed"$'\n'"$out"
  assert_contains "$out" "launch-check completed lc14" "the verdict is completed, not building"
  assert_contains "$out" "the worker declared done" "the evidence names the declaration"
  grep -qx "verdict=completed $(meta_field "$dir" lc14 spawn_gen)" "$dir/home/state/lc14.launch-check" \
    || fail "the completed verdict should be recorded against the incarnation"
  [ "$(launches "$dir")" = 0 ] || fail "a completed launch must never relaunch, got $(launches "$dir")"
  [ "$(grep -c '^failed' "$dir/home/state/lc14.status")" = 0 ] || fail "a completed launch writes no failure"
  out=$(run_check "$dir" lc14); rc=$?
  expect_code 0 "$rc" "the recorded completed verdict is reprinted"$'\n'"$out"
  assert_contains "$out" "launch-check completed lc14 (recorded for this incarnation)" "the repeat reprints completed"
  pass "launch-check: a done declaration after the launch is completed, never building or relaunched; an older one proves nothing"
}

test_decision_declaration_after_launch_is_held() {
  local dir out rc
  dir=$(new_case decision lc16 claude)
  arm "$dir" lc16 >/dev/null
  printf 'zsh' > "$dir/fake/command"
  printf 'needs-decision [at=%s]: pick the API shape\n' "$(date +%s)" > "$dir/home/state/lc16.status"
  out=$(run_check "$dir" lc16 --fallback claude/claude-sonnet-5-5); rc=$?
  expect_code 0 "$rc" "a worker waiting on a decision is held"$'\n'"$out"
  assert_contains "$out" "launch-check held lc16" "the verdict is held, not building"
  [ "$(launches "$dir")" = 0 ] || fail "a held launch must never relaunch, got $(launches "$dir")"
  [ "$(wc -l < "$dir/home/state/lc16.status" | tr -d ' ')" = 1 ] || fail "a held launch writes no status line"
  pass "launch-check: a needs-decision declaration after the launch is held, never building or relaunched"
}

test_working_declaration_forbids_relaunch_but_not_failure() {
  local dir gen out rc
  dir=$(new_case working lc17 claude)
  arm "$dir" lc17 >/dev/null
  printf 'zsh' > "$dir/fake/command"
  printf 'working [at=%s]: reading the brief\n' "$(date +%s)" > "$dir/home/state/lc17.status"
  out=$(run_check "$dir" lc17 --fallback claude/claude-sonnet-5-5); rc=$?
  expect_code 4 "$rc" "a worker that declared working and then died at the window failed"$'\n'"$out"
  assert_contains "$out" "so it is not relaunched" "the failure says the worker's act forbids a relaunch"
  [ "$(launches "$dir")" = 0 ] || fail "a worker that acted must never relaunch, got $(launches "$dir")"
  assert_contains "$(status_lines "$dir" lc17)" "not building" "the failure is an explicit status line"

  dir=$(new_case working2 lc18 claude 10)
  gen=$(arm "$dir" lc18)
  "$BUSY_EVENT" apply "$dir/home/state" lc18 busy --gen "$gen" --source claude-hook --event UserPromptSubmit \
    || fail "the adapter turn should apply"
  printf 'working [at=%s]: reading the brief\n' "$(date +%s)" > "$dir/home/state/lc18.status"
  out=$(run_check "$dir" lc18); rc=$?
  expect_code 3 "$rc" "a working line and a running turn inside the window are still pending"$'\n'"$out"
  assert_contains "$out" "launch-check pending lc18" "the verdict is pending before the window"
  pass "launch-check: a working declaration forbids a relaunch but never certifies building before the window"
}

test_worker_commit_after_launch_forbids_relaunch() {
  local dir out rc
  dir=$(new_case committed lc15 claude)
  arm "$dir" lc15 >/dev/null
  printf 'zsh' > "$dir/fake/command"
  git -C "$dir/wt" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m 'worker progress' \
    || fail "the worktree commit should succeed"
  out=$(run_check "$dir" lc15 --fallback claude/claude-sonnet-5-5); rc=$?
  expect_code 4 "$rc" "a worker that committed after this launch and then died failed"$'\n'"$out"
  assert_contains "$out" "the worker committed in its worktree after this launch" "the reason names the commit"
  [ "$(launches "$dir")" = 0 ] || fail "a worker that committed must never relaunch, got $(launches "$dir")"
  pass "launch-check: a commit made in the worktree after the launch forbids a relaunch"
}

test_attributed_run_holds_custody() {
  local dir out rc
  dir=$(new_case custody lc19 claude)
  arm "$dir" lc19 >/dev/null
  printf 'zsh' > "$dir/fake/command"
  echo 'state: parked · source: run-step · gate awaiting approval' > "$dir/fake/crew-state"
  out=$(run_check "$dir" lc19 --fallback claude/claude-sonnet-5-5); rc=$?
  expect_code 0 "$rc" "a task a no-mistakes run holds is held"$'\n'"$out"
  assert_contains "$out" "launch-check held lc19" "the verdict is held"
  assert_contains "$out" "a no-mistakes run holds the task" "the reason names the run's custody"
  [ "$(launches "$dir")" = 0 ] || fail "a run in custody must never be relaunched over, got $(launches "$dir")"
  [ -z "$(status_lines "$dir" lc19)" ] || fail "a held launch writes no status line"
  pass "launch-check: an attributed no-mistakes run holds custody and blocks a relaunch"
}

# --- 3. dead agent, one relaunch, then final -----------------------------------------

test_dead_agent_relaunches_once_then_fails() {
  local dir out rc first_gen
  dir=$(new_case dead lc4 claude)
  arm "$dir" lc4 >/dev/null
  printf 'zsh' > "$dir/fake/command"
  first_gen=$(meta_field "$dir" lc4 spawn_gen)
  out=$(run_check "$dir" lc4 --fallback claude/default --fallback claude/claude-sonnet-5-5 --fallback claude/claude-opus-5-5); rc=$?
  expect_code 3 "$rc" "a dead launch with an eligible fallback relaunches"$'\n'"$out"
  assert_contains "$out" "launch-check relaunched lc4 from=claude/default to=claude/claude-sonnet-5-5" \
    "the failed route itself is skipped and the next one in order is used"
  assert_contains "$out" "agent process is not running" "the reason should name the dead process"
  [ "$(meta_field "$dir" lc4 model)" = claude-sonnet-5-5 ] || fail "the record should follow the relaunch route"
  [ "$(meta_field "$dir" lc4 effort)" = medium ] || fail "the relaunch keeps the authorized effort"
  [ "$(meta_field "$dir" lc4 spawn_gen)" != "$first_gen" ] || fail "the relaunch must publish a new incarnation"
  [ "$(launches "$dir")" = 1 ] || fail "exactly one replacement launch, got $(launches "$dir")"
  assert_grep "Launch check: the previous launch on claude/default was not a working agent" \
    "$dir/home/data/lc4/brief.md" "the replacement's instructions should carry the launch-check note"
  [ -z "$(status_lines "$dir" lc4)" ] || fail "a relaunch is not yet a failure"

  printf 'zsh' > "$dir/fake/command"
  out=$(run_check "$dir" lc4 --fallback claude/claude-opus-5-5); rc=$?
  expect_code 4 "$rc" "a second failed incarnation is final"$'\n'"$out"
  assert_contains "$out" "after the one allowed relaunch (onto claude/claude-sonnet-5-5" "the final failure names the one relaunch"
  [ "$(launches "$dir")" = 1 ] || fail "a second relaunch must never happen, got $(launches "$dir") launches"
  [ "$(meta_field "$dir" lc4 model)" = claude-sonnet-5-5 ] || fail "the final failure changes no route"
  assert_contains "$(status_lines "$dir" lc4)" "failed [at=" "the final failure is an explicit failed: line"
  out=$(run_check "$dir" lc4 --fallback claude/claude-opus-5-5); rc=$?
  expect_code 4 "$rc" "the failure stays recorded"$'\n'"$out"
  [ "$(grep -c '^failed' "$dir/home/state/lc4.status")" = 1 ] || fail "a repeat must not append a second failed line"
  pass "launch-check: a dead launch relaunches once on the next eligible route; a second failure is final and recorded once"
}

test_relaunch_that_never_comes_up_is_recorded_failed() {
  local dir out rc
  dir=$(new_case nocomeup lc9 claude)
  arm "$dir" lc9 >/dev/null
  printf 'zsh' > "$dir/fake/command"
  printf 'zsh' > "$dir/fake/becomes"
  out=$(run_check "$dir" lc9 --fallback claude/claude-sonnet-5-5); rc=$?
  expect_code 4 "$rc" "a relaunch whose replacement never comes up is a recorded failure"$'\n'"$out"
  assert_contains "$out" "the one relaunch onto claude/claude-sonnet-5-5 failed" "the failure names the relaunch route"
  assert_contains "$(status_lines "$dir" lc9)" "not building" "the failure is an explicit status line"
  grep -qx 'relaunch_result=failed' "$dir/home/state/lc9.launch-check" || fail "the relaunch outcome should be recorded"
  [ -d "$dir/wt" ] || fail "the worktree must be preserved"
  out=$(run_check "$dir" lc9 --fallback claude/claude-opus-5-5); rc=$?
  expect_code 4 "$rc" "no second relaunch after a failed one"$'\n'"$out"
  [ "$(launches "$dir")" = 1 ] || fail "exactly one relaunch attempt, got $(launches "$dir")"
  pass "launch-check: a relaunch that never comes up is recorded as failed and never retried"
}

# --- 4. catalog-ineligible fallbacks ---------------------------------------------------

test_invalid_fallback_models_are_skipped_and_none_eligible_fails() {
  local dir out rc
  dir=$(new_case invalid lc5 claude)
  arm "$dir" lc5 >/dev/null
  printf 'zsh' > "$dir/fake/command"
  cat > "$dir/fakebin/pi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --list-models ]; then
  printf 'provider  model                       context\n'
  printf 'meta      muse-spark-1.3-contributor  262.1K\n'
  printf 'opencode-go muse-spark-1.3-contributor 262.1K\n'
fi
exit 0
SH
  chmod +x "$dir/fakebin/pi"
  out=$(run_check "$dir" lc5 --fallback pi/meta-muse-spark-1.3-contributor --fallback pi/muse-spark-1.3-contributor --fallback grok-bogus/x); rc=$?
  expect_code 4 "$rc" "no eligible route means an explicit failure"$'\n'"$out"
  assert_contains "$out" "skips fallback 'pi/meta-muse-spark-1.3-contributor': its harness catalog refuses the model" \
    "the dash-joined model is refused by Pi's catalog"
  assert_contains "$out" "skips fallback 'pi/muse-spark-1.3-contributor': its harness catalog refuses the model" \
    "the ambiguous bare id is refused by Pi's catalog"
  assert_contains "$out" "no eligible fallback route was given" "the failure says no route was eligible"
  [ "$(launches "$dir")" = 0 ] || fail "an ineligible route must never launch"
  [ "$(meta_field "$dir" lc5 harness)" = claude ] || fail "the record must not move to an ineligible route"
  assert_contains "$(status_lines "$dir" lc5)" "not building" "the failure is recorded as not building"
  pass "launch-check: catalog-refused fallbacks are skipped and an all-ineligible list fails explicitly"
}

test_unverifiable_fallback_catalog_is_ineligible() {
  local mode dir out rc n=0
  for mode in fail empty slow; do
    n=$((n + 1))
    dir=$(new_case "unverified-$mode" "lc2$n" claude)
    arm "$dir" "lc2$n" >/dev/null
    printf 'zsh' > "$dir/fake/command"
    cat > "$dir/fakebin/pi" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --list-models ] || exit 0
case $FM_FAKE_CATALOG_MODE in
  fail) exit 1 ;;
  empty) exit 0 ;;
  slow) /bin/sleep 5 ;;
esac
printf 'provider  model                       context\n'
printf 'meta      muse-spark-1.3-contributor  262.1K\n'
SH
    cat > "$dir/fakebin/opencode" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = models ] || exit 0
case $FM_FAKE_CATALOG_MODE in
  fail) exit 1 ;;
  empty) exit 0 ;;
  slow) /bin/sleep 5 ;;
esac
printf 'opencode/cat-jam-free\n'
SH
    chmod +x "$dir/fakebin/pi" "$dir/fakebin/opencode"
    out=$(FM_FAKE_CATALOG_MODE=$mode FM_PI_MODELS_TIMEOUT=1 FM_OPENCODE_MODELS_TIMEOUT=1 \
      run_check "$dir" "lc2$n" --fallback pi/meta/muse-spark-1.3-contributor --fallback opencode/opencode/cat-jam-free); rc=$?
    expect_code 4 "$rc" "$mode: a fallback whose catalog cannot verify the model is ineligible"$'\n'"$out"
    assert_contains "$out" "skips fallback 'pi/meta/muse-spark-1.3-contributor': its harness catalog refuses the model" \
      "$mode: the unverifiable Pi route is skipped"
    assert_contains "$out" "skips fallback 'opencode/opencode/cat-jam-free': its harness catalog refuses the model" \
      "$mode: the unverifiable OpenCode route is skipped"
    assert_contains "$out" "no eligible fallback route was given" "$mode: the failure says no route was eligible"
    [ "$(launches "$dir")" = 0 ] || fail "$mode: an unverifiable route must never launch"
  done
  pass "launch-check: a fallback whose Pi or OpenCode listing is unavailable, empty, or timed out is ineligible"
}

test_launch_owner_failed_line_still_relaunches() {
  local dir out rc
  dir=$(new_case ownerfail lc24 claude)
  arm "$dir" lc24 >/dev/null
  printf 'zsh' > "$dir/fake/command"
  printf 'failed [at=%s]: launch: kimi brief pointer delivery was not confirmed\n' "$(date +%s)" > "$dir/home/state/lc24.status"
  out=$(run_check "$dir" lc24 --fallback claude/claude-sonnet-5-5); rc=$?
  expect_code 3 "$rc" "a launch the launch owner itself failed is relaunched, not held"$'\n'"$out"
  assert_contains "$out" "launch-check relaunched lc24" "the launch failure relaunches on the next route"
  [ "$(launches "$dir")" = 1 ] || fail "the failed launch should relaunch once, got $(launches "$dir")"

  dir=$(new_case workerfail lc25 claude)
  arm "$dir" lc25 >/dev/null
  printf 'zsh' > "$dir/fake/command"
  printf 'failed [at=%s]: the test fixture cannot be built\n' "$(date +%s)" > "$dir/home/state/lc25.status"
  out=$(run_check "$dir" lc25 --fallback claude/claude-sonnet-5-5); rc=$?
  expect_code 0 "$rc" "a worker's own failure declaration holds the lane"$'\n'"$out"
  assert_contains "$out" "launch-check held lc25" "the worker's failure is held"
  [ "$(launches "$dir")" = 0 ] || fail "a worker failure must never relaunch, got $(launches "$dir")"
  pass "launch-check: fm-spawn's own launch failure line relaunches; a worker's failure declaration holds"
}

# run_relaunch <case-dir> <id> [args...]: a plain fm-control relaunch in the
# same hermetic world as run_check.
run_relaunch() {
  local dir=$1 id=$2
  shift 2
  mkdir -p "$dir/user-home"
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
    -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' \
    FM_SPAWN_NO_GUARD=1 GROK_HOME="$dir/grokhome" \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    "$CONTROL" "$id" relaunch --note 'relaunch under test' "$@" 2>&1
}

# A Pi stub whose catalog lists meta/muse-spark-1.3-contributor, fails when
# fake/catalog-fail exists, and logs every listing with the pane's command at
# that moment (claude before the stop, zsh after it).
make_logging_pi() {  # <case-dir>
  cat > "$1/fakebin/pi" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --list-models ] || exit 0
cat "$FM_FAKE_DIR/command" >> "$FM_FAKE_DIR/catalog-calls"
echo >> "$FM_FAKE_DIR/catalog-calls"
[ ! -e "$FM_FAKE_DIR/catalog-fail" ] || exit 1
printf 'provider  model                       context\n'
printf 'meta      muse-spark-1.3-contributor  262.1K\n'
SH
  chmod +x "$1/fakebin/pi"
}

test_custody_wins_over_a_running_turn() {
  local dir gen out rc
  dir=$(new_case custodybusy lc28 claude)
  gen=$(arm "$dir" lc28)
  "$BUSY_EVENT" apply "$dir/home/state" lc28 busy --gen "$gen" --source claude-hook --event UserPromptSubmit \
    || fail "the adapter turn should apply"
  echo 'state: working · source: run-step · reviewing' > "$dir/fake/crew-state"
  out=$(run_check "$dir" lc28); rc=$?
  expect_code 0 "$rc" "a task a no-mistakes run holds is held even with a running turn"$'\n'"$out"
  assert_contains "$out" "launch-check held lc28" "custody wins over building"
  grep -qx "verdict=held $(meta_field "$dir" lc28 spawn_gen)" "$dir/home/state/lc28.launch-check" \
    || fail "the held verdict should be recorded, never building"
  pass "launch-check: an attributed no-mistakes run holds the task even when its agent has a running turn"
}

test_relaunch_to_missing_opencode_is_refused_before_the_stop() {
  local dir out rc
  dir=$(new_case relocmissing lc29 claude)
  arm "$dir" lc29 >/dev/null
  out=$(PATH="$(dirname "$(command -v bash)"):/usr/bin:/bin"; run_relaunch "$dir" lc29 --harness opencode --model opencode/cat-jam-free); rc=$?
  expect_code 1 "$rc" "an opencode relaunch with no opencode executable is refused"$'\n'"$out"
  assert_contains "$out" "the opencode executable is not on PATH" "the refusal names the missing executable"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "the old agent must still be running after the refusal"
  [ "$(launches "$dir")" = 0 ] || fail "a refused relaunch must not launch"
  pass "relaunch: a missing opencode executable refuses a ship relaunch before the old agent is stopped"
}

test_cursor_relaunch_to_unlisted_model_is_refused_before_the_stop() {
  local dir out rc
  dir=$(new_case relcursor lc30 claude)
  arm "$dir" lc30 >/dev/null
  cat > "$dir/fakebin/cursor-agent" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" != --list-models ] || printf '%s\n' 'Available models' 'cursor-grok-4.5-high - Grok 4.5 High'
exit 0
SH
  cat > "$dir/fakebin/timeout" <<'SH'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do
  case "$1" in
    -k|-s|--kill-after|--signal) shift 2 ;;
    --) shift; break ;;
    -*) shift ;;
    *) break ;;
  esac
done
shift
exec "$@"
SH
  chmod +x "$dir/fakebin/cursor-agent" "$dir/fakebin/timeout"
  out=$(run_relaunch "$dir" lc30 --harness cursor --model cursor-not-listed); rc=$?
  expect_code 1 "$rc" "a cursor relaunch to an unlisted model is refused"$'\n'"$out"
  assert_contains "$out" "Cursor model 'cursor-not-listed' is not available" "the refusal names the unlisted model"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "the old agent must still be running after the refusal"
  if grep -qx '/exit' "$dir/fake/literal"; then fail "the refusal must come before any exit command"; fi
  pass "relaunch: a Cursor relaunch to an unlisted model refuses before the old agent is stopped"
}

test_verified_cursor_relaunch_lists_no_catalog_after_the_stop() {
  local dir out
  dir=$(new_case relcursorok lc31 claude)
  arm "$dir" lc31 >/dev/null
  cat > "$dir/fakebin/cursor-agent" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --list-models ] || exit 0
cat "$FM_FAKE_DIR/command" >> "$FM_FAKE_DIR/catalog-calls"
echo >> "$FM_FAKE_DIR/catalog-calls"
printf '%s\n' 'Available models' 'cursor-grok-4.5-high - Grok 4.5 High'
SH
  cat > "$dir/fakebin/timeout" <<'SH'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do
  case "$1" in
    -k|-s|--kill-after|--signal) shift 2 ;;
    --) shift; break ;;
    -*) shift ;;
    *) break ;;
  esac
done
shift
exec "$@"
SH
  chmod +x "$dir/fakebin/cursor-agent" "$dir/fakebin/timeout"
  out=$(run_relaunch "$dir" lc31 --harness cursor --model cursor-grok-4.5-high) || true
  grep -qx claude "$dir/fake/catalog-calls" || fail "the Cursor catalog must be verified before the stop"$'\n'"$out"
  if grep -qx zsh "$dir/fake/catalog-calls"; then
    fail "a verified Cursor relaunch must not list the catalog again after the stop"$'\n'"$out"
  fi
  grep -qx 'catalog_verified=cursor/cursor-grok-4.5-high' "$dir/home/state/lc31.control-relaunch" \
    || fail "the relaunch transaction record should carry the verified Cursor route"$'\n'"$out"
  pass "relaunch: a Cursor relaunch verified before the stop makes no second catalog call after it"
}

test_relaunch_with_unavailable_catalog_is_refused_before_the_stop() {
  local dir out rc
  dir=$(new_case relcatfail lc26 claude)
  arm "$dir" lc26 >/dev/null
  make_logging_pi "$dir"
  : > "$dir/fake/catalog-fail"
  out=$(run_relaunch "$dir" lc26 --harness pi --model meta/muse-spark-1.3-contributor); rc=$?
  expect_code 1 "$rc" "a ship relaunch whose catalog is unavailable is refused"$'\n'"$out"
  assert_contains "$out" "so the model is unverified" "the refusal names the unverifiable catalog"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "the old agent must still be running after the refusal"
  if grep -qx '/exit' "$dir/fake/literal"; then fail "the refusal must come before any exit command"; fi
  [ "$(launches "$dir")" = 0 ] || fail "a refused relaunch must not launch"
  pass "relaunch: an unavailable catalog refuses a ship relaunch before the old agent is stopped"
}

test_verified_relaunch_lists_no_catalog_after_the_stop() {
  local dir out
  dir=$(new_case relcatok lc27 claude)
  arm "$dir" lc27 >/dev/null
  make_logging_pi "$dir"
  out=$(run_relaunch "$dir" lc27 --harness pi --model meta/muse-spark-1.3-contributor) || true
  grep -qx claude "$dir/fake/catalog-calls" || fail "the catalog must be verified before the stop"$'\n'"$out"
  if grep -qx zsh "$dir/fake/catalog-calls"; then
    fail "a verified relaunch must not list the catalog again after the stop"$'\n'"$out"
  fi
  grep -qx 'catalog_verified=pi/meta/muse-spark-1.3-contributor' "$dir/home/state/lc27.control-relaunch" \
    || fail "the relaunch transaction record should carry the verified route"$'\n'"$out"
  pass "relaunch: a ship relaunch verified before the stop makes no second catalog call after it"
}

# --- 5. unproven and refused -------------------------------------------------------------

test_harness_without_turn_source_is_unproven_and_untouched() {
  local dir out rc
  dir=$(new_case unproven lc6 grok)
  out=$(run_check "$dir" lc6 --fallback claude/claude-sonnet-5-5); rc=$?
  expect_code 5 "$rc" "a harness with no adapter turn source cannot be proven"$'\n'"$out"
  assert_contains "$out" "has no adapter turn source" "the reason names the missing source"
  assert_contains "$out" "not counted as building" "unproven is never building"
  [ "$(launches "$dir")" = 0 ] || fail "unproven acts on nothing"
  [ -z "$(status_lines "$dir" lc6)" ] || fail "unproven writes no status line"
  pass "launch-check: a harness with no adapter turn source is unproven, not building, and untouched"
}

test_secondmate_is_refused() {
  local dir out rc
  dir=$(new_case secondmate lc7 claude)
  sed 's/^kind=ship$/kind=secondmate/' "$dir/home/state/lc7.meta" > "$dir/meta.tmp"
  cat "$dir/meta.tmp" > "$dir/home/state/lc7.meta"
  out=$(run_check "$dir" lc7); rc=$?
  expect_code 1 "$rc" "a secondmate's launch is not this verb's to judge"$'\n'"$out"
  assert_contains "$out" "launch-check judges ship and scout launches only" "the refusal names the scope"
  pass "launch-check: a secondmate is refused"
}

test_launch_check_options_are_verb_scoped() {
  local dir out rc
  dir=$(new_case options lc8 claude)
  out=$(run_check "$dir" lc8 --fallback claude); rc=$?
  expect_code 1 "$rc" "a fallback must name harness and model"$'\n'"$out"
  assert_contains "$out" "must be <harness>/<model>" "the refusal names the shape"
  mkdir -p "$dir/user-home"
  out=$(env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" HOME="$dir/user-home" \
    "$CONTROL" lc8 exit --fallback claude/x 2>&1); rc=$?
  expect_code 1 "$rc" "--fallback belongs to launch-check only"$'\n'"$out"
  assert_contains "$out" "apply to 'launch-check' only" "the refusal names the verb"
  pass "launch-check: --fallback is shape-checked and scoped to the verb"
}

test_adapter_turn_under_this_incarnation_is_building_and_recorded
test_launch_seed_alone_is_pending_then_failed
test_turn_from_an_older_incarnation_never_counts
test_ended_adapter_turn_is_not_building
test_adapter_turn_inside_window_is_pending_until_window
test_failed_launch_reads_failed_in_crew_state
test_worker_declaration_after_launch_proves_it
test_decision_declaration_after_launch_is_held
test_working_declaration_forbids_relaunch_but_not_failure
test_worker_commit_after_launch_forbids_relaunch
test_attributed_run_holds_custody
test_dead_agent_relaunches_once_then_fails
test_relaunch_that_never_comes_up_is_recorded_failed
test_invalid_fallback_models_are_skipped_and_none_eligible_fails
test_unverifiable_fallback_catalog_is_ineligible
test_launch_owner_failed_line_still_relaunches
test_relaunch_with_unavailable_catalog_is_refused_before_the_stop
test_verified_relaunch_lists_no_catalog_after_the_stop
test_custody_wins_over_a_running_turn
test_relaunch_to_missing_opencode_is_refused_before_the_stop
test_cursor_relaunch_to_unlisted_model_is_refused_before_the_stop
test_verified_cursor_relaunch_lists_no_catalog_after_the_stop
test_harness_without_turn_source_is_unproven_and_untouched
test_secondmate_is_refused
test_launch_check_options_are_verb_scoped
