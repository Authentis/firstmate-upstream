#!/usr/bin/env bash
# Live driver: real fm-config-push.sh pushing config/herdr-project-groups from a
# disposable lab primary home into a disposable secondmate home, then the real
# fm-herdr-groups.sh reader run inside the secondmate home.
set -u
ROOT=$1
W=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
W=$(cd "$W" && pwd -P)
cleanup() { TMUX_TMPDIR="$W/tmux" tmux kill-server 2>/dev/null; rm -rf "$W"; }
trap cleanup EXIT
"$ROOT/bin/fm-lab-home.sh" create "$W/home" >/dev/null
mkdir -p "$W/tmux"
export TMUX_TMPDIR="$W/tmux"
unset TMUX NO_MISTAKES_GATE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
git init -q -b main "$W/main"
printf 'projects/\nstate/\ndata/\nconfig/\n' > "$W/main/.gitignore"
printf 'v1\n' > "$W/main/AGENTS.md"
mkdir -p "$W/main/bin"; printf 'echo a\n' > "$W/main/bin/tool.sh"
git -C "$W/main" add -A
git -C "$W/main" -c user.name=t -c user.email=t@t commit -qm c1
git -C "$W/main" worktree add -q --detach "$W/sm" HEAD
printf 'sm\n' > "$W/sm/.fm-secondmate-home"
mkdir -p "$W/sm/config" "$W/sm/state" "$W/sm/data"
printf 'window=firstmate:fm-sm\nkind=secondmate\nhome=%s/sm\n' "$W" > "$W/home/state/sm.meta"
tmux new-session -d -s firstmate -n fm-sm -x 200 -y 50 "cat"

push() {
  FM_HOME="$W/home" FM_SEND_SETTLE=0 "$ROOT/bin/fm-config-push.sh" 2>&1
  echo "exit=$?"
}
show() {
  if [ -e "$W/sm/config/herdr-project-groups" ]; then
    echo 'secondmate config/herdr-project-groups PRESENT:'
    sed 's/^/  | /' "$W/sm/config/herdr-project-groups"
  else
    echo 'secondmate config/herdr-project-groups ABSENT'
  fi
}
redact() { sed "s#$W#<LAB>#g"; }
filt() { redact | grep -E "${1:-herdr-project-groups|config-reread|exit=}"; }
okey() {
  FM_HOME="$W/sm" "$ROOT/bin/fm-herdr-groups.sh" order-key t1 "$W/projects/$1" 2>&1 | redact | sed 's/^/  order-key> /'
  echo "  order-key exit=${PIPESTATUS[0]}"
}
mkdir -p "$W/projects/alpha" "$W/projects/beta"

echo "=== S1: primary sets rule lines; config-push ==="
printf '# groups\ninfra repo:beta\nweb repo:alpha\n' > "$W/home/config/herdr-project-groups"
push | filt 'config-push|secondmate|herdr-project-groups|config-reread|exit='
show
echo "=== S1b: reader in secondmate home uses inherited rules ==="
okey alpha
okey beta
echo "=== S2: re-push with no change ==="
push | filt
echo "=== S3: primary changes to off; push ==="
printf 'off\n' > "$W/home/config/herdr-project-groups"
push | filt
show
okey alpha
echo "=== S4: primary removes file; push mirrors absence ==="
rm -f "$W/home/config/herdr-project-groups"
push | filt
show
okey alpha
echo "=== S5: adversarial - secondmate diverged locally; primary authoritative ==="
printf 'on\n' > "$W/home/config/herdr-project-groups"
printf 'tamper repo:zzz\n' > "$W/sm/config/herdr-project-groups"
push | filt
show
okey alpha
