#!/usr/bin/env bash
# Behavior tests for fm-lane-reaper.sh: each joint condition gates alone,
# dry-run ends nothing, live ends only through the control seam, branch kept.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REAPER="$ROOT/bin/fm-lane-reaper.sh"
TMP_ROOT=$(fm_test_tmproot fm-lane-reaper)
NOW=2000000000

# Every tmux call, including the close path's window check, goes to a private
# server so no case can read or close a window on the host's own server.
REAL_TMUX=$(command -v tmux 2>/dev/null || true)
TMUX_SOCKET="fm-lane-reaper-$$"
mkdir -p "$TMP_ROOT/tmuxbin"
printf '#!/usr/bin/env bash\nexec %q -f /dev/null -L %q "$@"\n' "${REAL_TMUX:-false}" "$TMUX_SOCKET" \
  > "$TMP_ROOT/tmuxbin/tmux"
chmod +x "$TMP_ROOT/tmuxbin/tmux"
PATH="$TMP_ROOT/tmuxbin:$PATH"
unset TMUX

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
  mkdir -p "$W/config"
  : > "$W/config/lane-close-live"
}

run_close() {
  FM_TEST_SEAM=1 FM_LANE_CLOSE_TEARDOWN="$W/bin/teardown" run_reaper "$@"
}

assert_saved_head() {
  local bundle
  for bundle in "$W/data/bundles/"*.bundle; do
    [ -f "$bundle" ] || continue
    git clone -q "$bundle" "$W/restored-$RANDOM" 2>/dev/null || fail "bundle not independently restorable"
    git bundle list-heads "$bundle" | grep -qx "$1 HEAD" && return 0
  done
  fail "no independently restorable bundle of HEAD"
}

test_close_mirror_only_commits_are_bundled() {
  new_world close-mirror; make_lane a; add_teardown
  git -C "$W/wt-a" commit -q --allow-empty -m mirror-only
  git -C "$W/wt-a" remote rename origin no-mistakes
  git -C "$W/wt-a" push -q no-mistakes fm/a
  out=$(run_close)
  assert_contains "$out" "live close a: closed" "mirror lane closes"
  assert_saved_head "$(git -C "$W/wt-a" rev-parse HEAD)"
  pass "validation mirror alone requires an independently restorable bundle"
}

test_close_is_off_by_default_and_dry_run_reports() {
  new_world close-off; make_lane a; add_teardown
  rm "$W/config/lane-close-live"
  : > "$W/config/lane-reaper-live"
  out=$(FM_REAPER_CLOSE_LIVE=1 run_close --live)
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
  [ ! -d "$W/data/bundles" ] || fail "a pushed lane needs no bundle"
  pass "config/lane-close-live closes a pushed clean done lane through plain teardown"
}

window_present() {  # <window-name>
  tmux list-windows -t =firstmate -F '#{window_name}' 2>/dev/null | grep -qxF -- "$1"
}

test_close_closes_a_dead_lane_window_and_keeps_a_live_one() {
  [ -n "$REAL_TMUX" ] || { pass "skip: tmux not found"; return; }
  new_world close-window; make_lane a; make_lane b; make_lane c; make_lane d; add_teardown
  printf 'window=firstmate:fm-a\n' >> "$W/state/a.meta"
  printf 'window=firstmate:fm-b\n' >> "$W/state/b.meta"
  printf 'window=firstmate:other\n' >> "$W/state/d.meta"
  tmux new-session -d -s firstmate -n supervisor "sleep 300" || fail "private tmux session"
  tmux new-window -d -t firstmate: -n fm-a sh || fail "dead window"
  tmux new-window -d -t firstmate: -n fm-c sh || fail "unowned window"
  tmux new-window -d -t firstmate: -n fm-d sh || fail "mismatched endpoint window"
  tmux new-window -d -t firstmate: -n fm-b "sh -c 'sleep 300; exit 0'" || fail "busy window"
  for _ in $(seq 1 50); do
    [ "$(tmux display-message -p -t =firstmate:=fm-a '#{pane_current_command}')" = sh ] && break
    sleep 0.1
  done
  out=$(run_close)
  assert_contains "$out" "live close a: closed" "dead-window lane closed"
  assert_contains "$out" "live close b: closed; window firstmate:fm-b still runs a process, so it was left open" "busy window reported"
  window_present fm-a && fail "the idle-shell lane window was left open"
  window_present fm-b || fail "a window with a child process was closed"
  window_present supervisor || fail "an unrelated window was closed"
  assert_contains "$out" "live close c: closed" "windowless lane closed"
  assert_contains "$out" "live close d: closed" "mismatched-endpoint lane closed"
  assert_absent "$W/state/c.meta" "windowless lane record removed"
  window_present fm-c || fail "windowless record closed an unowned same-name window"
  window_present fm-d || fail "mismatched record closed an unowned same-name window"
  [ -d "$W/wt-a" ] || fail "closing the window touched the worktree"
  git -C "$W/wt-a" rev-parse --verify -q fm/a >/dev/null || fail "closing the window touched the branch"
  tmux kill-server >/dev/null 2>&1 || true
  pass "a closed lane's idle-shell window is closed, a window with a child process is kept and reported"
}

