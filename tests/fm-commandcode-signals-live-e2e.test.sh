#!/usr/bin/env bash
# Credentialed Command Code worker guard. Opt in with FM_COMMANDCODE_SIGNALS_LIVE=1.
# FM_COMMANDCODE_MODEL chooses a listed model (default deepseek/deepseek-v4.1-flash,
# a cheap plan model; one run costs a few cents of plan credit).
# Runs the real fm-spawn launch command in a private tmux server; only worktree
# allocation and initial endpoint delivery use fixtures. Steering, interrupt and
# exit use the real Firstmate control plane, including their clearing of a draft
# stuck in the idle composer. The worker runs under an isolated
# HOME holding only a copy of the login, so the guard can prove that the spawn
# never writes the user's global Command Code config (where --effort would land).
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
fm_live_gate opt-in FM_COMMANDCODE_SIGNALS_LIVE commandcode tmux jq node
CC_BIN=$(command -v commandcode)
REAL_TMUX=$(command -v tmux)
VERSION="commandcode $(commandcode --version 2>/dev/null)"
AUTH="$HOME/.commandcode/auth.json"
if [ ! -r "$AUTH" ] || ! commandcode status 2>/dev/null | grep -q 'Authenticated as'; then
  printf 'skip: live: %s is signed out; run commandcode login\n' "$VERSION"
  exit 0
fi
MODEL=${FM_COMMANDCODE_MODEL:-deepseek/deepseek-v4.1-flash}
LAB=$(mktemp -d "${TMPDIR:-/tmp}/cc.XXXXXX")
LAB=$(cd "$LAB" && pwd -P)
SOCKET="$LAB/tmux.sock"
case "$SOCKET" in "$PWD"/*) SOCKET=${SOCKET#"$PWD"/} ;; esac
cleanup() {
  "$REAL_TMUX" -S "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ "${FM_COMMANDCODE_KEEP_LAB:-0}" = 1 ] && { printf 'lab kept at %s\n' "$LAB" >&2; return 0; }
  # The spawn leaves the per-task git hooks directory read-only on purpose.
  chmod -R u+w "$LAB" 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT
fail() { printf 'not ok - %s: %s\n' "$VERSION" "$1" >&2; exit 1; }
# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=bin/fm-composer-lib.sh
. "$ROOT/bin/fm-composer-lib.sh"
# shellcheck source=bin/fm-tmux-lib.sh
. "$ROOT/bin/fm-tmux-lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$ROOT/bin/fm-control-lib.sh"
H="$LAB/home"
WT="$LAB/wt"
PROJ="$LAB/project"
ID=cc-live
fm_test_spawn_home "$H" commandcode
fm_git_worktree "$PROJ" "$WT" cc-live
mkdir -p "$H/user-home/.commandcode" "$LAB/bin"
cp "$AUTH" "$H/user-home/.commandcode/auth.json"
chmod 600 "$H/user-home/.commandcode/auth.json"
printf '%s\n' '{"installed":true,"provider":"command-code","firstMessageSent":true}' > "$H/user-home/.commandcode/config.json"
cp "$H/user-home/.commandcode/config.json" "$LAB/config.before"
git -C "$WT" config user.name 'Command Code Live Guard'
git -C "$WT" config user.email cc-live-guard@example.invalid
fm_test_spawn_brief "$H" "$ID" "Runtime verification only: compute 12345 plus 67890 using your shell tool and write only the result into answer.txt, then commit answer.txt with git using a commit message you write yourself. Also run '$ROOT/bin/fm-harness.sh' and write its output to harness.txt. Then end your turn at once: do no other work, do not inspect Firstmate's code, state, or inbox, and do not delegate. A later doorbell line will tell you when an instruction is waiting."
fakebin=$(make_spawn_fakebin "$LAB/fake" claude)
ln -s "$CC_BIN" "$fakebin/commandcode"
FM_FAKE_LAUNCH_LOG="$LAB/launch.sh" fm_test_run_spawn "$H" "$WT" "$fakebin" "$ID" "$PROJ" \
  --scout --harness commandcode --model "$MODEL" --effort high > "$LAB/spawn.log" 2>&1 \
  || fail "fm-spawn failed: $(cat "$LAB/spawn.log")"
# Route every backend read/write to this guard's own socket only.
printf '#!/bin/sh\nexec "%s" -S "%s" "$@"\n' "$REAL_TMUX" "$SOCKET" > "$LAB/bin/tmux"
chmod +x "$LAB/bin/tmux"
export PATH="$LAB/bin:$PATH" FM_HOME="$H"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
TARGET="firstmate:fm-$ID"
"$REAL_TMUX" -S "$SOCKET" new-session -d -s firstmate -n "fm-$ID" -x 140 -y 40 -c "$WT" \
  "HOME='$H/user-home' /bin/sh '$LAB/launch.sh'; exec /bin/bash --noprofile --norc" || fail 'could not start pane'
capture() { "$REAL_TMUX" -S "$SOCKET" capture-pane -p -e -t "$TARGET"; }
wait_file() {
  local path=$1 i
  for i in $(seq 1 480); do [ -s "$path" ] && return 0; sleep 0.5; done
  fail "timed out waiting for ${path##*/} (record: $(busy_state); screen: $(capture | fm_composer_strip_ansi | grep -v '^[[:space:]]*$' | tail -12))"
}
busy_state() { fm_busy_classify tmux "$TARGET" commandcode "$ID" "$H/state"; }
wait_idle() {
  local i
  for i in $(seq 1 480); do
    [ "$(busy_state)" = 'idle commandcode-mod' ] && return 0
    sleep 0.5
  done
  fail "run_end did not produce semantic idle (last: $(busy_state))"
}
wait_file "$WT/answer.txt"
wait_file "$WT/harness.txt"
[ "$(tr -d '[:space:]' < "$WT/answer.txt")" = 80235 ] || fail 'launch brief did not execute'
[ "$(tr -d '[:space:]' < "$WT/harness.txt")" = commandcode ] || fail "tool ancestry did not identify Command Code: $(cat "$WT/harness.txt")"
wait_idle
[ -f "$H/state/$ID.turn-ended" ] || fail 'turn_end did not notify'
[ "$(fm_backend_agent_state tmux "$TARGET")" = alive ] || fail 'real Command Code process not classified alive'
pass "$VERSION: spawn brief, model, autonomy, trust, identity and run_end idle"

