#!/usr/bin/env bash
# Behavior tests for session-start cost on a large home.
#
# The defect these pin: a home carrying hundreds of task records stalled
# bin/fm-bootstrap.sh's backlog reconcile (one `tasks-axi show` and several
# path-resolution spawns per record), and bin/fm-fleet-snapshot.sh passed whole
# JSON documents through argv, which fails outright once a document outgrows the
# kernel's argument limit. Session start cost must not grow with one subprocess
# per record, and a snapshot must fail rather than silently drop a record.
#
# The spawn counts come from counting shims on PATH, so they measure real
# process executions rather than reading the source.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset TASKS_AXI_BACKEND || :
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

BOOTSTRAP="$ROOT/bin/fm-bootstrap.sh"
SNAPSHOT="$ROOT/bin/fm-fleet-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-session-start-scale)
trap fm_test_cleanup EXIT

SMALL=20
LARGE=400
# Generous: the point is "not minutes", never a tight timing assertion.
WALL_BOUND=120
# Spawns that may differ between the small and large home. Everything per-record
# would show up as roughly (LARGE - SMALL) times its per-record cost, so this
# slack only has to cover the handful of heals and the one batched read.
SPAWN_SLACK=60

# Shims that count every execution of the tools a per-record loop would spawn.
COUNTED_TOOLS="tasks-axi perl jq cat sed awk grep head tail cut tr ln rm mv cp mkdir basename dirname date ps wc sort find"

make_counting_fakebin() {  # <case-dir>
  local case_dir=$1 fakebin tool real
  fakebin=$(fm_fakebin "$case_dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;; esac
case "${1:-}" in display-message) printf 'firstmate\n'; exit 0 ;; esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh gh-axi no-mistakes
  for tool in $COUNTED_TOOLS; do
    real=$(command -v "$tool" 2>/dev/null) || continue
    case "$real" in "$fakebin"/*) continue ;; esac
    cat > "$fakebin/$tool" <<SH
#!/usr/bin/env bash
printf '%s\\n' "$tool" >> "$case_dir/spawns.log"
exec "$real" "\$@"
SH
    chmod +x "$fakebin/$tool"
  done
}

# A home with <metas> task records and a backlog far larger than session start
# should ever read row by row. Three records are queued rows this home already
# owns (healable), one is a captain-held queued row (must be left alone), and the
# rest are in-flight rows, so the reconcile has real work and real no-ops.
make_home() {  # <name> <metas> <done-rows>
  local name=$1 metas=$2 done_rows=$3 case_dir home i id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  mkdir -p "$home/state" "$home/config" "$home/data" "$home/projects"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' claude > "$home/config/crew-harness"
  cat > "$home/.tasks.toml" <<'EOF'
backend = "markdown"

[markdown]
path = "data/backlog.md"
EOF
  {
    printf '# Backlog\n\n## In flight\n'
    i=0
    while [ "$i" -lt "$metas" ]; do
      i=$((i + 1))
      printf -- '- [ ] task-%04d - in flight item %s, with a comma and a long enough title to resemble a real row (kind: ship) (since 2026-10-03)\n' "$i" "$i"
    done
    printf '\n## Queued\n'
    for id in heal-a heal-b heal-c; do
      printf -- '- [ ] %s - queued row this home already owns (kind: ship) (since 2026-10-03)\n' "$id"
    done
    printf -- '- [ ] held-one - queued but held for the captain (kind: ship) (since 2026-10-03) (hold: waiting) (hold-kind: captain)\n'
    printf '\n## Done\n'
    i=0
    while [ "$i" -lt "$done_rows" ]; do
      i=$((i + 1))
      printf -- '- [x] done-%05d - finished work with a deliberately long title so the backlog file grows large enough to matter (kind: ship) (done 2026-09-01)\n' "$i"
    done
  } > "$home/data/backlog.md"
  i=0
  while [ "$i" -lt "$metas" ]; do
    i=$((i + 1))
    id=$(printf 'task-%04d' "$i")
    fm_write_meta "$home/state/$id.meta" \
      "window=firstmate:fm-$id" "worktree=/nonexistent/$id" "project=alpha" \
      "harness=claude" "mode=no-mistakes" "yolo=off"
  done
  for id in heal-a heal-b heal-c held-one; do
    fm_write_meta "$home/state/$id.meta" \
      "window=firstmate:fm-$id" "worktree=/nonexistent/$id" "project=alpha" \
      "harness=claude" "mode=no-mistakes" "yolo=off"
  done
  make_counting_fakebin "$case_dir"
  : > "$case_dir/spawns.log"
  printf '%s\n' "$case_dir"
}

home_of() { printf '%s/home\n' "$1"; }

row_state() {  # <case-dir> <id>
  tasks-axi show "$2" --file "$(home_of "$1")/data/backlog.md" 2>/dev/null |
    sed -n 's/^  state: *//p' | head -1
}

