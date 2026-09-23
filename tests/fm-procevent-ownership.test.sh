#!/usr/bin/env bash
# Behavior tests for process-to-event source ownership: cross-home claims,
# stale and reused-pid reclamation, launch confirmation and its failure wakes,
# and the runner's argv, stderr, exit-status, and output bounds. Shared
# fixtures and the delivery-durability boundary are described in
# tests/procevent-helpers.sh and tests/fm-procevent.test.sh.
set -u

# shellcheck source=tests/procevent-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/procevent-helpers.sh"

# --- two homes cannot both own one canonical source -------------------------
HA="$TMP_ROOT/ha"; HB="$TMP_ROOT/hb"; new_home "$HA"; new_home "$HB"
TRIG2="$TMP_ROOT/trigger-two"
pe_register "$HA" lavish shared-src -- "$BLOCKER" "$TRIG2" "shared" >/dev/null
pe_register "$HB" lavish shared-src -- "$BLOCKER" "$TRIG2" "shared" >/dev/null
pe "$HA" reconcile >/dev/null
sleep 0.5
out=$(pe "$HB" start shared-src)
assert_contains "$out" "already owned" "a second home cannot own a source another home already owns"
[ -z "$(wake_payloads "$HB")" ] || fail "the losing home published an event"
pass "one owner per canonical source across homes"

# A source whose child never completes must not survive retirement. This is the
# leak that reparented four orphaned runners: the fixture directory was removed
# while the detached child kept blocking, with nothing left to reap it.
runner_pid=$(sed -n '2p' "$FM_PROCEVENT_CLAIM_ROOT/shared-src.claim" 2>/dev/null)
[ -n "$runner_pid" ] || fail "no runner pid recorded for the blocked source"
kill -0 "$runner_pid" 2>/dev/null || fail "the blocked runner is not live before retirement"
pe "$HA" retire shared-src >/dev/null
for _ in $(seq 1 40); do kill -0 "$runner_pid" 2>/dev/null || break; sleep 0.1; done
kill -0 "$runner_pid" 2>/dev/null && fail "retire left the blocked runner alive"
assert_absent "$FM_PROCEVENT_CLAIM_ROOT/shared-src.claim" "retire releases the claim"
pass "retiring a never-completing source stops its runner and its blocked child"

# reconcile must also stop a runner whose registration was removed out from under it.
TRIG4="$TMP_ROOT/trigger-four"
HZ="$TMP_ROOT/hz"; new_home "$HZ"
pe_register "$HZ" lavish orphan-src -- "$BLOCKER" "$TRIG4" "orphan" >/dev/null
pe "$HZ" reconcile >/dev/null
sleep 0.5
orphan_pid=$(sed -n '2p' "$FM_PROCEVENT_CLAIM_ROOT/orphan-src.claim" 2>/dev/null)
if [ -z "$orphan_pid" ] || ! kill -0 "$orphan_pid" 2>/dev/null; then
  fail "orphan fixture runner did not start"
fi
rm -f "$HZ/state/procevent/orphan-src.source"
out=$(pe "$HZ" reconcile)
assert_contains "$out" "stopped=1" "reconcile stops a runner whose registration was removed"
for _ in $(seq 1 40); do kill -0 "$orphan_pid" 2>/dev/null || break; sleep 0.1; done
kill -0 "$orphan_pid" 2>/dev/null && fail "reconcile left an orphaned runner alive"
pass "reconcile reaps a runner whose source registration is gone"

# --- a stale claim is reclaimable, a live one is not ------------------------
CLAIM="$FM_PROCEVENT_CLAIM_ROOT/stale-src.claim"
mkdir -p "$FM_PROCEVENT_CLAIM_ROOT"
HC="$TMP_ROOT/hc"; new_home "$HC"
printf '%s\n%s\nstale-token\nstale-identity\n' "$HC" "999999" > "$CLAIM"
chmod 0600 "$CLAIM"
pe_register "$HC" lavish stale-src -- /bin/echo recovered >/dev/null
printf 'partial sensitive output\n' > "$HC/state/procevent/.stale-src.stale-token.output"
chmod 0600 "$HC/state/procevent/.stale-src.stale-token.output"
out=$(pe "$HC" start stale-src)
assert_contains "$out" "captured:" "a claim whose runner is gone is reclaimable"
assert_absent "$CLAIM" "the replacement claim generation is released after completion"
assert_absent "$HC/state/procevent/.stale-src.stale-token.output" "stale claim recovery removes its abandoned staging generation"
pass "stale-owner recovery removes abandoned output without displacing a live owner"

HC_OLD="$TMP_ROOT/hc-old"; new_home "$HC_OLD"
HC_NEW="$TMP_ROOT/hc-new"; new_home "$HC_NEW"
HC_OLD_STATE="$TMP_ROOT/hc-old-state"
mkdir -p "$HC_OLD_STATE/procevent"
printf '%s\n%s\ncross-home-token\ncross-home-identity\n%s\n' \
  "$HC_OLD" "999999" "$HC_OLD_STATE/procevent" > "$FM_PROCEVENT_CLAIM_ROOT/cross-home-src.claim"
chmod 0600 "$FM_PROCEVENT_CLAIM_ROOT/cross-home-src.claim"
printf 'partial cross-home output\n' > "$HC_OLD_STATE/procevent/.cross-home-src.cross-home-token.output"
chmod 0600 "$HC_OLD_STATE/procevent/.cross-home-src.cross-home-token.output"
pe_register "$HC_NEW" lavish cross-home-src -- /bin/echo recovered >/dev/null
out=$(pe "$HC_NEW" start cross-home-src)
assert_contains "$out" "captured:" "a second home can replace a stale source owner"
assert_absent "$HC_OLD_STATE/procevent/.cross-home-src.cross-home-token.output" "cross-home reclaim removes the old generation's recorded staging file"
pass "cross-home stale recovery removes abandoned output from the old state directory"

HR="$TMP_ROOT/hr"; new_home "$HR"
RACE_TRIGGER="$TMP_ROOT/race-trigger"
RACE_LOG="$TMP_ROOT/race-executions"
RACE_BLOCKER="$TMP_ROOT/race-blocker.sh"
cat > "$RACE_BLOCKER" <<'SH'
#!/usr/bin/env bash
printf 'started\n' >> "$1"
while [ ! -e "$2" ]; do sleep 0.05; done
printf 'race result\n'
SH
chmod +x "$RACE_BLOCKER"
pe_register "$HR" lavish race-src -- "$RACE_BLOCKER" "$RACE_LOG" "$RACE_TRIGGER" >/dev/null
printf '%s\n%s\nold-token\nold-identity\n' "$TMP_ROOT/gone-home" 999999 > "$FM_PROCEVENT_CLAIM_ROOT/race-src.claim"
chmod 0600 "$FM_PROCEVENT_CLAIM_ROOT/race-src.claim"
race_pids=()
for _ in $(seq 1 24); do
  pe "$HR" start race-src >/dev/null &
  race_pids+=("$!")
done
wait_for "$RACE_LOG" || fail "no contender acquired the stale claim"
sleep 0.5
[ "$(wc -l < "$RACE_LOG" | tr -d ' ')" = 1 ] || fail "stale-claim race started more than one runner"
: > "$RACE_TRIGGER"
for race_pid in "${race_pids[@]}"; do wait "$race_pid" 2>/dev/null || true; done
pass "concurrent stale-claim replacement starts exactly one runner"

# --- a crashed runner leader must not make its live child group look stale ---
# The runner is its own process group leader, so SIGKILL on the leader alone
# leaves the blocking source child running in that group. Classifying the
# missing leader as stale would release ownership and start a second poller
# against one canonical source, which for a destructive source means two
# concurrent long polls racing on the same session. The surviving group must be
# stopped before ownership can move.
HG="$TMP_ROOT/hg"; new_home "$HG"
ORPHAN_TRIGGER="$TMP_ROOT/orphan-trigger"
ORPHAN_LOG="$TMP_ROOT/orphan-executions"
ORPHAN_GROUP="$TMP_ROOT/orphan-group"
ORPHAN_OVERLAP="$TMP_ROOT/orphan-overlap"
ORPHAN_BLOCKER="$TMP_ROOT/orphan-blocker.sh"
cat > "$ORPHAN_BLOCKER" <<'SH'
#!/usr/bin/env bash
printf 'started\n' >> "$1"
if [ -s "$3" ]; then
  IFS= read -r old_group < "$3"
  if kill -0 "-$old_group" 2>/dev/null; then
    printf 'overlap\n' > "$4"
  fi
fi
while [ ! -e "$2" ]; do sleep 0.05; done
printf 'orphan result\n'
SH
chmod +x "$ORPHAN_BLOCKER"
pe_register "$HG" lavish orphan-src -- \
  "$ORPHAN_BLOCKER" "$ORPHAN_LOG" "$ORPHAN_TRIGGER" "$ORPHAN_GROUP" "$ORPHAN_OVERLAP" >/dev/null
pe "$HG" reconcile >/dev/null
wait_for "$FM_PROCEVENT_CLAIM_ROOT/orphan-src.claim" || fail "leader-crash fixture never claimed its source"
wait_for "$ORPHAN_LOG" || fail "leader-crash fixture source never started"
orphan_leader=$(sed -n '2p' "$FM_PROCEVENT_CLAIM_ROOT/orphan-src.claim")
case "$orphan_leader" in ''|*[!0-9]*) fail "could not read the runner leader pid: $orphan_leader" ;; esac
printf '%s\n' "$orphan_leader" > "$ORPHAN_GROUP"

