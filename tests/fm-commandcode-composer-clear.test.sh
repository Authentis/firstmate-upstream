#!/usr/bin/env bash
# Portable regression for clearing a draft stuck in a Command Code composer.
#
# A Command Code worker whose idle composer holds unsent text stalled its lane:
# fm-send skipped the doorbell and `fm-control exit` refused to type /exit,
# because one Escape on an idle composer clears nothing. The verified clear is
# two Escapes inside the CLI's pairing window (docs/verification/commandcode.md
# owns the dated result; fm-commandcode-signals-live-e2e.test.sh refreshes it).
#
# The same pair on an EMPTY composer opens the Rewind checkpoint picker once the
# session has a turn (verified live on 1.74.1), where Enter restores a
# checkpoint; a composer that is empty but misread as holding text, such as the
# placeholder drawn without its colours, therefore must not be hammered with it.
#
# This suite needs no Command Code install and no credentials. It runs the real
# fm-control.sh and fm_task_inbox_ring against REAL processes in a REAL tmux
# server: a Node stand-in executed under the process title `command-code`
# redraws byte-exact screens captured from live panes and obeys the facts under
# test, a pair of Escapes inside 400 ms empties a draft or opens the picker on an
# empty composer, one Escape closes the picker, and a lone Escape otherwise
# changes nothing. It logs every key it receives, so each case also asserts what
# was NOT sent.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$ROOT/bin/fm-task-inbox-lib.sh"
# shellcheck source=bin/fm-composer-lib.sh
. "$ROOT/bin/fm-composer-lib.sh"
# shellcheck source=bin/fm-tmux-lib.sh
. "$ROOT/bin/fm-tmux-lib.sh"

REAL_TMUX=$(command -v tmux)
SOCKET="fm-cc-clear-$$"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-cc-clear.XXXXXX")
LAB=$(cd "$LAB" && pwd -P)
cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "${LAB:-}" ] && rm -rf "$LAB"
}
trap cleanup_all EXIT
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }

CAPTURES="$ROOT/tests/captures/commandcode-v1.74.0"
mkdir -p "$LAB/shim" "$LAB/bin" "$LAB/home/state" "$LAB/home/data"
printf '#!/usr/bin/env bash\nexec "%s" -L "%s" "$@"\n' "$REAL_TMUX" "$SOCKET" > "$LAB/shim/tmux"
chmod +x "$LAB/shim/tmux"
PATH="$LAB/shim:$PATH"
export PATH
# The stand-in is a symlink to node named after the vendor process title, so the
# kernel-recorded executable name is what identifies the pane, as for the real CLI.
ln -s "$(command -v node)" "$LAB/bin/command-code"

# The idle screen is the captured composer tail with its CR row endings removed
# (tmux rows end in LF); the draft screens are captured byte-for-byte.
tr -d '\r' < "$CAPTURES/herdr-idle.ansi" > "$LAB/idle.ansi"
# The real 1.74.1 pictures: the picker, and an idle composer whose colours the
# launch environment erased (FORCE_COLOR=0), which reads as holding text.
PICKER="$ROOT/tests/captures/commandcode-v1.74.1/rewind-overlay.ansi"
MISREAD="$ROOT/tests/captures/commandcode-v1.74.1/forcecolor0-idle.ansi"
cat > "$LAB/tui.js" <<'EOF'
const fs = require('fs');
const env = process.env;
const log = (line) => fs.appendFileSync(env.FAKE_LOG, line + '\n');
const read = (p) => fs.readFileSync(p, 'utf8').replace(/\n$/, '');
const idle = read(env.FAKE_IDLE);
const rule = idle.split('\n').find((l) => l.includes('─────'));
let mode = env.FAKE_START_PICKER ? 'picker' : env.FAKE_DRAFT ? 'fixture' : 'idle';
let typed = '';
let lastEsc = 0;
const draw = () => {
  let rows;
  if (mode === 'picker') rows = read(env.FAKE_PICKER).split('\n');
  else if (mode === 'fixture') rows = read(env.FAKE_DRAFT).split('\n');
  else if (mode === 'typed') rows = [rule, '\x1b[39m❯ ' + typed + '\x1b[7m \x1b[0m', rule, '  ? for shortcuts · taste on'];
  else rows = idle.split('\n');
  if (env.FAKE_BUSY) rows = ['\x1b[38;2;138;148;168m⠋ Working…  esc to interrupt • 2s • ↓ 0\x1b[39m', ...rows];
  process.stdout.write('\x1b[2J\x1b[H' + rows.join('\r\n') + '\x1b[40;1H');
};
process.stdin.setRawMode(true);
process.stdin.resume();
process.stdin.on('data', (buf) => {
  for (const ch of buf.toString('utf8')) {
    if (ch === '\x1b') {
      const now = Date.now();
      log('KEY Escape');
      if (mode === 'picker') {
        // One Escape closes the picker; Enter would restore a checkpoint.
        if (!env.FAKE_PICKER_STUCK) mode = 'idle';
        lastEsc = 0;
      } else if (!env.FAKE_STUCK && lastEsc && now - lastEsc < 400) {
        // The pair empties a draft, and on an empty composer with history opens the picker.
        if (mode === 'idle' && env.FAKE_HISTORY) { mode = 'picker'; log('PICKER opened'); }
        else { mode = 'idle'; typed = ''; }
        lastEsc = 0;
      } else lastEsc = now;
    } else if (mode === 'picker') {
      if (ch === '\r') log('PICKER_ENTER restored a checkpoint');
    } else if (ch === '\r') {
      log('SUBMIT ' + typed);
      const line = typed;
      mode = 'idle'; typed = '';
      draw();
      if (line === '/exit') process.exit(0);
    } else {
      if (mode !== 'typed') { mode = 'typed'; typed = ''; }
      typed += ch;
    }
  }
  draw();
});
draw();
setInterval(() => {}, 1000);
EOF

