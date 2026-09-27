#!/usr/bin/env bash
# Claude task-worker session scratch: the single owner of the session identity
# format and of how a recorded identity resolves to its scratch directory.
#
# Claude Code keeps each session's scratchpad (and its background-task output)
# at ${CLAUDE_CODE_TMPDIR:-/tmp}/claude-<uid>/<cwd slug>/<session-id>/, where
# the slug is the session's real working directory with every character other
# than [A-Za-z0-9] replaced by '-' (verified against Claude Code 2.1.283 on
# macOS, where /tmp resolves to /private/tmp). That directory outlives the
# session, and reused worker copies share one slug, so only the session id
# says which directory belonged to a task.
#
# bin/fm-spawn.sh launches a claude ship or scout worker with --session-id and
# records every launch's id in the task record as claude_session_ids= (space
# separated). bin/fm-teardown.sh removes exactly those session directories and
# nothing else. Firstmate only ever removes under the default /tmp root, never
# a CLAUDE_CODE_TMPDIR it cannot see from the worker's pane.
# FM_CLAUDE_SCRATCH_ROOT overrides the per-uid root for tests only.
#
# Functions:
#   fm_claude_session_id_new            print a fresh lowercase UUID, or fail
#   fm_claude_session_id_valid <id>     succeed only for a lowercase UUID
#   fm_claude_scratch_root              print /tmp/claude-<uid> (or the override)
#   fm_claude_scratch_slug <cwd>        print Claude's slug for a working directory
#   fm_claude_scratch_resolve <cwd> <id>
#       Print the session directory for <id> when it is a real directory owned
#       by this user directly under <root>/<slug>/, with neither the root nor
#       the slug directory a symlink. Otherwise print one reason line and fail
#       with 2 when the directory is simply absent, or 1 when the identity or
#       path does not match the expected shape.

fm_claude_session_id_valid() {
  case "${1:-}" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) return 0 ;;
  esac
  return 1
}

fm_claude_session_id_new() {
  local id
  id=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || true)
  id=$(printf '%s' "$id" | tr 'A-F' 'a-f')
  fm_claude_session_id_valid "$id" || return 1
  printf '%s\n' "$id"
}

fm_claude_scratch_root() {
  if [ -n "${FM_CLAUDE_SCRATCH_ROOT:-}" ]; then
    printf '%s\n' "$FM_CLAUDE_SCRATCH_ROOT"
  else
    printf '/tmp/claude-%s\n' "$(id -u)"
  fi
}

fm_claude_scratch_slug() {
  printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9' '-'
}

fm_claude_scratch_resolve() {  # <cwd> <session-id>
  local cwd=${1:-} id=${2:-} real root slug dir
  if ! fm_claude_session_id_valid "$id"; then
    echo "recorded Claude session id '$id' is not a UUID"
    return 1
  fi
  case "$cwd" in
    /*) ;;
    *) echo "recorded worktree '$cwd' is not an absolute path"; return 1 ;;
  esac
  real=$(cd "$cwd" 2>/dev/null && pwd -P) || real=$cwd
  slug=$(fm_claude_scratch_slug "$real")
  # Claude shortens very long slugs with a hash suffix; never guess that form.
  if [ "${#slug}" -gt 200 ]; then
    echo "worktree path is too long for an exact Claude slug"
    return 1
  fi
  root=$(fm_claude_scratch_root)
  if [ -L "$root" ] || { [ -e "$root" ] && { [ ! -d "$root" ] || [ ! -O "$root" ]; }; }; then
    echo "$root is not a directory owned by this user"
    return 1
  fi
  dir="$root/$slug/$id"
  if [ ! -e "$dir" ] && [ ! -L "$dir" ]; then
    echo "no scratch at $dir"
    return 2
  fi
  if [ -L "$root/$slug" ] || [ -L "$dir" ] || [ ! -d "$dir" ] || [ ! -O "$dir" ]; then
    echo "$dir is not a session directory owned by this user"
    return 1
  fi
  printf '%s\n' "$dir"
}
