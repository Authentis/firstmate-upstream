#!/usr/bin/env bash
# fm-tool-update.sh - apply watched-tool updates, the missing half of
# fm-tool-update-check.sh's detection.
#
# fm-tool-update-check.sh already watches config/watched-tools.json and reports
# what is outdated; it deliberately repairs nothing. This script is the thin
# driver that applies an update once the operator (or the check wake) decides
# to act, in the same shape fm-update.sh applies to the firstmate repo itself:
# a mechanical guarded script plus a captain-invocable skill that drives it.
# See the updatefirstmate skill for that pattern's pair.
#
# Usage:
#   fm-tool-update.sh [fleet]   apply on this host, then on every registered
#                                secondmate host (local and remote)
#   fm-tool-update.sh apply     apply only on this host (FM_HOME); this is the
#                                unit `fleet` runs per host, and what a remote
#                                dispatch through fm-on.sh invokes there
#   fm-tool-update.sh --help
#
# THE SAFETY MODEL: prefer each tool's own refusal over a guard of our own.
# `no-mistakes update` (without --force) already refuses outright while
# pipeline runs are active, so this script never passes --force to anything
# and treats a nonzero exit from an update command as that tool's own
# authoritative refusal - reported as skipped, never retried, never worked
# around. A git-tracked tool is updated with `git pull --ff-only`, which
# refuses the same way on a dirty tree or a diverged history: git's own
# refusal, not a firstmate-side count of who is using the checkout. No tool
# here is ever forced, stashed, or reset.
#
# Reuses config/watched-tools.json as the single inventory (see
# docs/configuration.md "Watched tool updates" for the full schema owner). The
# only addition is one optional per-tool field:
#
#   "update_args": ["<args that make the tool's own `command` apply its
#                     update, e.g. ["update"] for no-mistakes>"]
#
# A command tool without update_args is reported manual-only and never
# attempted; nothing is guessed at. A git tool needs no extra field - its
# existing git.repo/remote/branch are enough to attempt a fast-forward pull.
#
# Verify, never assume: a command tool is asked its own version before and
# after the update command runs. Exit 0 with an unchanged version is reported
# as a failure, not a success, because that is exactly the PATH-skew shape
# that bit this fleet twice (docs/configuration.md's PATH-skew note) - a copy
# can install correctly and still be invisible to the tool that PATH resolves.
# A git tool's own HEAD sha before/after is its verification; an unchanged sha
# after a clean `git pull --ff-only` means the tool was already current, which
# git itself distinguishes from a refusal by exit status.
#
# What this script never does: install a tool for the first time, change
# PATH or a version manager's configuration, retry a refusal, or maintain a
# second inventory, daemon, or schedule of its own. The "don't forget" loop is
# the existing tool-update check wake becoming actionable, not a new timer.
set -u
export LC_ALL=C
export GIT_TERMINAL_PROMPT=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/watched-tools.json"
SECONDMATES_MD="$DATA/secondmates.md"

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-tool-update.sh [fleet]   apply on this host, then on every registered
                               secondmate host (local and remote)
  fm-tool-update.sh apply     apply only on this host
  fm-tool-update.sh --help    print this help

Watched tools are read from config/watched-tools.json (local, gitignored).
See docs/configuration.md "Watched tool updates" for the schema, including
the optional per-tool update_args field this script consumes.
EOF
}

die_usage() {
  printf 'fm-tool-update: %s\n' "$1" >&2
  usage >&2
  exit 2
}

PROBE_SECS=${FM_TOOL_UPDATE_PROBE_SECS:-5}
case "$PROBE_SECS" in
  ''|*[!0-9]*|0)
    printf 'fm-tool-update: FM_TOOL_UPDATE_PROBE_SECS must be a whole number from 1 to 30\n' >&2
    exit 2
    ;;
esac
[ "$PROBE_SECS" -le 30 ] || {
  printf 'fm-tool-update: FM_TOOL_UPDATE_PROBE_SECS must be a whole number from 1 to 30\n' >&2
  exit 2
}

# Updating is slower than probing a version, so this bound is its own knob
# rather than reusing the check script's probe bound.
APPLY_SECS=${FM_TOOL_APPLY_SECS:-180}
case "$APPLY_SECS" in
  ''|*[!0-9]*|0)
    printf 'fm-tool-update: FM_TOOL_APPLY_SECS must be a whole number from 1 to 1800\n' >&2
    exit 2
    ;;
