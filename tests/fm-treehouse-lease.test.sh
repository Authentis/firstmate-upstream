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

# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"

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
    # FM_FAKE_POOL_ORIGIN: the pool is named after `git remote get-url origin`,
    # as the real one is, so the slot is listed only while origin reads as this.
    if [ -n "${FM_FAKE_POOL_ORIGIN:-}" ] && [ "$(git remote get-url origin 2>/dev/null)" != "$FM_FAKE_POOL_ORIGIN" ]; then
      echo '[]'
    elif [ -n "${FM_FAKE_POOL_PATH:-}" ]; then
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
  id="lease-spawn-a1"
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
  id="lease-spawn-old-a2"
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
  id="lease-spawn-abort-a3"
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
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/${TD_WT_REL:-wt}" main
  git -C "$case_dir/${TD_WT_REL:-wt}" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "shippable work"
  git -C "$case_dir/${TD_WT_REL:-wt}" push -q origin fm/task-x1
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
    "worktree=$case_dir/${TD_WT_REL:-wt}" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes" \
    "spawn_gen=teardown-test-task-x1" \
    "$@"
}

# TD_BOUND=<seconds> runs teardown under a hard bound (fm_run_timed exits 124
# when it is hit), so a test of a wait cannot stall the suite.
run_teardown() {
  local case_dir=$1
  local -a bound=()
  shift
  [ -z "${TD_BOUND:-}" ] || bound=(fm_run_timed "$TD_BOUND")
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
    FM_DATA_OVERRIDE="$case_dir/data" FM_CONFIG_OVERRIDE="$case_dir/config" \
    FM_FAKE_POOL_PATH="${FM_FAKE_POOL_PATH-$case_dir/${TD_WT_REL:-wt}}" FM_FAKE_TH_LOG="$case_dir/treehouse.log" \
    PATH="$case_dir/fakebin:$PATH" \
    ${bound[@]+"${bound[@]}"} "$TEARDOWN" task-x1 "$@" 2>&1
}

add_hook() { # <case>: a hook file teardown removes only once it proceeds
  mkdir -p "$1/${TD_WT_REL:-wt}/.claude"
  printf '{}\n' > "$1/${TD_WT_REL:-wt}/.claude/settings.local.json"
}

wt_branch() { git -C "$1/${TD_WT_REL:-wt}" rev-parse --abbrev-ref HEAD; }

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
  local case_dir out status
  case_dir=$(make_teardown_case "td-unconfirmed-unreadable")
  write_teardown_meta "$case_dir" "lease_id=lease0123abcd"
  add_hook "$case_dir"
  out=$(FM_FAKE_TH_STATUS_FAIL=1 FM_FAKE_SLOT_LEASE=lease0123abcd run_teardown "$case_dir")
  status=$?
  [ "$status" -ne 0 ] || fail "a lease treehouse cannot report (unreadable) must abort teardown"$'\n'"$out"
  assert_present "$case_dir/state/task-x1.meta" "unreadable: the task record must be kept"
  [ "$(wt_branch "$case_dir")" = fm/task-x1 ] || fail "unreadable: the branch must stay checked out"
  assert_present "$case_dir/wt/.claude/settings.local.json" "unreadable: the hooks must be kept"
  assert_no_grep "return" "$case_dir/treehouse.log" "unreadable: no return may be attempted"
  pass "a lease treehouse that cannot report stops teardown before anything destructive"
}

test_absent_pool_listing_completes_records_only_after_backup() {
  local case_dir out status head
  case_dir=$(make_teardown_case "td-unconfirmed-absent")
  write_teardown_meta "$case_dir" "lease_id=lease0123abcd"
  add_hook "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  out=$(FM_FAKE_POOL_PATH='' FM_FAKE_SLOT_LEASE=lease0123abcd run_teardown "$case_dir")
  status=$?
  [ "$status" -eq 0 ] || fail "an absent pool listing must complete records-only after the safety proof"$'\n'"$out"
  assert_contains "$out" "or its lease no longer listed; copy left in place, backup in " \
    "absent: teardown did not report records-only completion"
  assert_contains "$out" "Preserved gone-pool-slot lane task-x1: bundle " \
    "absent: the safety proof did not preserve a backup"
  git bundle verify "$case_dir/data/bundles/task-x1.bundle" >/dev/null 2>&1 \
    || fail "absent: the backup bundle is missing or invalid"
  git bundle list-heads "$case_dir/data/bundles/task-x1.bundle" | grep -q "^$head " \
    || fail "absent: the backup bundle lost the lane head"
  assert_absent "$case_dir/state/task-x1.meta" "absent: the task record must be retired"
  [ "$(wt_branch "$case_dir")" = fm/task-x1 ] || fail "absent: the copy must stay checked out"
  [ "$(git -C "$case_dir/wt" rev-parse HEAD)" = "$head" ] || fail "absent: the copy head changed"
  assert_present "$case_dir/wt/.claude/settings.local.json" "absent: the hooks must be kept"
  assert_no_grep "return" "$case_dir/treehouse.log" "absent: no return may be attempted"
  pass "an absent pool listing completes records-only after a verified backup, leaving the copy in place"
}

