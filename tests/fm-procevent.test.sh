#!/usr/bin/env bash
# Behavior tests for the generic process-to-event runner and its Lavish adapter.
#
# The source under test is a fake blocking process that returns only when its
# trigger file appears, so completion is a real process event and no test here
# depends on a discovery timer. The Lavish adapter is exercised through its own
# public commands against the currently published poll shape; no live Lavish
# server is started.
#
# Delivery is deliberately NOT asserted as at-least-once or lossless: the
# published Lavish poll clears feedback destructively before returning it, so
# the only durability under test is the runner's own - output that reached the
# runner is stored before it is announced.
set -u

# shellcheck source=tests/procevent-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/procevent-helpers.sh"

# --- inert with nothing configured ------------------------------------------
IDLE="$TMP_ROOT/idle"; mkdir -p "$IDLE"
out=$(pe "$IDLE" list)
assert_contains "$out" "no sources registered" "an unconfigured home reports no sources"
out=$(pe "$IDLE" reconcile)
assert_contains "$out" "published=0 started=0" "reconcile is a no-op with nothing registered"
[ -z "$(ls -A "$IDLE/state" 2>/dev/null)" ] || fail "an unconfigured home generated state: $(ls -A "$IDLE/state")"
pass "no configured source means no generated state and no process"

sup=$(PATH="${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" bash -c \
  '. "$1/bin/fm-supervision-lib.sh"; fm_supervision_needed "$2" && echo yes || echo no' _ "$ROOT" "$IDLE/state")
assert_contains "$sup" no "an unconfigured home does not need supervision"

# --- a blocking source completes into exactly one normalized event ----------
H1="$TMP_ROOT/h1"; mkdir -p "$H1"
TRIG="$TMP_ROOT/trigger-one"
out=$(pe_register "$H1" lavish src-one -- "$BLOCKER" "$TRIG" "payload one")
assert_contains "$out" "registered: src-one" "register records a source"

sup=$(PATH="${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" bash -c \
  '. "$1/bin/fm-supervision-lib.sh"; fm_supervision_needed "$2" && echo yes || echo no' _ "$ROOT" "$H1/state")
assert_contains "$sup" yes "a registered source needs supervision with no task metadata"

pe "$H1" reconcile >/dev/null
# Reconcile's replacement runner is detached, so ownership is recorded after
# reconcile has already returned. Wait for the claim itself: a duplicate start
# only has an owner to lose to once that claim exists.
wait_for "$FM_PROCEVENT_CLAIM_ROOT/src-one.claim" || fail "reconcile never claimed the registered source"
out=$(pe "$H1" start src-one)
assert_contains "$out" "already owned" "a duplicate start loses instead of running a second child"

: > "$TRIG"
wait_for "$H1/state/.wake-queue" || fail "no event was published after the source completed"
payload=$(wake_payloads "$H1")
assert_contains "$payload" "procevent lavish src-one 1" "completion publishes the committed result sequence"
assert_not_contains "$payload" "payload one" "source output never reaches the event line"
[ "$(printf '%s\n' "$payload" | grep -c .)" = 1 ] || fail "expected exactly one event, got: $payload"
pass "one blocking completion yields exactly one bounded normalized event"

RESULT=$(first_result "$H1" src-one || true)
[ -n "$RESULT" ] || fail "no durable result was captured"
mode=$(PATH="${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" bash -c \
  '. "$1/bin/fm-pr-lib.sh"; fm_pr_file_mode "$2"' _ "$ROOT" "$RESULT")
assert_contains "$mode" 600 "the captured result is private"
assert_grep 'payload one' "$RESULT" "the captured result holds the source output verbatim"
assert_grep 'lavish' "${RESULT%.result}.adapter" "the captured result retains its immutable adapter"
assert_absent "${RESULT%.result}.handled" "publication alone never marks a result handled"

# --- a home spelled through a symlinked ancestor still runs its sources ------
# Such a home must run process-event sources exactly like a physically spelled
# one: reconcile's detached runner discards its own stderr, so a refusal here is
# invisible to the caller and the source simply never fires.
HPHYS="$TMP_ROOT/symlinked-parent-target"
mkdir -p "$HPHYS"
ln -s "$HPHYS" "$TMP_ROOT/symlinked-parent"
HSYM="$TMP_ROOT/symlinked-parent/home"; new_home "$HSYM"
SYM_TRIGGER="$TMP_ROOT/symlink-trigger"
pe_register "$HSYM" lavish symlinked-src -- "$BLOCKER" "$SYM_TRIGGER" "symlinked payload" >/dev/null
pe "$HSYM" reconcile >/dev/null
wait_for "$FM_PROCEVENT_CLAIM_ROOT/symlinked-src.claim" \
  || fail "a home reached through a symlinked ancestor never claimed its source"
: > "$SYM_TRIGGER"
wait_for "$HSYM/state/.wake-queue" \
  || fail "a home reached through a symlinked ancestor published no event"
assert_contains "$(wake_payloads "$HSYM")" "procevent lavish symlinked-src 1" \
  "the symlinked-ancestor home publishes the committed result sequence"
SYM_RESULT=$(first_result "$HSYM" symlinked-src || true)
[ -n "$SYM_RESULT" ] || fail "the symlinked-ancestor home captured no durable result"
assert_grep 'symlinked payload' "$SYM_RESULT" \
  "the symlinked-ancestor home captures the source output verbatim"
pass "a home reached through a symlinked ancestor runs its sources normally"

# --- the public start boundary establishes generation group ownership -------
HPG="$TMP_ROOT/hpg"; new_home "$HPG"
DIRECT_TRIGGER="$TMP_ROOT/direct-trigger"
pe_register "$HPG" lavish direct-src -- "$BLOCKER" "$DIRECT_TRIGGER" "direct result" >/dev/null
pe "$HPG" start direct-src > "$TMP_ROOT/direct-start.out" &
direct_runner=$!
wait_for "$FM_PROCEVENT_CLAIM_ROOT/direct-src.claim" || fail "direct start never claimed its source"
direct_leader=$(sed -n '2p' "$FM_PROCEVENT_CLAIM_ROOT/direct-src.claim")
direct_group=$(ps -o pgid= -p "$direct_leader" 2>/dev/null | tr -d '[:space:]')
[ "$direct_group" = "$direct_leader" ] \
  || fail "direct start claimed before leading its process group: pid=$direct_leader pgid=$direct_group"
: > "$DIRECT_TRIGGER"
wait "$direct_runner" || fail "direct start failed after its source completed"
assert_contains "$(cat "$TMP_ROOT/direct-start.out")" "captured:" "direct start captures its result"
pass "public start owns the process group recorded by its claim"

SHARED_TRIGGER="$TMP_ROOT/shared-trigger"
SHARED_SIBLING="$TMP_ROOT/shared-sibling"
SHARED_LAUNCHER="$TMP_ROOT/shared-launcher.pl"
cat > "$SHARED_LAUNCHER" <<'PL'
use strict;
use warnings;
my ($sibling_file, @command) = @ARGV;
pipe(my $reader, my $writer) or exit 125;
defined(my $runner = fork) or exit 125;
if ($runner == 0) {
  close $reader;
  setpgrp(0, 0) or exit 125;
  print {$writer} "ready\n";
  close $writer;
  exec @command;
  exit 125;
}
close $writer;
<$reader>;
close $reader;
defined(my $sibling = fork) or exit 125;
if ($sibling == 0) {
  setpgrp(0, $runner) or exit 125;
  open(my $out, '>', $sibling_file) or exit 125;
  print {$out} "$$\n";
  close $out;
  sleep 30;
  exit 0;
}
waitpid($runner, 0);
waitpid($sibling, 0);
exit 0;
PL
pe_register "$HPG" lavish shared-src -- "$BLOCKER" "$SHARED_TRIGGER" "shared result" >/dev/null
FM_HOME="$HPG" perl "$SHARED_LAUNCHER" "$SHARED_SIBLING" \
  "$ROOT/bin/fm-procevent.sh" start shared-src > "$TMP_ROOT/shared-start.out" &
shared_launcher=$!
wait_for "$SHARED_SIBLING" || fail "shared caller group never started its unrelated sibling"
wait_for "$FM_PROCEVENT_CLAIM_ROOT/shared-src.claim" || fail "shared-group start never claimed its source"
shared_sibling=$(cat "$SHARED_SIBLING")
pe "$HPG" retire shared-src >/dev/null
kill -0 "$shared_sibling" 2>/dev/null || fail "retirement signaled an unrelated caller-group process"
kill "$shared_sibling" 2>/dev/null || true
wait "$shared_launcher" || fail "shared caller-group fixture did not exit cleanly"
pass "public start never claims an inherited caller process group"

# --- an unhandled result remains eligible for re-announcement on restart ----
# A result is durable but nothing has ever acknowledged handling it. Every
# reconcile call - not just the first restart after a crash - must keep
# re-announcing it, because the only thing that stops re-announcement is an
# explicit handled acknowledgement, never a prior publication.
H2="$TMP_ROOT/h2"; new_home "$H2"
future_status=0
future_out=$(pe "$H2" handled src-cut 7 2>&1) || future_status=$?
[ "$future_status" -ne 0 ] || fail "handled accepted a generation that has not been captured"
assert_contains "$future_out" "cannot durably record handling" "premature acknowledgement is rejected through the public interface"
assert_absent "$H2/state/procevent-inbox/src-cut.7.handled" "premature acknowledgement creates no marker for the future generation"
mkdir -p "$H2/state/procevent-inbox"
printf 'stranded result\n' > "$H2/state/procevent-inbox/src-cut.7.result"
printf 'lavish\n' > "$H2/state/procevent-inbox/src-cut.7.adapter"
chmod 0600 "$H2/state/procevent-inbox/src-cut.7.result" "$H2/state/procevent-inbox/src-cut.7.adapter"
out=$(pe "$H2" reconcile)
assert_contains "$out" "published=1" "a durably captured but unhandled result is announced after restart"
assert_contains "$(wake_payloads "$H2")" "procevent lavish src-cut 7" "durable adapter identity survives without a registration"
assert_absent "$H2/state/procevent-inbox/src-cut.7.handled" "recovery alone never marks the recovered result handled"
mv "$H2/state/.wake-queue" "$H2/state/.wake-queue.drained-1"
out=$(pe "$H2" reconcile)
assert_contains "$out" "published=1" "an unhandled result is re-announced on every reconcile, not only the first"
assert_contains "$(wake_payloads "$H2")" "procevent lavish src-cut 7" "the repeat wake preserves its deduplication identity"
[ "$(count_results "$H2" src-cut)" = 1 ] || fail "repeat re-announcement created a second durable copy"
mv "$H2/state/.wake-queue" "$H2/state/.wake-queue.drained-2"

ack_out=$(pe "$H2" handled src-cut 7)
assert_contains "$ack_out" "handled: src-cut 7" "the owned handling interface newly authorizes the first acknowledgement"
assert_present "$H2/state/procevent-inbox/src-cut.7.handled" "acknowledgement durably records handling"
before=$(wake_payloads "$H2" | wc -l | tr -d ' ')
out=$(pe "$H2" reconcile)
assert_contains "$out" "published=0" "reconcile stops re-announcing once a result is durably handled"
[ "$(wake_payloads "$H2" | wc -l | tr -d ' ')" = "$before" ] || fail "a handled result was announced again"

repeat_out=$(pe "$H2" handled src-cut 7)
assert_contains "$repeat_out" "already-handled: src-cut 7" "repeated acknowledgement is safe and reports the repeat distinctly"
case "$repeat_out" in
  handled:*) fail "a repeat acknowledgement re-authorized a second handled effect: $repeat_out" ;;
esac
pass "an unhandled result survives restart and repeat drains, and only explicit acknowledgement stops its re-announcement"

