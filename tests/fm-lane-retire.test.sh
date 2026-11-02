#!/usr/bin/env bash
# Behavioral tests for bin/fm-lane-retire.sh: a merged or closed PR retires its
# lane, an open one is untouched, and no verified bundle means no retirement.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-lane-retire.sh"
TMP_ROOT=$(fm_test_tmproot fm-lane-retire)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
fm_git_identity

# The fake gh answers `pr view <url> --json state --jq .state` from the PR number.
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
case "$3" in
  */pull/1) echo MERGED ;;
  */pull/2) echo CLOSED ;;
  */pull/3) echo OPEN ;;
  */pull/4) cat "$FM_TEST_PR4_FILE" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$FAKEBIN/gh"

# The fake teardown records its arguments and removes the record, as the real one does.
cat > "$TMP_ROOT/teardown" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$FM_TEST_TEARDOWN_LOG"
rm -f "$FM_HOME/state/$1.meta"
SH
chmod +x "$TMP_ROOT/teardown"

new_home() {  # <name> -> prints the home dir
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

# add_lane <home> <id> <pr-number> [commits]: a ship lane worktree with <commits> local commits.
add_lane() {
  local home=$1 id=$2 pr=$3 commits=${4:-1} repo="$1/proj-$2" wt="$1/wt-$2" i
  fm_git_worktree "$repo" "$wt" "fm/$id"
  git -C "$wt" fetch -q origin
  git -C "$wt" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  for ((i = 0; i < commits; i++)); do
    echo "$i" > "$wt/f$i"
    git -C "$wt" add "f$i"
    git -C "$wt" commit -qm "c$i"
  done
  fm_write_meta "$home/state/$id.meta" kind=ship "worktree=$wt" "project=$repo" "branch=fm/$id" \
    "pr=https://github.com/o/r/pull/$pr"
}

run_pass() {  # <home> [args]
  local home=$1
  shift
  FM_HOME=$home FM_TEST_TEARDOWN_LOG="$home/teardown.log" FM_LANE_RETIRE_TEARDOWN="$TMP_ROOT/teardown" FM_TEST_PR4_FILE="$home/pr4" \
    PATH="$FAKEBIN:$PATH" "$SCRIPT" "$@"
}

# merged -> retired, bundle verified first, plain teardown
H=$(new_home merged)
add_lane "$H" lane-m 1
out=$(run_pass "$H") || fail "merged pass exited non-zero"
assert_contains "$out" "retire lane-m" "contains: out retire lane-m"
assert_equals "lane-m" "$(cat "$H/teardown.log")" "merged lane tears down without --force"
git -C "$H/wt-lane-m" bundle verify -q "$H/data/bundles/lane-m.bundle" >/dev/null 2>&1 || fail "merged lane bundle did not verify"
assert_grep "retire lane-m" "$H/data/lane-retire.log" "grep: retire lane-m H/data/lane-retire.log"
pass "merged PR retires its lane after a verified bundle"

# closed -> retired with --force after the bundle
H=$(new_home closed)
add_lane "$H" lane-c 2
run_pass "$H" >/dev/null || fail "closed pass exited non-zero"
assert_equals "lane-c --force" "$(cat "$H/teardown.log")" "closed lane tears down with --force"
assert_present "$H/data/bundles/lane-c.bundle" "present: H/data/bundles/lane-c.bundle"
pass "closed PR retires its lane after a verified bundle"

# open -> untouched
H=$(new_home open)
add_lane "$H" lane-o 3
run_pass "$H" >/dev/null || fail "open pass exited non-zero"
assert_absent "$H/teardown.log" "absent: H/teardown.log"
assert_present "$H/state/lane-o.meta" "present: H/state/lane-o.meta"
assert_absent "$H/data/bundles/lane-o.bundle" "absent: H/data/bundles/lane-o.bundle"
pass "open PR leaves its lane untouched"

# bundle missing (bundle directory cannot be created) -> refused, record kept
H=$(new_home nobundle)
add_lane "$H" lane-b 1
: > "$H/data/bundles"
out=$(run_pass "$H") || fail "bundle-missing pass exited non-zero"
assert_contains "$out" "refuse lane-b" "contains: out refuse lane-b"
assert_contains "$out" "no verified bundle" "contains: out no verified bundle"
assert_absent "$H/teardown.log" "absent: H/teardown.log"
assert_present "$H/state/lane-b.meta" "present: H/state/lane-b.meta"
pass "no verified bundle refuses retirement"

# dirty worktree -> refused
H=$(new_home dirty)
add_lane "$H" lane-d 1
echo x > "$H/wt-lane-d/untracked"
out=$(run_pass "$H") || fail "dirty pass exited non-zero"
assert_contains "$out" "uncommitted changes" "contains: out uncommitted changes"
assert_absent "$H/teardown.log" "absent: H/teardown.log"
pass "dirty worktree refuses retirement"

# kill switch -> nothing read
H=$(new_home killed)
add_lane "$H" lane-k 1
touch "$H/config/lane-retire.off"
out=$(run_pass "$H") || fail "killed pass exited non-zero"
assert_equals "" "$out"
assert_absent "$H/teardown.log" "absent: H/teardown.log"
assert_present "$H/state/lane-k.meta" "present: H/state/lane-k.meta"
pass "kill switch stops the pass"

# dry run -> reports, changes nothing
H=$(new_home dry)
add_lane "$H" lane-y 1
out=$(run_pass "$H" --dry-run) || fail "dry pass exited non-zero"
assert_contains "$out" "would-retire lane-y" "contains: out would-retire lane-y"
assert_absent "$H/teardown.log" "absent: H/teardown.log"
assert_absent "$H/data/lane-retire.log" "absent: H/data/lane-retire.log"
pass "dry run reports without acting"

# dry run takes no bundle
assert_absent "$H/data/bundles/lane-y.bundle" "dry run wrote a bundle"

# log unwritable -> refused before any teardown
H=$(new_home nolog)
add_lane "$H" lane-l 1
: > "$H/data/lane-retire.log"
chmod 444 "$H/data/lane-retire.log"
run_pass "$H" >/dev/null 2>&1 || fail "nolog pass exited non-zero"
if [ -w "$H/data/lane-retire.log" ]; then
  echo "skip - log stays writable (running as root)"
else
  assert_absent "$H/teardown.log" "retired without an audit record"
  assert_present "$H/state/lane-l.meta" "record removed without an audit record"
fi
pass "unwritable log refuses retirement"

# PR reopened between inspection and teardown -> aborted, record kept
cat > "$TMP_ROOT/hook-reopen" <<'SH'
#!/usr/bin/env bash
echo OPEN > "$FM_HOME/pr4"
SH
chmod +x "$TMP_ROOT/hook-reopen"
H=$(new_home reopen)
add_lane "$H" lane-r 4
echo CLOSED > "$H/pr4"
out=$(FM_LANE_RETIRE_PRE_TEARDOWN_HOOK="$TMP_ROOT/hook-reopen" run_pass "$H") || fail "reopen pass exited non-zero"
assert_contains "$out" "abort lane-r" "reopened PR must abort"
assert_contains "$out" "PR state changed" "reopened PR reason"
assert_absent "$H/teardown.log" "reopened PR was torn down"
assert_present "$H/state/lane-r.meta" "reopened PR record removed"
pass "reopened PR aborts retirement"

# head moves between inspection and teardown -> aborted, record kept
cat > "$TMP_ROOT/hook-move" <<'SH'
#!/usr/bin/env bash
wt=$(sed -n 's/^worktree=//p' "$FM_HOME/state/$1.meta")
echo late > "$wt/late"
git -C "$wt" add late
git -C "$wt" commit -qm late
SH
chmod +x "$TMP_ROOT/hook-move"
H=$(new_home moved)
add_lane "$H" lane-h 1
out=$(FM_LANE_RETIRE_PRE_TEARDOWN_HOOK="$TMP_ROOT/hook-move" run_pass "$H") || fail "moved pass exited non-zero"
assert_contains "$out" "abort lane-h" "moved head must abort"
assert_absent "$H/teardown.log" "moved head was torn down"
assert_present "$H/state/lane-h.meta" "moved head record removed"
pass "moved head aborts retirement"

# Landing calls teardown: after the proven fast-forward, bin/fm-merge-local.sh runs a
# plain teardown only under config/lane-close-live, and a refusal never fails the merge.
merge_local_lane() {  # <home> <id>: a local-only lane whose branch fast-forwards main
  local home=$1 id=$2 repo="$1/proj-$2" wt="$1/wt-$2"
  fm_git_worktree "$repo" "$wt" "fm/$id"
  echo landed > "$wt/landed"
  git -C "$wt" add landed
  git -C "$wt" commit -qm landed
  fm_write_meta "$home/state/$id.meta" kind=ship "worktree=$wt" "project=$repo" "branch=fm/$id" mode=local-only
}

run_merge_local() {  # <home> <id> [teardown]
  FM_HOME=$1 FM_STATE_OVERRIDE="$1/state" FM_CONFIG_OVERRIDE="$1/config" FM_TEST_SEAM=1 \
    FM_LANE_CLOSE_TEARDOWN="${3:-$TMP_ROOT/teardown}" FM_TEST_TEARDOWN_LOG="$1/teardown.log" \
    PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-merge-local.sh" "$2"
}

H=$(new_home merge-local-off)
merge_local_lane "$H" lane-a
out=$(run_merge_local "$H" lane-a 2>&1) || fail "local merge failed with closing off: $out"
assert_contains "$out" "merged fm/lane-a into local main" "merge reported"
assert_contains "$out" "lane close: dry-run, would tear down lane-a" "dry-run names the teardown"
assert_absent "$H/teardown.log" "teardown ran without config/lane-close-live"
pass "local merge with closing off reports the teardown it would run"

H=$(new_home merge-local-on)
: > "$H/config/lane-close-live"
merge_local_lane "$H" lane-b
out=$(run_merge_local "$H" lane-b 2>&1) || fail "local merge failed with closing on: $out"
assert_contains "$out" "lane close: tore down lane-b after the merge" "teardown reported"
assert_equals "lane-b" "$(cat "$H/teardown.log")" "merge runs a plain teardown, no --force"
for bundle in "$H/data/bundles/"*.bundle; do
  git clone -q "$bundle" "$H/restored" 2>/dev/null || fail "local-only merge bundle cannot restore independently"
done
assert_equals "$(git -C "$H/wt-lane-b" rev-parse HEAD)" "$(git -C "$H/restored" rev-parse HEAD)" "local-only merged head preserved"
pass "local merge runs a plain teardown right after the proven fast-forward"

H=$(new_home merge-local-preserve-fails)
: > "$H/config/lane-close-live"
merge_local_lane "$H" lane-f
: > "$H/data/bundles"
out=$(run_merge_local "$H" lane-f 2>&1) || fail "preservation failure failed the proven merge"
assert_contains "$out" "preservation of lane-f failed" "preservation refusal reported"
assert_absent "$H/teardown.log" "teardown ran without preservation"
assert_present "$H/state/lane-f.meta" "unpreserved lane kept"
pass "preservation failure keeps the merged lane without teardown"

cat > "$TMP_ROOT/teardown-refuses" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$FM_TEST_TEARDOWN_LOG"
echo "REFUSED: work not landed" >&2
exit 1
SH
chmod +x "$TMP_ROOT/teardown-refuses"
H=$(new_home merge-local-refused)
: > "$H/config/lane-close-live"
merge_local_lane "$H" lane-r
out=$(run_merge_local "$H" lane-r "$TMP_ROOT/teardown-refuses" 2>&1)
expect_code 0 "$?" "a refused teardown failed the proven merge"
assert_contains "$out" "teardown of lane-r refused (rc=1)" "refusal reported"
assert_equals "lane-r" "$(cat "$H/teardown.log")" "refusal not retried or forced"
assert_present "$H/state/lane-r.meta" "refused lane kept"
pass "a teardown refusal after a local merge is reported and never fails the merge"
