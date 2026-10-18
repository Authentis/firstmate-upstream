#!/usr/bin/env bash
# Default-on live guard for the mid-turn inbox pull, exactly as configured.
#
# tests/fm-inbox-pull.test.sh pins the owner's semantics with no harness. This
# one answers the question only a real pi can: does a steering record dropped
# into a coordinator's inbox while a long tool call is in flight reach the MODEL
# on its next request, once, throttled, silently, with the extension and owner
# wired the way bin/fm-spawn.sh wires a pi secondmate?
#
# "As configured" means nothing here is a hand-typed equivalent:
#   - the launch command is the one the REAL bin/fm-spawn.sh stages for a pi
#     secondmate (captured through the spawn suites' fake tmux), so the -e list
#     and the FM_INBOX_PULL_DIR export come from the real launch template;
#   - the harness is the installed pi, run in a real tmux pane;
#   - the owner script sits at mode 664, so only an explicit `bash <path>` can
#     run it (the netcup "Permission denied" defect, steering message 002);
#   - the model is a scripted local OpenAI-compatible server
#     (tests/fixtures/inbox-pull/scripted-provider.mjs), so the run needs no
#     credentials, spends no tokens, and can be asserted on the MODEL-SIDE
#     request log rather than on pi's own transcript.
#
# Scenarios: main (timeline, throttle, once-per-id, heartbeat, mode 664, pane
# silence, restart on the same session), kill-file, kill-env, missing-owner.
# Run it on every host before merge: FM_PI_INBOX_PULL_LIVE_E2E=1 bash <this file>.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

fm_live_gate default-on FM_PI_INBOX_PULL_LIVE_E2E pi tmux node

PI_VERSION=$(pi --version 2>/dev/null || printf 'unknown')
TMUX=$(command -v tmux)
PROVIDER="$ROOT/tests/fixtures/inbox-pull/scripted-provider.mjs"
TMP_ROOT=$(fm_test_tmproot fm-pi-inbox-pull-live)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
SOCKET="fm-inbox-pull-live-$$"
PROVIDER_PID=''
SCENARIO_N=0

cleanup() {
  "$TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
  [ -z "$PROVIDER_PID" ] || kill "$PROVIDER_PID" 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT

epoch_ms() { node -e 'process.stdout.write(String(Date.now()))'; }

# Build one scenario world: a primary home, a pi secondmate home carrying the
# tracked bin/ and .pi/, and the REAL spawn's staged launch command.
#   sets: C (case dir) H (primary home) SM (mate home) ID LAUNCH
build_world() {  # <name> <mate-owner-mode: 664|missing>
  local name=$1 owner_mode=$2 fakebin launchlog out status first_call_pid
  SCENARIO_N=$((SCENARIO_N + 1))
  C="$TMP_ROOT/$SCENARIO_N-$name"
  H="$C/home"
  SM="$C/sm"
  ID="inboxpull-$SCENARIO_N"
  mkdir -p "$C"
  fm_test_spawn_home "$H"
  printf '%s\n' 'pi fake/scripted' > "$H/config/secondmate-harness"
  fm_test_spawn_brief "$H" "$ID"

  mkdir -p "$SM/data" "$SM/state" "$SM/config"
  cp -R "$ROOT/bin" "$SM/bin"
  cp -R "$ROOT/.pi" "$SM/.pi"
  # .pi/extensions/lib symlinks the calm mod's files out of .claude/mods, and pi
  # auto-discovers the home's other extensions beside the three named with -e.
  mkdir -p "$SM/.claude"
  cp -R "$ROOT/.claude/mods" "$SM/.claude/mods"
  cp "$ROOT/AGENTS.md" "$SM/AGENTS.md"
  printf '%s\n' "$ID" > "$SM/.fm-secondmate-home"
  printf 'charter for %s\n' "$ID" > "$SM/data/charter.md"
  printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' > "$SM/.gitignore"
  git -C "$SM" init -q -b main
  SM=$(cd "$SM" && pwd -P)
  case "$owner_mode" in
    664) chmod 664 "$SM/bin/fm-inbox-pull.sh" ;;
    missing) rm -f "$SM/bin/fm-inbox-pull.sh" ;;
  esac

  # The installed pi stays on PATH: the fakebin holds only the tmux stub and a
  # no-op treehouse, so the spawn resolves and probes the real binary.
  fakebin=$(fm_test_make_spawn_fakebin "$C/fake")
  launchlog="$C/launch.log"
  : > "$launchlog"
  # The spawn waits for the mate's first model call, and the fake tmux never runs
  # a model, so a helper stands in for that call by driving the generated
  # first-call hook against the fake Pi event API once the hook exists.
  (
    i=0
    while [ "$i" -lt 600 ]; do
      if [ -f "$H/state/$ID.pi-first-call.ts" ] && grep -q '^kind=secondmate$' "$H/state/$ID.meta" 2>/dev/null; then
        node "$ROOT/tests/assets/pi-first-call-fake.mjs" "$H/state/$ID.pi-first-call.ts"
        exit 0
      fi
      sleep 0.2
      i=$((i + 1))
    done
  ) &
  first_call_pid=$!
  out=$(FM_FAKE_LAUNCH_LOG="$launchlog" fm_test_run_spawn "$H" "$SM" "$fakebin" "$ID" "$SM" --secondmate)
  status=$?
  kill "$first_call_pid" 2>/dev/null || true
  wait "$first_call_pid" 2>/dev/null || true
  [ "$status" -eq 0 ] || fail "spawn of the pi secondmate failed ($status): $out"
  LAUNCH=$(cat "$launchlog")
  case "$LAUNCH" in
    *"fm-inbox-pull.ts"*) ;;
    *) fail "the real spawn's pi secondmate launch does not load fm-inbox-pull.ts: $LAUNCH" ;;
  esac
  case "$LAUNCH" in
    *"FM_INBOX_PULL_DIR="*) ;;
    *) fail "the real spawn's pi secondmate launch does not export FM_INBOX_PULL_DIR" ;;
  esac
}

