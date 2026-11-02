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

# fm_lane_close_after_merge <home> <state> <task-id>: after a proven merge, run a
# plain teardown when the home opted in. Always returns 0: the merge already
# landed, so a refused teardown is reported and the lane is left for review.
fm_lane_close_after_merge() {
  local home=$1 state=$2 id=$3 rc=0
  if ! fm_lane_close_live "$home"; then
    printf 'lane close: dry-run, would tear down %s (live needs config/lane-close-live)\n' "$id"
    return 0
  fi
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$(fm_lane_close_teardown)" "$id" >&2 || rc=$?
  case "$rc" in
    0 | 4) printf 'lane close: tore down %s after the merge\n' "$id" ;;
    *) printf 'actionable: merged, but teardown of %s refused (rc=%s); the lane is kept for review\n' "$id" "$rc" >&2 ;;
  esac
  return 0
}
