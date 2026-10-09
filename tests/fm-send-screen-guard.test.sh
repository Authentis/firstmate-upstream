#!/usr/bin/env bash
# tests/fm-send-screen-guard.test.sh - the pre-typing screen guard shared by
# every text-typing path (fm_backend_send_text_submit in bin/fm-backend.sh,
# the fm-send doorbell ring in bin/fm-task-inbox-lib.sh).
#
# The 12:20 accident: a worker typed text plus Enter into a real Claude pane
# whose /config menu was open, which flipped a setting shared by every agent.
# These tests pin the prevention with captured Claude Code 2.1.295 screens
# (tests/fixtures/send-guard) and a fake tmux that replays them:
#   1. An open /config menu is refused and nothing is typed.
#   2. A half-typed draft is refused when the caller names the harness.
#   3. A plain empty prompt is accepted and delivered.
#   4. A refused doorbell ring leaves the inbox record unhandled, names the
#      reason, and the next ring on a clean prompt delivers it.
#   5. An unrecognised screen is refused for every harness, and the production
#      ring path (fm_task_inbox_ring) refuses a foreign draft, an open picker,
#      an unknown screen and a missing harness untouched. The own-doorbell
#      recovery is pinned in tests/fm-task-inbox.test.sh.
#   6. Claude, codex, opencode and pi each positively recognise their real
#      captured idle prompt and refuse their captured draft.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-send-screen-guard)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
FX="$ROOT/tests/fixtures/send-guard"

# A fake tmux: capture-pane replays the FM_FAKE_SCREEN fixture, the cursor sits
# on the fixture's composer row FM_FAKE_CURSOR, and every literal send-keys is
# logged to FM_SEND_LOG so typing is observable.
make_screen_stub() {  # <dir>
  mkdir -p "$1/fakebin"
  cat > "$1/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
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
    if [ "$literal" = 1 ]; then
      printf 'TYPED: %s\n' "$1" >> "$FM_SEND_LOG"
    else
      printf 'KEY: %s\n' "${1:-}" >> "$FM_SEND_LOG"
    fi
    exit 0 ;;
  display-message)
    case "$*" in
      *cursor_y*) printf '%s\n' "${FM_FAKE_CURSOR:-0}"; exit 0 ;;
      *pane_current_command*) printf '%s\n' "${FM_FAKE_COMM:-fakepane}"; exit 0 ;;
    esac
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) cat "$FM_FAKE_SCREEN"; exit 0 ;;
  list-windows) printf 'fm-t1\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$1/fakebin/tmux"
}

# The pane's real #{cursor_y}, recorded beside each capture; fixtures without
# one (menus, dialogs) fall back to the first "❯" row, else 0.
composer_row() {  # <fixture>
  if [ -f "${1%.txt}.cursor" ]; then
    cat "${1%.txt}.cursor"
  else
    awk '/^❯/ { print NR - 1; exit }' "$1"
  fi
}

# Run one library function in a subshell that sources the production library.
lib() {  # <state> <function> [args...]
  local state=$1
  shift
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fn=$2
    shift 2
    "$fn" "$@"
  ' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$@"
}

# submit <dir> <fixture> <harness> -> runs the shared submit primitive against
# the fake pane; sets SUBMIT_RC / SUBMIT_ERR / SUBMIT_OUT and the send log.
submit() {
  local dir=$1 fixture=$2 harness=$3 cursor
  cursor=$(composer_row "$fixture")
  : > "$dir/send.log"
  SUBMIT_RC=0
  SUBMIT_OUT=$(PATH="$dir/fakebin:$PATH" FM_SEND_LOG="$dir/send.log" FM_FAKE_SCREEN="$fixture" \
    FM_FAKE_CURSOR="${cursor:-0}" FM_FAKE_COMM="$harness" lib "$dir/state" fm_backend_send_text_submit \
    tmux sess:fm-t1 'hello worker' 1 0 0 fm-t1 "$harness" 2> "$dir/err.log") || SUBMIT_RC=$?
  SUBMIT_ERR=$(cat "$dir/err.log")
}

new_dir() {  # <name>
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/state"
  make_screen_stub "$dir"
  printf '%s\n' "$dir"
}

