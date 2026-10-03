#!/usr/bin/env bash
# Behavior tests for how the supervision-branch offer rule
# (.pi/extensions/lib/fm-branch-dispatch.ts, reached through
# bin/fm-branch-dispatch.mjs offer) treats the rows the wake fold records
# (bin/fm-wake-fold-lib.sh): a home's own outbound parent-channel echo and a
# repeated custom-check output are claimable by the branch without a task
# instead of vetoing the scan, the fold's digest and re-arm closes go to an
# attended host only when nothing is left for main, and every existing veto
# plus config/wake-fold=off still restores the unfolded verdicts.
#
# Rows are queued through the real fold library, so the queue row and the
# .wake-fold record are the production pair; the verdicts are read through the
# real dispatch entry.
# shellcheck disable=SC2016 # single-quoted scripts expand inside their own shells
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DISPATCH="$ROOT/bin/fm-branch-dispatch.mjs"

command -v node >/dev/null 2>&1 || { printf 'skip: node absent\n'; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-offer-wake-fold)

# A fresh home with one mapped worker task (demo).
fold_offer_home() {  # <name>
  local home="$TMP_ROOT/fold-offer-$1"
  rm -rf "$home"
  mkdir -p "$home/state" "$home/config"
  printf 'project=demo\nwindow=fm-demo\n' > "$home/state/demo.meta"
  : > "$home/state/.wake-queue"
  printf '%s\n' "$home"
}

# Queue a row the way the watcher's fold does.
fold_offer_fold_row() {  # <home> <kind> <key> <payload> <class>
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" bash -c '
    # shellcheck disable=SC1090,SC1091
    . "$1/bin/fm-wake-lib.sh" && . "$1/bin/fm-wake-fold-lib.sh"
    fm_wake_fold_append "$2" "$3" "$4" "$5"
  ' _ "$ROOT" "$2" "$3" "$4" "$5" || fail "the fold library refused to queue a $5 row"
}

# The offer verdict for <reason> in <home>, optionally away.
fold_offer() {  # <home> <reason> [--afk]
  local home=$1 reason=$2
  shift 2
  printf '%s\n' "$reason" | env -u FM_CONFIG_OVERRIDE -u FM_STATE_OVERRIDE FM_HOME="$home" node "$DISPATCH" offer "$@"
}

assert_offer() {  # <home> <reason> <eligible> <status> <description> [--afk]
  local home=$1 reason=$2 eligible=$3 status=$4 what=$5 out
  shift 5
  out=$(fold_offer "$home" "$reason" "$@")
  assert_contains "$out" "eligible=$eligible" "$what: wrong eligible verdict in: $out"
  assert_contains "$out" "status=$status" "$what: wrong scan status in: $out"
}

SIG="signal: demo.status"
DIGEST='check: wake digest: 1 folded routine wake row(s) queued, oldest 900s'
REARM='check: rearm-resurface'
ECHO_ROW='signal: parent-replies.status'

test_report_offer_probe_table_with_the_fold_on() {
  local home state out
  home=$(fold_offer_home table)
  state="$home/state"
  append_wake "$state" signal demo.status "$SIG"
  assert_offer "$home" "$SIG" 1 safe "worker row only"
  append_wake "$state" check merge 'check: merge landed: fixture'
  out=$(fold_offer "$home" "$SIG")
  assert_offer "$home" "$SIG" 1 safe "plus a check row"
  assert_contains "$out" "rows=1"$'\n' "a check row must stay main's"
  fold_offer_fold_row "$home" signal parent-replies.status "$ECHO_ROW" own-outbound
  out=$(fold_offer "$home" "$SIG")
  assert_offer "$home" "$SIG" 1 safe "plus a queued own-outbound parent-replies row"
  assert_contains "$out" "rows=1 3" "the folded echo must be claimed beside the worker row"
  assert_contains "$out" "tasks=demo" "a folded row must add no task"
  assert_contains "$out" "unscoped=0" "a folded row beside a task row must not widen the claim's scope"
  assert_contains "$out" "corrupted=0" "a folded row must not corrupt the scan"
  append_wake "$state" signal gone.status 'signal: gone.status'
  assert_offer "$home" "$SIG" 0 unsafe "plus a torn-down task row"
  assert_contains "$(fold_offer "$home" "$SIG")" "corrupted=1" "a torn-down task row must stay a scan veto"

  home=$(fold_offer_home stale)
  state="$home/state"
  append_wake "$state" signal demo.status "$SIG"
  fold_offer_fold_row "$home" signal parent-replies.status "$ECHO_ROW" own-outbound
  append_wake "$state" stale fm-ghost 'stale: fm-ghost'
  assert_offer "$home" "$SIG" 0 unsafe "plus a stale unmapped row"
  assert_contains "$(fold_offer "$home" "$SIG")" "corrupted=1" "an unmapped stale row must stay a scan veto"
  pass "offer rule: the report's offer-probe table gets the new verdicts with the fold on"
}

