#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
E=~/.no-mistakes/evidence/01M6FAVMY4A1RD4HQ95NB81C97
D=$(mktemp -d "$ROOT/.doorbell-check.XXXXXX")
trap 'rm -rf "$D"' EXIT
unset FM_STATE_OVERRIDE FM_ROOT_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE
. "$ROOT/bin/fm-task-inbox-lib.sh"
export PATH="$ROOT/bin:$PATH"
exec > "$E/doorbell-product-transcript.txt" 2>&1
printf 'Public contract oracle: requested sanctioned ack command, numeric batch acknowledgement, retry cessation, home-depth-independent doorbell, shell no-op. Synthetic state only.\n'
for layout in ordinary parent-route; do
  export FM_HOME="$D/$layout"
  state="$FM_HOME/state"; task=worker1
  if [ "$layout" = parent-route ]; then state="$state/parent-route"; task=secondmate1; fi
  mkdir -p "$state"
  r1=$(fm_task_inbox_write "$state" "$task" first)
  r2=$(fm_task_inbox_write "$state" "$task" second)
  r3=$(fm_task_inbox_write "$state" "$task" third)
  bell=$(fm_task_inbox_doorbell_line "$r1")
  printf '\n%s emitted doorbell:\n%s\n' "$layout" "$bell"
  [[ "$bell" == *"fm-inbox-ack.sh $task --all-handled-through <seq>"* ]]
  [[ "$bell" != *"mv "* ]]
  cmd=${bell##*" with '"}; cmd=${cmd%"'."}; cmd=${cmd/<seq>/2}
  fm_task_inbox_record_ring "$state" "$task" "$r1"
  fm_task_inbox_record_escalated "$state" "$task" "$r1"
  printf '001.msg\n' > "$state/$task.inbox/.retry-ring"
  printf 'Executing emitted acknowledgement with limit 2: %s\n' "$cmd"
  bash -c "$cmd"
  test -f "$state/$task.inbox/handled/001.msg"
  test -f "$state/$task.inbox/handled/002.msg"
  test -f "$r3"
  test ! -e "$r1"; test ! -e "$r2"
  for mark in .ring-state .escalated .retry-ring; do test ! -e "$state/$task.inbox/$mark"; done
  printf 'Observed handled/{001,002}.msg; 003.msg remains pending; retry/escalation marks cleared.\n'
  fm-inbox-ack.sh "$task" 3
  due=$(fm_task_inbox_due_action "$state" "$task"); test "$due" = quiet
  printf 'After final acknowledgement, retry decision: %s\n' "$due"
  fm-inbox-ack.sh "$task" 3
  printf 'Repeat acknowledgement is idempotent.\n'
done
state="$D/short/state"; mkdir -p "$state"
r=$(fm_task_inbox_write "$state" same-task sample)
short=$(fm_task_inbox_doorbell_line "$r")
long="$D/$(printf 'deep-home-path-%.0s' {1..12})/$(printf 'another-component-%.0s' {1..10})/state"
mkdir -p "$long"
r=$(fm_task_inbox_write "$long" same-task sample)
deep=$(fm_task_inbox_doorbell_line "$r")
test "$short" = "$deep"
printf '\nShort/deep homes produce byte-identical %s-character doorbells (deep state path: %s characters).\n' "${#short}" "${#long}"
# A valid task-like hostile inbox name is not needed: this adversarial directory
# tests the emitter shell boundary, where arbitrary on-disk names can occur.
mkdir -p "$D/hostile/state/x' ; touch SHOULD_NOT_EXIST; #.inbox"
bell=$(fm_task_inbox_doorbell_line "$D/hostile/state/x' ; touch SHOULD_NOT_EXIST; #.inbox/001.msg")
(cd "$D" && bash -c "$bell" && /bin/sh -c "$bell")
test ! -e "$D/SHOULD_NOT_EXIST"
printf 'Hostile-name emitted doorbell evaluated by bash and /bin/sh: exit 0, no injected side effect.\n'
printf '\nGenerated worker brief:\n'
export FM_HOME="$D/brief-home"
mkdir -p "$FM_HOME/config"
"$ROOT/bin/fm-brief.sh" brief-task sample-project --mode local-only
python3 - "$FM_HOME/data/brief-task/brief.md" "$E/generated-inbox-instructions.txt" <<'PY'
import sys
from pathlib import Path
text=Path(sys.argv[1]).read_text()
section=text.split('# Firstmate instruction inbox',1)[1].split('\n# ',1)[0]
Path(sys.argv[2]).write_text('# Firstmate instruction inbox'+section)
print(section)
assert 'fm-inbox-ack.sh' in section
assert 'never move the files by hand' in section
assert 'That command is the acknowledgement' in section
PY
printf '\nAll local public-interface checks completed.\n'
