#!/usr/bin/env bash
# bin/fm-quota-failover-lib.sh: provider-quota failover for a live secondmate.
#
# The pilot: an injected fake 429 in a fake pane must prove detection, the
# sustained window (shortened here), the durable first sighting across fresh
# processes, the chain advance written to the secondmate pin, and the
# persist-first restart call - all before the behavior runs anywhere live.
# Every value below is an invented fixture; no live provider is touched.
#
# The pane is a fake tmux whose capture-pane prints a fixture file, and the
# restart owner is replaced by a stub inside a symlinked copy of bin/ that
# records each call and answers in bin/fm-secondmate-restart.sh's documented
# outcome vocabulary, so the library runs unmodified against its real backend
# capture path.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-quota-failover)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
HOLDER=
trap '[ -z "$HOLDER" ] || kill "$HOLDER" 2>/dev/null; rm -rf -- "$TMP_ROOT"' EXIT
unset FM_SECONDMATE_PERSIST_WAIT FM_QUOTA_FAILOVER_PERSIST_WAIT

ID=mate-one

# A bin/ whose every entry is the real file except the restart owner.
BIN="$TMP_ROOT/bin"
mkdir -p "$BIN"
for f in "$ROOT"/bin/*; do ln -s "$f" "$BIN/${f##*/}"; done
rm -f "$BIN/fm-secondmate-restart.sh"
cat > "$BIN/fm-secondmate-restart.sh" <<'SH'
#!/usr/bin/env bash
if [ -z "${FM_HOME:-}" ]; then
  echo "error: FM_HOME is not set; fm-secondmate-restart refuses to resolve second mates without an explicit firstmate home" >&2
  exit 1
fi
printf '%s|wait=%s|pin=%s\n' "$*" "${FM_SECONDMATE_PERSIST_WAIT:-}" \
  "$(grep "^$FM_TEST_ID " "$FM_CONFIG_OVERRIDE/secondmate-harness")" >> "$FM_TEST_CALLS"
id=${!#}
case "${FM_TEST_RESTART:-ok}" in
  ok)
    printf 'restarted: %s (stub)\nsummary: 1 of 1 restarted, 0 nudged, 0 unreached, 0 held\n' "$id" ;;
  unpersisted)
    printf 'unpersisted: %s: no persist answer within 120s after a sustained provider quota error; restarting anyway\n' "$id"
    printf 'restarted: %s (stub)\nsummary: 1 of 1 restarted, 0 nudged, 0 unreached, 0 held\n' "$id" ;;
  held)
    printf 'held: %s: the request to write down its open work could not be delivered: endpoint busy\n' "$id"
    printf 'summary: 0 of 1 restarted, 0 nudged, 0 unreached, 1 held\n'
    exit 3 ;;
  refused)
    printf "held: %s: the restart was refused before its agent was touched: another lifecycle action is already running for task %s\n" "$id" "$id"
    printf 'summary: 0 of 1 restarted, 0 nudged, 0 unreached, 1 held\n'
    exit 3 ;;
  concurrent)
    # Another relaunch took the control lock after the pin moved, so it
    # relaunched the mate onto that pin, and this restart was refused.
    meta="$FM_STATE_OVERRIDE/$id.meta"
    { grep -v -e '^harness=' -e '^model=' -e '^effort=' "$meta"
      printf 'harness=%s\nmodel=%s\neffort=%s\n' $(grep "^$id " "$FM_CONFIG_OVERRIDE/secondmate-harness" | cut -d' ' -f2-); } > "$meta.new"
    mv -f "$meta.new" "$meta"
    printf "held: %s: the restart was refused before its agent was touched: another lifecycle action is already running for task %s\n" "$id" "$id"
    printf 'summary: 0 of 1 restarted, 0 nudged, 0 unreached, 1 held\n'
    exit 3 ;;
  lockheld)
    # Another lifecycle action takes the control lock as this restart is refused.
    ( . "$FM_TEST_BIN/fm-wake-lib.sh"
      fm_lock_try_acquire "$FM_STATE_OVERRIDE/.control-$id.lock" || exit 1
      : > "$FM_STATE_OVERRIDE/../locked"
      while [ ! -e "$FM_STATE_OVERRIDE/../release" ]; do sleep 0.1; done
      fm_lock_release "$FM_STATE_OVERRIDE/.control-$id.lock" ) </dev/null >/dev/null 2>&1 &
    for _ in $(seq 1 100); do [ -e "$FM_STATE_OVERRIDE/../locked" ] && break; sleep 0.05; done
    printf "held: %s: the restart was refused before its agent was touched: another lifecycle action is already running for task %s\n" "$id" "$id"
    printf 'summary: 0 of 1 restarted, 0 nudged, 0 unreached, 1 held\n'
    exit 3 ;;
  unknown)
    printf "unreached: %s: the restart outcome is unknown: %s's agent was stopped but the replacement did not launch\n" "$id" "$id"
    printf 'summary: 0 of 1 restarted, 0 nudged, 1 unreached, 0 held\n'
    exit 3 ;;
  unsaved)
    # The restart succeeds, and then this home's state can no longer be written.
    chmod 555 "$FM_STATE_OVERRIDE"
    printf 'restarted: %s (stub)\nsummary: 1 of 1 restarted, 0 nudged, 0 unreached, 0 held\n' "$id" ;;