H="$LAB/home"
STATE="$H/state"
ID=cc
LABEL="fm-$ID"
TARGET="fmses:$LABEL"
WT="$LAB/wt"
fm_git_worktree "$LAB/proj" "$WT" cc-clear
tmux_t() { "$REAL_TMUX" -L "$SOCKET" "$@"; }

# start_pane <draft-capture|-> [VAR=value...]: a fresh Command Code stand-in.
start_pane() {
  local draft=$1
  shift
  tmux_t kill-server >/dev/null 2>&1 || true
  : > "$LAB/keys.log"
  local draft_env=
  [ "$draft" = - ] || draft_env="FAKE_DRAFT=$CAPTURES/$draft"
  # shellcheck disable=SC2086
  tmux_t new-session -d -s fmses -n "$LABEL" -x 140 -y 40 -c "$WT" \
    "env FAKE_LOG=$LAB/keys.log FAKE_IDLE=$LAB/idle.ansi FAKE_PICKER=$PICKER FAKE_HISTORY=1 $draft_env $* $LAB/bin/command-code $LAB/tui.js; exec /bin/bash --noprofile --norc" \
    || fail 'could not start the stand-in pane'
  local i=0
  while [ "$i" -lt 100 ]; do
    case "$(tmux_t capture-pane -p -t "$TARGET" 2>/dev/null)" in *'for shortcuts'*|*'❯'*) break ;; esac
    sleep 0.1
    i=$((i + 1))
  done
  fm_tmux_pane_is_commandcode "$TARGET" || fail 'the stand-in is not identified as Command Code'
}
write_meta() {  # <harness>
  {
    echo "window=$TARGET"
    echo "endpoint_task_id=$ID"
    echo "worktree=$WT"
    echo "project=$LAB/proj"
    echo "harness=$1"
    echo kind=ship
    echo mode=local-only
    echo yolo=off
    echo model=default
    echo effort=default
  } > "$STATE/$ID.meta"
}
write_meta commandcode
run_control() {  # <verb>
  env FM_HOME="$H" FM_CONTROL_POLL=0.05 FM_CONTROL_SETTLE_WAIT=0.1 FM_CONTROL_EXIT_WAIT=8 \
    "$ROOT/bin/fm-control.sh" "$ID" "$1" 2>&1
}
composer() { fm_tmux_composer_state "$TARGET"; }
count_key() { grep -c "^$1" "$LAB/keys.log" || true; }
set_busy() {  # <busy|idle>
  [ -f "$STATE/$ID.busy-gen" ] || "$ROOT/bin/fm-busy-event.sh" arm "$STATE" "$ID" >/dev/null
  "$ROOT/bin/fm-busy-event.sh" apply "$STATE" "$ID" "$1" --current-gen --source commandcode-mod --event "run_$1" >/dev/null
}
new_record() {
  rm -rf "$STATE/$ID.inbox"
  fm_task_inbox_write "$STATE" "$ID" 'Check the new instruction.' >/dev/null
  printf '%s' "$STATE/$ID.inbox/001.msg"
}
wait_log() {  # <pattern>
  local i=0
  while [ "$i" -lt 60 ]; do
    grep -q "$1" "$LAB/keys.log" && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# --- the capability tables ---------------------------------------------------------
[ "$(fm_control_draft_clear_key commandcode)" = Escape ] || fail 'Command Code draft clear key'
[ "$(fm_control_draft_clear_presses commandcode)" = 2 ] || fail 'Command Code draft clear needs a pair'
awk -v g="$(fm_control_draft_clear_gap commandcode)" 'BEGIN{exit !(g > 0 && g < 0.3)}' \
  || fail 'the press gap must sit well inside the 0.4 s pairing window'
for harness in claude codex opencode pi pi-signed omp grok kimi cursor gemini muse rovo agy devin; do
  [ -z "$(fm_control_draft_clear_key "$harness")" ] || fail "$harness must have no draft clear: its draft may be the captain's"
  fm_control_clear_draft tmux "$TARGET" "$harness" "$LABEL"
  [ "$?" = 2 ] || fail "$harness: fm_control_clear_draft must report not-applicable"
done
! fm_control_draft_clear_key unknown-harness >/dev/null || fail 'an unverified adapter must have no table entry'
pass "draft clear table: Command Code only, every other adapter untouched"

# --- the captured draft shapes read pending, and the pair empties them ------------------
for shape in draft-multiline.ansi draft-pasted.ansi; do
  start_pane "$shape"
  [ "$(composer)" = pending ] || fail "$shape: the captured draft must read pending, got $(composer)"
  out=$(run_control interrupt) || fail "$shape: interrupt failed: $out"
  [ "$(composer)" = empty ] || fail "$shape: the composer still reads $(composer) after interrupt"
  case "$out" in *draft=cleared*) ;; *) fail "$shape: interrupt did not report the cleared draft: $out" ;; esac
  [ "$(count_key 'KEY Escape')" = 3 ] || fail "$shape: expected the interrupt Escape plus a pair, got $(count_key 'KEY Escape')"
  [ "$(fm_backend_agent_state tmux "$TARGET")" = alive ] || fail "$shape: the interrupt stopped the agent"
