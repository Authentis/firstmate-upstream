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
#   - An npm_package tool is installed with `npm install -g <pkg>@latest` only
#     when the published version is newer, is verified to have moved to it, and
#     an npm refusal or unreadable published version is reported skipped.
#   - An explicit action is required; the no-argument call that used to reach
#     every registered host is refused.
#   - Apply classes: an absent class is manual and never applied, a pass
#     applies only its own class (auto by default, quiet with --class quiet),
#     and --class manual is refused.
#   - A pin is never exceeded: a pinned npm tool installs exactly the pin, and
#     a pinned self-updating tool is held rather than run.
#   - Every update is preceded by a rollback record line, an unwritable record
#     stops the update, and a failed health check rolls the tool back to the
#     recorded version, or says ROLLBACK IMPOSSIBLE when that cannot be done.
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

# make_npm <dir>: a fake npm. `view <pkg> version` prints FM_TEST_NPM_PUBLISHED
# (exiting FM_TEST_NPM_VIEW_EXIT when set); `install` logs its arguments to
# <dir>/.npm-log, exits FM_TEST_NPM_INSTALL_EXIT when set, and otherwise writes
# FM_TEST_NPM_INSTALL_TO into the version state file FM_TEST_NPM_STATE.
make_npm() {
  local dir=$1
  mkdir -p "$dir"
  cat > "$dir/npm" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  view)
    [ -z "${FM_TEST_NPM_VIEW_EXIT:-}" ] || { echo 'npm error 404' >&2; exit "$FM_TEST_NPM_VIEW_EXIT"; }
    printf '%s\n' "${FM_TEST_NPM_PUBLISHED:-}"
    ;;
  install)
    printf '%s\n' "$*" >> "$(dirname "$0")/.npm-log"
    [ -z "${FM_TEST_NPM_INSTALL_EXIT:-}" ] || { echo 'npm error EACCES' >&2; exit "$FM_TEST_NPM_INSTALL_EXIT"; }
    want=${3##*@}
    case "$want" in
      [0-9]*)
        # An exact version: a pinned install or a rollback.
        [ -z "${FM_TEST_NPM_EXACT_EXIT:-}" ] || { echo 'npm error ETARGET' >&2; exit "$FM_TEST_NPM_EXACT_EXIT"; }
        printf '%s\n' "$want" > "$FM_TEST_NPM_STATE"
        ;;
      *) [ -z "${FM_TEST_NPM_INSTALL_TO:-}" ] || printf '%s\n' "$FM_TEST_NPM_INSTALL_TO" > "$FM_TEST_NPM_STATE" ;;
    esac
    ;;
esac
SH
  chmod +x "$dir/npm"
}

# --- npm package tools -------------------------------------------------

test_npm_package_tool_is_installed_and_verified() {
  local home fakebin out
  home=$(make_home npm-done)
  fakebin="$TMP_ROOT/npm-done/fakebin"
  make_command "$fakebin" npmtool 1.0.0
  make_npm "$fakebin"
  write_config "$home" '{"tools":[{"name":"npmtool","class":"auto","command":"npmtool","npm_package":"@scope/npmtool"}]}'

  out=$(FM_HOME="$home" PATH="$(fixture_path "$fakebin")" FM_TEST_NPM_PUBLISHED=1.2.0 \
    FM_TEST_NPM_INSTALL_TO=1.2.0 FM_TEST_NPM_STATE="$fakebin/.npmtool-version" "$APPLY" apply)
  assert_contains "$out" "npmtool: done: 1.0.0 -> 1.2.0" "a verified npm install was not reported done"
  assert_equals "install -g @scope/npmtool@latest" "$(cat "$fakebin/.npm-log")" "npm was not asked to install the package at latest"
  pass "an npm_package tool is updated with npm install -g <pkg>@latest and verified"
}

test_npm_package_tool_already_current_is_not_installed() {
  local home fakebin out
  home=$(make_home npm-current)
  fakebin="$TMP_ROOT/npm-current/fakebin"
  make_command "$fakebin" npmtool 1.3.0
  make_npm "$fakebin"
  write_config "$home" '{"tools":[{"name":"npmtool","class":"auto","command":"npmtool","npm_package":"npmtool"}]}'

  out=$(FM_HOME="$home" PATH="$(fixture_path "$fakebin")" FM_TEST_NPM_PUBLISHED=1.2.0 "$APPLY" apply)
  assert_contains "$out" "npmtool: done: already current at 1.3.0" "a copy at or past the published version was not reported current"
  assert_equals no "$([ -e "$fakebin/.npm-log" ] && echo yes || echo no)" "npm install must not run when nothing newer is published"
  pass "an npm_package tool at or past the published version is never reinstalled"
}