HRACE="$TMP_ROOT/hrace"; new_home "$HRACE"
mkdir -p "$HRACE/state/procevent-inbox"
printf 'racing result\n' > "$HRACE/state/procevent-inbox/racing-src.1.result"
printf 'lavish\n' > "$HRACE/state/procevent-inbox/racing-src.1.adapter"
chmod 0600 "$HRACE/state/procevent-inbox/racing-src.1.result" "$HRACE/state/procevent-inbox/racing-src.1.adapter"
RACE_PUBLISH_READY="$TMP_ROOT/race-publish-ready"
RACE_PUBLISH_RELEASE="$TMP_ROOT/race-publish-release"
RACE_RECONCILE_OUT="$TMP_ROOT/race-reconcile.out"
hold_source_lock_then_handle "$HRACE" racing-src 1 "$RACE_PUBLISH_READY" "$RACE_PUBLISH_RELEASE"
RACE_HANDLE_PID=$HOLDER_PID
wait_for "$RACE_PUBLISH_READY" || fail "publication race barrier did not acquire the source lock"
pe "$HRACE" reconcile > "$RACE_RECONCILE_OUT" &
RACE_RECONCILE_PID=$!
sleep 0.3
assert_absent "$HRACE/state/.wake-queue" "publication bypassed the source serialization boundary"
: > "$RACE_PUBLISH_RELEASE"
wait "$RACE_HANDLE_PID" || fail "publication race barrier could not record handling"
wait "$RACE_RECONCILE_PID" || fail "reconcile failed after the concurrent acknowledgement"
assert_contains "$(cat "$RACE_RECONCILE_OUT")" "published=0" "reconcile rechecks handling at the serialized publication boundary"
assert_present "$HRACE/state/procevent-inbox/racing-src.1.handled" "the concurrent acknowledgement remains durable"
assert_absent "$HRACE/state/.wake-queue" "an acknowledged result was appended after handling completed"
pass "publication cannot race a handled acknowledgement"

HPRIVATE="$TMP_ROOT/hprivate"; new_home "$HPRIVATE"
mkdir -p "$HPRIVATE/state/procevent-inbox"
printf 'private result\n' > "$HPRIVATE/state/procevent-inbox/private-src.1.result"
printf 'lavish\n' > "$HPRIVATE/state/procevent-inbox/private-src.1.adapter"
chmod 0600 "$HPRIVATE/state/procevent-inbox/private-src.1.result" "$HPRIVATE/state/procevent-inbox/private-src.1.adapter"
FAIL_CHMOD_BIN="$TMP_ROOT/fail-chmod-bin"
mkdir -p "$FAIL_CHMOD_BIN"
cat > "$FAIL_CHMOD_BIN/chmod" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$FAIL_CHMOD_BIN/chmod"
private_status=0
private_out=$(PATH="$FAIL_CHMOD_BIN:$PATH" pe "$HPRIVATE" handled private-src 1 2>&1) || private_status=$?
[ "$private_status" -ne 0 ] || fail "handled succeeded when private mode enforcement failed"
assert_contains "$private_out" "cannot durably record handling" "mode enforcement failure is reported through the owned interface"
assert_absent "$HPRIVATE/state/procevent-inbox/private-src.1.handled" "failed mode enforcement left an authoritative marker"
private_out=$(umask 000; pe "$HPRIVATE" handled private-src 1)
assert_contains "$private_out" "handled: private-src 1" "handling succeeds after private mode enforcement recovers"
private_mode=$(PATH="${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" bash -c \
  '. "$1/bin/fm-pr-lib.sh"; fm_pr_file_mode "$2"' _ "$ROOT" "$HPRIVATE/state/procevent-inbox/private-src.1.handled")
assert_contains "$private_mode" 600 "the handled marker is private under a permissive caller umask"
pass "handled acknowledgement creation is private and fails safely"

# --- a terminal result retires its source, on the adapter's verdict alone ----
# The runner must carry no notion of its own about what "done" means for a
# source. It asks that source's adapter whether the captured result ends the
# source, and retires the registration only on that adapter's verdict. Two
# fixture adapters isolate exactly that decision - one that ends on any result,
# one with no terminal knowledge at all - so the observed behavior is proven to
# follow the adapter rather than any condition built into the runner.
ADAPTER_ROOT="$TMP_ROOT/adapter-root"
mkdir -p "$ADAPTER_ROOT/bin"
cat > "$ADAPTER_ROOT/bin/fm-procevent-endnow.sh" <<'SH'
#!/usr/bin/env bash
# Fixture adapter: every captured result ends this source.
case "${1-}" in
  terminal) [ -f "${2-}" ] && exit 0 || exit 1 ;;
esac
exit 2
SH
cat > "$ADAPTER_ROOT/bin/fm-procevent-openended.sh" <<'SH'
#!/usr/bin/env bash
# Fixture adapter with no terminal knowledge at all: nothing ever ends it.
exit 2
SH
cat > "$ADAPTER_ROOT/bin/fm-procevent-applying.sh" <<'SH'
#!/usr/bin/env bash
case "${1-}" in
  autohandle)
    printf '%s %s\n' "$2" "$3" >> "$FM_HOME/state/applied"
    "$FM_PROCEVENT_UNDER_TEST" handled "$2" "$3" >/dev/null
    ;;
  *) exit 2 ;;
esac
SH
cat > "$ADAPTER_ROOT/bin/fm-procevent-selfann.sh" <<'SH'
#!/usr/bin/env bash
# Fixture adapter that declares a durable downstream announcement of its own.
# FM_HOME/state/selfann-fail makes its application fail so the fallback
# publication path stays provable.
case "${1-}" in
  self-announcing) exit 0 ;;
  autohandle)
    [ ! -e "$FM_HOME/state/selfann-fail" ] || exit 1
    printf '%s %s\n' "$2" "$3" >> "$FM_HOME/state/applied"
    "$FM_PROCEVENT_UNDER_TEST" handled "$2" "$3" >/dev/null
    ;;
  *) exit 2 ;;
esac
SH
chmod +x "$ADAPTER_ROOT/bin/fm-procevent-endnow.sh" "$ADAPTER_ROOT/bin/fm-procevent-openended.sh" \
  "$ADAPTER_ROOT/bin/fm-procevent-applying.sh" "$ADAPTER_ROOT/bin/fm-procevent-selfann.sh"

pe_adapter() {  # <home> <command>...: run the runner against the fixture adapters
  local home=$1
  shift
  FM_ROOT_OVERRIDE="$ADAPTER_ROOT" FM_PROCEVENT_UNDER_TEST="$ROOT/bin/fm-procevent.sh" \
    FM_HOME="$home" "$ROOT/bin/fm-procevent.sh" "$@"
}

HPUBLISH="$TMP_ROOT/hpublish"; new_home "$HPUBLISH"
fm_test_track_procevent_home "$HPUBLISH"
pe_adapter "$HPUBLISH" register applying publish-src -- /bin/echo "apply after publish" >/dev/null
mkdir "$HPUBLISH/state/.wake-queue"
out=$(pe_adapter "$HPUBLISH" start publish-src 2>&1)
assert_contains "$out" "not-autohandled: publish-src" "failed publication did not suppress automatic application"
assert_absent "$HPUBLISH/state/applied" "a result was applied before its wake was durably published"
assert_absent "$HPUBLISH/state/procevent-inbox/publish-src.1.handled" "a result was acknowledged before its wake was durably published"
rmdir "$HPUBLISH/state/.wake-queue"
# This source's child returns instantly, so leaving it registered would have the
# recovery reconcile below start a detached poll that races every assertion after
# it for the source claim, the next sequence, and this home's applied record.
# Re-announcement is proven from the durable inbox alone and needs no
# registration, so retire it first - the same retire-before-reconcile discipline
# the blocker-backed sources rely on - and prove no competing poll was started.
pe_adapter "$HPUBLISH" retire publish-src >/dev/null
out=$(pe_adapter "$HPUBLISH" reconcile)
assert_contains "$out" "published=1" "the unpublished capture was not announced on later reconciliation"
assert_contains "$out" "started=0" "reconcile started an always-ready poll that races the recovery assertions"
assert_contains "$(wake_payloads "$HPUBLISH")" "procevent applying publish-src 1" "later reconciliation did not deliver the capture to a handler"
FM_HOME="$HPUBLISH" FM_PROCEVENT_UNDER_TEST="$ROOT/bin/fm-procevent.sh" \
  "$ADAPTER_ROOT/bin/fm-procevent-applying.sh" autohandle publish-src 1 \
    "$HPUBLISH/state/procevent-inbox/publish-src.1.result"
assert_grep 'publish-src 1' "$HPUBLISH/state/applied" "the handler could not apply the later announcement"
assert_present "$HPUBLISH/state/procevent-inbox/publish-src.1.handled" "the later handler application was not acknowledged"
pass "automatic application waits for durable publication and failed publication remains recoverable"

# A self-announcing adapter inverts that order on its own declaration: the
# runner applies first and publishes nothing for a capture the adapter fully
# applied and acknowledged, because the adapter's own durable downstream
# channel is the announcement. The declaration never silences a capture the
# adapter could NOT apply - that one still publishes for the handler.
HSELF="$TMP_ROOT/hself"; new_home "$HSELF"
fm_test_track_procevent_home "$HSELF"
pe_adapter "$HSELF" register selfann self-src -- /bin/echo "self announced" >/dev/null
out=$(pe_adapter "$HSELF" start self-src 2>&1)
assert_contains "$out" "autohandled: self-src" "the self-announcing adapter did not apply its own capture"
assert_not_contains "$out" "not-autohandled" "the applied capture was still reported as left for the handler"
assert_grep 'self-src 1' "$HSELF/state/applied" "the self-announcing capture was not applied"
assert_present "$HSELF/state/procevent-inbox/self-src.1.handled" "the self-announcing application was not acknowledged"
if [ -e "$HSELF/state/.wake-queue" ] && grep -q 'procevent selfann self-src 1' "$HSELF/state/.wake-queue"; then
  fail "a fully autohandled self-announcing capture still published a duplicate check wake"
fi
# This self-announcing source's child returns instantly, so reconcile would
# restart it and that detached poll would race the failing-path start below for
# the source claim - non-deterministically stealing its sequence or the claim
# itself. Retire it before the re-announcement check so reconcile starts no
# competing poll, then re-register for the failing-path capture, the same
# retire-before-reconcile discipline the blocker-backed sources rely on.
pe_adapter "$HSELF" retire self-src >/dev/null
out=$(pe_adapter "$HSELF" reconcile)
assert_contains "$out" "published=0" "reconcile re-announced a capture its adapter already acknowledged"
assert_contains "$out" "started=0" "reconcile restarted an always-ready acknowledged source and raced the next start"
pe_adapter "$HSELF" register selfann self-src -- /bin/echo "self announced" >/dev/null
: > "$HSELF/state/selfann-fail"
out=$(pe_adapter "$HSELF" start self-src 2>&1)
assert_contains "$out" "not-autohandled: self-src" "a failed self-announcing application was reported as applied"
assert_absent "$HSELF/state/procevent-inbox/self-src.2.handled" "a failed self-announcing application was acknowledged anyway"
assert_contains "$(wake_payloads "$HSELF")" "procevent selfann self-src 2" \
  "a capture the self-announcing adapter could not apply lost its check-wake announcement"
rm -f "$HSELF/state/selfann-fail"
pass "a self-announcing adapter applies quietly and still publishes what it could not apply"

HTERM="$TMP_ROOT/hterm"; new_home "$HTERM"
fm_test_track_procevent_home "$HTERM"
pe_adapter "$HTERM" register endnow ends-src -- /bin/echo "terminal payload" >/dev/null
out=$(pe_adapter "$HTERM" start ends-src)
assert_contains "$out" "captured:" "a terminal result is still captured durably"
assert_contains "$out" "retired: ends-src" "the runner reports the adapter-driven retirement"
assert_absent "$HTERM/state/procevent/ends-src.source" "an adapter-classified terminal result retires its registration"
assert_absent "$FM_PROCEVENT_CLAIM_ROOT/ends-src.claim" "terminal retirement releases this runner's own claim"
assert_contains "$(wake_payloads "$HTERM")" "procevent endnow ends-src 1" "the terminal result is still announced"
[ "$(count_results "$HTERM" ends-src)" = 1 ] || fail "terminal retirement lost or duplicated the captured result"
TERMINAL_RESULT=$(first_result "$HTERM" ends-src || true)
assert_grep 'terminal payload' "$TERMINAL_RESULT" "automatic retirement retains the captured output verbatim"
out=$(pe_adapter "$HTERM" reconcile)
assert_contains "$out" "started=0" "a retired terminal source is never restarted"
assert_contains "$out" "published=1" "an unhandled terminal result is still re-announced until acknowledged"
[ "$(count_results "$HTERM" ends-src)" = 1 ] || fail "a retired terminal source ran its poll again"
out=$(pe_adapter "$HTERM" retire ends-src)
assert_contains "$out" "retired: ends-src" "explicit retirement stays supported and idempotent after automatic retirement"
ack_out=$(pe_adapter "$HTERM" handled ends-src 1)
assert_contains "$ack_out" "handled: ends-src 1" "a terminal result is acknowledged through the owned interface"
out=$(pe_adapter "$HTERM" reconcile)
assert_contains "$out" "published=0" "an acknowledged terminal result stops being re-announced"
pass "an adapter-classified terminal result is captured once, announced, and retires its source automatically"