spawn_count() {  # <case-dir> [tool]
  if [ -n "${2:-}" ]; then
    grep -cx "$2" "$1/spawns.log" || true
  else
    wc -l < "$1/spawns.log" | tr -d ' '
  fi
}

run_bootstrap() {  # <case-dir>
  local case_dir=$1
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$(home_of "$case_dir")" \
    FM_BOOTSTRAP_NETWORK=skip \
    PATH="$case_dir/fakebin:$PATH" \
    "$BOOTSTRAP" 2>&1
}

now() { date +%s; }

# --- bootstrap: cost is flat in the number of records -----------------------

SMALL_CASE=$(make_home small "$SMALL" 50)
LARGE_CASE=$(make_home large "$LARGE" 1500)
BACKLOG_BYTES=$(wc -c < "$(home_of "$LARGE_CASE")/data/backlog.md" | tr -d ' ')
[ "$BACKLOG_BYTES" -gt 150000 ] || fail "the synthetic backlog is too small to stand in for a large home: ${BACKLOG_BYTES} bytes"

START=$(now)
SMALL_OUT=$(run_bootstrap "$SMALL_CASE") || fail "bootstrap failed on the small home: $SMALL_OUT"
SMALL_SPAWNS=$(spawn_count "$SMALL_CASE")
START=$(now)
LARGE_OUT=$(run_bootstrap "$LARGE_CASE") || fail "bootstrap failed on the large home: $LARGE_OUT"
LARGE_ELAPSED=$(( $(now) - START ))
LARGE_SPAWNS=$(spawn_count "$LARGE_CASE")

[ "$LARGE_ELAPSED" -lt "$WALL_BOUND" ] \
  || fail "bootstrap took ${LARGE_ELAPSED}s on a $LARGE-record home (bound ${WALL_BOUND}s)"
pass "bootstrap finishes a $LARGE-record home with a ${BACKLOG_BYTES}-byte backlog in ${LARGE_ELAPSED}s"

EXTRA=$((LARGE_SPAWNS - SMALL_SPAWNS))
[ "$EXTRA" -le "$SPAWN_SLACK" ] \
  || fail "bootstrap spawned $EXTRA more processes for $((LARGE - SMALL)) more records ($SMALL_SPAWNS -> $LARGE_SPAWNS): cost grows per record"$'\n'"$(sort "$LARGE_CASE/spawns.log" | uniq -c | sort -rn | head -8)"
pass "bootstrap spawns $SMALL_SPAWNS processes at $SMALL records and $LARGE_SPAWNS at $LARGE: no per-record spawn cost"

# The old sweep read every record with its own `tasks-axi show`; the batched
# sweep reads the queue once and only re-reads a record it is about to heal.
LARGE_SHOWS=$(spawn_count "$LARGE_CASE" tasks-axi)
[ "$LARGE_SHOWS" -le 20 ] \
  || fail "bootstrap ran tasks-axi $LARGE_SHOWS times on a $LARGE-record home"
pass "bootstrap runs tasks-axi $LARGE_SHOWS times for $LARGE records (one batched read plus the heals)"

for CASE in "$SMALL_CASE" "$LARGE_CASE"; do
  for ID in heal-a heal-b heal-c; do
    [ "$(row_state "$CASE" "$ID")" = in_flight ] \
      || fail "the queued row for owned record $ID was not healed in $CASE: $LARGE_OUT"
  done
  [ "$(row_state "$CASE" held-one)" = queued ] \
    || fail "a captain-held row was moved by the sweep in $CASE"
  [ "$(row_state "$CASE" task-0001)" = in_flight ] \
    || fail "an in-flight row changed in $CASE"