esac
SH
chmod +x "$BIN/fm-secondmate-restart.sh"
# A remote mate's pane capture goes through fm-on.sh; the stub prints the pane.
rm -f "$BIN/fm-on.sh"
cat > "$BIN/fm-on.sh" <<'SH'
#!/usr/bin/env bash
cat "$FM_TEST_PANE"
SH
chmod +x "$BIN/fm-on.sh"

FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_TMUX_LOG"
# capture-pane -S -<n> returns at most the newest <n> rows, as a row-bounded
# backend capture does, so a request for too few rows loses older lines.
case "${1:-}" in
  capture-pane)
    rows=
    while [ "$#" -gt 0 ]; do
      [ "$1" != -S ] || rows=${2#-}
      shift
    done
    if [ -n "$rows" ]; then tail -n "$rows" "$FM_TEST_PANE"; else cat "$FM_TEST_PANE"; fi ;;
esac
SH
chmod +x "$FAKEBIN/tmux"

new_home() {  # <name>
  HOME_DIR="$TMP_ROOT/$1"
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/config"
  fm_write_secondmate_meta "$HOME_DIR/state/$ID.meta" "$HOME_DIR" "fmtest:fm-$ID"
  printf 'harness-zero\n%s claude model-a high\nmate-two kimi model-b low\n' "$ID" \
    > "$HOME_DIR/config/secondmate-harness"
  printf '%s claude model-a high\nmate-two kimi model-b low\n%s codex model-c low\n%s opencode model-d medium\n' \
    "$ID" "$ID" "$ID" > "$HOME_DIR/config/secondmate-quota-chain"
  : > "$HOME_DIR/calls"
  : > "$HOME_DIR/tmux.log"
}

pane() {  # <text>
  printf '%s\n' "$1" > "$HOME_DIR/pane"
}

# The wedged agent answers one more turn with a quota error.
again() {  # [text]
  printf '> turn %s\n%s\n' "$(grep -c '' "$HOME_DIR/pane")" "${1:-429 Too Many Requests}" >> "$HOME_DIR/pane"
}

# One check in a FRESH process, as each watcher pass is: nothing carries over
# except the durable state file. FM_HOME is a plain shell variable there, as
# the watcher's own default is, so the restart owner sees it only when the
# library passes it on.
# shellcheck disable=SC2016 # Expanded by the child shell, not here.
tick() {  # <now>
  env -u FM_HOME PATH="$FAKEBIN:$PATH" STATE="$HOME_DIR/state" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_TEST_ID="$ID" FM_TEST_BIN="$BIN" \
    FM_TEST_CALLS="$HOME_DIR/calls" FM_TEST_PANE="$HOME_DIR/pane" \
    FM_TEST_TMUX_LOG="$HOME_DIR/tmux.log" \
    FM_QUOTA_FAILOVER_WINDOW_SECS=60 FM_QUOTA_FAILOVER_RESET_SECS=600 \
    bash -c 'FM_HOME=$5; . "$1/fm-quota-failover-lib.sh"; fm_quota_failover_tick "$2" "$3" "$4"; rc=$?; printf "%s" "$FM_QF_REPORT"; exit "$rc"' \
    _ "$BIN" "$HOME_DIR/state/$ID.meta" "$ID" "$1" "$HOME_DIR"
}

pin() { grep "^$ID " "$HOME_DIR/config/secondmate-harness"; }
calls() { grep -c . "$HOME_DIR/calls" || true; }
state_field() { sed -n "s/^$1=//p" "$HOME_DIR/state/.quota-failover-$ID"; }

# --- signatures ------------------------------------------------------------

sig() {
  bash -c '. "$1/fm-quota-failover-lib.sh"; fm_quota_failover_signature "$2"' _ "$BIN" "$1"
}
sig 'API Error: 429 Too Many Requests' || fail "an API error carrying status 429 is a quota signature"
sig 'HTTP 429' || fail "an HTTP 429 status is a quota signature"
sig 'request failed with status=429' || fail "a status=429 field is a quota signature"
sig '{"error":{"code":"exceeded_current_quota"}}' || fail "exceeded_current_quota is a quota signature"
sig "You've reached your Usage Limit. Try again later." || fail "a reached usage limit matches case-insensitively"
sig 'Claude usage limit reached. Your limit will reset at 3pm' || fail "a usage-limit-reached notice is a quota signature"
sig "You've hit your weekly limit" || fail "the weekly-limit message is a quota signature"
sig 'You have reached the weekly limit for Claude' || fail "a reached weekly limit is a quota signature"
sig 'Error: weekly limit exceeded, resets Monday' || fail "an exceeded weekly limit is a quota signature"
! sig 'relayed: PR #429 merged' || fail "a PR number 429 is not a quota signature"
! sig 'closes 429 open review threads' || fail "a bare 429 count is not a quota signature"
! sig 'error in issue #429 is fixed' || fail "an issue reference near the word error is not a quota signature"
! sig 'listening on port 14290' || fail "429 inside a longer number is not a signature"
! sig 'checking the usage limit for the plan' || fail "prose about a usage limit is not a signature"
! sig 'checking the weekly budget for the plan' || fail "prose about a weekly budget is not a signature"
! sig 'the weekly report shows limits per model' || fail "weekly-limit prose without an error verb is not a signature"
! sig 'all good, 3 tasks done' || fail "ordinary output is not a signature"
pass "quota signatures need error context: a bare 429, a PR number, or usage-limit prose never counts"

# --- pilot: fake 429, window, advance, restart call --------------------------

new_home pilot
chmod 640 "$HOME_DIR/config/secondmate-harness"
pane 'working...
API Error: 429 {"type":"error","error":{"message":"usage limit reached"}}'

out=$(tick 1000) || fail "first sighting tick failed: $out"
assert_equals "" "$out" "the first sighting reports nothing"
assert_equals 0 "$(calls)" "the first sighting restarts nothing"
assert_equals 1000 "$(state_field first_seen)" "the first sighting is recorded durably"
assert_grep "capture-pane -p -t fmtest:fm-$ID -S -" "$HOME_DIR/tmux.log" "detection reads the recorded endpoint's newest lines"

again 'API Error: 429 {"type":"error","error":{"message":"usage limit reached"}}'
out=$(tick 1059) || fail "inside-window tick failed: $out"
assert_equals 0 "$(calls)" "a recurring error inside the window restarts nothing"
assert_equals 1000 "$(state_field first_seen)" "the first sighting survives a fresh process"

out=$(tick 1060) || fail "window tick failed: $out"
assert_equals 1 "$(calls)" "a sustained signature restarts once"
assert_equals "--failover $ID|wait=120|pin=$ID codex model-c low" "$(head -1 "$HOME_DIR/calls")" \
  "the restart runs persist-first in failover mode after the pin moved to the next link"
assert_equals "$ID codex model-c low" "$(pin)" "the pin stays on the next link"
assert_grep 'harness-zero' "$HOME_DIR/config/secondmate-harness" "the unkeyed default line is preserved"
assert_grep 'mate-two kimi model-b low' "$HOME_DIR/config/secondmate-harness" "another mate's pin is preserved"
[ -n "$(find "$HOME_DIR/config/secondmate-harness" -perm 640)" ] \
  || fail "the rewritten secondmate-harness keeps its original mode"
assert_contains "$out" "quota failover from chain link 0 to link 1" "the advance is reported"
assert_not_contains "$out" "persist answer" "a restart that got its persist answer does not claim otherwise"
assert_equals 1 "$(state_field link)" "the new link is recorded"
assert_equals "" "$(state_field first_seen)" "the window re-arms after an advance"
pass "pilot: an injected 429 sustained past the window advances the chain and restarts persist-first"

# The relaunched agent shares the endpoint, so the old error still on screen
# after the restart must not start a new window against the next link at once,
# but the stale record expires after one window instead of hiding it for good.
tick 1070 >/dev/null || fail "stale-scrollback tick failed"
tick 1119 >/dev/null
assert_equals 1 "$(calls)" "the replaced agent's error text must not fail the new link over"
assert_equals "" "$(state_field first_seen)" "stale error text records no sighting inside its window"
tick 1120 >/dev/null
tick 1200 >/dev/null
assert_equals 1 "$(calls)" "the old error, unchanged after its stale record expires, must not fail the new link over"
assert_equals "" "$(state_field recurred)" "an unchanged old error line never recurs"
pass "error text left in the reused endpoint's scrollback never counts as a sustained error"

# A clear capture resets the window; the next sustained sighting advances again.
pane 'all quiet'
tick 1210 >/dev/null || fail "clear tick failed"
assert_equals "" "$(state_field first_seen)" "a clear capture resets the window"
pane 'Error: exceeded_current_quota'
tick 1220 >/dev/null
again 'Error: exceeded_current_quota'
tick 1279 >/dev/null
assert_equals 1 "$(calls)" "a clear capture restarted the window"
out=$(tick 1280)
assert_equals 2 "$(calls)" "the second link fails over to the last"
assert_equals "$ID opencode model-d medium" "$(pin)" "the pin moved to the last link"

# The last link stays put and reports exhaustion once per episode.
pane 'Error: exceeded_current_quota
You have hit your usage limit.'
tick 1290 >/dev/null
again 'You have hit your usage limit.'
out=$(tick 1350)
assert_equals 2 "$(calls)" "an exhausted chain restarts nothing before link 0's reset"
assert_contains "$out" "last chain link" "an exhausted chain is reported"
assert_equals "$ID opencode model-d medium" "$(pin)" "an exhausted chain keeps the last link"
again 'You have hit your usage limit.'
out=$(tick 1410)
assert_equals "" "$out" "an exhausted chain is reported once, not every window"
out=$(tick 1659)
assert_equals "" "$out" "an exhausted chain stays quiet until link 0's reset period passes"
assert_equals 2 "$(calls)" "an exhausted chain still restarts nothing"
pass "an exhausted chain stays on its last link and reports once"

# Link 0 was left at 1060, so its pool's reset period ends at 1660.
out=$(tick 1660)
assert_equals 3 "$(calls)" "an exhausted chain retries link 0 after that link's reset period"
assert_equals "--failover $ID|wait=120|pin=$ID claude model-a high" "$(sed -n 3p "$HOME_DIR/calls")" \
  "the move back from a wedged last link proceeds in failover mode onto link 0"
assert_equals 0 "$(state_field link)" "link 0 is recorded"
assert_contains "$out" "back to chain link 0" "the move back is reported"
pass "a mate wedged on its last link returns to link 0 once that pool's reset period has passed"

# --- one static error line is not a sustained quota error --------------------

new_home static
pane 'relayed from crew-one: API Error: 429 Too Many Requests'
tick 1000 >/dev/null
assert_equals 1000 "$(state_field first_seen)" "the relayed error line is sighted once"
tick 1060 >/dev/null
tick 1400 >/dev/null
assert_equals 0 "$(calls)" "one unchanged error line seen again past the window must not fail the mate over"
pass "a single static quota error line, such as a relayed crew error, never advances the chain"

# A spinner or status line redrawing in place below a static error is not a
# new error.
new_home staticredraw
for t in 1000 1030 1060 1090 1120 1400; do
  pane "relayed from crew-one: API Error: 429 Too Many Requests
* Working ($((t - 997))s)
? for shortcuts"
  tick "$t" >/dev/null
done
assert_equals 1000 "$(state_field first_seen)" "the relayed error line is sighted once"
assert_equals "" "$(state_field recurred)" "a redraw below a static error line never recurs"
assert_equals 0 "$(calls)" "a static error line with only a ticking spinner below it must not fail the mate over"
pass "a static quota error line with only an in-place redraw below it never advances the chain"

# A periodic doorbell wedge seen alternately mid-turn (spinner) and after the
# turn (error) still recurs: the new error replaces the spinner in place.
new_home phases
: > "$HOME_DIR/history"
for n in 1 2 3 4 5 6; do
  printf '> check inbox\nreading inbox\nError: 429 Too Many Requests\n' >> "$HOME_DIR/history"
done
spinner_phase() {
  { cat "$HOME_DIR/history"; printf '> check inbox\nreading inbox\n* Working\n'; } > "$HOME_DIR/pane"
}
error_phase() {
  printf '> check inbox\nreading inbox\nError: 429 Too Many Requests\n' >> "$HOME_DIR/history"
  cat "$HOME_DIR/history" > "$HOME_DIR/pane"
}
cat "$HOME_DIR/history" > "$HOME_DIR/pane"
tick 1000 >/dev/null
assert_equals 1000 "$(state_field first_seen)" "the periodic wedge is sighted"
spinner_phase; tick 1020 >/dev/null
error_phase; tick 1040 >/dev/null
assert_equals 1 "$(state_field recurred)" "an error replacing the spinner in place recurs"
spinner_phase; tick 1060 >/dev/null
assert_equals 1 "$(calls)" "a periodic wedge alternating between spinner and error fails over"
pass "a periodic wedge captured alternately mid-turn and after the error still fails over"

# A transient line below a static error that appears and clears moves the full
# window's top edge; neither the shifted lines above the error nor an older
# error exposed at the top is a new error.
for variant in plain older; do
  new_home "transient-$variant"
  old=$(printf 'old line %s\n' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20)
  [ "$variant" = plain ] || old="$old
Error: exceeded_current_quota
$(printf 'reply line %s\n' 1 2 3 4 5 6 7 8 9)"
  quiet="$old
relayed from crew-one: API Error: 429 Too Many Requests
? for shortcuts"
  for t in 1000 1030 1060 1090 1120 1400; do
    case "$t" in 1030|1090) pane "$quiet
