#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
SCENARIO=${1:-merged}
mkdir -p .record
LAB="$PWD/.record/home"
bin/fm-lab-home.sh create "$LAB"
cleanup() { rm -rf "$ROOT/.record"; }
trap cleanup EXIT
export FM_HOME="$LAB" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=Lab GIT_AUTHOR_EMAIL=lab@example.invalid GIT_COMMITTER_NAME=Lab GIT_COMMITTER_EMAIL=lab@example.invalid
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
export GH_HOST="localhost:$(< .forge/port)" GH_REPO="localhost:$(< .forge/port)/example/repo" GH_ENTERPRISE_TOKEN=synthetic GH_TOKEN=synthetic GH_CONFIG_DIR="$LAB/gh"
export SSL_CERT_FILE="$PWD/.forge/cert.pem"
P="$LAB/projects/project"
git init -q --bare --initial-branch=main "$LAB/origin.git"
git clone -q "$LAB/origin.git" "$P"
printf 'landed\n' > "$P/feature"
git -C "$P" add feature
git -C "$P" commit -qm landed
git -C "$P" push -q origin main HEAD:refs/pull/7/head
HEAD=$(git -C "$P" rev-parse HEAD)
mkdir -p "$LAB/shared"
printf 'shared data, do not touch\n' > "$LAB/shared/sentinel"
cat > "$LAB/state/task-receipt.meta" <<EOF
endpoint_task_id=task-receipt
project=$P
worktree=$LAB/shared
kind=ship
mode=no-mistakes
yolo=off
record_only=yes
gate_receipt_source=bosgame:data/gate-receipts/7.json
pr=7
pr_head=$HEAD
EOF
FORGE_STATE=MERGED
FORGE_HEAD="$HEAD"
case "$SCENARIO" in
 open-force) FORGE_STATE=OPEN ;;
 mismatch-force) FORGE_HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ;;
 fetch-mismatch-force)
  printf 'moved\n' >> "$P/feature"
  git -C "$P" commit -qam moved
  git -C "$P" push -q origin HEAD:refs/pull/7/head
  FORGE_HEAD=$(git -C "$P" rev-parse HEAD)
 ;;
esac
python3 - "$FORGE_HEAD" "$FORGE_STATE" "$GH_HOST" <<'PY'
import json,sys
from pathlib import Path
Path('.forge/config.json').write_text(json.dumps({'head':sys.argv[1], 'state':sys.argv[2], 'url':'https://'+sys.argv[3]+'/example/repo/pull/7'}))
PY
echo "=== synthetic forge, real gh CLI ==="
gh pr view 7 --json state,headRefOid,url
echo "RECEIPT_PRESENT=$([ -f "$LAB/data/gate-receipts/7.json" ] && echo yes || echo no)"
set +e
if [ "$SCENARIO" = merged ]; then bin/fm-teardown.sh task-receipt; else bin/fm-teardown.sh task-receipt --force; fi
RC=$?
set -e
echo "TEARDOWN_EXIT=$RC"
echo "RECORD_PRESENT=$([ -f "$LAB/state/task-receipt.meta" ] && echo yes || echo no)"
echo "SHARED_SENTINEL=$(< "$LAB/shared/sentinel")"
[ "$(< "$LAB/shared/sentinel")" = 'shared data, do not touch' ]
[ ! -e "$LAB/shared/.git" ]
if [ "$SCENARIO" = merged ]; then
 [ "$RC" = 0 ]
 [ ! -f "$LAB/state/task-receipt.meta" ]
 git -C "$P" bundle verify "$LAB/data/bundles/task-receipt.bundle"
 git bundle list-heads "$LAB/data/bundles/task-receipt.bundle"
 git bundle list-heads "$LAB/data/bundles/task-receipt.bundle" | grep -q "^$HEAD "
else
 [ "$RC" = 1 ]
 [ -f "$LAB/state/task-receipt.meta" ]
 [ ! -f "$LAB/data/bundles/task-receipt.bundle" ]
fi
echo "SCENARIO_VERIFIED=$SCENARIO"
