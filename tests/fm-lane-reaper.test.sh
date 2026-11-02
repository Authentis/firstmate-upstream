#!/usr/bin/env bash
# Behavior tests for fm-lane-reaper.sh: each joint condition gates alone,
# dry-run ends nothing, live ends only through the control seam, branch kept.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REAPER="$ROOT/bin/fm-lane-reaper.sh"
TMP_ROOT=$(fm_test_tmproot fm-lane-reaper)
NOW=2000000000

# Fresh home with a fake control (records calls), fake crew-state, fake cpu.
# shellcheck disable=SC2016
new_world() {
  W="$TMP_ROOT/$1"
  mkdir -p "$W/state" "$W/bin"
  CALLS="$W/control.calls"
  : > "$CALLS"
  printf '#!/usr/bin/env bash\necho "$*" >> %q\n' "$CALLS" > "$W/bin/control"
  printf '#!/usr/bin/env bash\ncat %q/state-$1 2>/dev/null || echo "state: done"\n' "$W" > "$W/bin/crew-state"
  printf '#!/usr/bin/env bash\ncat %q/cpu 2>/dev/null || echo 0\n' "$W" > "$W/bin/cpu"
  chmod +x "$W/bin/control" "$W/bin/crew-state" "$W/bin/cpu"
}

