#!/usr/bin/env bash
# fm-lane-close-lib.sh - the opt-in that lets a finished lane reach a plain
# fm-teardown.sh on its own, and the after-merge teardown that uses it.
#
# Live closing is OFF by default. It is on for one home only while the file
# config/lane-close-live exists in that home (FM_CONFIG_OVERRIDE when set);
# removing the file turns it off. config/lane-reaper-live does not turn it on.
# Two callers act on it:
#   bin/fm-lane-reaper.sh   closes an idle done lane (its header owns which
#                           lanes qualify and when upstream pushes run).
#   bin/fm-pr-merge.sh and bin/fm-merge-local.sh
#                           call fm_lane_close_after_merge once their merge
#                           proof has succeeded.
# Both callers preserve commits through fm_lane_close_keep_commits before
# teardown. Commits absent from real remote-tracking refs require a standalone
# data/bundles/<id>-close.*.bundle; no-mistakes/* refs are not preservation proof.
# An existing same-HEAD bundle is reused only after a bare clone and full strict
# fsck prove its payload restorable. Otherwise a new full-history bundle is
# created and checked the same way before publication; failure prevents teardown.
# Teardown is always plain: never --force, so fm-teardown.sh's landed-work test
# decides, including refusal of dirty lanes. After-merge preservation failures
# and teardown refusals are reported on stderr without failing the proven merge
# or retrying here; the reaper owns later scan retries.
# After a successful close, both callers also close the lane's leftover tmux
# recorded window through fm_lane_close_window, which never closes one with a live process.
# Test seam: with FM_TEST_SEAM=1, FM_LANE_CLOSE_TEARDOWN replaces fm-teardown.sh.

FM_LANE_CLOSE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# fm_lane_close_live <home>: 0 when that home opted in to live closing.
fm_lane_close_live() {
  [ -e "${FM_CONFIG_OVERRIDE:-$1/config}/lane-close-live" ]
}

# fm_lane_close_teardown: prints the teardown executable to run.
fm_lane_close_teardown() {
  if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_LANE_CLOSE_TEARDOWN:-}" ]; then
    printf '%s\n' "$FM_LANE_CLOSE_TEARDOWN"
  else
    printf '%s\n' "$FM_LANE_CLOSE_LIB_DIR/fm-teardown.sh"
  fi
}

fm_lane_close_bundle_restorable() {
  local file=$1 head=$2 scratch rc=1
  git bundle list-heads "$file" 2>/dev/null | grep -qx "$head HEAD" || return 1
  scratch=$(mktemp -d "${file%/*}/.lane-close-verify.XXXXXX") || return 1
  if git clone --bare -q "$file" "$scratch/repo" >/dev/null 2>&1 \
    && [ "$(git -C "$scratch/repo" rev-parse HEAD 2>/dev/null)" = "$head" ] \
    && git -C "$scratch/repo" fsck --full --strict >/dev/null 2>&1; then
    rc=0
  fi
  rm -rf "$scratch"
  return "$rc"
}

fm_lane_close_keep_commits() {
  local home=$1 id=$2 wt=$3 head n dir tmp file
  head=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || return 1
  n=$(git -C "$wt" rev-list --count HEAD --not --exclude='no-mistakes/*' --remotes 2>/dev/null) || return 1
  [ "$n" -gt 0 ] || return 0
  dir="$home/data/bundles"
  mkdir -p "$dir" 2>/dev/null || return 1
  for file in "$dir/$id-close."*.bundle; do
    [ -f "$file" ] && [ ! -L "$file" ] || continue
    if fm_lane_close_bundle_restorable "$file" "$head"; then
      return 0
    fi
  done
  tmp=$(mktemp "$dir/$id-close.XXXXXX") || return 1
  file="$tmp.bundle"
  if git -C "$wt" bundle create -q "$tmp" HEAD >/dev/null 2>&1 \
    && fm_lane_close_bundle_restorable "$tmp" "$head" \
    && mv -f "$tmp" "$file"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# fm_lane_close_window_session <meta> <task-id>: the recorded tmux session,
# or nothing without an exact lane endpoint on the tmux backend.
fm_lane_close_window_session() {
  local backend window
  backend=$(awk -F= '$1 == "backend" { value=substr($0,9) } END { print value }' "$1" 2>/dev/null)
  case "$backend" in '' | tmux) ;; *) return 0 ;; esac
  window=$(awk -F= '$1 == "window" { value=substr($0,8) } END { print value }' "$1" 2>/dev/null)
  case "$window" in
    :* | *:*:*) return 0 ;;
    *:*) [ "${window#*:}" != "fm-$2" ] || printf '%s\n' "${window%%:*}" ;;
  esac
}

# fm_lane_close_window <session> <task-id>: after a successful close, closes the
# lane's tmux window <session>:fm-<id> if teardown left it behind. Only a window
# holding nothing but an idle shell is closed (bin/backends/tmux.sh's
# fm_backend_tmux_window_dead); the worktree and branch are not touched.
# Returns 0 when no such window remains and 1 when a window with a live process
# was left open. Runs in a subshell so sourcing the backend leaves callers as
# they were.
fm_lane_close_window() {
  [ -n "$1" ] || return 0
  (
    command -v tmux >/dev/null 2>&1 || exit 0
    # shellcheck source=bin/fm-backend.sh
    . "$FM_LANE_CLOSE_LIB_DIR/fm-backend.sh" && fm_backend_source tmux || exit 0
    windows=$(fm_backend_tmux_window_inventory "=$1") || exit 0
    printf '%s\n' "$windows" | grep -qxF -- "fm-$2" || exit 0
    fm_backend_tmux_window_dead "$1" "fm-$2" && fm_backend_tmux_kill "$1:fm-$2" 2>/dev/null
  )
}

# fm_lane_close_after_merge <home> <state> <task-id>: after a proven merge, run a
# plain teardown when the home opted in. Always returns 0: the merge already
# landed, so a refused teardown is reported and the lane is left for review.
fm_lane_close_after_merge() {
  local home=$1 state=$2 id=$3 rc=0 wt ses
  if ! fm_lane_close_live "$home"; then
    printf 'lane close: dry-run, would tear down %s (live needs config/lane-close-live)\n' "$id"
    return 0
  fi
  wt=$(awk -F= '$1 == "worktree" { value=substr($0,10) } END { print value }' "$state/$id.meta")
  ses=$(fm_lane_close_window_session "$state/$id.meta" "$id")
  if ! fm_lane_close_keep_commits "$home" "$id" "$wt"; then
    printf 'actionable: merged, but preservation of %s failed; the lane is kept for review\n' "$id" >&2
    return 0
  fi
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$(fm_lane_close_teardown)" "$id" >&2 || rc=$?
  case "$rc" in
    0 | 4)
      printf 'lane close: tore down %s after the merge\n' "$id"
      fm_lane_close_window "$ses" "$id" \
        || printf 'actionable: window %s:fm-%s still runs a process, so it was left open\n' "$ses" "$id" >&2
      ;;
    *) printf 'actionable: merged, but teardown of %s refused (rc=%s); the lane is kept for review\n' "$id" "$rc" >&2 ;;
  esac
  return 0
}