git -C "$WT" log -1 --format=%B -- answer.txt > "$LAB/commit.txt" 2>/dev/null
[ -s "$LAB/commit.txt" ] || fail 'the worker did not commit answer.txt'
! grep -qi 'co-authored-by' "$LAB/commit.txt" || fail "worker commit carries attribution: $(cat "$LAB/commit.txt")"
git -C "$WT" status --porcelain > "$LAB/porcelain.txt"
! grep -q '\.commandcode' "$LAB/porcelain.txt" || fail "Command Code workspace files leaked into git status: $(cat "$LAB/porcelain.txt")"
cmp -s "$LAB/config.before" "$H/user-home/.commandcode/config.json" \
  || fail "the spawn changed the user's global config: $(cat "$H/user-home/.commandcode/config.json")"
grep -rqs '"effort":"high"' "$H/user-home/.commandcode/projects" \
  || fail 'the session transcript records no high effort; the mod did not set it'
pass "$VERSION: no attribution, no workspace files in git, session-only effort, global config untouched"

verdict=$(fm_tmux_composer_state "$TARGET")
[ "$verdict" = empty ] || fail "idle composer was $verdict"
"$ROOT/bin/fm-send.sh" "$ID" 'Runtime steering verification: compute 31 times 37 and write only the result to steer.txt. Acknowledge this instruction by moving its .msg file into handled/ as instructed by the doorbell. Do no other work.' > "$LAB/send.log" 2>&1 || fail "steer failed: $(cat "$LAB/send.log")"
wait_file "$WT/steer.txt"
wait_file "$H/state/$ID.inbox/handled/001.msg"
[ "$(tr -d '[:space:]' < "$WT/steer.txt")" = 1147 ] || fail 'wrong steering result'
wait_idle
pass "$VERSION: idle composer reads empty; real fm-send doorbell read and acknowledged"

"$ROOT/bin/fm-control.sh" "$ID" interrupt > "$LAB/idle-interrupt.log" 2>&1 \
  || fail "idle interrupt failed: $(cat "$LAB/idle-interrupt.log")"