# A git url rewrite added after a slot was taken moves the project's current
# pool (Treehouse names a pool after `git remote get-url origin`). The fake pool
# is named after the origin it was created under (FM_FAKE_POOL_ORIGIN), and the
# slot sits in the real <pool>/<slot>/<repo> layout with the pool's own state.
#   old         the slot is in the pool from before the rewrite
#   new         the slot is in the pool the rewritten origin names
#   old-changed the old pool's own state shows another lease on the slot
test_url_rewrite_keeps_old_and_new_pool_slots_tearing_down() {
  local mode case_dir out status origin rewritten gitconfig slot pool_origin state_lease
  local TD_WT_REL=pool/1/repo
  for mode in old new old-changed; do
    case_dir=$(make_teardown_case "td-rewrite-$mode")
    slot="$case_dir/$TD_WT_REL"
    write_teardown_meta "$case_dir" "lease_id=lease0123abcd"
    add_hook "$case_dir"
    origin=$(git -C "$case_dir/project" config --get remote.origin.url)
    # Same repository, new URL string: the project's pool id moves.
    gitconfig="$case_dir/gitconfig"
    git config --file "$gitconfig" "url.file://$origin.insteadOf" "$origin"
    rewritten=$(GIT_CONFIG_GLOBAL="$gitconfig" git -C "$case_dir/project" remote get-url origin)
    [ "$rewritten" != "$origin" ] || fail "$mode control: the rewrite must change how origin reads"
    pool_origin=$origin
    [ "$mode" != new ] || pool_origin=$rewritten
    state_lease=lease0123abcd
    [ "$mode" != old-changed ] || state_lease=someone-elses-lease
    printf '{"version":4,"worktrees":[{"name":"1","path":"%s","leased":true,"lease_id":"%s"}]}\n' \
      "$(cd "$slot" && pwd -P)" "$state_lease" > "$case_dir/pool/treehouse-state.json"
    out=$( cd "$case_dir/project" && GIT_CONFIG_GLOBAL="$gitconfig" FM_FAKE_POOL_PATH="$slot" \
      FM_FAKE_POOL_ORIGIN="$pool_origin" "$case_dir/fakebin/treehouse" status --json )
    if [ "$mode" = new ]; then
      [ "$out" != '[]' ] || fail "$mode control: a plain status under the rewrite must list the slot"
    else
      [ "$out" = '[]' ] || fail "$mode control: a plain status under the rewrite must not list the slot"
    fi
    : > "$case_dir/treehouse.log"
    out=$(GIT_CONFIG_GLOBAL="$gitconfig" FM_FAKE_POOL_ORIGIN="$pool_origin" \
      FM_FAKE_SLOT_LEASE=lease0123abcd run_teardown "$case_dir")
    status=$?
    if [ "$mode" = old-changed ]; then
      [ "$status" -ne 0 ] || fail "$mode: another lease in the slot's own pool must abort teardown"$'\n'"$out"
      assert_contains "$out" "lease changed" "$mode: teardown did not report the changed lease"
      assert_present "$case_dir/state/task-x1.meta" "$mode: a refused teardown must keep the task record"
      [ "$(wt_branch "$case_dir")" = fm/task-x1 ] || fail "$mode: the branch must stay checked out"
      assert_no_grep "return" "$case_dir/treehouse.log" "$mode: no return may be attempted"
      continue
    fi
    expect_code 0 "$status" "$mode: a leased slot should tear down after a url rewrite"$'\n'"$out"
    assert_not_contains "$out" "no longer listed" "$mode: the slot must not be treated as gone from its pool"
    assert_grep "return --if-lease-id lease0123abcd $slot" "$case_dir/treehouse.log" \
      "$mode: teardown did not return the slot bound to its recorded lease"
    ! grep -F -- "return" "$case_dir/treehouse.log" | grep -F -- "--force" >/dev/null \
      || fail "$mode: the lease-bound return must not force"
    assert_absent "$case_dir/state/task-x1.meta" "$mode: a returned task keeps no live record"
  done
  pass "after a url rewrite, old-pool and new-pool leased slots both tear down unforced, and the old pool's own lease still guards"
}

