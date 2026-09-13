#!/usr/bin/env bash
# tests/fm-nm-findings-lib.test.sh - behavior tests for the no-mistakes
# finding-retention ledger owned by bin/fm-nm-findings-lib.sh.
#
# Reproduces the reported defect through the ledger's own documented event
# shapes (bin/fm-nm-findings-lib.sh's header is the single owner of that
# format): a registered `axi respond --action fix --findings <ids>` round
# that selects only some of a gate's findings leaves the rest unselected, and
# the tool's own registered interface does not re-surface them on a later
# round (real incident: run 01M1TB9ZZQGN0JQ1RYV3WERD4S review round3, evidence
# data/dos-cited-read-sol8w-implementation/deferred-findings-verbatim-ledger-20260906.json
# in the primary FM_HOME, outside this repo). These tests drive the ledger
# with fixtures shaped exactly like that registered interface's finding
# objects (id, severity, file, description) and its respond disposition
# (fixed/skipped-closed/deferred) to prove retention, explicit
# closure/defer, negative controls, and backward compatibility - without
# requiring a live, token-spending pipeline round.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/bin/fm-nm-findings-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-nm-findings-lib)

command -v jq >/dev/null 2>&1 || fail "fm-nm-findings-lib tests require jq"

new_case() {  # <name> -> echoes <data-dir>, with <data-dir>/<name> as the task dir
  local name=$1 dir
  dir=$(mktemp -d "$TMP_ROOT/case-XXXXXX")
  mkdir -p "$dir/data/$name"
  printf '%s' "$dir/data"
}

ledger_path() {  # <data-dir> <task-id>
  printf '%s/%s/nm-findings-ledger.jsonl' "$1" "$2"
}

append_line() {  # <ledger-path> <json-line>
  printf '%s\n' "$2" >> "$1"
}

test_unselected_findings_are_reproduced_then_retained() {
  local data id ledger folded open_ids report

  id=unselected-repro
  data=$(new_case "$id")
  ledger=$(ledger_path "$data" "$id")

  # Round 1: a review gate presents three findings; the registered respond
  # call selects only one to fix (finding-A), exactly reproducing the
  # documented bug shape - finding-B and finding-C are unselected.
  append_line "$ledger" '{"round":1,"step":"review","finding":{"id":"finding-A","severity":"warning","file":"x.py","description":"desc A"}}'
  append_line "$ledger" '{"round":1,"step":"review","finding":{"id":"finding-B","severity":"info","file":"y.py","description":"desc B"}}'
  append_line "$ledger" '{"round":1,"step":"review","finding":{"id":"finding-C","severity":"warning","file":"z.py","description":"desc C"}}'
  append_line "$ledger" '{"round":1,"step":"review","finding_id":"finding-A","disposition":"fixed"}'

  folded=$("$LIB" fold "$data" "$id")
  assert_equals 3 "$(printf '%s' "$folded" | jq 'length')" \
    "round1: all three findings must be retained, not just the selected one"
  assert_equals open "$(printf '%s' "$folded" | jq -r '.[] | select(.id=="finding-B") | .disposition')" \
    "round1: unselected finding-B must remain open, never dropped"
  assert_equals open "$(printf '%s' "$folded" | jq -r '.[] | select(.id=="finding-C") | .disposition')" \
    "round1: unselected finding-C must remain open, never dropped"
  assert_equals "desc B" "$(printf '%s' "$folded" | jq -r '.[] | select(.id=="finding-B") | .finding.description')" \
    "round1: retained finding must keep its original verbatim text"

  open_ids=$("$LIB" open "$data" "$id" | jq -r '.[].id' | sort | tr '\n' ' ')
  assert_equals "finding-B finding-C " "$open_ids" \
    "round1: the open list must name exactly the two unselected findings"

  report=$("$LIB" report "$data" "$id")
  assert_contains "$report" "finding-A (fixed)" "round1 report must show finding-A closed"
  assert_contains "$report" "  - finding-B" "round1 report must list finding-B as open"
  assert_contains "$report" "  - finding-C" "round1 report must list finding-C as open"

  "$LIB" all-addressed "$data" "$id" >/dev/null 2>&1 \
    && fail "round1: all-addressed must refuse while findings remain open"
  pass "fm-nm-findings-lib: reproduces and retains unselected findings across a round"
}