test_npm_package_install_that_does_not_take_is_a_failure() {
  local home fakebin out
  home=$(make_home npm-unchanged)
  fakebin="$TMP_ROOT/npm-unchanged/fakebin"
  make_command "$fakebin" npmtool 1.0.0
  make_npm "$fakebin"
  write_config "$home" '{"tools":[{"name":"npmtool","class":"auto","command":"npmtool","npm_package":"npmtool"}]}'

  out=$(FM_HOME="$home" PATH="$(fixture_path "$fakebin")" FM_TEST_NPM_PUBLISHED=1.2.0 "$APPLY" apply)
  assert_contains "$out" "npmtool: failed: still 1.0.0" "an npm install that left PATH on the old version was not a failure"

  printf '1.0.0\n' > "$fakebin/.npmtool-version"
  out=$(FM_HOME="$home" PATH="$(fixture_path "$fakebin")" FM_TEST_NPM_PUBLISHED=1.2.0 \
    FM_TEST_NPM_INSTALL_TO=1.1.0 FM_TEST_NPM_STATE="$fakebin/.npmtool-version" "$APPLY" apply)
  assert_contains "$out" "npmtool: failed: npm installed npmtool@latest (1.2.0) but" "a copy that moved short of the published version was not a failure"
  pass "an npm install whose version did not reach the published one is reported failed"
}

test_npm_refusals_are_skipped_not_retried() {
  local home fakebin out
  home=$(make_home npm-refuse)
  fakebin="$TMP_ROOT/npm-refuse/fakebin"
  make_command "$fakebin" npmtool 1.0.0
  make_npm "$fakebin"
  write_config "$home" '{"tools":[{"name":"npmtool","class":"auto","command":"npmtool","npm_package":"npmtool"}]}'

  out=$(FM_HOME="$home" PATH="$(fixture_path "$fakebin")" FM_TEST_NPM_PUBLISHED=1.2.0 FM_TEST_NPM_INSTALL_EXIT=243 "$APPLY" apply)
  assert_contains "$out" "npmtool: skipped: npm refused to install npmtool@latest (exit 243): npm error EACCES" "npm's own refusal was not reported skipped"
  assert_equals 1 "$(wc -l < "$fakebin/.npm-log" | tr -d ' ')" "a refused npm install must never be retried"
  assert_not_contains "$(cat "$fakebin/.npm-log")" "--force" "npm must never be forced"

  rm -f "$fakebin/.npm-log"
  out=$(FM_HOME="$home" PATH="$(fixture_path "$fakebin")" FM_TEST_NPM_VIEW_EXIT=1 "$APPLY" apply)
  assert_contains "$out" "npmtool: skipped: could not read the published version of npmtool" "an unreadable published version was not reported skipped"
  assert_equals no "$([ -e "$fakebin/.npm-log" ] && echo yes || echo no)" "npm install must not run blind"
  pass "npm refusals and unreadable published versions are reported skipped, never retried or forced"
}

test_npm_package_schema_is_validated() {
  local home out
  home=$(make_home npm-schema)
  write_config "$home" '{"tools":[{"name":"npmtool","class":"auto","command":"npmtool","npm_package":"npmtool","update_args":["update"]}]}'
  out=$(FM_HOME="$home" "$APPLY" apply)
  assert_contains "$out" "may set update_args or npm_package, not both" "update_args with npm_package was not refused"
  write_config "$home" '{"tools":[{"name":"npmtool","class":"auto","command":"npmtool","npm_package":"npmtool@latest; rm"}]}'
  out=$(FM_HOME="$home" "$APPLY" apply)
  assert_contains "$out" "npm_package must be a plain npm package name" "an unsafe package name was not refused"
  pass "an npm_package that is ambiguous or not a plain package name is refused"
}

# --- command tool outcomes ---------------------------------------------