kill -KILL "$orphan_leader" 2>/dev/null || fail "could not kill the runner leader"
for _ in $(seq 1 50); do kill -0 "$orphan_leader" 2>/dev/null || break; sleep 0.1; done
kill -0 "$orphan_leader" 2>/dev/null && fail "the runner leader survived SIGKILL"
kill -0 -"$orphan_leader" 2>/dev/null || fail "fixture invalid: the owned child group did not survive the leader"

orphan_out=$(pe "$HG" reconcile)
kill -0 -"$orphan_leader" 2>/dev/null \
  || fail "reconcile signalled an ambiguous leaderless process group: $orphan_out"
assert_contains "$orphan_out" "started=0" \
  "reconcile does not replace an ambiguous leaderless generation"
[ -e "$FM_PROCEVENT_CLAIM_ROOT/orphan-src.claim" ] \
  || fail "refusing ambiguous cleanup must preserve the claim"
[ "$(wc -l < "$ORPHAN_LOG" | tr -d ' ')" = 1 ] \
  || fail "reconcile started a source beside an ambiguous leaderless group"
assert_absent "$ORPHAN_OVERLAP" "no replacement source starts while the leaderless group remains"
# This is the ordinary crash shape, and it is refused permanently: `orphaned`
# in a listing and `uncertain=1` in output the supervision cycle discards
# reach nobody, so the strand has to announce itself durably, exactly once,
# under a key the watcher can tell apart from a captured result.
orphan_token=$(sed -n '3p' "$FM_PROCEVENT_CLAIM_ROOT/orphan-src.claim")
[ -n "$orphan_token" ] || fail "could not read the leaderless claim's token"
[ "$(stranded_wake_count "$HG" orphan-src)" = 1 ] \
  || fail "reconcile stranded a leaderless source without announcing it: $orphan_out"
[ "$(stranded_wake_keys "$HG" orphan-src)" = "procevent:orphan-src:stranded:$orphan_token" ] \
  || fail "the stranded wake is not keyed by source and claim generation: $(stranded_wake_keys "$HG" orphan-src)"
orphan_wake=$(stranded_wake_payloads "$HG" orphan-src)
assert_contains "$orphan_wake" "orphan-src" \
  "the leaderless stranded wake does not name the source it is about: $orphan_wake"
assert_contains "$orphan_wake" "polling" \
  "the leaderless stranded wake does not say what a human should check: $orphan_wake"
# `start` reports this claim as owned and reclaims nothing, so a wake that
# named it as the clearing command would send someone to a no-op.
case "$orphan_wake" in
  *"start orphan-src"*) fail "the leaderless stranded wake names start as clearing it: $orphan_wake" ;;
esac
orphan_start=$(pe "$HG" start orphan-src 2>&1)
assert_contains "$orphan_start" "already owned" \
  "start displaced a leaderless group's claim: $orphan_start"
[ "$(wc -l < "$ORPHAN_LOG" | tr -d ' ')" = 1 ] \
  || fail "start ran the source beside an ambiguous leaderless group"
orphan_again=$(pe "$HG" reconcile)
assert_contains "$orphan_again" "started=0" \
  "the second cycle replaced an ambiguous leaderless generation: $orphan_again"
assert_contains "$orphan_again" "uncertain=1" \
  "the second cycle stopped reporting the claim it could not settle: $orphan_again"
[ "$(stranded_wake_count "$HG" orphan-src)" = 1 ] \
  || fail "reconcile re-announced the same leaderless strand: $orphan_again"
[ "$(wc -l < "$ORPHAN_LOG" | tr -d ' ')" = 1 ] \
  || fail "the second cycle started a source beside an ambiguous leaderless group"
kill -0 -"$orphan_leader" 2>/dev/null \
  || fail "announcing the strand signalled the leaderless process group"
kill -KILL -"$orphan_leader" 2>/dev/null || true
for _ in $(seq 1 50); do kill -0 -"$orphan_leader" 2>/dev/null || break; sleep 0.1; done
kill -0 -"$orphan_leader" 2>/dev/null && fail "could not clean up the leaderless fixture group"
pe "$HG" retire orphan-src >/dev/null
pass "an ambiguous leaderless group is preserved without replacement"

# Counterexample: a genuinely dead generation - no leader and no surviving
# group - must still be reclaimable, or crash recovery would deadlock.
HG2="$TMP_ROOT/hg2"; new_home "$HG2"
DEAD_TRIGGER="$TMP_ROOT/dead-gen-trigger"
DEAD_LOG="$TMP_ROOT/dead-gen-executions"
pe_register "$HG2" lavish dead-gen-src -- "$RACE_BLOCKER" "$DEAD_LOG" "$DEAD_TRIGGER" >/dev/null
printf '%s\n%s\ndead-token\ndead-identity\n%s\n' "$HG2" 999999 "$HG2/state/procevent" \
  > "$FM_PROCEVENT_CLAIM_ROOT/dead-gen-src.claim"
chmod 0600 "$FM_PROCEVENT_CLAIM_ROOT/dead-gen-src.claim"
dead_out=$(pe "$HG2" reconcile)
assert_contains "$dead_out" "started=1" "a generation with no leader and no group is still reclaimable"
wait_for "$DEAD_LOG" || fail "the replacement source never started for a truly dead generation"
: > "$DEAD_TRIGGER"
pe "$HG2" retire dead-gen-src >/dev/null
pass "a truly dead generation with no surviving group is still safely reclaimed"

# --- a dead generation stays reclaimable when the state root cannot be
# revalidated -----------------------------------------------------------------
# The reported wedge. Reclaiming a dead generation ran the claim's
# capture-reservation cleanup first, and that cleanup re-verifies the recorded
# state-root identity. Once that identity stopped matching, a claim naming a pid
# and a process group that were both provably gone could not be cleared:
# reconcile kept reporting a start while nothing ever attached, and retire
# refused with "cannot release source ownership". Reservation records are keyed
# by claim token and a replacement always claims a fresh one, so they can never
# collide with the generation that replaces them - they are hygiene, not an
# ownership invariant, and they must not veto an ownership move that the
# documented promise already grants.
#
# The claim below is the modern shape (it carries the state-root identity block
# a legacy claim does not have), which is why the existing dead-generation case
# above never reached this path.
HSR="$TMP_ROOT/hsr"; new_home "$HSR"
SR_TRIGGER="$TMP_ROOT/state-root-trigger"
SR_LOG="$TMP_ROOT/state-root-executions"
pe_register "$HSR" lavish state-root-src -- "$RACE_BLOCKER" "$SR_LOG" "$SR_TRIGGER" >/dev/null
pe "$HSR" reconcile >/dev/null
wait_for "$FM_PROCEVENT_CLAIM_ROOT/state-root-src.claim" \
  || fail "state-root fixture never claimed its source"
wait_for "$SR_LOG" || fail "state-root fixture source never started"
sr_leader=$(sed -n '2p' "$FM_PROCEVENT_CLAIM_ROOT/state-root-src.claim")
case "$sr_leader" in ''|*[!0-9]*) fail "could not read the state-root fixture leader pid" ;; esac
[ -n "$(sed -n '8p' "$FM_PROCEVENT_CLAIM_ROOT/state-root-src.claim")" ] \
  || fail "fixture invalid: the claim carries no state-root identity to invalidate"

kill -KILL -"$sr_leader" 2>/dev/null || true
kill -KILL "$sr_leader" 2>/dev/null || true
for _ in $(seq 1 50); do kill -0 -"$sr_leader" 2>/dev/null || break; sleep 0.1; done
kill -0 "$sr_leader" 2>/dev/null && fail "the state-root fixture leader survived SIGKILL"
kill -0 -"$sr_leader" 2>/dev/null && fail "fixture invalid: the owned group outlived the whole generation"
# Drift the live state root away from what the claim recorded.
chmod 750 "$HSR/state" || fail "could not drift the state-root identity"

sr_out=$(pe "$HSR" reconcile)
assert_contains "$sr_out" "started=1" "a dead generation was not reclaimed after the state root drifted: $sr_out"
# Reporting a start is not the same fact as listening: the previous behavior
# reported exactly this while the replacement silently failed to claim.
wait_for_lines "$SR_LOG" 2 \
  || fail "reconcile reported a start but no replacement source ever ran: $(cat "$SR_LOG")"
sr_new=$(sed -n '2p' "$FM_PROCEVENT_CLAIM_ROOT/state-root-src.claim")
[ "$sr_new" != "$sr_leader" ] || fail "the dead generation's claim was never replaced"
kill -0 "$sr_new" 2>/dev/null || fail "the replacement runner did not take ownership"
: > "$SR_TRIGGER"
pe "$HSR" retire state-root-src >/dev/null
pass "reconcile reclaims a dead generation whose state-root identity no longer matches"

# Retire must release the same wedged claim rather than refusing forever.
HSR2="$TMP_ROOT/hsr2"; new_home "$HSR2"
pe_register "$HSR2" lavish wedged-src -- /bin/echo recovered >/dev/null
sr2_identity=$(bash -c '. "$1/bin/fm-pr-lib.sh"; fm_pr_file_identity "$2"' _ \
  "$ROOT" "$HSR2/state/procevent/wedged-src.source") \
  || fail "could not read the wedged fixture registration identity"
{
  printf '%s\n%s\nwedged-token\nwedged-identity\n' "$HSR2" 999999
  printf '%s\n%s\nactive\n' "$HSR2/state/procevent" "$sr2_identity"
  # A state-root identity that names the right directory with the wrong inode:
  # exactly what a claim recorded before its home was re-created looks like.
  printf '%s\n%s\n%s\n%s\n%s\n' "$HSR2/state" 1 1 "$(id -u)" 755
} > "$FM_PROCEVENT_CLAIM_ROOT/wedged-src.claim"
chmod 0600 "$FM_PROCEVENT_CLAIM_ROOT/wedged-src.claim"
wedged_out=$(pe "$HSR2" retire wedged-src 2>&1) \
  || fail "retire refused to release a claim whose whole generation is gone: $wedged_out"
