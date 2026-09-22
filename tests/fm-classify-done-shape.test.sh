#!/usr/bin/env bash
# tests/fm-classify-done-shape.test.sh - status_done_mode_shape_ok
# (bin/fm-classify-lib.sh) is the shape comparison AGENTS.md's "done shape
# must match mode" fix owns: a `done:` event must carry the ready-signal its
# task's recorded mode promises (bin/fm-dod-lib.sh) - a pull request URL for
# no-mistakes/direct-PR, "ready in branch" for local-only - or it is not a
# completion. The incident this pins: two 2026-09-21 mode=no-mistakes workers
# reported done naming only a branch and a commit, with no pull request in any
# state, and nothing caught it until a supervisor checked the forge by hand.
# kunchenguid dbc0bc4b does not cover this gap: it only strengthens a done
# report that CLAIMS a pull request by reading it back from the forge, and
# these two instances claimed none. These tests drive the real
# status_done_mode_shape_ok and _fm_status_mode functions, never their source
# text.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-classify-done-shape-tests)

assert_shape_ok() {  # <label> <event-line> <mode>
  status_done_mode_shape_ok "$2" "$3" \
    || fail "$1: expected shape OK for mode=$3: $2"
}

assert_shape_mismatch() {  # <label> <event-line> <mode>
  ! status_done_mode_shape_ok "$2" "$3" \
    || fail "$1: expected a shape MISMATCH for mode=$3: $2"
}

test_no_mistakes_pr_url_is_ok() {
  assert_shape_ok "no-mistakes PR url" \
    'done [at=1758503935]: PR https://github.com/example/repo/pull/42' no-mistakes
  assert_shape_ok "no-mistakes PR url checks green" \
    'done [at=1758503935]: PR https://github.com/example/repo/pull/42 checks green' no-mistakes
  pass "no-mistakes done lines naming a pull request URL are accepted"
}

test_direct_pr_pr_url_is_ok() {
  assert_shape_ok "direct-PR PR url" \
    'done [at=1758503935]: PR https://github.com/example/repo/pull/7' direct-PR
  pass "direct-PR done lines naming a pull request URL are accepted"
}

test_local_only_ready_in_branch_is_ok() {
  assert_shape_ok "local-only ready in branch" \
    'done [at=1758503935]: ready in branch fm/some-task-0921' local-only
  pass "local-only done lines naming ready-in-branch are accepted"
}

test_incident_shape_naming_only_a_branch_and_commit_mismatches_no_mistakes() {
  assert_shape_mismatch "no-mistakes bare branch/commit" \
    'done [at=1758503935]: implemented on branch fm/nu-14, commit a1b2c3d' no-mistakes
  pass "a no-mistakes done line naming only a branch and a commit is a shape mismatch (the 2026-09-21 incident shape)"
}

test_pr_number_alone_mismatches() {
  assert_shape_mismatch "PR number, no URL" \
    'done [at=1758503935]: PR 108' no-mistakes
  pass "a done line naming a bare PR number without a pull request URL is a shape mismatch"
}

test_ready_in_branch_mismatches_no_mistakes() {
  assert_shape_mismatch "ready-in-branch shape under no-mistakes mode" \
    'done [at=1758503935]: ready in branch fm/some-task-0921' no-mistakes
  pass "a local-only-shaped done line under mode=no-mistakes is a shape mismatch"
}

test_pr_url_mismatches_local_only() {
  assert_shape_mismatch "PR url shape under local-only mode" \
    'done [at=1758503935]: PR https://github.com/example/repo/pull/42' local-only
  pass "a PR-shaped done line under mode=local-only is a shape mismatch"
}

test_non_done_verb_is_never_judged() {
  assert_shape_ok "working: line" \
    'working [at=1758503935]: implemented on branch, no PR yet' no-mistakes
  assert_shape_ok "blocked: line" \
    'blocked [at=1758503935]: waiting on review' no-mistakes
  pass "a non-done verb is never judged against the mode shape"
}

test_scout_and_unset_mode_are_never_judged() {
  assert_shape_ok "empty mode (scout/secondmate/unreadable meta)" \
    'done [at=1758503935]: implemented on branch fm/x, commit abc' ''
  assert_shape_ok "unrecognized mode" \
    'done [at=1758503935]: implemented on branch fm/x, commit abc' scout
  pass "an empty or unrecognized mode is never judged, so a scout report is never flagged"
}

test_status_mode_reads_meta_field() {
  local dir meta
  dir="$TMP_ROOT/meta-read"
  mkdir -p "$dir"
  meta="$dir/task1.meta"
  printf 'kind=ship\nmode=no-mistakes\n' > "$meta"
  [ "$(_fm_status_mode "$dir/task1.status")" = no-mistakes ] \
    || fail "_fm_status_mode did not read mode= from the sibling .meta file"

  : > "$dir/task2.meta"
  [ "$(_fm_status_mode "$dir/task2.status")" = "" ] \
    || fail "_fm_status_mode should read empty for a meta with no mode= line (scout/secondmate)"

  [ "$(_fm_status_mode "$dir/task3.status")" = "" ] \
    || fail "_fm_status_mode should read empty for a missing meta file"
  pass "_fm_status_mode reads the recorded mode from state/<id>.meta, empty when absent or unset"
}

test_no_mistakes_pr_url_is_ok
test_direct_pr_pr_url_is_ok
test_local_only_ready_in_branch_is_ok
test_incident_shape_naming_only_a_branch_and_commit_mismatches_no_mistakes
test_pr_number_alone_mismatches
test_ready_in_branch_mismatches_no_mistakes
test_pr_url_mismatches_local_only
test_non_done_verb_is_never_judged
test_scout_and_unset_mode_are_never_judged
test_status_mode_reads_meta_field