test_command_tool_update_is_verified_done() {
  local home fakebin out
  home=$(make_home cmd-done)
  fakebin="$TMP_ROOT/cmd-done/fakebin"
  make_command "$fakebin" toola 1.0.0
  write_config "$home" '{"tools":[{"name":"toola","class":"auto","command":"toola","update_args":["update"]}]}'

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
  write_config "$home" '{"tools":[{"name":"toolb","class":"auto","command":"toolb","update_args":["update"]}]}'

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
  write_config "$home" '{"tools":[{"name":"toolc","class":"auto","command":"toolc","update_args":["update"]}]}'

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
  write_config "$home" '{"tools":[{"name":"toold","class":"auto","command":"toold"}]}'

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
  write_config "$home" '{"tools":[{"name":"toole","class":"auto","command":"toole-does-not-exist","update_args":["update"]}]}'

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
  write_config "$home" "{\"tools\":[{\"name\":\"gitrepo\",\"class\":\"auto\",\"git\":{\"repo\":\"$clone\",\"remote\":\"origin\",\"branch\":\"main\"}}]}"

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
  write_config "$home" "{\"tools\":[{\"name\":\"gitrepo\",\"class\":\"auto\",\"git\":{\"repo\":\"$clone\",\"remote\":\"origin\",\"branch\":\"main\"}}]}"

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
  write_config "$home" "{\"tools\":[{\"name\":\"gitrepo\",\"class\":\"auto\",\"git\":{\"repo\":\"$clone\",\"remote\":\"origin\",\"branch\":\"main\"}}]}"

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

  write_config "$main" '{"tools":[{"name":"toolf","class":"auto","command":"toolf","update_args":["update"]}]}'
  write_config "$second" '{"tools":[{"name":"toolg","class":"auto","command":"toolg","update_args":["update"]}]}'
  cat > "$main/data/secondmates.md" <<EOF
- alpha - a test secondmate (home: $second; scope: testing; projects: none; added 2026-09-21)
EOF

  out=$(FM_HOME="$main" PATH="$(fixture_path "$fakebin")" FM_TEST_UPDATE_TO=2.0.0 "$APPLY" fleet)
  assert_contains "$out" "host: this host ($main)" "the local host section was not printed"
  assert_contains "$out" "host: fm-alpha ($second)" "the local secondmate host section was not printed"
  assert_contains "$out" "fleet-summary: hosts=2 done=2 skipped=0 failed=0 manual=0 unreachable=0 held=0" \
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
  assert_contains "$out" "fleet-summary: hosts=2 done=0 skipped=0 failed=0 manual=0 unreachable=1 held=0" \
    "the fleet summary did not count the missing applier as unreachable"
  pass "a registered local secondmate with no fm-tool-update.sh yet is reported unreachable, not crashed past"
}

# --- explicit action, classes, and pin --------------------------------------

test_no_argument_is_refused_rather_than_running_fleet() {
  local home fakebin out status=0
  home=$(make_home no-arg)
  fakebin="$TMP_ROOT/no-arg/fakebin"
  make_command "$fakebin" toolh 1.0.0
  write_config "$home" '{"tools":[{"name":"toolh","class":"auto","command":"toolh","update_args":["update"]}]}'
  out=$(FM_HOME="$home" PATH="$(fixture_path "$fakebin")" FM_TEST_UPDATE_TO=2.0.0 "$APPLY" 2>&1) || status=$?
  expect_code 2 "$status" "no-argument exit"
  assert_contains "$out" "an explicit action is required" "the refusal did not say an action is required"
  assert_equals 1.0.0 "$(cat "$fakebin/.toolh-version")" "a no-argument call must not apply anything"
  pass "running with no argument is refused instead of defaulting to fleet"
}