assert_contains "$wedged_out" "retired: wedged-src" "retire did not report releasing the wedged source: $wedged_out"
assert_absent "$FM_PROCEVENT_CLAIM_ROOT/wedged-src.claim" "retire left the dead generation owning the source"
assert_absent "$HSR2/state/procevent/wedged-src.source" "retire left the wedged source registered"
pass "retire releases a dead generation's claim instead of refusing forever"

# The guard is not weakened in the other direction: the same unrevalidatable
# state root must NOT let anything take a source away from a live generation.
HSR3="$TMP_ROOT/hsr3"; new_home "$HSR3"
SR3_TRIGGER="$TMP_ROOT/state-root-live-trigger"
SR3_LOG="$TMP_ROOT/state-root-live-executions"
pe_register "$HSR3" lavish live-drift-src -- "$RACE_BLOCKER" "$SR3_LOG" "$SR3_TRIGGER" >/dev/null
pe "$HSR3" reconcile >/dev/null
wait_for "$FM_PROCEVENT_CLAIM_ROOT/live-drift-src.claim" \
  || fail "live-drift fixture never claimed its source"
wait_for "$SR3_LOG" || fail "live-drift fixture source never started"
sr3_leader=$(sed -n '2p' "$FM_PROCEVENT_CLAIM_ROOT/live-drift-src.claim")
chmod 750 "$HSR3/state" || fail "could not drift the live owner's state-root identity"
sr3_out=$(pe "$HSR3" start live-drift-src)
assert_contains "$sr3_out" "already owned" "a live generation was displaced after its state root drifted: $sr3_out"
[ "$(sed -n '2p' "$FM_PROCEVENT_CLAIM_ROOT/live-drift-src.claim")" = "$sr3_leader" ] \
  || fail "the live generation's claim was replaced"
kill -0 "$sr3_leader" 2>/dev/null || fail "the live owner was killed by a reclaim attempt"
sr3_reconcile=$(pe "$HSR3" reconcile)
assert_contains "$sr3_reconcile" "started=0" "reconcile started a second poller beside a live owner: $sr3_reconcile"
[ "$(wc -l < "$SR3_LOG" | tr -d ' ')" = 1 ] \
  || fail "a second source ran beside the live owner: $(cat "$SR3_LOG")"
: > "$SR3_TRIGGER"
pe "$HSR3" retire live-drift-src >/dev/null
pass "a live generation is never reclaimed, drifted state root or not"

HSR4="$TMP_ROOT/hsr4"; new_home "$HSR4"
SR4_TRIGGER="$TMP_ROOT/state-root-reused-trigger"
SR4_LOG="$TMP_ROOT/state-root-reused-executions"
pe_register "$HSR4" lavish reused-group-src -- "$RACE_BLOCKER" "$SR4_LOG" "$SR4_TRIGGER" >/dev/null
pe "$HSR4" reconcile >/dev/null
wait_for "$FM_PROCEVENT_CLAIM_ROOT/reused-group-src.claim" \
  || fail "reused-group fixture never claimed its source"
wait_for "$SR4_LOG" || fail "reused-group fixture source never started"
sr4_claim="$FM_PROCEVENT_CLAIM_ROOT/reused-group-src.claim"
sr4_leader=$(sed -n '2p' "$sr4_claim")
sr4_identity=$(sed -n '4p' "$sr4_claim")
kill -0 -"$sr4_leader" 2>/dev/null \
  || fail "fixture invalid: the reused-pid process group is not alive"
awk 'NR == 4 { print "different-live-process-identity"; next } { print }' \
  "$sr4_claim" > "$sr4_claim.tmp" && mv "$sr4_claim.tmp" "$sr4_claim"
chmod 0600 "$sr4_claim"
chmod 750 "$HSR4/state" || fail "could not drift the reused-group state root"
sr4_out=$(pe "$HSR4" reconcile)
sleep 0.5
[ "$(wc -l < "$SR4_LOG" | tr -d ' ')" = 1 ] \
  || fail "reconcile started a replacement beside a reused pid's live group: $sr4_out"
# Ownership cannot move here by design, so a replacement could only die on the
# claim it cannot take - once per reconcile cycle, forever.
assert_contains "$sr4_out" "started=0" \
  "reconcile reported a start into a claim nothing can take: $sr4_out"
assert_contains "$sr4_out" "uncertain=1" \
  "reconcile did not report the claim it could not settle: $sr4_out"
[ "$(sed -n '2p' "$sr4_claim")" = "$sr4_leader" ] \
  || fail "reconcile replaced the reused-pid generation's claim"
# Nothing can take this source, so reporting it as unowned reads like an idle
# source waiting to be started - the reassuring answer this surface gave while a
# review board collected nothing.
sr4_owner=$(pe "$HSR4" list | awk '$1 == "reused-group-src" { print $3 }')
[ "$sr4_owner" = orphaned ] \
  || fail "a source no caller can claim is listed as '$sr4_owner'"
# `orphaned` in a listing and `uncertain=1` in output the supervision cycle
# discards reach nobody. The strand has to announce itself durably, exactly
# once, and say which command clears it.
[ "$(stranded_wake_count "$HSR4" reused-group-src)" = 1 ] \
  || fail "reconcile stranded a source without announcing it: $sr4_out"
# The key carries the source and its claim generation in a shape the watcher
# can tell apart from a captured result, so the strand is never headlined as one.
[ "$(stranded_wake_keys "$HSR4" reused-group-src)" = "procevent:reused-group-src:stranded:$(sed -n '3p' "$sr4_claim")" ] \
  || fail "the stranded wake is not keyed by source and claim generation: $(stranded_wake_keys "$HSR4" reused-group-src)"
sr4_wake=$(stranded_wake_payloads "$HSR4" reused-group-src)
assert_contains "$sr4_wake" "reused-group-src" \
  "the stranded wake does not name the source it is about: $sr4_wake"
assert_contains "$sr4_wake" "bin/fm-procevent.sh start reused-group-src" \
  "the stranded wake does not name the command that clears it: $sr4_wake"
# A wake nobody can silence is as unusable as one nobody gets: the same stranded
# generation must not re-announce on every supervision cycle.
sr4_again=$(pe "$HSR4" reconcile)
assert_contains "$sr4_again" "uncertain=1" \
  "the second cycle stopped reporting the claim it could not settle: $sr4_again"
[ "$(stranded_wake_count "$HSR4" reused-group-src)" = 1 ] \
  || fail "reconcile re-announced the same stranded generation: $sr4_again"
[ "$(wc -l < "$SR4_LOG" | tr -d ' ')" = 1 ] \
  || fail "the second cycle started a replacement beside a reused pid's live group: $sr4_again"
# The wake names `start` as the recovery, so run it against the state it will
# actually meet. The earlier end-to-end demonstration of that command used an
# UNDRIFTED fixture and therefore proved only the easy case; on this one the
# state root has drifted, so the dead generation's reservation records cannot
# be tidied, and the claim path waives that tidy-up only for a generation
# proven gone - which a surviving group is not. `start` must refuse here, keep
# the claim, and start no second source beside the live group, and the wake
# must have said so rather than promising a reclaim.
assert_contains "$sr4_wake" "cannot claim source" \
  "the stranded wake promises an unconditional reclaim: $sr4_wake"
set +e
sr4_start=$(pe "$HSR4" start reused-group-src 2>&1)
sr4_start_rc=$?
set -e
[ "$sr4_start_rc" -ne 0 ] \
  || fail "start reported success against a claim it could not tidy: $sr4_start"
assert_contains "$sr4_start" "cannot claim source" \
  "start did not refuse by name on the drifted reused-pid fixture: $sr4_start"
[ "$(sed -n '2p' "$sr4_claim")" = "$sr4_leader" ] \
  || fail "a refused start replaced the reused-pid generation's claim"
sleep 0.3
[ "$(wc -l < "$SR4_LOG" | tr -d ' ')" = 1 ] \
  || fail "a refused start ran a second source beside a reused pid's live group: $(cat "$SR4_LOG")"
set +e
sr4_retire=$(pe "$HSR4" retire reused-group-src 2>&1)
sr4_rc=$?
set -e
[ "$sr4_rc" -ne 0 ] || fail "retire released a claim whose process group survives: $sr4_retire"
[ -e "$sr4_claim" ] || fail "retire removed the reused-pid generation's claim"
[ -e "$HSR4/state/procevent/reused-group-src.source" ] \
  || fail "retire removed the reused-pid generation's registration"
awk -v identity="$sr4_identity" 'NR == 4 { print identity; next } { print }' \
  "$sr4_claim" > "$sr4_claim.tmp" && mv "$sr4_claim.tmp" "$sr4_claim"
chmod 0600 "$sr4_claim"
chmod 755 "$HSR4/state"
# Keep the child blocked so retirement alone ends the restored generation;
# releasing it races natural exit against the first signal's ownership check.
pe "$HSR4" retire reused-group-src >/dev/null \
  || fail "retirement failed after restoring the reused-group fixture's identity"
kill -0 -"$sr4_leader" 2>/dev/null \
  && fail "retirement left the restored reused-group fixture running"
pass "a reused pid never makes its surviving process group reclaimable"

