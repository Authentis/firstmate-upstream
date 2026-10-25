#!/usr/bin/env bash
# Run the real bin/fm-session-start.sh against the lab home from inside a pane
# on the lab's private fm-lab tmux socket, writing the digest to <out>.
# Usage: run-digest.sh <worktree> <lab-dir> <out> [extra env assignments...]
set -u
WT=$1 H=$2 OUT=$3
shift 3
cd "$WT" || exit 1
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
  -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u CLAUDECODE \
  FM_HOME="$H" "$@" "$WT/bin/fm-session-start.sh" > "$OUT" 2>&1
echo "exit=$?" >> "$OUT"