# The same url rewrite, with the lane's own work committed but never pushed.
#   gone         the old pool's own state no longer leases the slot, so the
#                gone-pool fallback runs; it refuses unpushed work unforced
#   gone-forced  the same with --force, which the gone-pool proof never yields to
#   found        the old pool's own state confirms the lease; the ordinary
#                landed-work check refuses unpushed work unforced
#   found-forced the same with --force: a lease confirmed only through the
#                slot's own pool still faces the gone-pool proof, which refuses
#   new-conflict a new-pool slot the current pool lists with the recorded lease
#                while the slot's own pool state shows another: the current
#                pool decides, so the pushed lane still tears down
test_url_rewrite_never_overrides_unlanded_work_or_the_current_pool() {
  local mode case_dir out status origin rewritten gitconfig slot pool_origin state_json head
  local TD_WT_REL=pool/1/repo
  local -a force
  for mode in gone gone-forced found found-forced new-conflict; do
    case_dir=$(make_teardown_case "td-rewrite-unlanded-$mode")
    slot="$case_dir/$TD_WT_REL"
    write_teardown_meta "$case_dir" "lease_id=lease0123abcd"
    add_hook "$case_dir"
    # Real content, so no landed-content fallback can count it as already on main.
    if [ "$mode" != new-conflict ]; then
      printf 'lane work\n' > "$slot/lane-work.txt"
      git -C "$slot" add lane-work.txt
      git -C "$slot" -c user.email=t@t -c user.name=t commit -q -m "unpushed lane work"
    fi
    head=$(git -C "$slot" rev-parse HEAD)
    origin=$(git -C "$case_dir/project" config --get remote.origin.url)
    gitconfig="$case_dir/gitconfig"
    git config --file "$gitconfig" "url.file://$origin.insteadOf" "$origin"
    rewritten=$(GIT_CONFIG_GLOBAL="$gitconfig" git -C "$case_dir/project" remote get-url origin)
    pool_origin=$origin
    case "$mode" in
      gone|gone-forced) state_json='"leased":false,"lease_id":null' ;;
      found|found-forced) state_json='"leased":true,"lease_id":"lease0123abcd"' ;;
      new-conflict) pool_origin=$rewritten; state_json='"leased":true,"lease_id":"someone-elses-lease"' ;;
    esac
    printf '{"version":4,"worktrees":[{"name":"1","path":"%s",%s}]}\n' \
      "$(cd "$slot" && pwd -P)" "$state_json" > "$case_dir/pool/treehouse-state.json"
    force=()
    case "$mode" in *-forced) force=(--force) ;; esac
    : > "$case_dir/treehouse.log"
    out=$(GIT_CONFIG_GLOBAL="$gitconfig" FM_HOME="$case_dir" FM_FAKE_POOL_ORIGIN="$pool_origin" \
      FM_FAKE_SLOT_LEASE=lease0123abcd run_teardown "$case_dir" ${force[@]+"${force[@]}"})
    status=$?
    if [ "$mode" = new-conflict ]; then
      expect_code 0 "$status" "$mode: the current pool's matching lease should decide"$'\n'"$out"
      assert_grep "return --if-lease-id lease0123abcd $slot" "$case_dir/treehouse.log" \
        "$mode: teardown did not return the slot the current pool confirmed"
      assert_absent "$case_dir/state/task-x1.meta" "$mode: a returned task keeps no live record"
      continue
    fi
    [ "$status" -ne 0 ] || fail "$mode: unpushed lane work must refuse teardown"$'\n'"$out"
    case "$mode" in
      gone*|found-forced) assert_contains "$out" "has work not on any remote and not landed" \
        "$mode: the gone-pool proof did not name the unlanded work" ;;
      found) assert_not_contains "$out" "gone-pool" "$mode: a confirmed lease must not take the gone-pool fallback" ;;
    esac
    assert_present "$case_dir/state/task-x1.meta" "$mode: a refused teardown must keep the task record"
    [ -d "$slot" ] || fail "$mode: the copy must stay in place"
    [ "$(wt_branch "$case_dir")" = fm/task-x1 ] || fail "$mode: the branch must stay checked out"
    [ "$(git -C "$slot" rev-parse HEAD)" = "$head" ] || fail "$mode: the copy head changed"
    git -C "$case_dir/project" rev-parse --verify -q refs/heads/fm/task-x1 >/dev/null \
      || fail "$mode: the task branch must survive a refused teardown"
    assert_present "$slot/.claude/settings.local.json" "$mode: the worker's hooks must survive a refused teardown"
    assert_no_grep "return" "$case_dir/treehouse.log" "$mode: no return may be attempted"
  done
  pass "after a url rewrite, unpushed old-pool work still refuses, under --force too whether or not the old pool confirms the lease, and the current pool still decides"
}