test_open_menu_is_refused() {
  local dir h
  dir=$(new_dir menu)
  for h in claude ''; do
    submit "$dir" "$FX/claude-config-menu.txt" "$h"
    [ "$SUBMIT_RC" = 1 ] || fail "an open /config menu must be refused (harness='$h'), got rc $SUBMIT_RC"
    [ ! -s "$dir/send.log" ] || fail "text was typed into an open menu (harness='$h'):"$'\n'"$(cat "$dir/send.log")"
    case "$SUBMIT_ERR" in
      *'blocked on a prompt: an open menu or picker is showing'*) ;;
      *) fail "the refusal must name the open menu, got: $SUBMIT_ERR" ;;
    esac
  done
  pass "guard: an open /config menu is refused with a named reason and nothing is typed"
}

test_draft_is_refused() {
  local dir
  dir=$(new_dir draft)
  submit "$dir" "$FX/claude-draft.txt" claude
  [ "$SUBMIT_RC" = 1 ] || fail "a half-typed draft must be refused, got rc $SUBMIT_RC"
  [ ! -s "$dir/send.log" ] || fail "text was typed over a draft:"$'\n'"$(cat "$dir/send.log")"
  case "$SUBMIT_ERR" in
    *'the prompt already holds a draft'*) ;;
    *) fail "the refusal must name the draft, got: $SUBMIT_ERR" ;;
  esac
  pass "guard: a half-typed draft is refused when the harness is named"
}

test_empty_prompt_is_accepted() {
  local dir
  dir=$(new_dir empty)
  submit "$dir" "$FX/claude-idle.txt" claude
  grep -q '^TYPED: hello worker$' "$dir/send.log" \
    || fail "a plain empty prompt must be typed into (rc $SUBMIT_RC, err: $SUBMIT_ERR)"
  case "$SUBMIT_ERR" in
    *'blocked on a prompt'*) fail "a plain empty prompt was reported blocked: $SUBMIT_ERR" ;;
  esac
  pass "guard: a plain empty prompt is accepted and typed into"
}

test_unrecognised_screen_is_refused_for_every_harness() {
  local dir screen h
  dir=$(new_dir unreadable)
  screen="$dir/blank.txt"
  printf 'some output\nmore output\n' > "$screen"
  for h in claude codex opencode pi unknown; do
    submit "$dir" "$screen" "$h"
    [ "$SUBMIT_RC" = 1 ] && [ ! -s "$dir/send.log" ] \
      || fail "an unrecognised screen must be refused untyped for $h (rc $SUBMIT_RC)"
    case "$SUBMIT_ERR" in
      *'not a recognised empty prompt'*) ;;
      *) fail "the refusal must name the unrecognised prompt for $h, got: $SUBMIT_ERR" ;;
    esac
  done
  pass "guard: an unrecognised screen is refused for every harness"
}

test_real_captures_per_harness() {
  local dir h
  dir=$(new_dir captures)
  for h in claude codex opencode pi; do
    submit "$dir" "$FX/$h-idle.txt" "$h"
    grep -q '^TYPED: hello worker$' "$dir/send.log" \
      || fail "$h: the real idle capture must be typed into (rc $SUBMIT_RC, err: $SUBMIT_ERR)"
    submit "$dir" "$FX/$h-draft.txt" "$h"
    [ "$SUBMIT_RC" = 1 ] && [ ! -s "$dir/send.log" ] \
      || fail "$h: the real draft capture must be refused untyped (rc $SUBMIT_RC)"
  done
  submit "$dir" "$FX/codex-dialog.txt" codex
  [ "$SUBMIT_RC" = 1 ] && [ ! -s "$dir/send.log" ] \
    || fail "codex: a startup dialog must be refused untyped (rc $SUBMIT_RC)"
  pass "guard: claude, codex, opencode and pi accept their real idle prompt and refuse their real draft"
}

