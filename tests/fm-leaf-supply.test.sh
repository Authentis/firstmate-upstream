#!/usr/bin/env bash
# Behavioral tests for dispatchable bead leaf supply.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SUPPLY="$ROOT/bin/fm-leaf-supply.sh"
SYSTEM_PYTHON3=$(command -v python3) || exit 1
TMP_ROOT=$(fm_test_tmproot fm-leaf-supply)

make_case() {
  local name=$1 root repo tools
  root="$TMP_ROOT/$name"
  repo="$root/repo"
  tools="$root/tools"
  mkdir -p "$repo" "$tools"
  cat > "$root/ready.json" <<'JSON'
[
  {"id":"dos-product-safe","title":"safe","status":"open","issue_type":"task","description":"FILES: src/safe.sh"},
  {"id":"dos-product-landed","title":"landed","status":"open","issue_type":"task","description":"FILES: src/landed.sh"},
  {"id":"dos-product-open","title":"open","status":"open","issue_type":"task","description":"FILES: src/open.sh"},
  {"id":"dos-product-deleted","title":"deleted","status":"open","issue_type":"task","description":"FILES: src/deleted.sh"},
  {"id":"dos-product-otherbase","title":"other base","status":"open","issue_type":"task","description":"FILES: src/exists.sh"},
  {"id":"dos-product-no-files","title":"no files","status":"open","issue_type":"task","description":"no declared surface"}
]
JSON
  cat > "$root/prs.json" <<'JSON'
[
  {"number":1,"state":"closed","merged_at":"2026-09-01T00:00:00Z","merge_commit_sha":"aaa111","base":{"ref":"main"},"title":"finish dos-product-landed","head":{"ref":"fm/dos-product-landed"}},
  {"number":3,"state":"closed","merged_at":"2026-09-01T00:00:00Z","merge_commit_sha":"bbb222","base":{"ref":"main"},"title":"finish dos-product-deleted","head":{"ref":"fm/dos-product-deleted"}},
  {"number":4,"state":"closed","merged_at":"2026-09-01T00:00:00Z","merge_commit_sha":"ccc333","base":{"ref":"epic"},"title":"finish dos-product-otherbase","head":{"ref":"fm/dos-product-otherbase"}},
  {"number":2,"state":"open","merged_at":null,"title":"unrelated work","head":{"ref":"fm/unrelated"}}
]
JSON
  cat > "$tools/br" <<'SH'
#!/usr/bin/env bash
cat "$FM_TEST_READY_JSON"
SH
  cat > "$tools/gh-axi" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *compare/aaa111...main*|*compare/bbb222...main*)
    [ -z "${FM_TEST_COMPARE_FAIL:-}" ] || exit 1
    printf '%s\n' ahead
    ;;
  *pulls?state=*)
    if [ -n "${FM_TEST_GH_AXI_PAGINATED_YAML:-}" ]; then
      cat <<'YAML'
[1]:
  - number: 1
    state: closed
    merged_at: "2026-09-01T00:00:00Z"
    merge_commit_sha: aaa111
    base:
      ref: main
    title: finish dos-product-landed
    head:
      ref: fm/dos-product-landed
  - number: 3
    state: closed
    merged_at: "2026-09-01T00:00:00Z"
    merge_commit_sha: bbb222
    base:
      ref: main
    title: finish dos-product-deleted
    head:
      ref: fm/dos-product-deleted
  - number: 4
    state: closed
    merged_at: "2026-09-01T00:00:00Z"
    merge_commit_sha: ccc333
    base:
      ref: epic
    title: finish dos-product-otherbase
    head:
      ref: fm/dos-product-otherbase
  - number: 2
    state: open
    merged_at: null
    title: unrelated work
    head:
      ref: fm/unrelated
YAML
    else
      cat "$FM_TEST_PRS_JSON"
    fi
    ;;
  *pulls/1/files*) printf '%s\n' '[{"filename":"src/landed.sh"}]' ;;
  *pulls/2/files*)
    if [ -n "${FM_TEST_GH_AXI_PAGINATED_YAML:-}" ]; then
      printf '%s\n' '[1]:' '  - filename: src/open.sh'
    else
      printf '%s\n' '[{"filename":"src/open.sh"}]'
    fi
    ;;
  *pulls/3/files*|*pulls/4/files*) printf '%s\n' '[]' ;;
  *) exit 2 ;;
esac
SH
  cat > "$tools/git" <<'SH'
#!/usr/bin/env bash
exit 2
SH
  cat > "$tools/python3" <<'SH'
