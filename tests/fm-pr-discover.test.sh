#!/usr/bin/env bash
# Behavioural tests for bin/fm-pr-discover.sh: the bounded scan that finds a
# ship task's PR on the forge when its worker never recorded one, so the normal
# merge poll can arm.
# gh is a fake that answers `gh pr list --head <branch>` from a per-branch JSON
# file, answers the draft and head reads bin/fm-pr-check.sh makes while
# registering, and logs every call. Registration is the real
# bin/fm-pr-check.sh, so a recorded PR really arms its merge poll.
# FM_FAKE_GH_HANG=list|view makes that call hang and FM_FAKE_GH_ERR=list makes
# it fail, to prove a stalled or broken forge cannot hold the scan.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DISCOVER="$ROOT/bin/fm-pr-discover.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-discover)

make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state" "$case_dir/fakebin" "$case_dir/forge" "$case_dir/project"
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_GH_LOG"
case "${1:-} ${2:-}" in
  "pr list")
    [ "${FM_FAKE_GH_HANG:-}" != list ] || sleep 30
    [ "${FM_FAKE_GH_ERR:-}" != list ] || { echo "gh: forge unavailable" >&2; exit 1; }
    shift 2
    while [ "$#" -gt 0 ]; do
      [ "$1" = --head ] && head=$2
      shift
    done
    f="$FM_FAKE_FORGE/$(printf '%s' "$head" | tr '/' '_').json"
    if [ -f "$f" ]; then cat "$f"; else echo '[]'; fi ;;
  "pr view")
    [ "${FM_FAKE_GH_HANG:-}" != view ] || sleep 30
    case "$*" in
      *isDraft*) echo '{"isDraft":false}' ;;
      *headRefOid*) echo 0123456789abcdef0123456789abcdef01234567 ;;
    esac ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh"
  printf '%s\n' "$case_dir"
}

# add_task <case> <id> <branch> [extra key=val...]
add_task() {
  local case_dir=$1 id=$2 branch=$3
  shift 3
  mkdir -p "$case_dir/wt-$id"
  fm_write_meta "$case_dir/state/$id.meta" \
    "worktree=$case_dir/wt-$id" "project=$case_dir/project" "kind=ship" \
    "mode=no-mistakes" "branch=$branch" "$@"
}

# forge <case> <branch> <json>
forge() {
  printf '%s\n' "$3" > "$1/forge/$(printf '%s' "$2" | tr '/' '_').json"
}

pr_json() { # <state> <number> [head] [cross]
  printf '[{"url":"https://github.com/acme/widgets/pull/%s","state":"%s","headRefName":"%s","baseRefName":"main","isCrossRepository":%s}]' \
    "$2" "$1" "${3:-fm/t}" "${4:-false}"
}

run_scan() { # <case> [env...]
  local case_dir=$1
  shift
  env FM_HOME="$case_dir" FM_STATE_OVERRIDE="$case_dir/state" \
    FM_FAKE_GH_LOG="$case_dir/gh.log" FM_FAKE_FORGE="$case_dir/forge" \
    PATH="$case_dir/fakebin:$PATH" \
    "$@" "$DISCOVER" scan
}

age_marker() { # <case>
  touch -t 200001010000 "$1/state/.pr-discover"
}

query_count() { # <case>
  [ -f "$1/gh.log" ] || { printf '0\n'; return; }
  wc -l < "$1/gh.log" | tr -d ' '
}

test_open_pr_is_recorded() {
  local c out
  c=$(make_case open)
  add_task "$c" t1 fm/t1
  forge "$c" fm/t1 "$(pr_json OPEN 41 fm/t1)"
  out=$(run_scan "$c")
  assert_contains "$out" "recorded t1 https://github.com/acme/widgets/pull/41" "an unreported open PR was not recorded"
  assert_grep "pr=https://github.com/acme/widgets/pull/41" "$c/state/t1.meta" "registration did not record pr="
  assert_present "$c/state/t1.check.sh" "registration did not arm the merge poll"
  assert_grep "--head fm/t1" "$c/gh.log" "the forge was not asked about the task's own branch"
  pass "an open PR on the task branch is found and recorded"
}