test_wake_fold_off_restores_the_unfolded_verdicts() {
  local home state out
  home=$(fold_offer_home off)
  state="$home/state"
  append_wake "$state" signal demo.status "$SIG"
  fold_offer_fold_row "$home" signal parent-replies.status "$ECHO_ROW" own-outbound
  assert_offer "$home" "$SIG" 1 safe "fold on, before switching off"
  printf 'off\n' > "$home/config/wake-fold"
  out=$(fold_offer "$home" "$SIG")
  assert_offer "$home" "$SIG" 0 unsafe "wake-fold off with a recorded parent-replies row"
  assert_contains "$out" "corrupted=1" "wake-fold off must restore the unresolvable-row veto"
  assert_contains "$out" "rows="$'\n' "wake-fold off must claim nothing"
  printf 'garbage\n' > "$home/config/wake-fold"
  assert_offer "$home" "$SIG" 0 unsafe "an unrecognized wake-fold switch"
  printf 'on\n' > "$home/config/wake-fold"
  assert_offer "$home" "$SIG" 1 safe "wake-fold explicitly on"
  rm -f "$home/config/wake-fold"
  assert_offer "$home" "$SIG" 1 safe "wake-fold absent"

  # The same restore holds for the fold's own closes.
  home=$(fold_offer_home digest-off)
  fold_offer_fold_row "$home" signal parent-replies.status "$ECHO_ROW" own-outbound
  assert_offer "$home" "$DIGEST" 1 safe "a digest with the fold on"
  printf 'off\n' > "$home/config/wake-fold"
  assert_offer "$home" "$DIGEST" 0 unsafe "a digest with wake-fold off"
  home=$(fold_offer_home rearm-off)
  assert_offer "$home" "$REARM" 1 empty "an empty re-arm with the fold on"
  printf 'off\n' > "$home/config/wake-fold"
  assert_offer "$home" "$REARM" 0 empty "an empty re-arm with wake-fold off"

  # An away or quiet record also leaves the fold inactive.
  home=$(fold_offer_home away)
  state="$home/state"
  append_wake "$state" signal demo.status "$SIG"
  fold_offer_fold_row "$home" signal parent-replies.status "$ECHO_ROW" own-outbound
  assert_offer "$home" "$SIG" 0 unsafe "an away scan with a folded row (the fold is inactive away)" --afk
  : > "$state/.afk"
  assert_offer "$home" "$SIG" 0 unsafe "a daemon away flag"
  pass "offer rule: config/wake-fold=off and away records restore today's verdicts exactly"
}

test_unrecorded_and_mismatched_rows_are_classified_as_before() {
  local home state out
  home=$(fold_offer_home unrecorded)
  state="$home/state"
  append_wake "$state" signal demo.status "$SIG"
  append_wake "$state" signal parent-replies.status "$ECHO_ROW"
  assert_offer "$home" "$SIG" 0 unsafe "an unrecorded parent-replies row"

  home=$(fold_offer_home mismatch)
  state="$home/state"
  append_wake "$state" signal demo.status "$SIG"
  append_wake "$state" check merge 'check: merge landed: fixture'
  printf '2\t1\town-outbound\n' > "$state/.wake-fold"
  out=$(fold_offer "$home" "$SIG")
  assert_contains "$out" "rows=1"$'\n' "an own-outbound record on a check row must not claim it"
  assert_contains "$out" "eligible=1" "the worker row must still be claimed"

  home=$(fold_offer_home torn-record)
  state="$home/state"
  append_wake "$state" signal demo.status "$SIG"
  append_wake "$state" signal parent-replies.status "$ECHO_ROW"
  printf 'x\t1\town-outbound\n2\n2\t1\tother\n' > "$state/.wake-fold"
  assert_offer "$home" "$SIG" 0 unsafe "a malformed fold record"
  pass "offer rule: an unrecorded, mismatched, or malformed fold record claims nothing"
}