test_classes_gate_what_a_pass_applies() {
  local home fakebin out status=0
  home=$(make_home classes)
  fakebin="$TMP_ROOT/classes/fakebin"
  make_command "$fakebin" toolauto 1.0.0
  make_command "$fakebin" toolquiet 1.0.0
  make_command "$fakebin" toolnone 1.0.0
  make_command "$fakebin" toolmanual 1.0.0
  write_config "$home" '{"tools":[
    {"name":"toolauto","class":"auto","command":"toolauto","update_args":["update"]},
    {"name":"toolquiet","class":"quiet","command":"toolquiet","update_args":["update"]},
    {"name":"toolnone","command":"toolnone","update_args":["update"]},
    {"name":"toolmanual","class":"manual","command":"toolmanual","update_args":["update"]}]}'

  out=$(FM_HOME="$home" PATH="$(fixture_path "$fakebin")" FM_TEST_UPDATE_TO=2.0.0 "$APPLY" apply)
  assert_contains "$out" "toolauto: done: 1.0.0 -> 2.0.0" "an auto tool was not applied by the default pass"
  assert_contains "$out" "toolquiet: held: class quiet" "a quiet tool was not held by the default pass"
  assert_contains "$out" "toolnone: manual: class manual" "a tool with no class was not treated as manual"
  assert_contains "$out" "toolmanual: manual: class manual" "a manual tool was not reported manual"
  assert_contains "$out" "done=1 skipped=0 failed=0 manual=2 unreachable=0 held=1" "the class counters did not match"
  assert_equals 1.0.0 "$(cat "$fakebin/.toolquiet-version")" "the default pass must not apply a quiet tool"
  assert_equals 1.0.0 "$(cat "$fakebin/.toolnone-version")" "a tool with no class must never be applied"

  printf '1.0.0\n' > "$fakebin/.toolauto-version"
  out=$(FM_HOME="$home" PATH="$(fixture_path "$fakebin")" FM_TEST_UPDATE_TO=2.0.0 "$APPLY" apply --class quiet)
  assert_contains "$out" "toolquiet: done: 1.0.0 -> 2.0.0" "a quiet pass did not apply the quiet tool"
  assert_contains "$out" "toolauto: held: class auto" "a quiet pass did not hold the auto tool"
  assert_equals 1.0.0 "$(cat "$fakebin/.toolauto-version")" "a quiet pass must not apply an auto tool"
  assert_equals 1.0.0 "$(cat "$fakebin/.toolmanual-version")" "a manual tool must never be applied"

  out=$(FM_HOME="$home" PATH="$(fixture_path "$fakebin")" "$APPLY" apply --class manual 2>&1) || status=$?
  expect_code 2 "$status" "manual class exit"
  assert_contains "$out" "never applied" "--class manual was not refused"

  write_config "$home" '{"tools":[{"name":"toolauto","class":"au","command":"toolauto","update_args":["update"]}]}'
  out=$(FM_HOME="$home" "$APPLY" apply)
  assert_contains "$out" "class must be auto, quiet, or manual" "an unknown class was accepted"
  pass "a pass applies only its own class, an absent class is manual, and manual is never applied"
}

test_pin_is_never_exceeded() {
  local home fakebin out
  home=$(make_home pin)
  fakebin="$TMP_ROOT/pin/fakebin"
  make_command "$fakebin" npmtool 1.0.0
  make_command "$fakebin" selftool 1.0.0
  make_npm "$fakebin"
  write_config "$home" '{"tools":[
    {"name":"npmtool","class":"auto","command":"npmtool","npm_package":"npmtool","pin":"1.1.0"},
    {"name":"selftool","class":"auto","command":"selftool","update_args":["update"],"pin":"5.0.0"}]}'

  out=$(FM_HOME="$home" PATH="$(fixture_path "$fakebin")" FM_TEST_NPM_PUBLISHED=1.2.0 \
    FM_TEST_NPM_STATE="$fakebin/.npmtool-version" FM_TEST_UPDATE_TO=6.0.0 "$APPLY" apply)
  assert_contains "$out" "npmtool: done: 1.0.0 -> 1.1.0" "a pinned npm tool did not stop at its pin"
  assert_equals "install -g npmtool@1.1.0" "$(cat "$fakebin/.npm-log")" "a pinned npm tool was not installed at exactly the pin"
  assert_contains "$out" "selftool: held: pinned at 5.0.0" "a pinned self-updating tool was not held"
  assert_equals 1.0.0 "$(cat "$fakebin/.selftool-version")" "a pinned self-updating tool must not run its update"

  rm -f "$fakebin/.npm-log"
  out=$(FM_HOME="$home" PATH="$(fixture_path "$fakebin")" FM_TEST_NPM_PUBLISHED=1.2.0 \
    FM_TEST_NPM_STATE="$fakebin/.npmtool-version" "$APPLY" apply)
  assert_contains "$out" "npmtool: held: pinned at 1.1.0, already at 1.1.0" "a tool at its pin was not held"
  assert_equals no "$([ -e "$fakebin/.npm-log" ] && echo yes || echo no)" "a tool at its pin must not be reinstalled"
  pass "a pinned npm tool installs exactly the pin, and a pinned self-updating tool is held"
}