test_merged_pr_is_recorded_and_open_is_preferred() {
  local c out
  c=$(make_case merged)
  add_task "$c" t1 fm/t1
  add_task "$c" t2 fm/t2
  forge "$c" fm/t1 "$(pr_json MERGED 7 fm/t1)"
  forge "$c" fm/t2 '[{"url":"https://github.com/acme/widgets/pull/8","state":"MERGED","headRefName":"fm/t2","baseRefName":"main","isCrossRepository":false},{"url":"https://github.com/acme/widgets/pull/9","state":"OPEN","headRefName":"fm/t2","baseRefName":"main","isCrossRepository":false}]'
  out=$(run_scan "$c")
  assert_contains "$out" "recorded t1 https://github.com/acme/widgets/pull/7" "a merged PR was not recorded"
  assert_contains "$out" "recorded t2 https://github.com/acme/widgets/pull/9" "an open PR must win over an older merged one"
  pass "a merged PR is recorded, and an open one wins when both exist"
}

test_unusable_pull_requests_are_ignored() {
  local c out
  c=$(make_case ignored)
  add_task "$c" t1 fm/t1
  add_task "$c" t2 fm/t2
  add_task "$c" t3 fm/t3
  add_task "$c" t4 fm/t4 base_branch=release
  forge "$c" fm/t1 "$(pr_json CLOSED 1 fm/t1)"
  forge "$c" fm/t2 "$(pr_json OPEN 2 fm/t2 true)"
  forge "$c" fm/t3 "$(pr_json OPEN 3 other/branch)"
  forge "$c" fm/t4 "$(pr_json OPEN 4 fm/t4)"
  out=$(run_scan "$c" FM_PR_DISCOVER_MAX=10)
  [ -z "$out" ] || fail "nothing should be recorded, got: $out"
  assert_no_grep "pr=" "$c/state/t1.meta" "a closed PR must never be recorded"
  assert_absent "$c/state/t2.check.sh" "a fork PR must never arm a poll"
  assert_absent "$c/state/t3.check.sh" "a mis-headed PR must never arm a poll"
  assert_absent "$c/state/t4.check.sh" "a wrong-base PR must never arm a poll"
  pass "closed, forked, mis-headed and wrong-base PRs are ignored"
}

test_only_unrecorded_ship_tasks_are_queried() {
  local c
  c=$(make_case skipped)
  add_task "$c" has-pr fm/a "pr=https://github.com/acme/widgets/pull/5"
  add_task "$c" a-scout fm/b kind=scout
  add_task "$c" a-mate fm/c kind=secondmate
  add_task "$c" a-local fm/d mode=local-only
  fm_write_meta "$c/state/no-branch.meta" "kind=ship" "mode=no-mistakes" "project=$c/project"
  run_scan "$c" >/dev/null
  [ "$(query_count "$c")" = 0 ] || fail "tasks that cannot owe a PR must not cost a forge query"
  pass "recorded, scout, secondmate, local-only and branchless tasks cost no query"
}

test_scan_is_bounded_and_resumes_after_its_cursor() {
  local c i
  c=$(make_case bounded)
  for i in 1 2 3 4 5; do add_task "$c" "t$i" "fm/t$i"; done
  run_scan "$c" FM_PR_DISCOVER_MAX=2 >/dev/null
  [ "$(query_count "$c")" = 2 ] || fail "a scan must stop at its query budget ($(query_count "$c") queries)"
  age_marker "$c"
  run_scan "$c" FM_PR_DISCOVER_MAX=2 >/dev/null
  assert_grep "--head fm/t3" "$c/gh.log" "the next scan did not resume after the last candidate visited"
  assert_grep "--head fm/t4" "$c/gh.log" "the next scan did not resume after the last candidate visited"
  [ "$(query_count "$c")" = 4 ] || fail "second scan must also stop at its budget"
  pass "a scan stops at its query budget and the next scan resumes after its cursor"
}

test_scan_is_rate_limited() {
  local c
  c=$(make_case gated)
  add_task "$c" t1 fm/t1
  run_scan "$c" >/dev/null
  run_scan "$c" >/dev/null
  [ "$(query_count "$c")" = 1 ] || fail "a second scan inside the interval must not query ($(query_count "$c") queries)"
  age_marker "$c"
  run_scan "$c" >/dev/null
  [ "$(query_count "$c")" = 2 ] || fail "a scan after the interval must query again"
  pass "scans run at most once per interval"
}

