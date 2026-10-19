#!/usr/bin/env bash
# Live driver: the real sender (bin/fm-remote-inherit-push.sh -> bin/fm-on.sh
# from the run worktree) pushes the full inherited set to a disposable "remote"
# secondmate home whose receiver code root is extracted at RECV_REV. Only the
# SSH hop and remote worker queue are replaced by a local transport shim that
# decodes fm-on.sh's protocol argv and execs <root>/bin/<cmd> under an empty
# environment with FM_HOME=<home>, as the remote entrypoint's worker does.
# Usage: drive-remote-inherit.sh <worktree> <receiver-rev> <lab-dir>
set -u
WT=$1; RECV_REV=$2; LAB=$3
mkdir -p "$LAB/primary/config" "$LAB/primary/data" "$LAB/remote-home/config" "$LAB/remote-home/data" "$LAB/bin" "$LAB/recv-root"
git -C "$WT" archive "$RECV_REV" bin | tar -x -C "$LAB/recv-root" -f -
cat > "$LAB/bin/ssh" <<'SH'
#!/usr/bin/env bash
while [ "$1" != -- ]; do shift; done; shift
host=$1
root=$(printf '%s' "$4" | base64 -D)
home=$(printf '%s' "$5" | base64 -D)
args=(); while IFS= read -r -d '' a; do args+=("$a"); done < <(printf '%s' "$6" | base64 -D)
printf 'ssh-shim host=%s root=%s cmd=%s\n' "$host" "$root" "${args[*]}" >> "$LAB_LOG"
exec env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin FM_HOME="$home" bash "$root/bin/${args[0]}" "${args[@]:1}"
SH
chmod +x "$LAB/bin/ssh"
printf -- '- bosgame - lab remote (host: bosgame-lab; root: %s; home: %s; scope: lab; projects: none; added 2026-10-19)\n' \
  "$LAB/recv-root" "$LAB/remote-home" > "$LAB/primary/data/secondmates.md"
printf 'maintainer\n' > "$LAB/primary/config/firstmate-role"
printf 'herdr\n' > "$LAB/primary/config/backend"
echo "== receiver rev: $(git -C "$WT" rev-parse --short "$RECV_REV"); sender: $(git -C "$WT" rev-parse --short HEAD)"
LAB_LOG="$LAB/ssh.log" FM_HOME="$LAB/primary" FM_ROOT_OVERRIDE="$WT" \
  FM_CONFIG_OVERRIDE="$LAB/primary/config" FM_DATA_OVERRIDE="$LAB/primary/data" \
  FM_SSH_BIN="$LAB/bin/ssh" bash "$WT/bin/fm-remote-inherit-push.sh" bosgame 7
status=$?
echo "== push exit status: $status"
echo "== shim calls: $(wc -l < "$LAB/ssh.log" | tr -d ' ')"
echo "== remote home config/firstmate-role: $(cat "$LAB/remote-home/config/firstmate-role" 2>&1)"
echo "== remote home config/backend: $(cat "$LAB/remote-home/config/backend" 2>&1)"
exit $status
