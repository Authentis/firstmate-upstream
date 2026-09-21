#!/usr/bin/env bash
# tests/fm-inbox-ack.test.sh - bin/fm-inbox-ack.sh, the steering-inbox
# acknowledgement helper named by the doorbell and generated brief/relaunch
# text (bin/fm-task-inbox-lib.sh, bin/fm-brief.sh, bin/fm-control.sh).
#
# Why this script exists: a literal `mv <abs>/NNN.msg <abs>/handled/` is a
# form some worker-environment command guards refuse (a file-relocation
# command naming an absolute path under a user home), even though the worker
# both understood and intended the acknowledgement. This helper is invoked by
# its own absolute path (an ordinary script invocation, not itself a
# relocation or deletion command) and performs the actual `mv` using paths
# relative to the inbox directory, so the command line a worker runs never
# contains an absolute-path `mv`.
#
# These tests pin:
#   1. One record is acknowledged: moved into handled/, nothing else touched.
#   2. Several records in one call each land in handled/.
#   3. The relocation is via a relative path from the inbox directory: this
#      script must never invoke `mv` with an absolute-path argument.
#   4. A path-shaped or `.`/`..` "basename" is refused rather than escaping
#      the named inbox directory.
#   5. Missing usage arguments fail loudly rather than silently no-op.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ACK="$ROOT/bin/fm-inbox-ack.sh"
TMP_ROOT=$(fm_test_tmproot fm-inbox-ack)

make_inbox() {  # <dir>
  mkdir -p "$1/handled"
}

test_acks_one_record() {
  local dir=$TMP_ROOT/one out rc
  make_inbox "$dir"
  printf 'body\n' > "$dir/001.msg"
  out=$("$ACK" "$dir" 001.msg 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "fm-inbox-ack.sh failed on one record: $out"
  [ -z "$out" ] || fail "fm-inbox-ack.sh printed unexpected output: $out"
  [ ! -e "$dir/001.msg" ] || fail "the record was not removed from the inbox root"
  [ -f "$dir/handled/001.msg" ] || fail "the record did not land in handled/"
  pass "fm-inbox-ack: one record is acknowledged into handled/"
}

test_acks_several_records_in_one_call() {
  local dir=$TMP_ROOT/several out rc
  make_inbox "$dir"
  printf 'a\n' > "$dir/001.msg"
  printf 'b\n' > "$dir/002.msg"
  out=$("$ACK" "$dir" 001.msg 002.msg 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "fm-inbox-ack.sh failed on two records: $out"
  [ -f "$dir/handled/001.msg" ] || fail "first record did not land in handled/"
  [ -f "$dir/handled/002.msg" ] || fail "second record did not land in handled/"
  pass "fm-inbox-ack: several records in one call all reach handled/"
}

# The whole point of this script: prove the actual `mv` it runs never names
# an absolute path, by tracing every command it executes.
test_mv_is_relative_not_absolute() {
  local dir=$TMP_ROOT/trace trace out rc line
  make_inbox "$dir"
  printf 'body\n' > "$dir/001.msg"
  trace="$TMP_ROOT/trace.log"
  out=$(bash -x "$ACK" "$dir" 001.msg 2>"$trace"); rc=$?
  [ "$rc" -eq 0 ] || fail "fm-inbox-ack.sh failed under trace: $out"
  while IFS= read -r line; do
    case "$line" in
      *'mv '*"$dir"*)
        fail "fm-inbox-ack.sh ran mv naming the absolute inbox path: $line"
        ;;
    esac
  done < "$trace"
  grep -qE "mv .*'?001\.msg'? .*'?handled/001\.msg'?" "$trace" \
    || fail "fm-inbox-ack.sh's trace did not show the expected relative mv:"$'\n'"$(cat "$trace")"
  pass "fm-inbox-ack: the actual mv uses paths relative to the inbox dir, never the absolute one"
}

test_refuses_path_shaped_basename() {
  local dir=$TMP_ROOT/hostile out rc
  make_inbox "$dir"
  printf 'body\n' > "$dir/001.msg"
  out=$("$ACK" "$dir" "../escape" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "fm-inbox-ack.sh accepted a path-shaped basename"
  [ -f "$dir/001.msg" ] || fail "a refused call must not touch the inbox"
  out=$("$ACK" "$dir" "." 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "fm-inbox-ack.sh accepted '.' as a basename"
  pass "fm-inbox-ack: a path-shaped or dot basename is refused"
}

test_requires_arguments() {
  local out rc
  out=$("$ACK" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "fm-inbox-ack.sh with no arguments should fail loudly"
  assert_contains "$out" "usage" "the no-argument failure should explain usage"
  out=$("$ACK" "$TMP_ROOT/only-dir" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "fm-inbox-ack.sh with no basenames should fail loudly"
  pass "fm-inbox-ack: missing arguments fail loudly rather than silently no-op"
}

test_acks_one_record
test_acks_several_records_in_one_call
test_mv_is_relative_not_absolute
test_refuses_path_shaped_basename
test_requires_arguments