test_open_decisions_still_reach_main_beside_a_folded_row() {
  local home state out
  home=$(fold_offer_home decision)
  state="$home/state"
  append_wake "$state" signal demo.status 'needs-decision: pick one'
  fold_offer_fold_row "$home" signal parent-replies.status "$ECHO_ROW" own-outbound
  assert_offer "$home" "$SIG" 0 safe "a needs-decision worker signal beside a folded row"
  out=$(fold_offer "$home" "$SIG")
  assert_contains "$out" "rows=2"$'\n' "only the folded row may be claimed beside a decision row"

  # A folded echo whose payload is itself a decision keeps its decision handling.
  home=$(fold_offer_home decision-echo)
  fold_offer_fold_row "$home" signal parent-replies.status 'needs-decision: ask the parent' own-outbound
  out=$(env -u FM_CONFIG_OVERRIDE -u FM_STATE_OVERRIDE FM_HOME="$home" node "$DISPATCH" scope)
  assert_contains "$out" "rows="$'\n' "an echoed needs-decision must not be claimed as folded"

  # An ordinary check close stays main's.
  home=$(fold_offer_home other-check)
  fold_offer_fold_row "$home" signal parent-replies.status "$ECHO_ROW" own-outbound
  assert_offer "$home" 'check: merge landed: fixture' 0 safe "an ordinary check close"
  pass "offer rule: decision rows and ordinary check closes still reach main beside a folded row"
}

test_folded_check_repeat_rows_are_claimed_beside_a_worker_row() {
  local home state out
  home=$(fold_offer_home check-repeat)
  state="$home/state"
  append_wake "$state" signal demo.status "$SIG"
  fold_offer_fold_row "$home" check cloud-workers 'check: cloud workers: 3 idle' check-repeat
  out=$(fold_offer "$home" "$SIG")
  assert_contains "$out" "rows=1 2" "a folded check-repeat row must be claimed with the worker row"
  assert_contains "$out" "unscoped=0" "a claimed check-repeat row beside a task row keeps the claim scoped"
  pass "offer rule: a repeated check output is claimed without a task and without widening the worker claim"
}

test_fold_closes_go_to_the_host_only_when_nothing_is_left_for_main() {
  local home state out
  home=$(fold_offer_home digest)
  state="$home/state"
  fold_offer_fold_row "$home" signal parent-replies.status "$ECHO_ROW" own-outbound
  out=$(fold_offer "$home" "$DIGEST")
  assert_offer "$home" "$DIGEST" 1 safe "a digest of only folded rows"
  assert_contains "$out" "rows=1"$'\n' "the digest must claim the folded row"
  assert_contains "$out" "unscoped=1" "a claim of only folded rows names no task"
  append_wake "$state" check merge 'check: merge landed: fixture'
  assert_offer "$home" "$DIGEST" 0 safe "a digest beside a non-folded check row"

  home=$(fold_offer_home digest-empty)
  assert_offer "$home" "$DIGEST" 0 empty "a digest with nothing queued"

  home=$(fold_offer_home rearm)
  state="$home/state"
  assert_offer "$home" "$REARM" 1 empty "a re-arm with an empty queue"
  rm -f "$state/.wake-queue"
  assert_offer "$home" "$REARM" 0 unsafe "a re-arm with no readable queue"
  : > "$state/.wake-queue"
  append_wake "$state" signal demo.status "$SIG"
  fold_offer_fold_row "$home" signal parent-replies.status "$ECHO_ROW" own-outbound
  assert_offer "$home" "$REARM" 1 safe "a re-arm with only claimable rows"
  append_wake "$state" check merge 'check: merge landed: fixture'
  assert_offer "$home" "$REARM" 0 safe "a re-arm with a check row left for main"
  home=$(fold_offer_home rearm-decision)
  append_wake "$home/state" signal demo.status 'needs-decision: pick one'
  assert_offer "$home" "$REARM" 0 unsafe "a re-arm with a decision row left for main"
  home=$(fold_offer_home rearm-unsafe)
  append_wake "$home/state" signal demo.status "$SIG"
  append_wake "$home/state" signal gone.status 'signal: gone.status'
  assert_offer "$home" "$REARM" 0 unsafe "a re-arm with an unresolvable row"
  pass "offer rule: the fold's digest and re-arm closes reach the host only when no row is left for main"
}

test_report_offer_probe_table_with_the_fold_on
test_wake_fold_off_restores_the_unfolded_verdicts
test_unrecorded_and_mismatched_rows_are_classified_as_before
test_open_decisions_still_reach_main_beside_a_folded_row
test_folded_check_repeat_rows_are_claimed_beside_a_worker_row
test_fold_closes_go_to_the_host_only_when_nothing_is_left_for_main