HOPEN="$TMP_ROOT/hopen"; new_home "$HOPEN"
fm_test_track_procevent_home "$HOPEN"
pe_adapter "$HOPEN" register openended open-src -- /bin/echo "open payload" >/dev/null
out=$(pe_adapter "$HOPEN" start open-src)
assert_contains "$out" "captured:" "a result from an adapter with no terminal verdict is captured"
assert_not_contains "$out" "retired:" "an adapter with no terminal verdict never retires its source"
assert_present "$HOPEN/state/procevent/open-src.source" "a source with no terminal verdict stays armed"
pe_adapter "$HOPEN" retire open-src >/dev/null
pass "a source stays armed unless its own adapter classifies the result terminal"

HREPLACE="$TMP_ROOT/hreplace"; new_home "$HREPLACE"
fm_test_track_procevent_home "$HREPLACE"
OLD_TRIGGER="$TMP_ROOT/replace-old-trigger"
OLD_STARTED="$TMP_ROOT/replace-old-started"
pe_adapter "$HREPLACE" register endnow replace-src -- \
  "$STARTED_BLOCKER" "$OLD_STARTED" "$BLOCKER" "$OLD_TRIGGER" "old terminal payload" >/dev/null
pe_adapter "$HREPLACE" start replace-src > "$TMP_ROOT/replace-old.out" 2>&1 &
replace_old_pid=$!
wait_for "$OLD_STARTED" || fail "the old registration never started"
pe_adapter "$HREPLACE" register openended replace-src -- /bin/echo "replacement payload" >/dev/null
touch "$OLD_TRIGGER"
wait "$replace_old_pid" || fail "the old terminal runner failed"
assert_contains "$(cat "$TMP_ROOT/replace-old.out")" "cannot retire terminal source" \
  "an old runner refuses to retire a replacement registration"
assert_present "$HREPLACE/state/procevent/replace-src.source" \
  "a replacement registration survives the old runner's terminal result"
assert_contains "$(cat "$HREPLACE/state/procevent/replace-src.source")" "adapter=openended" \
  "the surviving registration is the replacement generation"
out=$(pe_adapter "$HREPLACE" start replace-src)
assert_contains "$out" "captured:" "the replacement registration remains independently runnable"
[ "$(count_results "$HREPLACE" replace-src)" = 2 ] \
  || fail "the replacement generation did not capture its own result"
pe_adapter "$HREPLACE" retire replace-src >/dev/null
pass "terminal retirement preserves and releases a concurrently replaced registration"

HRETFAIL="$TMP_ROOT/hretfail"; new_home "$HRETFAIL"
fm_test_track_procevent_home "$HRETFAIL"
FAIL_RM_BIN=$(fm_fakebin "$TMP_ROOT/retire-fail-bin")
REAL_RM=$(command -v rm)
export REAL_RM
cat > "$FAIL_RM_BIN/rm" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in */retire-fail-src.source) exit 1 ;; esac
done
exec "$REAL_RM" "$@"
SH
chmod +x "$FAIL_RM_BIN/rm"
pe_adapter "$HRETFAIL" register endnow retire-fail-src -- /bin/echo "one terminal payload" >/dev/null
out=$(PATH="$FAIL_RM_BIN:$PATH" pe_adapter "$HRETFAIL" start retire-fail-src 2>&1)
assert_contains "$out" "cannot retire terminal source" "a failed registration removal is reported"
assert_present "$HRETFAIL/state/procevent/retire-fail-src.source" \
  "failed retirement preserves the exact registration"
assert_present "$FM_PROCEVENT_CLAIM_ROOT/retire-fail-src.claim" \
  "failed retirement preserves its terminal ownership claim"
out=$(PATH="$FAIL_RM_BIN:$PATH" pe_adapter "$HRETFAIL" reconcile)
assert_contains "$out" "started=0" "failed terminal retirement never restarts the poll"
[ "$(count_results "$HRETFAIL" retire-fail-src)" = 1 ] \
  || fail "failed retirement allowed recurring terminal capture"
pe_adapter "$HRETFAIL" reconcile >/dev/null
assert_absent "$HRETFAIL/state/procevent/retire-fail-src.source" \
  "repeated retirement removes the same registration once removal recovers"
assert_absent "$FM_PROCEVENT_CLAIM_ROOT/retire-fail-src.claim" \
  "the claim releases only after that registration is removed"
[ "$(count_results "$HRETFAIL" retire-fail-src)" = 1 ] \
  || fail "retirement recovery reran the terminal source"
pass "failed terminal retirement is fail-closed and idempotently recoverable"

# --- end-user-aligned regression: one Send & End, one captured result -------
# The dogfood defect: a real armed Lavish source received one human `Send & End`
# action, and the runner captured four results - the human's real feedback, then
# recurring empty ended sessions - because it kept restarting a source whose own
# adapter already knew the session had ended. Driven through the adapter's own
# arm command against a stand-in for the published poll shape, so registration,
# the runner, capture, publication, and retirement all run for real.
HLT="$TMP_ROOT/hlt"; new_home "$HLT"
LAVISH_BIN=$(fm_fakebin "$TMP_ROOT/lavish-stub")
LAVISH_POLL_COUNT="$TMP_ROOT/lavish-poll-count"
export LAVISH_POLL_COUNT
cat > "$LAVISH_BIN/lavish-axi" <<'SH'
#!/usr/bin/env bash
# Stand-in for `lavish-axi poll <file>` around a human `Send & End`: the final
# feedback is delivered exactly once carrying session_ended, and every later
# poll returns an empty ended session immediately.
n=$(cat "$LAVISH_POLL_COUNT" 2>/dev/null || echo 0)
n=$((n + 1))
printf '%s\n' "$n" > "$LAVISH_POLL_COUNT"
if [ "$n" = 1 ]; then
  printf 'session:\n  file: /review.html\n  status: feedback\n  session_ended: true\n  ended_by: user\nfeedback[1]{text}:\n  ship it\n'
else
  printf 'session:\n  file: /review.html\n  status: ended\n  ended_by: user\n'
fi
SH
chmod +x "$LAVISH_BIN/lavish-axi"
REVIEW_ART="$TMP_ROOT/review.html"
printf '<h1>review</h1>\n' > "$REVIEW_ART"
lavish_session "$REVIEW_ART"
lavish_id=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$REVIEW_ART")
fm_test_track_procevent_home "$HLT"
PATH="$LAVISH_BIN:$PATH" FM_HOME="$HLT" "$ROOT/bin/fm-procevent-lavish.sh" arm "$REVIEW_ART" >/dev/null
for _ in $(seq 1 6); do
  PATH="$LAVISH_BIN:$PATH" pe "$HLT" reconcile >/dev/null
  sleep 0.3
done
[ "$(cat "$LAVISH_POLL_COUNT")" = 1 ] \
  || fail "an ended review kept being polled: $(cat "$LAVISH_POLL_COUNT") polls for one Send & End"
[ "$(count_results "$HLT" "$lavish_id")" = 1 ] \
  || fail "one Send & End produced $(count_results "$HLT" "$lavish_id") captured results"
[ "$(wake_payloads "$HLT" | sort -u | grep -c .)" = 1 ] \
  || fail "one Send & End produced more than one distinct event: $(wake_payloads "$HLT" | sort -u)"
assert_contains "$(wake_payloads "$HLT")" "procevent lavish $lavish_id 1" "the human's final feedback is announced"
assert_absent "$HLT/state/procevent/$lavish_id.source" "the ended review source retires automatically"
assert_absent "$FM_PROCEVENT_CLAIM_ROOT/$lavish_id.claim" "the ended review releases its owned claim"
LAVISH_RESULT=$(first_result "$HLT" "$lavish_id" || true)
assert_grep 'ship it' "$LAVISH_RESULT" "automatic retirement retains the human's final feedback"
out=$(PATH="$LAVISH_BIN:$PATH" FM_HOME="$HLT" "$ROOT/bin/fm-procevent-lavish.sh" retire "$REVIEW_ART")
assert_contains "$out" "retired: $lavish_id" "explicit adapter retirement stays supported after automatic retirement"
pass "one Send & End yields exactly one captured result, automatic retirement, and no recurring poll"

# --- end-user-aligned regression: an empty board close is not news ------------
# The captain's report: closing a review surface he had said nothing on still
# put a wake in his chat whose entire content was that nothing happened. The
# adapter now answers the runner's silence seam for exactly that shape, so the
# result is captured and recorded handled without ever being announced. Driven
# through the adapter's own arm command and the real runner, so registration,
# capture, the silence verdict, and retirement all run for real.
HEMPTY="$TMP_ROOT/hempty"; new_home "$HEMPTY"
EMPTY_BIN=$(fm_fakebin "$TMP_ROOT/lavish-empty-stub")
cat > "$EMPTY_BIN/lavish-axi" <<'SH'
#!/usr/bin/env bash
# Stand-in for `lavish-axi poll <file>` when the captain closes a board he said
# nothing on: an ended session carrying no queued content at all.
printf 'session:\n  file: /quiet.html\n  status: ended\n  ended_by: user\n'
SH
chmod +x "$EMPTY_BIN/lavish-axi"
QUIET_ART="$TMP_ROOT/quiet-board.html"
printf '<h1>quiet</h1>\n' > "$QUIET_ART"
lavish_session "$QUIET_ART"
quiet_id=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$QUIET_ART")
fm_test_track_procevent_home "$HEMPTY"
PATH="$EMPTY_BIN:$PATH" FM_HOME="$HEMPTY" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$QUIET_ART" >/dev/null
quiet_out=$(PATH="$EMPTY_BIN:$PATH" pe "$HEMPTY" start "$quiet_id" 2>&1)
assert_not_contains "$quiet_out" "not-autohandled" \
  "a durably silenced result was reported as still unacknowledged"
# The handled marker is written at exactly the point the wake would otherwise
# have been appended, so waiting on it - rather than on a fixed sleep - is what
# makes "no wake" a real observation instead of a race the test won by being
# early.
QUIET_HANDLED="$HEMPTY/state/procevent-inbox/$quiet_id.1.handled"
for _ in $(seq 1 100); do
  [ -f "$QUIET_HANDLED" ] && break
  sleep 0.1
done
[ -f "$QUIET_HANDLED" ] \
  || fail "a silenced result was not durably recorded handled, so a later reconcile would announce it"
[ "$(count_results "$HEMPTY" "$quiet_id")" = 1 ] \
  || fail "an empty board close captured $(count_results "$HEMPTY" "$quiet_id") results instead of one"
[ -z "$(wake_payloads "$HEMPTY")" ] \
  || fail "an empty board close woke the captain: $(wake_payloads "$HEMPTY")"
# Re-announcement is exactly what the handled marker exists to stop, so the
# silence has to survive the reconcile that would otherwise republish it.
PATH="$EMPTY_BIN:$PATH" pe "$HEMPTY" reconcile >/dev/null
sleep 0.3
[ -z "$(wake_payloads "$HEMPTY")" ] \
  || fail "a later reconcile re-announced a silenced empty board close: $(wake_payloads "$HEMPTY")"
assert_absent "$HEMPTY/state/procevent/$quiet_id.source" \
  "an empty board close still retires its ended source"
pass "an empty board close is captured and recorded handled without ever waking the captain"

# --- end-user-aligned regression: worker-owned rounds stay open until re-arm -
# One worker-owned board runs three rounds: feedback reaches only the worker's
# inbox, each re-arm acknowledges the prior capture and posts its reply once,
# and a terminal session ends without another automatic poll.
HMULTI="$TMP_ROOT/hmulti"; new_home "$HMULTI"
MULTI_BIN=$(fm_fakebin "$TMP_ROOT/lavish-multi-stub")
MULTI_ROOT="$TMP_ROOT/lavish-multi-root"
mkdir -p "$MULTI_ROOT"
export MULTI_ROOT
cat > "$MULTI_BIN/lavish-axi" <<'SH'
#!/usr/bin/env bash
set -eu
n=$(cat "$MULTI_ROOT/count" 2>/dev/null || echo 0)
n=$((n + 1))
printf '%s\n' "$n" > "$MULTI_ROOT/count"
printf '%s:%s\n' "${LAVISH_AXI_HOST-unset}" "${LAVISH_AXI_PORT-unset}" >> "$MULTI_ROOT/routes"
for arg in "$@"; do
  case "$arg" in
    --agent-reply) ;;
    --*)
      printf 'error: unknown option %s\ncode: VALIDATION_ERROR\n' "$arg" >&2
      exit 2
      ;;
  esac
done
if [ "${1-}" = poll ] && [ "${3-}" = --agent-reply ]; then
  printf 'poll%s reply: %s\n' "$n" "$4" >> "$MULTI_ROOT/replies"
