#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
E=~/.no-mistakes/evidence/01M6FAVMY4A1RD4HQ95NB81C97
LAB=$(mktemp -d /tmp/fm-lab.XXXXXX)
cleanup() {
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab kill-server 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT
bin/fm-lab-home.sh create "$LAB" >/dev/null
mkdir -p "$LAB/tmux"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
export FM_HOME="$LAB"
. "$ROOT/bin/fm-task-inbox-lib.sh"
rec=$(fm_task_inbox_write "$LAB/state" live-ack "Disposable validation: write the word acknowledged to $LAB/data/worker-action.txt, then acknowledge this message with the command the doorbell names. Do not change any other data or contact anyone.")
bell=$(fm_task_inbox_doorbell_line "$rec")
printf '%s\n' "$bell" > "$E/worker-emitted-doorbell.txt"
# Noninteractive Claude avoids persisting a folder-trust decision. It is still
# the real installed CLI using the existing normal login, in the private lab.
python3 - "$LAB" "$E" "$bell" "$ROOT" <<'PY'
import sys, shlex
from pathlib import Path
lab,e,bell,root=sys.argv[1:]
args=['claude','--print','--no-session-persistence','--output-format','stream-json','--verbose','--allowedTools','Bash,Read','--system-prompt',
      'You are a disposable Firstmate ship worker in an isolated validation lab. Follow the steering inbox instruction below. Only read the named FM_TASK_INBOX, and only write under FM_HOME. Do not run supervisor startup, spawn anything, access operator data, or change configuration. The code root is the current directory. Use its real bin scripts for acknowledgements. Finish after acting on and acknowledging the message.',bell]
cmd=shlex.join(args)+' > '+shlex.quote(e+'/worker-cli.jsonl')+' 2> '+shlex.quote(e+'/worker-cli.stderr')
cmd+='; rc=$?; printf "%s\\n" "$rc" > '+shlex.quote(lab+'/exit-status')
Path(lab+'/run-worker.sh').write_text('#!/usr/bin/env bash\n'+cmd+'\n')
PY
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -s primary -x 220 -y 50 -c "$ROOT" -e FM_HOME="$LAB" -e FM_TASK_INBOX="$LAB/state/live-ack.inbox" bash "$LAB/run-worker.sh"
for ((i=0;i<180;i++)); do
  [ ! -f "$LAB/exit-status" ] || break
  sleep 1
done
{
  printf 'Real worker route: private tmux, noninteractive installed Claude CLI, normal login, no session persistence, synthetic FM_HOME.\n'
  printf 'Emitted instruction: %s\n' "$bell"
  if [ ! -f "$LAB/exit-status" ]; then echo 'Worker did not finish within 180 seconds'; exit 124; fi
  rc=$(<"$LAB/exit-status")
  printf 'Claude exit status: %s\n' "$rc"
  if [ -f "$LAB/data/worker-action.txt" ]; then printf 'Action file: '; head -c 200 "$LAB/data/worker-action.txt"; printf '\n'; else echo 'Action file absent'; fi
  if [ -f "$LAB/state/live-ack.inbox/handled/001.msg" ]; then echo 'Acknowledged record: handled/001.msg'; else echo 'Acknowledged record absent'; fi
  test "$rc" = 0
  test -f "$LAB/data/worker-action.txt"
  test -f "$LAB/state/live-ack.inbox/handled/001.msg"
  test ! -f "$rec"
  due=$(fm_task_inbox_due_action "$LAB/state" live-ack)
  printf 'Post-worker retry decision: %s\n' "$due"
  test "$due" = quiet
} > "$E/worker-result.txt" 2>&1
