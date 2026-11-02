#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
B="$ROOT/.validation/backend"
mkdir -p "$B/bin"
REAL_TMUX=$(command -v tmux)
printf '#!/usr/bin/env bash\ncd %q\nexec %q -f /dev/null -S .validation/backend/socket "$@"\n' "$ROOT" "$REAL_TMUX" > "$B/bin/tmux"
chmod +x "$B/bin/tmux"
export PATH="$B/bin:$PATH"
unset TMUX
cleanup() { tmux kill-server >/dev/null 2>&1 || true; rm -rf "$B"; }
trap cleanup EXIT
. bin/fm-backend.sh
fm_backend_source tmux
. bin/fm-lane-close-lib.sh
tmux new-session -d -s fm-lab-backend -n supervisor -x 120 -y 32 sh
tmux new-window -d -t fm-lab-backend: -n fm-idle sh
tmux new-window -d -t fm-lab-backend: -n fm-busy "sh -c 'sleep 600; exit 0'"
for i in $(seq 1 50); do
  idle=$(tmux display-message -p -t =fm-lab-backend:=fm-idle '#{pane_current_command}')
  busy=$(tmux display-message -p -t =fm-lab-backend:=fm-busy '#{pane_current_command}')
  [ "$idle:$busy" != sh:sh ] || break
  sleep .1
done
echo 'Before duplicate spawn:'
tmux list-windows -t =fm-lab-backend -F '#{window_id} #{window_name} #{pane_current_command}'
old=$(fm_backend_tmux_window_id fm-lab-backend fm-idle)
new=$(fm_backend_tmux_create_task fm-lab-backend fm-idle "$ROOT")
printf 'Idle-shell replacement old=%s new=%s\n' "$old" "$new"
[ "$old" != "$new" ]
oldbusy=$(fm_backend_tmux_window_id fm-lab-backend fm-busy)
if fm_backend_tmux_create_task fm-lab-backend fm-busy "$ROOT"; then echo 'ERROR: running child replaced'; exit 1; fi
[ "$oldbusy" = "$(fm_backend_tmux_window_id fm-lab-backend fm-busy)" ]
echo 'After duplicate spawn:'
tmux list-windows -t =fm-lab-backend -F '#{window_id} #{window_name} #{pane_current_command}'
# Close helper consumes exact recorded ownership, after ordinary teardown.
printf 'backend=tmux\nwindow=fm-lab-backend:fm-idle\n' > "$B/record"
ses=$(fm_lane_close_window_session "$B/record" idle)
fm_lane_close_window "$ses" idle
printf 'backend=tmux\nwindow=fm-lab-backend:fm-busy\n' > "$B/record"
ses=$(fm_lane_close_window_session "$B/record" busy)
if fm_lane_close_window "$ses" busy; then echo 'ERROR: running-child close reported success'; exit 1; fi
printf 'backend=tmux\nwindow=fm-lab-backend:other\n' > "$B/record"
[ -z "$(fm_lane_close_window_session "$B/record" busy)" ]
printf 'backend=tmux\n' > "$B/record"
[ -z "$(fm_lane_close_window_session "$B/record" busy)" ]
echo 'After recorded-endpoint cleanup (idle removed, child/supervisor retained):'
tmux list-windows -t =fm-lab-backend -F '#{window_id} #{window_name} #{pane_current_command}' | tee "$B/windows"
! grep -q ' fm-idle ' "$B/windows"
grep -q ' fm-busy ' "$B/windows"
grep -q ' supervisor ' "$B/windows"
echo 'OBSERVED: replacement changes only idle-shell window ID; busy child refuses replacement and cleanup; absent/mismatched records claim no session.'
