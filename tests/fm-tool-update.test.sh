#!/usr/bin/env bash
# Tests for bin/fm-tool-update.sh: applying watched-tool updates, the missing
# half of fm-tool-update-check.sh's detection.
#
# The guarantees under test:
#   - --force is never passed to anything; a tool's own nonzero exit from its
#     update command is read as its authoritative refusal and reported as
#     skipped, never retried, never worked around (the no-mistakes shape).
#   - A command tool is verified, never assumed: its version is asked before
#     and after the update runs, and an unchanged version after a clean exit
#     is a failure, not a success, because that is the PATH-skew shape that
#     bit this fleet before.
#   - A command tool with no update_args configured is reported manual-only
#     and the update command is never attempted.
#   - A git tool updates with `git pull --ff-only`, which refuses a dirty or
#     diverged tree on its own; that refusal is reported as skipped exactly
#     like the command case, never forced.
#   - Fleet dispatch runs on this host, then on every local secondmate
#     registered in data/secondmates.md, folding one parseable fleet-summary
#     line whose counters equal the sum of every host-summary line.
#   - A registered local secondmate whose home has no fm-tool-update.sh yet is
#     reported unreachable rather than skipped silently or crashing the sweep.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

APPLY="$ROOT/bin/fm-tool-update.sh"

fm_git_identity fmtest fmtest@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-tool-update)

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/config" "$home/data"
  printf '%s\n' "$home"
}

write_config() {
  local home=$1
  shift
  printf '%s\n' "$*" > "$home/config/watched-tools.json"
}

# make_command <dir> <name> <version-text> [update-exit] [update-output]:
# a fake tool whose --version prints <version-text> from a state file (so an
# update can change it) and whose `update` subcommand exits <update-exit>
# (default 0) after printing <update-output> and, on a 0 exit, rewriting the
# state file to VERSION_AFTER if that env var is set by the caller.
make_command() {
  local dir=$1 name=$2 version=$3
  mkdir -p "$dir"
  printf '%s\n' "$version" > "$dir/.$name-version"
  cat > "$dir/$name" <<SH
#!/usr/bin/env bash
state="\$(dirname "\$0")/.$name-version"
case "\${1:-}" in
  --version) printf '$name %s\n' "\$(cat "\$state")" ;;
  update)
    if [ -n "\${FM_TEST_UPDATE_EXIT:-}" ] && [ "\${FM_TEST_UPDATE_EXIT}" != 0 ]; then
      printf '%s\n' "\${FM_TEST_UPDATE_MESSAGE:-refused}" >&2
      exit "\${FM_TEST_UPDATE_EXIT}"
    fi
    if [ -n "\${FM_TEST_UPDATE_TO:-}" ]; then
      printf '%s\n' "\${FM_TEST_UPDATE_TO}" > "\$state"
    fi
    printf 'updated\n'
    ;;
esac
SH
  chmod +x "$dir/$name"
}

fixture_path() { printf '%s:%s\n' "$1" "$PATH"; }

# --- command tool outcomes ---------------------------------------------

test_command_tool_update_is_verified_done() {
  local home fakebin out
  home=$(make_home cmd-done)
  fakebin="$TMP_ROOT/cmd-done/fakebin"
  make_command "$fakebin" toola 1.0.0
  write_config "$home" '{"tools":[{"name":"toola","command":"toola","update_args":["update"]}]}'

  out=$(FM_HOME="$home" PATH="$(fixture_path "$fakebin")" FM_TEST_UPDATE_TO=2.0.0 "$APPLY" apply)
  assert_contains "$out" "toola: done: 1.0.0 -> 2.0.0" "a real version change was not reported as done"
  assert_contains "$out" "done=1 skipped=0 failed=0 manual=0 unreachable=0" "the host summary counters did not match"
  pass "a command tool's verified version change is reported done"
}

test_command_tool_refusal_is_skipped_not_forced() {
  local home fakebin out
  home=$(make_home cmd-refuse)
  fakebin="$TMP_ROOT/cmd-refuse/fakebin"
  make_command "$fakebin" toolb 3.0.0
  write_config "$home" '{"tools":[{"name":"toolb","command":"toolb","update_args":["update"]}]}'

  out=$(FM_HOME="$home" PATH="$(fixture_path "$fakebin")" \
    FM_TEST_UPDATE_EXIT=1 FM_TEST_UPDATE_MESSAGE='pipeline runs active' "$APPLY" apply)
  assert_contains "$out" "toolb: skipped: " "the tool's own refusal was not reported as skipped"
  assert_contains "$out" "pipeline runs active" "the tool's own refusal message was not relayed"
  assert_contains "$out" "skipped=1" "the host summary did not count the refusal as skipped"
  assert_not_contains "$out" "--force" "the applier must never mention forcing an update"
  pass "a nonzero exit from the update command is reported skipped, never retried or forced"
}