* Working" ;; *) pane "$quiet" ;; esac
    tick "$t" >/dev/null
  done
  assert_equals "" "$(state_field recurred)" "a transient line below a static error never recurs ($variant)"
  assert_equals 0 "$(calls)" "a transient line below a static error must not fail the mate over ($variant)"
done
pass "a static quota error line with a transient line appearing and clearing below it never advances the chain"

# The lines around static errors scrolling - the line before one leaving the
# newest lines, then an older error leaving them too - is not a new error.
new_home staticscroll
relayed='crew-two reported:
Error: exceeded_current_quota
relayed from crew-one: API Error: 429 Too Many Requests'
pane "$relayed"
tick 1000 >/dev/null
assert_equals 1000 "$(state_field first_seen)" "the relayed error lines are sighted once"
pane "$relayed
$(printf 'reply line %s\n' 1 2 3 4 5 6 7 8 9 10)"
tick 1030 >/dev/null
pane "$relayed
$(printf 'reply line %s\n' 1 2 3 4 5 6 7 8 9 10 11)"
tick 1040 >/dev/null
tick 1100 >/dev/null
tick 1400 >/dev/null
assert_equals "" "$(state_field recurred)" "scrolling static error lines never recur"
assert_equals 0 "$(calls)" "static error lines scrolled to the top of the newest lines must not fail the mate over"
pass "static quota error lines scrolling within the newest lines never advance the chain"