# start_provider <tool-calls> <command>  -> PORT, REQLOG
start_provider() {
  local calls=$1 command=$2 i=0
  REQLOG="$C/requests.log"
  : > "$REQLOG"
  rm -f "$C/port"
  node "$PROVIDER" "$C/port" "$REQLOG" "$calls" "$command" &
  PROVIDER_PID=$!
  while [ ! -s "$C/port" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -s "$C/port" ] || fail "scripted provider did not start"
  PORT=$(cat "$C/port")
  mkdir -p "$C/cfg"
  printf '{"providers":{"fake":{"baseUrl":"http://127.0.0.1:%s/v1","api":"openai-completions","apiKey":"x","models":[{"id":"scripted","reasoning":false,"input":["text"],"contextWindow":32000,"maxTokens":2000}]}}}\n' "$PORT" > "$C/cfg/models.json"
  printf '{"defaultProvider":"fake","defaultModel":"scripted","quietStartup":true}\n' > "$C/cfg/settings.json"
}

stop_provider() {
  [ -z "$PROVIDER_PID" ] || kill "$PROVIDER_PID" 2>/dev/null || true
  wait "$PROVIDER_PID" 2>/dev/null || true
  PROVIDER_PID=''
}

# launch_pi <shell-prefix> <extra-args>: run the staged launch in a real pane.
launch_pi() {
  local prefix=$1 extra=$2
  {
    printf 'export PI_CODING_AGENT_DIR=%q PI_OFFLINE=1 DISABLE_AUTOUPDATER=1\n' "$C/cfg"
    printf '%s\n' "$prefix"
    printf 'cd %q || exit 1\n' "$SM"
    printf '%s%s\n' "$LAUNCH" "$extra"
    printf 'sleep 600\n'
  } > "$C/run.sh"
  "$TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
  # a server that is still shutting down refuses a new session on its socket
  local tries=0
  until "$TMUX" -L "$SOCKET" new-session -d -s pi -x 200 -y 50 -c "$SM" "bash $C/run.sh" 2>/dev/null; do
    tries=$((tries + 1))
    [ "$tries" -lt 20 ] || fail "could not start the tmux pane"
    sleep 0.5
  done
}

pane_text() {
  "$TMUX" -L "$SOCKET" capture-pane -p -S - -t pi 2>/dev/null || true
}

# A real record in the mate's steering inbox, written by the real writer.
drop() {  # <text>
  bash -c '. "$1/bin/fm-task-inbox-lib.sh" && fm_task_inbox_write "$2" "$3" "$4"' _ "$ROOT" "$H/state" "$ID" "$1" >/dev/null \
    || fail "could not write a steering record"
}

wait_for_requests() {  # <min-lines> <timeout-s> -> 0 once the request log has that many lines
  local want=$1 limit=$2 i=0
  while [ "$(wc -l < "$REQLOG" | tr -d ' ')" -lt "$want" ]; do
    sleep 0.5
    i=$((i + 1))
    [ "$i" -lt $((limit * 2)) ] || return 1
  done
}

pi_diag() {
  printf 'pane: %s --- run.sh: %s --- inbox-pull log: %s' "$(pane_text | tail -20)" "$(cat "$C/run.sh" 2>/dev/null)" "$(cat "$SM/state/inbox-pull/log" 2>/dev/null)"
}