test_command_tool_unchanged_version_is_a_failure() {
  local home fakebin out
  home=$(make_home cmd-unchanged)
  fakebin="$TMP_ROOT/cmd-unchanged/fakebin"
  make_command "$fakebin" toolc 1.0.0
  write_config "$home" '{"tools":[{"name":"toolc","command":"toolc","update_args":["update"]}]}'

  # Update exits 0 but never rewrites the version file, reproducing the
  # PATH-skew shape: the update "succeeded" yet the tool never moved.
  out=$(FM_HOME="$home" PATH="$(fixture_path "$fakebin")" "$APPLY" apply)
  assert_contains "$out" "toolc: failed: still 1.0.0" "an update that did not take was not reported as a failure"
  assert_contains "$out" "failed=1" "the host summary did not count the no-op update as a failure"
  pass "an update that exits 0 without moving the version is reported failed, not done"
}

test_command_tool_without_update_args_is_manual_only() {
  local home fakebin out
  home=$(make_home cmd-manual)
  fakebin="$TMP_ROOT/cmd-manual/fakebin"
  make_command "$fakebin" toold 1.0.0
  write_config "$home" '{"tools":[{"name":"toold","command":"toold"}]}'

  out=$(FM_HOME="$home" PATH="$(fixture_path "$fakebin")" FM_TEST_UPDATE_TO=9.9.9 "$APPLY" apply)
  assert_contains "$out" "toold: manual: " "a tool with no update_args was not reported manual-only"
  assert_contains "$out" "manual=1" "the host summary did not count the manual-only tool"
  assert_equals 1.0.0 "$(cat "$fakebin/.toold-version")" "a manual-only tool must never have its update command attempted"
  pass "a command tool with no update_args is reported manual-only and never attempted"
}

test_missing_command_is_unreachable() {
  local home fakebin out
  home=$(make_home cmd-missing)
  fakebin="$TMP_ROOT/cmd-missing/fakebin"
  mkdir -p "$fakebin"
  write_config "$home" '{"tools":[{"name":"toole","command":"toole-does-not-exist","update_args":["update"]}]}'

  out=$(FM_HOME="$home" PATH="$(fixture_path "$fakebin")" "$APPLY" apply)
  assert_contains "$out" "toole: unreachable: " "a command missing from PATH was not reported unreachable"
  assert_contains "$out" "unreachable=1" "the host summary did not count the missing command"
  pass "a watched command missing from PATH is reported unreachable"
}

# --- git tool outcomes ---------------------------------------------------

new_git_pair() {
  local name=$1 remote local_clone
  remote="$TMP_ROOT/$name-remote"
  local_clone="$TMP_ROOT/$name-clone"
  git init -q -b main "$remote"
  printf 'one\n' > "$remote/shared.txt"
  git -C "$remote" add shared.txt
  git -C "$remote" commit -q -m one
  git clone -q "$remote" "$local_clone" >/dev/null 2>&1
  printf '%s\n' "$local_clone"
}

test_git_tool_fast_forward_is_done() {
  local home clone out before after
  home=$(make_home git-ff)
  clone=$(new_git_pair git-ff)
  git -C "$TMP_ROOT/git-ff-remote" commit -q --allow-empty -m two
  before=$(git -C "$clone" rev-parse HEAD)
  write_config "$home" "{\"tools\":[{\"name\":\"gitrepo\",\"git\":{\"repo\":\"$clone\",\"remote\":\"origin\",\"branch\":\"main\"}}]}"

  out=$(FM_HOME="$home" "$APPLY" apply)
  after=$(git -C "$clone" rev-parse HEAD)
  assert_not_equals "$before" "$after" "the clone did not fast-forward"
  assert_contains "$out" "gitrepo: done: " "a clean fast-forward was not reported done"
  assert_contains "$out" "done=1" "the host summary did not count the git fast-forward"
  pass "a git tool that can fast-forward is updated and reported done"
}

test_git_tool_already_current_is_done_with_no_move() {
  local home clone out before after
  home=$(make_home git-current)
  clone=$(new_git_pair git-current)
  before=$(git -C "$clone" rev-parse HEAD)
  write_config "$home" "{\"tools\":[{\"name\":\"gitrepo\",\"git\":{\"repo\":\"$clone\",\"remote\":\"origin\",\"branch\":\"main\"}}]}"

  out=$(FM_HOME="$home" "$APPLY" apply)
  after=$(git -C "$clone" rev-parse HEAD)
  assert_equals "$before" "$after" "an already-current clone must not move"
  assert_contains "$out" "gitrepo: done: already current at" "an already-current git tool was not reported done"
  pass "a git tool already on the remote tip is reported done with no history change"
}

