#!/usr/bin/env bash
# Behavioural tests for the Treehouse lease a crewmate spawn takes and the
# lease-bound return teardown makes (bin/fm-spawn.sh, bin/fm-teardown.sh).
#
# A slot taken by the interactive `treehouse get` is reclaimed by process
# presence, so ending its agent strands it. A spawn that takes
# `treehouse get --lease --json` instead records the lease id as lease_id= in
# the task meta, and teardown returns exactly that lease with --if-lease-id: a
# slot since handed to anyone else is refused, never forced.
# The fake treehouse below honours the lease identity the way the real one does
# (it refuses a return whose --if-lease-id differs from the lease on the slot),
# so a refusal is observed through teardown rather than assumed.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
fm_git_identity fmtest fmtest@example.invalid

TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-treehouse-lease)
FM_REAL_GIT=$(command -v git)
export FM_REAL_GIT

# make_fake_treehouse <fakebin>
# Env the fake reads: FM_FAKE_TH_LOG (one line per invocation),
# FM_FAKE_LEASE_PATH / FM_FAKE_LEASE_ID (what `get --lease --json` reports),
# FM_FAKE_SLOT_LEASE (the lease currently on the slot, for status and return),
# FM_FAKE_POOL_PATH (the slot path `status --json` lists; unset lists nothing),
# FM_FAKE_SLOT_DIRTY=1 (a slot treehouse will not return without --force),
# FM_FAKE_TH_NOLEASE=1 (an old treehouse whose help lacks --lease/--json).
make_fake_treehouse() {
  cat > "$1/treehouse" <<'SH'
#!/usr/bin/env bash
[ -z "${FM_FAKE_TH_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_TH_LOG"
case "${1:-}" in
  get)
    case " $* " in
      *" --help "*)
        if [ "${FM_FAKE_TH_NOLEASE:-0}" = 1 ]; then
          printf 'Usage:\n  treehouse get [flags]\n      --base string   Branch\n'
        else
          printf 'Usage:\n  treehouse get [flags]\n      --json   Print lease allocation as JSON\n      --lease   Durably lease a worktree\n      --lease-holder string   label\n'
        fi
        exit 0 ;;
    esac
    if [ "${FM_FAKE_TH_NOLEASE:-0}" != 1 ]; then
      printf '{"path":"%s","lease_id":"%s","lease_holder":"fm","base_branch":"main"}\n' \
        "$FM_FAKE_LEASE_PATH" "$FM_FAKE_LEASE_ID"
    fi
    exit 0 ;;
  status)
    [ "${FM_FAKE_TH_STATUS_FAIL:-0}" != 1 ] || exit 1
    if [ -n "${FM_FAKE_POOL_PATH:-}" ]; then
      printf '[{"name":"1","path":"%s","status":"leased","lease_id":"%s"}]\n' \
        "$FM_FAKE_POOL_PATH" "${FM_FAKE_SLOT_LEASE:-}"
    else
      echo '[]'
    fi
    exit 0 ;;
  return)
    shift
    want=
    force=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --if-lease-id) want=$2; shift ;;
        --force) force=1 ;;
      esac
      shift
    done
    if [ "${FM_FAKE_SLOT_DIRTY:-0}" = 1 ] && [ "$force" = 0 ]; then
      echo "worktree has uncommitted changes; refusing to discard without confirmation" >&2
      exit 1
    fi
    if [ -n "$want" ] && [ "$want" != "${FM_FAKE_SLOT_LEASE:-}" ]; then
      echo "failed to return worktree: lease precondition failed: lease identity does not match worktree" >&2
      exit 1
    fi
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$1/treehouse"
}

# --- spawn ------------------------------------------------------------------

make_spawn_case() {
  local name=$1 id=$2 case_dir home project origin pool fakebin initial
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  origin="$case_dir/origin.git"
  pool="$case_dir/pool"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" gh)
  make_fake_treehouse "$fakebin"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_test_spawn_brief "$home" "$id"
  touch "$home/state/.last-watcher-beat"
  git init --quiet -b main "$project"
  printf 'base\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" commit -qm initial
  git clone --quiet --bare "$project" "$origin"
  git -C "$project" remote add origin "file://$origin"
  initial=$(git -C "$project" rev-parse HEAD)
  git -C "$project" worktree add --quiet --detach "$pool" "$initial"
  printf '%s\n' "$case_dir|$home|$project|$pool|$fakebin"
}