# --- the wedge: the same error every turn through a full window --------------

# Each turn adds the wake that reached the agent and the identical error it
# answered with, above a fixed footer, as a harness TUI does.
turn() {  # <n>
  printf '> wake %s\nAPI Error: 429 Too Many Requests\n' "$1" >> "$HOME_DIR/history"
  { cat "$HOME_DIR/history"; printf -- '-----\n? for shortcuts\n'; } > "$HOME_DIR/pane"
}
newest_errors() { grep -v '^[[:space:]]*$' "$HOME_DIR/pane" | tail -n 12 | grep -c 'API Error: 429'; }

new_home steady
: > "$HOME_DIR/history"
for n in 1 2 3 4 5 6 7 8; do turn "$n"; done
assert_equals 5 "$(newest_errors)" "the fixture starts with the newest lines already full of the error"
tick 1000 >/dev/null
assert_equals 1000 "$(state_field first_seen)" "a wedge already under way is sighted"
turn 9; tick 1020 >/dev/null
turn 10; tick 1040 >/dev/null
turn 11; tick 1059 >/dev/null
assert_equals 0 "$(calls)" "the wedge does not advance inside the window"
turn 12
assert_equals 5 "$(newest_errors)" "the newest lines stay full of the same error across the window"
out=$(tick 1060)
assert_equals 1 "$(calls)" "the same error every turn through a full window advances the chain"
assert_contains "$out" "quota failover from chain link 0 to link 1" "the wedge failover is reported"
pass "a wedged agent repeating one identical error through a full window still fails over"

