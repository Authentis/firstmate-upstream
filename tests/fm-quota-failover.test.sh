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
# restart owner is replaced by a recording stub inside a symlinked copy of bin/,
# so the library runs unmodified against its real backend capture path.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-quota-failover)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
trap 'rm -rf -- "$TMP_ROOT"' EXIT

ID=mate-one

# A bin/ whose every entry is the real file except the restart owner.
BIN="$TMP_ROOT/bin"
mkdir -p "$BIN"
for f in "$ROOT"/bin/*; do ln -s "$f" "$BIN/${f##*/}"; done
rm -f "$BIN/fm-secondmate-restart.sh"
cat > "$BIN/fm-secondmate-restart.sh" <<'SH'
#!/usr/bin/env bash
printf '%s|wait=%s|pin=%s\n' "$*" "${FM_SECONDMATE_PERSIST_WAIT:-}" \
  "$(grep "^$FM_TEST_ID " "$FM_CONFIG_OVERRIDE/secondmate-harness")" >> "$FM_TEST_CALLS"
printf 'restarted: %s (stub)\nsummary: 1 of 1 restarted, 0 nudged, 0 unreached\n' "${!#}"
exit "${FM_TEST_RESTART_RC:-0}"
SH
chmod +x "$BIN/fm-secondmate-restart.sh"

FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_TMUX_LOG"
case "${1:-}" in
  capture-pane) cat "$FM_TEST_PANE" ;;
esac
SH
chmod +x "$FAKEBIN/tmux"

new_home() {  # <name>
  HOME_DIR="$TMP_ROOT/$1"
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/config"
  fm_write_secondmate_meta "$HOME_DIR/state/$ID.meta" "$HOME_DIR" "fmtest:fm-$ID"
  printf 'harness-zero\n%s harness-a model-a high\nmate-two harness-b model-b low\n' "$ID" \
    > "$HOME_DIR/config/secondmate-harness"
  printf '%s harness-a model-a high\nmate-two harness-b model-b low\n%s harness-c model-c low\n%s harness-d model-d medium\n' \
    "$ID" "$ID" "$ID" > "$HOME_DIR/config/secondmate-quota-chain"
  : > "$HOME_DIR/calls"
  : > "$HOME_DIR/tmux.log"
}

pane() {  # <text>
  printf '%s\n' "$1" > "$HOME_DIR/pane"
}

# One check in a FRESH process, as each watcher pass is: nothing carries over
# except the durable state file.
tick() {  # <now>
  PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" STATE="$HOME_DIR/state" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_TEST_ID="$ID" \
    FM_TEST_CALLS="$HOME_DIR/calls" FM_TEST_PANE="$HOME_DIR/pane" \
    FM_TEST_TMUX_LOG="$HOME_DIR/tmux.log" \
    FM_QUOTA_FAILOVER_WINDOW_SECS=60 FM_QUOTA_FAILOVER_RESET_SECS=600 \
    bash -c '. "$1/fm-quota-failover-lib.sh"; fm_quota_failover_tick "$2" "$3" "$4"; rc=$?; printf "%s" "$FM_QF_REPORT"; exit "$rc"' \
    _ "$BIN" "$HOME_DIR/state/$ID.meta" "$ID" "$1"
}

pin() { grep "^$ID " "$HOME_DIR/config/secondmate-harness"; }
calls() { grep -c . "$HOME_DIR/calls" || true; }
state_field() { sed -n "s/^$1=//p" "$HOME_DIR/state/.quota-failover-$ID"; }

# --- signatures ------------------------------------------------------------

sig() {
  bash -c '. "$1/fm-quota-failover-lib.sh"; fm_quota_failover_signature "$2"' _ "$BIN" "$1"
}
sig 'API Error: 429 Too Many Requests' || fail "a bare 429 status is a quota signature"
sig '{"error":{"code":"exceeded_current_quota"}}' || fail "exceeded_current_quota is a quota signature"
sig "You've reached your Usage Limit. Try again later." || fail "usage limit matches case-insensitively"
sig 'status=429' || fail "429 after punctuation matches"
! sig 'listening on port 14290' || fail "429 inside a longer number is not a signature"
! sig 'all good, 3 tasks done' || fail "ordinary output is not a signature"
pass "quota signatures match 429, exceeded_current_quota, and usage limit only"

# --- pilot: fake 429, window, advance, restart call --------------------------

new_home pilot
pane 'working...
API Error: 429 {"type":"error","error":{"message":"usage limit reached"}}'

out=$(tick 1000) || fail "first sighting tick failed: $out"
assert_equals "" "$out" "the first sighting reports nothing"
assert_equals 0 "$(calls)" "the first sighting restarts nothing"
assert_equals 1000 "$(state_field first_seen)" "the first sighting is recorded durably"
assert_grep "capture-pane -p -t fmtest:fm-$ID" "$HOME_DIR/tmux.log" "detection reads the recorded endpoint's pane"