# --- the easy case the wake promises: an undrifted reused-pid claim ----------
# Same strand, no state-root drift: the dead generation's reservation records
# can be tidied, so the attached `start` the wake names takes the claim and
# runs the source. The claim path does not consult the process group; that is
# the documented asymmetry between reconcile and a deliberate start.
HSR5="$TMP_ROOT/hsr5"; new_home "$HSR5"
SR5_TRIGGER="$TMP_ROOT/reused-plain-trigger"
SR5_LOG="$TMP_ROOT/reused-plain-executions"
pe_register "$HSR5" lavish reused-plain-src -- "$RACE_BLOCKER" "$SR5_LOG" "$SR5_TRIGGER" >/dev/null
pe "$HSR5" reconcile >/dev/null
wait_for "$FM_PROCEVENT_CLAIM_ROOT/reused-plain-src.claim" \
  || fail "undrifted reused-pid fixture never claimed its source"
wait_for "$SR5_LOG" || fail "undrifted reused-pid fixture source never started"
sr5_claim="$FM_PROCEVENT_CLAIM_ROOT/reused-plain-src.claim"
sr5_leader=$(sed -n '2p' "$sr5_claim")
awk 'NR == 4 { print "different-live-process-identity"; next } { print }' \
  "$sr5_claim" > "$sr5_claim.tmp" && mv "$sr5_claim.tmp" "$sr5_claim"
chmod 0600 "$sr5_claim"
sr5_out=$(pe "$HSR5" reconcile)
assert_contains "$sr5_out" "uncertain=1" \
  "reconcile did not strand the undrifted reused-pid claim: $sr5_out"
[ "$(stranded_wake_count "$HSR5" reused-plain-src)" = 1 ] \
  || fail "the undrifted strand was not announced: $sr5_out"
pe "$HSR5" start reused-plain-src > "$TMP_ROOT/reused-plain-start.out" 2>&1 &
sr5_start_pid=$!
wait_for_lines "$SR5_LOG" 2 \
  || fail "start did not reclaim the undrifted reused-pid claim: $(cat "$TMP_ROOT/reused-plain-start.out")"
[ "$(sed -n '2p' "$sr5_claim")" != "$sr5_leader" ] \
  || fail "start ran the source without taking the claim from the dead generation"
: > "$SR5_TRIGGER"
wait "$sr5_start_pid" \
  || fail "start failed after reclaiming the undrifted claim: $(cat "$TMP_ROOT/reused-plain-start.out")"
assert_contains "$(cat "$TMP_ROOT/reused-plain-start.out")" "captured:" \
  "the reclaiming start did not capture the source's result"
for _ in $(seq 1 50); do kill -0 -"$sr5_leader" 2>/dev/null || break; sleep 0.1; done
pe "$HSR5" retire reused-plain-src >/dev/null 2>&1 || true
pass "start reclaims a reused-pid claim whose leftovers can still be tidied"

# --- a launch that cannot confirm is announced once per failure episode ------
# `bin/fm-watch.sh` discards reconcile's `failed=` count and exit status, so a
# runner that dies before claiming - for any cause, not only the claim wedge -
# would be relaunched and reported failed every cycle with nobody told: armed
# in appearance, a dead drop in fact. The episode is keyed by the registration
# identity the launch ran under and ends when a launch of that source confirms,
# so the registration below is damaged and repaired IN PLACE to keep that
# identity fixed across the whole sequence. The wake changes nothing about the
# launch: every failing cycle below still relaunches and still reports failed.
HEP="$TMP_ROOT/hep"; new_home "$HEP"
EP_SOURCE_CMD="$TMP_ROOT/episode-source.sh"
cat > "$EP_SOURCE_CMD" <<'SH'
#!/usr/bin/env bash
printf 'episode result\n'
SH
chmod +x "$EP_SOURCE_CMD"
pe_register "$HEP" lavish episode-src -- "$EP_SOURCE_CMD" >/dev/null
EP_SOURCE="$HEP/state/procevent/episode-src.source"
cp "$EP_SOURCE" "$TMP_ROOT/episode-good.source"
awk '/^argv:$/ { print; exit } { print }' "$EP_SOURCE" > "$TMP_ROOT/episode-bad.source" \
  || fail "could not prepare the damaged episode registration"
ep_damage() { cat "$TMP_ROOT/episode-bad.source" > "$EP_SOURCE"; }
ep_repair() { cat "$TMP_ROOT/episode-good.source" > "$EP_SOURCE"; }
ep_reconcile() {  # <expected-fragment> <expected-exit-nonzero:0|1> <msg>; sets ep_out
  local rc=0
  ep_out=$(FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=2 pe "$HEP" reconcile) || rc=$?
  assert_contains "$ep_out" "$1" "$3: $ep_out"
  if [ "$2" -eq 1 ]; then
    [ "$rc" -ne 0 ] || fail "$3 (reconcile exited 0): $ep_out"
  else
    [ "$rc" -eq 0 ] || fail "$3 (reconcile exited $rc): $ep_out"
  fi
}
ep_damage
ep_reconcile "failed=1" 1 "a launch that never proved its claim was not reported failed"
[ "$(launch_failed_wake_count "$HEP" episode-src)" = 1 ] \
  || fail "a launch that could not confirm was not announced: $ep_out"
ep_key=$(launch_failed_wake_keys "$HEP" episode-src)
# <registration identity>-<per-episode nonce>: the watcher remembers every key
# it has surfaced for good, so the identity alone would announce only the first
# episode of a registration (tests/fm-watch-triage.test.sh proves delivery).
[[ "$ep_key" =~ ^(procevent:episode-src:launch-failed:[0-9]+-[0-9]+)-[0-9]+$ ]] \
  || fail "the launch-failed wake is not keyed by source, registration identity and episode: $ep_key"
ep_episode_prefix=${BASH_REMATCH[1]}
ep_wake=$(launch_failed_wake_payloads "$HEP" episode-src)
assert_contains "$ep_wake" "episode-src" \
  "the launch-failed wake does not name the source it is about: $ep_wake"
# The payload may state only what confirmation observed: no claim proved
# inside the window. It cannot know whether the runner died or was slow, so it
# must not assert a cause, must not present `start` as the fix, and must say
# that a later cycle finding the source owned closes the episode by itself.
assert_contains "$ep_wake" "did not prove it took the source's claim within FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS" \
  "the launch-failed wake does not state what confirmation observed: $ep_wake"
assert_contains "$ep_wake" "attached bin/fm-procevent.sh start episode-src to reproduce a refusal" \
  "the launch-failed wake does not say start reproduces rather than fixes: $ep_wake"
assert_contains "$ep_wake" "adapter binary" \
  "the launch-failed wake does not name what to check: $ep_wake"
assert_contains "$ep_wake" "finds the source owned ends this episode on its own" \
  "the launch-failed wake does not say a slow runner closes its own episode: $ep_wake"
case "$ep_wake" in
  *"never claimed"*|*"exited without"*|*"runner died"*)
    fail "the launch-failed wake asserts a cause confirmation cannot observe: $ep_wake" ;;
esac
ep_reconcile "failed=1" 1 "the second cycle stopped relaunching a source that cannot start"
[ "$(launch_failed_wake_count "$HEP" episode-src)" = 1 ] \
  || fail "the same failure episode was announced twice: $ep_out"
ep_repair
ep_reconcile "started=1" 0 "a repaired source did not confirm"
assert_contains "$ep_out" "failed=0" "a repaired source was still reported failed: $ep_out"
[ "$(launch_failed_wake_count "$HEP" episode-src)" = 1 ] \
  || fail "a confirmed launch produced a launch-failed wake: $ep_out"
for _ in $(seq 1 100); do
  [ -e "$FM_PROCEVENT_CLAIM_ROOT/episode-src.claim" ] || break
  sleep 0.1
done
[ ! -e "$FM_PROCEVENT_CLAIM_ROOT/episode-src.claim" ] \
  || fail "the confirmed episode runner never released its claim"
ep_damage
ep_reconcile "failed=1" 1 "a source that failed again after recovering was not reported failed"
[ "$(launch_failed_wake_count "$HEP" episode-src)" = 2 ] \
  || fail "a new failure episode after a confirmed launch was not announced: $ep_out"
# The earlier version of this assertion locked in ONE key for both episodes,
# which is exactly the collision that left every episode after the first
# unsurfaced: both keys must carry the same registration identity and still
# differ, or the watcher's seen marker for episode one suppresses episode two.
ep_key_again=$(launch_failed_wake_keys "$HEP" episode-src | sed -n '2p')
[ "$ep_key_again" != "$ep_key" ] \
  || fail "a new failure episode reused the first episode's queue key: $ep_key_again"
case "$ep_key_again" in
  "$ep_episode_prefix"-*) ;;
  *) fail "the second episode ran under a different registration identity: $ep_key_again (first: $ep_key)" ;;
esac
ep_repair
pe "$HEP" retire episode-src >/dev/null 2>&1 || true
pass "a launch that cannot confirm is announced once per failure episode"

# --- the launch-failed key fits the watcher's seen marker at the id limit ----
# bin/fm-watch.sh names the marker for a surfaced key `.seen-procevent-<hex>`,
# 16 + 2 * keylen bytes against NAME_MAX 255, so a key longer than 119 chars
# cannot be marked and its wake would re-surface every cycle. The longest id
# the validator accepts is 64 chars; the executed key for such an id must fit.
HLK="$TMP_ROOT/hlk"; new_home "$HLK"
LK_ID=$(printf 'k%.0s' $(seq 1 64))
[ "${#LK_ID}" -eq 64 ] || fail "fixture invalid: long source id is ${#LK_ID} chars"
pe_register "$HLK" lavish "$LK_ID" -- "$EP_SOURCE_CMD" >/dev/null
LK_SOURCE="$HLK/state/procevent/$LK_ID.source"
if ! { awk '/^argv:$/ { print; exit } { print }' "$LK_SOURCE" > "$LK_SOURCE.tmp" \
  && cat "$LK_SOURCE.tmp" > "$LK_SOURCE" && rm -f -- "$LK_SOURCE.tmp"; }; then
  fail "could not damage the long-id registration"
