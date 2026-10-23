#!/usr/bin/env bash
# Tear the sandbox lab down: kill only the lab's private tmux server, drop the
# mate's worktree registration, and remove every lab directory (all under /tmp).
. ~/.no-mistakes/evidence/01M5N1SRZGKH3FMMZ7PQ7A9XBY/pilot-lab-env.sh
lt kill-server 2>/dev/null || true
sleep 0.3
git -C "$L/projects/proj" worktree remove --force "$SM" 2>/dev/null || true
for d in "$L" "${SM%/smhome}" /tmp/fm-$ID /tmp/fm-$ID+*; do
  case "$d" in /tmp/*|/private/tmp/*) ;; *) echo "skip $d"; continue ;; esac
  [ -e "$d" ] || continue
  chmod -R u+w "$d" && rm -rf -- "$d" && echo "removed $d"
done