sleep 1.5
[ "$(fm_tmux_composer_state "$TARGET")" = empty ] || fail 'an idle Escape left the composer non-empty'
"$ROOT/bin/fm-send.sh" "$ID" 'Runtime interrupt verification: run sleep 90 in your shell tool, then wait for it to finish. Do not respond before it finishes.' > "$LAB/send.log" 2>&1 || fail 'could not steer interrupt probe'
seen_busy=0
for _ in $(seq 1 240); do
  # Production delivery reads a plain capture; Command Code splits its hint
  # across SGR runs, so the styled bytes would never match.
  if [ "$(busy_state)" = 'busy commandcode-mod' ] && capture | fm_composer_strip_ansi | fm_busy_lines_match commandcode; then seen_busy=1; break; fi
  sleep 0.5
done
[ "$seen_busy" = 1 ] || fail "no semantic and rendered busy during interrupt probe (record: $(busy_state); screen: $(capture | fm_composer_strip_ansi | grep -v '^[[:space:]]*$' | tail -8))"
"$ROOT/bin/fm-control.sh" "$ID" interrupt > "$LAB/interrupt.log" 2>&1 || fail "interrupt failed: $(cat "$LAB/interrupt.log")"
wait_idle
capture | fm_composer_strip_ansi | grep -q 'Interrupted' || fail 'Escape did not cancel the running turn'
[ "$(fm_tmux_composer_state "$TARGET")" = empty ] || fail 'the interrupted composer is not empty'
pass "$VERSION: single Escape cancels, keeps the agent, and the mod records idle"

# A draft the idle composer already holds is the stall this guard exists for: one
# Escape clears nothing there, so the doorbell was skipped and exit refused.
# fm-control must empty it with the verified double Escape, for a typed
# multi-line draft and a bracketed-paste block alike.
draft_multi() { tmux send-keys -t "$TARGET" -l 'stale draft one'; tmux send-keys -t "$TARGET" M-Enter; tmux send-keys -t "$TARGET" -l 'stale draft two'; }
draft_paste() { printf '%s' $'pasted line one\npasted line two\npasted line three' | tmux load-buffer -b cc-live-draft -; tmux paste-buffer -p -b cc-live-draft -t "$TARGET"; }
wait_composer() {  # <state>
  local i
  for i in $(seq 1 40); do [ "$(fm_tmux_composer_state "$TARGET")" = "$1" ] && return 0; sleep 0.25; done
  return 1
}
for shape in draft_multi draft_paste; do
  "$shape"
  wait_composer pending || fail "$shape: the drafted composer did not read pending: $(capture | fm_composer_strip_ansi | grep -v '^[[:space:]]*$' | tail -6)"
  "$ROOT/bin/fm-control.sh" "$ID" interrupt > "$LAB/draft-interrupt.log" 2>&1 || fail "$shape: interrupt with a stuck draft failed: $(cat "$LAB/draft-interrupt.log")"
  wait_composer empty || fail "$shape: the composer still reads $(fm_tmux_composer_state "$TARGET") after the draft clear"
  grep -q 'draft=cleared' "$LAB/draft-interrupt.log" || fail "$shape: interrupt did not report the draft clear: $(cat "$LAB/draft-interrupt.log")"
  [ "$(fm_backend_agent_state tmux "$TARGET")" = alive ] || fail "$shape: clearing the draft stopped the agent"
done
pass "$VERSION: interrupt empties a stuck multi-line draft and a pasted block, keeping the agent"

draft_multi
wait_composer pending || fail 'the drafted composer did not read pending before the doorbell'
"$ROOT/bin/fm-send.sh" "$ID" 'Runtime stale-draft verification: compute 41 times 43 and write only the result to draft-steer.txt. Acknowledge this instruction by moving its .msg file into handled/ as instructed by the doorbell. Do no other work.' > "$LAB/send.log" 2>&1 || fail "steer onto a stuck draft failed: $(cat "$LAB/send.log")"
grep -q 'doorbell skipped' "$LAB/send.log" || fail "the doorbell rang over a draft it does not own: $(cat "$LAB/send.log")"
[ "$(fm_tmux_composer_state "$TARGET")" = pending ] || fail "the refused doorbell touched the draft: $(fm_tmux_composer_state "$TARGET")"
"$ROOT/bin/fm-control.sh" "$ID" interrupt > "$LAB/draft-interrupt.log" 2>&1 || fail "interrupt with a stuck draft failed: $(cat "$LAB/draft-interrupt.log")"
wait_composer empty || fail "the composer still reads $(fm_tmux_composer_state "$TARGET") after the draft clear"
bash -c '. "$1"; fm_task_inbox_ring tmux "$2" "$3" "$4" commandcode' _ \
  "$ROOT/bin/fm-task-inbox-lib.sh" "$TARGET" "$H/state/$ID.inbox/003.msg" "fm-$ID" \
  || fail 'the re-ring on the cleared composer did not deliver'