fi
while [ ! -e "$MULTI_ROOT/trigger$n" ]; do sleep 0.02; done
case "$n" in
  1|2)
    printf 'session:\n  status: feedback\nprompts[1]{uid,prompt,selector,tag,text}:\n  "","round %s","","message",""\n' "$n"
    ;;
  3)
    printf 'session:\n  status: ended\n  session_ended: true\n'
    ;;
esac
SH
chmod +x "$MULTI_BIN/lavish-axi"
printf 'reply one\n' > "$MULTI_ROOT/reply1"
printf 'reply two\n' > "$MULTI_ROOT/reply2"
printf 'reply three\n' > "$MULTI_ROOT/reply3"
MULTI_ART="$MULTI_ROOT/board.html"
printf '<h1>multi-round</h1>\n' > "$MULTI_ART"
lavish_session "$MULTI_ART"
multi_id=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$MULTI_ART")
fm_test_track_procevent_home "$HMULTI"
new_task_endpoint "$HMULTI" worker-1
new_task_endpoint "$HMULTI" worker-2
mkdir -p "$HMULTI/config"
printf 'wrong-server.example\n' > "$HMULTI/config/lavish-axi-host"
PATH="$MULTI_BIN:$PATH" LAVISH_AXI_HOST=arming.example LAVISH_AXI_PORT=24387 FM_HOME="$HMULTI" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$MULTI_ART" --for worker-1 \
  --agent-reply-file "$MULTI_ROOT/reply1" >/dev/null
if PATH="$MULTI_BIN:$PATH" FM_HOME="$HMULTI" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$MULTI_ART" >/dev/null 2>"$MULTI_ROOT/firstmate-arm.err"; then
  fail "firstmate arm replaced a worker-owned board"
fi
assert_contains "$(cat "$MULTI_ROOT/firstmate-arm.err")" "owned by task worker-1" \
  "second armer refusal did not name the worker owner"
list_out=$(FM_HOME="$HMULTI" "$ROOT/bin/fm-procevent.sh" list)
assert_contains "$list_out" "task:worker-1/dead" \
  "the source list did not expose the worker-owned board state"
PATH="$MULTI_BIN:$PATH" LAVISH_AXI_HOST=recovery.example LAVISH_AXI_PORT=34387 FM_HOME="$HMULTI" \
  pe "$HMULTI" start "$multi_id" > "$MULTI_ROOT/run1" 2>&1 &
MULTI_RUN=$!
for _ in $(seq 1 100); do [ "$(cat "$MULTI_ROOT/count" 2>/dev/null || true)" = 1 ] && break; sleep 0.02; done
touch "$MULTI_ROOT/trigger1"
for _ in $(seq 1 100); do [ -f "$HMULTI/state/worker-1.inbox/001.msg" ] && break; sleep 0.02; done
[ -f "$HMULTI/state/worker-1.inbox/001.msg" ] \
  || fail "worker-owned feedback did not reach the worker inbox"
[ -z "$(wake_payloads "$HMULTI")" ] \
  || fail "worker-owned feedback woke firstmate: $(wake_payloads "$HMULTI")"

# An open nonterminal round keeps the board with worker-1 through every
# retirement and registration path: the one source record cannot be retired out
# from under that round, and while it stands neither firstmate nor a sibling
# task can register over it or acknowledge worker-1's capture.
open_retire_status=0
PATH="$MULTI_BIN:$PATH" FM_HOME="$HMULTI" \
  "$ROOT/bin/fm-procevent-lavish.sh" retire "$MULTI_ART" \
  >/dev/null 2>"$MULTI_ROOT/open-retire.err" || open_retire_status=$?
[ "$open_retire_status" -ne 0 ] \
  || fail "explicit retire removed a worker-owned board with an unacknowledged round"
assert_contains "$(cat "$MULTI_ROOT/open-retire.err")" "unacknowledged" \
  "the refused retire did not say the owner's round is still unacknowledged"
[ -e "$HMULTI/state/procevent/$multi_id.source" ] \
  || fail "a refused retire still removed the worker-owned source record"
if PATH="$MULTI_BIN:$PATH" FM_HOME="$HMULTI" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$MULTI_ART" --for worker-2 \
  >/dev/null 2>"$MULTI_ROOT/open-sibling.err"; then
  fail "a sibling task registered over an open worker-owned round"
fi
assert_contains "$(cat "$MULTI_ROOT/open-sibling.err")" "owned by task worker-1" \
  "the sibling refusal over an open round did not name the worker owner"
if PATH="$MULTI_BIN:$PATH" FM_HOME="$HMULTI" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$MULTI_ART" \
  >/dev/null 2>"$MULTI_ROOT/open-firstmate.err"; then
  fail "firstmate armed a board with an open worker-owned round"
fi
assert_contains "$(cat "$MULTI_ROOT/open-firstmate.err")" "owned by task worker-1" \
  "the firstmate refusal over an open round did not name the worker owner"
[ ! -f "$HMULTI/state/procevent-inbox/$multi_id.1.handled" ] \
  || fail "a refused retire or registration acknowledged the owner's open round"
[ ! -e "$HMULTI/state/worker-2.inbox" ] \
  || fail "a refused sibling registration took delivery of the owner's feedback"

PATH="$MULTI_BIN:$PATH" FM_HOME="$HMULTI" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$MULTI_ART" --for worker-1 \
  --agent-reply-file "$MULTI_ROOT/reply2" >/dev/null
wait "$MULTI_RUN" || true
for _ in $(seq 1 100); do
  PATH="$MULTI_BIN:$PATH" pe "$HMULTI" reconcile >/dev/null 2>&1 || true
  [ "$(cat "$MULTI_ROOT/count" 2>/dev/null || true)" = 2 ] && break
  sleep 0.03
done
touch "$MULTI_ROOT/trigger2"
for _ in $(seq 1 100); do [ -f "$HMULTI/state/worker-1.inbox/002.msg" ] && break; sleep 0.02; done
[ -f "$HMULTI/state/worker-1.inbox/002.msg" ] \
  || fail "the next worker-owned feedback did not reach the worker inbox"
PATH="$MULTI_BIN:$PATH" FM_HOME="$HMULTI" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$MULTI_ART" --for worker-1 \
  --agent-reply-file "$MULTI_ROOT/reply3" >/dev/null
for _ in $(seq 1 100); do
  PATH="$MULTI_BIN:$PATH" pe "$HMULTI" reconcile >/dev/null 2>&1 || true
  [ "$(cat "$MULTI_ROOT/count" 2>/dev/null || true)" = 3 ] && break
  sleep 0.03
done
touch "$MULTI_ROOT/trigger3"
for _ in $(seq 1 100); do [ -f "$HMULTI/state/worker-1.inbox/003.msg" ] && break; sleep 0.02; done
[ -f "$HMULTI/state/procevent-inbox/$multi_id.1.handled" ] \
  || fail "first worker-owned round was not acknowledged by re-arm"
[ -f "$HMULTI/state/procevent-inbox/$multi_id.2.handled" ] \
  || fail "second worker-owned round was not acknowledged by re-arm"
assert_contains "$(cat "$HMULTI/state/worker-1.inbox/003.msg" 2>/dev/null || true)" \
  "do not re-arm" "terminal worker-owned result instructed the worker to stop"
[ "$(grep -c '^poll[123] reply:' "$MULTI_ROOT/replies" 2>/dev/null || true)" = 3 ] \
  || fail "worker replies were not posted once per round"
assert_contains "$(cat "$MULTI_ROOT/replies")" "poll1 reply: reply one" \
  "the reply staged with the arm was not the one the board received"
printf '%s\n' '127.0.0.1:14387' '127.0.0.1:14387' '127.0.0.1:14387' > "$MULTI_ROOT/expected-routes"
cmp -s "$MULTI_ROOT/expected-routes" "$MULTI_ROOT/routes" \
  || fail "worker replies/polls did not use the opened session server across start and reconcile"
pass "worker board replies and recovered listeners derive their server from the board session"

# The terminal round keeps the board with worker-1 until worker-1 acknowledges
# it, so the one source record stays the only ownership evidence there is: while
# it is open neither firstmate nor a sibling task can arm the board or consume
# the round, and acknowledging it is what concludes and retires the board.
[ -e "$HMULTI/state/procevent/$multi_id.source" ] \
  || fail "the terminal round released the worker's board before it was acknowledged"
if PATH="$MULTI_BIN:$PATH" FM_HOME="$HMULTI" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$MULTI_ART" >/dev/null 2>"$MULTI_ROOT/terminal-arm.err"; then
  fail "firstmate armed a worker-owned board whose terminal round was unacknowledged"
fi
assert_contains "$(cat "$MULTI_ROOT/terminal-arm.err")" "owned by task worker-1" \
  "the refusal over an open terminal round did not name the worker owner"
if PATH="$MULTI_BIN:$PATH" FM_HOME="$HMULTI" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$MULTI_ART" --for worker-2 \
  >/dev/null 2>"$MULTI_ROOT/sibling-arm.err"; then
  fail "a sibling task took over a worker-owned board whose terminal round was unacknowledged"
fi
assert_contains "$(cat "$MULTI_ROOT/sibling-arm.err")" "owned by task worker-1" \
  "the sibling registration refusal did not name the worker owner"
terminal_retire_status=0
PATH="$MULTI_BIN:$PATH" FM_HOME="$HMULTI" \
  "$ROOT/bin/fm-procevent-lavish.sh" retire "$MULTI_ART" \
  >/dev/null 2>"$MULTI_ROOT/terminal-retire.err" || terminal_retire_status=$?
[ "$terminal_retire_status" -ne 0 ] \
  || fail "explicit retire removed a worker-owned board with an unacknowledged terminal round"
[ -e "$HMULTI/state/procevent/$multi_id.source" ] \
  || fail "a refused retire removed the worker-owned record of an open terminal round"
[ ! -f "$HMULTI/state/procevent-inbox/$multi_id.3.handled" ] \
  || fail "a refused sibling registration consumed the owner's terminal round"
[ ! -f "$HMULTI/state/worker-2.inbox/001.msg" ] \
  || fail "a refused sibling registration took delivery of the owner's feedback"
chmod 0500 "$HMULTI/state/procevent"
blocked_handled_status=0
PATH="$MULTI_BIN:$PATH" pe "$HMULTI" handled "$multi_id" 3 \
  >/dev/null 2>"$MULTI_ROOT/blocked-handled.err" || blocked_handled_status=$?
chmod 0700 "$HMULTI/state/procevent"
[ "$blocked_handled_status" -ne 0 ] \
  || fail "an acknowledgement that could not retire the board still reported success"
[ ! -f "$HMULTI/state/procevent-inbox/$multi_id.3.handled" ] \
  || fail "an acknowledgement that could not retire the board still closed the round"
[ -e "$HMULTI/state/procevent/$multi_id.source" ] \
  || fail "a failed conclude left the board unowned"
PATH="$MULTI_BIN:$PATH" pe "$HMULTI" handled "$multi_id" 3 >/dev/null
[ -f "$HMULTI/state/procevent-inbox/$multi_id.3.handled" ] \
  || fail "the owner's acknowledgement of the terminal round was not recorded"
[ ! -e "$HMULTI/state/procevent/$multi_id.source" ] \
  || fail "acknowledging the terminal round did not retire the worker-owned board"
PATH="$MULTI_BIN:$PATH" pe "$HMULTI" reconcile >/dev/null 2>&1 || true
[ "$(cat "$MULTI_ROOT/count")" = 3 ] \
  || fail "the concluded board was polled again: $(cat "$MULTI_ROOT/count") polls"
[ -z "$(wake_payloads "$HMULTI")" ] \
  || fail "worker-owned rounds produced a firstmate wake: $(wake_payloads "$HMULTI")"
pass "worker-owned Lavish rounds deliver to the worker, acknowledge on re-arm, and stop at session end"