out=$(tick 1059) || fail "inside-window tick failed: $out"
assert_equals 0 "$(calls)" "a sighting inside the window restarts nothing"
assert_equals 1000 "$(state_field first_seen)" "the first sighting survives a fresh process"

out=$(tick 1060) || fail "window tick failed: $out"
assert_equals 1 "$(calls)" "a sustained signature restarts once"
assert_equals "--failover $ID|wait=120|pin=$ID harness-c model-c low" "$(head -1 "$HOME_DIR/calls")" \
  "the restart runs persist-first in failover mode after the pin moved to the next link"
assert_equals "$ID harness-c model-c low" "$(pin)" "the pin stays on the next link"
assert_grep 'harness-zero' "$HOME_DIR/config/secondmate-harness" "the unkeyed default line is preserved"
assert_grep 'mate-two harness-b model-b low' "$HOME_DIR/config/secondmate-harness" "another mate's pin is preserved"
assert_contains "$out" "quota failover from chain link 0 to link 1" "the advance is reported"
assert_equals 1 "$(state_field link)" "the new link is recorded"
assert_equals "" "$(state_field first_seen)" "the window re-arms after an advance"
pass "pilot: an injected 429 sustained past the window advances the chain and restarts persist-first"

# The relaunched agent shares the endpoint, so the old error still on screen
# must not start a new window against the next link.
tick 1070 >/dev/null || fail "stale-scrollback tick failed"
tick 1200 >/dev/null
assert_equals 1 "$(calls)" "the replaced agent's error text must not fail the new link over"
assert_equals "" "$(state_field first_seen)" "stale error text records no sighting"
pass "error text left in the reused endpoint's scrollback is not a new sighting"

# A clear capture resets the window; the next sustained sighting advances again.
pane 'all quiet'
tick 1210 >/dev/null || fail "clear tick failed"
pane 'Error: exceeded_current_quota'
tick 1220 >/dev/null
tick 1279 >/dev/null
assert_equals 1 "$(calls)" "a clear capture restarted the window"
out=$(tick 1280)
assert_equals 2 "$(calls)" "the second link fails over to the last"
assert_equals "$ID harness-d model-d medium" "$(pin)" "the pin moved to the last link"

# The last link stays put and re-arms.
pane 'Error: exceeded_current_quota
You have hit your usage limit.'
tick 1300 >/dev/null
out=$(tick 1360)
assert_equals 2 "$(calls)" "an exhausted chain restarts nothing"
assert_contains "$out" "last chain link" "an exhausted chain is reported"
assert_equals "$ID harness-d model-d medium" "$(pin)" "an exhausted chain keeps the last link"
assert_equals 1360 "$(state_field first_seen)" "an exhausted chain re-arms its window"
pass "the chain stays on its last link and re-arms when exhausted"

# --- return to the first link after the pool resets --------------------------

pane 'all quiet'
tick 1400 >/dev/null
tick 1999 >/dev/null
assert_equals 2 "$(calls)" "a clear period shorter than the reset does not return"
out=$(tick 2000)
assert_equals 3 "$(calls)" "a clear period of the reset length returns"
assert_equals "$ID|wait=120|pin=$ID harness-a model-a high" "$(sed -n 3p "$HOME_DIR/calls")" \
  "the return uses the ordinary persist gate on the first link"
assert_equals 0 "$(state_field link)" "the first link is recorded"
assert_contains "$out" "returned to chain link 0" "the return is reported"
pass "a mate returns to the first link after its quota stays clear for the reset period"

# --- a failed restart restores the pin --------------------------------------

new_home failed
pane '429 Too Many Requests'
tick 1000 >/dev/null
out=$(FM_TEST_RESTART_RC=3 tick 1060)
assert_equals 1 "$(calls)" "the failover restart was attempted"
assert_equals "$ID harness-a model-a high" "$(pin)" "a failed restart restores the previous pin"
assert_equals 0 "$(state_field link)" "a failed restart keeps the previous link"
assert_equals 1060 "$(state_field first_seen)" "a failed restart re-arms the window"
assert_contains "$out" "did not complete" "a failed restart is reported"
pass "a failed failover restart restores the previous pin and re-arms"

# --- opt-in by data ---------------------------------------------------------

new_home nochain
printf 'mate-two harness-b model-b low\nmate-two harness-c model-c low\n' > "$HOME_DIR/config/secondmate-quota-chain"
pane '429'
tick 1000 >/dev/null || fail "a mate without a chain must not fail"
tick 5000 >/dev/null
assert_equals 0 "$(calls)" "a mate without a chain is never restarted"
[ ! -s "$HOME_DIR/tmux.log" ] || fail "a mate without a chain must not have its pane read"
pass "a mate without a chain of two links is never read or restarted"

new_home malformed
printf '%s harness-a model-a\n' "$ID" > "$HOME_DIR/config/secondmate-quota-chain"
if out=$(tick 1000); then fail "a malformed chain must fail the check"; fi
assert_contains "$out" "malformed" "a malformed chain is reported"
assert_equals 0 "$(calls)" "a malformed chain restarts nothing"
pass "a malformed chain fails the check instead of selecting around it"
