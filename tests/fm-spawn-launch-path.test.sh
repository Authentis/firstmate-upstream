#!/usr/bin/env bash
# Behavior test for the launch PATH contract in bin/fm-spawn.sh's header.
#
# A harness binary that lives only on the spawning process's PATH must still
# resolve in a pane whose own PATH is bare. The fake tmux captures the launch
# command fm-spawn stages, and the test runs that command under a bare PATH the
# way the pane's shell would.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-launch-path)
unset LAVISH_AXI_HOST

BARE_PANE_PATH=/usr/bin:/bin

make_case() {
  local name=$1 harness=$2 id=$3
  CASE_DIR="$TMP_ROOT/$name"
  HOME_DIR="$CASE_DIR/home"
  PROJ_DIR="$CASE_DIR/project"
  WT_DIR="$CASE_DIR/wt"
  LAUNCH_LOG="$CASE_DIR/launch.log"
  FAKEBIN_DIR=$(fm_test_make_spawn_fakebin "$CASE_DIR/fake")
  # The stub lives on the spawner PATH only, in a directory the pane never sees.
  OFFPATH_DIR="$CASE_DIR/nvm/bin"
  mkdir -p "$OFFPATH_DIR"
  cat > "$OFFPATH_DIR/opencode" <<SH
#!/bin/sh
printf 'stub-opencode-ran\n' > '$CASE_DIR/ran.marker'
SH
  chmod +x "$OFFPATH_DIR/opencode"
  fm_test_spawn_home "$HOME_DIR" "$harness"
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "wt-$name"
  fm_test_spawn_brief "$HOME_DIR" "$id"
  : > "$LAUNCH_LOG"
}

spawn() {  # <extra PATH to prepend> [spawn args...]
  local extra=$1
  shift
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" PATH="$extra:$PATH" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$@" --mode no-mistakes --yolo off
}

run_in_bare_pane() {  # <launch command>
  (cd "$WT_DIR" && env -i HOME="$CASE_DIR" PATH="$BARE_PANE_PATH" FM_TASK_ID=x \
    /bin/bash -c "$1") 2>&1
}

test_launch_resolves_harness_missing_from_pane_path() {
  local id=launch-path-z1 out status launch pane_out
  make_case offpath opencode "$id"
  rm -f "$CASE_DIR/ran.marker"

  # Control: with no PATH carried, the bare pane cannot find the stub at all.
  pane_out=$(run_in_bare_pane "opencode --prompt x")
  assert_contains "$pane_out" "opencode" "control: the bare pane shell should report the missing binary"
  [ ! -e "$CASE_DIR/ran.marker" ] || fail "control: stub ran on the bare pane PATH, so the test proves nothing"

  out=$(spawn "$OFFPATH_DIR" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "opencode spawn should succeed: $out"
  launch=$(cat "$LAUNCH_LOG")
  # shellcheck disable=SC2016
  assert_contains "$launch" 'export PATH="${PATH:+$PATH:}"' "launch did not append to the pane PATH"
  assert_contains "$launch" ":$OFFPATH_DIR:" "launch did not carry the spawner PATH entry"
  run_in_bare_pane "$launch" > /dev/null
  [ -e "$CASE_DIR/ran.marker" ] || fail "launch line did not resolve the stub opencode on a bare pane PATH"
  pass "launch carries the spawner PATH so a binary absent from the pane PATH resolves"
}

test_launch_path_with_quote_is_shell_safe() {
  local id=launch-path-z2 out status launch quoted_dir
  make_case quotepath opencode "$id"
  quoted_dir="$CASE_DIR/it's here"
  mkdir -p "$quoted_dir"
  cp "$OFFPATH_DIR/opencode" "$quoted_dir/opencode"
  rm -f "$CASE_DIR/ran.marker"

  out=$(spawn "$quoted_dir" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "spawn with a quote in PATH should succeed: $out"
  launch=$(cat "$LAUNCH_LOG")
  run_in_bare_pane "$launch" > /dev/null
  [ -e "$CASE_DIR/ran.marker" ] || fail "a PATH entry containing a single quote did not survive shell quoting"
  pass "a PATH entry containing a single quote is quoted safely"
}

test_oversized_path_is_not_exported() {
  local id=launch-path-z3 out status launch pad
  make_case bigpath opencode "$id"
  pad=$(printf '/nonexistent%.0s' $(seq 1 400))
  out=$(spawn "$OFFPATH_DIR:$pad" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "spawn with an oversized PATH should still succeed: $out"
  assert_contains "$out" "longer than 4096 bytes" "oversized PATH should warn"
  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" "export PATH=" "oversized PATH must not be exported into the launch"
  pass "an oversized spawner PATH is skipped with a warning"
}

test_launch_resolves_harness_missing_from_pane_path
test_launch_path_with_quote_is_shell_safe
test_oversized_path_is_not_exported

echo "# all fm-spawn-launch-path tests passed"
