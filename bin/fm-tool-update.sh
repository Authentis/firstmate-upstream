#!/usr/bin/env bash
# fm-tool-update.sh - apply watched-tool updates, the missing half of
# fm-tool-update-check.sh's detection.
#
# fm-tool-update-check.sh already watches config/watched-tools.json and reports
# what is outdated; it deliberately repairs nothing. This script is the thin
# driver that applies an update once the operator decides; a check wake only
# reports. It has the same shape fm-update.sh applies to the firstmate repo itself:
# a mechanical guarded script plus a captain-invocable skill that drives it.
# See the updatefirstmate skill for that pattern's pair.
#
# Usage:
#   fm-tool-update.sh apply [--class auto|quiet] [label]
#                                apply only on this host (FM_HOME); this is the
#                                unit `fleet` runs per host, and what a remote
#                                dispatch through fm-on.sh invokes there
#   fm-tool-update.sh fleet [--class auto|quiet]
#                                apply on this host, then on every registered
#                                secondmate host (local and remote); only on an
#                                explicit human word naming those hosts -
#                                automation never runs fleet
#   fm-tool-update.sh --help
#
# An explicit action is required: running with no argument is refused, because
# the old no-argument default was fleet and reached every registered host.
#
# APPLY CLASSES: each tool carries an optional "class" - auto, quiet, or
# manual - and an absent class is manual, so nothing starts applying from an
# existing config. A pass applies exactly one class: auto by default, quiet
# with --class quiet (a host's own quiet-window step). A manual tool is never
# applied by this script; it is reported manual. A tool of the other class is
# reported held and left alone.
#
# PIN: an optional "pin" is the highest version the applier may install. A
# tool already at or past its pin is held. An npm_package tool whose published
# version is past its pin is installed at exactly the pin. A self-updating
# tool (update_args) with a pin is always held, because its own update command
# cannot be told a target version and could move past the pin.
#
# ROLLBACK RECORD: before each command-tool update, one line naming the
# previous version and the binary path (or npm package@version) is appended to
# data/tool-updates/<YYYY-MM-DD>.md, and a self-updating tool's resolved binary
# is copied to data/tool-updates/backup/ first. If that record cannot be
# written the update is not attempted. A git tool's line records its previous
# HEAD; it is never rolled back, because that would mean a reset.
#
# HEALTH CHECK AND ROLLBACK: after an update that moved the version, the tool
# must answer its version probe and, when "health_args" is set, run those args
# with exit 0 inside FM_TOOL_HEALTH_SECS. A failed health check rolls back: an
# npm tool reinstalls the recorded version, a self-updating tool gets its saved
# binary copied back, and the restored copy must report the previous version.
# A rollback that cannot be done or does not verify is reported
# "ROLLBACK IMPOSSIBLE" in the failed line and in the record.
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
# docs/configuration.md "Watched tool updates" for the full schema owner). It
# consumes one of two optional per-tool fields on a command tool:
#
#   "update_args": ["<args that make the tool's own `command` apply its
#                     update, e.g. ["update"] for no-mistakes>"]
#   "npm_package": "<npm package that installs `command`, e.g. tasks-axi>"
#
# An npm_package tool has no self-update command of its own, so it is updated
# with `npm install -g <pkg>@latest`, the same command bootstrap installs it
# with. The published version is asked first (`npm view <pkg> version`); a tool
# already at or past it is reported done without installing, and a published version
# that cannot be read is reported skipped rather than installed blind.
#
# A command tool with neither field is reported manual-only and never
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
  fm-tool-update.sh apply [--class auto|quiet] [label]
                              apply only on this host (default class auto)
  fm-tool-update.sh fleet [--class auto|quiet]
                              apply on this host, then on every registered
                              secondmate host; never run by automation
  fm-tool-update.sh --help    print this help

An explicit action is required. A manual-class tool is never applied.
Watched tools are read from config/watched-tools.json (local, gitignored).
See docs/configuration.md "Watched tool updates" for the schema, including
the per-tool class, pin, health_args, update_args, and npm_package fields
this script consumes.
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