fi
lk_out=$(FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=2 pe "$HLK" reconcile) || true
assert_contains "$lk_out" "failed=1" "the long-id launch was not reported failed: $lk_out"
lk_key=$(launch_failed_wake_keys "$HLK" "$LK_ID")
[ -n "$lk_key" ] || fail "the long-id launch failure was not announced: $lk_out"
[ "${#lk_key}" -le 119 ] \
  || fail "a 64-char source id yields a ${#lk_key}-char launch-failed key, which the watcher cannot mark: $lk_key"
pe "$HLK" retire "$LK_ID" >/dev/null 2>&1 || true
pass "a 64-char source id keeps the launch-failed key within the watcher's marker bound"

# --- reconcile reports only launches it actually confirmed -------------------
# The reported incident. A review board the captain had answered sat collecting
# nothing while `reconcile` reported a start on every run: `detach_runner` is
# fire-and-forget with the child's stderr discarded, so a runner that died
# before it could claim was counted exactly like one that is listening. A
# surface that presents as armed while being a dead drop is worse than one that
# visibly fails, because the answers look recorded.
#
# The damaged registration below makes the runner die BEFORE it claims, which
# is what keeps this deterministic: a runner that claims and then dies would
# race the confirmation either way, and the next reconcile cycle is what covers
# that case.
HUF="$TMP_ROOT/huf"; new_home "$HUF"
UF_TRIGGER="$TMP_ROOT/unstartable-trigger"
pe_register "$HUF" lavish unstartable-src -- "$BLOCKER" "$UF_TRIGGER" "unstartable" >/dev/null
UF_SOURCE="$HUF/state/procevent/unstartable-src.source"
if ! awk '/^argv:$/ { print; exit } { print }' "$UF_SOURCE" > "$UF_SOURCE.tmp"; then
  fail "could not damage the unstartable registration"
fi
mv "$UF_SOURCE.tmp" "$UF_SOURCE" || fail "could not damage the unstartable registration"
chmod 0600 "$UF_SOURCE"
uf_rc=0
uf_out=$(FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=2 pe "$HUF" reconcile) || uf_rc=$?
assert_contains "$uf_out" "started=0" \
  "reconcile counted a runner that never started as a start: $uf_out"
assert_contains "$uf_out" "failed=1" \
  "reconcile did not report the launch it could not confirm: $uf_out"
[ "$uf_rc" -ne 0 ] || fail "reconcile reported success while a source could not start: $uf_out"
uf_owner=$(pe "$HUF" list | awk '$1 == "unstartable-src" { print $3 }')
[ "$uf_owner" = none ] || fail "the unstartable source reports an owner: $uf_owner"
pe "$HUF" retire unstartable-src >/dev/null 2>&1 || true
pass "reconcile reports a launch it could not confirm instead of counting it as a start"

# --- a launch that finished before the first poll is still confirmed ---------
# Confirmation has to read evidence a finished runner leaves behind. A runner
# removes its own runner record on the way out, so a source that claims, runs
# and exits before confirmation looks at it once returns every transient signal
# to exactly what it was before the launch - and a good run gets reported as a
# failure, on every cycle, for a source that is working perfectly.
#
# The second registration is what makes that deterministic rather than a race:
# reconcile launches the fast source first, then blocks acquiring the held
# lock of the second source, and the holder is released only once the fast
# runner has captured its result and let go of both its claim and its runner
# record. Confirmation therefore starts strictly after the fast runner is gone.
HFC="$TMP_ROOT/hfc"; new_home "$HFC"
FC_FAST="$TMP_ROOT/fast-source.sh"
cat > "$FC_FAST" <<'SH'
#!/usr/bin/env bash
printf 'fast payload\n'
SH
chmod +x "$FC_FAST"
FC_TRIGGER="$TMP_ROOT/fast-hold-trigger"
pe_register "$HFC" lavish aa-fast-src -- "$FC_FAST" >/dev/null
pe_register "$HFC" lavish zz-hold-src -- "$BLOCKER" "$FC_TRIGGER" "held" >/dev/null
FC_READY="$TMP_ROOT/fast-hold-ready"; FC_RELEASE="$TMP_ROOT/fast-hold-release"
hold_source_lock zz-hold-src "$FC_READY" "$FC_RELEASE"
wait_for "$FC_READY" || fail "the fast-source fixture could not hold a source lock"
(
  for _ in $(seq 1 600); do
    if first_result "$HFC" aa-fast-src >/dev/null 2>&1 \
      && [ ! -e "$HFC/state/procevent/aa-fast-src.runner" ] \
      && [ ! -e "$FM_PROCEVENT_CLAIM_ROOT/aa-fast-src.claim" ]; then
      break
    fi
    sleep 0.05
  done
  : > "$FC_RELEASE"
) &
FC_RELEASER=$!
fc_rc=0
fc_out=$(FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=2 pe "$HFC" reconcile) || fc_rc=$?
wait "$FC_RELEASER" 2>/dev/null || true
wait "$HOLDER_PID" 2>/dev/null || true
first_result "$HFC" aa-fast-src >/dev/null \
  || fail "fixture invalid: the fast source never produced a result: $fc_out"
assert_contains "$fc_out" "started=2" \
  "reconcile did not report both launches as started: $fc_out"
assert_contains "$fc_out" "failed=0" \
  "reconcile reported a launch that ran to completion as a failure: $fc_out"
[ "$fc_rc" -eq 0 ] || fail "reconcile exited non-zero with every launch confirmed: $fc_out"
: > "$FC_TRIGGER"
pe "$HFC" retire aa-fast-src >/dev/null 2>&1 || true
pe "$HFC" retire zz-hold-src >/dev/null 2>&1 || true
pass "a launch that finished before confirmation looked is still reported as started"

# --- a zero-padded confirm window is read as base 10 -------------------------
# The window's validator reads base 10, so `08` is a value it accepts. Read as
# octal in arithmetic it is not a number at all, which under `set -u` takes the
# confirmation down with it and turns every launch of the cycle - including a
# perfectly healthy one - into a reported failure and a non-zero exit.
HZP="$TMP_ROOT/hzp"; new_home "$HZP"
ZP_TRIGGER="$TMP_ROOT/zeropad-trigger"
pe_register "$HZP" lavish zeropad-src -- "$BLOCKER" "$ZP_TRIGGER" "zeropad" >/dev/null
zp_rc=0
zp_out=$(FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=08 pe "$HZP" reconcile 2>/dev/null) || zp_rc=$?
assert_contains "$zp_out" "started=1" \
  "a zero-padded confirm window lost the launch reconcile started: $zp_out"
assert_contains "$zp_out" "failed=0" \
  "a zero-padded confirm window reported a healthy launch as failed: $zp_out"
[ "$zp_rc" -eq 0 ] || fail "a zero-padded confirm window made reconcile exit non-zero: $zp_out"
: > "$ZP_TRIGGER"
pe "$HZP" retire zeropad-src >/dev/null 2>&1 || true
pass "a zero-padded launch confirm window is honored as base 10"

# --- an unusable confirm window is refused by name --------------------------
# A window this command cannot use makes every launch unconfirmable. Reported
# from inside the confirmation it comes out as a fleet of healthy runners that
# all "could not start", blaming the sources instead of the typo. Every other
# tunable on this path - the launch floor, the output bound - refuses a bad
# value by name before anything runs, and so does this one.
HIW="$TMP_ROOT/hiw"; new_home "$HIW"
IW_TRIGGER="$TMP_ROOT/invalid-window-trigger"
pe_register "$HIW" lavish invalid-window-src -- "$BLOCKER" "$IW_TRIGGER" "window" >/dev/null
for iw_value in 5s 0 700; do
  iw_rc=0
  iw_out=$(FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS="$iw_value" pe "$HIW" reconcile 2>&1) || iw_rc=$?
  [ "$iw_rc" -ne 0 ] \
    || fail "reconcile accepted the unusable confirm window '$iw_value': $iw_out"
  assert_contains "$iw_out" "FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS" \
    "the unusable confirm window '$iw_value' was not named by what refused it: $iw_out"
  case "$iw_out" in
    *failed=*) fail "the unusable confirm window '$iw_value' was blamed on the sources: $iw_out" ;;
  esac
  [ ! -e "$FM_PROCEVENT_CLAIM_ROOT/invalid-window-src.claim" ] \
    || fail "reconcile launched a runner before refusing the confirm window '$iw_value'"
done
# The refusal costs the source nothing: it still arms on the next run with a
# usable value.
iw_ok=$(pe "$HIW" reconcile)
assert_contains "$iw_ok" "started=1" \
  "the source did not arm once its confirm window was usable: $iw_ok"
assert_contains "$iw_ok" "failed=0" \
  "the source was reported as failed once its confirm window was usable: $iw_ok"
: > "$IW_TRIGGER"
pe "$HIW" retire invalid-window-src >/dev/null 2>&1 || true
pass "an unusable launch confirm window is refused by name instead of blamed on the sources"