test_retention_across_rounds_with_new_and_deferred_findings() {
  local data id ledger folded report

  id=multi-round
  data=$(new_case "$id")
  ledger=$(ledger_path "$data" "$id")

  append_line "$ledger" '{"round":1,"step":"review","finding":{"id":"finding-A","severity":"warning","file":"x.py","description":"desc A"}}'
  append_line "$ledger" '{"round":1,"step":"review","finding":{"id":"finding-B","severity":"info","file":"y.py","description":"desc B"}}'
  append_line "$ledger" '{"round":1,"step":"review","finding":{"id":"finding-C","severity":"warning","file":"z.py","description":"desc C"}}'
  append_line "$ledger" '{"round":1,"step":"review","finding_id":"finding-A","disposition":"fixed"}'

  # Round 2: the pipeline's own gate no longer re-shows finding-B or
  # finding-C (the documented behavior), but the ledger keeps them from
  # round1 by construction. A new finding-D appears and is fixed, and
  # finding-C is explicitly deferred to an external owner/id.
  append_line "$ledger" '{"round":2,"step":"review","finding":{"id":"finding-D","severity":"info","file":"w.py","description":"desc D"}}'
  append_line "$ledger" '{"round":2,"step":"review","finding_id":"finding-D","disposition":"fixed"}'
  append_line "$ledger" '{"round":2,"step":"review","finding_id":"finding-C","disposition":"deferred","deferred_owner":"decision-os-tracker","deferred_id":"dos-9912"}'

  folded=$("$LIB" fold "$data" "$id")
  assert_equals 4 "$(printf '%s' "$folded" | jq 'length')" \
    "round2: prior findings must survive alongside the new one"
  assert_equals deferred "$(printf '%s' "$folded" | jq -r '.[] | select(.id=="finding-C") | .disposition')" \
    "round2: finding-C must show its explicit defer disposition"
  assert_equals "decision-os-tracker" "$(printf '%s' "$folded" | jq -r '.[] | select(.id=="finding-C") | .deferred_owner')" \
    "round2: deferred finding must retain its external owner"
  assert_equals "dos-9912" "$(printf '%s' "$folded" | jq -r '.[] | select(.id=="finding-C") | .deferred_id')" \
    "round2: deferred finding must retain its external id"
  assert_equals 2 "$(printf '%s' "$folded" | jq '.[] | select(.id=="finding-D") | .first_seen.round')" \
    "round2: a finding first seen in round2 must record round2 as its first_seen"
  assert_equals open "$(printf '%s' "$folded" | jq -r '.[] | select(.id=="finding-B") | .disposition')" \
    "round2: finding-B must still be open (never resurfaced, never lost)"

  report=$("$LIB" report "$data" "$id")
  assert_contains "$report" "finding-C -> decision-os-tracker/dos-9912" \
    "round2 report must name the deferred owner/id, not just say deferred"
  assert_contains "$report" "Total: 2 closed, 1 deferred, 1 open." \
    "round2 report must give an accurate closed/deferred/open rollup"

  "$LIB" all-addressed "$data" "$id" >/dev/null 2>&1 \
    && fail "round2: all-addressed must still refuse while finding-B is open"

  # Round 3: the last open finding is explicitly closed as intentionally
  # not-a-fix (skipped-closed), and the completion gate finally opens.
  append_line "$ledger" '{"round":3,"step":"review","finding_id":"finding-B","disposition":"skipped-closed"}'
  "$LIB" all-addressed "$data" "$id" >/dev/null 2>&1 \
    || fail "round3: all-addressed must pass once every finding is closed or deferred"
  pass "fm-nm-findings-lib: retains findings across rounds and reflects explicit close/defer"
}

test_deferred_without_owner_and_id_stays_open() {
  local data id ledger disposition

  id=defer-negative-control
  data=$(new_case "$id")
  ledger=$(ledger_path "$data" "$id")

  append_line "$ledger" '{"round":1,"step":"review","finding":{"id":"finding-X","severity":"warning","file":"a.py","description":"desc X"}}'
  # Missing deferred_id: an incomplete defer must never count as a real defer.
  append_line "$ledger" '{"round":1,"step":"review","finding_id":"finding-X","disposition":"deferred","deferred_owner":"someone"}'

  disposition=$("$LIB" fold "$data" "$id" | jq -r '.[] | select(.id=="finding-X") | .disposition')
  assert_equals open "$disposition" \
    "a deferred disposition missing deferred_id must not be trusted; the finding stays open"

  "$LIB" all-addressed "$data" "$id" >/dev/null 2>&1 \
    && fail "an incompletely deferred finding must still block all-addressed"
  pass "fm-nm-findings-lib: rejects an incomplete defer as a negative control"
}

