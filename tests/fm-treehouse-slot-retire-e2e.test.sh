#!/usr/bin/env bash
# End-to-end proof of the pool-slot retire against the REAL treehouse (>= 3.1),
# in an isolated scratch repo with its own pool (TREEHOUSE_ROOT); the machine's
# shared pool is never touched. tests/fm-treehouse-lease.test.sh covers the same
# contract against a stateful fake; this file exists because only the real
# treehouse can say that `return` detaches HEAD and keeps the branch ref, and
# that a slot left `available [branch]` by a killed pane hands out again.
# Skips (exit 0) when treehouse is absent or older than 3.1.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
fm_git_identity fmtest fmtest@example.invalid

SLOT_RELEASE="$ROOT/bin/fm-slot-release.sh"

if ! command -v treehouse >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  echo "skip - treehouse or jq is not installed"
  exit 0
fi
version=$(treehouse --version 2>/dev/null | sed -E 's/^[^0-9]*([0-9]+)\.([0-9]+).*/\1 \2/')
read -r major minor <<EOF
${version:-0 0}
EOF
if [ "${major:-0}" -lt 3 ] || { [ "$major" -eq 3 ] && [ "${minor:-0}" -lt 1 ]; }; then
  echo "skip - treehouse >= 3.1 is required (found: $(treehouse --version 2>/dev/null))"
  exit 0
fi

TMP_ROOT=$(fm_test_tmproot fm-treehouse-slot-retire-e2e)
HOME_DIR="$TMP_ROOT/home"
REPO="$TMP_ROOT/repo"
POOL="$TMP_ROOT/pool"
KILL_PGID=
cleanup_e2e() {
  [ -z "$KILL_PGID" ] || kill -9 -- "-$KILL_PGID" 2>/dev/null || true
}
trap cleanup_e2e EXIT

mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/projects"
git init -q --bare "$TMP_ROOT/origin.git"
git -C "$TMP_ROOT/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$TMP_ROOT/origin.git" "$REPO" 2>/dev/null
git -C "$REPO" commit -q --allow-empty -m baseline
git -C "$REPO" push -q origin HEAD:main
git -C "$REPO" branch -M main 2>/dev/null || true
ln -s "$REPO" "$HOME_DIR/projects/repo"

th() { TREEHOUSE_ROOT="$POOL" treehouse "$@" </dev/null; }
release() { FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" TREEHOUSE_ROOT="$POOL" "$SLOT_RELEASE" "$@"; }
slot_row() { (cd "$REPO" && th status --json) | jq -c --arg p "$1" '.[] | select(.path == $p)'; }

test_retire_then_lease_with_the_real_treehouse() {
  local lease slot id out
  id=e2e-lane-a
  lease=$(cd "$REPO" && th get --lease --json --lease-holder "fm-$id" 2>/dev/null)
  slot=$(printf '%s' "$lease" | jq -r .path)
  [ -d "$slot" ] || fail "control: the real treehouse did not lease a slot"$'\n'"$lease"
  git -C "$slot" checkout -q -b fm/e2e-lane-a
  printf 'task=%s\nhome=%s\n' "$id" "$HOME_DIR" > "$(dirname "$slot")/.fm-slot-owner"
  fm_write_meta "$HOME_DIR/state/$id.meta" "worktree=$slot" "project=$REPO" \
    "lease_id=$(printf '%s' "$lease" | jq -r .lease_id)" "kind=ship"
  out=$(release "$id")
  [ "$out" = released ] || fail "retire against the real treehouse should print released, got: $out"
  git -C "$REPO" rev-parse --verify -q refs/heads/fm/e2e-lane-a >/dev/null || fail "the lane branch must be kept"
  [ "$(slot_row "$slot" | jq -r .status)" = available ] || fail "the retired slot must read available"
  git -C "$slot" symbolic-ref --quiet HEAD >/dev/null 2>&1 && fail "the retired slot must be detached"
  assert_absent "$(dirname "$slot")/.fm-slot-owner" "the claim must be released"
  lease=$(cd "$REPO" && th get --lease --json --lease-holder fm-next 2>/dev/null)
  [ "$(printf '%s' "$lease" | jq -r .path)" = "$slot" ] || fail "the retired slot did not lease again"$'\n'"$lease"
  (cd "$REPO" && th return --if-lease-id "$(printf '%s' "$lease" | jq -r .lease_id)" "$slot" >/dev/null 2>&1)
  pass "real treehouse: retire detaches the slot, keeps the branch, and the slot leases again"
}

test_sweep_a_hard_killed_pane_with_the_real_treehouse() {
  local slot out row log pgid
  log="$TMP_ROOT/get.out"
  set -m
  ( printf 'git checkout -q -b fm/e2e-lane-e\n'; sleep 30 ) | (cd "$REPO" && TREEHOUSE_ROOT="$POOL" treehouse get) >"$log" 2>&1 &
  pgid=$(ps -o pgid= -p $! | tr -d ' ')
  set +m
  KILL_PGID=$pgid
  local waited=0
  while [ "$waited" -lt 40 ]; do
    slot=$(cd "$REPO" && th status --json | jq -r '.[] | select(.status == "in-use") | .path' | head -1)
    if [ -n "$slot" ] && [ "$(git -C "$slot" branch --show-current 2>/dev/null)" = fm/e2e-lane-e ]; then break; fi
    sleep 0.5
    waited=$((waited + 1))
  done
  [ -n "$slot" ] || fail "control: the interactive get never took a slot"
  { kill -9 -- "-$pgid"; wait; } 2>/dev/null || true
  KILL_PGID=
  waited=0
  while [ "$waited" -lt 20 ] && [ "$(slot_row "$slot" | jq -r .status)" != available ]; do
    sleep 0.5
    waited=$((waited + 1))
  done
  row=$(slot_row "$slot")
  [ "$(printf '%s' "$row" | jq -r .status)" = available ] || fail "control: the killed pane's slot should read available: $row"
  [ "$(printf '%s' "$row" | jq -r .branch)" = fm/e2e-lane-e ] || fail "control: the killed pane's slot should still hold its branch: $row"
  printf 'task=gone-task\nhome=%s\n' "$HOME_DIR" > "$(dirname "$slot")/.fm-slot-owner"
  out=$(release --sweep "$REPO")
  [ -z "$out" ] || fail "a released slot is silent, got: $out"
  git -C "$REPO" rev-parse --verify -q refs/heads/fm/e2e-lane-e >/dev/null || fail "the leftover's branch must be kept"
  git -C "$slot" symbolic-ref --quiet HEAD >/dev/null 2>&1 && fail "the swept slot must be detached"
  assert_grep "fm/e2e-lane-e released" "$HOME_DIR/state/slot-sweep.log" "the sweep must log the slot it acted on"
  out=$(cd "$REPO" && th get --lease --json --lease-holder fm-after-sweep 2>/dev/null)
  [ "$(printf '%s' "$out" | jq -r .path)" = "$slot" ] || fail "the swept slot did not lease again"$'\n'"$out"
  pass "real treehouse: the sweep returns a hard-killed pane's slot to leasable, branch kept"
}

test_retire_then_lease_with_the_real_treehouse
test_sweep_a_hard_killed_pane_with_the_real_treehouse

echo "# all fm-treehouse-slot-retire-e2e tests passed"