done
assert_contains "$LARGE_OUT" "marked heal-a in flight" "the heal was not reported"
pass "the sweep still heals exactly the queued, unheld rows a home owns and leaves held rows alone"

# --- bootstrap: the wall-clock budget skips and says so ---------------------

BUDGET_CASE=$(make_home budget 40 20)
REAL_TASKS_AXI=$(command -v tasks-axi)
# Heals are slow on this backend, so the budget runs out after the first one.
cat > "$BUDGET_CASE/fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = show ]; then sleep 2; fi
exec "$REAL_TASKS_AXI" "\$@"
SH
chmod +x "$BUDGET_CASE/fakebin/tasks-axi"
BUDGET_OUT=$(FM_BOOTSTRAP_RECONCILE_BUDGET_SECS=1 run_bootstrap "$BUDGET_CASE") \
  || fail "bootstrap failed instead of reporting a skipped sweep: $BUDGET_OUT"
assert_contains "$BUDGET_OUT" "BACKLOG_RECONCILE: sweep budget of 1s exhausted" \
  "an exhausted sweep budget was not reported"
[ "$(row_state "$BUDGET_CASE" heal-c)" = queued ] \
  || fail "the sweep kept healing after its budget ran out"
pass "an exhausted sweep budget stops the reconcile and reports how many records it skipped"

# --- bootstrap: an unreadable backlog names every owned record, once --------

FAIL_CASE=$(make_home unreadable 30 10)
cat > "$FAIL_CASE/fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
printf 'tasks-axi %s\n' "\$1" >> "$FAIL_CASE/axi-verbs.log"
case "\${1:-}" in
  list) echo 'error: "backlog exploded"' >&2; exit 1 ;;
esac
exec "$REAL_TASKS_AXI" "\$@"
SH
chmod +x "$FAIL_CASE/fakebin/tasks-axi"
FAIL_OUT=$(run_bootstrap "$FAIL_CASE") || fail "bootstrap aborted on an unreadable backlog: $FAIL_OUT"
assert_contains "$FAIL_OUT" "BACKLOG_RECONCILE: task-0001: worker record exists but its backlog item could not be read: error: \"backlog exploded\"" \
  "an unreadable backlog did not name the owned record and the backend's reason"
assert_contains "$FAIL_OUT" "BACKLOG_RECONCILE: heal-a: worker record exists but its backlog item could not be read" \
  "an unreadable backlog skipped a record"
if grep -q '^tasks-axi show$' "$FAIL_CASE/axi-verbs.log"; then
  fail "an unreadable backlog fell back to one tasks-axi show per record"
fi
pass "an unreadable backlog is reported per owned record from one failed read, with no per-record fallback"

# --- bootstrap: unsafe records are still refused ----------------------------

# Records are swept in name order, so a refusal stops the sweep at that record:
# a symlink that sorts first heals nothing, and one sorting later still refuses.
for UNSAFE_ID in aaa-unsafe task-0015; do
  UNSAFE_CASE=$(make_home "unsafe-$UNSAFE_ID" 30 10)
  UNSAFE_HOME=$(home_of "$UNSAFE_CASE")
  rm -f "$UNSAFE_HOME/state/$UNSAFE_ID.meta"
  : > "$UNSAFE_CASE/elsewhere.meta"
  ln -s "$UNSAFE_CASE/elsewhere.meta" "$UNSAFE_HOME/state/$UNSAFE_ID.meta"
  UNSAFE_OUT=$(run_bootstrap "$UNSAFE_CASE") || true
  # A record sorting first is refused by the earlier gate check, a later one by
  # the sweep itself; both refuse and say so.
  case "$UNSAFE_OUT" in
    *"refused unsafe worker record"*|*"unsafe worker record refused"*) ;;
    *) fail "a symlinked worker record ($UNSAFE_ID) was not refused: $UNSAFE_OUT" ;;
  esac
  if [ "$UNSAFE_ID" = aaa-unsafe ]; then
    [ "$(row_state "$UNSAFE_CASE" heal-a)" = queued ] \
      || fail "the sweep healed past a record it had refused as unsafe"
  fi
done
pass "a symlinked worker record is still refused, stopping the sweep at that record"