done
pass "interrupt: a captured multi-line draft and a captured pasted block both clear and verify empty"

start_pane -
out=$(run_control interrupt) || fail "idle interrupt failed: $out"
[ "$(count_key 'KEY Escape')" = 1 ] || fail "an empty composer must get exactly the one interrupt Escape, got $(count_key 'KEY Escape')"
case "$out" in *draft=*) fail "an empty composer reported a draft clear: $out" ;; esac
pass "interrupt: an empty composer still receives one Escape and no clear"

# --- exit: a stuck draft no longer blocks the exit command ---------------------------------
start_pane draft-multiline.ansi
out=$(run_control exit) || fail "exit failed with a stuck draft: $out"
wait_log '^SUBMIT /exit$' || fail 'the exit command never reached the composer'
[ "$(fm_backend_agent_state tmux "$TARGET")" = dead ] || fail 'exit did not stop the agent'
pass "exit: a stuck draft is cleared before /exit is typed, and the agent stops"

# --- refusing loudly when the clear does not work ------------------------------------------
start_pane draft-multiline.ansi FAKE_STUCK=1
out=$(run_control exit) && fail "exit must refuse a composer it cannot clear: $out"
case "$out" in *'did not leave it reading empty'*) ;; *) fail "the refusal must name the stuck composer: $out" ;; esac
! grep -q '^SUBMIT' "$LAB/keys.log" || fail 'exit typed into a composer it could not clear'
[ "$(composer)" = pending ] || fail 'the stuck draft must be left as it was'
out=$(run_control interrupt) && fail "interrupt must refuse a composer it cannot clear: $out"
pass "refuses loudly and types nothing when the draft cannot be cleared"

# --- the doorbell: never edits a screen it does not own ------------------------------------
ring() {  # <harness> -> prints the return code
  local rec rc=0
  rec=$(new_record)
  fm_task_inbox_ring tmux "$TARGET" "$rec" "$LABEL" "$1" 2>/dev/null || rc=$?
  printf '%s' "$rc"
}
start_pane draft-pasted.ansi
set_busy idle
[ "$(ring commandcode)" = 1 ] || fail 'the doorbell must skip a foreign draft, even on a proven-idle pane'
[ "$(count_key 'KEY Escape')" = 0 ] || fail 'the doorbell must not clear a draft it does not own'
! grep -q '^SUBMIT' "$LAB/keys.log" || fail "the doorbell typed over a foreign draft: $(cat "$LAB/keys.log")"
pass "doorbell: a foreign draft is refused untouched, with no Escape and no typing"

start_pane - FAKE_START_PICKER=1
set_busy idle
[ "$(ring commandcode)" = 1 ] || fail 'the doorbell must skip an open picker'
[ "$(count_key 'KEY Escape')" = 0 ] || fail 'the doorbell must not dismiss a picker it does not own'
! grep -q '^PICKER_ENTER\|^SUBMIT' "$LAB/keys.log" || fail "a key reached the open picker: $(cat "$LAB/keys.log")"
pass "doorbell: an open picker is refused untouched, with no Escape, Enter or typing"

start_pane -
set_busy idle
[ "$(ring commandcode)" = 0 ] || fail 'the doorbell must ring a plain empty composer'
wait_log '^SUBMIT : Firstmate instruction waiting' || fail "the doorbell line was never submitted: $(cat "$LAB/keys.log")"
pass "doorbell: a plain empty composer still receives the ring"
