#!/usr/bin/env bash
# Run the real bin/fm-session-start.sh --reemit against the lab home with a
# tiny lane byte budget. Usage: run-reemit.sh <worktree> <lab-dir> <out>
set -u
WT=$1 H=$2 OUT=$3
cd "$WT" || exit 1
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
  -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u CLAUDECODE \
  FM_HOME="$H" FM_SESSION_START_REEMIT_WORK_MAX_BYTES=400 \
  "$WT/bin/fm-session-start.sh" --reemit > "$OUT" 2>&1
echo "exit=$?" >> "$OUT"