HEALTH_SECS=${FM_TOOL_HEALTH_SECS:-30}
case "$HEALTH_SECS" in
  ''|*[!0-9]*|0)
    printf 'fm-tool-update: FM_TOOL_HEALTH_SECS must be a whole number from 1 to 300\n' >&2
    exit 2
    ;;
esac
[ "$HEALTH_SECS" -le 300 ] || {
  printf 'fm-tool-update: FM_TOOL_HEALTH_SECS must be a whole number from 1 to 300\n' >&2
  exit 2
}

ROLLBACK_DIR="$DATA/tool-updates"
ROLLBACK_BACKUP_DIR="$ROLLBACK_DIR/backup"
APPLY_CLASS=auto

# --- small helpers ------------------------------------------------------

first_line() { printf '%s\n' "$1" | tr '\t\r\n' '   ' | awk '{$1=$1;print}' | cut -c1-300; }

parse_version() {
  printf '%s' "$1" | grep -oE '[0-9]+(\.[0-9]+)+' | head -n 1
}

# version_newer <a> <b>: true when version a is numerically newer than b.
version_newer() {
  local a=$1 b=$2 i left right
  local -a ap bp
  IFS=. read -r -a ap <<< "$a"
  IFS=. read -r -a bp <<< "$b"
  i=0
  while [ "$i" -lt "${#ap[@]}" ] || [ "$i" -lt "${#bp[@]}" ]; do
    left=$((10#${ap[i]:-0}))
    right=$((10#${bp[i]:-0}))
    [ "$left" -eq "$right" ] || { [ "$left" -gt "$right" ]; return; }
    i=$((i + 1))
  done
  return 1
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
HELD_COUNT=0

report() {  # <name> <outcome> <detail>
  local name=$1 outcome=$2 detail=$3
  case "$outcome" in
    done) DONE_COUNT=$((DONE_COUNT + 1)) ;;
    skipped) SKIPPED_COUNT=$((SKIPPED_COUNT + 1)) ;;
    failed) FAILED_COUNT=$((FAILED_COUNT + 1)) ;;
    manual) MANUAL_COUNT=$((MANUAL_COUNT + 1)) ;;
    unreachable) UNREACHABLE_COUNT=$((UNREACHABLE_COUNT + 1)) ;;
    held) HELD_COUNT=$((HELD_COUNT + 1)) ;;
  esac
  printf '  %s: %s: %s\n' "$name" "$outcome" "$detail"
}

# --- rollback record --------------------------------------------------------

rollback_record_file() {
  printf '%s/%s.md\n' "$ROLLBACK_DIR" "$(date +%Y-%m-%d)"
}

# Append one line to today's rollback record, creating it with a heading the
# first time. A failure here is returned, so the caller can refuse to update a
# tool whose rollback would not be recorded.
rollback_note() {  # <line>
  local file
  file=$(rollback_record_file)
  mkdir -p "$ROLLBACK_DIR" 2>/dev/null || return 1
  if [ ! -f "$file" ]; then
    printf '# Tool updates %s\n\n' "$(date +%Y-%m-%d)" >> "$file" 2>/dev/null || return 1
  fi
  printf -- '- %s %s\n' "$(date +%H:%M:%S)" "$1" >> "$file" 2>/dev/null
}