test_fixed_with_deferred_fields_is_rejected() {
  local data id ledger disposition

  id=fixed-with-defer-fields
  data=$(new_case "$id")
  ledger=$(ledger_path "$data" "$id")

  append_line "$ledger" '{"round":1,"step":"review","finding":{"id":"finding-Y","severity":"info","file":"b.py","description":"desc Y"}}'
  # A non-deferred disposition must not carry deferred_owner/deferred_id.
  append_line "$ledger" '{"round":1,"step":"review","finding_id":"finding-Y","disposition":"fixed","deferred_owner":"someone","deferred_id":"ext-1"}'

  disposition=$("$LIB" fold "$data" "$id" | jq -r '.[] | select(.id=="finding-Y") | .disposition')
  assert_equals open "$disposition" \
    "a fixed disposition carrying stray deferred fields is malformed and must not be trusted"
  pass "fm-nm-findings-lib: rejects a fixed disposition polluted with defer fields"
}

test_disposition_for_unseen_finding_is_not_fabricated() {
  local data id ledger folded

  id=ghost-disposition
  data=$(new_case "$id")
  ledger=$(ledger_path "$data" "$id")

  # No seen event at all for this id: a disposition alone must never
  # fabricate a closure for a finding nobody ever recorded seeing.
  append_line "$ledger" '{"round":1,"step":"review","finding_id":"ghost-finding","disposition":"fixed"}'

  folded=$("$LIB" fold "$data" "$id")
  assert_equals 0 "$(printf '%s' "$folded" | jq 'length')" \
    "a disposition with no matching seen event must not appear in the fold at all"
  "$LIB" all-addressed "$data" "$id" >/dev/null 2>&1 \
    || fail "an empty fold (no real findings) must trivially pass all-addressed"
  pass "fm-nm-findings-lib: never fabricates a closure for an unseen finding id"
}

test_backward_compatible_with_absent_or_empty_ledger() {
  local data id report

  id=absent-ledger
  data=$(new_case "$id")
  # No ledger file is ever created for this task.

  assert_equals '[]' "$("$LIB" fold "$data" "$id")" \
    "an absent ledger must fold to an empty array, not an error"
  report=$("$LIB" report "$data" "$id")
  assert_equals "No no-mistakes findings recorded for this task." "$report" \
    "an absent ledger must report cleanly rather than crash"
  "$LIB" all-addressed "$data" "$id" >/dev/null 2>&1 \
    || fail "an absent ledger must vacuously pass all-addressed (nothing to omit)"

  id2=empty-ledger
  mkdir -p "$data/$id2"
  : > "$(ledger_path "$data" "$id2")"
  assert_equals '[]' "$("$LIB" fold "$data" "$id2")" \
    "an empty ledger file must also fold to an empty array"
  pass "fm-nm-findings-lib: backward compatible with a task that has no findings recorded"
}

test_malformed_lines_do_not_crash_the_fold() {
  local data id ledger folded

  id=malformed-lines
  data=$(new_case "$id")
  ledger=$(ledger_path "$data" "$id")

  printf 'not json at all\n' >> "$ledger"
  append_line "$ledger" '{"round":1,"step":"review","finding":{"id":"finding-Z","severity":"info","file":"c.py","description":"desc Z"}}'
  printf '{"round":1,"unterminated\n' >> "$ledger"

  folded=$("$LIB" fold "$data" "$id") || fail "a malformed line must not abort the whole fold"
  assert_equals 1 "$(printf '%s' "$folded" | jq 'length')" \
    "the one well-formed finding must still be retained despite surrounding malformed lines"
  assert_equals open "$(printf '%s' "$folded" | jq -r '.[0].disposition')" \
    "the well-formed finding must still fold to open"
  pass "fm-nm-findings-lib: tolerates malformed ledger lines without losing valid ones"
}

test_unselected_findings_are_reproduced_then_retained
test_retention_across_rounds_with_new_and_deferred_findings
test_deferred_without_owner_and_id_stays_open
test_fixed_with_deferred_fields_is_rejected
test_disposition_for_unseen_finding_is_not_fabricated
test_backward_compatible_with_absent_or_empty_ledger
test_malformed_lines_do_not_crash_the_fold