req_field() {  # <line-number> <ts|toolMsgs|notices>
  sed -n "${1}p" "$REQLOG" | tr ' ' '\n' | sed -n "s/^$2=//p"
}

first_request_with() {  # <needle> -> line number of the first request carrying it, or empty
  awk -v n="$1" 'index($0, n) { print NR; exit }' "$REQLOG"
}

hb_value() {  # <key>
  sed -n "s/^$1=//p" "$SM/state/inbox-pull/heartbeat" 2>/dev/null
}

session_notice_count() {  # <record-suffix> -> times that notice sits in pi's own session record
  local f total=0 n
  while IFS= read -r f; do
    n=$(grep -o "inbox-pull-notice:[^\"\\\\]*$1" "$f" | wc -l | tr -d ' ')
    total=$((total + n))
  done < <(find "$C/cfg" -name '*.jsonl' 2>/dev/null)
  printf '%s' "$total"
}

assert_pane_silent() {  # <label>: nothing from the extension or owner leaked into the TUI
  local text
  text=$(pane_text)
  assert_not_contains "$text" "Permission denied" "$1: a Permission denied reached the pane"
  assert_not_contains "$text" "fm-inbox-pull.sh" "$1: the owner script's name reached the pane"
  assert_not_contains "$text" "No such file or directory" "$1: a file error reached the pane"
  assert_not_contains "$text" "turn delivery failed" "$1: an extension failure line reached the pane"
}

# --- main: timeline, throttle, once-per-id, heartbeat, mode 664, restart ----------

test_main_timeline() {
  build_world main 664
  [ ! -x "$SM/bin/fm-inbox-pull.sh" ] || fail "the owner must be non-executable (mode 664) for the as-configured proof"
  start_provider 6 'sleep 12; echo step'
  launch_pi '' ''
  wait_for_requests 1 60 || fail "pi never made its first model request: $(pi_diag)"

  local t0 drop1 drop2 now max_age=0 age samples=0 hbts
  t0=$(req_field 1 ts)
  assert_equals "" "$(req_field 1 notices)" "the first request precedes any record"

  sleep 4
  drop1=$(epoch_ms)
  drop 'first steer: please acknowledge.'
  sleep 14
  drop2=$(epoch_ms)
  drop 'second steer: dropped while a tool call is in flight.'

  # Sample the heartbeat while the run continues: it must stay fresh throughout.
  while [ "$(wc -l < "$REQLOG" | tr -d ' ')" -lt 7 ]; do
    now=$(date +%s)
    hbts=$(hb_value ts)
    if [ -n "$hbts" ]; then
      age=$((now - hbts))
      [ "$age" -le "$max_age" ] || max_age=$age
      samples=$((samples + 1))
    fi
    sleep 1
    [ $(($(epoch_ms) - t0)) -lt 150000 ] || fail "the scripted run did not finish in time: $(cat "$REQLOG") $(pi_diag)"
  done
  [ "$samples" -ge 20 ] || fail "too few heartbeat samples ($samples) to judge freshness"
  [ "$max_age" -le 25 ] || fail "the heartbeat went stale during the run (max age ${max_age}s)"

  # 001: visible on the first request after its drop, absent before it.
  local r1 r2 l ts1 ts2 first_after
  r1=$(first_request_with "/001.msg")
  [ -n "$r1" ] || fail "record 001 never reached the model: $(cat "$REQLOG") $(pi_diag)"
  ts1=$(req_field "$r1" ts)
  first_after=$(awk -v d="$drop1" '{ split($1, a, "="); if (a[2] > d) { print NR; exit } }' "$REQLOG")
  assert_equals "$first_after" "$r1" "001 is on the very first model request after its drop"
  [ "$ts1" -gt "$drop1" ] || fail "001 appeared before it was dropped"
  # once it is in context it stays: every later request carries it
  for l in $(seq "$r1" "$(wc -l < "$REQLOG" | tr -d ' ')"); do
    case "$(req_field "$l" notices)" in *"/001.msg"*) ;; *) fail "request $l lost the 001 notice" ;; esac
  done

  # 002: throttled - not before 30 s after the first notice.
  r2=$(first_request_with "/002.msg")
  [ -n "$r2" ] || fail "record 002 never reached the model: $(cat "$REQLOG")"
  ts2=$(req_field "$r2" ts)
  [ "$ts2" -gt "$drop2" ] || fail "002 appeared before it was dropped"
  [ $((ts2 - ts1)) -ge 29000 ] || fail "002 reached the model $((ts2 - ts1)) ms after 001; the 30 s throttle was not honoured"
  for l in $(seq 1 $((r2 - 1))); do
    case "$(req_field "$l" notices)" in *"/002.msg"*) fail "request $l carried 002 inside the throttle window" ;; esac
  done

  # each id exactly once in pi's own session record
  assert_equals 1 "$(session_notice_count '/001.msg')" "001 entered the session exactly once"
  assert_equals 1 "$(session_notice_count '/002.msg')" "002 entered the session exactly once"
  assert_pane_silent main
  [ ! -s "$SM/state/inbox-pull/log" ] || fail "the extension logged an error during a healthy run: $(cat "$SM/state/inbox-pull/log")"
  assert_equals 2 "$(wc -l < "$SM/state/inbox-pull/notices" | tr -d ' ')" "two notices committed"
  assert_equals 0 "$(hb_value killed)" "the heartbeat reports a live pull"

  # restart on the same session: nothing is noticed again
  stop_provider
  "$TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
  local before
  before=$(cat "$SM/state/inbox-pull/cursor")
  start_provider 2 'sleep 3; echo again'
  launch_pi '' ' --continue'
  wait_for_requests 3 60 || fail "the restarted pi never finished its run: $(pi_diag)"
  sleep 2
  assert_equals "$before" "$(cat "$SM/state/inbox-pull/cursor")" "the cursor is unchanged across the restart"
  assert_equals 1 "$(session_notice_count '/001.msg')" "001 was not noticed again after the restart"
  assert_equals 1 "$(session_notice_count '/002.msg')" "002 was not noticed again after the restart"
  assert_equals 2 "$(wc -l < "$SM/state/inbox-pull/notices" | tr -d ' ')" "no notice was committed after the restart"
  assert_pane_silent restart
  stop_provider
  pass "main timeline on pi $PI_VERSION: 001 on the next request, 002 after the throttle, once each, heartbeat fresh, mode-664 owner, silent pane, restart quiet"
}