# --- end-user-aligned regression: a half-written capture does not wedge -----
# The result file is a capture's commit marker, so an owner sidecar left behind
# at a sequence with no result - a crash between publishing that sidecar and
# committing the result - is replaceable staging state. The next capture takes
# the same sequence and still routes to the owning worker.
HORPHAN="$TMP_ROOT/horphan"; new_home "$HORPHAN"
ORPHAN_BIN=$(fm_fakebin "$TMP_ROOT/lavish-orphan-stub")
cat > "$ORPHAN_BIN/lavish-axi" <<'SH'
#!/usr/bin/env bash
printf 'session:\n  status: feedback\nprompts[1]{uid,prompt,selector,tag,text}:\n  "","after the crash","","message",""\n'
SH
chmod +x "$ORPHAN_BIN/lavish-axi"
ORPHAN_ART="$TMP_ROOT/orphan-board.html"
printf '<h1>orphan</h1>\n' > "$ORPHAN_ART"
lavish_session "$ORPHAN_ART"
orphan_id=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$ORPHAN_ART")
fm_test_track_procevent_home "$HORPHAN"
new_task_endpoint "$HORPHAN" worker-4
PATH="$ORPHAN_BIN:$PATH" FM_HOME="$HORPHAN" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$ORPHAN_ART" --for worker-4 >/dev/null
(umask 077; mkdir -p "$HORPHAN/state/procevent-inbox")
chmod 0700 "$HORPHAN/state/procevent-inbox"
printf 'worker-4\n' > "$HORPHAN/state/procevent-inbox/$orphan_id.1.owner-task"
chmod 0600 "$HORPHAN/state/procevent-inbox/$orphan_id.1.owner-task"
PATH="$ORPHAN_BIN:$PATH" pe "$HORPHAN" start "$orphan_id" >/dev/null 2>&1 || true
[ -f "$HORPHAN/state/procevent-inbox/$orphan_id.1.result" ] \
  || fail "an owner sidecar with no committed result wedged the next capture of its source"
[ -f "$HORPHAN/state/worker-4.inbox/001.msg" ] \
  || fail "the recovered capture did not reach its owning worker's steering inbox"
pass "a capture interrupted before its result commit does not wedge its source"

# --- end-user-aligned regression: an orphaned capture keeps its owner ---------
# An unacknowledged capture belongs to whoever it was routed to. Retiring the
# board it came from orphans that capture without handing it to anyone, so a
# worker arming the same artifact is refused rather than silently acknowledging
# a round that never reached it.
HADOPT="$TMP_ROOT/hadopt"; new_home "$HADOPT"
ADOPT_BIN=$(fm_fakebin "$TMP_ROOT/lavish-adopt-stub")
cat > "$ADOPT_BIN/lavish-axi" <<'SH'
#!/usr/bin/env bash
printf 'session:\n  status: feedback\nprompts[1]{uid,prompt,selector,tag,text}:\n  "","for firstmate","","message",""\n'
SH
chmod +x "$ADOPT_BIN/lavish-axi"
ADOPT_ART="$TMP_ROOT/adopt-board.html"
printf '<h1>adopt</h1>\n' > "$ADOPT_ART"
lavish_session "$ADOPT_ART"
adopt_id=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$ADOPT_ART")
fm_test_track_procevent_home "$HADOPT"
new_task_endpoint "$HADOPT" worker-5
PATH="$ADOPT_BIN:$PATH" FM_HOME="$HADOPT" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$ADOPT_ART" >/dev/null
PATH="$ADOPT_BIN:$PATH" pe "$HADOPT" start "$adopt_id" >/dev/null 2>&1 || true
[ -f "$HADOPT/state/procevent-inbox/$adopt_id.1.result" ] \
  || fail "the firstmate fixture capture never landed"
[ ! -f "$HADOPT/state/procevent-inbox/$adopt_id.1.handled" ] \
  || fail "the firstmate fixture capture was already acknowledged"
PATH="$ADOPT_BIN:$PATH" FM_HOME="$HADOPT" \
  "$ROOT/bin/fm-procevent-lavish.sh" retire "$ADOPT_ART" >/dev/null
if PATH="$ADOPT_BIN:$PATH" FM_HOME="$HADOPT" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$ADOPT_ART" --for worker-5 \
  >/dev/null 2>"$TMP_ROOT/adopt-arm.err"; then
  fail "a worker armed a board carrying another owner's unacknowledged capture"
fi
assert_contains "$(cat "$TMP_ROOT/adopt-arm.err")" "firstmate" \
  "the refusal did not name the owner the orphaned capture belongs to"
[ ! -f "$HADOPT/state/procevent-inbox/$adopt_id.1.handled" ] \
  || fail "a refused arm still acknowledged another owner's capture"
[ ! -e "$HADOPT/state/procevent/$adopt_id.source" ] \
  || fail "a refused arm still published its task-owned registration"
pass "an orphaned capture is not acknowledged by a worker it never reached"

# --- end-user-aligned regression: a board is armed for a reachable owner ------
# Captured feedback goes straight to the owning task's steering inbox, so a task
# id that names no endpoint would strand every round it ever collects. The arm
# path refuses it instead of publishing a registration nobody can be told about.
HNOMETA="$TMP_ROOT/hnometa"; new_home "$HNOMETA"
NOMETA_ART="$TMP_ROOT/nometa-board.html"
printf '<h1>no endpoint</h1>\n' > "$NOMETA_ART"
lavish_session "$NOMETA_ART"
nometa_id=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$NOMETA_ART")
fm_test_track_procevent_home "$HNOMETA"
if PATH="$ADOPT_BIN:$PATH" FM_HOME="$HNOMETA" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$NOMETA_ART" --for worker-10 \
  >/dev/null 2>"$TMP_ROOT/nometa-arm.err"; then
  fail "a board was armed for a task id that names no endpoint"
fi
assert_contains "$(cat "$TMP_ROOT/nometa-arm.err")" "worker-10" \
  "the refusal did not name the task whose endpoint is missing"
[ ! -e "$HNOMETA/state/procevent/$nometa_id.source" ] \
  || fail "a board armed for an unreachable owner still published its registration"
new_task_endpoint "$HNOMETA" worker-10
PATH="$ADOPT_BIN:$PATH" FM_HOME="$HNOMETA" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$NOMETA_ART" --for worker-10 >/dev/null
[ -e "$HNOMETA/state/procevent/$nometa_id.source" ] \
  || fail "a board was refused for a task that does have an endpoint"
pass "a worker-owned board is only armed for an owner its feedback can reach"

# --- end-user-aligned regression: an open round is re-delivered --------------
# Filing the steering note away is not acknowledging the round. A worker that
# moved the note aside and then crashed still owes the round, so the next
# reconcile has to put a live note back in its inbox rather than ring an empty
# one.
HREDELIVER="$TMP_ROOT/hredeliver"; new_home "$HREDELIVER"
REDELIVER_ART="$TMP_ROOT/redeliver-board.html"
printf '<h1>redeliver</h1>\n' > "$REDELIVER_ART"
lavish_session "$REDELIVER_ART"
redeliver_id=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$REDELIVER_ART")
fm_test_track_procevent_home "$HREDELIVER"
new_task_endpoint "$HREDELIVER" worker-6
PATH="$ADOPT_BIN:$PATH" FM_HOME="$HREDELIVER" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$REDELIVER_ART" --for worker-6 >/dev/null
PATH="$ADOPT_BIN:$PATH" pe "$HREDELIVER" start "$redeliver_id" >/dev/null 2>&1 || true
[ -f "$HREDELIVER/state/worker-6.inbox/001.msg" ] \
  || fail "the first worker-owned round never reached the worker inbox"
mv "$HREDELIVER/state/worker-6.inbox/001.msg" \
  "$HREDELIVER/state/worker-6.inbox/handled/001.msg"
PATH="$ADOPT_BIN:$PATH" pe "$HREDELIVER" reconcile >/dev/null 2>&1 || true
[ -f "$HREDELIVER/state/worker-6.inbox/001.msg" ] \
  || fail "a round still open after its note was filed away was never re-delivered"
[ ! -f "$HREDELIVER/state/procevent-inbox/$redeliver_id.1.handled" ] \
  || fail "re-delivering the note acknowledged the round it is still asking for"
pass "an open worker-owned round is re-delivered after its note was filed away"

# --- end-user-aligned regression: a conclude only closes its own round --------
# Acknowledging a terminal round retires the board it belongs to. The same
# acknowledgement repeated later is a no-op on a closed round, so it must not
# reach past it and retire whatever board the artifact carries by then.
HCONC="$TMP_ROOT/hconclude"; new_home "$HCONC"
CONC_BIN=$(fm_fakebin "$TMP_ROOT/lavish-conclude-stub")
cat > "$CONC_BIN/lavish-axi" <<'SH'
#!/usr/bin/env bash
printf 'session:\n  status: ended\n  session_ended: true\n'
SH
chmod +x "$CONC_BIN/lavish-axi"
CONC_ART="$TMP_ROOT/conclude-board.html"
printf '<h1>conclude</h1>\n' > "$CONC_ART"
lavish_session "$CONC_ART"
conc_id=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$CONC_ART")
fm_test_track_procevent_home "$HCONC"
new_task_endpoint "$HCONC" worker-7
PATH="$CONC_BIN:$PATH" FM_HOME="$HCONC" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$CONC_ART" --for worker-7 >/dev/null
PATH="$CONC_BIN:$PATH" pe "$HCONC" start "$conc_id" >/dev/null 2>&1 || true
[ -f "$HCONC/state/procevent-inbox/$conc_id.1.result" ] \
  || fail "the terminal worker-owned round never landed"
[ -e "$HCONC/state/procevent/$conc_id.source" ] \
  || fail "the terminal round released the board before its owner acknowledged it"
chmod 0500 "$HCONC/state/procevent-inbox"
unrecordable_status=0
PATH="$CONC_BIN:$PATH" pe "$HCONC" handled "$conc_id" 1 >/dev/null 2>&1 || unrecordable_status=$?
chmod 0700 "$HCONC/state/procevent-inbox"
[ "$unrecordable_status" -ne 0 ] \
  || fail "an acknowledgement that could not be recorded still reported success"
[ ! -f "$HCONC/state/procevent-inbox/$conc_id.1.handled" ] \
  || fail "an acknowledgement that could not be recorded still closed the round"
[ -e "$HCONC/state/procevent/$conc_id.source" ] \
  || fail "an acknowledgement that could not be recorded still released the board it was owed"
conclude_out=$(PATH="$CONC_BIN:$PATH" pe "$HCONC" handled "$conc_id" 1)
assert_contains "$conclude_out" "retired: $conc_id" \
  "acknowledging the terminal round did not report the board retired"
[ ! -e "$HCONC/state/procevent/$conc_id.source" ] \
  || fail "acknowledging the terminal round did not retire the worker-owned board"
PATH="$CONC_BIN:$PATH" FM_HOME="$HCONC" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$CONC_ART" --for worker-7 >/dev/null
repeat_out=$(PATH="$CONC_BIN:$PATH" pe "$HCONC" handled "$conc_id" 1)
assert_contains "$repeat_out" "already-handled: $conc_id 1" \
  "repeating a closed acknowledgement did not report it as already handled"
case "$repeat_out" in
  *retired:*) fail "repeating a closed acknowledgement retired a board it never belonged to" ;;
esac
[ -e "$HCONC/state/procevent/$conc_id.source" ] \
  || fail "repeating a closed acknowledgement retired the board armed after it"
pass "acknowledging a terminal round concludes that round only"

# --- end-user-aligned regression: an interrupted conclude ends the board -----
# The conclude drops the registration and then records the acknowledgement. An
# interruption between those steps must leave nothing that relaunches the ended
# board, and the same acknowledgement has to finish the job on the next try.
HINTR="$TMP_ROOT/hinterrupted"; new_home "$HINTR"
INTR_ROOT="$TMP_ROOT/lavish-interrupted-root"; mkdir -p "$INTR_ROOT"; export INTR_ROOT
INTR_BIN=$(fm_fakebin "$TMP_ROOT/lavish-interrupted-stub")
cat > "$INTR_BIN/lavish-axi" <<'SH'
#!/usr/bin/env bash
n=$(cat "$INTR_ROOT/count" 2>/dev/null || echo 0)
printf '%s\n' "$((n + 1))" > "$INTR_ROOT/count"
printf 'session:\n  status: ended\n  session_ended: true\n'
SH
chmod +x "$INTR_BIN/lavish-axi"
INTR_ART="$TMP_ROOT/interrupted-board.html"
printf '<h1>interrupted</h1>\n' > "$INTR_ART"
lavish_session "$INTR_ART"
intr_id=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$INTR_ART")
fm_test_track_procevent_home "$HINTR"
new_task_endpoint "$HINTR" worker-12
PATH="$INTR_BIN:$PATH" FM_HOME="$HINTR" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$INTR_ART" --for worker-12 >/dev/null
PATH="$INTR_BIN:$PATH" pe "$HINTR" start "$intr_id" >/dev/null 2>&1 || true
[ "$(cat "$INTR_ROOT/count" 2>/dev/null || echo 0)" = 1 ] \
  || fail "the terminal worker-owned round was not polled exactly once"