esac
[ "$APPLY_SECS" -le 1800 ] || {
  printf 'fm-tool-update: FM_TOOL_APPLY_SECS must be a whole number from 1 to 1800\n' >&2
  exit 2
}

# --- small helpers ------------------------------------------------------

first_line() { printf '%s\n' "$1" | tr '\t\r\n' '   ' | awk '{$1=$1;print}' | cut -c1-300; }

parse_version() {
  printf '%s' "$1" | grep -oE '[0-9]+(\.[0-9]+)+' | head -n 1
}

short_sha() { printf '%s' "$1" | cut -c1-12; }

version_probe() {  # <resolved-path> <args-joined>
  local path=$1 args=$2 out
  # shellcheck disable=SC2086  # deliberate split on validated space-free tokens
  out=$(fm_run_timed "$PROBE_SECS" "$path" $args 2>&1)
  parse_version "$out"
}

# One report line per tool, all in one place so both the summary counters and
# the printed text stay in sync with the outcome.
DONE_COUNT=0
SKIPPED_COUNT=0
FAILED_COUNT=0
MANUAL_COUNT=0
UNREACHABLE_COUNT=0

report() {  # <name> <outcome> <detail>
  local name=$1 outcome=$2 detail=$3
  case "$outcome" in
    done) DONE_COUNT=$((DONE_COUNT + 1)) ;;
    skipped) SKIPPED_COUNT=$((SKIPPED_COUNT + 1)) ;;
    failed) FAILED_COUNT=$((FAILED_COUNT + 1)) ;;
    manual) MANUAL_COUNT=$((MANUAL_COUNT + 1)) ;;
    unreachable) UNREACHABLE_COUNT=$((UNREACHABLE_COUNT + 1)) ;;
  esac
  printf '  %s: %s: %s\n' "$name" "$outcome" "$detail"
}

# --- watched tool registry ----------------------------------------------

CONFIG_PROBLEM=

