#!/usr/bin/env bash
# tests/fm-wake-drain-done-shape.test.sh - the wake annotation firstmate
# actually reads must call out a `done:` line whose shape does not match its
# task's recorded mode, instead of presenting it as an ordinary completion.
# This is the supervisor-side acceptance check AGENTS.md's "done shape must
# match mode" fix adds: bin/fm-classify-lib.sh's status_done_mode_shape_ok is
# pinned in isolation by tests/fm-classify-done-shape.test.sh; this file pins
# its wiring into bin/fm-wake-lib.sh's fm_wake_print_annotations, exercised
# through the real drain (bin/fm-wake-drain.sh) over a crafted state dir, no
# harness.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-drain-done-shape-tests)

test_no_mistakes_done_with_no_pr_is_flagged_as_a_shape_mismatch() {
  local dir state out status
  dir=$(make_case incident-no-pr)
  state="$dir/state"
  out="$dir/drain.out"
  status="$state/task1.status"
  printf 'kind=ship\nmode=no-mistakes\n' > "$state/task1.meta"
  printf 'done [at=1758503935]: implemented on branch fm/task1, commit a1b2c3d\n' > "$status"

  append_wake "$state" signal task1.status "signal: $status" \
    || fail "wake append failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2>/dev/null \
    || fail "drain failed on the incident shape"

  grep -F 'DONE SHAPE MISMATCH' "$out" >/dev/null \
    || fail "a mode=no-mistakes done line naming only a branch and a commit was not flagged: $(cat "$out")"
  grep -F 'task1.status: done [at=1758503935]: implemented on branch fm/task1, commit a1b2c3d' "$out" >/dev/null \
    || fail "the mismatch annotation dropped the original done line: $(cat "$out")"
  pass "a mode=no-mistakes done line with no pull request is flagged DONE SHAPE MISMATCH, not silently accepted"
}

test_local_only_done_with_pr_shape_is_flagged() {
  local dir state out status
  dir=$(make_case wrong-shape-local-only)
  state="$dir/state"
  out="$dir/drain.out"
  status="$state/task2.status"
  printf 'kind=ship\nmode=local-only\n' > "$state/task2.meta"
  printf 'done [at=1758503935]: PR https://github.com/example/repo/pull/9\n' > "$status"

  append_wake "$state" signal task2.status "signal: $status" \
    || fail "wake append failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2>/dev/null \
    || fail "drain failed on the local-only mismatch shape"

  grep -F 'DONE SHAPE MISMATCH' "$out" >/dev/null \
    || fail "a mode=local-only done line naming a pull request was not flagged: $(cat "$out")"
  pass "a mode=local-only done line shaped like a pull-request completion is flagged"
}

test_matching_shapes_are_never_flagged() {
  local dir state out
  dir=$(make_case matching-shapes)
  state="$dir/state"
  out="$dir/drain.out"

  printf 'kind=ship\nmode=no-mistakes\n' > "$state/nm.meta"
  printf 'done [at=1758503935]: PR https://github.com/example/repo/pull/3 checks green\n' > "$state/nm.status"
  append_wake "$state" signal nm.status "signal: $state/nm.status" \
    || fail "no-mistakes wake append failed"

  printf 'kind=ship\nmode=local-only\n' > "$state/lo.meta"
  printf 'done [at=1758503935]: ready in branch fm/lo\n' > "$state/lo.status"
  append_wake "$state" signal lo.status "signal: $state/lo.status" \
    || fail "local-only wake append failed"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2>/dev/null \
    || fail "drain failed on matching-shape done lines"

  if grep -F 'DONE SHAPE MISMATCH' "$out" >/dev/null; then
    fail "a done line whose shape matches its recorded mode was flagged as a mismatch: $(cat "$out")"
  fi
  pass "done lines whose shape matches their recorded mode are never flagged"
}

test_scout_done_line_is_never_flagged() {
  local dir state out
  dir=$(make_case scout-no-mode)
  state="$dir/state"
  out="$dir/drain.out"

  printf 'kind=scout\n' > "$state/sc.meta"
  printf 'done [at=1758503935]: reproduced the bug, see report\n' > "$state/sc.status"
  append_wake "$state" signal sc.status "signal: $state/sc.status" \
    || fail "scout wake append failed"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2>/dev/null \
    || fail "drain failed on the scout done line"

  if grep -F 'DONE SHAPE MISMATCH' "$out" >/dev/null; then
    fail "a scout done line, which has no delivery mode, was flagged as a shape mismatch: $(cat "$out")"
  fi
  pass "a scout's done line, which carries no recorded mode, is never flagged"
}

test_no_mistakes_done_with_no_pr_is_flagged_as_a_shape_mismatch
test_local_only_done_with_pr_shape_is_flagged
test_matching_shapes_are_never_flagged
test_scout_done_line_is_never_flagged