# url_rewrite_old_pool_case <name> <state-lease>: a teardown case whose slot
# sits in its own pool from before a git url rewrite, so only that pool's own
# state lists it, leased as <state-lease>. Prints the case directory; the
# rewrite config is <case>/gitconfig and the pool origin <case>/pool-origin.
# Callers set TD_WT_REL=pool/1/repo.
url_rewrite_old_pool_case() {
  local case_dir origin gitconfig slot
  case_dir=$(make_teardown_case "$1")
  slot="$case_dir/pool/1/repo"
  write_teardown_meta "$case_dir" "lease_id=lease0123abcd"
  add_hook "$case_dir"
  origin=$(git -C "$case_dir/project" config --get remote.origin.url)
  gitconfig="$case_dir/gitconfig"
  git config --file "$gitconfig" "url.file://$origin.insteadOf" "$origin"
  printf '%s\n' "$origin" > "$case_dir/pool-origin"
  printf '{"version":4,"worktrees":[{"name":"1","path":"%s","leased":true,"lease_id":"%s"}]}\n' \
    "$(cd "$slot" && pwd -P)" "$2" > "$case_dir/pool/treehouse-state.json"
  printf '%s\n' "$case_dir"
}

run_url_rewrite_teardown() {  # <case> [teardown args...]
  local case_dir=$1
  shift
  GIT_CONFIG_GLOBAL="$case_dir/gitconfig" FM_HOME="$case_dir" \
    FM_FAKE_POOL_ORIGIN="$(cat "$case_dir/pool-origin")" \
    run_teardown "$case_dir" "$@"
}

# The old pool's lease is confirmed, then an allocator of that pool - one that
# still reads the old origin, so it takes a different Firstmate project lock -
# returns and re-leases the slot to someone else before the slot cleanup. It
# writes the pool state under Treehouse's own state lock, as a real allocator
# does. The new holder's branch, head, and hooks must survive, and nothing may
# be returned: the cleanup has to see the new lease, not the one read earlier.
test_url_rewrite_old_pool_relet_after_confirmation_leaves_the_new_holder_alone() {
  local case_dir out status slot head
  local TD_WT_REL=pool/1/repo
  case_dir=$(url_rewrite_old_pool_case td-rewrite-relet lease0123abcd)
  slot="$case_dir/pool/1/repo"
  head=$(git -C "$slot" rev-parse HEAD)
  cat > "$case_dir/fakebin/jq" <<SH
#!/usr/bin/env bash
"$(command -v jq)" "\$@" || exit \$?
[ "\${!#}" = "$case_dir/pool/treehouse-state.json" ] || exit 0
[ ! -e "$case_dir/relet-done" ] || exit 0
: > "$case_dir/relet-done"
perl -e '
  use Fcntl qw(:flock);
  open(my \$fh, ">>", \$ARGV[0]) or exit 1;
  flock(\$fh, LOCK_EX) or exit 1;
  open(my \$out, ">", \$ARGV[1]) or exit 1;
  print \$out \$ARGV[2];
  close(\$out) or exit 1;
' "$case_dir/pool/treehouse-state.lock" "$case_dir/pool/treehouse-state.json" \
  '{"version":4,"worktrees":[{"name":"1","path":"$(cd "$slot" && pwd -P)","leased":true,"lease_id":"new-holders-lease"}]}'
exit 0
SH
  chmod +x "$case_dir/fakebin/jq"
  cat > "$case_dir/fakebin/no-mistakes" <<SH
#!/usr/bin/env bash
: > "$case_dir/run-touched"
SH
  chmod +x "$case_dir/fakebin/no-mistakes"
  : > "$case_dir/treehouse.log"
  out=$(FM_FAKE_SLOT_LEASE=new-holders-lease run_url_rewrite_teardown "$case_dir")
  status=$?
  assert_present "$case_dir/relet-done" "control: the slot was never re-let during teardown"
  [ "$status" -ne 0 ] || fail "a slot re-let after its lease was confirmed must not be torn down"$'\n'"$out"
  assert_contains "$out" "lease changed" "teardown did not report the changed lease"
  assert_absent "$case_dir/run-touched" "a reassigned slot's run must not be queried or terminated"
  [ "$(wt_branch "$case_dir")" = fm/task-x1 ] || fail "the new holder's branch must stay checked out"
  [ "$(git -C "$slot" rev-parse HEAD)" = "$head" ] || fail "the new holder's head changed"
  git -C "$case_dir/project" rev-parse --verify -q refs/heads/fm/task-x1 >/dev/null \
    || fail "the new holder's branch must not be deleted"
  assert_present "$slot/.claude/settings.local.json" "the new holder's hooks must not be removed"
  assert_no_grep "return" "$case_dir/treehouse.log" "no return may be attempted"
  assert_present "$case_dir/state/task-x1.meta" "a refused teardown must keep the task record"
  pass "after a url rewrite, a slot re-let in its own pool after the lease check keeps the new holder's branch, head, and hooks"
}

