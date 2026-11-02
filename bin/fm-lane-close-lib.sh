#!/usr/bin/env bash
# fm-lane-close-lib.sh - the opt-in that lets a finished lane reach a plain
# fm-teardown.sh on its own, and the after-merge teardown that uses it.
#
# Live closing is OFF by default. It is on for one home only while the file
# config/lane-close-live exists in that home (FM_CONFIG_OVERRIDE when set);
# removing the file turns it off. config/lane-reaper-live does not turn it on.
# Two callers act on it:
#   bin/fm-lane-reaper.sh   closes an idle done lane (its header owns which
#                           lanes and how unpushed commits are kept first).
#   bin/fm-pr-merge.sh and bin/fm-merge-local.sh
#                           call fm_lane_close_after_merge once their merge
#                           proof has succeeded.
# Teardown is always plain: never --force, so fm-teardown.sh's landed-work test
# decides. A refusal is printed on stderr and never bypassed or retried here.
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

fm_lane_close_keep_commits() {
  local home=$1 id=$2 wt=$3 head n dir tmp file
  head=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || return 1
  n=$(git -C "$wt" rev-list --count HEAD --not --exclude='no-mistakes/*' --remotes 2>/dev/null) || return 1
  [ "$n" -gt 0 ] || return 0
  dir="$home/data/bundles"
  mkdir -p "$dir" 2>/dev/null || return 1
  for file in "$dir/$id-close."*.bundle; do
    [ -f "$file" ] && [ ! -L "$file" ] || continue
    if git -C "$wt" bundle verify -q "$file" >/dev/null 2>&1 \
      && git -C "$wt" bundle list-heads "$file" 2>/dev/null | grep -qx "$head HEAD"; then
      return 0
    fi
  done
  tmp=$(mktemp "$dir/$id-close.XXXXXX") || return 1
  file="$tmp.bundle"
  if git -C "$wt" bundle create -q "$tmp" HEAD >/dev/null 2>&1 \
    && git -C "$wt" bundle verify -q "$tmp" >/dev/null 2>&1 \
    && git -C "$wt" bundle list-heads "$tmp" 2>/dev/null | grep -qx "$head HEAD" \
    && mv -f "$tmp" "$file"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# fm_lane_close_after_merge <home> <state> <task-id>: after a proven merge, run a
# plain teardown when the home opted in. Always returns 0: the merge already
# landed, so a refused teardown is reported and the lane is left for review.
fm_lane_close_after_merge() {
  local home=$1 state=$2 id=$3 rc=0 wt
  if ! fm_lane_close_live "$home"; then
    printf 'lane close: dry-run, would tear down %s (live needs config/lane-close-live)\n' "$id"
    return 0
  fi
  wt=$(awk -F= '$1 == "worktree" { value=substr($0,10) } END { print value }' "$state/$id.meta")
  if ! fm_lane_close_keep_commits "$home" "$id" "$wt"; then
    printf 'actionable: merged, but preservation of %s failed; the lane is kept for review\n' "$id" >&2
    return 0
  fi
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$(fm_lane_close_teardown)" "$id" >&2 || rc=$?
  case "$rc" in
    0 | 4) printf 'lane close: tore down %s after the merge\n' "$id" ;;
    *) printf 'actionable: merged, but teardown of %s refused (rc=%s); the lane is kept for review\n' "$id" "$rc" >&2 ;;
  esac
  return 0
}