# --- return to the first link after the pool resets --------------------------

new_home return
pane '429 Too Many Requests'
tick 1000 >/dev/null
again
tick 1060 >/dev/null
assert_equals 1 "$(calls)" "the return case first fails over"
pane 'all quiet'
tick 1100 >/dev/null
tick 1659 >/dev/null
assert_equals 1 "$(calls)" "a clear period shorter than the reset does not return"
out=$(tick 1660)
assert_equals 2 "$(calls)" "a clear period of the reset length returns"
assert_equals "--no-nudge $ID|wait=120|pin=$ID claude model-a high" "$(sed -n 2p "$HOME_DIR/calls")" \
  "the return keeps the persist gate within the failover wait, and never sends the re-read message"
assert_equals 0 "$(state_field link)" "the first link is recorded"
assert_contains "$out" "returned to chain link 0" "the return is reported"
pass "a mate returns to the first link after its quota stays clear for the reset period"

# --- only the newest output counts -------------------------------------------

new_home newest
pane "API Error: 429 Too Many Requests
$(printf 'healthy line %s\n' 1 2 3 4 5 6 7 8 9 10 11 12)"
tick 1000 >/dev/null
tick 2000 >/dev/null
assert_equals "" "$(state_field first_seen)" "an error followed by twelve newer lines is not a sighting"
# Blank rows between them spread those lines over more than twelve raw rows.
pane "API Error: 429 Too Many Requests

$(printf 'healthy line %s\n\n' 1 2 3 4 5 6 7 8 9 10 11)"
tick 2010 >/dev/null
assert_equals 2010 "$(state_field first_seen)" "an error among the twelve newest non-blank lines is a sighting"
pane 'relayed: PR #429 merged'
tick 2020 >/dev/null
assert_equals "" "$(state_field first_seen)" "a PR number on screen is not a sighting"
assert_equals 0 "$(calls)" "nothing here is restarted"
pass "only a quota error among the twelve newest pane lines counts"

# An empty stale record proves nothing about the new link.
new_home emptystale
printf 'link=0\nstale_until=9999\n' > "$HOME_DIR/state/.quota-failover-$ID"
: > "$HOME_DIR/state/.quota-failover-$ID.stale"
pane 'HTTP 429'
tick 1000 >/dev/null
assert_equals 1000 "$(state_field first_seen)" "an empty stale record must not suppress a sighting"
pass "an empty stale record suppresses nothing"

# A repeated error is a new occurrence even while its first copy is stale.
new_home repeat
pane 'Error: exceeded_current_quota'
tick 1000 >/dev/null
again 'Error: exceeded_current_quota'
tick 1060 >/dev/null
assert_equals 1 "$(calls)" "the repeat case first fails over"
again 'Error: exceeded_current_quota'
tick 1070 >/dev/null
assert_equals 1070 "$(state_field first_seen)" "a repeat of the stale error is a sighting"
pass "a quota error that keeps occurring after a relaunch is a sighting"

# --- a failed restart --------------------------------------------------------

new_home held
printf 'harness-zero\n%s   claude  model-a   high\n' "$ID" > "$HOME_DIR/config/secondmate-harness"
pane '429 Too Many Requests'
tick 1000 >/dev/null
again
out=$(FM_TEST_RESTART=held tick 1060)
assert_equals 1 "$(calls)" "the failover restart was attempted"
assert_equals "$ID   claude  model-a   high" "$(pin)" "a refused restart restores the exact prior pin line"
assert_equals 0 "$(state_field link)" "a refused restart keeps the previous link"
assert_equals 1060 "$(state_field first_seen)" "a refused restart re-arms the window"
assert_contains "$out" "did not complete; pin restored to link 0: held: $ID:" "a refused restart is reported with its reason"
pass "a failover restart refused before the agent was touched restores the exact prior pin and re-arms"

again
out=$(FM_TEST_RESTART=held tick 1120)
assert_equals 2 "$(calls)" "a refused failover is retried the next window"
assert_equals "" "$out" "a repeated refusal is reported once per episode, not every window"
pass "a refused failover retries each window and reports once"

new_home unpinned
printf 'harness-zero\n' > "$HOME_DIR/config/secondmate-harness"
pane '429 Too Many Requests'
tick 1000 >/dev/null
again
FM_TEST_RESTART=held tick 1060 >/dev/null
assert_equals "--failover $ID|wait=120|pin=$ID codex model-c low" "$(head -1 "$HOME_DIR/calls")" \
  "the restart ran on the next link's pin"
assert_equals "" "$(pin)" "a refused restart removes a keyed pin that did not exist before"
assert_equals 'harness-zero' "$(cat "$HOME_DIR/config/secondmate-harness")" "the default line is untouched"
pass "a refused restart of a mate without a keyed pin leaves it without one"