# --- a dead generation's untidyable leftovers never wedge ownership ----------
# The same wedge as the state-root case above, reached through the sibling
# cleanups in the stale-claim branch rather than the capture reservation. Every
# one of them tidies leftovers keyed by the DEAD generation's claim token, so
# none can collide with the replacement, yet a failure in any of them used to
# refuse the claim outright - permanently, because the condition never clears on
# its own. Here the recorded registry directory no longer resolves to a
# directory at all, which is what a claim recorded before its home was replaced
# looks like.
HUW="$TMP_ROOT/huw"; new_home "$HUW"
UW_TRIGGER="$TMP_ROOT/untidyable-trigger"
UW_LOG="$TMP_ROOT/untidyable-executions"
pe_register "$HUW" lavish untidyable-src -- "$RACE_BLOCKER" "$UW_LOG" "$UW_TRIGGER" >/dev/null
UW_REG_FILE="$TMP_ROOT/untidyable-recorded-registry"
: > "$UW_REG_FILE"
uw_identity=$(bash -c '. "$1/bin/fm-pr-lib.sh"; fm_pr_file_identity "$2"' _ \
  "$ROOT" "$HUW/state/procevent/untidyable-src.source") \
  || fail "could not read the untidyable fixture registration identity"
UW_CLAIM="$FM_PROCEVENT_CLAIM_ROOT/untidyable-src.claim"
{
  printf '%s\n%s\nuntidyable-token\nuntidyable-identity\n' "$HUW" 999999
  printf '%s\n%s\nactive\n' "$UW_REG_FILE" "$uw_identity"
  printf '%s\n%s\n%s\n%s\n%s\n' "$HUW/state" \
    "$(bash -c '. "$1/bin/fm-pr-lib.sh"; fm_pr_file_device "$2"' _ "$ROOT" "$HUW/state")" \
    "$(bash -c '. "$1/bin/fm-pr-lib.sh"; fm_pr_file_inode "$2"' _ "$ROOT" "$HUW/state")" \
    "$(id -u)" 755
} > "$UW_CLAIM"
chmod 0600 "$UW_CLAIM"
kill -0 999999 2>/dev/null && fail "fixture invalid: the untidyable claim names a live pid"
kill -0 -999999 2>/dev/null && fail "fixture invalid: the untidyable claim's process group is alive"
uw_rc=0
uw_out=$(pe "$HUW" reconcile) || uw_rc=$?
[ "$uw_rc" -eq 0 ] || fail "reconcile could not repair a provably dead generation: $uw_out"
# Reporting a start is not the same fact as listening, so prove the listening
# half first: before this fix reconcile reported exactly this start on every run
# while the dead generation kept the claim and nothing ever attached.
wait_for "$UW_LOG" || fail "reconcile reported a start but no replacement source ever ran: $uw_out"
uw_new=$(sed -n '2p' "$UW_CLAIM")
[ "$uw_new" != 999999 ] || fail "the dead generation kept owning the source: $uw_out"
kill -0 "$uw_new" 2>/dev/null || fail "the replacement runner did not take ownership: $uw_out"
assert_contains "$uw_out" "started=1" "reconcile did not report the replacement it started: $uw_out"
assert_contains "$uw_out" "failed=0" "reconcile could not confirm the replacement: $uw_out"
: > "$UW_TRIGGER"
pe "$HUW" retire untidyable-src >/dev/null
pass "a dead generation whose leftovers cannot be tidied never keeps owning its source"

HJ="$TMP_ROOT/hj"; new_home "$HJ"
TORN_TRIGGER="$TMP_ROOT/torn-trigger"
pe_register "$HJ" lavish torn-src -- "$BLOCKER" "$TORN_TRIGGER" "torn" >/dev/null
pe "$HJ" reconcile >/dev/null
wait_for "$FM_PROCEVENT_CLAIM_ROOT/torn-src.claim" || fail "torn-read fixture runner did not claim its source"
awk 'NR == 3 { print "replacement-token"; next } { print }' \
  "$FM_PROCEVENT_CLAIM_ROOT/torn-src.claim" > "$TMP_ROOT/torn-next.claim"
chmod 0600 "$TMP_ROOT/torn-next.claim"
TORN_READY="$TMP_ROOT/torn-lock-ready"
TORN_RELEASE="$TMP_ROOT/torn-lock-release"
hold_source_lock torn-src "$TORN_READY" "$TORN_RELEASE"
torn_holder_pid=$HOLDER_PID
wait_for "$TORN_READY" || fail "could not hold the torn-read source boundary"
pe "$HJ" list > "$TMP_ROOT/torn-list.out" &
torn_list_pid=$!
sleep 0.2
kill -0 "$torn_list_pid" 2>/dev/null || fail "claim reader escaped the source boundary during replacement"
mv "$TMP_ROOT/torn-next.claim" "$FM_PROCEVENT_CLAIM_ROOT/torn-src.claim"
: > "$TORN_RELEASE"
wait "$torn_list_pid" || fail "claim reader failed after serialized replacement"
wait "$torn_holder_pid" || fail "torn-read source boundary holder failed"
assert_contains "$(cat "$TMP_ROOT/torn-list.out")" "live" "claim reader observes one coherent replacement generation"
pe "$HJ" retire torn-src >/dev/null
pass "claim replacement cannot produce a torn ownership snapshot"

HK="$TMP_ROOT/hk"; new_home "$HK"
START_LOG="$TMP_ROOT/retire-start-executions"
START_BLOCKER="$TMP_ROOT/retire-start-blocker.sh"
cat > "$START_BLOCKER" <<'SH'
#!/usr/bin/env bash
printf 'started\n' >> "$1"
sleep 30
SH
chmod +x "$START_BLOCKER"
pe_register "$HK" lavish retire-start-src -- "$START_BLOCKER" "$START_LOG" >/dev/null
START_READY="$TMP_ROOT/retire-start-lock-ready"
START_RELEASE="$TMP_ROOT/retire-start-lock-release"
hold_source_lock retire-start-src "$START_READY" "$START_RELEASE"
retire_start_holder_pid=$HOLDER_PID
wait_for "$START_READY" || fail "could not hold the retire-start source boundary"
pe "$HK" start retire-start-src > "$TMP_ROOT/retire-start.out" 2>&1 &
retire_start_pid=$!
sleep 0.2
kill -0 "$retire_start_pid" 2>/dev/null || fail "start did not wait for the source lifecycle boundary"
rm -f "$HK/state/procevent/retire-start-src.source"
: > "$START_RELEASE"
wait "$retire_start_pid" 2>/dev/null || true
wait "$retire_start_holder_pid" || fail "retire-start source boundary holder failed"
assert_absent "$START_LOG" "a start queued before retirement must revalidate the registration"
assert_absent "$FM_PROCEVENT_CLAIM_ROOT/retire-start-src.claim" "retirement cannot leave a late claim"
pass "retirement and start share one serialized lifecycle boundary"

HI="$TMP_ROOT/hi"; new_home "$HI"
pe_register "$HI" lavish reused-src -- /bin/true >/dev/null
sleep 60 &
innocent_pid=$!
printf '%s\n%s\nreused-token\nnot-the-live-process-identity\n' \
  "$HI" "$innocent_pid" > "$FM_PROCEVENT_CLAIM_ROOT/reused-src.claim"
chmod 0600 "$FM_PROCEVENT_CLAIM_ROOT/reused-src.claim"
pe "$HI" retire reused-src >/dev/null
kill -0 "$innocent_pid" 2>/dev/null || fail "retirement signaled a PID whose identity did not match the claim"
kill "$innocent_pid" 2>/dev/null || true
wait "$innocent_pid" 2>/dev/null || true
assert_absent "$FM_PROCEVENT_CLAIM_ROOT/reused-src.claim" "retirement releases the exact reused-pid claim"
pass "detected PID reuse is refused before signalling"

HL="$TMP_ROOT/hl"; new_home "$HL"
IDENTITY_TRIGGER="$TMP_ROOT/identity-trigger"
pe_register "$HL" lavish identity-src -- "$BLOCKER" "$IDENTITY_TRIGGER" "identity" >/dev/null
pe "$HL" reconcile >/dev/null
wait_for "$FM_PROCEVENT_CLAIM_ROOT/identity-src.claim" || fail "identity fixture runner did not claim its source"
identity_pid=$(sed -n '2p' "$FM_PROCEVENT_CLAIM_ROOT/identity-src.claim")
IDENTITY_FAKEBIN=$(fm_fakebin "$TMP_ROOT/identity-tools")
cat > "$IDENTITY_FAKEBIN/ps" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$IDENTITY_FAKEBIN/ps"
identity_status=0
identity_out=$(PATH="$IDENTITY_FAKEBIN:$PATH" FM_PROC_ROOT_OVERRIDE="$TMP_ROOT/no-proc" \
  pe "$HL" retire identity-src 2>&1) || identity_status=$?
[ "$identity_status" -ne 0 ] || fail "retirement succeeded despite uncertain live identity"
assert_contains "$identity_out" "source remains registered" "uncertain retirement reports preserved state"
kill -0 "$identity_pid" 2>/dev/null || fail "uncertain retirement signaled the runner"
assert_present "$HL/state/procevent/identity-src.source" "uncertain retirement preserves registration"
assert_present "$FM_PROCEVENT_CLAIM_ROOT/identity-src.claim" "uncertain retirement preserves claim generation"
pe "$HL" retire identity-src >/dev/null
pass "transient identity failure preserves the live source for retry"