test_work_written_after_initial_proof_survives_teardown() {
  local pool mode case_dir slot out status
  local TD_WT_REL=pool/1/repo
  for pool in current old old-unforced; do
    for mode in tracked untracked commit; do
      if [ "$pool" = current ]; then
        case_dir=$(make_teardown_case "td-late-$pool-$mode")
        write_teardown_meta "$case_dir" "lease_id=lease0123abcd"
        add_hook "$case_dir"
      else
        case_dir=$(url_rewrite_old_pool_case "td-late-$pool-$mode" lease0123abcd)
      fi
      slot="$case_dir/pool/1/repo"
      printf 'pushed\n' > "$slot/notes.txt"
      git -C "$slot" add notes.txt
      git -C "$slot" commit -qm notes
      git -C "$slot" push -q origin fm/task-x1
      cat > "$case_dir/fakebin/no-mistakes" <<SH
#!/usr/bin/env bash
[ ! -e "$case_dir/write-done" ] || exit 0
: > "$case_dir/write-done"
if [ "$pool" != current ]; then
  perl -e 'use Fcntl qw(:flock); open(my \$f, ">>", \$ARGV[0]) or exit 2; flock(\$f, LOCK_EX | LOCK_NB) and exit 1; exit 0' \
    "$case_dir/pool/treehouse-state.lock" || exit 1
  : > "$case_dir/pool-lock-held"
fi
case "$mode" in
  tracked) printf 'late work\n' >> "$slot/notes.txt" ;;
  untracked) printf 'late work\n' > "$slot/new-work.txt" ;;
  commit)
    printf 'late work\n' > "$slot/new-work.txt"
    git -C "$slot" add new-work.txt
    git -C "$slot" -c user.name=t -c user.email=t@t commit -qm 'late unlanded work' ;;
esac
exit 0
SH
      chmod +x "$case_dir/fakebin/no-mistakes"
      if [ "$pool" = current ]; then
        out=$(FM_FAKE_SLOT_LEASE=lease0123abcd run_teardown "$case_dir" --force)
      elif [ "$pool" = old ]; then
        out=$(FM_FAKE_SLOT_LEASE=lease0123abcd run_url_rewrite_teardown "$case_dir" --force)
      else
        out=$(FM_FAKE_SLOT_LEASE=lease0123abcd run_url_rewrite_teardown "$case_dir")
      fi
      status=$?
      [ "$status" -ne 0 ] || fail "$pool/$mode: late work must refuse teardown"$'\n'"$out"
      assert_present "$case_dir/write-done" "$pool/$mode: late writer never ran"
      [ "$pool" = current ] || assert_present "$case_dir/pool-lock-held" "$pool/$mode: run cleanup was not protected by the pool lock"
      if [ "$mode" = tracked ]; then
        assert_grep 'late work' "$slot/notes.txt" "$pool/$mode: tracked work was lost"
      else
        assert_grep 'late work' "$slot/new-work.txt" "$pool/$mode: new work was lost"
      fi
      [ "$(git -C "$slot" branch --show-current)" = fm/task-x1 ] || fail "$pool/$mode: branch was detached"
      assert_present "$slot/.claude/settings.local.json" "$pool/$mode: hooks were removed"
      assert_present "$case_dir/state/task-x1.meta" "$pool/$mode: task record was removed"
      assert_no_grep '^return ' "$case_dir/treehouse.log" "$pool/$mode: unsafe return was attempted"
    done
  done
  pass "late tracked, untracked, and unlanded work survives current and old pool cleanup"
}

test_forced_return_retry_rechecks_work() {
  local case_dir out status
  case_dir=$(make_teardown_case td-late-retry)
  write_teardown_meta "$case_dir" "lease_id=lease0123abcd"
  mv "$case_dir/fakebin/treehouse" "$case_dir/fakebin/treehouse-original"
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = return ]; then
  printf 'return attempt\n' >> "$case_dir/attempts"
  printf 'late work\n' > "$case_dir/wt/new-work.txt"
  echo "fatal: Unable to create '$case_dir/wt/.git/index.lock': File exists." >&2
  exit 1