rm -f "$HINTR/state/procevent/$intr_id.source"
PATH="$INTR_BIN:$PATH" pe "$HINTR" reconcile >/dev/null 2>&1 || true
[ "$(cat "$INTR_ROOT/count" 2>/dev/null || echo 0)" = 1 ] \
  || fail "an interrupted conclude let the ended board be polled again"
if PATH="$INTR_BIN:$PATH" FM_HOME="$HINTR" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$INTR_ART" --for worker-12 \
  >/dev/null 2>"$INTR_ROOT/intr-arm.err"; then
  fail "an interrupted conclude let its owner re-arm the ended board"
fi
assert_contains "$(cat "$INTR_ROOT/intr-arm.err")" "terminal" \
  "the refusal did not say the round still owed a conclude is terminal"
intr_out=$(PATH="$INTR_BIN:$PATH" pe "$HINTR" handled "$intr_id" 1)
assert_contains "$intr_out" "handled: $intr_id 1" \
  "repeating the interrupted acknowledgement did not record it"
[ -f "$HINTR/state/procevent-inbox/$intr_id.1.handled" ] \
  || fail "the interrupted conclude was never finished by the repeated acknowledgement"
pass "an interrupted conclude leaves the ended board unpollable and finishes on retry"

# --- end-user-aligned regression: a failed re-arm keeps the last generation ---
# Re-arm publishes the next generation and acknowledges the round it replaces.
# When that acknowledgement cannot be recorded the whole re-arm has to be off,
# leaving the generation the board is actually running untouched.
HROLL="$TMP_ROOT/hrollback"; new_home "$HROLL"
ROLL_ROOT="$TMP_ROOT/lavish-rollback-root"; mkdir -p "$ROLL_ROOT"; export ROLL_ROOT
ROLL_BIN=$(fm_fakebin "$TMP_ROOT/lavish-rollback-stub")
cat > "$ROLL_BIN/lavish-axi" <<'SH'
#!/usr/bin/env bash
set -eu
[ "${3-}" != --agent-reply ] || printf '%s\n' "$4" >> "$ROLL_ROOT/replies"
printf 'session:\n  status: feedback\nprompts[1]{uid,prompt,selector,tag,text}:\n  "","another round","","message",""\n'
SH
chmod +x "$ROLL_BIN/lavish-axi"
ROLL_ART="$TMP_ROOT/rollback-board.html"
printf '<h1>rollback</h1>\n' > "$ROLL_ART"
lavish_session "$ROLL_ART"
roll_id=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$ROLL_ART")
fm_test_track_procevent_home "$HROLL"
new_task_endpoint "$HROLL" worker-8
printf 'reply from generation one\n' > "$ROLL_ROOT/reply1"
printf 'reply from generation two\n' > "$ROLL_ROOT/reply2"
PATH="$ROLL_BIN:$PATH" FM_HOME="$HROLL" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$ROLL_ART" --for worker-8 \
  --agent-reply-file "$ROLL_ROOT/reply1" >/dev/null
PATH="$ROLL_BIN:$PATH" pe "$HROLL" start "$roll_id" >/dev/null 2>&1 || true
[ "$(grep -c 'generation one' "$ROLL_ROOT/replies" 2>/dev/null || true)" = 1 ] \
  || fail "the first generation's reply never reached the board"
cp "$HROLL/state/procevent/$roll_id.source" "$ROLL_ROOT/generation-one.source"
chmod 0500 "$HROLL/state/procevent-inbox"
rollback_status=0
PATH="$ROLL_BIN:$PATH" FM_HOME="$HROLL" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$ROLL_ART" --for worker-8 \
  --agent-reply-file "$ROLL_ROOT/reply2" >/dev/null 2>&1 || rollback_status=$?
chmod 0700 "$HROLL/state/procevent-inbox"
[ "$rollback_status" -ne 0 ] \
  || fail "a re-arm that could not acknowledge its round still reported success"
cmp -s "$ROLL_ROOT/generation-one.source" "$HROLL/state/procevent/$roll_id.source" \
  || fail "a failed re-arm replaced the generation the board is still running"
[ ! -f "$HROLL/state/procevent-inbox/$roll_id.1.handled" ] \
  || fail "a failed re-arm still acknowledged the round it could not close"
PATH="$ROLL_BIN:$PATH" FM_HOME="$HROLL" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$ROLL_ART" --for worker-8 \
  --agent-reply-file "$ROLL_ROOT/reply2" >/dev/null
PATH="$ROLL_BIN:$PATH" pe "$HROLL" start "$roll_id" >/dev/null 2>&1 || true
[ "$(grep -c 'generation two' "$ROLL_ROOT/replies" 2>/dev/null || true)" = 1 ] \
  || fail "the retried re-arm did not hand the board its generation's reply exactly once"
pass "a re-arm that cannot acknowledge its round leaves the running generation alone"

# --- end-user-aligned regression: re-arm is acknowledgement, nothing else -----
# The board is armed once and re-armed only to acknowledge a captured round. A
# worker that re-arms while its listener is still waiting would replace the
# generation carrying the reply it already handed over, and that reply would be
# swept away without ever reaching the board.
HREARM="$TMP_ROOT/hrearm"; new_home "$HREARM"
REARM_ROOT="$TMP_ROOT/lavish-rearm-root"; mkdir -p "$REARM_ROOT"; export REARM_ROOT
REARM_BIN=$(fm_fakebin "$TMP_ROOT/lavish-rearm-stub")
cat > "$REARM_BIN/lavish-axi" <<'SH'
#!/usr/bin/env bash
set -eu
[ "${3-}" != --agent-reply ] || printf '%s\n' "$4" >> "$REARM_ROOT/replies"
printf 'session:\n  status: feedback\nprompts[1]{uid,prompt,selector,tag,text}:\n  "","one more round","","message",""\n'
SH
chmod +x "$REARM_BIN/lavish-axi"
REARM_ART="$TMP_ROOT/rearm-board.html"
printf '<h1>rearm</h1>\n' > "$REARM_ART"
lavish_session "$REARM_ART"
rearm_id=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$REARM_ART")
fm_test_track_procevent_home "$HREARM"
new_task_endpoint "$HREARM" worker-11
printf 'first generation reply\n' > "$REARM_ROOT/reply1"
printf 'second generation reply\n' > "$REARM_ROOT/reply2"
PATH="$REARM_BIN:$PATH" FM_HOME="$HREARM" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$REARM_ART" --for worker-11 \
  --agent-reply-file "$REARM_ROOT/reply1" >/dev/null
[ -e "$HREARM/state/procevent/$rearm_id.source" ] \
  || fail "the initial arm of a worker-owned board did not register it"
if PATH="$REARM_BIN:$PATH" FM_HOME="$HREARM" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$REARM_ART" --for worker-11 \
  --agent-reply-file "$REARM_ROOT/reply2" >/dev/null 2>"$REARM_ROOT/idle-rearm.err"; then
  fail "a worker re-armed its own board with no captured round to acknowledge"
fi
assert_contains "$(cat "$REARM_ROOT/idle-rearm.err")" "worker-11" \
  "the refused idle re-arm did not name the task that already holds the board"
PATH="$REARM_BIN:$PATH" pe "$HREARM" start "$rearm_id" >/dev/null 2>&1 || true
[ "$(grep -c 'first generation reply' "$REARM_ROOT/replies" 2>/dev/null || true)" = 1 ] \
  || fail "the refused idle re-arm cost the board the reply its listener was already carrying"
[ -f "$HREARM/state/procevent-inbox/$rearm_id.1.result" ] \
  || fail "the first worker-owned round never landed"
if PATH="$REARM_BIN:$PATH" FM_HOME="$HREARM" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$REARM_ART" --for worker-11 \
  --agent-reply-file "$REARM_ROOT/never-written" >/dev/null 2>&1; then
  fail "a re-arm carrying a nonexistent reply path was accepted"
fi
[ ! -f "$HREARM/state/procevent-inbox/$rearm_id.1.handled" ] \
  || fail "a re-arm refused over its reply path still acknowledged the open round"
PATH="$REARM_BIN:$PATH" FM_HOME="$HREARM" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$REARM_ART" --for worker-11 \
  --agent-reply-file "$REARM_ROOT/reply2" >/dev/null
[ -f "$HREARM/state/procevent-inbox/$rearm_id.1.handled" ] \
  || fail "re-arming over an open round did not acknowledge that round"
PATH="$REARM_BIN:$PATH" pe "$HREARM" start "$rearm_id" >/dev/null 2>&1 || true
[ "$(grep -c 'second generation reply' "$REARM_ROOT/replies" 2>/dev/null || true)" = 1 ] \
  || fail "the acknowledging re-arm did not hand the board its own generation's reply"
pass "a worker-owned board is armed once and re-armed only to acknowledge an open round"

# The other half of the same contract, on the same real path: a close that
# carries what the captain actually said must still reach him. Same runner, same
# adapter, one different response shape.
HANSWER="$TMP_ROOT/hanswer"; new_home "$HANSWER"
ANSWER_BIN=$(fm_fakebin "$TMP_ROOT/lavish-answer-stub")
cat > "$ANSWER_BIN/lavish-axi" <<'SH'
#!/usr/bin/env bash
# Stand-in for `lavish-axi poll <file>` on a real `Send & End`: the captain's
# own choice, delivered with session_ended.
printf 'session:\n  file: /answered.html\n  status: feedback\n  session_ended: true\n  ended_by: user\nprompts[1]{tag,text,prompt}:\n  "choice","Option B","Context data: {\\"question\\":\\"noop-check-routing\\",\\"answer\\":\\"b\\"}"\n'
SH
chmod +x "$ANSWER_BIN/lavish-axi"
ANSWER_ART="$TMP_ROOT/answered-board.html"
printf '<h1>answered</h1>\n' > "$ANSWER_ART"
lavish_session "$ANSWER_ART"
answer_id=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$ANSWER_ART")
fm_test_track_procevent_home "$HANSWER"
PATH="$ANSWER_BIN:$PATH" FM_HOME="$HANSWER" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$ANSWER_ART" >/dev/null
PATH="$ANSWER_BIN:$PATH" pe "$HANSWER" reconcile >/dev/null
wait_for "$HANSWER/state/.wake-queue" \
  || fail "a board close carrying the captain's real answer produced no wake"
assert_contains "$(wake_payloads "$HANSWER")" "procevent lavish $answer_id 1" \
  "a real board answer still reaches the captain"
[ ! -f "$HANSWER/state/procevent-inbox/$answer_id.1.handled" ] \
  || fail "a real board answer was recorded handled without ever being handled"
pass "a board close carrying the captain's real answer is still announced"

# --- end-user-aligned regression: a transient poll interruption is not news ---
# The dogfood defect: a live board listener can answer with exactly
#     error: Lavish Editor poll response was interrupted
#     code: SERVER_ERROR
# while the board's marks remain available. Firstmate registered raw poll output,
# so the generic runner captured that transient response and woke the whole fleet
# over what is really an internal retry. Every scenario below runs through the
# adapter's own arm command and the real runner, so registration, capture, and
# publication are exercised for real.
LAVISH_SCRIPTED_BIN=$(fm_fakebin "$TMP_ROOT/lavish-scripted-stub")
cat > "$LAVISH_SCRIPTED_BIN/lavish-axi" <<'SH'
#!/usr/bin/env bash
# Stand-in for `lavish-axi poll <file>`, scripted per scenario: LAVISH_SCRIPT
# names the response for each successive poll, one word per poll, and its last
# word repeats forever. `interrupt` is the exact transient response the server
# returns while the board's marks stay available.
n=$(cat "$LAVISH_COUNT" 2>/dev/null || echo 0)
n=$((n + 1))
printf '%s\n' "$n" > "$LAVISH_COUNT"
for arg in "$@"; do
  case "$arg" in
    --agent-reply) ;;
    --*)
      printf 'error: unknown option %s\ncode: VALIDATION_ERROR\n' "$arg" >&2
      exit 2
      ;;
  esac
done
if [ -n "${LAVISH_REPLY_LOG-}" ] && [ "${1-}" = poll ] && [ "${3-}" = --agent-reply ]; then
  printf '%s\n' "$4" >> "$LAVISH_REPLY_LOG"