new_home unknown
pane '429 Too Many Requests'
tick 1000 >/dev/null
again
out=$(FM_TEST_RESTART=unknown tick 1060)
assert_equals "$ID codex model-c low" "$(pin)" "an unknown restart outcome keeps the target pin"
assert_equals 1 "$(state_field link)" "an unknown restart outcome records the target link"
assert_equals 1060 "$(state_field left0)" "an unknown restart outcome still counts as leaving link 0"
assert_contains "$out" "unknown restart outcome; pin kept on link 1: unreached: $ID:" "an unknown outcome is reported"
pass "an unknown restart outcome keeps the pin on the target link instead of the exhausted one"

# A relaunch of the mate started after the pin moved and before the quota
# restart's own relaunch, so it runs the target link and this restart is refused.
new_home concurrent
pane '429 Too Many Requests'
tick 1000 >/dev/null
again
out=$(FM_TEST_RESTART=concurrent tick 1060)
assert_equals "$ID codex model-c low" "$(pin)" "a refusal must not restore the pin under a mate running the target link"
assert_equals 1 "$(state_field link)" "the target link stays recorded"
assert_contains "$out" "pin kept on link 1: unreached: $ID: a concurrent relaunch already runs the mate on the target link" \
  "the kept pin is reported as an unknown outcome"
pass "a refusal caused by a concurrent relaunch onto the target link keeps the target pin"

# A remote mate's relaunch never takes this home's control lock, so one may
# already have consumed the target pin while this home's record still shows
# the previous link.
new_home remote
printf 'remote_host=host.invalid\n' >> "$HOME_DIR/state/$ID.meta"
pane '429 Too Many Requests'
tick 1000 >/dev/null
again
out=$(FM_TEST_RESTART=refused tick 1060)
assert_equals "$ID codex model-c low" "$(pin)" "a remote mate's refused relaunch must not restore the pin"
assert_equals 1 "$(state_field link)" "the target link stays recorded for a remote mate"
assert_contains "$out" "pin kept on link 1: unreached: $ID: a remote relaunch does not take the control lock" \
  "the kept remote pin is reported as an unknown outcome"
pass "a refused relaunch of a remote mate keeps the target pin"

# A remote mate held before any relaunch ran still runs the prior link.
new_home remoteheld
printf 'remote_host=host.invalid\n' >> "$HOME_DIR/state/$ID.meta"
pane '429 Too Many Requests'
tick 1000 >/dev/null
again
out=$(FM_TEST_RESTART=held tick 1060)
assert_equals "$ID claude model-a high" "$(pin)" "a remote mate held before its relaunch gets its prior pin back"
assert_equals 0 "$(state_field link)" "a remote mate held before its relaunch keeps the previous link"
assert_contains "$out" "did not complete; pin restored to link 0: held: $ID:" "the remote hold is reported as a restored refusal"
pass "a remote mate held before any relaunch ran restores the prior pin and link"

# The same hold on the way to the last link must not record that link while
# the mate still runs its exhausted one, or every later window would find the
# chain exhausted and restart nothing until link 0's reset period.
new_home remotelast
printf 'remote_host=host.invalid\n' >> "$HOME_DIR/state/$ID.meta"
pane '429 Too Many Requests'
tick 1000 >/dev/null
again
tick 1060 >/dev/null
assert_equals 1 "$(state_field link)" "the remote mate first fails over to link 1"
pane 'all quiet'
tick 1210 >/dev/null
pane 'Error: exceeded_current_quota'
tick 1220 >/dev/null
again 'Error: exceeded_current_quota'
out=$(FM_TEST_RESTART=held tick 1280)
assert_equals 2 "$(calls)" "the failover to the last link was attempted"
assert_equals "$ID codex model-c low" "$(pin)" "a remote hold on the way to the last link restores link 1's pin"
assert_equals 1 "$(state_field link)" "a remote hold on the way to the last link keeps link 1 recorded"
assert_contains "$out" "did not complete; pin restored to link 1: held: $ID:" "the remote hold is reported as a restored refusal"
again 'Error: exceeded_current_quota'
out=$(tick 1340)
assert_equals 3 "$(calls)" "the held failover to the last link is retried the next window"
assert_equals "$ID opencode model-d medium" "$(pin)" "the retried failover reaches the last link"
assert_equals 2 "$(state_field link)" "the last link is recorded once the mate was relaunched onto it"
assert_not_contains "$out" "last chain link" "the retry is a failover, not an exhausted chain"
pass "a remote mate held on its way to the last link retries instead of stranding on the exhausted link"

# A remote return that cannot confirm its open work keeps the mate where it
# is and retries after the next clear period.
new_home remotereturn
printf 'remote_host=host.invalid\n' >> "$HOME_DIR/state/$ID.meta"
pane '429 Too Many Requests'
tick 1000 >/dev/null
again
tick 1060 >/dev/null
pane 'all quiet'
tick 1100 >/dev/null
FM_TEST_RESTART=held tick 1660 >/dev/null
assert_equals 2 "$(calls)" "the return was attempted"
assert_equals "$ID codex model-c low" "$(pin)" "a held remote return restores link 1's pin"
assert_equals 1 "$(state_field link)" "a held remote return keeps link 1 recorded"
tick 2259 >/dev/null
assert_equals 2 "$(calls)" "a held return waits a full clear period before retrying"
out=$(tick 2260)
assert_equals 3 "$(calls)" "a held remote return is retried after the next clear period"
assert_equals 0 "$(state_field link)" "the retried return reaches link 0"
assert_contains "$out" "returned to chain link 0" "the retried return is reported"
pass "a held remote return keeps the mate on its link and retries after the next clear period"