#!/usr/bin/env bash
exec "$FM_TEST_SYSTEM_PYTHON3" -S "$@"
SH
  chmod 0755 "$tools/br" "$tools/gh-axi" "$tools/git" "$tools/python3"
  printf '%s|%s|%s\n' "$root" "$repo" "$tools"
}

run_supply() {
  local root=$1 repo=$2 tools=$3
  shift 3
  env PATH="$tools:$PATH" FM_TEST_SYSTEM_PYTHON3="$SYSTEM_PYTHON3" \
    FM_TEST_READY_JSON="$root/ready.json" FM_TEST_PRS_JSON="$root/prs.json" \
    "$SUPPLY" "$repo" --repository example/repo "$@"
}

test_reports_only_dispatchable_file_scoped_leaves() {
  local rec root repo tools out
  rec=$(make_case filters)
  IFS='|' read -r root repo tools <<EOF
$rec
EOF
  out=$(run_supply "$root" "$repo" "$tools" 2>&1) || fail "leaf supply failed: $out"
  assert_contains "$out" 'dispatchable: 2' "dispatchable leaf count is wrong: $out"
  assert_contains "$out" 'dos-product-otherbase' "leaf merged into a non-main base was treated as landed"
  assert_not_contains "$out" 'dos-product-deleted' "leaf whose only file it deleted was reported dispatchable"
  assert_contains "$out" 'dos-product-safe' "safe leaf was omitted"
  assert_not_contains "$out" 'dos-product-landed' "merged leaf survived"
  assert_not_contains "$out" 'dos-product-open' "open-PR leaf survived"
  pass "leaf supply requires files, ready deps, no merged landing, and no open PR"
}

test_accepts_paginated_gh_axi_yaml() {
  local rec root repo tools out
  rec=$(make_case paginated-yaml)
  IFS='|' read -r root repo tools <<EOF
$rec
EOF
  out=$(FM_TEST_GH_AXI_PAGINATED_YAML=1 run_supply "$root" "$repo" "$tools" 2>&1) \
    || fail "leaf supply rejected gh-axi paginated YAML: $out"
  assert_contains "$out" 'dispatchable: 2' "paginated YAML changed the dispatchable count: $out"
  assert_not_contains "$out" 'dos-product-landed' "paginated YAML failed to exclude a landed leaf"
  pass "leaf supply accepts gh-axi paginated YAML"
}

test_plan_threshold_reports_due_without_spawning() {
  local rec root repo tools out
  rec=$(make_case threshold)
  IFS='|' read -r root repo tools <<EOF
$rec
EOF
  out=$(run_supply "$root" "$repo" "$tools" --plan-below 14) || fail "leaf supply threshold failed"
  assert_contains "$out" 'planning: due (2 < 14)' "threshold did not report planning due"
  assert_contains "$out" 'spawn command:' "threshold did not print the bounded planning command"
  pass "low leaf supply reports planning due without spawning a lane"
}

test_fails_closed_when_current_main_cannot_be_verified() {
  local rec root repo tools out status
  rec=$(make_case compare-failure)
  IFS='|' read -r root repo tools <<EOF
$rec
EOF
  out=$(FM_TEST_COMPARE_FAIL=1 run_supply "$root" "$repo" "$tools" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "supply continued without a current-main comparison: $out"
  assert_contains "$out" 'could not verify whether merged pull request for dos-product-landed reached current main' \
    "comparison failure was not surfaced as verification failure"
  pass "leaf supply fails closed when current main cannot be verified"
}

test_check_refuses_a_leaf_landed_or_held_by_a_pull_request() {
  local rec root repo tools out status
  rec=$(make_case check)
  IFS='|' read -r root repo tools <<EOF
$rec
EOF
  out=$(run_supply "$root" "$repo" "$tools" --check dos-product-landed 2>&1)
  status=$?
  [ "$status" -eq 10 ] || fail "landed leaf check should refuse with 10, got $status: $out"
  assert_contains "$out" 'refused: dos-product-landed is not dispatchable' \
    "landed leaf refusal did not name the leaf"
  pass "leaf preflight rejects a landed or pull-request-held leaf"
}

test_reports_only_dispatchable_file_scoped_leaves
test_accepts_paginated_gh_axi_yaml
test_plan_threshold_reports_due_without_spawning
test_fails_closed_when_current_main_cannot_be_verified
test_check_refuses_a_leaf_landed_or_held_by_a_pull_request

echo "# all fm-leaf-supply tests passed"