test_registration_makes_bounded_reads_and_never_arms_a_second_poll() {
  local c lists views
  c=$(make_case once)
  add_task "$c" t1 fm/t1
  forge "$c" fm/t1 "$(pr_json OPEN 41 fm/t1)"
  run_scan "$c" >/dev/null
  lists=$(grep -c '^pr list' "$c/gh.log")
  views=$(grep -c '^pr view' "$c/gh.log")
  [ "$lists" = 1 ] || fail "discovery must ask the forge to list once per candidate ($lists)"
  [ "$views" = 2 ] || fail "registration should make exactly its two reads ($views)"
  cp "$c/state/t1.check.sh" "$c/first-poll.sh"
  age_marker "$c"
  run_scan "$c" >/dev/null
  [ "$(wc -l < "$c/gh.log" | tr -d ' ')" = 3 ] || fail "a recorded task must cost no further forge call"
  cmp -s "$c/first-poll.sh" "$c/state/t1.check.sh" || fail "the merge poll must not be re-armed"
  [ "$(ls "$c"/state/t1.check.sh* | wc -l | tr -d ' ')" = 1 ] || fail "there must be exactly one merge poll"
  pass "one list and two registration reads arm one poll, and a later scan adds none"
}

test_hanging_or_failing_forge_calls_cannot_hold_the_scan() {
  local c start elapsed
  c=$(make_case hang-list)
  add_task "$c" t1 fm/t1
  forge "$c" fm/t1 "$(pr_json OPEN 41 fm/t1)"
  start=$(date +%s)
  run_scan "$c" FM_FAKE_GH_HANG=list FM_PR_DISCOVER_QUERY_SECS=1 >/dev/null
  elapsed=$(( $(date +%s) - start ))
  [ "$elapsed" -lt 10 ] || fail "a hanging list call held the scan for ${elapsed}s"
  assert_no_grep "pr=" "$c/state/t1.meta" "a timed-out list must record nothing"

  c=$(make_case hang-view)
  add_task "$c" t1 fm/t1
  forge "$c" fm/t1 "$(pr_json OPEN 41 fm/t1)"
  start=$(date +%s)
  run_scan "$c" FM_FAKE_GH_HANG=view FM_PR_DISCOVER_CHECK_SECS=1 >/dev/null
  elapsed=$(( $(date +%s) - start ))
  [ "$elapsed" -lt 10 ] || fail "a hanging registration read held the scan for ${elapsed}s"
  assert_no_grep "pr=https" "$c/state/t1.meta" "a timed-out registration must not leave a recorded PR"
  assert_absent "$c/state/t1.check.sh" "a timed-out registration must not arm a poll"

  c=$(make_case forge-error)
  add_task "$c" t1 fm/t1
  run_scan "$c" FM_FAKE_GH_ERR=list >/dev/null || fail "a forge error must not fail the scan"
  assert_no_grep "pr=" "$c/state/t1.meta" "a forge error must record nothing"
  pass "a hanging list, a hanging registration read, and a forge error all leave the scan bounded and harmless"
}

test_whole_scan_is_held_to_its_budget() {
  local c i start elapsed
  c=$(make_case budget)
  for i in 1 2 3 4; do add_task "$c" "t$i" "fm/t$i"; done
  start=$(date +%s)
  run_scan "$c" FM_FAKE_GH_HANG=list FM_PR_DISCOVER_QUERY_SECS=3 FM_PR_DISCOVER_BUDGET_SECS=5 >/dev/null
  elapsed=$(( $(date +%s) - start ))
  [ "$elapsed" -lt 9 ] || fail "the scan overran its 5s budget (${elapsed}s)"
  [ "$(grep -c '^pr list' "$c/gh.log")" -le 2 ] || fail "the scan kept starting queries after its budget was spent"
  pass "a scan of stalled queries stops at its whole-scan budget"
}

test_open_pr_is_recorded
test_merged_pr_is_recorded_and_open_is_preferred
test_unusable_pull_requests_are_ignored
test_only_unrecorded_ship_tasks_are_queried
test_scan_is_bounded_and_resumes_after_its_cursor
test_scan_is_rate_limited
test_registration_makes_bounded_reads_and_never_arms_a_second_poll
test_hanging_or_failing_forge_calls_cannot_hold_the_scan
test_whole_scan_is_held_to_its_budget

echo "# all fm-pr-discover tests passed"