read_spawn_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJECT_DIR POOL_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_spawn() {
  local id=$1
  shift
  FM_FAKE_TH_LOG="$CASE_DIR/treehouse.log" FM_FAKE_LEASE_PATH="$POOL_DIR" \
    FM_FAKE_LEASE_ID="${LEASE_ID:-lease0123abcd}" \
    fm_test_run_spawn "$HOME_DIR" "$POOL_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJECT_DIR" --mode no-mistakes --yolo off "$@"
}

test_spawn_takes_a_lease_and_records_its_id() {
  local rec id out status
  id=lease-spawn-a1
  rec=$(make_spawn_case lease-spawn "$id")
  read_spawn_case "$rec"
  out=$(run_spawn "$id")
  status=$?
  expect_code 0 "$status" "a lease spawn should succeed"$'\n'"$out"
  assert_grep "get --lease --json --lease-holder fm-$id" "$CASE_DIR/treehouse.log" \
    "spawn did not take the slot as a durable lease held under its task label"
  assert_grep "lease_id=lease0123abcd" "$HOME_DIR/state/$id.meta" \
    "the lease identity was not recorded in the task meta"
  assert_grep "worktree=$POOL_DIR" "$HOME_DIR/state/$id.meta" \
    "the leased path was not recorded as the task worktree"
  pass "a spawn takes a durable lease and records its identity beside the worktree"
}

test_spawn_without_lease_support_keeps_the_interactive_path() {
  local rec id out status
  id=lease-spawn-old-a2
  rec=$(make_spawn_case lease-old "$id")
  read_spawn_case "$rec"
  out=$(FM_FAKE_TH_NOLEASE=1 run_spawn "$id")
  status=$?
  expect_code 0 "$status" "a spawn on a treehouse without lease support should still succeed"$'\n'"$out"
  assert_no_grep "lease_id=" "$HOME_DIR/state/$id.meta" \
    "a slot taken without a lease must not claim a lease identity"
  assert_no_grep "get --lease" "$CASE_DIR/treehouse.log" \
    "spawn asked for a lease from a treehouse that does not offer one"
  pass "a treehouse without get --lease keeps today's interactive acquire and records no lease"
}

test_aborted_spawn_returns_its_unrecorded_lease() {
  local rec id out status
  id=lease-spawn-abort-a3
  rec=$(make_spawn_case lease-abort "$id")
  read_spawn_case "$rec"
  # A lease that reports the spawning project itself fails the isolation guard.
  out=$(FM_FAKE_TH_LOG="$CASE_DIR/treehouse.log" FM_FAKE_LEASE_PATH="$PROJECT_DIR" \
    FM_FAKE_LEASE_ID=lease-abort-77 FM_FAKE_SLOT_LEASE=lease-abort-77 \
    fm_test_run_spawn "$HOME_DIR" "$PROJECT_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJECT_DIR" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a lease on the primary checkout must not launch"$'\n'"$out"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn must not publish a task record"
  assert_grep "return --if-lease-id lease-abort-77 $PROJECT_DIR" "$CASE_DIR/treehouse.log" \
    "a spawn that aborted before recording its lease must give the lease back, bound to its identity"
  pass "a spawn that aborts before its record exists returns the lease it took"
}

# --- teardown ---------------------------------------------------------------

make_teardown_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/config" "$case_dir/data" "$fakebin"
  make_fake_treehouse "$fakebin"
  fm_fake_exit0 "$fakebin" tmux gh no-mistakes
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  chmod +x "$fakebin/gh-axi"
  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m baseline
  git -C "$case_dir/_seed" push -q origin main
  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin
  touch "$case_dir/state/.last-watcher-beat"
  printf '%s\n' "$case_dir"
}

write_teardown_meta() { # <case> [extra key=val...]
  local case_dir=$1
  shift
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" \
    "endpoint_task_id=task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes" \
    "spawn_gen=teardown-test-task-x1" \
    "$@"
}

run_teardown() {
  local case_dir=$1
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
    FM_DATA_OVERRIDE="$case_dir/data" FM_CONFIG_OVERRIDE="$case_dir/config" \
    FM_FAKE_POOL_PATH="${FM_FAKE_POOL_PATH-$case_dir/wt}" FM_FAKE_TH_LOG="$case_dir/treehouse.log" \
    PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" task-x1 2>&1
}

add_hook() { # <case>: a hook file teardown removes only once it proceeds
  mkdir -p "$1/wt/.claude"
  printf '{}\n' > "$1/wt/.claude/settings.local.json"
}

wt_branch() { git -C "$1/wt" rev-parse --abbrev-ref HEAD; }