config_validate() {
  local problem status
  if ! command -v jq >/dev/null 2>&1; then
    CONFIG_PROBLEM='jq is required to read the watched tool registry'
    return 1
  fi
  problem=$(jq -r '
    def tool_problem($t):
      if ($t | type) != "object" then "every entry in tools must be an object"
      elif ($t.name | type) != "string" or ($t.name | length) == 0 then "every tool needs a non-empty name"
      elif ($t | has("command") | not) and ($t | has("git") | not) then "tool \($t.name) needs command, git, or both"
      elif ($t | has("update_args")) and (($t.update_args | type) != "array" or ($t.update_args | length) == 0) then "tool \($t.name) update_args must be a non-empty array"
      elif ($t | has("update_args")) and ([$t.update_args[] | select((type != "string") or (test("^[A-Za-z0-9._=+/:-]+$") | not))] | length) > 0 then "tool \($t.name) update_args must be simple flag strings without spaces"
      elif ($t | has("update_args")) and (($t | has("command")) | not) then "tool \($t.name) update_args needs command"
      else empty
      end;
    def problems:
      if type != "object" then ["the top level must be an object"]
      elif (.tools | type) != "array" then ["tools must be an array"]
      elif (.tools | length) == 0 then ["tools must list at least one tool"]
      else [.tools[] | tool_problem(.)]
      end;
    problems | .[0] // "ok"
  ' "$CONFIG" 2>/dev/null)
  status=$?
  if [ "$status" -ne 0 ] || [ -z "$problem" ]; then
    CONFIG_PROBLEM='the watched tool registry is not valid JSON'
    return 1
  fi
  if [ "$problem" != ok ]; then
    CONFIG_PROBLEM=$problem
    return 1
  fi
  CONFIG_PROBLEM=
  return 0
}

FIELD_SEP=$(printf '\037')

config_records() {
  jq -r '
    .tools[] | [
      .name,
      (.command // ""),
      ((.version_args // ["--version"]) | join(" ")),
      ((.update_args // []) | join(" ")),
      (.git.repo // ""),
      (.git.remote // "origin"),
      (.git.branch // "")
    ] | join("\u001f")
  ' "$CONFIG" 2>/dev/null
}

# --- apply one tool -------------------------------------------------------

apply_command_tool() {  # <name> <command> <version-args> <update-args>
  local name=$1 command_name=$2 version_args=$3 update_args=$4
  local resolved before_version out status resolved_after after_version

  resolved=$(command -v "$command_name" 2>/dev/null) || resolved=
  if [ -z "$resolved" ]; then
    report "$name" "unreachable" "$command_name is not on PATH"
    return 0
  fi
  if [ -z "$update_args" ]; then
    report "$name" "manual" "no update_args configured - update it by hand"
    return 0
  fi

  before_version=$(version_probe "$resolved" "$version_args")

  # shellcheck disable=SC2086  # deliberate split on validated space-free tokens
  out=$(fm_run_timed "$APPLY_SECS" "$resolved" $update_args 2>&1)
  status=$?
  if [ "$status" -eq 124 ]; then
    report "$name" "skipped" "update did not finish within ${APPLY_SECS}s"
    return 0
  fi
  if [ "$status" -ne 0 ]; then
    report "$name" "skipped" "$resolved refused the update (exit $status): $(first_line "$out")"
    return 0
  fi

  resolved_after=$(command -v "$command_name" 2>/dev/null) || resolved_after=$resolved
  after_version=$(version_probe "$resolved_after" "$version_args")
  if [ -z "$after_version" ]; then
    report "$name" "failed" "update exited 0 but $resolved_after did not report a version afterward"
  elif [ -z "$before_version" ]; then
    report "$name" "done" "now $after_version (no version was readable beforehand)"
  elif [ "$after_version" = "$before_version" ]; then
    report "$name" "failed" "still $after_version after the update exited 0 - the update did not take effect"
  else
    report "$name" "done" "$before_version -> $after_version"
  fi
  return 0
}

apply_git_tool() {  # <name> <repo> <remote> <branch>
  local name=$1 repo=$2 remote=$3 branch=$4
  local before_sha out status after_sha

  command -v git >/dev/null 2>&1 || { report "$name" "unreachable" "git is not installed"; return 0; }
  [ -d "$repo" ] || { report "$name" "unreachable" "$repo is not a directory"; return 0; }
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || {
    report "$name" "unreachable" "$repo is not a git repository"
    return 0
  }

  if [ -z "$branch" ]; then
    branch=$(git -C "$repo" symbolic-ref --short "refs/remotes/$remote/HEAD" 2>/dev/null)
    branch=${branch#"$remote/"}
  fi
  if [ -z "$branch" ]; then
    report "$name" "unreachable" "cannot resolve the default branch of $remote in $repo"
    return 0
  fi

  before_sha=$(git -C "$repo" rev-parse --verify --quiet HEAD 2>/dev/null)
  out=$(fm_run_timed "$APPLY_SECS" git -C "$repo" pull --ff-only "$remote" "$branch" 2>&1)
  status=$?
  after_sha=$(git -C "$repo" rev-parse --verify --quiet HEAD 2>/dev/null)

  if [ "$status" -eq 124 ]; then
    report "$name" "skipped" "git pull --ff-only did not finish within ${APPLY_SECS}s"
  elif [ "$status" -ne 0 ]; then
    report "$name" "skipped" "git pull --ff-only refused: $(first_line "$out")"
  elif [ "$before_sha" = "$after_sha" ]; then
    report "$name" "done" "already current at $(short_sha "$after_sha")"
  else
    report "$name" "done" "$(short_sha "$before_sha") -> $(short_sha "$after_sha")"
  fi
  return 0
}

# --- one host --------------------------------------------------------------

action_apply() {
  local label=${1:-"this host ($FM_HOME)"}
  local name command_name version_args update_args repo remote branch

  printf 'host: %s\n' "$label"

  if [ ! -f "$CONFIG" ]; then
    printf '  nothing to apply: no config/watched-tools.json\n'
    printf 'host-summary: %s done=0 skipped=0 failed=0 manual=0 unreachable=0\n' "$label"
    return 0
  fi

  if ! config_validate; then
    printf '  watched tool registry: %s\n' "$CONFIG_PROBLEM"
    printf 'host-summary: %s done=0 skipped=0 failed=0 manual=0 unreachable=1\n' "$label"
    return 1
  fi

  while IFS=$FIELD_SEP read -r name command_name version_args update_args repo remote branch; do
    [ -n "$name" ] || continue
    [ -z "$command_name" ] || apply_command_tool "$name" "$command_name" "$version_args" "$update_args"
    [ -z "$repo" ] || apply_git_tool "$name" "$repo" "$remote" "$branch"
  done < <(config_records)

  printf 'host-summary: %s done=%s skipped=%s failed=%s manual=%s unreachable=%s\n' \
    "$label" "$DONE_COUNT" "$SKIPPED_COUNT" "$FAILED_COUNT" "$MANUAL_COUNT" "$UNREACHABLE_COUNT"
  return 0
}

# --- fleet -------------------------------------------------------------

FLEET_DONE=0
FLEET_SKIPPED=0
FLEET_FAILED=0
FLEET_MANUAL=0
FLEET_UNREACHABLE=0
FLEET_HOSTS=0

fold_host_summary() {  # <line>
  local line=$1 d s f m u
  case "$line" in
    host-summary:*)
      d=$(printf '%s\n' "$line" | grep -oE 'done=[0-9]+' | cut -d= -f2)
      s=$(printf '%s\n' "$line" | grep -oE 'skipped=[0-9]+' | cut -d= -f2)
      f=$(printf '%s\n' "$line" | grep -oE 'failed=[0-9]+' | cut -d= -f2)
      m=$(printf '%s\n' "$line" | grep -oE 'manual=[0-9]+' | cut -d= -f2)
      u=$(printf '%s\n' "$line" | grep -oE 'unreachable=[0-9]+' | cut -d= -f2)
      FLEET_DONE=$((FLEET_DONE + ${d:-0}))
      FLEET_SKIPPED=$((FLEET_SKIPPED + ${s:-0}))
      FLEET_FAILED=$((FLEET_FAILED + ${f:-0}))
      FLEET_MANUAL=$((FLEET_MANUAL + ${m:-0}))
      FLEET_UNREACHABLE=$((FLEET_UNREACHABLE + ${u:-0}))
      FLEET_HOSTS=$((FLEET_HOSTS + 1))
      ;;
  esac
}

run_local_secondmate() {  # <id> <home>
  local id=$1 home=$2 target out line
  target="$home/bin/fm-tool-update.sh"
  if [ ! -x "$target" ]; then
    printf 'host: fm-%s (%s)\n' "$id" "$home"
    printf '  nothing to apply: fm-tool-update.sh is not yet present in that home\n'
    printf 'host-summary: fm-%s (%s) done=0 skipped=0 failed=0 manual=0 unreachable=1\n' "$id" "$home"
    fold_host_summary "host-summary: fm-$id (unreachable) done=0 skipped=0 failed=0 manual=0 unreachable=1"
    return 0
  fi
  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE='' FM_DATA_OVERRIDE='' "$target" apply "fm-$id ($home)" 2>&1)
  printf '%s\n' "$out"
  while IFS= read -r line; do
    fold_host_summary "$line"
  done <<< "$out"
}

run_remote_secondmate() {  # <id> <host>
  local id=$1 host=$2 out line
  if out=$("$SCRIPT_DIR/fm-on.sh" "$id" fm-tool-update.sh apply < /dev/null 2>&1); then
    printf '%s\n' "$out"
    while IFS= read -r line; do
      fold_host_summary "$line"
    done <<< "$out"
  else
    printf 'host: fm-%s (%s)\n' "$id" "$host"
    printf '  unreachable: %s\n' "$(first_line "$out")"
    printf 'host-summary: fm-%s (%s) done=0 skipped=0 failed=0 manual=0 unreachable=1\n' "$id" "$host"
    fold_host_summary "host-summary: fm-$id (unreachable) done=0 skipped=0 failed=0 manual=0 unreachable=1"
  fi
}

action_fleet() {
  local line local_out

  local_out=$(action_apply "this host ($FM_HOME)")
  printf '%s\n' "$local_out"
  while IFS= read -r line; do
    fold_host_summary "$line"
  done <<< "$local_out"

  if [ -f "$SECONDMATES_MD" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        "- "*) ;;
        *) continue ;;
      esac
      if ! secondmate_registry_parse_line "$line"; then
        echo "secondmate registry: skipped malformed entry: $line" >&2
        continue
      fi
      if [ "$SECONDMATE_REGISTRY_REMOTE" -eq 1 ]; then
        run_remote_secondmate "$SECONDMATE_REGISTRY_ID" "$SECONDMATE_REGISTRY_HOST"
      else
        run_local_secondmate "$SECONDMATE_REGISTRY_ID" "$SECONDMATE_REGISTRY_HOME"
      fi
    done < "$SECONDMATES_MD"
  fi

  printf 'fleet-summary: hosts=%s done=%s skipped=%s failed=%s manual=%s unreachable=%s\n' \
    "$FLEET_HOSTS" "$FLEET_DONE" "$FLEET_SKIPPED" "$FLEET_FAILED" "$FLEET_MANUAL" "$FLEET_UNREACHABLE"
}

case "${1:-fleet}" in
  apply) action_apply "${2:-this host ($FM_HOME)}" ;;
  fleet) action_fleet ;;
  -h|--help) usage ;;
  *) die_usage "unknown action: $1" ;;
esac