fi
read -r -a plan <<< "$LAVISH_SCRIPT"
i=$((n - 1))
[ "$i" -ge "${#plan[@]}" ] && i=$((${#plan[@]} - 1))
case "${plan[$i]}" in
  interrupt)
    printf 'error: Lavish Editor poll response was interrupted\ncode: SERVER_ERROR\n'; exit 1 ;;
  near-interrupt)
    printf 'error: Lavish Editor poll response was interrupted \ncode: SERVER_ERROR\n'; exit 1 ;;
  other-server-error)
    printf 'error: Lavish Editor session store is unavailable\ncode: SERVER_ERROR\n'; exit 1 ;;
  feedback)
    printf 'session:\n  file: /board.html\n  status: feedback\n  session_ended: true\n  ended_by: user\nfeedback[1]{text}:\n  ship it\n' ;;
  stream)
    printf 'x%.0s' {1..4096}
    printf 'ready\n' > "$LAVISH_STREAM_READY"
    while [ ! -e "$LAVISH_STREAM_RELEASE" ]; do sleep 0.05; done
    printf '\n' ;;
esac
SH
chmod +x "$LAVISH_SCRIPTED_BIN/lavish-axi"
export LAVISH_COUNT LAVISH_SCRIPT

DEFAULT_RATE_ART="$TMP_ROOT/default-rate-board.html"
printf '<h1>default rate</h1>\n' > "$DEFAULT_RATE_ART"
lavish_session "$DEFAULT_RATE_ART"
DEFAULT_RATE_COUNT="$TMP_ROOT/default-rate-count"
PATH="$LAVISH_SCRIPTED_BIN:$PATH" LAVISH_COUNT="$DEFAULT_RATE_COUNT" LAVISH_SCRIPT=interrupt \
  FM_LAVISH_POLL_RETRY_DELAY='' \
  "$ROOT/bin/fm-procevent-lavish.sh" poll "$DEFAULT_RATE_ART" >/dev/null 2>&1 &
DEFAULT_RATE_PID=$!
perl -MTime::HiRes=sleep -e 'sleep 6.2'
kill -TERM "$DEFAULT_RATE_PID" 2>/dev/null || true
wait "$DEFAULT_RATE_PID" 2>/dev/null || true
default_rate_count=$(cat "$DEFAULT_RATE_COUNT" 2>/dev/null || echo 0)
[ "$default_rate_count" -ge 2 ] \
  || fail "the default poll governor stopped an instantly returning source from making progress"
[ "$default_rate_count" -le 2 ] \
  || fail "the shipped poll governor allowed $default_rate_count iterations in 6.2 seconds"
pass "the shipped poll governor bounds an instantly returning source"

# A bounded test override keeps the retry policy's real bound under test without
# making the suite wait out the production delay.
export FM_LAVISH_POLL_RETRY_DELAY=1

# Two interruptions, then the captain's real feedback: the retries are silent and
# only the feedback becomes a captured result and a check wake.
HRETRY="$TMP_ROOT/hretry"; new_home "$HRETRY"
RETRY_ART="$TMP_ROOT/retry-board.html"
printf '<h1>retry</h1>\n' > "$RETRY_ART"
lavish_session "$RETRY_ART"
retry_id=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$RETRY_ART")
fm_test_track_procevent_home "$HRETRY"
LAVISH_COUNT="$TMP_ROOT/retry-count"; LAVISH_SCRIPT="interrupt interrupt feedback"
PATH="$LAVISH_SCRIPTED_BIN:$PATH" FM_HOME="$HRETRY" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$RETRY_ART" >/dev/null
PATH="$LAVISH_SCRIPTED_BIN:$PATH" pe "$HRETRY" reconcile >/dev/null
wait_for "$HRETRY/state/.wake-queue" || fail "feedback after interrupted polls produced no wake"
[ "$(cat "$LAVISH_COUNT")" = 3 ] \
  || fail "the interrupted listener was polled $(cat "$LAVISH_COUNT") times, not the two quiet retries plus the delivering poll"
[ "$(count_results "$HRETRY" "$retry_id")" = 1 ] \
  || fail "a retried interruption produced $(count_results "$HRETRY" "$retry_id") captured results instead of one"
[ "$(wake_payloads "$HRETRY" | sort -u | grep -c .)" = 1 ] \
  || fail "a retried interruption woke the fleet: $(wake_payloads "$HRETRY" | sort -u)"
assert_contains "$(wake_payloads "$HRETRY")" "procevent lavish $retry_id 1" \
  "feedback arriving after quiet retries is captured and announced"
assert_grep 'ship it' "$(first_result "$HRETRY" "$retry_id")" \
  "the announced result is the captain's feedback, not the interruption"
pass "a transient Lavish poll interruption is retried quietly and never announced"

# --- end-user-aligned regression: a retried poll does not resubmit the reply ---
# The worker hands its round reply to the adapter once. When the first poll of
# that round comes back as the transient interruption, the adapter's own quiet
# retries must keep polling WITHOUT the reply, or the board receives the same
# worker message once per retry.
HREPLY="$TMP_ROOT/hreply"; new_home "$HREPLY"
REPLY_ART="$TMP_ROOT/reply-retry-board.html"
printf '<h1>reply retry</h1>\n' > "$REPLY_ART"
lavish_session "$REPLY_ART"
reply_id=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$REPLY_ART")
fm_test_track_procevent_home "$HREPLY"
new_task_endpoint "$HREPLY" worker-9
printf 'applied round one\n' > "$TMP_ROOT/reply-retry.txt"
LAVISH_REPLY_LOG="$TMP_ROOT/reply-retry-log"; export LAVISH_REPLY_LOG
LAVISH_COUNT="$TMP_ROOT/reply-retry-count"; LAVISH_SCRIPT="interrupt interrupt feedback"
PATH="$LAVISH_SCRIPTED_BIN:$PATH" FM_HOME="$HREPLY" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$REPLY_ART" --for worker-9 \
  --agent-reply-file "$TMP_ROOT/reply-retry.txt" >/dev/null
PATH="$LAVISH_SCRIPTED_BIN:$PATH" pe "$HREPLY" start "$reply_id" >/dev/null
[ "$(cat "$LAVISH_COUNT")" = 3 ] \
  || fail "the reply-carrying listener was polled $(cat "$LAVISH_COUNT") times, not the two quiet retries plus the delivering poll"
[ "$(grep -c 'applied round one' "$LAVISH_REPLY_LOG" 2>/dev/null || true)" = 1 ] \
  || fail "the staged worker reply reached the board $(grep -c 'applied round one' "$LAVISH_REPLY_LOG" 2>/dev/null || true) times across the adapter's internal retries"
[ -f "$HREPLY/state/worker-9.inbox/001.msg" ] \
  || fail "the round that delivered after quiet retries did not reach the worker inbox"
unset LAVISH_REPLY_LOG
pass "a staged worker reply is handed to the board once across quiet poll retries"

# The other side of the same best-effort contract: posting a reply is allowed to
# lose it, so a listener that starts with no staged reply - because a crash
# consumed it, or because the round simply carries none - must still poll the
# board, with no reply and no refusal.
MISSING_REPLY_COUNT="$TMP_ROOT/missing-reply-count"
MISSING_REPLY_LOG="$TMP_ROOT/missing-reply-log"
missing_reply_status=0
PATH="$LAVISH_SCRIPTED_BIN:$PATH" LAVISH_COUNT="$MISSING_REPLY_COUNT" LAVISH_SCRIPT=feedback \
  LAVISH_REPLY_LOG="$MISSING_REPLY_LOG" \
  "$ROOT/bin/fm-procevent-lavish.sh" poll "$REPLY_ART" \
  --agent-reply-file "$TMP_ROOT/never-staged-reply" >/dev/null 2>&1 || missing_reply_status=$?
[ "$missing_reply_status" -eq 0 ] \
  || fail "a listener whose staged reply was gone refused to poll (status $missing_reply_status)"
[ "$(cat "$MISSING_REPLY_COUNT" 2>/dev/null || echo 0)" = 1 ] \
  || fail "a listener whose staged reply was gone never polled the board"
[ ! -s "$MISSING_REPLY_LOG" ] \
  || fail "a listener whose staged reply was gone still posted something: $(cat "$MISSING_REPLY_LOG")"
pass "a listener whose staged reply is gone polls the board without one"

# The accepted loss window is consuming-to-calling and nothing wider: a listener
# that never reaches the board at all must leave the staged reply for the next
# one. A malformed retry-delay override is one of the ordinary setup refusals
# that used to happen after the reply had already been consumed.
SETUP_GUARD_REPLY="$TMP_ROOT/setup-guard-reply"
SETUP_GUARD_COUNT="$TMP_ROOT/setup-guard-count"
printf 'kept for the next listener\n' > "$SETUP_GUARD_REPLY"
setup_guard_status=0
PATH="$LAVISH_SCRIPTED_BIN:$PATH" LAVISH_COUNT="$SETUP_GUARD_COUNT" LAVISH_SCRIPT=feedback \
  FM_LAVISH_POLL_RETRY_DELAY=not-a-number \
  "$ROOT/bin/fm-procevent-lavish.sh" poll "$REPLY_ART" \
  --agent-reply-file "$SETUP_GUARD_REPLY" >/dev/null 2>&1 || setup_guard_status=$?
[ "$setup_guard_status" -ne 0 ] \
  || fail "a malformed retry delay did not stop the listener before it polled"
[ "$(cat "$SETUP_GUARD_COUNT" 2>/dev/null || echo 0)" = 0 ] \
  || fail "a listener that refused its setup still reached the board"
[ -f "$SETUP_GUARD_REPLY" ] \
  || fail "a listener that never reached the board consumed its staged reply anyway"
pass "a listener that refuses its own setup leaves the staged reply for the next one"

# The board itself is part of that setup: an artifact that vanished between the
# re-arm and the listener's launch cannot be polled at all, so the reply it was
# carrying has to survive for the listener that polls the next one.
GONE_ART="$TMP_ROOT/artifact-gone-board.html"
GONE_REPLY="$TMP_ROOT/artifact-gone-reply"
GONE_COUNT="$TMP_ROOT/artifact-gone-count"
printf '<h1>gone</h1>\n' > "$GONE_ART"
lavish_session "$GONE_ART"
printf 'owed to the next listener\n' > "$GONE_REPLY"
rm -f "$GONE_ART"
gone_status=0
PATH="$LAVISH_SCRIPTED_BIN:$PATH" LAVISH_COUNT="$GONE_COUNT" LAVISH_SCRIPT=feedback \
  "$ROOT/bin/fm-procevent-lavish.sh" poll "$GONE_ART" \
  --agent-reply-file "$GONE_REPLY" >/dev/null 2>&1 || gone_status=$?
[ "$gone_status" -ne 0 ] \
  || fail "a listener whose artifact vanished reported a successful poll"
[ "$(cat "$GONE_COUNT" 2>/dev/null || echo 0)" = 0 ] \
  || fail "a listener whose artifact vanished still reached the board"
[ -f "$GONE_REPLY" ] \
  || fail "a listener whose artifact vanished consumed its staged reply anyway"
pass "a listener whose artifact vanished leaves the staged reply for the next one"

# Exhaustion is news: after the bounded retries the same exact response is
# captured and announced normally rather than being swallowed forever.
HEXH="$TMP_ROOT/hexh"; new_home "$HEXH"
EXH_ART="$TMP_ROOT/exhaust-board.html"
printf '<h1>exhaust</h1>\n' > "$EXH_ART"
lavish_session "$EXH_ART"
exh_id=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$EXH_ART")
fm_test_track_procevent_home "$HEXH"
LAVISH_COUNT="$TMP_ROOT/exhaust-count"; LAVISH_SCRIPT="interrupt"
PATH="$LAVISH_SCRIPTED_BIN:$PATH" FM_HOME="$HEXH" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$EXH_ART" >/dev/null
PATH="$LAVISH_SCRIPTED_BIN:$PATH" pe "$HEXH" start "$exh_id" >/dev/null
[ "$(cat "$LAVISH_COUNT")" = 13 ] \
  || fail "the retry bound polled $(cat "$LAVISH_COUNT") times, not the first poll plus 12 bounded retries"
[ "$(count_results "$HEXH" "$exh_id")" = 1 ] \
  || fail "exhaustion produced $(count_results "$HEXH" "$exh_id") captured results instead of one"
assert_contains "$(wake_payloads "$HEXH")" "procevent lavish $exh_id 1" \
  "the interruption that survives the bound is announced normally"
assert_grep 'poll response was interrupted' "$(first_result "$HEXH" "$exh_id")" \
  "the announced result is the exact interruption the server returned"
PATH="$LAVISH_SCRIPTED_BIN:$PATH" FM_HOME="$HEXH" \
  "$ROOT/bin/fm-procevent-lavish.sh" retire "$EXH_ART" >/dev/null
pass "an interruption that outlives the bounded retries is captured and announced"