# --- snapshot: large documents never ride argv ------------------------------

SNAP_CASE=$(make_home snapshot 400 4000)
SNAP_HOME=$(home_of "$SNAP_CASE")
SNAP_BACKLOG_BYTES=$(wc -c < "$SNAP_HOME/data/backlog.md" | tr -d ' ')

run_snapshot() {  # <case-dir> <mode> [fakebin-override]
  local case_dir=$1 mode=$2 fakebin=${3:-$1/fakebin}
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$(home_of "$case_dir")" \
    PATH="$fakebin:$PATH" "$SNAPSHOT" "$mode"
}

# The home-local contribution poll's input is the whole backlog plus the whole
# task set. The synthetic backlog parses to a JSON document well past a
# megabyte, which the old argv transport could not exec.
SNAP_START=$(now)
SNAP_OUT="$SNAP_CASE/contribution-input.json"
run_snapshot "$SNAP_CASE" --contribution-input > "$SNAP_OUT" 2> "$SNAP_CASE/contribution-input.err" \
  || fail "contribution input failed on a ${SNAP_BACKLOG_BYTES}-byte backlog: $(cat "$SNAP_CASE/contribution-input.err")"
SNAP_ELAPSED=$(( $(now) - SNAP_START ))
SNAP_JSON_BYTES=$(wc -c < "$SNAP_OUT" | tr -d ' ')
[ "$SNAP_JSON_BYTES" -gt 1048576 ] || fail "the synthetic document did not outgrow the argv limit (${SNAP_JSON_BYTES} bytes)"
[ "$SNAP_ELAPSED" -lt "$WALL_BOUND" ] || fail "contribution input took ${SNAP_ELAPSED}s (bound ${WALL_BOUND}s)"
jq -e --argjson rows 4404 --argjson tasks 404 \
  '(.backlog.records | length) == $rows and (.tasks | length) == $tasks' "$SNAP_OUT" >/dev/null \
  || fail "contribution input dropped records: $(jq -c '[(.backlog.records | length), (.tasks | length)]' "$SNAP_OUT")"
pass "contribution input carries a ${SNAP_JSON_BYTES}-byte document with every record in ${SNAP_ELAPSED}s"

# Counted spawns for the contribution read: a constant number for the whole
# document (backlog parse, task rows, authority), not one per record.
SNAP_SPAWNS=$(spawn_count "$SNAP_CASE")
[ "$SNAP_SPAWNS" -le 100 ] \
  || fail "contribution input spawned $SNAP_SPAWNS processes for 404 records"
pass "contribution input spawns $SNAP_SPAWNS processes for 404 records"

# --- snapshot: a dropped record fails the snapshot --------------------------

POISON_CASE=$(make_home poison 6 5)
POISON_REAL_JQ=$(command -v jq)
# The per-task record builder is the one jq call that names a task id; the
# contribution document is the one that slurps raw field rows (-R -s). Either
# failing must fail the snapshot, never shrink it.
cat > "$POISON_CASE/fakebin/jq" <<SH
#!/usr/bin/env bash
case "\$*" in
  *"--arg id task-0003 "*) echo "jq: simulated failure on task-0003" >&2; exit 5 ;;
esac
if [ "\${1:-}" = -R ] && [ "\${2:-}" = -s ] && [ -n "\${POISON_CONTRIBUTION:-}" ]; then
  echo "jq: simulated failure on the contribution rows" >&2
  exit 5
fi
exec "$POISON_REAL_JQ" "\$@"
SH
chmod +x "$POISON_CASE/fakebin/jq"
for MODE in --contribution-input --json; do
  POISON_RC=0
  POISON_CONTRIBUTION=1 run_snapshot "$POISON_CASE" "$MODE" > "$POISON_CASE/poison.out" 2> "$POISON_CASE/poison.err" || POISON_RC=$?
  [ "$POISON_RC" -ne 0 ] \
    || fail "$MODE succeeded although a record could not be built: $(head -c 300 "$POISON_CASE/poison.out")"
  [ ! -s "$POISON_CASE/poison.out" ] \
    || fail "$MODE emitted a partial snapshot after a dropped record"
done
pass "a record that cannot be built fails the snapshot instead of being dropped from it"

echo "# fm-session-start-scale.test.sh: all assertions passed"
