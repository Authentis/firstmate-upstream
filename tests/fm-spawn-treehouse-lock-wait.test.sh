#!/usr/bin/env bash
# Regression tests for fm-spawn's bounded wait on the shared Treehouse project lock.
#
# A teardown or return holds that lock only briefly, so a fresh Treehouse-backed
# spawn must wait a bounded time for a live holder instead of refusing on the
# first contention, keep the exact refusal once the bound expires, and still
# reclaim a dead holder's lock at once.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-treehouse-lock-wait)
REFUSAL='another Treehouse slot allocation or return is in progress'

make_case() {  # <name> <id>
  local name=$1 id=$2 case_dir home project pool fakebin initial
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  pool="$case_dir/pool"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")

  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_test_spawn_brief "$home" "$id"
  touch "$home/state/.last-watcher-beat"

  git init --quiet -b main "$project"
  printf 'base\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  initial=$(git -C "$project" rev-parse HEAD)
  git -C "$project" worktree add --quiet --detach "$pool" "$initial"

  printf '%s\n' "$case_dir|$home|$project|$pool|$fakebin"
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJECT_DIR POOL_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

project_lock() {
  FM_HOME="$HOME_DIR" bash -c '. "$1"; fm_treehouse_project_lock_path "$2"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$PROJECT_DIR"
}

# Hold the lock from a separate live process for <seconds>, or with `die` leave
# the record behind owned by a killed process. Returns once the lock exists.
hold_lock() {  # <lock> <seconds|die>
  FM_HOME="$HOME_DIR" bash -c '
    . "$1"
    fm_lock_try_acquire "$2" || exit 1
    if [ "$3" = die ]; then kill -9 $$; fi
    sleep "$3"
    fm_lock_release "$2"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$1" "$2" &
  HOLDER_PID=$!
  local n=0
  until [ -e "$1" ] || [ -L "$1" ]; do
    n=$((n + 1))
    [ "$n" -lt 100 ] || fail "the lock holder never took the project lock"
    sleep 0.1
  done
}

run_spawn() {
  local id=$1
  shift
  FM_SPAWN_TREEHOUSE_LOCK_POLL_SECS=0.2 \
    fm_test_run_spawn "$HOME_DIR" "$POOL_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJECT_DIR" "$@"
}

test_spawn_waits_for_a_live_holder_then_starts() {
  local rec id lock out status start elapsed
  id='lock-wait-live-r1'
  rec=$(make_case live "$id")
  read_case_record "$rec"
  lock=$(project_lock)
  hold_lock "$lock" 3
  start=$SECONDS
  out=$(FM_SPAWN_TREEHOUSE_LOCK_WAIT_SECS=30 run_spawn "$id" --scout)
  status=$?
  elapsed=$((SECONDS - start))
  wait "$HOLDER_PID" 2>/dev/null || true
  expect_code 0 "$status" "spawn should wait out a briefly held lock and start"$'\n'"$out"
  assert_contains "$out" "spawned $id" "the waiting spawn did not report success"
  assert_not_contains "$out" "$REFUSAL" "the waiting spawn refused instead of waiting"
  [ "$elapsed" -ge 2 ] || fail "spawn did not wait for the live holder (elapsed ${elapsed}s)"
  pass "a fresh spawn waits for a live holder of the project lock, then starts"
}

test_bound_expiry_keeps_the_refusal() {
  local rec id lock out status start elapsed
  id='lock-wait-expiry-r1'
  rec=$(make_case expiry "$id")
  read_case_record "$rec"
  lock=$(project_lock)
  hold_lock "$lock" 20
  start=$SECONDS
  out=$(FM_SPAWN_TREEHOUSE_LOCK_WAIT_SECS=2 run_spawn "$id" --scout)
  status=$?
  elapsed=$((SECONDS - start))
  kill "$HOLDER_PID" 2>/dev/null || true
  wait "$HOLDER_PID" 2>/dev/null || true
  [ "$status" -ne 0 ] || fail "spawn succeeded while a live holder kept the lock"
  assert_contains "$out" "error: $REFUSAL for $PROJECT_DIR; refusing to race it" \
    "the bound-expiry refusal text changed"
  [ "$elapsed" -ge 2 ] || fail "spawn refused before the bound elapsed (${elapsed}s)"
  [ "$elapsed" -lt 15 ] || fail "spawn waited far past its bound (${elapsed}s)"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  pass "an expired bound keeps the exact refusal text and a non-zero status"
}

test_dead_holder_is_reclaimed_without_waiting() {
  local rec id lock out status start elapsed
  id='lock-wait-dead-r1'
  rec=$(make_case dead "$id")
  read_case_record "$rec"
  lock=$(project_lock)
  hold_lock "$lock" die
  wait "$HOLDER_PID" 2>/dev/null || true
  start=$SECONDS
  out=$(FM_SPAWN_TREEHOUSE_LOCK_WAIT_SECS=60 run_spawn "$id" --scout)
  status=$?
  elapsed=$((SECONDS - start))
  expect_code 0 "$status" "spawn should reclaim a dead holder's lock"$'\n'"$out"
  assert_contains "$out" "spawned $id" "the spawn did not start after reclaiming the lock"
  [ "$elapsed" -lt 30 ] || fail "spawn waited on a dead holder (${elapsed}s)"
  pass "a dead holder's project lock is reclaimed without waiting out the bound"
}

test_other_project_spawn_is_not_refused_during_the_wait() {
  local rec id_a id_b lock project_q pool_q fakebin_q out_b status_b status_a spawn_a
  id_a='lock-wait-busy-r1'
  id_b='lock-wait-other-r1'
  rec=$(make_case other "$id_a")
  read_case_record "$rec"
  fm_test_spawn_brief "$HOME_DIR" "$id_b"
  project_q="$CASE_DIR/project-q"
  pool_q="$CASE_DIR/pool-q"
  fakebin_q=$(make_spawn_fakebin "$CASE_DIR/fake-q")
  git init --quiet -b main "$project_q"
  printf 'other\n' > "$project_q/README.md"
  git -C "$project_q" add README.md
  git -C "$project_q" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git -C "$project_q" worktree add --quiet --detach "$pool_q" HEAD
  lock=$(project_lock)
  hold_lock "$lock" 60
  FM_SPAWN_TREEHOUSE_LOCK_WAIT_SECS=90 run_spawn "$id_a" --scout > "$CASE_DIR/a.out" &
  spawn_a=$!
  sleep 2
  out_b=$(FM_SPAWN_TREEHOUSE_LOCK_POLL_SECS=0.2 \
    fm_test_run_spawn "$HOME_DIR" "$pool_q" "$fakebin_q" "$id_b" "$project_q" --scout)
  status_b=$?
  kill -0 "$HOLDER_PID" 2>/dev/null || fail "the project lock holder exited before the other spawn finished"
  kill "$HOLDER_PID" 2>/dev/null || true
  wait "$HOLDER_PID" 2>/dev/null || true
  wait "$spawn_a"
  status_a=$?
  expect_code 0 "$status_b" "a spawn for another project must start while the first waits"$'\n'"$out_b"
  assert_not_contains "$out_b" "task set is locked" "the other project's spawn was refused on the task-set lock"
  assert_contains "$out_b" "spawned $id_b" "the other project's spawn did not start"
  expect_code 0 "$status_a" "the waiting spawn should start once the holder is gone"$'\n'"$(cat "$CASE_DIR/a.out")"
  pass "a spawn for another project in the same home starts while one waits for its project lock"
}

test_spawn_waits_for_a_live_holder_then_starts
test_bound_expiry_keeps_the_refusal
test_dead_holder_is_reclaimed_without_waiting
test_other_project_spawn_is_not_refused_during_the_wait

echo "# all fm-spawn-treehouse-lock-wait tests passed"
