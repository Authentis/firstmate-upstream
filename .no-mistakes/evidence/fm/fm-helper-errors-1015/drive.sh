#!/usr/bin/env bash
# drive.sh <script> <mode> <label>: run the given fm-pr-merge.sh copy against the
# mock Forgejo through the real tea client, in a freshly minted lab home.
set -u
WT=~/.no-mistakes/worktrees/7e4b90506ed5/01M50HXDQ4NYY1C1EFR6WTSEJ6
SRV=/tmp/fmlab-01M50HX/srv
script=$1 mode=$2 label=$3
LAB=$(mktemp -d /tmp/fmlab-01M50HX/home.XXXXXX)
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 9
# fm-lab-home writes the stock layout; seed the markdown backlog a task home has.
cat > "$LAB/.tasks.toml" <<'TOML'
backend = "markdown"

[markdown]
path = "data/backlog.md"
archive = "data/done-archive.md"
done_keep = 10
TOML
printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$LAB/data/backlog.md"
mkdir -p "$LAB/wt"
git -C "$LAB/wt" init -q -b main
echo lab > "$LAB/wt/README.md"
git -C "$LAB/wt" add README.md
git -C "$LAB/wt" -c user.name=lab -c user.email=lab@example.invalid commit -qm initial
git -C "$LAB/wt" update-ref refs/remotes/origin/main "$(git -C "$LAB/wt" rev-parse HEAD)"
printf '%s\n' "window=fm-task-x1" "worktree=$LAB/wt" "project=$LAB/project" \
  "kind=ship" "mode=no-mistakes" > "$LAB/state/task-x1.meta"

printf '%s\n' "$mode" > "$SRV/mode"
rm -f "$SRV/merged" "$SRV/merge-body"
: > "$SRV/requests.log"

echo "=== $label: $(basename "$script") task-x1 https://127.0.0.1/labowner/labrepo/pulls/9  [server mode: $mode]"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
  -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  FM_HOME="$LAB" HOME=/tmp/fmlab-01M50HX/userhome XDG_CONFIG_HOME=/tmp/fmlab-01M50HX/userhome/.config \
  PATH="/tmp/fmlab-01M50HX/gobin:$PATH" \
  "$script" task-x1 https://127.0.0.1/labowner/labrepo/pulls/9 2>&1
echo "--- fm-pr-merge exit status: $?"
echo "--- requests the mock Forgejo received:"
sed 's/^/    /' "$SRV/requests.log"
if [ -e "$SRV/merged" ]; then echo "--- MERGE POSTED: $(cat "$SRV/merge-body")"; else echo "--- no merge was posted"; fi
echo "--- task meta after run:"; sed 's/^/    /' "$LAB/state/task-x1.meta"
rm -rf "$LAB"
echo