test_close_unpushed_lane_pushes_and_bundles_first() {
  local head
  new_world close-unpushed; make_lane a; add_teardown
  git -C "$W/wt-a" commit -q --allow-empty -m extra
  head=$(git -C "$W/wt-a" rev-parse HEAD)
  rm "$W/config/lane-close-live"
  out=$(run_reaper)
  assert_contains "$out" "dry-run close a: would-close (push)" "dry-run names the push"
  : > "$W/config/lane-close-live"
  out=$(run_close)
  assert_contains "$out" "live close a: closed" "closed line"
  assert_equals "$head" "$(git -C "$W/remote-a.git" rev-parse fm/a)" "unpushed commit reached the upstream"
  assert_saved_head "$head"
  assert_equals "a" "$(cat "$TEARDOWNS")" "plain teardown, no --force"
  pass "an unpushed done lane is bundled and pushed before a plain teardown"
}

assert_bundle_count() {
  local expected=$1
  set -- "$W/data/bundles/"*.bundle
  assert_equals "$expected" "$#" "preservation archive count"
}

test_close_reuses_only_verified_same_head_backups() {
  local first bundle
  new_world close-reuse; make_lane a; add_teardown
  git -C "$W/wt-a" branch -q --unset-upstream
  git -C "$W/wt-a" commit -q --allow-empty -m local
  echo 1 > "$W/teardown.rc"
  run_close >/dev/null
  assert_bundle_count 1
  run_close >/dev/null
  run_close >/dev/null
  assert_bundle_count 1
  assert_equals $'a\na\na' "$(cat "$TEARDOWNS")" "refused closes still retry"
  assert_saved_head "$(git -C "$W/wt-a" rev-parse HEAD)"
  git -C "$W/wt-a" commit -q --allow-empty -m newer
  run_close >/dev/null
  assert_bundle_count 2
  assert_saved_head "$(git -C "$W/wt-a" rev-parse HEAD)"

  new_world close-corrupt; make_lane a; add_teardown
  git -C "$W/wt-a" branch -q --unset-upstream
  git -C "$W/wt-a" commit -q --allow-empty -m local
  echo 1 > "$W/teardown.rc"
  run_close >/dev/null
  for first in "$W/data/bundles/"*.bundle; do break; done
  awk '{ print } /^$/ { exit }' "$first" > "$W/truncated.bundle"
  printf 'PACK' >> "$W/truncated.bundle"
  mv "$W/truncated.bundle" "$first"
  git -C "$W/wt-a" bundle verify -q "$first" >/dev/null 2>&1 || fail "truncated pack must retain a valid bundle header"
  git bundle list-heads "$first" | grep -qx "$(git -C "$W/wt-a" rev-parse HEAD) HEAD" \
    || fail "truncated pack must still advertise the current head"
  if git clone -q "$first" "$W/broken-restore" >/dev/null 2>&1; then
    fail "truncated pack unexpectedly restored"
  fi
  run_close >/dev/null
  assert_bundle_count 2
  for bundle in "$W/data/bundles/"*.bundle; do
    [ "$bundle" != "$first" ] || continue
    git clone -q "$bundle" "$W/restored" 2>/dev/null || fail "replacement bundle not restorable"
  done
  assert_equals "$(git -C "$W/wt-a" rev-parse HEAD)" "$(git -C "$W/restored" rev-parse HEAD)" "corrupt backup replaced with current head"
  run_close >/dev/null
  assert_bundle_count 2
  pass "retries reuse verified same-head bundles, not stale or corrupt backups"
}