# The production ring path (fm_task_inbox_ring) against the fake pane.
ring_fixture() {  # <dir> <fixture> <harness>
  local dir=$1 fixture=$2 harness=$3 cursor
  cursor=$(composer_row "$fixture")
  : > "$dir/send.log"
  RING_RC=0
  PATH="$dir/fakebin:$PATH" FM_SEND_LOG="$dir/send.log" FM_FAKE_SCREEN="$fixture" \
    FM_FAKE_CURSOR="${cursor:-0}" FM_FAKE_COMM="$harness" lib "$dir/state" fm_task_inbox_ring tmux sess:fm-t1 "$RING_REC" fm-t1 "$harness" \
    2> "$dir/ring-err.log" || RING_RC=$?
  RING_ERR=$(cat "$dir/ring-err.log")
}

test_production_ring_refuses_without_touching_the_screen() {
  local dir state name fixture harness
  dir=$(new_dir ringrefuse)
  state="$dir/state"
  RING_REC=$(lib "$state" fm_task_inbox_write "$state" t1 "please continue")
  printf 'some output\n' > "$dir/blank.txt"
  while IFS='|' read -r name fixture harness; do
    ring_fixture "$dir" "$fixture" "$harness"
    [ "$RING_RC" = 1 ] || fail "$name: the ring must skip (rc 1), got $RING_RC"
    [ ! -s "$dir/send.log" ] \
      || fail "$name: the ring typed or sent a key into a screen it must not touch:"$'\n'"$(cat "$dir/send.log")"
    [ -f "$RING_REC" ] || fail "$name: the refused ring lost the durable inbox record"
    case "$RING_ERR" in *'doorbell refused'*) ;; *) fail "$name: no reason reported: $RING_ERR" ;; esac
  done <<ROWS
foreign draft|$FX/claude-draft.txt|claude
open picker|$FX/claude-config-menu.txt|claude
codex dialog|$FX/codex-dialog.txt|codex
unknown screen|$dir/blank.txt|pi
missing harness|$FX/claude-idle.txt|
ROWS
  pass "guard: the production ring refuses a foreign draft, an open picker, a dialog, an unknown screen and a missing harness untouched"
}

test_refused_ring_keeps_the_record_and_retries() {
  local dir state rec rc err
  dir=$(new_dir ring)
  state="$dir/state"
  rec=$(lib "$state" fm_task_inbox_write "$state" t1 "please continue")
  : > "$dir/send.log"
  ring() {  # <fixture>
    local cursor
    cursor=$(composer_row "$1")
    PATH="$dir/fakebin:$PATH" FM_SEND_LOG="$dir/send.log" FM_FAKE_SCREEN="$1" \
      FM_FAKE_CURSOR="${cursor:-0}" FM_FAKE_COMM=claude lib "$state" fm_task_inbox_ring tmux sess:fm-t1 "$rec" fm-t1 claude \
      2> "$dir/ring-err.log"
  }
  rc=0; ring "$FX/claude-config-menu.txt" || rc=$?
  err=$(cat "$dir/ring-err.log")
  [ "$rc" = 1 ] || fail "a ring onto an open menu must skip (rc 1), got $rc"
  [ ! -s "$dir/send.log" ] || fail "the refused ring typed into the menu:"$'\n'"$(cat "$dir/send.log")"
  [ -f "$rec" ] || fail "the refused ring lost the durable inbox record"
  case "$err" in
    *'doorbell refused'*'an open menu or picker is showing'*) ;;
    *) fail "the refused ring must report its reason, got: $err" ;;
  esac
  rc=0; ring "$FX/claude-idle.txt" || rc=$?
  [ "$rc" = 0 ] || fail "the retry ring on a plain empty prompt must deliver, got rc $rc"
  grep -q '^TYPED: : Firstmate instruction waiting' "$dir/send.log" \
    || fail "the retry ring did not type the doorbell:"$'\n'"$(cat "$dir/send.log")"
  [ -f "$rec" ] || fail "the record must stay unhandled until the worker acknowledges it"
  pass "guard: a refused ring keeps the inbox record, reports why, and the next ring delivers"
}

test_open_menu_is_refused
test_draft_is_refused
test_empty_prompt_is_accepted
test_unrecognised_screen_is_refused_for_every_harness
test_real_captures_per_harness
test_production_ring_refuses_without_touching_the_screen
test_refused_ring_keeps_the_record_and_retries