HM="$TMP_ROOT/hm"; new_home "$HM"
SWEEP_TRIGGER_ONE="$TMP_ROOT/sweep-trigger-one"
SWEEP_TRIGGER_TWO="$TMP_ROOT/sweep-trigger-two"
pe_register "$HM" lavish sweep-one -- "$BLOCKER" "$SWEEP_TRIGGER_ONE" "sweep one" >/dev/null
pe_register "$HM" lavish sweep-two -- "$BLOCKER" "$SWEEP_TRIGGER_TWO" "sweep two" >/dev/null
pe "$HM" reconcile >/dev/null
wait_for "$FM_PROCEVENT_CLAIM_ROOT/sweep-one.claim" || fail "home sweep fixture one did not start"
wait_for "$FM_PROCEVENT_CLAIM_ROOT/sweep-two.claim" || fail "home sweep fixture two did not start"
sweep_pid_one=$(sed -n '2p' "$FM_PROCEVENT_CLAIM_ROOT/sweep-one.claim")
sweep_pid_two=$(sed -n '2p' "$FM_PROCEVENT_CLAIM_ROOT/sweep-two.claim")
# The claim-only case is an owned claim with no live runner, so build exactly
# that: kill the runner's group so it cannot run its own cleanup, confirm it is
# gone, and only then drop the registration. Deleting the registration out from
# under a LIVE runner no longer produces this case, because a superseded
# generation now observes the identity mismatch, self-retires, and releases its
# claim - so the sweep would race that exit and see one source or two depending
# on which won.
kill -KILL -"$sweep_pid_two" 2>/dev/null || true
for _ in $(seq 1 50); do kill -0 "$sweep_pid_two" 2>/dev/null || break; sleep 0.1; done
kill -0 "$sweep_pid_two" 2>/dev/null \
  && fail "the claim-only sweep fixture runner did not stop"
assert_present "$FM_PROCEVENT_CLAIM_ROOT/sweep-two.claim" \
  "a killed runner leaves its owned claim behind for the sweep"
rm -f "$HM/state/procevent/sweep-two.source"
out=$(pe "$HM" sweep-home --preflight)
assert_contains "$out" "sweep preflight: ready" "home sweep preflight validates the full bounded snapshot"
assert_present "$HM/state/procevent/sweep-one.source" "home sweep preflight does not remove registrations"
assert_present "$FM_PROCEVENT_CLAIM_ROOT/sweep-one.claim" "home sweep preflight does not release claims"
out=$(pe "$HM" sweep-home)
assert_contains "$out" "swept: attempted=2" "home sweep retires registrations and owned claim-only sources"
for sweep_pid in "$sweep_pid_one" "$sweep_pid_two"; do
  for _ in $(seq 1 40); do kill -0 "$sweep_pid" 2>/dev/null || break; sleep 0.1; done
  kill -0 "$sweep_pid" 2>/dev/null && fail "home sweep left a runner alive"
done
assert_absent "$HM/state/procevent/sweep-one.source" "home sweep removes registrations"
assert_absent "$FM_PROCEVENT_CLAIM_ROOT/sweep-one.claim" "home sweep releases the first claim"
assert_absent "$FM_PROCEVENT_CLAIM_ROOT/sweep-two.claim" "home sweep releases a claim with no registration"
pass "bounded home sweep preflights then retires every locally owned source"

HN="$TMP_ROOT/hn"; HO="$TMP_ROOT/ho"; new_home "$HN"; new_home "$HO"
FOREIGN_TRIGGER="$TMP_ROOT/foreign-trigger"
pe_register "$HN" lavish foreign-src -- "$BLOCKER" "$FOREIGN_TRIGGER" "foreign" >/dev/null
pe_register "$HO" lavish foreign-src -- "$BLOCKER" "$FOREIGN_TRIGGER" "foreign" >/dev/null
pe "$HN" reconcile >/dev/null
wait_for "$FM_PROCEVENT_CLAIM_ROOT/foreign-src.claim" || fail "foreign-owner fixture did not start"
foreign_pid=$(sed -n '2p' "$FM_PROCEVENT_CLAIM_ROOT/foreign-src.claim")
out=$(pe "$HO" sweep-home)
assert_contains "$out" "swept: attempted=1" "home sweep retires the local registration"
kill -0 "$foreign_pid" 2>/dev/null || fail "home sweep signaled a foreign-home runner"
assert_present "$FM_PROCEVENT_CLAIM_ROOT/foreign-src.claim" "home sweep preserves a foreign-home claim"
[ "$(sed -n '1p' "$FM_PROCEVENT_CLAIM_ROOT/foreign-src.claim")" = "$HN" ] || fail "home sweep changed foreign claim ownership"
assert_absent "$HO/state/procevent/foreign-src.source" "home sweep removes only the local registration"
pe "$HN" retire foreign-src >/dev/null
pass "home sweep leaves foreign-home claims and runners untouched"

HU="$TMP_ROOT/hu"; new_home "$HU"
SWEEP_UNCERTAIN_TRIGGER="$TMP_ROOT/sweep-uncertain-trigger"
pe_register "$HU" lavish sweep-uncertain -- "$BLOCKER" "$SWEEP_UNCERTAIN_TRIGGER" "uncertain" >/dev/null
pe "$HU" reconcile >/dev/null
wait_for "$FM_PROCEVENT_CLAIM_ROOT/sweep-uncertain.claim" || fail "uncertain sweep fixture did not start"
sweep_uncertain_pid=$(sed -n '2p' "$FM_PROCEVENT_CLAIM_ROOT/sweep-uncertain.claim")
sweep_status=0
sweep_out=$(PATH="$IDENTITY_FAKEBIN:$PATH" FM_PROC_ROOT_OVERRIDE="$TMP_ROOT/no-sweep-proc" \
  pe "$HU" sweep-home 2>&1) || sweep_status=$?
[ "$sweep_status" -ne 0 ] || fail "home sweep succeeded with an uncertain runner identity"
assert_contains "$sweep_out" "home sweep preflight failed" "uncertain home sweep reports a retryable refusal"
kill -0 "$sweep_uncertain_pid" 2>/dev/null || fail "uncertain home sweep signaled the runner"
assert_present "$HU/state/procevent/sweep-uncertain.source" "uncertain home sweep preserves registration"
assert_present "$FM_PROCEVENT_CLAIM_ROOT/sweep-uncertain.claim" "uncertain home sweep preserves the claim"
pe "$HU" sweep-home >/dev/null
pass "home sweep refuses safely until runner identity is readable"

HV="$TMP_ROOT/hv"; new_home "$HV"
mkdir -p "$HV/state/procevent-inbox"
printf 'already captured\n' > "$HV/state/procevent-inbox/result-only.1.result"
sup=$(bash -c '. "$1/bin/fm-supervision-lib.sh"; fm_supervision_needed "$2" && echo yes || echo no' _ "$ROOT" "$HV/state")
assert_contains "$sup" no "registration-free results do not broaden continuous supervision"
out=$(pe "$HV" sweep-home)
assert_contains "$out" "swept: attempted=0" "result-only homes need no process cleanup"
pass "healthy runtime behavior remains registration-only"

# --- argv boundaries, stderr, exit status, bounds, malformed output ---------
HD="$TMP_ROOT/hd"; new_home "$HD"
TRIG3="$TMP_ROOT/trigger-three"
pe_register "$HD" lavish argv-src -- "$BLOCKER" "$TRIG3" "one arg with spaces" "second; rm -rf /tmp/nope" >/dev/null
pe "$HD" reconcile >/dev/null
: > "$TRIG3"
wait_for "$HD/state/.wake-queue" || fail "argv source published no event"
R=$(first_result "$HD" argv-src || true)
assert_grep 'one arg with spaces' "$R" "an argument containing spaces survives as one argument"
assert_grep 'second; rm -rf /tmp/nope' "$R" "a shell-looking argument is passed literally, never interpreted"
assert_absent /tmp/nope "no shell interpretation occurred"
assert_not_contains "$(wake_payloads "$HD")" "rm -rf" "argv content never reaches the event line"

newline_status=0
newline_out=$(pe_register "$HD" lavish newline-src -- /bin/echo $'first\nsecond' 2>&1) || newline_status=$?
[ "$newline_status" -ne 0 ] || fail "registration accepted an argv element containing a newline"
assert_contains "$newline_out" "cannot contain newlines" "newline rejection explains the unsupported representation"
assert_absent "$HD/state/procevent/newline-src.source" "newline rejection publishes no corrupt registration"
pass "registration rejects unrepresentable newline arguments"

HE="$TMP_ROOT/he"; new_home "$HE"
pe_register "$HE" lavish fail-src -- /bin/sh -c 'exit 7' >/dev/null
out=$(pe "$HE" start fail-src)
assert_contains "$out" "no-result" "a failing source with no output publishes nothing"
[ -z "$(wake_payloads "$HE")" ] || fail "a failing source published an event"
assert_present "$HE/state/procevent/fail-src.source" "a failing source stays registered for retry"
pass "nonzero exit with no output stays armed and silent"

HF="$TMP_ROOT/hf"; new_home "$HF"
# shellcheck disable=SC2016  # single quotes are deliberate: the child shell expands this.
pe_register "$HF" lavish big-src -- /bin/sh -c 'printf "x%.0s" $(seq 1 5000)' >/dev/null
FM_PROCEVENT_MAX_OUTPUT_BYTES=100 FM_HOME="$HF" "$ROOT/bin/fm-procevent.sh" start big-src >/dev/null 2>&1
RB=$(first_result "$HF" big-src || true)
[ -n "$RB" ] || fail "bounded output was not captured at all"
[ "$(wc -c < "$RB" | tr -d ' ')" -le 100 ] || fail "output bound was not enforced"
pass "oversized output is bounded rather than published whole or dropped"

HG="$TMP_ROOT/hg-live"; new_home "$HG"
NOISY="$TMP_ROOT/noisy.sh"
NOISY_PID="$TMP_ROOT/noisy.pid"
cat > "$NOISY" <<'SH'
#!/usr/bin/env bash
trap '' TERM PIPE
printf '%s\n' "$$" > "$1"
while :; do
  printf 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n'