test_git_tool_dirty_tree_is_skipped_not_forced() {
  local home clone out before after
  home=$(make_home git-dirty)
  clone=$(new_git_pair git-dirty)
  printf 'two\n' >> "$TMP_ROOT/git-dirty-remote/shared.txt"
  git -C "$TMP_ROOT/git-dirty-remote" commit -aq -m two
  # An uncommitted edit to the SAME path the remote also changed: a
  # fast-forward checkout would overwrite it, so git itself must refuse.
  printf 'uncommitted local edit\n' >> "$clone/shared.txt"
  before=$(git -C "$clone" rev-parse HEAD)
  write_config "$home" "{\"tools\":[{\"name\":\"gitrepo\",\"git\":{\"repo\":\"$clone\",\"remote\":\"origin\",\"branch\":\"main\"}}]}"

  out=$(FM_HOME="$home" "$APPLY" apply)
  after=$(git -C "$clone" rev-parse HEAD)
  assert_equals "$before" "$after" "a dirty tree must never be advanced, stashed, or reset"
  assert_contains "$out" "gitrepo: skipped: " "git's own pull refusal was not reported as skipped"
  assert_contains "$out" "skipped=1" "the host summary did not count the dirty-tree refusal"
  assert_contains "$(cat "$clone/shared.txt")" "uncommitted local edit" "the applier must never discard unlanded local work"
  pass "a dirty working tree makes git refuse the pull, and that refusal is reported skipped, never forced"
}

# --- registry and config edges -------------------------------------------

test_absent_config_reports_nothing_to_apply() {
  local home out
  home=$(make_home no-config)
  out=$(FM_HOME="$home" "$APPLY" apply)
  assert_contains "$out" "nothing to apply" "an absent watched-tools.json must not be treated as an error"
  assert_contains "$out" "unreachable=0" "an absent config must count as nothing, not a failure"
  pass "a host with no watched-tools.json reports nothing to apply"
}

test_malformed_config_is_reported_not_silently_skipped() {
  local home out
  home=$(make_home bad-config)
  write_config "$home" '{"tools":[{"command":"missingname"}]}'
  out=$(FM_HOME="$home" "$APPLY" apply)
  assert_contains "$out" "watched tool registry:" "a malformed registry must name the problem"
  pass "a malformed watched-tools.json is reported, not silently ignored"
}

# --- fleet dispatch --------------------------------------------------------

test_fleet_applies_locally_and_on_a_registered_local_secondmate() {
  local main second fakebin out
  main=$(make_home fleet-main)
  second="$TMP_ROOT/fleet-second"
  mkdir -p "$second/config" "$second/bin"
  cp "$APPLY" "$ROOT/bin/fm-timeout-lib.sh" "$ROOT/bin/fm-secondmate-registry-lib.sh" "$ROOT/bin/fm-on.sh" "$second/bin/"
  chmod +x "$second/bin/fm-tool-update.sh"
  fakebin="$TMP_ROOT/fleet-main/fakebin"
  # Distinct command names per host: both hosts share one PATH in this
  # fixture (real hosts would not), so each needs its own independent
  # version-state file to prove its own update ran.
  make_command "$fakebin" toolf 1.0.0
  make_command "$fakebin" toolg 1.0.0

  write_config "$main" '{"tools":[{"name":"toolf","command":"toolf","update_args":["update"]}]}'
  write_config "$second" '{"tools":[{"name":"toolg","command":"toolg","update_args":["update"]}]}'
  cat > "$main/data/secondmates.md" <<EOF
- alpha - a test secondmate (home: $second; scope: testing; projects: none; added 2026-09-21)
EOF

  out=$(FM_HOME="$main" PATH="$(fixture_path "$fakebin")" FM_TEST_UPDATE_TO=2.0.0 "$APPLY" fleet)
  assert_contains "$out" "host: this host ($main)" "the local host section was not printed"
  assert_contains "$out" "host: fm-alpha ($second)" "the local secondmate host section was not printed"
  assert_contains "$out" "fleet-summary: hosts=2 done=2 skipped=0 failed=0 manual=0 unreachable=0" \
    "the fleet summary did not sum both hosts' results"
  pass "fleet dispatch applies updates on this host and on every registered local secondmate"
}

test_fleet_reports_a_secondmate_with_no_applier_yet_as_unreachable() {
  local main second out
  main=$(make_home fleet-missing-main)
  second="$TMP_ROOT/fleet-missing-second"
  mkdir -p "$second/config" "$second/bin"
  cat > "$main/data/secondmates.md" <<EOF
- bravo - a test secondmate (home: $second; scope: testing; projects: none; added 2026-09-21)
EOF

  out=$(FM_HOME="$main" "$APPLY" fleet)
  assert_contains "$out" "fm-tool-update.sh is not yet present" "a secondmate home without the applier must say so plainly"
  assert_contains "$out" "fleet-summary: hosts=2 done=0 skipped=0 failed=0 manual=0 unreachable=1" \
    "the fleet summary did not count the missing applier as unreachable"
  pass "a registered local secondmate with no fm-tool-update.sh yet is reported unreachable, not crashed past"
}

test_command_tool_update_is_verified_done
test_command_tool_refusal_is_skipped_not_forced
test_command_tool_unchanged_version_is_a_failure
test_command_tool_without_update_args_is_manual_only
test_missing_command_is_unreachable
test_git_tool_fast_forward_is_done
test_git_tool_already_current_is_done_with_no_move
test_git_tool_dirty_tree_is_skipped_not_forced
test_absent_config_reports_nothing_to_apply
test_malformed_config_is_reported_not_silently_skipped
test_fleet_applies_locally_and_on_a_registered_local_secondmate
test_fleet_reports_a_secondmate_with_no_applier_yet_as_unreachable