test_teardown_returns_exactly_the_recorded_lease_without_force() {
  local case_dir out status
  case_dir=$(make_teardown_case td-lease)
  write_teardown_meta "$case_dir" "lease_id=lease0123abcd"
  out=$(FM_FAKE_SLOT_LEASE=lease0123abcd run_teardown "$case_dir")
  status=$?
  expect_code 0 "$status" "teardown of a leased task should return its slot"$'\n'"$out"
  assert_grep "return --if-lease-id lease0123abcd $case_dir/wt" "$case_dir/treehouse.log" \
    "teardown did not return the slot bound to its recorded lease"
  ! grep -F -- "return" "$case_dir/treehouse.log" | grep -F -- "--force" >/dev/null \
    || fail "a lease-bound return must never force"
  assert_absent "$case_dir/state/task-x1.meta" "a returned task keeps no live record"
  pass "teardown returns the slot bound to its recorded lease, without --force"
}

test_teardown_without_a_lease_returns_as_before() {
  local case_dir out status
  case_dir=$(make_teardown_case td-nolease)
  write_teardown_meta "$case_dir"
  out=$(run_teardown "$case_dir")
  status=$?
  expect_code 0 "$status" "a record without a lease should tear down as before"$'\n'"$out"
  assert_grep "return --force $case_dir/wt" "$case_dir/treehouse.log" \
    "teardown did not return the slot"
  assert_no_grep "if-lease-id" "$case_dir/treehouse.log" \
    "a record with no lease must not invent a lease-bound return"
  assert_no_grep "status" "$case_dir/treehouse.log" "a record with no lease needs no lease query"
  pass "a record with no lease id keeps today's unbound return"
}

test_changed_lease_stops_teardown_before_anything_destructive() {
  local case_dir out status
  case_dir=$(make_teardown_case td-changed)
  write_teardown_meta "$case_dir" "lease_id=lease0123abcd"
  add_hook "$case_dir"
  out=$(FM_FAKE_SLOT_LEASE=someone-elses-lease run_teardown "$case_dir")
  status=$?
  [ "$status" -ne 0 ] || fail "a changed lease must abort teardown"$'\n'"$out"
  assert_contains "$out" "lease changed" "teardown did not report that the lease changed"
  assert_present "$case_dir/state/task-x1.meta" "a refused teardown must keep the task record"
  [ "$(wt_branch "$case_dir")" = fm/task-x1 ] || fail "a changed lease must leave the branch checked out"
  git -C "$case_dir/wt" rev-parse --verify -q fm/task-x1 >/dev/null || fail "the task branch must survive a refused teardown"
  assert_present "$case_dir/wt/.claude/settings.local.json" "the worker's hooks must survive a refused teardown"
  assert_no_grep "return" "$case_dir/treehouse.log" "no return may be attempted for a slot whose lease changed"
  pass "a changed lease stops teardown before it touches the branch, hooks, or slot"
}