done
SH
chmod +x "$NOISY"
pe_register "$HG" lavish noisy-src -- "$NOISY" "$NOISY_PID" >/dev/null
FM_PROCEVENT_MAX_OUTPUT_BYTES=100 pe "$HG" reconcile >/dev/null
wait_for "$NOISY_PID" || fail "noisy source child did not start"
noisy_child=$(cat "$NOISY_PID")
staged=
for _ in $(seq 1 100); do
  for candidate in "$HG/state/procevent"/.noisy-src.*.output; do
    if [ -f "$candidate" ]; then staged=$candidate; break; fi
  done
  [ -n "$staged" ] && break
  sleep 0.1
done
[ -n "$staged" ] || fail "noisy source created no bounded staging file"
sleep 0.2
[ "$(wc -c < "$staged" | tr -d ' ')" -le 100 ] || fail "live staging exceeded the configured output bound"
pe "$HG" retire noisy-src >/dev/null
kill -0 "$noisy_child" 2>/dev/null && fail "TERM-resistant source child survived runner retirement"
assert_absent "$staged" "retirement removes the tracked partial staging file"
pass "live output stays bounded and retirement reaps the whole source group"

# When a fixture never records TERM, capture the claim, leader, group, and
# retirement output to help distinguish a blocked stop from a refused signal.
# Collect this evidence only on the failure path so passing cases stay quiet.
post_term_evidence() {  # <case> <runner-pid> <claim> <signals> <started-epoch> <retire-output>
  local case=$1 runner=$2 claim=$3 signals=$4 started=$5 out=$6
  {
    printf 'post-TERM evidence (%s case)\n' "$case"
    printf '  elapsed since retire started: %ss\n' "$(( $(date +%s) - started ))"
    printf '  identity recorded at claim time: %s\n' "$(sed -n '4p' "$claim" 2>/dev/null || echo '<claim unreadable>')"
    printf '  identity readable now (real ps): %s\n' "$(LC_ALL=C ps -p "$runner" -o lstart= 2>/dev/null || echo '<ps failed>')"
    printf '  signals file: %s (%s bytes)\n' "$signals" "$(wc -c < "$signals" 2>/dev/null | tr -d ' ' || echo 0)"
    printf '  leader state: %s\n' "$(ps -o pid=,ppid=,pgid=,stat= -p "$runner" 2>/dev/null || echo '<leader gone>')"
    printf '  leader wchan: %s\n' "$(ps -o wchan= -p "$runner" 2>/dev/null || echo '<none>')"
    printf '  live members of the runner group:\n'
    ps -Ao pid,ppid,pgid,stat,wchan,command 2>/dev/null | awk -v g="$runner" 'NR==1 || $3==g' | sed 's/^/    /'
    printf '  retire said: %s\n' "${out:-<no output>}"
  } >&2
}

for post_term_case in mismatch unreadable unreadable-pgid nonleader; do
  HPOST_TERM="$TMP_ROOT/post-term-$post_term_case"; new_home "$HPOST_TERM"
  POST_TERM_SOURCE="$HPOST_TERM/source.sh"
  POST_TERM_PID="$HPOST_TERM/child.pid"
  POST_TERM_SIGNALS="$HPOST_TERM/child.signals"
  cat > "$POST_TERM_SOURCE" <<'SH'
#!/usr/bin/env bash
trap 'printf "signalled\n" >> "$2"' TERM
printf '%s\n' "$$" > "$1"
while [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do sleep 1; done
SH
  chmod +x "$POST_TERM_SOURCE"
  POST_TERM_BIN=$(fm_fakebin "$HPOST_TERM/tools")
  REAL_PS=$(command -v ps) || fail "the post-TERM reuse fixture requires ps"
  pe_register "$HPOST_TERM" lavish post-term-src -- \
    "$POST_TERM_SOURCE" "$POST_TERM_PID" "$POST_TERM_SIGNALS" >/dev/null
  FM_PROC_ROOT_OVERRIDE="$TMP_ROOT/no-post-term-proc" \
    FM_PROCEVENT_OWNER_CHECK_SECONDS=5 pe "$HPOST_TERM" reconcile >/dev/null
  wait_for "$POST_TERM_PID" || fail "the post-TERM reuse fixture did not start"
  wait_for "$FM_PROCEVENT_CLAIM_ROOT/post-term-src.claim" \
    || fail "the post-TERM reuse fixture did not claim its source"
  POST_TERM_RUNNER=$(sed -n '2p' "$FM_PROCEVENT_CLAIM_ROOT/post-term-src.claim")
  # The child can publish its PID before startup releases the source lock.
  # Cross that boundary before suspending the runner, or retirement waits on
  # a stopped lock owner instead of exercising the signal checks below.
  FM_PROC_ROOT_OVERRIDE="$TMP_ROOT/no-post-term-proc" pe "$HPOST_TERM" list >/dev/null \
    || fail "the post-TERM fixture never finished its source launch"
  kill -STOP "$POST_TERM_RUNNER" || fail "the post-TERM fixture could not keep its leader alive"
  cat > "$POST_TERM_BIN/ps" <<SH
#!/usr/bin/env bash
if [ "\${1-}" = -p ] && [ "\${2-}" = "$POST_TERM_RUNNER" ] \
  && [ "\${3-}" = -o ] && [ "\${4-}" = lstart= ]; then
  if [ "$post_term_case" = mismatch ]; then
    printf 'reused identity\n'
    exit 0
  fi
  [ ! -s "$POST_TERM_SIGNALS" ] || exit 1
fi
if [ "\${1-}" = -o ] && [ "\${2-}" = pgid= ] \
  && [ "\${3-}" = -p ] && [ "\${4-}" = "$POST_TERM_RUNNER" ]; then
  case "$post_term_case" in
    unreadable-pgid) [ ! -s "$POST_TERM_SIGNALS" ] || exit 1 ;;
    nonleader) printf '0\n'; exit 0 ;;
  esac
fi
exec "$REAL_PS" "\$@"
SH
  chmod +x "$POST_TERM_BIN/ps"
  post_term_status=0
  post_term_started=$(date +%s)
  post_term_out=$(PATH="$POST_TERM_BIN:$PATH" FM_PROC_ROOT_OVERRIDE="$TMP_ROOT/no-post-term-proc" \
    pe "$HPOST_TERM" retire post-term-src 2>&1) || post_term_status=$?
  case "$post_term_case" in
    mismatch|nonleader)
      assert_absent "$POST_TERM_SIGNALS" "the first signal refuses $post_term_case evidence"
      [ "$post_term_status" -ne 0 ] || fail "retirement escalated despite $post_term_case evidence"
      assert_contains "$post_term_out" "cannot confirm runner identity" \
        "first-signal $post_term_case evidence refuses retirement"
      kill -0 "$POST_TERM_RUNNER" 2>/dev/null \
        || fail "the post-TERM fixture lost its leader instead of exercising $post_term_case evidence"
      kill -0 -"$POST_TERM_RUNNER" 2>/dev/null \
        || fail "a $post_term_case group was killed during escalation"
      assert_present "$HPOST_TERM/state/procevent/post-term-src.source" \
        "first-signal $post_term_case evidence preserves registration"
      assert_present "$FM_PROCEVENT_CLAIM_ROOT/post-term-src.claim" \
        "first-signal $post_term_case evidence preserves its claim"
      kill -KILL -"$POST_TERM_RUNNER" 2>/dev/null || true
      ;;
    *)
      if [ ! -s "$POST_TERM_SIGNALS" ]; then
        post_term_evidence "$post_term_case" "$POST_TERM_RUNNER" \
          "$FM_PROCEVENT_CLAIM_ROOT/post-term-src.claim" "$POST_TERM_SIGNALS" \
          "$post_term_started" "$post_term_out"
        fail "the post-TERM fixture never received TERM"
      fi
      [ "$post_term_status" -eq 0 ] \
        || fail "retirement abandoned a proved stop after $post_term_case identity: $post_term_out"
      assert_absent "$HPOST_TERM/state/procevent/post-term-src.source" \
        "proved escalation retires the source after $post_term_case identity"
      assert_absent "$FM_PROCEVENT_CLAIM_ROOT/post-term-src.claim" \
        "proved escalation releases its claim after $post_term_case identity"
      ;;
  esac
  for _ in $(seq 1 50); do kill -0 -"$POST_TERM_RUNNER" 2>/dev/null || break; sleep 0.1; done
  kill -0 -"$POST_TERM_RUNNER" 2>/dev/null && fail "the post-TERM fixture group survived: $post_term_case"
  pe "$HPOST_TERM" retire post-term-src >/dev/null
  pass "stop $post_term_case evidence preserves the proved-stop boundary"
done

HBAD="$TMP_ROOT/hbad"; new_home "$HBAD"
pe_register "$HBAD" lavish bad-limit -- /bin/true >/dev/null
bad_limit_status=0
bad_limit_out=$(FM_PROCEVENT_MAX_OUTPUT_BYTES=invalid pe "$HBAD" start bad-limit 2>&1) || bad_limit_status=$?
[ "$bad_limit_status" -ne 0 ] || fail "an invalid output bound was accepted"
assert_contains "$bad_limit_out" "must be a nonnegative integer" "invalid output bound reports its contract"
assert_absent "$FM_PROCEVENT_CLAIM_ROOT/bad-limit.claim" "invalid output bound leaves no source claim"
pass "invalid output bounds fail closed"

printf '\nall procevent ownership tests passed\n'