# Another lifecycle action holds the control lock when the refusal would restore.
new_home restorelock
pane '429 Too Many Requests'
tick 1000 >/dev/null
again
out=$(FM_TEST_RESTART=lockheld tick 1060)
: > "$HOME_DIR/release"
assert_equals "$ID codex model-c low" "$(pin)" "the pin is never restored without the control lock"
assert_equals 1 "$(state_field link)" "the target link stays recorded when the restore cannot take the lock"
assert_contains "$out" "another lifecycle action held the control lock, so the target pin was kept" \
  "the skipped restore is reported"
pass "a refusal restores the prior pin only while holding the mate's control lock"

new_home refused
pane '429 Too Many Requests'
tick 1000 >/dev/null
again
out=$(FM_TEST_RESTART=refused tick 1060)
assert_equals "$ID claude model-a high" "$(pin)" "a relaunch refused before the stop restores the prior pin"
assert_equals 0 "$(state_field link)" "a relaunch refused before the stop keeps the previous link"
assert_contains "$out" "did not complete; pin restored to link 0: held: $ID: the restart was refused before its agent was touched" \
  "a relaunch refused before the stop is reported as a restored refusal"
pass "a relaunch the control plane refused before stopping the agent restores the prior pin"

# The pin file cannot be rewritten, so the pin never moves off link 0.
new_home pinunwritable
pane '429 Too Many Requests'
tick 1000 >/dev/null
again
chmod 555 "$HOME_DIR/config"
out=$(tick 1060 2>/dev/null)
chmod 755 "$HOME_DIR/config"
assert_equals 0 "$(calls)" "a failover whose pin was never written restarts nothing"
assert_equals "$ID claude model-a high" "$(pin)" "the unwritten pin stays on link 0"
assert_equals 0 "$(state_field link)" "the state keeps link 0 when the target pin was never written"
assert_contains "$out" "did not complete; pin restored to link 0: the secondmate pin could not be rewritten" \
  "the failed pin write is reported as a refusal, not an unknown outcome"
pass "a failover whose target pin could not be written keeps the state on the current link"

# A link a secondmate relaunch would refuse is never pinned or restarted onto.
for bad in 'muse model-c low' 'no-such-harness model-c low' 'codex model-c ultra'; do
  new_home "badlink-${bad%% *}"
  printf '%s claude model-a high\n%s %s\n' "$ID" "$ID" "$bad" > "$HOME_DIR/config/secondmate-quota-chain"
  pane '429 Too Many Requests'
  tick 1000 >/dev/null
  again
  out=$(tick 1060)
  assert_equals 0 "$(calls)" "an invalid chain link is never restarted onto ($bad)"
  assert_equals "$ID claude model-a high" "$(pin)" "an invalid chain link is never pinned ($bad)"
  assert_equals 0 "$(state_field link)" "an invalid chain link keeps the current link ($bad)"
  assert_contains "$out" "did not complete; pin restored to link 0:" "an invalid chain link is reported ($bad)"
done
pass "a chain link a secondmate relaunch would refuse is never pinned"

# --- serialization with other relaunches and other pin rewrites ---------------

# hold_lock <lock> <script>: hold <lock> in a live background process while
# <script> runs, then release it.
hold_lock() {
  rm -f "$HOME_DIR/release" "$HOME_DIR/held"
  (
    # shellcheck source=bin/fm-wake-lib.sh
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$1" || exit 1
    : > "$HOME_DIR/held"
    eval "$2"
    fm_lock_release "$1"
  ) &
  # shellcheck disable=SC2031 # The background PID is captured immediately in this shell.
  HOLDER=$!
  for _ in $(seq 1 100); do [ -e "$HOME_DIR/held" ] && break; sleep 0.05; done
  [ -e "$HOME_DIR/held" ] || fail "the lock holder never acquired $1"
}

# A relaunch of the same mate already holds the control plane's lock.
new_home controllock
pane '429 Too Many Requests'
tick 1000 >/dev/null
# shellcheck disable=SC2016 # Expanded by the holder, not here.
hold_lock "$HOME_DIR/state/.control-$ID.lock" 'while [ ! -e "$HOME_DIR/release" ]; do sleep 0.1; done'
again
out=$(tick 1060)
assert_equals 0 "$(calls)" "a failover must not restart a mate another relaunch is handling"
assert_equals "$ID claude model-a high" "$(pin)" "a failover must not move the pin under another relaunch"
assert_contains "$out" "another lifecycle action is already running for $ID" "the held control lock is reported"
: > "$HOME_DIR/release"; wait "$HOLDER"; HOLDER=
again
tick 1120 >/dev/null
assert_equals 1 "$(calls)" "the failover is retried once the other relaunch is done"
assert_equals "$ID codex model-c low" "$(pin)" "the retried failover moves the pin"
pass "a failover never moves the pin while another relaunch of the mate holds its control lock"