wait_file "$WT/draft-steer.txt"
wait_file "$H/state/$ID.inbox/handled/003.msg"
[ "$(tr -d '[:space:]' < "$WT/draft-steer.txt")" = 1763 ] || fail 'wrong steering result after the re-ring'
wait_idle
pass "$VERSION: fm-send refuses a foreign draft untouched, and the re-ring after interrupt clears it is acknowledged"

"$ROOT/bin/fm-send.sh" "$ID" 'Runtime busy-draft verification: run sleep 90 in your shell tool, then wait for it to finish. Do not respond before it finishes.' > "$LAB/send.log" 2>&1 || fail 'could not steer busy-draft probe'
seen_busy=0
for _ in $(seq 1 240); do
  if [ "$(busy_state)" = 'busy commandcode-mod' ] && capture | fm_composer_strip_ansi | fm_busy_lines_match commandcode; then seen_busy=1; break; fi
  sleep 0.5
done
[ "$seen_busy" = 1 ] || fail 'no busy turn for the busy-draft probe'
tmux send-keys -t "$TARGET" -l 'draft typed while running'
"$ROOT/bin/fm-control.sh" "$ID" interrupt > "$LAB/busy-draft.log" 2>&1 || fail "interrupt of a running turn with a draft failed: $(cat "$LAB/busy-draft.log")"
wait_idle
wait_composer empty || fail "a draft typed during a running turn survived the interrupt: $(fm_tmux_composer_state "$TARGET")"
pass "$VERSION: interrupting a running turn that holds a draft leaves an empty composer ($(grep -o 'draft=cleared' "$LAB/busy-draft.log" || echo 'one Escape sufficed'))"

# The same Escape pair on an EMPTY composer opens the Rewind checkpoint picker
# once the session has a turn, where Enter restores a checkpoint. The control
# plane must therefore never send the pair to a composer that reads empty, and
# must close a picker that is open with ONE Escape and prove it closed.
wait_composer empty || fail 'the composer is not empty before the checkpoint-picker probe'
fm_control_overlay_open tmux "$TARGET" commandcode && fail 'the checkpoint picker read open on an empty composer'
fm_control_clear_draft tmux "$TARGET" commandcode || fail 'clearing an empty composer must succeed without a key'
sleep 0.5
fm_control_overlay_open tmux "$TARGET" commandcode && fail 'clearing an empty composer opened the checkpoint picker'
tmux send-keys -t "$TARGET" Escape
sleep 0.1
tmux send-keys -t "$TARGET" Escape
for _ in $(seq 1 20); do fm_control_overlay_open tmux "$TARGET" commandcode && break; sleep 0.25; done
fm_control_overlay_open tmux "$TARGET" commandcode \
  || fail "the Escape pair on an empty composer no longer opens the checkpoint picker; the guard is vacuous: $(capture | fm_composer_strip_ansi | grep -v '^[[:space:]]*$' | tail -6)"
[ "$(fm_tmux_composer_state "$TARGET")" != empty ] || fail 'an open checkpoint picker read as an empty composer'
"$ROOT/bin/fm-control.sh" "$ID" interrupt > "$LAB/picker-interrupt.log" 2>&1 \
  || fail "interrupt with the checkpoint picker open failed: $(cat "$LAB/picker-interrupt.log")"
fm_control_overlay_open tmux "$TARGET" commandcode && fail 'the control plane left the checkpoint picker open'
wait_composer empty || fail "the composer reads $(fm_tmux_composer_state "$TARGET") after the picker was closed"
[ "$(fm_backend_agent_state tmux "$TARGET")" = alive ] || fail 'closing the checkpoint picker stopped the agent'
pass "$VERSION: an Escape pair on an empty composer opens the checkpoint picker; the control plane never sends it there and closes the picker with one Escape"

draft_multi
wait_composer pending || fail 'the drafted composer did not read pending before exit'
"$ROOT/bin/fm-control.sh" "$ID" exit > "$LAB/exit.log" 2>&1 || fail "exit failed: $(cat "$LAB/exit.log")"
[ "$(fm_backend_agent_state tmux "$TARGET")" = dead ] || fail '/exit did not return to the shell'
[ "$(busy_state)" != 'busy commandcode-mod' ] || fail 'exit left a busy record'
pass "$VERSION: /exit through the control plane, with a stuck draft cleared first"
