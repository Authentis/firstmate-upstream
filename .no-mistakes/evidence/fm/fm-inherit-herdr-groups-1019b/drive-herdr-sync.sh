#!/usr/bin/env bash
# Live driver: the real fm-herdr-groups.sh reader against a throwaway
# fm-lab-* Herdr session provisioned by bin/fm-herdr-lab.sh, in a disposable
# lab home whose config/herdr-project-groups was inherited by fm-config-push.sh.
set -u
ROOT=$1
LAB="$ROOT/bin/fm-herdr-lab.sh"
W=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
W=$(cd "$W" && pwd -P)
S=$("$LAB" name groups) || exit 1
cleanup() {
  echo "=== teardown $S ==="
  "$LAB" teardown "$S" 2>&1 | tail -3
  TMUX_TMPDIR="$W/tmux" tmux kill-server 2>/dev/null
  rm -rf "$W"
}
trap cleanup EXIT
unset TMUX NO_MISTAKES_GATE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_ROOT_OVERRIDE
redact() { sed -e "s#$W#<LAB>#g"; }

echo "=== provision $S ==="
"$LAB" provision "$S" 2>&1 | tail -2
"$LAB" run "$S" status --json | jq -c '{client_protocol: .client.protocol}'

# Primary home with the opt-in rules, secondmate home that inherits them.
"$ROOT/bin/fm-lab-home.sh" create "$W/home" >/dev/null
mkdir -p "$W/tmux"; export TMUX_TMPDIR="$W/tmux"
git init -q -b main "$W/main"
printf 'projects/\nstate/\ndata/\nconfig/\n' > "$W/main/.gitignore"
printf 'v1\n' > "$W/main/AGENTS.md"
mkdir -p "$W/main/bin"; printf 'echo a\n' > "$W/main/bin/tool.sh"
git -C "$W/main" add -A
git -C "$W/main" -c user.name=t -c user.email=t@t commit -qm c1
git -C "$W/main" worktree add -q --detach "$W/sm" HEAD
printf 'sm\n' > "$W/sm/.fm-secondmate-home"
mkdir -p "$W/sm/config" "$W/sm/state" "$W/sm/data" "$W/sm/projects/alpha"
printf 'window=firstmate:fm-sm\nkind=secondmate\nhome=%s/sm\n' "$W" > "$W/home/state/sm.meta"
tmux new-session -d -s firstmate -n fm-sm -x 200 -y 50 "cat"
printf 'web repo:alpha\n' > "$W/home/config/herdr-project-groups"
echo "=== primary -> secondmate config-push ==="
FM_HOME="$W/home" FM_SEND_SETTLE=0 "$ROOT/bin/fm-config-push.sh" 2>&1 | redact

echo "=== create a worker pane in the lab session ==="
created=$("$LAB" run "$S" workspace create --label "groups-lab" --no-focus 2>&1)
echo "$created" | jq -c '.result | {type, workspace: .workspace.workspace_id, pane: (.root_pane.pane_id // .pane.pane_id)}' 2>/dev/null || echo "$created"
ws=$(echo "$created" | jq -r '.result.workspace.workspace_id')
pane=$(echo "$created" | jq -r '.result.root_pane.pane_id // .result.pane.pane_id // empty')
if [ -z "$pane" ]; then
  pane=$("$LAB" run "$S" pane list | jq -r --arg w "$ws" '[.result.panes[] | select(.workspace_id==$w)][0].pane_id')
fi
echo "workspace=$ws pane=$pane"

# A ship task recorded in the SECONDMATE home, bound to that real pane.
printf 'kind=ship\nbackend=herdr\nproject=%s/sm/projects/alpha\nherdr_session=%s\nherdr_workspace_id=%s\nherdr_pane_id=%s\n' \
  "$W" "$S" "$ws" "$pane" > "$W/sm/state/t1.meta"

ptokens() { "$LAB" run "$S" pane list | jq -c --arg p "$pane" '.result.panes[] | select(.pane_id==$p) | {pane_id, tokens: (.tokens // {})}'; }
echo "=== tokens before sync ==="; ptokens
echo "=== plan (secondmate home) ==="
FM_HOME="$W/sm" "$ROOT/bin/fm-herdr-groups.sh" plan 2>&1 | redact
echo "=== sync (secondmate home) ==="
FM_HOME="$W/sm" "$ROOT/bin/fm-herdr-groups.sh" sync 2>&1 | redact; echo "sync exit=${PIPESTATUS[0]}"
echo "=== tokens after sync (read back from Herdr) ==="; ptokens
echo "=== second sync is a no-op ==="
FM_HOME="$W/sm" "$ROOT/bin/fm-herdr-groups.sh" sync 2>&1 | redact; echo "sync exit=${PIPESTATUS[0]}"; ptokens
echo "=== primary turns groups off, pushes; secondmate sync must do nothing ==="
printf 'off\n' > "$W/home/config/herdr-project-groups"
FM_HOME="$W/home" FM_SEND_SETTLE=0 "$ROOT/bin/fm-config-push.sh" 2>&1 | grep 'herdr-project-groups'
FM_HOME="$W/sm" "$ROOT/bin/fm-herdr-groups.sh" plan 2>&1 | redact; echo "plan exit=${PIPESTATUS[0]} (no lines = off)"
echo "=== clear (secondmate home) ==="
FM_HOME="$W/sm" "$ROOT/bin/fm-herdr-groups.sh" clear 2>&1 | redact; echo "clear exit=${PIPESTATUS[0]}"
echo "=== tokens after clear ==="; ptokens