fi
exec "$case_dir/fakebin/treehouse-original" "\$@"
SH
  chmod +x "$case_dir/fakebin/treehouse"
  out=$(FM_FAKE_SLOT_LEASE=lease0123abcd run_teardown "$case_dir" --force)
  status=$?
  [ "$status" -ne 0 ] || fail "a forced retry must refuse new work"$'\n'"$out"
  assert_contains "$out" 'uncommitted changes or untracked files' "retry did not recheck work"
  [ "$(wc -l < "$case_dir/attempts" | tr -d ' ')" = 1 ] || fail "return retried without proving late work safe"
  assert_grep 'late work' "$case_dir/wt/new-work.txt" "retry lost new work"
  assert_present "$case_dir/state/task-x1.meta" "refused retry lost the task record"
  pass "forced return retries recheck and preserve newly written work"
}

# HEAD is pushed, so no commit is at risk, but the copy holds uncommitted work:
#   tracked    a modified tracked file
#   untracked  a new untracked file
# --force on a leased slot must refuse rather than clean and reset it.
test_forced_return_refuses_uncommitted_work_in_a_leased_slot() {
  local mode case_dir out status
  for mode in tracked untracked; do
    case_dir=$(make_teardown_case "td-force-uncommitted-$mode")
    write_teardown_meta "$case_dir" "lease_id=lease0123abcd"
    add_hook "$case_dir"
    printf 'committed\n' > "$case_dir/wt/notes.txt"
    git -C "$case_dir/wt" add notes.txt
    git -C "$case_dir/wt" -c user.email=t@t -c user.name=t commit -q -m "pushed notes"
    git -C "$case_dir/wt" push -q origin fm/task-x1
    if [ "$mode" = tracked ]; then
      printf 'uncommitted edit\n' >> "$case_dir/wt/notes.txt"
    else
      printf 'new work\n' > "$case_dir/wt/new-work.txt"
    fi
    [ -z "$(git -C "$case_dir/wt" log --oneline HEAD --not --remotes --)" ] \
      || fail "$mode control: HEAD must already be on the remote"
    : > "$case_dir/treehouse.log"
    out=$(FM_FAKE_SLOT_LEASE=lease0123abcd run_teardown "$case_dir" --force)
    status=$?
    [ "$status" -ne 0 ] || fail "$mode: --force must not discard uncommitted work in a leased slot"$'\n'"$out"
    assert_contains "$out" "uncommitted changes or untracked files" "$mode: the refusal must name the uncommitted work"
    if [ "$mode" = tracked ]; then
      assert_grep "uncommitted edit" "$case_dir/wt/notes.txt" "$mode: the tracked edit was discarded"
    else
      assert_present "$case_dir/wt/new-work.txt" "$mode: the untracked file was discarded"
      assert_contains "$out" "new-work.txt" "$mode: the refusal must list the untracked file"
    fi
    [ "$(wt_branch "$case_dir")" = fm/task-x1 ] || fail "$mode: the branch must stay checked out"
    assert_present "$case_dir/wt/.claude/settings.local.json" "$mode: the worker's hooks must survive a refused teardown"
    assert_present "$case_dir/state/task-x1.meta" "$mode: a refused teardown must keep the task record"
    assert_no_grep "return" "$case_dir/treehouse.log" "$mode: no return may be attempted"
  done
  pass "--force never cleans or resets a leased slot's uncommitted tracked or untracked work, even with HEAD pushed"
}

# The old pool's own state confirms the lease, and the copy's only uncommitted
# content is arbitrary work under .claude/ beside the generated hook file. No
# bundle holds it, so the own-pool backup check must refuse, forced or not.
test_url_rewrite_old_pool_refuses_untracked_claude_work() {
  local mode case_dir out status slot
  local TD_WT_REL=pool/1/repo
  local -a force
  for mode in unforced forced; do
    case_dir=$(url_rewrite_old_pool_case "td-rewrite-claude-$mode" lease0123abcd)
    slot="$case_dir/pool/1/repo"
    printf 'agent notes\n' > "$slot/.claude/notes.md"
    force=()
    [ "$mode" = unforced ] || force=(--force)
    : > "$case_dir/treehouse.log"
    out=$(FM_FAKE_SLOT_LEASE=lease0123abcd run_url_rewrite_teardown "$case_dir" ${force[@]+"${force[@]}"})
    status=$?
    [ "$status" -ne 0 ] || fail "$mode: untracked .claude/ work must refuse teardown"$'\n'"$out"
    assert_contains "$out" "has uncommitted changes" "$mode: the refusal must name the uncommitted work"
    assert_contains "$out" ".claude/notes.md" "$mode: the refusal must list the .claude/ file"
    assert_not_contains "$out" "settings.local.json" "$mode: the generated hook file must stay exempt"
    assert_present "$slot/.claude/notes.md" "$mode: the .claude/ work was discarded"
    [ "$(git -C "$slot" rev-parse --abbrev-ref HEAD)" = fm/task-x1 ] || fail "$mode: the branch must stay checked out"
    assert_present "$case_dir/state/task-x1.meta" "$mode: a refused teardown must keep the task record"
    assert_no_grep "return" "$case_dir/treehouse.log" "$mode: no return may be attempted"
  done
  pass "after a url rewrite, untracked .claude/ work in an old-pool slot refuses teardown, forced or not, while the hook file stays exempt"
}

