#!/usr/bin/env bash
set -eu
L=$PWD/.test-live
E=~/.no-mistakes/evidence/01M66BN74HWH511G9TWY2XJ2R5
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$L/key.pem" -out "$L/cert.pem" -days 1 -config "$L/openssl.cnf" > "$L/openssl.log" 2>&1
head=$(git -C "$L/project" rev-parse main)
git -C "$L/project" push -q origin main:refs/pull/7/head
printf 'MERGED' > "$L/forge-state"
python3 "$L/forge.py" "$head" "$L/cert.pem" "$L/key.pem" "$L/forge-state" > "$E/local-forge.log" 2>&1 &
pid=$!
trap 'kill "$pid"; wait "$pid" || true' EXIT
export GH_HOST=forge.test.invalid GH_ENTERPRISE_TOKEN=synthetic-local-token GH_TOKEN=synthetic-local-token GH_CONFIG_DIR=$L/gh SSL_CERT_FILE=$L/cert.pem
export HTTPS_PROXY=http://127.0.0.1:18443 https_proxy=http://127.0.0.1:18443 NO_PROXY= no_proxy=
mkdir -p "$GH_CONFIG_DIR"
# Verify the actual gh client is ready before driving teardown.
for i in 1 2 3 4 5; do
 if gh pr view https://forge.test.invalid/example/repo/pull/7 --json state,headRefOid,url > "$L/gh-result.json" 2> "$L/gh-error"; then break; fi
 sleep 1
done
python3 -c 'import json,sys; v=json.load(open(sys.argv[1])); assert v["state"]=="MERGED"' "$L/gh-result.json"
export FM_HOME=$L/home FM_ROOT_OVERRIDE=$PWD FM_STATE_OVERRIDE=$L/home/state FM_CONFIG_OVERRIDE=$L/home/config
unset FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS FM_TEST_SEAM TMUX TASKS_AXI_FILE TASKS_AXI_BACKEND
mkdir -p "$L/shared"
printf 'untouched shared data\n' > "$L/shared/sentinel"
for scenario in match no-worktree mismatch open; do
 printf 'MERGED' > "$L/forge-state"
 if [ "$scenario" = open ]; then printf 'OPEN' > "$L/forge-state"; fi
 recorded=$head
 if [ "$scenario" = mismatch ]; then recorded=0000000000000000000000000000000000000000; fi
 printf '%s\n' "endpoint_task_id=receipt-lane" "project=$L/project" "worktree=$L/shared" "kind=ship" "mode=no-mistakes" "record_only=yes" "branch=fm/lab" "gate_receipt_source=$L/absent.json" "pr=https://forge.test.invalid/example/repo/pull/7" "pr_head=$recorded" > "$FM_STATE_OVERRIDE/receipt-lane.meta"
 if [ "$scenario" = no-worktree ]; then
  grep -v '^worktree=' "$FM_STATE_OVERRIDE/receipt-lane.meta" > "$L/meta-new"
  mv "$L/meta-new" "$FM_STATE_OVERRIDE/receipt-lane.meta"
 fi
 echo "=== record-only $scenario, absent receipt, real gh + local HTTPS forge ==="
 rc=0
 bin/fm-teardown.sh receipt-lane || rc=$?
 echo "exit=$rc"
 if [ "$scenario" = match ] || [ "$scenario" = no-worktree ]; then
  test "$rc" = 0; test ! -e "$FM_STATE_OVERRIDE/receipt-lane.meta"
  bundle=$(ls -t "$L/home/data/bundles/"receipt-lane*.bundle | head -1)
  git -C "$L/project" bundle verify "$bundle"
  git bundle list-heads "$bundle" | grep "^$head "
 else
  test "$rc" = 1; test -f "$FM_STATE_OVERRIDE/receipt-lane.meta"
 fi
 test "$(< "$L/shared/sentinel")" = 'untouched shared data'
 echo 'shared sentinel preserved; receipt absent'
done