# A different SERVER_ERROR is a genuine error, never a retry: no fail-open drift
# from the one exact transient response this adapter owns.
HOTHER="$TMP_ROOT/hother"; new_home "$HOTHER"
OTHER_ART="$TMP_ROOT/other-board.html"
printf '<h1>other</h1>\n' > "$OTHER_ART"
lavish_session "$OTHER_ART"
other_id=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$OTHER_ART")
fm_test_track_procevent_home "$HOTHER"
LAVISH_COUNT="$TMP_ROOT/other-count"; LAVISH_SCRIPT="other-server-error"
PATH="$LAVISH_SCRIPTED_BIN:$PATH" FM_HOME="$HOTHER" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$OTHER_ART" >/dev/null
PATH="$LAVISH_SCRIPTED_BIN:$PATH" pe "$HOTHER" start "$other_id" >/dev/null
[ "$(cat "$LAVISH_COUNT")" = 1 ] \
  || fail "an unrelated SERVER_ERROR was retried $(cat "$LAVISH_COUNT") times instead of surfacing at once"
assert_contains "$(wake_payloads "$HOTHER")" "procevent lavish $other_id 1" \
  "an unrelated SERVER_ERROR is captured and announced immediately"
PATH="$LAVISH_SCRIPTED_BIN:$PATH" FM_HOME="$HOTHER" \
  "$ROOT/bin/fm-procevent-lavish.sh" retire "$OTHER_ART" >/dev/null
pass "only the exact interruption is retried; an unrelated SERVER_ERROR still surfaces"
unset FM_LAVISH_POLL_RETRY_DELAY

# A whitespace variant is not the exact transient response and must surface on
# the first poll instead of drifting into the quiet retry policy.
HNEAR="$TMP_ROOT/hnear"; new_home "$HNEAR"
NEAR_ART="$TMP_ROOT/near-board.html"
printf '<h1>near</h1>\n' > "$NEAR_ART"
lavish_session "$NEAR_ART"
near_id=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$NEAR_ART")
fm_test_track_procevent_home "$HNEAR"
LAVISH_COUNT="$TMP_ROOT/near-count"; LAVISH_SCRIPT="near-interrupt feedback"
PATH="$LAVISH_SCRIPTED_BIN:$PATH" FM_HOME="$HNEAR" FM_LAVISH_POLL_RETRY_DELAY=1 \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$NEAR_ART" >/dev/null
PATH="$LAVISH_SCRIPTED_BIN:$PATH" FM_HOME="$HNEAR" pe "$HNEAR" start "$near_id" >/dev/null
[ "$(cat "$LAVISH_COUNT")" = 1 ] \
  || fail "a near-match interruption was retried instead of surfacing on its first poll"
assert_contains "$(wake_payloads "$HNEAR")" "procevent lavish $near_id 1" \
  "a whitespace variant of the interruption is captured and announced immediately"
PATH="$LAVISH_SCRIPTED_BIN:$PATH" FM_HOME="$HNEAR" \
  "$ROOT/bin/fm-procevent-lavish.sh" retire "$NEAR_ART" >/dev/null
pass "only the literal two-line interruption enters the quiet retry policy"

# The public arm boundary refuses invalid retry intervals before it publishes a
# source registration, rather than arming a listener that can only fail later.
HINVALID="$TMP_ROOT/hinvalid"; new_home "$HINVALID"
INVALID_ART="$TMP_ROOT/invalid-delay-board.html"
printf '<h1>invalid delay</h1>\n' > "$INVALID_ART"
lavish_session "$INVALID_ART"
invalid_id=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$INVALID_ART")
for invalid_delay in 0 61 invalid; do
  invalid_status=0
  invalid_out=$(PATH="$LAVISH_SCRIPTED_BIN:$PATH" FM_HOME="$HINVALID" \
    FM_LAVISH_POLL_RETRY_DELAY="$invalid_delay" \
    "$ROOT/bin/fm-procevent-lavish.sh" arm "$INVALID_ART" 2>&1) || invalid_status=$?
  [ "$invalid_status" -ne 0 ] \
    || fail "arm accepted invalid retry delay: $invalid_delay"
  assert_contains "$invalid_out" "must be whole seconds from 1 to 60" \
    "arm explains the rejected retry delay"
  assert_absent "$HINVALID/state/procevent/$invalid_id.source" \
    "arm publishes no source registration for an invalid retry delay"
done
pass "arm rejects malformed and out-of-range retry delays before registration"

# Shell-safe cleanup must preserve a valid TMPDIR containing an apostrophe.
QUOTED_TMPDIR="$TMP_ROOT/poll's-stage"
mkdir -p "$QUOTED_TMPDIR"
LAVISH_COUNT="$TMP_ROOT/quoted-count"; LAVISH_SCRIPT="feedback"
PATH="$LAVISH_SCRIPTED_BIN:$PATH" TMPDIR="$QUOTED_TMPDIR" \
  "$ROOT/bin/fm-procevent-lavish.sh" poll "$NEAR_ART" >/dev/null
quoted_staged=("$QUOTED_TMPDIR"/fm-lavish-poll.*)
[ ! -e "${quoted_staged[0]}" ] \
  || fail "poll left its staged response behind in an apostrophe-containing TMPDIR"
pass "poll cleanup safely handles an apostrophe-containing TMPDIR"

HSTREAM="$TMP_ROOT/hstream"; new_home "$HSTREAM"
STREAM_ART="$TMP_ROOT/stream-board.html"
STREAM_TMPDIR="$TMP_ROOT/stream-stage"
LAVISH_STREAM_READY="$TMP_ROOT/stream-ready"
LAVISH_STREAM_RELEASE="$TMP_ROOT/stream-release"
mkdir -p "$STREAM_TMPDIR"
printf '<h1>stream</h1>\n' > "$STREAM_ART"
lavish_session "$STREAM_ART"
stream_id=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$STREAM_ART")
fm_test_track_procevent_home "$HSTREAM"
LAVISH_COUNT="$TMP_ROOT/stream-count"; LAVISH_SCRIPT="stream"
PATH="$LAVISH_SCRIPTED_BIN:$PATH" FM_HOME="$HSTREAM" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$STREAM_ART" >/dev/null
PATH="$LAVISH_SCRIPTED_BIN:$PATH" TMPDIR="$STREAM_TMPDIR" \
  LAVISH_STREAM_READY="$LAVISH_STREAM_READY" LAVISH_STREAM_RELEASE="$LAVISH_STREAM_RELEASE" \
  FM_PROCEVENT_MAX_OUTPUT_BYTES=100 pe "$HSTREAM" reconcile >/dev/null
wait_for "$LAVISH_STREAM_READY" || fail "streaming poll did not start"
stream_staged=("$STREAM_TMPDIR"/fm-lavish-poll.*)
[ -e "${stream_staged[0]}" ] || fail "streaming poll created no classifier staging file"
[ "$(wc -c < "${stream_staged[0]}" | tr -d ' ')" -le 100 ] \
  || fail "streaming poll exceeded its bounded classifier staging"
: > "$LAVISH_STREAM_RELEASE"
wait_for "$HSTREAM/state/.wake-queue" || fail "streaming poll produced no wake"
stream_result=$(first_result "$HSTREAM" "$stream_id" || true)
[ "$(wc -c < "$stream_result" | tr -d ' ')" -le 100 ] \
  || fail "streaming poll bypassed the runner output bound"
PATH="$LAVISH_SCRIPTED_BIN:$PATH" FM_HOME="$HSTREAM" \
  "$ROOT/bin/fm-procevent-lavish.sh" retire "$STREAM_ART" >/dev/null
pass "Lavish classification staging stays bounded while nonmatches stream"

# --- end-user-aligned regression: the exact drain-before-handling restart cut
# Reproduces the confirmed defect through the public interface end to end: a
# real blocking source completes, its result is captured and published, the
# wake is drained without any handling, a replacement session's reconcile must
# resurface the exact same source and sequence, and only the owned handling
# interface may retire it - safely and without ever authorizing a paired
# effect a second time.
HW="$TMP_ROOT/hw"; new_home "$HW"
TRIGW="$TMP_ROOT/trigger-restart-cut"
pe_register "$HW" lavish restart-cut-src -- "$BLOCKER" "$TRIGW" "restart cut payload" >/dev/null
pe "$HW" start restart-cut-src > "$TMP_ROOT/restart-cut-start.log" 2>&1 &
restart_cut_start_pid=$!
sleep 0.5
: > "$TRIGW"
wait_for "$HW/state/.wake-queue" || fail "the restart-cut source published no event"
assert_contains "$(wake_payloads "$HW")" "procevent lavish restart-cut-src 1" \
  "capture and publish reaches the wake queue before any handling"

# Retire the registration now that the source has completed and captured its
# one result. The fixture's trigger file persists on disk, so a still-armed
# registration would let every further reconcile call restart the blocker and
# capture a fresh generation; retiring leaves only the durable inbox and wake
# state under test, matching the exact restart cut - the source side is done,
# only the handling side is still open.
# Publication precedes runner exit; wait for completion before retiring.
wait "$restart_cut_start_pid" || fail "the restart-cut source did not complete"
pe "$HW" retire restart-cut-src >/dev/null \
  || fail "the restart-cut registration was not retired"

# Drain the wake without handling it: the end-user experience of a session
# reading the wake queue at turn end without yet acting on this specific line.
mv "$HW/state/.wake-queue" "$HW/state/.wake-queue.drained-unhandled"
[ -z "$(wake_payloads "$HW")" ] || fail "the wake queue was not actually drained"

# Simulate a replacement Firstmate session: reconcile runs cold, as it would on
# a fresh process with no memory of the prior turn.
out=$(pe "$HW" reconcile)
assert_contains "$out" "published=1" \
  "a replacement session's reconcile resurfaces a drained-but-unhandled result"
assert_contains "$(wake_payloads "$HW")" "procevent lavish restart-cut-src 1" \
  "the exact same captured source and sequence resurfaces, never a substitute"

# Acknowledge handling through the owned interface.
ack_out=$(pe "$HW" handled restart-cut-src 1)
assert_contains "$ack_out" "handled: restart-cut-src 1" \
  "the first acknowledgement newly authorizes the paired effect"

mv "$HW/state/.wake-queue" "$HW/state/.wake-queue.post-handle"
out=$(pe "$HW" reconcile)
assert_contains "$out" "published=0" \
  "a later reconcile does not resurface a result once it is durably handled"
[ -z "$(wake_payloads "$HW")" ] || fail "a handled result was announced again: $(wake_payloads "$HW")"

auth_count=0
for _ in 1 2 3; do
  repeat_ack=$(pe "$HW" handled restart-cut-src 1)
  assert_contains "$repeat_ack" "already-handled: restart-cut-src 1" "repeated acknowledgement stays safe and idempotent"
  case "$repeat_ack" in handled:*) auth_count=$((auth_count + 1)) ;; esac
done
[ "$auth_count" -eq 0 ] || fail "a result already durably handled was authorized again: count=$auth_count"
pass "a drained-but-unhandled result survives a replacement session and is retired only by explicit handling, never twice"

HP="$TMP_ROOT/hp"; new_home "$HP"
mkdir -p "$HP/state/procevent-inbox"
for seq in 10 2 1; do
  printf '%s\n' "$seq" > "$HP/state/procevent-inbox/ordered-src.$seq.result"
  printf 'lavish\n' > "$HP/state/procevent-inbox/ordered-src.$seq.adapter"
  chmod 0600 "$HP/state/procevent-inbox/ordered-src.$seq.result" "$HP/state/procevent-inbox/ordered-src.$seq.adapter"
done
pending=$(bash -c '. "$1/bin/fm-procevent-lib.sh"; fm_procevent_pending "$2"' _ "$ROOT" "$HP/state")
expected=$(printf '%s\n' \
  "$HP/state/procevent-inbox/ordered-src.1.result" \
  "$HP/state/procevent-inbox/ordered-src.2.result" \
  "$HP/state/procevent-inbox/ordered-src.10.result")
[ "$pending" = "$expected" ] || fail "pending results were not emitted in numeric sequence order: $pending"
pe "$HP" reconcile >/dev/null
deduped=$(FM_HOME="$HP" bash -c '
  . "$1/bin/fm-wake-lib.sh"
  fm_wake_print_deduped "$2/state/.wake-queue" | awk -F "\t" "{print \$5}"
' _ "$ROOT" "$HP")
expected=$(printf '%s\n' \
  'check: procevent lavish ordered-src 1' \
  'check: procevent lavish ordered-src 2' \
  'check: procevent lavish ordered-src 10')
[ "$deduped" = "$expected" ] || fail "distinct result generations were coalesced or reordered: $deduped"
pass "pending results preserve numeric order and distinct wake identity"

printf '\nall procevent tests passed\n'