# --- rollback record, health check, rollback --------------------------------

# make_selfupdating <dir> <name> <version>: a tool whose version is baked into
# its own bytes, so restoring a saved binary really restores the version. Its
# `update` rewrites itself at FM_TEST_UPDATE_TO, broken (health exits 1) when
# FM_TEST_UPDATE_BROKEN is set.
selfupdating_bytes() {  # <name> <version> <health-exit>
  cat <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  --version) printf '$1 %s\n' '$2' ;;
  health) exit $3 ;;
  update)
    [ -n "\${FM_TEST_UPDATE_TO:-}" ] || exit 0
    h=0; [ -z "\${FM_TEST_UPDATE_BROKEN:-}" ] || h=1
    "\$FM_TEST_GEN" "$1" "\$FM_TEST_UPDATE_TO" "\$h" > "\$0.new" && chmod +x "\$0.new" && mv -f "\$0.new" "\$0"
    ;;
esac
SH
}

make_selfupdating() {
  local dir=$1 name=$2 version=$3
  mkdir -p "$dir"
  selfupdating_bytes "$name" "$version" 0 > "$dir/$name"
  chmod +x "$dir/$name"
  # The generator the fake update calls to write its next self.
  {
    printf '#!/usr/bin/env bash\n'
    declare -f selfupdating_bytes
    printf 'selfupdating_bytes "$@"\n'
  } > "$TMP_ROOT/gen"
  chmod +x "$TMP_ROOT/gen"
}