test_changed_lease_stops_teardown_before_a_stale_lock_is_removed() {
  local case_dir out status lock mode
  for mode in matching changed; do
    case_dir=$(make_teardown_case "td-lock-$mode")
    write_teardown_meta "$case_dir" "lease_id=lease0123abcd"
    printf '#!/usr/bin/env bash\ncase " $* " in *" -d cwd "*) exit 0 ;; esac\nexit 1\n' > "$case_dir/fakebin/lsof"
    chmod +x "$case_dir/fakebin/lsof"
    # git status cannot run while the index lock exists, which is what sends the
    # safety check down the stale-lock path.
    cat > "$case_dir/fakebin/git" <<'SH'
#!/usr/bin/env bash
if [ -e "${FM_FAKE_LOCK:-/nonexistent}" ]; then
  for a in "$@"; do
    [ "$a" = status ] && { echo "fatal: Unable to create index.lock: File exists" >&2; exit 128; }
  done
fi
exec "$FM_REAL_GIT" "$@"
SH
    chmod +x "$case_dir/fakebin/git"
    lock=$(git -C "$case_dir/wt" rev-parse --git-path index.lock)
    case "$lock" in /*) ;; *) lock="$(cd "$case_dir/wt" && pwd -P)/$lock" ;; esac
    mkdir -p "$(dirname "$lock")"
    : > "$lock"
    touch -t 200001010000 "$lock"
    if [ "$mode" = matching ]; then
      out=$(FM_FAKE_LOCK="$lock" FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
        FM_FAKE_SLOT_LEASE=lease0123abcd run_teardown "$case_dir")
      # Control: the scenario really reaches the stale-lock removal when the lease holds.
      assert_contains "$out" "removed provably-stale git lock" "control: a matching lease should let the stale lock be cleared"
    else
      out=$(FM_FAKE_LOCK="$lock" FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
        FM_FAKE_SLOT_LEASE=someone-elses-lease run_teardown "$case_dir")
      status=$?
      [ "$status" -ne 0 ] || fail "a changed lease must abort teardown"$'\n'"$out"
      assert_present "$lock" "a changed lease must stop teardown before it deletes a stale index lock"
      assert_contains "$out" "lease changed" "teardown did not report the changed lease"
    fi
  done
  pass "a changed lease stops teardown before a stale index lock is removed"
}

test_unconfirmable_lease_stops_teardown_before_anything_destructive() {
  local case_dir out status mode
  for mode in absent unreadable; do
    case_dir=$(make_teardown_case "td-unconfirmed-$mode")
    write_teardown_meta "$case_dir" "lease_id=lease0123abcd"
    add_hook "$case_dir"
    if [ "$mode" = absent ]; then
      out=$(FM_FAKE_POOL_PATH='' FM_FAKE_SLOT_LEASE=lease0123abcd run_teardown "$case_dir")
    else
      out=$(FM_FAKE_TH_STATUS_FAIL=1 FM_FAKE_SLOT_LEASE=lease0123abcd run_teardown "$case_dir")
    fi
    status=$?
    [ "$status" -ne 0 ] || fail "a lease treehouse cannot confirm ($mode) must abort teardown"$'\n'"$out"
    assert_present "$case_dir/state/task-x1.meta" "$mode: the task record must be kept"
    [ "$(wt_branch "$case_dir")" = fm/task-x1 ] || fail "$mode: the branch must stay checked out"
    assert_present "$case_dir/wt/.claude/settings.local.json" "$mode: the hooks must be kept"
    assert_no_grep "return" "$case_dir/treehouse.log" "$mode: no return may be attempted"
  done
  pass "a lease treehouse does not list or cannot report stops teardown before anything destructive"
}

test_dirty_slot_return_is_refused_not_forced() {
  local case_dir out status calls
  case_dir=$(make_teardown_case td-dirty)
  write_teardown_meta "$case_dir" "lease_id=lease0123abcd"
  out=$(FM_FAKE_SLOT_DIRTY=1 FM_FAKE_SLOT_LEASE=lease0123abcd run_teardown "$case_dir")
  status=$?
  [ "$status" -ne 0 ] || fail "a return treehouse refuses must abort teardown"$'\n'"$out"
  assert_contains "$out" "nothing was forced" "teardown did not report the refusal as unforced"
  assert_present "$case_dir/state/task-x1.meta" "a refused return must keep the task record"
  calls=$(grep -c '^return ' "$case_dir/treehouse.log")
  [ "$calls" -eq 1 ] || fail "a refused lease-bound return must not be retried or forced ($calls return calls)"
  ! grep -F -- "--force" "$case_dir/treehouse.log" >/dev/null || fail "a refused lease-bound return must never be forced"
  pass "a slot treehouse will not return unforced is reported and left, never forced"
}

test_teardown_refuses_a_malformed_lease_id() {
  local case_dir out status
  case_dir=$(make_teardown_case td-malformed)
  write_teardown_meta "$case_dir" 'lease_id=bad;touch pwned'
  add_hook "$case_dir"
  out=$(run_teardown "$case_dir")
  status=$?
  [ "$status" -ne 0 ] || fail "a malformed lease identity must abort teardown"$'\n'"$out"
  assert_absent "$case_dir/treehouse.log" "teardown must not call treehouse with a malformed lease id"
  assert_present "$case_dir/wt/.claude/settings.local.json" "a refused teardown must leave the hooks"
  assert_present "$case_dir/state/task-x1.meta" "a refused teardown must keep the task record"
  pass "a malformed lease id is refused before any treehouse call or destructive step"
}

test_spawn_takes_a_lease_and_records_its_id
test_spawn_without_lease_support_keeps_the_interactive_path
test_aborted_spawn_returns_its_unrecorded_lease
test_teardown_returns_exactly_the_recorded_lease_without_force
test_teardown_without_a_lease_returns_as_before
test_changed_lease_stops_teardown_before_anything_destructive
test_changed_lease_stops_teardown_before_a_stale_lock_is_removed
test_unconfirmable_lease_stops_teardown_before_anything_destructive
test_dirty_slot_return_is_refused_not_forced
test_teardown_refuses_a_malformed_lease_id

echo "# all fm-treehouse-lease tests passed"
