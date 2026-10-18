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
# FM_FAKE_RETURN_LEASE (the lease on the slot by the time of the return, when it
# changed after status was read),
# FM_FAKE_SLOT_DIRTY=1 (a slot treehouse will not return without --force),
# FM_FAKE_TH_NOLEASE=1 (an old treehouse whose help lacks --lease/--json).
make_fake_treehouse() {
  cat > "$1/treehouse" <<'SH'
#!/usr/bin/env bash
[ -z "${FM_FAKE_TH_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_TH_LOG"
# Stateful pool: with FM_FAKE_POOL_DIR set, every slot <pool>/<n>/repo is a real
# linked worktree and <pool>/<n>/.fake-state holds "available" or "leased <id>".
# status reads the worktrees' real HEADs, return detaches HEAD (keeping every
# branch ref) and marks the slot available, get --lease hands out the first
# available slot detached - the same contract the real treehouse keeps, so a
# retire-then-lease sequence is observed rather than assumed.
if [ -n "${FM_FAKE_POOL_DIR:-}" ]; then
  fake_slot_dirs() { for d in "$FM_FAKE_POOL_DIR"/*/; do [ -f "${d}.fake-state" ] && printf '%s\n' "${d%/}"; done; }
  case "${1:-}" in
    status)
      sep=
      printf '['
      # FM_FAKE_FLIP_AFTER_FIRST_STATUS=<slot>: the first status call reads the
      # pool as it is, then the slot is leased out from under the reader - the
      # race between a sweep's unlocked read and its locked retire.
      if [ -n "${FM_FAKE_FLIP_AFTER_FIRST_STATUS:-}" ] && [ -e "$FM_FAKE_POOL_DIR/.flip-armed" ]; then
        echo "leased lease-flipped" > "$FM_FAKE_POOL_DIR/$FM_FAKE_FLIP_AFTER_FIRST_STATUS/.fake-state"
      fi
      # FM_FAKE_FLIP_META=<path> likewise creates that task record after the
      # first call, leaving the slot available: a reused task id re-claimed.
      if [ -n "${FM_FAKE_FLIP_META:-}" ] && [ -e "$FM_FAKE_POOL_DIR/.flip-armed" ]; then
        : > "$FM_FAKE_FLIP_META"
      fi
      if [ -n "${FM_FAKE_FLIP_AFTER_FIRST_STATUS:-}${FM_FAKE_FLIP_META:-}" ]; then
        : > "$FM_FAKE_POOL_DIR/.flip-armed"
      fi
      # Each slot lists the processes holding it (FM_FAKE_BUSY_SLOT=<slot>).
      while IFS= read -r d; do
        read -r st lid < "$d/.fake-state"
        br=$(git -C "$d/repo" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
        procs=
        [ "${FM_FAKE_BUSY_SLOT:-}" != "$(basename "$d")" ] || procs='{"pid":4242,"name":"agent"}'
        printf '%s{"name":"%s","path":"%s","status":"%s","branch":"%s","lease_id":"%s","processes":[%s]}' \
          "$sep" "$(basename "$d")" "$d/repo" "$st" "$br" "${lid:-}" "$procs"
        sep=,
      done < <(fake_slot_dirs)
      printf ']\n'
      exit 0 ;;
    get)
      case " $* " in
        *" --help "*)
          printf 'Usage:\n  treehouse get [flags]\n      --json   Print lease allocation as JSON\n      --lease   Durably lease a worktree\n      --lease-holder string   label\n'
          exit 0 ;;
      esac
      while IFS= read -r d; do
        read -r st _ < "$d/.fake-state"
        [ "$st" = available ] || continue
        git -C "$d/repo" checkout -q --detach
        echo "leased lease-$(basename "$d")-$$" > "$d/.fake-state"
        printf '{"path":"%s","lease_id":"lease-%s-%s","lease_holder":"fm","base_branch":"main"}\n' \
          "$d/repo" "$(basename "$d")" "$$"
        exit 0
      done < <(fake_slot_dirs)
      echo "no available slot" >&2
      exit 1 ;;
    return)
      shift
      want=; force=0; target=
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --if-lease-id) want=$2; shift ;;
          --force) force=1 ;;
          *) target=$1 ;;
        esac
        shift
      done
      d=$(dirname "$target")
      [ -f "$d/.fake-state" ] || { echo "not a pool slot: $target" >&2; exit 1; }
      read -r st lid < "$d/.fake-state"
      if [ -n "$want" ] && [ "$want" != "${lid:-}" ]; then
        echo "failed to return worktree: lease precondition failed: lease identity does not match worktree" >&2
        exit 1
      fi
      if [ "$force" = 0 ] && [ -n "$(git -C "$target" status --porcelain)" ]; then
        echo "worktree has uncommitted changes; refusing to discard without confirmation" >&2
        exit 1
      fi
      git -C "$target" checkout -q --detach
      echo available > "$d/.fake-state"
      exit 0 ;;
  esac
fi
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
    if [ -n "$want" ] && [ "$want" != "${FM_FAKE_RETURN_LEASE:-${FM_FAKE_SLOT_LEASE:-}}" ]; then
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
  grep -q '^spawn_first=[0-9][0-9]*$' "$HOME_DIR/state/$id.meta" \
    || fail "a fresh spawn did not record its first-incarnation epoch"
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
  shift
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
    FM_DATA_OVERRIDE="$case_dir/data" FM_CONFIG_OVERRIDE="$case_dir/config" \
    FM_FAKE_POOL_PATH="${FM_FAKE_POOL_PATH-$case_dir/wt}" FM_FAKE_TH_LOG="$case_dir/treehouse.log" \
    PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" task-x1 "$@" 2>&1
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
  # Untracked .claude/ files pass the ship safety filter but still block an unforced return.
  mkdir -p "$case_dir/wt/.claude"
  printf 'scratch\n' > "$case_dir/wt/.claude/notes.md"
  out=$(FM_FAKE_SLOT_DIRTY=1 FM_FAKE_SLOT_LEASE=lease0123abcd run_teardown "$case_dir")
  status=$?
  [ "$status" -ne 0 ] || fail "a return treehouse refuses must abort teardown"$'\n'"$out"
  assert_contains "$out" "nothing was forced" "teardown did not report the refusal as unforced"
  assert_contains "$out" "slot $case_dir/wt under lease lease0123abcd" "the refusal must name the slot and its lease"
  assert_contains "$out" ".claude/notes.md" "the refusal must name the files blocking the return"
  assert_present "$case_dir/state/task-x1.meta" "a refused return must keep the task record"
  calls=$(grep -c '^return ' "$case_dir/treehouse.log")
  [ "$calls" -eq 1 ] || fail "a refused lease-bound return must not be retried or forced ($calls return calls)"
  ! grep -F -- "--force" "$case_dir/treehouse.log" >/dev/null || fail "a refused lease-bound return must never be forced"
  pass "a slot treehouse will not return unforced is reported and left, never forced"
}

test_forced_and_scout_teardowns_force_the_lease_bound_return() {
  local case_dir out status mode
  for mode in forced scout; do
    case_dir=$(make_teardown_case "td-force-$mode")
    printf 'scratch\n' > "$case_dir/wt/scratch.txt"
    if [ "$mode" = forced ]; then
      write_teardown_meta "$case_dir" "lease_id=lease0123abcd"
      out=$(FM_FAKE_SLOT_DIRTY=1 FM_FAKE_SLOT_LEASE=lease0123abcd run_teardown "$case_dir" --force)
    else
      write_teardown_meta "$case_dir" "lease_id=lease0123abcd" "kind=scout" \
        "decisions_reviewed=1" "decision_keys="
      mkdir -p "$case_dir/data/task-x1"
      printf 'scout findings\n' > "$case_dir/data/task-x1/report.md"
      out=$(FM_FAKE_SLOT_DIRTY=1 FM_FAKE_SLOT_LEASE=lease0123abcd run_teardown "$case_dir")
    fi
    status=$?
    expect_code 0 "$status" "$mode: a dirty leased slot should be returned"$'\n'"$out"
    assert_grep "return --force --if-lease-id lease0123abcd $case_dir/wt" "$case_dir/treehouse.log" \
      "$mode: the return must force while staying bound to the recorded lease"
    assert_absent "$case_dir/state/task-x1.meta" "$mode: a returned task keeps no live record"
  done
  pass "an explicit --force teardown and a scout return a dirty slot forced, still lease-bound"
}

test_forced_return_refused_by_a_lease_change_is_reported_as_such() {
  local case_dir out status
  case_dir=$(make_teardown_case td-force-changed)
  write_teardown_meta "$case_dir" "lease_id=lease0123abcd"
  out=$(FM_FAKE_SLOT_LEASE=lease0123abcd FM_FAKE_RETURN_LEASE=someone-elses-lease \
    run_teardown "$case_dir" --force)
  status=$?
  [ "$status" -ne 0 ] || fail "a forced return refused for a lease change must abort teardown"$'\n'"$out"
  assert_contains "$out" "refused the forced lease-bound return of slot $case_dir/wt under lease lease0123abcd (its lease changed)" \
    "a refused forced return must name the lease change as its cause"
  assert_not_contains "$out" "nothing was forced" "a forced return must not be reported as unforced"
  assert_present "$case_dir/state/task-x1.meta" "a refused return must keep the task record"
  pass "a forced lease-bound return refused for a lease change is reported as a lease change"
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

# --- retire and stranded-slot sweep (stateful pool) -------------------------

SLOT_RELEASE="$ROOT/bin/fm-slot-release.sh"

# make_pool_case <name> -> prints the case dir. One project with an origin, a
# home, and a two-slot stateful pool (slot 1 leased to task-p1 on branch
# fm/task-p1 with its work pushed, slot 2 available and detached).
make_pool_case() {
  local name=$1 case_dir pool n
  case_dir="$TMP_ROOT/$name"
  pool="$case_dir/pool"
  mkdir -p "$case_dir/home/state" "$case_dir/home/config" "$case_dir/home/data" "$case_dir/fakebin" "$pool"
  make_fake_treehouse "$case_dir/fakebin"
  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/project" 2>/dev/null
  git -C "$case_dir/project" -c user.email=t@t -c user.name=t commit -q --allow-empty -m baseline
  git -C "$case_dir/project" push -q origin HEAD:main
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  touch "$pool/treehouse-state.json"
  for n in 1 2; do
    mkdir -p "$pool/$n"
    git -C "$case_dir/project" worktree add -q --detach "$pool/$n/repo" main
  done
  printf 'leased lease-p1\n' > "$pool/1/.fake-state"
  printf 'available\n' > "$pool/2/.fake-state"
  git -C "$pool/1/repo" checkout -q -b fm/task-p1
  git -C "$pool/1/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "lane work"
  git -C "$pool/1/repo" push -q origin fm/task-p1
  printf 'task=task-p1\nhome=%s\n' "$case_dir/home" > "$pool/1/.fm-slot-owner"
  fm_write_meta "$case_dir/home/state/task-p1.meta" \
    "worktree=$pool/1/repo" "project=$case_dir/project" "lease_id=lease-p1" "kind=ship"
  printf '%s\n' "$case_dir"
}

# strand_slot <case> <slot> <branch> [claim-task]: the hard-killed state - the
# slot reads available while its checkout still holds a branch and a claim.
strand_slot() {
  local case_dir=$1 slot=$2 branch=$3 claim=${4:-}
  git -C "$case_dir/pool/$slot/repo" checkout -q -b "$branch" main
  git -C "$case_dir/pool/$slot/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "leftover work"
  git -C "$case_dir/pool/$slot/repo" push -q origin "$branch"
  printf 'available\n' > "$case_dir/pool/$slot/.fake-state"
  [ -z "$claim" ] || printf 'task=%s\nhome=%s\n' "$claim" "$case_dir/home" > "$case_dir/pool/$slot/.fm-slot-owner"
}

pool_cmd() { # <case> <command...>
  local case_dir=$1
  shift
  FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_FAKE_POOL_DIR="$case_dir/pool" \
    FM_FAKE_TH_LOG="$case_dir/treehouse.log" PATH="$case_dir/fakebin:$PATH" "$@" 2>&1
}

slot_head() { git -C "$1/pool/$2/repo" symbolic-ref --quiet --short HEAD 2>/dev/null || echo detached; }

# A slot is leasable again when treehouse hands it out and firstmate's own
# custody check (the one a spawn applies) finds nothing holding it.
assert_slot_leasable() { # <case> <slot> <why>
  local case_dir=$1 slot=$2 why=$3 got
  [ "$(slot_head "$case_dir" "$slot")" = detached ] || fail "$why: slot $slot still holds a branch"
  (
    . "$ROOT/bin/fm-wake-lib.sh"
    FM_HOME="$case_dir/home"
    fm_treehouse_slot_claim_custody "$case_dir/pool/$slot/repo" next-task
    [ "$FM_TREEHOUSE_SLOT_CLAIM" = free ]
  ) || fail "$why: slot $slot is still claimed"
  got=$(pool_cmd "$case_dir" treehouse get --lease --json) || fail "$why: treehouse could not lease the slot"$'\n'"$got"
  assert_contains "$got" "$case_dir/pool/$slot/repo" "$why: the lease did not hand out slot $slot"
}

test_retire_keeps_the_branch_and_the_slot_leases_again() {
  local case_dir out status
  case_dir=$(make_pool_case retire-then-lease)
  git -C "$case_dir/pool/2/repo" checkout -q -b fm/other main
  printf 'leased lease-other\n' > "$case_dir/pool/2/.fake-state"
  out=$(pool_cmd "$case_dir" "$SLOT_RELEASE" task-p1)
  status=$?
  expect_code 0 "$status" "retiring a landed, clean slot should succeed"$'\n'"$out"
  [ "$out" = released ] || fail "retire should print exactly 'released', got: $out"
  git -C "$case_dir/project" rev-parse --verify -q refs/heads/fm/task-p1 >/dev/null \
    || fail "the lane branch must survive a retire"
  assert_absent "$case_dir/pool/1/.fm-slot-owner" "a released slot keeps no claim"
  assert_slot_leasable "$case_dir" 1 "retire then lease"
  assert_grep "return --if-lease-id lease-p1" "$case_dir/treehouse.log" \
    "retire did not return the slot bound to the recorded lease"
  pass "retire detaches the slot, keeps the branch, drops the claim, and the slot leases again"
}

test_retire_refuses_dirty_unlanded_and_reassigned_slots() {
  local case_dir out status
  case_dir=$(make_pool_case retire-refusals)
  printf 'wip\n' > "$case_dir/pool/1/repo/untracked.txt"
  out=$(pool_cmd "$case_dir" "$SLOT_RELEASE" task-p1)
  status=$?
  expect_code 1 "$status" "a dirty slot must not be retired"
  [ "$out" = kept:dirty ] || fail "expected kept:dirty, got: $out"
  assert_present "$case_dir/pool/1/repo/untracked.txt" "retire must not discard uncommitted files"
  rm "$case_dir/pool/1/repo/untracked.txt"
  printf 'new content\n' > "$case_dir/pool/1/repo/feature.txt"
  git -C "$case_dir/pool/1/repo" add feature.txt
  git -C "$case_dir/pool/1/repo" -c user.email=t@t -c user.name=t commit -q -m "unpushed work"
  out=$(pool_cmd "$case_dir" "$SLOT_RELEASE" task-p1)
  [ "$out" = kept:unlanded ] || fail "expected kept:unlanded, got: $out"
  [ "$(slot_head "$case_dir" 1)" = fm/task-p1 ] || fail "an unlanded slot must keep its branch checked out"
  printf 'task=someone-else\nhome=%s\n' "$case_dir/home" > "$case_dir/pool/1/.fm-slot-owner"
  out=$(pool_cmd "$case_dir" "$SLOT_RELEASE" task-p1)
  [ "$out" = kept:reassigned ] || fail "expected kept:reassigned, got: $out"
  assert_grep "task=someone-else" "$case_dir/pool/1/.fm-slot-owner" "a reassigned slot's claim must be left alone"
  assert_no_grep "^return" "$case_dir/treehouse.log" "no refusal may reach treehouse return"
  pass "retire keeps dirty, unlanded and reassigned slots exactly as found"
}

test_sweep_returns_a_hard_killed_leftover_to_the_pool() {
  local case_dir out status
  case_dir=$(make_pool_case sweep-leftover)
  strand_slot "$case_dir" 2 fm/task-gone task-gone
  [ "$(slot_head "$case_dir" 2)" = fm/task-gone ] || fail "control: the leftover should hold its branch"
  out=$(pool_cmd "$case_dir" "$SLOT_RELEASE" --sweep "$case_dir/project")
  status=$?
  expect_code 0 "$status" "sweep should succeed"$'\n'"$out"
  [ -z "$out" ] || fail "a released slot is silent, got: $out"
  git -C "$case_dir/project" rev-parse --verify -q refs/heads/fm/task-gone >/dev/null \
    || fail "the leftover's branch must be kept"
  assert_absent "$case_dir/pool/2/.fm-slot-owner" "the sweep must drop the stale claim"
  assert_slot_leasable "$case_dir" 2 "sweep then lease"
  assert_grep "$case_dir/pool/2/repo fm/task-gone released" "$case_dir/home/state/slot-sweep.log" \
    "the sweep must log every slot it acted on"
  [ "$(slot_head "$case_dir" 1)" = fm/task-p1 ] || fail "the sweep must not touch the leased slot"
  pass "the sweep returns a hard-killed leftover to leasable and logs it"
}

test_sweep_leaves_dirty_unlanded_claimed_and_disabled_slots() {
  local case_dir out
  case_dir=$(make_pool_case sweep-limits)
  strand_slot "$case_dir" 2 fm/task-dirty task-dirty
  printf 'wip\n' > "$case_dir/pool/2/repo/scratch.txt"
  out=$(pool_cmd "$case_dir" "$SLOT_RELEASE" --sweep "$case_dir/project")
  assert_contains "$out" "SLOT_SWEEP: $case_dir/pool/2/repo: kept:dirty (fm/task-dirty)" "a dirty leftover must be reported"
  assert_present "$case_dir/pool/2/repo/scratch.txt" "a dirty leftover's files must be untouched"
  [ "$(slot_head "$case_dir" 2)" = fm/task-dirty ] || fail "a dirty leftover must keep its branch checked out"
  assert_present "$case_dir/pool/2/.fm-slot-owner" "a dirty leftover keeps its claim"
  rm "$case_dir/pool/2/repo/scratch.txt"
  printf 'new content\n' > "$case_dir/pool/2/repo/feature.txt"
  git -C "$case_dir/pool/2/repo" add feature.txt
  git -C "$case_dir/pool/2/repo" -c user.email=t@t -c user.name=t commit -q -m "unpushed"
  out=$(pool_cmd "$case_dir" "$SLOT_RELEASE" --sweep "$case_dir/project")
  assert_contains "$out" "kept:unlanded (fm/task-dirty)" "an unlanded leftover must be reported"
  [ "$(slot_head "$case_dir" 2)" = fm/task-dirty ] || fail "an unlanded leftover must keep its branch checked out"
  git -C "$case_dir/pool/2/repo" reset -q --hard origin/fm/task-dirty
  # A claim whose task record still exists is a live claim: never acted on.
  fm_write_meta "$case_dir/home/state/task-dirty.meta" "worktree=$case_dir/pool/2/repo" "kind=ship"
  out=$(pool_cmd "$case_dir" "$SLOT_RELEASE" --sweep "$case_dir/project")
  [ -z "$out" ] || fail "a live claim must be skipped silently, got: $out"
  [ "$(slot_head "$case_dir" 2)" = fm/task-dirty ] || fail "a slot with a live claim must keep its branch checked out"
  rm "$case_dir/home/state/task-dirty.meta"
  # The kill switch disables the sweep even for a slot it would act on.
  : > "$case_dir/home/config/slot-sweep-disable"
  out=$(pool_cmd "$case_dir" "$SLOT_RELEASE" --sweep "$case_dir/project")
  [ -z "$out" ] || fail "a disabled sweep must print nothing, got: $out"
  [ "$(slot_head "$case_dir" 2)" = fm/task-dirty ] || fail "a disabled sweep must not act"
  rm "$case_dir/home/config/slot-sweep-disable"
  out=$(pool_cmd "$case_dir" "$SLOT_RELEASE" --sweep "$case_dir/project")
  [ "$(slot_head "$case_dir" 2)" = detached ] || fail "control: the same slot should be released once the limits clear"
  pass "the sweep leaves dirty, unlanded, live-claimed and kill-switched slots alone"
}

test_sweep_rechecks_the_slot_under_the_lock() {
  local case_dir out
  case_dir=$(make_pool_case sweep-recheck)
  strand_slot "$case_dir" 2 fm/task-raced task-raced
  # The slot is leased out (and re-claimed under the same task id) between the
  # sweep's read and its locked retire: the sweep must stand down, not return it.
  out=$(FM_FAKE_FLIP_AFTER_FIRST_STATUS=2 pool_cmd "$case_dir" "$SLOT_RELEASE" --sweep "$case_dir/project")
  [ -z "$out" ] || fail "a raced slot must be skipped silently, got: $out"
  [ "$(slot_head "$case_dir" 2)" = fm/task-raced ] || fail "a slot leased during the sweep must keep its branch checked out"
  assert_present "$case_dir/pool/2/.fm-slot-owner" "a slot leased during the sweep must keep its claim"
  assert_no_grep "^return" "$case_dir/treehouse.log" "the sweep must not return a slot that was leased under it"
  # The same task id re-claimed by a live record, slot still reading available.
  case_dir=$(make_pool_case sweep-recheck-claim)
  strand_slot "$case_dir" 2 fm/task-raced task-raced
  out=$(FM_FAKE_FLIP_META="$case_dir/home/state/task-raced.meta" pool_cmd "$case_dir" "$SLOT_RELEASE" --sweep "$case_dir/project")
  [ -z "$out" ] || fail "a re-claimed slot must be skipped silently, got: $out"
  assert_present "$case_dir/home/state/task-raced.meta" "control: the flip should have recorded the reused task id"
  [ "$(slot_head "$case_dir" 2)" = fm/task-raced ] || fail "a slot re-claimed during the sweep must keep its branch checked out"
  pass "the sweep rechecks the slot under the lock and stands down when it was leased or re-claimed meanwhile"
}

test_release_refuses_a_slot_a_process_still_holds() {
  local case_dir out status
  case_dir=$(make_pool_case release-busy)
  out=$(FM_FAKE_BUSY_SLOT=1 pool_cmd "$case_dir" "$SLOT_RELEASE" task-p1)
  status=$?
  expect_code 1 "$status" "a slot a process still holds must not be retired"
  assert_contains "$out" "failed" "a busy slot must report failed"
  [ "$(slot_head "$case_dir" 1)" = fm/task-p1 ] || fail "a busy slot must keep its branch checked out"
  assert_present "$case_dir/pool/1/.fm-slot-owner" "a busy slot must keep its claim"
  mkdir "$case_dir/task-p1"
  out=$(cd "$case_dir" && pool_cmd "$case_dir" "$SLOT_RELEASE" task-p1)
  [ "$out" = released ] || fail "a recorded task id must win over a same-named directory, got: $out"
  pass "an explicit release refuses a slot a process still holds, and a task id beats a same-named directory"
}

test_teardown_goes_through_the_retire_owner_and_frees_the_slot() {
  local case_dir out status
  case_dir=$(make_teardown_case td-retire-owner)
  write_teardown_meta "$case_dir" "lease_id=lease0123abcd"
  printf 'task=task-x1\nhome=%s\n' "$case_dir" > "$case_dir/.fm-slot-owner"
  out=$(FM_FAKE_SLOT_LEASE=lease0123abcd run_teardown "$case_dir")
  status=$?
  expect_code 0 "$status" "teardown should retire through the owner"$'\n'"$out"
  assert_grep "return --if-lease-id lease0123abcd $case_dir/wt" "$case_dir/treehouse.log" \
    "teardown must return through the retire owner, lease-bound"
  assert_absent "$case_dir/.fm-slot-owner" "teardown must drop the claim only after the return"
  pass "teardown retires through the one owner and drops its claim after the return"
}

test_spawn_takes_a_lease_and_records_its_id
test_retire_keeps_the_branch_and_the_slot_leases_again
test_retire_refuses_dirty_unlanded_and_reassigned_slots
test_sweep_returns_a_hard_killed_leftover_to_the_pool
test_sweep_leaves_dirty_unlanded_claimed_and_disabled_slots
test_sweep_rechecks_the_slot_under_the_lock
test_release_refuses_a_slot_a_process_still_holds
test_teardown_goes_through_the_retire_owner_and_frees_the_slot
test_spawn_without_lease_support_keeps_the_interactive_path
test_aborted_spawn_returns_its_unrecorded_lease
test_teardown_returns_exactly_the_recorded_lease_without_force
test_teardown_without_a_lease_returns_as_before
test_changed_lease_stops_teardown_before_anything_destructive
test_changed_lease_stops_teardown_before_a_stale_lock_is_removed
test_unconfirmable_lease_stops_teardown_before_anything_destructive
test_dirty_slot_return_is_refused_not_forced
test_forced_and_scout_teardowns_force_the_lease_bound_return
test_forced_return_refused_by_a_lease_change_is_reported_as_such
test_teardown_refuses_a_malformed_lease_id

echo "# all fm-treehouse-lease tests passed"