# The real file a resolved command runs, so a symlinked install is backed up
# and restored at its target rather than by replacing the link.
real_file() {
  local path=$1 dir link
  while [ -L "$path" ]; do
    link=$(readlink "$path") || return 1
    case "$link" in
      /*) path=$link ;;
      *) dir=$(dirname "$path"); path="$dir/$link" ;;
    esac
  done
  dir=$(cd "$(dirname "$path")" 2>/dev/null && pwd -P) || return 1
  printf '%s/%s\n' "$dir" "$(basename "$path")"
}

# Copy the binary a self-updating tool is about to replace. Prints the backup
# path, or nothing when no copy could be made.
backup_binary() {  # <name> <real-path> <version>
  local name=$1 real=$2 version=$3 dest
  mkdir -p "$ROLLBACK_BACKUP_DIR" 2>/dev/null || return 1
  dest="$ROLLBACK_BACKUP_DIR/$name-${version:-unknown}-$(date +%s)"
  cp -p -- "$real" "$dest" 2>/dev/null || { rm -f -- "$dest"; return 1; }
  printf '%s\n' "$dest"
}

# Put a saved binary back in place by rename, so the path never holds a
# half-written copy.
restore_binary() {  # <backup> <real-path>
  local backup=$1 real=$2 tmp
  tmp="$real.fm-rollback.$$"
  cp -p -- "$backup" "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$real" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
}

# The health check: the tool answers its version probe, and health_args, when
# set, exits 0. Prints the reason on failure.
health_check() {  # <resolved-path> <version-args> <health-args>
  local path=$1 version_args=$2 health_args=$3 out status
  if [ -z "$(version_probe "$path" "$version_args")" ]; then
    printf '%s did not answer its version probe' "$path"
    return 1
  fi
  [ -n "$health_args" ] || return 0
  # shellcheck disable=SC2086  # deliberate split on validated space-free tokens
  out=$(fm_run_timed "$HEALTH_SECS" "$path" $health_args 2>&1)
  status=$?
  [ "$status" -eq 0 ] && return 0
  printf '%s %s exited %s: %s' "$path" "$health_args" "$status" "$(first_line "$out")"
  return 1
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
      elif ($t | has("npm_package")) and (($t.npm_package | type) != "string" or ($t.npm_package | test("^(@[a-z0-9][a-z0-9._-]*/)?[a-z0-9][a-z0-9._-]*$") | not)) then "tool \($t.name) npm_package must be a plain npm package name"
      elif ($t | has("npm_package")) and (($t | has("command")) | not) then "tool \($t.name) npm_package needs command"
      elif ($t | has("npm_package")) and ($t | has("update_args")) then "tool \($t.name) may set update_args or npm_package, not both"
      elif ($t | has("class")) and (($t.class | type) != "string" or ($t.class | IN("auto","quiet","manual") | not)) then "tool \($t.name) class must be auto, quiet, or manual"
      elif ($t | has("pin")) and (($t.pin | type) != "string" or ($t.pin | test("^[0-9]+(\\.[0-9]+)+$") | not)) then "tool \($t.name) pin must be a dotted version such as 1.2.3"
      elif ($t | has("pin")) and (($t | has("command")) | not) then "tool \($t.name) pin needs command"
      elif ($t | has("health_args")) and (($t.health_args | type) != "array" or ($t.health_args | length) == 0) then "tool \($t.name) health_args must be a non-empty array"
      elif ($t | has("health_args")) and ([$t.health_args[] | select((type != "string") or (test("^[A-Za-z0-9._=+/:-]+$") | not))] | length) > 0 then "tool \($t.name) health_args must be simple flag strings without spaces"
      elif ($t | has("health_args")) and (($t | has("command")) | not) then "tool \($t.name) health_args needs command"
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
      (.git.branch // ""),
      (.npm_package // ""),
      (.class // "manual"),
      (.pin // ""),
      ((.health_args // []) | join(" "))
    ] | join("\u001f")
  ' "$CONFIG" 2>/dev/null
}

# --- apply one tool -------------------------------------------------------

# Class and pin gate, shared by both tool kinds. True when this pass may try
# the tool; otherwise the outcome is already reported.
class_allows() {  # <name> <class>
  local name=$1 class=$2
  if [ "$class" = manual ]; then
    report "$name" "manual" "class manual - never applied by this script, update it by hand"
    return 1
  fi
  if [ "$class" != "$APPLY_CLASS" ]; then
    report "$name" "held" "class $class - not applied in a $APPLY_CLASS pass"
    return 1
  fi
  return 0
}

# Roll a command tool back after a failed health check, and report the result.
rollback_command_tool() {  # <name> <command> <version-args> <before-version> <npm-bin> <npm-package> <real-path> <backup> <why>
  local name=$1 command_name=$2 version_args=$3 before_version=$4 npm_bin=$5 npm_package=$6
  local real=$7 backup=$8 why=$9 out status resolved restored impossible=''

  if [ -z "$before_version" ]; then
    impossible='no previous version was readable'
  elif [ -n "$npm_package" ]; then
    out=$(fm_run_timed "$APPLY_SECS" "$npm_bin" install -g "$npm_package@$before_version" 2>&1)
    status=$?
    [ "$status" -eq 0 ] || impossible="npm install -g $npm_package@$before_version exited $status: $(first_line "$out")"
  elif [ -z "$backup" ]; then
    impossible='no copy of the previous binary could be saved'
  elif ! restore_binary "$backup" "$real"; then
    impossible="could not copy $backup back to $real"
  fi

  if [ -z "$impossible" ]; then
    resolved=$(command -v "$command_name" 2>/dev/null) || resolved=
    restored=
    [ -z "$resolved" ] || restored=$(version_probe "$resolved" "$version_args")
    [ "$restored" = "$before_version" ] \
      || impossible="the restored copy reports ${restored:-no version}, not $before_version"
  fi

  if [ -n "$impossible" ]; then
    rollback_note "$name: health check failed ($why); ROLLBACK IMPOSSIBLE: $impossible" || true
    report "$name" "failed" "health check failed ($why) and ROLLBACK IMPOSSIBLE: $impossible"
  else
    rollback_note "$name: health check failed ($why); rolled back to $before_version" || true
    report "$name" "failed" "health check failed ($why); rolled back to $before_version"
  fi
}

apply_command_tool() {  # <name> <command> <version-args> <update-args> <npm-package> <pin> <health-args>
  local name=$1 command_name=$2 version_args=$3 update_args=$4 npm_package=$5 pin=$6 health_args=$7
  local resolved before_version out status resolved_after after_version
  local npm_bin='' published='' target='' real='' backup='' why

  resolved=$(command -v "$command_name" 2>/dev/null) || resolved=
  if [ -z "$resolved" ]; then
    report "$name" "unreachable" "$command_name is not on PATH"
    return 0
  fi
  if [ -z "$update_args" ] && [ -z "$npm_package" ]; then
    report "$name" "manual" "no update_args or npm_package configured - update it by hand"
    return 0
  fi

  before_version=$(version_probe "$resolved" "$version_args")

  if [ -n "$pin" ]; then
    if [ -n "$before_version" ] && ! version_newer "$pin" "$before_version"; then
      report "$name" "held" "pinned at $pin, already at $before_version"
      return 0
    fi
    if [ -z "$npm_package" ]; then
      report "$name" "held" "pinned at $pin - its own update command cannot be held below a pin"
      return 0
    fi
  fi

  if [ -n "$npm_package" ]; then
    npm_bin=$(command -v npm 2>/dev/null) || npm_bin=
    if [ -z "$npm_bin" ]; then
      report "$name" "unreachable" "npm is not on PATH to update $npm_package"
      return 0
    fi
    out=$(fm_run_timed "$PROBE_SECS" "$npm_bin" view "$npm_package" version 2>&1)
    status=$?
    published=$(parse_version "$out")
    if [ "$status" -ne 0 ] || [ -z "$published" ]; then
      report "$name" "skipped" "could not read the published version of $npm_package (exit $status): $(first_line "$out")"
      return 0
    fi
    target=$published
    [ -z "$pin" ] || ! version_newer "$published" "$pin" || target=$pin
    # Never let an install move a copy that is already at or past its target.
    if [ -n "$before_version" ] && ! version_newer "$target" "$before_version"; then
      report "$name" "done" "already current at $before_version (published $published)"
      return 0
    fi
    if ! rollback_note "$name: previous ${before_version:-unknown} at $resolved; npm $npm_package@${before_version:-unknown}; installing $npm_package@$target"; then
      report "$name" "skipped" "could not write the rollback record in $ROLLBACK_DIR - not updating without it"
      return 0
    fi
    if [ "$target" = "$published" ]; then
      out=$(fm_run_timed "$APPLY_SECS" "$npm_bin" install -g "$npm_package@latest" 2>&1)
    else
      out=$(fm_run_timed "$APPLY_SECS" "$npm_bin" install -g "$npm_package@$target" 2>&1)
    fi
  else
    real=$(real_file "$resolved") || real=$resolved
    backup=$(backup_binary "$name" "$real" "$before_version") || backup=
    if ! rollback_note "$name: previous ${before_version:-unknown} at $real; backup ${backup:-none (no copy could be saved)}"; then
      report "$name" "skipped" "could not write the rollback record in $ROLLBACK_DIR - not updating without it"
      return 0
    fi
    # shellcheck disable=SC2086  # deliberate split on validated space-free tokens
    out=$(fm_run_timed "$APPLY_SECS" "$resolved" $update_args 2>&1)
  fi
  status=$?
  if [ "$status" -eq 124 ]; then
    report "$name" "skipped" "update did not finish within ${APPLY_SECS}s"
    return 0
  fi
  if [ "$status" -ne 0 ]; then
    if [ -n "$npm_package" ]; then
      report "$name" "skipped" "npm refused to install $npm_package@$([ "$target" = "$published" ] && echo latest || echo "$target") (exit $status): $(first_line "$out")"
    else
      report "$name" "skipped" "$resolved refused the update (exit $status): $(first_line "$out")"
    fi
    return 0
  fi

  resolved_after=$(command -v "$command_name" 2>/dev/null) || resolved_after=$resolved
  after_version=$(version_probe "$resolved_after" "$version_args")
  if [ -n "$after_version" ] && [ -n "$before_version" ] && [ "$after_version" = "$before_version" ]; then
    report "$name" "failed" "still $after_version after the update exited 0 - the update did not take effect"
    return 0
  fi
  if ! why=$(health_check "$resolved_after" "$version_args" "$health_args"); then
    rollback_command_tool "$name" "$command_name" "$version_args" "$before_version" "$npm_bin" "$npm_package" "$real" "$backup" "$why"
    return 0
  fi
  if [ -z "$before_version" ]; then
    report "$name" "done" "now $after_version (no version was readable beforehand)"
  elif [ -n "$target" ] && [ "$after_version" != "$target" ]; then
    report "$name" "failed" "npm installed $npm_package@$([ "$target" = "$published" ] && echo latest || echo "$target") ($target) but $resolved_after reports $after_version"
  else
    rollback_note "$name: now $after_version, health check passed" || true
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
  if ! rollback_note "$name: previous HEAD $before_sha in $repo"; then
    report "$name" "skipped" "could not write the rollback record in $ROLLBACK_DIR - not updating without it"
    return 0
  fi
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

host_summary() {  # <label> <done> <skipped> <failed> <manual> <unreachable> <held>
  printf 'host-summary: %s done=%s skipped=%s failed=%s manual=%s unreachable=%s held=%s\n' "$@"
}

action_apply() {
  local label=${1:-"this host ($FM_HOME)"}
  local name command_name version_args update_args repo remote branch npm_package class pin health_args

  printf 'host: %s (class %s)\n' "$label" "$APPLY_CLASS"

  if [ ! -f "$CONFIG" ]; then
    printf '  nothing to apply: no config/watched-tools.json\n'
    host_summary "$label" 0 0 0 0 0 0
    return 0
  fi

  if ! config_validate; then
    printf '  watched tool registry: %s\n' "$CONFIG_PROBLEM"
    host_summary "$label" 0 0 0 0 1 0
    return 1
  fi

  while IFS=$FIELD_SEP read -r name command_name version_args update_args repo remote branch npm_package class pin health_args; do
    [ -n "$name" ] || continue
    class_allows "$name" "$class" || continue
    [ -z "$command_name" ] || apply_command_tool "$name" "$command_name" "$version_args" "$update_args" "$npm_package" "$pin" "$health_args"
    [ -z "$repo" ] || apply_git_tool "$name" "$repo" "$remote" "$branch"
  done < <(config_records)

  host_summary "$label" "$DONE_COUNT" "$SKIPPED_COUNT" "$FAILED_COUNT" "$MANUAL_COUNT" "$UNREACHABLE_COUNT" "$HELD_COUNT"
  return 0
}

# --- fleet -------------------------------------------------------------

FLEET_DONE=0
FLEET_SKIPPED=0
FLEET_FAILED=0
FLEET_MANUAL=0
FLEET_UNREACHABLE=0
FLEET_HELD=0
FLEET_HOSTS=0

fold_host_summary() {  # <line>
  local line=$1 d s f m u h
  case "$line" in
    host-summary:*)
      d=$(printf '%s\n' "$line" | grep -oE 'done=[0-9]+' | cut -d= -f2)
      s=$(printf '%s\n' "$line" | grep -oE 'skipped=[0-9]+' | cut -d= -f2)
      f=$(printf '%s\n' "$line" | grep -oE 'failed=[0-9]+' | cut -d= -f2)
      m=$(printf '%s\n' "$line" | grep -oE 'manual=[0-9]+' | cut -d= -f2)
      u=$(printf '%s\n' "$line" | grep -oE 'unreachable=[0-9]+' | cut -d= -f2)
      h=$(printf '%s\n' "$line" | grep -oE 'held=[0-9]+' | cut -d= -f2)
      FLEET_DONE=$((FLEET_DONE + ${d:-0}))
      FLEET_SKIPPED=$((FLEET_SKIPPED + ${s:-0}))
      FLEET_FAILED=$((FLEET_FAILED + ${f:-0}))
      FLEET_MANUAL=$((FLEET_MANUAL + ${m:-0}))
      FLEET_UNREACHABLE=$((FLEET_UNREACHABLE + ${u:-0}))
      FLEET_HELD=$((FLEET_HELD + ${h:-0}))
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
    host_summary "fm-$id ($home)" 0 0 0 0 1 0
    fold_host_summary "host-summary: fm-$id (unreachable) unreachable=1"
    return 0
  fi
  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE='' FM_DATA_OVERRIDE='' "$target" apply --class "$APPLY_CLASS" "fm-$id ($home)" 2>&1)
  printf '%s\n' "$out"
  while IFS= read -r line; do
    fold_host_summary "$line"
  done <<< "$out"
}

run_remote_secondmate() {  # <id> <host>
  local id=$1 host=$2 out line
  if out=$("$SCRIPT_DIR/fm-on.sh" "$id" fm-tool-update.sh apply --class "$APPLY_CLASS" < /dev/null 2>&1); then
    printf '%s\n' "$out"
    while IFS= read -r line; do
      fold_host_summary "$line"
    done <<< "$out"
  else
    printf 'host: fm-%s (%s)\n' "$id" "$host"
    printf '  unreachable: %s\n' "$(first_line "$out")"
    host_summary "fm-$id ($host)" 0 0 0 0 1 0
    fold_host_summary "host-summary: fm-$id (unreachable) unreachable=1"
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

  printf 'fleet-summary: hosts=%s done=%s skipped=%s failed=%s manual=%s unreachable=%s held=%s\n' \
    "$FLEET_HOSTS" "$FLEET_DONE" "$FLEET_SKIPPED" "$FLEET_FAILED" "$FLEET_MANUAL" "$FLEET_UNREACHABLE" "$FLEET_HELD"
}

# Reads an optional --class <auto|quiet> into APPLY_CLASS and leaves the
# remaining arguments in PARSED_ARGS.
PARSED_ARGS=()
parse_class() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --class)
        [ "$#" -ge 2 ] || die_usage "--class needs auto or quiet"
        case "$2" in
          auto|quiet) APPLY_CLASS=$2 ;;
          manual) die_usage "a manual-class tool is never applied by this script" ;;
          *) die_usage "--class must be auto or quiet, not $2" ;;
        esac
        shift 2
        ;;
      *) PARSED_ARGS+=("$1"); shift ;;
    esac
  done
}

[ "$#" -gt 0 ] || die_usage "an explicit action is required (apply for this host; fleet only on an explicit human word)"
action=$1
shift
case "$action" in
  apply)
    parse_class "$@"
    [ "${#PARSED_ARGS[@]}" -le 1 ] || die_usage "apply takes at most one label"
    action_apply "${PARSED_ARGS[0]:-this host ($FM_HOME)}"
    ;;
  fleet)
    parse_class "$@"
    [ "${#PARSED_ARGS[@]}" -eq 0 ] || die_usage "fleet takes no other arguments"
    action_fleet
    ;;
  -h|--help) usage ;;
  *) die_usage "unknown action: $action" ;;
esac