# set_mtime <path> <epoch>: portable across BSD and GNU.
set_mtime() {
  local stamp
  stamp=$(date -r "$2" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$2" +%Y%m%d%H%M.%S)
  touch -t "$stamp" "$1"
}

# make_lane <id>: a pushed, clean, old, idle done lane.
make_lane() {
  local id=$1 remote="$W/remote-$1.git" wt="$W/wt-$1"
  git init -q --bare "$remote"
  git clone -q "$remote" "$wt" 2>/dev/null
  (
    cd "$wt" || exit 1
    git config user.email t@t; git config user.name t
    git checkout -q -b "fm/$id"
    echo a > f; git add f; git commit -q -m init
    git push -q -u origin "fm/$id"
  )
  set_mtime "$wt/f" "$((NOW - 7200))"
  printf 'kind=ship\nworktree=%s\nbranch=fm/%s\n' "$wt" "$id" > "$W/state/$id.meta"
  printf 'done [at=%s]: ready\n' "$((NOW - 7300))" > "$W/state/$id.status"
  mkdir -p "$W/state/.lane-reaper-seen"
  printf '%s\n' "$((NOW - 3600))" > "$W/state/.lane-reaper-seen/$id.idle"
}

run_reaper() {
  FM_HOME="$W" FM_STATE_OVERRIDE="$W/state" FM_REAPER_FORCE=1 FM_REAPER_NOW=$NOW \
    FM_REAPER_CONTROL="$W/bin/control" FM_REAPER_CREW_STATE="$W/bin/crew-state" \
    FM_REAPER_CPU_CMD="$W/bin/cpu" "$REAPER" scan "$@"
}

test_all_conditions_met_dry_run_ends_nothing() {
  new_world dry; make_lane a
  out=$(run_reaper)
  assert_contains "$out" "dry-run candidate a: would-end" "dry-run candidate"
  [ ! -s "$CALLS" ] || fail "dry-run invoked control"
  assert_present "$W/state/lane-reaper.log" "log written"
  pass "dry-run logs the candidate and ends nothing"
}

test_live_ends_via_control_and_keeps_branch() {
  new_world live; make_lane a
  out=$(run_reaper --live)
  assert_contains "$out" "live candidate a: ended" "live candidate"
  assert_equals "a exit" "$(cat "$CALLS")" "control call"
  git -C "$W/wt-a" rev-parse --verify -q fm/a >/dev/null || fail "branch removed"
  [ -d "$W/wt-a" ] || fail "worktree removed"
  pass "live ends only through control exit; branch and worktree kept"
}

expect_spared() {  # <label> <condition>
  out=$(run_reaper --live)
  assert_contains "$out" "spared a: $2 unmet" "spared line"
  [ ! -s "$CALLS" ] || fail "$1: control invoked despite unmet condition"
  pass "$1 alone spares the lane"
}

test_each_condition_gates_alone() {
  new_world young; make_lane a
  printf 'done [at=%s]: ready\n' "$((NOW - 7100))" > "$W/state/a.status"
  expect_spared "done for under 2h" idle-status

  new_world working; make_lane a
  echo "state: working · source: run-step · fixing" > "$W/state-a"
  expect_spared "open fix round (current state working)" idle-status

  new_world write; make_lane a
  set_mtime "$W/wt-a/f" "$((NOW - 600))"
  expect_spared "recent file write" quiet

  new_world cpu; make_lane a
  echo 12.5 > "$W/cpu"
  expect_spared "process CPU" quiet

  new_world dirty; make_lane a
  echo x > "$W/wt-a/new"; set_mtime "$W/wt-a/new" "$((NOW - 7200))"
  expect_spared "dirty git status" clean

  new_world unpushed; make_lane a
  git -C "$W/wt-a" commit -q --allow-empty -m extra
  expect_spared "unpushed commit" pushed
}

test_paused_lane_is_candidate() {
  new_world paused; make_lane a
  printf 'paused [at=%s]: waiting\n' "$((NOW - 7300))" > "$W/state/a.status"
  echo "state: paused · source: status-log" > "$W/state-a"
  out=$(run_reaper)
  assert_contains "$out" "dry-run candidate a: would-end" "paused candidate"
  pass "a paused lane is a candidate"
}

test_cpu_needs_history_and_probe_failure_spares() {
  new_world hist; make_lane a
  rm -f "$W/state/.lane-reaper-seen/a.idle"
  expect_spared "first CPU observation (no history)" quiet
  printf '#!/usr/bin/env bash\nexit 1\n' > "$W/bin/cpu"
  new_world probe; make_lane a
  printf '#!/usr/bin/env bash\nexit 1\n' > "$W/bin/cpu"
  expect_spared "failed CPU probe" quiet
}

test_note_embedded_timestamp_and_head_branch() {
  new_world note; make_lane a
  printf 'done [at=%s]: retry [at=1]\n' "$((NOW - 100))" > "$W/state/a.status"
  expect_spared "a note-embedded stale tag cannot age the status" idle-status
  new_world wrongbranch; make_lane a
  git -C "$W/wt-a" checkout -q --detach
  expect_spared "worktree off the lane branch" clean
}

test_live_does_not_end_twice() {
  new_world twice; make_lane a
  run_reaper --live >/dev/null; run_reaper --live >/dev/null
  assert_equals "a exit" "$(cat "$CALLS")" "one exit across two live scans"
  pass "a live lane is not ended again until its status changes"
}

test_secondmate_and_remote_skipped() {
  new_world skip; make_lane a
  printf 'kind=secondmate\nworktree=%s\n' "$W/wt-a" > "$W/state/a.meta"
  out=$(run_reaper --live)
  assert_not_contains "$out" " a" "secondmate not logged"
  [ ! -s "$CALLS" ] || fail "secondmate reaped"
  pass "secondmates are skipped"
}

# Close: a fake teardown records its arguments, exits with the code in
# $W/teardown.rc (default 0), and removes the record on success as the real one does.
# shellcheck disable=SC2016
add_teardown() {
  TEARDOWNS="$W/teardown.calls"
  : > "$TEARDOWNS"
  printf '#!/usr/bin/env bash\necho "$*" >> %q\nrc=$(cat %q 2>/dev/null || echo 0)\n[ "$rc" != 0 ] || rm -f "$FM_STATE_OVERRIDE/$1.meta"\nexit "$rc"\n' \
    "$TEARDOWNS" "$W/teardown.rc" > "$W/bin/teardown"
  chmod +x "$W/bin/teardown"
}

run_close() {
  FM_TEST_SEAM=1 FM_LANE_CLOSE_TEARDOWN="$W/bin/teardown" run_reaper "$@"
}

test_close_is_off_by_default_and_dry_run_reports() {
  new_world close-off; make_lane a; add_teardown
  mkdir -p "$W/config"; : > "$W/config/lane-reaper-live"
  out=$(run_close --live)
  assert_contains "$out" "dry-run close a: would-close (pushed)" "dry-run close line"
  [ ! -s "$TEARDOWNS" ] || fail "teardown ran without the close opt-in"
  assert_present "$W/state/a.meta" "record kept"
  pass "closing is off without config/lane-close-live and dry-run names the lane"
}

test_close_pushed_clean_lane_tears_down_without_force() {
  new_world close-pushed; make_lane a; add_teardown
  mkdir -p "$W/config"; : > "$W/config/lane-close-live"
  out=$(run_close)
  assert_contains "$out" "live close a: closed" "closed line"
  assert_equals "a" "$(cat "$TEARDOWNS")" "plain teardown, no --force"
  assert_absent "$W/data/bundles/a-close.bundle" "a pushed lane needs no bundle"
  pass "config/lane-close-live closes a pushed clean done lane through plain teardown"
}

test_close_unpushed_lane_pushes_and_bundles_first() {
  local head
  new_world close-unpushed; make_lane a; add_teardown
  git -C "$W/wt-a" commit -q --allow-empty -m extra
  head=$(git -C "$W/wt-a" rev-parse HEAD)
  out=$(run_reaper)
  assert_contains "$out" "dry-run close a: would-close (push)" "dry-run names the push"
  out=$(run_close --close-live)
  assert_contains "$out" "live close a: closed" "closed line"
  assert_equals "$head" "$(git -C "$W/remote-a.git" rev-parse fm/a)" "unpushed commit reached the upstream"
  git -C "$W/wt-a" bundle list-heads "$W/data/bundles/a-close.bundle" | grep -q "^$head HEAD" \
    || fail "bundle does not hold HEAD"
  assert_equals "a" "$(cat "$TEARDOWNS")" "plain teardown, no --force"
  pass "an unpushed done lane is bundled and pushed before a plain teardown"
}

test_close_no_upstream_lane_bundles_and_teardown_decides() {
  local head
  new_world close-bundle; make_lane a; add_teardown
  git -C "$W/wt-a" branch -q --unset-upstream
  git -C "$W/wt-a" commit -q --allow-empty -m local
  head=$(git -C "$W/wt-a" rev-parse HEAD)
  echo 1 > "$W/teardown.rc"
  out=$(run_close --close-live)
  assert_contains "$out" "live close a: refused: teardown refused (rc=1)" "teardown refusal reported"
  git -C "$W/wt-a" bundle list-heads "$W/data/bundles/a-close.bundle" | grep -q "^$head HEAD" \
    || fail "bundle does not hold HEAD"
  assert_present "$W/state/a.meta" "refused lane kept"
  out=$(run_close --close-live)
  assert_not_contains "$out" "close a:" "a refusal is not retried on the same status line"
  assert_equals "a" "$(cat "$TEARDOWNS")" "one plain teardown attempt"
  pass "a lane with no upstream is bundled, and a teardown refusal is reported once and kept"
}

test_close_push_failure_refuses_and_keeps_bundle() {
  new_world close-pushfail; make_lane a; add_teardown
  git -C "$W/wt-a" commit -q --allow-empty -m extra
  git -C "$W/wt-a" remote set-url origin "$W/gone.git"
  out=$(run_close --close-live)
  assert_contains "$out" "live close a: refused: push to upstream failed; bundle kept" "push failure"
  assert_present "$W/data/bundles/a-close.bundle" "bundle kept"
  [ ! -s "$TEARDOWNS" ] || fail "teardown ran after a failed push"
  pass "a failed push refuses the close and keeps the bundle"
}

test_close_refuses_dirty_missing_and_paused() {
  new_world close-dirty; make_lane a; add_teardown
  echo x > "$W/wt-a/new"; set_mtime "$W/wt-a/new" "$((NOW - 7200))"
  out=$(run_close --close-live)
  assert_contains "$out" "spared a: clean unmet" "dirty lane reported"
  [ ! -s "$TEARDOWNS" ] || fail "dirty lane torn down"

  new_world close-missing; make_lane a; add_teardown
  mv "$W/wt-a" "$W/wt-a.moved"
  out=$(run_close --close-live)
  assert_contains "$out" "spared a: worktree unmet (missing)" "missing worktree reported"
  [ ! -s "$TEARDOWNS" ] || fail "missing-worktree lane torn down"

  new_world close-paused; make_lane a; add_teardown
  printf 'paused [at=%s]: waiting\n' "$((NOW - 7300))" > "$W/state/a.status"
  echo "state: paused · source: status-log" > "$W/state-a"
  out=$(run_close --close-live)
  assert_not_contains "$out" "close a:" "paused lane is not a close candidate"
  [ ! -s "$TEARDOWNS" ] || fail "paused lane torn down"
  pass "dirty, missing-worktree, and paused lanes are never closed"
}

test_all_conditions_met_dry_run_ends_nothing
test_live_ends_via_control_and_keeps_branch
test_close_is_off_by_default_and_dry_run_reports
test_close_pushed_clean_lane_tears_down_without_force
test_close_unpushed_lane_pushes_and_bundles_first
test_close_no_upstream_lane_bundles_and_teardown_decides
test_close_push_failure_refuses_and_keeps_bundle
test_close_refuses_dirty_missing_and_paused
test_each_condition_gates_alone
test_paused_lane_is_candidate
test_cpu_needs_history_and_probe_failure_spares
test_note_embedded_timestamp_and_head_branch
test_live_does_not_end_twice
test_secondmate_and_remote_skipped