# --- kill switch: file and env ------------------------------------------------------

test_kill_file() {
  build_world kill-file 664
  start_provider 3 'sleep 3; echo step'
  printf 'off\n' > "$SM/state/.inbox-pull-off"
  launch_pi '' ''
  wait_for_requests 1 60 || fail "pi never made its first model request: $(pi_diag)"
  drop 'steer while the pull is switched off by file.'
  wait_for_requests 4 60 || fail "the scripted run did not finish: $(cat "$REQLOG")"
  assert_not_contains "$(cat "$REQLOG")" "/001.msg" "the kill file did not stop the pull"
  assert_equals 1 "$(hb_value killed)" "the heartbeat reports the file kill"
  assert_pane_silent kill-file
  stop_provider
  pass "the kill file stops the pull and the heartbeat says so"
}

test_kill_env() {
  build_world kill-env 664
  start_provider 3 'sleep 3; echo step'
  launch_pi 'export FM_INBOX_PULL=0' ''
  wait_for_requests 1 60 || fail "pi never made its first model request: $(pi_diag)"
  drop 'steer while the pull is switched off by environment.'
  wait_for_requests 4 60 || fail "the scripted run did not finish: $(cat "$REQLOG")"
  assert_not_contains "$(cat "$REQLOG")" "/001.msg" "FM_INBOX_PULL=0 did not stop the pull"
  assert_pane_silent kill-env
  stop_provider
  pass "FM_INBOX_PULL=0 stops the pull"
}

# --- missing owner: no leak into the pane, tool flow untouched --------------------

test_missing_owner() {
  build_world missing-owner missing
  start_provider 6 'sleep 2; echo step'
  launch_pi 'export FM_INBOX_PULL_MIN_INTERVAL=0' ''
  wait_for_requests 1 60 || fail "pi never made its first model request: $(pi_diag)"
  drop 'steer that cannot be pulled because the owner is missing.'
  wait_for_requests 7 90 || fail "a missing owner stalled the tool flow: $(cat "$REQLOG")"
  assert_not_contains "$(cat "$REQLOG")" "/001.msg" "a missing owner cannot deliver"
  assert_pane_silent missing-owner
  assert_not_contains "$(pane_text)" "disabled for this session" "the extension wrote its disable notice into the pane"
  assert_not_contains "$(pane_text)" "owner peek" "the extension wrote an owner failure into the pane"
  assert_not_contains "$(pane_text)" "inbox-pull-notice" "a notice reached the pane although the owner is missing"
  assert_grep "extension:" "$SM/state/inbox-pull/log" "the failure was not logged to the log file"
  assert_grep "disabled for this session" "$SM/state/inbox-pull/log" "five failures did not disable the extension"
  stop_provider
  pass "a missing owner is logged, disables the pull after five failures, and never reaches the pane or blocks the model"
}

test_main_timeline
test_kill_file
test_kill_env
test_missing_owner