# A slot allocation or another return holds the shared project lock briefly, so
# teardown waits a bounded 120s for a live holder before refusing as it always
# has. The holder is a separate live process: a dead holder's lock is reclaimed
# at once and would never exercise the wait.
#   released  the holder lets go a few seconds in, so teardown proceeds
#   held      the holder outlives the bound, so teardown refuses unchanged
test_held_project_lock_is_waited_out_within_the_bound() {
  local mode case_dir out status lock holder start elapsed n
  local TD_WT_REL=pool/1/repo
  for mode in released held; do
    case_dir=$(make_teardown_case "td-project-lock-$mode")
    : > "$case_dir/pool/treehouse-state.json"
    write_teardown_meta "$case_dir" "lease_id=lease0123abcd"
    lock=$(FM_HOME="$case_dir" bash -c '. "$1"; fm_treehouse_project_lock_path "$2"' _ \
      "$ROOT/bin/fm-wake-lib.sh" "$case_dir/project") || fail "$mode: could not resolve the project lock"
    FM_HOME="$case_dir" bash -c '
      . "$1"
      fm_lock_try_acquire "$2" || exit 1
      sleep "$3"
      fm_lock_release "$2"
    ' _ "$ROOT/bin/fm-wake-lib.sh" "$lock" "$([ "$mode" = released ] && echo 4 || echo 300)" >/dev/null 2>&1 &
    holder=$!
    n=0
    until [ -e "$lock" ]; do
      n=$((n + 1))
      [ "$n" -lt 100 ] || fail "$mode: the holder never took the project lock"
      sleep 0.1
    done
    start=$SECONDS
    out=$(TD_BOUND=200 FM_HOME="$case_dir" FM_FAKE_SLOT_LEASE=lease0123abcd run_teardown "$case_dir")
    status=$?
    elapsed=$((SECONDS - start))
    [ "$status" -ne 124 ] || fail "$mode: teardown was still waiting at the 200s hard bound"$'\n'"$out"
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    assert_contains "$out" "waiting up to 120s" "$mode: teardown did not wait for the live holder"
    if [ "$mode" = released ]; then
      expect_code 0 "$status" "$mode: teardown should proceed once the holder lets go"$'\n'"$out"
      [ "$elapsed" -ge 2 ] || fail "$mode: teardown finished in ${elapsed}s, before the holder let go"
      [ "$elapsed" -le 30 ] || fail "$mode: teardown took ${elapsed}s after a holder that let go at 4s"
      assert_grep "return --if-lease-id lease0123abcd" "$case_dir/treehouse.log" "$mode: the slot was not returned"
      assert_absent "$case_dir/state/task-x1.meta" "$mode: a returned task keeps no live record"
    else
      expect_code 1 "$status" "$mode: teardown must refuse once the bound expires"$'\n'"$out"
      [ "$elapsed" -ge 118 ] || fail "$mode: teardown refused after ${elapsed}s, before the 120s bound"
      [ "$elapsed" -le 150 ] || fail "$mode: teardown refused after ${elapsed}s, well past the 120s bound"
      assert_contains "$out" "REFUSED: another Treehouse slot allocation or return is in progress for $case_dir/project; nothing was changed" \
        "$mode: the refusal text changed"
      assert_present "$case_dir/state/task-x1.meta" "$mode: a refused teardown must keep the task record"
      [ "$(wt_branch "$case_dir")" = fm/task-x1 ] || fail "$mode: the branch must stay checked out"
      [ ! -s "$case_dir/treehouse.log" ] || fail "$mode: no treehouse call may run without the lock: $(cat "$case_dir/treehouse.log")"
    fi
  done
  pass "teardown waits out a live project-lock holder for up to 120s, then refuses exactly as before"
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
    # Only a scout's copy is declared scratch: a forced ship return refuses real
    # untracked work (test_forced_return_refuses_uncommitted_work_in_a_leased_slot),
    # so its dirt here is only what the fake treehouse reports.
    [ "$mode" != scout ] || printf 'scratch\n' > "$case_dir/wt/scratch.txt"
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

# The current pool lists the slot under its matching lease, so this is the
# ordinary path, where --force skips the landed-work check.
test_forced_return_refuses_unlanded_commits_in_a_current_pool_slot() {
  local case_dir out status head
  case_dir=$(make_teardown_case td-force-unlanded)
  write_teardown_meta "$case_dir" "lease_id=lease0123abcd"
  add_hook "$case_dir"
  # Real content, so no landed-content fallback can count it as already on main.
  printf 'lane work\n' > "$case_dir/wt/lane-work.txt"
  git -C "$case_dir/wt" add lane-work.txt
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t commit -q -m "unpushed lane work"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  out=$(FM_FAKE_SLOT_LEASE=lease0123abcd run_teardown "$case_dir" --force)
  status=$?
  [ "$status" -ne 0 ] || fail "--force must not return a current-pool slot holding unlanded commits"$'\n'"$out"
  assert_contains "$out" "has work not on any remote and not landed" "the refusal must name the unlanded work"
  assert_contains "$out" "unpushed lane work" "the refusal must list the unpushed commit"
  assert_present "$case_dir/state/task-x1.meta" "a refused teardown must keep the task record"
  [ -d "$case_dir/wt" ] || fail "the copy must stay in place"
  [ "$(wt_branch "$case_dir")" = fm/task-x1 ] || fail "the branch must stay checked out"
  [ "$(git -C "$case_dir/wt" rev-parse HEAD)" = "$head" ] || fail "the copy head changed"
  git -C "$case_dir/project" rev-parse --verify -q refs/heads/fm/task-x1 >/dev/null \
    || fail "the task branch must survive a refused teardown"
  assert_present "$case_dir/wt/.claude/settings.local.json" "the worker's hooks must survive a refused teardown"
  assert_no_grep "return" "$case_dir/treehouse.log" "no return may be attempted"
  pass "--force never returns a current-pool leased slot holding unlanded commits"
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
  local case_dir=$1 slot_n=$2 why=$3 got
  [ "$(slot_head "$case_dir" "$slot_n")" = detached ] || fail "$why: slot $slot_n still holds a branch"
  (
    . "$ROOT/bin/fm-wake-lib.sh"
    FM_HOME="$case_dir/home"
    fm_treehouse_slot_claim_custody "$case_dir/pool/$slot_n/repo" next-task
    [ "$FM_TREEHOUSE_SLOT_CLAIM" = free ]
  ) || fail "$why: slot $slot_n is still claimed"
  got=$(pool_cmd "$case_dir" treehouse get --lease --json) || fail "$why: treehouse could not lease the slot"$'\n'"$got"
  assert_contains "$got" "$case_dir/pool/$slot_n/repo" "$why: the lease did not hand out slot $slot_n"
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
  # A durable lease the caller cannot name is somebody's: refused, nothing touched.
  printf 'leased lease-other\n' > "$case_dir/pool/1/.fake-state"
  out=$(pool_cmd "$case_dir" "$SLOT_RELEASE" "$case_dir/pool/1/repo/")
  case "$out" in failed*) ;; *) false ;; esac || fail "a slot under a foreign lease must not be retired by path, got: $out"
  [ "$(slot_head "$case_dir" 1)" = fm/task-p1 ] || fail "a foreign-leased slot must keep its branch checked out"
  printf 'leased lease-p1\n' > "$case_dir/pool/1/.fake-state"
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
test_absent_pool_listing_completes_records_only_after_backup
test_url_rewrite_keeps_old_and_new_pool_slots_tearing_down
test_url_rewrite_never_overrides_unlanded_work_or_the_current_pool
test_url_rewrite_old_pool_relet_after_confirmation_leaves_the_new_holder_alone
test_url_rewrite_old_pool_refuses_untracked_claude_work
test_work_written_after_initial_proof_survives_teardown
test_forced_return_retry_rechecks_work
test_held_project_lock_is_waited_out_within_the_bound
test_dirty_slot_return_is_refused_not_forced
test_forced_and_scout_teardowns_force_the_lease_bound_return
test_forced_return_refuses_unlanded_commits_in_a_current_pool_slot
test_forced_return_refuses_uncommitted_work_in_a_leased_slot
test_forced_return_refused_by_a_lease_change_is_reported_as_such
test_teardown_refuses_a_malformed_lease_id

echo "# all fm-treehouse-lease tests passed"