test_close_no_upstream_lane_bundles_and_teardown_decides() {
  local head
  new_world close-bundle; make_lane a; add_teardown
  git -C "$W/wt-a" branch -q --unset-upstream
  git -C "$W/wt-a" commit -q --allow-empty -m local
  head=$(git -C "$W/wt-a" rev-parse HEAD)
  echo 1 > "$W/teardown.rc"
  out=$(run_close)
  assert_contains "$out" "live close a: refused: teardown refused (rc=1)" "teardown refusal reported"
  assert_saved_head "$head"
  assert_present "$W/state/a.meta" "refused lane kept"
  echo 0 > "$W/teardown.rc"
  out=$(run_close)
  assert_contains "$out" "live close a: closed" "same-status refusal retried"
  assert_equals $'a\na' "$(cat "$TEARDOWNS")" "second plain teardown attempt"
  pass "a lane with no upstream is bundled and a refused teardown retries"
}

test_close_push_failure_refuses_and_keeps_bundle() {
  new_world close-pushfail; make_lane a; add_teardown
  git -C "$W/wt-a" commit -q --allow-empty -m extra
  git -C "$W/wt-a" remote set-url origin "$W/gone.git"
  out=$(run_close)
  assert_contains "$out" "live close a: refused: push to upstream failed; bundle kept" "push failure"
  assert_saved_head "$(git -C "$W/wt-a" rev-parse HEAD)"
  [ ! -s "$TEARDOWNS" ] || fail "teardown ran after a failed push"
  out=$(run_close)
  assert_contains "$out" "refused: push to upstream failed" "persistent push failure still retries"
  assert_bundle_count 1
  git -C "$W/wt-a" remote set-url origin "$W/remote-a.git"
  out=$(run_close)
  assert_contains "$out" "live close a: closed" "push retried after recovery"
  assert_equals "a" "$(cat "$TEARDOWNS")" "teardown after push recovery"
  pass "a failed push keeps the bundle and retries after recovery"
}

test_close_refuses_dirty_missing_and_paused() {
  new_world close-dirty; make_lane a; add_teardown
  echo x > "$W/wt-a/new"; set_mtime "$W/wt-a/new" "$((NOW - 7200))"
  out=$(run_close)
  assert_contains "$out" "spared a: clean unmet" "dirty lane reported"
  [ ! -s "$TEARDOWNS" ] || fail "dirty lane torn down"

  new_world close-missing; make_lane a; add_teardown
  mv "$W/wt-a" "$W/wt-a.moved"
  out=$(run_close)
  assert_contains "$out" "spared a: worktree unmet (missing)" "missing worktree reported"
  [ ! -s "$TEARDOWNS" ] || fail "missing-worktree lane torn down"

  new_world close-paused; make_lane a; add_teardown
  printf 'paused [at=%s]: waiting\n' "$((NOW - 7300))" > "$W/state/a.status"
  echo "state: paused · source: status-log" > "$W/state-a"
  out=$(run_close)
  assert_not_contains "$out" "close a:" "paused lane is not a close candidate"
  [ ! -s "$TEARDOWNS" ] || fail "paused lane torn down"
  pass "dirty, missing-worktree, and paused lanes are never closed"
}

test_all_conditions_met_dry_run_ends_nothing
test_live_ends_via_control_and_keeps_branch
test_close_is_off_by_default_and_dry_run_reports
test_close_pushed_clean_lane_tears_down_without_force
test_close_mirror_only_commits_are_bundled
test_close_closes_a_dead_lane_window_and_keeps_a_live_one
test_close_unpushed_lane_pushes_and_bundles_first
test_close_no_upstream_lane_bundles_and_teardown_decides
test_close_reuses_only_verified_same_head_backups
test_close_push_failure_refuses_and_keeps_bundle
test_close_refuses_dirty_missing_and_paused
test_each_condition_gates_alone
test_paused_lane_is_candidate
test_cpu_needs_history_and_probe_failure_spares
test_note_embedded_timestamp_and_head_branch
test_live_does_not_end_twice
test_secondmate_and_remote_skipped
