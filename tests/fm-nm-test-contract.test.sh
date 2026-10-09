#!/usr/bin/env bash
# Contract: parsed .no-mistakes.yaml must leave commands.test absent or empty.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NM="$ROOT/.no-mistakes.yaml"

test_nm_has_no_deterministic_test_command() {
  command -v ruby >/dev/null 2>&1 \
    || fail "ruby is required to parse .no-mistakes.yaml for this contract"
  local val
  val=$(ruby -ryaml -e '
doc = YAML.load_file(ARGV[0]) || {}
cmds = doc["commands"] || {}
val = cmds.is_a?(Hash) ? cmds["test"] : nil
puts (val.nil? || val == false || val == "") ? "" : val.inspect
' "$NM") || fail "failed to parse .no-mistakes.yaml as YAML"
  if [ -n "$val" ]; then
    fail "commands.test must be absent or empty so Test stays intent-targeted; got: $val"
  fi
  pass "no-mistakes does not configure commands.test"
}

test_nm_has_no_deterministic_test_command

test_nm_test_instructions_carry_mac_rule() {
  local val
  val=$(ruby -ryaml -e '
doc = YAML.load_file(ARGV[0]) || {}
t = doc["test"].is_a?(Hash) ? doc["test"]["instructions"].to_s : ""
puts t
' "$NM") || fail "failed to parse .no-mistakes.yaml as YAML"
  case "$val" in
    *"taskpolicy -b"*"bosgame or netcup"*) pass "test.instructions carry the Mac single-file rule" ;;
    *) fail "test.instructions must carry the Mac single-file rule (taskpolicy -b; full suites on bosgame or netcup)" ;;
  esac
}

test_nm_test_instructions_carry_mac_rule