# Another pass rewrites the file from what it read, while this one advances.
new_home pinlock
pane '429 Too Many Requests'
tick 1000 >/dev/null
# shellcheck disable=SC2016 # Expanded by the holder, not here.
hold_lock "$HOME_DIR/state/.quota-failover-pin.lock" '
  read_before=$(cat "$HOME_DIR/config/secondmate-harness")
  sleep 2
  printf "%s\n" "$read_before" | sed "s/^mate-two .*/mate-two codex model-e high/" > "$HOME_DIR/config/other-pass"
  cat "$HOME_DIR/config/other-pass" > "$HOME_DIR/config/secondmate-harness"'
again
tick 1060 >/dev/null
wait "$HOLDER"; HOLDER=
assert_equals 1 "$(calls)" "the failover ran"
assert_equals "$ID codex model-c low" "$(pin)" "the advance survives another pass's rewrite"
assert_grep 'mate-two codex model-e high' "$HOME_DIR/config/secondmate-harness" "the other pass's rewrite survives the advance"
pass "overlapping pin rewrites are serialized and never lose each other's update"

# --- a failed final save after the restart ----------------------------------

new_home unsaved
pane '429 Too Many Requests'
tick 1000 >/dev/null
again
out=$(FM_TEST_RESTART=unsaved tick 1060 2>/dev/null); rc=$?
chmod 755 "$HOME_DIR/state"
[ "$rc" -eq 0 ] || fail "a failover that restarted the mate must not be a liveness error (exit $rc): $out"
assert_contains "$out" "check: secondmate $ID quota failover from chain link 0 to link 1" "the completed failover is still reported"
assert_contains "$out" "quota failover state for $ID could not be saved" "the failed save is reported with it"
pass "a failed state save after a completed failover is reported as part of its check"

new_home unpersisted
pane '429 Too Many Requests'
tick 1000 >/dev/null
for t in 1010 1020 1030 1040 1050 1059; do again; tick "$t" >/dev/null; done
assert_equals 0 "$(calls)" "turns inside the window restart nothing"
again
again
out=$(FM_TEST_RESTART=unpersisted tick 1060)
assert_contains "$out" "quota failover from chain link 0 to link 1" "the restart is reported"
assert_contains "$out" "without a persist answer" "a restart without a persist answer says so"
pass "a failover restart made without a persist answer says so"

# --- one failover at a time per mate ----------------------------------------

new_home locked
pane '429 Too Many Requests'
tick 1000 >/dev/null
(
  STATE="$HOME_DIR/state"
  # shellcheck source=bin/fm-wake-lib.sh
  . "$ROOT/bin/fm-wake-lib.sh"
  fm_lock_try_acquire "$HOME_DIR/state/.quota-failover-$ID.lock" || exit 1
  : > "$HOME_DIR/held"
  while :; do sleep 0.2; done
) &
# shellcheck disable=SC2031 # $! is read here, in the parent, after the holder forks.
HOLDER=$!
for _ in $(seq 1 100); do [ -e "$HOME_DIR/held" ] && break; sleep 0.05; done
[ -e "$HOME_DIR/held" ] || fail "the lock holder never acquired the failover lock"
again
out=$(tick 1060) || fail "a skipped tick must not fail: $out"
assert_equals "" "$out" "a mate whose failover is in flight is skipped silently"
assert_equals 0 "$(calls)" "a concurrent pass must not start a second failover"
assert_equals 1000 "$(state_field first_seen)" "a skipped pass leaves the state alone"
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
HOLDER=
out=$(tick 1061)
assert_equals 1 "$(calls)" "a lock left by a dead pass is recovered"
pass "a pass skips a mate whose failover is held by another live pass"

# --- opt-in by data ---------------------------------------------------------

new_home nochain
printf 'mate-two kimi model-b low\nmate-two codex model-c low\n' > "$HOME_DIR/config/secondmate-quota-chain"
pane '429 Too Many Requests'
tick 1000 >/dev/null || fail "a mate without a chain must not fail"
tick 5000 >/dev/null
assert_equals 0 "$(calls)" "a mate without a chain is never restarted"
[ ! -s "$HOME_DIR/tmux.log" ] || fail "a mate without a chain must not have its pane read"
pass "a mate without a chain of two links is never read or restarted"

new_home malformed
printf '%s claude model-a\n%s codex model-c low\n' "$ID" "$ID" > "$HOME_DIR/config/secondmate-quota-chain"
pane '429 Too Many Requests'
out=$(tick 1000) || fail "a malformed chain must not fail the watcher's check: $out"
assert_contains "$out" "malformed" "a malformed chain is reported"
out=$(tick 1060) || fail "a repeated malformed check must not fail: $out"
assert_equals "" "$out" "a malformed chain is reported once"
assert_equals 0 "$(calls)" "a malformed chain restarts nothing"
[ ! -s "$HOME_DIR/tmux.log" ] || fail "a mate with a malformed chain must not have its pane read"
pass "a malformed chain stops only that mate's failover and is reported once"

new_home othermalformed
printf '%s claude model-a high\nmate-two kimi\n%s codex model-c low\n' "$ID" "$ID" \
  > "$HOME_DIR/config/secondmate-quota-chain"
pane '429 Too Many Requests'
tick 1000 >/dev/null || fail "another mate's malformed line must not fail this mate's check"
again
out=$(tick 1060)
assert_equals 1 "$(calls)" "another mate's malformed line does not stop this mate's failover"
assert_contains "$out" "quota failover from chain link 0 to link 1" "this mate still fails over"
pass "a malformed line for another mate leaves this mate's chain working"