record_of() { cat "$1"/data/tool-updates/*.md 2>/dev/null; }

test_rollback_record_is_written_before_each_update() {
  local home fakebin out record
  home=$(make_home record)
  fakebin="$TMP_ROOT/record/fakebin"
  make_selfupdating "$fakebin" selftool 1.0.0
  make_command "$fakebin" npmtool 1.0.0
  make_npm "$fakebin"
  write_config "$home" '{"tools":[
    {"name":"selftool","class":"auto","command":"selftool","update_args":["update"],"health_args":["health"]},
    {"name":"npmtool","class":"auto","command":"npmtool","npm_package":"npmtool"}]}'

  out=$(FM_HOME="$home" PATH="$(fixture_path "$fakebin")" FM_TEST_GEN="$TMP_ROOT/gen" FM_TEST_UPDATE_TO=2.0.0 \
    FM_TEST_NPM_PUBLISHED=1.2.0 FM_TEST_NPM_INSTALL_TO=1.2.0 FM_TEST_NPM_STATE="$fakebin/.npmtool-version" "$APPLY" apply)
  assert_contains "$out" "selftool: done: 1.0.0 -> 2.0.0" "a healthy self-update was not reported done"
  assert_contains "$out" "npmtool: done: 1.0.0 -> 1.2.0" "a healthy npm update was not reported done"
  [ -f "$home/data/tool-updates/$(date +%Y-%m-%d).md" ] || fail "no dated rollback record was written"
  record=$(record_of "$home")
  assert_contains "$record" "selftool: previous 1.0.0 at $(cd "$fakebin" && pwd -P)/selftool; backup " "the record did not name the previous version and binary path"
  assert_contains "$record" "npmtool: previous 1.0.0 at $fakebin/npmtool; npm npmtool@1.0.0" "the record did not name the previous npm version"
  assert_contains "$(ls "$home/data/tool-updates/backup")" "selftool-1.0.0-" "no copy of the previous binary was saved"
  pass "each update is preceded by a dated rollback record naming the previous version and binary or npm version"
}

test_unwritable_rollback_record_stops_the_update() {
  local home fakebin out
  home=$(make_home record-blocked)
  fakebin="$TMP_ROOT/record-blocked/fakebin"
  make_command "$fakebin" toolr 1.0.0
  write_config "$home" '{"tools":[{"name":"toolr","class":"auto","command":"toolr","update_args":["update"]}]}'
  printf 'not a directory\n' > "$home/data/tool-updates"
  out=$(FM_HOME="$home" PATH="$(fixture_path "$fakebin")" FM_TEST_UPDATE_TO=2.0.0 "$APPLY" apply)
  assert_contains "$out" "toolr: skipped: could not write the rollback record" "an unwritable record did not stop the update"
  assert_equals 1.0.0 "$(cat "$fakebin/.toolr-version")" "a tool must not be updated without a rollback record"
  pass "an update whose rollback record cannot be written is not attempted"
}

test_failed_health_check_restores_the_saved_binary() {
  local home fakebin out
  home=$(make_home health-self)
  fakebin="$TMP_ROOT/health-self/fakebin"
  make_selfupdating "$fakebin" selftool 1.0.0
  write_config "$home" '{"tools":[{"name":"selftool","class":"auto","command":"selftool","update_args":["update"],"health_args":["health"]}]}'
  out=$(FM_HOME="$home" PATH="$(fixture_path "$fakebin")" FM_TEST_GEN="$TMP_ROOT/gen" FM_TEST_UPDATE_TO=2.0.0 \
    FM_TEST_UPDATE_BROKEN=1 "$APPLY" apply)
  assert_contains "$out" "selftool: failed: health check failed (" "a failed health check was not reported"
  assert_contains "$out" "health exited 1" "the health check did not see the broken update"
  assert_contains "$out" "rolled back to 1.0.0" "the saved binary was not restored"
  assert_contains "$("$fakebin/selftool" --version)" "1.0.0" "the tool on disk is not the previous version"
  assert_contains "$(record_of "$home")" "selftool: health check failed" "the rollback was not written to the record"
  pass "a failed health check restores the saved previous binary and reports it"
}

test_failed_health_check_reinstalls_the_recorded_npm_version() {
  local home fakebin out
  home=$(make_home health-npm)
  fakebin="$TMP_ROOT/health-npm/fakebin"
  make_command "$fakebin" npmtool 1.0.0
  make_npm "$fakebin"
  # A health arg that passes only at the previous version, so the new install
  # fails its health check and the rollback has to bring 1.0.0 back.
  cat >> "$fakebin/npmtool" <<'SH'
[ "${1:-}" != health ] || [ "$(cat "$(dirname "$0")/.npmtool-version")" = 1.0.0 ]
SH
  write_config "$home" '{"tools":[{"name":"npmtool","class":"auto","command":"npmtool","npm_package":"npmtool","health_args":["health"]}]}'
  out=$(FM_HOME="$home" PATH="$(fixture_path "$fakebin")" FM_TEST_NPM_PUBLISHED=1.2.0 \
    FM_TEST_NPM_INSTALL_TO=1.2.0 FM_TEST_NPM_STATE="$fakebin/.npmtool-version" "$APPLY" apply)
  assert_contains "$out" "npmtool: failed: health check failed (" "a failed npm health check was not reported"
  assert_contains "$out" "rolled back to 1.0.0" "the recorded npm version was not reinstalled"
  assert_contains "$(cat "$fakebin/.npm-log")" "install -g npmtool@1.0.0" "npm was not asked to install the recorded version"
  assert_equals 1.0.0 "$(cat "$fakebin/.npmtool-version")" "the npm tool is not back at the previous version"

  printf '1.0.0\n' > "$fakebin/.npmtool-version"
  out=$(FM_HOME="$home" PATH="$(fixture_path "$fakebin")" FM_TEST_NPM_PUBLISHED=1.2.0 FM_TEST_NPM_EXACT_EXIT=1 \
    FM_TEST_NPM_INSTALL_TO=1.2.0 FM_TEST_NPM_STATE="$fakebin/.npmtool-version" "$APPLY" apply)
  assert_contains "$out" "ROLLBACK IMPOSSIBLE" "a rollback that npm refused was not reported loudly"
  assert_contains "$(record_of "$home")" "ROLLBACK IMPOSSIBLE" "an impossible rollback was not written to the record"
  pass "a failed npm health check reinstalls the recorded version, or says loudly that it could not"
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
test_npm_package_tool_is_installed_and_verified
test_npm_package_tool_already_current_is_not_installed
test_npm_package_install_that_does_not_take_is_a_failure
test_npm_refusals_are_skipped_not_retried
test_npm_package_schema_is_validated
test_no_argument_is_refused_rather_than_running_fleet
test_classes_gate_what_a_pass_applies
test_pin_is_never_exceeded
test_rollback_record_is_written_before_each_update
test_unwritable_rollback_record_stops_the_update
test_failed_health_check_restores_the_saved_binary
test_failed_health_check_reinstalls_the_recorded_npm_version
