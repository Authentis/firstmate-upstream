#!/usr/bin/env bash
# Live drive: real bin/fm-watch.sh inbox_steer_check against a real tmux pane on
# a private socket, grok-shaped busy footer (Ctrl+c:cancel), disposable state.
# usage: live-postbusy-drive.sh <repo-root> <scenario: idle|ack>
set -u
ROOT=$1; SCEN=$2
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab-postbusy.XXXXXX"); LAB=$(cd "$LAB" && pwd)
SOCK="fm-lab-postbusy-$$"
REAL_TMUX=$(command -v tmux)
mkdir -p "$LAB/shim" "$LAB/state"
printf '#!/usr/bin/env bash\nexec "%s" -L "%s" "$@"\n' "$REAL_TMUX" "$SOCK" > "$LAB/shim/tmux"
chmod +x "$LAB/shim/tmux"
cleanup() { "$REAL_TMUX" -L "$SOCK" kill-server 2>/dev/null; rm -rf "$LAB"; }
trap cleanup EXIT
# A perl worker (not a shell) so the tmux backend reads the pane as a live agent.
cat > "$LAB/worker.pl" <<'W'
$| = 1; my $lab = shift;
while (-e "$lab/busy") { print "\r working...  Ctrl+c:cancel"; select(undef, undef, undef, 0.5); }
print "\n" x 120; print "idle worker ready\n";  # scroll the busy footer out of the screen plus 40-line history capture
while (my $l = <STDIN>) { open(my $f, '>>', "$lab/typed.log"); print $f $l; close $f; print "got: $l"; }
W
touch "$LAB/busy" "$LAB/typed.log"
"$REAL_TMUX" -L "$SOCK" new-session -d -s fmlab -n fm-t1 -x 200 -y 50 "perl $LAB/worker.pl $LAB"
printf 'window=fmlab:fm-t1\nkind=ship\nharness=grok\n' > "$LAB/state/t1.meta"
export FM_STATE_OVERRIDE="$LAB/state" FM_TASK_INBOX_GRACE_SECS=0 FM_TASK_INBOX_BUSY_MAX=2 PATH="$LAB/shim:$PATH"
unset TMUX NO_MISTAKES_GATE
REC=$(bash -c '. "$1/bin/fm-task-inbox-lib.sh"; fm_task_inbox_write "$2" t1 "gate run waiting at review:fix_review; respond"' _ "$ROOT" "$LAB/state")
touch -t 202001010000 "$REC"

count_doorbells() { grep -c 'Firstmate instruction waiting' "$LAB/typed.log" 2>/dev/null || true; }
check() {  # one fresh watcher process per poll, as real watcher restarts would
  bash -c '. "$1/bin/fm-watch.sh" && inbox_steer_check fmlab:fm-t1 t1' _ "$ROOT" >>"$LAB/check.out" 2>&1
  local wakes pane=idle
  wakes=$(grep -c . "$LAB/state/.wake-queue" 2>/dev/null || true)
  [ ! -e "$LAB/busy" ] || pane=busy
  printf '[poll %-7s] pane=%-4s wakes=%s busy-state=%s .escalated=%s .busy-escalated=%s doorbells-typed=%s\n' \
    "$1" "$pane" "${wakes:-0}" \
    "$(tr '\t' ':' < "$LAB/state/t1.inbox/.busy-state" 2>/dev/null || echo -)" \
    "$(cat "$LAB/state/t1.inbox/.escalated" 2>/dev/null || echo -)" \
    "$(cat "$LAB/state/t1.inbox/.busy-escalated" 2>/dev/null || echo -)" \
    "$(count_doorbells)"
}
echo "== scenario=$SCEN record=${REC##*/} (real tmux socket $SOCK, real fm-watch.sh)"
sleep 1
check busy-1; check busy-2; check busy-3; check busy-4
echo "-- wake-queue after busy polls:"; sed 's/^/   /' "$LAB/state/.wake-queue" 2>/dev/null
if [ "$SCEN" = ack ]; then
  mv "$REC" "$LAB/state/t1.inbox/handled/"
  echo "-- worker acknowledged ${REC##*/} (mv into handled/) while still busy"
fi
rm -f "$LAB/busy"; sleep 1.5; echo "-- lane goes idle"
check idle-1; sleep 1; check idle-2; check idle-3
sleep 1
echo "-- typed.log (everything the pane received, including any keys typed while busy):"
sed 's/^/   /' "$LAB/typed.log"
echo "-- pane capture:"
"$REAL_TMUX" -L "$SOCK" capture-pane -p -t fmlab:fm-t1 | grep -v '^$' | sed 's/^/   /'
echo "-- triage log lines:"
grep -rh 'steer-inbox' "$LAB/state" 2>/dev/null | sed 's/^/   /'
echo "-- check.out:"; sed 's/^/   /' "$LAB/check.out"
echo "== final doorbells-typed=$(count_doorbells) wakes=$(grep -c . "$LAB/state/.wake-queue" 2>/dev/null)"
